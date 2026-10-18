#!/usr/bin/env python3
"""Trains the **candidate-conditioned** shot policy.

The geometry proposes the shots that are on — as **inputs**, one row per candidate — and the network reads
the position plus that candidate's numbers, scores it and gives the stroke. The highest score wins and its
six numbers are the shot. The network never has to rediscover the ghost ball; it has to rank the proposals
and say what the stroke should be.

    Snooker --ai-export-candidates /tmp/candidates.bin --frames 10 --hard
    python3 train_candidate_net.py /tmp/candidates.bin /tmp/Candidate1.mlpackage --epochs 200

Each row is `PositionFeatures` + the candidate's six numbers and ease, its intent, cut, pocket and ball:
191 inputs. The label is 1 for the candidate the Hard player chose; the six stroke numbers are its shot.
"""

import argparse
import struct
import time

import numpy as np
import torch
import torch.nn as nn

MAGIC = b"SNOOKERCV1"
SHOT = 6


def read_dataset(path):
    blob = open(path, "rb").read()
    if blob[:10] != MAGIC:
        raise SystemExit(f"{path} is not a candidate dataset (it starts with {blob[:10]!r})")
    count, stride = struct.unpack_from("<II", blob, 10)
    rows = np.frombuffer(blob, dtype="<f4", offset=18, count=count * stride).reshape(count, stride)
    split = stride - 1 - SHOT
    return rows[:, :split].copy(), rows[:, split].copy(), rows[:, split + 1:].copy()


class CandidateNet(nn.Module):
    def __init__(self, features, hidden):
        super().__init__()
        self.layers = nn.Sequential(
            nn.Conv1d(features, hidden, kernel_size=1), nn.ReLU(),
            nn.Conv1d(hidden, hidden, kernel_size=1), nn.ReLU(),
            nn.Conv1d(hidden, hidden // 2, kernel_size=1), nn.ReLU(),
        )
        self.head = nn.Conv1d(hidden // 2, 1 + SHOT, kernel_size=1)

    def forward(self, x):
        y = self.head(self.layers(x.unsqueeze(-1))).squeeze(-1)
        aim = y[:, 1:3]
        aim = aim / (aim.norm(dim=1, keepdim=True) + 1e-6)
        return torch.cat([y[:, 0:1], aim, torch.sigmoid(y[:, 3:4]), torch.tanh(y[:, 4:6]),
                          torch.sigmoid(y[:, 6:7])], dim=1)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset")
    parser.add_argument("out")
    parser.add_argument("--epochs", type=int, default=200)
    parser.add_argument("--hidden", type=int, default=256)
    parser.add_argument("--batch", type=int, default=128)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--no-coreml", action="store_true")
    arguments = parser.parse_args()
    torch.manual_seed(arguments.seed)

    features, label, shot = read_dataset(arguments.dataset)
    # The aim head is a **residual**: the turn from the candidate's own line. That is what lets the network
    # move a shot ten degrees for a swerve, and what the loss then actually measures. The candidate's aim
    # is the first pair after the position features.
    candidate_angle = np.arctan2(features[:, 152], features[:, 153])
    target_angle = np.arctan2(shot[:, 0], shot[:, 1])
    offset = (target_angle - candidate_angle + np.pi) % (2 * np.pi) - np.pi
    shot = shot.copy()
    shot[:, 0] = np.sin(offset)
    shot[:, 1] = np.cos(offset)
    print(f"aim offsets: median {np.degrees(np.median(np.abs(offset))):.2f}°, "
          f"95th {np.degrees(np.percentile(np.abs(offset), 95)):.2f}°, "
          f"max {np.degrees(np.abs(offset).max()):.2f}°")
    print(f"{len(features)} candidate rows, {features.shape[1]} inputs, "
          f"{label.mean() * 100:.0f}% chosen")
    order = np.random.default_rng(arguments.seed).permutation(len(features))
    split = int(len(features) * 0.85)
    train, val = order[:split], order[split:]
    if label[val].sum() < 5:
        train = val = order

    x_train = torch.tensor(features[train], dtype=torch.float32)
    l_train = torch.tensor(label[train], dtype=torch.float32)
    s_train = torch.tensor(shot[train], dtype=torch.float32)
    x_val = torch.tensor(features[val], dtype=torch.float32)
    l_val = torch.tensor(label[val], dtype=torch.float32)
    s_val = torch.tensor(shot[val], dtype=torch.float32)
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    print(f"training on {device}")
    model = CandidateNet(features.shape[1], arguments.hidden).to(device)
    print(f"{sum(p.numel() for p in model.parameters())} weights")
    optimiser = torch.optim.Adam(model.parameters(), lr=arguments.lr,
                                 weight_decay=arguments.weight_decay)
    schedule = torch.optim.lr_scheduler.CosineAnnealingLR(optimiser, T_max=arguments.epochs)
    positives = float(label.sum())
    negatives = float(len(label) - positives)
    pos_weight = torch.tensor([min(20.0, negatives / max(1.0, positives))], device=device)
    shot_weights = torch.tensor([4.0, 4.0, 2.0, 1.5, 1.5, 1.0], device=device)

    def loss_of(out, chosen, target):
        loss = nn.functional.binary_cross_entropy_with_logits(
            out[:, 0], chosen, pos_weight=pos_weight)
        pick = chosen > 0.5
        if pick.any():
            loss = loss + (((out[pick, 1:] - target[pick]) ** 2) * shot_weights).mean()
        return loss

    def aim_error(out, chosen, target):
        pick = (chosen > 0.5)
        if not pick.any():
            return 0.0
        p = out[pick, 1:3].detach().cpu().numpy()
        t = target[pick].cpu().numpy()
        pa = np.degrees(np.arctan2(p[:, 0], p[:, 1]))
        ta = np.degrees(np.arctan2(t[:, 0], t[:, 1]))
        return float(np.abs((pa - ta + 180) % 360 - 180).mean())

    def ranking(out, chosen):
        scores = out[:, 0].detach().cpu().numpy()
        positive = scores[chosen.numpy() > 0.5]
        negative = scores[chosen.numpy() <= 0.5]
        if len(positive) == 0 or len(negative) == 0:
            return 0.0
        sample = min(len(positive), len(negative), 4000)
        rng = np.random.default_rng(1)
        p = positive[rng.integers(0, len(positive), sample)]
        n = negative[rng.integers(0, len(negative), sample)]
        return float((p[:, None] > n[None, :]).mean())

    best, best_state, best_epoch = float("inf"), None, 0
    started = time.time()
    for epoch in range(arguments.epochs):
        model.train()
        shuffle = torch.randperm(len(x_train))
        total = 0.0
        for start in range(0, len(shuffle), arguments.batch):
            index = shuffle[start:start + arguments.batch]
            bx, bl, bs = x_train[index].to(device), l_train[index].to(device), s_train[index].to(device)
            optimiser.zero_grad()
            loss = loss_of(model(bx), bl, bs)
            loss.backward()
            optimiser.step()
            total += float(loss.detach()) * len(index)
        schedule.step()
        model.eval()
        with torch.no_grad():
            out = model(x_val.to(device)).cpu()
        error = aim_error(out, l_val, s_val)
        if error < best:
            best, best_epoch = error, epoch + 1
            best_state = {k: v.detach().clone() for k, v in model.state_dict().items()}
        if (epoch + 1) % 20 == 0 or epoch == arguments.epochs - 1:
            print(f"  epoch {epoch + 1:4d}  loss {total / len(shuffle):6.4f}  "
                  f"ranking {100 * ranking(out, l_val):4.0f}%  chosen aim {error:5.2f}°")
    if best_state:
        model.load_state_dict(best_state)
        print(f"keeping epoch {best_epoch} (chosen aim {best:.2f}°)")
    print(f"trained in {time.time() - started:.1f} s")
    model.eval()
    with torch.no_grad():
        out = model(x_val.to(device)).cpu()
    print(f"held out: ranking {100 * ranking(out, l_val):.0f}%, "
          f"chosen aim {aim_error(out, l_val, s_val):.2f}°")
    torch.save(model.state_dict(), arguments.out + ".pt")
    print(f"wrote {arguments.out}.pt")

    if arguments.no_coreml:
        return
    import coremltools as ct
    model = model.cpu().eval()
    example = torch.zeros(1, features.shape[1], dtype=torch.float32)
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="position", shape=example.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="decision")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS13,
        convert_to="mlprogram",
    )
    mlmodel.short_description = ("A score for this proposed shot, and the stroke to play instead: "
                                 "aim sin/cos, power, side, vertical, lift/45°")
    mlmodel.save(arguments.out)
    print(f"wrote {arguments.out}")


if __name__ == "__main__":
    main()
