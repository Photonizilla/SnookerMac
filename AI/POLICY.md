# A learned policy: the network that plays the stroke

The policy reads a position — every ball on the table, the ball on, the score — and gives back the whole
stroke: the aiming angle, the power, the side spin, the vertical spin and the lift. It is a Core ML
program, `AI/Models/Policy1.mlpackage`, and the player has no say in those five numbers when it is loaded:
the search is not asked for a shot, and the cue action's own error (0.03° at Hard) is applied to what the
network chose.

## The pipeline

```sh
# 1. Supervised: the current Hard player's own shots, from varied layouts.
Snooker --ai-export-policy AI/Models/policy_supervised.bin --frames 12 --hard --reds 10

# 2. Train and convert. The torch weights are saved beside the package for a later round.
python3 AI/train_policy_net.py AI/Models/policy_supervised.bin \
        AI/Models/Policy1.mlpackage --epochs 300 --hidden 256

# 3. The compiled copy, so the harness does not need a writable temporary directory to compile it.
xcrun coremlcompiler compile AI/Models/Policy1.mlpackage AI/Models/

# 4. Play with it. Every stroke is the network's.
Snooker --ai-play 1 --hard --policy AI/Models/Policy1.mlmodelc

# 5. Self-play: the policy plays itself, the Hard player labels the positions it visits.
Snooker --ai-selfplay AI/Models/policy_selfplay.bin \
        --policy AI/Models/Policy1.mlmodelc --frames 10 --hard

# 6. Fine-tune on the supervised data and the self-play data together.
python3 AI/train_policy_net.py AI/Models/policy_supervised.bin \
        AI/Models/Policy2.mlpackage --extra AI/Models/policy_selfplay.bin \
        --init AI/Models/Policy1.pt --epochs 200
```

The dataset is `SNOOKERPC1`: a count, a stride, then for every shot the 152 `PositionFeatures` and six
labels — `sin(angle), cos(angle), power, side, vertical, lift ÷ 45°` — and four outcomes: the points the
stroke scored, whether it fouled, whether it kept the table, and whether its player won the frame. The
angle is a pair so the wrap at ±180° is not a cliff. The outcomes are not used by the supervised loss yet;
they are there for the self-play weighting that comes next.

## What the first model does

Trained on 570 shots from 12 Hard frames (10 reds, varied starting layouts), held out:

| | |
|---|---|
| aim error | **33.6° mean, 15.8° median** |
| within 1° | 21% |
| within 3° | 36% |
| power | 0.18 mean absolute error |
| side spin | 0.08 |
| vertical spin | 0.19 |
| lift | 6.2° |

It loads and plays, but that is not a player yet: a typical frame opens with

```
the network's shot — -11.5° power 0.42 side +0.02 vertical +0.00
    ⚠️ foul: cue ball failed to contact a ball on and a miss
```

and the self-play frames end after a handful of strokes, because a shot the network invents often leaves
the cue nowhere it can be laid. The self-play loop itself runs: two frames produced six samples with the
Hard player's targets, which is the first round of the loop, not an improvement.

## Why, and what comes next

The first model is an **absolute regression from a flat vector to a shot**. The Hard player's shots are a
multimodal function of the position — the same layout offers several pots and safeties — and the network
has to rediscover the ghost-ball geometry, the throw correction and the search's preferences from 570
examples. That is far too few, and 0.03° is a demanding target.

The next architecture should give the network the geometry the player already computes:

- **a candidate-conditioned policy**: for each pot/safety the geometry proposes, the network reads the
  position plus that candidate's five parameters and outputs a score and the final five parameters. It
  picks the highest-scoring candidate and plays its parameters. That is still the network choosing the
  shot and every number in it, but it no longer has to learn the ghost ball from scratch.
- **a spatial encoder** for the table (a small grid of ball planes) if the flat vector turns out to be the
  limit, as the earlier value experiments suggested.
- **the same pipeline, many more frames**: the export costs about 15 s a frame and produces about 48 shots,
  so 100 frames is a quarter-hour and roughly 5,000 shots; a candidate-conditioned policy should need far
  fewer than the absolute one.

## The Neural Engine

The network is written as 1×1 convolutions — dense layers in the shape Core ML hands to the Neural Engine —
and every call reports the compute plan. On this Mac the plan for `Policy1` was **55 operations
unassigned and 23 on the CPU**: the same answer the value network gave. The model is small and its input is
one position at a time, and Core ML does not put it on the Neural Engine. A batch of positions, or a much
larger spatial trunk, is what the engine wants; the player needs one shot at a time, so the honest answer
is that the ANE is not being used yet.
