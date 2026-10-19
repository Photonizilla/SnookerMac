#!/usr/bin/env python3
"""Trains the **all-decisions** network: the pure learned player.

It reads `PolicySituation` — the position's features and the rules' masks for actions, colours, free balls
and placement cells — and answers with one action and every number the action needs: the twelve action
logits, the six stroke labels, the sixty-four placement logits and the six colour logits.

    Snooker --ai-export-all /tmp/all.bin --frames 12 --hard --reds 10
    python3 train_decider_net.py /tmp/all.bin /tmp/Decider1.mlpackage --epochs 200 --hidden 256

The supervised targets are the current Hard player's own decisions, recorded at its positions: shots,
where it placed the cue ball, which colour it nominated, whether it took a free ball, and what it asked for
after a foul. `--extra` adds a self-play round's dataset (the network's states, the Hard player's targets).
"""

import argparse
import struct
import time

import numpy as np
import torch
import torch.nn as nn

MAGIC = b"SNOOKERPA1"
ACTIONS, SHOT, PLACEMENTS, COLOURS, OUTCOMES = 12, 6, 64, 6, 4
LABELS = 1 + SHOT + 1 + 1
OUTPUTS = ACTIONS + SHOT + PLACEMENTS + COLOURS


def read_dataset(path):
    blob = open(path, "rb").read()
    if blob[:10] != MAGIC:
        raise SystemExit(f"{path} is not an all-decisions dataset (it starts with {blob[:10]!r})")
    count, stride = struct.unpack_from("<II", blob, 10)
    rows = np.frombuffer(blob, dtype="<f4", offset=18, count=count * stride).reshape(count, stride)
    split = stride - LABELS - OUTCOMES
    inputs = rows[:, :split].copy()
    rest = rows[:, split:]
    action = rest[:, 0].astype(np.int64)
    shot = rest[:, 1:7].copy()
    placement = rest[:, 7].astype(np.int64)
    colour = rest[:, 8].astype(np.int64)
    outcomes = rest[:, 9:].copy()
    return inputs, action, shot, placement, colour, outcomes


class DeciderNet(nn.Module):
    def __init__(self, features, hidden):
        super().__init__()
        self.layers = nn.Sequential(
            nn.Conv1d(features, hidden, kernel_size=1), nn.ReLU(),
            nn.Conv1d(hidden, hidden, kernel_size=1), nn.ReLU(),
            nn.Conv1d(hidden, hidden, kernel_size=1), nn.ReLU(),
            nn.Conv1d(hidden, 128, kernel_size=1), nn.ReLU(),
        )
        self.actions = nn.Conv1d(128, ACTIONS, kernel_size=1)
        self.shot = nn.Conv1d(128, SHOT, kernel_size=1)
        self.placements = nn.Conv1d(128, PLACEMENTS, kernel_size=1)
        self.colours = nn.Conv1d(128, COLOURS, kernel_size=1)

    def forward(self, x):
        h = self.layers(x.unsqueeze(-1))
        shot = self.shot(h).squeeze(-1)
        aim = shot[:, 0:2]
        aim = aim / (aim.norm(dim=1, keepdim=True) + 1e-6)
        shot = torch.cat([aim, torch.sigmoid(shot[:, 2:3]), torch.tanh(shot[:, 3:5]),
                          torch.sigmoid(shot[:, 5:6])], dim=1)
        return torch.cat([self.actions(h).squeeze(-1),
                          shot,
                          self.placements(h).squeeze(-1),
                          self.colours(h).squeeze(-1)], dim=1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset")
    parser.add_argument("out")
    parser.add_argument("--extra", action="append", default=[])
    parser.add_argument("--epochs", type=int, default=200)
    parser.add_argument("--hidden", type=int, default=256)
    parser.add_argument("--batch", type=int, default=64)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--init")
    parser.add_argument("--no-coreml", action="store_true")
    parser.add_argument("--win-weighted", action="store_true",
                        help="weight every decision by whether its player won the frame: the only label a "
                             "self-play round is allowed to learn from")
    arguments = parser.parse_args()
    torch.manual_seed(arguments.seed)

    parts = [read_dataset(arguments.dataset)] + [read_dataset(p) for p in arguments.extra]
    inputs = np.concatenate([p[0] for p in parts])
    action = np.concatenate([p[1] for p in parts])
    shot = np.concatenate([p[2] for p in parts])
    placement = np.concatenate([p[3] for p in parts])
    colour = np.concatenate([p[4] for p in parts])
    outcomes = np.concatenate([p[5] for p in parts])
    print(f"{len(inputs)} decisions, {inputs.shape[1]} inputs each")
    for kind, name in enumerate(["shoot", "place", "nominate", "free ball", "decline", "play on",
                                 "ask again", "replace", "claim", "re-rack"]):
        count = (action == kind).sum()
        if count:
            print(f"  {name:<10} {count}")

    order = np.random.default_rng(arguments.seed).permutation(len(inputs))
    split = int(len(inputs) * 0.85)
    train, val = order[:split], order[split:]
    if len(val) < 8:
        train = val = order

    def tensors(index):
        return (torch.tensor(inputs[index], dtype=torch.float32),
                torch.tensor(action[index], dtype=torch.long),
                torch.tensor(shot[index], dtype=torch.float32),
                torch.tensor(placement[index], dtype=torch.long),
                torch.tensor(colour[index], dtype=torch.long))

    x_train, a_train, s_train, p_train, c_train = tensors(train)
    x_val, a_val, s_val, p_val, c_val = tensors(val)
    won = outcomes[:, 3] if outcomes.ndim > 1 and outcomes.shape[1] >= 4 else np.zeros(len(inputs))
    sample_weight = 0.15 + 0.85 * won if arguments.win_weighted else np.ones(len(inputs))
    if arguments.win_weighted:
        print(f"win-weighted: {100 * float(won.mean()):.0f}% of decisions come from frames that were won")
    w_train = torch.tensor(sample_weight[train], dtype=torch.float32)
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    print(f"training on {device}")
    state = torch.load(arguments.init, map_location="cpu") if arguments.init else None
    model = DeciderNet(inputs.shape[1],
                       state["layers.0.weight"].shape[0] if state else arguments.hidden).to(device)
    if state:
        model.load_state_dict(state)
        print(f"starting from {arguments.init}")
    print(f"{sum(p.numel() for p in model.parameters())} weights")
    optimiser = torch.optim.Adam(model.parameters(), lr=arguments.lr,
                                 weight_decay=arguments.weight_decay)
    schedule = torch.optim.lr_scheduler.CosineAnnealingLR(optimiser, T_max=arguments.epochs)
    shot_weights = torch.tensor([4.0, 4.0, 2.0, 1.5, 1.5, 1.0], device=device)
    cross = nn.CrossEntropyLoss()

    def loss_of(out, a, s, p, c, w):
        ce = nn.functional.cross_entropy(out[:, :ACTIONS], a, reduction="none")
        loss = (ce * w).mean()
        is_shot = a == 0
        if is_shot.any():
            mse = (((out[is_shot, ACTIONS:ACTIONS + SHOT] - s[is_shot]) ** 2)
                   * shot_weights).mean(dim=1)
            loss = loss + (mse * w[is_shot]).mean()
        is_place = a == 1
        if is_place.any():
            place = nn.functional.cross_entropy(
                out[is_place, ACTIONS + SHOT:ACTIONS + SHOT + PLACEMENTS], p[is_place], reduction="none")
            loss = loss + (place * w[is_place]).mean()
        is_colour = (a == 2) | (a == 3)
        if is_colour.any():
            colour = nn.functional.cross_entropy(
                out[is_colour, ACTIONS + SHOT + PLACEMENTS:], c[is_colour], reduction="none")
            loss = loss + (colour * w[is_colour]).mean()
        return loss

    def aim_error(out, a, s):
        is_shot = (a == 0).numpy()
        if not is_shot.any():
            return 0.0
        predicted = out[is_shot, ACTIONS:ACTIONS + 2].detach().cpu().numpy()
        truth = s[is_shot].cpu().numpy()
        pa = np.degrees(np.arctan2(predicted[:, 0], predicted[:, 1]))
        ta = np.degrees(np.arctan2(truth[:, 0], truth[:, 1]))
        return float(np.abs((pa - ta + 180) % 360 - 180).mean())

    best, best_state, best_epoch = float("inf"), None, 0
    started = time.time()
    for epoch in range(arguments.epochs):
        model.train()
        shuffle = torch.randperm(len(x_train))
        total = 0.0
        for start in range(0, len(shuffle), arguments.batch):
            index = shuffle[start:start + arguments.batch]
            batch = (x_train[index].to(device), a_train[index].to(device), s_train[index].to(device),
                     p_train[index].to(device), c_train[index].to(device))
            optimiser.zero_grad()
            loss = loss_of(model(batch[0]), *batch[1:], w_train[index].to(device))
            loss.backward()
            optimiser.step()
            total += float(loss.detach()) * len(index)
        schedule.step()
        model.eval()
        with torch.no_grad():
            out = model(x_val.to(device)).cpu()
        error = aim_error(out, a_val, s_val)
        if error < best:
            best, best_epoch = error, epoch + 1
            best_state = {k: v.detach().clone() for k, v in model.state_dict().items()}
        if (epoch + 1) % 20 == 0 or epoch == arguments.epochs - 1:
            accuracy = float((out[:, :ACTIONS].argmax(1) == a_val).float().mean())
            print(f"  epoch {epoch + 1:4d}  loss {total / len(shuffle):6.3f}  "
                  f"action {100 * accuracy:4.0f}%  shot aim {error:5.2f}°")
    if best_state:
        model.load_state_dict(best_state)
        print(f"keeping epoch {best_epoch} (shot aim {best:.2f}°)")
    print(f"trained in {time.time() - started:.1f} s")
    model.eval()
    with torch.no_grad():
        out = model(x_val.to(device)).cpu()
    prediction = out[:, :ACTIONS].argmax(1)
    print(f"held out: action accuracy {100 * float((prediction == a_val).float().mean()):.0f}%")
    print(f"held out: shot aim error {aim_error(out, a_val, s_val):.2f}°")
    for kind, name in ((1, "placement"), (2, "colour")):
        pick = a_val == kind
        if pick.any():
            offset = ACTIONS + SHOT if kind == 1 else ACTIONS + SHOT + PLACEMENTS
            print(f"held out: {name} accuracy "
                  f"{100 * float((out[pick, offset:].argmax(1) == (p_val if kind == 1 else c_val)[pick]).float().mean()):.0f}%")
    torch.save(model.state_dict(), arguments.out + ".pt")
    print(f"wrote {arguments.out}.pt")

    if arguments.no_coreml:
        return
    import coremltools as ct
    model = model.cpu().eval()
    example = torch.zeros(1, inputs.shape[1], dtype=torch.float32)
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="position", shape=example.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="decision")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS13,
        convert_to="mlprogram",
    )
    mlmodel.short_description = ("Every decision a player makes from PositionFeatures and the rules' masks:"
                                 " action logits, stroke, placement logits, colour logits")
    mlmodel.save(arguments.out)
    print(f"wrote {arguments.out}")


if __name__ == "__main__":
    main()
