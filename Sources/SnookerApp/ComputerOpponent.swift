import Foundation
import AppKit
import SnookerCore

/// The computer player, headless: no window, no picture, just frames played out and counted.
///
/// The playing is `ComputerMatch`'s, in the core, where it can be tested; what is here is the printing —
/// the log of a frame, the tally of a run of them, and the timing that says what thinking costs.
enum ComputerOpponent {

    /// What a run of frames came to.
    struct Tally {
        var framesPlayed = 0
        var strokes = 0
        var pots = 0
        var fouls = 0
        var misses = 0
        /// Points scored over the whole run, added up frame by frame.
        var points = [0, 0]
        var highestBreak = [0, 0]
        var framesWon = [0, 0]
        var rollouts = 0
        var seconds = 0.0
        var unfinished = 0
        var trouble: [String] = []

        var potRate: Double { strokes == 0 ? 0 : Double(pots) / Double(strokes) }
        var foulsPerHundredStrokes: Double { strokes == 0 ? 0 : 100 * Double(fouls) / Double(strokes) }
        var pointsPerPlayerPerFrame: Double {
            framesPlayed == 0 ? 0 : Double(points[0] + points[1]) / Double(2 * framesPlayed)
        }
        var millisecondsPerStroke: Double { strokes == 0 ? 0 : 1000 * seconds / Double(strokes) }
        var shotsPerDecision: Double { strokes == 0 ? 0 : Double(rollouts) / Double(strokes) }

        var summary: String {
            [
                "frames              \(framesPlayed)  (\(unfinished) unfinished)",
                "strokes             \(strokes)",
                "pots                \(pots)  (\(String(format: "%.0f", potRate * 100))% of strokes)",
                "fouls               \(fouls)  (\(String(format: "%.1f", foulsPerHundredStrokes)) per 100 strokes)",
                "misses called       \(misses)",
                "points scored       \(points[0]) – \(points[1]) over the run",
                "points a frame      \(String(format: "%.1f", pointsPerPlayerPerFrame)) a player",
                "highest breaks      \(highestBreak[0]) and \(highestBreak[1])",
                "frames won          \(framesWon[0]) – \(framesWon[1])",
                "shots played out    \(rollouts)  (\(String(format: "%.0f", shotsPerDecision)) a decision)",
                "wall clock          \(String(format: "%.1f", seconds)) s  (\(String(format: "%.0f", millisecondsPerStroke)) ms a decision)",
            ].joined(separator: "\n")
        }
    }

    static func name(of player: Int) -> String { player == 0 ? "Computer A" : "Computer B" }

    // MARK: - Playing frames

    static func playFrames(_ count: Int, options: Options) -> Int32 {
        let learned = valueFunction(for: options)
        let policy = options.policyPath.flatMap { LearnedPolicy.load(path: $0) }
        let verbose = options.verbose
        var random = SeededRandom(seed: options.seed ^ 0xC0FFEE)
        let unit: () -> Double = { random.unit() }
        var tally = Tally()
        let start = Date()
        for frame in 0..<max(1, count) {
            if verbose { print("\n——— frame \(frame + 1) ———") }
            let frameStart = Date()
            var reportedStrokes = 0
            var scores = [0, 0]
            let report = ComputerMatch.playFrame(
                firstPlayer: frame % 2,
                difficulty: options.difficulty,
                configure: { player in
                    player.valueOfPosition = learned
                    player.policy = policy
                    dress(player, with: options, random: unit)
                }
            ) { event in
                switch event {
                case .action(let player, let description):
                    if verbose { print("      \(name(of: player)): \(description)") }
                case .stroke(let player, let number, let description, let potted, let foul,
                             let missed, let after, let breakScore):
                    reportedStrokes = number
                    scores = after
                    guard verbose else { return }
                    var line = String(format: "%4d. %@: %@", number, name(of: player), description)
                    if let foul {
                        line += "   ⚠️ foul: \(foul)\(missed ? " and a miss" : "")"
                    } else if potted > 0 {
                        line += "   ➜ \(potted) potted"
                    }
                    line += "   \(after[0])–\(after[1])"
                    if breakScore > 0 { line += "  (break \(breakScore))" }
                    print(line)
                case .frameOver(let winner, let final):
                    if verbose {
                        let result = winner.map { "to \(name(of: $0))" } ?? "unfinished"
                        print("      frame \(result) \(final[0])–\(final[1])")
                    }
                case .trouble(let message):
                    print("      ⚠️ \(message)")
                }
            }

            tally.framesPlayed += 1
            tally.strokes += reportedStrokes
            tally.pots += report.pots
            tally.fouls += report.fouls
            tally.misses += report.misses
            tally.rollouts += report.rollouts
            tally.seconds += Date().timeIntervalSince(frameStart)
            tally.points[0] += scores[0]
            tally.points[1] += scores[1]
            tally.trouble += report.trouble
            if !report.finished { tally.unfinished += 1 }
            for who in 0...1 {
                tally.highestBreak[who] = max(tally.highestBreak[who], report.highestBreak[who])
            }
            if let winner = report.winner { tally.framesWon[winner] += 1 }
        }
        print("")
        print(tally.summary)
        print("total wall clock    \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        for line in tally.trouble.prefix(10) { print("trouble: \(line)") }
        return tally.trouble.isEmpty ? 0 : 1
    }

    // MARK: - Learning a policy

    /// One sample of a policy dataset: a position, the stroke the teacher chose there, and what the stroke
    /// turned out to be worth. The last four are filled in after the stroke — `won` only when the frame is.
    struct PolicySample {
        var features: [Float]
        var labels: [Float]
        var points: Float = 0
        var foul: Float = 0
        var kept: Float = 0
        var won: Float = 0
    }

    /// What the network is asked to give back for a stroke: the aim as a **pair** — so the wrap at ±180° is
    /// not a cliff — then the strength, both spins and the lift as a fraction of `LearnedPolicy.maximumLift`.
    static func policyLabels(_ shot: Shot) -> [Float] {
        [Float(sin(shot.angle)), Float(cos(shot.angle)), Float(shot.power), Float(shot.side),
         Float(shot.vertical), Float(shot.elevation / LearnedPolicy.maximumLift)]
    }

    /// The file is `SNOOKERPC1`, a count, a stride, then the features, the six labels and the four outcomes.
    static func writePolicySamples(_ samples: [PolicySample], to path: String) -> Bool {
        var data = Data()
        data.append(contentsOf: Array("SNOOKERPC1".utf8))
        func put(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func put(_ value: Float) {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        put(UInt32(samples.count))
        put(UInt32(PositionFeatures.count + 6 + 4))
        for sample in samples {
            for value in sample.features { put(value) }
            for value in sample.labels { put(value) }
            for value in [sample.points, sample.foul, sample.kept, sample.won] { put(value) }
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            print("could not write \(path): \(error)")
            return false
        }
    }

    /// **Supervised**: the current Hard player's own shots, recorded where it plays them. The teacher runs
    /// with no aim error so that the target is the shot it *chose* and not that run's draw of the miss; the
    /// network is given the position's features with the Hard cue action in them, and the σ is applied to
    /// the network's own shot when it is played.
    static func exportPolicy(path: String, options: Options) -> Int32 {
        let start = Date()
        var samples: [PolicySample] = []
        for frame in 0..<options.frames {
            let driver = FrameDriver(playerNames: ["A", "B"])
            driver.game.decideTheDraw = { frame % 2 }
            // A layout to start from, different every frame: a teacher with no aim error plays the same
            // opening frame after frame, and a dataset of six of those is a dataset of one position.
            let layout = PositionGenerator.positions(count: 1, reds: min(15, options.reds),
                                                     seed: options.seed &+ UInt64(frame) &* 7919)[0]
            driver.load(layout)
            let players = [ComputerPlayer(playerIndex: 0, difficulty: .hard),
                           ComputerPlayer(playerIndex: 1, difficulty: .hard)]
            for player in players {
                player.aimError = 0
                player.decideTheDraw = { frame % 2 }
            }
            var frameSamples: [(index: Int, who: Int)] = []
            var strokes = 0
            while !driver.game.state.frameOver, strokes < 500 {
                let who = driver.game.state.currentPlayer
                let action = players[who].nextAction(for: driver)
                if case .shoot(let shot) = action {
                    samples.append(PolicySample(
                        features: PositionFeatures.of(driver.game.state,
                                                      aimError: options.cueAction).values,
                        labels: policyLabels(shot)))
                    frameSamples.append((samples.count - 1, who))
                    strokes += 1
                }
                guard ComputerMatch.apply(action, to: driver) else {
                    if options.verbose {
                        print("  stopped: \(action) in \(driver.mode),"
                                + " pending \(String(describing: driver.game.state.pending))")
                    }
                    break
                }
                if case .shoot = action, let index = frameSamples.last?.index {
                    samples[index].points = Float(driver.lastResult?.pointsScored ?? 0)
                    samples[index].foul = driver.lastResult?.foul != nil ? 1 : 0
                    samples[index].kept = driver.game.state.currentPlayer == who ? 1 : 0
                }
            }
            if let winner = driver.game.state.winner {
                for sample in frameSamples where sample.who == winner { samples[sample.index].won = 1 }
            }
            if options.verbose {
                print("  frame \(frame + 1) of \(options.frames): \(strokes) strokes,"
                        + " \(driver.game.state.scores[0])–\(driver.game.state.scores[1]),"
                        + " \(samples.count) samples, \(String(format: "%.0f", Date().timeIntervalSince(start))) s")
            }
        }
        guard writePolicySamples(samples, to: path) else { return 1 }
        print("wrote \(samples.count) policy samples to \(path)")
        return 0
    }

    /// **Self-play**: the learned policy plays itself, and the current Hard player labels every position the
    /// policy actually visits. The states are the policy's — that is the distribution it has to be good on;
    /// the targets are the strong player's — that is what it is being taught. The policy's own strokes,
    /// their points and whether it kept the table, are recorded with each sample so that later training can
    /// weight or filter with them.
    static func selfPlay(path: String, options: Options) -> Int32 {
        guard let policyPath = options.policyPath,
              let policy = LearnedPolicy.load(path: policyPath) else {
            print("--ai-selfplay needs --policy <a model that loads>")
            return 2
        }
        let start = Date()
        var samples: [PolicySample] = []
        for frame in 0..<options.frames {
            let driver = FrameDriver(playerNames: ["A", "B"])
            driver.game.decideTheDraw = { frame % 2 }
            let learners = [ComputerPlayer(playerIndex: 0, difficulty: .hard),
                            ComputerPlayer(playerIndex: 1, difficulty: .hard)]
            let teachers = [ComputerPlayer(playerIndex: 0, difficulty: .hard),
                            ComputerPlayer(playerIndex: 1, difficulty: .hard)]
            for player in learners {
                player.policy = policy
                player.aimError = options.cueAction
                player.decideTheDraw = { frame % 2 }
            }
            for teacher in teachers {
                teacher.aimError = 0
                teacher.decideTheDraw = { frame % 2 }
            }
            var frameSamples: [(index: Int, who: Int)] = []
            var strokes = 0
            while !driver.game.state.frameOver, strokes < 500 {
                let who = driver.game.state.currentPlayer
                let action = learners[who].nextAction(for: driver)
                if case .shoot = action {
                    if case .shoot(let target) = teachers[who].nextAction(for: driver) {
                        samples.append(PolicySample(
                            features: PositionFeatures.of(driver.game.state,
                                                          aimError: options.cueAction).values,
                            labels: policyLabels(target)))
                        frameSamples.append((samples.count - 1, who))
                    }
                    strokes += 1
                }
                guard ComputerMatch.apply(action, to: driver) else { break }
                if case .shoot = action, let index = frameSamples.last?.index {
                    samples[index].points = Float(driver.lastResult?.pointsScored ?? 0)
                    samples[index].foul = driver.lastResult?.foul != nil ? 1 : 0
                    samples[index].kept = driver.game.state.currentPlayer == who ? 1 : 0
                }
            }
            if let winner = driver.game.state.winner {
                for sample in frameSamples where sample.who == winner { samples[sample.index].won = 1 }
            }
            if options.verbose {
                print("  frame \(frame + 1) of \(options.frames): \(strokes) strokes,"
                        + " \(driver.game.state.scores[0])–\(driver.game.state.scores[1]),"
                        + " \(samples.count) samples, \(String(format: "%.0f", Date().timeIntervalSince(start))) s")
            }
        }
        guard writePolicySamples(samples, to: path) else { return 1 }
        print("wrote \(samples.count) self-play policy samples to \(path)")
        return 0
    }

    // MARK: - What thinking costs

    /// A position as it is written down: what it looks like, what the player's own arithmetic made of it,
    /// what the stroke played from it scored, and which visit it belonged to. The two returns are filled in
    /// when the visit ends, because that is when they are known.
    struct TrainingSample {
        var features: PositionFeatures
        var arithmetic: Double
        var points: Int
        var visit: Int
        /// The points scored from this position until the table passed — what a value function is for.
        var visitReturn = 0.0
        /// The same sum with each stroke worth `discount` of the one before it: truer to how a break is
        /// valued, and a good deal quieter a thing to learn from.
        var discountedReturn = 0.0

        /// The numbers beside the features. The visit is not a target at all — it is there so that a
        /// training run can group a visit's positions together and build its own targets from them.
        static let columns = 5

        var targets: [Float] {
            [Float(visitReturn), Float(points), Float(discountedReturn), Float(arithmetic), Float(visit)]
        }
    }

    /// What each position in a visit was worth, once the visit is over.
    ///
    /// The plain return is the points scored from the position until the table passed. The discounted one
    /// is the same sum with each stroke worth `discount` of the one before it, which is quieter: a position
    /// early in a visit is not really worth the whole of the twenty-point break that followed it, and the
    /// noise of that break's later strokes is exactly what stops a network learning anything from it. The
    /// stroke played from the position itself is the search's business and is not in either sum — the
    /// search adds it separately, which is what makes `points + V(next)` and not `V(here)`.
    static func visitReturns(_ samples: [TrainingSample], discount: Double = 0.7) -> [TrainingSample] {
        var filled = samples
        for index in filled.indices {
            filled[index].visitReturn = Double(filled[index...].reduce(0) { $0 + $1.points })
            var discounted = 0.0
            for later in (index + 1)..<filled.count {
                discounted += pow(discount, Double(later - index - 1)) * Double(filled[later].points)
            }
            filled[index].discountedReturn = discounted
        }
        return filled
    }

    // MARK: - Positions, and the data they make

    /// The options the position-driven modes take.
    struct Options {
        var positions = 200
        var reds = 15
        var seed: UInt64 = 1
        var exploration = 0.25
        var difficulty: ComputerPlayer.Difficulty = .easy
        var verbose = true
        /// Whether to judge positions with a learned value function rather than the built-in arithmetic.
        var learned = false
        var modelPath: String?
        /// Whether the check should fill both seats and play the frame out entire.
        var bothSeats = false
        /// How many of its own shots ahead the computer looks, when the run asks for something other than
        /// the default of three.
        var depth: Int?
        /// Whether the shot's spin and strength are tuned by the line they leave rather than by the
        /// one-shot value: `--line-tuning` on, `--no-line-tuning` off. Nothing means **the difficulty's
        /// own** — on for Hard, off for the others. See `ComputerPlayer.tuneAgainstTheLine`.
        var lineTuning: Bool?
        /// A learned policy to play the stroke with: `--policy <model>`. Every parameter of the shot comes
        /// out of the network; without it the search decides, as before.
        var policyPath: String?
        /// How many frames `--ai-export-policy` and `--ai-selfplay` should play.
        var frames = 10
        /// How far off the line the computer's cue goes, in degrees. Nothing means **the difficulty's
        /// own**: each of the three has a cue action of its own, and `--ai-error` is only for asking what
        /// a different one would do.
        var aimErrorDegrees: Double?

        /// The cue action the run is played with: what `--ai-error` asked for, or the difficulty's.
        var cueAction: Double {
            aimErrorDegrees.map { $0 * Double.pi / 180 } ?? difficulty.aimError
        }

        /// The same in degrees, for the data.
        var cueActionDegrees: Double { cueAction * 180 / Double.pi }

        /// A range of cue actions to play the dataset out with, in degrees, when the run asked for one:
        /// `--ai-error-range <low> <high>`. One net is then a value function for **any** of three
        /// difficulties rather than one per difficulty, because how good the cue action is is a feature of
        /// the position as far as the network is concerned.
        var aimErrorRange: ClosedRange<Double>?

        /// The depth the **challenger** plays to, when a comparison is between two searches rather than
        /// between two ways of judging a position: `--challenger-depth 3` against the run's own `--depth`.
        var challengerDepth: Int?

        init(_ arguments: [String]) {
            if let value = ComputerOpponent.argument("--positions", in: arguments), let n = Int(value) {
                positions = max(1, n)
            }
            if let value = ComputerOpponent.argument("--reds", in: arguments), let n = Int(value) {
                reds = max(1, min(15, n))
            }
            if let value = ComputerOpponent.argument("--seed", in: arguments), let n = UInt64(value) {
                seed = n
            }
            if let value = ComputerOpponent.argument("--explore", in: arguments), let n = Double(value) {
                exploration = max(0, min(1, n))
            }
            if arguments.contains("--hard") { difficulty = .hard }
            if arguments.contains("--medium") { difficulty = .medium }
            verbose = !arguments.contains("--quiet")
            learned = arguments.contains("--learned")
            modelPath = ComputerOpponent.argument("--model", in: arguments)
            bothSeats = arguments.contains("--both")
            if arguments.contains("--line-tuning") { lineTuning = true }
            if arguments.contains("--no-line-tuning") { lineTuning = false }
            policyPath = ComputerOpponent.argument("--policy", in: arguments)
            if let value = ComputerOpponent.argument("--frames", in: arguments), let n = Int(value) {
                frames = max(1, n)
            }
            if let value = ComputerOpponent.argument("--depth", in: arguments), let n = Int(value) {
                depth = max(1, n)
            }
            if let value = ComputerOpponent.argument("--challenger-depth", in: arguments),
               let n = Int(value) {
                challengerDepth = max(1, n)
            }
            if let value = ComputerOpponent.argument("--ai-error", in: arguments),
               let degrees = Double(value) {
                aimErrorDegrees = max(0, degrees)
            }
            if let index = arguments.firstIndex(of: "--ai-error-range"),
               arguments.count > index + 2,
               let low = Double(arguments[index + 1]), let high = Double(arguments[index + 2]) {
                aimErrorRange = min(low, high)...max(low, high)
            }
        }
    }

    /// Puts the run's settings on a player: how far off the line its cue goes, and where the randomness
    /// that decides that comes from — one seeded generator for the whole run, so that a run can be had
    /// again exactly.
    static func dress(_ player: ComputerPlayer, with options: Options, random: @escaping () -> Double) {
        player.aimError = options.cueAction
        player.aimErrorSource = random
        if let lineTuning = options.lineTuning { player.tuneAgainstTheLine = lineTuning }
        if let depth = options.depth { player.depth = depth }
    }

    /// The learned value function, if the run asked for one: nil when it did not, or when the model will
    /// not load — in which case the player simply goes on judging positions the way it always has.
    static func valueFunction(for options: Options) -> ((PositionFeatures) -> Double)? {
        guard options.learned else { return nil }
        return LearnedValue.load(path: options.modelPath ?? "AI/ValueNet.mlpackage")
    }

    static func argument(_ name: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: name), arguments.count > index + 1 else { return nil }
        let value = arguments[index + 1]
        return value.hasPrefix("--") ? nil : value
    }

    /// Writes positions and what a player scored from them, for a network to be trained on.
    ///
    /// The file is `SNOOKERAI1`, then the number of samples and the width of a sample as little-endian
    /// 32-bit numbers, then the samples themselves as 32-bit floats: the position's features, and the
    /// points the striker went on to score from that position before the table passed. Both ends are
    /// written out by `PositionFeatures`, so the file cannot drift from what the player computes.
    static func export(path: String, options: Options) -> Int32 {
        var random = SeededRandom(seed: options.seed ^ 0x5EED_1234)
        let unit: () -> Double = { random.unit() }
        let starts = PositionGenerator.positions(count: options.positions, reds: options.reds,
                                                 seed: options.seed)
        var samples: [TrainingSample] = []
        var visits = 0
        var strokes = 0
        var visitNumber = 0
        var trouble = 0
        let start = Date()
        let learned = valueFunction(for: options)

        for (index, position) in starts.enumerated() {
            let driver = FrameDriver(playerNames: ["A", "B"])
            driver.load(position)
            let players = [ComputerPlayer(playerIndex: 0, difficulty: options.difficulty),
                           ComputerPlayer(playerIndex: 1, difficulty: options.difficulty)]
            // The cue action this layout is played by, drawn from the range: the value of a position
            // depends on who is asking, and a dataset with one cue action in it could not teach that.
            let low = options.aimErrorRange?.lowerBound ?? options.cueActionDegrees
            let high = options.aimErrorRange?.upperBound ?? options.cueActionDegrees
            let cueAction = (low + random.unit() * (high - low)) * Double.pi / 180
            for player in players {
                player.exploration = options.exploration
                player.randomUnit = unit
                player.decideTheDraw = { 0 }
                player.valueOfPosition = learned
                player.aimError = cueAction
                player.aimErrorSource = unit
            }

            // The positions the striker played from, held open until their visit ends: the points scored
            // from a position are only known once the visit is over, and the target is built from the
            // whole run of them.
            var open: [TrainingSample] = []
            var striker = position.currentPlayer
            var steps = 0
            while !driver.game.state.frameOver, steps < 200 {
                steps += 1
                let state = driver.game.state
                let player = players[state.currentPlayer]
                let action = player.nextAction(for: driver)
                let recorded = action.isAShot
                    ? TrainingSample(features: PositionFeatures.of(state, aimError: cueAction),
                                     arithmetic: player.positionValue(of: state),
                                     points: 0, visit: visitNumber)
                    : nil
                guard ComputerMatch.apply(action, to: driver) else {
                    if !driver.game.state.frameOver { trouble += 1 }
                    break
                }
                if var sample = recorded {
                    // What the stroke scored is known once it has been played, and a foul scores the
                    // striker nothing — the penalty goes the other way.
                    sample.points = driver.lastResult?.pointsScored ?? 0
                    open.append(sample)
                    strokes += 1
                }
                let now = driver.game.state
                if now.frameOver || now.currentPlayer != striker {
                    samples += visitReturns(open)
                    visits += 1
                    visitNumber += 1
                    open.removeAll()
                    striker = now.currentPlayer
                    if now.frameOver { break }
                }
            }
            if options.verbose, (index + 1) % 25 == 0 {
                print("  ... \(index + 1) of \(starts.count) positions, \(samples.count) samples")
            }
        }

        var data = Data()
        data.append(contentsOf: Array("SNOOKERAI2".utf8))
        func put(_ value: UInt32) {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        func put(_ value: Float) {
            withUnsafeBytes(of: value.bitPattern.littleEndian) { data.append(contentsOf: $0) }
        }
        put(UInt32(samples.count))
        put(UInt32(PositionFeatures.count + TrainingSample.columns))
        for sample in samples {
            for value in sample.features.values { put(value) }
            for value in sample.targets { put(value) }
        }
        do {
            try data.write(to: URL(fileURLWithPath: path))
        } catch {
            print("could not write \(path): \(error)")
            return 1
        }

        let targets = samples.map(\.visitReturn)
        let mean = targets.isEmpty ? 0 : targets.reduce(0, +) / Double(targets.count)
        let nothing = targets.filter { $0 == 0 }.count
        let big = targets.filter { $0 >= 8 }.count
        print("wrote \(samples.count) samples to \(path)")
        print("  \(PositionFeatures.count) features + the visit's return, the stroke's own points, the")
        print("  discounted return, the player's own arithmetic, and which visit it came from")
        print("  from \(visits) visits and \(strokes) strokes over \(starts.count) positions"
              + " in \(String(format: "%.1f", Date().timeIntervalSince(start))) s")
        print(String(format: "  the points scored: mean %.2f, nothing %.0f%%, eight or more %.0f%%",
                     mean, 100 * Double(nothing) / Double(max(1, targets.count)),
                     100 * Double(big) / Double(max(1, targets.count))))
        if trouble > 0 { print("  ⚠️ \(trouble) positions stopped early") }
        return trouble == 0 ? 0 : 1
    }

    /// Plays positions out and says what the player did with them: the benchmark a learned value function
    /// has to beat, and the one a change to the player is measured against.
    static func measure(options: Options) -> Int32 {
        let starts = PositionGenerator.positions(count: options.positions, reds: options.reds,
                                                 seed: options.seed)
        let start = Date()
        var visits = 0
        var strokes = 0
        var pots = 0
        var fouls = 0
        var points = 0
        var best = 0
        var trouble = 0
        var rollouts = 0
        var foulReasons: [String: Int] = [:]
        var foulsByKind: [String: Int] = [:]
        var strokesByKind: [String: Int] = [:]
        let learned = valueFunction(for: options)
        var random = SeededRandom(seed: options.seed ^ 0xC0FFEE)
        let unit: () -> Double = { random.unit() }

        for position in starts {
            let driver = FrameDriver(playerNames: ["A", "B"])
            driver.load(position)
            let players = [ComputerPlayer(playerIndex: 0, difficulty: options.difficulty),
                           ComputerPlayer(playerIndex: 1, difficulty: options.difficulty)]
            for player in players {
                player.valueOfPosition = learned
                dress(player, with: options, random: unit)
            }
            var striker = position.currentPlayer
            var strikerStartedOn = position.scores[striker]
            var steps = 0
            while !driver.game.state.frameOver, steps < 200 {
                steps += 1
                let state = driver.game.state
                let player = players[state.currentPlayer]
                let action = player.nextAction(for: driver)
                rollouts += player.rolloutsLastDecision
                guard ComputerMatch.apply(action, to: driver) else {
                    if !driver.game.state.frameOver { trouble += 1 }
                    break
                }
                if case .shoot = action {
                    strokes += 1
                    let kind: String
                    switch player.lastIntent {
                    case .pot: kind = "pot"
                    case .safety: kind = "safety"
                    case .escape: kind = "escape"
                    case .neural: kind = "the network's shot"
                    case nil: kind = "?"
                    }
                    strokesByKind[kind, default: 0] += 1
                    pots += (driver.lastStroke?.potted ?? []).filter { $0 != BallID.cue }.count
                    if let reason = driver.lastResult?.foul?.reason {
                        fouls += 1
                        foulReasons[reason, default: 0] += 1
                        foulsByKind[kind, default: 0] += 1
                    }
                }
                let now = driver.game.state
                if now.frameOver || now.currentPlayer != striker {
                    points += now.scores[striker] - strikerStartedOn
                    best = max(best, now.players[striker].highestBreak)
                    visits += 1
                    striker = now.currentPlayer
                    strikerStartedOn = now.scores[striker]
                    if now.frameOver { break }
                }
            }
        }

        let seconds = Date().timeIntervalSince(start)
        print([
            "positions           \(starts.count)",
            "visits              \(visits)  (\(String(format: "%.2f", Double(visits) / Double(max(1, starts.count)))) each)",
            "strokes             \(strokes)",
            "pots                \(pots)  (\(String(format: "%.0f", 100 * Double(pots) / Double(max(1, strokes))))% of strokes)",
            "fouls               \(fouls)  (per visit \(String(format: "%.2f", Double(fouls) / Double(max(1, visits)))))",
            "points a visit      \(String(format: "%.2f", Double(points) / Double(max(1, visits))))",
            "strokes a visit     \(String(format: "%.2f", Double(strokes) / Double(max(1, visits))))",
            "biggest visit       \(best)",
            "shots played out    \(rollouts)  (\(String(format: "%.0f", Double(rollouts) / Double(max(1, strokes)))) a decision)",
            "wall clock          \(String(format: "%.1f", seconds)) s",
        ].joined(separator: "\n"))
        for (reason, count) in foulReasons.sorted(by: { $0.value > $1.value }).prefix(6) {
            print("  foul: \(count) × \(reason)")
        }
        for (kind, count) in strokesByKind.sorted(by: { $0.value > $1.value }) {
            let bad = foulsByKind[kind] ?? 0
            print(String(format: "  %-8@ %6d strokes, %5d fouled (%.0f%%)",
                         kind as NSString, count, bad, 100 * Double(bad) / Double(max(1, count))))
        }
        if trouble > 0 { print("⚠️ \(trouble) positions stopped early") }
        return trouble == 0 ? 0 : 1
    }

    /// A player whose cue action is exact and the same player with an aim error are asked what they would
    /// What the cushions really do to a ball that arrives at an angle.
    ///
    /// The route finder aims at a cushion as if it were a mirror — a ball leaves at the angle it arrived at
    /// — and this table's cushion is deliberately **not** one: it holds the ball and turns it towards the
    /// normal, harder the harder it is struck, which is why two thirds of the routes it works out arrive
    /// and one third do not. What the cushion actually does is measured here rather than assumed, and the
    /// aim is worked out from the measurements.
    static func cushion(options: Options) -> Int32 {
        print("power  ball mm/s  incoming°  normal mm/s  outgoing°  out/in")
        for power in [0.2, 0.3, 0.45, 0.6, 0.8] {
            for degrees in [20.0, 30.0, 45.0, 60.0] {
                let theta = degrees * Double.pi / 180
                let driver = FrameDriver(playerNames: ["Cushion", "Cushion"])
                let start = Vec2(1200, Table.centreY)
                driver.game.withState { state in
                    state.ballsOnTable = [BallID.cue]
                    state.redsRemaining = 0
                    state.ballOn = .colourOfSequence(.black)
                    state.ballPositions[BallID.cue] = start
                    state.cueBallInHand = false
                    state.pending = nil
                }
                driver.syncWorldFromState()
                // At the left cushion, at `theta` from its normal.
                driver.shoot(angle: Double.pi - theta, power: power, side: 0, vertical: 0)
                guard let world = driver.world.ball(id: BallID.cue) else { continue }
                var previous = world.velocity
                var arrivalSpeed = 0.0
                var outgoing: Vec2?
                for _ in 0..<8000 {
                    driver.world.step(dt: 1.0 / 240.0)
                    guard let ball = driver.world.ball(id: BallID.cue) else { break }
                    let velocity = ball.velocity
                    // The bounce: the ball was going left and is now going right.
                    if velocity.x > 0, previous.x < 0 {
                        arrivalSpeed = abs(previous.x)
                        outgoing = velocity
                        break
                    }
                    previous = velocity
                }
                guard let outgoing else { continue }
                let out = atan2(abs(outgoing.y), abs(outgoing.x)) * 180 / Double.pi
                print(String(format: "%.2f   %8.0f   %8.0f   %10.0f   %8.1f   %.3f",
                             power, power * FrameDriver.maxPower, degrees,
                             arrivalSpeed, out, out / degrees))
            }
        }
        return 0
    }

    /// A player whose cue action is exact and the same player with an aim error are asked what they would
    /// do **at the same position**, over and over as a frame is played out. What this answers is the one
    /// thing the aim error is *for*: whether a player that knows it can miss chooses differently — plays
    /// safe where the exact player would go for the pot — as opposed to merely missing more often.
    static func choices(options: Options) -> Int32 {
        let starts = PositionGenerator.positions(count: options.positions, reds: options.reds,
                                                 seed: options.seed)
        var random = SeededRandom(seed: options.seed ^ 0xC0FFEE)
        let unit: () -> Double = { random.unit() }
        var compared = 0
        var agreed = 0, safer = 0, braver = 0

        /// What a shot is for, in one word.
        func kind(_ intent: ShotIntent?) -> String {
            switch intent {
            case .pot: return "pot"
            case .safety: return "safety"
            case .escape: return "escape"
            case .neural: return "the network's shot"
            case nil: return "?"
            }
        }

        for position in starts {
            let driver = FrameDriver(playerNames: ["A", "B"])
            driver.load(position)
            let fallible = [ComputerPlayer(playerIndex: 0, difficulty: options.difficulty),
                            ComputerPlayer(playerIndex: 1, difficulty: options.difficulty)]
            let exact = [ComputerPlayer(playerIndex: 0, difficulty: options.difficulty),
                         ComputerPlayer(playerIndex: 1, difficulty: options.difficulty)]
            for player in fallible { dress(player, with: options, random: unit) }
            for player in exact { player.aimError = 0 }

            var striker = position.currentPlayer
            var steps = 0
            while !driver.game.state.frameOver, steps < 200 {
                steps += 1
                let state = driver.game.state
                let action = fallible[state.currentPlayer].nextAction(for: driver)
                if action.isAShot {
                    // Both are asked the same question about the same position. Asking costs a search each,
                    // which is why this is a check of its own rather than something the game does.
                    let asPlayed = kind(fallible[state.currentPlayer].lastIntent)
                    let asIfExact = kind(exact[state.currentPlayer].bestShot(for: driver)?.intent)
                    compared += 1
                    if asPlayed == asIfExact {
                        agreed += 1
                    } else if asIfExact == "pot" {
                        safer += 1
                    } else if asPlayed == "pot" {
                        braver += 1
                    }
                }
                guard ComputerMatch.apply(action, to: driver) else { break }
                if driver.game.state.frameOver || driver.game.state.currentPlayer != striker {
                    striker = driver.game.state.currentPlayer
                }
            }
        }

        func percent(_ part: Int) -> String {
            compared == 0 ? "—" : String(format: "%.0f%%", 100 * Double(part) / Double(compared))
        }
        print([
            "decisions compared   \(compared) over \(starts.count) positions",
            "the same choice      \(agreed) (\(percent(agreed)))",
            "the error made it    safer \(safer) times (\(percent(safer))), braver \(braver) times (\(percent(braver)))",
            "                     — a player that knows it can miss should be the safer one more often",
        ].joined(separator: "\n"))
        return 0
    }

    /// Two ways of judging a position, on the same positions.
    ///
    /// A single run of positions says very little: the game is deterministic but it is not stable — two
    /// value functions that differ in the fourth decimal place will choose different shots and end up in
    /// places a hundred points apart — so the only comparison worth making is a **paired** one. Each
    /// position is played twice, once with the player's own arithmetic and once with the learned value
    /// function, and what is compared is the difference within each position. The standard error printed
    /// with it is what says whether the difference is bigger than the game's own noise.
    static func compare(options: Options) -> Int32 {
        // Two things can be compared: how the player **judges a position** (the arithmetic against a
        // learned value function) and how far ahead it **searches** (`--challenger-depth`). The second
        // needs no model; the first does.
        let learned = valueFunction(for: options)
        let comparingDepth = options.challengerDepth != nil
        guard comparingDepth || learned != nil else {
            print("--ai-compare needs --learned and a model, or --challenger-depth")
            return 1
        }
        let challengerDepth = options.challengerDepth ?? options.depth ?? 3
        let starts = PositionGenerator.positions(count: options.positions, reds: options.reds,
                                                 seed: options.seed)
        let start = Date()

        /// The first visit from a position: what the striker scores with it, and how many strokes it takes.
        func firstVisit(_ position: GameState,
                        judgingBy judge: ((PositionFeatures) -> Double)?,
                        depth: Int?) -> (points: Int, strokes: Int) {
            // The aim errors come from a generator seeded afresh for **each** visit, so that the two
            // judges are given the same run of good and bad cue actions: what is compared is then the
            // judging and nothing else.
            var random = SeededRandom(seed: options.seed ^ 0xC0FFEE)
            let unit: () -> Double = { random.unit() }
            let driver = FrameDriver(playerNames: ["A", "B"])
            driver.load(position)
            let players = [ComputerPlayer(playerIndex: 0, difficulty: options.difficulty),
                           ComputerPlayer(playerIndex: 1, difficulty: options.difficulty)]
            for player in players {
                player.valueOfPosition = judge
                dress(player, with: options, random: unit)
                // After the dressing: the depth the caller asked for is the one this visit is played at,
                // and `dress` has the run's own depth in it.
                if let depth { player.depth = depth }
            }
            let striker = position.currentPlayer
            let startedOn = position.scores[striker]
            var strokes = 0
            var steps = 0
            while !driver.game.state.frameOver, steps < 80 {
                steps += 1
                let action = players[driver.game.state.currentPlayer].nextAction(for: driver)
                guard ComputerMatch.apply(action, to: driver) else { break }
                if case .shoot = action { strokes += 1 }
                if driver.game.state.frameOver || driver.game.state.currentPlayer != striker { break }
            }
            return (driver.game.state.scores[striker] - startedOn, strokes)
        }

        var plainPoints = 0, learnedPoints = 0, plainStrokes = 0, learnedStrokes = 0
        var differences: [Double] = []
        var better = 0, worse = 0, level = 0

        for position in starts {
            let plain = firstVisit(position, judgingBy: comparingDepth ? learned : nil,
                                   depth: comparingDepth ? (options.depth ?? 1) : nil)
            let smart = firstVisit(position, judgingBy: learned, depth: comparingDepth ? challengerDepth : nil)
            plainPoints += plain.points
            learnedPoints += smart.points
            plainStrokes += plain.strokes
            learnedStrokes += smart.strokes
            let difference = Double(smart.points - plain.points)
            differences.append(difference)
            if difference > 0 { better += 1 } else if difference < 0 { worse += 1 } else { level += 1 }
        }

        let count = Double(max(1, differences.count))
        let mean = differences.reduce(0, +) / count
        let variance = differences.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / max(1, count - 1)
        let error = (variance / count).squareRoot()
        print([
            "positions           \(starts.count)",
            String(format: "points a visit      the player's own arithmetic %.3f, the learned value %.3f",
                   Double(plainPoints) / count, Double(learnedPoints) / count),
            String(format: "strokes a visit     %.2f and %.2f",
                   Double(plainStrokes) / count, Double(learnedStrokes) / count),
            String(format: "the difference      %+.3f points a visit (standard error %.3f)",
                   mean, error),
            "how often better    \(better) better, \(worse) worse, \(level) level",
            "wall clock          \(String(format: "%.1f", Date().timeIntervalSince(start))) s",
        ].joined(separator: "\n"))
        if abs(mean) < 2 * error {
            print("the difference is inside the noise: this many positions cannot tell them apart")
        }
        return 0
    }

    /// Whether a list of proposed escapes contains one that **ends without a foul**: each played out with
    /// the real physics on a copy of the frame.
    ///
    /// This is the question that matters, and it is not the same as reaching a ball on: an escape can meet
    /// a ball on and then put the cue ball in a pocket, and it can be a foul in a dozen other ways. What
    /// the player has to be able to do is get away with the stroke.
    private static func endsWithoutAFoul(_ candidates: [ShotCandidate],
                                         player: ComputerPlayer,
                                         driver: FrameDriver) -> Bool {
        for candidate in candidates {
            guard let outcome = player.playOutcome(of: candidate.shot, in: driver) else { continue }
            if outcome.foul == nil { return true }
        }
        return false
    }

    /// Whether the cheap geometry can be trusted: the lines it says reach a ball on, played out.
    /// The new-game question, driven the way the window drives it: the three modes, the difficulty, and
    /// Escape as the pause of a game between two computers.
    ///
    /// The question is the scene's — it is buttons on an overlay and not a rule of the game — so this is
    /// where it is checked, with no window open: the modes put the right number of computers in the right
    /// seats, and Escape stops a game between two of them where it stands.
    static func uiCheck(options: Options) -> Int32 {
        let scene = TableScene(size: CGSize(width: 1180, height: 760))
        scene.scaleMode = .resizeFill
        var trouble: [String] = []
        func check(_ condition: Bool, _ what: String) {
            if !condition { trouble.append(what) }
        }

        var clock = 0.0
        var strokes = 0
        var wasRunning = false
        /// Lets the scene run for `seconds` of its own clock, with the main queue given its turns.
        func step(_ seconds: Double) {
            let until = clock + seconds
            while clock < until {
                clock += 1.0 / 120.0
                scene.update(clock)
                RunLoop.current.run(until: Date().addingTimeInterval(0.003))
                let running = scene.controller.mode == .simulating
                if running, !wasRunning { strokes += 1 }
                wasRunning = running
            }
        }

        // Two computers play each other, and Escape is the pause.
        scene.startNewGame(mode: .computerVersusComputer, difficulty: .medium)
        check(scene.computerOpponentIsOn, "a game between two computers has computers in it")
        check(!scene.controller.isAskingAboutANewGame, "and the question is put away")
        step(14)
        let played = strokes
        check(played > 0, "two computers play on their own (played \(played) strokes)")

        scene.escapePressed()
        check(scene.controller.isAskingAboutANewGame, "Escape asks the new-game question")
        check(scene.theGameIsPaused, "and pauses a game between two computers")
        let atThePause = strokes
        step(8)
        check(strokes == atThePause, "nothing is played while it is paused (played \(strokes - atThePause))")

        scene.keepPlaying()
        check(!scene.theGameIsPaused, "carrying on takes the pause off")
        check(!scene.controller.isAskingAboutANewGame, "and puts the question away")
        step(14)
        check(strokes > atThePause, "and the game goes on (played \(strokes - atThePause) strokes)")

        // The other two modes put the right number of computers in the seats, and the human one draws its
        // seat rather than always taking the same one.
        scene.startNewGame(mode: .humanVersusHuman)
        check(!scene.computerOpponentIsOn, "two people is no computer at all")
        var seatsSeen: Set<Int> = []
        for _ in 0..<40 {
            scene.startNewGame(mode: .humanVersusComputer, difficulty: .hard)
            check(scene.computerDifficulty == .hard, "the difficulty chosen is the one that plays")
            let computers = (0...1).filter { scene.isPlayingTheComputer($0) }.count
            check(computers == 1, "one person and one computer")
            if let seat = (0...1).first(where: { scene.isPlayingTheComputer($0) }) {
                seatsSeen.insert(seat)
            }
        }
        check(seatsSeen.count == 2, "and the computer's seat is drawn, not fixed (saw \(seatsSeen.sorted()))")

        // Watching: while the computer is at the table the mouse is the player's **own head** and their
        // feet are their own — and none of it touches the shot the computer is playing.
        func key(_ character: String, down: Bool) {
            guard let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp,
                                               location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: 0, context: nil,
                                               characters: character,
                                               charactersIgnoringModifiers: character,
                                               isARepeat: false, keyCode: 0) else { return }
            if down { scene.keyDown(with: event) } else { scene.keyUp(with: event) }
        }

        scene.startNewGame(mode: .computerVersusComputer, difficulty: .easy)
        step(8)
        check(scene.controller.isWatching, "the player is watching while the computer is at the table")
        // Its stroke is the **charged** one — a charge and the cue action it leaves behind — and not a ball
        // given a speed outright.
        var sawTheCueAction = false
        for _ in 0..<600 where !sawTheCueAction {
            step(0.05)
            if scene.controller.theChargedStrokePhase != "none" { sawTheCueAction = true }
        }
        check(sawTheCueAction, "the computer strikes the ball with the charged cue action")
        let aimBefore = scene.controller.aimAngle
        let feetBefore = scene.controller.playerPosition
        let yawBefore = scene.watchingYaw
        scene.steer(at: CGPoint(x: 400, y: 400), moved: CGPoint(x: 60, y: 0), flags: [])
        check(scene.controller.aimAngle == aimBefore, "looking about does not steer the computer's cue")
        check(scene.watchingYaw != yawBefore, "the mouse turns the watcher's own head instead")
        key("x", down: true)
        key("x", down: false)
        key("z", down: true)
        // Across the table rather than into it: a player's body is kept clear of the wood however hard
        // they walk at it, so walking *at* the table from the baulk end goes nowhere.
        scene.steer(at: CGPoint(x: 400, y: 400), moved: CGPoint(x: 80, y: 0), flags: [])
        key("z", down: false)
        let feetAfter = scene.controller.playerPosition
        check(feetAfter.distance(to: feetBefore) > 1,
              "holding Z walks the watcher about (\(Int(feetBefore.x)), \(Int(feetBefore.y)))"
                + " → (\(Int(feetAfter.x)), \(Int(feetAfter.y))), looking \(scene.viewMode)")
        let strokesBeforeWatching = strokes
        step(14)
        check(strokes > strokesBeforeWatching,
              "the computer plays on while the player walks about (played \(strokes - strokesBeforeWatching))")

        // And when it is the **player's** turn the mouse is the cue's again. The seat a human game gives the
        // computer is drawn, so this finds a game the human breaks in rather than waiting for the computer
        // to give the table up: the turn is the player's from the first stroke.
        var thePlayerBreaks = false
        for _ in 0..<40 where !thePlayerBreaks {
            scene.startNewGame(mode: .humanVersusComputer, difficulty: .easy)
            thePlayerBreaks = !scene.isPlayingTheComputer(0)
        }
        check(thePlayerBreaks, "a game against the computer can be found with the player breaking")
        if thePlayerBreaks {
            _ = scene.controller.placeCueBall(at: Vec2(600, Table.centreY))
            step(1)
            check(!scene.controller.isWatching, "the player is not watching when it is their own turn")
            let aim = scene.controller.aimAngle
            scene.steer(at: CGPoint(x: 400, y: 400), moved: CGPoint(x: 60, y: 0), flags: [])
            check(scene.controller.aimAngle != aim,
                  "on the player's own turn the mouse steers the cue again")
        }

        for what in trouble { print("⚠️ \(what)") }
        print(trouble.isEmpty
              ? "the new-game question: the three modes, the difficulty and the pause all behave"
              : "\(trouble.count) of the new-game question's behaviours are wrong")
        return trouble.isEmpty ? 0 : 1
    }

    ///
    /// The one thing the core's tests cannot reach: the window's own scene, driven with the computer at
    /// the table and no window open. It is the same scene the app runs, so what this checks is the whole
    /// of the integration — the decision is asked for off the main thread, the answer comes back, the cue
    /// is put on the ball and the stroke is played — rather than the pieces of it.
    static func computerCheck(options: Options) -> Int32 {
        let scene = TableScene(size: CGSize(width: 1180, height: 760))
        scene.scaleMode = .resizeFill
        // The computer takes the striker's seat: everything the frame asks for from here has to be
        // answered by it, beginning with where to put the cue ball. With `--both` it takes the other seat
        // too, and then the frame is played out entire, which is the whole of what needs checking.
        let aimError = options.cueAction
        scene.setComputerOpponent(true, difficulty: options.difficulty, playing: 0, aimError: aimError)
        if options.bothSeats {
            scene.setComputerOpponent(true, difficulty: options.difficulty, playing: 1,
                                      aimError: aimError)
        }
        guard scene.computerOpponentIsOn else { print("the computer did not take the table"); return 1 }

        let finish = Date().addingTimeInterval(90)
        let started = Date()
        var clock = 0.0
        var strokes = 0
        var wasRunning = false
        var trouble: String?
        var lastSignature = ""
        var lastProgress = Date()
        /// How many of the computer's own strokes ended with a ball it had struck coming back into its own
        /// cue: the stick is on the table while the balls run (`theComputerLooksAfterItsCue` takes it up),
        /// and every one of these is a foul the computer had no business playing.
        var strokesThatHitTheCue = 0

        while Date() < finish {
            clock += 1.0 / 120.0
            scene.update(clock)
            // The answer comes back on the main queue, so the queue has to be given its turn: this is a
            // run loop with nothing in it, which is all the scene needs.
            RunLoop.current.run(until: Date().addingTimeInterval(0.004))

            let controller = scene.controller
            let running = controller.mode == .simulating
            if running, !wasRunning { strokes += 1 }
            if !running, wasRunning, let stroke = controller.lastStroke,
               !stroke.ballsTheCueTouched.isEmpty {
                strokesThatHitTheCue += 1
            }
            wasRunning = running
            if controller.game.state.frameOver { break }
            // One stroke is the whole of what the check is for; once it is over and the table settled,
            // the turn is the other player's and this one has nothing more to do.
            if strokes >= 1, !running, !controller.ballsAreFalling {
                if !options.bothSeats, controller.game.state.currentPlayer != 0 { break }
            }
            // Nothing moving, nothing decided, nothing owed for eight seconds: it is stuck, and the whole
            // point of the check is to catch that rather than to hang.
            let signature = "\(strokes)|\(controller.mode)|\(controller.game.state.currentPlayer)"
                + "|\(controller.game.state.pending != nil)|\(controller.balls.filter(\.onTable).count)"
            if signature != lastSignature {
                lastSignature = signature
                lastProgress = Date()
            } else if Date().timeIntervalSince(lastProgress) > 8 {
                trouble = "nothing has happened for eight seconds"
                break
            }
        }

        let controller = scene.controller
        print([
            "the computer at the table   \(scene.computerOpponentIsOn ? "yes" : "no")",
            "the cue ball                \(controller.cueBall.map { "at \(Int($0.position.x)), \(Int($0.position.y)) \($0.onTable ? "on the table" : "off it")" } ?? "nowhere")",
            "strokes played              \(strokes)",
            "the balls                   \(controller.balls.filter(\.onTable).count) on the table",
            "scores                      \(controller.scores[0]) – \(controller.scores[1])",
            "the frame                   \(controller.isFrameOver ? "over" : "in play"), \(controller.ballOnDescription) on, \(controller.playerNames[controller.game.state.currentPlayer]) to play",
            "the referee                 \(controller.status)",
            "strokes that hit the cue    \(strokesThatHitTheCue) of \(strokes)",
            "wall clock                  \(String(format: "%.1f", Date().timeIntervalSince(started))) s",
        ].joined(separator: "\n"))
        if let trouble { print("⚠️ \(trouble)"); return 1 }
        return strokes >= 1 ? 0 : 1
    }

    ///
    /// Escapes are the one place the player still fouls, and there are two possible reasons for it — the
    /// search cannot find a shot that is there, or there is no shot to find. This tells the two apart. For
    /// positions with nothing on, every line the ray test verified is played out with the real physics and
    /// what happened to it is counted, along with the speculative shots that follow it in the list.
    static func escapeCheck(options: Options) -> Int32 {
        let starts = PositionGenerator.positions(count: options.positions, reds: options.reds,
                                                 seed: options.seed)
        var escapeDecisions = 0
        var verifiedPlayed = 0, verifiedLegal = 0, verifiedPotted = 0
        var guessesPlayed = 0, guessesLegal = 0
        var noVerifiedLine = 0
        var nothingLegal = 0
        var foulsPlayed = 0, strokesPlayed = 0
        var visits = 0
        // The same decisions judged with the cushion routes and without them: the paired answer to whether
        // the routes are worth the rollouts they cost.
        var legalWithRoutes = 0, legalWithoutRoutes = 0, legalBeforeTheWork = 0
        var onlyWith = 0, onlyWithout = 0, neither = 0
        /// What the escape shots that fail actually did, and the powers they were played at: the question
        /// is whether the ones that foul are the ones that never got there.
        var escapesByOutcome: [String: Int] = [:]
        var escapesByPower: [Int: Int] = [:]
        let start = Date()
        var random = SeededRandom(seed: options.seed ^ 0xC0FFEE)
        let unit: () -> Double = { random.unit() }

        for position in starts {
            let driver = FrameDriver(playerNames: ["A", "B"])
            driver.load(position)
            let players = [ComputerPlayer(playerIndex: 0, difficulty: options.difficulty),
                           ComputerPlayer(playerIndex: 1, difficulty: options.difficulty)]
            for player in players { dress(player, with: options, random: unit) }
            var striker = position.currentPlayer
            var steps = 0
            // Played out, because this is where escapes happen: the positions a visit begins from are
            // almost never ones with nothing on, and the ones the game reaches are. Every decision the
            // player answers by escaping is taken apart.
            while !driver.game.state.frameOver, steps < 200 {
                steps += 1
                let state = driver.game.state
                let player = players[state.currentPlayer]
                let action = player.nextAction(for: driver)
                // `lastIntent` is only set by a stroke, so a decision that is a question — a colour to
                // nominate, a cue ball to place — would otherwise be counted as another escape of the
                // position the last stroke was played from.
                if action.isAShot, player.lastIntent == .escape {
                    escapeDecisions += 1
                    let targets = driver.game.legalFirstContacts()
                    let layout = BallLayout(state: state)
                    let candidates = ShotGenerator.escapes(layout: layout, targets: targets,
                                                           settings: player.settings)
                    if !candidates.contains(where: \.verifies) { noVerifiedLine += 1 }
                    var withoutSettings = player.settings
                    withoutSettings.cushionRoutes = false
                    let without = ShotGenerator.escapes(layout: layout, targets: targets,
                                                        settings: withoutSettings)
                    // And as the planner was **before** this turn's work: no routes, and the shorter list
                    // of escapes it used to play out. Two changes were made together, and this separates
                    // them.
                    var beforeSettings = withoutSettings
                    beforeSettings.escapeLimit = 20
                    let before = ShotGenerator.escapes(layout: layout, targets: targets,
                                                       settings: beforeSettings)
                    let withOne = endsWithoutAFoul(candidates, player: player, driver: driver)
                    let withoutOne = endsWithoutAFoul(without, player: player, driver: driver)
                    let beforeOne = endsWithoutAFoul(before, player: player, driver: driver)
                    if withOne { legalWithRoutes += 1 }
                    if withoutOne { legalWithoutRoutes += 1 }
                    if beforeOne { legalBeforeTheWork += 1 }
                    if withOne, !withoutOne { onlyWith += 1 }
                    if withoutOne, !withOne { onlyWithout += 1 }
                    if !withOne, !withoutOne { neither += 1 }
                    var anyLegal = false
                    for candidate in candidates {
                        guard let outcome = player.playOutcome(of: candidate.shot, in: driver) else {
                            continue
                        }
                        let legal = outcome.firstContact.map { targets.contains($0) } ?? false
                        if legal { anyLegal = true }
                        strokesPlayed += 1
                        if outcome.foul != nil { foulsPlayed += 1 }
                        let whatHappened = outcome.foul
                            ?? (legal ? "reached a ball on" : "hit nothing at all")
                        escapesByOutcome[whatHappened, default: 0] += 1
                        escapesByPower[Int((candidate.shot.power * 100).rounded()), default: 0] += 1
                        if candidate.verifies {
                            verifiedPlayed += 1
                            if legal { verifiedLegal += 1 }
                            if !outcome.potted.isEmpty { verifiedPotted += 1 }
                        } else {
                            guessesPlayed += 1
                            if legal { guessesLegal += 1 }
                        }
                    }
                    if !anyLegal { nothingLegal += 1 }
                }
                guard ComputerMatch.apply(action, to: driver) else { break }
                if driver.game.state.frameOver || driver.game.state.currentPlayer != striker {
                    visits += 1
                    striker = driver.game.state.currentPlayer
                }
            }
        }

        func percent(_ part: Int, _ whole: Int) -> String {
            whole == 0 ? "—" : String(format: "%.0f%%", 100 * Double(part) / Double(whole))
        }
        print([
            "escapes met                 \(escapeDecisions) over \(starts.count) positions",
            "lines the ray test verified \(verifiedPlayed) played out, "
                + "\(percent(verifiedLegal, verifiedPlayed)) reached a ball on, "
                + "\(percent(verifiedPotted, verifiedPlayed)) potted one",
            "the guesses after them      \(guessesPlayed) played out, "
                + "\(percent(guessesLegal, guessesPlayed)) reached a ball on",
            "no verified line at all     \(noVerifiedLine) positions",
            "nothing legal on offer      \(nothingLegal) positions — where the player has no choice but to foul",
            "routes on / off             \(legalWithRoutes) / \(legalWithoutRoutes) decisions with a legal"
                + " shot: \(onlyWith) only with them, \(onlyWithout) only without, \(neither) neither",
            "and before this turn's work \(legalBeforeTheWork) decisions had a legal shot",
            String(format: "of every shot tried        %.0f%% fouled", 100 * Double(foulsPlayed) / Double(max(1, strokesPlayed))),
            "wall clock                  \(String(format: "%.1f", Date().timeIntervalSince(start))) s",
        ].joined(separator: "\n"))
        print("every escape shot tried, by what it did:")
        for (what, count) in escapesByOutcome.sorted(by: { $0.value > $1.value }).prefix(5) {
            print(String(format: "  %6d × %@", count, what as NSString))
        }
        print("  played at: " + escapesByPower.sorted { $0.key < $1.key }
            .map { "\($0.key)% × \($0.value)" }.joined(separator: ", "))
        return 0
    }

    /// How far a ball really rolls for the speed it is struck at: the one number the shot arithmetic has
    /// to be calibrated against, measured from the physics rather than assumed.
    static func roll() -> Int32 {
        print("power   speed mm/s   travelled mm   speed needed to travel that far (the estimate)")
        for power in [0.05, 0.08, 0.1, 0.15, 0.2, 0.3, 0.5] {
            let driver = FrameDriver(playerNames: ["Roll", "Roll"])
            driver.game.withState { state in
                state.ballsOnTable = [BallID.cue]
                state.redsRemaining = 0
                state.ballOn = .colourOfSequence(.black)
                state.ballPositions[BallID.cue] = Vec2(60, Table.centreY)
                state.cueBallInHand = false
                state.pending = nil
            }
            driver.syncWorldFromState()
            let from = Vec2(60, Table.centreY)
            driver.shoot(angle: 0, power: power, side: 0, vertical: 0)
            driver.runStrokeToRest()
            guard let end = driver.cueBall?.position else { continue }
            let travelled = end.distance(to: from)
            let speed = power * FrameDriver.maxPower
            print(String(format: "%.2f    %6.0f      %8.0f       %8.0f",
                         power, speed, travelled, ShotGeometry.speedToTravel(travelled)))
        }
        return 0
    }

    /// Plays the shots the geometry proposes for one position and prints what each of them did: the tool
    /// for asking why the computer chose what it chose. The position is the one the shot tests use — the
    /// cue ball in the "D" and one Red dead on the line into the bottom-left corner pocket.
    static func probe() -> Int32 {
        let driver = FrameDriver(playerNames: ["Probe", "Probe"])
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.yellow, BallID.green,
                                  BallID.brown, BallID.blue, BallID.pink, BallID.black]
            state.redsRemaining = 1
            state.ballOn = .red
            state.ballPositions[BallID.firstRed] = Vec2(400, 400)
            state.ballPositions[BallID.cue] = Vec2(737, 737)
            state.cueBallInHand = true
            state.pending = .placeCueBallInD
        }
        driver.syncWorldFromState()
        _ = driver.placeCueBall(at: Vec2(737, 737))

        let settings = ShotGenerator.Settings()
        let layout = BallLayout(state: driver.game.state)
        let targets = driver.game.legalFirstContacts()
        let pots = ShotGenerator.pots(layout: layout, targets: targets, settings: settings)
        print("the geometry offers \(pots.count) pots and \(ShotGenerator.safeties(layout: layout, targets: targets, settings: settings).count) safeties from here")

        var toPlay: [(String, Shot)] = pots.prefix(4).map { ($0.intent.summary, $0.shot) }
        if let straight = pots.first {
            // Where the pot actually comes on, which is the number the estimate has to land under.
            for power in stride(from: 0.10, through: 0.20, by: 0.01) {
                var shot = straight.shot
                shot.power = power
                toPlay.append(("straight pot at power \(String(format: "%.2f", power))", shot))
            }
        }

        let computer = ComputerPlayer(playerIndex: 0)
        for (name, shot) in toPlay {
            guard let outcome = computer.playOutcome(of: shot, in: driver) else {
                print("\(name): could not be played")
                continue
            }
            let potted = outcome.potted.isEmpty ? "—" : outcome.potted.map { "\($0)" }.joined(separator: ",")
            print(name.padding(toLength: 42, withPad: " ", startingAt: 0)
                  + shot.describedForTheLog.padding(toLength: 52, withPad: " ", startingAt: 0)
                  + "potted \(potted.padding(toLength: 10, withPad: " ", startingAt: 0))"
                  + "foul \(outcome.foul ?? "—")"
                  + "  points \(outcome.points)"
                  + (outcome.cueBallPotted ? "  CUE BALL POTTED" : "")
                  + (outcome.opponentSnookered ? "  opponent snookered" : "")
                  + String(format: "  value %.2f", outcome.value))
        }
        return 0
    }

    /// Times the one thing the search spends its time on: playing a shot out on a copy of the frame.
    static func benchmark(shots count: Int) -> Int32 {
        let driver = FrameDriver(playerNames: ["Benchmark", "Benchmark"])
        guard driver.placeCueBall(at: Vec2(Table.baulkLineX - 200, Table.centreY)) else {
            print("could not place the cue ball")
            return 1
        }
        let player = ComputerPlayer(playerIndex: 0, difficulty: .medium)
        let shots = max(1, count)
        var played = 0
        let start = Date()
        for i in 0..<shots {
            // A spread of aims, so that the strokes are not all the same one: a shot that pots and a
            // shot that does not are not the same work.
            let angle = 2 * Double.pi * Double(i) / Double(shots)
            let shot = Shot(angle: angle, power: i % 3 == 0 ? 0.25 : 0.7)
            if player.valueOfPlaying(shot, in: driver) != nil { played += 1 }
        }
        let elapsed = Date().timeIntervalSince(start)
        let each = 1000 * elapsed / Double(shots)
        print(String(format: "%d shots played out in %.2f s — %.2f ms a shot", shots, elapsed, each))
        print(String(format: "a decision of 30 shots would be %.2f s; of 100 shots, %.2f s; of 300, %.2f s",
                     0.03 * each, 0.1 * each, 0.3 * each))
        return played == shots ? 0 : 1
    }
}
