import Foundation
import Dispatch

/// The computer player.
///
/// It does two things: it picks a stroke, and it answers the questions the rules ask. Picking a stroke
/// is a small search: the geometry proposes the shots that are on (`ShotGenerator`), each one is played
/// out on the real physics, and the position it leaves is judged. The judgement is the part a learned
/// network is meant to take over — `value(of:result:)` is the only thing here that has an opinion about
/// a position, and it is deliberately one small function.
///
/// Nothing here touches the live frame except to read it: every candidate is played out on a copy, so a
/// caller can ask what the computer would do without anything moving.
public final class ComputerPlayer {

    public enum Difficulty: String, Sendable, CaseIterable {
        case easy, medium, hard

        /// How many shots are put to the physics, and how hard the geometry is allowed to be.
        public var settings: ShotGenerator.Settings {
            var settings = ShotGenerator.Settings()
            switch self {
            case .easy:
                settings.potLimit = 6
                settings.safetyLimit = 3
                settings.escapeBalls = 3
                settings.escapeLimit = 20
                settings.arrivalSpeed = 450
            case .medium:
                settings.potLimit = 14
                settings.safetyLimit = 6
                settings.escapeBalls = 4
                settings.escapeLimit = 40
            case .hard:
                settings.potLimit = 26
                settings.safetyLimit = 10
                settings.escapeBalls = 6
                settings.escapeLimit = 70
            }
            return settings
        }

        /// The spins the best shot is tried with. A shot is as much about where the cue ball finishes as
        /// about the ball that is potted, and the tip is how that is bought.
        public var spinVariants: [Double] {
            switch self {
            case .easy: return [0]
            case .medium: return [0, -0.5, 0.4]
            case .hard: return [-0.6, -0.25, 0, 0.35]
            }
        }

        /// The strengths the best shot is tried with, as multipliers of the strength the geometry asked
        /// for — the arithmetic is a guess, and the physics is the truth. `1` is the estimate itself, and
        /// the strength and the spin are tried together: a pot that needs screw to hold the cue ball back
        /// needs it played hard enough as well.
        public var powerRefinements: [Double] {
            switch self {
            case .easy: return [1]
            case .medium: return [0.7, 1, 1.35, 1.9]
            case .hard: return [0.7, 0.9, 1.15, 1.5]
            }
        }

        /// The side spins and the cue lifts its shots are tuned with. A shot is aimed with the whole of the
        /// cue, not just its line: the tip across the ball is what brings it off a cushion, and the butt in
        /// the air is what plays it over one.
        public var sideSpins: [Double] {
            switch self {
            case .easy: return [0]
            case .medium: return [0, -0.3, 0.3]
            case .hard: return [0, -0.35, 0, 0.35]
            }
        }

        public var elevations: [Double] {
            switch self {
            case .easy: return [0]
            case .medium: return [0, 10 * .pi / 180]
            case .hard: return [0, 8 * .pi / 180, 20 * .pi / 180]
            }
        }

        /// The most shots one decision may play out. A shot played out costs about 30 ms of one core in a
        /// release build, and they go round the cores together, so this is what thinking time is.
        public var rolloutBudget: Int {
            switch self {
            case .easy: return 10
            case .medium: return 40
            case .hard: return 90
            }
        }

        /// How far off the line this player's cue goes, in degrees: the standard deviation of the aim
        /// error. It is what the three difficulties are **for** — how long the computer thinks is the
        /// smaller half of what makes it hard to play — and it is a property of the cue action rather than
        /// of the thinking, so it is set here beside the search's own settings.
        ///
        /// The sizes are the ones measured in the project README: 0.2° is a weak club player who loses the
        /// long game, 0.1° is a club player, and 0.03° keeps the long pots and with them the breaks.
        public var aimErrorDegrees: Double {
            switch self {
            case .easy: return 0.2
            case .medium: return 0.1
            case .hard: return 0.03
            }
        }

        public var aimError: Double { aimErrorDegrees * Double.pi / 180 }
    }

    /// What the computer wants done next. The player only *decides*: carrying it out is the caller's,
    /// so that the same brain drives the headless harness and, later, the window.
    public enum Action: Equatable, Sendable {
        case placeCueBall(Vec2)
        case nominateColour(BallColor)
        case takeAFreeBall(BallColor)
        case declineTheFreeBall
        case playFromHere
        case askTheOffenderToPlayAgain
        case replaceTheBalls
        case claimTheFrame
        /// Ask for the frame to be **re-racked**: Section 3 Rule 17, the answer to a position neither
        /// player can do anything with.
        case reRack
        case shoot(Shot)
        case wait
    }

    public let playerIndex: Int
    public var difficulty: Difficulty {
        didSet { applyTheDifficulty() }
    }
    /// The shots the geometry offers, how many of them are played out, and what the best of them is then
    /// tried with. Set from `difficulty`, and settable directly for a caller that wants something else —
    /// a test that cannot afford a full think, or a player tuned another way.
    public var settings: ShotGenerator.Settings
    public var spinVariants: [Double]
    public var powerRefinements: [Double]
    public var sideSpins: [Double]
    public var elevations: [Double]
    public var rolloutBudget: Int
    /// How many of the player's **own shots** it looks ahead: 1 is the shot and where it leaves the balls,
    /// and 3 is a break being built — this red, the black after it, and the one after that. It is the
    /// difference between a player that pots and a player that *plays position*.
    public var depth: Int = 3
    /// How many of the best lines are followed deeper at each ply. Three plies of the whole candidate list
    /// is the product of the counts at each of them, which is more shots than there is time to play.
    public var beam: Int = 3
    /// How long one decision may take, in seconds. The search is anytime: it stops when the clock does and
    /// plays the best line it has found.
    public var timeBudget: Double = 4.0
    /// Who wins the draw for the choice of playing next when the Black is re-spotted (Section 3 Rule
    /// 4(b)(ii)). Fixed, so that a run of frames can be reproduced.
    public var decideTheDraw: () -> Int = { 0 }
    /// How often the computer plays something other than the shot it thinks is best. Playing is always
    /// the best shot; this is for **generating positions to learn from**, where the shots a good player
    /// would never play are exactly the ones a network has seen nothing like.
    public var exploration: Double = 0
    /// Where that randomness comes from. Set from a seeded generator so that a dataset can be had again.
    public var randomUnit: () -> Double = { Double.random(in: 0..<1) }
    /// How far off the line the computer's cue goes, as the standard deviation of the aim error in
    /// radians: **the player is not perfect and does not pretend to be**. It is applied twice over, and
    /// both are the point:
    ///
    ///  * to every shot the search plays out, so that a pot which only goes in off a perfect line is seen
    ///    to miss sometimes and is worth less than one with margin — which is what makes an inaccurate
    ///    player play safe;
    ///  * to the shot it finally plays, so that a pot it did choose is missed now and then.
    ///
    /// `0` is a cue action that never misses: what the tests and the benchmarks play, and what the numbers
    /// elsewhere in the project were measured with unless they say otherwise.
    public var aimError: Double
    /// Where the aim error comes from. Two uniforms from here make one normal sample, so a caller that
    /// wants a run of shots to be the same twice sets this from a seeded generator.
    public var aimErrorSource: () -> Double = { Double.random(in: 0..<1) }
    /// What a position is worth, when the caller has something better than the arithmetic below: it is
    /// given a position and answers with the points the player **at the table** is expected to score from
    /// it. This is where a learned value function goes — the network's opinion replaces the geometry's,
    /// and nothing else about the player changes.
    public var valueOfPosition: ((PositionFeatures) -> Double)?

    /// What the computer decided last, in words, for the commentary.
    public private(set) var lastPlan: String = ""
    /// What that decision was, as the planner saw it — a pot, a safety or an escape. Kept so that a
    /// caller can ask what kind of shot the player is playing, and measure fouls by kind.
    public private(set) var lastIntent: ShotIntent?
    /// How many decisions in a row have been made from the **same** position, and the position itself. A
    /// frame in which neither player can do anything but foul is one the rules let them re-rack, and the
    /// computer has to notice that for itself: two of them that do not would foul at each other for ever,
    /// and the frame would never end.
    private var lastPosition: String?
    private var decisionsInOnePosition = 0
    /// How many shots the last decision played out. The cost of thinking, in the unit it is paid in.
    public private(set) var rolloutsLastDecision: Int = 0

    public init(playerIndex: Int, difficulty: Difficulty = .medium) {
        self.playerIndex = playerIndex
        self.difficulty = difficulty
        self.settings = difficulty.settings
        self.spinVariants = difficulty.spinVariants
        self.powerRefinements = difficulty.powerRefinements
        self.sideSpins = difficulty.sideSpins
        self.elevations = difficulty.elevations
        self.rolloutBudget = difficulty.rolloutBudget
        self.aimError = difficulty.aimError
    }

    private func applyTheDifficulty() {
        settings = difficulty.settings
        spinVariants = difficulty.spinVariants
        powerRefinements = difficulty.powerRefinements
        sideSpins = difficulty.sideSpins
        elevations = difficulty.elevations
        rolloutBudget = difficulty.rolloutBudget
        aimError = difficulty.aimError
    }

    // MARK: - What to do next

    public func nextAction(for driver: FrameDriver) -> Action {
        let state = driver.game.state
        guard !state.frameOver, state.currentPlayer == playerIndex else { return .wait }
        // The Black is the only ball left and the striker is more than seven ahead: the frame is theirs
        // if they want it (Section 2 Rule 1(b)).
        if driver.canClaimTheFrame { return .claimTheFrame }
        // Nothing has moved for half a dozen decisions, whoever was at the table: there is nothing here to
        // play, and the frame is the sort the rules let the players begin again.
        let position = thePositionInShort(state)
        if position == lastPosition {
            decisionsInOnePosition += 1
        } else {
            decisionsInOnePosition = 0
            lastPosition = position
        }
        if decisionsInOnePosition >= 6 { return .reRack }

        if let pending = state.pending {
            switch pending {
            case .nominateColour(let options):
                guard let colour = bestColour(among: options, in: driver) else { return .wait }
                return .nominateColour(colour)

            case .placeCueBallInD, .placeCueBallAnywhere:
                guard let point = bestCueBallPlacement(for: driver) else { return .wait }
                lastPlan = "place the cue ball at \(Int(point.x)), \(Int(point.y))"
                return .placeCueBall(point)

            case .nominateFreeBall(let options):
                return freeBallAction(among: options, in: driver)

            case .afterFoul(let decision):
                return afterAFoul(driver) { decision.canRequestOriginalPosition }

            case .afterMiss(let decision):
                return afterAFoul(driver) { decision.canRequestOriginalPosition }
            }
        }

        if driver.canStrike, let choice = bestShot(for: driver) {
            lastPlan = "\(choice.intent.summary) — \(choice.shot.describedForTheLog)"
            lastIntent = choice.intent
            // The shot as it will actually be struck: the search has already lived with errors like this
            // one, so what is played is a shot it has taken into account and not a shot it never saw.
            return .shoot(theShotAsItWillBePlayed(choice.shot))
        }
        return .wait
    }

    /// Where the balls are, coarsely, and what is on — **not** whose turn it is, because a position two
    /// players are fouling at each other from is the same position whoever is holding the cue. Rounded to
    /// twenty millimetres, so that a ball nudged by a hair is not a new position.
    private func thePositionInShort(_ state: GameState) -> String {
        var parts = "\(state.ballOn)|\(state.redsRemaining)|\(state.ballsOnTable.count)"
        for id in state.ballsOnTable.sorted() {
            guard let position = state.ballPositions[id] else { continue }
            parts += "|\(id):\(Int(position.x / 20)),\(Int(position.y / 20))"
        }
        return parts
    }

    /// The shot as it will be struck: the same shot, with the cue a little off the line it was aimed
    /// along. One draw from the aim error, which is nothing at all when the player's cue action is exact.
    public func theShotAsItWillBePlayed(_ shot: Shot) -> Shot {
        theShot(shot, withError: aimErrorOffset())
    }

    /// One draw of the aim error, in radians: nothing at all for a cue action that never misses.
    func aimErrorOffset() -> Double {
        guard aimError > 0 else { return 0 }
        return Normal.sample(standardDeviation: aimError, using: aimErrorSource)
    }

    /// The same shot with an error on it that the caller has already drawn, so that a whole family of
    /// shots — one shot and the strengths and spins it might be played with — can be given the **same**
    /// cue action and compared with each other rather than with their own luck.
    func theShot(_ shot: Shot, withError offset: Double) -> Shot {
        guard offset != 0 else { return shot }
        var played = shot
        played.angle += offset
        return played
    }

    // MARK: - Choosing the stroke

    public struct Choice: Sendable {
        public var shot: Shot
        public var intent: ShotIntent
        /// What the computer thinks the shot is worth, in points-ish: the units are its own, and only
        /// the comparisons between them mean anything.
        public var value: Double
        /// The draw of the aim error this candidate was first played out with, so that the strengths and
        /// spins it is tried with can be given the same cue action.
        var draw: Double = 0
    }

    /// The best shot the computer can find from where the frame stands. Nothing is played: every
    /// candidate goes through a copy of the frame.
    public func bestShot(for driver: FrameDriver) -> Choice? {
        var budget = 0
        let deadline = Date().addingTimeInterval(timeBudget)
        let found = search(from: driver, depth: depth, deadline: deadline, budget: &budget)
        rolloutsLastDecision = budget
        // Playing something other than the best shot, on purpose: for generating positions to learn from,
        // where the shots a good player would never play are the ones a network has seen nothing like.
        if exploration > 0, randomUnit() < exploration,
           let alternatives = found.runnerUps, !alternatives.isEmpty {
            let window = min(6, alternatives.count)
            return alternatives[min(window - 1, Int(randomUnit() * Double(window)))]
        }
        return found.choice
    }

    /// The best line of the player's **own shots** from where the frame stands, and the shot that begins it.
    ///
    /// A line is a shot played out with the real physics and then — if the player is still at the table —
    /// the best line from *there*, one ply shorter. The turn passing ends the line: the position is the
    /// opponent's, and the line is worth less by what they can do with it. It is a **beam** search rather
    /// than a tree, because three plies of the whole candidate list is the product of the counts at each
    /// of them, which is more shots than there is time to play in a game.
    private func search(from driver: FrameDriver, depth: Int, deadline: Date,
                        budget: inout Int) -> (choice: Choice?, value: Double, runnerUps: [Choice]?) {
        let state = driver.game.state
        guard !state.frameOver, state.currentPlayer == playerIndex else {
            return (nil, -leafValue(of: state), nil)
        }
        guard depth > 0, Date() <= deadline else { return (nil, leafValue(of: state), nil) }
        let candidates = proposals(for: driver, deep: depth < self.depth)
        guard !candidates.isEmpty else { return (nil, leafValue(of: state), nil) }

        // Every shot is played out on its own copy of the frame, so they go round the cores together. One
        // draw of the aim error per candidate, and the **same** draw is used for the strengths, spins and
        // lifts that candidate is tuned with: what separates them is then the shot and not the luck.
        let errors = candidates.map { _ in aimErrorOffset() }
        budget += candidates.count
        let outcomes = playOutcomes(candidates.map(\.shot), errors: errors, in: driver)
        var scored: [(choice: Choice, outcome: Outcome)] = []
        for (index, candidate) in candidates.enumerated() {
            guard let outcome = outcomes[index] else { continue }
            scored.append((Choice(shot: candidate.shot, intent: candidate.intent,
                                  value: outcome.value, draw: errors[index]), outcome))
        }
        guard !scored.isEmpty else { return (nil, leafValue(of: state), nil) }
        scored.sort { $0.choice.value > $1.choice.value }

        // The best few shots are **tuned** — strength, both spins and the lift of the cue, one at a time —
        // and then the best few of those are carried a ply further. Tuning only happens at the top of the
        // tree: further in, the geometry's own strength is good enough to judge a line by.
        var tuned = scored
        if depth == self.depth {
            for (index, entry) in scored.prefix(beam + 1).enumerated() {
                tuned[index] = tune(entry, from: driver, deadline: deadline, budget: &budget)
            }
            tuned.sort { $0.choice.value > $1.choice.value }
        }
        guard depth > 1 else {
            return (tuned[0].choice, tuned[0].choice.value, tuned.map(\.choice))
        }

        var best = tuned[0]
        for entry in tuned.prefix(beam) where Date() <= deadline {
            guard entry.outcome.stillAtTheTable, let leaf = entry.outcome.leaf, !leaf.frameOver else {
                continue
            }
            let probe = FrameDriver(playerNames: driver.playerNames)
            probe.load(leaf)
            let deeper = search(from: probe, depth: depth - 1, deadline: deadline, budget: &budget)
            // The shot scores what it scores, and the line is worth what is left on the table after it.
            let total = 0.9 * Double(entry.outcome.points) + deeper.value
            if total > best.choice.value {
                best = (Choice(shot: entry.choice.shot, intent: entry.choice.intent,
                               value: total, draw: entry.choice.draw), entry.outcome)
            }
        }
        return (best.choice, best.choice.value, tuned.map(\.choice))
    }

    /// The shots the geometry offers from where the frame is: the pots that are on and the safeties off
    /// them, or — when nothing is on — the escapes. `deep` narrows the list for the plies further in, so
    /// that the beam does not multiply into thousands of shots.
    private func proposals(for driver: FrameDriver, deep: Bool) -> [ShotCandidate] {
        let state = driver.game.state
        let layout = BallLayout(state: state)
        let targets = driver.game.legalFirstContacts()
        guard !targets.isEmpty else { return [] }

        var candidates = ShotGenerator.pots(layout: layout, targets: targets, settings: settings)
        var escaping = false
        if candidates.isEmpty {
            // Nothing is on, so the shot is about reaching a ball on at all.
            escaping = true
            candidates = ShotGenerator.escapes(layout: layout, targets: targets, settings: settings)
        } else {
            // A safety aimed down a pot line is not a safety, it is a harder pot: the geometry proposes
            // both, and the same line twice only wastes a play-out. The pot keeps the line.
            var potLines: [Int: [Double]] = [:]
            for candidate in candidates {
                if case .pot(let ball, _, _) = candidate.intent {
                    potLines[ball, default: []].append(candidate.shot.angle)
                }
            }
            let tolerance = 2.5 * Double.pi / 180
            let safeties = ShotGenerator.safeties(layout: layout, targets: targets, settings: settings)
                .filter { candidate in
                    guard case .safety(let ball) = candidate.intent, let lines = potLines[ball] else {
                        return true
                    }
                    return !lines.contains { ShotGeometry.angleBetween($0, candidate.shot.angle) < tolerance }
                }
            candidates += safeties
        }
        // An escape is a different budget: it is the only shot there is, and being snookered is not a
        // reason to think less. Deeper in the tree every list is cut to a quarter.
        let limit = escaping ? settings.escapeLimit
            : (deep ? max(4, rolloutBudget / 4) : rolloutBudget)
        return Array(candidates.prefix(limit))
    }

    /// Tunes a shot: the strength, the vertical spin, the side spin and the lift of the cue, one at a time,
    /// keeping whatever is worth more. The geometry's strength is a starting point and nothing more — the
    /// shot that goes in **and leaves something** is a different strength and a different tip from the one
    /// that only goes in.
    private func tune(_ entry: (choice: Choice, outcome: Outcome), from driver: FrameDriver,
                      deadline: Date, budget: inout Int) -> (choice: Choice, outcome: Outcome) {
        var best = entry
        // The spins and the lift come **first** and the strength last, because a shot is one stroke: the tip
        // off centre spends part of the impulse on spin, so a ball struck with screw is slower than the same
        // strength struck plain, and a strength chosen before the spin is a strength for a different shot.
        let ladders: [(kind: String, values: [Double])] = [
            ("vertical", spinVariants),
            ("side", sideSpins),
            ("elevation", elevations),
            ("power", powerRefinements),
        ]
        for ladder in ladders {
            var variants: [Shot] = []
            for value in ladder.values {
                var shot = best.choice.shot
                switch ladder.kind {
                case "power":
                    guard value != 1 else { continue }
                    shot.power = min(1, max(0.03, best.choice.shot.power * value))
                case "vertical":
                    guard value != 0 else { continue }
                    shot.vertical = value
                case "side":
                    guard value != 0 else { continue }
                    shot.side = value
                default:
                    guard value != 0 else { continue }
                    shot.elevation = value
                }
                variants.append(shot)
            }
            guard !variants.isEmpty, Date() <= deadline else { continue }
            budget += variants.count
            let errors = variants.map { _ in best.choice.draw }
            let outcomes = playOutcomes(variants, errors: errors, in: driver)
            for (index, outcome) in outcomes.enumerated() {
                guard let outcome, outcome.value > best.choice.value else { continue }
                best = (Choice(shot: variants[index], intent: best.choice.intent,
                               value: outcome.value, draw: best.choice.draw), outcome)
            }
        }
        return best
    }

    /// Plays a list of shots out on copies of the frame, all at once, and says what each was worth. Nil
    /// where a shot could not be played at all.
    func playOut(_ shots: [Shot], in driver: FrameDriver, errors: [Double]? = nil) -> [Double?] {
        playOutcomes(shots, errors: errors, in: driver).map { $0?.value }
    }

    /// The same, with the whole of what each shot did rather than only what it was worth: what a search
    /// one shot further needs is the position the shot left.
    func playOutcomes(_ shots: [Shot], errors: [Double]?, in driver: FrameDriver) -> [Outcome?] {
        guard !shots.isEmpty else { return [] }
        var outcomes = [Outcome?](repeating: nil, count: shots.count)
        let writing = NSLock()
        DispatchQueue.concurrentPerform(iterations: shots.count) { index in
            let outcome = playOutcome(of: shots[index], in: driver, error: errors?[index])
            writing.lock()
            outcomes[index] = outcome
            writing.unlock()
        }
        return outcomes
    }

    // MARK: - Playing one shot out

    /// What a shot did, played out on a copy of the frame: what went in, what was fouled, and what the
    /// computer made of the position it left.
    public struct Outcome: Sendable {
        public var potted: [Int] = []
        public var cueBallPotted = false
        /// The first ball the cue ball met, if it met one at all: what the stroke was legal for is decided
        /// by this and by nothing else.
        public var firstContact: Int?
        public var foul: String?
        public var penalty = 0
        public var points = 0
        public var stillAtTheTable = false
        public var opponentSnookered = false
        public var cueBallInHand = false
        public var frameOver = false
        public var value: Double = 0
        /// The position the shot left, as the rules have it: what a search one shot further looks at.
        public var leaf: GameState?
    }

    /// Plays `shot` on a **copy** of the frame and reports what it did. This is the unit of work the whole
    /// player is built out of — one shot, played out by the real physics — and the one thing worth timing.
    public func playOutcome(of shot: Shot, in driver: FrameDriver, error: Double? = nil) -> Outcome? {
        let probe = FrameDriver(playerNames: driver.playerNames)
        // The frame's own position, **mode and all**: a charged stroke is a stroke the player may be in a
        // place to play or not, and the same is true of the copy.
        probe.load(driver.game.state)
        probe.game.decideTheDraw = decideTheDraw
        // The shot is played out **as this player would play it**: error and all, and played the way a
        // player plays a shot — a charge and the cue action it leaves behind, so that the tip's own contact
        // with the ball is what gives it its speed, off-centre cost and all. What the search judges is then
        // what will actually happen at the table, not an idealised version of it.
        let played = theShot(shot, withError: error ?? aimErrorOffset())
        // The stroke is the cue's before it is the ball's: it is not away until the tip has met it, and
        // `runStrokeToRest` is what takes it that far before letting the balls run.
        guard probe.playCharged(played, at: 0) else { return nil }
        probe.runStrokeToRest()
        // A stroke that never came off leaves nothing behind it: the cue action is the shot, and a shot
        // whose tip never reached the ball is one this player cannot play.
        guard probe.lastResult != nil else { return nil }
        let state = probe.game.state
        var outcome = Outcome()
        outcome.potted = (probe.lastStroke?.potted ?? []).filter { $0 != BallID.cue }
        outcome.cueBallPotted = probe.lastStroke?.cueBallPotted ?? false
        outcome.firstContact = probe.lastStroke?.firstContacts.first
        outcome.foul = probe.lastResult?.foul?.reason
        outcome.penalty = probe.lastResult?.penalty ?? 0
        outcome.points = probe.lastResult?.pointsScored ?? 0
        outcome.stillAtTheTable = !state.frameOver && state.currentPlayer == playerIndex
        outcome.opponentSnookered = !state.frameOver && state.currentPlayer != playerIndex
            && isSnookered(state)
        outcome.cueBallInHand = state.cueBallInHand
        outcome.frameOver = state.frameOver
        outcome.value = value(of: state, result: probe.lastResult)
        outcome.leaf = state
        return outcome
    }

    /// What a shot was worth, without the detail.
    public func valueOfPlaying(_ shot: Shot, in driver: FrameDriver) -> Double? {
        playOutcome(of: shot, in: driver)?.value
    }

    /// What a position is worth to the player whose turn it is to be judged, in the computer's own
    /// units. Points scored are worth what they are worth; the table itself is worth having — an easy
    /// ball on is worth a great deal, and leaving one to the opponent costs as much.
    func value(of state: GameState, result: TurnResult?) -> Double {
        guard let result else { return -1000 }
        if state.frameOver {
            return state.winner == playerIndex ? 1000 : -1000
        }
        if let foul = result.foul {
            var value = -Double(foul.penalty) - 3
            if result.missCalled { value -= 2 }
            // A foul that leaves the opponent an easy pot is a bigger disaster than one that leaves them
            // nothing at all.
            value -= 1.5 * opportunity(in: state)
            return value
        }

        var value = 0.9 * Double(result.pointsScored)
        // What the player at the table is expected to score from where the balls have been left: theirs
        // when the striker is still on, and the opponent's — counting against us — when the table has
        // passed. That is the whole of what a value function says about a shot.
        let theirs = leafValue(of: state)
        value += state.currentPlayer == playerIndex ? theirs : -theirs
        return value
    }

    /// What the player **at the table** is expected to score from a position: the learned value function
    /// when there is one, and the arithmetic when there is not. It is the end of every line the search
    /// plays out, and the only opinion the player has about a position it has not played from.
    func leafValue(of state: GameState) -> Double {
        guard !state.frameOver else { return 0 }
        if let learned = valueOfPosition {
            return learned(PositionFeatures.of(state, aimError: aimError))
        }
        return positionValue(of: state)
    }

    /// What the player's own arithmetic makes of a position, **from the point of view of the player at the
    /// table**: how good the balls on are for them, whether they are snookered (which is bad for them) and
    /// how tucked up against a cushion the cue ball is (which is awkward for them, and is what a safety is
    /// for).
    ///
    /// It is the whole of the judgement the player has without a learned value function, and it is what a
    /// network has to be better than — so it is written down here once, and the search, the tests and the
    /// recorded data all read the same one. Note the two signs: a position that is *good for whoever is at
    /// the table* is good for us when that is us and bad for us when it is not, which is why this is the
    /// value **of the turn** and not of the shot.
    public func positionValue(of state: GameState) -> Double {
        guard !state.frameOver else { return 0 }
        // Being at the table is worth something in itself: the balls on are yours to play.
        var value = 1.2 + 2.4 * opportunity(in: state)
        // And it matters **which** ball is on, not only how easy it is: a break is built by playing for
        // the black, and a position that leaves the black on with a pot is worth a good deal more than the
        // same pot on the yellow. The term is nothing for a red — every red is worth one — and goes up with
        // the colour's value, which is what makes the search play for the high ones.
        let ballOn = Double(ballOnValue(of: state))
        value += 0.6 * max(0, ballOn - 1) * opportunity(in: state)
        if isSnookered(state) { value -= 1.5 }
        value -= 0.5 * cushionCloseness(of: state)
        return value
    }

    /// What the ball on is worth in points (Rule 1(a)).
    func ballOnValue(of state: GameState) -> Int {
        let game = SnookerGame()
        game.withState { $0 = state }
        return game.ballOnValue()
    }

    // MARK: - Judging a position without playing it

    /// How good the balls on are for whoever is at the table: 0 is nothing to hit, 1 is a ball hanging
    /// over a pocket. It is the geometry's own opinion, and it costs nothing to ask — this is what the
    /// computer uses to judge where a shot has left things, and what a learned value network will
    /// replace.
    func opportunity(in state: GameState) -> Double {
        // A ball in hand is a free hand at the table: the striker can put the cue ball where they like.
        if state.cueBallInHand { return 0.75 }
        let targets = ShotGenerator.targets(in: state)
        guard !targets.isEmpty else { return 0 }
        let pots = ShotGenerator.pots(layout: BallLayout(state: state),
                                      targets: targets,
                                      settings: .quick)
        guard let best = pots.first else { return 0 }
        return 1 - best.ease
    }

    func isSnookered(_ state: GameState) -> Bool {
        guard !state.cueBallInHand else { return false }
        let game = SnookerGame()
        game.withState { $0 = state }
        return game.isSnookered()
    }

    /// How tucked up the cue ball is: 0 out in the middle of the table, 1 tight against a cushion.
    func cushionCloseness(of state: GameState) -> Double {
        guard !state.cueBallInHand, let cue = state.ballPositions[BallID.cue] else { return 0 }
        let toTheNearestCushion = min(cue.x, Table.length - cue.x, cue.y, Table.width - cue.y)
        return max(0, min(1, 1 - toTheNearestCushion / 500))
    }

    // MARK: - Colours, free balls and where to put the cue ball

    func bestColour(among options: [BallColor], in driver: FrameDriver) -> BallColor? {
        var best: (colour: BallColor, score: Double)?
        for colour in options {
            var trial = driver.game.state
            trial.ballOn = .anyColour
            trial.nominatedColour = colour
            let score = Double(colour.value) * (0.35 + 0.65 * opportunity(in: trial))
            if best == nil || score > best!.score { best = (colour, score) }
        }
        return best?.colour
    }

    func freeBallAction(among options: [BallColor], in driver: FrameDriver) -> Action {
        var best: (colour: BallColor, score: Double)?
        for colour in options {
            var trial = driver.game.state
            trial.freeBallNominee = colour
            let score = opportunity(in: trial)
            if best == nil || score > best!.score { best = (colour, score) }
        }
        var declined = driver.game.state
        declined.freeBallNominee = nil
        let asItStands = opportunity(in: declined)
        guard let best, best.score > asItStands + 0.02 else {
            lastPlan = "no free ball: play what is on"
            return .declineTheFreeBall
        }
        lastPlan = "free ball as the \(best.colour.rawValue)"
        return .takeAFreeBall(best.colour)
    }

    func bestCueBallPlacement(for driver: FrameDriver) -> Vec2? {
        var best: (point: Vec2, score: Double)?
        for point in placementSamples(for: driver.game.state) {
            guard driver.game.isFreePosition(point, ignoring: BallID.cue) else { continue }
            var trial = driver.game.state
            trial.ballPositions[BallID.cue] = point
            trial.ballsOnTable.insert(BallID.cue)
            trial.cueBallInHand = false
            let score = opportunity(in: trial)
            if best == nil || score > best!.score { best = (point, score) }
        }
        return best?.point
    }

    func placementSamples(for state: GameState) -> [Vec2] {
        var points: [Vec2] = []
        if case .placeCueBallAnywhere = state.pending {
            let step = 260.0
            var x = Table.ballRadius
            while x <= Table.length - Table.ballRadius {
                var y = Table.ballRadius
                while y <= Table.width - Table.ballRadius {
                    points.append(Vec2(x, y))
                    y += step
                }
                x += step
            }
            return points
        }
        // The "D": the half-disc behind the baulk line.
        let step = 55.0
        var x = Table.baulkLineX - Table.dRadius
        while x <= Table.baulkLineX {
            var y = Table.centreY - Table.dRadius
            while y <= Table.centreY + Table.dRadius {
                let point = Vec2(x, y)
                if Table.isInsideD(point), ShotGeometry.isOnTheCloth(point) { points.append(point) }
                y += step
            }
            x += step
        }
        return points
    }

    // MARK: - What happens next, after a foul

    /// The non-offender's choice after a foul: play from where the balls lie, ask the offender to play
    /// again from there, or — where the rules allow it — put the balls back and make the offender play
    /// the stroke over.
    ///
    /// The position is the same for both players, so what decides it is who it suits: with a ball on
    /// that can be potted, the striker wants it; with nothing to hit, the striker wants the *other* one
    /// to have it, and the cue ball in hand or a ball in the open is worth taking every time.
    func afterAFoul(_ driver: FrameDriver, canRequestOriginalPosition: () -> Bool) -> Action {
        let state = driver.game.state
        if state.cueBallInHand {
            lastPlan = "play from here: the cue ball is in hand"
            return .playFromHere
        }
        let ours = opportunity(in: state)
        if ours >= 0.4 {
            lastPlan = "play from here"
            return .playFromHere
        }
        if canRequestOriginalPosition() {
            lastPlan = "put the balls back: nothing is on from here"
            return .replaceTheBalls
        }
        lastPlan = "ask the offender to play it again: nothing is on from here"
        return .askTheOffenderToPlayAgain
    }
}

public extension ComputerPlayer.Action {
    /// True when the decision is a **stroke to play** rather than an answer to one of the game's
    /// questions. The questions are decisions too, and a caller that is counting what the computer did to
    /// the balls cares about the difference.
    var isAShot: Bool {
        if case .shoot = self { return true }
        return false
    }
}
