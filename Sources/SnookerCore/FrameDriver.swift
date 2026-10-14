import Foundation

/// Drives a frame: owns the rules engine and the physics world, runs the stroke
/// simulation and decides what the player may do next. This is UI-free, so the whole
/// gameplay loop can be tested without a window.
public final class FrameDriver {
    public enum Mode: Equatable, Sendable {
        case aiming
        case charging
        case simulating
        case placingCueBall
        case decision
        case frameOver
    }

    /// A contact the frame has just made, as the **view** needs it: what kind, where on the table, and
    /// how hard. The game makes no sound of its own — this is the whole of what a sound needs, and the
    /// view plays it or does not. Nothing that is not reported here has any noise to it.
    public struct Impact: Equatable, Sendable {
        public enum Kind: String, Sendable, CaseIterable {
            /// The tip on the cue ball: the stroke itself. `speed` is the cue ball's speed away.
            case strike
            /// Two balls collided.
            case ballOnBall
            /// A ball on the rubber: a straight cushion or a jaw.
            case cushion
            /// A ball on the cut of a pocket behind a jaw — dead wood, not rubber.
            case throat
            /// A ball on the cloth-covered wood of the rail.
            case rail
            /// A ball coming back down on the cloth of the bed and bouncing.
            case bed
            /// A ball that was forced off the table reaching the floor.
            case floor
            /// A ball reaching the bottom of a pocket.
            case pocket
            /// The stick knocking a ball in play (a foul).
            case cueOnBall
        }

        public var kind: Kind
        /// Where it happened, in the table's own plane — what a pan is worked out from.
        public var at: Vec2
        /// How hard: the impact speed in mm/s. 0 means a contact with no speed of its own — a pot.
        public var speed: Double

        public init(kind: Kind, at: Vec2, speed: Double) {
            self.kind = kind
            self.at = at
            self.speed = speed
        }
    }

    public private(set) var game: SnookerGame
    public private(set) var world: PhysicsWorld
    public private(set) var mode: Mode = .aiming

    /// Which frame of the match this is, counting from one. A frame is a frame of snooker: the balls
    /// are racked and the scores start afresh, while the frames each player has won are carried over.
    /// `N` starts the next one.
    public private(set) var frameNumber: Int = 1

    /// How many frames each player has won. A frame counts for its winner the moment it ends, and for
    /// nobody when it is level. A re-rack is the same frame played again (Section 3 Rule 17), so a win
    /// already counted for it comes back off the board.
    public private(set) var framesWon: [Int] = [0, 0]

    /// Whether the frame in progress has already been counted, so that it is counted once however many
    /// times the next mode is decided.
    private var haveCountedTheFrame = false

    /// The cue ball's speed at full power **on a centre hit**, in mm/s: the top of the range everything
    /// about a shot is measured against — the strength meter's far end, and the speed a centre-ball strike
    /// sends the ball away at. Both ways of playing a shot set the **cue's** own speed
    /// (`maxCueSpeed`) and the ball's speed comes out of the strike: see `ballSpeed(fromCueSpeed:tipOffset:)`
    /// and `beginStroke(cueSpeed:followThrough:)`.
    public static let maxPower: Double = 6000

    // Aiming
    /// The way the player is facing. Setting it settles the cue at the ball again: turning the aim turns
    /// the cue about the ball, and what is behind the ball changes with the line. See `settleTheCue`.
    public var aimAngle: Double = 0 {
        didSet {
            if aimAngle != oldValue {
                settleTheCue()
                // While the ball on is a colour of the striker's own choice, the colour the cue is on is
                // taken as their nomination, and answering the question with the aim settles what they may
                // do next. See `nominateTheColourTheCueIsOn`.
                if nominateTheColourTheCueIsOn() { decideNextMode() }
            }
        }
    }
    public var power: Double = 0.35
    public var spinSide: Double = 0
    public var spinVertical: Double = 0
    /// The angle the cue stands at, in radians — the cue's own elevation, not an offset from level:
    /// what the widget reads, what the cue is drawn at, and the angle the strike is played along. It
    /// runs from the floor the player's own stance gives it (`Table.cueStanceElevationDegrees`, level)
    /// up to as far as a cue can be stood without scooping the ball (`PhysicsWorld.maxCueElevation`,
    /// 90°). A lifted cue is what plays a swerve — the ball is struck down at an angle, so its spin is
    /// tilted with the cue and the cloth curves it — and the elevation key (B) puts the mouse on it. It
    /// goes back down to the stance after every stroke, like the tip goes back to the middle.
    public var cueElevation: Double = Table.cueStanceElevation
    public var pointer: Vec2 = Vec2(Table.length / 2, Table.centreY)

    // MARK: Up and about

    /// What the player is doing with the cue while they are standing up at the table (the `C` key).
    public enum CueHandling: String, Sendable {
        /// The cue is put away: the player walks about the table and looks where they like.
        case putAway
        /// The cue is laid on the table, pointing from the player to the cue ball: the player stands by
        /// the cue, and the camera comes round the line of aim as the shot is aimed.
        case laid

        /// What the `C` key offers from here.
        public var toggled: CueHandling { self == .putAway ? .laid : .putAway }
        public var title: String {
            toggled == .laid ? "Lay the cue on the table" : "Put the cue away"
        }
    }

    /// What the player is doing with the cue while standing. Laying it puts the camera on the line of
    /// the cue; putting it away lets them walk.
    public private(set) var cueHandling: CueHandling = .laid

    /// Where the player's feet are when the cue is put away and they are walking about.
    private var walkingPosition = Vec2(Table.baulkLineX - PlayerCamera.Preset.standing.standOff,
                                       Table.centreY)

    /// Where the player's body is. With the cue put away it is where they have walked to; with the cue
    /// laid it is on the line of the cue, standing the standing stand-off back from the ball — and no
    /// closer to the table than their body allows, so shooting across the table they stand right at it.
    public var playerPosition: Vec2 {
        guard cueHandling == .laid, let cue = cueBall, cue.onTable else { return walkingPosition }
        let away = Vec2(-cos(aimAngle), -sin(aimAngle))
        let standOff = max(PlayerCamera.Preset.standing.standOff,
                           PlayerWalk.clearStandOff(from: cue.position, away: away))
        return cue.position + away * standOff
    }

    /// Walks the player `forward` — along the way they are looking — and `sideways` to their right,
    /// over `dt` seconds, at the walking pace. Nothing happens while the cue is laid: the player stands
    /// by the cue then, and the camera comes round it instead.
    public func walk(forward: Double, sideways: Double, over dt: Double) {
        walk(byForward: forward * PlayerWalk.pace * dt, sideways: sideways * PlayerWalk.pace * dt)
    }

    /// Walks the player a **distance** — `forward` along the way they are looking and `sideways` to their
    /// right, in millimetres — rather than at the walking pace over a time.
    ///
    /// This is the walk the **mouse** drives: what the hand has moved across the desk is a distance and
    /// not a speed, so the player goes as far as the mouse has moved and stops when it stops, rather than
    /// following the frame rate. The held-arrow walk is the other way round and comes through the pace
    /// above. Nothing happens while the cue is laid: the player stands by the cue then, and the camera
    /// comes round it instead.
    public func walk(byForward forward: Double, sideways: Double) {
        guard cueHandling == .putAway else { return }
        walkingPosition = PlayerWalk.step(from: walkingPosition,
                                          forward: forward,
                                          sideways: sideways,
                                          yaw: aimAngle)
    }

    /// The `C` key: puts the cue away so that the player may walk about, or lays it on the table,
    /// pointing from where they stand at the cue ball.
    public func toggleCueHandling() {
        switch cueHandling {
        case .putAway:
            // Lay it along the line from where the player stands to the ball, so it points at the ball.
            if let cue = cueBall, cue.onTable {
                aimAngle = atan2(cue.position.y - walkingPosition.y, cue.position.x - walkingPosition.x)
                pointer = cue.position + Vec2(cos(aimAngle), sin(aimAngle)) * 600
            }
            cueHandling = .laid
            settleTheCue()
            // With the balls running the cue is a thing on the table: laying it again puts it down
            // behind the cue ball, at rest, wherever the cue ball has got to.
            if mode == .simulating, let cue = cueBall, cue.onTable {
                placeTheCueAfterTheStrike(of: cue, at: 0)
            }
        case .laid:
            // Put it away: the player **stands up** with it — you cannot be down on the shot without a
            // cue — and then walks on from where they were standing. That is what frees them to look
            // about and walk around while the balls run, if they want to watch them from elsewhere.
            // Standing up on its own leaves the stick on the table (see `standUp`), so it is *this* that
            // takes it off: with the cue in the player's hands there is nothing for a ball to meet.
            let whereTheyWere = playerPosition
            standUp()
            world.cue = nil
            walkingPosition = PlayerWalk.clearOfTheTable(whereTheyWere)
            cueHandling = .putAway
        }
    }

    // Feedback
    public private(set) var status: String = ""
    public private(set) var commentary: [String] = []
    public private(set) var lastStroke: StrokeReport?
    public private(set) var lastResult: TurnResult?
    public private(set) var flash: String?

    private var chargeStart: TimeInterval?
    private var simulationClock: Double = 0
    private var strokeCueStart: Vec2 = .zero
    /// Where every ball was when the stroke was played, so that the ones that moved can be told from
    /// the ones that did not (Rule 8(b), the push stroke).
    private var positionsBeforeStroke: [Int: Vec2] = [:]
    private var report = StrokeReport()
    private var contactedCueBalls: [Int] = []
    /// Balls the stick itself has touched during the stroke: see `StrokeReport.ballsTheCueTouched`.
    private var ballsTheCueTouched: [Int] = []

    /// What this frame has made a noise with, in the order it happened. The view drains it once a
    /// frame with `takeImpacts()`, so a contact is played on the frame it was made and never twice.
    public private(set) var impacts: [Impact] = []

    /// Takes the impacts this frame has made and clears them: the view's once-a-frame read.
    public func takeImpacts() -> [Impact] {
        defer { impacts.removeAll() }
        return impacts
    }

    public init(playerNames: [String] = ["Prof. Snoo", "Dr. Ker"]) {
        self.game = SnookerGame(playerNames: playerNames)
        self.world = FrameDriver.makeWorld(for: game.state)
        game.beginFrame(startingPlayer: 0)
        syncWorldFromState()
        mode = .placingCueBall
        canRepositionCueBall = true
        status = "\(game.state.currentPlayerName) to break: click inside the D to place the cue ball."
    }

    // MARK: - World <-> state

    static func makeWorld(for state: GameState) -> PhysicsWorld {
        var balls: [Ball] = []
        for (id, position) in state.ballPositions {
            guard let color = BallID.colour(of: id) else { continue }
            let onTable = state.ballsOnTable.contains(id)
            balls.append(Ball(id: id, color: color, position: position, onTable: onTable))
        }
        return PhysicsWorld(balls: balls.sorted { $0.id < $1.id })
    }

    /// Rebuild the physics world from the rules engine's ball layout.
    public func syncWorldFromState() {
        let falling = world.balls.filter(\.isFalling)
        world = FrameDriver.makeWorld(for: game.state)
        // A ball on its way to the floor is off the table already, so a world built from the state would
        // have it gone. It is carried over instead, and goes on falling until it lands.
        for ball in falling { world.putBack(ball) }
        // The balls have moved, so what is behind the cue ball has changed with them: settle the cue
        // where it can be laid before anything reads it.
        settleTheCue()
    }

    private func writePhysicsPositionsIntoState() {
        game.withState { state in
            for ball in world.balls where ball.onTable {
                state.ballPositions[ball.id] = ball.position
            }
        }
    }

    // MARK: - Queries for rendering

    public var balls: [Ball] { world.balls }
    public var cueBall: Ball? { world.ball(id: BallID.cue) }

    public var ballOnDescription: String {
        let state = game.state
        switch state.ballOn {
        case .red:
            return state.freeBallNominee.map { "Free ball (\($0.rawValue)) as a Red" } ?? "Red"
        case .anyColour:
            return state.nominatedColour.map { $0.rawValue.capitalized } ?? "Colour (choose)"
        case .colourOfSequence(let colour):
            return colour.rawValue.capitalized
        }
    }

    public var scores: [Int] { game.state.scores }
    public var playerNames: [String] { game.state.players.map(\.name) }

    /// True while the ball on is a colour of the striker's own choice, so that the colours can stay
    /// on offer until they play the stroke.
    public var isPlayingForAColour: Bool {
        if case .anyColour = game.state.ballOn { return true }
        return false
    }

    /// The colour the striker has chosen, once they have chosen one.
    public var nominatedColour: BallColor? { game.state.nominatedColour }

    /// The colours on the table, in the order they are offered to a striker choosing one. The question
    /// carries them too, but a striker who has answered it with the aim — before it was ever put on the
    /// screen — still has every one of them to change their mind with.
    public var coloursOnTheTable: [BallColor] {
        BallColor.coloursInAscendingOrder.filter { colour in
            guard let id = BallID.colourID(colour) else { return false }
            return game.state.ballsOnTable.contains(id)
        }
    }

    /// True while the game is asking the striker which colour is on.
    public var isChoosingAColour: Bool {
        if case .nominateColour = game.state.pending { return true }
        return false
    }

    /// Whether the colour being played for was nominated **by hand** — with the buttons or the number keys
    /// — since the last stroke. Until it has been, the colour the cue is pointing at is taken as the
    /// nomination; from then on the choice is the striker's and looking about does not take it away from
    /// them. See `nominateTheColourTheCueIsOn`.
    private var theStrikerChoseTheColourByHand = false

    /// True when the striker may play: over a shot, or while being asked which colour is on. A
    /// stroke played without having declared one is a foul, but it is the striker's stroke to
    /// play, and the game calls the foul rather than refusing the shot.
    public var canStrike: Bool {
        // The cue has to be on the table to play a stroke: with it put away the player is only walking.
        !isAskingAboutANewFrame && !isAskingAboutAReRack && !isAskingAboutANewGame && cueHandling == .laid
            && (mode == .aiming || (mode == .decision && isChoosingAColour))
    }

    // MARK: - Laying the cue at the ball

    /// How far up the game will stand the butt of the cue for the player before it stops lifting and
    /// puts top spin on the ball instead.
    ///
    /// A cue stood up is a different shot — it strikes down into the cloth — so the game does not stand
    /// it up without being asked. This is as much as a player would raise it themselves when the
    /// cushion behind the ball gives them no choice, and past it the cure is the tip: put up the ball's
    /// face, where it lifts the *line of the stick* with it (see `PhysicsWorld.cueLine`) and buys the
    /// last of the room with a shot a player can play, rather than a cue stood on end.
    public static let automaticLiftCap: Double = 10 * .pi / 180

    /// How far up the ball's face the game will put the tip for the player when lifting the butt is not
    /// enough: as far as the spin limit allows at the cap's own angle, so that what is drawn is what is
    /// struck — see `PhysicsWorld.spinLimit`.
    public static let automaticTopSpin: Double =
        PhysicsWorld.spinLimit(angle: .pi / 2, elevation: automaticLiftCap)

    /// The **first cap** a spin change is stopped at: 10 degrees, the same 10° a place is settled to,
    /// because it is the same question (is the stick clear of what is behind the ball?) asked about a
    /// spin rather than a place. The butt comes up to here in 0.5° steps and stops: what happens at the
    /// cap is the **tip**, not more cue — see `spinLiftTop` and `setSpin`.
    public static let spinLiftFirstCap: Double = automaticLiftCap

    /// The **second cap** a spin change is allowed: 30 degrees, as far as the butt will carry on standing
    /// the cue up with the spin the player asked for when lifting the tip at the first cap was not enough
    /// either.
    ///
    /// Past this the butt stops altogether and the **spin** is settled instead, to what the cue has room
    /// for at the angle it has been left at. `spinLiftCap` is the far end of the family a spin change
    /// belongs to, which the second cap bites well before.
    public static let spinLiftSecondCap: Double = 30 * .pi / 180

    /// The far end of the family a **spin change** belongs to, 37 degrees: the bound the second cap sits
    /// under, so no spin change is ever settled past 30° (see `setSpin`).
    public static let spinLiftCap: Double = 37 * .pi / 180

    /// How far up the ball's face the game will put the tip when it **lifts the tip** at the first cap:
    /// the spin limit at the angle the tip is at while it is lifted — the cap's own 10°, since the
    /// elevation does not move while it does. It is the same 0.54 of a radius a settle tops a ball to,
    /// and for the same reason: it is the most the ball can hold at that angle, so what is drawn is what
    /// is struck — see `PhysicsWorld.spinLimit`.
    public static let spinLiftTop: Double =
        PhysicsWorld.spinLimit(angle: .pi / 2, elevation: spinLiftFirstCap)

    /// How finely the game feels its way up to a pose the cue fits in, in radians of elevation.
    private static let settleStep: Double = 0.5 * .pi / 180

    /// Whether the cue has room behind the ball at a pose. See `PhysicsWorld.cueFits`.
    private func cueFits(elevation: Double, side: Double, vertical: Double, draw: Double) -> Bool {
        guard let cue = cueBall, cue.onTable else { return true }
        return world.cueFits(cueBallID: BallID.cue, yaw: aimAngle, elevation: elevation,
                             side: side, vertical: vertical, draw: draw)
    }

    /// How far the cue can be drawn back from its rest place, in millimetres: as much as the player's
    /// hand would take it, or as much as there is room for behind the ball, whichever is less.
    ///
    /// The room runs out where the cue stops fitting: the stick is swept over the whole of the draw, so
    /// this is walked out from the backswing the cue is known to have (the settle saw to that) until a
    /// draw is found that it has no room for.
    public var maximumCueDraw: Double {
        guard let cue = cueBall, cue.onTable else { return FrameDriver.maxCueDraw }
        if cueFits(elevation: cueElevation, side: spinSide, vertical: spinVertical,
                   draw: FrameDriver.maxCueDraw) { return FrameDriver.maxCueDraw }
        var draw = FrameDriver.minimumCueDraw
        while draw < FrameDriver.maxCueDraw {
            let next = min(FrameDriver.maxCueDraw, draw + 20)
            if !cueFits(elevation: cueElevation, side: spinSide, vertical: spinVertical, draw: next) {
                return draw
            }
            draw = next
        }
        return FrameDriver.maxCueDraw
    }

    /// Whether there is room behind the ball to play a stroke at all. A stroke needs a backswing: with
    /// no room to draw the cue back, letting it go would be a push and not a shot, and the game does
    /// not offer one.
    public var hasRoomForTheCue: Bool {
        maximumCueDraw >= FrameDriver.minimumCueDraw
    }

    /// Whether a level cue has no room where the player wants it, so that the game has had to stand the
    /// cue up — and top the ball, if it must — to find the stick room behind it. It is a question about
    /// the **place** and not about what the game has just done, so it holds whenever the player is
    /// aiming in one. Nothing is said about it on the screen: the cue's own angle is on the widget, and
    /// the picture shows what it is doing.
    public var needsTheCueStoodUp: Bool {
        guard mode == .charging || canStrike, let cue = cueBall, cue.onTable else { return false }
        return !cueFits(elevation: Table.cueStanceElevation, side: 0, vertical: 0,
                        draw: FrameDriver.minimumCueDraw)
    }

    /// Lays the cue at the ball where it can be laid: the player's own elevation and spin, moved by as
    /// little as it takes for the stick to have room behind the ball.
    ///
    /// This is what keeps the cue on the table. Rather than take the cue away when the ball is up
    /// against a cushion — or let it be drawn through one — the game settles it: the butt comes up, no
    /// further than `automaticLiftCap`, and if that is not enough the tip goes up the ball's face,
    /// which lifts the line of the stick with it; only if even that will not do does the butt go up
    /// past the cap. What it leaves behind is the player's own pose for everything that follows — the
    /// widget, the picture and the stroke all read it — and the player can carry on from there.
    ///
    /// Returns false in the one case where nothing fits (a ball resting against the back of the cue
    /// ball in a corner, say), leaving the cue standing at its last resort rather than taking it away.
    @discardableResult
    public func settleTheCue() -> Bool {
        guard let cue = cueBall, cue.onTable else { return true }
        guard !cueFits(elevation: cueElevation, side: spinSide, vertical: spinVertical,
                       draw: FrameDriver.minimumCueDraw) else { return true }

        // 1. The butt comes up, as far as the game will lift it for the player.
        var lift = cueElevation
        while lift < FrameDriver.automaticLiftCap - 1e-9 {
            lift = min(FrameDriver.automaticLiftCap, lift + FrameDriver.settleStep)
            if cueFits(elevation: lift, side: spinSide, vertical: spinVertical,
                       draw: FrameDriver.minimumCueDraw) {
                cueElevation = lift
                return true
            }
        }
        // 2. Hold it there and put the tip up the ball's face: a topped ball stands the line of the
        //    stick up with it, and that is the last of the room a lift within the cap can find.
        var top = spinVertical
        while top < FrameDriver.automaticTopSpin - 1e-9 {
            top = min(FrameDriver.automaticTopSpin, top + 0.1)
            if cueFits(elevation: FrameDriver.automaticLiftCap, side: spinSide, vertical: top,
                       draw: FrameDriver.minimumCueDraw) {
                cueElevation = FrameDriver.automaticLiftCap
                spinVertical = top
                return true
            }
        }
        // 3. Even that was not enough — a ball resting against the back of the cue ball wants about
        //    20° — so the butt goes up past the cap, topped, rather than the cue coming off the ball.
        spinVertical = FrameDriver.automaticTopSpin
        while lift < PhysicsWorld.maxCueElevation - 1e-9 {
            lift = min(PhysicsWorld.maxCueElevation, lift + FrameDriver.settleStep)
            cueElevation = lift
            if cueFits(elevation: lift, side: spinSide, vertical: FrameDriver.automaticTopSpin,
                       draw: FrameDriver.minimumCueDraw) { return true }
        }
        cueElevation = PhysicsWorld.maxCueElevation
        return false
    }

    /// The furthest a change may be taken: all the way when the cue has room for it, none of it when it
    /// has not, and as much of it as fits in between. `allowed` says whether the cue fits at a point on
    /// the way between the two.
    private func asFarAsItFits(from: Double, to: Double, allowed: (Double) -> Bool) -> Double {
        if allowed(to) { return to }
        guard allowed(from) else { return from }
        var low = from, high = to
        for _ in 0..<7 {
            let middle = (low + high) / 2
            if allowed(middle) { low = middle } else { high = middle }
        }
        return low
    }

    /// The room a **spin change** buys with the tip when the butt cannot buy it: walking the tip up the
    /// ball's face from `from` in 0.1 steps, keeping the side `side`, and stopping at the smallest lift
    /// the cue has room for at `elevation` — or nil when the top of the face will not do it. A topped
    /// ball stands the *line of the stick* up with it (`PhysicsWorld.cueLine`), which is the same room
    /// standing the butt up buys, bought with the shot instead of the cue.
    ///
    /// Nothing else lifts the tip for the player: the cue's own changes are stopped where the room runs
    /// out, the butt coming down into something among them — see `adjustElevation`.
    ///
    /// The lift stops at `spinLiftTop`, the most top the ball can hold at the angle a lift is made at
    /// (`PhysicsWorld.spinLimit`), and it never takes the tip off the ball: with a side on it, the face
    /// runs out sooner than that, at `sqrt(1 - side²)` of a radius.
    private func liftedTip(at elevation: Double, side: Double, from vertical: Double) -> Double? {
        let limit = min(FrameDriver.spinLiftTop, (max(0, 1 - side * side)).squareRoot())
        var top = vertical
        while top < limit - 1e-9 {
            top = min(limit, top + 0.1)
            if cueFits(elevation: elevation, side: side, vertical: top, draw: 0) { return top }
        }
        return nil
    }

    public var currentPlayer: Int { game.state.currentPlayer }
    public var breakScore: Int { game.state.breakScore }
    public var remainingPoints: Int { game.remainingPoints() }

    /// True when the player at the table cannot win the frame on the balls alone: they are further behind
    /// than the points still on the table, so nothing but fouls — snookers — will bring them back. Level
    /// deficits are not enough: a striker who can catch up exactly needs the balls, not snookers.
    public var theStrikerNeedsSnookers: Bool {
        let scores = self.scores
        guard scores.count >= 2, !game.state.frameOver else { return false }
        return scores[currentPlayer] + remainingPoints < scores[1 - currentPlayer]
    }
    public var pending: PendingDecision? { game.state.pending }
    public var isFrameOver: Bool { game.state.frameOver }
    public var winner: Int? { game.state.winner }
    public var cueBallInHand: Bool { game.state.cueBallInHand }

    /// True while the player may still move the cue ball about: it was given to them in hand and they
    /// have not struck it yet. Putting it down does not commit them to that spot (Section 3 Rule 5).
    public private(set) var canRepositionCueBall = false
    public var missWarning: Bool { game.state.missWarning }

    // MARK: - The referee

    /// The balls the cue ball is resting against that are on, or could be on (Rule 8). Empty unless
    /// the balls are at rest, since a touching ball is called at the completion of a stroke.
    public var touchingBalls: [Int] {
        switch mode {
        case .aiming, .decision, .placingCueBall: return game.touchingBallsOn()
        case .charging, .simulating, .frameOver: return []
        }
    }

    /// The referee's call for the screen: the touching ball, if there is one.
    public var refereeCall: String? { game.touchingBallCall }

    // MARK: - Player input

    public func movePointer(to tablePoint: Vec2) {
        pointer = tablePoint
        if let cue = cueBall, cue.onTable, mode == .aiming || mode == .charging {
            let delta = tablePoint - cue.position
            if delta.length > 1 {
                aimAngle = atan2(delta.y, delta.x)
            }
        }
    }

    /// Turns the aim by `radians` — the arrow keys' fine aim — taking the pointer round with it, and
    /// settles the cue at the ball again as the aim moves: see `settleTheCue`.
    public func turnTheAim(by radians: Double) {
        aimAngle += radians
        if let cue = cueBall, cue.onTable {
            pointer = cue.position + Vec2(cos(aimAngle), sin(aimAngle)) * 600
        }
    }

    /// Moves the contact point of the tip on the cue ball, the E key's job: `side` towards the
    /// striker's right, `vertical` towards the top of the ball for follow, down for screw back.
    /// Offsets are fractions of the ball's radius, and they stop at `PhysicsWorld.spinLimit` for the
    /// angle the cue is standing at — inside the leather's grip, and inside where the ball can still
    /// get away from the tip.
    public func adjustSpin(side: Double, vertical: Double) {
        setSpin(side: spinSide + side, vertical: spinVertical + vertical)
    }

    /// Puts the tip where the player asks on the ball's face, as far as the cue has room for.
    ///
    /// What is being found is **room**, not spin: a tip that would carry the stick into something behind
    /// the ball is answered by posing the cue differently, never by taking it off the ball, and the game
    /// works through five steps to find a pose that has room for what the player asked for:
    ///
    /// 1. Room where the cue stands: the tip goes there.
    /// 2. Otherwise the butt **comes up**, 0.5° a step, stopping at the **first cap**
    ///    (`spinLiftFirstCap`, 10°) — a cue stood up is a different shot, so the game does not stand it
    ///    up without being asked.
    /// 3. At the first cap it stops standing the cue up and **lifts the tip** instead: further up the
    ///    ball's face, keeping the side the player asked for, no further than `spinLiftTop`. A topped
    ///    ball stands the *line of the stick* up with it (`PhysicsWorld.cueLine`), which is the same room
    ///    the butt was buying, bought with the shot instead of the cue. The elevation does not move while
    ///    it does.
    /// 4. If that is not enough either, the butt **carries on to the second cap** (`spinLiftSecondCap`,
    ///    30°) with the spin unchanged: the room there is bought with the cue, so the lift of step 3 is
    ///    given back and what the player asked for is posed at the angle that has room for it.
    /// 5. Only past both caps is the **spin settled** to what fits, at the angle the cue has been left at
    ///    — the second cap.
    ///
    /// The short of it: the spin the player asks for is what the shot is played with wherever the cue can
    /// be laid for it, the lift is kept only when it is the lift itself that bought the room, and the
    /// player is never left with a pose the cue cannot be laid at.
    public func setSpin(side: Double, vertical: Double) {
        // The player may put the tip where they like on the ball: the spin graph **shows** where a
        // strike would slip (a miscue) or leave the ball able to be caught by the cue, but it does not
        // stop the tip being put there — see `PhysicsWorld.spinRange` for the boundaries it draws. All
        // that is settled here is that the tip stays **on the ball**: an offset of more than a radius
        // is not a contact at all. Taken across the ball and up it together, on the line being pushed.
        let angle = atan2(vertical, side)
        let wanted = min(1, (side * side + vertical * vertical).squareRoot())
        let wantedSide = wanted * cos(angle)
        let wantedVertical = wanted * sin(angle)
        // 1. Room where the cue stands, and the tip goes there.
        if cueFits(elevation: cueElevation, side: wantedSide, vertical: wantedVertical, draw: 0) {
            spinSide = wantedSide
            spinVertical = wantedVertical
            return
        }
        // 2. No room there: the butt comes up, 0.5° a step, stopping at the first cap. A place that has
        // already been settled may have left the cue standing above the cap — the butt never comes back
        // down for a spin, so the steps it has taken are the steps it keeps.
        var lift = cueElevation
        while lift < FrameDriver.spinLiftFirstCap - 1e-9 {
            lift = min(FrameDriver.spinLiftFirstCap, lift + FrameDriver.settleStep)
            if cueFits(elevation: lift, side: wantedSide, vertical: wantedVertical, draw: 0) {
                cueElevation = lift
                spinSide = wantedSide
                spinVertical = wantedVertical
                return
            }
        }
        // 3. Stood up as far as the game will take the butt, and still no room: **lift the tip, not the
        // butt.** From where the player put it, the tip goes further up the ball's face with the side
        // they asked for, and the topped ball stands the line of the stick up with it. The elevation
        // does not move while it does.
        let held = max(lift, FrameDriver.spinLiftFirstCap)
        if let top = liftedTip(at: held, side: wantedSide, from: wantedVertical) {
            cueElevation = held
            spinSide = wantedSide
            spinVertical = top
            return
        }
        // 4. Not enough either: the butt carries on to the second cap with the spin unchanged. The lift
        // of step 3 bought nothing, so it is given back and the room is found with the cue instead.
        while lift < FrameDriver.spinLiftSecondCap - 1e-9 {
            lift = min(FrameDriver.spinLiftSecondCap, lift + FrameDriver.settleStep)
            if cueFits(elevation: lift, side: wantedSide, vertical: wantedVertical, draw: 0) {
                cueElevation = lift
                spinSide = wantedSide
                spinVertical = wantedVertical
                return
            }
        }
        // 5. Past both caps: the cue is left standing at the second cap and the spin is settled to what
        // fits there — as much of the player's ask as that angle has room for.
        cueElevation = max(cueElevation, FrameDriver.spinLiftSecondCap)
        var low = 0.0, high = 1.0
        for _ in 0..<7 {
            let middle = (low + high) / 2
            let candidateSide = spinSide + (wantedSide - spinSide) * middle
            let candidateVertical = spinVertical + (wantedVertical - spinVertical) * middle
            if cueFits(elevation: cueElevation, side: candidateSide, vertical: candidateVertical,
                       draw: 0) {
                low = middle
            } else {
                high = middle
            }
        }
        spinSide += (wantedSide - spinSide) * low
        spinVertical += (wantedVertical - spinVertical) * low
    }

    /// Lifts or lowers the butt of the cue by `radians`, between level and as far up as the cue can be
    /// stood. "Level" is the bottom of the lift, which is the angle the player's own stance gives the
    /// cue — 0°, a cue held flat, which is what a player does on the open table. A lifted cue strikes
    /// down at the ball, and with side spin set the shot swerves.
    public func adjustElevation(by radians: Double) {
        let wanted = max(Table.cueStanceElevation,
                         min(PhysicsWorld.maxCueElevation, cueElevation + radians))
        // A change the cue has no room for is simply stopped: the cue stays at the last angle it fitted
        // in rather than the game taking it off the ball.
        cueElevation = asFarAsItFits(from: cueElevation, to: wanted) {
            cueFits(elevation: $0, side: spinSide, vertical: spinVertical, draw: 0)
        }
    }

    public func beginCharge(at time: TimeInterval) {
        guard canStrike, hasRoomForTheCue else { return }
        // A timed charge and a cue action are two ways of doing the same job; taking hold of one
        // lets go of the other.
        endCueAction()
        mode = .charging
        chargeStart = time
        power = min(FrameDriver.minimumChargePower, maximumChargePower)
        isDownOnTheShot = true
    }

    public func updateCharge(at time: TimeInterval) {
        guard mode == .charging, let start = chargeStart else { return }
        // A charge is drawn back in proportion to its power, so the room behind the ball caps what the
        // cue can be charged to: a shot with the cue ball up against a cushion is a soft one.
        power = min(maximumChargePower, FrameDriver.minimumChargePower + (time - start) / 1.1)
    }

    /// The most of a full charge the room behind the ball allows. The timed charge draws the cue back
    /// by `power · maxCueDraw` (the 3D view draws it at exactly that), so this is the power whose
    /// backswing just fits — and it is what makes a jammed cue a gentle shot rather than a free one.
    private var maximumChargePower: Double {
        min(1, maximumCueDraw / FrameDriver.maxCueDraw)
    }

    public func releaseShot() {
        guard mode == .charging, !game.state.cueBallInHand, !game.state.frameOver else {
            decideNextMode()
            return
        }
        // The cue still has to have room behind it. Turning the aim while the power was building can
        // put a ball or a cushion behind the cue ball, and the shot is not on if it has: the charge is
        // put down again and the player is told why.
        guard hasRoomForTheCue else {
            cancelCharge()
            return
        }
        // A charge is a shot with **the hand on the button and not on the cue**, so its follow-through is
        // the shot's own rather than the mouse's: see `chargedFollowThroughLength(of:)`.
        beginStroke(followThrough: .charged)
    }

    public func cancelCharge() {
        endCueAction()
        guard mode == .charging else { return }
        chargeStart = nil
        power = 0.05
        mode = .aiming
        isDownOnTheShot = false
    }

    // MARK: - Cue action (the S key)

    /// The furthest back the cue can be drawn, in millimetres. The 3D view draws the cue back at the
    /// same distance, so the pull-back the player sees is the pull-back they made.
    public static let maxCueDraw: Double = 400

    /// The furthest the cue is **followed through**, in millimetres: past the strike the tip may not
    /// be carried further than this from the middle of the ball it struck. It is the mirror of
    /// `maxCueDraw` — 400 mm back, 250 through — and, like the pull-back, it caps the player's own
    /// hand rather than setting anything: a player who stops the cue short has a shorter
    /// follow-through, and the **cloth** stops it sooner still when the cue is stood up, which is what
    /// `asFarAsTheTableAllows` sees to. Without the cap the stick would run on up the table for as
    /// long as the mouse kept pushing, where no player's cue finishes.
    ///
    /// It is also the far end of the follow-through a **charged** shot is given by the game itself: see
    /// `chargedFollowThroughLength(of:)`, which runs from `leastChargedFollowThrough` up to this.
    public static let maxFollowThrough: Double = 250

    /// How far the cue has to come back before a push through counts as a stroke. Without it a
    /// twitch of the mouse while the aim is being lined up would play the shot. It sets nothing
    /// else: how hard the shot is has nothing to do with how far back the cue was taken.
    public static let minimumCueDraw: Double = 20

    /// The least a **charge** can be set to, as a fraction of full power: the meter starts here and fills
    /// from it, and the room behind the ball can hold it below even this.
    public static let minimumChargePower: Double = 0.05

    /// The shortest follow-through a **charged** shot is given, in millimetres. A charged shot's
    /// follow-through is the shot's own and not the hand's — see `chargedFollowThroughLength(of:)` — and
    /// this is the least of it, at the gentlest the meter will go.
    public static let leastChargedFollowThrough: Double = 50

    /// How long a **charged** shot's follow-through is held when the cue ball leaves the cue, in frames.
    ///
    /// The strike is played the moment the tip has the ball, and the tip then **has** the ball for the
    /// softness of the leather (`PhysicsWorld.cueTipGrabSeconds`) — the whole of that moment being the
    /// stroke's one contact. What follows it is a beat: the stick is stopped dead for this many frames
    /// the moment the ball is off it, and only then is it carried on through the rest of the
    /// follow-through. It is what a player's own stroke does — the ball goes, and the cue stands for an
    /// instant before the arm follows it — and it is measured in **frames** because that is what the beat
    /// is: two of them, at whatever the table is running at.
    public static let chargedFollowThroughHoldFrames = 2

    /// How far the stick follows through on a **charged** shot, in millimetres, from the middle of the
    /// ball it struck — the same measure `maxFollowThrough` uses.
    ///
    /// **Linear in the strength of the shot**: the gentlest the meter will set is
    /// `leastChargedFollowThrough` (50 mm) and full power is `maxFollowThrough` (250 mm), with everything
    /// between them in proportion. A shot played by hand has no length of its own: its follow-through is
    /// the player's, and `maxFollowThrough` is only the cap on it.
    public static func chargedFollowThroughLength(of strength: Double) -> Double {
        let strongest = min(max(strength, 0), 1)
        let least = FrameDriver.minimumChargePower
        let wayAlong = min(max((strongest - least) / max(1 - least, 1e-9), 0), 1)
        return leastChargedFollowThrough
            + (maxFollowThrough - leastChargedFollowThrough) * wayAlong
    }

    /// Restitution of the tip against the ball. A leather tip is not a spring: about 0.75.
    public static let cueTipRestitution = PhysicsWorld.cueTipRestitution

    /// The fastest the tip can be travelling, in mm/s: a centre-ball hit — the most the physics will
    /// give — comes off the cue ball at `maxPower`, and half again as fast as the range the game was
    /// first tuned in, which was found a little soft for the hardest shots a player can play.
    public static var maxCueSpeed: Double {
        maxPower / (1 + cueTipRestitution)
    }

    /// The cue ball's speed when the tip strikes it at `cueSpeed`, `offset` of a ball radius off
    /// centre.
    ///
    /// The cue is the player's hand and outmasses a ball many times over, so the physics treats it as
    /// **infinite in mass**: the impulse it delivers is the collision of that mass with the ball
    /// through a tip of restitution `e`,
    /// `J = (1 + e) V / (1/m + b²/I)`, where `b` is how far off the middle of the ball the impulse
    /// acts. A centre hit sends the ball away at **1.75 times** the speed of the tip — the whole of
    /// the tip's approach, and three quarters of it again for the spring. Hitting off centre spends
    /// part of the impulse on spin: the ball rotates, the contact point moves away with it, and less
    /// of the cue's speed is left for travel. Half a radius off centre leaves the ball at about three
    /// fifths of what a centre hit would. The spin itself comes out of the same impulse, at
    /// `omega = (5/2) v k / r`, which is what `applyCueStrike` applies.
    ///
    /// The tip can only pass so much of that impulse sideways before it loses its grip and slips — a
    /// miscue — which is what `PhysicsWorld.cueTipOffsetLimit` is: see `cueTipFriction`.
    public static func ballSpeed(fromCueSpeed cueSpeed: Double, tipOffset offset: Double) -> Double {
        let k = min(PhysicsWorld.cueTipOffsetLimit, abs(offset))
        return (1 + cueTipRestitution) * cueSpeed / (1 + 2.5 * k * k)
    }

    /// True while the cue is being drawn back and pushed forward by hand (the S key) rather than
    /// charged off a timer (the mouse button or the space bar).
    public private(set) var isMovingTheCue = false

    /// How far back the cue is drawn from its rest position: 0 has the tip at the ball.
    public private(set) var cueDraw: Double = 0

    /// How long a **push** is averaged over to give the speed a shot is played at.
    ///
    /// A delivery is a run of frames, and the mouse's speed from one frame to the next is a shaky
    /// thing: a millimetre or two of jitter either way in the frame the tip meets the ball is a hundred
    /// mm/s or more of shot strength. So the strength is not the one frame's speed but the running
    /// average of the push's own, over about `cuePushAverageSeconds`. The average is started afresh
    /// each time the hand turns from drawing back to driving **forward**, so a push is never diluted by
    /// the backswing before it, a steady delivery is worth exactly its own speed, and a one-frame push
    /// — which has no jitter in it to average — is worth exactly what it was. Only the speed is
    /// smoothed: the cue's **place** is still the hand's, so what is drawn is what was asked for.
    public static let cuePushAverageSeconds: Double = 0.025

    /// The running average of the current push's speed, in mm/s: see `cuePushAverageSeconds`.
    private var pushSpeedAverage: Double = 0
    /// Whether the last frame moved the cue back rather than forward, so that the frame the push starts
    /// can be told.
    private var lastMoveWasABackswing = false

    /// The furthest the cue has been drawn back in this cue action, so that a push through is known
    /// to be a stroke rather than a twitch.
    private var peakCueDraw: Double = 0

    /// How fast the cue's tip is travelling towards the ball, in mm/s. This is the strength of the
    /// shot: it is read at the moment the tip comes into the ball.
    public private(set) var cueSpeed: Double = 0

    /// The speed the tip was travelling at when the last shot was played, in mm/s: the number the
    /// shot's strength came from, kept so the readout can show it.
    public private(set) var lastStrikeCueSpeed: Double = 0

    /// The speed the **stick** was travelling at when it struck the cue ball, in mm/s — the cue's own
    /// speed at the moment of contact, and the fastest it may be carried **forward** for the rest of the
    /// stroke. See `carryTheCue`.
    private var theStickWasTravellingAt: Double = 0

    /// Whether the stroke in play is a **charged** one, whose follow-through is the shot's own: see
    /// `carryTheChargedFollowThrough`.
    private var theStrokeIsCharged = false

    /// The follow-through a charged shot is carried through: the **distance from the middle of the ball
    /// it struck** the tip is to reach, and the speed it is carried at — the speed it struck with, held
    /// **constant** for the whole of the travel. Nil for a stroke played by hand, whose follow-through is
    /// the mouse's.
    private var theChargedFollowThrough: (target: Double, speed: Double)?
    /// Whether the cue ball has left the cue yet on a charged shot, and how many frames of the beat by
    /// its leaving are still to run. See `carryTheChargedFollowThrough`.
    private var theCueBallHasLeftTheCue = false
    private var chargedHoldFramesLeft = 0

    /// How far off centre the tip strikes the ball, in ball radii: the other thing the shot's
    /// strength depends on, because that is the part of the impulse spent on spin.
    public var tipOffset: Double {
        min(PhysicsWorld.cueTipOffsetLimit,
            (spinSide * spinSide + spinVertical * spinVertical).squareRoot())
    }

    /// What the shot would be worth if the tip came into the ball now — the cue's speed and where it
    /// is striking — as a fraction of full power, for the power bar to show while the cue is moving.
    public var cueActionStrength: Double {
        min(1, FrameDriver.ballSpeed(fromCueSpeed: max(0, cueSpeed), tipOffset: tipOffset) / FrameDriver.maxPower)
    }

    /// Takes hold of the cue: the player draws it back and pushes it forward by hand, and the shot
    /// is played as the tip comes through the ball (the S key).
    @discardableResult
    public func beginCueAction() -> Bool {
        // The cue has to have somewhere to go: a stick with a ball, a cushion or the rail behind it
        // cannot be laid at the ball at all, and the player's way round it is to lift the butt (B).
        guard canStrike, hasRoomForTheCue else { return false }
        mode = .charging
        chargeStart = nil          // the strength comes from the cue's travel, not from a stopwatch
        cueDraw = 0
        peakCueDraw = 0
        cueSpeed = 0
        pushSpeedAverage = 0
        lastMoveWasABackswing = false
        isMovingTheCue = true
        power = 0
        isDownOnTheShot = true
        return true
    }

    /// Draws the cue back (`millimetres` negative) or pushes it towards the ball (positive), the way
    /// the mouse moves it, over `dt` seconds. When a push brings the tip into the ball after a real
    /// backswing the stroke is played — at the speed the cue is travelling, which is the shot's
    /// strength — and this returns true.
    @discardableResult
    public func moveCue(forwardByMillimetres millimetres: Double, over dt: TimeInterval) -> Bool {
        guard mode == .charging, isMovingTheCue else { return false }
        // The cue's place is the hand's, frame by frame, but the **speed** a shot is read at is the
        // running average of the push the hand is making — see `cuePushAverageSeconds`: a shaky
        // delivery averages out, a steady one is worth exactly its own speed, and nothing about the
        // backswing comes into it, because the average starts again when the push does.
        let wanted = dt > 0 ? max(0, min(FrameDriver.maxCueSpeed, millimetres / dt)) : 0
        if millimetres > 0, lastMoveWasABackswing {
            pushSpeedAverage = wanted
        } else {
            let blend = dt > 0 ? min(1, dt / FrameDriver.cuePushAverageSeconds) : 1
            pushSpeedAverage += (wanted - pushSpeedAverage) * blend
        }
        lastMoveWasABackswing = millimetres < 0
        cueSpeed = pushSpeedAverage
        cueDraw -= millimetres
        // The aim can be turned while the cue is being drawn — Shift gives the mouse back to it — and
        // turning it can put an obstruction behind the ball: the stroke is not played then, however
        // far back the cue was taken while there was room for it.
        if cueDraw <= 0, peakCueDraw >= FrameDriver.minimumCueDraw, hasRoomForTheCue {
            // The tip has come into the ball: the stroke is played at the speed it is moving, less
            // whatever the off-centre contact spends on spin.
            playStroke()
            return true
        }
        // The cue cannot be drawn through what is behind it: it comes back as far as its own draw and
        // as far as the room behind the ball allow, whichever is less.
        cueDraw = max(0, min(min(FrameDriver.maxCueDraw, maximumCueDraw), cueDraw))
        peakCueDraw = max(peakCueDraw, cueDraw)
        power = cueActionStrength
        return false
    }

    /// Plays the stroke the cue action has arrived at: the cue ball's speed comes from the cue's own
    /// speed and from where the tip struck it.
    private func playStroke() {
        lastStrikeCueSpeed = cueSpeed
        let ballSpeed = FrameDriver.ballSpeed(fromCueSpeed: cueSpeed, tipOffset: tipOffset)
        power = min(1, ballSpeed / FrameDriver.maxPower)
        beginStroke(cueSpeed: cueSpeed)
    }

    /// Puts the cue down without playing a stroke: letting go of the S key, or putting the shot down to
    /// answer a question with Escape.
    public func cancelCueAction() {
        endCueAction()
        cancelCharge()
        if mode != .simulating { isDownOnTheShot = false }
    }

    private func endCueAction() {
        isMovingTheCue = false
        cueDraw = 0
        peakCueDraw = 0
        cueSpeed = 0
        pushSpeedAverage = 0
        lastMoveWasABackswing = false
    }

    /// Starts a stroke with explicit parameters. Used by the UI and by tests.
    public func shoot(angle: Double, power: Double, side: Double, vertical: Double) {
        shoot(angle: angle, power: power, side: side, vertical: vertical, elevation: 0)
    }

    /// Starts a stroke with explicit parameters, including how far the cue is lifted.
    public func shoot(angle: Double, power: Double, side: Double, vertical: Double, elevation: Double) {
        aimAngle = angle
        self.power = power
        spinSide = side
        spinVertical = vertical
        // The cue cannot be laid flatter than the player's own stance, so a "level" stroke is the
        // stance's angle and not 0: see `PhysicsWorld.cueLean`.
        cueElevation = PhysicsWorld.cueLean(at: elevation)
        guard let cue = cueBall, cue.onTable, !game.state.frameOver else { return }
        beginStroke()
    }

    /// Plays a stroke. `ballSpeed` is the speed the cue ball leaves at when the caller has worked it
    /// out (the cue action does, from the cue's own speed); otherwise it comes from the charged power.
    /// How the stick is carried **after** the strike: by the player's hand, or by the shot itself.
    private enum FollowThrough {
        /// The player's own hand, through `carryTheCue`: the follow-through is the mouse's, capped at
        /// `maxFollowThrough` and at the cloth. A shot played by hand is this.
        case byHand
        /// The **shot's own**: a charged shot is played with the hand on the button and not on the cue, so
        /// the game carries the stick on for it — at the speed it struck with, for `chargedFollowThroughLength(of:)`
        /// millimetres, and at that **one speed** all the way. See `carryTheChargedFollowThrough`.
        case charged
    }

    /// Plays the stroke: the **cue's** own speed is what the caller sets, and everything the cue ball does
    /// comes out of that and the point on the ball the tip is striking — see
    /// `ballSpeed(fromCueSpeed:tipOffset:)`.
    ///
    /// `cueSpeed` is the speed of the stick at the moment it meets the ball: the hand's own speed for a
    /// shot played with `S` (see `playStroke`), and for a **charge** the meter's fraction of
    /// `maxCueSpeed` — so a full charge is a cue at its fastest and a gentler one is a slower cue. What the
    /// ball does with that is the strike's business: a centre hit sends it away at `1 + e` times the cue's
    /// speed, and the further the tip is from the middle of the ball the more of the strike goes on spin
    /// and the less there is left for travel. The ball's speed is therefore **derived**, and never set
    /// alongside the cue's.
    private func beginStroke(cueSpeed: Double? = nil, followThrough: FollowThrough = .byHand) {
        guard let cue = cueBall, cue.onTable else { return }
        endCueAction()
        // The cue is laid where it fits before it is driven through the ball: the pose the strike is
        // played with is the pose the player has been looking at, room and all.
        settleTheCue()
        // Whatever the caller has set, the strike is played with the spin the control allows at the
        // angle the cue has settled at. The strike itself is where the leather's grip has the last
        // word — see `PhysicsWorld.cueTipOffsetLimit`, which `applyCueStrike` settles a too-far-out
        // tip on to rather than letting it slip — but the tip can be put where the player likes.
        // The cue ball is in play from here: it can no longer be moved about.
        canRepositionCueBall = false
        // The stroke in front of them is the one played: a colour choice that comes with the next one is
        // theirs to make afresh, by hand or with the aim.
        theStrikerChoseTheColourByHand = false
        // Remember the layout before the balls move, in case the non-offender asks for it back.
        game.rememberLayout()
        chargeStart = nil
        strokeCueStart = cue.position
        positionsBeforeStroke = Dictionary(uniqueKeysWithValues:
            world.balls.filter(\.onTable).map { ($0.id, $0.position) })
        report = StrokeReport()
        contactedCueBalls = []
        ballsTheCueTouched = []
        simulationClock = 0
        flash = nil

        let speed = cueSpeed ?? FrameDriver.maxCueSpeed * max(0.03, power)
        // What the strike does with that speed at the point on the ball the tip is striking — the leather's
        // own limit, not the edge of the ball, is how far off centre the strike acts:
        // `PhysicsWorld.cueTipOffsetLimit`.
        let struckBallSpeed = FrameDriver.ballSpeed(fromCueSpeed: speed, tipOffset: tipOffset)
        // The stroke itself is the first impact of the frame, and the only one not to come back through
        // `world.events` — the strike is played here, after the events were cleared and before the
        // simulation starts walking them out.
        impacts.append(Impact(kind: .strike, at: cue.position, speed: struckBallSpeed))
        world.clearEvents()
        // The strike is played along the cue's own axis, at the angle the cue is standing at: see
        // `PhysicsWorld.cueLean` for the floor the player's stance puts under that.
        world.applyCueStrike(cueBallID: BallID.cue,
                             direction: Vec2(cos(aimAngle), sin(aimAngle)),
                             power: struckBallSpeed, side: spinSide, vertical: spinVertical,
                             elevation: PhysicsWorld.cueLean(at: cueElevation))
        // The stick itself stays on the table from here, and it is the player's for the rest of the
        // stroke: the mouse carries it along at whatever speed they give it, and any ball it runs into
        // after the cue ball is a ball contacted with the player's equipment — a foul either way.
        // The stick is left travelling at **its own speed at the moment it touched the ball**, which is the
        // speed the caller set: a cue does not speed up or slow down when it meets a ball, and this is the
        // fastest it may be carried forward for the rest of the stroke. See `carryTheCue`.
        theStickWasTravellingAt = speed
        placeTheCueAfterTheStrike(of: cue, at: theStickWasTravellingAt)
        // A charged shot's follow-through is the game's to carry: the length follows the strength of the
        // shot, from the least a charge can be to a full-power one, and it is measured like
        // `maxFollowThrough` — **from the middle of the ball it struck**. See
        // `carryTheChargedFollowThrough`.
        theStrokeIsCharged = followThrough == .charged
        if theStrokeIsCharged {
            theChargedFollowThrough = (target: FrameDriver.chargedFollowThroughLength(of: speed / FrameDriver.maxCueSpeed),
                                       speed: theStickWasTravellingAt)
        } else {
            theChargedFollowThrough = nil
        }
        theCueBallHasLeftTheCue = false
        chargedHoldFramesLeft = 0
        isDownOnTheShot = true
        mode = .simulating
    }

    // MARK: - The cue itself, once the shot is away

    /// True while the player is down over the shot, which after the stroke is theirs to end: releasing
    /// `S` stands them up while the balls run.
    public private(set) var isDownOnTheShot = false
    /// How fast the tip is travelling along the cue's axis while the balls run, in mm/s: what the mouse
    /// is giving it. Negative draws the stick away, positive pushes it on through.
    public private(set) var cueTravelSpeed: Double = 0

    /// Puts the stick where the strike left it: just clear of the ball, pointing where the shot went,
    /// and travelling at the speed the shot was played at — so the follow-through is the player's own
    /// mouse rather than an animation.
    ///
    /// The tip is a dome of `Table.cueGirth`'s own radius in the physics, so the *end* of the stick
    /// stands that radius plus a hair off the middle of the ball when it is at the ball: the tip's
    /// skin is what touched it, and the solid end has to stay out of it.
    private func placeTheCueAfterTheStrike(of cue: Ball, at speed: Double) {
        let (tipAtContact, axis) = PhysicsWorld.cueLine(
            ballCentre: Vec3(cue.position.x, cue.position.y, Table.ballRadius),
            yaw: aimAngle, elevation: cueElevation, side: spinSide, vertical: spinVertical)
        // Where the tip actually is: **on** the ball, where the contact point of `cueLine` puts it — that
        // is the impulse's own offset from the middle of the ball, and the crown of the tip stands on the
        // ball's surface there. The tip then *has* the ball for the few milliseconds of the strike's own
        // contact: see `PhysicsWorld.grabTheCueBall`, which carries the stick with it and reports nothing
        // for it, since the stroke is one contact and not two.
        let across = tipAtContact - Vec3(cue.position.x, cue.position.y, Table.ballRadius)
        let touching = Vec3(cue.position.x, cue.position.y, Table.ballRadius) + across
        world.grabTheCueBall(BallID.cue, with: Cue(tip: touching, axis: axis, speed: speed))
        cueTravelSpeed = speed
    }

    /// The cue as the physics has it, when the player has it on the table: where the stick is and how
    /// fast it is going. Nil when the cue is put away, or before a stroke has placed it.
    public var cueOnTheTable: Cue? {
        cueHandling == .laid ? world.cue : nil
    }

    /// Where the cue ball was when the last stroke was played from: where the stick stands for the
    /// whole of that stroke, since a player plays from one place and watches the balls go from it.
    /// It is where the cue is drawn from until the stroke is over, whether or not the player is still
    /// down on the shot.
    public var strokeWasPlayedFrom: Vec2 { strokeCueStart }

    /// Moves the cue the way the mouse does while the balls run: `millimetres` along the stick's own
    /// axis, carrying the stick with it and telling the physics how fast it is going. The cue is the
    /// player's hand, so **the mouse owns its position**: the simulation never carries it along, and a
    /// stick the player has stopped moving stays where it is. What it has is a speed, which is what a
    /// ball it runs into is answered with, and any ball it does run into is a foul (Rule 11(b)(vi)).
    public func carryTheCue(forwardByMillimetres millimetres: Double, over dt: TimeInterval) {
        // On a **charged** shot the stick is the shot's, not the mouse's: the hand is on the button rather
        // than on the cue, and the game carries it through for the player (see
        // `carryTheChargedFollowThrough`). The mouse may still take the stick **back** off the ball —
        // pulling it clear is the player's to do and can only make a foul less likely — but it does not
        // drive it on.
        carryCue(forwardByMillimetres: theStrokeIsCharged ? min(0, millimetres) : millimetres, over: dt)
    }

    /// Carries the stick through the ball on a **charged** shot, at the speed it struck with and for the
    /// length the strength of the shot buys, and then leaves it standing where it stopped.
    ///
    /// The speed is held **constant** the whole way, which is what makes a charged shot's follow-through
    /// look like a stroke rather than a stab: the stick is the shot's own from the moment the button is
    /// let go, and nothing takes it out of its line or slows it. What stops it is the length, and — as
    /// with the hand's own follow-through — the cloth or a cushion the tip comes up against, which is
    /// `carryCue`'s business: whatever it refuses is not counted as travelled.
    private func carryTheChargedFollowThrough(over dt: Double) {
        guard let followThrough = theChargedFollowThrough, let cue = world.cue else { return }
        // The beat: the ball leaves the cue when the tip's hold has gone and the ball is no longer on
        // it, and the stick is held **still** there for `chargedFollowThroughHoldFrames` frames before
        // the rest of the follow-through is carried out. While it is held the stick is not travelling,
        // so a ball against it is met by a stick that is standing and not by one being driven on.
        // The frame of the strike itself is the leather's own hold, and is not this beat: it is the
        // grab that has the ball then, and the grab is what places the tip. See
        // `chargedFollowThroughHoldFrames`.
        if !theCueBallHasLeftTheCue, !world.theCueIsOn(BallID.cue) {
            theCueBallHasLeftTheCue = true
            chargedHoldFramesLeft = FrameDriver.chargedFollowThroughHoldFrames
        }
        if chargedHoldFramesLeft > 0 {
            chargedHoldFramesLeft -= 1
            if var held = world.cue { held.speed = 0; world.cue = held }
            cueTravelSpeed = 0
            return
        }
        // The length is a **place**, not a distance travelled: it is measured the way `maxFollowThrough`
        // is, from the middle of the ball the shot was played at, and the tip is carried until it reaches
        // it. That is the one measure that survives the strike itself — the tip is on the ball's surface
        // when the leather lets go, wherever the ball has got to by then — and it is also what lets the
        // cloth, a cushion or the room behind the ball stop the stick without the length being lost: what
        // is not travelled is still to be travelled.
        let whereTheTipIs = Vec2(cue.tip.x, cue.tip.y)
        let stillToGo = followThrough.target - whereTheTipIs.distance(to: strokeCueStart)
        guard stillToGo > 0 else { return }
        carryCue(forwardByMillimetres: min(followThrough.speed * max(0, dt), stillToGo), over: dt)
    }

    private func carryCue(forwardByMillimetres millimetres: Double, over dt: TimeInterval) {
        guard mode == .simulating, world.cue != nil else { return }
        // The stick is the player's hand, but it is still a stick: driven on into the table it stops
        // where the tip touches — the cloth, or the wood of the cushion and the rail — rather than
        // passing through it. Only as much of the mouse's travel as the table allows is taken.
        //
        // **And it is not carried forward any faster than it was going when it struck the ball.** A
        // stroke is played *by the hand going on through the ball*: the tip meets the ball part way
        // through a flick, and the frames that follow are still the same movement. Left to the mouse the
        // stick's speed after the strike is the *hand's*, while the ball's is `1.75` times the stroke's
        // own — and the stroke's strength is the **average** of the push, which a flick's last frame is
        // faster than. So a soft shot with the hand going on through it ran the ball down from behind and
        // was called a second hit the player never played: measured, a stroke at 840 mm/s with the hand
        // going on was called a second hit **14 ms** after the first contact. A cue does not speed up
        // when it meets a ball, so the stick's own speed at the strike is the fastest it may be carried
        // on at: the hand may go on, and the stick follows it only as fast as the shot it played.
        let fastestForward = max(0, theStickWasTravellingAt) * max(0, dt)
        let fastestBack = FrameDriver.maxCueSpeed * max(0, dt)
        var wanted = max(-fastestBack, min(fastestForward, millimetres))
        // The follow-through runs out at `maxFollowThrough`: the tip may be carried on no further than
        // that from the middle of the ball it struck, so the mouse's push is what carries it and the
        // cap is where it stops. Drawing the stick **back** is the player's own: pulling it clear of the
        // balls is what the hand is doing and is capped only by the ceiling every hand movement has
        // (`maxCueSpeed`), not by speed of the shot — so a cue can always be taken off the ball.
        if wanted > 0 {
            wanted = min(wanted, roomToFollowThrough)
        }
        let allowed = asFarAsTheTableAllows(wanted)
        let speed = dt > 0
            ? max(-FrameDriver.maxCueSpeed, min(FrameDriver.maxCueSpeed, allowed / dt))
            : 0
        cueTravelSpeed = speed
        if var cue = world.cue {
            cue.tip += cue.axis * allowed
            cue.speed = speed
            world.cue = cue
        }
    }

    /// As much of `millimetres` of travel along the cue's own axis as the table allows before the tip
    /// comes up against it — found by halving the difference, so the stick stops within a fraction of a
    /// millimetre of the cloth or the cushion rather than a frame's travel short of it.
    private func asFarAsTheTableAllows(_ millimetres: Double) -> Double {
        guard millimetres > 0, let cue = world.cue else { return millimetres }
        let axis = cue.axis
        func clear(_ travel: Double) -> Bool {
            world.theCueTipCanStand(at: cue.tip + axis * travel, along: axis)
        }
        if clear(millimetres) { return millimetres }
        var low = 0.0, high = millimetres
        for _ in 0..<10 {
            let middle = (low + high) / 2
            if clear(middle) { low = middle } else { high = middle }
        }
        return low
    }

    /// How much further forward the tip may be carried before the follow-through runs out: what is
    /// left of `maxFollowThrough` between the tip and the middle of the ball it struck. The ball's
    /// place **when the stroke was played** (`strokeCueStart`) is the reference rather than wherever
    /// the ball has got to, so the follow-through is the player's own hand and is not stretched by the
    /// ball running away down the table.
    private var roomToFollowThrough: Double {
        guard let cue = world.cue else { return 0 }
        let tip = Vec2(cue.tip.x, cue.tip.y)
        return max(0, FrameDriver.maxFollowThrough - tip.distance(to: strokeCueStart))
    }

    /// The player stands up from the shot — `S` released, or Escape — while the balls are still
    /// running.
    ///
    /// Standing up takes the player's **hand** off the stick rather than the stick off the table: the
    /// cue stays where the mouse left it, at the shot's own place, and it is still a stick the balls
    /// are answered by — only stopped, since nobody is driving it now. A ball that runs into it is
    /// still a ball met with the player's equipment, which is a foul (Rule 11(b)(vi)), exactly as it is
    /// while they are down on the shot. Putting the cue away is a separate thing (`C`,
    /// `toggleCueHandling`), and that is what takes it off the table and out of the balls' way.
    public func standUp() {
        isDownOnTheShot = false
        cueTravelSpeed = 0
        if var cue = world.cue {
            cue.speed = 0
            world.cue = cue
        }
    }

    // MARK: - Simulation

    /// Advances the simulation. Returns true when the stroke has finished.
    @discardableResult
    public func update(dt: Double) -> Bool {
        guard mode == .simulating else { return false }
        // A charged shot carries its own stick on through the ball, before the balls are stepped, so that
        // the place it has reached is the place they are answered by. See
        // `carryTheChargedFollowThrough`.
        carryTheChargedFollowThrough(over: min(dt, 0.1))
        let step = 1.0 / 240.0
        var remaining = min(dt, 0.1)
        while remaining > 0 {
            world.clearEvents()
            world.step(dt: step)
            collectEvents(world.events)
            remaining -= step
            simulationClock += step
            if simulationClock > 25 || world.allAtRest { break }
        }
        if world.allAtRest || simulationClock > 25 {
            world.stopAll()
            finishStroke()
            return true
        }
        return false
    }

    /// True while a ball forced off the table is still on its way to the floor.
    public var ballsAreFalling: Bool { world.balls.contains(where: \.isFalling) }

    /// Lets the balls that have been forced off the table fall the rest of the way to the floor. The
    /// view calls this every frame, whether or not a stroke is running: the rules have had the ball
    /// since the moment it left — see `PhysicsWorld.takeBallsOffTheTable` — so this is only the picture
    /// of it finishing, and it ends when the ball lands and is gone.
    public func letTheBallsFall(dt: Double) {
        guard mode != .simulating, ballsAreFalling else { return }
        world.clearEvents()
        world.step(dt: min(dt, 0.1))
        // A ball reaching the floor is a contact like any other, and is reported like one.
        collectEvents(world.events)
    }

    /// Runs the whole stroke to completion (used by tests and by headless mode).
    ///
    /// The headless run stands the player up and **puts the cue away** as soon as the shot is away —
    /// the stick off the table, so that the stroke is the balls' own game with nobody holding it in
    /// their way. A caller that wants the cue in play — to see a ball run into it — leaves it on the
    /// table and drives it with `carryTheCue`.
    public func runStrokeToRest(maxSeconds: Double = 30) {
        standUp()
        world.cue = nil
        var elapsed = 0.0
        while mode == .simulating && elapsed < maxSeconds {
            update(dt: 1.0 / 120.0)
            elapsed += 1.0 / 120.0
        }
    }

    private func collectEvents(_ events: [PhysicsEvent]) {
        // Where a ball is, for the sound the contact makes: the whole of what a pan is worked from.
        func whereIs(_ ball: Int) -> Vec2 { world.ball(id: ball)?.position ?? .zero }
        for event in events {
            switch event {
            case .ballBall(let a, let b, let relativeSpeed):
                if a == BallID.cue || b == BallID.cue {
                    let other = a == BallID.cue ? b : a
                    if !contactedCueBalls.contains(other) {
                        contactedCueBalls.append(other)
                        report.contactedAnyObjectBall = true
                    }
                }
                let meeting = (whereIs(a) + whereIs(b)) / 2
                impacts.append(Impact(kind: .ballOnBall, at: meeting, speed: relativeSpeed))
            case .cushion(let ball, _, let speed):
                if ball == BallID.cue, report.firstContacts.isEmpty {
                    report.cushionBeforeFirstContact = true
                }
                impacts.append(Impact(kind: .cushion, at: whereIs(ball), speed: speed))
            case .throat(let ball, let speed):
                impacts.append(Impact(kind: .throat, at: whereIs(ball), speed: speed))
            case .rail(let ball, let speed):
                impacts.append(Impact(kind: .rail, at: whereIs(ball), speed: speed))
            case .bed(let ball, let speed):
                impacts.append(Impact(kind: .bed, at: whereIs(ball), speed: speed))
            case .landed(let ball, let speed):
                impacts.append(Impact(kind: .floor, at: whereIs(ball), speed: speed))
            case .pocketWood(let ball, let speed):
                // The wood at the back of a pocket is wood like the rail's, and sounds like it.
                impacts.append(Impact(kind: .rail, at: whereIs(ball), speed: speed))
            case .pocketed(let ball, _):
                report.potted.append(ball)
                if ball == BallID.cue { report.cueBallPotted = true }
                impacts.append(Impact(kind: .pocket, at: whereIs(ball), speed: 0))
            case .forcedOffTable(let ball):
                report.ballsForcedOffTable.append(ball)
            case .jumpShot(let ball):
                report.jumpedOver.append(ball)
            case .cueTouched(let ball, let after, let speed):
                if ball == BallID.cue, report.secondsUntilTheCueBallWasStruckAgain == nil {
                    report.secondsUntilTheCueBallWasStruckAgain = after
                }
                if !ballsTheCueTouched.contains(ball) { ballsTheCueTouched.append(ball) }
                impacts.append(Impact(kind: .cueOnBall, at: whereIs(ball), speed: speed))
            }
        }
    }

    private func finishStroke() {
        report.firstContacts = contactedCueBalls.first.map { [$0] } ?? []
        report.ballsTheCueTouched = ballsTheCueTouched
        report.movedBalls = world.balls.compactMap { ball in
            guard let before = positionsBeforeStroke[ball.id] else { return nil }
            return !ball.onTable || ball.position.distance(to: before) > Table.touchingTolerance
                ? ball.id : nil
        }
        writePhysicsPositionsIntoState()
        let cueEnd = cueBall?.position ?? strokeCueStart
        let result = game.applyStroke(report, cueBallStart: strokeCueStart, cueBallEnd: cueEnd)
        lastStroke = report
        lastResult = result

        if let foul = result.foul {
            flash = "FOUL: \(foul.reason) (+\(foul.penalty))"
        } else if result.pointsScored > 0 {
            flash = "+\(result.pointsScored)"
        }

        // The shot's spin has been played: the tip goes back to the middle of the ball, so the next
        // stroke starts from a clean cue ball rather than from the last one's side or screw back. The
        // cue goes back down with it, to the bottom of the lift — the angle the player's own stance
        // gives it — since a swerve is set for the shot it is played on.
        spinSide = 0
        spinVertical = 0
        cueElevation = Table.cueStanceElevation
        // The player is up again, and the stick is off the table until the next stroke puts it back.
        isDownOnTheShot = false
        cueTravelSpeed = 0
        // And the stroke is done with, charged or by hand: the next one sets its own follow-through.
        theStrokeIsCharged = false
        theChargedFollowThrough = nil
        theCueBallHasLeftTheCue = false
        chargedHoldFramesLeft = 0
        world.cue = nil
        ballsTheCueTouched = []

        syncWorldFromState()
        commentary = game.state.commentary
        decideNextMode()
    }

    private func decideNextMode() {
        // With only the Black left and the striker more than seven behind, the striker needs snookers and
        // the frame is the non-striker's without being asked for (Section 2 Rule 1(c)). It is awarded here,
        // the moment the position is noticed — at the end of the stroke that left it — rather than left to
        // a button: it is not the striker's frame to play on for. The striker's own case, when they are the
        // one ahead, stays a claim and waits for them; see `canClaimTheFrame`.
        if game.awardTheFrameToTheNonStriker() {
            // The referee's own line about it belongs on the log the player is reading, and the log is
            // copied from the game at the points where the game has something to say.
            commentary = game.state.commentary
        }
        // A striker who is on a colour of their own choice and has the cue pointing at one has already said
        // which colour they are playing for: the aim is taken as the nomination, so that the choice is made
        // before the question is even asked.
        nominateTheColourTheCueIsOn()
        countTheFrameIfItHasJustEnded()
        if game.state.frameOver {
            mode = .frameOver
            if let winner = game.state.winner {
                status = "Frame over: \(playerNames[winner]) wins \(scores[0])-\(scores[1])."
            } else {
                status = "Frame over."
            }
            return
        }
        if let pending = game.state.pending {
            switch pending {
            case .placeCueBallInD, .placeCueBallAnywhere:
                mode = .placingCueBall
                canRepositionCueBall = true
                status = game.state.respottedBlack
                    ? "Re-spotted Black: \(playerNames[currentPlayer]) plays from in-hand."
                    : "\(playerNames[currentPlayer]): place the cue ball in the D."
            case .nominateColour:
                mode = .decision
                status = "\(playerNames[currentPlayer]): which colour is on?"
            case .afterFoul(let decision):
                mode = .decision
                status = "Foul: \(decision.foul.reason) (+\(decision.foul.penalty)). \(playerNames[currentPlayer]) chooses."
            case .afterMiss(let decision):
                mode = .decision
                status = decision.warningJustIssued
                    ? "FOUL AND A MISS. Warning: a further failure loses the frame."
                    : "FOUL AND A MISS called. \(playerNames[currentPlayer]) chooses."
            case .nominateFreeBall:
                mode = .decision
                status = "FREE BALL: nominate any ball as the ball on."
            }
            return
        }
        if game.state.cueBallInHand {
            mode = .placingCueBall
            status = "\(playerNames[currentPlayer]): place the cue ball in the D."
            return
        }
        mode = .aiming
        status = "\(playerNames[currentPlayer]) to play: \(ballOnDescription) is on."
        // With only the Black left and the striker more than seven ahead, the frame is theirs to claim
        // (Section 2 Rule 1(b)) and the game says so rather than ending it for them. The non-striker's own
        // case never reaches here: it is awarded at the top of this method.
        if let claimant = game.claimOfTheFrame {
            status += " \(playerNames[claimant]) may claim the frame."
        }
    }

    /// Counts the frame for its winner, once, the moment it ends. Every way a frame can finish — the
    /// last pot, a claim, a concession — runs through `decideNextMode`, so this is the one place that
    /// has to notice.
    private func countTheFrameIfItHasJustEnded() {
        guard game.state.frameOver, !haveCountedTheFrame else { return }
        haveCountedTheFrame = true
        guard let winner = game.state.winner, framesWon.indices.contains(winner) else { return }
        framesWon[winner] += 1
    }

    /// A re-rack puts the same frame back to its start (Section 3 Rule 17), so a frame that had ended
    /// and been counted comes back off the board with its scores.
    private func takeBackTheCountIfTheFrameHadEnded() {
        guard haveCountedTheFrame else { return }
        haveCountedTheFrame = false
        guard let winner = game.state.winner, framesWon.indices.contains(winner) else { return }
        framesWon[winner] -= 1
    }

    // MARK: - Actions

    /// True while the game is asking whether the player really means to start a new frame. `N` asks
    /// first — the key sits next to the others and the frame in progress is worth more than a slip of
    /// the hand — and nothing is thrown away until the player says so.
    public private(set) var isAskingAboutANewFrame = false

    /// Asks about starting a new frame. The frame in progress is left exactly as it stands.
    public func askToStartANewFrame() {
        putTheOtherQuestionsAway(from: .aNewFrame)
        isAskingAboutANewFrame = true
    }

    /// What answering the new-frame question yes would do, said plainly, so that the question can be put
    /// to the player with the whole of it on the screen: they are ending the frame in progress, and the
    /// player with fewer points is the one who concedes it to the other. With the scores level there is
    /// nothing between them to concede, and the frame is re-racked instead.
    public var whatANewFrameMeans: String {
        let scores = self.scores
        guard scores.count >= 2 else { return "" }
        if scores[0] == scores[1] {
            return "The scores are level at \(scores[0])-\(scores[1]), so the frame is re-racked: nothing is won."
        }
        let loser = scores[0] < scores[1] ? 0 : 1
        return "\(playerNames[loser]) concedes to \(playerNames[1 - loser]) at \(scores[0])-\(scores[1]), "
            + "and frame \(frameNumber + 1) is racked."
    }

    /// Answers the new-frame question yes. A frame still in progress cannot just be thrown away: the
    /// player with fewer points has conceded it, so it is counted for the other and the next frame is
    /// racked. With the scores level nobody is behind to concede it, so the frame is **re-racked** and
    /// nothing is won. With the frame already over there is nothing left to settle, and the next frame
    /// simply begins.
    public func startTheNewFrame(startingPlayer: Int = 0) {
        isAskingAboutANewFrame = false
        guard !game.state.frameOver else {
            newFrame(startingPlayer: startingPlayer)
            return
        }
        let scores = self.scores
        guard scores.count >= 2, scores[0] != scores[1] else {
            reRack()
            status = "The scores were level, so the frame is re-racked: nothing is won."
            return
        }
        // The frame ends the way a conceded frame does, and is counted for the player it goes to; the
        // referee's own line about it is carried into the new frame, since that is where the player will
        // be looking for why the frame count has moved.
        game.concede(player: scores[0] < scores[1] ? 0 : 1)
        decideNextMode()
        let howTheFrameEnded = game.state.commentary.last
        newFrame(startingPlayer: startingPlayer)
        if let howTheFrameEnded { commentary.insert(howTheFrameEnded, at: 0) }
    }

    /// True while the **re-rack** is being asked about. `R` asks first, exactly as `N` does: a re-rack
    /// nullifies every score in the frame and sets the balls up again (Section 3 Rule 17), so it is not
    /// something to do on a slipped key.
    public private(set) var isAskingAboutAReRack = false

    /// Asks about re-racking. The frame is left exactly as it stands until the question is answered.
    public func askToReRack() {
        guard mode != .simulating else { return }   // not while a stroke is in the air
        putTheOtherQuestionsAway(from: .aReRack)
        isAskingAboutAReRack = true
    }

    /// Answers the question yes: the scores go and the frame is set up again.
    public func reRackTheFrame() {
        isAskingAboutAReRack = false
        reRack()
    }

    /// Answers the question no: the frame in progress carries on as it was.
    public func keepPlaying() {
        isAskingAboutANewFrame = false
        isAskingAboutAReRack = false
        isAskingAboutANewGame = false
        decideNextMode()
    }

    /// True while the game is asking whether the player really means to start a **new game**: the frame
    /// number, the frames each player has won and the frame in progress all go back to the start of the
    /// match. **Esc** asks it, and **Esc** again puts the question away, so nothing is cleared until the
    /// question is answered.
    public private(set) var isAskingAboutANewGame = false

    /// Asks about starting a new game. The match is left exactly as it stands.
    public func askToStartANewGame() {
        putTheOtherQuestionsAway(from: .aNewGame)
        isAskingAboutANewGame = true
    }

    /// There is only ever one question on the screen: asking one puts the others away, so the keys that
    /// answer them cannot be read against the wrong one.
    private enum Question {
        case aNewFrame
        case aReRack
        case aNewGame
    }

    private func putTheOtherQuestionsAway(from question: Question) {
        if question != .aNewFrame { isAskingAboutANewFrame = false }
        if question != .aReRack { isAskingAboutAReRack = false }
        if question != .aNewGame { isAskingAboutANewGame = false }
    }

    /// Answers the question yes: the match goes back to its first frame, with no frames won, and the
    /// balls are racked.
    public func startTheNewGame(startingPlayer: Int = 0) {
        frameNumber = 1
        framesWon = [0, 0]
        haveCountedTheFrame = false
        rackAFrame(startingPlayer: startingPlayer)
        status = "New game. \(playerNames[startingPlayer % 2]) to break."
    }

    public func newFrame(startingPlayer: Int = 0) {
        frameNumber += 1
        haveCountedTheFrame = false
        rackAFrame(startingPlayer: startingPlayer)
    }

    /// Racks a fresh frame and stands the player at the table for it. The match's own counters are the
    /// caller's business: `newFrame` takes the next frame of the match, `startTheNewGame` goes back to
    /// the first, and a re-rack keeps the frame it was asked in.
   private func rackAFrame(startingPlayer: Int) {
       isAskingAboutANewFrame = false
       isAskingAboutANewGame = false
        theStrikerChoseTheColourByHand = false
        let names = playerNames
        game = SnookerGame(playerNames: names)
        game.beginFrame(startingPlayer: startingPlayer)
        syncWorldFromState()
        power = 0.35
        spinSide = 0
        spinVertical = 0
        cueElevation = Table.cueStanceElevation
        mode = .placingCueBall
        canRepositionCueBall = true
        status = "New frame. \(playerNames[startingPlayer % 2]) to break."
        commentary = game.state.commentary
    }

    @discardableResult
    public func placeCueBall(at point: Vec2) -> Bool {
        guard game.placeCueBall(at: point) else { return false }
        syncWorldFromState()
        decideNextMode()
        return true
    }

    /// Picks the cue ball up again, to be put down somewhere else in the "D": a ball placed in hand
    /// may be moved about until the stroke is played (Section 3 Rule 5).
    public func repositionCueBall() {
        guard canRepositionCueBall, mode != .simulating, !game.state.frameOver else { return }
        game.takeCueBallInHand()
        syncWorldFromState()
        decideNextMode()
        status = "\(playerNames[currentPlayer]): place the cue ball in the D."
    }

    public func chooseColour(_ colour: BallColor) {
        game.nominateColour(colour)
        // A colour chosen by hand is the striker's own: the aim does not get to change it afterwards, and
        // looking about the table is free.
        if game.state.nominatedColour == colour { theStrikerChoseTheColourByHand = true }
        decideNextMode()
    }

    /// The colour the cue is pointing at, taken as the striker's nomination. True when that nominated
    /// something it had not nominated already.
    ///
    /// While the ball on is a colour of their own choice, aiming at a colour **is** the choice: a striker
    /// with the Yellow in their sights is playing for the Yellow, and the game takes that rather than
    /// making them press a button for something they have already said with the cue. The nomination follows
    /// the cue from colour to colour until the striker nominates one **by hand**, from which point the
    /// choice is theirs and the aim is free to wander without it.
    ///
    /// Only a colour **on the table** that is the **first thing the cue ball would meet** is taken, which
    /// is the ball on of a stroke aimed that way. A cue pointed at a cushion, or at a Red, nominates
    /// nothing and leaves the last nomination standing — and nothing is taken while another question is on
    /// the screen, or mid-stroke, when the ball on for the stroke just played is settled.
    @discardableResult
    private func nominateTheColourTheCueIsOn() -> Bool {
        let theColourIsTheStrikersToChoose = isChoosingAColour
            || (isPlayingForAColour && game.state.pending == nil)
        guard !theStrikerChoseTheColourByHand, theColourIsTheStrikersToChoose,
              !game.state.frameOver, mode != .simulating else { return false }
        guard case .ball(let id)? = predictedFirstContact()?.contact,
              let colour = BallID.colour(of: id), colour.isColour,
              colour != game.state.nominatedColour else { return false }
        game.nominateColour(colour, announced: false)
        return true
    }

    public func chooseFreeBall(_ colour: BallColor) {
        game.nominateFreeBall(colour)
        decideNextMode()
    }

    public func declineFreeBall() {
        game.declineFreeBall()
        decideNextMode()
    }

    public func playFromPositionLeft() {
        game.acceptPositionLeft()
        decideNextMode()
    }

    /// Whether the non-offender may still take their answer to the foul (or miss) question back: the
    /// `U` key. It is theirs to do until the next stroke is played, and only if they answered it by
    /// playing from where the balls lie. See `SnookerGame.canChooseSomethingElse`.
    public var canChooseSomethingElse: Bool { game.canChooseSomethingElse }

    /// Puts that question back, with the position as it was when it was asked.
    public func chooseSomethingElse() {
        guard game.canChooseSomethingElse else { return }
        game.chooseSomethingElse()
        decideNextMode()
        commentary = game.state.commentary
    }

    public func askOffenderToPlayAgain() {
        game.askOffenderToPlayAgain()
        decideNextMode()
    }

    /// Ask for the balls to be replaced and the offender to play again from the original position.
    public func requestOriginalPosition() {
        game.requestOriginalPosition()
        syncWorldFromState()
        decideNextMode()
    }

   public func reRack() {
       takeBackTheCountIfTheFrameHadEnded()
       game.reRack()
       syncWorldFromState()
        theStrikerChoseTheColourByHand = false
       isAskingAboutAReRack = false
        mode = .placingCueBall
        canRepositionCueBall = true
        status = "Stalemate: frame re-racked, scores nullified."
        commentary = game.state.commentary
    }

    public func concede() {
        game.concede(player: currentPlayer)
        decideNextMode()
    }

    /// True when the frame is there for the **striker** to claim (Section 2 Rule 1(b)): no more than the
    /// Black is left and they are more than seven points ahead. They are not made to take it — playing on
    /// is their right, and the first pot or foul then ends the frame with the scores deciding it (Rule
    /// 4(a)). The non-striker's own case is an **award** and is taken the moment it is noticed rather than
    /// offered as a button: see `SnookerGame.awardTheFrameToTheNonStriker`. This is only what puts the
    /// button on the screen.
    public var canClaimTheFrame: Bool { game.strikerMayClaimTheFrame }

    /// Claims the frame for the player it is there for. Does nothing when it is not there to claim.
    public func claimTheFrame() {
        guard game.claimTheFrame() else { return }
        decideNextMode()
    }

    // MARK: - Aim assistance

    /// What a shot would meet first, and where the cue ball's centre would be when it met it.
    public enum AimContact: Equatable, Sendable {
        /// An object ball.
        case ball(id: Int)
        /// A cushion, or the round at the end of one. A shot aimed at a cushion with nothing in the
        /// way is still worth a ghost ball: that is where on the cushion the cue ball will arrive.
        case cushion(side: CushionSide)
    }

    /// First thing the cue ball would hit along the current aim — a ball, or a cushion — and where
    /// its own centre would be when it touched it. That is the ghost ball's place.
    public func predictedFirstContact() -> (point: Vec2, contact: AimContact)? {
        guard let cue = cueBall, cue.onTable else { return nil }
        let dir = Vec2(cos(aimAngle), sin(aimAngle))
        var best: (distance: Double, contact: AimContact, point: Vec2)?
        for ball in world.balls where ball.onTable && ball.id != BallID.cue {
            let toBall = ball.position - cue.position
            let along = toBall.dot(dir)
            guard along > 0 else { continue }
            let perpendicularSquared = toBall.lengthSquared - along * along
            let radius = Table.ballDiameter
            guard perpendicularSquared <= radius * radius else { continue }
            let offset = (radius * radius - perpendicularSquared).squareRoot()
            let distance = along - offset
            guard distance > 0 else { continue }
            if best == nil || distance < best!.distance {
                best = (distance, .ball(id: ball.id), cue.position + dir * distance)
            }
        }
        if let cushion = world.firstCushionContact(from: cue.position, direction: dir),
           best == nil || cushion.distance < best!.distance {
            best = (cushion.distance, .cushion(side: cushion.side), cushion.point)
        }
        guard let hit = best else { return nil }
        return (hit.point, hit.contact)
    }
}
