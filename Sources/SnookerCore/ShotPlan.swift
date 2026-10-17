import Foundation

// MARK: - A shot

/// A stroke, as the computer plays it: the same five things a player's hand sets on the cue, and the
/// same five things `FrameDriver.shoot` takes.
public struct Shot: Equatable, Sendable {
    /// The way the cue is pointing, in radians, measured the same way as `FrameDriver.aimAngle`.
    public var angle: Double
    /// The strength: the cue ball's speed away, as a fraction of `FrameDriver.maxPower`.
    public var power: Double
    /// Side spin, −1…1 — the tip across the ball's face.
    public var side: Double
    /// Vertical spin, −1…1: positive is follow through the ball, negative is screw back.
    public var vertical: Double
    /// How far the cue is stood up, in radians: 0 is the player's own level stance.
    public var elevation: Double

    public init(angle: Double, power: Double, side: Double = 0,
                vertical: Double = 0, elevation: Double = 0) {
        self.angle = angle
        self.power = power
        self.side = side
        self.vertical = vertical
        self.elevation = elevation
    }

    /// Plays the shot on a frame, the way a **player** plays one: a charge, and the cue action it leaves
    /// behind — the pull-back, the tip's own contact with the ball, and the follow-through.
    ///
    /// It is the stroke the mouse button and the space bar play, and it is the same stroke the computer's
    /// own search plays each candidate out with, so what a caller plays is what the search judged. The
    /// caller drives the frame on from here: the shot is not away until the cue's own run brings the tip
    /// into the ball.
    public func play(on driver: FrameDriver) {
        driver.playCharged(self, at: Date().timeIntervalSinceReferenceDate)
    }

    public var angleInDegrees: Double { angle * 180 / .pi }

    public var describedForTheLog: String {
        String(format: "%.1f° power %.2f side %+.2f vertical %+.2f", angleInDegrees, power, side, vertical)
    }
}

/// What a candidate shot is for. Carried with the shot so a decision can be explained, and so a test
/// can say what the computer thought it was doing.
public enum ShotIntent: Equatable, Sendable {
    /// Pot the ball into the pocket, along the line the cue ball sends it.
    case pot(ball: Int, pocket: PocketID, cut: Double)
    /// Strike a ball on and leave nothing: a safety.
    case safety(ball: Int)
    /// Nothing can be hit straight on — come off a cushion, or through a gap, to reach a ball on.
    case escape
    /// A stroke a learned policy chose: it gives every parameter of the stroke itself, so what the shot is
    /// *for* is the policy's own business and not something the geometry has a word to say about.
    case neural

    /// A word for the commentary.
    public var summary: String {
        switch self {
        case .pot(let ball, let pocket, let cut):
            return String(format: "pot %@ into %@ (cut %.0f°)",
                          ShotIntent.name(of: ball), pocket.rawValue, cut * 180 / .pi)
        case .safety(let ball):
            return "safety off \(ShotIntent.name(of: ball))"
        case .escape:
            return "escape"
        case .neural:
            return "the network's shot"
        }
    }

    static func name(of ball: Int) -> String {
        if ball == BallID.cue { return "cue ball" }
        if ball >= BallID.firstRed, ball <= BallID.lastRed { return "red \(ball)" }
        return BallID.colour(of: ball)?.rawValue.capitalized ?? "ball \(ball)"
    }
}

// MARK: - Where the balls are

/// Where every ball is, as the planner wants it: the rules' own layout, in millimetres in the table's
/// plane, with the cue ball named apart because everything is aimed from it.
public struct BallLayout: Sendable {
    public struct Placed: Sendable, Equatable {
        public var id: Int
        public var position: Vec2
        public init(id: Int, position: Vec2) {
            self.id = id
            self.position = position
        }
    }

    public var cue: Vec2
    public var placed: [Placed]

    public init(cue: Vec2, placed: [Placed]) {
        self.cue = cue
        self.placed = placed
    }

    public init(state: GameState) {
        var placed: [Placed] = []
        for id in state.ballsOnTable.sorted() {
            guard let position = state.ballPositions[id] else { continue }
            placed.append(Placed(id: id, position: position))
        }
        self.placed = placed
        self.cue = state.ballPositions[BallID.cue] ?? Table.brownSpot
    }

    public func position(of id: Int) -> Vec2? {
        placed.first { $0.id == id }?.position
    }

    /// Every ball but the ones named: what a path has to keep clear of.
    public func leavingOut(_ ids: Set<Int>) -> [Placed] {
        placed.filter { !ids.contains($0.id) }
    }
}

// MARK: - The geometry a shot is built from

/// The arithmetic the planner aims by. Nothing here plays anything: it is what a candidate shot is
/// proposed from, and the physics is what decides whether the shot works.
public enum ShotGeometry {
    /// How far a ball travels over the cloth for the speed it is struck at: `distance = clothTravel *
    /// speed²`.
    ///
    /// It is **measured off the physics, not derived from the cloth's own coefficient**. A ball struck at
    /// its middle slides before it rolls, and the slide costs a good deal more than the rolling
    /// resistance alone would — the derivation says a ball struck at 480 mm/s travels 600 mm, and the
    /// physics says 703 — so the constant the shots are worked out with is the one `--ai-roll` prints,
    /// fitted over the speeds a pot is played at. Everything the planner aims by comes from here, and it
    /// is the first thing to re-measure if the physics is ever tuned.
    public static let clothTravel = 3.0e-3

    /// How far a ball struck at `speed` mm/s travels before the cloth stops it.
    public static func travel(fromSpeed speed: Double) -> Double {
        clothTravel * speed * speed
    }

    /// The speed a ball has to be struck at to travel `distance` millimetres.
    public static func speedToTravel(_ distance: Double) -> Double {
        (max(0, distance) / clothTravel).squareRoot()
    }

    /// How much of a ball's speed along the line of centres the ball it strikes takes away: with equal
    /// masses and the physics world's own restitution, `(1 + e) / 2`.
    public static let contactTransfer = (1 + PhysicsWorld.ballRestitution) / 2

    /// Whether a ball's centre can stand at `point` and still be on the cloth.
    public static func isOnTheCloth(_ point: Vec2, margin: Double = Table.ballRadius) -> Bool {
        let slack = 1e-9
        return point.x >= margin - slack && point.x <= Table.length - margin + slack
            && point.y >= margin - slack && point.y <= Table.width - margin + slack
    }

    /// Whether a ball's centre travelling straight from `from` to `to` keeps clear of every ball in
    /// `balls`. Two balls meet when their centres come within a diameter of each other, so a ball whose
    /// centre stands closer than that to the line is in the way of it.
    public static func isClearPath(from: Vec2, to: Vec2, past balls: [BallLayout.Placed],
                                   ignoring: Set<Int> = [],
                                   clearance: Double = Table.ballDiameter) -> Bool {
        let along = to - from
        let length = along.length
        guard length > 1e-9 else { return true }
        let direction = along / length
        for ball in balls where !ignoring.contains(ball.id) {
            let toBall = ball.position - from
            let alongTheLine = toBall.dot(direction)
            guard alongTheLine > 0, alongTheLine < length else { continue }
            if (toBall - direction * alongTheLine).length < clearance { return false }
        }
        return true
    }

    /// Whether a ball's centre travelling from `from` to `to` keeps to the cloth the whole way. A
    /// straight path's extremes are its ends, so the ends are all there is to check.
    public static func staysOnTheCloth(from: Vec2, to: Vec2,
                                       margin: Double = Table.ballRadius) -> Bool {
        isOnTheCloth(from, margin: margin) && isOnTheCloth(to, margin: margin)
    }

    /// The unit vector from one point towards another.
    public static func direction(_ from: Vec2, _ to: Vec2) -> Vec2 {
        (to - from).normalized
    }

    /// The angle of a direction, measured the way `FrameDriver.aimAngle` is.
    public static func angle(of direction: Vec2) -> Double {
        atan2(direction.y, direction.x)
    }

    /// A direction turned by `radians` about the vertical.
    public static func turn(_ direction: Vec2, by radians: Double) -> Vec2 {
        Vec2(direction.x * cos(radians) - direction.y * sin(radians),
             direction.x * sin(radians) + direction.y * cos(radians))
    }

    /// The angle between two directions, 0…π.
    public static func angleBetween(_ a: Vec2, _ b: Vec2) -> Double {
        acos(min(1, max(-1, a.normalized.dot(b.normalized))))
    }

    /// The angle between two directions given as angles, 0…π.
    public static func angleBetween(_ a: Double, _ b: Double) -> Double {
        abs(atan2(sin(a - b), cos(a - b)))
    }

    /// The turn of the **object ball** off the line of centres, as two balls rub against one another: the
    /// friction at the touch, and the cue ball's side spin's part in it.
    ///
    /// The touch is worth a normal impulse of `(1+e)·V·cos(cut)/2`. What slides there is the cue ball's own
    /// surface running across the object ball — `2.5·side·V` from the side spin, less `V·sin(cut)` from the
    /// cut itself, which is the cue ball's surface already moving across the face of a cut — and friction
    /// takes `min(slip/7, μ·jn)` of it. The object ball leaves `atan(jt/jn)` off the line of centres. Both
    /// figures are proportional to the speed, so the throw depends on the **cut and the side alone** and not
    /// on how hard the shot is played. Positive is a quarter turn counter-clockwise off the line of centres.
    public static func throwAngle(cut: Double, side: Double) -> Double {
        let k = max(-PhysicsWorld.cueTipOffsetLimit, min(PhysicsWorld.cueTipOffsetLimit, side))
        let normalSpeed = cos(cut)
        guard normalSpeed > 1e-6 else { return 0 }
        let normalImpulse = (1 + PhysicsWorld.ballRestitution) * normalSpeed / 2
        let slip = 2.5 * k - sin(cut)
        let friction = min(abs(slip) / 7, PhysicsWorld.ballFriction * normalImpulse)
        let angle = atan2(friction, normalImpulse)
        return slip < 0 ? -angle : angle
    }

    /// The angle the cue ball leaves at **across** the cue's own line when the tip strikes `side` of its
    /// face: squirt. A throw-aware aim has to take it out of the line as well as the throw, because the cue
    /// ball's path is what sets the line of centres the object ball is thrown off.
    public static func squirtAngle(side: Double) -> Double {
        let k = max(-PhysicsWorld.cueTipOffsetLimit, min(PhysicsWorld.cueTipOffsetLimit, side))
        return 0.022 * k
    }

    /// Where the cue has to point to send `objectBall` along `objectDirection` with `side` spin on the cue
    /// ball, the **throw** and the **squirt** both taken out.
    ///
    /// The object ball leaves the line of centres thrown by `throwAngle`, so the line — and the ghost ball
    /// with it — is turned the other way, and the cue is aimed at **that** ghost. The cue ball itself leaves
    /// across the cue's line by its squirt, so the aim is turned back by that too. The ghost is only a
    /// ball's width from the object ball, so a few degrees of throw turn the **aim** by a good deal less
    /// than a few degrees: the turn is `diameter · throw` about the object ball, spread over the whole way
    /// the cue ball has to come. The cut is taken again from the moved ghost, since it is what the throw is
    /// read from, and the second pass settles the couple of degrees the first one moves it.
    public static func throwAwareAim(cueBall: Vec2, objectBall: Vec2,
                                     objectDirection: Vec2, side: Double) -> (ghost: Vec2, angle: Double) {
        let desired = objectDirection.normalized
        guard desired.length > 0, cueBall.distance(to: objectBall) > Table.ballDiameter else {
            let ghost = objectBall - desired * Table.ballDiameter
            return (ghost, angle(of: ghost - cueBall))
        }
        var ghost = objectBall - desired * Table.ballDiameter
        var aim = angle(of: ghost - cueBall)
        for _ in 0..<2 {
            let cut = angleBetween(ghost - cueBall, desired)
            let turned = rotate(desired, by: -throwAngle(cut: cut, side: side))
            ghost = objectBall - turned * Table.ballDiameter
            aim = angle(of: ghost - cueBall) - squirtAngle(side: side)
        }
        return (ghost, aim)
    }

    /// The cue angle `throwAwareAim` gives, for a caller that only wants the angle.
    public static func throwAwareAngle(cueBall: Vec2, objectBall: Vec2,
                                       objectDirection: Vec2, side: Double) -> Double {
        throwAwareAim(cueBall: cueBall, objectBall: objectBall,
                      objectDirection: objectDirection, side: side).angle
    }

    /// `v` turned by `angle` counter-clockwise.
    static func rotate(_ v: Vec2, by angle: Double) -> Vec2 {
        let c = cos(angle), s = sin(angle)
        return Vec2(v.x * c - v.y * s, v.x * s + v.y * c)
    }

    /// Where a ball is seen **in a cushion**: the point a shot has to be aimed at to reach the ball after
    /// bouncing off that cushion once.
    ///
    /// A ball leaves a cushion as a mirror leaves it, so the line of the shot to the ball's own image is
    /// the line the cue ball must take: it meets the cushion at the same place as the line to the ball
    /// would, and carries on to the ball. The mirror is taken about the line the **ball's centre** reaches
    /// at the cushion — the nose line, a ball's radius inside the cushion's own face.
    public static func reflection(of point: Vec2, in cushion: CushionSide) -> Vec2 {
        let r = Table.ballRadius
        switch cushion {
        case .left: return Vec2(2 * r - point.x, point.y)
        case .right: return Vec2(2 * (Table.length - r) - point.x, point.y)
        case .bottom: return Vec2(point.x, 2 * r - point.y)
        case .top: return Vec2(point.x, 2 * (Table.width - r) - point.y)
        }
    }

    /// A route to a ball **off one cushion**: aim at the ball's own image in the cushion, and check both
    /// halves of the way.
    ///
    /// The image is what makes a bounce work — the line from the cue ball to the ball seen in the cushion
    /// meets the cushion exactly where the line to the ball would, and carries on to the ball — but the
    /// image alone says nothing about whether either half of the path is **clear**, which is why most of
    /// these shots do not come off when they are aimed at blind. Two things are checked here that the
    /// image does not know: every other ball is out of the way of both halves, and the cue ball meets the
    /// **rubber** rather than a jaw or the mouth of a pocket.
    ///
    /// The physics is still what says whether the shot arrives. This says the way is not obviously barred,
    /// which is enough to be worth playing out.
    public static func routeOffACushion(from cue: Vec2, to ball: Vec2, target: Int,
                                        off cushion: CushionSide, past balls: [BallLayout.Placed],
                                        hold: Double = 1,
                                        clearance: Double = Table.ballDiameter)
        -> (angle: Double, bounce: Vec2)? {
        // What the cushion does with the angle: 1 is a mirror, and this table's cushions are less than
        // that. See `cushionHold(forNormalSpeed:)`.
        let keeps = min(1, max(0.5, hold))
        let inward: Vec2
        let along: Vec2
        switch cushion {
        case .left: inward = Vec2(1, 0); along = Vec2(0, 1)
        case .right: inward = Vec2(-1, 0); along = Vec2(0, 1)
        case .bottom: inward = Vec2(0, 1); along = Vec2(1, 0)
        case .top: inward = Vec2(0, -1); along = Vec2(1, 0)
        }

        /// Where the line from the cue ball along `direction` meets this cushion.
        func crossing(of direction: Vec2) -> Double? {
            let r = Table.ballRadius
            switch cushion {
            case .left:
                guard direction.x < -1e-9 else { return nil }
                return (r - cue.x) / direction.x
            case .right:
                guard direction.x > 1e-9 else { return nil }
                return (Table.length - r - cue.x) / direction.x
            case .bottom:
                guard direction.y < -1e-9 else { return nil }
                return (r - cue.y) / direction.y
            case .top:
                guard direction.y > 1e-9 else { return nil }
                return (Table.width - r - cue.y) / direction.y
            }
        }

        // The bounce starts from the mirror's own answer and is turned, a little at a time, into the one
        // that sends the ball where the ball is: the aim has to be **wider** than the mirror's, because
        // the cushion gives the ball back closer to the normal than it arrived.
        guard let mirror = crossing(of: (reflection(of: ball, in: cushion) - cue).normalized) else {
            return nil
        }
        var bounce = cue + (reflection(of: ball, in: cushion) - cue).normalized * mirror
        var direction = (bounce - cue).normalized
        for _ in 0..<6 {
            let outgoing = (ball - bounce).normalized
            let outwards = max(1e-6, outgoing.dot(inward))
            let angleOut = atan2(abs(outgoing.dot(along)), outwards)
            let angleIn = min(1.5, angleOut / keeps)
            let side: Double = outgoing.dot(along) < 0 ? -1 : 1
            // Broken into its parts: written as one expression the arithmetic is too much for the type
            // checker to see through in reasonable time.
            let towardsTheCushion: Double = cos(angleIn)
            let acrossTheCushion: Double = sin(angleIn) * side
            let incoming: Vec2 = Vec2(-inward.x, -inward.y) * towardsTheCushion
                + along * acrossTheCushion
            guard let distance = crossing(of: incoming), distance > 1e-6 else { return nil }
            direction = incoming
            bounce = cue + incoming * distance
        }

        // Off the rubber, and not into the jaws: a ball whose centre meets the cushion inside a pocket's
        // own mouth is going into the pocket, or onto a jaw, and neither is the shot that was worked out.
        for pocket in PocketID.allCases where bounce.distance(to: pocket.cut.mouth) < pocket.cut.width {
            return nil
        }
        // The way there, with every ball in the way counting — the ball being aimed at included, because a
        // route that runs through it is not a route.
        guard isClearPath(from: cue, to: bounce, past: balls, ignoring: [BallID.cue]) else { return nil }
        // And the way back, where the ball being aimed at is the one thing that is allowed to be there.
        guard isClearPath(from: bounce, to: ball, past: balls,
                          ignoring: [BallID.cue, target], clearance: clearance) else { return nil }
        return (angle(of: direction), bounce)
    }

    /// How much of its angle a ball **keeps** off a cushion: the angle it leaves at over the angle it
    /// arrived at. One would be a mirror, and this table's cushions are deliberately less than one — the
    /// rubber holds the ball and turns it towards the normal, the harder the harder it is hit — so a shot
    /// aimed at the ball's own image in the cushion comes off short of it.
    ///
    /// The numbers are `--ai-cushion`'s, measured off the physics rather than taken from the model: 0.88 at
    /// a walking pace, 0.84 at a medium shot's impact and 0.70 at a hard one, and the straight line
    /// between them is close enough for the three or four degrees it is ever asked to correct.
    public static func cushionHold(forNormalSpeed speed: Double) -> Double {
        min(1, max(0.65, 0.892 - 0.0000455 * speed))
    }

    /// The speed a shot launched at `launch` mm/s is still doing after rolling `distance` millimetres.
    public static func speedAfter(travelling distance: Double, from launch: Double) -> Double {
        (max(0, launch * launch - distance / clothTravel)).squareRoot()
    }

    /// What a shot straight along `direction` meets first.
    public enum FirstContact: Equatable, Sendable {
        /// A ball, at the place the cue ball's centre is when they touch.
        case ball(id: Int, at: Vec2)
        /// A cushion, at the place the cue ball's centre is when it reaches it.
        case cushion(side: CushionSide, at: Vec2)
    }

    /// The first thing a shot along `direction` meets, by a straight line and nothing else: no spin, no
    /// nap, no jaws, no pockets. It is not a prediction of what a shot does — the physics is that — but it
    /// is the **cheap** question, and the one worth asking of a thousand aim directions to find the few
    /// that are worth playing out. Nothing is decided with it; shots are only thrown away with it.
    public static func firstContact(from cue: Vec2, direction: Vec2,
                                    balls: [BallLayout.Placed],
                                    ignoring: Set<Int> = [],
                                    margin: Double = 0) -> FirstContact? {
        let dir = direction.normalized
        guard dir.length > 0 else { return nil }
        var best: (distance: Double, contact: FirstContact)?
        func keep(_ distance: Double, _ contact: FirstContact) {
            guard distance > 1e-6 else { return }
            if best == nil || distance < best!.distance { best = (distance, contact) }
        }

        for ball in balls where !ignoring.contains(ball.id) {
            let toTheBall = ball.position - cue
            let along = toTheBall.dot(dir)
            guard along > 0 else { continue }
            let across = abs(toTheBall.dot(dir.perpendicular))
            // `margin` widens what counts as meeting a ball. A shot that would pass within a few
            // millimetres of one is a shot that might miss it, or clip it — and a plan that turns on a
            // graze is not a plan. Nothing is decided with the margin; candidates are thrown away with it.
            guard across < Table.ballDiameter + margin else { continue }
            // The two centres are a diameter apart at the contact; where along the line that is. A ball
            // the margin has caught is already closer than a diameter — the shot would graze it — so the
            // closest approach is the contact there, and the square root is taken of nothing.
            let back = (max(0, Table.ballDiameter * Table.ballDiameter - across * across)).squareRoot()
            let at = cue + dir * (along - back)
            keep(along - back, .ball(id: ball.id, at: at))
        }

        let r = Table.ballRadius
        if dir.x < 0 { let t = (r - cue.x) / dir.x; keep(t, .cushion(side: .left, at: cue + dir * t)) }
        if dir.x > 0 {
            let t = (Table.length - r - cue.x) / dir.x
            keep(t, .cushion(side: .right, at: cue + dir * t))
        }
        if dir.y < 0 { let t = (r - cue.y) / dir.y; keep(t, .cushion(side: .bottom, at: cue + dir * t)) }
        if dir.y > 0 {
            let t = (Table.width - r - cue.y) / dir.y
            keep(t, .cushion(side: .top, at: cue + dir * t))
        }
        return best?.contact
    }

    /// Whether a ball's centre travelling from `from` to `to` keeps out of every pocket on the way.
    ///
    /// A path across the mouth of a pocket is a path the cue ball can drop into, and an escape that pots
    /// the cue ball is a foul like any other — four points and the opponent in hand.
    public static func pathKeepsOutOfThePockets(from: Vec2, to: Vec2) -> Bool {
        for pocket in PocketID.allCases {
            let hole = pocket.cut.holeCentre
            let along = to - from
            let length = along.length
            guard length > 1e-9 else { return true }
            let direction = along / length
            let toTheHole = hole - from
            let near = min(length, max(0, toTheHole.dot(direction)))
            let closest = from + direction * near
            if closest.distance(to: hole) < pocket.cut.holeRadius + Table.ballRadius { return false }
        }
        return true
    }
}

// MARK: - Proposing shots

/// One shot the computer is thinking about, and why.
public struct ShotCandidate: Sendable {
    public var shot: Shot
    public var intent: ShotIntent
    /// How hard the shot looks **from the geometry alone**: 0 is the easiest pot on the table, 1 the
    /// hardest the computer will consider. It orders the candidates, and it is how the computer guesses
    /// what an opponent will be left — the physics is what says whether the shot is really on.
    public var ease: Double
    /// True when a **cheap straight-line test** says this shot reaches a ball on — not that it does, which
    /// is still the physics' business, but that the geometry has nothing to say against it: the line is
    /// clear of every other ball, or both halves of a cushion route are. Candidates that verify are worth
    /// playing out before the ones that do not.
    public var verifies: Bool

    public init(shot: Shot, intent: ShotIntent, ease: Double, verifies: Bool = false) {
        self.shot = shot
        self.intent = intent
        self.ease = ease
        self.verifies = verifies
    }
}

/// Builds the shots worth thinking about: the pots that are geometrically on, the safeties off the
/// balls on, and — when nothing can be reached straight — the escapes.
public enum ShotGenerator {

    public struct Settings: Sendable {
        /// Past this cut the object ball takes so little of the cue ball's speed that the shot is not
        /// worth playing: `cos 72°` is a third of it.
        public var maximumCutAngle: Double = 72 * .pi / 180
        /// How far off the pocket's own line the object ball may be travelling and still be aimed at it.
        public var maximumApproachAngle: Double = 60 * .pi / 180
        /// How far into the pocket's passage the object ball is aimed: past the mouth, so the line runs
        /// down the middle of the jaws rather than along one of them.
        public var pocketAimDepth: Double = 25
        /// How much further than the mouth a ball's centre has to travel before it is over the hole and
        /// falls: the passage runs on past the mouth, and a ball that stops in the jaws is not potted.
        public var pocketDepthAllowance: Double = 55
        /// The speed the object ball is asked to still be doing when it reaches the pocket, on top of
        /// being able to get there at all. A ball that arrives with nothing left dribbles across the
        /// mouth and stops in the jaws: `--ai-probe` measures this pot coming on at a cue ball speed of
        /// 780 mm/s, and the estimate has to be asked for a good deal more than the barest roll.
        public var arrivalSpeed: Double = 350
        public var minimumPower: Double = 0.05
        /// How many pots, safeties and escapes to offer for the physics to look at.
        public var potLimit: Int = 20
        public var safetyLimit: Int = 8
        /// How many of the nearest balls on an escape tries to reach at all, and how many of the shots it
        /// works out are played out. An escape is not a fan of directions — see `escapes` — so the count
        /// that matters is how many balls are aimed at and how many ways each of them is tried.
        public var escapeBalls: Int = 4
        public var escapeLimit: Int = 40
        /// Whether an escape is allowed to look for ways round the table: **off a cushion and into a ball
        /// on**, with both halves of the way checked. Off, the cushion shots are aimed at the ball's own
        /// image and left at that, which is what the planner did before it knew what a cushion does.
        public var cushionRoutes: Bool = true
        public var escapePowers: [Double] = [0.35, 0.7]
        public var escapePower: Double = 0.5
        public var escapeBankPower: Double = 0.7
        /// How far clear of every other ball an escape's line has to pass to be worth proposing, in
        /// millimetres. A shot that turns on a graze is a shot that will foul as often as not, and the
        /// play-outs are better spent on the ones that do not.
        public var escapeMargin: Double = 4
        public var safetyPowers: [Double] = [0.3, 0.55]
        public var safetyCuts: [Double] = [0, 25, 50, 70].map { $0 * .pi / 180 }
        public var safetyBalls: Int = 3
        /// The side spins and the cue lifts a shot's own tuning is allowed to try. Side spin is how a cue
        /// ball is brought off a cushion and a lift is what a ball against one needs: between them they are
        /// the difference between a pot that leaves nothing and a pot that leaves the next one on.
        public var sideSpins: [Double] = [0, -0.3, 0.3]
        public var elevations: [Double] = [0, 10 * .pi / 180]

        public init() {}

        /// A cheap setting for judging a position rather than playing it: the pots that are on, ordered,
        /// and nothing else.
        public static var quick: Settings {
            var s = Settings()
            s.potLimit = 400
            return s
        }
    }

    /// The pots that are geometrically on: for every ball on and every pocket, the line of centres from
    /// the ghost ball into the pocket.
    public static func pots(layout: BallLayout, targets: Set<Int>,
                            settings: Settings = Settings()) -> [ShotCandidate] {
        let diagonal = (Table.length * Table.length + Table.width * Table.width).squareRoot()
        let maximumCut = cos(settings.maximumCutAngle)
        var found: [ShotCandidate] = []

        for target in targets.sorted() {
            guard let ball = layout.position(of: target) else { continue }
            let blockers = layout.leavingOut([BallID.cue, target])
            for pocket in PocketID.allCases {
                let cut = pocket.cut
                let aimPoint = cut.mouth + cut.axis * settings.pocketAimDepth
                let towardsThePocket = aimPoint - ball
                guard towardsThePocket.length > 1 else { continue }
                let objectDirection = towardsThePocket.normalized
                // The ball has to go into the pocket the way the pocket runs, or it meets a jaw.
                guard ShotGeometry.angleBetween(objectDirection, cut.axis) <= settings.maximumApproachAngle
                else { continue }
                guard ShotGeometry.isClearPath(from: ball, to: aimPoint, past: blockers) else { continue }

                // Where the cue ball's centre has to arrive to send the object ball down that line.
                let ghost = ball - objectDirection * Table.ballDiameter
                guard ShotGeometry.isOnTheCloth(ghost) else { continue }
                let towardsTheGhost = ghost - layout.cue
                guard towardsTheGhost.length > 1 else { continue }
                let cueDirection = towardsTheGhost.normalized
                let cosCut = cueDirection.dot(objectDirection)
                guard cosCut > maximumCut else { continue }
                guard ShotGeometry.isClearPath(from: layout.cue, to: ghost, past: blockers) else { continue }
                guard ShotGeometry.staysOnTheCloth(from: layout.cue, to: ghost) else { continue }

                // The object ball has to be able to carry the pocket's distance and still be moving when
                // it gets there; the cue ball has to deliver that much along the line of centres at the
                // moment it arrives, which is more than delivering it at the tip, because it loses speed
                // on the way over.
                let toTheHole = ball.distance(to: cut.mouth) + settings.pocketDepthAllowance
                let objectSpeed = ShotGeometry.speedToTravel(toTheHole) + settings.arrivalSpeed
                let throughTheBall = objectSpeed / max(ShotGeometry.contactTransfer * cosCut, 0.05)
                let cueSpeed = ShotGeometry.speedToTravel(
                    towardsTheGhost.length + ShotGeometry.travel(fromSpeed: throughTheBall))
                let power = cueSpeed / FrameDriver.maxPower
                guard power >= settings.minimumPower, power <= 1.0 else { continue }

                let cutAngle = ShotGeometry.angleBetween(cueDirection, objectDirection)
                // What the two balls' own friction will do to the object ball: a full ball goes straight,
                // and a cut is thrown back towards the cue ball's line, so the ghost ball is moved round
                // the object ball by the throw before the cue is aimed at it. A shot with side on it is
                // built again for that side when the search tries it — see `ComputerPlayer.tune`.
                let aim = ShotGeometry.throwAwareAim(cueBall: layout.cue, objectBall: ball,
                                                     objectDirection: objectDirection, side: 0)
                // The cue ball's path is what has to be clear, and it is the line to **this** ghost: the
                // ghost has moved by the throw, and a clearance checked against the old one is a different
                // shot. See `ShotGeometry.throwAwareAim`.
                guard ShotGeometry.isOnTheCloth(aim.ghost),
                      ShotGeometry.isClearPath(from: layout.cue, to: aim.ghost, past: blockers),
                      ShotGeometry.staysOnTheCloth(from: layout.cue, to: aim.ghost) else { continue }
                let ease = potEase(cut: cutAngle / settings.maximumCutAngle,
                                   cueDistance: towardsTheGhost.length / diagonal,
                                   objectDistance: toTheHole / diagonal)
                found.append(ShotCandidate(
                    shot: Shot(angle: aim.angle, power: power),
                    intent: .pot(ball: target, pocket: pocket, cut: cutAngle),
                    ease: ease))
            }
        }

        found.sort { $0.ease < $1.ease }
        // Two ways of potting the same ball into the same pocket differ only in the last decimal place:
        // keep the best of them.
        var seen: Set<String> = []
        var unique: [ShotCandidate] = []
        for candidate in found {
            let key = "\(candidate.intent)"
            if seen.insert(key).inserted { unique.append(candidate) }
        }
        return Array(unique.prefix(settings.potLimit))
    }

    /// Safeties: off the nearest balls on, full and thin, at a couple of strengths. What they leave is
    /// for the physics to say.
    public static func safeties(layout: BallLayout, targets: Set<Int>,
                                settings: Settings = Settings()) -> [ShotCandidate] {
        let nearest = targets
            .compactMap { id -> (Int, Double)? in
                guard let position = layout.position(of: id) else { return nil }
                return (id, layout.cue.distance(to: position))
            }
            .sorted { $0.1 < $1.1 }
            .prefix(settings.safetyBalls)

        var found: [ShotCandidate] = []
        let others = layout.leavingOut([BallID.cue])
        for (target, distance) in nearest {
            guard let ball = layout.position(of: target) else { continue }
            let straightAt = ShotGeometry.direction(layout.cue, ball)
            let nearness = min(1, distance / 3000)
            for cut in settings.safetyCuts {
                for (index, power) in settings.safetyPowers.enumerated() {
                    // Only the gentlest strength for the thinnest contacts: a very thin cut played hard
                    // is a different shot, and the ones that matter here are the ones that leave the cue
                    // ball safe.
                    if cut > 60 * .pi / 180, index > 0 { continue }
                    // Dead straight at the ball, or cut across its face to one side or the other.
                    let aims = cut == 0
                        ? [straightAt]
                        : [-1.0, 1.0].map { ShotGeometry.turn(straightAt, by: $0 * cut) }
                    for aim in aims {
                        // A safety is only worth playing out if it reaches a ball that is **on** first. A
                        // ray test says which ball that would be; the physics still says the rest.
                        guard case .ball(let first, _)? = ShotGeometry.firstContact(
                            from: layout.cue, direction: aim, balls: others),
                            targets.contains(first) else { continue }
                        found.append(ShotCandidate(
                            shot: Shot(angle: ShotGeometry.angle(of: aim), power: power),
                            intent: .safety(ball: target),
                            ease: min(1, nearness + abs(cut) / .pi)))
                    }
                }
            }
        }
        found.sort { $0.ease < $1.ease }
        return Array(found.prefix(settings.safetyLimit))
    }

    /// Escapes: nothing is on, so the shot is about **reaching a ball on at all**.
    ///
    /// A fan of directions all round the table is not good enough for this. A ball's own width is about
    /// four degrees at the length of a snooker, half of that for a thin contact, and a fan fine enough to
    /// be sure of finding one is hundreds of shots — of which the search can afford twenty. So the balls
    /// on are aimed **at**: full, thin to either side of them, and at the place each of them is seen from
    /// in each cushion, which is where a shot must be aimed to reach the ball after one bounce. Which of
    /// them arrives is the physics' business, and that is what the play-outs are for.
    public static func escapes(layout: BallLayout, targets: Set<Int>,
                               settings: Settings = Settings()) -> [ShotCandidate] {
        let nearest = targets
            .compactMap { id -> (Int, Double)? in
                guard let position = layout.position(of: id) else { return nil }
                return (id, layout.cue.distance(to: position))
            }
            .sorted { $0.1 < $1.1 }
            .prefix(settings.escapeBalls)

        var found: [ShotCandidate] = []
        // Where the balls on are, reached by a straight line: a quarter of a degree apart, which is finer
        // than a ball's own width at the far end of the table. This is the cheap half of the work — the
        // physics is still what says whether the shot arrives, and whether it was legal when it did.
        let others = layout.leavingOut([BallID.cue])
        var lines: [Int: [(angle: Double, thickness: Double)]] = [:]
        var angle = -Double.pi
        while angle < Double.pi {
            let direction = Vec2(cos(angle), sin(angle))
            if case .ball(let id, _)? = ShotGeometry.firstContact(from: layout.cue, direction: direction,
                                                                  balls: others,
                                                                  margin: settings.escapeMargin),
               targets.contains(id),
               let ball = layout.position(of: id),
               // And the way there keeps out of the pockets: a cue ball that drops in on its way to a ball
               // on is a foul, and it is a foul that looks like a good shot until it is played.
               ShotGeometry.pathKeepsOutOfThePockets(from: layout.cue, to: ball) {
                let straightAt = ShotGeometry.direction(layout.cue, ball)
                let thickness: Double = 1 - ShotGeometry.angleBetween(direction, straightAt)
                    / max(1e-6, asin(min(0.9, Table.ballRadius / max(1, layout.cue.distance(to: ball)))))
                lines[id, default: []].append((angle, max(0, min(1, thickness))))
            }
            angle += 0.25 * Double.pi / 180
        }
        for (id, hits) in lines {
            guard let ball = layout.position(of: id) else { continue }
            let distance = layout.cue.distance(to: ball)
            let nearness = min(1, distance / 4000)
            // A few of the ways to reach it: the fullest contact and the thinnest ones either side.
            let chosen = [hits.max { $0.thickness < $1.thickness },
                          hits.filter { $0.thickness < 0.35 }.first,
                          hits.filter { $0.thickness < 0.35 }.last].compactMap { $0 }
            for hit in chosen {
                for power in settings.escapePowers {
                    found.append(ShotCandidate(
                        shot: Shot(angle: hit.angle, power: power),
                        intent: .escape,
                        // Ordered by what the geometry knows and not by how far away the ball is: a line
                        // the ray test has found to a ball on is worth playing out before a guess at one,
                        // and the list is cut to length further down.
                        ease: 0 + (1 - hit.thickness) * 0.2 + nearness * 0.05,
                        verifies: true))
                }
            }
        }

        for (target, distance) in nearest {
            guard let ball = layout.position(of: target) else { continue }
            let nearness = min(1, distance / 4000)
            for cushion in [CushionSide.left, .right, .bottom, .top] {
                guard settings.cushionRoutes else {
                    // What the planner did before it knew what a cushion does: aim at the ball's own image
                    // and hope. Kept because it is what the route finder is measured against.
                    let image = ShotGeometry.reflection(of: ball, in: cushion)
                    let aim = ShotGeometry.direction(layout.cue, image)
                    found.append(ShotCandidate(
                        shot: Shot(angle: ShotGeometry.angle(of: aim), power: settings.escapeBankPower),
                        intent: .escape, ease: 2 + nearness))
                    continue
                }
                // Off the cushion and into the ball, with both halves of the way checked rather than
                // assumed, and aimed **both** ways: at the ball's own image, and at the place the ball has
                // to be seen from for a cushion that keeps only some of the angle. Which of the two comes
                // off is the physics' business, and it is worth playing out both.
                let launch = settings.escapeBankPower * FrameDriver.maxPower
                let impact = ShotGeometry.speedAfter(travelling: layout.cue.distance(to: ball),
                                                     from: launch) * 0.6
                for hold in [ShotGeometry.cushionHold(forNormalSpeed: impact), 1] {
                    guard let route = ShotGeometry.routeOffACushion(
                        from: layout.cue, to: ball, target: target, off: cushion, past: others,
                        hold: hold) else { continue }
                    found.append(ShotCandidate(
                        shot: Shot(angle: route.angle, power: settings.escapeBankPower),
                        intent: .escape, ease: (hold == 1 ? 0.12 : 0.06) + nearness * 0.05,
                        verifies: true))
                }
            }
        }
        found.sort { $0.ease < $1.ease }
        return Array(found.prefix(settings.escapeLimit))
    }

    /// The balls on that the cue ball could reach at all, by the rules' own view of the table.
    public static func targets(in state: GameState) -> Set<Int> {
        let game = SnookerGame()
        game.withState { $0 = state }
        return game.legalFirstContacts()
    }

    private static func potEase(cut: Double, cueDistance: Double, objectDistance: Double) -> Double {
        min(1, max(0, 0.5 * min(1, cut) + 0.25 * min(1, cueDistance) + 0.25 * min(1, objectDistance)))
    }
}
