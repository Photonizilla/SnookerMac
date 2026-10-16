import Foundation

/// A position as the learned part of the player sees it: a fixed-length vector of numbers, one for every
/// thing about the table that could matter, each scaled into a small range.
///
/// It is deliberately a **flat vector rather than a picture**. What decides whether a shot is on is not
/// how the table looks but the geometry between the balls, and the geometry is exactly what the features
/// carry: where every ball is, whether the cue ball can see it, and how hard the pots are from here. The
/// same features are what the hand-written value function reads, so a network trained on them starts
/// from everything the search knows and only has to learn what to do with it.
///
/// Every number is scaled so that a position's features are all of order one: distances by the table,
/// scores by a frame, counts by how many there can be. The vector is **always from the point of view of
/// the player at the table** — the score difference is theirs, the ball on is theirs — so a value the
/// network predicts means the same thing wherever the position came from.
public struct PositionFeatures: Sendable {
    /// Every ball the game has, in `BallID` order: the cue ball, the fifteen reds, the six colours.
    public static let ballCount = 22
    /// What is said about each of them.
    public static let perBall = 6
    /// What is said about the frame.
    public static let globals = 20
    public static let count = ballCount * perBall + globals

    public var values: [Float]

    public init(values: [Float]) {
        self.values = values
    }

    /// A position's features, from the point of view of the striker.
    ///
    /// `aimError` is how fallible the player whose value this is — the standard deviation of its aim error
    /// in radians — and it is a feature because **a position is worth less to a player who misses**. A
    /// break-building cue action scores from a hard position that a wild one scores nothing from, so a
    /// value function that does not know which of the two it is answering for can only answer for the
    /// average. Left at nothing, the answer is the one for a player who never misses.
    public static func of(_ state: GameState, aimError: Double = 0) -> PositionFeatures {
        var values = [Float](repeating: 0, count: count)
        let layout = BallLayout(state: state)
        let cue = layout.cue
        let targets = ShotGenerator.targets(in: state)

        // The pots that are on, and which ball each of them is for: the geometry the whole planner is
        // built on, in the form a network can be given.
        let pots = targets.isEmpty ? [] : ShotGenerator.pots(layout: layout, targets: targets,
                                                            settings: .quick)
        var bestPotFor: [Int: Double] = [:]
        for pot in pots {
            guard case .pot(let ball, _, _) = pot.intent else { continue }
            bestPotFor[ball] = min(bestPotFor[ball] ?? 1, pot.ease)
        }

        for slot in 0..<ballCount {
            let id = slot == 0 ? BallID.cue : (slot <= BallID.lastRed ? slot : ballIDForColourSlot(slot))
            let base = slot * perBall
            guard let position = layout.position(of: id) else { continue }
            values[base] = 1
            values[base + 1] = Float(position.x / Table.length)
            values[base + 2] = Float(position.y / Table.width)
            if id != BallID.cue {
                values[base + 3] = Float(min(1, cue.distance(to: position) / 4000))
                let others = layout.leavingOut([BallID.cue, id])
                values[base + 4] = ShotGeometry.isClearPath(from: cue, to: position, past: others)
                    ? 1 : 0
                values[base + 5] = Float(min(1, bestPotFor[id] ?? 1))
            }
        }

        var g = ballCount * perBall
        func put(_ value: Double) {
            values[g] = Float(value)
            g += 1
        }
        put(Double(state.redsRemaining) / 15)
        switch state.ballOn {
        case .red:
            put(1); put(0); put(0)
        case .anyColour:
            put(0); put(1); put(0)
        case .colourOfSequence(let colour):
            put(0); put(0); put(Double(colour.value) / 7)
        }
        put(Double(state.nominatedColour?.value ?? 0) / 7)
        put(Double(state.freeBallNominee?.value ?? 0) / 7)
        put(state.cueBallInHand ? 1 : 0)
        let me = state.currentPlayer
        let them = 1 - me
        put(min(1, max(-1, Double(state.scores[me] - state.scores[them]) / 50)))
        put(Double(state.scores[me]) / 147)
        put(Double(state.breakScore) / 50)
        let game = rules(state)
        put(Double(game.remainingPoints()) / 147)
        put(game.isSnookered() ? 1 : 0)
        put(min(1, Double(pots.first?.ease ?? 1)))
        put(Double(targets.count) / 15)
        put(Double(pots.filter { $0.ease < 0.3 }.count) / 10)
        put(cue.x / Table.length)
        put(cue.y / Table.width)
        let toTheNearestCushion = min(cue.x, Table.length - cue.x, cue.y, Table.width - cue.y)
        put(min(1, toTheNearestCushion / 1000))
        put(Double(state.ballsOnTable.filter { id in
            guard id != BallID.cue, let position = layout.position(of: id) else { return false }
            return position.distance(to: cue) < 200
        }.count) / 5)
        put(min(1, (aimError * 180 / Double.pi) / 0.5))
        return PositionFeatures(values: values)
    }

    /// The ball a slot in the vector stands for: the cue ball, then the reds in order, then the colours.
    private static func ballIDForColourSlot(_ slot: Int) -> Int {
        let colours = BallColor.coloursInAscendingOrder
        let index = min(colours.count - 1, max(0, slot - 16))
        return BallID.colourID(colours[index]) ?? BallID.yellow
    }

    /// The rules engine's own view of a position, for the questions that need it.
    private static func rules(_ state: GameState) -> SnookerGame {
        let game = SnookerGame()
        game.withState { $0 = state }
        return game
    }
}
