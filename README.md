# Snooker — a native macOS snooker game, written from scratch

A snooker simulation in Swift: original code, original physics, and a rules engine that
implements the **WPBSA "Official Rules of the Games of Snooker and English Billiards",
revised May 2022** (the rule book the game is written against, which is not part of this
repository). No third-party game code is involved.

You can watch the table from above, or stand at it: the **player's view** puts you behind
the cue ball in 3D, sighting down the cue, and you turn to face each shot the way you
would at a real table.

## Open it in Xcode

Open **`Snooker.xcodeproj`**. Three targets:

| Target | Kind | Contents |
|---|---|---|
| `SnookerCore` | macOS framework | the game logic: vectors, table, physics, rules, frame driver, player camera |
| `Snooker` | macOS app | the window, the SpriteKit HUD and the SceneKit table; links and embeds `SnookerCore` |
| `SnookerCoreTests` | unit test bundle | the 226 tests, linked against `SnookerCore` |

Press **Run** (`Cmd+R`) to build and launch, **Test** (`Cmd+U`) to run the suite. The
`Snooker` scheme is shared, so it works from a fresh checkout.

The same things from the command line:

```bash
xcodebuild -project Snooker.xcodeproj -scheme Snooker build
xcodebuild -project Snooker.xcodeproj -scheme Snooker -configuration Release build
xcodebuild -project Snooker.xcodeproj -scheme Snooker -destination 'platform=macOS' test
```

Or use the helper: `Scripts/build-app.sh [Debug|Release]` (it defaults to Release), which
leaves a double-clickable app in `build/Snooker.app`. Where this project lives inside a
larger folder there is also a `Play Snooker.command` beside it that does the same from the
outside; a clone has the script.

Requires macOS 13+ and Xcode (built and tested with Xcode 27 / Swift 6.4). The app builds
universal: arm64 and x86_64.

## Controls

| Action | Input |
|---|---|
| Aim | Move the mouse over the table (a ghost ball shows the first contact — the ball on, or the cushion the shot runs into, where the cue ball's centre would be when it arrives) |
| The pointer | In the player's view the **mouse is captured**: the pointer is uncoupled from it and hidden, and the aim and the cue are steered by the mouse's **own movement** (the event's deltas, from the device rather than from where the pointer was seen) — so the turn never runs out of screen, and the pointer is never in the way. **`Control` is the tap that takes the pointer and gives it back** — one tap for the pointer, the next for the mouse — and it is a tap, not a hold, so a screen wanting the pointer can be dealt with without holding a key down. **Nothing puts the pointer up for you, not even a question** — not the colour, the free ball, the foul, the re-rack, the new frame or the new game, and those last three are the ones most often asked with the frame already over: the questions are answered with the keys below, and the buttons are there for a player who has taken the pointer out to click them. It does come out of its own accord when the game stops being the frontmost application, and goes back where you left it |
| The control and the pointer | **The mouse steers only while the pointer is hidden.** With the pointer out it is a pointer and steers nothing at all: the view stays exactly where you left it, however far the pointer is moved, and the cue, the tip and the gaze are all left alone. That is the rule the capture is built on — hidden the mouse is the game's, shown it is yours |
| Power | Hold `S` and move the mouse: back draws the cue — as much as 400 mm of it — forward drives it through the ball, and the shot's strength is the speed the cue is travelling when the tip arrives. The cue moves at 0.35 mm a point of mouse travel, so the whole pull-back is about 1140 points of mouse and a push of about 9800 points a second is a full-power shot. Or press and hold the left mouse button, or `Space`, and release to strike (the meter fills over ~1.1 s): **the meter is the cue's speed**, its full power being the fastest a cue may travel, and the ball's speed then comes out of the strike — so a shot taken off centre is a softer one. A shot played that way is also carried through **for** you — see below |
| After the shot | The cue does not vanish with the stroke: it is a stick on the table, still in your hand. Keep `S` down and the mouse still moves it — the follow-through, a push, or pulling it clear — and the balls are answered by it if they run into it; touching a ball with it is a foul. The follow-through runs out at 250 mm from the middle of the ball (`FrameDriver.maxFollowThrough`, the mirror of the 400 mm pull-back), or at the cloth if a stood-up cue meets it first. **A shot played by charge is carried through by the game itself**, because the hand is on the button and not on the cue: the stick goes on at the speed it struck with — **the same speed the whole way** — for a length that follows the strength of the shot, from **50 mm** from the middle of the ball at the gentlest the meter will set to **250 mm** at full power (`FrameDriver.chargedFollowThroughLength`), and then stands where it stopped. The mouse does not drive that stick on — it may still take it **back** off the ball, which is the player's to do — and a shot played by hand with `S` keeps the hand's own follow-through, as before. **Standing up takes your hand off the stick and not the stick off the table**: whether you stay down on the shot or stand up (release `S`), the cue stays at the shot's own place while the balls run — standing up does **not** lay it at the ball — and it is still a stick the balls are answered by, only stopped. It is carried to the ball when the stroke is over, ready for the next one. Putting it away (`C`) is the one thing that takes it off the table: the player stands up with it and is then free to look and walk about while the balls run, and laying it again brings it back to the ball |
| Spin | Hold `E` and move the mouse over the cue ball's face: across for side, up for follow, down for screw back. Works down on the shot too — hold `S` and `E` together and the mouse is the tip's, with the cue left where it is. Or drag inside the cue-ball widget, bottom right. The tip returns to the middle of the ball after every shot |
| Swerve | Hold `B` and move the mouse up and down: the butt of the cue lifts and lowers, and the widget bottom right reads the cue's **own** angle — the elevation, from **level** right up to 90°, standing the cue on end and striking straight down. A cue held level is a level cue: the game does not hold it up for you, and finds it room where there is none (see *Cue room* below). Hold `S` with it (**S + B**) and the player is down on the shot while the cue comes up, standing up with it so their head stays above the cue. A lifted cue strikes *down* at the ball, so its spin tilts with the cue — set side spin with `E` as well and the cloth curves the shot into a swerve. The lift goes back down to level after every shot, like the tip. The aim line and the ghost are the line of the cue's own lowest angle: a swerved ball leaves them |
| Cue room | The cue is a stick 1400 mm long and it cannot pass through a ball, a cushion or the rail. It is judged as the body it is — 9.8 mm across the tip, 22 mm across the butt — and as the **stroke**, not just the pose: the tip travels from the ball out to the drawn place, and the stick has to be clear of every place it passes through. Where the player's own pose leaves it no room the game **settles** the cue for them: the butt comes up, no further than 10°, and past that the tip goes up the ball's face (which lifts the line of the stick with it); only if even that will not do does the butt go past the 10°. The cue is never taken off the ball and never drawn through anything. The player's own changes are stopped where the room runs out — the butt cannot be laid back into a cushion, and a tip that would carry the stick into something stops there — with one exception: a **spin change** that will not fit is found room for by the game, and the spin the player asked for is what is left on the ball. The butt comes up, no further than its **first cap**, 10°; at the cap the game stops standing the cue up and **lifts the tip** instead, further up the ball's face with the side the player asked for, which lifts the line of the stick with it; if that is not enough the butt carries on to its **second cap**, 30°, with the spin unchanged; and only past both is the spin settled to what fits, at the angle the cue has been left at. `B` (or `S + B`, down on the shot) still lifts the butt by hand as far as it fits |
| Colour on | When the ball on is a colour of your choice, **aiming at a colour nominates it**: a striker with the Blue in their sights is playing for the Blue, and the game takes that rather than making them press a button for something they have already said with the cue. The nomination follows the cue from colour to colour until one is named **by hand** — with the buttons or `2`-`7` — from which point the choice is theirs and looking about does not change it, however far the cue wanders. The colours stay on the buttons until the stroke is played, either way, so you can always change your mind. (A cue pointed at a cushion, or at a Red, nominates nothing and leaves the last nomination standing.) |
| Strike without choosing | Allowed, and it costs you: a stroke played with the cue on **no colour at all** — at a cushion, or at a Red — is a seven point foul and a miss (Rule 11(d)(v)-(vi)). This is the case the aim's own nomination does not reach: with the cue on a colour there is nothing to declare, because the aim has declared it |
| Place cue ball | Click inside the "D" when in hand. It is not a commitment: press `P`, or click the ball itself, to pick it up and put it down anywhere in the D again — the cue ball is in play only once you strike it. (`P` answers **Play from here** while a question after a foul is on the screen; with the cue ball in hand and no question, it picks the ball up) |
| Colour on by number | `2` Yellow, `3` Green, `4` Brown, `5` Blue, `6` Pink, `7` Black — the values from Rule 1(a). They pick the colour being nominated, or a free ball standing in for the ball on, and do nothing else while a colour is being chosen; away from that they are the eye-level keys. **`0` is a free ball answered with nothing** — the keyboard's half of the **No free ball** button — and is taken whether or not that question is up, so it never falls through to be a beep |
| Change view | `V` (player's view) / `T` (top-down) |
| Full screen | `F` — the window fills the screen, and `F` again brings it back. The View menu's **Full Screen** is the same switch. The picture re-lays itself out to whatever size the screen is |
| Walk about | `C` puts the cue away — and lays it on the table again. With the cue **away** the player is only walking about: the **arrow keys** walk them, up and down along the way they are looking and left and right across it, the mouse looks about, and their body is kept clear of the table however hard they walk at it. Hold **`Z`** and the mouse walks them instead — forward and back along the way they are facing, and across it, the look left alone — as far as the hand moves. That works **while the balls run** too: stand up from the shot (release `S`), put the cue away, and you are free to walk around and watch the balls from wherever you like. With the cue **laid** the player stands by the cue and the mouse swings the camera round it, as before |
| Eye level | `2` standing at the table (the default), `3` raised (`1` stands you up too; the View menu's **Eye Level: On the Shot** is `⌘1`). Getting down over the shot is not a key: hold `S`, or a charge, and the player bends down to the ball. Hold `X` to duck the eye down over the cloth — 150 mm above the bed — and let go to come back up |
| Fine aim | Arrow keys (with the cue laid, or down on the shot; with it put away they walk instead), or hold `Shift` and move the mouse |
| Fine spin | Hold `Shift` with `E` for a quarter of the travel |
| Fine aim while down | Hold `Shift` with `S`: the mouse goes back to the aim, at the fine setting — across to turn, up and down to raise and lower the gaze — while the cue stays where it was drawn |
| Aiming aids | `G` steps round **three** sets of them. None at all; then the **line of aim**, which runs from the cue ball to where the shot first meets something, with the **ghost ball** sitting at the cue ball's own centre there — on the ball on, or, aimed at a cushion with nothing in the way, at the point on the cushion the cue ball will reach; and then that line **with the line the ball being met will take**: a solid 400 mm stripe **6 mm across** — twice the baulk line — painted on the cloth and drawn from that ball's middle along the line of centres, which is the way the cue ball is sending it. That line is **green** while the ball it belongs to is one the cue ball may strike first, and **red** when it is not — aiming at a ball that is not on is a foul, and the colour says so before the stroke is played. The menu item shows which of the three is on |
| New frame | `N`, which asks first — **Start a new frame** or **Keep playing** — while the frame is still on. `N` sits next to the other keys and the frame in progress is worth more than a slip of the hand, so nothing is thrown away until you say so: no ball moves while the question is up, and no stroke can be played over it. Answering it yes **ends the frame in progress by concession**: the player with fewer points is the one who concedes it, so it counts for the other on the frames won, and the next frame is racked. With the scores **level** there is nobody behind to concede, so the frame is **re-racked** instead — the same frame, from the balls on their spots, with nothing won. Either way the question says which of the two it will be before it is answered. With the frame already **over** it does not ask, and nothing is conceded: the frame is finished and a new one is what `N` was pressed for, so it just starts one — which is what the frame-over screen's own "press N for a new frame" means |
| Re-rack (stalemate) | `R`, which **asks first**, exactly as `N` does: **Re-rack the frame** or **Keep playing**. A re-rack nullifies every score in the frame (Section 3 Rule 17) and the frame in progress is worth more than a slipped key, so nothing is thrown away until you say so — no ball moves while the question is up and no stroke can be played over it. (While a question *after a foul* is on the screen, `R` is **Replace balls, offender plays** instead — see below) |
| After a foul: play from here | `P` — the non-offender plays from where the balls lie (Rules 10(f), 12) |
| After a foul: offender plays | `O` — the non-offender asks the offender to play again from there (Rules 10(h), 13) |
| After a foul: replace the balls | `R` — the balls go back and the offender plays again from the original position, where the rules leave that open (Rules 10(i), 14(b)) |
| Take the answer back | `U` — after answering **Play from here**, until the next stroke is played, puts the question back exactly as it was asked, so you can choose something else. The penalty stands: it was the offender's |
| Concede frame | `Shift`-`C` (plain `C` is the cue, put away or laid on the table, which is the handier key) |
| Claim the frame | The **Claim the frame** button, when the Black is the only ball left and the **striker** is more than seven ahead (Section 2 Rule 1(b)). They are not made to take it, and it is never taken for them: playing on is their right, and the first pot or foul then ends the frame with the scores deciding it (Rule 4(a)). The **other** half of the rule is not a claim at all — when the Black is the only ball left and the **non-striker** is the one more than seven ahead, the striker needs snookers to win and the frame is **awarded** to the non-striker there and then (Section 2 Rule 1(c)). Nobody presses anything for it: the game notices the position the moment it arises, ends the frame, and counts it for the opponent, with the referee's own line in the log to say why |
| Cancel a shot | Let go of `S`: the cue goes back to its rest position and the stroke is never played |
| New game | `Esc`, which asks first — **Start a new game** or **Keep playing** — and `Esc` again puts the question away, exactly as `N` and `R` do, so nothing is thrown away until you say so: no ball moves while it asks, and no stroke can be played over it. Answering it takes the match back to its **first frame**, with the frame count, the frames won and both scores at nothing. Whatever is in hand — a charge, or a cue drawn back — is put down when it asks |
| Help | `H` opens and closes a panel with the whole of the controls on it, in either view. The game plays on behind it. The screen keeps only the one line of its own: **Press H for help**, in the top left corner, with the view the player is looking through — **3D — standing**, or **Top-down** — in the top right |
| Sound | `M` mutes the table and `M` again brings it back (the View menu's **Mute Sound** is the same switch). Every contact sounds where it happens and at the volume its own speed earns it: the cue on the ball, ball on ball, a ball on a cushion or a jaw, a ball on the throat of a pocket, a ball coming down on the wood of the rail, and a ball forced off the table landing on the floor. A ball dropping into a pocket is silent |

Two players share the keyboard ("hot seat"). Buttons appear for decisions the rules
require: colour nomination, free-ball nomination, and the choices after a foul or a miss.

### What the screen shows

Across the top: the score board — each player's name, their score and the frames each has won, with
the player at the table marked by the triangle on their own name — and, above it, the frame number.
Down the left under it are **Break**, **Ball on** and **Points remaining**, and below those, when it
applies, the caption **Snookers required**: the player at the table is further behind than the points
still on the table, so only fouls will bring them back. (Being behind by *exactly* what the balls are
worth does not earn the caption — that is a frame to be won on the balls.) The referee's call and the
last few lines of the game log are under those, at the foot of the screen, with the strength meter
and the spin widget. The log carries the frame's own news — the fouls, the referee's calls, and a
**break said once, when it is over**, and only when it came to anything: the break itself is read as it
is made from the readout above, so a line for every ball potted is a log with the frame lost in it. The
help hint is in the top left corner and the view in the top right.

## The player's view

The game opens in the player's view: a real 3D table seen from behind the cue ball, with
the cue in shot. The camera is the player rather than an observer: the eye sits **directly
above the line of aim** — the cue is always straight below it, running away up the middle
of the view — at the height the player stands at, coming down to the ball only to play, and
the gaze runs straight up the line of aim. Moving the mouse turns the player around the cue ball — right turns right, left
turns left. The view follows the mouse's *movement* rather than where the pointer has got to,
and the **mouse is captured** while it is the game's: the pointer is uncoupled from the mouse
(`CGAssociateMouseAndMouseCursorPosition(false)`) and hidden, and the mouse's own movement is the
whole of the control. So there is no edge to run into and no limit on how far round you can turn — two
window widths of travel is one full circle, and you can go round and round, and the pointer is never
in the way of the view. Nothing about the pointer is the control: the aim and the cue are steered by
the mouse's **own movement**, the event's deltas, which come from the device and not from the place
the pointer was seen at — which is why there is nothing to recentre and nothing to see, and why **the
pointer can be taken out at any time without the view so much as twitching: the mouse steers only
while the pointer is hidden**. `Control` is the tap that takes the pointer and gives it back — one tap
for the pointer, the next for the mouse — and it is a tap and not a hold. Nothing puts the pointer up
for you, not even a question: the questions are answered with the keys, and the buttons are there for
the player who has taken the pointer out to click one. It comes out of its own accord only when the
game stops being the frontmost application, and it goes back where you left it. `Shift` sights finely,
a tenth of the travel per degree, and the arrow keys nudge it the same way round.

The way round the two axes are read is **learned once and then kept**. The mouse's deltas and the
pointer's own places come from different parts of the system, so rather than assume that a delta one
way is a movement that way, the game reads the sign off the first movement where the two can be
compared. Only a movement the pointer could have made is believed: a place that has jumped further
than the mouse itself moved was moved by something else. And the pointer's places are not believed at
all for a moment after the window changes size, because the same point on the screen is a different
place in a scene that has just been resized — which is what taking the window full screen does, over
half a second of animation. Learning the sign from across that is how the controls come out upside
down, or back to front; the sign is a property of the device, so once the two are known they stay
known, and nothing a resize throws at them can turn them round.

The cursor is taken away by **asking again on every frame** the mouse is the game's, rather than once
at the capture: a hide can be overtaken by the unhide that went with the last release, arriving late,
and a cursor left standing in the middle of the window with the mouse still captured is the very
thing the capture is there to prevent. The asking is counted, and past the few the game keeps in hand
each new hide is answered by giving an older one back — so the count stays bounded and never reaches
nothing while the mouse is captured — and giving the mouse back gives every one of them back, so the
player has their cursor again.

Two keys take the mouse off the aim for as long as they are held, so that lining the shot up and
playing it are separate jobs:

- **`E` — the tip on the ball.** The mouse moves the contact point of the tip on the cue ball's
  face: across towards the striker's own right, up towards the top of the ball for follow, down for
  screw back. The tip can be put **anywhere on the ball**, out to its edge; only the ball itself stops
  it, because further out than a radius is not a contact. The cue-ball widget in the corner shows the
  tip **exactly** where it is — the white ball is the cue ball at its own scale, drawn at twice its
  old size, and the red dot sits at the tip's true offset. A **vertical and a horizontal hairline,
  dashed, cross at the middle of the ball**, so that the place the offset is measured from is plain to
  see. It draws two thin solid lines as
  **guidance, not a fence**: the boundary where a strike would leave the ball able to be caught by the
  cue and called a second hit (`PhysicsWorld.spinRange`), and the leather's own grip
  (`PhysicsWorld.cueTipOffsetLimit`), past which the tip slips and gives no more spin. Both redraw as
  the elevation moves; see `spinRange` for the physics. Spin does not carry over from one shot to the
  next: the tip goes back to the middle of the ball as soon as a stroke has been played, so every shot
  starts from a clean cue ball.
- **`S` — the cue action.** The mouse moves the cue itself, linearly: back draws it away from the
  ball, forward drives it through, and the strike is played as the tip comes into the ball. While it
  is held the mouse can be handed to either of the two finer jobs: with `Shift` it goes back to the
  aim — finely, at a tenth of the travel, across to turn and up and down to raise and lower the gaze —
  and with `E` it goes to the tip on the ball, the cue staying where it was drawn. So, down on the
  shot, hold `S` to be there, `Shift` to sight it, `E` to set the spin, and the mouse alone to draw
  the cue. Wherever the tip is on the ball, that is where the cue is drawn to: with spin set it
  meets the ball off centre — up to half a ball to either side, or up and down it — always on the
  striker's own right, whichever way round they are facing, leaning in from the hand at about half
  a degree, which is the same lean that makes a ball squirt away from the side it was struck. The
  power meter fills with the shot as the cue moves, and the cue in the 3D view stands where you have
  drawn it. Let go of `S` without pushing through and the shot is not played: the cue returns to its
  rest position. Nothing is struck until the cue has been drawn back at least 20 mm, so a twitch of
  the mouse while lining up cannot play the shot — that pull-back is only there to arm the stroke,
  it does not set the strength (see below).
  The push **through** the ball is the follow-through, and it has a limit: the tip may be carried no
  further than **250 mm** from the middle of the ball the stroke was played at — the mirror of the
  400 mm pull-back (`FrameDriver.maxFollowThrough`) — or stops at the **cloth** if a stood-up cue
  meets it first. A level cue in the open is stopped by the 250 mm; a cue stood up at 10° meets the
  cloth at about 150 mm, and one at 30° at about 50 mm.

**How hard the shot is** is the speed of the *cue* when the tip arrives, not how far back it was
taken, and where on the ball the tip lands. **Both ways of playing a shot set the cue's own speed** and
nothing else: the hand's speed for a shot played with `S`, and the meter's fraction of `maxCueSpeed` for
a charge. Everything the cue ball does comes out of that and the point on the ball the tip is striking —
`FrameDriver.ballSpeed(fromCueSpeed:tipOffset:)` — so a shot taken off centre sends the ball away slower
as well as turning it, and no path sets the ball's speed alongside the cue's. That speed is read as the
running **average of the push**
over about 25 ms (`FrameDriver.cuePushAverageSeconds`), not as the one frame's mouse speed: a delivery
is a run of frames and a real hand jitters a millimetre or two either way, which on the frame the tip
meets the ball would be a hundred mm/s or more of shot. The average is started afresh the moment the
hand turns from drawing back to driving forward, so a push is never diluted by the backswing before
it, a steady delivery is worth exactly its own speed, and a one-frame push — which has no jitter to
average — is worth exactly what it was. Only the *speed* is smoothed; the cue's place under the mouse
is still the hand's, so what is drawn is what was asked for. The tip is a springy point on the end of
a heavy stick, far heavier than the ball, so the cue does not budge on the strike: the ball is
answered as a collision with a body that does not move, and a centre-ball hit sends it away at
**1.75 times the cue's speed** — the tip's own approach, and three quarters of it again for the
spring (`1 + e`, the leather's restitution being 0.75). Hitting off centre spends part of that
impulse on spin — the ball turns, the contact point moves away with it, and less is left for
travel: half a radius off centre leaves the ball at about three fifths of what a centre hit would.
The spin comes out of the same impulse, at `omega = (5/2) v k / r`, which is the formula the
physics applies.

So the same flick of the mouse plays the same shot however far back the cue was drawn, and a slow
lazy push plays a soft one. The mouse travels 0.35 mm of cue per point — down from the 0.9 mm a point
the cue action began with, for a finer cue action — so a brisk push, 1000 points a second, call it, is a shot of
about a tenth power, and full power takes a real snap of the mouse: the cue has to be moving at
3.4 m/s, and at a third of a millimetre a point that is a push of some 9800 points a second. The cue's
speed is capped there, at what a
player's hand can do and at what sends a centre-ball hit away at the fastest shot in the game.

**The player is standing at the table by default**, outside it at the back of the cue, and gets down
over the ball to play. Taking the cue up — holding `S` for the cue action, or holding a charge —
brings them down to the sighting level, and the stroke stands them up again once the balls have
stopped. The camera is *moved* between the two rather than snapped between presets: standing and down
on the shot are the same position solved from different numbers, so the game interpolates the
stand-off, the eye height, the gaze and the field of view between them, about a third of a second
each way. A gaze the player has changed by hand rides along with the body rather than being
overwritten. **A lifted cue takes the head with it**: the sighting eye sits 209 mm above the cue
where the eye is, and when the cue is stood up for a swerve — `S` with `B`, so the player is still
down on the shot — the eye rides up the same angle and the gaze tips down with it, so the player
stands up over the ball looking along the cue rather than over it. At 45° they are all but standing.

**The player can walk about the table, and the cue can be put away.** `C` lays the cue on the table —
pointing from where the player is standing at the cue ball — or puts it away; with it away the player
is only walking, and the **arrow keys** walk them: up and down along the way they are looking, left
and right across it, at a stroll of 0.9 m a second, while the mouse looks about — or `Z` held puts the
mouse on their legs, walking them as far as the hand moves with the look left where it was. Their **body is a
250 mm circle that is never allowed on the table**: walking at it stops them at the edge of the wood,
and walking at it sideways slides them along it. The camera stands over their feet, at the standing
eye height.

With the cue **laid** — and down on the shot — the camera goes back on to the line of the cue, which
is the circle the player walks as they swing the cue: `standOff` behind the ball, *or as far back as
the table makes them stand*, whichever is further, so shooting across the table they stand right at
the edge and shooting up it they stand off the end. Down on the shot the camera may come **inside**
the table, but no further than a player leaning over it could look: the eye comes in over the cushion
while the waist stays outside, so **450 mm of the eye-to-waist reach is a limit and not a
distance** — a ball near a cushion needs none of it, and a ball out in the middle takes all of it.
And the camera is always **exactly above the cue**: when the stand-off has to give, it gives *along
the line of the cue*, standing the player further back, rather than shifting the camera sideways.

| Key | Eye level | Eye height | Stand-off |
|---|---|---|---|
| — | On the shot, sighting along the cue (automatic); with the cue lifted the head rides it and the eye goes up by the same amount — 401 mm at 15°, 593 at 30°, 855 at 45°, the rise topping out there | 235 mm above the cloth, and 209 mm above the cue where the eye is | 620 mm behind the ball |
| `2` | Standing at the table | 810 mm | 1080 mm |
| `3` | Raised, over the whole table | 1790 mm | 1760 mm |

The player stays put while the balls run rather than walking after them, and when the cue
ball is in hand the camera drops back to a standing view of the "D" so the whole of it is
on screen to click into. Placing the ball casts the click onto the cloth from where the
player is standing, rather than reading the screen position as a table position.

In the player's view the top-down table shrinks to a plan in the corner of the window, so
the angles stay readable while you are behind the ball. `V` switches back.

### How it is drawn

`Table3D` builds a SceneKit scene shaped like a real table, wrapped around the measurements
the rules fix. Only the playing area, the balls, the spots and the mouth of each pocket
come from the rule book; everything else is furniture, and the cushion nose sits exactly on
the boundary the rules measure the playing area to. The cushion's section — nose height, the
5 mm of square band above it, the 65° face and the 3 mm round over the nose — is `Table`'s,
and both the drawing and the collision in `PhysicsWorld` read it, so what is drawn and what is
played on are one shape.

The shape is laid on the table as paths, which is how the pockets can be cut properly. Where a path
is *laid flat* it is an `SCNShape`, extruded square to the cloth; where a solid's **section** has to
be right — the cushions' square band and undercut, the jaws, the wood — it is built as a mesh of its
own, because SceneKit fills a concave path with its convex hull and takes the shape away. The cloth,
the slate and the markings are flat paths and stay that way:

| Part | Shape |
|---|---|
| Cloth | The bed, cut away at each pocket's hole and nowhere else: it runs on into each throat under the cushions and the rails, which stand over it |
| Slate | The whole footprint, with each pocket's hole cut through it |
| Cushion | One section swept along each run, built as a solid of its own. The side is cut back under the nose at 65° to the cloth, so the nose overhangs its own foot by 16.9 mm; the top of that undercut is the **nose**, 33.3375 mm up; and on top of the nose the cushion carries a further **5 mm of plain band**, standing **square to the cloth**, so the face turns upright above its own lean and the cushion's top is 38.3375 mm. Every edge of that section is **rounded over**: 3 mm at the top, where the square side turns on to the flat, and a 3 mm fillet at the nose, where the square side is carried tangentially into the lean — so the face has no crease left in it anywhere, and only a stretch of the square band is left standing flat between the two. The **top is level** the whole way from the face back to the wood. The run stops where the jaw's round begins, and the round of 50 mm radius carries it into the pocket, carrying the same section: the side stands square above the nose and leans at **65° in the direction square to its own foot** below it, so a corner jaw and a middle pocket's are cut alike, and neither is ever left pointed. A jaw and the run it was cut from are **one surface with no round between them**: the round on the face is the same the whole length of the run and carries straight on round the jaw, with no easing out at the ends, and the edge where the two solids meet is left square on both — so the top is flat on the join line and the leaning face meets its own continuation with nothing to show. The run is carried half a millimetre on into the jaw, which is buried inside it, so the two meet flush rather than face to face, and that would flicker at a grazing angle. The cushion stops on the **line the wood stops at**: it does not run on under the rail by so much as a millimetre. The geometry probe fires at every one of those joins and reads the top back off the render to check it |
| Rail | 95 mm of wood behind each cushion: a frame with the pockets cut into its inner edge, wrapping round the outside of each hole, its four corners taken off in the plan with a 26 mm radius. Its top is **level with the cushion's** and its edge lands **exactly on the line the cushion's top ends at**, so the two meet on one line — there is no strip of wood standing proud of the rubber and no strip of it buried under it. A step here is *visible* whether it is wood above the cushion or a chamfer across it: two edges at different heights read as the rail being out of line with the cushion, which is the seam this shape exists to avoid. The wood's **outer edge** — the arris running right round the table — is taken off with a wide **15 mm round**, so the frame's rim reads as a bull nose rather than a bare edge, and that round runs on across the cuts between the pieces: those cuts are buried between two pieces and both carry the same ramp up them. The wood's edge **beside a pocket's cut** keeps the cushion's own 3 mm round instead, so the frame's rim carries straight on into the jaw beside it, and the line the wood stops at is left square, since the cushion stands against it there. It is one round-over routine that draws them both: the radius belongs to the point of the outline rather than to the solid, and the sweep through the section reads each edge's own radius at the height it has reached. Its **cut round each pocket leans at the cushion's own 65°**: square to the cloth over the back of the rail, and carried out under the jaws' own undercut round the throat, so that at the top of the wood the cut is the mouth's width and at the level of the cloth it is the rim of the hole. A jaw's face and the wood's edge beside it are then one surface, the wood leaning away exactly where the jaw does. The width is set with the pockets: the land left between a hole and the outer edge is what the rail's own width has to leave, and 95 mm of it keeps the land at a middle pocket 12.9 mm on the pocket's centre line and keeps about 22 mm at a corner. SceneKit will not draw the whole frame as one path once the pockets' cuts are in it — it fills the table — so the wood is laid down as **one piece for each pocket**, each running from the middle of the stretch of cushion before that pocket to the middle of the stretch after it, with the pieces meeting along straight cuts across the wood |
| Pockets | A round hole wider than the mouth — the passage's width plus the jaws' own setback on each side, and a millimetre of clearance past each foot again, 111.091 mm, and 20 mm wider again at the four **corners**, 131.091 mm — cut through the bed and dropped away, lined in black, with the rails cut back to meet it |
| Frame | The body below the slates, carried on **six legs**: round pillars **150 mm across**, three down each long side — the two ends of the table and the middle of it, because a table 3.57 m long wants carrying in the middle as well as at its ends. Each pillar is set in 90 mm from the outside of the frame, so the wood covers the top of it and the leg stands well in under the table, and it runs from the underside of the frame **down to the floor**, a few millimetres into the slab so the foot is buried rather than laid on the surface |
| Shadow | The table's shadow on the carpet, **drawn rather than cast**: a soft black shape the size of the table's own plan with a 500 mm penumbra, a couple of millimetres above the carpet, half strength in the middle and unlit so that it takes no light of its own — see *The table's shadow* below for why there is no light in this room that can cast it |
| Floor | The room's floor, and the surface a ball forced off the table lands on: a 40 mm slab whose face is at `Table.floorHeight`, 800 mm below the cloth, **three table lengths by four table widths** — 10707 x 7112 mm — centred under the table, covered in a light grey **carpet**: a loop pile a little over a centimetre from loop to loop, tiled square on the floor whatever size it is cut to (`carpetMaps`), and **wholly diffuse** (the renderer's `lambert` model, which has no specular term at all). The only things in the room that shine are the balls and the polished wood, and a sheen on a carpet under lamps reads as ice; the pile's relief is in the normal map, which is where a surface that takes no specular keeps whatever surface it has. The room's own light is a flat wash rather than the plates, which hang over the cloth and reach a couple of metres past it and no further — without it the carpet came out near-black, which is not a floor |
| Markings | The baulk line, the "D" and the six spots, chalked on the cloth at the rule book's positions |

Each pocket is cut as **a round hole, wider than the mouth**, down the 45° diagonal at a corner and
square to the cushion at a middle pocket, with **the table's surface running on into the throat
around it and cut away only at the hole itself** — so the surface forms part of the hole. The hole
sits far enough out that it reaches the line the rails stop at, so the wood meets the pocket and no
bare slate shows between the two, and a ball is potted when its centre is over the hole: until then
it is still on the table, in the throat between the jaws.

**The hole is wider than the throat, and set out well past it.** Its diameter is the passage's 78 mm
plus the jaws’ own setback of 15.5455 mm — the cushion's undercut measured at the level of the cloth,
33.3375 / tan 65° — on each side, and then `pocketHoleClearance` of 1 mm past each foot again, which is
111.091 mm. Without the clearance it would be 109.091 mm, exactly the passage's width where the jaws'
feet meet the cloth; the clearance puts the rim a millimetre outside each foot, where the jaw's own
lean overhangs it and the extra cloth's edge is tucked out of sight. And the **corners'** holes are
opened out by `cornerPocketHoleExtra` of 20 mm more than that again, 131.091 mm, because a corner takes
the ball off two cushions at once and the wood round it has the room to give; a middle pocket's has not,
its rim already being within 13 mm of the table's outer edge, so it is left as it is. Its middle is carried
`passageLength` down the passage and then out along the
outward of **every cushion the pocket is cut in**, by that setback plus a further `pocketHolePull` of
20 mm: a corner is cut into two cushions, so its hole moves 35.5455 mm in x and 35.5455 mm in y — 50.3
mm along its own 45° diagonal — and a middle pocket's 35.5455 mm square to its own cushion.

That last figure is the one that sets how a pocket plays. The cloth carries a ball until its centre
crosses the hole's rim, so pulling the hole out moves the drop further into the throat: a middle
pocket's rim now sits **19 mm** beyond the mouth (the 20 mm pull less the millimetre the hole is cut
past the jaws), and a corner's rim **52.6 mm** along the diagonal — the same pull and clearance, with
the corner's own 20 mm of extra hole coming off the near side of it. The corner still takes a ball run
along the cushion: the physics probe rolls one in and it is potted with its centre 37 mm inside the
hole's rim, as a middle pocket takes one rolled
straight up the table (29 mm inside the rim).

**The wood is cut to the throat, not to the circle, and the cut leans with the jaws.** The rail's own
cut round a pocket is a straight throat closed by the hole's semicircle, run out along the way the
jaws' throats run — `pocketSlot` builds that outline, and the geometry probe measures its run, its
direction and its lean. So the wood's edge round a pocket runs the way the jaw beside it runs: square
to the cushion at a middle pocket, along the 45° at a corner. A circle through the same two points
would cross the line the wood stops at at a quite different angle — 57.5° at a middle pocket — which is
what the rail used to be cut to, and it read as the wood's edge being out of line with the cushion it
runs behind.

The cut carries the cushion's own profile, round-overs and all. It **stands square** down the 5 mm band over the nose —
which is why the wood is 38.3375 mm high there, level with the cushion — and **below the nose it leans**,
carried outwards at the cushion's own 65° to the cloth, which is the undercut a jaw carries, over the
rest of the depth. So at the **top of the wood** the cut is the **mouth's** own width, 78 mm, and lands
on the line the jaws' noses stand on; at the **level of the cloth** it has opened to exactly the **line
the jaws' feet stand on**, 109.091 mm — the hole itself is cut 111.091 mm, a millimetre past each foot, so
its rim runs just outside the wood's edge and under the jaw's own overhang, and at a corner 131.091 mm
(`cornerPocketHoleExtra` again), so there the rim runs 11 mm past the foot; and the cut goes on
widening to the bottom of the slab. A jaw's face and the
wood's edge beside it are one and the same surface — square to the cloth over the band, leaning at 65°
under it — rather than the wood standing square to the cloth the whole way down where the jaw leans
away from it. The two ends of the cut are the exception: they stand on the line the wood stops at,
whose face is square, so their feet slide along that line instead of leaning across it.

Every one of those sections is swept from the top down through a run of levels — the round-over, the
band, the fillet at the nose and the lean — and the wall is one surface: the fillets are tangent to
the flats either side of them, so no crease is left in it to be seen.

That is why the wood is **built** as a mesh rather than extruded. A flat path can only be pushed out
square, so each piece of the rail is laid down as a solid whose outline carries, at every point, the
direction its side is set back in and how far: nothing at all along the back of the rail and the
table's own edge, and the jaw's undercut round the throat. The faces are triangulated by ear clipping
— the throat is a bite out of the outline, so it is not convex — and a point **repeated** in the
outline is dropped before the ears are clipped: a doubled point lies on the edge of every ear at that
corner, so no ear is ever found there and the face comes out with a bite of its own missing.

SceneKit will not draw that cut in a single path: an extruded path carrying one pocket's slot is fine,
and the circle at every pocket is fine, but **two or more slots at any sampling, chamfer or winding
rule, and the correct corner outline especially, and it fills the whole table with wood**. So the
frame is laid down as **one piece for each pocket** — `railPieces` builds them, and the geometry probe
measures that they meet. A piece is the wood between two rays from the middle of the table: its inner
side is the line the wood stops at, with that pocket's own throat cut into it, and its outer side is
the table's own outline between the two rays, taken the near way round — past the corner the piece
stands at and never further. Each pair of neighbouring pieces shares a whole cut, so the six of them
tile the frame with nothing left over and no seam to see.

That ray is also why the pieces have to be cut the way they are. The table's own outline is straight
along each side, with points only where a corner turns, so the end of a piece has to be *put* on the
run rather than looked for among the outline's points: the nearest point of the outline to a piece's
end is a corner of the table, and a piece cut to that comes out as a bow tie that SceneKit will not
draw at all.

The outline is walked for its points rather than used as a path, and **each of its arcs begins with a
step at the very place the line before it ended**, so the walk meets that place twice — three times
where the outline closes on itself. Two points in a row at one place leave a step of no length between
them, and a step with no direction of its own will not carry a round-over: the section read off it came
out flung to the far end of the rail, which left the rim square over a good part of the table. A repeat
is therefore dropped as the piece is built, and the section-builder refuses to cross a step of no
length at all, so a repeat can never do that again.

Each jaw is a **cut in the cushion with a round of `Table.jawRadius` — 50 mm — whose axis is
perpendicular to the table**, so the cushion is the same height the whole way along and only its
plan is cut. The round is tangent to the cushion's straight face at one end and to the pocket's
throat at the other, so it is the round surface that joins the two, and it is the same circle
the ball bounces off: what is drawn and what is played on are one shape in plan. In section the
jaw's side carries the cushion's own profile — square to the cloth over the 5 mm band above the nose,
then its undercut, its own depth behind the nose — the whole way: round the round, down the throat and
into the wood. A jaw is cut with the cushion, and the cushion is one profile along its length, up the
band and down the lean — see below.

The cushion's side is **cut back under the nose**: the face leans out at 65° to the cloth rather
than standing square, so the nose overhangs the cushion's own foot by 16.9 mm — and **above the nose
the face turns upright**, 5 mm of cushion standing square to the cloth, which is the band that makes
the cushion 38.3375 mm through instead of 33.3375 mm. The band is the same the whole way along the
cushion and round into each jaw: the lean finishes at the nose and the face goes straight up from
there, so nothing about the cushion's shape turns over the top. **The top is level** at 38.3375 mm from
the nose back to the wood, and the jaws are cut with the same cushion, so the top runs into a jaw
without a step between them. The **wood of the border is level with it** — the same 38.3375 mm, one
surface all the way round — and its edge lands exactly on the line the cushion's top ends at, with no
bevel and nothing running on under the rubber: cushion and wood meet on **one line**, at one height,
rather than the two edges at two heights that a raised rail gives. The physics still measures the
playing area to the nose itself, where the rules measure it, so the table plays to the same rectangle.

A jaw is cut with the same cushion, so its side leans with the cushion's own undercut — the whole way,
round the round and down the throat to the wood. It is **which way it leans that differs between the
two kinds of pocket**, because the two cuts do.

**The lean is taken square to the jaw's own foot**, which is what a cushion's undercut is: 65° to the
cloth, over the height of the cushion, measured in the direction the side is set back in. The foot is
therefore the jaw's own outline carried inwards by the undercut along that perpendicular — at a
corner, the round of the jaw gives a foot that is **the round again, concentric**, 16.9 mm in at a
radius of 33.1 mm, and the straight throat gives a foot that is a line **parallel** to it. The radius
runs into the throat tangentially where the outline does, so the two parts of the foot meet
**tangentially** too, and the curve where the jaw meets the cloth is the cushion's own cut: straight
along the cushion's face where it leaves it, the round of the jaw, and straight along the throat.

A corner and a middle pocket differ only in the way their outlines run — a corner's throat runs at 45°
across the table, a middle pocket's along the cushion's own outward — and not in the angle: the lean
is 65° on both, because it is taken from the jaw's own foot each time rather than from the table. (The
56.5968° a corner jaw used to be leaned at, which is this same surface read *along* the throat rather
than across it, is gone.)

**The hole is cut past the foot.** The foot crosses the level of the cloth 15.5455 mm in from the
nose — the undercut over the 33.3375 mm **from the nose down to the cloth**, rather than down to the
bottom of it — so the
passage is 78 + 2 × 15.5455 = 109.091 mm wide where the jaws meet the cloth, and the hole is cut
`pocketHoleClearance` of 1 mm wider than that on each side, 111.091 mm, so its rim stands a millimetre
outside the foot rather than exactly on it — and at a corner `cornerPocketHoleExtra` of 20 mm more
again, 131.091 mm, so there it stands 11 mm outside. The probe measures the two against each other:
the rim comes out **1.00 mm outside** the side where it crosses the cloth at a middle pocket, and
**11.00 mm** at a corner.

The side is *shaded* as the one surface it is, rather than a facet at a time: it carries a normal at
every step of the path, each the surface of the two steps meeting there averaged together and shared
by the quads either side of it, so the renderer draws a smooth side instead of a set of creases. A
step has as much say in that average as it is **long**, so a long straight edge meeting a short one at
a corner — the face of a run of cushion meeting the square end the jaw was cut from — keeps its own
normal rather than being pulled round the corner by the other. That is what carries a reflection on
across the join: the probe reads the run's last normal and the jaw's first off the two built meshes,
at the foot of the flush line where they meet, and they come out **0.9° apart**. The probe reads the
result off the built mesh as well: the widest turn from one step's normal to the next is **1.8° at
both kinds of pocket** — less than the round's own facets, so the jaw is as smooth as the rest of the
table.

Weighting by length alone is not enough where a **join** runs into a face, though. A face left square
because another solid stands against it — a cut between two pieces of the rail, the line the wood stops
at, the back of a cushion — is not part of the surface a piece *shows*: it is where that surface runs
on, so at the point they meet the join is left out of the average wherever the surface beside it
carries on. Taken in, the long buried cut across the rail dragged the normal at the rim of the wood
round with it, by **12°** along the straight and by more where a long cut meets a short arc step, and
the pieces either side of every cut came out shaded differently. With the join left out they agree: the
probe reads both pieces' normals at each of the six joins, over the whole of the rim's round-over, and
they come out **0.0° apart**.

The foot has to stay **convex** — curving outward, the way the round itself curves, with no dip back
into the jaw — and it does so exactly, being an arc and the line it is tangent to. The probe measures
how far the foot comes back in, the deepest it sags behind the line its own neighbours draw, and it is
**0.00 mm at a corner and 0.01 mm at a middle pocket** — no dip at all — against a round whose own
sampling sags 0.04 mm.

Down the throat the ruling is *along* the run, where it says nothing about which way the surface
faces, so the surface is shaded by following the step before it rather than by asking the ruling
again at every step: everything that faces the side down there lies in its own plane, and a normal
taken from the ruling's own direction comes out either side of the surface from one step to the next.

None of it is visible from the table — it happens below the cushion's nose, inside the mouth — but it
is the cut of a real jaw. In plan nothing moved, and the physics still plays the ball on the 50 mm
circle the plan draws: a ball meets a jaw at its own equator, where a leaning side is a few
millimetres outside the nose line, exactly as it is on the cushions.

That makes the mouth the **narrowest gap between the two rounds**, which is how a pocket's mouth
is measured: 78 mm at every pocket on this table. The rule book's middle pocket is wider — 98 mm —
but this table is cut with the middle pockets the same as the corners. It also means the cushions'
straight faces stop where the rounds begin — 20.7 mm short of the mouth at a corner, 50 mm at a
middle pocket — so the opening at the line of the cushions is wider than the mouth, and the pocket
funnels in to it.
The cloth covers that funnel: the bed is cut at the hole and not before, so a ball runs off the
end of a cushion, round the jaw and across the throat — still on the table — and drops when its
centre reaches the hole. A ball rolling along a cushion into a corner pocket therefore drops at
the corner, where the hole comes back to meet it, and one rolling along a cushion past a middle
pocket runs over the throat and on: a middle pocket's hole reaches the mouth, but not out to where
a ball running along the cushion has its centre, so the ball passes over it.

Reaching the hole is where the fall begins, not where the ball leaves the table. The bed is gone
from under the ball at that moment, so it drops the depth of the pocket under gravity — a ball
rolled in gently slips in — and a ball still travelling when it gets there runs on into the back
of the pocket on the way down, where the well stops it dead and it drops from there. Either way
the ball is only off the table once it is on the bottom of the pocket.

Every curve in those outlines — the pockets, the "D", the rounded corners of the frame — is
laid down as a run of short straight segments rather than left to SceneKit, which flattens a
path's arcs in the scene's own units. That tolerance is coarse: a quarter circle of 292 mm
comes out as one straight line, which is enough to turn the "D" into a wedge and each pocket
into a triangle.

The scene is in metres with the table's long axis along `x` and the engine's `y` along `-z`
— the handedness that puts the striker's right hand at `+z`, the same way round as the
top-down view and the same way round as a real table (the Yellow Spot on the striker's right
from the baulk end).

The table is lit the way a match table is: **three long rectangular plates**, one down the middle of
the table and one along each of its long sides, each **3.164 m** by 0.4 m with 20 mm between them
across the table — so the plates stop 202 mm inside each cushion line, rather than reaching out over
them. The middle of the rig hangs 2.2 m over the middle of the table. The two plates along the
sides are turned down 10 degrees — outer edge low, face angled in at the cloth — which is what evens
the light out over the cushions; the middle one looks straight down. A plate turns about its own
middle, so turning one down lifts the edge along the middle of the rig: the two are lowered by
34.7 mm — half their width times the sine of the angle — to bring that edge back level with the plate
beside them, so the rig joins up as one light with its sides folded down. The plates the fixture is
drawn from are the same three, so looking up from the table shows them overhead.

They began as nine smaller plates in a three by three, 1.2 m by 0.4 m with 20 mm between neighbours.
The gaps inside a row have gone: a 20 mm gap at 2.2 m is invisible and nothing like the gap across
the table, so each row of three is one plate. The 20 mm across the table is kept, because that one
can be seen and is what makes the light read as three plates rather than one.

**Each plate is a rectangular area light**, which is also what keeps the renderer honest: SceneKit
applies **at most eight lights to any one object**, and a ball is one object. With nine plates and
the four corner lights in the scene, five of the plates were being dropped without a word, and a
ball was lit and reflecting whichever eight the renderer happened to choose. Three plates and four
corner lights is seven, so every light in the scene is applied.

An area light cannot cast a shadow — SceneKit's shadows come from spot and directional lights only,
and no setting will change that — so the shadow under a ball comes from **four more lights, 2.2 m
over the four corner pockets**, each looking straight down. Being over the corners, their shadows
fall outward from the middle of the table, and their light fills the corners the plates do not quite
reach.

**What is cast is cast in the lamps' shadow maps, and their texels are a measure of cloth**
(`Table3D.cornerShadowMapSize`, 2048). A lamp's map covers the whole of its 120° cone — several metres
of table — so one texel stands for 3.7 mm of it. A ball is 52.5 mm across and comes out of that easily;
the **cue** is 9.8 mm across at the tip and 22 at the butt, and a shadow narrower than the texels it is
drawn in can only come out as a staircase, which is what the cue's shadow was. The map was 1024, whose
texels are 7.4 mm, the probe measured the edge of the cue's shadow moving in steps of **4.83 pixels**;
at 2048 it is **3.5**, and the shadow reads as a shadow. **4096 was tried and is worse**: SceneKit's
spot shadows come apart at that size, smearing the cue's shadow across the cloth (16-pixel steps)
instead of sharpening it.

**A shadow is a shading of the cloth and not a hole in it.** What a shadowed piece of cloth keeps is the
lamp's own light less the shadow's colour, and the colour is black at `Table3D.shadowDepth` — six
tenths of the light — rather than all of it: the cue's shadow is 13.4 levels of the 255 where taking the
whole lamp away made it 24.4, and it reads as the cloth being shaded rather than cut out. (The shadow a
**ball** keeps is fainter for it too: 1.8% of the light at 28 mm from its middle, where it was 2.6%.) And the
blur is two shadow-map texels (`shadowRadius`, 7.4 mm of cloth): wide enough that the edge of a shadow
falls away over a dozen pixels instead of standing up in a cliff, and still well short of the 52.5 mm a
ball is across, so the shadow under a ball is a shadow and not a smudge.

**Those four lights are lamps, and they are drawn as lamps**: a spot lamp at each of the four places,
the shape a spotlight is — a shallow shade that opens downwards, its mouth 264 mm across, with the
glass under it alight — and a body above it. The lamp hangs on the light rather than being the light,
the same arrangement the plates have: the fixture can be taken out of a view from above the table,
where it would stand between the camera and the cloth, without taking its light away with it, and it
does not cast a shadow, because the light it houses is inside it. A lamp that shadowed its own
spotlight would take the light off the table.

**Round the table there is a ring of twenty small spotlights**: they stand in a rectangle the table's
own outer edge with **1 m of floor outside it** — 5855 x 4064 mm — and hang on the same plane 2.2 m
over the cloth, so the whole rig over the table is one rig. Each side of the rectangle is divided
into equal runs rather than the perimeter being walked, so there is **a lamp at every one of the four
corners** and the spaces between them are even all the way round: 976 mm apart down a long side and
1016 mm across a short one, which is a ring of lamps and not a row of dots.

**A small lamp is not a small version of a big one.** The four over the table are *shades* — a wide
cone opening downwards, which is what a lamp hung over a table looks like from underneath — and a
ring of those, small, reads as a row of little cones. A small spotlight is a **can**: a barrel with
the glass set back into its mouth behind a collar, on a stem with a knob on the end to hang it by.
There is no cone anywhere in it.

**The ring is lamps and not lights**, which is the point of it. A light inside one of these lays a
circle of its own on the carpet: twenty bright circles round the table, each where a lamp stands, which
is neither a carpet nor a room, and the table is lit already. What a ring of lamps is *for* here is
to be **seen** — they stand round the table with their glass alight, and the balls reflect them,
which is what the eye reads a rig by — and a lamp that houses no light has no cone to throw either,
so there is nothing of the ring to fall on the cloth or the cushions. The probe reads the carpet
under a lamp and between two of them: **#686b71 against #686a70, 0.009 of full scale apart**, which
is the same carpet.

The room therefore holds exactly **eight lights** — the room's wash, the three plates and the four
corner lights — which is the most SceneKit will apply to any one object, so every light in the room
is applied and nothing is quietly dropped. That is what the ring costs: not one of its lamps is a
light, so the rig drawn round the table is a fixture rather than a second light over the room.

**The table's shadow on the carpet is drawn, not cast.** The room's shadow-casting lights are the four
small spots over the corner pockets, and of the light that falls on the carpet nearly all of it comes
from the three plates and the room's wash — and an area light cannot cast a shadow at all. A light
bright enough to throw the table's shadow on the floor would have to outshine the rig itself, and it
would light the cloth as well. So the shadow is a thing the scene draws (`tableShadowMap`): black,
unlit, laid on the carpet a couple of millimetres above it, the size of the table's own plan with a 500 mm
penumbra outside it, half strength in the middle. The probe reads the carpet under the middle of the
table against the carpet in the open: **27% darker**.

**The capture is grey.** It is not only a reflection: SceneKit lights the whole scene from the same
environment, and anything smooth enough takes it — more than the balls. Taken from over the middle of
the table it is mostly green cloth, and it was putting a green sheen on the rails' outer faces, on
the frame below them and on the legs. There is no green light in this room, and the wood is lit by
the lamps. So the colour is taken out of the captured surroundings before the scene is given them:
the room keeps its second light and puts no colour on anything, and the green stays where it belongs,
in the cloth and in the paint on the balls. The probe reads the green in the leg, with the reflection
on and off: **0.000 either way** — and, because the first attempt at the desaturation failed *silently*
(a copied bitmap that came back nil, so the filter returned the original picture), the **faces of the
capture are read back** and any of them with colour in it is a failure. Reading the leg would not have
caught it: the leg was brown and stayed brown, and it was the light falling on it that was green.

**The lamps are in what the balls reflect.** They are the one thing left *in* the capture the balls
are given — only the three plates are taken out of it, because a plate is a rectangle the size of the
table and comes back smeared across the seams of the cube map, where a lamp is a lamp-shaped thing in
its own place. The environment the balls reflect was doubled, from 0.5 to 1.0: at 0.5 the room's
reflections sat under the balls' own highlights and showed nothing of them, and at 1.0 a ball shows
the rig it is under. The cloth moves by a couple of parts in a hundred for it, which is measured
rather than assumed.

The room's own light — the wash a floor is lit by, as against the plates, which reach a couple of
metres past the cloth and no further — is a flat ambient at 380, under four per cent of what a plate
gives the table: a wash on the table itself, and the floor's own light under the ring. The floor's
size, its covering, the places of the six legs and the places of the four big lamps and the twenty
small ones are read off the built scene by the probe, which cannot measure a ten-metre slab in a
picture; what the carpet *looks* like — its grey, its pile, and the pool of light a lamp of the ring
lays on it — is sampled out of renders, in a patch rather than a pixel, because one pixel of a carpet
is one tuft.

**The balls are glassy, and reflect what is around them.** A snooker ball is moulded and buffed to a
high polish, so it shows the panels overhead, the green of the cloth it is sitting on and the dark of
the room around it rather than a wash of its own colour with one highlight on it: roughness 0.05, a
strong clear coat, and a little metalness, which carries the light that would otherwise scatter off
the surface as pale colour into the reflection instead. From a ball's own height over the middle of
the table the scene is rendered as a cube map, 512 pixels a face, and the scene is lit by that
capture. The capture is taken on the first frame, with the rack already on the table, so the balls
reflect each other too. Without it a ball shows the lamps and nothing else, which reads as a ball
hanging in a void. (This has to go through the scene's lighting environment: a physically based
material ignores its own `reflective` property, and SceneKit has no per-material environment.)

**The cloth is cloth, and it has a nap.** Its colour, its roughness and its relief all come from one
height field: two families of threads crossing at right angles, one running over the other in
alternate squares, each a little out of true, with the nap lying on top of the weave as fine fibres.
The threads' crowns take the colour and come up smoother, the valleys between them darker and
rougher, and the height field turns into a normal map so the weave catches the light rather than
only varying in tone.

The nap is not in the texture, because a nap is not a pattern: it is the same cloth looking
different depending on which way you look along it. The fibres are brushed from the baulk end
towards the top, and the material carries a shader modifier that takes the roughness down when the
eye is looking up the table — reading along the fibres — and up when the eye looks back down it into
them. Looking away from the baulk the cloth shows the lamps as a tighter, brighter sheen over a
darker body; looking back into the nap it is flatter and more uniform. The probe measures both,
over the same points from the two ends of the table, and the spread of the light is about twice as
wide one way as the other.

The rig's measurements live in `TableLightRig` (in `SnookerCore`, where they can be measured
without a picture) and the scene is built from them, so the renderer cannot drift from them. The
balls are polished spheres drawn at the height the simulation gives them, so a potted ball is seen
falling into its pocket rather than being moved there.

### What a frame costs

The game **asks** for frames rather than taking them, because drawing is the whole of what it costs
when the table is not moving.

| What the player is doing | Frames a second |
|---|---|
| Anything being played: down on the shot, the cue being drawn, the balls running or falling, the player walking | 120 |
| Standing at the table — looking about, aiming, placing the ball | 60 |
| Nothing touched and nothing moving for a second | one, with the 3D table **stopped** |

A second of stillness costs one frame of the HUD: the 3D renderer is not run at all, the picture stays
on the screen, and anything the game changes of its own accord is drawn on that one frame. The moment
the player does anything — or a ball moves — the rate goes straight back up. The camera's and the cue's
own easing count as movement, and so does a ball fading into a pocket, so a picture is never left
half-way between two poses.

Two things are **kept** rather than worked out again, because they belong to something that has not
changed. The **spin limit** the cue-ball widget draws belongs to the angle the cue stands at: a limit is
a walk of three hundred offsets and the outline is three hundred of those, and one of them costs 0.6 ms
— five times what a whole physics frame of a break costs — so it is worked out when the angle moves and
kept until it moves again. And the **capture of the room** the balls reflect is taken once, on the first
frame. The line of aim and the ghost ball are two nodes made once and moved, and the strength meter is
the same shape scaled, rather than a node and a path built afresh every frame.

**The exposure is fixed.** The camera does not adapt to the average brightness of what it is looking
at, so turning from the cloth to the dark room does not change the brightness of the table under the
player — and it is a pass over every frame the renderer no longer makes.

**The table is drawn with 4× multisampling** (`Table3D.antialiasing`), and the offscreen renders use the
same setting as the view, so the pictures the harness takes are the picture the player is shown.

`--snapshots` checks the lot: the frame rate probe drives the loop by hand and reads back the rate at
each point in the play, and counts how often the spin limit is worked out.

## Sound

Every contact the frame makes is played as it happens: the tip on the cue ball, ball on ball, a ball
bouncing back down on the cloth of the bed, a ball on a cushion or a jaw, a ball on the dead facing of
a pocket's throat, a ball on the wood of the rail or at the back of a pocket, a ball that was forced
off the table landing on the floor, and the stick knocking a ball in play. A ball dropping into a
pocket makes **no sound** — the game has no voice for it. `M` mutes the lot, and the View menu's
**Mute Sound** is the same switch.

**The core makes no sound.** It reports each contact as a `FrameDriver.Impact` — what kind, where on
the table, and the speed it was made at — and the view drains those once a frame and plays them. That
keeps the physics headless and deterministic, and it keeps the sound free to be changed without going
anywhere near the game: the offscreen harness never builds an engine and is silent, and the contacts
it does report are the same events the rules already run on.

**The volume of a contact is the speed it was made at**, in proportion: half the closing speed is half
the volume. Each material is measured against a reference of its own — a cushion takes a ball at a
couple of metres a second, a stroke leaves the cue ball at up to six, and a ball that has fallen to
the floor arrives at three or four — and nothing is played at all below about a centimetre a second,
which is what **two balls touching** are: the solver reports a closing speed of a hair as it holds
them apart, and a touch is not a hit.

**The wood of a rail is the one contact that does not follow that rule.** Wood is only struck hard on
this table: a ball coming down on the rail does so at a hop's speed, and it is the wood at the back of
a pocket that is hit at speed. So the rail is **silent below 4 m/s**, comes in at **half volume**
there, and is at full volume by **8 m/s**.

**A cushion makes one sound and not two.** The cushion answers a ball **above its own equator** — the
nose overhangs the cloth — so part of its answer throws the ball up off the cloth, and the ball lands
again a moment later. That landing would be a second noise for the one hit, and by far the louder of
the two: the cloth is at 0.2 where the cushion is at 0.05. So a ball coming back down on the cloth
within **0.4 s** of a cushion or a throat is taken to be that contact's own hop and is not played. A
hop from a screw shot, with no cushion involved, still sounds.

| Contact | Sound |
|---|---|
| the tip on the cue ball | `cue-ball.flac` |
| ball on ball | `ball-ball.flac` |
| a ball bouncing back down on the cloth of the bed | `throat.flac` |
| a ball on a cushion or a jaw | `cushion.flac` |
| a ball on a pocket's throat | `throat.flac` |
| a ball on the wood of the rail — or on the wood at the back of a pocket | `ball-rail.flac` |
| a ball reaching the floor | `drop.flac` |
| the stick knocking a ball in play | `cue-ball.flac` again |
| a ball reaching the bottom of a pocket | nothing — it is not a collision, and the game is silent |

Those files are in `Sources/SnookerApp/Resources/`, and are read and converted into the voices' own
format at launch. They were recorded independently and arrive at very different levels — the quietest
some thirteen decibels below the loudest — so each is **brought to a common peak** first, which leaves
the strength of a contact to its speed and the balance between materials to one small weight each:
ball on ball at 1.0, a ball landing on the floor at 0.8, the stroke and the stick on a ball at 0.3,
the cloth of the bed at 0.2 and the cushion and the throat at 0.05. `--sound-check` prints the
whole mix back, each with the speed it reaches its own ceiling at.

**Where there is no sample, the sound is made in code.** A click is a burst of white noise through a
narrow band-pass that dies away in a few tens of milliseconds, and a knock is the same with a low
struck resonance under it for body: each material is a few numbers — where its noise is centred, how
sharply it is filtered, how fast it falls away and what note is under it (`GameAudio.palette`) — and
each is built as **three variants**, so a break of fifteen balls is not one sample played over and
over. A material whose file is missing is synthesised as well, so the game always has a voice for every
contact.

Sixteen voices play at once, and a frame carrying more contacts than that plays the loudest of them
rather than cutting one off mid-thud — and **no kind is played twice inside twenty milliseconds**. That
last is for the **first break of a session**: the picture is still being warmed up, so the frame the
cue ball meets the pack in can be fifty milliseconds long instead of eight, and every substep of it
reports its own contacts into that one frame. The probe measures what that is worth — twenty-one
ball-on-ball contacts in one instant. Playing them all is a buzz; playing them *a few milliseconds
apart* is worse, because a run at a few milliseconds is a **pitch** of a few hundred hertz rather than
a set of clicks, and a pitch is heard over the clack instead of beside it. Twenty milliseconds is about
where the ear stops fusing two clicks into one, so a pack's chain arrives as the single crack it sounds
like, and two contacts that really are separate — a ball off one cushion and then another — are still
two.

In the player's view each contact is placed left or right of the player by where on the table it
happened; from above there is nothing to pan against, so there is none.

## Rules implemented

Rule numbers below are Section 3 of the May 2022 rulebook unless stated otherwise.

**Equipment and set-up**

- Playing area 3569 x 1778 mm, balls 52.5 mm, from Section 1 Rules 1(a) and 2(b).
- Pocket openings 78 mm at every pocket: the four corners (Section 1 Rule 1(g)) and the two middle
  pockets, which this table cuts to the corner width rather than the rule book's 98 mm. Each is
  measured between the two rounded jaw tips and carried out by a passage of that width — 45° at a
  corner, square to the cushion at a middle pocket — to a round hole of 111.091 mm, which is the
  passage plus the jaws' own 15.5455 mm setback on each side and a further 1 mm of clearance past
  each foot; the corners' holes are `cornerPocketHoleExtra` of 20 mm wider again, 131.091 mm, the
  middle pockets' being left as they are.
- Baulk line 737 mm from the baulk cushion, "D" radius 292 mm (Section 1 Rule 1(d)-(e)).
- Spots: brown on the baulk line, yellow/green at the corners of the D (yellow on the
  right seen from the baulk end), blue at the centre, pink midway between the blue spot
  and the top cushion, black 324 mm from the top cushion (Section 1 Rule 1(f)).
- Fifteen reds racked in a tight triangle behind the Pink Spot with the apex on the centre
  line (Rule 2(a)).

**Scoring and sequence**

- Reds 1, yellow 2, green 3, brown 4, blue 5, pink 6, black 7 (Rule 1(a)).
- Red then colour alternately while any red remains; every red potted in one stroke scores
  (Rules 3(g), 3(h)(i)).
- A colour potted after a red is scored and re-spotted; the striker is then on another red
  (Rule 3(h)(i)).
- After the final red, the striker still gets a colour of their choice, then the colours
  are on in ascending order and stay off when potted (Rule 3(h)(ii)-(iii)). That colour ends
  the alternation whether it was potted or missed, and from then on **nobody nominates**: the
  ball on is simply the next colour in the order, so the next player is on the yellow.
- Spotting: own spot, else the highest value spot available, else as near as possible to
  its own spot toward the top cushion, pink/black falling back on the centre line, never
  touching another ball (Rule 7(e)-(j)).

**Fouls and penalty values**

- Minimum four points, otherwise the value of the ball on, or the higher of the ball on
  and the ball concerned, and seven points in the cases listed in Rule 11(d) (Rule 11).
- Implemented fouls include: cue ball pocketed; failing to contact any object ball;
  first contact with a ball not on; potting a ball not on; striking two balls
  simultaneously other than two reds or a free ball with a ball on (Rule 6, Rule 11(c));
  missing the nominated free ball first (Rule 12(b)(i)); and forcing a ball off the table
  (Rule 11(b)(x), Section 2 Rule 14), worth the value of the ball on or the ball concerned,
  whichever is higher.
- **Playing a jump shot** (Rule 11(a)(x), Section 2 Rule 20) is a foul worth the value of the ball
  on. A jump shot is the cue ball passing over any part of an object ball it has not already hit, so
  it is the *jump* that is the foul and not what the ball then reaches: a cue ball scooped over an
  obstruction to get at a ball on is a foul, however well it comes off. A ball lifted with `B` hard
  enough really does clear another ball, and the game calls it. A swerve is not a jump — the ball
  curves *round* what is in its way with the cloth under it all the way — and is a legal shot.
- Nothing scores in a foul stroke, but points already made in the break stand, and colours
  pocketed in a foul are re-spotted (Rule 10(e), Rule 7).
- Two balls in one stroke: two Reds both score (Rule 3(g)); a free ball as a Red and a Red each
  score (Rule 12(e)); and potting anything that is not the ball on — including a second colour
  when only one colour of your own choice was nominated — is a foul, so nothing from that stroke
  scores and the colours go back on their spots (Rules 10(e), 11(b)(iii)).
- A red potted in a foul stroke also comes off the table without scoring (Rule 3(i),
  Rule 10(e)), so it stops counting as one of the reds left.
- A ball forced off the table is treated like one potted: a colour is spotted before the next
  stroke (Rule 7), a Red stays off (Rule 3(i)), and the cue ball comes back in-hand
  (Section 2 Rule 9(a)(iii)). The ball is out of the simulation from the moment it is off the
  playing area and out of a pocket, so the stroke is over as soon as the balls still on the table
  stop — nothing waits on a ball that has left the table. It is still **drawn** though, because it is
  still a ball in the air: it falls to the floor (`Table.floorHeight`, a table's bed being about
  800 mm up) and only once it has landed is it gone. The view keeps the fall going between strokes;
  the rules have had the ball since it left.
- Higher of multiple fouls in one stroke (Rule 10(g)); the cue ball goes in hand when it is
  not in play (Rule 10(f)).

**Options after a foul**

- The incoming player may play from where the balls lie or ask the offender to play again
  from there (Rules 10(f), 10(h), 13). The balls stay where they lie: replacing them is only
  allowed in the cases Rule 12(f) lists, which for this game means a foul and a miss.
- **The ball on comes with the turn, not with the foul** (Rule 3(g)): a turn begins on a Red
  while any Red is on the table, so an incoming player who takes over after the offender was
  playing for a colour is on a Red. That holds for either player: the non-offender playing from
  here, and the offender asked to play again from there (Rule 13), each get a fresh turn and so a
  Red while any is left. Rule 13(a)(ii) does not hand the offender back the ball on they were on;
  it only gives them a free hand at a ball on that is already a colour of their own choice, which
  never arises at the start of a turn. Only the Foul and a Miss replacement (Rule 14(b)) restores
  the ball on, because there the balls themselves go back. In the colours the sequence runs in
  ascending order, so the same colour stays on (Rule 3(h)(iii)).
- **Free ball** is offered when the incoming player is snookered on every ball on
  (Section 2 Rule 17, Rule 12): any ball other than the ball on may be nominated, it takes the
  value of the ball on, and if potted it is spotted and the value of the ball on is scored.
  **Snookered is Rule 17's own test and not a looser one**: the cue ball is *not* snookered only
  if a ball on can be hit at **both** of its extreme edges with nothing not on in the way of
  either. A ball on showing only part of itself — one extreme edge cut off by a ball not on — is
  "partially obstructed", and partially obstructed is snookered, so a free ball is due. Being
  able to reach the ball somewhere in the middle is not enough: that is the wider question
  Rule 14(c) asks about a miss, and the two are asked separately here.
  While the colours are being cleared that means the free ball is spotted and the *same* colour
  is still on, and if the ball on is potted in the same stroke only that one scores
  (Rule 12(c), 12(e)). It is an **offer and not an obligation** (Rule 12(a)): the striker may
  decline it — the **No free ball** button, or `0` — and is then held to the ball on like any other
  stroke, so hitting a colour first with a Red on is a foul. A nomination the referee would refuse
  is refused here too: the free ball has to be a colour still on the table and can never be the
  ball on itself, or the ball on could be named as its own free ball and **spotted** when it was
  potted in the ordinary way. And with the cue ball in hand the offer comes **after** it has been
  placed: whether the striker is snookered depends on where they put it down, so the free ball is
  judged from the spot they choose rather than from wherever the ball happened to stop.
- **Touching ball** (Rule 8): the cue ball resting against a ball on, or one that could be on, is
  called by the referee when the balls come to rest — on screen, in the referee's own line above the
  status, not just in the log — and the ball is ringed on the cloth, since a call on its own is hard
  to read off a table of balls. The call and the ring name only the balls on (8(a), 8(e)); the striker is asked to declare which colour they are on when the cue ball is touching
  colours after a Red (8(a)). Playing away from a ball the cue ball is touching, without moving
  it, needs no contact of its own — the stroke is legal having hit nothing (8(c)) — and where that
  ball **is** the ball on, that contact stands for the stroke's contact with a ball on, so the cue
  ball may be played straight into a ball that is not on: **a cue ball resting against a Red, with
  Red on, may be played at a colour**, and neither the wrong-ball foul nor the miss is called for it
  (8(c)(i)). Where the touching ball only *could* be on, the contact is good while the cue ball then
  hits a ball that could be on too (8(c)(iii)). Moving the ball is a push stroke, worth the higher
  of the ball on and the ball concerned (8(b), Rule 11(b)(v)).
  Two balls touch when their centres are a ball's diameter apart, 52.5 mm, with a twentieth of a
  millimetre of slack for the arithmetic (`Table.touchingTolerance`): the solver leaves a resting
  contact at exactly the diameter, so no more is needed, and a ball genuinely a sliver clear of
  another is not touching. That is the same test that decides a spot is occupied (Rules 7(i), 18).
- **A ball touched with the cue** (Rule 11(b)(vi)): the stick is a body on the table, and a ball that
  runs into it — the tip, or the side of the shaft — is a ball in play contacted with the player's
  equipment, worth the ball on or the ball concerned, whichever is higher. The cue ball struck a
  second time is the double hit of Rule 11(a)(ii), worth the ball on, and the call is **timed**: the
  caption says how long after the first contact it came, in milliseconds, because that is what tells a
  cue that really went back to the ball from one that was simply still against it as it left. The
  cue's *first* touch of the cue ball is the stroke and is not reported. The spin graph shows where a
  strike would risk the double hit (`PhysicsWorld.spinRange`) but does not stop the tip being put
  there. The stick is **in play for the whole stroke**: standing up (releasing `S`) takes the player's
  hand off it and leaves it on the table where the shot put it, stopped but still a stick the balls are
  answered by, so a ball that runs into it while they are standing up is that same foul. Putting it
  away (`C`) is the one thing that takes it off the table.
- **The free ball must not be left doing the snookering** (Rule 12(b)(ii), Rule 11(a)(viii)):
  having potted nothing, the striker has fouled if the cue ball is left snookered on the ball on
  by the ball they nominated. Which ball is doing the snookering is decided as Section 2 Rule 17
  does — the nearest of the balls not on, and with Red on there is nobody to blame when different
  Reds are blocked by different balls — and the rule excepts the end of the frame: with only the
  Pink and Black left, the free ball may stay where it is.

**Foul and a miss**

- Called whenever the striker fails to *first* hit a ball on (Rule 14(c)) — hitting the wrong
  colour as well as hitting nothing at all — **snookered or not**. The rule book spares a striker who
  could not have hit the ball on (Rule 14(a)(ii)); the game does not ask that question, so a miss is
  called in any case. It is a simplification, and a deliberate one: it is simpler to play against and
  to explain, and it means every failure to hit the ball on carries the three choices of Rule 14(b).
  A stroke with no ball on the table at all is still no miss, there being nothing to miss.
- Playing a stroke without having declared a colour after a Red is a seven point foul
  (Rule 11(d)(v)-(vi)) and, since no ball on was ever chosen, a miss as well. The game takes the
  colour the cue is on as the declaration, so this is the stroke played with the cue on no colour at
  all; a striker whose cue is on a colour has declared it, to the game, by aiming at it.
- The non-offender then has three choices (Rule 14(b)): play from the position left
  themselves; ask the offender to play again from there; or have every ball replaced and the
  offender play again from the original position, with the ball on restored to whatever it
  was. A request to replace the balls also voids the free ball option (Rule 12(f)), and the
  Foul and a Miss sequence carries on from the replaced position, so a further failure is a
  second failure. Both "play from the position left" choices leave the balls where they lie and
  put the player who plays next on the ball on for a new turn (Red while any is left); only the
  replacement puts the ball on back to what it was. Asking for the position left ends the sequence
  (Rule 14(d)(iii)).
- A second failure from the original position issues the warning and a further failure awards the
  frame (Rule 14(d)(i)-(ii)) — but only when the striker had the ball on to hit. Rule 14(d) asks for
  "central, full ball, contact available": the whole ball to aim at, so that missing it is the
  striker's doing and not the snooker's. The game asks that of the position the stroke was played
  from (`hadFullBallContactAvailable`). A failure to **escape a snooker**, or one where no more than
  a thin edge of the ball on could be reached, is a foul and a miss like any other and carries the
  three choices of Rule 14(b) — but it cannot cost the frame: three failures to get out of a snooker
  are three fouls, not the loss of a match.

**Ending the frame**

- Black as the only object ball, with more than seven points between the scores: the frame is
  there for **whoever is ahead** (Section 2 Rule 1). The striker's is a *claim* (Rule 1(b)): the
  **Claim the frame** button is theirs, they are not made to take it, and playing on is their right —
  potting the Black ends the frame just as well (Rule 4(a)). The non-striker's is an *award*
  (Rule 1(c)) and is never asked for: the striker needs snookers, so the game ends the frame and
  counts it for the opponent the moment the position is noticed, rather than waiting on a button
  that would only ever be pressed for them.
- Black as the only object ball, otherwise: the first pot or foul ends the frame — except when
  the scores are then level, which gives the **re-spotted Black** (Rule 4(a)-(b)): the Black goes
  back on its spot, the players draw lots for the choice of playing next, and that player plays
  from in-hand. The next pot or infringement ends the frame.
- Concession, and the stalemate re-rack that nullifies scores and re-sets the balls
  (Section 4 Rule 2, Rule 17).

**Variants** — the engine takes a red count, so the Six Reds variation (Rule 19) can be
played by constructing the game with `reds: 6`; the UI currently starts a standard frame.

## What is deliberately not modelled

Honest limitations, kept small on purpose:

- Referee judgement is automated where it can be decided geometrically, and the engine raises a
  decision instead of silently applying one. A failure to hit a ball on is always **called** a miss,
  snookered or not — the rulebook spares a striker who could not have hit the ball on at all (Rule
  14(a)(ii)), and the game does not ask that — so what the geometry decides is whether the failure
  *counts*: the warning and the frame follow only a failure with "central, full ball, contact
  available" (Rule 14(d), `hadFullBallContactAvailable`), so nobody loses a frame for failing to
  escape a snooker. `hasClearPathToBallOn` answers the wider Rule 14(c) question — whether any part
  of a ball on could be reached at all.
- Ball-on-edge-of-pocket (Rule 9) and balls-moved-by-others (Rules 15-16) are not modelled beyond
  the plain physics, and the referee's own judgements in Rule 8(d)-(g) — "nearly touching", and
  movement not caused by the striker — cannot arise in a simulation.
- Fouls that cannot happen in a single-player-machine context (both feet off the floor,
  non-standard cue, measuring gaps, conferring with a partner) are not enforced.
- The size of the nap's sideways push, of spin-induced throw and of cue-ball squirt are
  approximations in the physics, not the published measurements.
- No AI opponent, no aggregate-points bookkeeping beyond the frames won and the frame number, and no
  save/load. (The game does have sound — see *Sound* above.)

## Project layout

```
Snooker.xcodeproj/            the Xcode project (shared "Snooker" scheme)
Sources/SnookerCore/          framework target: pure logic, no AppKit
  Vec.swift                   Vec2 / Vec3
  Table.swift                 dimensions, spots, pockets, ball model, racking
  Physics.swift               cloth friction and nap, spin, cushions, jaws, pockets, events
  Rules.swift                 the WPBSA rules engine (scoring, fouls, free ball, spotting)
  FrameDriver.swift           stroke pipeline: physics -> events -> adjudication -> next state
  PlayerCamera.swift          where the player's eye is and what it is looking at
Sources/SnookerApp/           app target: the Mac app
  main.swift                  NSApplication, window, menu, and the two layers of the window
  TableScene.swift            SpriteKit HUD and plan of the table, mouse/keyboard input
  Table3D.swift               SceneKit table, lights, cue, balls and the player's eye
  GameAudio.swift             the sounds: what each contact plays, and the engine that plays it
  Snapshots.swift             offscreen renders and text reports, for checking the 3D view
Tests/SnookerCoreTests/       test target: 226 tests (85 rules, 67 physics, 62 end-to-end, 12 camera)
Scripts/build-app.sh          optional command-line build that assembles build/Snooker.app
```

The window is two views: the SceneKit table underneath, and a transparent SpriteKit scene
over it drawing the HUD and the plan of the table. Switching to the top-down view makes
that overlay opaque again and stops the 3D renderer.

The physics world is rebuilt from the rules engine after every stroke, so the engine always
owns the authoritative ball layout (positions and spotting).

## Physics model

- Full 3D angular velocity per ball. While the contact point slides, kinetic friction
  (0.15) slows the ball and changes its spin; once rolling, rolling resistance (0.010)
  applies. The cloth is a fast competition one: rolling resistance 0.010 means a ball
  loses 0.098 m/s^2 to the cloth, so one struck at 800 mm/s with natural roll runs 3.26 m
  (v^2 / 2 mu g) — nearly the whole length of the table — and a 2 m/s shot crosses the
  table, comes back off the cushion and dies about a length and a half from the start.
  This produces natural stun, follow, and draw without special cases, and draw shots
  genuinely screw back.

  The sliding friction is capped by what the cloth can supply in one step *and* by what is
  needed to take the slip away, whichever is smaller. Skipping that second limit lets a step's
  friction reverse a small slip, so the friction cancels itself out step about step: a ball
  left barely moving by a collision would chatter on the spot and crawl for hundreds of
  millimetres rather than stopping.

  A ball counts as moving if it is spinning, not only if it is travelling: the cloth turns
  spin into motion, so a stroke that ends while the cue ball still has follow or draw on it
  would cut the shot short.
- Every ball carries the height of its centre as well as its place on the cloth, and the
  simulation moves it vertically under gravity. The bed holds a ball up: a ball dropped onto
  the cloth lands, comes back up and settles, and a collision that presses one into the cloth
  pushes it back out. The cloth's own springiness is 0.5 and a bounce smaller than 60 mm/s is
  taken to have settled. The one thing the cloth does not hold a ball up over is a hole — see
  the pockets below — and a ball in the air is above the bed, so it clears one under it rather
  than colliding with it on the plan.

  A hard tip below the centre pinches the cue ball against the cloth, and the cloth pushes
  back, so the cue ball comes off the bed a little: 12% of the speed of the low part of the
  tip, which is a 3 mm hop on a hard screw shot and nothing on the medium ones. That is the
  only thing in the game that puts a ball in the air other than a pocket, and how much of the
  pinch comes back is a judgement rather than a measurement — it depends on how the ball and
  the cloth deform, which the model does not simulate.
- Cue strike from tip offsets: `omega = 5 * speed / (2 r^2) * (h * t + s * z)`, so a
  0.4 r offset gives natural roll. The tip offsets are the striker's own: up for follow, down
  for screw back, and right for right side spin. A hit on the right turns the ball
  counter-clockwise seen from above — a positive turn about the vertical — and the ball
  squirts away from the side struck, so right side sends it slightly left. That is the sign
  convention every other part of the physics reads: throw and cushion grip both take their
  direction from it.
- **The cue is a body, and it is infinitely heavy.** It is the player's hand, not a projectile: the
  simulation never moves it — the mouse does, along the stick's own line — and nothing a ball does to
  it moves it either. What it has is a **speed**, and every ball it meets is answered as a collision
  with a body that does not budge. The tip is a leather face square to the cue, so a ball in front of
  it is struck **along the cue's own axis** with the tip's restitution (0.75), and the ball behind it
  comes away at `1.75` times the speed of the tip: the whole of the tip's approach, and three quarters
  of it again for the spring. Hitting off centre spends part of that impulse on spin —
  `omega = (5/2) v k / r`, the same figure as before, which is why a 0.4 r offset rolls naturally.

  The tip can only pass so much of the impulse sideways before the leather lets go. The impulse has a
  part across the ball's face (`b`) and a part into it (`sqrt(r² - b²)`), and the tip holds while
  `b <= μ sqrt(r² - b²)` — that is, while `b/r <= μ / sqrt(1 + μ²)`. Chalked leather on a phenolic
  ball is about `μ = 0.8`, so `cueTipFriction` is set to 0.8 and the grip's own limit is
  `0.8 / √1.64` — **0.625 of a ball radius**. Past it the tip would skate off the ball — a **miscue**,
  the shot's spin lost.

  Inside that is the region `PhysicsWorld.spinRange` marks out, which is where the ball can still get
  away from the tip. A strike sends the ball off at `1.75 / (1 + 2.5k²)` times the cue's speed, so a
  **level** cue is safe to `√0.3` of a radius — `1 + 2.5k² ≤ 1.75`, the offset where the ball leaves
  at the cue's own speed and no follow-through can catch it. `√0.3` is `0.548`, *inside* the chalked
  tip's `0.625` grip, so at a level cue it is the ball's speed that is the closer of the two lines and
  not the leather, the same in every direction. The cue's own speed cancels out of the sum, which is
  why "a hard enough strike" is the only assumption it needs. **None of it is enforced**: the control
  puts the tip wherever the player asks, out to the edge of the ball, and the lines are there to tell
  them what they are choosing.

  Standing the cue up costs the spin, and it costs it on a **schedule**: the part of the strike that
  goes down into the cloth is given up, and the cloth's friction — the impulse that stops the ball
  being driven through the bed — drags the ball's own surface with it. `separationAlongTheCue` is the
  ball's lead along the cue's line, and the allowed offsets are where it stays at least the cue's own
  speed. At 20° a screw is down to `0.43`; at 30° to `0.28`; by 36° only a sliver is left; and by 37°
  nothing, because even a spinless strike cannot get the ball away from a cue driven down on it.

  The limit is not always a single run from the middle, and that is the part worth knowing. A small
  offset leaves the ball under-spinning: its surface runs forward on the cloth, the friction drags it
  back, and the ball loses its lead. Past about `0.4` of a radius up the face — the offset that leaves
  the ball rolling naturally — the slip **reverses**, the friction pushes the ball on, and a second
  run of larger offsets the cue cannot catch opens up. At 30° on the follow side the allowed offsets
  are `[0, 0.28]` **and** `[0.35, 0.41]`, with the band between them dead. The widget draws the
  boundary as a thin solid line and, where there is a hole in the region like that, an inner solid
  edge too; both redraw as the elevation moves. A player may still put the tip in the dead band — the
  line only says what will happen if they do.

  The cue can be drawn **400 mm** back, followed through **250 mm** (`FrameDriver.maxFollowThrough`,
  measured from the middle of the ball it struck) and stood **right up to 90°**, and its tip is not
  flat: it is a dome of 12 mm radius of curvature (`Table.cueTipCurvature`), a spherical cap that
  stands about a millimetre deeper at its crown than at its rim. That dome is what puts a stop to a cue
  driven on into the table — the follow-through is short because the tip comes up against the **cloth**,
  or is capped at the 250 mm where no cloth is in the way, and a cue
  pushed across the table stops at the **cushion or the rail** — and it is the rim, not the crown, that
  reaches the cloth first once the cue is stood up past the cap's own 24°. See
  `PhysicsWorld.theTipReachesDownTo` and `FrameDriver.carryTheCue`.

  The tip is **soft**, and a strike is not an instant: the leather compresses against the ball, holds
  it for a moment and lets go — `cueTipGrabSeconds`, three milliseconds, a tenth of a frame. That whole
  moment is **one contact** of the cue and the cue ball (`PhysicsWorld.grabTheCueBall`). The tip is
  carried with the ball while it has hold of it, nothing is reported for it, and the ball is only free of
  the cue once the leather has let go; a contact made after that is a second one, the double hit of Rule
  11(a)(ii). The stroke is one contact and not two.

  The stick stays on the table after the shot, and it is still the player's. A ball that runs into it
  — the tip or the side of the shaft, which is varnished wood rather than the tip's leather — is a
  ball **contacted with the player's equipment**, and that is a foul worth the ball on or the ball
  concerned, whichever is higher (Rule 11(b)(vi)); the cue ball struck a second time is the double hit
  of Rule 11(a)(ii), worth the ball on. Staying down on the shot and keeping the mouse on the stick is
  the only way to do it: releasing `S` stands the player up and takes their hand off the stick, leaving
  it on the table where the shot put it, stopped.
  **The stick is carried forward no faster than it was travelling when it struck the ball.** The speed
  it has at the moment of contact is kept (`theStickWasTravellingAt`) and is the cap on the rest of the
  stroke, while drawing the stick *back* stays the player's as far as the table allows. That cap is what
  keeps a flick from running the ball down from behind: the ball leaves at `1 + e` times the stick's
  speed, so a stick that does not speed up when it meets a ball cannot catch what it has sent away. The
  separate cap at `maxCueSpeed` is still there, for the *backward* travel and as the ceiling on the
  stick's own speed; the cap that matters after the strike is this one, because a stroke is played *by
  the hand going on through the ball* — the tip meets the ball part way through a flick, and the frames
  that follow are still the same movement. Left to the hand, the stick would speed up *through* the
  ball while the ball's speed is `1.75` times the stroke's own, and the stroke's own strength is the
  **average** of the push, which a flick's last frame is faster than: measured, a stroke at 840 mm/s
  with the hand going on through it was called a second hit **14 ms** after the first contact, over and
  over, which is the foul the player met as coming from nowhere. With the cap it is a follow-through
  like any other.

  The spin control is the other half of the same business: the ball comes away at
  `1.75 / (1 + 2.5k²)` times the cue's speed, and the control stops the tip at the offset where that is
  exactly the cue's own speed — `√0.3` of a radius at a level cue, which is why a tip inside that is a
  shot the cue cannot catch however hard it is played. Past it — heavy side or screw, where the ball
  leaves *slower* than the stick was going — the cap no longer separates the two, and the margin is
  thin rather than gone: the probe's heavy-side case comes out with the ball at 744 mm/s against a stick
  capped at 840, and it is still a follow-through rather than a foul. Those offsets are the miscue the
  widget's own lines warn about. See `PhysicsWorld.spinRange`.

  A ball that comes back to a stick left standing on the table is none of this: the stick is in play for
  the whole stroke and a ball that runs into it is the foul of Rule 11(b)(vi). The probe plays the same
  shot ten ways — the hand stopping on the ball, going on at the same pace, easing back, snapping
  through a soft one, heavy side — and reports which of them are second hits and which are
  follow-throughs.
- **The swerve, and the cue lifted.** The cue is not always level: hold `B` and the butt rises, and
  the elevation the widget reads is the cue's **own** angle — the stick's lowest is **level** and the
  top of the lift is 90°, and the strike is played along whichever
  of those the cue is standing at. A lifted cue still strikes along its own axis, so the ball is driven *down* into
  the cloth — which is what the press of a massé is — and the tip's place on the ball is taken
  square to that axis, so the spin turns with the cue. Levelled, that is the same
  `omega = (5 v / 2 r^2)(h t + s z)` as before; lifted, side spin gains a **barrel of spin about
  the line of the shot**, and the cloth's friction on that barrel — the contact point moving
  sideways while the ball runs — curves the ball off the line of aim. That is the swerve: it takes
  side spin as well as lift, and it is strongest at a slow, steep shot. The ball is pressed into the
  cloth by the same impulse, so a lifted shot hops as well as curves, and a hard enough one really
  does clear a ball in front of it — which the rules call a jump shot, and a foul.
- **The cue needs room behind the ball, and it is a stick.** The cue is 1400 mm long and it is not a
  shadow: it is judged as the body it is — `Table.cueGirth` gives each length of it its own widest
  measurement, 9.8 mm across the tip and 22 mm across the butt, so the thin end is not made to keep
  the fat end's distance. The line it is judged on is the **tip's own contact**, not the middle of the
  ball: a tip struck up the ball's face or out at its side meets the ball there, and the stick behind
  it is carried up or over with it (`PhysicsWorld.cueLine`) — which is what makes topping the ball buy
  clearance. And what is judged is the **stroke** and not just the pose: the tip travels from the ball
  out to the drawn place, so the cue has to be clear of every place it passes through on the way, which
  is the cue with its girth carried on past the butt by the distance the butt itself moves
  (`PhysicsWorld.cueFits`). The ball right against a cushion is the hard case: the tip has to tuck
  under the nose at the ball and come back out through the gap the leaning face leaves it. A cue at the
  bottom of the lift, judged as a line down its middle, would clear a cushion 69 mm behind the ball at
  a 10° lift; judged as the stick it is, it needs 100 mm. Held level it clears none at all, which is
  why the room behind the ball has to be found for it.

  The game does not take the cue away when the room runs out, and it does not draw it through
  anything: it **settles** the cue where it can be laid (`FrameDriver.settleTheCue`). The butt comes up,
  no further than `automaticLiftCap` (10°) — a cue stood up is a different shot, so the game does not
  stand it up without being asked — and if that is not enough the tip goes up the ball's face
  (`automaticTopSpin`, the spin limit), which lifts the line of the stick with it; only if even that
  will not do does the butt go up past the cap, topped. The cue ball on a cushion settles at the 10°
  with the tip up the ball; a ball resting against the back of the cue ball wants about 20°. It is the
  player's own pose the game settles, so the widget, the picture and the stroke all read the same
  thing, and the player can carry on from there. Their own changes are stopped where the room runs out:
  the butt cannot be laid back into a cushion, and a tip that would carry the stick into something
  stops there — with one exception: a **spin change** with no room is not refused. The game finds room
  for it, and what is left on the ball is the spin the player asked for rather than a change of its
  own. The butt comes up in the same way, to the **first cap**, `spinLiftFirstCap` (10°), and at the cap
  it stops standing the cue up and **lifts the tip** instead — further up the ball's face, keeping the
  side the player asked for and going no further than `spinLiftTop` (0.54 of a radius), with the
  elevation standing still while it does. Only if that is not enough either does the butt carry on, to
  the **second cap**, `spinLiftSecondCap` (30°), with the spin unchanged; and only past both caps is
  the spin **settled** to what fits, at the second cap the cue has been left standing at. A cue ball on
  a cushion is the case: half a ball of side spin taken there does not fit at the settled 10°, and the
  game lifts the tip up the ball's face — 0.5 of a radius — to find it, with the elevation left at the
  cap and the butt where the settle put it; a side spin right out at the edge of the ball, which no tip
  can buy room for, is settled at the second cap instead. `spinLiftCap` (37°) is the far end of the
  family a spin change belongs to, which the second cap bites well before.

  Bringing the butt **down** is the other way to run out of room, and it is simply stopped there: no top
  spin is put on the ball to buy a lower angle. A settle never lays the butt back down by itself, so a
  cue stood up for a place stays there until the player brings it down by hand, and it comes down only
  as far as the room allows, with the tip left where it is.
  A timed charge draws the cue back in proportion to its power, so the room caps the power
  too. The angle the room is measured at and the angle the strike is played along are the same one —
  the cue's own elevation — so a stroke asked for "level" is struck level, which is what a real level
  stroke is. The aim can be turned while the cue is drawn (`Shift` gives the mouse back to
  it), and the cue is settled again as the line moves rather than being refused.
- The nap of the cloth. The cloth is brushed, and its fibres run one way up the table: from the
  baulk end towards the black, which is the physics world's +x. A ball turning about the vertical
  drags those fibres across themselves and is pushed sideways along y, across the nap — clockwise
  seen from above towards the green (the higher y, the striker's left at the baulk end) and
  anti-clockwise towards the yellow (the lower y, their right). The push is `napSpinDrift`, 0.03
  mm/s^2 for each rad/s of side spin: a nudge that carries a well-spun ball a few millimetres over a
  shot a length of the table long, beside the centimetres the same shot's squirt wanders. It takes
  side spin to feel it — a ball spinning about a horizontal axis, running with follow or screw back,
  is not carried sideways — and it is the same on every ball, not only the cue ball, since the nap
  is a property of the cloth. The fibres are not yet modelled as telling a ball running up the table
  from one running down it; only the sideways push is here.
- **Ball on ball is answered at the place the two balls touched**, whatever pace it was played at. The
  pair is walked back along its own closing motion to the moment they were exactly a diameter apart,
  answered there, and walked on again for the rest of the step. Without that the balls are answered
  where the step left them — **overlapped** — and the line of centres there is not the line they met
  on: the object ball goes off a degree or two wide of it, and wider the harder the shot, which is
  exactly the sort of thing a cut is felt in.

  The impulse itself is the usual one along the line of centres — equal masses, restitution 0.95 — and
  **friction acts at the contact point**. What it opposes is the slip of *that point*, in three
  dimensions: a radius out along the line of centres, a ball's surface there is moving at
  `v + w × (r n)`, so a ball's own follow or draw carries its surface across the contact as much as its
  side spin does. The two arms point opposite ways, so the spins enter as a **sum** —
  `u = (v_a − v_b) + (w_a + w_b) × r n`. The impulse that takes that slip away on two equal spheres is
  a **seventh** of it — the two centres' own changes are `2 J`, and the spin the impulse gives them
  carries `5 J` back to the contact — and it is capped at `ballFriction` (0.06) of the normal impulse.
  That cap is what a real throw is bounded by: an object ball leaves at no more than `atan(0.06)`,
  about **3.4°**, inside the line of the cue, however hard the shot, and turns as it goes.

  **The cloth is part of the collision too**, and this is where a good deal of the throw comes from.
  The impulse above has a *vertical* part — from the line of centres when the two balls are at
  different heights, and from the friction whenever the slip at the contact is not level, which is any
  ball carrying follow or draw — and a ball resting on the bed cannot be driven down into it. The bed
  answers that part with a normal impulse of its own, and a normal impulse on the cloth comes with the
  cloth's **friction**: the cloth opposes the slide of the ball's own patch, `u = v − r(w × ẑ)`, so a
  collision that presses a ball into the cloth also drags it along and turns it. It is the same rule
  the cloth is given every other step, applied to the one impulse that happens *between* two of them.
  A ball the collision has lifted instead is off the cloth for the moment and is left alone, and the
  cloth's own springiness is not put back here — the bed's restitution belongs to a ball arriving at
  the cloth at a pace of its own, and a hop from a screw shot has its own rule (`hopFromALowTip`).
- **The cushion is three-dimensional.** A ball does not meet a wall in the plane of the table: the
  nose stands 33.3375 mm up and the ball rides with its centre at 26.25 mm, so the ball meets the
  cushion **above its own equator** and its centre comes in a hair inside a radius — it tucks under
  the nose, and the aiming aid's ghost ball is drawn at that reach. The face is the shape `Table3D`
  draws — the leaning side cut back at 65°, the 3 mm round over the nose, the square band above it —
  and the collision is resolved against that section, with the ball's place *and height* and its
  full angular velocity. The impulse at the contact does three things: it reverses the ball along
  the face normal with the cushion's restitution; it rubs along the face, turning the ball about the
  **vertical** (side spin, so side spin still comes off a cushion at a modest angle) *and* about the
  **horizontal** axis along the cushion; and, because the contact is above the middle, it can throw
  the ball **up off the cloth**. A ball rolling into a cushion has its surface running down the face,
  and the friction that stops that slip takes most of the run off it — it comes away checking, with
  backspin against the way it is now going — and can lift it a few millimetres, which the rest of
  the simulation then handles: gravity brings it back, the bed bounces it, and it settles. A ball
  screwing *back* into a cushion has its backspin taken off the same way. The answer leans down as
  well as in along the nose's own section, so what comes straight back along the table is a little
  less than the figure along the face normal: the restitution is **0.87**, which tunes a square hit
  to come back at about **0.80** of its approach, a lively competition cushion. The jaws are cut from
  the same rubber and read the same figure, and the **throat** behind a jaw — the cut either side of a
  pocket, running from the jaw's round down to the hole — is cut in the cushion's own **section** too,
  so a ball meets the same leaning face there: tucked in under the nose, turned by the grip above its
  middle, and lifted by a hard one. What it is not is the same material: a facing on wood gives back
  half of what the rubber gives and grips what slides along it, which is what takes a ball into a
  corner at a shallow angle rather than throwing it out.
- **A cushion turns a hard ball back towards the normal.** A ball played fast into a cushion at an
  angle comes off at a *smaller* angle than it went in — the cushion's own grip, not a mirror. It is
  a few degrees, more the harder the ball is hit, and it never straightens the ball out: the probe's
  rolling ball into the cushion at 30° comes back at 26.4° at 0.7 m/s, 25.2° at 2 m/s and 22.5° at
  4 m/s. The rubber is an elastomer (a competition cushion is moulded to about **43 on the Shore A**
  scale, which fixes its modulus through Gent's relation), so a ball **sinks into it** by the Hertz impact
  depth — growing as the fourth fifth power of the approach speed, shrinking with the modulus. The
  modulus that matters is the one **under an impact**: Shore A is measured slowly, and rubber
  stiffens as it is deformed faster, about three times over between the Shore test and a
  millisecond-long hit (`cushionImpactStiffening`). Taking the hardness at face value sank the ball
  6 mm into the cushion at 3 m/s — a contact patch two thirds of the ball wide — and turned every
  hard ball back along the normal, which is not how a snooker cushion plays. The grip the dimple
  gives follows the square of the sink, so a slow shot barely denting the cushion keeps nearly all
  its angle and the effect comes on with speed. The speed dependence is the physics above; how the
  grip follows the depth is a tuned judgement, in `cushionGripDepth` (0.40: how deep the ball has to
  go for the cushion to have it completely), `cushionShoreA` and `cushionImpactStiffening`.

  The collision is solved as a **blend of two outcomes** rather than as one impulse after another,
  because the sliding friction and the grip work on the same contact and undo one another if they
  are taken in turn (the friction's sideways kick was being cancelled, and a hard cushion did not
  touch a spinning ball's side spin at all). The sliding outcome is the usual thing — the bounce
  along the normal with restitution, and friction rubbing out the slip, which is what turns the ball
  over and throws it. The **stuck** outcome leaves the ball along the face normal with its angular
  momentum about the contact point: it can turn — the rubber lets it — so the side spin it arrived
  with and the turning effect of the momentum across the face both go round the point it is held
  by, and a hard ball comes away spinning (the same three shots leave it turning at 8, 30 and 76 rad/s).
  The two are mixed in proportion to the grip, so the velocity *and* the spin come out of one
  consistent solve.
- Cushions are segments that stop at the pocket jaws, with rounded jaw tips standing tangent
  to the cushion faces, so balls can rattle in the jaws rather than shearing off them, and the
  middle pockets are real openings in the long cushions. **A jaw is not a different collider**: it
  is the same rubber, cut off where the pocket begins, and the section swept along a run is swept
  round the jaw's own 50 mm round, so a ball meets a jaw's nose above its equator exactly as it
  meets a run's and the whole collision above is shared — restitution, friction, the run taken off,
  the grip and the lift. A ball fired at a jaw at 30° comes off at the angle the straight cushion
  gives it, to within a degree, and comes away turning rather than merely reflected. A ball's centre
  has to pass into the pocket — through the mouth into the passage, or into the hole — before it is
  potted: a ball
  running along a cushion drops in a corner pocket, where the mouth is across its path, but
  runs past a middle pocket, where the cloth is still under it.
- A pocket is the one place the bed does not hold a ball up. Once a ball's centre is over the
  hole it falls the depth of the pocket (`Table.pocketDepth`, 110 mm) under gravity, and it is
  off the table when it reaches the bottom of the pocket, not when it crosses the rim. That is
  deeper than a ball is wide on purpose: a ball sinking into a pocket has to be out of sight
  before it is taken off the table, and at the 44 mm it started with it came to rest with the
  top of it still standing above the cloth, in view, so it was seen to fade away rather than to
  drop in. While it is in there it is a sphere in a closed cylinder the width of the hole: the
  sides, the back, and the near side, which is the rim of the hole doing the same job above the
  cloth — so the ball's centre cannot come within its own radius of any of it, and the room
  closes as the ball drops past the rim, which is the rim carrying the centre in as the ball
  tips over it. The walls are dead, with restitution 0.2, so a ball played in hard is stopped by
  the back of the pocket and drops from there rather than coming back out onto the cloth.
- **The wooden rail is a surface, and it is what "off the table" is measured against.** Beyond the
  cushion's line the cloth runs on over the wood of the surround — the cushion's own top and the rail
  behind it, out to the table's outer edge — and a ball can land on it, bounce, roll along it, come
  off its inner edge back onto the bed, or drop through the cut a pocket makes in it. The wood is
  played as the same cloth over something less stiff than the bed's slate: rolling resistance 0.014
  against the bed's 0.010, and restitution 0.4 against the bed's 0.5, so a ball dropped on a rail
  comes back about a sixth of its drop and a ball rolling along one goes about three quarters of the
  distance it would have covered on the bed. The nap is the *bed's* cloth and is not applied on a
  rail, whose strips are cut and laid along their own length. A ball whose centre is inside the wood
  is impossible — one that slips in behind a cushion, past a jaw, is turned back out into the playing
  area rather than left in the rail.

  Section 2 Rule 14 makes a ball **forced off the table** when it comes to rest otherwise than on the
  playing area or in a pocket, and the game now says what that means: a ball is off the table when it
  comes to rest **on** the wood of the rail (or on the top of a cushion over it), or when it goes
  **past** the wood, out over the floor. A ball merely *over* the wood — in the air across it, or
  rolling along it — is not off the table: it may still come back onto the cloth, and only what it
  does when it stops decides. A ball in the jaws is in the pocket's keeping, not off the table, and
  one over the hole is potted. What is off the table is taken out of the simulation at once rather
  than tracked on over the floor, so it never holds the stroke up: the stroke ends as soon as the
  balls still on the table stop, and the rules engine gets the ball as one forced off the table and
  applies the foul, the spotting and the in-hand cue ball.

## Tests

```bash
xcodebuild -project Snooker.xcodeproj -scheme Snooker -destination 'platform=macOS' test
```

or press `Cmd+U` in Xcode. 226 tests: the rules tests build situations directly (for example
"Black is the only ball left, so the first pot ends the frame"), the end-to-end tests place
the cue ball, aim, shoot, run the simulation and check the adjudication, and the camera
tests check where the player's eye ends up and where it is looking.

### Checking the 3D view without a screen

The 3D view can be rendered offscreen and reported as text, which is how it was checked
while it was being written:

```bash
Snooker.app/Contents/MacOS/Snooker --snapshots /tmp/snooker-snapshots
```

That writes a PNG for each of several positions — the break, the raised view, open play,
looking back down the table, the HUD over the table, the top-down view — and prints, for
each one, the exposure, the colour of the cloth and of every ball, a luminance map of the
frame, where the mouse steers the player's eye, and whether clicking the cloth lands where
it should. It also renders the room: the floor's size, its covering and the grey the carpet comes
out under the lights, read in patches from a render straight above past the rails, where the slab is
the only thing the camera finds; the six legs, counted and placed against the frame and read back off
a render at the height of a leg's middle; the four big lamps, one by one against the places of the
four spot lights; the ring of twenty small ones, its rectangle, its pitch, **the lamp at each of the
four corners** and that the ring is lit by nothing at all — the carpet under a lamp is read against the
carpet between two of them, and the lights in the room are counted, because eight is all any one
object may be given; and what the balls reflect of the room, the up face of the capture they are given
holding the lamps. It also renders the table from straight
above and reads the colour of the
pockets, the rails, the cushions and the markings off it, checks the shape of the cloth,
slate and rail as paths (does the cloth stop at the jaws, is the pocket cut through the
slate, does the rail wrap round it, is the wood level with the cushion and flush with its
back, are there six pieces and do they meet, and is the wood's own cut round each pocket the
mouth's width at the top of the wood, leaning at the jaws' 65°, so that it is the line the two jaws'
feet stand on at the level of the cloth, with the hole cut a millimetre wider again than that on each
side, and 11 mm wider at a corner — with
the 5 mm of cushion above the nose standing square, the wood's
top level with it, and the join between a jaw and the run of cushion it was cut from flush at
38.3375 mm on both sides of the seam), and measures the lighting at several levels.
The physics probe takes a ball into a pocket at two speeds and reports the fall: whether it
left the bed at the rim of the hole, how far it fell, whether it reached the back of the
pocket and how much speed that took off it, and when it was potted. It drops a ball onto the
cloth as well, and reports where it bounced back up to. It also reports where a potted ball
comes to rest — the top of it against the 110 mm depth of the pocket and the 44 mm the well is
drawn — so a ball that was still in view as it was taken away would be caught.
It reports the swerve as well: the same side-spun shot with the cue up at nothing, 15°, 30° and
45°, and how far each comes off the line of aim (18 mm, 104, 161 and 165 — the level one only
squirted) and how high each hopped; and then a ball lifted hard enough to clear another one, which
is reported as the jump shot the rules call a foul. A lifted cue is checked to still meet the ball
on the same sphere — a radius plus the gap — however far up it is stood, and the player down on the
shot with it: the eye comes up with the cue, keeping its 209 mm of daylight over it (235 mm above the
cloth level, 855 at 45°). It walks the player about the table as well — reporting where they end up
and that their body is still clear of the wood — and puts the cue away and lays it again, checking
that the player stands off the ball on the line of the cue and clear of the table. Down on the shot
over the middle of the table it reports the camera **0.000 mm off the line of the cue** and 450 mm
inside the side — the eye-to-waist reach, which is as far as it may lean.
The geometry probe reads the jaws off the model the renderer builds from: the 56.5968° a corner jaw
used to be leaned at appears nowhere — they stand at **65.0°** to the cloth at a corner jaw and at a
middle pocket's alike, and the same 65.0° at the end of the round and where they run into the wood. It reads
the depth of a jaw's foot behind its nose — 16.9 mm, the cushion's own undercut — and measures the
hole's rim against the jaw's own side where that side crosses the level of the cloth: **1.00 mm
outside** it at a middle pocket and **11.00 mm** at a corner — the clearance the hole is cut by,
the corner's being that much more — to a tenth of a millimetre. It also reports how many triangles
each jaw solid is drawn with and the heights its
sides span, and reads the normals back off the built jaw to report how far the shading of its side
turns from one step of the path to the next: a side left to be shaded a facet at a time would step
by the whole facet angle at every join in it. It reads the normals off **both** solids at each join
between a jaw and the run of cushion it was cut from as well — the run's last point against the jaw's
first, at the foot of the flush line they meet on — and they come out 0.9° apart at every one of the
six, so the reflection reads on across the join.
It reads the wood's own **outer edge** back off the built rail as well: the section of the rim over
the bottom middle pocket, taken between the two cuts where the edge runs straight, comes out a
**15.00 mm** radius — the top edge in by the whole radius and the round running down to the square
side at 23.34 mm, the wood's 38.34 mm top less the round — so the frame's rim is a bull nose and not
a bare arris. And it walks all six pieces of the rim to check the round runs the whole way round:
**all 140** points of the six pieces' outer edges come in by at least the radius at the top, so no
stretch of the rim is left square. It reads the two pieces' shading normals at each of the six joins as
well, over the whole of the rim's round-over, and they come out **0.0° apart** — the reflection reads
on from one piece to the next with nothing at the join to see.
The fabric probe reads the cloth and the ball materials back off the built scene — roughness,
metalness, clear coat, whether the weave and the nap are there — and then looks along the cloth
from each end of the table, reporting the colour, mean and spread of the light there: looking
away from the baulk, along the nap, the cloth should show a wider, tighter sheen than looking
back down the table into the fibres.
`--lighting-probe` adds the sweep of light levels and two views of the light rig itself, and
reads back where the renderer put each of the three plates, how big it is and how far it is
turned down. It also measures the shadow under a ball — the cloth at a ball's foot comes out a
few per cent darker than the same cloth with the lights casting nothing (1.8% in luminance 28 mm
from the ball) — and what a ball reflects: with the capture in place the lower half of a ball is
lit by the room under it, and with it removed that half comes up darker and flatter.
The **cue's own shadow** is measured too, and it is the hardest thing on the table to cast. The cue is
9.8 mm across at the tip and the lamps' shadow-map texels are 3.7 mm of cloth, so the probe renders the
player's own view twice — with the lights casting and with them not — and reads the difference, which is
the shadow and nothing else: how deep the shadow comes out, how it falls away — drawn against a fixed
scale, so one tuning can be read against the next — and how far the centre of one strip of it wanders
from the straight line it should lie on, with the worst step from one row of pixels to the next. A
staircase is a wander in steps the size of a texel; a smooth edge is a wander of less than a pixel in
steps of nothing.
And the probes that are not about a picture: **the frame rate the scene asks for** at each point in a
frame of play (a table nobody is touching, the player standing at it, the shot being played), **how
often the spin limit is worked out** (once per change of the cue's angle, and not per frame), **a shot
played ten ways** to show which ways of going on through the ball are second hits and which are
follow-throughs, and **the log a break leaves behind** — the break itself, said once, and nothing said
of the strokes that made it.
`--inspect <png>` reports on any image, including a screenshot of the running app.
`--sound-check [directory]` builds every synthesised sound, reports how long each is and how loud, and
starts the audio engine, so the whole of the audio path can be checked where there is nothing to listen
to — and writes each sound out as a WAV when it is given a directory.
