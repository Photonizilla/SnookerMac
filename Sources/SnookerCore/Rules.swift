import Foundation

// MARK: - Ball identity

public enum BallID {
    public static let cue = 0
    public static let firstRed = 1
    public static let lastRed = 15
    public static let yellow = 16
    public static let green = 17
    public static let brown = 18
    public static let blue = 19
    public static let pink = 20
    public static let black = 21

    public static func colourID(_ colour: BallColor) -> Int? {
        switch colour {
        case .yellow: return yellow
        case .green: return green
        case .brown: return brown
        case .blue: return blue
        case .pink: return pink
        case .black: return black
        case .red: return nil
        case .white: return cue
        }
    }

    public static func colour(of id: Int) -> BallColor? {
        switch id {
        case cue: return .white
        case firstRed...lastRed: return .red
        case yellow: return .yellow
        case green: return .green
        case brown: return .brown
        case blue: return .blue
        case pink: return .pink
        case black: return .black
        default: return nil
        }
    }
}

// MARK: - What is "on"

public enum BallOn: Equatable, Sendable {
    /// A Red is on (Section 3 Rule 3(g)).
    case red
    /// A colour of the striker's choice is on (after a Red has been potted).
    case anyColour
    /// Colours come in ascending order once the Reds are gone (Section 3 Rule 3(h)(iii)).
    case colourOfSequence(BallColor)

    /// Lowest legal penalty base for this ball on: the value of the ball on (Section 3 Rule 11).
    public var nominalValue: Int {
        switch self {
        case .red: return 1
        case .anyColour: return 2  // the lowest colour the striker could nominate
        case .colourOfSequence(let c): return c.value
        }
    }
}

public struct Player: Equatable, Sendable {
    public var name: String
    public var score: Int = 0
    public var highestBreak: Int = 0

    public init(name: String) {
        self.name = name
    }
}

/// What the striker must do before the next stroke can be made.
public enum PendingDecision: Equatable, Sendable {
    /// Choose which colour is on (after potting a Red, or a free ball nominated as a Red).
    case nominateColour(options: [BallColor])
    /// Cue ball is in hand; place it in the "D" (Section 3 Rule 5).
    case placeCueBallInD
    /// Cue ball is in hand, anywhere on the table (Six Reds Rule 19(b)(iii)).
    case placeCueBallAnywhere
    /// A foul has been committed; the non-offender chooses what happens next.
    case afterFoul(FoulDecision)
    /// A foul and a miss has been called (Section 3 Rule 14).
    case afterMiss(MissDecision)
    /// Deciding whether Red or a free ball nominated as a Red is on.
    case nominateFreeBall(options: [BallColor])

    /// True when the question is the one the **non-offender** has to answer after a foul, rather than a
    /// stroke's own business.
    public var isWhatHappensNext: Bool {
        switch self {
        case .afterFoul, .afterMiss: return true
        default: return false
        }
    }
}

public struct FoulDecision: Equatable, Sendable {
    public var foul: Foul
    /// Free ball is available to the incoming player (Section 3 Rule 12).
    public var freeBallAvailable: Bool
    /// The incoming player may ask the offender to play again from the original position.
    public var canRequestOriginalPosition: Bool
}

public struct MissDecision: Equatable, Sendable {
    public var foul: Foul
    /// True when the offender was warned that the next failure loses the frame.
    public var warningJustIssued: Bool
    /// True when the frame has been awarded to the opponent (third failure).
    public var frameAwarded: Bool
    public var canRequestOriginalPosition: Bool
}

public struct Foul: Equatable, Sendable {
    /// Description shown to the players, e.g. "cue ball pocketed".
    public var reason: String
    public var penalty: Int
    public var missedBallOn: Bool = false
}

/// Everything the physics layer observed during one stroke.
public struct StrokeReport: Equatable, Sendable {
    public var firstContacts: [Int] = []
    public var potted: [Int] = []
    public var cueBallPotted: Bool = false
    public var ballsForcedOffTable: [Int] = []
    /// Balls the cue ball passed over before it had hit one: a jump shot (Rule 11(a)(x), Rule 20).
    public var jumpedOver: [Int] = []
    public var contactedAnyObjectBall: Bool = false
    /// True if the cue ball hit a cushion before contacting any object ball.
    public var cushionBeforeFirstContact: Bool = false
    public var objectBallsContacted: [Int] = []
    /// Balls that were on the table before the stroke and are not where they were after it — moved,
    /// or off the table altogether. Rule 8(b) turns on whether a ball the cue ball was touching moved.
    public var movedBalls: [Int] = []
    /// Balls the cue itself touched in play: the tip of the stick, or its side. Contacting a ball with
    /// the player's equipment is a foul (Rule 11(b)(vi)) — and the cue ball touched again after the
    /// stroke has left it is the double hit of Rule 11(a)(ii).
    public var ballsTheCueTouched: [Int] = []
    /// How long after the strike the cue ball was touched again, in seconds, when it was — the gap
    /// between the stroke's own contact and the second one, which the referee's call is timed with.
    public var secondsUntilTheCueBallWasStruckAgain: Double?

    public init() {}

    public var isSimultaneousFirstContact: Bool { firstContacts.count > 1 }
}

/// Rules engine for a frame of snooker.
///
/// Rule numbers in comments refer to the WPBSA "Official Rules of the Games of Snooker
/// and English Billiards", revised May 2022 (Section 3 unless stated otherwise).
public final class SnookerGame {
    public private(set) var state: GameState

    /// Who wins the draw for the choice of playing next when the Black is re-spotted (Section 3 Rule
    /// 4(b)(ii)). Random in play, and settable so that a test or a probe knows how it comes out.
    public var decideTheDraw: () -> Int = { Bool.random() ? 0 : 1 }

    public init(playerNames: [String] = ["Prof. Snoo", "Dr. Ker"], reds: Int = 15) {
        self.state = GameState(playerNames: playerNames, redCount: reds)
    }

    // MARK: - Frame set-up

    public func beginFrame(startingPlayer: Int = 0, reds: Int? = nil) {
        let count = reds ?? state.initialRedCount
        state = GameState(playerNames: state.players.map(\.name), redCount: count)
        state.currentPlayer = startingPlayer % 2
        state.cueBallInHand = true
        state.ballOn = .red
        state.pending = .placeCueBallInD
        state.commentary.append("Frame begins. \(state.players[startingPlayer % 2].name) to break.")
    }

    /// Initial positions of every ball for the start of a frame (Section 3 Rule 2(a)).
    public static func initialPositions(redCount: Int = 15) -> [Int: Vec2] {
        var positions: [Int: Vec2] = [:]
        positions[BallID.cue] = Vec2(Table.brownSpot.x - 150, Table.centreY + 120)  // shown in the D
        let reds = Table.rackedReds()
        for i in 0..<min(redCount, reds.count) {
            positions[BallID.firstRed + i] = reds[i]
        }
        for colour in BallColor.coloursInAscendingOrder {
            if let id = BallID.colourID(colour), let spot = Table.spot(for: colour) {
                positions[id] = spot
            }
        }
        return positions
    }

    // MARK: - Legal targets and snookers

    /// Balls the cue ball may strike first for the current ball on (Section 3 Rule 3(g)-(h)).
    public func legalFirstContacts() -> Set<Int> {
        var targets = Set<Int>()
        let ballsOnTable = state.ballsOnTable

        if let nominee = state.freeBallNominee, let id = BallID.colourID(nominee) {
            targets.insert(id)
            // A ball on hit simultaneously with the free ball is also legal (Rule 12(b)(i)).
            if case .colourOfSequence(let c) = state.ballOn, let id = BallID.colourID(c) {
                targets.insert(id)
            }
            return targets
        }

        switch state.ballOn {
        case .red:
            for id in BallID.firstRed...BallID.lastRed where ballsOnTable.contains(id) {
                targets.insert(id)
            }
        case .anyColour:
            if let nominated = state.nominatedColour, let id = BallID.colourID(nominated) {
                targets.insert(id)
            } else {
                for colour in BallColor.coloursInAscendingOrder {
                    if let id = BallID.colourID(colour), ballsOnTable.contains(id) { targets.insert(id) }
                }
            }
        case .colourOfSequence(let colour):
            if let id = BallID.colourID(colour), ballsOnTable.contains(id) { targets.insert(id) }
        }
        return targets
    }

    public func ballOnValue() -> Int {
        if let nominee = state.freeBallNominee, let id = BallID.colourID(nominee) {
            _ = id
        }
        switch state.ballOn {
        case .red: return 1
        case .anyColour: return state.nominatedColour?.value ?? 2
        case .colourOfSequence(let c): return c.value
        }
    }

    /// Section 3 Rule 8: the balls the cue ball is touching.
    ///
    /// Two balls touch when the distance between their centres is a ball's diameter. The solver leaves
    /// a resting contact at exactly that, so `Table.touchingTolerance` is a twentieth of a millimetre
    /// of slack for the arithmetic — a ball genuinely a sliver clear of another is not touching.
    ///
    /// `cueBall` and `positions` are for asking about a stroke that has been played: the touching call
    /// is made when the balls come to rest, so it is the position the next stroke is played from.
    public func touchingBalls(cueBall: Vec2? = nil, positions: [Int: Vec2]? = nil) -> [Int] {
        let layout = positions ?? state.ballPositions
        let cue = cueBall ?? layout[BallID.cue] ?? Table.brownSpot
        let touching = Table.ballDiameter + Table.touchingTolerance
        return state.ballsOnTable
            .filter { $0 != BallID.cue }
            .filter { id in
                guard let position = layout[id] else { return false }
                return position.distance(to: cue) <= touching
            }
            .sorted()
    }

    /// The balls the cue ball is touching that are on, or could be on (Rule 8(a)). Those are the ones
    /// the referee calls and the ones the striker must play away from; Rule 8(e) keeps the balls not on
    /// out of it.
    public func touchingBallsOn(cueBall: Vec2? = nil, positions: [Int: Vec2]? = nil) -> [Int] {
        let couldBeOn = ballsThatCouldBeOn()
        return touchingBalls(cueBall: cueBall, positions: positions).filter { couldBeOn.contains($0) }
    }

    /// The balls that are on, or could be on, for the ball on now: what the referee's touching call is
    /// drawn from (Rule 8(a)) and what Rule 8(c) works in. A Red is on while any Red is left; in the
    /// colours it is the colour in sequence, or — while the striker is choosing one — any colour still
    /// on the table; and a nominated free ball is a ball on for the stroke.
    private func ballsThatCouldBeOn() -> Set<Int> {
        var couldBeOn: Set<Int>
        switch state.ballOn {
        case .red:
            couldBeOn = Set((BallID.firstRed...BallID.lastRed).filter { state.ballsOnTable.contains($0) })
        case .anyColour:
            couldBeOn = Set(BallColor.coloursInAscendingOrder.compactMap { BallID.colourID($0) }
                .filter { state.ballsOnTable.contains($0) })
        case .colourOfSequence(let colour):
            couldBeOn = BallID.colourID(colour).map { Set([$0]) } ?? []
        }
        if let nominee = state.freeBallNominee, let id = BallID.colourID(nominee) { couldBeOn.insert(id) }
        return couldBeOn
    }

    /// Rule 8(a): the referee's call for the balls the cue ball is touching now, or nil when it is
    /// touching nothing that is or could be on. This is both what goes in the log and what the screen
    /// shows above the status line — a call is meant to be heard, not filed.
    public var touchingBallCall: String? {
        let touching = touchingBallsOn()
        guard !touching.isEmpty else { return nil }
        let names = touching.compactMap { BallID.colour(of: $0)?.rawValue }.joined(separator: " and ")
        return "TOUCHING BALL: the cue ball is touching the \(names)"
    }

    /// The call, and the striker's declaration when the cue ball is touching colours after a Red,
    /// written into the log at the completion of a stroke.
    private func callTouchingBall() {
        guard !state.frameOver, let call = touchingBallCall else { return }
        state.commentary.append(call + ".")
        if case .anyColour = state.ballOn {
            state.commentary.append("Declare which colour you are on.")
        }
    }

    /// True when the only object balls left on the table are the Pink and the Black, the case
    /// Rule 12(b)(ii) excepts from the foul for leaving the free ball as a snookering ball.
    private func onlyPinkAndBlackRemain() -> Bool {
        state.ballsOnTable.subtracting([BallID.cue]) == [BallID.pink, BallID.black]
    }

    /// Which ball not on is doing the snookering, if one of them is (Section 2 Rule 17(b)-(c)).
    ///
    /// `ballOn` is the ball on for the stroke being judged; the nominated free ball, if there is one,
    /// is a ball not on by this point and so is one of the candidates.
    private func effectiveSnookeringBall(cueBall: Vec2, ballOn: BallOn) -> Int? {
        let on: [Int]
        switch ballOn {
        case .red:
            on = (BallID.firstRed...BallID.lastRed).filter { state.ballsOnTable.contains($0) }
        case .anyColour:
            on = state.nominatedColour.flatMap { BallID.colourID($0) }.map { [$0] } ?? []
        case .colourOfSequence(let colour):
            on = BallID.colourID(colour).map { [$0] } ?? []
        }
        guard !on.isEmpty else { return nil }

        // Every ball but the cue ball and the balls that are on, which includes the free ball
        // itself: whether that is the one doing the snookering is the question.
        let blockers = state.ballsOnTable.subtracting(on).subtracting([BallID.cue])

        // Which balls are obstructing which. If any ball on can be hit, there is no snooker.
        var obstructedBy: [Int: Set<Int>] = [:]
        for id in on {
            guard let target = state.ballPositions[id] else { continue }
            var obstructing: Set<Int> = []
            for blocker in blockers {
                guard let position = state.ballPositions[blocker] else { continue }
                // A ball not on obstructs the ball on when it alone cuts off an extreme edge of it,
                // which is Rule 17's own test of the thing asked of one ball.
                if !canBeHitAtBothExtremeEdges(cue: cueBall, target: target, blockers: [position]) {
                    obstructing.insert(blocker)
                }
            }
            guard !obstructing.isEmpty else { return nil }
            obstructedBy[id] = obstructing
        }

        // Rule 17(c): with Red on, if different Reds are obstructed by different balls, no one ball
        // is the effective snookering ball.
        let distinct = Set(obstructedBy.values)
        guard distinct.count == 1, let candidates = distinct.first else { return nil }

        // Rule 17(b)(i): the one nearest the cue ball.
        return candidates.min { a, b in
            let first = state.ballPositions[a] ?? cueBall
            let second = state.ballPositions[b] ?? cueBall
            return first.distance(to: cueBall) < second.distance(to: cueBall)
        }
    }

    /// Section 2 Rule 17: is the cue ball snookered on every ball on?
    ///
    /// The rule's own test, in its own words: the cue ball is **not** snookered if "one or more balls
    /// on can be hit at both extreme edges free of obstruction by any ball not on". So a ball on that is
    /// showing only part of itself — one of its two extreme edges cut off by a ball not on — is
    /// "partially obstructed", and partially obstructed is snookered. Reaching the ball somewhere in the
    /// middle is **not** enough to clear a snooker: that is the wider question Rule 14(c) asks, and
    /// `hasClearPathToBallOn` is the one that asks it.
    public func isSnookered(cueBall: Vec2? = nil) -> Bool {
        let cue = cueBall ?? state.ballPositions[BallID.cue] ?? Table.brownSpot
        let ballsOn = legalFirstContacts()
        guard !ballsOn.isEmpty else { return false }
        let blockers = state.ballsOnTable.subtracting(ballsOn)
        for id in ballsOn {
            guard let target = state.ballPositions[id] else { continue }
            let blockingBalls = blockers.compactMap { state.ballPositions[$0] }
            if canBeHitAtBothExtremeEdges(cue: cue, target: target, blockers: blockingBalls) { return false }
        }
        return true
    }

    /// Rule 17's test of one ball on: can it be hit at **both** of its extreme edges — the two aiming
    /// lines that graze it — with nothing not on in the way of either.
    private func canBeHitAtBothExtremeEdges(cue: Vec2, target: Vec2, blockers: [Vec2]) -> Bool {
        let direction = target - cue
        let distance = direction.length
        guard distance > 1e-6 else { return false }
        let aim = direction / distance
        // A ball on is hit at an extreme edge when the cue ball's centre passes a **diameter** from
        // the ball on's own centre, which is the thinnest contact there is: the two edges are therefore
        // the two ends of the cone of aiming lines that reach the ball at all.
        let halfAngle = asin(min(1, Table.ballDiameter / distance))
        let baseAngle = atan2(aim.y, aim.x)
        for edge in [-halfAngle, halfAngle] {
            let ray = Vec2(cos(baseAngle + edge), sin(baseAngle + edge))
            if isBlocked(ray: ray, from: cue, before: distance, by: blockers) { return false }
        }
        return true
    }

    /// True when **every** straight line from the cue ball to the target ball is blocked, so the ball
    /// cannot be reached at any part of it at all — the wider question Section 3 Rule 14(c) asks, and
    /// not the one Rule 17 asks about a snooker.
    private func isFullyObstructed(cue: Vec2, target: Vec2, blockers: [Vec2]) -> Bool {
        let direction = target - cue
        let distance = direction.length
        guard distance > 1e-6 else { return false }
        let aim = direction / distance
        let halfAngle = asin(min(1, (Table.ballRadius * 2) / distance))
        let baseAngle = atan2(aim.y, aim.x)
        // Sample the aiming cone; the target can be hit if any sample is unobstructed.
        let samples = 41
        for s in 0..<samples {
            let f = Double(s) / Double(samples - 1)
            let angle = baseAngle - halfAngle + 2 * halfAngle * f
            let ray = Vec2(cos(angle), sin(angle))
            if !isBlocked(ray: ray, from: cue, before: distance, by: blockers) { return false }
        }
        return true
    }

    /// Whether a ball is in the way of a ray from the cue ball, before it has gone `distance`.
    ///
    /// Two balls meet when their centres come within a diameter of each other, so a ball whose centre
    /// is that close to the line the cue ball's centre will take is in the way of it.
    private func isBlocked(ray: Vec2, from cue: Vec2, before distance: Double, by blockers: [Vec2]) -> Bool {
        for b in blockers {
            let toBall = b - cue
            let along = toBall.dot(ray)
            guard along > 0, along < distance else { continue }
            if (toBall - ray * along).length < Table.ballDiameter { return true }
        }
        return false
    }

    /// Section 3 Rule 14(c): is there a clear straight path to a ball on?
    /// Whether a ball on could be hit in a straight line from `cue`.
    ///
    /// `positions` is where every ball was: Rule 14 asks whether the ball on could have been hit
    /// from where the stroke was played, and by the time a stroke is assessed the balls have moved,
    /// so a blocker that drifted into the line since must not count.
    public func hasClearPathToBallOn(from cueOverride: Vec2? = nil, positions: [Int: Vec2]? = nil) -> Bool {
        let cue = cueOverride ?? state.ballPositions[BallID.cue] ?? Table.brownSpot
        let layout = positions ?? state.ballPositions
        let ballsOn = legalFirstContacts()
        let blockers = state.ballsOnTable.subtracting(ballsOn).compactMap { layout[$0] }
        for id in ballsOn {
            guard let target = layout[id] else { continue }
            if !isFullyObstructed(cue: cue, target: target, blockers: blockers) { return true }
        }
        return false
    }

    /// Section 3 Rule 14(d): was a **full ball** contact with a ball on available?
    ///
    /// Rule 14(c) is the wider question — whether the ball on could be hit *at all*, thin edge
    /// included — and a failure to hit it then is a foul and a miss. But the warning, and with it the
    /// frame a third failure hands to the opponent, only comes when there was "central, full ball,
    /// contact available": the whole ball to aim at, so that failing to hit it is the striker's doing
    /// and not the snooker's. That is the line through the **middle** of a ball on, with nothing
    /// within a ball's width of it, and it is asked from the position the stroke was played from.
    public func hadFullBallContactAvailable(from cueOverride: Vec2? = nil,
                                            positions: [Int: Vec2]? = nil) -> Bool {
        let cue = cueOverride ?? state.ballPositions[BallID.cue] ?? Table.brownSpot
        let layout = positions ?? state.ballPositions
        let ballsOn = legalFirstContacts()
        let blockers = state.ballsOnTable.subtracting(ballsOn).compactMap { layout[$0] }
        for id in ballsOn {
            guard let target = layout[id] else { continue }
            let direction = target - cue
            let distance = direction.length
            guard distance > 1e-6 else { return true }
            if !isBlocked(ray: direction / distance, from: cue, before: distance, by: blockers) {
                return true
            }
        }
        return false
    }

    // MARK: - Spotting colours (Section 3 Rule 7)

    /// Where a colour must be spotted: its own spot, else the highest value spot
    /// available, else as near as possible to its own spot toward the top cushion.
    public func spottingPosition(for colour: BallColor) -> Vec2 {
        // The colour being spotted is off the table, so it must not block its own spot.
        let spottedID = BallID.colourID(colour)
        let occupied = state.ballsOnTable.compactMap { id -> Vec2? in
            if id == spottedID { return nil }
            return state.ballPositions[id]
        }

        func isFree(_ p: Vec2) -> Bool {
            // A spot is occupied if a ball placed on it would touch another ball, so the test is the
            // diameter itself: 0.01 mm of slack used to let a spot ball be placed a hair inside
            // another, which is an overlap (Rules 7(i), 18).
            !occupied.contains { $0.distance(to: p) <= Table.ballDiameter }
        }

        if let own = Table.spot(for: colour), isFree(own) { return own }

        // Highest value spot available (Rule 7(e)/(f)).
        for (_, spot) in Table.allSpots where isFree(spot) {
            return spot
        }

        // All spots occupied: place as near to its own spot as possible, between that
        // spot and the nearest part of the top cushion (Rule 7(g)).
        let own = Table.spot(for: colour) ?? Table.blackSpot
        var offset = Table.ballDiameter
        while offset < Table.length {
            let candidate = Vec2(min(own.x + offset, Table.length - Table.ballRadius), own.y)
            if isFree(candidate) { return candidate }
            offset += 4
        }

        // Rule 7(h): Pink and Black fall back to the centre longitudinal line.
        var back = Table.ballDiameter
        while back < Table.length {
            let candidate = Vec2(max(own.x - back, Table.ballRadius), own.y)
            if isFree(candidate) { return candidate }
            back += 4
        }
        return own
    }

    // MARK: - Decisions from the previous stroke

    /// Nominates the colour the striker is playing at, which Rule 13 lets them change until the stroke is
    /// played. `announced` is for the nomination the **aim** makes on the striker's behalf: it is not
    /// something they have said out loud, and a cue swung about the table would otherwise put a line in the
    /// log for every colour it crossed. The ball on the screen says what the nomination is either way.
    public func nominateColour(_ colour: BallColor, announced: Bool = true) {
        // A colour that is not on the table cannot be the ball on.
        guard colourIDOnTable(colour) else { return }
        state.nominatedColour = colour
        state.ballOn = .anyColour
        state.pending = nil
        if announced {
            state.commentary.append("\(state.currentPlayerName) nominates \(colour.rawValue).")
        }
    }

    public func nominateFreeBall(_ colour: BallColor) {
        // Rule 12(a)(i): a free ball may be any ball **as** the ball on, so it has to be a colour still
        // on the table and it can never be the ball on itself. Without this the game would take a
        // nomination the referee would refuse — the ball on named as its own free ball, say — and spot
        // a ball that was potted in the ordinary way.
        guard availableFreeBallOptions().contains(colour) else { return }
        state.freeBallNominee = colour
        state.freeBallAvailable = false
        state.pending = state.cueBallInHand ? .placeCueBallInD : nil
        state.commentary.append("Free ball: \(colour.rawValue) nominated as the ball on.")
    }

    public func declineFreeBall() {
        // A free ball is an offer and not an obligation (Rule 12(a)): the striker may play the ball on
        // itself, and is then held to hitting it first like any other stroke.
        state.freeBallNominee = nil
        state.freeBallAvailable = false
        state.pending = state.cueBallInHand ? .placeCueBallInD : nil
        state.commentary.append("No free ball: the ball on is played as it stands.")
    }

    /// Takes the cue ball back in hand.
    ///
    /// The cue ball is in play once it has been struck, and not before (Section 2 Rule 10(a)): a ball
    /// placed in the "D" may be moved about until the stroke is played (Section 3 Rule 5), so putting
    /// it down is not a commitment.
    public func takeCueBallInHand() {
        guard !state.frameOver, state.ballsOnTable.contains(BallID.cue) else { return }
        state.cueBallInHand = true
        state.pending = .placeCueBallInD
    }

    /// Places (or replaces) the cue ball. Returns false if the position is illegal.
    @discardableResult
    public func placeCueBall(at position: Vec2) -> Bool {
        switch state.pending {
        case .placeCueBallInD:
            let p = position
            guard Table.isInsideD(p), p.x >= Table.ballRadius, p.y >= Table.ballRadius,
                  p.y <= Table.width - Table.ballRadius else { return false }
            guard isFreePosition(p, ignoring: BallID.cue) else { return false }
            state.ballPositions[BallID.cue] = p
            state.ballsOnTable.insert(BallID.cue)
            state.cueBallInHand = false
            state.pending = nil
            offerTheFreeBall()
            return true
        case .placeCueBallAnywhere:
            guard position.x >= Table.ballRadius, position.x <= Table.length - Table.ballRadius,
                  position.y >= Table.ballRadius, position.y <= Table.width - Table.ballRadius else { return false }
            guard isFreePosition(position, ignoring: BallID.cue) else { return false }
            state.ballPositions[BallID.cue] = position
            state.ballsOnTable.insert(BallID.cue)
            state.cueBallInHand = false
            state.pending = nil
            offerTheFreeBall()
            return true
        default:
            return false
        }
    }

    public func isFreePosition(_ p: Vec2, ignoring id: Int) -> Bool {
        for (ballID, position) in state.ballPositions where ballID != id && state.ballsOnTable.contains(ballID) {
            if position.distance(to: p) <= Table.ballDiameter { return false }
        }
        return true
    }

    // MARK: - What happens after a foul (Section 3 Rules 10, 12(f), 13 and 14)

    /// The layout as it stood before the last stroke, so the balls can be put back.
    private struct Layout {
        var ballPositions: [Int: Vec2]
        var ballsOnTable: Set<Int>
        var redsRemaining: Int
        var ballOn: BallOn
        var nominatedColour: BallColor?
        var freeBallNominee: BallColor?
        var cueBallInHand: Bool
    }

    private var layoutBeforeStroke: Layout?

    /// Remembers where every ball was, and what was on, before a stroke is played. The balls can be
    /// put back to this when the non-offender asks for the original position (Rules 10(i), 14(b)).
    public func rememberLayout() {
        // A stroke is about to be played: an answer taken back before it is one thing, and an answer
        // after it another — the shot the striker has played settles the question.
        theQuestionJustAnswered = nil
        layoutBeforeStroke = Layout(
            ballPositions: state.ballPositions,
            ballsOnTable: state.ballsOnTable,
            redsRemaining: state.redsRemaining,
            ballOn: state.ballOn,
            nominatedColour: state.nominatedColour,
            freeBallNominee: state.freeBallNominee,
            cueBallInHand: state.cueBallInHand
        )
    }

    /// The non-offender elects to play from where the balls lie.
    public func acceptPositionLeft() {
        // "Play from here" is an answer that can be **taken back** until the next stroke is played: the
        // question and everything the position was when it was asked are kept, so that
        // `chooseSomethingElse()` can put them both back. See the `U` key.
        if let question = state.pending, question.isWhatHappensNext {
            theQuestionJustAnswered = TheQuestion(
                question: question,
                ballPositions: state.ballPositions,
                ballsOnTable: state.ballsOnTable,
                cueBallInHand: state.cueBallInHand,
                ballOn: state.ballOn,
                nominatedColour: state.nominatedColour,
                freeBallNominee: state.freeBallNominee,
                freeBallAvailable: state.freeBallAvailable,
                missCount: state.missCount,
                missWarning: state.missWarning
            )
        }
        state.pending = nil
        // Rule 14(d)(iii): playing from the position left ends a Foul and a Miss sequence.
        state.missCount = 0
        state.missWarning = false
        if state.cueBallInHand {
            // The cue ball is in hand, so whether the striker is snookered depends on **where they put
            // it down**: the free ball is judged once it has been placed, not before. See `placeCueBall`.
            state.pending = .placeCueBallInD
        } else if state.freeBallAvailable, isSnookered() {
            state.pending = .nominateFreeBall(options: availableFreeBallOptions())
        } else {
            state.freeBallAvailable = false
        }
    }

    /// The foul (or miss) question the non-offender has just answered by playing from where the balls
    /// lay, with everything the position was when it was asked. Kept until the next stroke is played, so
    /// that the answer can be taken back.
    private struct TheQuestion {
        var question: PendingDecision
        var ballPositions: [Int: Vec2]
        var ballsOnTable: Set<Int>
        var cueBallInHand: Bool
        var ballOn: BallOn
        var nominatedColour: BallColor?
        var freeBallNominee: BallColor?
        var freeBallAvailable: Bool
        var missCount: Int
        var missWarning: Bool
    }
    private var theQuestionJustAnswered: TheQuestion?

    /// Whether that question can be put back: "Play from here" has been answered, and no stroke has been
    /// played since.
    public var canChooseSomethingElse: Bool { theQuestionJustAnswered != nil }

    /// Takes the answer to the foul (or miss) question back, so the non-offender may choose something
    /// else. Nothing of the game has happened since but their own answer, so everything goes back to what
    /// it was when the question was asked — the balls as they lay, whose turn it is, what is on, whether
    /// the cue ball is in hand, and any free ball on offer. The **penalty stands**: it was the offender's,
    /// and taking an answer back is not the non-offender's to give away.
    public func chooseSomethingElse() {
        guard let takenBack = theQuestionJustAnswered else { return }
        theQuestionJustAnswered = nil
        state.ballPositions = takenBack.ballPositions
        state.ballsOnTable = takenBack.ballsOnTable
        state.cueBallInHand = takenBack.cueBallInHand
        state.ballOn = takenBack.ballOn
        state.nominatedColour = takenBack.nominatedColour
        state.freeBallNominee = takenBack.freeBallNominee
        state.freeBallAvailable = takenBack.freeBallAvailable
        state.missCount = takenBack.missCount
        state.missWarning = takenBack.missWarning
        state.pending = takenBack.question
        state.commentary.append("Playing from here is taken back: what happens next is still to be settled.")
    }

    /// Offers the free ball after the cue ball has been put down, if one is still there to offer and the
    /// striker is snookered from where they placed it (Rule 12). With nothing left to offer the flag is
    /// put away, so a stale free ball cannot come back later.
    private func offerTheFreeBall() {
        guard state.freeBallAvailable else { return }
        if isSnookered() {
            state.pending = .nominateFreeBall(options: availableFreeBallOptions())
        } else {
            state.freeBallAvailable = false
        }
    }

    /// The non-offender asks the offender to play again from the position left (Rules 10(h), 13).
    ///
    /// Rule 13 lets the offender change their mind about the stroke and the ball on, but it does not
    /// hand them back the ball on they were on. A request to play again is a **new turn**, so Rule
    /// 3(g) puts the offender on a Red while any Red is left, exactly as it puts the non-offender on
    /// a Red when they play from here. Only the Foul and a Miss replacement (Rule 14(b),
    /// `requestOriginalPosition()`) restores the ball on the offender had, because there the balls
    /// themselves go back and Rule 14(b)(i)-(iii) sets the ball on from the position.
    public func askOffenderToPlayAgain() {
        state.pending = nil
        // The question is answered and done with: there is nothing to take back.
        theQuestionJustAnswered = nil
        state.currentPlayer = 1 - state.currentPlayer
        state.breakScore = 0
        // Rule 12(f): asking the offender to play again voids the free ball option.
        state.freeBallAvailable = false
        state.freeBallNominee = nil
        // Rule 14(d)(iii): so does it end a Foul and a Miss sequence.
        state.missCount = 0
        state.missWarning = false
        // Rule 3(g): the offender's turn begins on a Red while any Red is left, and on the next
        // colour in the sequence once the Reds are gone. Rule 13(a)(ii) does not override that — it
        // only gives them a free hand at a ball on that is already a colour of their own choice,
        // which never arises at the start of a turn.
        resetBallOnForIncomingTurn()
        if state.cueBallInHand {
            state.pending = .placeCueBallInD
        }
        state.commentary.append("\(state.currentPlayerName) asked the offender to play from here.")
    }

    /// The non-offender asks for the balls to be put back and the offender to play again from the
    /// original position (Rules 10(i) and 14(b)).
    ///
    /// The penalty already awarded stands, the ball on goes back to whatever it was, and the free
    /// ball option is void (Rule 12(f)). A Foul and a Miss sequence carries on from here, so a
    /// further failure from the same position is a second failure (Rule 14(d)).
    public func requestOriginalPosition() {
        guard let layout = layoutBeforeStroke else { return }
        // The question is answered and done with: there is nothing to take back.
        theQuestionJustAnswered = nil
        state.ballPositions = layout.ballPositions
        state.ballsOnTable = layout.ballsOnTable
        state.redsRemaining = layout.redsRemaining
        state.ballOn = layout.ballOn
        state.nominatedColour = layout.nominatedColour
        state.freeBallNominee = layout.freeBallNominee
        state.cueBallInHand = layout.cueBallInHand
        state.freeBallAvailable = false
        state.pending = nil
        state.currentPlayer = 1 - state.currentPlayer
        state.breakScore = 0

        if case .anyColour = state.ballOn {
            // Rule 10(i)(iii) and 14(b)(iii): the ball on is a colour of the striker's choice, so
            // they choose again.
            state.nominatedColour = nil
            state.pending = .nominateColour(options: BallColor.coloursInAscendingOrder.filter { colourIDOnTable($0) })
        } else if state.cueBallInHand {
            state.pending = .placeCueBallInD
        }
        state.commentary.append("The balls have been replaced; \(state.currentPlayerName) plays again from the original position.")
    }

    public func availableFreeBallOptions() -> [BallColor] {
        var options = state.ballsOnTable.compactMap { BallID.colour(of: $0) }.filter { $0.isColour }
        if case .red = state.ballOn {
            // When Red is on, a free ball can be any colour (it acquires the value of a Red).
            options = options.sorted { $0.value < $1.value }
        } else {
            options.removeAll { $0 == state.ballOnColour }
        }
        return options
    }

    // MARK: - Stroke adjudication

    /// Applies the outcome of a stroke and returns what happened.
    @discardableResult
    public func applyStroke(_ report: StrokeReport, cueBallPosition: Vec2) -> TurnResult {
        let start = state.ballPositions[BallID.cue] ?? cueBallPosition
        return applyStroke(report, cueBallStart: start, cueBallEnd: cueBallPosition)
    }

    /// Applies a stroke. `cueBallStart` is where the cue ball was played from and
    /// `cueBallEnd` is where it finished. The distinction matters for the Foul and a
    /// Miss assessment, which Rule 14 makes from the position the stroke was played from.
    @discardableResult
    public func applyStroke(_ report: StrokeReport, cueBallStart: Vec2, cueBallEnd: Vec2) -> TurnResult {
        var result = TurnResult()
        state.missWarningForNextOriginalPosition = false

        // Record where the cue ball finished (used when a stroke must be replayed).
        state.ballPositions[BallID.cue] = cueBallEnd

        let ballsOn = legalFirstContacts()
        let foulBase = max(4, ballOnValue())

        // Section 3 Rule 8. The touching call is made when the balls come to rest, so it is the layout
        // the stroke was played from that decides whether the cue ball was touching a ball on — and
        // whether the striker moved it, which is a push stroke.
        let touchedAtStart = touchingBallsOn(cueBall: cueBallStart,
                                             positions: layoutBeforeStroke?.ballPositions)
        let touchedThatMoved = touchedAtStart.filter { report.movedBalls.contains($0) }
        // Rule 8(c). The cue ball is touching a ball that is on, or that could be on, and the striker
        // has played away from it without moving it — moving it is a push stroke (Rule 8(b)). That
        // contact stands for the stroke's contact with a ball on, so the cue ball need hit nothing of
        // its own: a ball resting against a Red, with Red on, **may be played straight into a colour**,
        // and neither the wrong-ball foul nor the miss is called for it (8(c)(i)-(ii)). Where the
        // touching ball only could be on, the contact is good while the cue ball then runs into a ball
        // that could be on too (8(c)(iii)).
        let touching = Set(touchedAtStart)
        let couldBeOn = ballsThatCouldBeOn()
        let playedAwayFromATouchingBallOn: Bool
        if !touchedThatMoved.isEmpty {
            playedAwayFromATouchingBallOn = false
        } else if !touching.isDisjoint(with: ballsOn) {
            playedAwayFromATouchingBallOn = true
        } else {
            playedAwayFromATouchingBallOn = !touching.isDisjoint(with: couldBeOn)
                && !report.firstContacts.isEmpty
                && report.firstContacts.allSatisfy { couldBeOn.contains($0) }
        }

        // --- 1. Potted balls that were not on, and balls hit that were not on.
        var foul: Foul?

        if report.cueBallPotted {
            foul = Foul(reason: "cue ball pocketed", penalty: foulBase)
        }

        if foul == nil, let moved = touchedThatMoved.first {
            // Rule 8(b): the cue ball must be played away from a ball it is touching without moving it.
            // Moving it is a push stroke (Rule 11(b)(v)), worth the higher of the ball on and the ball
            // concerned.
            let value = BallID.colour(of: moved)?.value ?? 0
            foul = Foul(reason: "push stroke: the ball the cue ball was touching moved",
                        penalty: max(foulBase, value))
        }

        if foul == nil, report.firstContacts.isEmpty, !playedAwayFromATouchingBallOn {
            // Rule 8(c): the contact with the touching ball was the ball on, so a stroke that then
            // runs into nothing is no foul — only a stroke that was never in contact with anything on
            // has failed to contact a ball on.
            foul = Foul(reason: "cue ball failed to contact a ball on", penalty: foulBase,
                        missedBallOn: true)
        }

        if foul == nil, let first = report.firstContacts.first {
            let hitSimultaneous = report.firstContacts.count > 1
            if hitSimultaneous {
                let values = report.firstContacts.map { BallID.colour(of: $0)?.value ?? 0 }
                let allReds = report.firstContacts.allSatisfy { BallID.colour(of: $0) == .red }
                let freeBallAndOn = state.freeBallNominee != nil && report.firstContacts.contains { ballsOn.contains($0) }
                // Rule 6: two Reds may be struck simultaneously when Red is the ball on.
                if !(allReds && state.ballOn == .red) && !freeBallAndOn {
                    // Rule 11(c): value of the ball on or higher value of the two balls concerned.
                    let penalty = max(foulBase, values.max() ?? 0)
                    foul = Foul(reason: "cue ball struck two balls simultaneously", penalty: penalty)
                }
            }
            if foul == nil, !playedAwayFromATouchingBallOn, !ballsOn.contains(first) {
                let hitValue = BallID.colour(of: first)?.value ?? 0
                foul = Foul(reason: "cue ball first hit a ball not on", penalty: max(foulBase, hitValue))
            }
        }

        // Balls pocketed that are not on (Rule 11(b)(iii)).
        if foul == nil {
            for id in report.potted where !isBallOnForPotting(id) {
                let value = BallID.colour(of: id)?.value ?? 0
                foul = Foul(reason: "pocketed a ball not on", penalty: max(foulBase, value))
                break
            }
        }

        // Rule 11(b)(x): causing a ball to be forced off the table — the value of the ball on or the
        // ball concerned, whichever is higher. Section 2 Rule 14 makes that a ball which comes to
        // rest other than on the playing area or in a pocket. Rule 10(g) keeps the highest of the
        // stroke's penalties when there is more than one foul.
        if !report.ballsForcedOffTable.isEmpty {
            let concerned = report.ballsForcedOffTable.map { BallID.colour(of: $0)?.value ?? 0 }.max() ?? 0
            let forcedOff = Foul(reason: "forced a ball off the table", penalty: max(foulBase, concerned))
            if foul == nil || forcedOff.penalty > (foul?.penalty ?? 0) {
                foul = forcedOff
            }
        }

        // Rule 11(a)(x): playing a jump shot — the cue ball passing over any part of an object ball,
        // which Rule 20 makes a jump shot unless it had already hit one. It is a foul worth the value
        // of the ball on, and it is the *jump* that is the foul, not what the ball then hits: a ball
        // scooped over an obstruction to reach a ball on is a foul, not a clever shot.
        if !report.jumpedOver.isEmpty {
            let jumped = Foul(reason: "playing a jump shot", penalty: foulBase)
            if foul == nil || jumped.penalty > (foul?.penalty ?? 0) {
                foul = jumped
            }
        }

        // Free ball nominated but not hit first (Rule 12(b)(i)).
        if foul == nil, let nominee = state.freeBallNominee,
           let nomineeID = BallID.colourID(nominee),
           let first = report.firstContacts.first {
            let hitNominee = first == nomineeID
            let hitOnSimultaneously = report.firstContacts.contains { ballsOn.contains($0) }
            if !hitNominee && !hitOnSimultaneously {
                foul = Foul(reason: "cue ball did not hit the nominated free ball first",
                            penalty: max(foulBase, nominee.value))
            }
        }

        // Rule 12(b)(ii), with Rule 11(a)(viii): a free ball is a ball on for the stroke, and it must
        // not be left doing the snookering — the striker cannot hide behind the ball they nominated.
        // Having potted nothing and left the cue ball snookered by it is a foul worth the value of the
        // ball on, except when the Pink and Black are the only object balls left on the table.
        if foul == nil, let nominee = state.freeBallNominee,
           report.potted.allSatisfy({ $0 == BallID.cue }),
           !onlyPinkAndBlackRemain(),
           effectiveSnookeringBall(cueBall: cueBallEnd, ballOn: state.ballOn) == BallID.colourID(nominee) {
            foul = Foul(reason: "left the cue ball snookered by the nominated free ball",
                        penalty: foulBase)
        }

        // --- 1d. The cue itself. Contacting a ball in play with the player's equipment is a foul
        // (Rule 11(b)(vi)) — the tip of the stick or the side of it, on anything but the stroke's own
        // contact with the cue ball — and striking the cue ball a second time is the double hit of
        // Rule 11(a)(ii). Whichever it is, it is worth the ball on or the ball concerned, whichever is
        // higher, and it stands with whatever else the stroke did: the higher penalty is the one
        // called, and the miss, if the stroke missed as well, comes with it.
        if let touched = report.ballsTheCueTouched.first {
            let struckTheCueBallAgain = touched == BallID.cue
            let value = BallID.colour(of: touched)?.value ?? 0
            // A second strike of the cue ball is timed: the referee's call says how long after the
            // first contact it came, which is what tells the player whether the cue really went back
            // to it or was simply still against it as it left.
            let seconds = report.secondsUntilTheCueBallWasStruckAgain
            let secondStrike = seconds.map { "the cue struck the cue ball a second time (\(Int(($0 * 1000).rounded())) ms after the first contact)" }
                ?? "the cue struck the cue ball a second time"
            let cueFoul = Foul(reason: struckTheCueBallAgain ? secondStrike : "the cue touched a ball in play",
                               penalty: struckTheCueBallAgain ? foulBase : max(foulBase, value),
                               missedBallOn: foul?.missedBallOn ?? false)
            if let existing = foul, existing.penalty > cueFoul.penalty {
                foul = Foul(reason: existing.reason, penalty: existing.penalty,
                            missedBallOn: existing.missedBallOn || cueFoul.missedBallOn)
            } else {
                foul = cueFoul
            }
        }

        // --- 2. Resolve the stroke.
        let pottedReds = report.potted.filter { BallID.colour(of: $0) == .red }
        let pottedColours = report.potted.filter { BallID.colour(of: $0)?.isColour == true }
        let isColoursPhase: Bool
        if case .colourOfSequence = state.ballOn { isColoursPhase = true } else { isColoursPhase = false }

        // Rule 11(d)(v)-(vi): once a Red has been potted the striker has to declare which colour is
        // on, and the game asks them to. Striking without having declared one is a seven point foul
        // and, since the ball on was never chosen, a Foul and a Miss as well.
        if case .anyColour = state.ballOn, state.nominatedColour == nil {
            let undeclared = Foul(reason: "no colour was nominated", penalty: 7, missedBallOn: true)
            if let existing = foul, existing.penalty > undeclared.penalty {
                foul = Foul(reason: existing.reason, penalty: existing.penalty, missedBallOn: true)
            } else {
                foul = undeclared
            }
        }

        // Rule 14(c): a stroke that fails to first hit a ball on — hitting nothing at all, or
        // hitting a ball that is not on — is a Foul and a Miss when there was a ball on to be hit.
        // Marking it here is what gives the non-offender the three choices of Rule 14(b): hitting
        // the wrong colour is as much a miss as hitting nothing.
        if var call = foul, !playedAwayFromATouchingBallOn,
           !report.firstContacts.contains(where: { ballsOn.contains($0) }) {
            call.missedBallOn = true
            foul = call
        }

        if let foul {
            // Section 3 Rule 4(a): with the Black the only object ball left on the table the first
            // foul ends the frame. Read before the balls come off below, because the foul may itself
            // have potted the Black or put it off the table.
            let blackWasTheOnlyObjectBall = theBlackIsTheOnlyObjectBallLeft()

            // Remove any potted balls, and any forced off the table: nothing scores in a foul stroke
            // (Rule 10(e)), but colours are re-spotted (Rule 7) and Reds stay off (Rule 3(i)), so
            // the count of Reds still on the table comes down with them. A ball forced off the table
            // is treated the same way, and the cue ball comes back in-hand (Section 2 Rule 9(a)(iii)).
            let removed = report.potted + report.ballsForcedOffTable
            for id in removed where id != BallID.cue {
                if id >= BallID.firstRed, id <= BallID.lastRed, state.ballsOnTable.contains(id) {
                    state.redsRemaining = max(0, state.redsRemaining - 1)
                }
                state.ballsOnTable.remove(id)
            }
            if report.cueBallPotted || report.ballsForcedOffTable.contains(BallID.cue) {
                // Rule 10(f): if the cue ball is not in play the next stroke is played in-hand.
                state.ballsOnTable.remove(BallID.cue)
                state.cueBallInHand = true
            }
            state.scores[1 - state.currentPlayer] += foul.penalty
            // A break ended by a foul is still a break: what it came to is said before the score is put
            // away. See `sayTheBreakIsOver`, which says it for the breaks that end without a foul too.
            sayTheBreakIsOver()
            state.breakScore = 0
            result.foul = foul
            state.commentary.append("FOUL by \(state.currentPlayerName): \(foul.reason). \(foul.penalty) points to \(state.players[1 - state.currentPlayer].name).")

            // Colours that were on the table but potted in a foul are spotted.
            var respotted: [BallColor] = []
            for id in removed where id != BallID.cue {
                if let colour = BallID.colour(of: id), colour.isColour {
                    respot(colour)
                    respotted.append(colour)
                }
            }
            if !respotted.isEmpty {
                state.ballPositions[BallID.cue] = cueBallEnd
            }

            // Section 3 Rule 4(a): with the Black as the only object ball left, the first foul ends
            // the frame as well as the first pot — unless the penalty has left the scores level,
            // which gives the re-spotted Black (Rule 4(b)). The ball the foul was on has to be the
            // Black for this to be reached: a foul with a colour still to come leaves the frame alive.
            if blackWasTheOnlyObjectBall {
                result.penalty = foul.penalty
                settleTheFrameWithTheBlackGone()
                callTouchingBall()
                return result
            }

            let missedBallOn = foul.missedBallOn
            // Rule 14(a)(ii) spares a striker who could not have hit the ball on — one who was
            // snookered — from a miss. The game does not ask that question: a stroke that fails to
            // first hit a ball on is called a foul **and a miss** whether the striker was snookered or
            // not. It is a simplification, and it is the one the player is told about here. A miss
            // still needs a ball on to have been missed, so a stroke with none on the table is no miss.
            let missCalled = missedBallOn && !ballsOn.isEmpty
            // Rule 14(d): the warning, and the frame a third failure hands over, only come when the
            // striker had the ball on to hit — "central, full ball, contact available" — from the
            // position the stroke was played from. Failing to escape a snooker is a foul and a miss
            // like any other, but it cannot cost the frame: three failures to get out of a snooker do
            // not lose a match. It is the same question whether the striker could reach any part of
            // the ball on at all (14(c), `hasClearPathToBallOn`), asked about the middle of the ball
            // rather than its edge.
            let fullBallWasAvailable = hadFullBallContactAvailable(
                from: cueBallStart, positions: layoutBeforeStroke?.ballPositions)

            endBreakAndPassTurn()
            state.freeBallAvailable = true
            // Rule 3(g): a turn begins on a Red while any Red is left on the table, whatever the
            // offender was on. That holds for whoever plays next: the non-offender playing from
            // here, and equally the offender asked to play again (`askOffenderToPlayAgain()`, Rule
            // 13). Only the Foul and a Miss replacement (Rule 14(b), `requestOriginalPosition()`)
            // restores the ball on the offender had, because there the balls go back.
            resetBallOnForIncomingTurn()

            if missCalled {
                var decision = MissDecision(foul: foul, warningJustIssued: false, frameAwarded: false,
                                            canRequestOriginalPosition: true)
                if fullBallWasAvailable {
                    state.missCount += 1
                    if state.missCount >= 3 {
                        let winner = state.currentPlayer   // the non-offender plays on
                        state.frameOver = true
                        state.winner = winner
                        decision.frameAwarded = true
                        state.commentary.append("Third consecutive failure: frame awarded to \(state.players[winner].name).")
                    } else if state.missCount == 2 {
                        decision.warningJustIssued = true
                        state.missWarning = true
                        state.commentary.append("FOUL AND A MISS. \(state.currentPlayerName) is warned: a further failure will lose the frame.")
                    } else {
                        state.commentary.append("FOUL AND A MISS called.")
                    }
                } else {
                    // The ball on was not there to be hit full ball — the striker was snookered, or had
                    // no more than a thin edge of it. The failure is a foul and a miss, and no more: no
                    // warning, no count, and no frame from failing to escape a snooker three times.
                    // A count cannot be running when this happens — it only ever runs from a position
                    // that had the full ball available — so there is nothing here to put back.
                    state.commentary.append("FOUL AND A MISS called: the ball on could not be hit full ball, so this failure cannot cost the frame.")
                }
                state.pending = .afterMiss(decision)
                result.missCalled = true
                result.missWarning = decision.warningJustIssued
            } else {
                // An ordinary foul, committed during the stroke: the balls stay where they lie, so
                // the non-offender's choices are to play from there or to ask the offender to play
                // again from there. Putting the balls back is only allowed in the cases the rules
                // list (Rule 12(f)) — a foul before striking, a Foul and a Miss, or a foul after
                // the balls have been replaced.
                state.pending = .afterFoul(FoulDecision(foul: foul, freeBallAvailable: true,
                                                       canRequestOriginalPosition: false))
            }
            result.penalty = foul.penalty
            callTouchingBall()
            return result
        }

        // --- 3. No foul: score the pots.
        state.missCount = 0
        var scored = 0
        var pottedOnValue = 0

        for id in report.potted where id != BallID.cue {
            let value = BallID.colour(of: id)?.value ?? 0
            if id <= BallID.lastRed, id >= BallID.firstRed {
                scored += 1
                pottedOnValue += 1
                state.ballsOnTable.remove(id)
                state.redsRemaining -= 1
            } else if let colour = BallID.colour(of: id), colour.isColour {
                let freeBallAsRed = state.freeBallNominee == colour && state.ballOn == .red
                if freeBallAsRed {
                    // Free ball potted while Red is on: value of the ball on (a Red) is scored,
                    // and the free ball is spotted (Rule 12(c)).
                    scored += 1
                    pottedOnValue += 1
                    respot(colour)
                } else if state.freeBallNominee == colour {
                    // The nominated free ball is potted while the ball on is a colour. The free ball
                    // is spotted, and the value of the ball on is scored — unless the ball on itself
                    // was potted in the same stroke, when only that one is scored (Rule 12(c), 12(e)).
                    // Either way the ball on, if it is still on the table, is on for the next stroke.
                    let ballOnPotted = state.ballOnColour
                        .flatMap { BallID.colourID($0) }
                        .map { report.potted.contains($0) } ?? false
                    if !ballOnPotted {
                        let onValue = ballOnValue()
                        scored += onValue
                        pottedOnValue += onValue
                    }
                    respot(colour)
                } else if isColoursPhase {
                    if case .colourOfSequence(let on) = state.ballOn, on == colour {
                        scored += value
                        pottedOnValue += value
                        state.ballsOnTable.remove(id)
                    } else {
                        // Should not happen: guarded by the foul check above.
                        respot(colour)
                    }
                } else {
                    // Colour potted after a Red: scored, then spotted (Rule 3(h)(i)).
                    scored += value
                    pottedOnValue += value
                    respot(colour)
                }
            }
        }

        if report.cueBallPotted {
            state.ballsOnTable.remove(BallID.cue)
        }

        state.scores[state.currentPlayer] += scored
        state.breakScore += scored
        state.players[state.currentPlayer].highestBreak = max(state.players[state.currentPlayer].highestBreak, state.breakScore)
        if scored > 0 {
            result.pointsScored = scored
            // **A stroke that scores says nothing.** A break is a run of scores, and the run is read as it
            // is made from the readout on the screen — the break and both scores are up there and move as
            // the balls go in — so the log keeps the one line worth keeping: what the break *came to*,
            // said when it is over and only if it was worth anything. See `sayTheBreakIsOver`. A line for
            // every ball potted is a log with the frame lost in it.
        }

        // --- 4. Work out the next ball on.
        let freeBallPottedAsRed = state.freeBallNominee != nil && state.ballOn == .red && !pottedColours.isEmpty
        state.freeBallNominee = nil
        state.nominatedColour = nil

        let pottedRedThisStroke = !pottedReds.isEmpty || freeBallPottedAsRed
        if pottedRedThisStroke {
            // Rule 3(h)(i)-(ii): the next ball on is a colour of the striker's choice,
            // including after the final Red of the frame has been potted.
            state.ballOn = .anyColour
            state.pending = .nominateColour(options: BallColor.coloursInAscendingOrder.filter { colourIDOnTable($0) })
        } else if pottedOnValue > 0 {
            // A colour was potted: back to a Red while any remain, otherwise the next
            // colour in the ascending sequence (Rule 3(h)(iii)).
            if state.redsRemaining > 0 {
                state.ballOn = .red
            } else {
                advanceColourSequence()
            }
        } else {
            // Nothing was potted. The next stroke is the same ball on — except that a colour played
            // after the last Red ends the Reds-and-colours alternation whether or not it went in: the
            // colours are on now in ascending order (Rule 3(h)(ii)-(iii)), so a ball on of the
            // striker's own choice is not carried over to the next player.
            if state.redsRemaining > 0 {
                state.ballOn = .red
            } else if case .anyColour = state.ballOn {
                advanceColourSequence()
            }
            passTurn()
        }

        // --- 5. End of frame conditions.
        checkFrameEnd()
        callTouchingBall()
        return result
    }

    private func colourIDOnTable(_ colour: BallColor) -> Bool {
        guard let id = BallID.colourID(colour) else { return false }
        return state.ballsOnTable.contains(id)
    }

    private func isBallOnForPotting(_ id: Int) -> Bool {
        guard let colour = BallID.colour(of: id) else { return false }
        if let nominee = state.freeBallNominee, nominee == colour { return true }
        switch state.ballOn {
        case .red:
            return colour == .red
        case .anyColour:
            // A colour of the striker's own choice: the one they nominated is the ball on, and no
            // other. Potting a colour they did not nominate is potting a ball not on (Rule 11(b)(iii)),
            // which is a foul — and nothing scores in a foul stroke (Rule 10(e)), not even the colour
            // that was on. Only if they never nominated one at all does any colour count as on, since
            // the stroke is a seven point foul for that in any case (Rule 11(d)(vi)).
            if let nominated = state.nominatedColour { return colour == nominated }
            return colour.isColour
        case .colourOfSequence(let on):
            return colour == on
        }
    }

    private func respot(_ colour: BallColor) {
        guard let id = BallID.colourID(colour) else { return }
        let position = spottingPosition(for: colour)
        state.ballPositions[id] = position
        state.ballsOnTable.insert(id)
    }

    private func advanceColourSequence() {
        let remaining = BallColor.coloursInAscendingOrder.filter { colourIDOnTable($0) }
        if let next = remaining.first {
            state.ballOn = .colourOfSequence(next)
            state.pending = nil
        } else {
            state.ballOn = .colourOfSequence(.black)
            state.pending = nil
        }
    }

    /// The ball on for a turn that begins after a foul (Rules 3(g) and 3(h)(iii)).
    ///
    /// A turn starts on a Red for as long as a Red is on the table, so an incoming player who
    /// takes over after a foul while the offender was playing for a colour is on a Red, not on a
    /// colour. Once the Reds are gone the colours are on in ascending order, which is the lowest
    /// colour left. The offender asked to play again gets the same turn, so `askOffenderToPlayAgain()`
    /// calls this too; only `requestOriginalPosition()` (Rule 14(b)) puts the offender's own ball on
    /// back, from the remembered layout.
    private func resetBallOnForIncomingTurn() {
        state.nominatedColour = nil
        if state.redsRemaining > 0 {
            state.ballOn = .red
        } else {
            advanceColourSequence()
        }
    }

    private func passTurn() {
        state.ballOn = state.redsRemaining > 0 ? .red : state.ballOn
        // The break is over — a stroke that potted nothing is what ends one — so what it came to is said
        // here, before the turn and the break go: see `sayTheBreakIsOver`.
        sayTheBreakIsOver()
        state.currentPlayer = 1 - state.currentPlayer
        state.breakScore = 0
        state.missCount = 0
        state.cueBallInHand = state.cueBallInHand || !state.ballsOnTable.contains(BallID.cue)
        if state.cueBallInHand, case .afterFoul = state.pending {} else if state.cueBallInHand {
            state.pending = .placeCueBallInD
        }
        state.commentary.append("\(state.currentPlayerName) to play.")
    }

    private func endBreakAndPassTurn() {
        // The break is over: what it came to is said here, once, and only when it was worth anything.
        // The name is the striker's, so it is read before the turn changes hands.
        sayTheBreakIsOver()
        state.currentPlayer = 1 - state.currentPlayer
        state.breakScore = 0
        if !state.ballsOnTable.contains(BallID.cue) {
            state.cueBallInHand = true
        }
        state.commentary.append("\(state.currentPlayerName) to play.")
    }

    /// Says what the break came to, once, when it is over — and only when it came to anything.
    ///
    /// This is the one line a break leaves in the log. Nothing is said of the strokes that made it: a
    /// player watches the break build on the readout, which carries it as it goes, and reads the log for
    /// what happened rather than for what they have just watched. A break ends either by a stroke that
    /// potted nothing (`passTurn`) or by a foul (`endBreakAndPassTurn`), and both come through here, so
    /// no break is said twice and none is missed. The name is read before the turn changes hands.
    private func sayTheBreakIsOver() {
        guard state.breakScore > 0 else { return }
        state.commentary.append("\(state.currentPlayerName)'s break ends on \(state.breakScore).")
    }

    private func checkFrameEnd() {
        let objectBalls = state.ballsOnTable.filter { $0 != BallID.cue }
        if objectBalls.isEmpty {
            // The Black has gone: the frame is decided by the scores, or, if they are level, the
            // Black is spotted and played for again (Section 3 Rule 4(a)-(b)).
            settleTheFrameWithTheBlackGone()
            return
        }
        // With only the Black left and more than seven points between the scores the frame belongs to
        // the player who is ahead (Section 2 Rule 1(b)-(c)) — but it is not taken off the table here.
        // See `claimOfTheFrame`: the game offers it as a claim rather than an award, so the players
        // play on until whoever is ahead takes it, or until the first pot or foul ends the frame
        // (Section 3 Rule 4(a)) with the scores deciding it.
    }

    /// Whether no more than the Black is left to play at.
    private func theBlackIsTheOnlyObjectBallLeft() -> Bool {
        let objectBalls = state.ballsOnTable.filter { $0 != BallID.cue }
        return objectBalls.count == 1 && objectBalls.contains(BallID.black)
    }

    /// The Black has been potted, so the frame is over — unless that has left the scores level, which
    /// the rules answer with the re-spotted Black (Section 3 Rule 4(a)-(b)).
    private func settleTheFrameWithTheBlackGone() {
        if !state.respottedBlack, state.scores[0] == state.scores[1] {
            respotTheBlack()
            return
        }
        state.frameOver = true
        state.winner = state.scores[0] == state.scores[1] ? nil : (state.scores[0] > state.scores[1] ? 0 : 1)
        if let winner = state.winner {
            state.commentary.append("Frame over: \(state.players[winner].name) wins \(state.scores[0])-\(state.scores[1]).")
        } else {
            state.commentary.append("Frame over: level at \(state.scores[0])-\(state.scores[1]).")
        }
    }

    /// Section 3 Rule 4(b), the re-spotted Black: the Black goes back on its spot, the players draw
    /// lots for the choice of playing next, and that player plays from in-hand. The first pot or
    /// infringement after that ends the frame.
    private func respotTheBlack() {
        respot(.black)
        state.respottedBlack = true
        state.ballsOnTable.remove(BallID.cue)
        state.cueBallInHand = true
        state.pending = .placeCueBallInD
        state.ballOn = .colourOfSequence(.black)
        state.nominatedColour = nil
        state.freeBallAvailable = false
        state.freeBallNominee = nil
        state.breakScore = 0
        state.missCount = 0
        state.missWarning = false
        state.missWarningForNextOriginalPosition = false
        state.currentPlayer = decideTheDraw() % state.players.count
        state.commentary.append("Scores level at \(state.scores[0])-\(state.scores[1]): the Black is re-spotted. \(state.currentPlayerName) wins the draw and plays from in-hand.")
    }

    /// The player the frame is there to claim, if any: with no more than the Black left on the table
    /// and more than seven points between the scores, it belongs to whoever is ahead (Section 2
    /// Rule 1). The rules make the striker's a **claim** (Rule 1(b)) and the non-striker's an
    /// **award** (Rule 1(c)): the striker is offered theirs as a button and is not made to take it, while
    /// the non-striker's is theirs and is taken the moment the position is noticed — see
    /// `awardTheFrameToTheNonStriker`.
    public var claimOfTheFrame: Int? {
        guard !state.frameOver else { return nil }
        let objectBalls = state.ballsOnTable.filter { $0 != BallID.cue }
        guard objectBalls.count == 1, objectBalls.contains(BallID.black) else { return nil }
        for player in [state.currentPlayer, 1 - state.currentPlayer]
        where state.scores[player] - state.scores[1 - player] > 7 {
            return player
        }
        return nil
    }

    /// True when the frame is the striker's to claim (Section 2 Rule 1(b)).
    public var strikerMayClaimTheFrame: Bool { claimOfTheFrame == state.currentPlayer }

    /// Section 2 Rule 1(c), the **award**: with no more than the Black left and the **non-striker** more
    /// than seven points ahead, the striker cannot come back without snookers, and the frame is the
    /// non-striker's — it is not theirs to claim, it is theirs. True when there was such a frame to award.
    @discardableResult
    public func awardTheFrameToTheNonStriker() -> Bool {
        guard let ahead = claimOfTheFrame, ahead != state.currentPlayer else { return false }
        state.frameOver = true
        state.winner = ahead
        state.commentary.append("\(state.players[state.currentPlayer].name) needs snookers: the frame is awarded to \(state.players[ahead].name), more than seven ahead with only the Black left.")
        return true
    }

    /// Claims the frame for the player it is there for (Section 2 Rule 1) — which, by the time anyone can
    /// ask, is the striker and only the striker: the non-striker's own case is awarded rather than claimed.
    /// Refused when it is not there to claim: the Black is not the only ball left, or nobody is more than
    /// seven ahead.
    @discardableResult
    public func claimTheFrame() -> Bool {
        guard let claimant = claimOfTheFrame else { return false }
        state.frameOver = true
        state.winner = claimant
        state.commentary.append("\(state.players[claimant].name) claims the frame, more than seven ahead with only the Black left.")
        return true
    }

    // MARK: - Player actions

    public func concede(player: Int) {
        state.frameOver = true
        state.winner = 1 - player
        state.commentary.append("\(state.players[player].name) concedes the frame.")
    }

    /// Stalemate: the referee offers a re-rack (Section 3 Rule 17).
    public func reRack() {
        let names = state.players.map(\.name)
        let starter = state.currentPlayer
        state = GameState(playerNames: names, redCount: state.initialRedCount)
        state.currentPlayer = starter
        state.cueBallInHand = true
        state.pending = .placeCueBallInD
        state.commentary.append("Stalemate: the frame is re-racked. All scores are nullified.")
    }

    public func remainingPoints() -> Int {
        var points = 0
        let reds = state.redsRemaining
        if reds > 0 {
            points += reds * 8           // each Red plus a Black
        }
        for colour in BallColor.coloursInAscendingOrder where colourIDOnTable(colour) {
            points += colour.value
        }
        return points
    }

    /// Direct state access, used for set-up (and by tests) to construct a known
    /// position without replaying a whole frame.
    public func withState(_ transform: (inout GameState) -> Void) {
        transform(&state)
    }
}

/// Mutable frame state.
public struct GameState: Sendable {
    public var players: [Player]
    public var currentPlayer: Int = 0
    public var breakScore: Int = 0
    public var ballPositions: [Int: Vec2]
    public var ballsOnTable: Set<Int>
    public var redsRemaining: Int
    public let initialRedCount: Int
    public var ballOn: BallOn = .red
    public var nominatedColour: BallColor?
    public var cueBallInHand: Bool = true
    public var freeBallAvailable: Bool = false
    public var freeBallNominee: BallColor?
    public var missCount: Int = 0
    public var missWarning: Bool = false
    public var missWarningForNextOriginalPosition: Bool = false
    public var pending: PendingDecision?
    public var frameOver: Bool = false
    public var winner: Int?
    /// True once the Black has been re-spotted (Section 3 Rule 4(b)): the next pot or infringement
    /// ends the frame, whatever the scores are then.
    public var respottedBlack: Bool = false
    public var commentary: [String] = []

    public init(playerNames: [String], redCount: Int) {
        var players = playerNames.map { Player(name: $0) }
        if players.isEmpty { players = [Player(name: "Prof. Snoo"), Player(name: "Dr. Ker")] }
        if players.count == 1 { players.append(Player(name: "Dr. Ker")) }
        self.players = players
        self.initialRedCount = redCount
        self.redsRemaining = redCount
        self.ballPositions = SnookerGame.initialPositions(redCount: redCount)
        var onTable = Set<Int>([BallID.cue])
        for i in 0..<redCount { onTable.insert(BallID.firstRed + i) }
        for colour in BallColor.coloursInAscendingOrder {
            if let id = BallID.colourID(colour) { onTable.insert(id) }
        }
        self.ballsOnTable = onTable
    }

    public var currentPlayerName: String { players[currentPlayer].name }

    /// Convenience accessor for both players' scores.
    public var scores: [Int] {
        get { players.map(\.score) }
        set {
            for (index, value) in newValue.enumerated() where index < players.count {
                players[index].score = value
            }
        }
    }

    public var ballOnColour: BallColor? {
        switch ballOn {
        case .red: return nil
        case .anyColour: return nominatedColour
        case .colourOfSequence(let c): return c
        }
    }
}

public struct TurnResult: Sendable {
    public var foul: Foul?
    public var penalty: Int = 0
    public var pointsScored: Int = 0
    public var missCalled: Bool = false
    public var missWarning: Bool = false
    public init() {}
}
