#!/usr/bin/env python3
"""Trains the computer's **policy**: a network that reads a position and gives the whole stroke.

The dataset comes from the game itself:

    Snooker --ai-export-policy /tmp/policy.bin --frames 12 --hard

which plays Hard frames from varied layouts and records, at every shot the player played, the position's
features (`PositionFeatures.of`) and the five things the player set on the cue: the aiming angle, the
strength, the side spin, the vertical spin and the lift. The aim is stored as **sin and cos** rather than
an angle, so that the wrap at ±180° is not a cliff for the network to fall off.

The network is written as 1×1 convolutions over the feature vector — the same arithmetic as dense layers,
in the shape Core ML hands to the Neural Engine — and converted to an `.mlpackage` with one input
(`position`, 152 floats) and one output (`shot`: sin, cos, power, side, vertical, lift ÷ 45°).

    python3 train_policy_net.py <dataset.bin> <out.mlpackage> [--epochs 400] [--hidden 256]

The torch weights are saved next to the package (`<out>.pt`) so that a self-play round can fine-tune
from them with `--init`.
"""

import argparse
import struct
import time

import numpy as np
import torch
import torch.nn as nn

MAGIC = b"SNOOKERPC1"
LABELS = 6
OUTCOMES = 4


def read_dataset(path):
    blob = open(path, "rb").read()
    if blob[:10] != MAGIC:
        raise SystemExit(f"{path} is not a policy dataset (it starts with {blob[:10]!r})")
    count, stride = struct.unpack_from("<II", blob, 10)
    rows = np.frombuffer(blob, dtype="<f4", offset=18, count=count * stride).reshape(count, stride)
    split = stride - LABELS - OUTCOMES
    return rows[:, :split].copy(), rows[:, split:split + LABELS].copy(), rows[:, split + LABELS:].copy()


class PolicyNet(nn.Module):
    """A position in, the five things a stroke is made of out."""

    def __init__(self, features, hidden):
        super().__init__()
        self.layers = nn.Sequential(
            nn.Conv1d(features, hidden, kernel_size=1), nn.ReLU(),
            nn.Conv1d(hidden, hidden, kernel_size=1), nn.ReLU(),
            nn.Conv1d(hidden, hidden, kernel_size=1), nn.ReLU(),
            nn.Conv1d(hidden, 64, kernel_size=1), nn.ReLU(),
            nn.Conv1d(64, LABELS, kernel_size=1),
        )

    def forward(self, x):
        y = self.layers(x.unsqueeze(-1)).squeeze(-1)
        aim = y[:, 0:2]
        aim = aim / (aim.norm(dim=1, keepdim=True) + 1e-6)
        return torch.cat([aim,
                          torch.sigmoid(y[:, 2:3]),
                          torch.tanh(y[:, 3:5]),
                          torch.sigmoid(y[:, 5:6])], dim=1)


def angles_in_degrees(pair):
    return np.degrees(np.arctan2(pair[:, 0], pair[:, 1]))


def report(name, predicted, truth):
    angle_error = np.abs((angles_in_degrees(predicted) - angles_in_degrees(truth) + 180) % 360 - 180)
    print(f"{name}:")
    print(f"  aim    mean {angle_error.mean():5.2f}°, median {np.median(angle_error):5.2f}°, "
          f"within 1° {100 * (angle_error <= 1).mean():4.0f}%, within 3° {100 * (angle_error <= 3).mean():4.0f}%")
    for index, label, scale in ((2, "power", 1), (3, "side", 1), (4, "vertical", 1), (5, "lift", 45)):
        error = np.abs(predicted[:, index] - truth[:, index]) * scale
        print(f"  {label:<6} mean {error.mean():5.3f}{'°' if scale > 1 else ''}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset")
    parser.add_argument("out")
    parser.add_argument("--extra", action="append", default=[],
                        help="another policy dataset to train on as well (a self-play round)")
    parser.add_argument("--epochs", type=int, default=400)
    parser.add_argument("--hidden", type=int, default=256)
    parser.add_argument("--batch", type=int, default=64)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--init", help="torch weights to start from (a previous round)")
    parser.add_argument("--no-coreml", action="store_true")
    arguments = parser.parse_args()

    torch.manual_seed(arguments.seed)
    features, labels, outcomes = read_dataset(arguments.dataset)
    for path in arguments.extra:
        more_features, more_labels, more_outcomes = read_dataset(path)
        features = np.concatenate([features, more_features])
        labels = np.concatenate([labels, more_labels])
        outcomes = np.concatenate([outcomes, more_outcomes])
    print(f"{len(features)} shots, {features.shape[1]} features each")
    print(f"  {100 * (outcomes[:, 1] > 0).mean():.0f}% fouled, "
          f"{100 * (outcomes[:, 2] > 0).mean():.0f}% kept the table, "
          f"{100 * (outcomes[:, 3] > 0).mean():.0f}% won the frame")

    order = np.random.default_rng(arguments.seed).permutation(len(features))
    split = int(len(features) * 0.85)
    train_index, validation_index = order[:split], order[split:]
    x_train = torch.tensor(features[train_index], dtype=torch.float32)
    y_train = torch.tensor(labels[train_index], dtype=torch.float32)
    x_val = torch.tensor(features[validation_index], dtype=torch.float32)
    y_val = torch.tensor(labels[validation_index], dtype=torch.float32)
    if len(x_val) < 8:
        x_val, y_val = x_train, y_train

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    print(f"training on {device}")
    state = torch.load(arguments.init, map_location="cpu") if arguments.init else None
    model = PolicyNet(features.shape[1],
                      state["layers.0.weight"].shape[0] if state else arguments.hidden).to(device)
    if state:
        model.load_state_dict(state)
        print(f"starting from {arguments.init}")
    print(f"{sum(p.numel() for p in model.parameters())} weights")
    optimiser = torch.optim.Adam(model.parameters(), lr=arguments.lr,
                                 weight_decay=arguments.weight_decay)
    schedule = torch.optim.lr_scheduler.CosineAnnealingLR(optimiser, T_max=arguments.epochs)
    # The aim is the thing that decides whether the shot is on at all, so it is worth more than a
    # hundredth of a unit of side; the strengths and spins are next, and the lift last.
    weights = torch.tensor([4.0, 4.0, 2.0, 1.5, 1.5, 1.0], device=device)

    def loss_of(predicted, truth):
        return (((predicted - truth) ** 2) * weights).mean()

    best_weights = None
    best_error = float("inf")
    best_epoch = 0
    started = time.time()
    for epoch in range(arguments.epochs):
        model.train()
        shuffle = torch.randperm(len(x_train))
        total = 0.0
        for start in range(0, len(shuffle), arguments.batch):
            index = shuffle[start:start + arguments.batch]
            batch_x, batch_y = x_train[index].to(device), y_train[index].to(device)
            optimiser.zero_grad()
            loss = loss_of(model(batch_x), batch_y)
            loss.backward()
            optimiser.step()
            total += float(loss.detach()) * len(index)
        schedule.step()
        model.eval()
        with torch.no_grad():
            predicted = model(x_val.to(device)).cpu().numpy()
        truth = y_val.numpy()
        error = np.abs((angles_in_degrees(predicted) - angles_in_degrees(truth) + 180) % 360 - 180).mean()
        if error < best_error:
            best_error, best_epoch = error, epoch + 1
            best_weights = {key: value.detach().clone() for key, value in model.state_dict().items()}
        if (epoch + 1) % 20 == 0 or epoch == arguments.epochs - 1:
            print(f"  epoch {epoch + 1:4d}  loss {total / len(shuffle):6.4f}  "
                  f"held-out aim {error:5.2f}°")
    if best_weights is not None:
        model.load_state_dict(best_weights)
        print(f"keeping the weights from epoch {best_epoch} (held-out aim {best_error:.2f}°)")
    print(f"trained in {time.time() - started:.1f} s")
    model.eval()
    with torch.no_grad():
        predicted = model(x_val.to(device)).cpu().numpy()
    report("held out", predicted, y_val.numpy())
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
        outputs=[ct.TensorType(name="shot")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS13,
        convert_to="mlprogram",
    )
    mlmodel.short_description = ("The stroke a player should play from this position, from "
                                 "PositionFeatures.of: aim sin and cos, power, side, vertical, lift/45°")
    mlmodel.save(arguments.out)
    print(f"wrote {arguments.out}")


if __name__ == "__main__":
    main()
