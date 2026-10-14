import XCTest
@testable import SnookerCore

final class PhysicsTests: XCTestCase {

    private func world(cue: Vec2, objectBalls: [(Int, Vec2)] = []) -> PhysicsWorld {
        var balls = [Ball(id: BallID.cue, color: .white, position: cue)]
        for (id, position) in objectBalls {
            balls.append(Ball(id: id, color: BallID.colour(of: id) ?? .red, position: position))
        }
        return PhysicsWorld(balls: balls)
    }

    private func run(_ world: PhysicsWorld, seconds: Double, step: Double = 1.0 / 240.0) {
        var t = 0.0
        while t < seconds {
            world.step(dt: step)
            t += step
        }
    }

    /// Rolls the cue ball until it comes to rest and returns how far it travelled along the cloth.
    /// The distance along the cloth, not the straight-line displacement: a ball that rattles off the
    /// cushions ends up near where it started however far it has run.
    private func pathUntilRest(_ world: PhysicsWorld, seconds: Double = 40) -> Double {
        var path = 0.0, t = 0.0
        var previous = world.balls[0].position
        while t < seconds, world.balls[0].velocity.length > 0 {
            world.step(dt: 1.0 / 240.0)
            t += 1.0 / 240.0
            let position = world.balls[0].position
            path += position.distance(to: previous)
            previous = position
        }
        return path
    }

    func testBallAtRestStaysAtRest() {
        let w = world(cue: Vec2(1000, 889))
        run(w, seconds: 2)
        XCTAssertEqual(w.balls[0].position, Vec2(1000, 889))
    }

    func testRollingBallComesToRestAndTravelsAPlausibleDistance() {
        // Straight up the table at 2000 mm/s: it reaches the far cushion, comes back most of the
        // way and dies. Much of the loss is the cushion: it grips the ball above its middle and
        // takes the run off it as it turns it round (see the cushion tests below), so the ball
        // comes away with less than the bounce alone would leave it, and the cloth carries the rest
        // off over the length of the return. The result is about a length and a half of cloth, not
        // five: five is what the rolling resistance alone would give on a table with no cushions.
        let w = world(cue: Vec2(200, 889))
        w.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 2000, side: 0, vertical: 0.4)
        let path = pathUntilRest(w)
        XCTAssertEqual(w.balls[0].velocity.length, 0, accuracy: 0.001, "ball must stop")
        XCTAssertGreaterThan(path, 1.2 * Table.length, "a firm shot should run up the table and back")
        XCTAssertLessThan(path, 2.5 * Table.length, "and should not rattle about for ever")
    }

    func testTheClothSlowsARollingBallAtTheCompetitionRate() {
        // Once a ball is rolling, the only thing slowing it is the cloth: it loses
        // rollingResistance * g of speed every second. On a 0.010 competition cloth that is
        // 0.098 m/s^2, so a ball rolling at 300 mm/s should still be rolling at about 100 mm/s
        // two seconds later. A club table, roughly twice that resistance, would have stopped it.
        let w = world(cue: Vec2(60, 889))
        w.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 300, side: 0, vertical: 0.4)
        let before = w.balls[0].velocity.length
        run(w, seconds: 2)
        let drop = before - w.balls[0].velocity.length
        let expected = 2 * PhysicsWorld.rollingResistance * PhysicsWorld.gravity
        XCTAssertEqual(drop, expected, accuracy: 10,
                       "a rolling ball should shed rollingResistance * g per second")
    }

    func testHeadOnCollisionTransfersMomentum() {
        let w = world(cue: Vec2(1000, 889), objectBalls: [(BallID.firstRed, Vec2(1500, 889))])
        w.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 1000, side: 0, vertical: 0.4)
        run(w, seconds: 0.6)
        let cue = w.balls[0], red = w.balls[1]
        XCTAssertGreaterThan(red.velocity.x, 450, "the object ball takes most of the speed")
        XCTAssertGreaterThan(red.velocity.x, cue.velocity.length * 1.8, "the object ball carries the momentum")
    }

    func testCloseStunStopsTheCueBallDead() {
        // With the balls close together the cue ball is still sliding at contact
        // (no time to pick up roll), so a centre-ball hit leaves it nearly dead.
        let w = world(cue: Vec2(1000, 889), objectBalls: [(BallID.firstRed, Vec2(1100, 889))])
        w.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 2000, side: 0, vertical: 0)
        run(w, seconds: 0.4)
        let cue = w.balls[0], red = w.balls[1]
        XCTAssertLessThan(cue.velocity.length, red.velocity.x * 0.35, "stun: the cue ball should barely follow")
    }

    func testBackSpinBringsTheCueBallBack() {
        let w = world(cue: Vec2(1000, 889), objectBalls: [(BallID.firstRed, Vec2(1300, 889))])
        w.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 1500, side: 0, vertical: -0.5)
        // Let the cue ball reach the red, then settle.
        run(w, seconds: 2.5)
        let cue = w.balls[0]
        XCTAssertLessThan(cue.position.x, 1300, "with draw the cue ball must come back behind the contact point")
    }

    func testTopSpinFollowsThrough() {
        let w = world(cue: Vec2(1000, 889), objectBalls: [(BallID.firstRed, Vec2(1300, 889))])
        w.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 1500, side: 0, vertical: 0.5)
        run(w, seconds: 1.5)
        let cue = w.balls[0]
        XCTAssertGreaterThan(cue.position.x, 1300 + Table.ballDiameter, "with follow the cue ball goes forward")
    }

    func testCushionAbsorbsSomeSpeedAndReversesDirection() {
        let w = world(cue: Vec2(500, 400))
        w.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(0, -1), power: 1500, side: 0, vertical: 0.4)
        run(w, seconds: 1.0)
        let cue = w.balls[0]
        XCTAssertGreaterThan(cue.position.y, 0)
        XCTAssertGreaterThan(cue.velocity.y, 0, "the ball must rebound off the cushion")
        XCTAssertTrue(w.events.contains { if case .cushion = $0 { return true } else { return false } })
    }

    func testBallIsCapturedByACornerPocket() {
        let w = world(cue: Vec2(400, 400))
        // Aim straight at the bottom-left corner pocket: the approach line must pass
        // between the two jaw tips, as it would on a real table.
        let direction = (PocketID.bottomLeft.position - Vec2(400, 400)).normalized
        w.applyCueStrike(cueBallID: BallID.cue, direction: direction, power: 1600, side: 0, vertical: 0.4)
        run(w, seconds: 4)
        XCTAssertFalse(w.balls[0].onTable, "the ball should drop in the corner pocket")
        XCTAssertEqual(w.balls[0].pottedInto, .bottomLeft)
    }

    func testBallRolledAtTheMiddleOfALongCushionIsNotPotted() {
        // Aim at the cushion well away from the middle pocket.
        let w = world(cue: Vec2(1784 + 250, 600))
        w.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(0, -1), power: 2500, side: 0, vertical: 0.4)
        run(w, seconds: 3)
        XCTAssertTrue(w.balls[0].onTable)
    }

    func testBallRolledIntoTheMiddlePocketIsPotted() {
        let w = world(cue: Vec2(PocketID.bottomMiddle.position.x, 600))
        w.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(0, -1), power: 2000, side: 0, vertical: 0.4)
        run(w, seconds: 3)
        XCTAssertFalse(w.balls[0].onTable)
        XCTAssertEqual(w.balls[0].pottedInto, .bottomMiddle)
    }

    /// A ball hugging a cushion into a corner pocket drops: the corner's mouth is across the corner
    /// at 45°, so the ball's centre passes over it on the way down the cushion. Its nose is at the
    /// jaw tip, so the ball brushes past the rounded jaw; a jaw centred on its own tip would instead
    /// bulge a radius into the playing area and shear the ball off across the table.
    func testABallHuggingACushionDropsIntoTheCornerPocket() {
        let w = world(cue: Vec2(900, Table.ballRadius))
        w.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(-1, 0), power: 1600, side: 0, vertical: 0.4)
        run(w, seconds: 8)
        XCTAssertFalse(w.balls[0].onTable, "the ball hugging the cushion must drop in the corner")
        XCTAssertEqual(w.balls[0].pottedInto, .bottomLeft)
    }

    /// A ball hugging a cushion runs *past* a middle pocket rather than dropping, the way it does on
    /// a real table: the mouth is on the line of the cushion, so the slate is still under the ball
    /// as it crosses it. The ball's centre has to be played over the mouth — into the pocket — for
    /// it to fall.
    func testABallHuggingACushionRunsPastTheMiddlePocket() {
        let w = world(cue: Vec2(PocketID.bottomMiddle.position.x - 500, Table.ballRadius))
        w.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 1600, side: 0, vertical: 0.4)
        var t = 0.0
        while t < 8, w.balls[0].onTable, w.balls[0].position.x < PocketID.bottomMiddle.position.x + 150 {
            w.step(dt: 1.0 / 240.0)
            t += 1.0 / 240.0
        }
        XCTAssertTrue(w.balls[0].onTable, "it must not drop in the middle pocket")
        XCTAssertGreaterThan(w.balls[0].position.x, PocketID.bottomMiddle.position.x + 100,
                             "it must carry on past the mouth, not drop into it")
    }

    /// What a corner makes of a fan of shots played across its mouth.
    ///
    /// Thirteen shots from one place, at one pace, aimed at points spread across the bottom-left
    /// corner's mouth: some of the fan is played at the mouth and some of it at the **throat**, which
    /// is the surface a jaw's round runs out into. How many the corner takes is a property of this
    /// table and this pace rather than a measurement, so it is asserted. Nine of the thirteen are
    /// taken, and it is the **grab** of the facing that takes them — see `cushionHold` — rather than
    /// the restitution it gives back.
    func testACornerTakesMostOfAFanPlayedAcrossItsMouth() {
        let cut = PocketID.bottomLeft.cut
        var taken = 0
        for offset in stride(from: -30.0, through: 30.0, by: 5.0) {
            let from = Vec2(560, 560)
            let aim = cut.mouth + cut.axis.perpendicular * offset
            let shot = PhysicsWorld(balls: [Ball(id: BallID.cue, color: .white, position: from)])
            shot.applyCueStrike(cueBallID: BallID.cue, direction: (aim - from).normalized,
                                power: 1600, side: 0, vertical: 0.4)
            var clock = 0.0
            while clock < 8, shot.balls[0].onTable {
                shot.step(dt: 1.0 / 240.0)
                clock += 1.0 / 240.0
            }
            if !shot.balls[0].onTable { taken += 1 }
        }
        XCTAssertGreaterThanOrEqual(taken, 9, "a corner takes nine of the thirteen: \(taken)")
    }

    /// The bed holds a ball up **through a collision as well as between them**. An impulse with a
    /// downward part — from a line of centres that is not level, as here, or from friction on a ball
    /// carrying follow or draw — cannot drive a ball on the cloth into it: the bed answers that part
    /// with a normal impulse of its own, and the cloth's friction comes with that answer.
    func testTheBedHoldsABallUpThroughACollision() {
        // One ball a centimetre above the bed, closing on one resting on it: the line of centres is
        // tilted, so the impulse on the lower ball has a downward part.
        let world = PhysicsWorld(balls: [
            Ball(id: BallID.cue, color: .white, position: Vec2(980, Table.centreY),
                 velocity: Vec2(1500, 0), height: Table.ballRadius + 10),
            Ball(id: BallID.firstRed, color: .red, position: Vec2(1050, Table.centreY)),
        ])
        var met = false
        for _ in 0..<40 where !met {
            world.clearEvents()
            world.step(dt: 1.0 / 240.0)
            met = world.events.contains { if case .ballBall = $0 { return true }; return false }
        }
        XCTAssertTrue(met, "the two really met")
        let resting = world.balls[1]
        XCTAssertGreaterThanOrEqual(resting.height, Table.ballRadius - 1e-9,
                                    "the ball on the bed is not driven into it")
        // And what the bed gave back is exactly what the collision took: the ball is left sitting on
        // the cloth, not bouncing off it. A ball the bed answered *and* bounced would leave this at
        // some tens of millimetres a second — which is what the bed's own restitution would do to a
        // ball arriving at it, and not what it owes a ball a collision pressed into it.
        XCTAssertEqual(resting.verticalVelocity, 0, accuracy: 1,
                       "the downward part of the impulse is cancelled and not given back")
    }

    /// A collision is answered at the place the two balls touched, so what comes of a cut does not
    /// depend on how far the balls travelled in a step — which is the same thing as saying it does not
    /// depend on how hard the shot was played. The same shot stepped coarsely and finely has to send the
    /// object ball away at the same speed and on the same line.
    ///
    /// It did not: an overlap found at the end of a step was answered where the balls had got to, so the
    /// line of centres was no longer the line they met on and the ball went off wider, the faster the
    /// shot — a degree or two at a firm pace, which is exactly the sort of thing a cut is felt in.
    func testACutComesOutTheSameHoweverFinelyTheStepIsTaken() {
        let cut = 30.0 * .pi / 180
        func objectBall(stepped step: Double) -> Vec2 {
            let offset = Table.ballDiameter * sin(cut)
            let world = PhysicsWorld(balls: [
                Ball(id: BallID.cue, color: .white, position: Vec2(1500, Table.centreY + offset),
                     velocity: Vec2(3000, 0)),
                Ball(id: BallID.firstRed, color: .red, position: Vec2(1700, Table.centreY)),
            ])
            var clock = 0.0
            while clock < 1, world.balls[1].velocity.length < 1 {
                world.step(dt: step)
                clock += step
            }
            return world.balls[1].velocity
        }
        let coarse = objectBall(stepped: 1.0 / 240.0)
        let fine = objectBall(stepped: 1.0 / 2400.0)
        XCTAssertGreaterThan(coarse.length, 100, "the object ball is struck")
        XCTAssertEqual(coarse.length, fine.length, accuracy: 5,
                       "away at the same speed however the step was taken")
        XCTAssertLessThan((coarse.normalized - fine.normalized).length, 0.01,
                          "and along the same line")
    }

    /// And the facing that does it is the pocket's own surface and not the cushion's: it gives back
    /// less than the rubber does, and nearer the back of the pocket's deadness than the rubber's life.
    func testACornerThroatIsDeadRatherThanRubber() {
        let pocket = PhysicsWorld.pocketRestitution
        let cushion = PhysicsWorld.cushionRestitution
        let throat = PhysicsWorld.throatRestitution
        XCTAssertLessThan(throat, cushion, "the facing gives back less than the rubber does")
        XCTAssertLessThan(throat, (pocket + cushion) / 2,
                          "and it belongs to the pocket's own family of dead surfaces")
    }

    /// The jaws are the rounds the cushions are cut back with where they meet a pocket: a round of
    /// `Table.jawRadius` whose axis is perpendicular to the table, tangent to the cushion's face and
    /// to the pocket's throat. `Table3D` draws the same circles, so the shape on the table is the
    /// shape the ball is played on.
    func testTheJawsAreRoundsJoiningTheCushionsToThePockets() {
        let jaws = PhysicsWorld.jawCircles
        XCTAssertEqual(jaws.count, 12, "one at each end of the six cushion runs")
        XCTAssertEqual(Table.jawRadius, 50, accuracy: 0.001)
        XCTAssertTrue(jaws.allSatisfy { $0.radius == Table.jawRadius })

        for pocket in PocketID.allCases {
            let cut = pocket.cut
            let pair = [cut.jaws.0, cut.jaws.1]

            for jaw in pair {
                // The round stands a radius back from the cushion's face, so it is tangent to it.
                let alongTheFace = (jaw.tip - jaw.atTheFace).normalized
                let across = (jaw.centre - jaw.atTheFace).dot(alongTheFace.perpendicular)
                XCTAssertEqual(abs(across), Table.jawRadius, accuracy: 1e-9,
                               "\(pocket.rawValue): the round is tangent to the cushion's face")
                // And a radius from the throat it runs into.
                let alongTheThroat = (jaw.atTheThroat - jaw.tip).normalized
                let acrossThroat = (jaw.centre - jaw.atTheThroat).dot(alongTheThroat.perpendicular)
                XCTAssertEqual(abs(acrossThroat), Table.jawRadius, accuracy: 1e-9,
                               "\(pocket.rawValue): the round is tangent to the throat")
                XCTAssertGreaterThan(jaw.atTheFace.distance(to: jaw.tip), 0,
                                     "\(pocket.rawValue): the cushion's face stops where the round begins")
            }

            // The narrowest opening between a pocket's two jaws is the mouth the rules measure.
            XCTAssertEqual(pair[0].centre.distance(to: pair[1].centre) - 2 * Table.jawRadius,
                           pocket.mouth, accuracy: 0.001,
                           "\(pocket.rawValue): the two rounds leave the mouth between them")
        }
    }

    /// A ball rolled at a pocket is not taken off the table the moment its centre crosses the rim.
    /// The cloth carries it to the hole and lets go there, and gravity does the rest: the ball falls
    /// the depth of the pocket and comes to rest on the bottom of it. That fall is the difference
    /// between a ball dropping in and a ball blinking out.
    func testABallRolledIntoAPocketFallsInRatherThanVanishing() {
        let pocket = PocketID.bottomMiddle
        let w = world(cue: Vec2(pocket.position.x, 700))
        w.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(0, -1), power: 700, side: 0, vertical: 0.4)
        var clock = 0.0
        var seenOnTheWayDown = false
        var lowest = Table.ballRadius
        while clock < 6, w.balls[0].onTable {
            w.step(dt: 1.0 / 240.0)
            clock += 1.0 / 240.0
            let ball = w.balls[0]
            if ball.onTable, ball.height < Table.ballRadius - 1 { seenOnTheWayDown = true }
            lowest = min(lowest, ball.height)
        }
        let ball = w.balls[0]
        XCTAssertTrue(seenOnTheWayDown, "the ball must be seen on its way down, not taken off at the rim")
        XCTAssertFalse(ball.onTable, "the ball must drop in")
        XCTAssertEqual(ball.pottedInto, pocket)
        XCTAssertEqual(ball.height, Table.ballRadius - Table.pocketDepth, accuracy: 1e-9,
                       "it comes to rest on the floor of the pocket")
        XCTAssertEqual(lowest, ball.height, accuracy: 1e-9, "and never goes deeper than that")
    }

    /// A ball played hard into a pocket runs into the back of it on the way down. The back of a
    /// pocket is dead — it takes nearly all of a ball's speed — which is why a hard ball drops in
    /// rather than coming back out across the table. The well is a cylinder and the ball is a
    /// sphere, so its centre never gets within a ball of the wall, and never past the back.
    func testABallDrivenIntoTheBackOfAPocketIsStoppedByItAndStillDrops() {
        let pocket = PocketID.bottomMiddle
        let w = world(cue: Vec2(pocket.position.x, 700))
        w.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(0, -1), power: 2600, side: 0, vertical: 0.4)
        let room = pocket.cut.holeRadius - Table.ballRadius
        var clock = 0.0
        var speedIntoTheBack = 0.0
        var speedOutOfTheBack = 0.0
        var brokeOutOfTheWell = false
        for _ in 0..<2400 where w.balls[0].onTable {
            let before = w.balls[0]
            w.step(dt: 1.0 / 240.0)
            clock += 1.0 / 240.0
            let after = w.balls[0]
            if after.onTable, after.height <= 0 {
                let offset = after.position - pocket.cut.holeCentre
                if abs(offset.dot(pocket.cut.axis)) > room + 0.01
                    || abs(offset.dot(pocket.cut.axis.perpendicular)) > room + 0.01 {
                    brokeOutOfTheWell = true
                }
            }
            let into = before.velocity.dot(pocket.cut.axis), out = after.velocity.dot(pocket.cut.axis)
            if after.onTable, out < into - 100 {
                speedIntoTheBack = into
                speedOutOfTheBack = out
            }
        }
        let ball = w.balls[0]
        XCTAssertFalse(brokeOutOfTheWell, "the ball must be held inside the pocket all the way down")
        XCTAssertGreaterThan(speedIntoTheBack, 2000, "it should reach the back of the pocket still moving")
        XCTAssertLessThan(abs(speedOutOfTheBack), speedIntoTheBack * 0.5,
                          "and the back of a pocket must take nearly all of that away")
        XCTAssertFalse(ball.onTable, "a ball stopped by the back of the pocket still drops")
        XCTAssertEqual(ball.pottedInto, pocket)
        XCTAssertEqual(ball.height, Table.ballRadius - Table.pocketDepth, accuracy: 1e-9)
        // And the wood it ran into is reported, with the speed it went in at: the back of a pocket is
        // wood, and the game hears it as wood.
        let intoTheWood = w.events.compactMap { event -> Double? in
            if case .pocketWood(_, let speed) = event { return speed }
            return nil
        }.max()
        XCTAssertNotNil(intoTheWood, "the back of the pocket is reported")
        XCTAssertGreaterThan(intoTheWood ?? 0, 1000, "and at the speed the ball went into it")
    }

    /// The throat behind a jaw is a **live surface**, and a ball that rattles in a corner is answered
    /// by it: the shot below is one of the fan across the corner's mouth, aimed wide enough that what
    /// it meets is the facing rather than the hole. What shape it is answered by — the cushion's own
    /// section, leaning at 65° to the cloth, rather than a wall standing square to it — is not
    /// something a ball's path alone can be asked about: it is that `bounceOffThroat` and `bounceOffFace`
    /// are one piece of code, and this is here so that it stays reachable.
    func testACornerThroatAnswersAsACushionFaceDoes() {
        let cut = PocketID.bottomLeft.cut
        let from = Vec2(560, 560)
        let aim = cut.mouth + cut.axis.perpendicular * 25
        let world = PhysicsWorld(balls: [Ball(id: BallID.cue, color: .white, position: from)])
        world.applyCueStrike(cueBallID: BallID.cue, direction: (aim - from).normalized,
                             power: 1600, side: 0, vertical: 0.4)

        var answeredAt: [Double] = []
        var clock = 0.0
        while clock < 8, world.balls[0].onTable {
            world.clearEvents()
            world.step(dt: 1.0 / 240.0)
            clock += 1.0 / 240.0
            for event in world.events {
                if case .throat(_, let speed) = event { answeredAt.append(speed) }
            }
        }
        XCTAssertFalse(answeredAt.isEmpty, "the shot meets the facing, and the contact is reported")
        XCTAssertGreaterThan(answeredAt.max() ?? 0, 100, "at a pace worth answering")
    }

    /// The cloth is not a floor a ball sticks to. A ball dropped onto it lands, comes back up, and
    /// settles, each bounce lower than the last.
    func testABallDroppedOntoTheClothBouncesOnItAndSettles() {
        let w = PhysicsWorld(balls: [Ball(id: BallID.cue, color: .white, position: Vec2(1200, 889), height: 400)])
        var clock = 0.0
        var bounces = 0
        var highestAfterABounce = Table.ballRadius
        while clock < 4, !w.allAtRest {
            w.step(dt: 1.0 / 240.0)
            clock += 1.0 / 240.0
            let ball = w.balls[0]
            if ball.verticalVelocity > 0 {
                bounces += 1
                highestAfterABounce = max(highestAfterABounce, ball.height)
            }
        }
        XCTAssertGreaterThan(bounces, 0, "it must come back off the cloth")
        XCTAssertGreaterThan(highestAfterABounce, Table.ballRadius + 50, "and come back up a good way")
        XCTAssertLessThan(highestAfterABounce, 400, "but not as high as it was dropped from")
        XCTAssertEqual(w.balls[0].height, Table.ballRadius, accuracy: 1e-9, "then settle on the cloth")
        XCTAssertEqual(w.balls[0].verticalVelocity, 0, accuracy: 1e-9)
        XCTAssertTrue(w.allAtRest)
        // And each bounce on the cloth is a contact the view can hear, at the speed it came down at.
        let ontoTheCloth = w.events.compactMap { event -> Double? in
            if case .bed(_, let speed) = event { return speed }
            return nil
        }
        XCTAssertFalse(ontoTheCloth.isEmpty, "coming down on the cloth of the bed is reported")
        XCTAssertGreaterThan(ontoTheCloth.first ?? 0, PhysicsWorld.bounceRest,
                             "at a speed worth coming back off the cloth for")
    }

    /// A ball a collision has squeezed into the cloth comes back onto it: only a hole in the bed
    /// lets a ball fall. The middle of the table is nowhere near one.
    func testABallPressedIntoTheClothComesBackOntoIt() {
        let w = PhysicsWorld(balls: [Ball(id: BallID.cue, color: .white, position: Vec2(1200, 889), height: 5)])
        run(w, seconds: 0.5)
        XCTAssertTrue(w.balls[0].onTable, "the middle of the table is not a pocket")
        XCTAssertEqual(w.balls[0].height, Table.ballRadius, accuracy: 1e-9)
    }

    /// Aimed at a cushion, the shot reaches the cushion where the ball would come to rest against
    /// it — the ball meets the nose above its own equator, so its centre stands `cushionRestReach`
    /// off the face, a couple of millimetres inside a radius. That point is the ghost ball the table
    /// draws when a player aims at a cushion rather than at a ball.
    func testABallSentAtACushionReachesItWithItsCentreUnderTheNose() {
        let w = world(cue: Vec2(1000, Table.centreY))
        for (degrees, side, expected) in [(90.0, CushionSide.top, Vec2(1000, Table.width - Table.cushionRestReach)),
                                          (270.0, CushionSide.bottom, Vec2(1000, Table.cushionRestReach))] {
            let direction = Vec2(cos(degrees * .pi / 180), sin(degrees * .pi / 180))
            guard let contact = w.firstCushionContact(from: Vec2(1000, Table.centreY), direction: direction) else {
                return XCTFail("a ball sent at a cushion must reach it")
            }
            XCTAssertEqual(contact.side, side)
            XCTAssertEqual(contact.point.distance(to: expected), 0, accuracy: 1e-9,
                           "the centre arrives under the nose, at the reach the face allows it")
        }
    }

    /// The shape of a pocket is what takes a ball in. A ball rolled along a cushion into a corner
    /// pocket is carried across the throat by the jaw's round and drops — the well below the hole
    /// has next to nothing to do, and in particular it is not snapping the ball onto the middle of
    /// the hole.
    func testABallIsGuidedIntoAPocketByItsShapeRatherThanSnappedIntoIt() {
        let w = PhysicsWorld(balls: [Ball(id: BallID.cue, color: .white,
                                          position: Vec2(900, Table.ballRadius))])
        w.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(-1, 0), power: 1600, side: 0, vertical: 0.4)
        run(w, seconds: 8)
        XCTAssertFalse(w.balls[0].onTable, "the ball must drop in the corner pocket")
        XCTAssertEqual(w.balls[0].pottedInto, .bottomLeft)
        XCTAssertLessThan(w.largestPocketCorrection, 4,
                          "the pocket guides the ball in; it must not push it onto its line")
        XCTAssertGreaterThan(w.largestPocketCorrection, 0,
                             "though the well does keep it inside, which is what the figure measures")
    }

    /// Two balls meet as spheres, not as discs: one flying over another passes over it.
    func testABallInTheAirPassesOverOneUnderIt() {
        let w = PhysicsWorld(balls: [
            Ball(id: BallID.cue, color: .white, position: Vec2(1000, 889), velocity: Vec2(3000, 0),
                 height: Table.ballRadius + 400),
            Ball(id: BallID.firstRed, color: .red, position: Vec2(1400, 889)),
        ])
        run(w, seconds: 0.25)
        XCTAssertEqual(w.balls[1].velocity.length, 0, accuracy: 1e-9,
                       "a ball in the air must clear one under it")
        XCTAssertEqual(w.balls[1].position.distance(to: Vec2(1400, 889)), 0, accuracy: 1e-9,
                       "and leave it exactly where it was")
    }

    /// A hard tip below the centre pinches the cue ball against the cloth and the cloth pushes back,
    /// so the ball comes off the bed a little — the hop a hard screw shot is played with. A level tip
    /// leaves the ball on the cloth.
    func testAHardTipBelowTheCentreLiftsTheCueBallOffTheCloth() {
        let low = world(cue: Vec2(1000, 889))
        low.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 4000, side: 0, vertical: -0.5)
        let level = world(cue: Vec2(1000, 889))
        level.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 4000, side: 0, vertical: 0)

        XCTAssertGreaterThan(low.balls[0].verticalVelocity, 0, "a hard low tip should lift the ball")
        XCTAssertEqual(level.balls[0].verticalVelocity, 0, "a level tip should not")

        var clock = 0.0
        var highest = Table.ballRadius
        while clock < 0.5 {
            low.step(dt: 1.0 / 240.0)
            clock += 1.0 / 240.0
            highest = max(highest, low.balls[0].height)
        }
        XCTAssertGreaterThan(highest, Table.ballRadius + 1, "the ball must actually leave the cloth")
        XCTAssertEqual(low.balls[0].height, Table.ballRadius, accuracy: 1e-9, "and come back down to it")
    }

    func testFastBallDoesNotTunnelThroughAnotherBall() {
        let w = world(cue: Vec2(1000, 889), objectBalls: [(BallID.firstRed, Vec2(2000, 889))])
        w.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 6000, side: 0, vertical: 0.4)
        run(w, seconds: 0.5)
        XCTAssertTrue(w.events.contains { if case .ballBall = $0 { return true } else { return false } },
                      "a fast ball must still collide with the ball in its path")
    }

    // MARK: - What the balls do when they collide

    /// Runs two balls together and reports the velocities either side of the collision itself.
    private func collision(cue: Vec2, object: Vec2, power: Double, vertical: Double)
        -> (before: Vec2, after: (cue: Vec2, object: Vec2), lineOfCentres: Vec2) {
        let world = self.world(cue: cue, objectBalls: [(BallID.firstRed, object)])
        world.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: power, side: 0, vertical: vertical)
        var lineOfCentres = Vec2(1, 0)
        var before = world.balls[0].velocity
        var t = 0.0
        while t < 1, world.balls[1].velocity.length < 1 {
            lineOfCentres = (world.balls[1].position - world.balls[0].position).normalized
            before = world.balls[0].velocity
            world.step(dt: 1.0 / 240.0)
            t += 1.0 / 240.0
        }
        return (before, (world.balls[0].velocity, world.balls[1].velocity), lineOfCentres)
    }

    func testACollisionConservesMomentum() {
        // Friction with the cloth slows the balls, but the collision itself is two equal masses
        // pushing on each other: it must not create or destroy momentum.
        let hit = collision(cue: Vec2(900, 889), object: Vec2(1400, 889), power: 1200, vertical: 0.4)
        XCTAssertEqual(hit.after.cue.x + hit.after.object.x, hit.before.x, accuracy: hit.before.x * 0.01,
                       "the collision must not gain or lose momentum")
    }

    /// Total angular momentum per unit mass about the table's origin, in mm²/s.
    private func angularMomentum(_ world: PhysicsWorld) -> Double {
        let inertia = 2.0 / 5.0 * Table.ballRadius * Table.ballRadius
        return world.balls.reduce(0) { total, ball in
            total
                + ball.position.x * ball.velocity.y - ball.position.y * ball.velocity.x
                + inertia * ball.spin.z
        }
    }

    func testACollisionKeepsAngularMomentum() {
        // The collision is an impulse along the line of centres plus friction at the contact point.
        // Neither may create or destroy angular momentum — friction converts spin into motion and
        // back, but it does not invent it.
        let world = self.world(cue: Vec2(900, 889), objectBalls: [(BallID.firstRed, Vec2(1400, 889 + 26))])
        world.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 1500, side: 0, vertical: 0.4)
        var before = angularMomentum(world)
        var t = 0.0
        while t < 1, world.balls[1].velocity.length < 1 {
            before = angularMomentum(world)
            world.step(dt: 1.0 / 240.0)
            t += 1.0 / 240.0
        }
        let after = angularMomentum(world)
        XCTAssertEqual(after, before, accuracy: abs(before) * 0.01,
                       "the collision must not create or destroy angular momentum")
    }

    // MARK: - Side spin

    /// Ahead is +x, so the striker's right is -y (the lower y, as `Table` describes the Yellow Spot)
    /// and their left is +y.
    func testRightHandSideSpinTurnsTheBallTheRightWay() {
        // The widget is the ball seen face on: dragging the dot to the right is the tip striking the
        // right of the ball. That turns it counter-clockwise from above — a positive turn about the
        // vertical — and squirt takes the ball away from the side struck, so it leaves to the left.
        let right = world(cue: Vec2(1000, 889))
        right.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 1000, side: 0.5, vertical: 0)
        XCTAssertGreaterThan(right.balls[0].spin.z, 0, "right side spin is a positive turn about the vertical")
        XCTAssertGreaterThan(right.balls[0].velocity.y, 0, "and the ball squirts away to the left")

        let left = world(cue: Vec2(1000, 889))
        left.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 1000, side: -0.5, vertical: 0)
        XCTAssertLessThan(left.balls[0].spin.z, 0, "left side spin is the other way about")
        XCTAssertLessThan(left.balls[0].velocity.y, 0, "and squirts away to the right")
    }

    func testTopSpinAndScrewBackAreTiltedAboutTheShotsOwnAxis() {
        // Follow is a tilt towards the direction of travel, screw back against it: about the axis to
        // the striker's left, whichever way they are aiming.
        for degrees in stride(from: 0.0, to: 360.0, by: 45.0) {
            let yaw = degrees * .pi / 180
            let forward = Vec2(cos(yaw), sin(yaw))
            let left = Vec2(-sin(yaw), cos(yaw))

            let follow = world(cue: Vec2(1000, 889))
            follow.applyCueStrike(cueBallID: BallID.cue, direction: forward, power: 1000, side: 0, vertical: 0.5)
            let tilt = Vec3(follow.balls[0].spin.x, follow.balls[0].spin.y, 0)
            XCTAssertGreaterThan(tilt.x * left.x + tilt.y * left.y, 0,
                                 "top spin should tilt about the striker's left at \(degrees) degrees")

            let screw = world(cue: Vec2(1000, 889))
            screw.applyCueStrike(cueBallID: BallID.cue, direction: forward, power: 1000, side: 0, vertical: -0.5)
            let back = Vec3(screw.balls[0].spin.x, screw.balls[0].spin.y, 0)
            XCTAssertLessThan(back.x * left.x + back.y * left.y, 0,
                              "screw back should tilt the other way at \(degrees) degrees")
        }
    }

    func testSideSpinComesOffACushionOnItsOwnSide() {
        // Right side spin grips the cushion and throws the ball that way as it comes back.
        let right = world(cue: Vec2(3000, 889))
        right.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 1200, side: 0.5, vertical: 0)
        runUntilOffTheCushion(right)
        XCTAssertLessThan(right.balls[0].velocity.y, 0, "right side spin comes off towards the right")

        let left = world(cue: Vec2(3000, 889))
        left.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 1200, side: -0.5, vertical: 0)
        runUntilOffTheCushion(left)
        XCTAssertGreaterThan(left.balls[0].velocity.y, 0, "and left side spin towards the left")
    }

    private func runUntilOffTheCushion(_ world: PhysicsWorld) {
        var t = 0.0
        while t < 6, world.balls[0].velocity.x > 0 {
            world.step(dt: 1.0 / 240.0)
            t += 1.0 / 240.0
        }
    }

    // MARK: - The cushion in three dimensions

    /// Rolls the cue ball square into the bottom cushion and reports the state either side of the
    /// contact, how high the ball then went, and whether it came back to the bed and stopped.
    private func squareIntoTheCushion(spin: Vec3, speed: Double = 1200, from startY: Double = 500)
        -> (before: Ball, after: Ball, peak: Double, settled: Bool)? {
        var ball = Ball(id: BallID.cue, color: .white, position: Vec2(1000, startY))
        ball.velocity = Vec2(0, -speed)
        ball.spin = spin
        let w = PhysicsWorld(balls: [ball])
        var before: Ball?
        var after: Ball?
        var t = 0.0
        while t < 2, after == nil {
            before = w.balls[0]
            w.step(dt: 1.0 / 240.0)
            t += 1.0 / 240.0
            if w.events.contains(where: { if case .cushion = $0 { return true }; return false }) {
                after = w.balls[0]
            }
            w.clearEvents()
        }
        guard let before, let after else { return nil }
        var peak = after.height
        var u = 0.0
        while u < 8 {
            peak = max(peak, w.balls[0].height)
            w.step(dt: 1.0 / 240.0)
            u += 1.0 / 240.0
            if w.allAtRest { break }
        }
        return (before, after, peak, w.allAtRest)
    }

    /// A ball rolled square into a cushion comes away with the run taken off it. The cushion meets
    /// the ball above its middle, its surface slips down the face, and the friction that stops that
    /// slip turns the ball about the horizontal axis: most of the roll is gone, and what is left is
    /// backspin against the way the ball is now going. A cushion that simply reversed the ball would
    /// carry the roll straight through, which is what the old flat-wall model did.
    func testAPerpendicularCushionTakesTheRunOffARollingBall() {
        guard let shot = squareIntoTheCushion(spin: Vec3(1200 / Table.ballRadius, 0, 0)) else {
            return XCTFail("the ball must reach the cushion")
        }
        XCTAssertGreaterThan(shot.before.spin.x, 5, "the ball should reach the cushion rolling")
        XCTAssertGreaterThan(shot.after.velocity.y, 0, "and be turned round")
        XCTAssertGreaterThan(shot.after.spin.x, 0, "it comes away with backspin against the return")
        XCTAssertLessThan(shot.after.spin.x, shot.before.spin.x * 0.5,
                          "the cushion should take off far more than half the run")
    }

    /// The same grip works the other way: a ball screwing back into the cushion has its backspin
    /// taken off it too, rather than carried through. Sent from close in so the cloth has not
    /// already rolled the screw away before it arrives.
    func testTheCushionTakesBackspinOffTheBallAsWell() {
        guard let shot = squareIntoTheCushion(spin: Vec3(-1200 / Table.ballRadius, 0, 0), from: 80) else {
            return XCTFail("the ball must reach the cushion")
        }
        XCTAssertLessThan(shot.before.spin.x, -5, "the ball should arrive screwing back")
        XCTAssertGreaterThan(shot.after.spin.x, shot.before.spin.x,
                             "the cushion should take backspin off, not carry it through")
    }

    /// The contact above the middle can throw the ball up off the cloth: the friction that stops its
    /// surface running down the face points up the face. The ball is then the simulation's to bring
    /// back — gravity takes it down and the bed bounces it — so it leaves the cloth, lands, bounces
    /// and settles.
    func testACushionCanThrowABallUpOffTheCloth() {
        guard let shot = squareIntoTheCushion(spin: Vec3(3000 / Table.ballRadius, 0, 0), speed: 3000) else {
            return XCTFail("the ball must reach the cushion")
        }
        XCTAssertGreaterThan(shot.after.verticalVelocity, 0, "the cushion should throw the ball upwards")
        XCTAssertGreaterThan(shot.peak, Table.ballRadius + 0.5, "so it should leave the cloth")
        XCTAssertTrue(shot.settled, "and it must come back down and stop on the cloth")
    }

    /// The cushion only answers a ball that is running at it. A ball rolling along the cushion,
    /// touching it and going nowhere near it across, must pass undisturbed: no sideways push, no
    /// spin, no lift.
    func testABallRollingAlongACushionIsNotDisturbed() {
        var ball = Ball(id: BallID.cue, color: .white, position: Vec2(400, Table.cushionRestReach))
        ball.velocity = Vec2(600, 0)
        ball.spin = Vec3(0, 600 / Table.ballRadius, 0)
        let w = PhysicsWorld(balls: [ball])
        run(w, seconds: 1)
        XCTAssertEqual(w.balls[0].velocity.y, 0, accuracy: 0.01, "no push across the cushion")
        XCTAssertEqual(w.balls[0].position.y, Table.cushionRestReach, accuracy: 0.01, "it stays on its line")
        XCTAssertEqual(w.balls[0].height, Table.ballRadius, accuracy: 1e-9, "and on the cloth")
        XCTAssertEqual(w.balls[0].spin.x, 0, accuracy: 0.01, "with no spin put on it")
    }

    /// Fires the cue ball rolling at the bottom cushion at `incident` degrees off the normal, at
    /// `speed`, and returns it just before and just after the contact.
    private func cushionBounce(incident: Double, speed: Double) -> (before: Ball, after: Ball)? {
        let a = incident * .pi / 180
        var ball = Ball(id: BallID.cue, color: .white, position: Vec2(1000, 700))
        ball.velocity = Vec2(sin(a) * speed, -cos(a) * speed)
        ball.spin = Vec3(-ball.velocity.y / Table.ballRadius, ball.velocity.x / Table.ballRadius, 0)
        let w = PhysicsWorld(balls: [ball])
        var before: Ball?
        var after: Ball?
        var t = 0.0
        while t < 1.5, after == nil {
            before = w.balls[0]
            w.step(dt: 1.0 / 480.0)
            t += 1.0 / 480.0
            if w.events.contains(where: { if case .cushion = $0 { return true }; return false }) { after = w.balls[0] }
            w.clearEvents()
        }
        guard let before, let after else { return nil }
        return (before, after)
    }

    /// The angle off the normal a ball fired at the cushion at `incident` degrees comes away at.
    private func cushionReboundAngle(incident: Double, speed: Double) -> Double? {
        guard let (_, after) = cushionBounce(incident: incident, speed: speed) else { return nil }
        return atan2(abs(after.velocity.x), after.velocity.y) * 180 / .pi
    }

    /// Fires the ball at a jaw — the round at the end of the bottom middle pocket's left cushion —
    /// straight down the table at `incident` degrees to the jaw's own radial normal, and returns the
    /// angle it comes away at and the side spin it leaves with.
    private func jawBounce(incident: Double, speed: Double) -> (angle: Double, spin: Double)? {
        let jaw = PocketID.bottomMiddle.cut.jaws.0
        let contactRadius = jaw.radius + Table.cushionRestReach
        let offset = contactRadius * sin(incident * .pi / 180)
        var ball = Ball(id: BallID.cue, color: .white,
                        position: Vec2(jaw.centre.x + offset, jaw.centre.y + contactRadius * 2 + 150))
        ball.velocity = Vec2(0, -speed)
        ball.spin = Vec3(speed / Table.ballRadius, 0, 0)     // natural roll, no side spin
        let w = PhysicsWorld(balls: [ball])
        var after: Ball?
        var t = 0.0
        while t < 1, after == nil {
            w.step(dt: 1.0 / 480.0)
            t += 1.0 / 480.0
            if w.events.contains(where: { if case .cushion = $0 { return true }; return false }) { after = w.balls[0] }
            w.clearEvents()
        }
        guard let after else { return nil }
        // Where the ball's centre was when it touched: the radial normal there is the contact normal.
        let contact = Vec2(jaw.centre.x + offset,
                           jaw.centre.y + (contactRadius * contactRadius - offset * offset).squareRoot())
        let n = (contact - jaw.centre).normalized
        return (atan2(abs(after.velocity.dot(n.perpendicular)), after.velocity.dot(n)) * 180 / .pi, after.spin.z)
    }

    /// A jaw is not a different thing from a cushion: it is the same rubber, cut off where the pocket
    /// begins, and the section swept along a run is swept round the jaw's own round. So the same shot
    /// on a jaw and on a straight cushion has to come off the same way — the same angle, taken off by
    /// the same grip — and a ball with no side spin has to be turned and thrown exactly as a cushion
    /// turns it. The old jaw was a plain circular bounce: it reflected the ball and never touched its
    /// spin at all.
    func testAJawAnswersExactlyAsTheCushionItWasCutFrom() {
        for speed in [1000.0, 3000.0] {
            guard let jaw = jawBounce(incident: 30, speed: speed),
                  let cushionAngle = cushionReboundAngle(incident: 30, speed: speed) else {
                return XCTFail("both the jaw and the cushion must be reached")
            }
            XCTAssertEqual(jaw.angle, cushionAngle, accuracy: 2,
                           "a jaw should give the angle a cushion gives, at \(speed) mm/s")
            XCTAssertLessThan(jaw.spin, -10, "and should turn the ball over, not just reflect it")
        }
    }

    /// A ball played at an angle into a cushion comes off at a *smaller* angle than it went in: the
    /// rubber grips the ball, and the grip holds more of it the harder it is hit. It is a few degrees,
    /// though — a snooker cushion takes some of the angle off a hard ball, it does not straighten it
    /// out — and a slow ball that barely dents the cushion keeps nearly all of its angle.
    func testACushionPullsAHardBallsAngleTowardsTheNormal() {
        guard let slow = cushionReboundAngle(incident: 30, speed: 700),
              let firm = cushionReboundAngle(incident: 30, speed: 2000),
              let hard = cushionReboundAngle(incident: 30, speed: 4000) else {
            return XCTFail("the ball must reach the cushion")
        }
        XCTAssertLessThan(slow, 30, "even a slow ball should lose a little angle")
        XCTAssertGreaterThan(slow, 20, "but a slow ball should keep most of it")
        XCTAssertLessThan(firm, slow, "a firmer ball should come off straighter")
        XCTAssertLessThan(hard, firm, "and a hard one straighter still")
        XCTAssertGreaterThan(hard, 12, "but only by a few degrees, not most of the angle")
    }

    /// The grip is a *held* contact, so it works on the ball's velocity and its spin together: the
    /// rubber carries the momentum the ball has across the face round the point it holds it by, and
    /// the ball comes away spinning about the vertical. A ball that arrived with none is given some,
    /// which is the test that the grip is not simply an edit to the velocity — the friction and the
    /// grip have to be solved together, or one undoes the other.
    func testACushionTurnsAHardBallItCatches() {
        guard let slow = cushionBounce(incident: 30, speed: 700),
              let fast = cushionBounce(incident: 30, speed: 3000) else {
            return XCTFail("the ball must reach the cushion")
        }
        XCTAssertEqual(slow.before.spin.z, 0, accuracy: 0.5, "the ball arrives with no side spin")
        XCTAssertGreaterThan(slow.after.spin.z, -20, "a slow ball's contact slides, and turns it barely")
        XCTAssertLessThan(fast.after.spin.z, -40,
                          "a hard ball is caught by the cushion and comes away turning")
    }

    // MARK: - Off the table

    /// A ball that has left the playing area and is not in a pocket is off the table (Section 2
    /// Rule 14). It is taken out of the simulation at once — it is not tracked on across the rail —
    /// and it no longer holds the stroke up: the stroke is over as soon as the balls still on the
    /// table have stopped.
    func testABallOffTheTableStopsBeingTrackedAndDoesNotHoldUpTheStroke() {
        var rolling = Ball(id: 1, color: .red, position: Vec2(1000, 400))
        rolling.velocity = Vec2(600, 0)
        let w = PhysicsWorld(balls: [
            Ball(id: 0, color: .white, position: Vec2(600, -200)),   // out beyond the rail
            rolling,
        ])
        w.step(dt: 1.0 / 240.0)
        XCTAssertFalse(w.balls[0].onTable, "the ball off the table is out of play at once")
        XCTAssertTrue(w.events.contains { if case .forcedOffTable(let id) = $0 { return id == 0 } else { return false } },
                      "and it is reported as forced off the table")
        XCTAssertTrue(w.balls[1].onTable, "while the ball still on the table plays on")

        run(w, seconds: 10)
        XCTAssertTrue(w.allAtRest, "the stroke is over once the balls on the table have stopped")
    }

    /// A ball at the jaws is in the pocket's keeping, not off the table; and a ball over the hole is
    /// potted, not forced off.
    func testABallAtTheJawsIsInThePocketNotOffTheTable() {
        let middle = PocketID.bottomMiddle.position
        let jaws = PhysicsWorld(balls: [Ball(id: 0, color: .white, position: Vec2(middle.x + 55, -12))])
        run(jaws, seconds: 3)
        XCTAssertTrue(jaws.balls[0].onTable, "a ball in the jaws is still on the table")

        let hole = PhysicsWorld(balls: [Ball(id: 0, color: .white, position: Vec2(middle.x, -40))])
        run(hole, seconds: 3)
        XCTAssertFalse(hole.balls[0].onTable)
        XCTAssertEqual(hole.balls[0].pottedInto, .bottomMiddle, "it is potted, not forced off")
    }

    // MARK: - The wooden rail

    // MARK: - The cue as a body

    /// The tip's leather has hold of the ball it has struck for a moment, and that whole moment is the
    /// stroke's **one** contact of the cue and the cue ball: a ball struck and held is not touched
    /// again, and only a ball that comes back to the stick after the tip has let go is a second contact.
    func testTheTipHoldsTheBallItHasStruckForOneContact() {
        let w = PhysicsWorld(balls: [Ball(id: 0, color: .white, position: Vec2(600, 889))])
        let atTheBall = Vec3(600 - Table.ballRadius, 889, Table.ballRadius)
        // The cue's own speed that sends the ball away at 2000: a centre hit gives the ball `1 + e`
        // times the cue's speed, and the contact the tip is held for is worked out from it.
        let cueSpeed = 2000 / (1 + PhysicsWorld.cueTipRestitution)
        let hold = PhysicsWorld.cueTipContactSeconds(forCueSpeed: cueSpeed)
        w.grabTheCueBall(0, with: Cue(tip: atTheBall, axis: Vec3(1, 0, 0), speed: cueSpeed))
        w.applyCueStrike(cueBallID: 0, direction: Vec2(1, 0), power: 2000, side: 0, vertical: 0)

        // Through the strike and its own contact: the tip is carried with the ball, and nothing is
        // reported — the stroke is one contact and not a touch followed by a foul.
        w.step(dt: hold / 8)             // a step of the stroke, well inside the contact
        guard let cue = w.cue else { return XCTFail("the cue is on the table") }
        let ball = w.balls[0]
        let reach = (cue.tip - Vec3(ball.position.x, ball.position.y, ball.height)).length
        XCTAssertEqual(reach, Table.ballRadius, accuracy: 0.5,
                       "the crown of the tip is still on the ball it is holding")
        XCTAssertTrue(w.events.isEmpty, "and the stroke's own contact is not reported")

        // The tip has let go. A ball that comes back to the stick now *is* a contact.
        w.clearEvents()
        w.step(dt: hold)                              // the tip lets go
        w.step(dt: 1.0 / 480.0)                       // and the ball runs off the tip
        w.place(ballID: 0, at: Vec2(cue.tip.x, cue.tip.y))
        w.step(dt: 1.0 / 480.0)
        XCTAssertTrue(w.events.contains { if case .cueTouched = $0 { return true }; return false },
                      "a ball back at the stick after the tip has let go is a contact")
        // And the contact is stamped with the time since the strike, so a second strike can be timed.
        let after = w.events.compactMap { event -> Double? in
            if case .cueTouched(_, let after, _) = event { return after }
            return nil
        }.first
        XCTAssertNotNil(after)
        XCTAssertGreaterThan(after ?? 0, hold, "past the tip's own contact with the ball")
    }

    /// The tip is **leather of a stated hardness**, and the whole of the contact it makes with the ball is
    /// worked out from that one figure: its modulus, the stiffness of the contact, how long it is on the
    /// ball, how far it presses into it, and what the ball comes away with.
    func testTheTipIsLeatherOfAStatedHardnessAndTheContactFollowsFromIt() {
        XCTAssertEqual(PhysicsWorld.cueTipShoreD, 70, "a firm playing tip, which is the one set")

        // Hardness and modulus are one chart apart, and the chart is the hardness-to-modulus one for
        // elastomers: a Shore D tip of each hardness sits where an elastomer of that hardness sits.
        for (shoreD, megapascals) in [(40.0, 8.0), (50.0, 20.0), (60.0, 50.0), (70.0, 126.0), (80.0, 316.0)] {
            XCTAssertEqual(PhysicsWorld.cueTipYoungsModulus(tipAt: shoreD) / 1e6, megapascals,
                           accuracy: megapascals * 0.03, "a Shore D \(shoreD) leather")
        }

        // The contact is a dome of 12 mm on a ball of 26.25: one radius, one modulus, and the ball's own
        // mass against a cue that does not budge for it.
        XCTAssertEqual(PhysicsWorld.cueTipContactRadius, 8.24, accuracy: 0.01,
                       "the radius the dome and the ball are worth together")
        XCTAssertEqual(PhysicsWorld.cueTipContactModulus / 1e6, 161.9, accuracy: 1,
                       "and the modulus of the contact: the leather's, for the most of it")

        // The time the tip is on the ball is the Hertz contact time, and it narrows as the shot gets
        // firmer — a fifth root of the speed, so eight times the shot is about two thirds of the time.
        let hard = PhysicsWorld.cueTipContactSeconds(forCueSpeed: FrameDriver.maxCueSpeed)
        let gentle = PhysicsWorld.cueTipContactSeconds(forCueSpeed: 200)
        XCTAssertEqual(hard * 1000, 1.40, accuracy: 0.02, "a full charge is on the ball for 1.4 ms")
        XCTAssertEqual(gentle * 1000, 2.47, accuracy: 0.03, "and the gentlest shot for about two and a half")
        XCTAssertGreaterThan(gentle, hard, "so a firmer shot is on the ball for less of it")
        XCTAssertEqual(gentle / hard, pow(FrameDriver.maxCueSpeed / 200, 0.2), accuracy: 0.03,
                       "and it is the speed's own fifth root that narrows it")

        XCTAssertEqual(PhysicsWorld.cueTipDeflection(forCueSpeed: FrameDriver.maxCueSpeed), 1.63,
                       accuracy: 0.05, "a full charge presses the leather about 1.6 mm into the ball")

        // What the ball comes away with is read off the same contact: the restitution the game is tuned
        // at, from the tip it is tuned with — so the power scale's top is the ball speed it always was.
        XCTAssertEqual(PhysicsWorld.cueTipRestitution, PhysicsWorld.cueTipTunedRestitution, accuracy: 1e-9,
                       "the tip the game was tuned on is the tip it is wearing")
        XCTAssertEqual(FrameDriver.maxCueSpeed * (1 + PhysicsWorld.cueTipRestitution), FrameDriver.maxPower,
                       accuracy: 0.5, "so a full charge is still the top of the power scale")

        // And the hardness carries both of them: a harder tip is a stiffer contact, on the ball for less
        // time and returning more of the speed; a softer one is the other way round.
        let hardnesses = [55.0, 60.0, 70.0, 80.0]
        let restitutions = hardnesses.map { PhysicsWorld.cueTipRestitution(tipAt: $0) }
        let times = hardnesses.map {
            PhysicsWorld.cueTipContactSeconds(forCueSpeed: FrameDriver.maxCueSpeed, tipAt: $0)
        }
        XCTAssertEqual(restitutions, restitutions.sorted(), "harder tips give more of the speed back")
        XCTAssertEqual(times, times.sorted(by: >), "and are on the ball for less time")
        XCTAssertEqual(restitutions.first ?? 0, 0.61, accuracy: 0.02, "a soft tip, Shore D 55")
        XCTAssertEqual(restitutions.last ?? 0, 0.82, accuracy: 0.02, "and a hard one, Shore D 80")
        XCTAssertEqual((times.first ?? 0) * 1000, 2.40, accuracy: 0.05, "2.4 ms on the ball at Shore D 55")
        XCTAssertEqual((times.last ?? 0) * 1000, 0.99, accuracy: 0.05, "and under a millisecond at 80")
    }

    /// The tip is a dome, and it is what puts a stop to a cue driven on into the table: the dome comes
    /// up against the cloth under it, or the wood of the cushion and the rail beside it.
    func testTheTipOfTheCueMeetsTheTable() {
        let w = world(cue: Vec2(1000, 889))
        let atBallHeight = Vec3(1000, 889, Table.ballRadius)
        let level = Vec3(1, 0, 0)
        // A level cue's lowest part is the rim of its dome, a tip's half-width below the stick.
        XCTAssertEqual(PhysicsWorld.theTipReachesDownTo(tip: atBallHeight, along: level),
                       Table.ballRadius - 4.9, accuracy: 0.001)
        XCTAssertTrue(w.theCueTipCanStand(at: atBallHeight, along: level))

        // Stood right up the dome points at the cloth and its crown is the lowest point of it.
        let straightDown = Vec3(0, 0, -1)
        XCTAssertEqual(PhysicsWorld.theTipReachesDownTo(tip: Vec3(1000, 889, 20), along: straightDown),
                       20, accuracy: 0.001)
        XCTAssertTrue(w.theCueTipCanStand(at: Vec3(1000, 889, 0), along: straightDown),
                      "a crown on the cloth is the stop itself")
        XCTAssertFalse(w.theCueTipCanStand(at: Vec3(1000, 889, -1), along: straightDown),
                       "and a crown through it is through it")

        // And driven at a cushion, the tip stops when it comes up against the face.
        XCTAssertTrue(w.theCueTipCanStand(at: Vec3(1000, 100, Table.ballRadius), along: level))
        XCTAssertFalse(w.theCueTipCanStand(at: Vec3(1000, 0, Table.ballRadius), along: level),
                       "the nose is in the way at the tip's own width")
    }

    /// The cue is a body on the table for the physics, not a line the game pretends is not there: a
    /// ball that runs into the side of the stick is pushed off it, and the contact is reported, which
    /// is what makes touching a ball with it a foul (Rule 11(b)(vi)).
    func testABallRunningIntoTheCueIsPushedOffIt() {
        let w = PhysicsWorld(balls: [Ball(id: 0, color: .white,
                                          position: Vec2(600, 889), velocity: Vec2(600, 0))])
        // The stick lying across the ball's path: the tip up the table, the shaft crossing y = 889.
        w.cue = Cue(tip: Vec3(1000, 889 + 200, Table.ballRadius), axis: Vec3(0, 1, 0), speed: 0)
        var clock = 0.0
        func touchedTheCue() -> Bool {
            w.events.contains { if case .cueTouched = $0 { return true }; return false }
        }
        while clock < 1, !touchedTheCue() {
            w.step(dt: 1.0 / 480.0)
            clock += 1.0 / 480.0
        }
        XCTAssertTrue(touchedTheCue(), "the ball ran into the cue")
        XCTAssertLessThan(w.balls[0].velocity.x, 0, "and was pushed back off the side of it")
        XCTAssertEqual(w.cue?.tip.y ?? 0, 1089, accuracy: 0.001,
                       "while the cue itself — infinitely heavy — is not moved by the ball at all")
    }

    /// And the tip of the stick is the other half of it: a ball that runs into the tip is answered
    /// along the cue's own axis, the way the strike is.
    func testABallRunningIntoTheTipIsPushedAlongTheCue() {
        let w = PhysicsWorld(balls: [Ball(id: 0, color: .white,
                                          position: Vec2(600, 889), velocity: Vec2(600, 0))])
        // Straight down the stick's own line: the tip facing the ball, the butt away behind it.
        w.cue = Cue(tip: Vec3(800, 889, Table.ballRadius), axis: Vec3(-1, 0, 0), speed: 0)
        var clock = 0.0
        while clock < 1, w.balls[0].velocity.x > 0 {
            w.step(dt: 1.0 / 480.0)
            clock += 1.0 / 480.0
        }
        XCTAssertTrue(w.events.contains { if case .cueTouched = $0 { return true }; return false },
                      "the ball ran into the tip of the cue")
        XCTAssertLessThan(w.balls[0].velocity.x, 0, "and came back off it, along its own axis")
        XCTAssertEqual(w.balls[0].velocity.y, 0, accuracy: 1, "with nothing sideways in it")
    }

    /// The wood of the rail is a surface like the bed: a ball can land on it, bounce, roll along it and
    /// come to rest there — and coming to rest on the wood is what makes it a ball off the table
    /// (Section 2 Rule 14), rather than merely being over it.
    func testABallLandsOnTheRailRollsAlongItAndIsOffTheTableWhenItStops() {
        let onTheWood = Table.cushionHeight + Table.ballRadius
        // Dropped onto the wood of the long rail, with a little pace along the table — not enough to
        // carry it a metre into the middle pocket's cut.
        let w = PhysicsWorld(balls: [
            Ball(id: 0, color: .white, position: Vec2(1200, -60), velocity: Vec2(300, 0),
                 height: onTheWood + 40),
        ])
        var bounced = 0.0
        var landed = false
        var clock = 0.0
        while clock < 20, !w.allAtRest {
            w.step(dt: 1.0 / 480.0)
            clock += 1.0 / 480.0
            if w.balls[0].height <= onTheWood + 0.5 { landed = true }
            if landed { bounced = max(bounced, w.balls[0].height) }
        }
        let ball = w.balls[0]
        XCTAssertEqual(ball.height, onTheWood, accuracy: 0.5, "it comes to rest on the wood")
        XCTAssertGreaterThan(bounced - onTheWood, 2, "having bounced off the wood on the way")
        XCTAssertGreaterThan(ball.position.x, 1250, "and rolled along the rail")
        XCTAssertFalse(ball.onTable, "a ball that stops on the wood is off the table")
        XCTAssertTrue(w.events.contains { if case .forcedOffTable(0) = $0 { return true }; return false },
                      "and it is reported as forced off the table")
    }

    /// A ball forced off the table is off it as far as the rules are concerned from the moment it
    /// leaves — the stroke does not wait for it — but it is still a ball in the air: it falls to the
    /// floor, and only once it has landed is it gone.
    func testABallForcedOffTheTableFallsToTheFloorBeforeItGoes() {
        let onTheWood = Table.cushionHeight + Table.ballRadius
        let w = PhysicsWorld(balls: [
            Ball(id: 0, color: .white, position: Vec2(1200, -60), velocity: Vec2(300, 0),
                 height: onTheWood + 40),
        ])
        var clock = 0.0
        while clock < 20, w.balls[0].onTable {
            w.step(dt: 1.0 / 480.0)
            clock += 1.0 / 480.0
        }
        XCTAssertFalse(w.balls[0].onTable, "off the table")
        XCTAssertTrue(w.balls[0].isFalling, "and still in the air, on its way to the floor")
        XCTAssertTrue(w.allAtRest, "the stroke does not wait for a ball that is off the table")

        let whenItLeft = w.balls[0].height
        while w.balls[0].isFalling {
            w.step(dt: 1.0 / 480.0)
            clock += 1.0 / 480.0
        }
        XCTAssertEqual(w.balls[0].height, Table.floorHeight + Table.ballRadius, accuracy: 0.5,
                       "it lands on the floor")
        XCTAssertLessThan(w.balls[0].height, whenItLeft, "having fallen to get there")
        XCTAssertFalse(w.balls[0].onTable, "and it is gone: neither on the table nor falling")
        // And the landing is a contact the view can hear, at the speed the fall arrived with.
        let landed = w.events.compactMap { event -> Double? in
            if case .landed(_, let speed) = event { return speed }
            return nil
        }.first
        XCTAssertNotNil(landed, "the floor is reported")
        XCTAssertGreaterThan(landed ?? 0, 1000, "at the speed a fall from a table's height comes down")
    }

    /// A ball rolling off the rail and back over the cushion falls onto the bed and plays on: being out
    /// over the wood is not being off the table, and only where a ball stops decides that.
    func testABallRollingOffTheRailComesBackOntoTheBed() {
        let w = PhysicsWorld(balls: [
            Ball(id: 0, color: .white, position: Vec2(1200, -40), velocity: Vec2(0, 300),
                 height: Table.cushionHeight + Table.ballRadius),
        ])
        run(w, seconds: 4)
        let ball = w.balls[0]
        XCTAssertTrue(ball.onTable, "it is still in play")
        XCTAssertEqual(ball.height, Table.ballRadius, accuracy: 0.5, "back on the cloth")
        XCTAssertGreaterThan(ball.position.y, 0, "and in the playing area")
        XCTAssertFalse(w.isOffTheTable(ball.position, atRest: true))
    }

    /// The pocket's cut goes through the rail as well as the cloth, so a ball rolling along the wood
    /// over a middle pocket drops in rather than rolling across the mouth.
    func testABallRollingAlongTheRailDropsIntoAMiddlePocket() {
        let middle = PocketID.bottomMiddle.position
        let w = PhysicsWorld(balls: [
            Ball(id: 0, color: .white, position: Vec2(middle.x, -40), velocity: Vec2(400, 0),
                 height: Table.cushionHeight + Table.ballRadius),
        ])
        run(w, seconds: 6)
        XCTAssertFalse(w.balls[0].onTable)
        XCTAssertEqual(w.balls[0].pottedInto, .bottomMiddle, "the cut through the rail is the pocket's")
    }

    /// What counts as off the table: resting on the wood of the rail, or out past it — and not merely
    /// being over the wood, in the air or rolling along it.
    func testOffTheTableIsAboutTheWood() {
        let w = world(cue: Vec2(1200, 600))
        XCTAssertFalse(w.isOffTheTable(Vec2(1200, 600), atRest: true), "on the bed")
        XCTAssertFalse(w.isOffTheTable(Vec2(1200, -60)), "over the wood, in the air or rolling")
        XCTAssertTrue(w.isOffTheTable(Vec2(1200, -60), atRest: true), "resting on the wood: off")
        XCTAssertFalse(w.isOffTheTable(Vec2(1200, -100)), "still over the wood")
        XCTAssertTrue(w.isOffTheTable(Vec2(1200, -200)), "past the wood of the rail: off")
    }

    // MARK: - The nap

    // MARK: - The swerve

    /// Strikes the cue ball up the table with a lifted cue and returns its spin, its vertical velocity
    /// and how far it has veered off the line of aim by the time it has run a while.
    private func liftedStrike(elevation: Double, side: Double, power: Double = 2500)
        -> (spin: Vec3, vertical: Double, veer: Double) {
        let ball = Ball(id: BallID.cue, color: .white, position: Vec2(400, Table.centreY))
        let w = PhysicsWorld(balls: [ball])
        w.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: power,
                         side: side, vertical: 0, elevation: elevation)
        let struck = w.balls[0]
        run(w, seconds: 0.9)
        return (struck.spin, struck.verticalVelocity, w.balls[0].position.y - Table.centreY)
    }

    /// A lifted cue strikes *down* at the ball, so the impulse is along the cue and the spin is the
    /// impulse's moment about the middle of the ball: the spin axis tilts with the cue, and side spin
    /// gains a barrel of spin about the line of the shot. That barrel is what the cloth turns into the
    /// curve — the ball swerves — and the lift also presses the ball into the cloth, which hops it.
    func testALiftedCueWithSideSpinSwervesTheBall() {
        let level = liftedStrike(elevation: 0, side: 0.5)
        let lifted = liftedStrike(elevation: 30 * .pi / 180, side: 0.5)

        XCTAssertEqual(level.spin.x, 0, accuracy: 1e-6,
                       "a level cue with side spin turns the ball about the vertical and no other way")
        XCTAssertEqual(level.vertical, 0, accuracy: 1e-6, "and leaves it on the cloth")
        XCTAssertGreaterThan(lifted.spin.x, 20,
                             "a lifted cue tips the spin into a barrel about the line of the shot")
        XCTAssertGreaterThan(lifted.spin.z, 50, "with the side spin still there")
        XCTAssertLessThan(lifted.vertical, -500, "and drives the ball down into the cloth")
        XCTAssertLessThan(lifted.veer, level.veer - 150,
                          "so it comes off the line of aim — the swerve")
    }

    /// It takes side spin to swerve: a lifted cue with the tip on the middle of the ball presses it
    /// into the cloth, hops it, and leaves the line of aim alone.
    func testALiftedCueWithTheTipOnTheMiddleDoesNotSwerve() {
        let lifted = liftedStrike(elevation: 30 * .pi / 180, side: 0)
        XCTAssertEqual(lifted.spin.length, 0, accuracy: 1e-6, "no spin, so nothing for the cloth to curve")
        XCTAssertEqual(lifted.veer, 0, accuracy: 0.01, "the ball runs straight up the table")
        XCTAssertLessThan(lifted.vertical, -500, "though it is still driven into the cloth")
    }

    /// A lifted cue hard enough puts the ball over another one. Going over part of a ball **before
    /// hitting one** is a jump shot (Section 2 Rule 20), so the shot is reported for the rules to call.
    func testACueBallLiftedOverABallIsReportedAsAJumpShot() {
        let obstruction = Ball(id: BallID.firstRed, color: .red, position: Vec2(700, Table.centreY))
        let cue = Ball(id: BallID.cue, color: .white, position: Vec2(400, Table.centreY))
        let w = PhysicsWorld(balls: [cue, obstruction])
        w.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 4600, side: 0, vertical: 0,
                         elevation: 30 * .pi / 180)
        var jumped = false
        var t = 0.0
        while t < 0.4 {
            w.clearEvents()
            w.step(dt: 1.0 / 480.0)
            t += 1.0 / 480.0
            if w.events.contains(where: { if case .jumpShot = $0 { return true }; return false }) { jumped = true }
        }
        XCTAssertTrue(jumped, "the cue ball went over the Red, which is a jump shot")
    }

    // MARK: - The nap

    /// The cloth is brushed: its fibres lie along the table from the baulk end towards the black —
    /// this file's +x — and a ball turning about the vertical is carried across them, along y.
    ///
    /// The spin is set on the ball directly rather than played with a cue, so the cue's own squirt
    /// is out of the measurement and only the nap is left in it.
    private func napDrift(spinZ: Double, speed: Double = 800, seconds: Double = 20) -> Double {
        var ball = Ball(id: BallID.cue, color: .white, position: Vec2(150, Table.centreY))
        ball.velocity = Vec2(speed, 0)                       // rolled up the table, along the nap
        ball.spin = Vec3(0, speed / Table.ballRadius, spinZ) // natural roll, plus the side spin
        let w = PhysicsWorld(balls: [ball])
        run(w, seconds: seconds)
        return w.balls[0].position.y - Table.centreY
    }

    /// Clockwise seen from above is the negative turn about the vertical, and the nap carries it
    /// towards the green; the anti-clockwise turn is carried towards the yellow. The yellow spot is
    /// at the lower y of the "D", so the green side is +y and the yellow side is -y.
    func testTheNapCarriesASideSpinningBallAcrossTheTable() {
        let straight = napDrift(spinZ: 0)
        let clockwise = napDrift(spinZ: -150)
        let antiClockwise = napDrift(spinZ: 150)
        XCTAssertEqual(straight, 0, accuracy: 0.001, "a ball with no side spin runs straight up the nap")
        XCTAssertGreaterThan(clockwise, 0, "a clockwise ball is carried towards the green (higher y)")
        XCTAssertLessThan(antiClockwise, 0, "an anti-clockwise ball is carried towards the yellow (lower y)")
        XCTAssertGreaterThan(clockwise, straight)
        XCTAssertLessThan(antiClockwise, straight)
    }

    /// The push is across the nap, and it takes side spin to feel it: a ball spinning about a
    /// horizontal axis — follow or screw back — is not carried sideways by the nap.
    func testFollowAndScrewBackAreNotCarriedSidewaysByTheNap() {
        for vertical in [0.5, -0.5] {
            var ball = Ball(id: BallID.cue, color: .white, position: Vec2(150, Table.centreY))
            ball.velocity = Vec2(800, 0)
            let factor = 5 * 800 / (2 * Table.ballRadius * Table.ballRadius)
            let h = vertical * Table.ballRadius
            ball.spin = Vec3(0, h * factor, 0)   // pure follow/draw, no side spin
            let w = PhysicsWorld(balls: [ball])
            run(w, seconds: 20)
            XCTAssertEqual(w.balls[0].position.y, Table.centreY, accuracy: 0.001,
                           "vertical spin at \(vertical) should not be carried across the nap")
        }
    }

    /// The nap is a nudge, not a swerve you would see at a glance: a ball well spun over a shot a
    /// full length of the table long drifts a few centimetres at the very most, and the two turns
    /// are the same size.
    func testNapDriftIsSmallAndSymmetrical() {
        let clockwise = napDrift(spinZ: -150)
        let antiClockwise = napDrift(spinZ: 150)
        XCTAssertEqual(clockwise, -antiClockwise, accuracy: 0.01, "the two turns should drift alike")
        XCTAssertGreaterThan(abs(clockwise), 0.5, "the drift should be there at all")
        XCTAssertLessThan(abs(clockwise), 60, "and should stay a nudge, not a swerve")
    }

    func testASlowBallStopsInsteadOfCrawling() {
        // A ball left barely moving — which is what a second collision leaves behind — used to
        // chatter: the friction reversed its slip every step, the two directions cancelled out, and
        // it slithered for hundreds of millimetres instead of stopping.
        for speed in [60.0, 20.0, 10.0] {
            let world = self.world(cue: Vec2(1000, 889))
            world.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: speed, side: 0, vertical: 0)
            let start = world.balls[0].position
            run(world, seconds: 5)
            let travelled = world.balls[0].position.distance(to: start)
            XCTAssertEqual(world.balls[0].velocity.length, 0, accuracy: 0.001,
                           "a ball set going at \(speed) mm/s should come to rest")
            XCTAssertLessThan(travelled, speed * 0.5,
                              "a ball set going at \(speed) mm/s should stop in its own length, not crawl")
        }
    }

    func testACutThrowsTheObjectBallTowardsTheLineOfTheShot() {
        // The object ball sits to the striker's right of the line, so a real table throws it
        // slightly back towards that line: its path is a few degrees inside the line of centres.
        let hit = collision(cue: Vec2(900, 889), object: Vec2(1400, 889 + 26), power: 1500, vertical: 0.4)
        let line = atan2(hit.lineOfCentres.y, hit.lineOfCentres.x)
        let object = atan2(hit.after.object.y, hit.after.object.x)
        XCTAssertLessThan(abs(object), abs(line), "the object ball should be thrown towards the line of the shot")
        XCTAssertGreaterThan(abs(object), abs(line) - 8 * .pi / 180, "and not thrown wildly")
    }

    func testACutLeavesTheBallsAboutNinetyDegreesApart() {
        let hit = collision(cue: Vec2(900, 889), object: Vec2(1400, 889 + 26), power: 1500, vertical: 0.4)
        let apart = acos(max(-1, min(1, hit.after.cue.normalized.dot(hit.after.object.normalized)))) * 180 / .pi
        // Throw pulls the angle a little under ninety degrees, but not far under it.
        XCTAssertEqual(apart, 90, accuracy: 10)
    }

    func testAStruckBallRollsAwayLikeARealOne() {
        // A ball struck at 800 mm/s with natural roll runs on the cloth alone: it comes to rest in
        // v^2 / (2 * rollingResistance * g), which on a 0.010 competition cloth is 3.26 m — nearly a
        // full length of the table. It must not stop in its own length, and it must not sail on for
        // metres more than the cloth can account for. The shot starts at the baulk end and dies a
        // handsbreadth short of the far cushion, so nothing but the cloth is in the reckoning.
        let world = self.world(cue: Vec2(200, 889))
        world.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 800, side: 0, vertical: 0.4)
        let travelled = pathUntilRest(world)
        let expected = 800.0 * 800.0 / (2 * PhysicsWorld.rollingResistance * PhysicsWorld.gravity)
        XCTAssertEqual(travelled, expected, accuracy: 150,
                       "a medium shot should run the distance the cloth's rolling resistance allows")
    }

    func testACushionSendsABallBackAlongTheLineItCameInOn() {
        // Straight into a cushion with no side spin: the ball comes straight back.
        let world = self.world(cue: Vec2(3000, 889))
        world.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 1200, side: 0, vertical: 0.4)
        var t = 0.0
        while t < 6, world.balls[0].velocity.x > 0 {
            world.step(dt: 1.0 / 240.0)
            t += 1.0 / 240.0
        }
        XCTAssertLessThan(world.balls[0].velocity.x, 0, "the ball should come back")
        XCTAssertEqual(world.balls[0].velocity.y, 0, accuracy: 1, "and along the same line")
    }

    func testCushionsDoNotOverthrowABallWithSideSpin() {
        // Side spin off a cushion is real, but it must stay modest: a ball sent square into a
        // cushion should not come off at a wild angle.
        let world = self.world(cue: Vec2(3000, 889))
        world.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 1200, side: 0.5, vertical: 0.4)
        var t = 0.0
        while t < 6, world.balls[0].velocity.x > 0 {
            world.step(dt: 1.0 / 240.0)
            t += 1.0 / 240.0
        }
        let out = world.balls[0].velocity
        let offLine = abs(atan2(out.y, -out.x)) * 180 / .pi
        XCTAssertLessThan(offLine, 25, "cushion throw should be a few degrees, not tens of them")
    }

    func testBallsNeverOverlapAtRest() {
        let w = world(cue: Vec2(1000, 889), objectBalls: [
            (BallID.firstRed, Vec2(1300, 889)),
            (BallID.firstRed + 1, Vec2(1352, 889)),
        ])
        w.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 2500, side: 0, vertical: 0.2)
        run(w, seconds: 6)
        let onTable = w.balls.filter(\.onTable)
        for i in 0..<onTable.count {
            for j in (i + 1)..<onTable.count {
                XCTAssertGreaterThanOrEqual(onTable[i].position.distance(to: onTable[j].position),
                                            Table.ballDiameter - 1.0)
            }
        }
    }

    // MARK: The room behind the ball for the cue

    /// The cue is a stick, not a shadow: it is judged down its whole length and at its own thickness,
    /// so a cushion a line down the middle would clear is one the stick itself cannot.
    func testTheCueIsJudgedAsTheStickItIs() {
        // The cue is judged **level** now, and a level cue never clears a cushion at all — which is the
        // whole reason the room behind the ball has to be found for it. The lift it is measured at here
        // is therefore stated: `automaticLiftCap` is as far as the game will stand the butt up of its own
        // accord, which is the pose a jammed cue is settled into.
        let lifted = FrameDriver.automaticLiftCap
        /// Whether a cue lifted that far fits, with the ball `distance` from the cushion it is played
        /// away from and a full backswing asked for.
        func fits(_ distance: Double) -> Bool {
            world(cue: Vec2(distance, Table.centreY))
                .cueFits(cueBallID: BallID.cue, yaw: 0, elevation: lifted, side: 0, vertical: 0, draw: 260)
        }
        var crossing = 0.0
        for distance in stride(from: 0.0, through: 900.0, by: 2.0) where fits(distance) {
            crossing = distance
            break
        }
        // A line down the middle of the stick would clear a cushion this far behind the ball; the stick
        // itself needs more room than that — how much more is its own girth, and at this lift it is
        // most of a hand's width.
        let middleOfTheStick = (Table.cushionHeight - Table.ballRadius) / tan(lifted)
        XCTAssertGreaterThan(crossing, middleOfTheStick + 25,
                             "the stick's own girth puts the crossing well beyond its middle line")
        XCTAssertLessThan(crossing, middleOfTheStick + 250)

        // And the girth really is a shape rather than one number: the tip is the thin end and the butt the
        // fat one, and the two are **one rate apart** — the cue is a long cone and its side is a straight
        // line, so every length of it rises at the rate the whole stick does.
        XCTAssertEqual(Table.cueGirth.first?.radius, Table.cueRadius(at: Table.cueSlice))
        XCTAssertEqual(Table.cueGirth.last?.radius, Table.cueButtRadius)
        XCTAssertGreaterThan(Table.cueRadius(at: Table.cueLength), Table.cueRadius(at: 0))
        let overallRate = (Table.cueButtRadius - Table.cueTipRadius) / Table.cueLength
        for (front, back, radius) in Table.cueGirth {
            XCTAssertEqual(radius, Table.cueRadius(at: back), accuracy: 1e-9,
                           "the stick's own girth is the taper's")
            XCTAssertEqual((Table.cueRadius(at: back) - Table.cueRadius(at: front)) / (back - front),
                           overallRate, accuracy: 1e-9,
                           "length \(front)…\(back) rises at the whole stick's rate")
        }

        // On the middle of the table a **level** cue has room up and down it, where the cushions are a
        // table's length away: the game leaves it alone there. Across it the cushion is 889 mm behind
        // the ball and a level cue runs into it — a level cue runs at the middle of the ball, 26.25 mm,
        // and a cushion's top stands 38.34 mm up — which is the whole reason the game has to settle the
        // cue where it fits.
        let open = world(cue: Vec2(Table.length / 2, Table.centreY))
        XCTAssertTrue(open.cueFits(cueBallID: BallID.cue, yaw: 0, elevation: 0, side: 0, vertical: 0, draw: 260))
        XCTAssertFalse(open.cueFits(cueBallID: BallID.cue, yaw: .pi / 2, elevation: 0, side: 0, vertical: 0, draw: 260),
                       "a level cue does not clear the cushion across the table")
    }

    /// Spin moves the cue: the tip meets the ball up its face and the stick behind it is carried up
    /// with it, so a topped ball can be struck where a level cue has nowhere to put its tip.
    func testATipUpTheBallLiftsTheLineOfTheCue() {
        let against = world(cue: Vec2(1000, Table.cushionRestReach))
        func fits(elevation: Double, vertical: Double) -> Bool {
            against.cueFits(cueBallID: BallID.cue, yaw: .pi / 2, elevation: elevation,
                            side: 0, vertical: vertical, draw: 20)
        }
        XCTAssertFalse(fits(elevation: 0, vertical: 0), "a level cue has no room at a ball on the cushion")
        XCTAssertFalse(fits(elevation: 0, vertical: 0.5),
                       "and topping the ball alone is not enough at the bottom of the lift")
        XCTAssertTrue(fits(elevation: PhysicsWorld.maxCueElevation, vertical: 0.5),
                      "stood up, with the tip up the ball, the cue fits")
    }

    /// A ball resting behind the cue ball is an obstruction of the same kind, and the cue has to pass
    /// over it — which is what the butt coming up and the tip going up the ball are for.
    func testABallBehindTheCueBallIsPassedOverRatherThanThrough() {
        let ballBehind = world(cue: Vec2(1784, Table.centreY),
                               objectBalls: [(BallID.firstRed, Vec2(1784 - Table.ballDiameter, Table.centreY))])
        XCTAssertFalse(ballBehind.cueFits(cueBallID: BallID.cue, yaw: 0, elevation: 0,
                                          side: 0, vertical: 0, draw: 20),
                       "a level cue would go through the ball behind")
        XCTAssertTrue(ballBehind.cueFits(cueBallID: BallID.cue, yaw: 0,
                                        elevation: 30 * .pi / 180, side: 0, vertical: 0.5, draw: 20),
                      "stood up and topped, it passes over it")
    }

}
