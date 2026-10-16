import Foundation

/// Two computers playing a frame out, with nobody at the table.
///
/// This is the whole of what a caller needs to run the player: it asks whoever is at the table what to
/// do, does it, and carries on until the frame is over. It is headless on purpose — there is no window
/// and no clock in it — and it is where the player is measured, because a player that cannot answer a
/// question or find a legal shot shows up here at once as a frame that stops.
public enum ComputerMatch {

    /// What happened, as it happened: enough for a log, a tally or a picture, and nothing the caller has
    /// to know the rules to read.
    public enum Event: Sendable {
        /// The computer answered a question or settled on a plan in words.
        case action(player: Int, description: String)
        /// A stroke was played and adjudicated.
        case stroke(player: Int, number: Int, description: String, potted: Int,
                    foul: String?, missCalled: Bool, scores: [Int], breakScore: Int)
        case frameOver(winner: Int?, scores: [Int])
        /// The player could not find anything to do. A frame that ends this way is a bug worth seeing.
        case trouble(String)
    }

    public struct Report: Sendable {
        public var strokes = 0
        public var pots = 0
        public var fouls = 0
        public var misses = 0
        public var highestBreak = [0, 0]
        public var scores = [0, 0]
        public var winner: Int?
        public var finished = false
        public var rollouts = 0
        public var trouble: [String] = []
    }

    @discardableResult
    /// Carries out one of the computer's decisions on a frame.
    ///
    /// It goes through the **driver's own** controls rather than the rules engine's, because the driver is
    /// what decides whether the striker may play at all: a colour nominated straight into the game leaves
    /// the frame still asking the question, and a stroke that cannot be played looks exactly like one
    /// that has been. Returns false when the frame would not take the decision.
    public static func apply(_ action: ComputerPlayer.Action, to driver: FrameDriver) -> Bool {
        switch action {
        case .wait:
            return false
        case .placeCueBall(let point):
            return driver.placeCueBall(at: point)
        case .nominateColour(let colour):
            driver.chooseColour(colour)
            return true
        case .takeAFreeBall(let colour):
            driver.chooseFreeBall(colour)
            return true
        case .declineTheFreeBall:
            driver.declineFreeBall()
            return true
        case .playFromHere:
            driver.playFromPositionLeft()
            return true
        case .askTheOffenderToPlayAgain:
            driver.askOffenderToPlayAgain()
            return true
        case .replaceTheBalls:
            driver.requestOriginalPosition()
            return true
        case .claimTheFrame:
            driver.claimTheFrame()
            return true
        case .reRack:
            // Section 3 Rule 17: a position neither player can make anything of is begun again. The
            // computer asks for it when it has been fouling at the same position for long enough.
            driver.reRack()
            return true
        case .shoot(let shot):
            // Played the way a player plays it — a charge and the cue action it leaves behind — so that a
            // frame played out headless is the same game as one played at the table.
            guard driver.playCharged(shot, at: Date().timeIntervalSinceReferenceDate) else { return false }
            driver.runStrokeToRest()
            return true
        }
    }

    @discardableResult
    public static func playFrame(firstPlayer: Int = 0,
                                 difficulty: ComputerPlayer.Difficulty = .medium,
                                 strokeLimit: Int = 900,
                                 configure: ((ComputerPlayer) -> Void)? = nil,
                                 observe: (Event) -> Void = { _ in }) -> Report {
        let driver = FrameDriver(playerNames: ["Computer A", "Computer B"])
        driver.game.decideTheDraw = { firstPlayer }
        let players = [ComputerPlayer(playerIndex: 0, difficulty: difficulty),
                       ComputerPlayer(playerIndex: 1, difficulty: difficulty)]
        for player in players {
            player.decideTheDraw = { firstPlayer }
            configure?(player)
        }

        var report = Report()
        var idle = 0
        var number = 0

        frame: while !driver.game.state.frameOver, report.strokes < strokeLimit {
            let index = driver.game.state.currentPlayer
            let player = players[index]
            let action = player.nextAction(for: driver)
            report.rollouts += player.rolloutsLastDecision

            func note(_ text: String) {
                observe(.action(player: index, description: text))
            }
            func trouble(_ text: String) {
                report.trouble.append(text)
                observe(.trouble("\(driver.playerNames[index]): \(text)"))
            }

            switch action {
            case .wait:
                idle += 1
                if idle > 6 {
                    trouble("nothing to do in mode \(driver.mode)")
                    break frame
                }
                continue

            case .shoot(let shot):
                idle = 0
                guard ComputerMatch.apply(action, to: driver) else {
                    trouble("the shot could not be played: \(shot.describedForTheLog)")
                    break frame
                }
                number += 1
                let state = driver.game.state
                let result = driver.lastResult
                let potted = (driver.lastStroke?.potted ?? []).filter { $0 != BallID.cue }.count
                report.strokes += 1
                report.pots += potted
                if result?.foul != nil { report.fouls += 1 }
                if result?.missCalled == true { report.misses += 1 }
                report.scores = state.scores
                for who in 0...1 {
                    report.highestBreak[who] = max(report.highestBreak[who],
                                                   state.players[who].highestBreak)
                }
                observe(.stroke(player: index, number: number, description: player.lastPlan,
                                potted: potted, foul: result?.foul?.reason,
                                missCalled: result?.missCalled ?? false,
                                scores: state.scores, breakScore: state.breakScore))

            default:
                idle = 0
                guard ComputerMatch.apply(action, to: driver) else {
                    trouble("the frame would not take the decision: \(action)")
                    break frame
                }
                note(player.lastPlan.isEmpty ? "\(action)" : player.lastPlan)
            }
        }

        report.scores = driver.game.state.scores
        report.winner = driver.game.state.winner
        report.finished = driver.game.state.frameOver
        observe(.frameOver(winner: report.winner, scores: report.scores))
        return report
    }
}
