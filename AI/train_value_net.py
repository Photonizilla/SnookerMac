#!/usr/bin/env python3
"""Trains the value network the computer player can use instead of its own arithmetic.

The dataset comes from the game itself:

    Snooker.app/Contents/MacOS/Snooker --ai-export /tmp/train.bin --positions 400 --easy

which plays positions out with the search player and records, for every position it was the striker's
turn to play from, the **points that striker went on to score from it** before the table passed. That is
the thing to predict: not who wins, not what the shot is, but what a position is worth to the player
whose turn it is.

The network is deliberately small — a few hundred thousand weights — because it is not the player. It is
called at the leaves of a search that already knows the physics exactly, thousands of times a shot, so it
has to be a fraction of a millisecond, and it has to be a shape the Neural Engine will take: dense layers,
ReLU, fixed shapes, half precision. Anything cleverer belongs in the search, where it can be checked.

    python train_value_net.py <dataset.bin> <out.mlpackage> [--epochs 200] [--hidden 128]
"""

import argparse
import struct
import time

import numpy as np
import torch
import torch.nn as nn

MAGIC_V1 = b"SNOOKERAI1"
MAGIC_V2 = b"SNOOKERAI2"

# What a sample's target columns are, past the features. The first is what a value function is for; the
# others are there so that a training run can choose between them — see `--target`.
TARGETS = ("the points scored from the position", "the stroke's own points",
           "those points discounted", "the player's own arithmetic", "the visit it came from")


def read_dataset(path):
    """The dataset file: a magic, a count, a stride, then float32 rows of features and targets."""
    with open(path, "rb") as handle:
        blob = handle.read()
    magic = blob[:10]
    if magic not in (MAGIC_V1, MAGIC_V2):
        raise SystemExit(f"{path} is not a snooker dataset (it starts with {magic!r})")
    count, stride = struct.unpack_from("<II", blob, 10)
    rows = np.frombuffer(blob, dtype="<f4", offset=18, count=count * stride).reshape(count, stride)
    feature_count = stride - (1 if magic == MAGIC_V1 else len(TARGETS))
    features = rows[:, :feature_count].copy()
    if magic == MAGIC_V1:
        # The first format had the features and one target: the points scored from the position.
        return features, {"visit": rows[:, -1].copy()}
    return features, {name: rows[:, feature_count + index].copy()
                      for index, name in enumerate(TARGETS)}


class ValueNet(nn.Module):
    """A position's features in, the points the striker will score from it out."""

    def __init__(self, features, hidden):
        super().__init__()
        self.layers = nn.Sequential(
            nn.Linear(features, hidden), nn.ReLU(),
            nn.Linear(hidden, hidden), nn.ReLU(),
            nn.Linear(hidden, hidden // 2), nn.ReLU(),
            nn.Linear(hidden // 2, 1),
        )

    def forward(self, x):
        return self.layers(x).squeeze(-1)


class ConvolutionalValueNet(nn.Module):
    """The same network, with its dense layers written as the convolutions the Neural Engine is built for.

    A 1x1 convolution over a feature vector **is** a dense layer — every output looks at every input and
    nothing else — but Core ML's planner does not treat the two the same. Asked for a dense network, even
    a large one, it runs the whole thing on the CPU: the Neural Engine is built for the shapes
    convolutions come in, and a matmul over a short vector is not one of them. Written as convolutions,
    the same arithmetic is handed to the Neural Engine instead. `--ai-model-plan` is what shows the
    difference; the two networks predict the same thing.
    """

    def __init__(self, features, hidden):
        super().__init__()
        self.layers = nn.Sequential(
            nn.Conv1d(features, hidden, kernel_size=1), nn.ReLU(),
            nn.Conv1d(hidden, hidden, kernel_size=1), nn.ReLU(),
            nn.Conv1d(hidden, hidden // 2, kernel_size=1), nn.ReLU(),
            nn.Conv1d(hidden // 2, 1, kernel_size=1),
        )

    def forward(self, x):
        # The features are one pixel with `features` channels, so a 1x1 convolution over them is exactly a
        # dense layer: every output sees every input, and nothing is mixed across anything else.
        return self.layers(x.unsqueeze(-1)).squeeze(-1).squeeze(-1)


def as_convolutions(dense, features, hidden):
    """The trained dense network's own weights, in the convolutional network's shape.

    A 1x1 convolution holds the same numbers as the dense layer it stands for, so nothing has to be
    trained twice: the network that is measured is the network that is converted, and the two are checked
    against each other before either is written out.
    """
    convolutional = ConvolutionalValueNet(features, hidden)
    linears = [layer for layer in dense.layers if isinstance(layer, nn.Linear)]
    convolutions = [layer for layer in convolutional.layers if isinstance(layer, nn.Conv1d)]
    for linear, convolution in zip(linears, convolutions):
        with torch.no_grad():
            convolution.weight.copy_(linear.weight.unsqueeze(-1))
            convolution.bias.copy_(linear.bias)
    return convolutional


def rank_correlation(a, b):
    """Spearman's, which is the number that matters: the search only ever compares two positions.

    Ties get the average of the ranks they span, which is what makes a prediction with no variation in it
    score nothing at all. Ranking ties by their place in the file instead quietly turns "the same answer
    every time" into a very good score, because the file is full of runs — a break is twenty positions in a
    row that are all worth something.
    """
    def ranks(x):
        order = np.argsort(x, kind="stable")
        ranks = np.empty(len(x), dtype=np.float64)
        ranks[order] = np.arange(len(x))
        ordered = x[order]
        start = 0
        while start < len(ordered):
            end = start
            while end + 1 < len(ordered) and ordered[end + 1] == ordered[start]:
                end += 1
            if end > start:
                ranks[order[start:end + 1]] = (start + end) / 2
            start = end + 1
        return ranks
    ra, rb = ranks(a), ranks(b)
    ra -= ra.mean()
    rb -= rb.mean()
    denominator = np.sqrt((ra ** 2).sum() * (rb ** 2).sum())
    return float((ra * rb).sum() / denominator) if denominator else 0.0


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("dataset")
    parser.add_argument("out")
    parser.add_argument("--epochs", type=int, default=200)
    parser.add_argument("--hidden", type=int, default=128)
    parser.add_argument("--batch", type=int, default=256)
    parser.add_argument("--lr", type=float, default=1e-3)
    parser.add_argument("--weight-decay", type=float, default=1e-4)
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--no-coreml", action="store_true")
    parser.add_argument("--batch-shape", type=int, default=1,
                        help="the number of positions the exported model takes at once. The Neural "
                             "Engine is chosen for a shape with work in it; one position at a time is "
                             "small enough that Core ML puts the whole thing on the CPU.")
    parser.add_argument("--arch", choices=["dense", "conv"], default="dense")
    parser.add_argument("--target", choices=["scored", "discounted"], default="scored",
                        help="what the network is asked to predict: the points scored from the position "
                             "until the table passes, or the same sum with each stroke worth less than "
                             "the one before it (which is quieter to learn from)")
    arguments = parser.parse_args()

    torch.manual_seed(arguments.seed)
    features, columns = read_dataset(arguments.dataset)
    wanted = "the points scored from the position" if arguments.target == "scored" \
        else "those points discounted"
    targets = columns[wanted]
    print(f"{len(features)} positions, {features.shape[1]} features each")
    print(f"the target is {wanted}")
    print(f"  mean {targets.mean():.2f}, "
          f"nothing {100 * (targets == 0).mean():.0f}%, "
          f"eight or more {100 * (targets >= 8).mean():.0f}%, most {targets.max():.0f}")

    # Shuffled before the split, and the whole file is shuffled rather than only the training part of it:
    # the dataset is written position by position, and within a position visit by visit, so consecutive
    # rows are the same player's break and their targets rise and fall together. Splitting such a file in
    # order puts whole breaks on one side of the line, and any statistic that reads the order — a ranking,
    # as it happens — picks up the runs instead of the signal.
    order = np.random.default_rng(arguments.seed).permutation(len(features))
    split = int(len(features) * 0.9)
    train_index, validation_index = order[:split], order[split:]
    x_train = torch.tensor(features[train_index], dtype=torch.float32)
    y_train = torch.tensor(targets[train_index], dtype=torch.float32)
    x_val = torch.tensor(features[validation_index], dtype=torch.float32)
    y_val = torch.tensor(targets[validation_index], dtype=torch.float32)

    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    print(f"training on {device}")
    model = ValueNet(features.shape[1], arguments.hidden).to(device)
    print(f"{sum(p.numel() for p in model.parameters())} weights")
    optimiser = torch.optim.Adam(model.parameters(), lr=arguments.lr,
                                 weight_decay=arguments.weight_decay)
    schedule = torch.optim.lr_scheduler.CosineAnnealingLR(optimiser, T_max=arguments.epochs)
    loss_function = nn.HuberLoss(delta=2.0)

    # The target is noisy — the same position played twice can be worth nothing or a break — so the
    # network starts fitting the noise long before it is done fitting the signal, and the held-out error
    # gets worse while the training loss keeps falling. The weights that are kept are the ones from the
    # best held-out epoch, not the last.
    best_weights = None
    best_error = float("inf")
    best_epoch = 0
    started = time.time()
    for epoch in range(arguments.epochs):
        model.train()
        order = torch.randperm(len(x_train))
        total = 0.0
        for start in range(0, len(order), arguments.batch):
            index = order[start:start + arguments.batch]
            batch_x = x_train[index].to(device)
            batch_y = y_train[index].to(device)
            optimiser.zero_grad()
            loss = loss_function(model(batch_x), batch_y)
            loss.backward()
            optimiser.step()
            total += float(loss.detach()) * len(index)
        schedule.step()
        # The held-out position is looked at every epoch — it is a tenth of the data and costs nothing —
        # and what is reported is thinned out.
        model.eval()
        with torch.no_grad():
            predicted = model(x_val.to(device)).cpu().numpy()
        mae = float(np.abs(predicted - y_val.numpy()).mean())
        if mae < best_error:
            best_error = mae
            best_epoch = epoch + 1
            best_weights = {key: value.detach().clone()
                            for key, value in model.state_dict().items()}
        if (epoch + 1) % 20 == 0 or epoch == arguments.epochs - 1:
            correlation = rank_correlation(predicted, y_val.numpy())
            print(f"  epoch {epoch + 1:4d}  loss {total / len(order):6.3f}  "
                  f"held-out error {mae:5.2f} points  ranking {correlation:+.3f}")
        model.train()
    if best_weights is not None:
        model.load_state_dict(best_weights)
        print(f"keeping the weights from epoch {best_epoch} "
              f"(held-out error {best_error:.2f} points)")
    print(f"trained in {time.time() - started:.1f} s")

    # What the network is worth. Two things are being asked at once: does it predict the target better
    # than guessing, and — the one that matters, because the search only ever compares two positions —
    # does it *rank* them better than the arithmetic the player already has?
    model.eval()
    with torch.no_grad():
        predicted = model(x_val.to(device)).cpu().numpy()
    truth = y_val.numpy()
    arithmetic = columns["the player's own arithmetic"][validation_index]
    mean_only = np.full_like(truth, float(y_train.mean()))
    rows = [
        ("the network", predicted),
        ("the arithmetic the player has", arithmetic),
        ("always the average", mean_only),
    ]
    print("held out from training:")
    for name, guess in rows:
        print(f"  {name:>30}  error {np.abs(guess - truth).mean():5.2f}   "
              f"ranking {rank_correlation(guess, truth):+.3f}")
    print("  (the ranking is what the search uses: it only ever compares two positions)")

    # The last feature is how fallible the cue action was, in degrees: if the data varies it — which is
    # what `--ai-error-range` is for — then a position is worth less to a worse player, and the network
    # should have learned that rather than answering for the average of them.
    fallibility = features[validation_index][:, -1] * 0.5
    middle = np.median(fallibility)
    if 30 < (fallibility <= middle).sum() < len(fallibility) - 30:
        for label, pick in (("the gentler half", fallibility <= middle),
                            ("the wilder half", fallibility > middle)):
            print(f"  {label:>30}  the target {truth[pick].mean():5.2f} points, "
                  f"the network {np.abs(predicted[pick] - truth[pick]).mean():5.2f} error, "
                  f"ranking {rank_correlation(predicted[pick], truth[pick]):+.3f}")

    if arguments.no_coreml:
        return
    import coremltools as ct

    model = model.cpu().eval()
    if arguments.arch == "conv":
        dense = model
        model = as_convolutions(dense, features.shape[1], arguments.hidden)
        check = torch.randn(4, features.shape[1], dtype=torch.float32)
        with torch.no_grad():
            difference = float((dense(check) - model(check)).abs().max())
        print(f"the convolutional network runs the same numbers as the dense one "
              f"(largest difference {difference:.2e})")
        # The two do not agree to the last bit: summing a convolution's terms is not summing a dense
        # layer's in the same order. A thousandth of a point is the same answer.
        if difference > 1e-3:
            raise SystemExit("the two networks do not agree: not converting")

    example = torch.zeros(arguments.batch_shape, features.shape[1], dtype=torch.float32)
    traced = torch.jit.trace(model, example)
    mlmodel = ct.convert(
        traced,
        inputs=[ct.TensorType(name="position", shape=example.shape, dtype=np.float32)],
        outputs=[ct.TensorType(name="value")],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.macOS13,
        convert_to="mlprogram",
    )
    mlmodel.short_description = ("The points the player at the table is expected to score from this "
                                 "position, from PositionFeatures.of")
    mlmodel.save(arguments.out)
    print(f"wrote {arguments.out}")


if __name__ == "__main__":
    main()
