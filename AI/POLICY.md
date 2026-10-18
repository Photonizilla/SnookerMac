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

## The pure player: every decision from the network

`--decider <model>` installs a player with **no geometry and no search**. It is given
`PolicySituation` — the 152 `PositionFeatures` plus the rules' own masks: 12 possible actions, the 6
colours, the 6 free-ball nominations and the 64 placement cells — and answers with 88 numbers: the twelve
action logits, the six stroke labels, the sixty-four placement logits and the six colour logits. The masks
are applied to the logits, so the action that comes out is one the rules allow; the choice is the
network's. The administrative decisions are network heads too: place the cue ball, nominate a colour, take
or decline a free ball, play from here, ask the offender, replace the balls, claim the frame, re-rack.

```sh
Snooker --ai-export-all AI/Models/all.bin --frames 12 --hard --reds 10
python3 AI/train_decider_net.py AI/Models/all.bin AI/Models/Decider1.mlpackage --epochs 200
xcrun coremlcompiler compile AI/Models/Decider1.mlpackage AI/Models/
Snooker --ai-play 1 --hard --decider AI/Models/Decider1.mlmodelc
Snooker --ai-selfplay-all AI/Models/all_selfplay.bin --policy AI/Models/Decider1.mlmodelc --frames 10
```

The first all-decisions model was trained on **475 decisions** from 8 Hard frames and scored 99% of actions
(the classes are dominated by "shoot"), 67% of colours and a **36.6° mean aim error**. Doubling the data to
**1,046 decisions** — 18 more frames, every third one starting from the rack or from the colours-only
endgame — moved the held-out shot aim to **24.7°** and the colour accuracy to **96%**. More data of the
right kind is exactly what moves it:

| | 475 decisions | 1,046 decisions |
|---|---|---|
| actions | 99% | 99% |
| colours | 67% | **96%** |
| shot aim | 36.6° | **24.7°** |
| placement | — (4 examples) | 0% (11 examples) |

In play it makes every decision itself and records **zero shots played out**. It is a working pure player,
not a good one: three strokes, three fouls, and the log shows the other player's network deciding
`replaceTheBalls`.

The labels are not the limit — the Hard teacher can make as many as the clock allows: about **4.6
decisions a second** (571 decisions in 125 s), so 10,000 decisions is roughly 35 minutes and 100,000 about
six hours. The limits are two: the **mix of starting states**, because 8 random mid-frame layouts gave 4
placements and no free balls, and the **representation of the stroke**, which is why 24.7° is still far
from 0.03°. The next data change is to seed in-hand states from random layouts and to offer free balls, so
that the placement and free-ball heads get hundreds of examples rather than eleven; the shot needs the
candidate-conditioned or spatial policy described above.

## The candidate-conditioned shot

An **absolute** stroke from a flat vector asks the network to rediscover the ghost ball and to average
several correct shots into one wrong one. The candidate-conditioned policy gives it a frame of reference:
the geometry proposes the shots that are on — as **inputs**, never as decisions — and the network reads
the position plus one candidate's numbers, scores it and gives the stroke.

Each row is 191 numbers: the 152 position features, the candidate's aim, power, spins, lift and ease, its
intent, cut, pocket and ball. The model answers with a **score** and six stroke numbers. At play every
candidate is scored, the highest wins, and its stroke is what is played.

```sh
Snooker --ai-export-candidates AI/Models/candidates.bin --frames 10 --hard
python3 AI/train_candidate_net.py AI/Models/candidates.bin AI/Models/Candidate1.mlpackage
xcrun coremlcompiler compile AI/Models/Candidate1.mlpackage AI/Models/
Snooker --ai-play 1 --hard --candidate-policy AI/Models/Candidate1.mlmodelc
```

On 2,059 candidate rows from 240 Hard positions, the model ranks the teacher's candidate above the others
**80%** of the time and its chosen-shot aim error is **5.44°**, against **24.7°** for the absolute policy on
the same teacher data — a 4.5× improvement from the representation alone. In play it still fouls (5.4° is
enough to miss), and the tally records **0 shots played out**: the geometry proposed, the network decided.

The two models compose: `--decider` makes every administrative decision, and `--candidate-policy` supplies
the stroke whenever that decision is "shoot". That is the pure player with the better shot representation,
and neither the action nor the stroke comes from the search.

## The Neural Engine

`--ai-model-plan` reports, for every operation, where Core ML **prefers** it and where it **can** run. On
this M1 Pro (macOS 27.0.1), with `.cpuAndNeuralEngine`, float16 and static shapes:

| model | preferred | can run on |
|---|---|---|
| the policy: 152 → 256×3, batch 1 | 12 CPU | 11 Neural Engine |
| the same, batch 8 and batch 32 | 12 CPU | 11 Neural Engine |
| 152 → 1024×3, batch 32 | **11 Neural Engine, 1 CPU** | 11 Neural Engine |
| spatial 8×16×32, 32/64 channels, batch 1 | 10 CPU | 9 Neural Engine |
| the same, batch 8 | **9 Neural Engine, 1 CPU** | 9 Neural Engine |
| spatial 3×64×128, 64/128 channels, batch 1 | **11 Neural Engine, 1 CPU** | 11 Neural Engine |

Three things decide it:

1. **The process has to be allowed to use it.** The same models read *all CPU* when the harness is run
   inside the Codex sandbox, and move to the Neural Engine when it is run normally. A sandbox that denies
   the engine's device access makes the planner choose the CPU for everything.
2. **The work per layer has to be worth the dispatch.** A position is a 152-float vector: one "pixel" 152
   channels wide, so a 1×1 convolution over it is a tiny matrix multiply. 256 wide at batch 32 is still
   CPU; 1024 wide at batch 32, or a real 2D feature map with 3×3 kernels, reaches the Neural Engine.
   Batch 1 spatial is still CPU; batch 8 spatial is not.
3. **Operations and precision.** Convolutions, ReLU, pooling and elementwise ops are supported; a single
   unsupported op, dynamic shape or fp32 layer splits the graph or moves it. Static float16 `mlprogram`
   models are the shape the engine is built for.

The consequence for this player is architectural: a one-position-at-a-time flat policy will stay on the
CPU. To use the Neural Engine it has to either **batch the positions it evaluates** — the search already
proposes many candidates per decision — or use a **spatial table encoder** with a real trunk.
