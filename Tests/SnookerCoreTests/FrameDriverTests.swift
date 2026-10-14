import XCTest
@testable import SnookerCore

/// End-to-end tests: place the cue ball, aim, shoot, simulate and adjudicate.
final class FrameDriverTests: XCTestCase {

    private func driver() -> FrameDriver {
        FrameDriver(playerNames: ["A", "B"])
    }

    /// Sets up a position with only the cue ball and one Red, both on the diagonal
    /// line that runs into the bottom-left corner pocket.
    private func pottedRedSetup() -> FrameDriver {
        let d = driver()
        d.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed,
                                  BallID.yellow, BallID.green, BallID.brown,
                                  BallID.blue, BallID.pink, BallID.black]
            state.redsRemaining = 1
            state.ballOn = .red
            state.ballPositions[BallID.firstRed] = Vec2(400, 400)
            state.ballPositions[BallID.cue] = Vec2(737, 737)
            state.cueBallInHand = true
            state.pending = .placeCueBallInD
        }
        d.syncWorldFromState()
        XCTAssertTrue(d.placeCueBall(at: Vec2(737, 737)))
        return d
    }

    func testNewFrameAwaitsTheCueBallInTheD() {
        let d = driver()
        XCTAssertEqual(d.mode, .placingCueBall)
        XCTAssertTrue(d.game.state.cueBallInHand)
        XCTAssertFalse(d.placeCueBall(at: Vec2(2000, 889)), "outside the D is not allowed")
    }

    /// `N` does not throw the frame away by itself: it asks first, and the frame in progress is only
    /// replaced when the player says so. A slip of the hand therefore costs nothing.
    func testANewFrameIsAskedAboutBeforeItIsStarted() {
        let d = driver()
        XCTAssertTrue(d.placeCueBall(at: Vec2(600, 889)))
        d.shoot(angle: 0, power: 0.5, side: 0, vertical: 0)
        d.runStrokeToRest()
        let ballsBefore = d.balls.map(\.position)
        let scoresBefore = d.scores

        d.askToStartANewFrame()
        XCTAssertTrue(d.isAskingAboutANewFrame, "the game asks")
        XCTAssertEqual(d.balls.map(\.position), ballsBefore, "and nothing moves while it asks")
        XCTAssertEqual(d.scores, scoresBefore)
        XCTAssertFalse(d.canStrike, "and no stroke can be played over the question")

        d.keepPlaying()
        XCTAssertFalse(d.isAskingAboutANewFrame, "keeping the frame puts the question away")
        XCTAssertEqual(d.balls.map(\.position), ballsBefore, "with the frame exactly as it was")
        XCTAssertEqual(d.scores, scoresBefore)

        // The break was a foul, so the scores are not level: answering the question yes is the way a frame
        // still in progress ends — the player behind concedes it. See
        // `testANewFrameIsConcededByThePlayerWithFewerPoints` and, for level scores,
        // `testANewFrameWithTheScoresLevelIsAReRack`.
        XCTAssertEqual(scoresBefore, [0, 4])
        d.askToStartANewFrame()
        d.startTheNewFrame()
        XCTAssertFalse(d.isAskingAboutANewFrame)
        XCTAssertEqual(d.scores, [0, 0], "and answering it racks the frame fresh")
        XCTAssertEqual(d.frameNumber, 2, "the frame that was on is settled, and the next one is racked")
        XCTAssertEqual(d.mode, .placingCueBall)
        XCTAssertTrue(d.game.state.cueBallInHand)
    }

    /// `N` while the frame is on ends it by **concession**: the player with fewer points is the one who
    /// concedes, so the frame is counted for the other, and the next frame is racked. The question says
    /// which of the two it will be before it is answered.
    func testANewFrameIsConcededByThePlayerWithFewerPoints() {
        let d = driver()                                        // the players are "A" and "B"
        XCTAssertTrue(d.placeCueBall(at: Vec2(600, 889)))
        d.game.withState { $0.scores = [40, 20] }               // B is behind

        XCTAssertEqual(d.whatANewFrameMeans, "B concedes to A at 40-20, and frame 2 is racked.")

        d.askToStartANewFrame()
        d.startTheNewFrame()
        XCTAssertFalse(d.isAskingAboutANewFrame)
        XCTAssertEqual(d.framesWon, [1, 0], "the frame is counted for the player it was conceded to")
        XCTAssertEqual(d.frameNumber, 2, "and the next frame of the match is racked")
        XCTAssertEqual(d.scores, [0, 0])
        XCTAssertTrue(d.commentary.contains { $0.contains("concedes") },
                      "and the referee's own line about the concession is kept")
    }

    /// With the scores level there is nobody behind to concede the frame, so `N` re-racks it instead: the
    /// same frame of the match, nothing won, the scores at nothing.
    func testANewFrameWithTheScoresLevelIsAReRack() {
        let d = driver()
        XCTAssertTrue(d.placeCueBall(at: Vec2(600, 889)))
        d.game.withState { $0.scores = [12, 12] }

        XCTAssertEqual(d.whatANewFrameMeans,
                       "The scores are level at 12-12, so the frame is re-racked: nothing is won.")

        d.askToStartANewFrame()
        d.startTheNewFrame()
        XCTAssertEqual(d.frameNumber, 1, "a re-rack is the same frame")
        XCTAssertEqual(d.framesWon, [0, 0], "and nothing is won")
        XCTAssertEqual(d.scores, [0, 0])
        XCTAssertEqual(d.mode, .placingCueBall)
    }

    /// Sets up the last Black for the player at the table, pots it, and leaves the frame ended.
    private func potTheLastBlack(_ d: FrameDriver) {
        d.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.black]
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.black)
            state.cueBallInHand = false
            state.pending = nil
            state.scores = [60, 20]
            state.ballPositions[BallID.cue] = Vec2(737, 737)
            state.ballPositions[BallID.black] = Vec2(400, 400)
        }
        d.syncWorldFromState()
        d.shoot(angle: atan2(400.0 - 737.0, 400.0 - 737.0), power: 0.345, side: 0, vertical: -0.45)
        d.runStrokeToRest()
    }

    /// The match keeps the frames each player has won: a frame is counted for its winner the moment it
    /// ends, and the next frame carries those on and takes the next number.
    func testFramesWonAreCountedAndCarriedIntoTheNextFrame() {
        let d = driver()
        XCTAssertEqual(d.frameNumber, 1, "the first frame of the match")
        XCTAssertEqual(d.framesWon, [0, 0])

        potTheLastBlack(d)
        XCTAssertEqual(d.winner, 0, "the striker takes the frame")
        XCTAssertEqual(d.framesWon, [1, 0], "counted for its winner as it ends")

        d.startTheNewFrame()
        XCTAssertEqual(d.frameNumber, 2, "and the next frame is the next number")
        XCTAssertEqual(d.framesWon, [1, 0], "with the frames already won carried over")
    }

    /// A re-rack is the same frame played again (Section 3 Rule 17), so a win already counted for it
    /// comes back off the board — the frame is not won twice.
    func testAReRackedFrameComesBackOffTheBoard() {
        let d = driver()
        potTheLastBlack(d)
        XCTAssertEqual(d.framesWon, [1, 0])

        d.reRack()
        XCTAssertEqual(d.frameNumber, 1, "a re-rack is the same frame")
        XCTAssertEqual(d.framesWon, [0, 0], "and the frame that had ended is no longer won")
    }

    /// The question **Esc** asks: it asks first, the match is left exactly as it stands while it asks, and
    /// answering it takes the frame number and the frames won back to the start of the match.
    func testANewGameGoesBackToTheFirstFrameWithNothingWon() {
        let d = driver()
        potTheLastBlack(d)                          // the first frame, to player 0
        d.startTheNewFrame()
        XCTAssertEqual(d.frameNumber, 2)
        XCTAssertEqual(d.framesWon, [1, 0])
        XCTAssertTrue(d.placeCueBall(at: Vec2(600, 889)))
        XCTAssertTrue(d.canStrike, "the striker is at the table")

        d.askToStartANewGame()
        XCTAssertTrue(d.isAskingAboutANewGame)
        XCTAssertFalse(d.canStrike, "and no stroke can be played over the question")
        XCTAssertEqual(d.frameNumber, 2, "with nothing thrown away yet")
        XCTAssertEqual(d.framesWon, [1, 0])

        d.keepPlaying()
        XCTAssertFalse(d.isAskingAboutANewGame)
        XCTAssertEqual(d.frameNumber, 2, "carrying on leaves the match where it was")
        XCTAssertEqual(d.framesWon, [1, 0])

        d.askToStartANewGame()
        d.startTheNewGame()
        XCTAssertFalse(d.isAskingAboutANewGame)
        XCTAssertEqual(d.frameNumber, 1, "a new game is the first frame of the match")
        XCTAssertEqual(d.framesWon, [0, 0], "with nothing won")
        XCTAssertEqual(d.scores, [0, 0])
        XCTAssertEqual(d.mode, .placingCueBall)
    }

    /// There is only ever one question on the screen: each of the three puts the others away.
    func testAskingOneQuestionPutsTheOthersAway() {
        let d = driver()
        d.askToStartANewFrame()
        XCTAssertTrue(d.isAskingAboutANewFrame)
        d.askToStartANewGame()
        XCTAssertFalse(d.isAskingAboutANewFrame, "the new game takes the question over")
        XCTAssertTrue(d.isAskingAboutANewGame)
        d.askToReRack()
        XCTAssertFalse(d.isAskingAboutANewGame)
        XCTAssertTrue(d.isAskingAboutAReRack)
    }

    /// With only the Black left and the striker needing snookers, the frame is the **non-striker's** and is
    /// awarded without being asked for (Section 2 Rule 1(c)): the opponent claims it automatically.
    func testTheOpponentIsAwardedTheFrameWhenTheStrikerNeedsSnookers() {
        let d = driver()
        d.game.withState { state in
            state.redsRemaining = 0
            state.ballsOnTable = [BallID.cue, BallID.black]
            state.ballOn = .colourOfSequence(.black)
            state.ballPositions[BallID.black] = Vec2(3200, 889)
            state.scores = [40, 48]                     // the striker is eight points behind
        }
        d.syncWorldFromState()
        XCTAssertTrue(d.placeCueBall(at: Vec2(Table.baulkLineX - 100, Table.centreY - 100)))

        XCTAssertTrue(d.isFrameOver, "the frame ends the moment the position is noticed")
        XCTAssertEqual(d.winner, 1, "and it is the non-striker's")
        XCTAssertFalse(d.canClaimTheFrame, "there is nothing left to claim")
        XCTAssertEqual(d.framesWon, [0, 1], "counted for the player it was awarded to")
        XCTAssertTrue(d.commentary.contains { $0.contains("needs snookers") },
                      "and the referee's own line says why")
    }

    /// The striker's own case is still a **claim**, not an award: more than seven ahead themselves, the
    /// frame is not ended for them, and taking it or playing on is theirs to choose.
    func testTheStrikerStillClaimsTheFrameThemselves() {
        let d = driver()
        d.game.withState { state in
            state.redsRemaining = 0
            state.ballsOnTable = [BallID.cue, BallID.black]
            state.ballOn = .colourOfSequence(.black)
            state.ballPositions[BallID.black] = Vec2(3200, 889)
            state.scores = [48, 40]                     // the striker is eight points ahead
        }
        d.syncWorldFromState()
        XCTAssertTrue(d.placeCueBall(at: Vec2(Table.baulkLineX - 100, Table.centreY - 100)))

        XCTAssertFalse(d.isFrameOver, "the frame is not ended for the player at the table")
        XCTAssertTrue(d.canClaimTheFrame)
        d.claimTheFrame()
        XCTAssertTrue(d.isFrameOver)
        XCTAssertEqual(d.winner, 0)
        XCTAssertEqual(d.framesWon, [1, 0])
    }

    /// The same award at the end of a real stroke, the way it arises in play: the striker pots the last
    /// colour before the Black, which leaves the Black alone on the table, and the frame is the
    /// non-striker's before the striker can play at it.
    func testTheFrameIsAwardedWhenTheLastColourLeavesTheBlackAlone() {
        let d = driver()
        d.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.pink, BallID.black]
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.pink)
            state.cueBallInHand = false
            state.pending = nil
            state.scores = [30, 48]
            state.ballPositions[BallID.cue] = Vec2(737, 737)
            state.ballPositions[BallID.pink] = Vec2(400, 400)     // on the line into the corner
            state.ballPositions[BallID.black] = Vec2(3200, 889)
        }
        d.syncWorldFromState()
        XCTAssertFalse(d.isFrameOver, "the Pink is still there to play at")

        d.shoot(angle: atan2(400.0 - 737.0, 400.0 - 737.0), power: 0.345, side: 0, vertical: -0.45)
        d.runStrokeToRest()

        XCTAssertEqual(d.scores, [36, 48], "the Pink's six")
        XCTAssertTrue(d.isFrameOver, "with the Black alone and the striker twelve behind, the frame is over")
        XCTAssertEqual(d.winner, 1, "awarded to the player who was ahead")
        XCTAssertEqual(d.framesWon, [0, 1])
    }

    /// "Snookers required" is true of the striker when they are further behind than the points still on the
    /// table — and not when they are behind by exactly that much, which the balls alone can make up.
    func testTheStrikerNeedsSnookersOnlyWhenTheBallsCannotCatchUp() {
        let d = driver()
        XCTAssertEqual(d.remainingPoints, 147, "a full table")
        XCTAssertFalse(d.theStrikerNeedsSnookers, "level at the break")

        // One Red and every colour left is 35 on: a Red plus a Black, and the six colours.
        d.game.withState { state in
            state.redsRemaining = 1
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.yellow, BallID.green,
                                  BallID.brown, BallID.blue, BallID.pink, BallID.black]
        }
        d.syncWorldFromState()
        XCTAssertEqual(d.remainingPoints, 35)

        d.game.withState { $0.scores = [20, 50] }          // thirty behind
        XCTAssertFalse(d.theStrikerNeedsSnookers, "thirty behind with 35 on is still the striker's to win")

        d.game.withState { $0.scores = [10, 50] }          // forty behind
        XCTAssertTrue(d.theStrikerNeedsSnookers, "forty behind with 35 on needs a foul")

        d.game.withState { $0.scores = [50, 10] }          // the striker ahead
        XCTAssertFalse(d.theStrikerNeedsSnookers, "and it is never said of the player who is ahead")

        d.game.withState { $0.frameOver = true; $0.scores = [10, 50] }
        XCTAssertFalse(d.theStrikerNeedsSnookers, "with the frame over there is nothing left to require")
    }

    /// A striker on a colour of their own choice, with the Yellow straight ahead of the cue ball and the
    /// Green off to one side, so that the cue can be swept from one to the other.
    private func strikerChoosingAColour() -> FrameDriver {
        let d = driver()
        d.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.yellow, BallID.green, BallID.black]
            state.redsRemaining = 0
            state.ballOn = .anyColour
            state.nominatedColour = nil
            state.pending = .nominateColour(options: [.yellow, .green, .black])
            state.cueBallInHand = false
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.yellow] = Vec2(2000, 889)
            state.ballPositions[BallID.green] = Vec2(2000, 1200)
            state.ballPositions[BallID.black] = Vec2(3000, 889)
        }
        d.syncWorldFromState()
        return d
    }

    /// While the ball on is a colour of the striker's own choice, aiming at a colour **is** the nomination:
    /// the game takes the colour the cue is on rather than making them press a button for something they
    /// have already said with the cue.
    func testAimingAtAColourNominatesIt() {
        let d = strikerChoosingAColour()
        XCTAssertNil(d.nominatedColour, "nothing is nominated to begin with")
        XCTAssertTrue(d.isChoosingAColour, "and the game is asking")

        d.aimAngle = -0.4                       // off at the cushion, with nothing on that line
        XCTAssertNil(d.nominatedColour, "a cue pointed at nothing nominates nothing")
        XCTAssertTrue(d.isChoosingAColour, "and the question is still open")

        d.aimAngle = 0                          // straight at the Yellow
        XCTAssertEqual(d.nominatedColour, .yellow, "the aim has said which colour is on")
        XCTAssertFalse(d.isChoosingAColour, "so the question is answered")
        XCTAssertTrue(d.canStrike, "and the striker is back over their shot")
        XCTAssertEqual(d.ballOnDescription, "Yellow")

        d.aimAngle = atan2(311, 1000)           // on to the Green
        XCTAssertEqual(d.nominatedColour, .green, "and the nomination follows the cue")
    }

    /// And the choice is read as soon as the question is asked, without the cue having to be moved: the
    /// striker who is already pointing at a colour is playing for it.
    func testTheCueOnAColourAnswersTheQuestionAsSoonAsItIsAsked() {
        let d = strikerChoosingAColour()
        XCTAssertNil(d.nominatedColour)
        // Any change of state settles what the striker may do next, and `keepPlaying` is the public way to
        // ask the game for that settle: nothing else is standing here.
        d.keepPlaying()
        XCTAssertEqual(d.nominatedColour, .yellow, "the cue was already on the Yellow")
        XCTAssertFalse(d.isChoosingAColour)
        XCTAssertTrue(d.canStrike)
    }

    /// Once the striker has nominated a colour **by hand**, the choice is theirs: the aim does not take it
    /// away, however they look about the table.
    func testAColourNominatedByHandIsNotChangedByTheAim() {
        let d = strikerChoosingAColour()
        d.aimAngle = atan2(311, 1000)           // the cue is on the Green
        XCTAssertEqual(d.nominatedColour, .green)

        d.chooseColour(.black)                  // and the striker says the Black
        XCTAssertEqual(d.nominatedColour, .black)

        d.aimAngle = -0.4                       // looking off at the cushion
        XCTAssertEqual(d.nominatedColour, .black, "which is still what they are playing for")
        d.aimAngle = 0                          // and on to the Yellow
        XCTAssertEqual(d.nominatedColour, .black, "which is still what they are playing for")
        XCTAssertEqual(d.ballOnDescription, "Black")
    }

    /// Aimed at a cushion with nothing in the way, the shot still has a first contact, and it is on
    /// the cushion: the cue ball's centre arrives under the nose, `cushionRestReach` off the face.
    /// That is where the ghost ball goes, so a player looking at a cushion shot can see the point
    /// they are about to hit.
    func testAShotAimedAtACushionMeetsTheCushion() {
        let d = driver()
        // In the D but not on any of its spots, and with nothing between it and the top cushion.
        XCTAssertTrue(d.placeCueBall(at: Vec2(Table.baulkLineX - 100, Table.centreY - 100)))
        d.aimAngle = .pi / 2                     // straight up the table, at the top cushion
        guard let contact = d.predictedFirstContact() else {
            return XCTFail("a shot at a cushion must have a first contact")
        }
        XCTAssertEqual(contact.contact, .cushion(side: .top))
        XCTAssertEqual(contact.point.x, Table.baulkLineX - 100, accuracy: 1e-9, "straight along the aim")
        XCTAssertEqual(contact.point.y, Table.width - Table.cushionRestReach, accuracy: 1e-9,
                       "the centre reaches the cushion under the nose")
    }

    /// And a ball in the way is met before the cushion behind it.
    func testABallInTheWayIsMetBeforeTheCushionBehindIt() {
        let d = driver()
        d.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.redsRemaining = 1
            state.ballOn = .red
            state.ballPositions[BallID.firstRed] = Vec2(737, 1400)
            state.ballPositions[BallID.cue] = Vec2(737, 889)
            state.cueBallInHand = true
            state.pending = .placeCueBallInD
        }
        d.syncWorldFromState()
        XCTAssertTrue(d.placeCueBall(at: Vec2(737, 889)))
        d.aimAngle = .pi / 2
        guard let contact = d.predictedFirstContact() else {
            return XCTFail("a shot at a ball must have a first contact")
        }
        XCTAssertEqual(contact.contact, .ball(id: BallID.firstRed))
        XCTAssertEqual(contact.point.y, 1400 - Table.ballDiameter, accuracy: 1e-9)
    }

    func testBreakOffFromTheDRunsAStrokeAndResolves() {
        let d = driver()
        XCTAssertTrue(d.placeCueBall(at: Vec2(600, 889)))
        XCTAssertEqual(d.mode, .aiming)

        let before = d.balls.map(\.position)
        d.shoot(angle: 0, power: 0.85, side: 0, vertical: 0.2)
        XCTAssertEqual(d.mode, .simulating)
        d.runStrokeToRest()

        XCTAssertNotEqual(d.mode, .simulating)
        let moved = zip(before, d.balls.map(\.position)).contains { $0.distance(to: $1) > 5 }
        XCTAssertTrue(moved, "the break must move balls")
        XCTAssertTrue(d.commentary.contains { !$0.isEmpty })
    }

    func testPottingARedScoresAndPromptsForAColour() {
        let d = pottedRedSetup()
        // Aim at the Red, which is exactly on the line into the corner pocket.
        let angle = atan2(400.0 - 737.0, 400.0 - 737.0)
        // Screw back: a full ball on the pocket line would otherwise follow it in.
        d.shoot(angle: angle, power: 0.345, side: 0, vertical: -0.45)
        d.runStrokeToRest()

        XCTAssertEqual(d.scores[0], 1, "potting a Red scores one")
        XCTAssertEqual(d.game.state.redsRemaining, 0)
        if case .nominateColour(let options) = d.pending {
            XCTAssertTrue(options.contains(.yellow))
        } else {
            XCTFail("expected a colour nomination after potting a Red, got \(String(describing: d.pending))")
        }
    }

    func testCueBallPottedIsAFourPointFoulAndGoesInHand() {
        let d = driver()
        d.game.withState { state in
            state.ballsOnTable = [BallID.cue]
            state.redsRemaining = 0
            state.pending = .placeCueBallInD
            state.cueBallInHand = true
        }
        d.syncWorldFromState()
        XCTAssertTrue(d.placeCueBall(at: Vec2(537, 689)))

        // Fire the cue ball straight into the bottom-left corner pocket.
        let angle = atan2(-30.0 - 689.0, -30.0 - 537.0)
        d.shoot(angle: angle, power: 0.7, side: 0, vertical: 0.3)
        d.runStrokeToRest()

        XCTAssertEqual(d.scores[1], 4, "cue ball potted costs at least four points")
        XCTAssertTrue(d.game.state.cueBallInHand)
        if case .afterFoul = d.pending {
            // expected
        } else {
            XCTFail("expected the non-offender to have options after the foul")
        }
    }

    func testTheStrikerMayPlayWhileChoosingAColourButNotWhileDecidingAFoul() {
        // Being asked what to do about a foul stops play: the non-offender has to choose first.
        let deciding = driver()
        deciding.game.withState { state in
            // Pink and Black: a foul leaves the frame alive, since only a foul with the Black as the
            // last ball on the table ends it (Section 3 Rule 4(a)).
            state.ballsOnTable = [BallID.cue, BallID.pink, BallID.black]
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.pink)
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.pink] = Vec2(2000, 400)
            state.ballPositions[BallID.black] = Vec2(2000, 889)
        }
        deciding.syncWorldFromState()
        deciding.shoot(angle: Double.pi / 2, power: 0.3, side: 0, vertical: 0)
        deciding.runStrokeToRest()
        XCTAssertEqual(deciding.mode, .decision)
        XCTAssertFalse(deciding.canStrike, "a foul has to be answered before the next stroke")

        // Being asked which colour is on does not: the striker can look around, and may play
        // without declaring, which the rules call a foul and a miss.
        let choosing = driver()
        choosing.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.yellow, BallID.green]
            state.ballOn = .anyColour
            state.nominatedColour = nil
            state.cueBallInHand = false
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.yellow] = Vec2(2000, 889)
            state.ballPositions[BallID.green] = Vec2(2500, 889)
        }
        choosing.syncWorldFromState()
        // The mode only becomes .decision through the driver's own pipeline, so take it there the
        // way the game does: a foul, then put the colour choice in front of it.
        choosing.game.withState { state in
            state.pending = .afterFoul(FoulDecision(foul: Foul(reason: "test", penalty: 4),
                                                    freeBallAvailable: false,
                                                    canRequestOriginalPosition: false))
        }
        choosing.syncWorldFromState()
        choosing.shoot(angle: 0, power: 0.2, side: 0, vertical: 0)
        choosing.runStrokeToRest()
        XCTAssertEqual(choosing.mode, .decision)
        choosing.game.withState { state in
            state.ballOn = .anyColour
            state.nominatedColour = nil
            state.pending = .nominateColour(options: [.yellow, .green])
        }
        XCTAssertTrue(choosing.isChoosingAColour)
        XCTAssertTrue(choosing.canStrike, "the striker can look around and play while choosing")
        choosing.beginCharge(at: 0)
        XCTAssertEqual(choosing.mode, .charging, "and the charge starts")
    }

    func testFoulCanBeAnsweredByAskingTheOffenderToPlayAgain() {
        let d = driver()
        d.game.withState { state in
            // The Pink is on with the Black behind it, so the foul does not end the frame.
            state.ballsOnTable = [BallID.cue, BallID.pink, BallID.black]
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.pink)
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.pink] = Vec2(2000, 400)
            state.ballPositions[BallID.black] = Vec2(2000, 889)
        }
        d.syncWorldFromState()

        // Hit nothing: a foul, and a miss because the Pink was clearly available.
        d.shoot(angle: Double.pi / 2, power: 0.3, side: 0, vertical: 0)
        d.runStrokeToRest()
        XCTAssertEqual(d.scores[1], 6, "a foul on the Pink costs six")

        let offender = 0
        d.askOffenderToPlayAgain()
        XCTAssertEqual(d.currentPlayer, offender, "the offender must play again when asked")
    }

    // MARK: Ball in hand

    /// A ball placed in hand may be moved about until the stroke is played: putting it down is not a
    /// commitment (Section 2 Rule 10(a), Section 3 Rule 5).
    func testTheCueBallCanBePickedUpAndPutDownAgainBeforeTheStroke() {
        let d = driver()
        XCTAssertTrue(d.canRepositionCueBall, "the frame starts with the cue ball in hand")
        XCTAssertTrue(d.placeCueBall(at: Vec2(600, 889)))
        XCTAssertEqual(d.mode, .aiming)
        XCTAssertTrue(d.canRepositionCueBall, "putting it down is not a commitment")

        d.repositionCueBall()
        XCTAssertEqual(d.mode, .placingCueBall)
        XCTAssertTrue(d.game.state.cueBallInHand)
        XCTAssertTrue(d.placeCueBall(at: Vec2(700, 800)), "and somewhere else is allowed")
        XCTAssertEqual(d.cueBall?.position, Vec2(700, 800))

        d.shoot(angle: 0, power: 0.2, side: 0, vertical: 0)
        d.runStrokeToRest()
        XCTAssertFalse(d.canRepositionCueBall, "the cue ball is in play once it has been struck")
        let afterTheStroke = d.cueBall?.position
        d.repositionCueBall()
        XCTAssertEqual(d.cueBall?.position, afterTheStroke, "and cannot be moved about again")
    }

    // MARK: Touching ball (Rule 8), end to end

    /// What the screen shows for a touching ball: the referee's call, and the balls it names.
    func testTheRefereeCallsTheBallTheCueBallIsTouching() {
        let d = restingAgainstARed()
        XCTAssertEqual(d.touchingBalls, [BallID.firstRed])
        XCTAssertEqual(d.refereeCall, "TOUCHING BALL: the cue ball is touching the red")

        // And with the cue ball clear of everything there is nothing to call.
        d.game.withState { $0.ballPositions[BallID.cue] = Vec2(900, 889) }
        d.syncWorldFromState()
        XCTAssertTrue(d.touchingBalls.isEmpty)
        XCTAssertNil(d.refereeCall)
    }



    /// The cue ball resting against a Red, with the Red as the ball on, through the real physics: the
    /// two are exactly a diameter apart, which is what touching means.
    private func restingAgainstARed() -> FrameDriver {
        let d = driver()
        d.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.redsRemaining = 1
            state.ballOn = .red
            state.cueBallInHand = false
            state.pending = nil
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(1000 + Table.ballDiameter, 889)
        }
        d.syncWorldFromState()
        return d
    }

    func testPlayingAwayFromATouchingBallHitsNothingAndIsNoFoul() {
        let d = restingAgainstARed()
        d.shoot(angle: .pi, power: 0.115, side: 0, vertical: 0)     // straight away from the Red
        d.runStrokeToRest()

        XCTAssertEqual(d.lastStroke?.firstContacts, [])
        XCTAssertNil(d.lastResult?.foul, "a ball the cue ball is touching needs no contact of its own")
        XCTAssertEqual(d.scores, [0, 0])
        XCTAssertEqual(d.currentPlayer, 1, "the turn passes in the ordinary way")
    }

    func testPlayingIntoATouchingBallMovesItAndIsAPushStroke() {
        let d = restingAgainstARed()
        d.shoot(angle: 0, power: 0.15, side: 0, vertical: 0)       // straight into the Red
        d.runStrokeToRest()

        guard let foul = d.lastResult?.foul else {
            return XCTFail("expected a push stroke")
        }
        XCTAssertTrue(foul.reason.contains("push stroke"), foul.reason)
        XCTAssertEqual(d.scores, [0, 4])
    }

    // MARK: Cue action and spin (the E and S keys)

    /// The speed a ball leaves along the cloth when the cue strikes it worth `ballSpeed`. The cue
    /// stands at the angle the player's own stance gives it — level, since a cue may be held flat —
    /// so the impulse is along that angle and the part of it left for travel is that much less by the
    /// cosine: see `PhysicsWorld.cueLean`.
    private func alongTheCloth(_ ballSpeed: Double) -> Double {
        alongTheCloth(ballSpeed, at: Table.cueStanceElevation)
    }

    /// The same, at the angle the shot was really played at: the cue is **level** at the bottom of the
    /// lift now, so a stroke with a cushion or a ball behind the ball is settled a little above it, and
    /// the part of the strike that goes down into the cloth comes off the ball's speed with it.
    private func alongTheCloth(_ ballSpeed: Double, at elevation: Double) -> Double {
        ballSpeed * cos(elevation)
    }

    /// A driver with the cue ball and a Red lined up, ready for a stroke to be played by hand.
    private func cueActionSetup() -> FrameDriver {
        let d = driver()
        d.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.redsRemaining = 1
            state.ballOn = .red
            state.cueBallInHand = true
            state.pending = .placeCueBallInD
            state.ballPositions[BallID.cue] = Vec2(600, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
        }
        d.syncWorldFromState()
        // Placing the cue ball is what puts the driver at the table, aiming.
        XCTAssertTrue(d.placeCueBall(at: Vec2(600, 889)))
        return d
    }

    /// The same, but with the ball out in the open, well clear of every cushion: the cue has room for
    /// the tip to be anywhere on the ball's face and for the whole of a backswing at any of them.
    private func cueActionSetupInTheOpen() -> FrameDriver {
        let d = cueActionSetup()
        d.game.withState { state in
            state.cueBallInHand = false
            state.pending = nil
            state.ballPositions[BallID.cue] = Vec2(1784, Table.centreY)
            state.ballPositions[BallID.firstRed] = Vec2(2900, Table.centreY)
        }
        d.syncWorldFromState()
        return d
    }

    func testTheCueActionDrawsTheCueBackAndPlaysTheShotAsItComesThrough() {
        let d = cueActionSetup()
        XCTAssertTrue(d.beginCueAction(), "the cue can be taken up at the table")
        XCTAssertEqual(d.mode, .charging)
        XCTAssertTrue(d.isMovingTheCue)
        XCTAssertEqual(d.cueDraw, 0, accuracy: 0.001, "the tip starts at the ball")
        XCTAssertEqual(d.power, 0, accuracy: 0.001, "nothing has been struck or drawn yet")

        // Draw the cue back slowly: no stroke, whatever the backswing turns out to be.
        XCTAssertFalse(d.moveCue(forwardByMillimetres: -130, over: 0.2))
        XCTAssertEqual(d.cueDraw, 130, accuracy: 0.001)
        XCTAssertEqual(d.mode, .charging)

        // Part of the way forward: the cue has moved, the ball has not been struck.
        XCTAssertFalse(d.moveCue(forwardByMillimetres: 80, over: 0.1))
        XCTAssertEqual(d.cueDraw, 50, accuracy: 0.001)

        // Through the ball: the shot is played, at the speed the cue was travelling — 80 mm in
        // 40 ms is the hand's 2000 mm/s — and with nothing spent on spin, a centre hit.
        XCTAssertTrue(d.moveCue(forwardByMillimetres: 80, over: 0.04))
        XCTAssertEqual(d.mode, .simulating)
        XCTAssertFalse(d.isMovingTheCue, "the cue is out of the player's hands once the shot is away")
        // The ball is struck at the cue's own speed, and the cue's own speed is never more than the
        // hand's: the push is read as its running average (`cuePushAverageSeconds`), so the tip is
        // played at the speed the cue has arrived at. This frame is longer than that window, so the
        // average has caught right up to the hand; a frame shorter than it would leave the cue still
        // catching up, which is the smoothing the game plays with — see the shaky-delivery test.
        XCTAssertGreaterThan(d.lastStrikeCueSpeed, 0)
        XCTAssertLessThanOrEqual(d.lastStrikeCueSpeed, 2000, "the hand's own speed was 2000 mm/s")
        XCTAssertEqual(d.cueBall?.velocity.length ?? 0,
                       alongTheCloth(FrameDriver.ballSpeed(fromCueSpeed: d.lastStrikeCueSpeed, tipOffset: 0),
                                     at: d.cueElevation),
                       accuracy: 1,
                       "the ball leaves at what the cue's own speed is worth")
        XCTAssertEqual(FrameDriver.ballSpeed(fromCueSpeed: 2000, tipOffset: 0) / 2000, 1.75, accuracy: 0.01,
                       "a centre hit leaves the ball at 1.75 times the cue's speed: the cue outmasses "
                       + "the ball, so the whole of its approach comes back and the tip's spring with it")
    }

    /// A shaky hand does not shake the shot: a shot's strength is the running average of the push
    /// (`cuePushAverageSeconds`), not the one frame that happens to meet the ball. Two deliveries with
    /// the same average speed but wildly different jitter come out worth about the same.
    func testAShakyDeliveryPlaysAboutTheSameShotAsASteadyOne() {
        /// Draws back, then drives through with a push whose frame-by-frame speeds alternate between
        /// `fast` and `slow` — a steady hand is `fast == slow`.
        func shotSpeed(fast: Double, slow: Double) -> Double {
            let d = cueActionSetup()
            d.beginCueAction()
            d.moveCue(forwardByMillimetres: -120, over: 0.3)
            let dt = 1.0 / 120.0
            var left = 140.0
            var pushTheFastFrame = true
            while left > 0, d.mode == .charging {
                let piece = min(left, (pushTheFastFrame ? fast : slow) * dt)
                if d.moveCue(forwardByMillimetres: piece, over: dt) { break }
                left -= piece
                pushTheFastFrame.toggle()
            }
            return d.cueBall?.velocity.length ?? 0
        }
        let steady = shotSpeed(fast: 2000, slow: 2000)
        let shaky = shotSpeed(fast: 3400, slow: 600)
        XCTAssertGreaterThan(steady, 0)
        XCTAssertGreaterThan(shaky, 0)
        XCTAssertEqual(shaky, steady, accuracy: steady * 0.2,
                       "a shaky delivery is worth about what a steady one is")
    }

    /// The strength is the cue's speed, so the same flick plays the same shot however far back the
    /// cue was taken, and a twitch of the mouse plays a weak one however long the backswing was.
    func testTheStrengthIsTheCueSpeedNotHowFarBackItWasDrawn() {
        /// Draws the cue back `draw` millimetres, slowly, and then drives it through the ball at
        /// 1500 mm/s — the same speed every time, whatever the backswing.
        func ballSpeedAfterDrawingBack(_ draw: Double) -> Double {
            let d = cueActionSetup()
            d.beginCueAction()
            d.moveCue(forwardByMillimetres: -draw, over: 0.3)
            let travel = draw + 20          // far enough to bring the tip through the ball
            d.moveCue(forwardByMillimetres: travel, over: travel / 1500)
            return d.cueBall?.velocity.length ?? 0
        }

        let short = ballSpeedAfterDrawingBack(40)
        let long = ballSpeedAfterDrawingBack(240)
        XCTAssertEqual(short, long, accuracy: 1,
                       "a 240 mm backswing is worth exactly what a 40 mm one is at the same speed")
        XCTAssertGreaterThan(short, 0, "and both are worth what the cue's own speed is worth")

        /// The same flick, but taking ten times as long, is a tenth of the shot.
        let d = cueActionSetup()
        d.beginCueAction()
        d.moveCue(forwardByMillimetres: -100, over: 0.3)
        d.moveCue(forwardByMillimetres: 120, over: 0.4)
        XCTAssertEqual(d.cueBall?.velocity.length ?? 0,
                       FrameDriver.ballSpeed(fromCueSpeed: 300, tipOffset: 0), accuracy: 1,
                       "moving the cue slowly is a slow shot")
    }

    func testTheCueCannotBeDrawnBackFurtherThanItsFullDraw() {
        let d = cueActionSetup()
        d.beginCueAction()
        d.moveCue(forwardByMillimetres: -2000, over: 1)
        XCTAssertEqual(d.cueDraw, FrameDriver.maxCueDraw, accuracy: 0.001)
    }

    /// The elevation is the cue's **own** angle, and the bottom of the lift is the level the player's
    /// stance gives the stick. The widget reads the same number, and a stroke is played along it.
    func testTheElevationIsTheCuesOwnAngle() {
        // The bottom of the lift is **level**: a cue may be held flat, and on the open table that is what
        // a player does. It is not the arm's own 2.5° dressed up as a floor.
        XCTAssertEqual(Table.cueStanceElevationDegrees, 0, accuracy: 1e-12,
                       "the cue is held level at the bottom of the lift")
        let d = cueActionSetupInTheOpen()
        // Well up the table, so that the whole backswing fits behind the ball with a **level** cue: at
        // 26.25 mm the stick needs more room than one raised at the arm's old 2.5° did.
        d.game.withState { $0.ballPositions[BallID.cue] = Vec2(2000, Table.centreY) }
        d.syncWorldFromState()
        d.aimAngle = 0                                     // up the table: the open end is behind it
        d.cueElevation = 0                                 // the player's own angle: level
        d.settleTheCue()
        XCTAssertEqual(d.cueElevation, 0, accuracy: 1e-12,
                       "with room behind the ball a level cue is left alone, not lifted")

        d.adjustElevation(by: 10 * .pi / 180)
        XCTAssertEqual(d.cueElevation, 10 * .pi / 180, accuracy: 1e-12,
                       "lifting the butt raises the elevation from there")
        d.adjustElevation(by: -40 * .pi / 180)
        XCTAssertEqual(d.cueElevation, 0, accuracy: 1e-12,
                       "and lowering it stops at level: the cue is not put above it for the player")
        d.adjustElevation(by: 100 * .pi / 180)
        XCTAssertEqual(d.cueElevation, PhysicsWorld.maxCueElevation, accuracy: 1e-12,
                       "no further up than a cue can be stood without scooping the ball")

        // A stroke asked for "level" is played along the level, and the cue goes back to it when the
        // stroke is over.
        d.cueElevation = 0
        d.shoot(angle: 0, power: 0.3, side: 0, vertical: 0)
        XCTAssertEqual(d.cueElevation, 0, accuracy: 1e-12)
        d.runStrokeToRest()
        XCTAssertEqual(d.cueElevation, 0, accuracy: 1e-12)
    }

    /// Hitting off centre costs the shot speed, because part of the impulse goes into spin instead of
    /// travel, and leaves the cue ball turning.
    func testAnOffCentreHitIsSlowerAndSpinsTheBall() {
        let k = PhysicsWorld.spinLimit(angle: 0, elevation: Table.cueStanceElevation)
        func struck(side: Double) -> (speed: Double, spin: Double) {
            let d = cueActionSetup()
            d.adjustSpin(side: side, vertical: 0)
            d.beginCueAction()
            d.moveCue(forwardByMillimetres: -100, over: 0.3)
            d.moveCue(forwardByMillimetres: 120, over: 0.05)
            return (d.cueBall?.velocity.length ?? 0, abs(d.cueBall?.spin.z ?? 0))
        }

        // The cue is settled a hair above level here — the baulk cushion is behind the ball — so the
        // expectation is worked out at the angle the shot was really played at.
        let playedAt = cueActionSetup().cueElevation
        let centre = struck(side: 0)
        let right = struck(side: k)
        XCTAssertEqual(centre.speed,
                       alongTheCloth(FrameDriver.ballSpeed(fromCueSpeed: 2400, tipOffset: 0), at: playedAt),
                       accuracy: 1)
        XCTAssertEqual(right.speed,
                       alongTheCloth(FrameDriver.ballSpeed(fromCueSpeed: 2400, tipOffset: k), at: playedAt),
                       accuracy: 1)
        XCTAssertLessThan(right.speed, centre.speed * 0.8,
                          "the furthest off centre the control goes is about three quarters of the speed")
        XCTAssertEqual(right.spin, 2.5 * right.speed * k / Table.ballRadius, accuracy: 1,
                       "the spin comes out of the same impulse: omega = (5/2) v k / r")
        XCTAssertEqual(centre.spin, 0, accuracy: 0.001, "a centre hit does not turn it")
    }

    func testATwitchOfTheMouseNeverPlaysTheShot() {
        // The cue has to be drawn back properly before a push counts: otherwise a stray movement
        // while the aim is being lined up would play the stroke.
        let d = cueActionSetup()
        d.beginCueAction()
        XCTAssertFalse(d.moveCue(forwardByMillimetres: -10, over: 0.2), "a 10 mm draw is not a backswing")
        XCTAssertFalse(d.moveCue(forwardByMillimetres: 40, over: 0.02), "so pushing through plays nothing")
        XCTAssertEqual(d.mode, .charging)
        XCTAssertTrue(d.isMovingTheCue)
    }

    func testLettingGoOfTheCuePlaysNoShot() {
        let d = cueActionSetup()
        let cueBallStart = d.cueBall?.position
        d.beginCueAction()
        d.moveCue(forwardByMillimetres: -220, over: 0.3)
        d.cancelCueAction()

        XCTAssertEqual(d.mode, .aiming)
        XCTAssertFalse(d.isMovingTheCue)
        XCTAssertEqual(d.cueDraw, 0, accuracy: 0.001, "the cue goes back to its rest position")
        d.runStrokeToRest(maxSeconds: 1)
        XCTAssertEqual(d.cueBall?.position, cueBallStart, "and no stroke has been played")
    }

    func testTheCueCannotBeTakenUpWhileTheBallsAreRunning() {
        let d = cueActionSetup()
        d.shoot(angle: 0, power: 0.8, side: 0, vertical: 0.4)
        XCTAssertEqual(d.mode, .simulating)
        XCTAssertFalse(d.beginCueAction(), "not until the balls have stopped")
    }

    func testTheSpinGoesBackToTheMiddleOfTheBallAfterAShot() {
        let d = cueActionSetupInTheOpen()
        let k = PhysicsWorld.spinLimit(angle: 0, elevation: Table.cueStanceElevation)
        d.adjustSpin(side: k, vertical: 0)
        d.beginCueAction()
        d.moveCue(forwardByMillimetres: -100, over: 0.3)
        d.moveCue(forwardByMillimetres: 120, over: 0.05)

        // The shot is played with the spin the player set: the offset comes out of the same impulse,
        // `omega = (5/2) v k / r`.
        let ballSpeed = d.cueBall?.velocity.length ?? 0
        XCTAssertGreaterThan(ballSpeed, 0)
        XCTAssertEqual(d.cueBall?.spin.z ?? 0, 2.5 * ballSpeed * k / Table.ballRadius, accuracy: 1,
                       "the side spin the player set is on the shot")

        d.runStrokeToRest()
        XCTAssertEqual(d.spinSide, 0, accuracy: 0.001, "the next shot starts from a clean cue ball")
        XCTAssertEqual(d.spinVertical, 0, accuracy: 0.001)
    }

    func testTheSpinIsResetAfterAChargedShotAsWell() {
        let d = cueActionSetupInTheOpen()
        d.spinSide = 0.5
        d.spinVertical = 0.25
        d.beginCharge(at: 0)
        d.updateCharge(at: 1.0)
        d.releaseShot()
        d.runStrokeToRest()

        XCTAssertEqual(d.spinSide, 0, accuracy: 0.001, "a mouse-button charge is a shot like any other")
        XCTAssertEqual(d.spinVertical, 0, accuracy: 0.001)
    }

    /// The spin control is the player's: it puts the tip where they ask, all the way to the edge of the
    /// ball, and the lines the widget draws — the double-contact boundary and the leather's grip — are
    /// **shown**, not enforced. Past the grip the strike slips and gives no more spin; that is the
    /// physics, not the control.
    func testTheSpinControlPutsTheTipWhereThePlayerAsks() {
        // In the open, where the cue has room behind the ball for the tip to be anywhere on its face.
        let d = cueActionSetupInTheOpen()
        d.adjustSpin(side: 0.3, vertical: -0.2)
        XCTAssertEqual(d.spinSide, 0.3, accuracy: 0.001, "across the ball is side spin")
        XCTAssertEqual(d.spinVertical, -0.2, accuracy: 0.001, "down the ball is screw back")

        // Past both drawn lines: the control keeps it.
        d.setSpin(side: 1, vertical: -1)
        XCTAssertEqual((d.spinSide * d.spinSide + d.spinVertical * d.spinVertical).squareRoot(),
                       PhysicsWorld.maximumTipOffset, accuracy: 0.001,
                       "the tip can be put on the edge of the ball")
        XCTAssertGreaterThan(d.spinSide, 0)
        XCTAssertLessThan(d.spinVertical, 0, "on the side of the ball it was pushed towards")
        XCTAssertGreaterThan(PhysicsWorld.cueTipOffsetLimit, 0.5, "which is past the leather's grip")
        XCTAssertEqual(PhysicsWorld.maximumTipOffset, 1, accuracy: 1e-12)

        // Further out than a radius is not a contact, so that is where it stops.
        d.setSpin(side: -1, vertical: 1)
        XCTAssertEqual((d.spinSide * d.spinSide + d.spinVertical * d.spinVertical).squareRoot(),
                       PhysicsWorld.maximumTipOffset, accuracy: 0.001)
        XCTAssertLessThan(d.spinSide, 0)
        XCTAssertGreaterThan(d.spinVertical, 0)
    }

    /// The cue ball resting against a cushion, the ball placed and then let go, with a red far away:
    /// `away` millimetres further out from the cushion than a ball can rest. Across the table, so the
    /// stick is laid back over the cushion behind the ball, which is where the room runs out.
    private func cueBallOnTheCushion(outBy away: Double = 0) -> FrameDriver {
        let d = driver()
        XCTAssertTrue(d.placeCueBall(at: Vec2(600, 889)))     // in hand, in the D: puts the player at the table
        d.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.redsRemaining = 1
            state.ballOn = .red
            state.cueBallInHand = false
            state.pending = nil
            state.ballPositions[BallID.cue] = Vec2(1000, Table.cushionRestReach + away)
            state.ballPositions[BallID.firstRed] = Vec2(2200, Table.centreY)
        }
        d.syncWorldFromState()
        d.aimAngle = .pi / 2                    // across the table, away from the cushion behind
        return d
    }

    /// A spin change the cue has no room for is answered by **lifting the tip**, not by refusing the
    /// spin. Just clear of a cushion the butt comes up as far as the game will take it by itself — the
    /// **first cap**, 10°, the same angle a place is settled to — and the tip then goes further up the
    /// ball's face, keeping the side the player asked for, until the line of the stick has room. The
    /// elevation does not move while it does: what buys the room is the shot, not more cue.
    func testASpinChangeWithNoRoomIsAnsweredByLiftingTheTipAtTheFirstCap() {
        let d = cueBallOnTheCushion(outBy: 20)
        let settled = d.cueElevation
        XCTAssertEqual(settled, FrameDriver.spinLiftFirstCap, accuracy: 1e-9,
                       "this place is settled at the first cap")

        // Side spin carries the tip across the ball, and the whole line of the stick with it, towards
        // the cushion the cue ball is on. It does not fit at the angle the cue has been settled at.
        XCTAssertFalse(d.world.cueFits(cueBallID: BallID.cue, yaw: d.aimAngle, elevation: settled,
                                       side: 0.5, vertical: 0, draw: 0),
                       "the side spin has no room at the settled angle")
        d.setSpin(side: 0.5, vertical: 0)

        XCTAssertEqual(d.spinSide, 0.5, accuracy: 1e-9, "the side spin the player asked for is on")
        XCTAssertEqual(d.cueElevation, settled, accuracy: 1e-9,
                       "the butt is left standing where the first cap put it")
        XCTAssertGreaterThan(d.spinVertical, 0, "and the tip went up the ball's face instead")
        XCTAssertLessThanOrEqual(d.spinVertical, FrameDriver.spinLiftTop + 1e-9,
                                 "no further up the face than the tip may go")
        XCTAssertTrue(d.world.cueFits(cueBallID: BallID.cue, yaw: d.aimAngle, elevation: d.cueElevation,
                                      side: d.spinSide, vertical: d.spinVertical, draw: 0),
                      "and it fits where the cue has been put")
        XCTAssertTrue(d.hasRoomForTheCue, "the stroke is still there")
    }

    /// A spin change is never settled past the **second cap**, 30°: the butt stops there whatever else
    /// happens, and the family a spin change belongs to ends at `spinLiftCap` beyond it. With a side
    /// spin the tip can buy room for, the butt does not move at all; with one it cannot — right out at
    /// the edge of the ball — the butt carries on to the second cap and the **spin is settled there** to
    /// what fits. The butt never comes back down for a spin either: the steps it has taken, it keeps.
    func testASpinChangeNeverStandsTheCueUpPastTheSecondCap() {
        XCTAssertLessThan(FrameDriver.spinLiftFirstCap, FrameDriver.spinLiftSecondCap,
                          "the first cap is under the second")
        XCTAssertLessThan(FrameDriver.spinLiftSecondCap, FrameDriver.spinLiftCap,
                          "and the second cap is under the family's own end")

        // Half a ball of side spin, on the cushion: the tip buys the room at the first cap, and the butt
        // is left exactly where it was.
        let half = cueBallOnTheCushion()
        let settled = half.cueElevation
        half.setSpin(side: 0.5, vertical: 0)
        XCTAssertEqual(half.cueElevation, settled, accuracy: 1e-9,
                       "the butt does not move for a spin the tip can find room for")
        XCTAssertEqual(half.spinSide, 0.5, accuracy: 1e-9, "and the side spin is the player's own")
        XCTAssertTrue(half.world.cueFits(cueBallID: BallID.cue, yaw: half.aimAngle,
                                         elevation: half.cueElevation, side: half.spinSide,
                                         vertical: half.spinVertical, draw: 0),
                      "which the cue has room for")
        XCTAssertTrue(half.hasRoomForTheCue, "the stroke is still there")

        // Right out at the edge of the ball: the tip has no room to go further up a face it is already at
        // the edge of, so the butt carries on to the second cap and the spin is settled to what fits
        // there — never past the second cap.
        let edge = cueBallOnTheCushion()
        edge.setSpin(side: 0.9, vertical: 0)
        XCTAssertEqual(edge.cueElevation, FrameDriver.spinLiftSecondCap, accuracy: 1e-9,
                       "the butt is left standing at the second cap")
        XCTAssertLessThan(edge.spinSide, 0.9, "and the spin was settled back")
        XCTAssertGreaterThan(edge.spinSide, 0, "to as much of it as fits")
        XCTAssertTrue(edge.world.cueFits(cueBallID: BallID.cue, yaw: edge.aimAngle,
                                         elevation: edge.cueElevation, side: edge.spinSide,
                                         vertical: edge.spinVertical, draw: 0),
                      "which is a pose the cue can be laid at")
        XCTAssertTrue(edge.hasRoomForTheCue, "the stroke is still there")
    }

    /// If the tip is not enough either, the butt **carries on to the second cap with the spin
    /// unchanged**: the lift is given back, and what the player asked for is posed at the angle that has
    /// room for it. Just clear of a cushion, a spin right out at the edge of the ball (0.95 of a radius
    /// of side) is like that — the tip has no face left to go up, and the butt finds the room at 21°.
    func testTheButtCarriesOnWithTheSpinUnchangedWhenTheTipWillNotDo() {
        let d = cueBallOnTheCushion(outBy: 20)
        d.setSpin(side: 0.95, vertical: 0)

        XCTAssertEqual(d.spinSide, 0.95, accuracy: 1e-9, "the side spin the player asked for is on")
        XCTAssertEqual(d.spinVertical, 0, accuracy: 1e-9, "and the spin is unchanged: no top added")
        XCTAssertGreaterThan(d.cueElevation, FrameDriver.spinLiftFirstCap,
                             "the butt carried on past the first cap")
        XCTAssertLessThanOrEqual(d.cueElevation, FrameDriver.spinLiftSecondCap + 1e-9,
                                 "no further than the second cap")
        XCTAssertTrue(d.world.cueFits(cueBallID: BallID.cue, yaw: d.aimAngle, elevation: d.cueElevation,
                                      side: d.spinSide, vertical: d.spinVertical, draw: 0),
                      "and it fits where the cue has been put")
        XCTAssertTrue(d.hasRoomForTheCue, "the stroke is still there")
    }

    /// A spin change with a ball **behind** the cue ball: room the tip has to find, since the butt alone
    /// would have to be stood right up over the ball. What the tip does there is go up the ball's face
    /// **only as far as it takes** — never lower than the player put it, never past `spinLiftTop` — with
    /// the side spin the player asked for kept exactly, and the butt left where it was. None of them
    /// needs the butt past the **second cap** either.
    func testASpinChangeWithABallBehindLiftsTheTipOnlyAsFarAsItTakes() {
        for behind in [30.0, 45.0, 60.0, 80.0, 100.0] {
            for wanted in [(0.6, 0.0), (0.3, 0.5), (0.0, 0.9)] {
                let d = driver()
                d.game.withState { state in
                    state.ballsOnTable = [BallID.cue, BallID.firstRed]
                    state.redsRemaining = 1
                    state.ballOn = .red
                    state.cueBallInHand = false
                    state.pending = nil
                    state.ballPositions[BallID.cue] = Vec2(1784, Table.centreY)
                    state.ballPositions[BallID.firstRed] = Vec2(1784 - Table.ballDiameter - behind,
                                                                 Table.centreY)
                }
                d.aimAngle = 0
                d.syncWorldFromState()
                let settled = d.cueElevation
                d.setSpin(side: wanted.0, vertical: wanted.1)

                XCTAssertEqual(d.spinSide, wanted.0, accuracy: 1e-9,
                               "the side spin asked for, with a Red \(behind) mm behind the cue ball")
                XCTAssertGreaterThanOrEqual(d.spinVertical, wanted.1 - 1e-9,
                                            "the tip is only ever lifted up the face, never lowered")
                XCTAssertLessThanOrEqual(d.spinVertical,
                                         max(wanted.1, FrameDriver.spinLiftTop) + 1e-9,
                                         "and never past the top of the face for its side")
                XCTAssertGreaterThanOrEqual(d.cueElevation, settled - 1e-9,
                                            "the butt never comes back down for a spin")
                XCTAssertLessThanOrEqual(d.cueElevation, FrameDriver.spinLiftSecondCap + 1e-9,
                                         "and never goes past the second cap")
                XCTAssertTrue(d.world.cueFits(cueBallID: BallID.cue, yaw: d.aimAngle,
                                              elevation: d.cueElevation, side: d.spinSide,
                                              vertical: d.spinVertical, draw: 0),
                              "and it fits where the cue has been put")
            }
        }
    }

    /// The cue is settled where it fits rather than taken away. With the ball on the cushion the player
    /// has nowhere to lay a level cue, so the game stands the butt up — no further than its own cap —
    /// and puts the tip up the ball's face, which lifts the line of the stick with it. The shot is
    /// there to play, and it is still the player's cue: nothing has vanished.
    func testTheCueIsSettledWhereItFitsRatherThanTakenAway() {
        let d = cueBallOnTheCushion()
        XCTAssertEqual(d.mode, .aiming, "the player is at the table")
        XCTAssertTrue(d.canStrike)
        XCTAssertTrue(d.needsTheCueStoodUp, "the place needs the cue stood up")

        // The butt comes up to the cap and the tip goes up the ball's face with it. Topping the ball is
        // held to the spin limit like everything else, and here that is not quite enough room at the
        // cap, so the butt ends a little past it rather than the cue coming off the ball.
        XCTAssertGreaterThanOrEqual(d.cueElevation, FrameDriver.automaticLiftCap - 1e-9,
                                    "the butt comes up as far as the cap")
        XCTAssertLessThan(d.cueElevation, PhysicsWorld.maxCueElevation,
                          "and past it only because the topped ball did not buy the room")
        XCTAssertGreaterThan(d.spinVertical, 0.4, "and the tip goes up the ball, which is what buys the")
        XCTAssertLessThanOrEqual(d.spinVertical, FrameDriver.automaticTopSpin + 1e-9, "last of the room")
        XCTAssertEqual(d.spinSide, 0, accuracy: 1e-9, "the player's side spin is not touched")

        XCTAssertTrue(d.hasRoomForTheCue, "the stroke is there")
        XCTAssertEqual(d.maximumCueDraw, FrameDriver.maxCueDraw, accuracy: 0.001)
        XCTAssertTrue(d.beginCueAction())
        d.moveCue(forwardByMillimetres: -100, over: 0.3)
        XCTAssertEqual(d.cueDraw, 100, accuracy: 0.001, "and it draws back as it always did")
    }

    /// **C** puts the cue away so the player may walk about, and lays it on the table again pointing
    /// from where they stand at the ball. Both are the same key: the stick is either the player's to
    /// hold or a thing on the table, and there is no third state.
    func testTheCueCanBePutAwayAndLaidOnTheTable() {
        let d = cueActionSetup()
        XCTAssertEqual(d.cueHandling, .laid, "the player starts with the cue at the ball")

        d.toggleCueHandling()                       // C
        XCTAssertEqual(d.cueHandling, .putAway)
        XCTAssertNil(d.cueOnTheTable, "put away, it is off the table and out of the balls' way")

        d.toggleCueHandling()                       // C again: laid on the table at the ball
        XCTAssertEqual(d.cueHandling, .laid)
        // Laid from where the player stands, pointing at the ball.
        guard let ball = d.cueBall else { return XCTFail("no cue ball") }
        let from = d.playerPosition
        XCTAssertEqual(d.aimAngle, atan2(ball.position.y - from.y, ball.position.x - from.x), accuracy: 1e-9,
                       "the cue is laid along the line from the player to the ball")
        XCTAssertTrue(d.beginCueAction(), "and it can be taken up from there")
    }

    /// A foul while the striker is playing for a **colour** leaves the incoming player on a **red**,
    /// where there are Reds left: the ball on goes back to the sequence rather than staying on the
    /// colour the striker was on (Section 3 Rule 4).
    func testAFoulWhilePlayingForAColourLeavesTheIncomingPlayerOnARed() {
        let d = driver()
        d.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
            state.redsRemaining = 1
            state.ballOn = .colourOfSequence(.black)
            state.cueBallInHand = false
            state.pending = nil
            state.scores = [40, 12]
            state.ballPositions[BallID.cue] = Vec2(600, Table.centreY)
            state.ballPositions[BallID.firstRed] = Vec2(1200, 300)
            state.ballPositions[BallID.black] = Vec2(2400, 1400)
        }
        d.syncWorldFromState()
        // Nothing touched at all: seven away, being the value of the ball on.
        d.shoot(angle: 0, power: 0.55, side: 0, vertical: 1)
        d.runStrokeToRest()
        XCTAssertEqual(d.scores, [40, 19], "the black's seven for hitting nothing")
        XCTAssertEqual(d.game.state.ballOn, .red, "and the incoming player is on a Red")
        XCTAssertFalse(d.game.state.frameOver)
    }

    /// A **colour** potted during the Reds is spotted: it is scored, and then it goes back on its spot
    /// (Section 3 Rule 3(h)(i)) — unlike a Red, which is off the table for good.
    func testColourIsSpottedAfterBeingPottedDuringTheFrame() {
        let d = driver()
        d.game.withState { state in
            // The striker has just potted a Red, so a colour is on, and it is the Blue.
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.blue]
            state.redsRemaining = 1
            state.ballOn = .anyColour
            state.nominatedColour = .blue
            state.cueBallInHand = false
            state.pending = nil
            state.scores = [30, 10]
            state.ballPositions[BallID.cue] = Vec2(737, 737)
            state.ballPositions[BallID.blue] = Vec2(400, 400)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 1400)
        }
        d.syncWorldFromState()
        // The Blue is on the diagonal into the bottom-left corner pocket; screw back off it.
        let angle = atan2(400.0 - 737.0, 400.0 - 737.0)
        d.shoot(angle: angle, power: 0.345, side: 0, vertical: -0.45)
        d.runStrokeToRest()

        XCTAssertEqual(d.scores[0], 35, "the Blue's five")
        XCTAssertTrue(d.game.state.ballsOnTable.contains(BallID.blue), "and the Blue is back on the table")
        XCTAssertEqual(d.game.state.ballPositions[BallID.blue], Table.blueSpot, "on its own spot")
    }

    /// A ball left off the table is **adjudicated when the balls come to rest**, not while they run. The
    /// ball being put on the wood part-way through the stroke is contrived on purpose: what is under test
    /// here is the adjudication — that a ball left off the table is called, and a Red is not spotted —
    /// rather than the physics that puts a ball there, which `PhysicsTests` and the rail probe have.
    func testABallOffTheTableIsAdjudicatedWhenTheRestStop() {
        let d = driver()
        d.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.redsRemaining = 1
            state.ballOn = .red
            state.cueBallInHand = false
            state.pending = nil
            state.scores = [20, 6]
            state.ballPositions[BallID.cue] = Vec2(600, Table.centreY)
            state.ballPositions[BallID.firstRed] = Vec2(1100, Table.centreY)
        }
        d.syncWorldFromState()
        d.shoot(angle: 0, power: 0.5, side: 0, vertical: 0.2)
        XCTAssertEqual(d.mode, .simulating, "the balls are running")
        // The Red comes to rest up on the wood of the rail: off the table, and called when it stops.
        d.world.setBall(Ball(id: BallID.firstRed, color: .red, position: Vec2(1100, -80),
                             height: Table.cushionHeight + Table.ballRadius))
        d.runStrokeToRest()

        XCTAssertFalse(d.game.state.ballsOnTable.contains(BallID.firstRed),
                       "a Red off the table is off: it is not spotted")
        XCTAssertEqual(d.game.state.redsRemaining, 0, "and stops counting among the Reds left")
        XCTAssertEqual(d.scores, [20, 10], "the ball on's four to the other player")
    }

    /// The last black potted ends the frame, whatever is left of the scores.
    func testFrameEndsWhenTheFinalBlackIsPotted() {
        let d = driver()
        d.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.black]
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.black)
            state.cueBallInHand = false
            state.pending = nil
            state.scores = [60, 20]
            state.ballPositions[BallID.cue] = Vec2(737, 737)
            state.ballPositions[BallID.black] = Vec2(400, 400)
        }
        d.syncWorldFromState()
        let angle = atan2(400.0 - 737.0, 400.0 - 737.0)     // the corner pocket's own diagonal
        d.shoot(angle: angle, power: 0.345, side: 0, vertical: -0.45)
        d.runStrokeToRest()

        XCTAssertEqual(d.scores[0], 67, "the Black's seven")
        XCTAssertTrue(d.isFrameOver, "and the frame is over")
        XCTAssertEqual(d.winner, 0)
    }

    /// The player can stand the cue up further, and lowering it back into the cushion is simply
    /// stopped: the cue stays at the last angle it had room at, with the spin left as it is.
    func testLoweringTheButtIntoAnObstructionIsStopped() {
        let d = cueBallOnTheCushion()
        let settled = d.cueElevation
        let tip = d.spinVertical
        d.adjustElevation(by: 10 * .pi / 180)              // up and over the cushion
        XCTAssertEqual(d.cueElevation, settled + 10 * .pi / 180, accuracy: 1e-9)
        XCTAssertEqual(d.spinVertical, tip, accuracy: 1e-9, "with the spin untouched on the way up")
        d.adjustElevation(by: -40 * .pi / 180)             // and try to lay it back down again
        XCTAssertLessThan(d.cueElevation, settled + 10 * .pi / 180, "the butt comes back down")
        XCTAssertGreaterThanOrEqual(d.cueElevation, settled - 3 * .pi / 180,
                                    "and stops where the room runs out rather than going into the cushion")
        XCTAssertEqual(d.spinVertical, tip, accuracy: 1e-9, "with no top spin added to buy the room")
        XCTAssertTrue(d.world.cueFits(cueBallID: BallID.cue, yaw: d.aimAngle, elevation: d.cueElevation,
                                      side: d.spinSide, vertical: d.spinVertical, draw: 0),
                      "and the cue left at a pose it fits in")
        XCTAssertTrue(d.hasRoomForTheCue)
    }

    /// A ball resting against the back of the cue ball is the other thing that can be in the way. The
    /// cue has to pass over it, and the cap on the lift is not enough for that: the game stands the butt
    /// up past the cap, with the tip up the ball's face, and the shot is there.
    func testABallAgainstTheBackOfTheCueBallIsClearedWithTheButtAndTheTip() {
        let d = driver()
        XCTAssertTrue(d.placeCueBall(at: Vec2(600, 889)))
        d.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.redsRemaining = 1
            state.ballOn = .red
            state.cueBallInHand = false
            state.pending = nil
            state.ballPositions[BallID.cue] = Vec2(1784, Table.centreY)
            state.ballPositions[BallID.firstRed] = Vec2(1784 - Table.ballDiameter, Table.centreY)
        }
        d.aimAngle = 0
        d.syncWorldFromState()

        XCTAssertTrue(d.needsTheCueStoodUp)
        XCTAssertEqual(d.spinVertical, FrameDriver.automaticTopSpin, accuracy: 1e-9,
                       "the tip goes up the ball, which is what lifts the line of the stick")
        XCTAssertGreaterThan(d.cueElevation, FrameDriver.automaticLiftCap,
                             "and past the cap, since a ball against the back leaves no choice")
        XCTAssertTrue(d.hasRoomForTheCue, "the shot is on")
        XCTAssertTrue(d.beginCueAction())
    }

    /// With the open table behind the ball the cue is left exactly where the player has it: no lift, no
    /// spin of the game's, and the full draw.
    func testWithRoomTheCueIsLeftAlone() {
        // Out in the open — well clear of every cushion — the cue is left exactly as the player has it:
        // level, no lift of the game's, no spin of the game's, and the full draw.
        let d = cueActionSetupInTheOpen()
        d.cueElevation = 0                                 // the player's own angle: level
        d.settleTheCue()
        XCTAssertEqual(d.cueElevation, 0, accuracy: 1e-9)
        XCTAssertEqual(d.spinVertical, 0, accuracy: 1e-9)
        XCTAssertFalse(d.needsTheCueStoodUp)
        // The backswing is as long as the table leaves it — a level cue runs lower than a raised one, so
        // the cushion behind the ball takes a little more of it than the arm's old 2.5° did — and no
        // lift or spin of the game's has been added to the player's own angle.
        XCTAssertGreaterThan(d.maximumCueDraw, 300, "a stroke's worth of room behind the ball")
        XCTAssertLessThanOrEqual(d.maximumCueDraw, FrameDriver.maxCueDraw)
        XCTAssertTrue(d.beginCueAction())
        d.moveCue(forwardByMillimetres: -2000, over: 1)
        XCTAssertEqual(d.cueDraw, d.maximumCueDraw, accuracy: 0.001,
                       "the cue comes back as far as the table allows and no further")
    }

    /// Turning the aim can put a cushion behind the ball, and the cue is settled again as the aim comes
    /// round: it is stood up for the new line rather than refused or taken off the ball.
    func testTurningTheAimSettlesTheCueAgain() {
        let d = driver()
        XCTAssertTrue(d.placeCueBall(at: Vec2(600, 889)))
        d.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.redsRemaining = 1
            state.ballOn = .red
            state.cueBallInHand = false
            state.pending = nil
            state.ballPositions[BallID.cue] = Vec2(1800, Table.centreY)   // the open table behind it
            state.ballPositions[BallID.firstRed] = Vec2(2900, Table.centreY)
        }
        d.aimAngle = 0                                    // up the table: the open end is behind the ball
        d.syncWorldFromState()
        d.cueElevation = 0                                // the player's own angle: level
        d.settleTheCue()
        XCTAssertEqual(d.cueElevation, Table.cueStanceElevation, accuracy: 1e-9)
        XCTAssertFalse(d.needsTheCueStoodUp)

        d.turnTheAim(by: .pi / 2)                         // now the side cushion is behind it
        XCTAssertTrue(d.needsTheCueStoodUp)
        XCTAssertGreaterThan(d.cueElevation, Table.cueStanceElevation,
                             "the cue has been stood up for the new line")
        XCTAssertTrue(d.hasRoomForTheCue, "and the shot is still there")
    }

    // MARK: The cue as a body, after the shot

    /// Standing up takes the player's **hand** off the stick rather than the stick off the table: it
    /// stays where the mouse left it, at the shot's own place, and it is still a body the balls are
    /// answered by — only stopped, since nobody is driving it now.
    func testStandingUpLeavesTheCueOnTheTableAsABody() {
        let d = cueActionSetup()
        d.shoot(angle: 0, power: 0.5, side: 0, vertical: 0)     // up the table into the Red
        XCTAssertNotNil(d.cueOnTheTable)
        XCTAssertTrue(d.isDownOnTheShot, "the stroke is played from down on the shot")
        let whereTheShotPutIt = d.cueOnTheTable?.tip
        d.standUp()
        XCTAssertFalse(d.isDownOnTheShot, "and standing up is the player up again")
        XCTAssertNotNil(d.cueOnTheTable, "but the stick is still a stick on the table")
        XCTAssertEqual(d.cueOnTheTable?.tip, whereTheShotPutIt, "left where the shot put it")
        XCTAssertEqual(d.cueOnTheTable?.speed ?? 1, 0, "and stopped: the hand is off it")
        d.runStrokeToRest()
        XCTAssertNil(d.lastResult?.foul, "and nothing ran into it, so nothing fouled")
    }

    /// And a ball that **does** run into it while the player is standing up is a ball met with the
    /// player's equipment, which is a foul all the same (Rule 11(b)(vi)). Putting the cue away is the
    /// thing that takes it out of the balls' way, and only that.
    func testABallThatRunsIntoTheLeftCueWhileStandingUpIsAFoul() {
        let d = cueActionSetup()
        d.game.withState { state in
            state.cueBallInHand = false
            state.pending = nil
            state.ballPositions[BallID.cue] = Vec2(1800, Table.centreY)
            state.ballPositions[BallID.firstRed] = Vec2(1800, 400)   // well clear of the line
        }
        d.syncWorldFromState()
        // Up the table into the top cushion and back along the same line, into the cue left behind the
        // ball. The player stands up as soon as the shot is away.
        d.shoot(angle: 0, power: 0.6, side: 0, vertical: 0)
        d.standUp()
        XCTAssertNotNil(d.cueOnTheTable, "the cue is left on the table")
        var t = 0.0
        while t < 30, d.mode == .simulating {
            _ = d.update(dt: 1.0 / 60.0)
            t += 1.0 / 60.0
        }
        XCTAssertTrue((d.lastStroke?.ballsTheCueTouched ?? []).contains(BallID.cue),
                      "the ball came back off the cushion into the cue")
        XCTAssertNotNil(d.lastResult?.foul, "and a ball met by the player's equipment is a foul")
    }

    /// Standing up and putting the cue away in the middle of a stroke leaves the player up and about
    /// while the balls run: free to walk around the table and watch them from wherever they like.
    func testPuttingTheCueAwayMidStrokeLeavesThePlayerUpAndAbout() {
        let d = cueActionSetup()
        d.shoot(angle: 0, power: 0.5, side: 0, vertical: 0)
        XCTAssertEqual(d.mode, .simulating, "the balls are running")
        XCTAssertTrue(d.isDownOnTheShot)

        d.standUp()                                   // S released
        XCTAssertFalse(d.isDownOnTheShot)
        d.toggleCueHandling()                         // C: the cue put away
        XCTAssertEqual(d.cueHandling, .putAway)
        XCTAssertNil(d.cueOnTheTable, "with the stick off the table")
        XCTAssertTrue(PlayerWalk.isClearOfTheTable(d.playerPosition))

        let before = d.playerPosition
        for _ in 0..<60 { d.walk(forward: -1, sideways: 0, over: 1.0 / 60) }
        XCTAssertGreaterThan(d.playerPosition.distance(to: before), 500,
                             "and the player walking about while the balls run")
        XCTAssertTrue(PlayerWalk.isClearOfTheTable(d.playerPosition))

        // Laying the cue again brings them back to the ball with it, without disturbing the stroke.
        d.toggleCueHandling()
        XCTAssertEqual(d.cueHandling, .laid)
        XCTAssertNotNil(d.cueOnTheTable)
        XCTAssertEqual(d.mode, .simulating, "the stroke is still the stroke")
    }

    /// The cue can be drawn back 400 mm, and stood right up to 90°.
    func testTheCueDrawsBackFourHundredMillimetresAndStandsUpToNinetyDegrees() {
        XCTAssertEqual(FrameDriver.maxCueDraw, 400)
        XCTAssertEqual(PhysicsWorld.maxCueElevation, 90 * .pi / 180, accuracy: 1e-12)

        let d = cueActionSetupInTheOpen()
        d.beginCueAction()
        d.moveCue(forwardByMillimetres: -5000, over: 1)
        XCTAssertEqual(d.cueDraw, 400, accuracy: 0.001, "the whole pull-back, and no more")
        d.adjustElevation(by: 5)
        XCTAssertEqual(d.cueElevation, 90 * .pi / 180, accuracy: 1e-12, "stood right up")
    }

    /// The stick is the player's hand, but it is still a stick: driven on into the table it stops where
    /// the tip touches — the cloth under it, or the cushion it is driven at — rather than passing
    /// through it. A follow-through is short because a real cue's tip comes up against the cloth, and
    /// that is inside the 250 mm the hand allows once the cue is stood up.
    func testTheCueStopsWhenTheTipComesUpAgainstTheTable() {
        let d = cueActionSetupInTheOpen()
        // A cue stood up 30°: the tip has only a ball radius of cloth below it and comes down to meet it
        // in about 50 mm of travel, well inside `maxFollowThrough`.
        d.shoot(angle: 0, power: 0.3, side: 0, vertical: 0, elevation: 30 * .pi / 180)
        // Pushing the stick on up the table, far further than the tip has cloth to travel over.
        for _ in 0..<240 {
            d.carryTheCue(forwardByMillimetres: 60, over: 1.0 / 60)
            guard d.mode == .simulating else { break }
            d.update(dt: 1.0 / 120.0)
        }
        guard let cue = d.cueOnTheTable else { return XCTFail("the cue is on the table") }
        XCTAssertTrue(d.world.theCueTipCanStand(at: cue.tip, along: cue.axis),
                      "wherever it stopped, the tip is somewhere it can stand")
        XCTAssertLessThan(Vec2(cue.tip.x, cue.tip.y).distance(to: d.strokeWasPlayedFrom),
                          FrameDriver.maxFollowThrough,
                          "the cloth stopped it inside the follow-through")
        XCTAssertLessThan(d.cueTravelSpeed, 60, "having stopped there rather than carrying on")
        // The tip is at the table, not through it: the dome is on the cloth where it stopped.
        XCTAssertEqual(PhysicsWorld.theTipReachesDownTo(tip: cue.tip, along: cue.axis), 0, accuracy: 0.5,
                       "the tip is standing on the cloth")
    }

    /// The cue's follow-through is the player's own hand, and it runs out at `maxFollowThrough`: pushed
    /// on after the strike, the tip is carried the whole 250 mm from the middle of the ball and no
    /// further. A level cue in the open never meets the cloth first, so the cap is what stops it.
    func testTheFollowThroughStopsAtTwoHundredAndFiftyMillimetres() {
        XCTAssertEqual(FrameDriver.maxFollowThrough, 250)
        let d = cueActionSetupInTheOpen()
        d.shoot(angle: 0, power: 0.3, side: 0, vertical: 0)
        let before = d.cueOnTheTable?.tip ?? .zero
        for _ in 0..<120 {
            d.carryTheCue(forwardByMillimetres: 60, over: 1.0 / 60)
            guard d.mode == .simulating else { break }
            d.update(dt: 1.0 / 120.0)
        }
        guard let cue = d.cueOnTheTable else { return XCTFail("the cue is on the table") }
        XCTAssertGreaterThan((cue.tip - before).length, 20, "and it was driven on")
        XCTAssertEqual(Vec2(cue.tip.x, cue.tip.y).distance(to: d.strokeWasPlayedFrom),
                       FrameDriver.maxFollowThrough, accuracy: 0.5,
                       "the tip is carried the whole follow-through, and no more")
        XCTAssertLessThan(d.cueTravelSpeed, 60, "having stopped there rather than carrying on")
        XCTAssertTrue(d.world.theCueTipCanStand(at: cue.tip, along: cue.axis),
                      "and it is nowhere it may not stand")
    }

    /// Charges a shot to `power`, lets it go, and runs the stroke with **no hand on the cue** — the
    /// mouse is never moved — reporting how far the tip was carried from the middle of the ball it
    /// struck, how fast it was going as it went, and over how many frames.
    private func chargedShotFollowThrough(power: Double)
        -> (travelled: Double, speeds: [Double], movingFrames: Int) {
        let d = cueActionSetupInTheOpen()
        d.beginCharge(at: 0)
        // The meter fills from `minimumChargePower` over 1.1 s, so this is the time that leaves it at
        // the power asked for.
        d.updateCharge(at: (power - FrameDriver.minimumChargePower) * 1.1)
        XCTAssertEqual(d.power, power, accuracy: 0.001, "the charge is where the probe asked for")
        d.releaseShot()
        let from = d.strokeWasPlayedFrom
        var travelled = 0.0
        var speeds: [Double] = []
        var movingFrames = 0
        var frames = 0
        while d.mode == .simulating, frames < 60 * 30 {
            d.update(dt: 1.0 / 120.0)
            frames += 1
            guard let cue = d.cueOnTheTable else { break }
            let distance = Vec2(cue.tip.x, cue.tip.y).distance(to: from)
            if distance > travelled + 0.001 {
                travelled = distance
                movingFrames += 1
                speeds.append(d.cueTravelSpeed)
            }
        }
        return (travelled, speeds, movingFrames)
    }

    /// A **charged** shot is carried through by the game itself — the hand is on the button and not on the
    /// cue — and at **one speed all the way**: the speed the stick struck the ball with, held constant for
    /// the whole of the follow-through. Nothing of the hand is in it.
    func testAChargedShotIsCarriedThroughAtTheSpeedItStruckWith() {
        let full = chargedShotFollowThrough(power: 1)
        let strikeSpeed = FrameDriver.maxPower / (1 + FrameDriver.cueTipRestitution)
        XCTAssertEqual(full.travelled, FrameDriver.maxFollowThrough, accuracy: 2,
                       "a full charge is carried the whole follow-through, measured from the ball's middle")
        XCTAssertGreaterThan(full.speeds.count, 2, "and the stick was carried on")
        // Every **full** step of the travel is at the speed the stick struck with; the last step is the
        // short one that lands the tip exactly on the length, and is the only one that is slower.
        for speed in full.speeds.dropLast() {
            XCTAssertEqual(speed, strikeSpeed, accuracy: strikeSpeed * 0.02,
                           "at the speed it struck with, the same speed all the way")
        }
        XCTAssertLessThanOrEqual(full.speeds.last ?? 0, strikeSpeed, "and never faster than the strike")
        // The travel takes the length over that speed, give or take the strike's own hold — which carries
        // the tip with the ball for a fraction of the first frame — and the short step at the end.
        XCTAssertEqual(Double(full.movingFrames), full.travelled / strikeSpeed * 120, accuracy: 3,
                       "and the travel takes the length over that speed, neither hurrying nor dawdling")
    }

    /// The length of that follow-through is **linear in the strength** of the shot: the gentlest a charge
    /// will go is `leastChargedFollowThrough` and full power is the whole of `maxFollowThrough`, with the
    /// shots between them in proportion.
    func testAChargedShotsFollowThroughIsLinearInItsStrength() {
        XCTAssertEqual(FrameDriver.chargedFollowThroughLength(of: FrameDriver.minimumChargePower),
                       FrameDriver.leastChargedFollowThrough, accuracy: 0.001,
                       "the gentlest the meter will go is the shortest follow-through")
        XCTAssertEqual(FrameDriver.chargedFollowThroughLength(of: 1), FrameDriver.maxFollowThrough,
                       accuracy: 0.001, "and full power is all of it")
        let halfway = (FrameDriver.minimumChargePower + 1) / 2
        XCTAssertEqual(FrameDriver.chargedFollowThroughLength(of: halfway),
                       (FrameDriver.leastChargedFollowThrough + FrameDriver.maxFollowThrough) / 2,
                       accuracy: 0.001, "half way up the strength is half way along the length")

        let gentle = chargedShotFollowThrough(power: FrameDriver.minimumChargePower)
        let half = chargedShotFollowThrough(power: 0.5)
        let full = chargedShotFollowThrough(power: 1)
        XCTAssertEqual(gentle.travelled, FrameDriver.leastChargedFollowThrough, accuracy: 2,
                       "and the gentlest charge is carried the shortest distance of all")
        XCTAssertEqual(half.travelled, FrameDriver.chargedFollowThroughLength(of: 0.5), accuracy: 2,
                       "a half-charged shot is carried half way along")
        XCTAssertEqual(full.travelled, FrameDriver.maxFollowThrough, accuracy: 2)
    }

    /// **A charge sets the cue's own speed**, and everything the cue ball does comes out of that and the
    /// point on the ball the tip is striking: a centre hit sends it away at `1 + e` times the cue's speed,
    /// and the further off centre the tip is, the more of the same impulse goes on spin and the less is
    /// left for travel. Nothing sets the ball's speed alongside the cue's.
    func testAChargedShotSetsTheCuesSpeedAndTheStrikeDecidesTheBall() {
        for (side, vertical) in [(0.0, 0.0), (0.5, -0.2), (0.0, -0.5), (0.9, 0.0)] {
            let d = cueActionSetupInTheOpen()
            d.setSpin(side: side, vertical: vertical)
            let power = 0.6
            d.beginCharge(at: 0)
            d.updateCharge(at: (power - FrameDriver.minimumChargePower) * 1.1)
            XCTAssertEqual(d.power, power, accuracy: 0.001)
            d.releaseShot()

            // The stick is at its own speed at the moment it touched the ball — the meter's fraction of the
            // fastest a cue may be travelling — and the ball's speed is that speed put through the strike.
            let cueSpeed = FrameDriver.maxCueSpeed * power
            XCTAssertEqual(d.cueTravelSpeed, cueSpeed, accuracy: cueSpeed * 0.001,
                           "the meter sets the cue's speed, and the cue does not change speed on the ball")
            // The strike sends the ball away **along the cue's own line** at the speed the model gives for
            // that cue speed and that point on the ball; what the ball's velocity *along the cloth* is of
            // that depends on the angle the cue stands at, since a lifted cue drives the ball down into it.
            let alongTheCue = FrameDriver.ballSpeed(fromCueSpeed: cueSpeed, tipOffset: d.tipOffset)
            XCTAssertEqual(d.cueBall?.velocity.length ?? 0, alongTheCue * cos(d.cueElevation), accuracy: 1,
                           "and the ball's speed is what the strike makes of that speed at that point")
        }
    }

    /// The frame reports every contact as it happens — what kind, where on the table, and how hard —
    /// and reports nothing it did not make: the view plays what it is handed and has nothing else.
    func testTheFrameReportsTheContactsItMade() {
        func runOut(_ d: FrameDriver) -> [FrameDriver.Impact] {
            var made: [FrameDriver.Impact] = []
            for _ in 0..<1200 {
                _ = d.update(dt: 1.0 / 120.0)
                made += d.takeImpacts()
                if d.mode != .simulating { break }
            }
            return made
        }
        func aShot(at power: Double) -> (driver: FrameDriver, made: [FrameDriver.Impact]) {
            let d = cueActionSetupInTheOpen()
            d.game.withState { state in
                state.ballPositions[BallID.cue] = Vec2(1000, Table.centreY)
                state.ballPositions[BallID.firstRed] = Vec2(2200, Table.centreY)
            }
            d.syncWorldFromState()
            d.aimAngle = 0
            d.shoot(angle: 0, power: power, side: 0, vertical: 0)
            return (d, runOut(d))
        }

        let gentle = aShot(at: 0.10)
        let firm = aShot(at: 1.0)

        let gentleStrike = gentle.made.first { $0.kind == .strike }
        let firmStrike = firm.made.first { $0.kind == .strike }
        XCTAssertNotNil(gentleStrike, "the stroke is a contact, and it is the first of them")
        XCTAssertEqual(gentleStrike?.at, Vec2(1000, Table.centreY), "reported where the ball was")
        XCTAssertGreaterThan(firmStrike?.speed ?? 0, (gentleStrike?.speed ?? 0) * 3,
                             "and the harder stroke is the harder contact")

        XCTAssertTrue(firm.made.contains { $0.kind == .ballOnBall }, "the cue ball met the red")
        XCTAssertTrue(firm.made.contains { $0.kind == .cushion && $0.speed > 0 },
                      "a ball on the rubber, with the speed it met it at")
        for impact in firm.made {
            XCTAssertGreaterThanOrEqual(impact.speed, 0, "\(impact.kind) has a speed")
        }

        XCTAssertTrue(firm.driver.takeImpacts().isEmpty, "reading a frame's contacts takes them")
        XCTAssertTrue(runOut(firm.driver).isEmpty, "and a frame with nothing in it makes no noise")
    }

    /// A cue delivered at a steady speed and left where the shot was played must not be said to have
    /// struck the ball twice when the ball runs up the table, comes off a cushion and comes back to
    /// the tip — a second contact there is a second strike (Rule 11(a)(ii)).
    func testACueBallComingBackToTheParkedCueIsASecondHit() {
        let d = shotSetup()
        XCTAssertTrue(d.beginCueAction())
        deliverTheCue(d, at: FrameDriver.maxCueSpeed, followThrough: 0)
        XCTAssertTrue((d.lastStroke?.ballsTheCueTouched ?? []).contains(BallID.cue),
                      "the ball came back to the cue: a second contact")
        // The call is timed: the ball ran up the table and came back, so the gap is not a millisecond
        // or two but most of a second, and the caption says so.
        let reason = d.lastResult?.foul?.reason ?? ""
        XCTAssertTrue(reason.hasPrefix("the cue struck the cue ball a second time"), reason)
        XCTAssertTrue(reason.hasSuffix("ms after the first contact)"), reason)
        XCTAssertNotNil(d.lastStroke?.secondsUntilTheCueBallWasStruckAgain)
        XCTAssertGreaterThan(d.lastStroke?.secondsUntilTheCueBallWasStruckAgain ?? 0, 0.2,
                             "the ball had time to go up the table and back")
    }

    /// A cue driven through the ball faster than it can be played — a flick, above `maxCueSpeed` — and
    /// followed through must not run the ball down from behind. The stick cannot move faster than the
    /// shot that came off it, so its travel is capped at the same speed the shot's strength is: the
    /// ball, leaving at `1.75` times that, outruns the tip. Put the cue away shortly after the ball
    /// leaves and nothing can reach it either.
    func testAFastFollowThroughDoesNotRunTheBallDown() {
        let d = shotSetup()
        XCTAssertTrue(d.beginCueAction())
        deliverTheCue(d, at: 4 * FrameDriver.maxCueSpeed, followThrough: 4 * FrameDriver.maxCueSpeed,
                      putAwayAfter: 0.12)
        XCTAssertFalse((d.lastStroke?.ballsTheCueTouched ?? []).contains(BallID.cue),
                       "the stick cannot run down the ball it has just struck")
        XCTAssertFalse(d.lastResult?.foul?.reason.contains("second time") ?? false)
    }

    /// A driver with the cue ball out in the open and a Red well clear of the shot, ready for the cue
    /// to be delivered by hand.
    private func shotSetup() -> FrameDriver {
        let d = cueActionSetupInTheOpen()
        d.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.redsRemaining = 1
            state.ballOn = .red
            state.cueBallInHand = false
            state.pending = nil
            state.ballPositions[BallID.cue] = Vec2(1784, Table.centreY)
            state.ballPositions[BallID.firstRed] = Vec2(3000, 200)
        }
        d.syncWorldFromState()
        return d
    }

    /// Draws the cue back and drives it through the ball at `speed`, then runs the stroke out. After
    /// the strike the mouse keeps carrying the cue at `followThrough` mm/s (0 leaves it where it is),
    /// and `putAwayAfter` seconds later the player stands up and **puts the cue away** — which is what
    /// takes it off the table and out of the balls' way. The run is bounded by the driver's own
    /// 25-second stroke cap.
    private func deliverTheCue(_ d: FrameDriver, at speed: Double, followThrough: Double,
                               putAwayAfter: Double? = nil) {
        let dt = 1.0 / 60.0
        var drawn = 0.0
        while drawn < 120 {
            d.moveCue(forwardByMillimetres: -speed * dt, over: dt)
            drawn += speed * dt
        }
        var t = 0.0
        var putAway = false
        while t < 30, d.mode == .charging || d.mode == .simulating {
            if d.mode == .charging {
                _ = d.moveCue(forwardByMillimetres: speed * dt, over: dt)
            } else {
                if let after = putAwayAfter, !putAway, t > after {
                    putAway = true
                    d.standUp()
                    d.toggleCueHandling()
                }
                _ = d.update(dt: dt)
                d.carryTheCue(forwardByMillimetres: followThrough * dt, over: dt)
            }
            t += dt
        }
    }

    /// The spin control stops where the ball can no longer outrun the cue — `PhysicsWorld.spinRange` —
    /// which is inside the leather's own grip and is taken in as the cue stands up. A level cue's limit
    /// is `√0.3` of a radius, where the ball leaves at the cue's own speed; the chalked tip's 0.8 of
    /// friction grips to 0.625 of a radius, so it is the ball's speed that stops the control, not the
    /// leather. Standing the cue up gives up the part of the strike that goes down into the cloth, and
    /// the limit closes with it.
    func testTheSpinLimitKeepsTheBallInFrontOfTheCue() {
        let level = Table.cueStanceElevation
        XCTAssertEqual(PhysicsWorld.cueTipFriction, 0.8, accuracy: 1e-12)
        XCTAssertGreaterThan(PhysicsWorld.cueTipOffsetLimit, 0.6, "the leather grips past half a radius")

        // A level cue: the ball's own speed is the limit, and it is inside the leather's grip.
        for degrees in stride(from: 0.0, to: 360.0, by: 30.0) {
            let angle = degrees * .pi / 180
            let limit = PhysicsWorld.spinLimit(angle: angle, elevation: level)
            XCTAssertEqual(limit, 0.3.squareRoot(), accuracy: 0.01,
                           "√0.3 is the level cue's limit at \(degrees)°")
            XCTAssertLessThan(limit, PhysicsWorld.cueTipOffsetLimit, "inside the leather")
            XCTAssertGreaterThanOrEqual(
                PhysicsWorld.separationAlongTheCue(offset: limit, angle: angle, elevation: level),
                1, "\(degrees)°: the ball outruns the cue at the limit")
            XCTAssertLessThan(
                PhysicsWorld.separationAlongTheCue(offset: limit + 0.03, angle: angle, elevation: level),
                1, "and not past it")
        }

        // The control is the player's, so a drag past the limit is kept — the widget's lines are
        // guidance, not a fence — and it is the strike that settles the spin on the leather's grip.
        let clamped = shotSetup()
        clamped.adjustSpin(side: 5, vertical: 5)
        let settled = (clamped.spinSide * clamped.spinSide
                       + clamped.spinVertical * clamped.spinVertical).squareRoot()
        XCTAssertEqual(settled, PhysicsWorld.maximumTipOffset, accuracy: 1e-9,
                       "the tip is put where the player asked")
        XCTAssertEqual(clamped.spinSide > 0, clamped.spinVertical > 0, "on the line it was pushed")

        // Standing the cue up gives up the part of the strike that goes into the cloth, and the outer
        // limit closes with it.
        let levelDraw = PhysicsWorld.spinLimit(angle: -.pi / 2, elevation: level)
        let raisedDraw = PhysicsWorld.spinLimit(angle: -.pi / 2, elevation: 30 * .pi / 180)
        XCTAssertLessThan(raisedDraw, levelDraw, "a raised cue screws less")
        XCTAssertEqual(PhysicsWorld.spinLimit(angle: -.pi / 2, elevation: 45 * .pi / 180), 0,
                       accuracy: 1e-9, "and by 45° the screw has closed")

        // The second run: at 30° a heavy follow is allowed even though the offsets just inside it are
        // not — the ball has to be spinning hard enough that the cloth's friction pushes it on.
        let runs = PhysicsWorld.spinRange(angle: .pi / 2, elevation: 30 * .pi / 180)
        XCTAssertEqual(runs.count, 2, "a dead band between two runs of follow")
        XCTAssertEqual(runs[0].lower, 0, accuracy: 1e-9, "the first run starts at the middle")
        XCTAssertGreaterThan(runs[1].lower, 0.3, "the second starts out past the dead band")
        XCTAssertGreaterThan(runs[1].upper, runs[1].lower)
        XCTAssertLessThan(runs[0].upper, runs[1].lower, "with the gap between them")

        // A player dragged into the dead band is settled on the nearer run, not on the middle.
        let dead = (runs[0].upper + runs[1].lower) / 2
        let nearer = PhysicsWorld.allowedSpin(dead, angle: .pi / 2, elevation: 30 * .pi / 180)
        XCTAssertTrue(abs(nearer - runs[0].upper) < 1e-6 || abs(nearer - runs[1].lower) < 1e-6,
                      "the dead band is not allowed")
        XCTAssertEqual(PhysicsWorld.allowedSpin(0.36, angle: .pi / 2, elevation: 30 * .pi / 180),
                       0.36, accuracy: 1e-9, "but the second run is")
    }

}
