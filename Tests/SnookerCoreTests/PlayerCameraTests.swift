import XCTest
@testable import SnookerCore

/// The first-person camera: where the player's eye sits and what it looks at.
final class PlayerCameraTests: XCTestCase {

    private let cueBall = Vec2(1000, 889)

    func testTheEyeStandsBehindTheCueBall() {
        for preset in PlayerCamera.Preset.allCases {
            let camera = PlayerViewSolver.camera(cueBall: cueBall, yaw: 0, pitch: preset.pitch, preset: preset)
            // Straight up the table means standing at a smaller x than the cue ball.
            XCTAssertLessThan(camera.eye.x, cueBall.x, "\(preset) should stand behind the ball")
            XCTAssertEqual(cueBall.x - camera.eye.x, preset.standOff, accuracy: 1e-9)
            XCTAssertEqual(camera.eyeHeight, preset.eyeHeight, accuracy: 1e-9)
        }
    }

    func testTheEyeSitsDirectlyAboveTheLineOfAim() {
        // The player sights straight down the cue: wherever they are aiming and whichever eye
        // level they are using, the eye is on the line of aim, not off to one side of it.
        for preset in PlayerCamera.Preset.allCases {
            for degrees in stride(from: 0.0, to: 360.0, by: 23.0) {
                let yaw = degrees * .pi / 180
                let camera = PlayerViewSolver.camera(cueBall: cueBall, yaw: yaw, pitch: -0.2, preset: preset)
                let forward = Vec2(cos(yaw), sin(yaw))
                let behind = camera.eye - cueBall
                // Nothing of the offset is across the line of aim.
                XCTAssertEqual((behind - forward * behind.dot(forward)).length, 0, accuracy: 1e-9,
                               "\(preset) at \(degrees) degrees is off the cue")
                XCTAssertEqual(behind.length, preset.standOff, accuracy: 1e-9)
            }
        }
    }

    func testStandingFurtherBackRaisesTheEye() {
        let sighting = PlayerViewSolver.camera(cueBall: cueBall, yaw: 0.3, pitch: -0.2, preset: .sighting)
        let standing = PlayerViewSolver.camera(cueBall: cueBall, yaw: 0.3, pitch: -0.2, preset: .standing)
        let raised = PlayerViewSolver.camera(cueBall: cueBall, yaw: 0.3, pitch: -0.2, preset: .raised)
        XCTAssertGreaterThan(standing.eyeHeight, sighting.eyeHeight)
        XCTAssertGreaterThan(raised.eyeHeight, standing.eyeHeight)
        XCTAssertGreaterThan(standing.eye.distance(to: cueBall), sighting.eye.distance(to: cueBall))
        XCTAssertGreaterThan(raised.eye.distance(to: cueBall), standing.eye.distance(to: cueBall))
    }

    func testAGazeIsClampedToWhatAPlayerCanHold() {
        XCTAssertEqual(PlayerViewSolver.clampPitch(-10), PlayerCamera.pitchRange.lowerBound)
        XCTAssertEqual(PlayerViewSolver.clampPitch(10), PlayerCamera.pitchRange.upperBound)
        XCTAssertEqual(PlayerViewSolver.clampPitch(-0.2), -0.2)
    }

    func testTheGazeRunsStraightDownTheCue() {
        // Standing above the line of aim, the player's gaze should follow it exactly: the cue runs
        // up the middle of the view rather than across it.
        let camera = PlayerViewSolver.camera(cueBall: cueBall, yaw: 0, pitch: -0.25, preset: .standing)
        let gaze = camera.convergencePoint(aimLinePoint: cueBall, converge: 3000)
        XCTAssertEqual(gaze.position.x, cueBall.x + 3000, accuracy: 1e-9)
        XCTAssertEqual(gaze.position.y, cueBall.y, accuracy: 1e-9)
        // The elevation of the gaze is the elevation that was asked for.
        let horizontal = (gaze.position - camera.eye).length
        XCTAssertEqual((gaze.height - camera.eyeHeight) / horizontal, tan(camera.pitch), accuracy: 1e-9)

        // And the gaze goes straight up the line of aim.
        let flat = gaze.position - camera.eye
        XCTAssertEqual(atan2(flat.y, flat.x), camera.yaw, accuracy: 1e-9)
    }

    func testGazePointFollowsTheLineOfSight() {
        let camera = PlayerCamera(eye: Vec2(0, 0), eyeHeight: 500, yaw: 0, pitch: 0, fieldOfView: 50)
        let ahead = camera.gazePoint(distance: 1000)
        XCTAssertEqual(ahead.position.x, 1000, accuracy: 1e-9)
        XCTAssertEqual(ahead.height, 500, accuracy: 1e-9)
    }

    /// Standing at the table and down on the shot are the same position from different numbers, and
    /// getting down is a matter of moving between them.
    func testTheFramingBetweenPresetsCarriesTheEyeDown() {
        let up = PlayerViewSolver.framing(from: .standing, to: .sighting, 0)
        XCTAssertEqual(up.standOff, PlayerCamera.Preset.standing.standOff, accuracy: 0.001)
        XCTAssertEqual(up.eyeHeight, PlayerCamera.Preset.standing.eyeHeight, accuracy: 0.001)

        let half = PlayerViewSolver.framing(from: .standing, to: .sighting, 0.5)
        XCTAssertEqual(half.eyeHeight,
                       (PlayerCamera.Preset.standing.eyeHeight + PlayerCamera.Preset.sighting.eyeHeight) / 2,
                       accuracy: 0.001, "half way down is half the height")

        let down = PlayerViewSolver.framing(from: .standing, to: .sighting, 1)
        XCTAssertEqual(down.eyeHeight, PlayerCamera.Preset.sighting.eyeHeight, accuracy: 0.001)
        XCTAssertEqual(down.standOff, PlayerCamera.Preset.sighting.standOff, accuracy: 0.001)
    }

    /// And a camera built from a framing stands where the numbers say: the eye back along the line of
    /// aim by the stand-off, at the height given.
    func testACameraCanBeBuiltFromAFraming() {
        let camera = PlayerViewSolver.camera(cueBall: Vec2(1000, 889), yaw: 0, pitch: 0,
                                             standOff: 620, eyeHeight: 235, fieldOfView: 40)
        XCTAssertEqual(camera.eye, Vec2(1000 - 620, 889))
        XCTAssertEqual(camera.eyeHeight, 235, accuracy: 0.001)
        XCTAssertEqual(camera.fieldOfView, 40, accuracy: 0.001)
    }

    /// Down on the shot with the cue stood up, the player's head goes up with the cue: the eye keeps
    /// the same clearance over it that it had with the cue level, and the gaze tips down by the lift so
    /// they are still looking along the cue. At 45° they are all but standing again.
    func testALiftedCueLiftsThePlayerWithIt() {
        let standOff = PlayerCamera.Preset.sighting.standOff
        let level = PlayerViewSolver.sighting(standOff: standOff, elevation: 0)
        XCTAssertEqual(level.eyeHeight, PlayerCamera.Preset.sighting.eyeHeight, accuracy: 0.001)
        XCTAssertEqual(level.pitch, PlayerCamera.Preset.sighting.pitch, accuracy: 1e-9)
        let clearance = PlayerCamera.Preset.sighting.eyeHeight - Table.ballRadius

        for degrees in [10.0, 25.0, 45.0] {
            let lift = degrees * .pi / 180
            let sighting = PlayerViewSolver.sighting(standOff: standOff, elevation: lift)
            // The cue passes through the ball and rises away from it, so at the eye's own place along
            // the table it stands `standOff · tan(lift)` higher than it does when it is level.
            let cueAtTheEye = Table.ballRadius + standOff * tan(lift)
            XCTAssertGreaterThan(sighting.eyeHeight, cueAtTheEye,
                                 "the head should be above the cue at \(degrees)°")
            XCTAssertEqual(sighting.eyeHeight - cueAtTheEye, clearance, accuracy: 0.001,
                           "with the same clearance over it as a level cue")
            XCTAssertEqual(sighting.pitch, PlayerCamera.Preset.sighting.pitch - lift, accuracy: 1e-9,
                           "and the gaze tipped down with the cue")
        }

        // And the framing carries it: getting down with the cue up stands the player up.
        let framing = PlayerViewSolver.framing(from: .standing, to: .sighting, 1,
                                               elevation: 30 * .pi / 180)
        XCTAssertGreaterThan(framing.eyeHeight, PlayerCamera.Preset.sighting.eyeHeight)
        XCTAssertLessThan(framing.pitch, PlayerCamera.Preset.sighting.pitch)
    }

    // MARK: - Up and about

    /// Walking about the table keeps the player's body clear of it: the wood stops them, whichever way
    /// they walk at it.
    func testWalkingKeepsTheBodyOffTheTable() {
        let standOff = Table.tableSurround + PlayerWalk.bodyRadius
        // Walk straight at the near long side, a step at a time the way the frame loop does: the player
        // stops at the wood.
        var atTheSide = Vec2(Table.length / 2, -1200)
        for _ in 0..<200 { atTheSide = PlayerWalk.step(from: atTheSide, forward: 40, sideways: 0, yaw: .pi / 2) }
        XCTAssertTrue(PlayerWalk.isClearOfTheTable(atTheSide))
        XCTAssertEqual(atTheSide.y, -standOff, accuracy: 40, "stopped at the wood, not through it")
        // And at the end of the table.
        var atTheEnd = Vec2(-1200, Table.centreY)
        for _ in 0..<200 { atTheEnd = PlayerWalk.step(from: atTheEnd, forward: 40, sideways: 0, yaw: 0) }
        XCTAssertEqual(atTheEnd.x, -standOff, accuracy: 40)
        // A single step that would land on the table is simply not taken.
        XCTAssertEqual(PlayerWalk.step(from: Vec2(-1200, Table.centreY), forward: 2000, sideways: 0, yaw: 0),
                       Vec2(-1200, Table.centreY))
        // Walking along beside it is left alone.
        // Walking to the player's own right is towards the lower y.
        let beside = PlayerWalk.step(from: Vec2(1000, -800), forward: 500, sideways: 250, yaw: 0)
        XCTAssertEqual(beside, Vec2(1500, -1050))
    }

    /// The stand-off the player takes with the cue laid: straight behind the ball, and no nearer to the
    /// table than their body allows — so shooting across the table they stand right at the edge, and
    /// shooting along it they stand off the end.
    func testTheCueIsLaidFromWhereThePlayerStandsAtTheBall() {
        let ball = Vec2(Table.length / 2, Table.centreY)
        let across = PlayerWalk.clearStandOff(from: ball, away: Vec2(0, 1))
        XCTAssertEqual(across, Table.width - Table.centreY + Table.tableSurround + PlayerWalk.bodyRadius,
                       accuracy: 0.001, "standing back across the table stops at the near edge")
        let along = PlayerWalk.clearStandOff(from: ball, away: Vec2(-1, 0))
        XCTAssertEqual(along, ball.x + Table.tableSurround + PlayerWalk.bodyRadius, accuracy: 0.001)
    }

    /// Down on the shot the camera may come in over the cushion, but no further than the eye-to-waist
    /// reach would let a player lean — and it stays **exactly above the cue**: the distance comes off
    /// the stand-off along the line of the cue, never off to one side.
    func testTheCameraLeansOverTheTableNoFurtherThanTheReach() {
        // A ball deep in the table: the player stands back until the eye is within the reach.
        let deep = Vec2(Table.length / 2, Table.centreY)
        let standOff = PlayerWalk.leaningStandOff(from: deep, away: Vec2(0, -1))
        XCTAssertGreaterThan(standOff, 0)
        let eye = deep + Vec2(0, -1) * standOff
        XCTAssertEqual(eye.x, deep.x, accuracy: 1e-9, "exactly above the cue, not shunted sideways")
        let nearestSide = min(eye.x, Table.length - eye.x, eye.y, Table.width - eye.y)
        XCTAssertEqual(nearestSide, PlayerWalk.leanReach, accuracy: 1e-9,
                       "leaning in over the cushion, and no further")

        // A ball already within the reach of a cushion needs no stand-off at all: the limit is a limit,
        // not a distance the camera is pushed out to.
        XCTAssertEqual(PlayerWalk.leaningStandOff(from: Vec2(Table.length / 2, 100), away: Vec2(0, -1)),
                       0, accuracy: 1e-9)
        // And one with the cushion behind it: the camera is already out beyond the playing area.
        XCTAssertEqual(PlayerWalk.leaningStandOff(from: Vec2(deep.x, -200), away: Vec2(0, 1)),
                       0, accuracy: 1e-9)
    }
}
