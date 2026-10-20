# The learned value function

**The learned policy is in [POLICY.md](POLICY.md)**: a network that reads the position and gives the whole
stroke — aim, power, side spin, vertical spin and lift — with its dataset export, supervised training, Core
ML conversion and self-play loop. The rest of this file is the value network the search uses at its leaves.

## Training Studio

For running a session without the command line:

```sh
python3 AI/training_studio.py
```

It opens a local page (only on this Mac, on `127.0.0.1`) with four presets — **Shot policy**, **Candidate +
swerve**, **All decisions** and **Exact network** — and the knobs that matter:

- the teacher: Hard (σ 0.03°), Exact (σ 0), Medium or Easy;
- how much data: frames, reds and seed, plus the **aim sweep** that puts swerve lines into the labels;
- the model: epochs, hidden width, batch, learning rate;
- the session name and folder, the Snooker engine and the **Python for training**.

**Check environment** reports the Python, torch, coremltools and whether MPS is available. **Run** executes
the chosen task — a full run is export → train → Core ML conversion → test frame — and streams the log;
**Stop** cancels it and **Open session folder** reveals the dataset, model, compiled `.mlmodelc` and weights.
Sessions are written under `AI/Sessions/<name>/`.

**Deploy to game** copies a session's compiled models into `AI/Models/` — `Model.mlmodelc` becomes
`Candidate2.mlmodelc` (the stroke) and `Decider.mlmodelc` becomes `Decider2.mlmodelc` (the decisions). That
is the folder the app reads, first, so the next *Exact + Deep Learned: On* game uses the new model with no
rebuild; everything stays inside the SnookerMac project.

### Versions

Every full training run is saved as a numbered **version** under `AI/Models/Versions/` when it finishes —
for example `v003-exact-04` — with a `version.json` holding the session, the **parent** it started from
(`scratch` or an earlier version), the date and the run's settings, and the compiled `.mlmodelc` plus the
`.pt` weights. A session that already has models can be saved by hand with **Save this session as a
version**.

**Start from** in the Session panel chooses what a run begins with: *Scratch — a new network*, or a
version. The trainers load that version's `.pt` (the architecture's width is read from the checkpoint), so
a new version can either start fresh or continue an existing model. Each new version records which one it
came from.

The **Versions** panel lists them; choose one and press **Deploy the chosen version**. That copies its
compiled models into `AI/Models/Candidate2.mlmodelc` and `AI/Models/Decider2.mlmodelc` — the files the app
reads — and records the choice in `AI/Models/deployed.json`. The live version is marked ⚡ in the list. A
version with both models replaces both; one with only a candidate (or only decisions) replaces only that
part. Shot-policy versions are not deployable to the game: the Exact network needs the candidate-conditioned
stroke and the all-decisions model.

### The two models, and the three files

| file | what it is |
|---|---|
| `Model.mlpackage` / `Model.mlmodelc` / `Model.mlpackage.pt` | the **stroke**: a candidate-conditioned network — position plus one proposed shot in, a score and the aim turn, power, side spin, vertical spin and lift out. Played with `--candidate-policy`, deployed as `Candidate2.mlmodelc`. |
| `Decider.*` | the **all-decisions** network — `PolicySituation` in, 88 numbers out: 12 action logits, its own six stroke numbers, 64 placement logits and 6 colour logits. Played with `--decider`, deployed as `Decider2.mlmodelc`. |
| `.mlpackage` | the converted Core ML program (source). |
| `.mlmodelc` | the compiled model the app actually loads. |
| `.mlpackage.pt` | the torch weights — what "Start from" and "Convert the saved weights" use. |

In the Exact player the decider chooses every action; when the action is "shoot" the stroke comes from the
candidate model, and only if that model is missing from the decider's own six-number shoot head. A
candidate/stroke run therefore writes only `Model.*`, and an all-decisions run writes only `Decider.*`.

**Delete the chosen version** removes its folder. The version that is currently deployed is refused — deploy
another one first — so the game can never be left pointing at a version that is gone.

### Self-play rounds

Two rounds train the all-decisions model on a network playing itself, with σ = 0.03° of aim error on every
shot:

- **win-weighted** — every decision is weighted by whether its player won the frame (1.0 for the winner's
  side, 0.15 for the loser's);
- **break-weighted** — every decision is weighted by the **highest break** its player made in that frame,
  reaching full weight at 50 (so a decision that was part of a 40 break counts far more than one made in a
  frame that never got going). The frame's winner is not consulted.

Both write a self-play dataset, fine-tune the existing decision model from its weights, keep the old model
aside, and finish with a match between old and new — frames won are the acceptance for the win-weighted
round, and the break distribution is the thing to watch for the break-weighted one.

The export prints **each frame's highest break for both players** as it goes — `breaks 14 and 6` — and the
run's two best at the end, so a break-weighted round can be followed without reading the dataset.

A session that trained only a **stroke** has no decision model to continue. The round then borrows the
**deployed version's** decision model and its torch weights, copies them into the session as the starting
point, and says so in the log; if no version is deployed either, it stops with that reason rather than
starting and failing at the first command.

The studio itself needs only the Python standard library; the training needs `torch` and `coremltools` in
the interpreter you point it at, for example:

```sh
python3 -m venv AI/.venv
AI/.venv/bin/pip install torch coremltools
```

then put `AI/.venv/bin/python` in the *Python for training* field. The engine defaults to
`build/Snooker.app/Contents/MacOS/Snooker`; rebuild the app with `./Scripts/build-app.sh Release` first.

**If a run stops with `ModuleNotFoundError: No module named 'torch'`**, nothing is wrong with the dataset —
the *Python for training* field is on an interpreter that does not have the packages. The studio now starts
with the first training Python it can find (`AI/.venv`, a known venv, then the system Python), **refuses to
start a training run** with one that has no torch and says so in the log, and has a **Set up Python** button
that creates `AI/.venv` and installs `torch` and `coremltools`. The generated data is kept: pick **Train
candidate model** with the same session name and the export is reused rather than regenerated.

The computer player in `Sources/SnookerCore` plays by searching the real physics: it proposes shots, plays
each of them out in full, and judges the position it is left with. That judgement —
`ComputerPlayer.value(of:result:)` — is one small function of hand-written arithmetic, and it is the one
place in the player where a learned model can go. This folder is the pipeline that trains one, converts it
to Core ML, and measures whether it is any better.

**The honest headline: the network is a slightly better judge than the arithmetic, and it makes no
difference to how the player plays.** It predicts the points scored from a position better than the
arithmetic does, and ranks positions slightly better, but over 240 random positions playing with it is
level with playing without it. What that means and what to do about it is at the bottom of this file.

## The four steps

```bash
# 1. Play positions out and record what a position is worth. ~12 minutes for 400 positions.
Snooker.app/Contents/MacOS/Snooker --ai-export /tmp/train.bin --positions 400 --easy --seed 7

# 2. Train, and write the Core ML model. About 12 seconds on this machine's CPU.
python AI/train_value_net.py /tmp/train.bin /tmp/ValueNet.mlpackage --epochs 150 --hidden 128

# 3. See where Core ML would run it — the Neural Engine, the GPU, or the CPU.
Snooker.app/Contents/MacOS/Snooker --ai-model-plan /tmp/ValueNet.mlpackage

# 4. Play it against the player's own arithmetic, on the same positions.
Snooker.app/Contents/MacOS/Snooker --ai-compare --positions 80 --easy --seed 21 \
    --learned --model /tmp/ValueNet.mlpackage
```

`TMPDIR` has to point somewhere writable for Core ML to compile the model; outside a sandbox the default
is fine.

Two more tools, for the questions those four raise: `--ai-escape-check` plays the positions where the
player has nothing on out with the real physics, to tell "the search cannot find a shot that is there"
from "there is no shot to find"; and `--ai-model-plan` reports where Core ML would run each operation of
a model — the Neural Engine, the GPU or the CPU.

## What the data is

`--ai-export` lays out frames at random with `PositionGenerator` — whole frames are a poor diet, being
mostly the same break over and over in a game that is deterministic — and plays each one out with the
search player. For every position it was somebody's turn to play from, it records that position's
features and **the points that player went on to score from it before the table passed** — the thing a
value function is for: not who wins, not which shot to play, but what a position is worth to whoever is at
the table.

The file is `SNOOKERAI2`, a sample count, a width, then float32 rows: 152 features followed by five
numbers — that visit's return, the stroke's own points, the same return discounted, what the **player's own
arithmetic** made of the position, and which visit the sample came from. The features are written by
`PositionFeatures` and the arithmetic by `ComputerPlayer.positionValue`, so the file cannot drift from what
the player computes, and the extra columns are what let a training run choose between targets and measure
itself against the arithmetic instead of only against a guess.

The 152 features are, per ball (the cue ball, fifteen reds, six colours): is it on the table, where is it,
how far is it from the cue ball, can the cue ball see it, and how hard is the best pot on it. Then twenty
numbers about the frame: reds left, what is on, what has been nominated, the score, the break, whether the
striker is snookered, how good the best ball on is, how tucked up the cue ball is. Every one is scaled to
order one, and the whole vector is always from the point of view of the player at the table.

That is deliberately the *same information* the hand-written value function reads. The network is not
being asked to see something the search cannot; it is being asked to weigh what is there better.

## The network

A small dense network — 152 → 128 → 128 → 64 → 1, about 44,000 weights — with ReLU and Huber loss. It is
small on purpose: it sits at the leaves of a search that calls it some fifty times a decision, so it has
to be a fraction of a millisecond and a shape that Core ML can hand to hardware. The training script keeps
the weights from the **best held-out epoch**, not the last: the target is noisy, so the training loss goes
on falling long after the network has started fitting that noise. A tenth of the data is held out, and the
file is shuffled before the split — a dataset written position by position is full of runs, where a break
is twenty consecutive positions all worth something, and a statistic that reads the order will pick those
runs up as if they were signal.

The `--arch conv` option converts the trained weights into an equivalent network whose dense layers are
written as 1×1 convolutions (the script checks that the two agree to a thousandth of a point before
converting). It exists because of what the next section says: Core ML is supposed to favour the Neural
Engine for convolutions.

## Where Core ML runs it

**On the CPU, on this machine, for every version of this network that has been tried.** `--ai-model-plan`
asks Core ML's own compute plan which device each operation of the model would run on, and the answer has
been the CPU for:

- the dense network, 44k weights;
- a dense network an order of magnitude larger (512 hidden, 400k weights);
- the same network exported to take 64 positions at once;
- the convolutional version;
- a spatially-shaped convolutional network over the features as an 8×19 image.

That is not a misconfiguration. `computeUnits` is set to `.cpuAndNeuralEngine`, the model is an ML
Program in half precision, and the answer is the same inside and outside the sandbox — Core ML is free to
put the model on the Neural Engine and chooses not to. Its placement is a cost decision, and for a network
this small the fixed cost of handing work to the Neural Engine is not worth paying.

So the Neural Engine is available and unused. What changes that is a network with real work in it — and
the switch is one line (`MLModelConfiguration.computeUnits`), so a model worth putting there goes there
without anything else changing.

## Is it a better judge than the arithmetic?

`--target scored` (the default) against `--target discounted`, held out from training, with the arithmetic
the player already has measured on the same rows:

| what is predicting | error, `scored` | ranking, `scored` | error, `discounted` | ranking, `discounted` |
|---|---|---|---|---|
| the network | **1.85 points** | **+0.444** | **0.95** | +0.292 |
| the player's own arithmetic | 2.41 | +0.416 | 1.70 | +0.265 |
| always guessing the average | 2.74 | 0.000 | 1.40 | 0.000 |

The ranking is the column that matters, because the search only ever asks which of two positions is
better. The network is the better judge of the two, by a little; **discounting the return makes it a worse
one** (85% of discounted targets are zero), so the plain return is what is used.

### And after the cue action was made fallible

The player's cue is no longer exact: every shot it plays — in the search and on the table — is struck from
a line with a normal error on it (N(0, σ), where σ is the difficulty's: Easy 0.2°, Medium 0.1°, Hard
0.03°; see *A cue action that misses now and then* in the project README). A value function learned from a
player like that is learning a harder thing, because part of what happens from a position is now the
player's own cue action, which no feature of the position can predict.

**How fallible the player was is a feature.** `PositionFeatures` ends with the cue action's standard
deviation, because a position is worth less to a player who misses, and `--ai-error-range <low> <high>`
plays the dataset out with a different cue action for every layout so that the network has something to
learn it from. It does: on the held-out tenth, the target averages **1.78 points for the gentler half of
the cue actions and 1.09 for the wilder half**, and the network's error tracks it (1.88 against 1.21) —
and it ranks the gentler half better (+0.215) than the wilder one (+0.151), which is what a noisier target
should look like. One network therefore serves all three difficulties.

Retrained on 15,867 positions played by cue actions from 0.02° to 0.25° — where the target's mean is 1.37
points a visit and two thirds of positions are worth nothing — the numbers are:

| what is predicting | error | ranking |
|---|---|---|
| the network | **1.54 points** | +0.198 |
| the player's own arithmetic | 1.97 | **+0.202** |
| always guessing the average | 1.99 | 0.000 |

The network is still the better *predictor* and the two are level as *judges* — the gap between them, 0.004,
is a small fraction of the noise on a ranking of this size. In play, over 80 random positions a run at
Medium: +0.037 points a visit against a standard error of 0.22, twice; and at Hard, −0.19 against 0.43.
Level, exactly as it was before the player could miss, and as it was before that.

## Does it help?

The game is deterministic but not stable: two value functions that differ in the fourth decimal place
choose different shots and end up a hundred points apart. A single run of positions therefore says
nothing, and `--ai-compare` plays each position **twice** — once with the arithmetic, once with the
network — and compares the difference within each position.

Over 80 random positions a run, three runs, each position played twice:

| seed | the arithmetic | the learned value | difference | better / worse / identical |
|---|---|---|---|---|
| 21 | 4.00 points a visit | 4.04 | +0.04 ± 0.55 | 4 / 7 / 69 |
| 7 | 4.69 | 4.68 | −0.01 ± 0.32 | 3 / 3 / 74 |
| 99 | 3.78 | 3.55 | −0.23 ± 0.23 | 2 / 4 / 74 |

Pooled over 240 positions the difference is −0.07 points a visit against a standard error of about 0.17:
level. The network changes the player's mind in about one position in fifteen, and where it does, it is as
likely to be wrong as right.

Why so little, when it is the better judge? Because it is *only slightly* better — +0.03 of rank
correlation — and because a value function is not what the player is short of. What it is short of is
**shots**: on the positions where the search cannot find a legal stroke it fouls whatever the value
function says, and no amount of judging fixes a candidate that was never proposed.

## What would make it better

- **A better policy, not a better value.** The shots the search proposes are the ceiling: escapes are the
  weak place (see below), and a policy learned from positions like these could propose them where the
  geometry cannot.
- **Learn from the search, not just from the outcome.** The search already computes a one-ply opinion of
  every candidate; training the network to reproduce that (and then to exceed it) is the classical
  bootstrapping route, and it needs no new labels at all.
- **A bigger network, and with it the Neural Engine.** The models tried here are far too small for Core
  ML to bother with the Neural Engine. A network that reads the table as an image and the shots as
  candidates would be big enough to earn it.

## A bug this turned up

Comparing the network against the arithmetic meant writing the arithmetic down in one place
(`ComputerPlayer.positionValue`), and writing it down one place at a time showed that two of its signs
were the wrong way round: it **rewarded** leaving the opponent a good ball, and rewarded a foul that left
them one. It had been that way since the player was first written, and it is why the player's safeties
were worse than its potting.

With the signs right the player is visibly better: playing from the rack it pots 73% of its strokes
against 69%, and its highest breaks went from the mid-teens to 22 and 23. On the random positions the
change shows up as a different game rather than a better score — it plays far more safety, so there are
more empty visits — and it also **exposed where the search fouls**: 65% of the strokes it plays when
nothing is on end in a foul.

`--ai-escape-check` answers the two possible reasons for that — the search cannot find a shot that is
there, or there is no shot to find — by playing those positions out with the real physics:

| | |
|---|---|
| escape shots tried and played out | 1993, of which **39% were fouls** |
| and of those fouls | 291 hit a ball not on, 238 hit nothing at all, 171 potted the cue ball |

Asked the way that matters — **does any proposed escape end without a foul**, rather than does it reach a
ball on — 92% of the positions the player escapes from had a legal answer in the candidate list all along,
and it was fouling anyway, on shots that turn on a graze or that run across the mouth of a pocket. Three
changes followed, all of them in the project README: a 4 mm clearance margin, a line that has to keep out
of the pockets, and the thin cuts aimed past a ball's edge dropped. The escape fouls in play fell from
**61% of escape strokes to 22%**.

That is the third time in this file that measuring properly changed the answer, and the second time the
*measurement itself* was wrong. The earlier runs of this check asked whether a candidate would reach a
ball on, and printed a share of positions with "nothing legal on offer" that swung between 28% and 44% on
the same build: it was counting the wrong thing, and the swings were the position samples. Two attempts to
find *more* ways out — checking cushion routes using the cushion's measured behaviour instead of aiming at
its mirror image, and playing twice as many escapes out — each changed the answer at three decisions out of
286 and are kept only as switches (`ShotGenerator.Settings.cushionRoutes`). What mattered was proposing
*better* shots, not more of them.
