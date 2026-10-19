#!/usr/bin/env python3
"""A small, local training studio for the snooker neural networks.

Run it with the system Python (it uses only the standard library):

    python3 AI/training_studio.py

It opens a page in your browser. From there you choose what to train, how much data the Hard/Exact teacher
should generate, the model's size, and the session folder; press Run and watch the log. A "Full run" does
the export, the training, the Core ML conversion and a test frame in order.

The training itself needs `torch` and `coremltools`. Point the *Python for training* field at the interpreter
that has them; the "Check" button says whether it does. The engine (the Snooker binary) is only used to
generate data and to play the test frame.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time
import webbrowser
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parent.parent
PORT = 8765
TRAINING_TASKS = {"train_shot", "train_candidate", "train_decider",
                  "full_shot", "full_candidate", "full_decider", "full_exact"}
PACKAGE_CACHE: dict[str, bool] = {}


@dataclass
class Job:
    """One run of the studio: the commands being executed and what they said."""
    running: bool = False
    finished: bool = False
    cancelled: bool = False
    returncode: int | None = None
    lines: list[str] = field(default_factory=list)
    started: float = 0.0
    stage: str = ""
    session: Path | None = None
    process: subprocess.Popen | None = None
    command: list[str] = field(default_factory=list)


JOB = Job()
LOCK = threading.Lock()


def say(text: str) -> None:
    with LOCK:
        JOB.lines.append(text)
        del JOB.lines[:-4000]


def safe_name(name: str) -> str:
    cleaned = re.sub(r"[^A-Za-z0-9._ -]+", "", name).strip().replace(" ", "-")
    return cleaned or "session"


def engine_path(config: dict) -> Path:
    given = (config.get("engine") or "").strip()
    if given:
        return Path(given).expanduser()
    return ROOT / "build" / "Snooker.app" / "Contents" / "MacOS" / "Snooker"


def python_path(config: dict) -> str:
    given = (config.get("python") or "").strip()
    return given or sys.executable


def find_training_python() -> str:
    """The first Python that looks like a training environment.

    Looking is cheap and does not import torch: the studio's own start must not wait for it. The
    *Check environment* and *Run* buttons do the real import and tell the truth.
    """
    override = os.environ.get("SNOOKER_PYTHON", "").strip()
    candidates = [override,
                  str(ROOT / "AI" / ".venv" / "bin" / "python"),
                  "/private/tmp/snooker-ai/venv/bin/python",
                  shutil.which("python3") or "",
                  sys.executable]
    for candidate in candidates:
        if candidate and Path(candidate).exists():
            return candidate
    return sys.executable


def has_training_packages(python: str) -> bool:
    if python in PACKAGE_CACHE:
        return PACKAGE_CACHE[python]
    if not Path(python).exists():
        PACKAGE_CACHE[python] = False
        return False
    try:
        result = subprocess.run([python, "-c", "import torch, coremltools"], capture_output=True,
                                timeout=120)
        ok = result.returncode == 0
    except Exception:  # noqa: BLE001
        ok = False
    PACKAGE_CACHE[python] = ok
    return ok


def session_dir(config: dict) -> Path:
    base = Path((config.get("sessions") or "").strip() or ROOT / "AI" / "Sessions").expanduser()
    return base / safe_name(config.get("session") or "session")


def teacher_flags(config: dict) -> list[str]:
    teacher = config.get("teacher", "hard")
    flags = {"hard": "--hard", "exact": "--exact", "medium": "--medium", "easy": "--easy"}.get(
        teacher, "--hard")
    result = [flags, "--frames", str(int(config.get("frames", 12))),
              "--reds", str(int(config.get("reds", 10))),
              "--seed", str(int(config.get("seed", 1)))]
    if config.get("aimSweep"):
        result.append("--aim-sweep")
    if config.get("lineTuning"):
        result.append("--line-tuning")
    return result


def training_flags(config: dict) -> list[str]:
    return ["--epochs", str(int(config.get("epochs", 200))),
            "--hidden", str(int(config.get("hidden", 256))),
            "--batch", str(int(config.get("batch", 64))),
            "--lr", str(float(config.get("lr", 0.001))),
            "--weight-decay", str(float(config.get("weightDecay", 0.0001))),
            "--seed", str(int(config.get("seed", 1)))]


def stages_for(task: str, config: dict) -> list[tuple[str, list[str]]]:
    """The commands a task runs, in order. Each is (name, argv)."""
    engine = str(engine_path(config))
    python = python_path(config)
    folder = session_dir(config)
    dataset = folder / "training.bin"
    model = folder / "Model.mlpackage"
    compiled = folder / "Model.mlmodelc"
    teacher = teacher_flags(config)
    training = training_flags(config)

    export_candidates = [engine, "--ai-export-candidates", str(dataset)] + teacher
    export_shots = [engine, "--ai-export-policy", str(dataset)] + teacher
    export_all = [engine, "--ai-export-all", str(dataset)] + teacher
    train_candidate = [python, str(ROOT / "AI" / "train_candidate_net.py"), str(dataset),
                       str(model)] + training
    train_shot = [python, str(ROOT / "AI" / "train_policy_net.py"), str(dataset),
                  str(model)] + training
    train_decider = [python, str(ROOT / "AI" / "train_decider_net.py"), str(dataset),
                     str(model)] + training
    compile_model = ["xcrun", "coremlcompiler", "compile", str(model), str(folder)]
    play = [engine, "--ai-play", "1"]
    if config.get("teacher") == "exact":
        play.append("--exact")
    else:
        play.append("--hard")
    if task in ("full_candidate", "train_candidate", "play_candidate"):
        play += ["--candidate-policy", str(compiled)]
    if task == "full_exact":
        # Both are compiled earlier in this same run, so the paths are the ones the test frame will use.
        play += ["--decider", str(folder / "Decider.mlmodelc"),
                 "--candidate-policy", str(compiled)]

    if task == "export_shot":
        return [("Exporting shots", export_shots)]
    if task == "export_candidate":
        return [("Exporting candidate rows", export_candidates)]
    if task == "export_all":
        return [("Exporting every decision", export_all)]
    if task == "train_shot":
        return [("Training the shot policy", train_shot)]
    if task == "train_candidate":
        return [("Training the candidate policy", train_candidate)]
    if task == "train_decider":
        return [("Training the all-decisions policy", train_decider)]
    if task == "play_candidate":
        return [("A test frame", play)]
    if task == "full_shot":
        return [("Exporting shots", export_shots), ("Training the shot policy", train_shot),
                ("Compiling the model", compile_model), ("A test frame", play)]
    if task == "full_candidate":
        return [("Exporting candidate rows", export_candidates),
                ("Training the candidate policy", train_candidate),
                ("Compiling the model", compile_model), ("A test frame", play)]
    if task == "full_decider":
        return [("Exporting every decision", export_all),
                ("Training the all-decisions policy", train_decider),
                ("Compiling the model", compile_model), ("A test frame", play)]
    if task == "full_exact":
        # The exact network the ESC menu uses: the all-decisions heads and the candidate stroke, trained
        # on the clean Exact teacher.
        decider_dataset = folder / "decisions.bin"
        decider_model = folder / "Decider.mlpackage"
        decider_train = [python, str(ROOT / "AI" / "train_decider_net.py"),
                         str(decider_dataset), str(decider_model)] + training
        decider_compile = ["xcrun", "coremlcompiler", "compile", str(decider_model), str(folder)]
        clean_teacher = ["--exact", "--frames", str(int(config.get("frames", 12))),
                         "--reds", str(int(config.get("reds", 10))),
                         "--seed", str(int(config.get("seed", 1)))]
        if config.get("aimSweep"):
            clean_teacher.append("--aim-sweep")
        return [("Exporting the decisions", [engine, "--ai-export-all",
                                             str(decider_dataset)] + clean_teacher),
                ("Exporting the candidate rows",
                 [engine, "--ai-export-candidates", str(dataset)] + clean_teacher),
                ("Training the all-decisions hands", decider_train),
                ("Training the stroke", train_candidate),
                ("Compiling the stroke model", compile_model),
                ("Compiling the decisions model", decider_compile),
                ("A test frame", play)]
    if task == "setup_python":
        venv = ROOT / "AI" / ".venv"
        return [("Creating the training environment",
                 [sys.executable, "-m", "venv", str(venv)]),
                ("Installing torch and coremltools",
                 [str(venv / "bin" / "pip"), "install", "--upgrade", "torch", "coremltools"])]
    raise SystemExit(f"unknown task {task}")


def run_stages(stages: list[tuple[str, list[str]]]) -> None:
    try:
        for name, command in stages:
            if JOB.cancelled:
                return
            with LOCK:
                JOB.stage = name
                JOB.command = command
            say(f"\n=== {name} ===")
            say("$ " + " ".join(command))
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                       text=True, bufsize=1, cwd=str(ROOT))
            with LOCK:
                JOB.process = process
            assert process.stdout is not None
            for line in process.stdout:
                say(line.rstrip("\n"))
                if JOB.cancelled:
                    process.terminate()
                    break
            code = process.wait()
            with LOCK:
                JOB.process = None
            if code != 0:
                say(f"\n*** {name} stopped with exit {code} ***")
                with LOCK:
                    JOB.returncode = code
                return
        with LOCK:
            JOB.returncode = 0
        say("\n*** Done ***")
    except Exception as error:  # noqa: BLE001 - the studio has to survive anything it started
        say(f"\n*** {error} ***")
        with LOCK:
            JOB.returncode = 1
    finally:
        with LOCK:
            JOB.running = False
            JOB.finished = True
            JOB.process = None


class Handler(BaseHTTPRequestHandler):
    server_version = "SnookerTrainingStudio/1"

    def log_message(self, *args) -> None:  # quiet: the page is the log
        pass

    def reply(self, code: int, body: bytes, kind: str = "application/json") -> None:
        self.send_response(code)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/":
            self.reply(200, PAGE.encode(), "text/html; charset=utf-8")
            return
        if parsed.path == "/api/status":
            since = int(parse_qs(parsed.query).get("since", ["0"])[0])
            with LOCK:
                body = json.dumps({
                    "running": JOB.running,
                    "finished": JOB.finished,
                    "returncode": JOB.returncode,
                    "stage": JOB.stage,
                    "started": JOB.started,
                    "lines": JOB.lines[since:],
                    "next": min(len(JOB.lines), since + 4000),
                    "session": str(JOB.session) if JOB.session else "",
                    "artifacts": sorted(p.name for p in JOB.session.iterdir())
                    if JOB.session and JOB.session.is_dir() else [],
                }).encode()
            self.reply(200, body)
            return
        if parsed.path == "/api/config":
            body = json.dumps({
                "root": str(ROOT),
                "engine": str(engine_path({})),
                "python": find_training_python(),
                "sessions": str(ROOT / "AI" / "Sessions"),
            }).encode()
            self.reply(200, body)
            return
        self.reply(404, b"{}")

    def do_POST(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        length = int(self.headers.get("Content-Length", "0"))
        try:
            payload = json.loads(self.rfile.read(length) or b"{}")
        except json.JSONDecodeError:
            self.reply(400, b'{"error":"bad json"}')
            return
        if parsed.path == "/api/check":
            python = python_path(payload)
            code = (
                "import sys;"
                "print('python', sys.version.split()[0]);"
                "import torch, coremltools;"
                "print('torch', torch.__version__, 'coremltools', coremltools.__version__);"
                "print('mps', torch.backends.mps.is_available())"
            )
            try:
                result = subprocess.run([python, "-c", code], capture_output=True, text=True,
                                        timeout=90)
                ok = result.returncode == 0
                self.reply(200, json.dumps({"ok": ok,
                                            "log": (result.stdout + result.stderr).strip()}).encode())
            except Exception as error:  # noqa: BLE001
                self.reply(200, json.dumps({"ok": False, "log": str(error)}).encode())
            return
        if parsed.path == "/api/stop":
            with LOCK:
                JOB.cancelled = True
                process = JOB.process
            if process:
                process.terminate()
            self.reply(200, b'{"stopped":true}')
            return
        if parsed.path == "/api/reveal":
            folder = session_dir(payload)
            folder.mkdir(parents=True, exist_ok=True)
            subprocess.Popen(["open", str(folder)])
            self.reply(200, b'{"opened":true}')
            return
        if parsed.path == "/api/run":
            task = payload.get("task", "full_candidate")
            if task in TRAINING_TASKS and not has_training_packages(python_path(payload)):
                self.reply(200, json.dumps({
                    "started": False,
                    "error": (f"{python_path(payload)} has no torch/coremltools. "
                              "Put a Python that has them in “Python for training” (Check environment), "
                              "or press “Set up Python” to create AI/.venv."),
                }).encode())
                return
            with LOCK:
                if JOB.running:
                    self.reply(409, b'{"error":"a run is already going"}')
                    return
                JOB.running = True
                JOB.finished = False
                JOB.cancelled = False
                JOB.returncode = None
                JOB.lines = []
                JOB.started = time.time()
                JOB.stage = "Starting"
                JOB.session = session_dir(payload)
            JOB.session.mkdir(parents=True, exist_ok=True)
            try:
                stages = stages_for(task, payload)
            except SystemExit as error:
                with LOCK:
                    JOB.running = False
                    JOB.finished = True
                    JOB.returncode = 2
                    JOB.lines = [str(error)]
                self.reply(200, b'{"started":false}')
                return
            threading.Thread(target=run_stages, args=(stages,), daemon=True).start()
            self.reply(200, b'{"started":true}')
            return
        self.reply(404, b"{}")


PAGE = r"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Snooker · Training Studio</title>
<style>
  :root { color-scheme: dark; --bg:#14171c; --panel:#1c2129; --line:#2c333e; --ink:#e9eef5;
          --muted:#93a0b4; --accent:#4fa3ff; --good:#5fd08a; --bad:#ff7b7b; --felt:#1d6a45; }
  * { box-sizing: border-box; }
  body { margin:0; background:var(--bg); color:var(--ink);
         font: 14px/1.45 -apple-system, BlinkMacSystemFont, "SF Pro Text", Helvetica, sans-serif; }
  header { padding:22px 28px 18px; border-bottom:1px solid var(--line);
           background: linear-gradient(180deg, #182630, var(--bg)); }
  h1 { margin:0; font-size:22px; letter-spacing:.2px; }
  h1 span { color:var(--good); }
  p.sub { margin:6px 0 0; color:var(--muted); }
  main { display:grid; grid-template-columns: 380px 1fr; gap:18px; padding:18px 28px 40px; }
  .panel { background:var(--panel); border:1px solid var(--line); border-radius:12px; padding:16px; }
  h2 { margin:0 0 12px; font-size:13px; text-transform:uppercase; letter-spacing:.12em; color:var(--muted); }
  label { display:block; font-size:12px; color:var(--muted); margin:10px 0 4px; }
  input, select { width:100%; padding:8px 10px; border-radius:8px; border:1px solid var(--line);
                  background:#12161b; color:var(--ink); font-size:13px; }
  .row { display:grid; grid-template-columns:1fr 1fr; gap:10px; }
  .presets { display:grid; grid-template-columns:1fr 1fr; gap:8px; margin-bottom:8px; }
  button { border:1px solid var(--line); background:#243040; color:var(--ink); border-radius:8px;
           padding:9px 12px; font-size:13px; cursor:pointer; }
  button:hover { border-color:#3d4b5e; }
  button.primary { background:var(--felt); border-color:#2c8a5b; font-weight:600; }
  button.stop { background:#5a2626; border-color:#8a3a3a; }
  button.small { padding:6px 9px; font-size:12px; }
  .actions { display:flex; gap:8px; margin-top:14px; flex-wrap:wrap; }
  .logwrap { display:flex; flex-direction:column; min-height:520px; }
  .status { display:flex; gap:14px; align-items:center; color:var(--muted); font-size:12px;
            margin-bottom:10px; flex-wrap:wrap; }
  .dot { width:9px; height:9px; border-radius:50%; background:var(--muted); display:inline-block; }
  .dot.run { background:var(--accent); animation:pulse 1.1s infinite; }
  .dot.ok { background:var(--good); }
  .dot.bad { background:var(--bad); }
  @keyframes pulse { 50% { opacity:.35; } }
  pre { flex:1; margin:0; padding:14px; background:#0e1116; border:1px solid var(--line);
        border-radius:10px; overflow:auto; height:560px; font:12px/1.5 "SF Mono", Menlo, monospace;
        color:#cfd8e3; white-space:pre-wrap; }
  .hint { color:var(--muted); font-size:12px; margin-top:8px; }
  .artifacts { margin-top:10px; color:var(--muted); font-size:12px; word-break:break-word; }
  .badge { display:inline-block; padding:1px 7px; border-radius:99px; border:1px solid var(--line);
           color:var(--muted); font-size:11px; margin-right:6px; }
  @media (max-width: 1000px) { main { grid-template-columns:1fr; } pre { height:380px; } }
</style>
</head>
<body>
<header>
  <h1>Snooker <span>Training Studio</span></h1>
  <p class="sub">Generate the teacher's data, train a network, convert it, and play a test frame — all on this Mac.</p>
</header>
<main>
  <section class="panel">
    <h2>Session</h2>
    <div class="presets">
      <button class="small" data-preset="shot">Shot policy</button>
      <button class="small" data-preset="candidate">Candidate + swerve</button>
      <button class="small" data-preset="decider">All decisions</button>
      <button class="small" data-preset="exact">Exact network</button>
    </div>
    <label for="task">What to run</label>
    <select id="task">
      <option value="full_candidate">Full: export → train candidate → compile → play</option>
      <option value="full_exact">Full: exact network (decisions + stroke)</option>
      <option value="full_shot">Full: shot policy</option>
      <option value="full_decider">Full: all decisions</option>
      <option value="export_candidate">Export candidate rows</option>
      <option value="export_shot">Export shots</option>
      <option value="export_all">Export every decision</option>
      <option value="train_candidate">Train candidate model</option>
      <option value="train_shot">Train shot model</option>
      <option value="train_decider">Train all-decisions model</option>
      <option value="play_candidate">Test frame with the candidate model</option>
      <option value="setup_python">Set up the training Python (venv + install)</option>
    </select>
    <label for="session">Session name</label>
    <input id="session" value="session-01">
    <label for="teacher">Teacher</label>
    <select id="teacher">
      <option value="hard">Hard (σ 0.03°)</option>
      <option value="exact">Exact (σ 0°)</option>
      <option value="medium">Medium (σ 0.1°)</option>
      <option value="easy">Easy (σ 0.2°)</option>
    </select>
    <div class="row">
      <div><label for="frames">Frames</label><input id="frames" type="number" min="1" value="12"></div>
      <div><label for="reds">Reds</label><input id="reds" type="number" min="1" max="15" value="10"></div>
    </div>
    <div class="row">
      <div><label for="epochs">Epochs</label><input id="epochs" type="number" min="1" value="200"></div>
      <div><label for="hidden">Hidden width</label><input id="hidden" type="number" min="16" value="256"></div>
    </div>
    <div class="row">
      <div><label for="batch">Batch</label><input id="batch" type="number" min="1" value="64"></div>
      <div><label for="lr">Learning rate</label><input id="lr" type="number" step="0.0001" value="0.001"></div>
    </div>
    <label for="seed">Seed</label><input id="seed" type="number" value="1">
    <label><input id="aimSweep" type="checkbox" checked style="width:auto"> Aim sweep (±3/7/15°) for swerve labels</label>
    <label><input id="lineTuning" type="checkbox" checked style="width:auto"> Line-aware tuning</label>
    <label for="python">Python for training (torch + coremltools)</label>
    <input id="python" placeholder="/path/to/venv/bin/python">
    <label for="engine">Snooker engine</label>
    <input id="engine">
    <div class="actions">
      <button class="small" id="check">Check environment</button>
      <button class="small" id="setup">Set up Python</button>
      <button class="small" id="reveal">Open session folder</button>
    </div>
    <div class="actions">
      <button class="primary" id="run">Run</button>
      <button class="stop" id="stop">Stop</button>
    </div>
    <p class="hint">A full candidate run on 12 frames is roughly 3–6 minutes of export and 2–8 minutes of
    training. The teacher can generate as much data as the clock allows.</p>
  </section>
  <section class="panel logwrap">
    <div class="status">
      <span><span id="dot" class="dot"></span> <span id="state">idle</span></span>
      <span id="stage"></span>
      <span id="clock"></span>
    </div>
    <pre id="log">The log will appear here.</pre>
    <div class="artifacts" id="artifacts"></div>
  </section>
</main>
<script>
const $ = (id) => document.getElementById(id);
let since = 0, timer = null, startedAt = 0;
const fields = ["task","session","teacher","frames","reds","epochs","hidden","batch","lr","seed",
                "aimSweep","lineTuning","python","engine"];
function config() {
  const c = {};
  for (const f of fields) c[f] = $(f).type === "checkbox" ? $(f).checked : $(f).value;
  c.frames = +c.frames; c.reds = +c.reds; c.epochs = +c.epochs; c.hidden = +c.hidden;
  c.batch = +c.batch; c.lr = +c.lr; c.seed = +c.seed;
  return c;
}
let root = "";
async function defaults() {
  const d = await (await fetch("/api/config")).json();
  root = d.root; $("python").value = d.python; $("engine").value = d.engine;
}
const presets = {
  shot:      { task:"full_shot", teacher:"hard", session:"shot-01", frames:12 },
  candidate: { task:"full_candidate", teacher:"hard", session:"candidate-01", frames:12, aimSweep:true },
  decider:   { task:"full_decider", teacher:"hard", session:"decisions-01", frames:12 },
  exact:     { task:"full_exact", teacher:"exact", session:"exact-01", frames:14, aimSweep:true },
};
document.querySelectorAll("[data-preset]").forEach(b => b.onclick = () => {
  const p = presets[b.dataset.preset];
  for (const [k,v] of Object.entries(p)) {
    if ($(k).type === "checkbox") $(k).checked = v; else $(k).value = v;
  }
});
async function poll() {
  const r = await (await fetch("/api/status?since=" + since)).json();
  if (r.lines && r.lines.length) {
    $("log").textContent += (since ? "\n" : "") + r.lines.join("\n");
    $("log").scrollTop = $("log").scrollHeight;
    since = r.next;
  }
  $("state").textContent = r.running ? "running" : (r.finished ? (r.returncode === 0 ? "done" : "stopped") : "idle");
  $("dot").className = "dot " + (r.running ? "run" : (r.finished && r.returncode === 0 ? "ok" : (r.finished ? "bad" : "")));
  $("stage").textContent = r.stage || "";
  $("artifacts").textContent = r.artifacts && r.artifacts.length ? "Session files: " + r.artifacts.join("  ·  ") : "";
  if (r.started) { const s = Math.max(0, Date.now()/1000 - r.started); $("clock").textContent = s.toFixed(0) + " s"; }
  if (!r.running) { clearInterval(timer); timer = null; }
}
async function start(taskOverride) {
  if (taskOverride) $("task").value = taskOverride;
  $("log").textContent = ""; since = 0;
  const res = await fetch("/api/run", { method:"POST", headers:{"Content-Type":"application/json"},
                                        body: JSON.stringify(config()) });
  const body = await res.json().catch(() => ({}));
  if (!res.ok) { $("log").textContent = "A run is already going."; return; }
  if (body.started === false) {
    $("log").textContent = body.error || "The run did not start.";
    return;
  }
  if (!timer) timer = setInterval(poll, 700);
  poll();
}
$("run").onclick = () => start();
$("setup").onclick = () => {
  if (root) $("python").value = root + "/AI/.venv/bin/python";
  start("setup_python");
};
$("stop").onclick = () => fetch("/api/stop", { method:"POST", headers:{"Content-Type":"application/json"}, body:"{}" });
$("reveal").onclick = () => fetch("/api/reveal", { method:"POST", headers:{"Content-Type":"application/json"},
                                                   body: JSON.stringify(config()) });
$("check").onclick = async () => {
  $("log").textContent = "Checking the training environment…\n";
  const r = await (await fetch("/api/check", { method:"POST", headers:{"Content-Type":"application/json"},
                                               body: JSON.stringify(config()) })).json();
  $("log").textContent += r.log + "\n" + (r.ok ? "Ready to train." : "torch/coremltools were not found in that Python.");
};
defaults().then(() => { $("log").textContent = "Ready. Pick a preset, then Run."; });
</script>
</body>
</html>
"""


def main() -> None:
    httpd = None
    port = PORT
    for candidate in range(PORT, PORT + 20):
        try:
            httpd = ThreadingHTTPServer(("127.0.0.1", candidate), Handler)
            port = candidate
            break
        except OSError:
            continue
    if httpd is None:
        print(f"No port between {PORT} and {PORT + 19} was free.")
        return
    print(f"Training Studio: http://127.0.0.1:{port}/")
    threading.Timer(0.8, lambda: webbrowser.open(f"http://127.0.0.1:{port}/")).start()
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
