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
    private static func describeThePlan(of url: URL, configuration: MLModelConfiguration) {
        guard #available(macOS 14.4, *) else { return }
        var counts: [String: Int] = [:]
        let done = DispatchSemaphore(value: 0)
        Task {
            defer { done.signal() }
            do {
                let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
                guard case .program(let program) = plan.modelStructure,
                      let main = program.functions["main"] else { return }
                for operation in main.block.operations {
                    switch plan.deviceUsage(for: operation)?.preferred {
                    case .neuralEngine: counts["the Neural Engine", default: 0] += 1
                    case .gpu: counts["the GPU", default: 0] += 1
                    case .cpu: counts["the CPU", default: 0] += 1
                    default: counts["nothing", default: 0] += 1
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
        print("the model: \(summary)")
    }

}
