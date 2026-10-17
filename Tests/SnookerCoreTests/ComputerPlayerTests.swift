import XCTest
@testable import SnookerCore

/// The computer player: the geometry it aims by, the strokes it picks, the questions it answers, and a
/// frame played out with nobody at the table.
final class ComputerPlayerTests: XCTestCase {

    // MARK: - Set-ups

    /// One Red on the line into the bottom-left corner pocket, with the colours on their spots and the cue
    /// ball out on the cloth behind it — **not** in the "D", where the cue has no room to be drawn back and
    /// the game's own answer is a gentle shot. A player's stroke is a cue with a backswing in it: see
    /// `testAChargedStrokeSendsTheCueBallWhereItWasAimed`.
    private func straightRedSetup() -> FrameDriver {
        let driver = FrameDriver(playerNames: ["A", "B"])
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.yellow, BallID.green,
                                  BallID.brown, BallID.blue, BallID.pink, BallID.black]
            state.redsRemaining = 1
            state.ballOn = .red
            state.ballPositions[BallID.firstRed] = Vec2(400, 400)
            state.ballPositions[BallID.cue] = Vec2(2000, Table.centreY)
            state.cueBallInHand = false
            state.pending = nil
        }
        driver.syncWorldFromState()
        driver.load(driver.game.state)
        return driver
    }

    /// Only the Black left, player 0 eight points ahead and at the table.
    private func blackOnlySetup() -> FrameDriver {
        let driver = FrameDriver(playerNames: ["A", "B"])
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.black]
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.black)
            state.ballPositions[BallID.black] = Table.blackSpot
            state.ballPositions[BallID.cue] = Vec2(1200, Table.centreY)
            state.scores = [50, 40]
            state.currentPlayer = 0
            state.cueBallInHand = false
            state.pending = nil
        }
        driver.syncWorldFromState()
        return driver
    }

    // MARK: - The geometry

    func testTheGeometryFindsThePotDownTheCornerLine() {
        let layout = BallLayout(cue: Vec2(737, 737),
                                placed: [BallLayout.Placed(id: BallID.firstRed,
                                                           position: Vec2(400, 400))])
        let pots = ShotGenerator.pots(layout: layout, targets: [BallID.firstRed])
        guard let first = pots.first else { return XCTFail("no pot was found at all") }
        guard case .pot(let ball, let pocket, let cut) = first.intent else {
            return XCTFail("the best shot was not a pot: \(first.intent)")
        }
        XCTAssertEqual(ball, BallID.firstRed)
        XCTAssertEqual(pocket, .bottomLeft, "the red is on the corner line and that is the pocket it is on")
        XCTAssertLessThan(cut * 180 / .pi, 2, "and it is dead straight, so the cut is nothing")
    }

    func testTheGeometryFindsNoPotThroughABlocker() {
        // The same line, with a second red sitting in the way of the cue ball.
        let layout = BallLayout(cue: Vec2(737, 737), placed: [
            BallLayout.Placed(id: BallID.firstRed, position: Vec2(400, 400)),
            BallLayout.Placed(id: BallID.firstRed + 1, position: Vec2(560, 560)),
        ])
        let pots = ShotGenerator.pots(layout: layout, targets: [BallID.firstRed])
        XCTAssertTrue(pots.isEmpty, "a ball in the way of the cue ball is not a pot")
    }

    func testTheGeometryFindsAWayRoundToABallItCannotSee() {
        // The cue ball and a red up the same line, with the black squarely between them: no straight line
        // to the red, and a way round to it off the side cushion.
        let cue = Vec2(3000, 400)
        let red = Vec2(3000, 1400)
        let blocker = Vec2(3000, 900)
        let layout = BallLayout(cue: cue, placed: [
            BallLayout.Placed(id: BallID.firstRed, position: red),
            BallLayout.Placed(id: BallID.black, position: blocker),
        ])
        let others = layout.leavingOut([BallID.cue])
        guard case .ball(let straightAt, _)? = ShotGeometry.firstContact(
            from: cue, direction: ShotGeometry.direction(cue, red), balls: others) else {
            return XCTFail("something has to be met along that line")
        }
        XCTAssertEqual(straightAt, BallID.black, "the red cannot be reached straight: the black is in the way")

        let route = ShotGeometry.routeOffACushion(from: cue, to: red, target: BallID.firstRed,
                                                  off: .left, past: others)
        XCTAssertNotNil(route, "but it can be reached off the bottom cushion")
        guard let route else { return }
        XCTAssertEqual(route.bounce.x, Table.ballRadius, accuracy: 1e-6,
                       "the cue ball meets the cushion where its centre passes a radius inside it")
        XCTAssertGreaterThan(route.bounce.y, cue.y, "and the bounce is between the two balls")
        XCTAssertLessThan(route.bounce.y, red.y)
    }

    func testTheWayRoundIsRefusedWhenSomethingIsInIt() {
        let cue = Vec2(3000, 400)
        let red = Vec2(3000, 1400)
        let layout = BallLayout(cue: cue, placed: [
            BallLayout.Placed(id: BallID.firstRed, position: red),
            // A ball sitting on the line the cue ball would take **to** the cushion, where the way to the
            // ball it is aiming at runs.
            BallLayout.Placed(id: BallID.black, position: Vec2(1500, 652)),
        ])
        XCTAssertNil(ShotGeometry.routeOffACushion(from: cue, to: red, target: BallID.firstRed,
                                                   off: .left, past: layout.leavingOut([BallID.cue])),
                     "a ball on the way is not a way round")
    }

    func testACushionKeepsLessOfTheAngleTheHarderItIsHit() {
        XCTAssertEqual(ShotGeometry.cushionHold(forNormalSpeed: 0), 0.892, accuracy: 0.001)
        XCTAssertEqual(ShotGeometry.cushionHold(forNormalSpeed: 4000), 0.71, accuracy: 0.01)
        XCTAssertLessThan(ShotGeometry.cushionHold(forNormalSpeed: 4000),
                          ShotGeometry.cushionHold(forNormalSpeed: 500))
        // And it never runs away with itself: a cushion is not steeper than a mirror, nor a wall.
        XCTAssertLessThanOrEqual(ShotGeometry.cushionHold(forNormalSpeed: -5000), 1)
        XCTAssertGreaterThanOrEqual(ShotGeometry.cushionHold(forNormalSpeed: 99_000), 0.65)
    }

    func testAnEscapeHasToKeepClearOfTheBallsItIsNotAimingAt() {
        // A black a hair outside the line from the cue ball to a red: a shot that grazes it, and a foul.
        let cue = Vec2(500, Table.centreY)
        let red = Vec2(2500, Table.centreY)
        let graze = Vec2(1500, Table.centreY + Table.ballDiameter + 2)
        let balls = [BallLayout.Placed(id: BallID.firstRed, position: red),
                     BallLayout.Placed(id: BallID.black, position: graze)]
        let direction = ShotGeometry.direction(cue, red)
        guard case .ball(let straight, _)? = ShotGeometry.firstContact(from: cue, direction: direction,
                                                                      balls: balls) else {
            return XCTFail("the red is straight ahead")
        }
        XCTAssertEqual(straight, BallID.firstRed, "the red is what a perfectly played shot meets")
        guard case .ball(let withMargin, _)? = ShotGeometry.firstContact(from: cue, direction: direction,
                                                                        balls: balls, margin: 5) else {
            return XCTFail("the black is inside the margin")
        }
        XCTAssertEqual(withMargin, BallID.black,
                       "and within five millimetres of it the shot is a graze, not a shot")
    }

    func testALineAcrossAPocketIsNotAWayToReachAnything() {
        // Straight down the middle, over the mouth of the bottom middle pocket, and a line beside it.
        let middle = Table.length / 2
        XCTAssertFalse(ShotGeometry.pathKeepsOutOfThePockets(from: Vec2(middle, 900),
                                                              to: Vec2(middle, 0)),
                       "that line runs over the mouth of the middle pocket")
        XCTAssertTrue(ShotGeometry.pathKeepsOutOfThePockets(from: Vec2(middle + 200, 900),
                                                            to: Vec2(middle + 200, 0)),
                      "and that one does not")
    }

    func testAShotLosesSpeedAsItRolls() {
        XCTAssertEqual(ShotGeometry.speedAfter(travelling: 0, from: 1000), 1000, accuracy: 1e-6)
        XCTAssertLessThan(ShotGeometry.speedAfter(travelling: 2000, from: 1000),
                          ShotGeometry.speedAfter(travelling: 500, from: 1000))
        XCTAssertEqual(ShotGeometry.speedAfter(travelling: 100_000, from: 1000), 0,
                       "a shot that cannot get there has no speed left when it does")
    }

    // MARK: - How hard the computer is to play

    func testEachDifficultyHasACueActionOfItsOwn() {
        XCTAssertEqual(ComputerPlayer.Difficulty.easy.aimErrorDegrees, 0.2, accuracy: 1e-9)
        XCTAssertEqual(ComputerPlayer.Difficulty.medium.aimErrorDegrees, 0.1, accuracy: 1e-9)
        XCTAssertEqual(ComputerPlayer.Difficulty.hard.aimErrorDegrees, 0.03, accuracy: 1e-9)
        // A harder computer is a straighter cue: that is most of what the setting means.
        XCTAssertLessThan(ComputerPlayer.Difficulty.hard.aimError,
                          ComputerPlayer.Difficulty.medium.aimError)
        XCTAssertLessThan(ComputerPlayer.Difficulty.medium.aimError,
                          ComputerPlayer.Difficulty.easy.aimError)
    }

    func testAPlayersCueActionFollowsItsDifficulty() {
        let computer = ComputerPlayer(playerIndex: 0, difficulty: .easy)
        XCTAssertEqual(computer.aimError, ComputerPlayer.Difficulty.easy.aimError)
        computer.difficulty = .hard
        XCTAssertEqual(computer.aimError, ComputerPlayer.Difficulty.hard.aimError,
                       "changing how hard it thinks changes how well it plays too")
        XCTAssertEqual(computer.rolloutBudget, ComputerPlayer.Difficulty.hard.rolloutBudget)
    }

    // MARK: - Thinking ahead

    func testLookingFurtherAheadPlaysMoreShotsOut() {
        // The search plays its own shots out, so thinking three shots ahead costs more played-out shots
        // than thinking one — and the shot it settles on is still a shot it can play.
        let shallow = ComputerPlayer(playerIndex: 0, difficulty: .medium)
        shallow.aimError = 0
        shallow.depth = 1
        let deep = ComputerPlayer(playerIndex: 0, difficulty: .medium)
        deep.aimError = 0
        deep.depth = 3
        guard let one = shallow.bestShot(for: straightRedSetup()) else { return XCTFail("no shot at depth 1") }
        let oneRollouts = shallow.rolloutsLastDecision
        guard let three = deep.bestShot(for: straightRedSetup()) else { return XCTFail("no shot at depth 3") }
        XCTAssertGreaterThanOrEqual(deep.rolloutsLastDecision, oneRollouts,
                                    "three shots ahead is at least as much work as one")
        // And both are strokes that can be played: a pot, a safety or an escape.
        for choice in [one, three] {
            switch choice.intent {
            case .pot, .safety, .escape: break
            }
            XCTAssertTrue(choice.shot.power > 0 && choice.shot.power <= 1)
        }
    }

    func testTheShotIsTunedInEveryOneOfItsControls() {
        // The strength, both spins and the lift of the cue are the shot, and the search tries them all:
        // a hard search with a fallible cue is allowed to move any of them.
        let computer = ComputerPlayer(playerIndex: 0, difficulty: .hard)
        XCTAssertFalse(computer.powerRefinements.isEmpty)
        XCTAssertFalse(computer.spinVariants.filter { $0 != 0 }.isEmpty)
        XCTAssertFalse(computer.sideSpins.filter { $0 != 0 }.isEmpty)
        XCTAssertFalse(computer.elevations.filter { $0 != 0 }.isEmpty)
        let easy = ComputerPlayer(playerIndex: 0, difficulty: .easy)
        XCTAssertTrue(easy.sideSpins.filter { $0 != 0 }.isEmpty,
                      "an easy computer does not tune the tip or the butt at all")
        XCTAssertTrue(easy.elevations.filter { $0 != 0 }.isEmpty)
    }

    func testTheBlackIsWorthMoreThanTheYellowInTheSamePosition() {
        // The same ball on the same line into the same pocket, as the black and then as the yellow: how
        // hard the pot is is identical, and what it is worth is not. A break is built by playing for the
        // black, and the player's own judgement has to say so.
        let computer = ComputerPlayer(playerIndex: 0, difficulty: .easy)
        var state = straightRedSetup().game.state
        state.pending = nil
        state.cueBallInHand = false
        state.ballOn = .colourOfSequence(.black)
        state.ballPositions[BallID.black] = Vec2(400, 400)
        state.ballPositions[BallID.yellow] = Table.yellowSpot
        let onTheBlack = computer.positionValue(of: state)
        state.ballOn = .colourOfSequence(.yellow)
        state.ballPositions[BallID.yellow] = Vec2(400, 400)
        state.ballPositions[BallID.black] = Table.blackSpot
        let onTheYellow = computer.positionValue(of: state)
        XCTAssertGreaterThan(onTheBlack, onTheYellow)
    }

    func testTheComputerAsksForAReRackRatherThanFoulingForEver() {
        // A position neither player can do anything with: asked about it again and again, the computer
        // stops choosing shots and asks for the frame to be racked again (Section 3 Rule 17). Without
        // this, two of them foul at each other from the same position until the frame's stroke limit.
        let driver = straightRedSetup()
        let computer = ComputerPlayer(playerIndex: 0, difficulty: .easy)
        computer.rolloutBudget = 3
        computer.settings.potLimit = 3
        computer.settings.safetyLimit = 1
        var asked = 0
        var sawAReRack = false
        for _ in 0..<10 {
            asked += 1
            if computer.nextAction(for: driver) == .reRack { sawAReRack = true; break }
        }
        XCTAssertTrue(sawAReRack, "it never asked, after \(asked) decisions about the same position")
        XCTAssertLessThanOrEqual(asked, 8, "and it asks within a few decisions rather than at once")
    }

    func testTheSpeedToRollABallGrowsWithTheDistance() {
        XCTAssertLessThan(ShotGeometry.speedToTravel(500), ShotGeometry.speedToTravel(2000))
        // The constant is the one `--ai-roll` measures: the physics has a ball struck at 600 mm/s
        // travelling about 1.1 m, and the estimate has to agree with it.
        XCTAssertEqual(ShotGeometry.travel(fromSpeed: 600), 1095, accuracy: 120)
        XCTAssertEqual(ShotGeometry.speedToTravel(1095), 600, accuracy: 30)
    }

    // MARK: - Playing a stroke

    func testTheComputerPotsARedThatIsOn() {
        let driver = straightRedSetup()
        let computer = ComputerPlayer(playerIndex: 0, difficulty: .medium)
        computer.aimError = 0
        guard let choice = computer.bestShot(for: driver) else { return XCTFail("no shot was found") }
        if case .pot = choice.intent {} else { XCTFail("the red is dead on: it should be a pot, not \(choice.intent)") }

        choice.shot.play(on: driver)
        driver.runStrokeToRest()
        XCTAssertNotNil(driver.lastResult, "the stroke was played")

        XCTAssertTrue((driver.lastStroke?.potted ?? []).contains(BallID.firstRed),
                      "the red went down: \(choice.intent.summary) — \(choice.shot.describedForTheLog)")
        XCTAssertNil(driver.lastResult?.foul, "and nothing was fouled")
        XCTAssertEqual(driver.scores[0], 1)
    }

    /// Plays one charge of the straight pot and says what came of it: whether the red went down, and what
    /// strength the stroke turned out to be worth.
    private func playOneCharge(_ power: Double) -> (potted: Bool, strength: Double) {
        let driver = straightRedSetup()
        let cueBall = Vec2(2000, Table.centreY)
        let ghost = Vec2(400, 400) + Vec2(1, 1).normalized * Table.ballDiameter
        let angle = atan2(ghost.y - cueBall.y, ghost.x - cueBall.x)
        let probe = FrameDriver(playerNames: ["A", "B"])
        probe.load(driver.game.state)
        probe.playCharged(Shot(angle: angle, power: power), at: 0)
        probe.runStrokeToRest()
        return ((probe.lastStroke?.potted ?? []).contains(BallID.firstRed), probe.power)
    }

    func testAChargedStrokeIsTheCueActionAPlayerPlays() {
        // The pot played the way a player plays it: a charge, and the cue's own run through the ball. Too
        // gentle and the ball does not get there; enough and it goes in; and past what the room behind the
        // ball allows the strength stops rising, because the cue cannot be drawn back any further. It is
        // the stroke the search plays its candidates out with, so this is the one the whole plan stands on.
        XCTAssertFalse(playOneCharge(0.10).potted, "a charge too soft never reached the red")
        XCTAssertTrue(playOneCharge(0.30).potted, "and a proper one pots it")
        XCTAssertEqual(playOneCharge(0.7).strength, playOneCharge(1.0).strength, accuracy: 1e-9,
                       "the room behind the ball caps what a charge can be worth")
    }

    func testTheComputerLeavesTheCueBallOnTheTableWhenItPots() {
        // A straight pot with the cue ball rolling after the red goes in behind it: the shot is only a
        // shot if the computer finds the screw that holds the cue ball back.
        let driver = straightRedSetup()
        let computer = ComputerPlayer(playerIndex: 0, difficulty: .medium)
        computer.aimError = 0
        guard let choice = computer.bestShot(for: driver) else { return XCTFail("no shot was found") }
        choice.shot.play(on: driver)
        driver.runStrokeToRest()
        XCTAssertFalse(driver.game.state.cueBallInHand || driver.lastStroke?.cueBallPotted == true,
                       "the cue ball followed the red in: \(choice.shot.describedForTheLog)")
    }

    func testTheComputerPlaysALegalOpeningShot() {
        let driver = FrameDriver(playerNames: ["A", "B"])
        let computer = ComputerPlayer(playerIndex: 0, difficulty: .medium)
        computer.aimError = 0
        guard case .placeCueBall(let point) = computer.nextAction(for: driver) else {
            return XCTFail("the computer should put the cue ball down first")
        }
        XCTAssertTrue(driver.placeCueBall(at: point))
        guard case .shoot(let shot) = computer.nextAction(for: driver) else {
            return XCTFail("the computer should play a stroke")
        }
        shot.play(on: driver)
        driver.runStrokeToRest()
        XCTAssertNil(driver.lastResult?.foul, "there are fifteen reds to hit: a foul is the computer's own doing")
    }

    // MARK: - The questions

    func testTheComputerPutsTheCueBallInTheD() {
        let driver = FrameDriver(playerNames: ["A", "B"])
        let computer = ComputerPlayer(playerIndex: 0)
        guard case .placeCueBall(let point) = computer.nextAction(for: driver) else {
            return XCTFail("the cue ball is in hand: that is the question to answer")
        }
        XCTAssertTrue(Table.isInsideD(point), "\(point) is not in the D")
        XCTAssertTrue(driver.game.isFreePosition(point, ignoring: BallID.cue))
        XCTAssertTrue(driver.placeCueBall(at: point))
    }

    func testTheComputerClaimsTheFrameItIsAheadIn() {
        let driver = blackOnlySetup()
        XCTAssertTrue(driver.canClaimTheFrame)
        let computer = ComputerPlayer(playerIndex: 0)
        XCTAssertEqual(computer.nextAction(for: driver), .claimTheFrame)
    }

    func testTheComputerWaitsWhenItIsNotItsTurn() {
        let driver = blackOnlySetup()
        driver.game.withState { $0.currentPlayer = 1 }
        XCTAssertEqual(ComputerPlayer(playerIndex: 0).nextAction(for: driver), .wait)
    }

    // MARK: - Judging a position

    func testAPotIsWorthMoreThanAFoul() {
        let computer = ComputerPlayer(playerIndex: 0)
        var state = SnookerGame().state
        state.currentPlayer = 0
        state.pending = nil
        state.cueBallInHand = false
        state.ballPositions[BallID.cue] = Vec2(737, 737)
        state.ballPositions[BallID.firstRed] = Vec2(400, 400)

        var potted = TurnResult()
        potted.pointsScored = 1
        var fouled = TurnResult()
        fouled.foul = Foul(reason: "cue ball pocketed", penalty: 4)
        fouled.penalty = 4

        XCTAssertGreaterThan(computer.value(of: state, result: potted),
                             computer.value(of: state, result: fouled))
    }

    func testAnEasyBallOnIsWorthMoreThanASnooker() {
        let computer = ComputerPlayer(playerIndex: 0)
        var open = SnookerGame().state
        open.cueBallInHand = false
        open.pending = nil
        open.ballPositions[BallID.cue] = Vec2(737, 737)
        open.ballPositions[BallID.firstRed] = Vec2(400, 400)

        var hidden = open
        // The cue ball behind the Black, with the reds behind it: nothing to hit.
        hidden.ballPositions[BallID.cue] = Vec2(3569 - 120, 120)
        for id in BallID.firstRed...BallID.lastRed {
            hidden.ballPositions[id] = Vec2(400, 500 + Double(id) * 60)
        }

        XCTAssertGreaterThan(computer.opportunity(in: open), computer.opportunity(in: hidden))
    }

    // MARK: - A frame

    func testAFramePlayedByTwoComputersRunsWithoutStopping() {
        // A small frame on purpose: this is about the loop answering every question and never getting
        // stuck, and running one in a debug build is slow enough without a full think behind every shot.
        let report = ComputerMatch.playFrame(firstPlayer: 0, difficulty: .easy, strokeLimit: 20,
                                             configure: { player in
            player.rolloutBudget = 5
            player.settings.potLimit = 4
            player.settings.safetyLimit = 2
            player.spinVariants = [0]
            player.powerRefinements = [1]
            player.aimError = 0
            player.depth = 1
        })
        XCTAssertTrue(report.trouble.isEmpty, "the computers got stuck: \(report.trouble)")
        XCTAssertGreaterThan(report.strokes, 10, "the frame should have got going")
    }

    func testTheComputerDecidesTheSameWayTwiceRunning() {
        // The shots are played out on the machine's own cores, and the answer must not depend on the
        // order they come back in.
        let computer = ComputerPlayer(playerIndex: 0, difficulty: .medium)
        computer.aimError = 0
        let first = computer.bestShot(for: straightRedSetup())
        let second = computer.bestShot(for: straightRedSetup())
        XCTAssertEqual(first?.shot, second?.shot)
        XCTAssertEqual(first?.intent, second?.intent)
    }

    // MARK: - What a position looks like to a network

    // MARK: - The aim error

    func testTheCueIsTakenUpWhenABallComesBackAtIt() {
        // The stick on the table with a ball rolling at it: a ball met with the player's own equipment is a
        // foul (Rule 11(b)(vi)), and a player takes the cue up in time.
        let driver = straightRedSetup()
        let cueOnTheTable = Cue(tip: Vec3(1000, Table.centreY, Table.ballRadius),
                                axis: Vec3(1, 0, 0), speed: 0)
        driver.world.cue = cueOnTheTable
        XCTAssertEqual(driver.cueHandling, .laid, "the cue is on the table to begin with")

        // A red 200 mm in front of the tip, rolling at 1 m/s back into it.
        driver.world.setBall(Ball(id: BallID.firstRed, color: .red,
                                  position: Vec2(1200, Table.centreY), velocity: Vec2(-1000, 0)))
        XCTAssertTrue(driver.aBallIsHeadingForTheCue, "that ball is coming for it")

        driver.takeTheCueOffTheTable()
        XCTAssertEqual(driver.cueHandling, .putAway, "so the cue comes up")
        XCTAssertFalse(driver.aBallIsHeadingForTheCue, "and there is nothing on the table to be met")

        // And the other way: a ball rolling away from the stick is no danger at all.
        driver.putTheCueBackOnTheTable()
        driver.world.setBall(Ball(id: BallID.firstRed, color: .red,
                                  position: Vec2(1200, Table.centreY), velocity: Vec2(1000, 0)))
        XCTAssertFalse(driver.aBallIsHeadingForTheCue, "a ball going the other way is not coming for it")

        // Nor is a ball that is coming for it but is still more than a second away: a player who took the
        // cue up at every ball pointed their way would never lay it down again.
        driver.world.setBall(Ball(id: BallID.firstRed, color: .red,
                                  position: Vec2(2600, Table.centreY), velocity: Vec2(-1000, 0)))
        XCTAssertFalse(driver.aBallIsHeadingForTheCue, "that one is 1.6 s off yet")
    }

    /// The ball that most often comes for the stick is the one it has just struck: a screw shot sends the
    /// cue ball back down the line of the cue, and the tip that struck it is standing on that line.
    func testAScrewShotTakesTheCueUpBeforeTheCueBallComesBackToIt() {
        // Played with nobody looking after the stick, the cue ball comes back into it: that is the contact
        // this is about, and the reason the test below is worth having.
        let left = aScrewShotPlayedOut(lookingAfterTheCue: false)
        XCTAssertEqual(left.driver.lastStroke?.ballsTheCueTouched ?? [], [BallID.cue],
                       "the cue ball came back into the cue left standing in its way")

        // And with the player's own eye on it, the cue is up before the ball gets there: no contact at all.
        let looked = aScrewShotPlayedOut(lookingAfterTheCue: true)
        XCTAssertTrue(looked.tookTheCueUp, "the cue is taken up as the ball comes back")
        XCTAssertEqual(looked.driver.lastStroke?.ballsTheCueTouched ?? [], [],
                       "the cue was out of the ball's way in time")
    }

    /// A play-out that takes the cue up has to lay it again, or the player it is measuring could never play
    /// another stroke: `canStrike` is false with the cue since put away.
    func testAPlayOutThatTookItsCueUpLaysItAgainForTheNextStroke() {
        let driver = straightScrewSetup()
        Shot(angle: 0, power: 0.7, vertical: -0.5).play(on: driver)
        driver.runStrokeToRest(lookingAfterTheCue: true)
        XCTAssertEqual(driver.cueHandling, .laid,
                       "the cue is laid again, ready for the next stroke")
    }

    /// A screw shot played out to rest, with the cue left on the table — or taken up as soon as a ball is
    /// coming for it, which is what the scene does for the computer.
    ///
    /// The shot is the ordinary one: a red dead in line down the table, played hard off the bottom of the
    /// ball so that the cue ball comes back at the player — and at the cue, which is still standing where
    /// the follow-through left it, on the very line the ball is coming back along.
    private func aScrewShotPlayedOut(lookingAfterTheCue: Bool) -> (driver: FrameDriver,
                                                                  tookTheCueUp: Bool) {
        let driver = straightScrewSetup()
        Shot(angle: 0, power: 0.7, vertical: -0.5).play(on: driver)
        // The frame's own clock, run on as the scene runs it: the charge is what the meter is measured
        // against, and a scripted cue action is driven by it.
        var clock = Date().timeIntervalSinceReferenceDate
        var elapsed = 0.0
        var tookTheCueUp = false
        while elapsed < 30, driver.mode == .charging || driver.mode == .simulating {
            if lookingAfterTheCue, driver.aBallIsHeadingForTheCue {
                driver.takeTheCueOffTheTable()
                tookTheCueUp = true
            }
            if driver.mode == .charging {
                clock += 1.0 / 240
                driver.updateCharge(at: clock)
            } else {
                driver.update(dt: 1.0 / 240)
            }
            elapsed += 1.0 / 240
        }
        return (driver, tookTheCueUp)
    }

    /// A red dead in line down the table from the cue ball, and nothing else in the way: the shot a screw
    /// is played on.
    private func straightScrewSetup() -> FrameDriver {
        let driver = FrameDriver(playerNames: ["A", "B"])
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.redsRemaining = 1
            state.ballOn = .red
            state.ballPositions[BallID.firstRed] = Vec2(2400, Table.centreY)
            state.ballPositions[BallID.cue] = Vec2(2000, Table.centreY)
            state.cueBallInHand = false
            state.pending = nil
        }
        driver.syncWorldFromState()
        driver.load(driver.game.state)
        return driver
    }

    func testTheSamplerDrawsFromANormalDistribution() {
        var generator = SeededRandom(seed: 99)
        let draws = (0..<20_000).map { _ in
            Normal.sample(standardDeviation: 1, using: { generator.unit() })
        }
        let mean = draws.reduce(0, +) / Double(draws.count)
        let spread = (draws.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(draws.count - 1))
            .squareRoot()
        XCTAssertEqual(mean, 0, accuracy: 0.05, "a normal sample is centred on nothing")
        XCTAssertEqual(spread, 1, accuracy: 0.05, "and spreads as far as it was asked to")
    }

    func testAnExactCueActionPlaysTheShotItChose() {
        let computer = ComputerPlayer(playerIndex: 0, difficulty: .easy)
        computer.aimError = 0
        let shot = Shot(angle: 0.3, power: 0.4)
        XCTAssertEqual(computer.theShotAsItWillBePlayed(shot), shot)
    }

    func testTheAimErrorMovesTheShotOffTheLineItWasAimedAlong() {
        let computer = ComputerPlayer(playerIndex: 0, difficulty: .easy)
        computer.aimError = 2 * .pi / 180
        // Two uniforms, chosen so that the Box–Muller draw is exactly −3.03485: the first sets the radius
        // (√(−2·ln 0.01)) and the second the direction (cos π = −1).
        var draws = [0.01, 0.5]
        computer.aimErrorSource = { draws.removeFirst() }
        let shot = Shot(angle: 0.3, power: 0.4)
        let played = computer.theShotAsItWillBePlayed(shot)
        XCTAssertEqual(played.angle - shot.angle, -3.03485 * 2 * .pi / 180, accuracy: 1e-6)
        XCTAssertEqual(played.power, shot.power, "only the line is wrong: the shot is the same shot")
    }

    func testAnAimErrorMakesAShotMissWhatItWouldHavePotted() {
        let driver = straightRedSetup()
        let computer = ComputerPlayer(playerIndex: 0, difficulty: .medium)
        computer.aimError = 0
        guard let choice = computer.bestShot(for: driver) else { return XCTFail("no shot was found") }
        guard let exact = computer.playOutcome(of: choice.shot, in: driver) else {
            return XCTFail("the shot could not be played")
        }
        XCTAssertTrue(exact.potted.contains(BallID.firstRed), "the red goes down on the line it was aimed along")

        // The same shot, played by someone whose cue is six degrees off it.
        computer.aimError = 2 * .pi / 180
        var draws = [0.01, 0.5]
        computer.aimErrorSource = { draws.removeFirst() }
        guard let missed = computer.playOutcome(of: choice.shot, in: driver) else {
            return XCTFail("the shot could not be played")
        }
        XCTAssertFalse(missed.potted.contains(BallID.firstRed),
                       "the same shot, six degrees off the line, is a miss")
    }

    func testTheCueBallInHandAndTheQuestionsAreNotShots() {
        XCTAssertTrue(ComputerPlayer.Action.shoot(Shot(angle: 0, power: 0.5)).isAShot)
        XCTAssertFalse(ComputerPlayer.Action.wait.isAShot)
        XCTAssertFalse(ComputerPlayer.Action.playFromHere.isAShot)
        XCTAssertFalse(ComputerPlayer.Action.placeCueBall(Vec2(0, 0)).isAShot)
    }

    func testTheFeaturesOfAPositionAreAllOfOrderOne() {
        let features = PositionFeatures.of(straightRedSetup().game.state)
        XCTAssertEqual(features.values.count, PositionFeatures.count)
        XCTAssertTrue(features.values.allSatisfy { $0.isFinite })
        XCTAssertTrue(features.values.allSatisfy { $0 >= -1.001 && $0 <= 1.001 },
                      "every feature is scaled to a small range: \(features.values.filter { $0 < -1 || $0 > 1 })")
        // The cue ball and the red are the two balls on the table of the ones that matter here.
        XCTAssertEqual(features.values[0], 1, "the cue ball is there")
        XCTAssertEqual(features.values[PositionFeatures.perBall], 1, "and so is the first red")
    }

    func testTheFeaturesFollowTheStriker() {
        // The same balls, the same scores, the other player at the table: the difference is what is said
        // about who is on, and nothing else.
        var state = SnookerGame().state
        state.scores = [20, 10]
        state.currentPlayer = 0
        state.pending = nil
        let theirs = PositionFeatures.of(state)
        state.currentPlayer = 1
        let ours = PositionFeatures.of(state)
        XCTAssertNotEqual(theirs.values, ours.values)
    }

    func testALearnedValueFunctionIsWhatThePlayerJudgesPositionsWith() {
        let driver = straightRedSetup()
        var asked: [PositionFeatures] = []
        let computer = ComputerPlayer(playerIndex: 0, difficulty: .easy)
        computer.aimError = 0
        computer.valueOfPosition = { features in
            asked.append(features)
            return 0
        }
        _ = computer.bestShot(for: driver)
        XCTAssertFalse(asked.isEmpty, "every position a shot leaves goes through the learned value")
        XCTAssertEqual(asked.first?.values.count, PositionFeatures.count)
    }

    // MARK: - Positions to learn from

    func testThePositionGeneratorGivesTheSamePositionsFromTheSameSeed() {
        let first = PositionGenerator.positions(count: 3, reds: 15, seed: 42)
        let second = PositionGenerator.positions(count: 3, reds: 15, seed: 42)
        XCTAssertEqual(first.map(\.ballPositions), second.map(\.ballPositions))
        let other = PositionGenerator.positions(count: 3, reds: 15, seed: 43)
        XCTAssertNotEqual(first.map(\.ballPositions), other.map(\.ballPositions))
    }

    func testGeneratedPositionsAreOnesTheGameCanBePlayedFrom() {
        for state in PositionGenerator.positions(count: 12, reds: 15, seed: 5) {
            let onTheTable = state.ballsOnTable.compactMap { state.ballPositions[$0] }
            XCTAssertEqual(onTheTable.count, state.ballsOnTable.count)
            for position in onTheTable {
                XCTAssertTrue(ShotGeometry.isOnTheCloth(position),
                              "\(position) is off the cloth")
            }
            for (index, one) in onTheTable.enumerated() {
                for other in onTheTable[(index + 1)...] {
                    XCTAssertGreaterThan(one.distance(to: other), Table.ballDiameter,
                                         "two balls are in the same place")
                }
            }
            XCTAssertEqual(state.redsRemaining, 15)
            XCTAssertFalse(state.frameOver)
            XCTAssertFalse(state.cueBallInHand)

            // And the frame really takes it: a driver loaded with it has something to play.
            let driver = FrameDriver(playerNames: ["A", "B"])
            driver.load(state)
            XCTAssertTrue(driver.canStrike, "the striker can play from a generated position")
            XCTAssertFalse(driver.game.legalFirstContacts().isEmpty)
        }
    }

    func testAShortSetOfGeneratedPositionsCanBePlayedOut() {
        // The same loop the dataset is made with, small enough for a test: a dozen strokes from each of a
        // few generated positions, with the player never stuck for something to do. A whole frame from each
        // would take minutes in a debug build and prove nothing more.
        var strokes = 0
        for position in PositionGenerator.positions(count: 3, reds: 6, seed: 11) {
            let driver = FrameDriver(playerNames: ["A", "B"])
            driver.load(position)
            let players = [ComputerPlayer(playerIndex: 0, difficulty: .easy),
                           ComputerPlayer(playerIndex: 1, difficulty: .easy)]
            for player in players {
                player.settings.potLimit = 3
                player.settings.safetyLimit = 1
                player.rolloutBudget = 3
                player.aimError = 0
                player.depth = 1
            }
            var here = 0
            while !driver.game.state.frameOver, here < 12 {
                let action = players[driver.game.state.currentPlayer].nextAction(for: driver)
                if case .shoot = action { here += 1; strokes += 1 }
                let taken = ComputerMatch.apply(action, to: driver)
                XCTAssertTrue(taken || driver.game.state.frameOver,
                              "the frame would not take \(action)")
                if !taken { break }
            }
            XCTAssertEqual(here, 12, "twelve strokes were played from the position")
        }
        XCTAssertEqual(strokes, 36)
    }
}
