import XCTest
@testable import SnookerCore

/// Tests follow the WPBSA "Official Rules of the Games of Snooker and English
/// Billiards" (May 2022). Rule references are to Section 3 unless stated otherwise.
final class RulesTests: XCTestCase {

    private func newGame(reds: Int = 15) -> SnookerGame {
        let game = SnookerGame(playerNames: ["A", "B"], reds: reds)
        game.beginFrame(startingPlayer: 0)
        _ = game.placeCueBall(at: Vec2(600, 889))
        return game
    }

    /// A frame that has reached the re-spotted Black: the scores are level, the Black is back on its
    /// spot, and player 0 has won the draw and put the cue ball down to play from in-hand.
    private func respottedBlackPosition() -> SnookerGame {
        let game = newGame(reds: 0)
        game.decideTheDraw = { 0 }
        game.withState { state in
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.black)
            state.ballsOnTable = [BallID.cue, BallID.black]
            state.scores = [33, 40]
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.black]
        report.potted = [BallID.black]
        _ = game.applyStroke(report, cueBallPosition: Vec2(1200, 889))
        XCTAssertTrue(game.state.respottedBlack, "the set-up must reach the re-spotted Black")
        XCTAssertTrue(game.placeCueBall(at: Vec2(600, 889)))
        return game
    }

    // MARK: Set-up (Section 1 Rule 1, Section 3 Rule 2)

    func testTableDimensionsAndSpots() {
        XCTAssertEqual(Table.length, 3569, accuracy: 0.001)
        XCTAssertEqual(Table.width, 1778, accuracy: 0.001)
        XCTAssertEqual(Table.baulkLineX, 737, accuracy: 0.001)
        XCTAssertEqual(Table.dRadius, 292, accuracy: 0.001)
        XCTAssertEqual(Table.ballDiameter, 52.5, accuracy: 0.001)

        XCTAssertEqual(Table.brownSpot, Vec2(737, 889))
        XCTAssertEqual(Table.blueSpot.x, 1784.5, accuracy: 0.001)
        XCTAssertEqual(Table.pinkSpot.x, (1784.5 + 3569) / 2, accuracy: 0.001)
        XCTAssertEqual(Table.blackSpot.x, 3569 - 324, accuracy: 0.001)
        // Yellow is the right-hand corner of the "D" seen from the baulk end.
        XCTAssertLessThan(Table.yellowSpot.y, Table.brownSpot.y)
        XCTAssertGreaterThan(Table.greenSpot.y, Table.brownSpot.y)
    }

    /// The pocket openings (Section 1 Rule 1(g), except for the middle pockets): a corner pocket
    /// mouth 78 mm wide — and the middle pockets cut to the same 78 mm rather than the rule book's
    /// 98 mm — each measured between its two jaw tips, the ends of the cushion faces.
    ///
    /// Each jaw is a round of `Table.jawRadius` cut into the cushion where it meets the pocket, and
    /// the narrowest gap between a pocket's two rounds comes out at the mouth.
    func testPocketMouthsAreMeasuredBetweenRoundedJaws() {
        XCTAssertEqual(Table.cornerPocketMouth, 78, accuracy: 0.001)
        XCTAssertEqual(Table.middlePocketMouth, 78, accuracy: 0.001)
        XCTAssertEqual(Table.jawRadius, 50, accuracy: 0.001)

        // The corner pocket's two jaws stand on the diagonal, `cornerJawGap` from the corner along
        // each cushion, so the two tips are `cornerJawGap * sqrt(2)` apart.
        XCTAssertEqual(Table.cornerJawGap * 2.0.squareRoot(), Table.cornerPocketMouth, accuracy: 0.001)
        // A middle pocket's jaws stand in the long cushion, straight across the table.
        XCTAssertEqual(2 * Table.middleJawGap, Table.middlePocketMouth, accuracy: 0.001)

        // Both openings take a ball, and on this table they are the same width.
        XCTAssertGreaterThan(Table.cornerPocketMouth, Table.ballDiameter)
        XCTAssertEqual(Table.middlePocketMouth, Table.cornerPocketMouth, accuracy: 0.001)
    }

    /// The pocket the table is cut to (Rule 1(g)): a passage the width of the mouth — down the 45°
    /// diagonal at a corner, square to the cushion at a middle pocket — running out to a round hole
    /// wider than it by the jaws' own setback on each side, with the table's surface running on into
    /// the throat around it and cut away only at the hole. A ball is potted when its centre is over
    /// the hole.
    func testEachPocketIsAHoleInTheTableSurface() {
        for pocket in PocketID.allCases {
            let cut = pocket.cut
            XCTAssertEqual(cut.width, pocket.mouth, accuracy: 0.001)
            // The hole is wider than the mouth by the jaws' own setback on each side, and then by the
            // clearance again: the jaws lean out under their noses, so their feet stand over the hole
            // with the rim just outside them, and the throat keeps its width all the while. A corner's
            // is wider again than a middle pocket's, by the corner's own extra.
            let clearance = Table.pocketHoleClearance
                + (pocket.isCorner ? Table.cornerPocketHoleExtra / 2 : 0)
            XCTAssertEqual(cut.holeRadius, Table.pocketHoleDiameter(for: pocket) / 2, accuracy: 0.001)
            XCTAssertEqual(cut.holeRadius - cut.width / 2,
                           Table.pocketHoleSetback + clearance, accuracy: 0.001,
                           "\(pocket.rawValue): the hole opens out by the jaws' setback each side, and the clearance past them")
            XCTAssertEqual(Table.cornerPocketHoleDiameter - Table.middlePocketHoleDiameter,
                           Table.cornerPocketHoleExtra, accuracy: 1e-9,
                           "the corner's hole is the corner's extra wider than a middle pocket's")
            XCTAssertEqual(cut.holeRadius, pocket.isCorner
                           ? Table.cornerPocketHoleDiameter / 2 : Table.middlePocketHoleDiameter / 2,
                           accuracy: 0.001,
                           "\(pocket.rawValue): a corner's hole is the corner's, a middle pocket's its own")
            XCTAssertEqual(cut.tipA.distance(to: cut.tipB), pocket.mouth, accuracy: 0.001,
                           "\(pocket.rawValue): the mouth is measured between the two jaw tips")

            // And the hole is pushed out past the passage by that same setback and the pull — once
            // along the outward of each cushion the pocket is cut in, so a corner's hole moves out
            // along both of the cushion faces that meet there and a middle pocket's out square to its
            // own cushion.
            let pushedBy = Table.pocketHoleSetback + Table.pocketHolePull
            let cutIn = Set([cut.tipA, cut.tipB].map { PocketCut.outward(at: $0) })
            let pushedOut = cutIn.map { $0 * pushedBy }.reduce(Vec2.zero, +)
            let straightDown = cut.mouth + cut.axis * cut.passageLength
            XCTAssertEqual(cut.holeCentre.distance(to: straightDown + pushedOut), 0, accuracy: 1e-9,
                           "\(pocket.rawValue): the hole is pushed out by the setback and the pull")
            XCTAssertEqual(pushedOut.length,
                           pocket.isCorner ? pushedBy * 2.0.squareRoot() : pushedBy,
                           accuracy: 1e-9,
                           "\(pocket.rawValue): once for each cushion the pocket is cut in")
            XCTAssertEqual(abs(pushedOut.x), pocket.isCorner ? pushedBy : 0,
                           accuracy: 1e-9,
                           "\(pocket.rawValue): a corner's hole moves out along x as well as y")
            // And the pocket's two jaws leave exactly the mouth between them.
            XCTAssertEqual(cut.jaws.0.centre.distance(to: cut.jaws.1.centre) - 2 * Table.jawRadius,
                           pocket.mouth, accuracy: 0.001)

            if pocket.isCorner {
                XCTAssertEqual(abs(cut.axis.x), abs(cut.axis.y), accuracy: 1e-9,
                               "\(pocket.rawValue): a corner pocket runs out at 45°")
            } else {
                XCTAssertEqual(cut.axis.x, 0, accuracy: 1e-9,
                               "\(pocket.rawValue): a middle pocket runs out square to the cushion")
                XCTAssertEqual(abs(cut.axis.y), 1, accuracy: 1e-9)
            }

            // The hole: the ball's centre is over it, and its far side is one radius out.
            XCTAssertTrue(cut.contains(cut.holeCentre))
            XCTAssertTrue(cut.contains(cut.holeCentre + cut.axis * (cut.holeRadius - 0.5)))
            XCTAssertFalse(cut.contains(cut.holeCentre + cut.axis * (cut.holeRadius + 0.5)),
                           "\(pocket.rawValue): the hole is round, and no bigger than the mouth")
            for across in [-1.0, 1.0] {
                XCTAssertFalse(cut.contains(cut.holeCentre
                    + cut.axis.perpendicular * across * (cut.holeRadius + 0.5)))
            }

            // How far into the throat a ball's centre has to travel before it is over the hole: the
            // cloth carries it that far, and the hole is somewhere out past the mouth at every pocket.
            let rim = (cut.holeCentre - cut.mouth).dot(cut.axis) - cut.holeRadius
            XCTAssertGreaterThan(rim, 0,
                                 "\(pocket.rawValue): the hole is set out behind the mouth")
            XCTAssertTrue(cut.contains(cut.mouth + cut.axis * (rim + 1)),
                          "\(pocket.rawValue): the hole is there once the rim is crossed")
            XCTAssertFalse(cut.contains(cut.mouth + cut.axis * (rim - 1)),
                           "\(pocket.rawValue): the throat short of the hole is table, not pocket")
            XCTAssertFalse(cut.contains(cut.mouth - cut.axis * 1),
                           "\(pocket.rawValue): nothing in front of the mouth is pocket")

            // The hole reaches the line the rails stop at, or bare slate would show between them.
            let far = cut.holeCentre + cut.axis * cut.holeRadius
            let beyondRails = max(-Table.cushionDepth - far.x, far.x - (Table.length + Table.cushionDepth),
                                  -Table.cushionDepth - far.y, far.y - (Table.width + Table.cushionDepth))
            XCTAssertGreaterThanOrEqual(beyondRails, -1e-9,
                "\(pocket.rawValue): the hole must reach the line the rails stop at, or slate shows")
        }
    }

    /// The light over the table: three long plates, one down the middle and one along each side,
    /// 400 mm across with 20 mm between them, hanging 2.2 m over the middle of the table, the two
    /// along the sides turned down by 10 degrees.
    ///
    /// They began as nine smaller plates in a three by three: the gaps inside a row have since gone,
    /// because a 20 mm gap at 2.2 m is invisible and nothing like the 20 mm across the table.
    func testTheLightIsThreePlatesOnePerRow() {
        let plates = TableLightRig.plates
        XCTAssertEqual(plates.count, 3)
        XCTAssertEqual(TableLightRig.plateLength, 3164, accuracy: 0.001, "the length of the table's light")
        XCTAssertEqual(TableLightRig.plateWidth, 400, accuracy: 0.001)
        XCTAssertEqual(TableLightRig.gap, 20, accuracy: 0.001, "between the plates, across the table")
        XCTAssertEqual(TableLightRig.heightAboveCloth, 2200, accuracy: 0.001)
        XCTAssertEqual(TableLightRig.outerTiltDegrees, 10, accuracy: 0.001)

        // One plate on each side and one down the middle, the whole rig centred on the table.
        XCTAssertEqual(Set(plates.map(\.centre.y)).count, 3)
        XCTAssertTrue(plates.allSatisfy { $0.centre.x == Table.length / 2 },
                      "each plate runs the length of the table")
        XCTAssertEqual(plates.map(\.centre.y).reduce(0, +) / Double(plates.count),
                       Table.width / 2, accuracy: 0.001)

        // 20 mm of daylight between them: the plates are 420 mm apart across the table, and the
        // middle one runs over the middle of the table.
        let acrosses = Set(plates.map(\.centre.y)).sorted()
        XCTAssertEqual(acrosses[1] - acrosses[0], 420, accuracy: 0.001)
        XCTAssertEqual(acrosses[2] - acrosses[1], 420, accuracy: 0.001)
        XCTAssertEqual(acrosses[1], Table.width / 2, accuracy: 0.001)

        let middle = plates.filter { $0.centre.y == Table.width / 2 }
        let sides = plates.filter { $0.centre.y != Table.width / 2 }
        XCTAssertEqual(middle.count, 1)
        XCTAssertEqual(sides.count, 2, "the two plates along the long sides are the ones turned down")
        XCTAssertTrue(middle.allSatisfy { $0.tilt == 0 })
        XCTAssertTrue(middle.allSatisfy { !$0.isTurnedDown })
        XCTAssertTrue(sides.allSatisfy { $0.isTurnedDown })
        XCTAssertTrue(sides.allSatisfy { abs($0.tilt) == TableLightRig.outerTiltDegrees })
        XCTAssertEqual(sides.map(\.tilt).reduce(0, +), 0, accuracy: 0.001,
                       "the two sides are turned opposite ways")
        for plate in sides {
            let outwards = plate.centre.y - Table.width / 2
            XCTAssertEqual(plate.tilt, outwards > 0 ? TableLightRig.outerTiltDegrees
                                                    : -TableLightRig.outerTiltDegrees,
                           accuracy: 0.001, "a positive tilt drops the plate's far edge")
        }

        // The plate across the middle hangs 2.2 m over the middle of the table, and the two turned
        // down ones are dropped so that the light joins up: a plate turns about its own middle, so
        // the turn lifts the edge along the middle of the rig by half its width times the sine of
        // the angle, and the plate is lowered by exactly that. Its edge is then level with the plate
        // beside it, and its far edge hangs below.
        let drop = (TableLightRig.plateWidth / 2) * sin(TableLightRig.outerTiltDegrees * .pi / 180)
        XCTAssertEqual(drop, 34.73, accuracy: 0.01, "the two are lowered by about 35 mm")
        XCTAssertEqual(TableLightRig.dropForTurnedDownPlate, drop, accuracy: 0.001)
        XCTAssertTrue(middle.allSatisfy { $0.height == TableLightRig.heightAboveCloth })
        XCTAssertTrue(sides.allSatisfy { $0.height == TableLightRig.heightAboveCloth - drop })
        for plate in sides {
            let innerEdge = plate.height + (TableLightRig.plateWidth / 2) * sin(abs(plate.tilt) * .pi / 180)
            XCTAssertEqual(innerEdge, TableLightRig.heightAboveCloth, accuracy: 0.001,
                           "the turned-down plates meet the middle one along their long side")
        }

        // The rig is a little shorter than the table — its plates stop 202 mm inside each cushion line —
        // and, at 1.24 m, narrower than it.
        XCTAssertEqual(TableLightRig.halfLength, 1582, accuracy: 0.001)
        XCTAssertEqual(TableLightRig.halfWidth, 620, accuracy: 0.001)
    }

    func testFrameStartsWithFifteenRedsAndColoursOnSpots() {
        let game = newGame()
        XCTAssertEqual(game.state.redsRemaining, 15)
        XCTAssertEqual(game.state.ballPositions[BallID.black], Table.blackSpot)
        XCTAssertEqual(game.state.ballPositions[BallID.pink], Table.pinkSpot)
        XCTAssertTrue(game.state.ballOn == .red)
        XCTAssertEqual(game.state.scores, [0, 0])
    }

    func testRedsAreRackedBehindThePinkSpot() {
        let reds = Table.rackedReds()
        XCTAssertEqual(reds.count, 15)
        let apex = reds[0]
        XCTAssertGreaterThan(apex.x, Table.pinkSpot.x)          // above the Pink Spot
        XCTAssertEqual(apex.y, Table.centreY, accuracy: 0.001)  // on the centre line
        XCTAssertGreaterThanOrEqual(apex.x - Table.pinkSpot.x, Table.ballDiameter)
    }

    // MARK: Scoring (Rule 1(b), Rule 3(g)-(h))

    func testPottingARedScoresOneAndAsksForAColour() {
        let game = newGame()
        var report = StrokeReport()
        report.firstContacts = [BallID.firstRed]
        report.potted = [BallID.firstRed]
        report.contactedAnyObjectBall = true
        _ = game.applyStroke(report, cueBallPosition: Vec2(800, 889))

        XCTAssertEqual(game.state.scores[0], 1)
        XCTAssertEqual(game.state.redsRemaining, 14)
        XCTAssertEqual(game.state.ballOn, .anyColour)
        if case .nominateColour(let options) = game.state.pending {
            XCTAssertTrue(options.contains(.black))
        } else {
            XCTFail("expected a colour nomination prompt")
        }
    }

    func testPottingARedThenABlackScoresEightAndRespotsTheBlack() {
        let game = newGame()
        var first = StrokeReport()
        first.firstContacts = [BallID.firstRed]
        first.potted = [BallID.firstRed]
        _ = game.applyStroke(first, cueBallPosition: Vec2(900, 889))

        game.nominateColour(.black)
        var second = StrokeReport()
        second.firstContacts = [BallID.black]
        second.potted = [BallID.black]
        _ = game.applyStroke(second, cueBallPosition: Vec2(3000, 889))

        XCTAssertEqual(game.state.scores[0], 8)
        XCTAssertEqual(game.state.breakScore, 8)
        // Rule 3(h)(i): the colour is spotted while Reds remain.
        XCTAssertTrue(game.state.ballsOnTable.contains(BallID.black))
        XCTAssertEqual(game.state.ballPositions[BallID.black], Table.blackSpot)
        XCTAssertEqual(game.state.ballOn, .red)
        XCTAssertEqual(game.state.redsRemaining, 14)
    }

    func testTwoRedsPottedInOneStrokeBothScore() {
        let game = newGame()
        var report = StrokeReport()
        report.firstContacts = [BallID.firstRed]
        report.potted = [BallID.firstRed, BallID.firstRed + 1]   // Rule 3(g)
        _ = game.applyStroke(report, cueBallPosition: Vec2(1000, 889))
        XCTAssertEqual(game.state.scores[0], 2)
        XCTAssertEqual(game.state.redsRemaining, 13)
    }

    // MARK: Fouls and penalties (Rule 11)

    func testCueBallPottedCostsTheValueOfTheBallOn() {
        let game = newGame()
        var report = StrokeReport()
        report.firstContacts = [BallID.firstRed]
        report.cueBallPotted = true
        report.potted = [BallID.cue]
        _ = game.applyStroke(report, cueBallPosition: Vec2(500, 500))

        // Ball on was a Red (value 1) so the minimum of four applies.
        XCTAssertEqual(game.state.scores[1], 4)
        XCTAssertEqual(game.state.currentPlayer, 1)
        XCTAssertFalse(game.state.ballsOnTable.contains(BallID.cue))
    }

    func testCueBallPottedWhenBlackIsOnCostsSeven() {
        let game = newGame(reds: 0)
        game.withState { state in
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.black)
            state.ballsOnTable = [BallID.cue, BallID.black]
        }
        var report = StrokeReport()
        report.cueBallPotted = true
        report.firstContacts = [BallID.black]
        report.potted = [BallID.cue]
        _ = game.applyStroke(report, cueBallPosition: Vec2(400, 400))
        XCTAssertEqual(game.state.scores[1], 7)
    }

    func testHittingABallNotOnIsPenalisedByTheHigherValue() {
        let game = newGame()
        var report = StrokeReport()
        report.firstContacts = [BallID.black]   // Black is not on while Reds remain
        _ = game.applyStroke(report, cueBallPosition: Vec2(2000, 889))
        XCTAssertEqual(game.state.scores[1], 7)  // max(4, ball on 1, ball hit 7)
    }

    func testPottingABallNotOnIsAFoul() {
        let game = newGame()
        var report = StrokeReport()
        report.firstContacts = [BallID.firstRed]
        report.potted = [BallID.blue]           // Blue is not on
        _ = game.applyStroke(report, cueBallPosition: Vec2(1500, 889))
        XCTAssertEqual(game.state.scores[1], 5) // max(4, value of the ball pocketed)
        XCTAssertTrue(game.state.ballsOnTable.contains(BallID.blue), "pocketed colour is spotted")
    }

    func testSimultaneousContactWithTwoColoursIsAFoul() {
        let game = newGame()
        game.nominateColourIfPossible()
        var report = StrokeReport()
        report.firstContacts = [BallID.pink, BallID.black]
        _ = game.applyStroke(report, cueBallPosition: Vec2(2500, 889))
        XCTAssertEqual(game.state.scores[1], 7)  // higher value of the two balls concerned
    }

    func testTwoRedsHitSimultaneouslyIsNotAFoul() {
        let game = newGame()
        var report = StrokeReport()
        report.firstContacts = [BallID.firstRed, BallID.firstRed + 1]  // Rule 6 exception
        _ = game.applyStroke(report, cueBallPosition: Vec2(1200, 800))
        XCTAssertEqual(game.state.scores[1], 0)
    }

    func testFailingToContactAnyBallIsAFoul() {
        let game = newGame()
        let report = StrokeReport()
        _ = game.applyStroke(report, cueBallPosition: Vec2(300, 300))
        XCTAssertEqual(game.state.scores[1], 4)
        XCTAssertEqual(game.state.currentPlayer, 1)
    }

    // MARK: Forced off the table (Rule 11(b)(x), Section 2 Rule 14)

    /// Causing a ball to be forced off the table is a foul worth the value of the ball on or the ball
    /// concerned, whichever is higher; the ball itself is treated like one potted — a colour is
    /// spotted (Rule 7), a Red stays off (Rule 3(i)).
    func testForcingABallOffTheTableCostsTheHigherOfTheBallOnAndTheBallConcerned() {
        let game = newGame()
        var report = StrokeReport()
        report.firstContacts = [BallID.firstRed]
        report.ballsForcedOffTable = [BallID.blue]   // the Blue is not on: a Red is, so the base is four
        _ = game.applyStroke(report, cueBallPosition: Vec2(1500, 889))
        XCTAssertEqual(game.state.scores[1], 5, "max(4, the ball on 1, the Blue 5)")
        XCTAssertTrue(game.state.ballsOnTable.contains(BallID.blue), "a colour forced off is spotted")
        XCTAssertEqual(game.state.ballPositions[BallID.blue], Table.blueSpot)
    }

    func testACueBallForcedOffTheTableComesBackInHand() {
        let game = newGame()
        var report = StrokeReport()
        report.firstContacts = [BallID.firstRed]
        report.ballsForcedOffTable = [BallID.cue]
        _ = game.applyStroke(report, cueBallPosition: Vec2(1500, 889))
        XCTAssertEqual(game.state.scores[1], 4)
        XCTAssertTrue(game.state.cueBallInHand, "Section 2 Rule 9(a)(iii): the cue ball is in hand")
        XCTAssertFalse(game.state.ballsOnTable.contains(BallID.cue))
    }

    func testARedForcedOffTheTableStaysOff() {
        let game = newGame()
        var report = StrokeReport()
        report.firstContacts = [BallID.firstRed]
        report.ballsForcedOffTable = [BallID.firstRed + 1]
        _ = game.applyStroke(report, cueBallPosition: Vec2(1500, 889))
        XCTAssertFalse(game.state.ballsOnTable.contains(BallID.firstRed + 1),
                      "a Red forced off is not replaced")
        XCTAssertEqual(game.state.redsRemaining, 14, "and stops counting among the Reds left")
    }

    /// Rule 11(a)(x): playing a jump shot is a foul, worth the value of the ball on. Rule 20 makes it
    /// a jump shot when the cue ball passes over any part of an object ball it has not already hit —
    /// so a ball scooped over an obstruction to reach a ball on is a foul, not a clever shot.
    func testJumpingTheCueBallOverABallIsAFoul() {
        let game = newGame()
        var report = StrokeReport()
        report.firstContacts = [BallID.firstRed]
        report.jumpedOver = [BallID.black]
        let result = game.applyStroke(report, cueBallPosition: Vec2(1500, 889))
        XCTAssertEqual(result.foul?.reason, "playing a jump shot")
        XCTAssertEqual(game.state.scores[1], 4, "a Red is on, so the ball on's value")
    }

    // MARK: Colours sequence (Rule 3(h)(iii))

    func testColoursComeInAscendingOrderAndStaysOffWhenPotted() {
        let game = newGame(reds: 0)
        game.withState { state in
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.yellow)
            state.ballsOnTable = [BallID.cue, BallID.yellow, BallID.green, BallID.brown,
                                  BallID.blue, BallID.pink, BallID.black]
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.yellow]
        report.potted = [BallID.yellow]
        _ = game.applyStroke(report, cueBallPosition: Vec2(900, 889))

        XCTAssertEqual(game.state.scores[0], 2)
        XCTAssertFalse(game.state.ballsOnTable.contains(BallID.yellow), "colours stay off in the sequence")
        XCTAssertEqual(game.state.ballOn, .colourOfSequence(.green))
    }

    func testPottingTheWrongColourInSequenceIsAFoul() {
        let game = newGame(reds: 0)
        game.withState { state in
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.yellow)
            state.ballsOnTable = [BallID.cue, BallID.yellow, BallID.green, BallID.black]
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.green]
        report.potted = [BallID.green]
        _ = game.applyStroke(report, cueBallPosition: Vec2(1200, 889))
        XCTAssertEqual(game.state.scores[1], 4)   // max(4, yellow 2, green 3)
        XCTAssertTrue(game.state.ballsOnTable.contains(BallID.green))
    }

    // MARK: Spotting (Rule 7)

    func testColourTakesTheHighestValueFreeSpotWhenItsOwnIsOccupied() {
        let game = newGame()
        game.withState { state in
            // Occupy the Black spot with a Red and take the Pink off its spot, so the
            // Pink Spot becomes the highest value spot available (Rule 7(e)).
            state.ballPositions[BallID.firstRed] = Table.blackSpot
            state.ballPositions[BallID.pink] = Vec2(3000, 600)
        }
        let position = game.spottingPosition(for: .black)
        XCTAssertNotEqual(position, Table.blackSpot)
        XCTAssertEqual(position, Table.pinkSpot, "next highest value spot available")
    }

    func testSpottingWhenEverySpotIsOccupiedGoesTowardTheTopCushion() {
        let game = newGame()
        game.withState { state in
            // Full rack: every colour is on its own spot, and a Red occupies the Black spot.
            state.ballPositions[BallID.firstRed] = Table.blackSpot
        }
        let position = game.spottingPosition(for: .black)
        // Rule 7(g): as near to its own spot as possible, between the spot and the top cushion.
        XCTAssertGreaterThan(position.x, Table.blackSpot.x)
        XCTAssertEqual(position.y, Table.blackSpot.y, accuracy: 0.001)
        XCTAssertLessThanOrEqual(position.x, Table.length - Table.ballRadius)
    }

    func testSpottedColourIsNeverTouchingAnotherBall() {
        let game = newGame()
        game.withState { state in
            state.ballPositions[BallID.firstRed] = Table.blackSpot
            state.ballPositions[BallID.firstRed + 1] = Table.pinkSpot
        }
        let position = game.spottingPosition(for: .black)
        for (id, other) in game.state.ballPositions where id != BallID.black {
            XCTAssertGreaterThanOrEqual(position.distance(to: other), Table.ballDiameter - 0.01)
        }
    }

    // MARK: Snookered and free ball (Section 2 Rule 17, Rule 12)

    func testStraightLineObstructionIsDetectedAsSnookered() {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
            state.ballPositions[BallID.black] = Vec2(1500, 889)   // directly in the way
        }
        XCTAssertTrue(game.isSnookered())
    }

    /// Rule 17's own test is **both** extreme edges: "If one or more balls on can be hit at both
    /// extreme edges free of obstruction by any ball not on, the cue-ball is not snookered." A ball on
    /// clear of everything passes it.
    func testABallOnClearAtBothExtremeEdgesIsNotSnookered() {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
            state.ballPositions[BallID.black] = Vec2(1500, 520)   // well off both edges' lines
        }
        XCTAssertFalse(game.isSnookered())
    }

    /// The same test fails as soon as **one** extreme edge is cut off: a ball on showing only part of
    /// itself is "partially obstructed", and partially obstructed is snookered. Reaching the ball in
    /// the middle is not enough — that is the wider question Rule 14(c) asks, and `hasClearPathToBallOn`
    /// is the one that asks it.
    func testABallOnCutOffAtOneExtremeEdgeIsSnookered() {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
            // The black lies across the line to the Red's right-hand extreme edge and clear of the line
            // to its left-hand one, so the Red can be reached in the middle and at one edge, but not at
            // both.
            state.ballPositions[BallID.black] = Vec2(1497.9, 941.2)
        }
        XCTAssertTrue(game.hasClearPathToBallOn(), "the Red can still be reached, thin edge included")
        XCTAssertTrue(game.isSnookered(), "but not at both extreme edges, so the cue ball is snookered")
    }

    /// And after a foul that leaves the ball on cut off at one edge, the incoming striker gets the
    /// free ball (Section 3 Rule 12: "After a foul, if the cue-ball is snookered, the referee shall call
    /// FREE BALL").
    func testAFoulLeavingOneExtremeEdgeCutOffOffersAFreeBall() {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
            state.ballPositions[BallID.black] = Vec2(1497.9, 941.2)
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.black]      // foul: hit a ball not on
        _ = game.applyStroke(report, cueBallPosition: Vec2(1000, 889))
        game.acceptPositionLeft()
        guard case .nominateFreeBall(let options) = game.state.pending else {
            return XCTFail("the Red was left cut off at one edge, so a free ball is due")
        }
        XCTAssertTrue(options.contains(.black))
    }

    /// And a **Foul and a Miss** is a foul like any other for this call: a stroke that hits nothing at
    /// all, with the ball on cut off at one edge, leaves the incoming striker the same free ball.
    func testAFoulAndAMissLeavesTheFreeBallToo() {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
            state.ballPositions[BallID.black] = Vec2(1497.9, 941.2)
        }
        var report = StrokeReport()
        report.firstContacts = []                  // struck and missed everything
        let result = game.applyStroke(report, cueBallPosition: Vec2(1000, 889))
        XCTAssertTrue(result.missCalled, "nothing hit with a ball on is a foul and a miss")
        game.acceptPositionLeft()
        guard case .nominateFreeBall = game.state.pending else {
            return XCTFail("a foul and a miss leaves the free ball due when the ball on is not clear at both edges")
        }
    }

    func testFreeBallNomineeScoresTheValueOfTheBallOnAndIsRespotted() {
        let game = newGame()
        game.withState { state in
            state.freeBallNominee = .blue
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.blue]
        report.potted = [BallID.blue]
        _ = game.applyStroke(report, cueBallPosition: Vec2(900, 889))

        // Rule 12(c): the value of the ball on (a Red) is scored and the free ball is spotted.
        XCTAssertEqual(game.state.scores[0], 1)
        XCTAssertTrue(game.state.ballsOnTable.contains(BallID.blue))
        XCTAssertNotEqual(game.state.ballPositions[BallID.blue], Vec2(900, 889))
    }

    func testSnookeredAfterFoulOffersAFreeBall() {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
            state.ballPositions[BallID.black] = Vec2(1500, 889)
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.black]      // foul: hit a ball not on
        _ = game.applyStroke(report, cueBallPosition: Vec2(1000, 889))
        game.acceptPositionLeft()
        if case .nominateFreeBall(let options) = game.state.pending {
            XCTAssertTrue(options.contains(.black))
        } else {
            XCTFail("expected a free ball nomination after being snookered by a foul")
        }
    }

    /// A free ball may not be the ball on itself, and it has to be a colour still on the table
    /// (Rule 12(a)(i)): a nomination the referee would refuse is refused here too. Without the check the
    /// ball on could be named as its own free ball and then **spotted** when it was potted in the
    /// ordinary way, which is not the game.
    func testAFreeBallCannotBeTheBallOnOrOneOffTheTable() {
        let game = newGame(reds: 0)
        game.withState { state in
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.blue)
            state.ballsOnTable = [BallID.cue, BallID.blue, BallID.pink]
        }
        game.nominateFreeBall(.blue)               // the ball on itself
        XCTAssertNil(game.state.freeBallNominee, "the ball on cannot be its own free ball")
        game.nominateFreeBall(.black)              // not on the table
        XCTAssertNil(game.state.freeBallNominee, "nor can a ball that is off it")
        game.nominateFreeBall(.pink)               // a colour on the table, not the ball on: fine
        XCTAssertEqual(game.state.freeBallNominee, .pink)
    }

    // MARK: Taking the answer back (the `U` key)

    /// A foul to answer: one Red on the table, a stroke that hits nothing, which is a foul and a miss.
    private func aFoulToAnswer() -> SnookerGame {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.redsRemaining = 1
            state.ballOn = .red
            state.cueBallInHand = false
            state.pending = nil
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
        }
        var report = StrokeReport()
        report.firstContacts = []                  // struck and missed everything
        game.rememberLayout()                      // as the driver does before a stroke, so the balls
                                                   // *can* be put back, which is one of the answers
        _ = game.applyStroke(report, cueBallStart: Vec2(1000, 889), cueBallEnd: Vec2(1000, 889))
        return game
    }

    /// "Play from here" may be taken back until the next stroke is played: the question goes back exactly
    /// as it was asked, and nothing of the game has happened since but the answer. The penalty stands —
    /// it was the offender's, and taking an answer back is not the non-offender's to give away.
    func testPlayingFromHereCanBeTakenBackBeforeTheNextStroke() {
        let game = aFoulToAnswer()
        guard case .afterMiss = game.state.pending else {
            return XCTFail("expected the question after a foul and a miss")
        }
        XCTAssertFalse(game.canChooseSomethingElse, "nothing has been answered yet")
        let penalty = game.state.scores
        game.acceptPositionLeft()
        XCTAssertTrue(game.canChooseSomethingElse, "playing from here can be taken back")
        XCTAssertEqual(game.state.scores, penalty, "the penalty stands")
        game.chooseSomethingElse()
        guard case .afterMiss = game.state.pending else {
            return XCTFail("the question is back")
        }
        XCTAssertFalse(game.canChooseSomethingElse, "and it is in play again, not on the shelf")
        XCTAssertEqual(game.state.scores, penalty, "and the penalty still stands")
    }

    /// The striker's own stroke settles it, and so does any answer but "play from here": there is nothing
    /// to take back once the question is behind either of them.
    func testTheQuestionIsSettledByAStrokeOrByAnotherAnswer() {
        let struck = aFoulToAnswer()
        struck.acceptPositionLeft()
        XCTAssertTrue(struck.canChooseSomethingElse)
        struck.rememberLayout()                    // the next stroke is under way
        XCTAssertFalse(struck.canChooseSomethingElse, "the stroke settles the question")

        let answered = aFoulToAnswer()
        answered.askOffenderToPlayAgain()
        XCTAssertFalse(answered.canChooseSomethingElse, "an answer that is not 'play from here' is final")

        let replaced = aFoulToAnswer()
        replaced.acceptPositionLeft()
        replaced.requestOriginalPosition()
        XCTAssertFalse(replaced.canChooseSomethingElse, "and so is having the balls put back")
    }

    /// With the cue ball in hand the free ball is judged from where it is **put down**, not from where
    /// it happened to stop before: whether the striker is snookered is down to them, since they choose
    /// the spot. The offer comes after the placement.
    func testAFreeBallWithTheCueBallInHandIsJudgedAfterItIsPlaced() {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
            state.redsRemaining = 1
            state.ballOn = .red
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
            state.ballPositions[BallID.black] = Vec2(1500, 889)   // in the way of the Red
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.cueBallInHand = true
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.black]      // foul: hit a ball not on
        report.potted = [BallID.cue]
        report.cueBallPotted = true
        _ = game.applyStroke(report, cueBallPosition: Vec2(1000, 889))
        game.acceptPositionLeft()

        guard case .placeCueBallInD = game.state.pending else {
            return XCTFail("in hand, the striker places the ball first")
        }
        XCTAssertTrue(game.state.freeBallAvailable, "the free ball is still to be judged")
        XCTAssertTrue(game.placeCueBall(at: Vec2(600, 889)), "in the D")
        guard case .nominateFreeBall(let options) = game.state.pending else {
            return XCTFail("snookered from where it was placed, so the free ball is offered")
        }
        XCTAssertTrue(options.contains(.black))
    }

    /// Declining a free ball is the striker's to do — it is an offer, not an obligation (Rule 12(a)) —
    /// and it leaves nothing behind: the flag goes with the offer, so the ball on has to be hit first
    /// like any other stroke.
    func testDecliningAFreeBallLeavesNothingBehind() {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
            state.redsRemaining = 1
            state.ballOn = .red
            state.freeBallAvailable = true
            state.pending = .nominateFreeBall(options: [.black])
        }
        game.declineFreeBall()
        XCTAssertNil(game.state.freeBallNominee)
        XCTAssertFalse(game.state.freeBallAvailable, "the offer is answered, and gone with it")
        XCTAssertNil(game.state.pending)
    }

    // MARK: Foul and a miss (Rule 14)

    func testFirstMissIsCalledWhenThereWasAClearPath() {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
        }
        let report = StrokeReport()            // no contact at all
        let result = game.applyStroke(report, cueBallPosition: Vec2(700, 700))
        XCTAssertTrue(result.missCalled)
        XCTAssertEqual(game.state.scores[1], 4)
        if case .afterMiss(let decision) = game.state.pending {
            XCTAssertFalse(decision.frameAwarded)
        } else {
            XCTFail("expected a foul and a miss decision")
        }
    }

    func testSecondMissFromOriginalPositionIssuesAWarning() {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
            state.missCount = 1
        }
        let result = game.applyStroke(StrokeReport(), cueBallPosition: Vec2(800, 800))
        XCTAssertTrue(result.missCalled)
        XCTAssertTrue(game.state.missWarning)
        if case .afterMiss(let decision) = game.state.pending {
            XCTAssertTrue(decision.warningJustIssued)
        } else {
            XCTFail("expected a miss decision with a warning")
        }
    }

    func testThirdConsecutiveMissAwardsTheFrame() {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
            state.missCount = 2
            state.missWarning = true
        }
        let result = game.applyStroke(StrokeReport(), cueBallPosition: Vec2(800, 800))
        XCTAssertTrue(result.missCalled)
        XCTAssertTrue(game.state.frameOver)
        XCTAssertEqual(game.state.winner, 1)
    }

    /// The rule book spares a striker who could not have hit the ball on from a miss (Rule 14(a)(ii)).
    /// This game does not ask: a stroke that fails to hit a ball on is a foul **and a miss**, snookered
    /// or not — the simplification it plays to.
    func testAMissIsCalledEvenWhenTheBallOnCouldNotBeHit() {
        let game = newGame(reds: 1)
        game.withState { state in
            // Red tucked behind the Black with no path at all.
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
            state.ballPositions[BallID.cue] = Vec2(500, 300)
            state.ballPositions[BallID.black] = Vec2(600, 320)
            state.ballPositions[BallID.firstRed] = Vec2(3000, 1500)
        }
        let result = game.applyStroke(StrokeReport(), cueBallPosition: Vec2(700, 400))
        XCTAssertTrue(result.missCalled, "snookered or not, failing to hit a ball on is a miss")
        XCTAssertEqual(game.state.scores[1], 4)
        guard case .afterMiss = game.state.pending else {
            return XCTFail("expected a foul and a miss")
        }
    }

    /// Three failures to escape a snooker are three fouls, not the loss of the frame. The warning, and
    /// with it the frame the third failure hands over, is Rule 14(d)'s and comes only when the striker
    /// had "central, full ball, contact available": failing to get out of a snooker cannot cost a match.
    func testThreeFailuresToEscapeASnookerDoNotLoseTheFrame() {
        let game = newGame(reds: 1)
        func failToEscape() {
            game.withState { state in
                // Red tucked behind the Black with no path to it at all.
                state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
                state.ballPositions[BallID.cue] = Vec2(500, 300)
                state.ballPositions[BallID.black] = Vec2(600, 320)
                state.ballPositions[BallID.firstRed] = Vec2(3000, 1500)
            }
            let result = game.applyStroke(StrokeReport(), cueBallPosition: Vec2(700, 400))
            XCTAssertTrue(result.missCalled, "failing to hit a ball on is a foul and a miss")
            XCTAssertFalse(result.missWarning, "but not one that can cost the frame")
        }
        failToEscape()
        XCTAssertEqual(game.state.missCount, 0, "a failure out of a snooker is not counted")
        failToEscape()
        XCTAssertFalse(game.state.missWarning, "so the second one warns of nothing")
        failToEscape()
        XCTAssertFalse(game.state.frameOver, "and the third does not lose the frame")
        XCTAssertNil(game.state.winner)
        XCTAssertEqual(game.state.scores[0] + game.state.scores[1], 12,
                       "three fouls of four, and no frame")
    }

    /// The other half of Rule 14(d): the ball on has to be there to be hit **full ball**. A Red with a
    /// colour beside it, leaving only its thinnest edge, is not that — the striker can hit it, so the
    /// failure is a foul and a miss, but the frame does not follow a third one.
    func testAThinEdgeOfTheBallOnIsNotAFullBallContact() {
        let game = newGame(reds: 1)
        let cue = Vec2(1000, 889), red = Vec2(1300, 889), black = Vec2(1280, 940)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
            state.ballPositions[BallID.cue] = cue
            state.ballPositions[BallID.firstRed] = red
            state.ballPositions[BallID.black] = black
        }
        XCTAssertTrue(game.hasClearPathToBallOn(from: cue),
                      "the thin edge of the Red can be reached")
        XCTAssertFalse(game.hadFullBallContactAvailable(from: cue),
                       "but the middle of it cannot: the Black is in the way of that line")

        let failure = game.applyStroke(StrokeReport(), cueBallPosition: Vec2(1100, 950))
        XCTAssertTrue(failure.missCalled, "the failure is a foul and a miss")
        XCTAssertFalse(failure.missWarning)
        XCTAssertEqual(game.state.missCount, 0, "and it counts for nothing")

        // And a clear line to the middle of a ball on is exactly what does count.
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.ballPositions[BallID.cue] = cue
            state.ballPositions[BallID.firstRed] = red
        }
        XCTAssertTrue(game.hadFullBallContactAvailable(from: cue), "nothing in the way of the middle")
    }

    /// Rule 11(b)(vi): a ball in play contacted with the player's equipment — the cue — is a foul worth
    /// the ball on or the ball concerned, whichever is higher. The cue ball struck a second time is the
    /// double hit of Rule 11(a)(ii), worth the ball on.
    func testABallTouchedWithTheCueIsAFoul() {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
            state.ballPositions[BallID.black] = Vec2(2500, 889)
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.firstRed]
        report.ballsTheCueTouched = [BallID.black]
        let result = game.applyStroke(report, cueBallPosition: Vec2(1200, 889))
        guard let foul = result.foul else { return XCTFail("expected a foul") }
        XCTAssertTrue(foul.reason.contains("the cue touched a ball in play"), foul.reason)
        XCTAssertEqual(foul.penalty, 7, "the Black is worth more than the ball on")

        // And the cue ball itself, struck again: the double hit, worth the ball on.
        let again = newGame(reds: 1)
        again.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
        }
        var second = StrokeReport()
        second.firstContacts = [BallID.firstRed]
        second.ballsTheCueTouched = [BallID.cue]
        let struckTwice = again.applyStroke(second, cueBallPosition: Vec2(1200, 889))
        guard let foul = struckTwice.foul else { return XCTFail("expected a foul") }
        XCTAssertTrue(foul.reason.contains("struck the cue ball a second time"), foul.reason)
        XCTAssertEqual(foul.penalty, 4, "the ball on was a Red")
    }

    // MARK: What the non-offender may do (Rules 10(f), 10(h), 10(i), 12(f), 13 and 14(b))

    /// A foul and a miss, with the cue ball played from one place and finishing somewhere else, so
    /// that putting the balls back can be told apart from playing from where they lie.
    private func foulAndMiss() -> SnookerGame {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
        }
        game.rememberLayout()
        _ = game.applyStroke(StrokeReport(), cueBallStart: Vec2(1000, 889), cueBallEnd: Vec2(1500, 1200))
        return game
    }

    func testStrikingWithoutDeclaringAColourIsAFoulAndAMiss() {
        // Rule 11(d)(v)-(vi): once a Red has been potted the striker must declare which colour is
        // on. Striking without having declared one costs seven, and because no ball on was ever
        // chosen it is a Foul and a Miss as well.
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.yellow, BallID.green]
            state.ballOn = .anyColour
            state.nominatedColour = nil            // nothing declared
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.yellow] = Vec2(2000, 889)
            state.ballPositions[BallID.green] = Vec2(2500, 889)
        }
        // The driver remembers the layout before every stroke; the miss rule needs it.
        game.rememberLayout()
        var report = StrokeReport()
        report.firstContacts = [BallID.yellow]     // hit a colour, but none had been declared
        let result = game.applyStroke(report, cueBallStart: Vec2(1000, 889), cueBallEnd: Vec2(1900, 889))
        XCTAssertEqual(result.foul?.reason, "no colour was nominated")
        XCTAssertEqual(result.foul?.penalty, 7)
        XCTAssertTrue(result.missCalled)
        XCTAssertEqual(game.state.scores[1], 7)
        guard case .afterMiss(let decision) = game.state.pending else {
            return XCTFail("expected a foul and a miss")
        }
        XCTAssertTrue(decision.canRequestOriginalPosition)
    }

    func testDeclaringAColourMakesTheSameStrokeLegal() {
        // The same stroke with a colour declared is just a legal shot at that colour.
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.yellow, BallID.green]
            state.ballOn = .anyColour
            state.nominatedColour = .yellow
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.yellow] = Vec2(2000, 889)
            state.ballPositions[BallID.green] = Vec2(2500, 889)
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.yellow]
        let result = game.applyStroke(report, cueBallStart: Vec2(1000, 889), cueBallEnd: Vec2(1900, 889))
        XCTAssertNil(result.foul)
        XCTAssertFalse(result.missCalled)
        XCTAssertEqual(game.state.scores[0], 0, "nothing was potted, so nothing scored")
    }

    func testHittingTheWrongBallIsAFoulAndAMiss() {
        // Rule 14(c): failing to first hit a ball on covers hitting the wrong ball as well as
        // hitting nothing, so the non-offender gets the same three choices (Rule 14(b)).
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
            state.ballPositions[BallID.black] = Vec2(1400, 1400)
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.black]      // hit a ball not on, with the Red in clear view
        let result = game.applyStroke(report, cueBallStart: Vec2(1000, 889), cueBallEnd: Vec2(1500, 1200))
        XCTAssertTrue(result.missCalled, "hitting the wrong ball when the Red was there is a miss")
        XCTAssertEqual(game.state.scores[1], 7, "hitting the Black when a Red is on costs seven")
        guard case .afterMiss(let decision) = game.state.pending else {
            return XCTFail("expected a foul and a miss")
        }
        XCTAssertTrue(decision.canRequestOriginalPosition,
                      "so the balls may be replaced and the offender asked to play again")
    }

    func testFoulAndAMissLetsTheNonOffenderAskForTheOriginalPosition() {
        let game = foulAndMiss()
        guard case .afterMiss(let decision) = game.state.pending else {
            return XCTFail("expected a foul and a miss")
        }
        XCTAssertTrue(decision.canRequestOriginalPosition,
                      "Rule 14(b): the balls may be replaced and the offender asked to play again")
    }

    func testAnOrdinaryFoulDoesNotAllowTheBallsToBeReplaced() {
        // Rule 12(f) lists the cases where the balls may be put back, and a foul committed during a
        // stroke is not one of them: the non-offender plays from where they lie, or asks the
        // offender to play again from there. Here the striker hits a Red properly and then pots a
        // colour that is not on.
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.pink]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
            state.ballPositions[BallID.pink] = Vec2(2200, 889)
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.firstRed]   // a legal first contact
        report.potted = [BallID.pink]              // but a colour potted with a Red on: a foul
        _ = game.applyStroke(report, cueBallPosition: Vec2(1000, 889))
        guard case .afterFoul(let decision) = game.state.pending else {
            return XCTFail("expected an ordinary foul, not a miss")
        }
        XCTAssertFalse(decision.canRequestOriginalPosition)
    }

    func testRequestingTheOriginalPositionPutsTheBallsBackAndTheOffenderPlays() {
        let game = foulAndMiss()
        XCTAssertEqual(game.state.currentPlayer, 1, "the foul passes the turn to the other player")
        game.requestOriginalPosition()
        XCTAssertEqual(game.state.ballPositions[BallID.cue], Vec2(1000, 889),
                       "the cue ball goes back to where the stroke was played from")
        XCTAssertEqual(game.state.ballPositions[BallID.firstRed], Vec2(2000, 889))
        XCTAssertEqual(game.state.ballOn, .red, "and so does the ball on")
        XCTAssertEqual(game.state.currentPlayer, 0, "the offender plays again when asked")
        XCTAssertEqual(game.state.breakScore, 0)
        XCTAssertEqual(game.state.scores[1], 4, "the penalty already awarded stands")
        XCTAssertFalse(game.state.freeBallAvailable, "Rule 12(f): the free ball option is void")
    }

    func testRequestingTheOriginalPositionCarriesTheMissSequenceOn() {
        let game = foulAndMiss()
        XCTAssertEqual(game.state.missCount, 1)
        game.requestOriginalPosition()
        XCTAssertEqual(game.state.missCount, 1,
                       "Rule 14(d): a further failure from the same position is a second failure")
    }

    func testAskingTheOffenderToPlayAgainVoidsTheFreeBall() {
        let game = newGame(reds: 1)
        game.withState { state in
            // Black between the cue ball and the only Red: a free ball would be on offer.
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
            state.ballPositions[BallID.black] = Vec2(1500, 889)
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.black]      // foul: hit a ball not on
        _ = game.applyStroke(report, cueBallPosition: Vec2(1000, 889))
        game.askOffenderToPlayAgain()
        XCTAssertFalse(game.state.freeBallAvailable,
                       "Rule 12(f): asking the offender to play again voids the free ball")
        if case .nominateFreeBall = game.state.pending {
            XCTFail("the offender does not receive the free ball")
        }
    }

    /// Two balls potted in one stroke where one of them was not on. The striker scores nothing,
    /// the ball not on is spotted, and the penalty is the higher of the ball on and the ball
    /// concerned (Rules 10(e), 11(b)(iii)).
    func testPottingAColourOtherThanTheOneNominatedIsAFoul() {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.pink, BallID.black]
            state.redsRemaining = 1
            state.ballOn = .anyColour
            state.nominatedColour = .black
            state.ballPositions[BallID.cue] = Vec2(600, 889)
            state.ballPositions[BallID.black] = Vec2(2000, 889)
            state.ballPositions[BallID.pink] = Vec2(2400, 889)
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.black]
        report.potted = [BallID.black, BallID.pink]
        _ = game.applyStroke(report, cueBallPosition: Vec2(600, 889))

        XCTAssertEqual(game.state.scores, [0, 7], "the value of the ball on, to the opponent")
        XCTAssertTrue(game.state.ballsOnTable.contains(BallID.black), "the Black is respotted")
        XCTAssertTrue(game.state.ballsOnTable.contains(BallID.pink), "and so is the Pink")
        XCTAssertEqual(game.state.currentPlayer, 1, "and the striker's turn is over")
    }

    // MARK: Touching ball (Rule 8)

    /// The cue ball resting against a Red, as the next stroke will find it. The layout is remembered
    /// the way the driver remembers it, since the touching call is made from where the stroke is
    /// played.
    private func restingAgainstARed() -> SnookerGame {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
            state.redsRemaining = 1
            state.ballOn = .red
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(1000 + Table.ballDiameter, 889)
            state.ballPositions[BallID.black] = Vec2(2500, 889)
        }
        game.rememberLayout()
        return game
    }

    /// A ball the cue ball is touching, that does not move, needs no contact of its own: playing away
    /// from it is the stroke (Rule 8(c)). Nothing may be contacted and there is still no foul.
    func testTouchingABallOnAndPlayingAwayNeedsNoContact() {
        let game = restingAgainstARed()
        XCTAssertEqual(game.touchingBallsOn(cueBall: Vec2(1000, 889),
                                            positions: game.state.ballPositions), [BallID.firstRed])

        var report = StrokeReport()                  // no contact at all
        report.movedBalls = []
        _ = game.applyStroke(report, cueBallPosition: Vec2(900, 889))

        XCTAssertNil(game.state.pending, "no foul to answer")
        XCTAssertEqual(game.state.scores, [0, 0])
        XCTAssertEqual(game.state.currentPlayer, 1, "the turn passes in the ordinary way")
        XCTAssertFalse(game.state.commentary.contains { $0.hasPrefix("TOUCHING BALL") },
                       "and nothing is called, the cue ball having finished clear of the Red")
    }

    /// The call is made at the completion of a stroke, so it is the ball the cue ball comes to rest
    /// against that is named (Rule 8(a)).
    func testTheCallIsMadeWhenTheCueBallComesToRestAgainstABallOn() {
        let game = restingAgainstARed()
        var report = StrokeReport()
        report.firstContacts = [BallID.firstRed]
        report.movedBalls = []
        // The cue ball finishes where it started, a diameter from the Red.
        _ = game.applyStroke(report, cueBallPosition: Vec2(1000, 889))

        XCTAssertTrue(game.state.commentary.contains { $0.hasPrefix("TOUCHING BALL") },
                      "the Red is on and the cue ball is against it")
    }

    /// Moving the ball the cue ball was touching is a push stroke (Rule 8(b), Rule 11(b)(v)).
    func testMovingTheBallTheCueBallIsTouchingIsAPushStroke() {
        let game = restingAgainstARed()
        var report = StrokeReport()
        report.firstContacts = [BallID.firstRed]
        report.movedBalls = [BallID.firstRed]
        _ = game.applyStroke(report, cueBallPosition: Vec2(1000, 889))

        guard case .afterFoul(let decision) = game.state.pending else {
            return XCTFail("expected a foul for the non-offender to answer")
        }
        XCTAssertTrue(decision.foul.reason.contains("push stroke"), decision.foul.reason)
        XCTAssertEqual(game.state.scores, [0, 4], "the ball on is a Red, so four points")
    }

    /// Rule 8(c)(i): the cue ball is resting against a ball that **is** on, and the striker plays away
    /// from it without moving it. That contact is the stroke's contact with a ball on, so the cue ball
    /// may be played straight into a ball that is not on — a ball touching a Red, with Red on, can be
    /// played at a colour, and neither the wrong-ball foul nor the miss is called for it.
    func testACueBallTouchingARedMayBePlayedAtAColour() {
        let game = restingAgainstARed()
        var report = StrokeReport()
        report.firstContacts = [BallID.black]        // played away from the Red into a colour
        report.movedBalls = []
        let result = game.applyStroke(report, cueBallStart: Vec2(1000, 889), cueBallEnd: Vec2(1500, 700))
        XCTAssertNil(result.foul, "the touching Red was the ball on, so the colour may be hit first")
        XCTAssertFalse(result.missCalled)
    }

    /// Rule 8(e): the call names the balls on, not a ball not on that happens to be touching too.
    func testTheCallNamesOnlyBallsThatAreOn() {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
            state.redsRemaining = 1
            state.ballOn = .red
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(1000 + Table.ballDiameter, 889)
            state.ballPositions[BallID.black] = Vec2(1000, 889 - Table.ballDiameter)
        }
        game.rememberLayout()
        XCTAssertEqual(game.touchingBalls(cueBall: Vec2(1000, 889)), [BallID.firstRed, BallID.black],
                       "both are touching")
        XCTAssertEqual(game.touchingBallsOn(cueBall: Vec2(1000, 889)), [BallID.firstRed],
                       "but only the Red is on")
    }

    /// Rule 8(a): touching colours after a Red means the striker is asked to declare which colour.
    func testTouchingColoursAfterARedAsksForADeclaration() {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.yellow, BallID.black]
            state.redsRemaining = 1
            state.ballOn = .red
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(1000 + Table.ballDiameter * 3, 889)
            state.ballPositions[BallID.yellow] = Vec2(1000 - Table.ballDiameter, 889)
            state.ballPositions[BallID.black] = Vec2(2500, 889)
        }
        game.rememberLayout()

        // Pot the Red: the striker is on a colour of their own choice, with the cue ball touching the
        // Yellow.
        var report = StrokeReport()
        report.firstContacts = [BallID.firstRed]
        report.potted = [BallID.firstRed]
        report.movedBalls = [BallID.firstRed]
        // The cue ball comes to rest against the Yellow, a diameter away.
        _ = game.applyStroke(report, cueBallPosition: Vec2(1000 - Table.ballDiameter, 889))

        XCTAssertEqual(game.state.ballOn, .anyColour)
        XCTAssertTrue(game.state.commentary.contains { $0.hasPrefix("TOUCHING BALL") },
                      "the Yellow is called, and it could be on")
        XCTAssertTrue(game.state.commentary.contains { $0.contains("Declare which colour") },
                      "so the striker is asked to declare")
    }

    // MARK: The free ball as a blocker (Rules 11(a)(viii), 12(b)(ii))

    /// A free ball nominated with a Red on, and a stroke in which nothing is potted. `blocking` puts
    /// the nominated ball straight between the cue ball and the Red.
    private func freeBallStroke(blocking: Bool, ballOn: BallOn = .red, onTable: [Int]? = nil,
                                freeBall: BallColor = .black) -> SnookerGame {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = Set(onTable ?? [BallID.cue, BallID.firstRed, BallID.black])
            state.redsRemaining = state.ballsOnTable.contains(BallID.firstRed) ? 1 : 0
            state.ballOn = ballOn
            state.freeBallAvailable = true
            state.freeBallNominee = freeBall
            state.cueBallInHand = false
            state.pending = nil
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.black] = Vec2(1500, blocking ? 889 : 1200)
            state.ballPositions[BallID.pink] = Vec2(2400, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.colourID(freeBall)!]
        _ = game.applyStroke(report, cueBallPosition: Vec2(1000, 889))
        return game
    }

    /// The free ball is a ball on for the stroke and must not be left doing the snookering: the
    /// striker cannot hide behind the ball they nominated (Rule 12(b)(ii), Rule 11(a)(viii)).
    func testLeavingTheNominatedFreeBallAsASnookerIsAFoul() {
        let game = freeBallStroke(blocking: true)
        XCTAssertEqual(game.state.scores, [0, 4], "four points, the ball on being a Red")
        XCTAssertEqual(game.state.currentPlayer, 1, "and the turn passes")
        guard case .afterFoul(let decision) = game.state.pending else {
            return XCTFail("expected a foul for the non-offender to answer")
        }
        XCTAssertTrue(decision.foul.reason.contains("snookered by the nominated free ball"))
        XCTAssertFalse(decision.canRequestOriginalPosition,
                       "the balls were not moved before the stroke, so they stay where they lie")
    }

    /// The same stroke with the nominated ball clear of the line: no snooker, so no foul.
    func testAFreeBallLeftClearOfTheBallOnIsNoFoul() {
        let game = freeBallStroke(blocking: false)
        XCTAssertEqual(game.state.scores, [0, 0])
        XCTAssertEqual(game.state.currentPlayer, 1, "the turn passes in the ordinary way")
        XCTAssertNil(game.state.pending)
    }

    /// The rule excepts the end of the frame: with only the Pink and Black left, the free ball may
    /// be left snookering (Rule 12(b)(ii)).
    func testTheFreeBallMayBeLeftSnookeringWhenOnlyThePinkAndBlackAreLeft() {
        let game = freeBallStroke(blocking: true, ballOn: .colourOfSequence(.pink),
                                  onTable: [BallID.cue, BallID.pink, BallID.black])
        XCTAssertEqual(game.state.scores, [0, 0], "no foul at the end of the frame")
        XCTAssertNil(game.state.pending)
        XCTAssertEqual(game.state.ballOn, .colourOfSequence(.pink))
    }

    /// A colour that is not on the table cannot be the ball on, so nominating one is not accepted:
    /// the number keys are only offered the colours that are there, and the engine agrees.
    func testAColourThatIsNotOnTheTableCannotBeNominated() {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.yellow]
            state.redsRemaining = 1
            state.ballOn = .anyColour
        }
        game.nominateColour(.black)          // the Black is off the table
        XCTAssertNil(game.state.nominatedColour)

        game.nominateColour(.yellow)
        XCTAssertEqual(game.state.nominatedColour, .yellow)
        XCTAssertNil(game.state.pending, "and the choice is taken")
    }

    // MARK: The colours (Rule 3(h))

    /// A frame down to its last Red, with a colour nominated, ready for the stroke that ends the
    /// Reds-and-colours alternation.
    private func lastRedAndAColour(_ colour: BallColor = .green) -> SnookerGame {
        let game = newGame(reds: 1)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.yellow, BallID.green, BallID.brown,
                                  BallID.blue, BallID.pink, BallID.black]
            state.redsRemaining = 1
            state.ballOn = .red
            state.ballPositions[BallID.cue] = Vec2(600, 889)
            state.ballPositions[BallID.firstRed] = Vec2(800, 889)
            for (index, each) in BallColor.coloursInAscendingOrder.enumerated() {
                state.ballPositions[BallID.colourID(each)!] = Vec2(900 + Double(index) * 200, 889)
            }
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.firstRed]
        report.potted = [BallID.firstRed]
        _ = game.applyStroke(report, cueBallPosition: Vec2(600, 889))
        game.nominateColour(colour)
        return game
    }

    /// A colour played after the last Red ends the alternation whether or not it was potted: the
    /// colours are then on in ascending order, so the next player is on the yellow and nobody is
    /// asked to nominate a colour of their own (Rule 3(h)(ii)-(iii)).
    func testTheColoursStartAtYellowHoweverTheColourAfterTheLastRedGoes() {
        // Potted.
        let potted = lastRedAndAColour()
        var report = StrokeReport()
        report.firstContacts = [BallID.green]
        report.potted = [BallID.green]
        _ = potted.applyStroke(report, cueBallPosition: Vec2(1100, 889))
        XCTAssertEqual(potted.state.scores[0], 1 + 3, "the Red and then the Green")
        XCTAssertTrue(potted.state.ballsOnTable.contains(BallID.green), "the Green is spotted")
        XCTAssertEqual(potted.state.ballOn, .colourOfSequence(.yellow))
        XCTAssertNil(potted.state.pending, "and there is nothing for anyone to nominate")

        // Missed.
        let missed = lastRedAndAColour()
        report = StrokeReport()
        report.firstContacts = [BallID.green]
        _ = missed.applyStroke(report, cueBallPosition: Vec2(1100, 889))
        XCTAssertEqual(missed.state.ballOn, .colourOfSequence(.yellow),
                       "the colours are on in order, not a colour of the next player's choice")
        XCTAssertNil(missed.state.pending, "so the next player is not asked to nominate one")
        XCTAssertEqual(missed.state.currentPlayer, 1)
    }

    /// Clearing the colours, in every case the free ball rule gives (Rule 12(a), (c) and (e)).
    private func clearingTheColours(freeBall: BallColor?) -> SnookerGame {
        let game = newGame(reds: 0)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.yellow, BallID.green, BallID.brown, BallID.blue,
                                  BallID.pink, BallID.black]
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.yellow)
            state.cueBallInHand = false
            state.pending = nil
            state.freeBallAvailable = freeBall != nil
            state.freeBallNominee = freeBall
            state.ballPositions[BallID.cue] = Vec2(600, 889)
            for (index, each) in BallColor.coloursInAscendingOrder.enumerated() {
                state.ballPositions[BallID.colourID(each)!] = Vec2(900 + Double(index) * 200, 889)
            }
        }
        return game
    }

    func testAFreeBallPottedWhileClearingTheColoursScoresTheBallOn() {
        let game = clearingTheColours(freeBall: .blue)
        var report = StrokeReport()
        report.firstContacts = [BallID.blue]
        report.potted = [BallID.blue]
        _ = game.applyStroke(report, cueBallPosition: Vec2(600, 889))

        XCTAssertEqual(game.state.scores[0], 2, "the value of the ball on, the Yellow, is scored")
        XCTAssertEqual(game.state.currentPlayer, 0, "and the striker plays on")
        XCTAssertTrue(game.state.ballsOnTable.contains(BallID.blue), "the free ball is spotted")
        XCTAssertTrue(game.state.ballsOnTable.contains(BallID.yellow), "the Yellow is still on")
        XCTAssertEqual(game.state.ballOn, .colourOfSequence(.yellow), "and is still the ball on")
    }

    func testAFreeBallAndTheBallOnPottedScoresOnlyTheBallOn() {
        let game = clearingTheColours(freeBall: .blue)
        var report = StrokeReport()
        report.firstContacts = [BallID.blue]
        report.potted = [BallID.blue, BallID.yellow]
        _ = game.applyStroke(report, cueBallPosition: Vec2(600, 889))

        XCTAssertEqual(game.state.scores[0], 2, "only the ball on scores, not the free ball too")
        XCTAssertTrue(game.state.ballsOnTable.contains(BallID.blue), "the free ball is spotted")
        XCTAssertFalse(game.state.ballsOnTable.contains(BallID.yellow), "the Yellow stays off")
        XCTAssertEqual(game.state.ballOn, .colourOfSequence(.green), "and the sequence moves on")
    }

    func testPlayingAtAColourAndMissingLeavesTheSameColourOn() {
        let game = clearingTheColours(freeBall: nil)
        var report = StrokeReport()
        report.firstContacts = [BallID.yellow]
        _ = game.applyStroke(report, cueBallPosition: Vec2(600, 889))

        XCTAssertEqual(game.state.ballOn, .colourOfSequence(.yellow))
        XCTAssertEqual(game.state.currentPlayer, 1, "the turn passes")
        XCTAssertNil(game.state.pending, "with nothing to nominate")
    }

    // MARK: Ball on after a foul (Rule 3(g))

    /// A striker who has potted a Red is playing for a colour of their own choice. If they foul
    /// there, the turn passes and the incoming player starts a turn of their own, which Rule 3(g)
    /// says is on a Red for as long as a Red is on the table — the colour does not travel with the
    /// foul.
    func testFoulWhilePlayingForAColourLeavesTheIncomingPlayerOnARed() {
        let game = newGame(reds: 3)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.firstRed + 1, BallID.firstRed + 2,
                                  BallID.black]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
            state.ballPositions[BallID.firstRed + 1] = Vec2(2200, 889)
            state.ballPositions[BallID.firstRed + 2] = Vec2(2400, 889)
            state.ballPositions[BallID.black] = Vec2(1500, 889)
            state.ballOn = .anyColour
            state.nominatedColour = .black
        }
        var report = StrokeReport()
        report.firstContacts = []                  // struck and missed everything: a foul
        _ = game.applyStroke(report, cueBallPosition: Vec2(1000, 889))

        XCTAssertEqual(game.state.currentPlayer, 1, "the foul passes the turn to the other player")
        XCTAssertEqual(game.state.ballOn, .red, "Rule 3(g): the incoming player's turn is on a Red")
        XCTAssertNil(game.state.nominatedColour, "the offender's colour is not carried over")

        game.acceptPositionLeft()
        XCTAssertEqual(game.state.ballOn, .red, "playing from here does not put them on a colour")
        XCTAssertEqual(game.state.currentPlayer, 1)
    }

    /// Rule 3(g) and Rule 13: asking the offender to play again starts a **new turn**, so while any
    /// Red is left the ball on is a Red — not the colour the offender was playing for when they
    /// fouled. Rule 13(a)(ii) only lets them change their mind about a ball on that is already a
    /// colour of their own choice, which never arises at the start of a turn.
    func testTheOffenderIsOnARedWhenAskedToPlayAgainWhileRedsRemain() {
        let game = newGame(reds: 3)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.firstRed + 1, BallID.firstRed + 2,
                                  BallID.black]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
            state.ballPositions[BallID.firstRed + 1] = Vec2(2200, 889)
            state.ballPositions[BallID.firstRed + 2] = Vec2(2400, 889)
            state.ballPositions[BallID.black] = Vec2(1500, 889)
            state.ballOn = .anyColour
            state.nominatedColour = .black
        }
        var report = StrokeReport()
        report.firstContacts = []
        _ = game.applyStroke(report, cueBallPosition: Vec2(1000, 889))
        game.askOffenderToPlayAgain()

        XCTAssertEqual(game.state.currentPlayer, 0, "the offender plays again when asked")
        XCTAssertEqual(game.state.ballOn, .red, "Rule 3(g): the new turn is on a Red")
        XCTAssertNil(game.state.nominatedColour, "the offender's old colour is not carried over")
        if case .nominateColour = game.state.pending {
            XCTFail("a Red is on, so there is no colour to nominate")
        }
    }

    /// A regression check on the ball on itself: after the offender is asked to play again with
    /// Reds still on the table, a stroke that first hits a Red is legal and one that first hits a
    /// colour is a foul (Rule 11(b)(i), Rule 3(g)).
    func testTheOffenderAskedToPlayAgainMustHitARedFirst() {
        let game = newGame(reds: 3)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.firstRed + 1, BallID.firstRed + 2,
                                  BallID.black]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
            state.ballPositions[BallID.firstRed + 1] = Vec2(2200, 889)
            state.ballPositions[BallID.firstRed + 2] = Vec2(2400, 889)
            state.ballPositions[BallID.black] = Vec2(1500, 889)
            state.ballOn = .anyColour
            state.nominatedColour = .black
        }
        var foul = StrokeReport()
        foul.firstContacts = []
        _ = game.applyStroke(foul, cueBallPosition: Vec2(1000, 889))
        game.askOffenderToPlayAgain()

        // Hitting the Red first is legal.
        var legal = StrokeReport()
        legal.firstContacts = [BallID.firstRed]
        let legalResult = game.applyStroke(legal, cueBallPosition: Vec2(1800, 889))
        XCTAssertNil(legalResult.foul, "a Red is on, so hitting a Red first is legal")

        // Set up the same position again and hit the Black first instead: a foul.
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.firstRed + 1, BallID.firstRed + 2,
                                  BallID.black]
            state.currentPlayer = 0
            state.ballOn = .red
            state.nominatedColour = nil
            state.pending = nil
            state.cueBallInHand = false
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
            state.ballPositions[BallID.firstRed + 1] = Vec2(2200, 889)
            state.ballPositions[BallID.firstRed + 2] = Vec2(2400, 889)
            state.ballPositions[BallID.black] = Vec2(1500, 889)
        }
        var illegal = StrokeReport()
        illegal.firstContacts = [BallID.black]
        let illegalResult = game.applyStroke(illegal, cueBallPosition: Vec2(1400, 889))
        XCTAssertNotNil(illegalResult.foul, "hitting the Black first with a Red on is a foul")
        XCTAssertEqual(illegalResult.foul?.penalty, 7, "the higher of the ball on and the ball concerned")
    }

    /// In the colours the sequence runs in ascending order (Rule 3(h)(iii)), so a foul leaves the
    /// same colour on for the incoming player.
    func testAFoulInTheColoursLeavesTheSameColourOn() {
        let game = newGame(reds: 0)
        game.withState { state in
            state.redsRemaining = 0
            state.ballsOnTable = [BallID.cue, BallID.green, BallID.brown, BallID.blue, BallID.pink,
                                  BallID.black]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.green] = Vec2(2000, 889)
            state.ballPositions[BallID.brown] = Vec2(2200, 889)
            state.ballPositions[BallID.blue] = Vec2(2400, 889)
            state.ballPositions[BallID.pink] = Vec2(2600, 889)
            state.ballPositions[BallID.black] = Vec2(2800, 889)
            state.ballOn = .colourOfSequence(.green)   // Yellow has already gone
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.black]      // foul: first hit a ball not on
        _ = game.applyStroke(report, cueBallPosition: Vec2(1000, 889))

        XCTAssertEqual(game.state.currentPlayer, 1)
        XCTAssertEqual(game.state.ballOn, .colourOfSequence(.green),
                       "Green is still the next colour in the sequence")
    }

    /// The colour played after the last Red is the striker's own choice for that stroke only. If
    /// they foul there, the colours are on in ascending order for the incoming player (Rule
    /// 3(h)(ii)-(iii)), which is Yellow.
    func testAFoulPlayingTheColourAfterTheLastRedLeavesYellowOn() {
        let game = newGame(reds: 0)
        game.withState { state in
            state.redsRemaining = 0
            state.ballsOnTable = [BallID.cue, BallID.yellow, BallID.green, BallID.brown, BallID.blue,
                                  BallID.pink, BallID.black]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.yellow] = Vec2(2000, 889)
            state.ballPositions[BallID.green] = Vec2(2100, 889)
            state.ballPositions[BallID.brown] = Vec2(2200, 889)
            state.ballPositions[BallID.blue] = Vec2(2400, 889)
            state.ballPositions[BallID.pink] = Vec2(2600, 889)
            state.ballPositions[BallID.black] = Vec2(2800, 889)
            state.ballOn = .anyColour            // the colour after the final Red
            state.nominatedColour = .black
        }
        var report = StrokeReport()
        report.firstContacts = []
        _ = game.applyStroke(report, cueBallPosition: Vec2(1000, 889))

        XCTAssertEqual(game.state.currentPlayer, 1)
        XCTAssertEqual(game.state.ballOn, .colourOfSequence(.yellow),
                       "the colours are on in ascending order for the incoming player")
    }

    /// Rule 3(i): a Red potted in a foul stroke is not replaced, and Rule 10(e) says it does not
    /// score, so it comes off the table without changing the score.
    func testARedPottedInAFoulStrokeLeavesTheTableWithoutScoring() {
        let game = newGame(reds: 2)
        game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.firstRed + 1, BallID.black]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2000, 889)
            state.ballPositions[BallID.firstRed + 1] = Vec2(2200, 889)
            state.ballPositions[BallID.black] = Vec2(1500, 889)
            state.ballOn = .anyColour
            state.nominatedColour = .black
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.black]      // Black is on: a legal first contact
        report.potted = [BallID.firstRed]          // but a Red in the same stroke is a foul
        _ = game.applyStroke(report, cueBallPosition: Vec2(1000, 889))

        XCTAssertEqual(game.state.scores[1], 7, "the foul is on the Black, so it costs seven")
        XCTAssertFalse(game.state.ballsOnTable.contains(BallID.firstRed), "the Red stays off")
        XCTAssertEqual(game.state.redsRemaining, 1, "and is no longer counted as on the table")
        XCTAssertEqual(game.state.scores[0], 0, "nothing scores in a foul stroke")
        XCTAssertEqual(game.state.ballOn, .red, "and the incoming player is still on a Red")
    }

    // MARK: End of frame (Rule 4)

    func testFirstPotWithBlackTheOnlyBallEndsTheFrame() {
        let game = newGame(reds: 0)
        game.withState { state in
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.black)
            state.ballsOnTable = [BallID.cue, BallID.black]
            state.scores = [40, 20]
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.black]
        report.potted = [BallID.black]
        _ = game.applyStroke(report, cueBallPosition: Vec2(1200, 889))
        XCTAssertTrue(game.state.frameOver)
        XCTAssertEqual(game.state.winner, 0)
        XCTAssertEqual(game.state.scores[0], 47)
    }

    func testFrameIsNotOverWithBlackOnlyWhenTheLeadIsSevenOrLess() {
        let game = newGame(reds: 0)
        game.withState { state in
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.black)
            state.ballsOnTable = [BallID.cue, BallID.black]
            state.scores = [30, 24]
        }
        XCTAssertFalse(game.state.frameOver)
    }

    /// With only the Black left and the opponent needing snookers, the striker may claim the frame
    /// (Section 2 Rule 1(b)) — but they are not made to. The frame is not ended for them: they can
    /// play on and pot the Black, which ends it just as well (Section 3 Rule 4(a)).
    func testTheStrikerWithTheBlackLeftMayClaimTheFrameButIsNotMadeTo() {
        let game = newGame(reds: 0)
        game.withState { state in
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.pink)
            state.ballsOnTable = [BallID.cue, BallID.pink, BallID.black]
            state.scores = [48, 40]              // eight ahead: the opponent needs snookers
        }
        // Potting the Pink leaves the Black as the only ball, fourteen ahead: the frame is not ended
        // for the striker, and the claim is theirs to take or leave.
        var report = StrokeReport()
        report.firstContacts = [BallID.pink]
        report.potted = [BallID.pink]
        _ = game.applyStroke(report, cueBallPosition: Vec2(1200, 889))
        XCTAssertFalse(game.state.frameOver, "the striker must not be made to claim the frame")
        XCTAssertTrue(game.strikerMayClaimTheFrame, "but the claim is theirs to take")

        XCTAssertTrue(game.claimTheFrame())
        XCTAssertTrue(game.state.frameOver)
        XCTAssertEqual(game.state.winner, 0)
        XCTAssertEqual(game.state.scores, [54, 40], "claiming the frame adds nothing to the score")
    }

    /// The other way round, the frame is awarded to the non-striker who is more than seven ahead
    /// (Section 2 Rule 1(c)) — it is not the striker's to claim.
    /// The rule book *awards* the frame to the non-striker when it is they who are more than seven
    /// ahead with only the Black left (Section 2 Rule 1(c)). The game offers it as a claim instead, so
    /// the frame is never ended for the player at the table: whoever is ahead takes it with the button,
    /// and until they do the game plays on, the first pot or foul ending the frame on the scores.
    func testTheFrameIsThereForTheNonStrikerToClaimWithOnlyTheBlackLeft() {
        let game = newGame(reds: 0)
        game.withState { state in
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.pink)
            state.ballsOnTable = [BallID.cue, BallID.pink, BallID.black]
            state.scores = [30, 44]              // the striker is fourteen behind
        }
        XCTAssertNil(game.claimOfTheFrame, "the Pink is still on the table")
        XCTAssertFalse(game.strikerMayClaimTheFrame, "it is not the striker's to claim")
        XCTAssertFalse(game.claimTheFrame())

        var report = StrokeReport()
        report.firstContacts = [BallID.pink]
        report.potted = [BallID.pink]            // leaving the Black, with the striker still behind
        _ = game.applyStroke(report, cueBallPosition: Vec2(1200, 889))

        XCTAssertFalse(game.state.frameOver, "the frame is not taken off the table for them")
        XCTAssertEqual(game.claimOfTheFrame, 1, "it is there for the non-striker, who is ahead")
        XCTAssertTrue(game.claimTheFrame(), "and they take it with the button")
        XCTAssertTrue(game.state.frameOver)
        XCTAssertEqual(game.state.winner, 1)
        XCTAssertEqual(game.state.scores, [36, 44])
    }

    /// And the claim is refused while there is anything else to play for: a ball other than the
    /// Black still on the table, or a lead of seven or less.
    func testTheClaimIsRefusedWhenItIsNotTheStrikersToClaim() {
        let withABallLeft = newGame(reds: 0)
        withABallLeft.withState { state in
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.black)
            state.ballsOnTable = [BallID.cue, BallID.pink, BallID.black]
            state.scores = [48, 40]
        }
        XCTAssertFalse(withABallLeft.strikerMayClaimTheFrame)
        XCTAssertFalse(withABallLeft.claimTheFrame())

        let notAheadEnough = newGame(reds: 0)
        notAheadEnough.withState { state in
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.black)
            state.ballsOnTable = [BallID.cue, BallID.black]
            state.scores = [47, 40]
        }
        XCTAssertFalse(notAheadEnough.strikerMayClaimTheFrame, "seven ahead is not more than seven")
        XCTAssertFalse(notAheadEnough.claimTheFrame())
        XCTAssertFalse(notAheadEnough.state.frameOver)
    }

    /// Potting the Black to level the scores does not win the frame: the Black is re-spotted, the
    /// players draw lots for the choice of playing next, and that player plays from in-hand
    /// (Section 3 Rule 4(a)-(b)).
    func testPottingTheBlackToLevelTheScoresRespotsIt() {
        let game = newGame(reds: 0)
        game.decideTheDraw = { 1 }               // so the draw has a known winner
        game.withState { state in
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.black)
            state.ballsOnTable = [BallID.cue, BallID.black]
            state.scores = [33, 40]              // seven behind: the Black levels it
        }
        var report = StrokeReport()
        report.firstContacts = [BallID.black]
        report.potted = [BallID.black]
        _ = game.applyStroke(report, cueBallPosition: Vec2(1200, 889))

        XCTAssertFalse(game.state.frameOver, "level scores give the re-spotted Black, not a result")
        XCTAssertTrue(game.state.respottedBlack)
        XCTAssertEqual(game.state.scores, [40, 40])
        XCTAssertTrue(game.state.ballsOnTable.contains(BallID.black), "the Black is back on the table")
        XCTAssertEqual(game.state.ballPositions[BallID.black], Table.blackSpot, "and on its spot")
        XCTAssertFalse(game.state.ballsOnTable.contains(BallID.cue), "the cue ball is in hand")
        XCTAssertTrue(game.state.cueBallInHand)
        XCTAssertEqual(game.state.pending, .placeCueBallInD)
        XCTAssertEqual(game.state.currentPlayer, 1, "the draw decides who plays from in-hand")
        XCTAssertEqual(game.state.ballOn, .colourOfSequence(.black))
    }

    /// The next pot ends the frame, level or not (Rule 4(b)(iv)).
    func testAPotAfterTheBlackIsRespottedEndsTheFrame() {
        let game = respottedBlackPosition()
        var report = StrokeReport()
        report.firstContacts = [BallID.black]
        report.potted = [BallID.black]
        _ = game.applyStroke(report, cueBallPosition: Vec2(1200, 889))

        XCTAssertTrue(game.state.frameOver)
        XCTAssertEqual(game.state.winner, 0)
        XCTAssertEqual(game.state.scores, [47, 40])
    }

    /// And so does a foul: the re-spot is offered once, not over and over.
    func testAFoulAfterTheBlackIsRespottedEndsTheFrame() {
        let game = respottedBlackPosition()
        var report = StrokeReport()
        report.cueBallPotted = true               // in off the Black: a seven point foul
        _ = game.applyStroke(report, cueBallPosition: Vec2(1200, 889))

        XCTAssertTrue(game.state.frameOver)
        XCTAssertEqual(game.state.winner, 1, "the penalty decides it")
        XCTAssertEqual(game.state.scores, [40, 47])
    }

    /// A foul with the Black as the only object ball ends the frame too (Rule 4(a)) — and when the
    /// penalty leaves the scores level, that gives the re-spotted Black (Rule 4(b)).
    func testAFoulWithTheBlackLeftEndsTheFrameUnlessItLevelsTheScores() {
        let decided = newGame(reds: 0)
        decided.withState { state in
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.black)
            state.ballsOnTable = [BallID.cue, BallID.black]
            state.scores = [40, 33]              // seven ahead, so a seven point foul levels it
        }
        var level = StrokeReport()
        level.cueBallPotted = true
        _ = decided.applyStroke(level, cueBallPosition: Vec2(1200, 889))
        XCTAssertFalse(decided.state.frameOver)
        XCTAssertTrue(decided.state.respottedBlack)
        XCTAssertEqual(decided.state.scores, [40, 40])

        let lost = newGame(reds: 0)
        lost.withState { state in
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.black)
            state.ballsOnTable = [BallID.cue, BallID.black]
            state.scores = [48, 33]              // fifteen ahead: a foul cannot level it
        }
        var foul = StrokeReport()
        foul.cueBallPotted = true
        _ = lost.applyStroke(foul, cueBallPosition: Vec2(1200, 889))
        XCTAssertTrue(lost.state.frameOver, "a foul with only the Black left ends the frame")
        XCTAssertEqual(lost.state.winner, 0, "the striker is still ahead")
        XCTAssertEqual(lost.state.scores, [48, 40])
    }

    // MARK: Conceding and stalemate (Section 4 Rule 2, Rule 17)

    func testConcedingEndsTheFrame() {
        let game = newGame()
        game.withState { $0.scores = [10, 40] }
        game.concede(player: 0)
        XCTAssertTrue(game.state.frameOver)
        XCTAssertEqual(game.state.winner, 1)
    }

    func testReRackNullifiesScoresAndResetsBalls() {
        let game = newGame()
        game.withState { $0.scores = [30, 12] }
        game.reRack()
        XCTAssertEqual(game.state.scores, [0, 0])
        XCTAssertEqual(game.state.redsRemaining, 15)
        XCTAssertEqual(game.state.ballPositions[BallID.black], Table.blackSpot)
    }

    func testRemainingPointsCountsRedsPlusColours() {
        let game = newGame()
        // 15 Reds each worth 1 plus a Black (8 per Red in the usual calculation) plus 27 for colours.
        XCTAssertEqual(game.remainingPoints(), 15 * 8 + 27)
    }
}

private extension SnookerGame {
    /// Convenience for tests that need a colour nominated without a preceding Red.
    func nominateColourIfPossible() {
        withState { $0.ballOn = .anyColour }
        nominateColour(.black)
    }
}
