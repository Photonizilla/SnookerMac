import Foundation
import CoreML
import SnookerCore

/// The learned value function, when there is one to hand: a small network that reads a position's
/// features and answers with the points the player at the table is expected to score from it.
///
/// It lives in the app rather than in `SnookerCore` on purpose. The core is pure logic — physics, rules,
/// the search — and can be tested without a model file; the app is what knows how to load a Core ML
/// model, and it hands the player a plain closure. A build with no model in it is the player the game
/// has always had.
enum LearnedValue {

    /// Loads a model and returns the function the player asks for, or nil if it will not load.
    ///
    /// `computeUnits: .cpuAndNeuralEngine` is the whole point of doing this on a Mac: Core ML puts the
    /// network where it runs best out of the two, and `describe` reports where it went. It is asked for a
    /// **compiled** model (`.mlmodelc`) or a package to compile on the spot, so that the harness can be
    /// pointed at a freshly exported `.mlpackage` without adding it to the project first.
    static func load(path: String, describe: Bool = true) -> ((PositionFeatures) -> Double)? {
        let source = URL(fileURLWithPath: path)
        do {
            let compiled = source.pathExtension == "mlmodelc"
                ? source
                : try MLModel.compileModel(at: source)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: compiled, configuration: configuration)
            if describe { describeThePlan(of: compiled, configuration: configuration) }
            let shape = [1, NSNumber(value: PositionFeatures.count)]
            return { features in
                guard let input = try? MLMultiArray(shape: shape, dataType: .float32) else { return 0 }
                for (index, value) in features.values.enumerated() {
                    input[index] = NSNumber(value: value)
                }
                let provider = try? MLDictionaryFeatureProvider(
                    dictionary: ["position": MLFeatureValue(multiArray: input)])
                guard let provider,
                      let output = try? model.prediction(from: provider),
                      let value = output.featureValue(for: "value") else { return 0 }
                if let array = value.multiArrayValue, array.count > 0 {
                    return array[0].doubleValue
                }
                return value.doubleValue
            }
        } catch {
            print("could not load the learned value from \(path): \(error)")
            return nil
        }
    }

    /// Asks Core ML where the model's operations would run — the Neural Engine, the GPU or the CPU — and
    /// says so. It is the difference between a model that is *allowed* on the Neural Engine and one that
    /// is actually put there: an operation Core ML cannot hand to it takes the whole graph off it.
    static func describeThePlan(of url: URL, configuration: MLModelConfiguration) {
        guard #available(macOS 14.4, *) else { return }
        var counts: [String: Int] = [:]
        var allowed: [String: Int] = [:]
        let done = DispatchSemaphore(value: 0)
        Task {
            defer { done.signal() }
            do {
                let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
                guard case .program(let program) = plan.modelStructure,
                      let main = program.functions["main"] else { return }
                for operation in main.block.operations {
                    let usage = plan.deviceUsage(for: operation)
                    switch usage?.preferred {
                    case .neuralEngine: counts["the Neural Engine", default: 0] += 1
                    case .gpu: counts["the GPU", default: 0] += 1
                    case .cpu: counts["the CPU", default: 0] += 1
                    default: counts["nothing", default: 0] += 1
                    }
                    // What the operation **could** run on, which is the other half of the answer: a
                    // preferred CPU with the Neural Engine supported is a cost decision, not a refusal.
                    for device in usage?.supported ?? [] {
                        switch device {
                        case .neuralEngine: allowed["the Neural Engine", default: 0] += 1
                        case .gpu: allowed["the GPU", default: 0] += 1
                        case .cpu: allowed["the CPU", default: 0] += 1
                        @unknown default: allowed["something else", default: 0] += 1
                        }
                    }
                }
            } catch {
                counts["unknown (\(error))"] = 1
            }
        }
        guard done.wait(timeout: .now() + 20) == .success else {
            print("the model: Core ML did not answer in time about where it would run")
            return
        }
        let summary = counts.sorted { $0.value > $1.value }
            .map { "\($0.value) on \($0.key)" }
            .joined(separator: ", ")
        let support = allowed.sorted { $0.value > $1.value }
            .map { "\($0.value) can run on \($0.key)" }
            .joined(separator: ", ")
        print("the model: \(summary)" + (support.isEmpty ? "" : "; \(support)"))
    }

}

/// The learned **policy**: a network that reads a position — every ball on the table, the ball on, the
/// score — and answers with the whole stroke. The angle, the strength, both spins and the lift are each
/// the network's, and the search is not asked for a shot while one is loaded.
///
/// The model is a Core ML program with one input (`position`, `PositionFeatures`) and one output (`shot`):
/// `sin(angle), cos(angle), power, side, vertical, elevation ÷ 45°`. The angle is a pair rather than a
/// number so that the wrap at ±180° is not a cliff for the network to fall off; the pair is normalised at
/// inference and turned back into an angle with `atan2`.
enum LearnedPolicy {

    /// The lift the sixth output is scaled by: the search's own lifts run to 20°, and this leaves room
    /// without asking a network for a cue stood on end.
    static let maximumLift = 45 * Double.pi / 180

    /// Loads a policy and returns the function the player asks for, or nil if it will not load.
    static func load(path: String, describe: Bool = true) -> ((PositionFeatures) -> Shot?)? {
        let source = URL(fileURLWithPath: path)
        do {
            let compiled = source.pathExtension == "mlmodelc"
                ? source
                : try MLModel.compileModel(at: source)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: compiled, configuration: configuration)
            if describe { LearnedValue.describeThePlan(of: compiled, configuration: configuration) }
            let shape = [1, NSNumber(value: PositionFeatures.count)]
            return { features in
                guard let input = try? MLMultiArray(shape: shape, dataType: .float32) else { return nil }
                for (index, value) in features.values.enumerated() {
                    input[index] = NSNumber(value: value)
                }
                guard let provider = try? MLDictionaryFeatureProvider(
                        dictionary: ["position": MLFeatureValue(multiArray: input)]),
                      let output = try? model.prediction(from: provider),
                      let shot = output.featureValue(for: "shot")?.multiArrayValue,
                      shot.count >= 6 else { return nil }
                return Shot(angle: atan2(shot[0].doubleValue, shot[1].doubleValue),
                            power: shot[2].doubleValue,
                            side: shot[3].doubleValue,
                            vertical: shot[4].doubleValue,
                            elevation: shot[5].doubleValue * maximumLift)
            }
        } catch {
            print("could not load the learned policy from \(path): \(error)")
            return nil
        }
    }

    /// The **all-decisions** model: one Core ML program whose output is the twelve action logits, the six
    /// stroke numbers, the sixty-four placement logits and the six colour logits — 88 numbers. The masks in
    /// the situation are applied to the logits here, so what comes back is an action the rules allow, with
    /// every number of the stroke the network's.
    static func loadEverything(path: String, describe: Bool = true)
        -> ((PolicySituation) -> ComputerPlayer.Action?)? {
        let source = URL(fileURLWithPath: path)
        do {
            let compiled = source.pathExtension == "mlmodelc"
                ? source
                : try MLModel.compileModel(at: source)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: compiled, configuration: configuration)
            if describe { LearnedValue.describeThePlan(of: compiled, configuration: configuration) }
            let shape = [1, NSNumber(value: PolicySituation.count)]
            let colours = BallColor.coloursInAscendingOrder
            return { situation in
                guard let input = try? MLMultiArray(shape: shape, dataType: .float32) else { return nil }
                let values = situation.values
                for (index, value) in values.enumerated() { input[index] = NSNumber(value: value) }
                guard let provider = try? MLDictionaryFeatureProvider(
                        dictionary: ["position": MLFeatureValue(multiArray: input)]),
                      let output = try? model.prediction(from: provider),
                      let decision = output.featureValue(for: "decision")?.multiArrayValue,
                      decision.count >= 88 else { return nil }
                func numbers(from start: Int, count: Int) -> [Double] {
                    (0..<count).map { decision[start + $0].doubleValue }
                }
                func best(_ logits: [Double], maskedBy mask: [Float]) -> Int? {
                    var bestIndex: Int?
                    var bestValue = -Double.greatestFiniteMagnitude
                    for (index, value) in logits.enumerated() where index < mask.count && mask[index] > 0 {
                        if value > bestValue { bestValue = value; bestIndex = index }
                    }
                    return bestIndex
                }
                let kind = best(numbers(from: 0, count: PolicySituation.actionCount).map { $0 },
                                maskedBy: situation.actions)
                guard let kind else { return nil }
                let stroke = numbers(from: PolicySituation.actionCount, count: 6)
                guard stroke.count == 6 else { return nil }
                let shot = Shot(angle: atan2(stroke[0], stroke[1]),
                                power: stroke[2], side: stroke[3], vertical: stroke[4],
                                elevation: stroke[5] * maximumLift)
                switch kind {
                case 0:
                    return .shoot(ComputerPlayer.legalShot(shot))
                case 1:
                    let placementStart = PolicySituation.actionCount + 6
                    let cells = numbers(from: placementStart, count: PolicySituation.placementCount)
                    guard let cell = best(cells, maskedBy: situation.placements) else { return nil }
                    return .placeCueBall(PolicySituation.placementPoint(cell))
                case 2, 3:
                    let colourStart = PolicySituation.actionCount + 6 + PolicySituation.placementCount
                    let mask = kind == 3 ? situation.freeBalls : situation.colours
                    guard let index = best(numbers(from: colourStart, count: colours.count),
                                           maskedBy: mask), index < colours.count else { return nil }
                    return kind == 3 ? .takeAFreeBall(colours[index]) : .nominateColour(colours[index])
                case 4: return .declineTheFreeBall
                case 5: return .playFromHere
                case 6: return .askTheOffenderToPlayAgain
                case 7: return .replaceTheBalls
                case 8: return .claimTheFrame
                case 9: return .reRack
                default: return nil
                }
            }
        } catch {
            print("could not load the all-decisions policy from \(path): \(error)")
            return nil
        }
    }

    /// The **candidate-conditioned** model: one position and one proposed shot in, a score and the stroke
    /// out. Every candidate is scored, and the highest-scoring one supplies the shot the network gives —
    /// the geometry only proposed the lines.
    static func loadCandidate(path: String, describe: Bool = true)
        -> ((PolicySituation, [ShotCandidate]) -> Shot?)? {
        let source = URL(fileURLWithPath: path)
        do {
            let compiled = source.pathExtension == "mlmodelc"
                ? source
                : try MLModel.compileModel(at: source)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .cpuAndNeuralEngine
            let model = try MLModel(contentsOf: compiled, configuration: configuration)
            if describe { LearnedValue.describeThePlan(of: compiled, configuration: configuration) }
            let shape = [1, NSNumber(value: PolicySituation.candidateCount)]
            return { situation, candidates in
                var bestScore = -Double.greatestFiniteMagnitude
                var bestShot: Shot?
                for candidate in candidates {
                    guard let input = try? MLMultiArray(shape: shape, dataType: .float32) else {
                        continue
                    }
                    for (index, value) in situation.candidateValues(candidate).enumerated() {
                        input[index] = NSNumber(value: value)
                    }
                    guard let provider = try? MLDictionaryFeatureProvider(
                            dictionary: ["position": MLFeatureValue(multiArray: input)]),
                          let output = try? model.prediction(from: provider),
                          let choice = output.featureValue(for: "decision")?.multiArrayValue,
                          choice.count >= 7 else { continue }
                    let score = choice[0].doubleValue
                    if score > bestScore {
                        bestScore = score
                        bestShot = Shot(angle: atan2(choice[1].doubleValue, choice[2].doubleValue),
                                        power: choice[3].doubleValue,
                                        side: choice[4].doubleValue,
                                        vertical: choice[5].doubleValue,
                                        elevation: choice[6].doubleValue * maximumLift)
                    }
                }
                return bestShot
            }
        } catch {
            print("could not load the candidate policy from \(path): \(error)")
            return nil
        }
    }
}
