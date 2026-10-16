import Foundation

/// A small reproducible generator: splitmix64, a dozen lines, good enough for laying balls out at random
/// and **the same way every time**. Everything the computer player generates — positions to learn from,
/// positions to measure on, the odd shot it plays off its own line — is taken from one of these, so a
/// dataset or a measurement can be had again exactly.
public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64) {
        state = seed &+ 0x9E37_79B9_7F4A_7C15
    }

    public mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    /// A number in 0..<1.
    public mutating func unit() -> Double {
        Double(next() >> 11) * (1.0 / 9_007_199_254_740_992.0)
    }

    /// A number in `range`.
    public mutating func value(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + unit() * (range.upperBound - range.lowerBound)
    }

    /// True with probability `p`.
    public mutating func chance(_ p: Double) -> Bool {
        unit() < p
    }

    public mutating func index(_ count: Int) -> Int {
        count <= 1 ? 0 : min(count - 1, Int(unit() * Double(count)))
    }
}

/// The normal distribution, for the small errors a player makes without meaning to.
public enum Normal {
    /// One sample, by the **Box–Muller transform**: two independent uniforms in 0..<1 become one draw from
    /// a normal distribution. `uniform` is asked for both of them, in that order, so a caller that seeds
    /// one generator gets a run of errors that can be had again.
    ///
    /// (The other half of the transform — the sine — is thrown away. A second sample for the price of the
    /// same two uniforms is not worth the state it would take to keep, when the thing being drawn is how
    /// far off the line one shot was.)
    public static func sample(mean: Double = 0, standardDeviation: Double = 1,
                              using uniform: () -> Double) -> Double {
        // Zero takes the logarithm to negative infinity, so the draws are kept off both ends.
        let first = min(max(uniform(), 1e-12), 1 - 1e-12)
        let second = uniform()
        let radius = (-2 * log(first)).squareRoot()
        return mean + standardDeviation * radius * cos(2 * Double.pi * second)
    }
}

/// Positions to learn from and to measure on: a frame's worth of balls, laid out at random, with the
/// rules told what is on and who is at the table.
///
/// Whole frames are a poor diet for either purpose. A frame played by two good players is mostly similar
/// positions — a break being built — and it is the *same* positions every time, because the game is
/// deterministic. A position generator puts balls where a frame rarely does, which is what makes a
/// measurement mean something and what stops a network learning the shape of one break.
///
/// What comes out is a position the rules engine accepts: every ball on the cloth and clear of every
/// other, the cue ball in play, the reds remaining counted off the table, a ball on that matches what is
/// left, and a player at the table.
public enum PositionGenerator {

    /// `count` positions, each with `reds` reds on the table, from one seed.
    public static func positions(count: Int, reds: Int = 15, seed: UInt64) -> [GameState] {
        var generator = SeededRandom(seed: seed)
        return (0..<max(0, count)).map { _ in random(reds: reds, using: &generator) }
    }

    /// One position, laid out with `random`.
    public static func random(reds: Int, using random: inout SeededRandom) -> GameState {
        var state = SnookerGame(playerNames: ["A", "B"], reds: max(0, min(15, reds))).state

        // Every ball somewhere of its own: a ball's centre has to be on the cloth (a radius inside the
        // cushion line) and a diameter clear of every other ball. Nothing else is required of it — a
        // position a frame would never reach is exactly what is wanted.
        let margin = Table.ballRadius + 1
        var placed: [Vec2] = []
        for id in state.ballsOnTable.sorted() {
            for _ in 0..<400 {
                let point = Vec2(margin + random.unit() * (Table.length - 2 * margin),
                                 margin + random.unit() * (Table.width - 2 * margin))
                if placed.contains(where: { $0.distance(to: point) < Table.ballDiameter + 2 }) { continue }
                placed.append(point)
                state.ballPositions[id] = point
                break
            }
        }

        let redsOnTheTable = state.ballsOnTable.filter { $0 >= BallID.firstRed && $0 <= BallID.lastRed }
        state.redsRemaining = redsOnTheTable.count
        state.currentPlayer = random.chance(0.5) ? 0 : 1
        state.breakScore = 0
        state.cueBallInHand = false
        state.pending = nil
        state.frameOver = false
        state.winner = nil
        state.nominatedColour = nil
        state.freeBallNominee = nil
        state.freeBallAvailable = false
        state.missCount = 0
        state.missWarning = false
        state.commentary = []
        state.scores = [0, 0]

        // What is on: mostly a Red while there are Reds, sometimes a colour of the striker's own choice,
        // and the next colour in the sequence once the Reds are gone.
        if !redsOnTheTable.isEmpty && random.chance(0.75) {
            state.ballOn = .red
        } else if redsOnTheTable.isEmpty || random.chance(0.4) {
            state.ballOn = .colourOfSequence(nextColour(in: state) ?? .black)
        } else {
            state.ballOn = .anyColour
        }
        return state
    }

    /// The next colour in the sequence that is still on the table.
    private static func nextColour(in state: GameState) -> BallColor? {
        BallColor.coloursInAscendingOrder.first { colour in
            guard let id = BallID.colourID(colour) else { return false }
            return state.ballsOnTable.contains(id)
        }
    }
}
