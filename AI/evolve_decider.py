#!/usr/bin/env python3
"""A population evolution for the neural player.

This is the genetic-algorithm half of the training pipeline. It does not train by gradient descent: it
keeps a population of genomes, measures each one by playing frames, and lets the ones that win frames (or
make the highest breaks) reproduce by crossover and weight mutation.

A genome has two parts when the base has them:

* `decider` — the all-decisions network (`Decider.*`);
* `stroke` — the candidate-conditioned stroke (`Model.*`).

Evolving both is what makes a break-selected run meaningful: the decision model can choose the right ball
and the stroke model can then put the cue ball where the next shot needs it. A base with no stroke is still
valid; its decider's own six-number shot head is what plays, so the genome is decider-only.

The studio drives it as:

    evolve_decider.py init   --dir .../Evolution --base <version dir or Decider.pt> ...
    evolve_decider.py breed  --dir .../Evolution --generation 0 ...
    evolve_decider.py finish --dir .../Evolution --session ...

`init` compiles generation 0. `breed` reads the JSON reports the engine wrote for generation N, ranks
them, writes generation N+1 and compiles it. `finish` puts the best genome ever seen in the session as
`Decider.mlmodelc` / `Decider.mlpackage.pt` and, when present, `Model.mlmodelc` / `Model.mlpackage.pt`,
which is what the studio's version save and deploy use.

The fitness functions are deliberately narrow:

* **win-selected**: frames won minus frames lost against the current champion and peers, then wins, then
  fewer unfinished frames, then points difference.
* **break-selected**: the highest break in the individual's self-play frames, then its second-highest
  break, then whether the frames finished, then total points.

A frame that reaches the engine's decision cap is still measured: it contributes its points and counts as
unfinished, so a population that never finishes is visible in the ranking.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
import time
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parent))
from train_candidate_net import CandidateNet, convert as convert_stroke  # noqa: E402
from train_decider_net import DeciderNet, convert as convert_decider  # noqa: E402


# MARK: - Small file and tensor helpers

def read_json(path: Path, default=None):
    try:
        return json.loads(path.read_text())
    except Exception:  # noqa: BLE001
        return default


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n")


def load_state(path: Path) -> dict:
    try:
        state = torch.load(path, map_location="cpu", weights_only=True)
    except TypeError:  # older torch has no weights_only
        state = torch.load(path, map_location="cpu")
    return {key: value.detach().clone() for key, value in state.items()}


def save_state(state: dict, path: Path) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    torch.save(state, path)


def load_genome(decider_path: Path, stroke_path: Path | None = None) -> dict:
    decider = load_state(decider_path)
    stroke = load_state(stroke_path) if stroke_path and stroke_path.is_file() else None
    return {"decider": decider, "stroke": stroke}


def fingerprint_state(state: dict) -> str:
    digest = hashlib.sha256()
    for key in sorted(state):
        value = state[key]
        digest.update(key.encode())
        digest.update(np.ascontiguousarray(value.detach().cpu().numpy()).tobytes())
    return digest.hexdigest()


def fingerprint_genome(genome: dict) -> str:
    digest = hashlib.sha256()
    digest.update(fingerprint_state(genome["decider"]).encode())
    if genome.get("stroke") is not None:
        digest.update(b":stroke:")
        digest.update(fingerprint_state(genome["stroke"]).encode())
    return digest.hexdigest()


def same_architecture(a: dict, b: dict) -> bool:
    return a.keys() == b.keys() and all(a[key].shape == b[key].shape for key in a)


def same_genome_architecture(a: dict, b: dict) -> bool:
    if not same_architecture(a["decider"], b["decider"]):
        return False
    if (a.get("stroke") is None) != (b.get("stroke") is None):
        return False
    return a.get("stroke") is None or same_architecture(a["stroke"], b["stroke"])


def shapes(genome: dict) -> str:
    decider = tuple(genome["decider"]["layers.0.weight"].shape)
    if genome.get("stroke") is None:
        return f"decider {decider}, no stroke"
    stroke = tuple(genome["stroke"]["layers.0.weight"].shape)
    return f"decider {decider}, stroke {stroke}"


# MARK: - Variation

def mutate_state(state: dict, sigma: float, rng: np.random.Generator, kick: float = 0.12) -> dict:
    """A Gaussian step on every weight, scaled to each tensor's own spread.

    A single absolute sigma cannot work for a network whose input layer, hidden layers and heads have very
    different scales. `sigma` is therefore a fraction of each tensor's standard deviation. A small fraction
    of tensors gets a three-times-larger kick, which lets an offspring leave a local basin instead of only
    trembling inside it.
    """
    out = {}
    for key, value in state.items():
        tensor = value.detach().clone()
        if tensor.is_floating_point() and tensor.numel() > 0:
            scale = max(float(tensor.std()), abs(float(tensor.mean())) * 0.01, 1e-4) \
                if tensor.numel() > 1 else max(abs(float(tensor.mean())), 1e-4)
            noise = torch.randn_like(tensor) * (sigma * max(scale, 1e-6))
            if rng.random() < kick:
                noise = noise * 3.0
            tensor = tensor + noise
        out[key] = tensor
    return out


def crossover_state(a: dict, b: dict, rng: np.random.Generator) -> dict:
    """Neuron-wise crossover: an output channel comes whole from one parent.

    Mixing individual weights inside a channel mostly destroys what the channel computes. Choosing each
    output channel of a 1x1 convolution (and its bias) from one parent or the other keeps each neuron's
    function intact while still recombining the two networks.
    """
    child = {}
    for key in a:
        left, right = a[key], b[key]
        if left.ndim == 3:
            mask = torch.rand(left.shape[0]) < 0.5
            child[key] = torch.where(mask.view(-1, 1, 1), left, right)
        elif left.ndim == 1:
            mask = torch.rand(left.shape[0]) < 0.5
            child[key] = torch.where(mask, left, right)
        else:
            mask = torch.rand_like(left) < 0.5
            child[key] = torch.where(mask, left, right)
    return child


def mutate_genome(genome: dict, sigma: float, rng: np.random.Generator) -> dict:
    return {
        "decider": mutate_state(genome["decider"], sigma, rng),
        "stroke": mutate_state(genome["stroke"], sigma, rng) if genome.get("stroke") is not None
        else None,
    }


def crossover_genome(a: dict, b: dict, rng: np.random.Generator) -> dict:
    stroke = None
    if a.get("stroke") is not None and b.get("stroke") is not None:
        stroke = crossover_state(a["stroke"], b["stroke"], rng)
    return {"decider": crossover_state(a["decider"], b["decider"], rng), "stroke": stroke}


# MARK: - Core ML

def compile_model(package: Path, folder: Path, name: str) -> Path:
    try:
        result = subprocess.run(["xcrun", "coremlcompiler", "compile", str(package), str(folder)],
                                capture_output=True, text=True)
    except FileNotFoundError:
        raise SystemExit("xcrun was not found; install the Xcode command-line tools") from None
    if result.returncode != 0:
        raise SystemExit(f"coremlcompiler failed for {package}:\n{result.stdout}\n{result.stderr}")
    compiled = folder / f"{name}.mlmodelc"
    if not compiled.is_dir():
        raise SystemExit(f"coremlcompiler produced no {compiled}")
    return compiled


def export_state(state: dict, kind: str, folder: Path) -> None:
    """Write one half of the player as a Core ML package, compile it, and remove the package."""
    folder.mkdir(parents=True, exist_ok=True)
    features = int(state["layers.0.weight"].shape[1])
    hidden = int(state["layers.0.weight"].shape[0])
    name = "Decider" if kind == "decider" else "Model"
    weights = folder / f"{name}.mlpackage.pt"
    save_state(state, weights)
    package = folder / f"{name}.mlpackage"
    if package.exists():
        shutil.rmtree(package)
    if kind == "decider":
        model = DeciderNet(features, hidden)
        model.load_state_dict(state)
        model.eval()
        convert_decider(model, features, str(package))
    else:
        model = CandidateNet(features, hidden)
        model.load_state_dict(state)
        model.eval()
        convert_stroke(model, features, str(package))
    compile_model(package, folder, name)
    shutil.rmtree(package, ignore_errors=True)


def export_genome(genome: dict, folder: Path) -> None:
    export_state(genome["decider"], "decider", folder)
    if genome.get("stroke") is not None:
        export_state(genome["stroke"], "stroke", folder)


def copy_genome_files(source: Path, destination: Path, with_stroke: bool) -> None:
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copy2(source / "Decider.mlpackage.pt", destination / "Decider.mlpackage.pt")
    shutil.copytree(source / "Decider.mlmodelc", destination / "Decider.mlmodelc")
    if with_stroke and (source / "Model.mlmodelc").is_dir():
        shutil.copy2(source / "Model.mlpackage.pt", destination / "Model.mlpackage.pt")
        shutil.copytree(source / "Model.mlmodelc", destination / "Model.mlmodelc")


# MARK: - Population records

def individual_folder(root: Path, generation: int, index: int) -> Path:
    return root / "generations" / f"gen-{generation:03d}" / f"individual-{index:03d}"


def result_folder(root: Path, generation: int) -> Path:
    return root / "results" / f"gen-{generation:03d}"


def read_generation(root: Path, generation: int) -> dict:
    return read_json(root / "generations" / f"gen-{generation:03d}" / "generation.json", {}) or {}


def record_for(folder: Path, index: int, identifier: str, origin: str, parent: str,
               with_stroke: bool) -> dict:
    record = {
        "index": index,
        "id": identifier,
        "origin": origin,
        "parent": parent,
        "deciderWeights": str(folder / "Decider.mlpackage.pt"),
        "deciderModel": str(folder / "Decider.mlmodelc"),
        "strokeWeights": "",
        "strokeModel": "",
    }
    if with_stroke:
        record["strokeWeights"] = str(folder / "Model.mlpackage.pt")
        record["strokeModel"] = str(folder / "Model.mlmodelc")
    return record


def genome_from_record(record: dict) -> dict:
    decider = Path(record.get("deciderWeights") or record.get("weights", ""))
    stroke = Path(record["strokeWeights"]) if record.get("strokeWeights") else None
    return load_genome(decider, stroke)


def print_population(generation: int, individuals: list[dict]) -> None:
    print(f"generation {generation:03d}: {len(individuals)} individuals")
    for individual in individuals:
        print(f"  {individual['index']:3d}  {individual.get('origin', 'base'):<34}"
              f" parent {individual.get('parent', '-'):<30} {individual['deciderWeights']}")


# MARK: - init

def initial_population(base: dict, base_label: str, seeds: list[tuple[str, dict]], population: int,
                       sigma: float, rng: np.random.Generator) -> tuple[list[dict], list[str]]:
    """The base first, then distinct saved genomes, then mutations of that gene pool."""
    pool: list[tuple[str, dict]] = [(base_label, base)]
    seen = {fingerprint_genome(base)}
    for label, genome in seeds:
        if not same_genome_architecture(base, genome):
            print(f"  skipping {label}: its shape is {shapes(genome)}; the base is {shapes(base)}")
            continue
        mark = fingerprint_genome(genome)
        if mark in seen:
            print(f"  skipping {label}: it is the same weights as one already in the pool")
            continue
        seen.add(mark)
        pool.append((label, genome))

    individuals: list[dict] = []
    for index in range(population):
        if index < len(pool):
            label, genome = pool[index]
            individuals.append({"index": index,
                                "origin": "base" if index == 0 else f"seed {label}",
                                "parent": label, "genome": genome})
        else:
            label, parent = pool[int(rng.integers(0, len(pool)))]
            genome = mutate_genome(parent, sigma * 2.5, rng)
            # The initial population should be more diverse than a generation-to-generation step: a
            # larger first mutation is what gives selection something to select.
            individuals.append({"index": index, "origin": f"mutation of {label}",
                                "parent": label, "genome": genome})
    return individuals, [label for label, _ in pool]


def resolve_base(arguments) -> tuple[Path, Path | None, str]:
    base = Path(arguments.base).expanduser().resolve()
    if base.is_dir():
        decider = base / "Decider.mlpackage.pt"
        stroke = Path(arguments.stroke).expanduser().resolve() if arguments.stroke else \
            (base / "Model.mlpackage.pt")
        label = arguments.base_label or base.name
    else:
        decider = base
        stroke = Path(arguments.stroke).expanduser().resolve() if arguments.stroke else None
        label = arguments.base_label or base.parent.name or "base"
    if not decider.is_file():
        raise SystemExit(f"no decision weights at {decider}")
    if stroke and not stroke.is_file():
        print(f"ignoring the missing stroke weights at {stroke}")
        stroke = None
    return decider, stroke, label


def read_seed(path: str) -> tuple[str, dict] | None:
    candidate = Path(path).expanduser().resolve()
    if candidate.is_dir():
        decider = candidate / "Decider.mlpackage.pt"
        stroke = candidate / "Model.mlpackage.pt"
        label = candidate.name
    else:
        decider = candidate
        stroke = None
        label = candidate.parent.name or candidate.name
    if not decider.is_file():
        print(f"  skipping {candidate}: no Decider.mlpackage.pt")
        return None
    return label, load_genome(decider, stroke if stroke and stroke.is_file() else None)


def command_init(arguments) -> int:
    root = Path(arguments.dir).expanduser().resolve()
    decider_path, stroke_path, base_label = resolve_base(arguments)
    if root.exists() and any(root.iterdir()):
        if not arguments.fresh:
            raise SystemExit(f"{root} already has a run; pass --fresh to keep the old one aside")
        aside = root.with_name(f"{root.name}-{time.strftime('%Y%m%d-%H%M%S')}")
        root.rename(aside)
        print(f"the old run was moved to {aside}")
    root.mkdir(parents=True, exist_ok=True)

    rng = np.random.default_rng(arguments.seed)
    base = load_genome(decider_path, stroke_path)
    seeds = [seed for path in arguments.seed_version or [] if (seed := read_seed(path))]
    population = max(2, int(arguments.population))
    individuals, pool = initial_population(base, base_label, seeds, population,
                                           arguments.mutation, rng)

    save_state(base["decider"], root / "base-decider.pt")
    if base.get("stroke") is not None:
        save_state(base["stroke"], root / "base-stroke.pt")
    print(f"base: {decider_path}")
    print(f"shape: {shapes(base)}")
    print(f"gene pool: {len(pool)} distinct genome(s)")
    for individual in individuals:
        folder = individual_folder(root, 0, int(individual["index"]))
        export_genome(individual["genome"], folder)
    manifest = {
        "created": time.strftime("%Y-%m-%d %H:%M"),
        "base": str(decider_path),
        "baseStroke": str(stroke_path) if stroke_path else "",
        "baseLabel": base_label,
        "hasStroke": base.get("stroke") is not None,
        "mode": arguments.mode,
        "seed": arguments.seed,
        "mutation": arguments.mutation,
        "elite": arguments.elite,
        "crossover": arguments.crossover,
        "population": population,
        "generations": arguments.generations,
        "deciderInputs": int(base["decider"]["layers.0.weight"].shape[1]),
        "deciderHidden": int(base["decider"]["layers.0.weight"].shape[0]),
        "pool": pool,
    }
    write_json(root / "population.json", manifest)
    records = [record_for(individual_folder(root, 0, int(individual["index"])),
                          int(individual["index"]),
                          f"gen-000/individual-{int(individual['index']):03d}",
                          individual["origin"], individual["parent"],
                          base.get("stroke") is not None)
               for individual in individuals]
    write_json(root / "generations" / "gen-000" / "generation.json",
               {"index": 0, "individuals": records})
    print_population(0, records)
    return 0


# MARK: - Measurements

def load_results(root: Path, generation: int, population: int) -> dict[int, list[dict]]:
    folder = result_folder(root, generation)
    found: dict[int, list[dict]] = {index: [] for index in range(population)}
    if not folder.is_dir():
        raise SystemExit(f"no measurement folder {folder}")
    for path in sorted(folder.glob("*.json")):
        try:
            index = int(path.stem.split("-")[1])
        except (IndexError, ValueError):
            continue
        if index not in found:
            continue
        report = read_json(path)
        if report is None:
            raise SystemExit(f"{path} is not valid JSON")
        found[index].append(report)
    missing = [index for index, reports in found.items() if not reports]
    if missing:
        raise SystemExit(f"generation {generation:03d} has no measurements for individuals {missing}")
    return found


def win_metrics(reports: list[dict]) -> dict:
    wins = losses = unfinished = frames = 0
    points_for = points_against = 0
    breaks = [0, 0]
    for report in reports:
        summary = report.get("summary", {})
        frame_wins = summary.get("wins", [0, 0])
        wins += int(frame_wins[0])
        losses += int(frame_wins[1])
        points_for += int(summary.get("points", [0, 0])[0])
        points_against += int(summary.get("points", [0, 0])[1])
        unfinished += int(summary.get("unfinished", 0))
        frames += int(summary.get("frames", len(report.get("frames", []))))
        for side in (0, 1):
            breaks[side] = max(breaks[side], int(summary.get("breaks", [0, 0])[side]))
    fitness = (wins - losses, wins, -unfinished, points_for - points_against)
    return {"fitness": fitness, "wins": wins, "losses": losses, "frames": frames,
            "points": [points_for, points_against], "breaks": breaks, "unfinished": unfinished}


def break_metrics(reports: list[dict]) -> dict:
    all_breaks: list[int] = []
    points_for = points_against = unfinished = frames = 0
    for report in reports:
        summary = report.get("summary", {})
        frame_breaks = [int(value) for frame in report.get("frames", [])
                        for value in frame.get("breaks", [])]
        all_breaks += frame_breaks or [int(value) for value in summary.get("breaks", [])]
        points_for += int(summary.get("points", [0, 0])[0])
        points_against += int(summary.get("points", [0, 0])[1])
        unfinished += int(summary.get("unfinished", 0))
        frames += int(summary.get("frames", len(report.get("frames", []))))
    all_breaks.sort(reverse=True)
    best = all_breaks[0] if all_breaks else 0
    second = all_breaks[1] if len(all_breaks) > 1 else 0
    # A frame that never finished is not better break-building just because both players traded foul
    # points for the decision budget. Finishing comes before the point tie-break.
    fitness = (best, second, -unfinished, points_for + points_against)
    return {"fitness": fitness, "bestBreak": best, "secondBreak": second,
            "points": [points_for, points_against], "breaks": all_breaks[:5],
            "unfinished": unfinished, "frames": frames}


def rankings(root: Path, generation: int, manifest: dict) -> list[dict]:
    population = int(manifest["population"])
    mode = manifest.get("mode", "win")
    results = load_results(root, generation, population)
    generation_file = read_generation(root, generation)
    ranked = []
    for record in generation_file.get("individuals", []):
        index = int(record["index"])
        record.setdefault("id", f"gen-{generation:03d}/individual-{index:03d}")
        metrics = (win_metrics if mode == "win" else break_metrics)(results[index])
        ranked.append({**record, **metrics})
    ranked.sort(key=lambda row: (row["fitness"], row["index"]), reverse=True)
    return ranked


def describe(ranked: list[dict], mode: str) -> None:
    print(f"  {'rank':>4}  {'individual':<28} {'fitness':<30} details")
    for rank, row in enumerate(ranked, start=1):
        if mode == "win":
            detail = (f"W {row['wins']}  L {row['losses']}  points "
                      f"{row['points'][0]}–{row['points'][1]}  unfinished {row['unfinished']}")
        else:
            detail = (f"best {row['bestBreak']}  second {row['secondBreak']}  points "
                      f"{row['points'][0] + row['points'][1]}  unfinished {row['unfinished']}")
        print(f"  {rank:4d}  {row['id']:<28} {str(row['fitness']):<30} {detail}")


def is_better(candidate: dict, current: dict) -> bool:
    if not current:
        return True
    return tuple(candidate.get("fitness", [])) > tuple(current.get("fitness", []))


def champion_metrics(root: Path) -> dict:
    return read_json(root / "champion.json", {}) or {}


def promote(root: Path, session: Path) -> None:
    decider = root / "champion-decider.mlmodelc"
    decider_weights = root / "champion-decider.pt"
    if not decider.is_dir() or not decider_weights.is_file():
        raise SystemExit("there is no champion to promote")
    session.mkdir(parents=True, exist_ok=True)
    destination = session / "Decider.mlmodelc"
    shutil.rmtree(destination, ignore_errors=True)
    shutil.copytree(decider, destination)
    shutil.copy2(decider_weights, session / "Decider.mlpackage.pt")
    stroke = root / "champion-stroke.mlmodelc"
    if stroke.is_dir() and (root / "champion-stroke.pt").is_file():
        destination = session / "Model.mlmodelc"
        shutil.rmtree(destination, ignore_errors=True)
        shutil.copytree(stroke, destination)
        shutil.copy2(root / "champion-stroke.pt", session / "Model.mlpackage.pt")
    print(f"the best model so far is in {session / 'Decider.mlmodelc'}")


# MARK: - breed

def tournament(ranked: list[dict], rng: np.random.Generator, size: int = 3) -> dict:
    picks = rng.choice(len(ranked), size=min(size, len(ranked)), replace=False)
    # `ranked` is best first, so the smallest sampled index is the tournament's winner.
    return ranked[min(int(index) for index in picks)]


def command_breed(arguments) -> int:
    root = Path(arguments.dir).expanduser().resolve()
    manifest = read_json(root / "population.json", {}) or {}
    if not manifest:
        raise SystemExit(f"no population at {root}; run init first")
    generation = int(arguments.generation)
    mode = manifest.get("mode", "win")
    population = int(manifest["population"])
    with_stroke = bool(manifest.get("hasStroke"))
    ranked = rankings(root, generation, manifest)
    print(f"\n=== generation {generation:03d}: {mode}-selected ranking ===")
    describe(ranked, mode)
    history = read_json(root / "history.json", []) or []
    history = [entry for entry in history if entry.get("generation") != generation]
    history.append({"generation": generation, "mode": mode, "ranking": ranked})
    write_json(root / "history.json", history)

    best = ranked[0]
    best_genome = genome_from_record(best)
    current = champion_metrics(root)
    best_fingerprint = fingerprint_genome(best_genome)
    current_fingerprint = current.get("fingerprint", "")
    if not current_fingerprint and (root / "champion-decider.pt").is_file():
        current_genome = load_genome(root / "champion-decider.pt",
                                     root / "champion-stroke.pt" if with_stroke else None)
        current_fingerprint = fingerprint_genome(current_genome)
    # Re-measuring the champion copy is a new sample, not a new model. It may look better or worse by
    # chance; neither is an improvement.
    improved = best_fingerprint != current_fingerprint and is_better(best, current)
    if improved:
        source = individual_folder(root, generation, int(best["index"]))
        shutil.copy2(source / "Decider.mlpackage.pt", root / "champion-decider.pt")
        shutil.rmtree(root / "champion-decider.mlmodelc", ignore_errors=True)
        shutil.copytree(source / "Decider.mlmodelc", root / "champion-decider.mlmodelc")
        if with_stroke:
            shutil.copy2(source / "Model.mlpackage.pt", root / "champion-stroke.pt")
            shutil.rmtree(root / "champion-stroke.mlmodelc", ignore_errors=True)
            shutil.copytree(source / "Model.mlmodelc", root / "champion-stroke.mlmodelc")
        write_json(root / "champion.json", {
            "id": best["id"],
            "generation": generation,
            "index": best["index"],
            "fitness": best["fitness"],
            "fingerprint": best_fingerprint,
            "metrics": {key: value for key, value in best.items()
                        if key not in ("fitness", "deciderWeights", "deciderModel",
                                       "strokeWeights", "strokeModel")},
            "mode": mode,
            "base": manifest.get("baseLabel", ""),
            "hasStroke": with_stroke,
            "at": time.strftime("%Y-%m-%d %H:%M"),
        })
        print(f"new champion: {best['id']}  fitness {best['fitness']}")
    else:
        print(f"champion stays {current.get('id')}  fitness {current.get('fitness')}")
    promote(root, root.parent)

    if arguments.last:
        return 0

    rng = np.random.default_rng(int(manifest["seed"]) + 1009 * (generation + 1))
    elite = max(1, min(int(manifest.get("elite", 2)), population))
    mutation = float(manifest.get("mutation", 0.06))
    crossover_rate = float(manifest.get("crossover", 0.35))
    next_generation = generation + 1
    records: list[dict] = []

    # The best ever seen stays in the population, even when this generation did not beat it.
    champion_id = best["id"] if improved else current.get("id", best["id"])
    champion_genome = load_genome(root / "champion-decider.pt",
                                  root / "champion-stroke.pt" if with_stroke else None)
    records.append({"index": 0, "id": champion_id, "origin": "champion",
                    "parent": champion_id, "genome": champion_genome, "from_champion": True})
    used = {fingerprint_genome(champion_genome)}
    for row in ranked:
        if len(records) >= elite:
            break
        genome = genome_from_record(row)
        mark = fingerprint_genome(genome)
        if mark in used:
            continue
        used.add(mark)
        source = individual_folder(root, generation, int(row["index"]))
        records.append({"index": len(records), "id": row["id"], "origin": "elite",
                        "parent": row["id"], "genome": genome, "from_folder": source})

    while len(records) < population:
        index = len(records)
        if rng.random() < crossover_rate and len(ranked) >= 2:
            first = tournament(ranked, rng)
            second = tournament(ranked, rng)
            if second["id"] == first["id"]:
                others = [row for row in ranked if row["id"] != first["id"]]
                if others:
                    second = others[int(rng.integers(0, len(others)))]
            state = crossover_genome(genome_from_record(first), genome_from_record(second), rng)
            origin = f"crossover {first['id']} × {second['id']}"
            parent = f"{first['id']} + {second['id']}"
        else:
            parent_row = tournament(ranked, rng)
            state = mutate_genome(genome_from_record(parent_row), mutation, rng)
            origin = f"mutation of {parent_row['id']}"
            parent = parent_row["id"]
        records.append({"index": index,
                        "id": f"gen-{next_generation:03d}/individual-{index:03d}",
                        "origin": origin, "parent": parent, "genome": state})

    print(f"\nbreeding generation {next_generation:03d}: {elite} elite, "
          f"{population - elite} offspring (mutation {mutation}, crossover {crossover_rate})")
    output = []
    for record in records:
        index = int(record["index"])
        folder = individual_folder(root, next_generation, index)
        if folder.exists():
            shutil.rmtree(folder)
        if record.get("from_champion"):
            folder.mkdir(parents=True, exist_ok=True)
            # The champion's files are named differently from an individual's.
            shutil.copy2(root / "champion-decider.pt", folder / "Decider.mlpackage.pt")
            shutil.rmtree(folder / "Decider.mlmodelc", ignore_errors=True)
            shutil.copytree(root / "champion-decider.mlmodelc", folder / "Decider.mlmodelc")
            if with_stroke:
                shutil.copy2(root / "champion-stroke.pt", folder / "Model.mlpackage.pt")
                shutil.rmtree(folder / "Model.mlmodelc", ignore_errors=True)
                shutil.copytree(root / "champion-stroke.mlmodelc", folder / "Model.mlmodelc")
        elif record.get("from_folder"):
            copy_genome_files(Path(record["from_folder"]), folder, with_stroke)
        else:
            export_genome(record["genome"], folder)
        output.append(record_for(folder, index,
                                 f"gen-{next_generation:03d}/individual-{index:03d}",
                                 record["origin"], record["parent"], with_stroke))
    write_json(root / "generations" / f"gen-{next_generation:03d}" / "generation.json",
               {"index": next_generation, "individuals": output})
    print_population(next_generation, output)
    return 0


# MARK: - finish

def command_finish(arguments) -> int:
    root = Path(arguments.dir).expanduser().resolve()
    session = Path(arguments.session).expanduser().resolve() if arguments.session else root.parent
    promote(root, session)
    champion = champion_metrics(root)
    history = read_json(root / "history.json", []) or []
    lines = [f"champion: {champion.get('id', '?')}  ({champion.get('mode', '?')}-selected)",
             f"fitness: {champion.get('fitness', '?')}",
             "", "generation  champion                         fitness"]
    for entry in history:
        ranking = entry.get("ranking", [])
        if not ranking:
            continue
        top = ranking[0]
        lines.append(f"{entry['generation']:10d}  {top['id']:<32} {top['fitness']}")
    (root / "summary.txt").write_text("\n".join(lines) + "\n")
    print("\n".join(lines))
    print(f"champion copied to {session / 'Decider.mlmodelc'}")
    if (session / "Model.mlmodelc").is_dir():
        print(f"the champion's stroke is {session / 'Model.mlmodelc'}")
    print(f"the run's measurements and every generation are in {root}")
    return 0


def self_test(arguments) -> int:
    """A shape-only check of mutation and crossover: no engine, no Core ML."""
    rng = np.random.default_rng(1)
    decider = {"layers.0.weight": torch.randn(8, 4, 1), "layers.0.bias": torch.zeros(8),
               "actions.weight": torch.randn(12, 8, 1), "actions.bias": torch.zeros(12)}
    stroke = {"layers.0.weight": torch.randn(8, 4, 1), "layers.0.bias": torch.zeros(8),
              "head.weight": torch.randn(7, 4, 1), "head.bias": torch.zeros(7)}
    genome = {"decider": decider, "stroke": stroke}
    child = mutate_genome(genome, 0.1, rng)
    other = mutate_genome(genome, 0.2, rng)
    crossed = crossover_genome(child, other, rng)
    for key in decider:
        assert child["decider"][key].shape == decider[key].shape
        assert crossed["decider"][key].shape == decider[key].shape
        assert torch.isfinite(child["decider"][key]).all()
    for key in stroke:
        assert child["stroke"][key].shape == stroke[key].shape
        assert crossed["stroke"][key].shape == stroke[key].shape
    assert not torch.equal(child["decider"]["layers.0.weight"],
                           decider["layers.0.weight"])
    assert not torch.equal(child["stroke"]["layers.0.weight"], stroke["layers.0.weight"])
    print("self-test ok: both halves mutate and cross while keeping their shapes")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    init = sub.add_parser("init", help="create and compile generation 0")
    init.add_argument("--dir", required=True)
    init.add_argument("--base", required=True,
                      help="a version directory, or a Decider.mlpackage.pt")
    init.add_argument("--stroke",
                      help="the stroke weights when --base is a Decider .pt; a version directory finds them")
    init.add_argument("--base-label", default="")
    init.add_argument("--seed-version", action="append", default=[],
                      help="a version directory (or a Decider .pt) to add to the gene pool")
    init.add_argument("--population", type=int, default=12)
    init.add_argument("--generations", type=int, default=8)
    init.add_argument("--mutation", type=float, default=0.06)
    init.add_argument("--elite", type=int, default=2)
    init.add_argument("--crossover", type=float, default=0.35)
    init.add_argument("--seed", type=int, default=1)
    init.add_argument("--mode", choices=("win", "break"), required=True)
    init.add_argument("--fresh", action="store_true")
    init.set_defaults(function=command_init)

    breed = sub.add_parser("breed", help="rank a generation and breed the next")
    breed.add_argument("--dir", required=True)
    breed.add_argument("--generation", type=int, required=True)
    breed.add_argument("--last", action="store_true",
                       help="rank and promote only; do not create another generation")
    breed.set_defaults(function=command_breed)

    finish = sub.add_parser("finish", help="copy the best ever seen into the session")
    finish.add_argument("--dir", required=True)
    finish.add_argument("--session", default="")
    finish.set_defaults(function=command_finish)

    test = sub.add_parser("self-test", help="check mutation and crossover shapes")
    test.set_defaults(function=self_test)

    arguments = parser.parse_args()
    return arguments.function(arguments)


if __name__ == "__main__":
    raise SystemExit(main())
