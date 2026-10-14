import AppKit
import Metal
import SceneKit
import SnookerCore
import SpriteKit

/// Renders the 3D view offscreen, so the table, the lighting and the player's eye can be
/// inspected without opening a window:
///
///     Snooker.app/Contents/MacOS/Snooker --snapshots /tmp/snooker-snapshots
enum Snapshots {

    private static let size = CGSize(width: 1280, height: 720)

    static func run(into directory: URL) -> Int32 {
        guard let device = MTLCreateSystemDefaultDevice() else {
            FileHandle.standardError.write(Data("No Metal device available.\n".utf8))
            return 1
        }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            FileHandle.standardError.write(Data("Cannot create \(directory.path): \(error)\n".utf8))
            return 1
        }

        let table = Table3D()
        var written: [String] = []

        // Waiting to break: the cue ball is in hand, so the player stands behind the D.
        let opening = FrameDriver()
        opening.aimAngle = 0
        written += capture(table, opening, preset: .standing, name: "01-cue-ball-in-hand", into: directory, device: device)

        // The break, sighted down the cue and then from further back.
        let breakStart = Vec2(Table.baulkLineX, Table.centreY - 120)
        opening.placeCueBall(at: breakStart)
        if let apex = Table.rackedReds().first {
            opening.aimAngle = atan2(apex.y - breakStart.y, apex.x - breakStart.x)
        }
        written += capture(table, opening, preset: .sighting, name: "02-on-the-break", into: directory, device: device)
        written += capture(table, opening, preset: .standing, name: "03-standing-at-the-break", into: directory, device: device)
        written += capture(table, opening, preset: .raised, name: "04-raised-over-the-table", into: directory, device: device)

        // Open play, from where the break left the cue ball.
        opening.shoot(angle: opening.aimAngle, power: 0.82, side: 0, vertical: 0.1)
        opening.runStrokeToRest()
        if let cue = opening.cueBall, cue.onTable {
            let towardsCentre = Vec2(Table.length / 2, Table.centreY) - cue.position
            if towardsCentre.length > 1 {
                opening.aimAngle = atan2(towardsCentre.y, towardsCentre.x)
            }
        }
        written += capture(table, opening, preset: .sighting, name: "05-open-play", into: directory, device: device)

        // Looking back down the table towards the baulk end.
        if let cue = opening.cueBall, cue.onTable {
            let toBaulk = Table.brownSpot - cue.position
            if toBaulk.length > 1 {
                opening.aimAngle = atan2(toBaulk.y, toBaulk.x)
                written += capture(table, opening, preset: .sighting, name: "06-looking-back", into: directory, device: device)
            }
        }

        // The HUD that the app draws over the 3D view, composited the same way the window does.
        if let hud = hudOverlay(table: table, driver: opening, device: device) {
            report(hud, name: "07-hud-over-the-table", table: table, driver: opening)
            written += [write(hud, name: "07-hud-over-the-table", into: directory)]
        }
        if let topDown = topDownView(table: table, driver: opening, device: device) {
            written += [write(topDown, name: "08-top-down", into: directory)]
        }

        steerProbe()
        cueControlProbe()
        clickProbe(table)
        geometryProbe(table)
        fabricProbe(table, device: device, into: directory)
        cueProbe(table)
        cueRoomProbe(table, device: device, into: directory)
        railProbe()
        physicsProbe()
        markingProbe(table, device: device)
        ghostProbe(table, device: device)
        noiseProbe()
        buttonProbe()
        scoreBoardProbe()
        helpProbe()
        newFrameProbe()
        snookersProbe()
        mouseAxisProbe()
        cursorProbe()
        frameRateProbe()
        tipProbe()
        doubleHitProbe()
        breakLogProbe()
        colourChoiceProbe()
        cushionGrabProbe()
        aimingAidProbe(table)
        surfaceProbe(table, device: device, into: directory)
        roomProbe(table, device: device, into: directory)
        cueShadowProbe(table, device: device, into: directory)

        // Passing --lighting-probe measures the exposure of the same view at several stops, for
        // tuning the lights.
        if CommandLine.arguments.contains("--lighting-probe") {
            lightingProbe(table, device: device)
            shadowProbe(table, device: device)
            ballReflectionProbe(table, device: device, into: directory)
            lightContributionProbe(table, device: device)
            touchingBallProbe(table, device: device, into: directory)
            ballInHandProbe(table)
            standingProbe(table)
            fineAimProbe(table)
            cueAndSpinProbe(table, device: device, into: directory)
            lightRigProbe(table, device: device, into: directory)
        }

        print(written.joined(separator: "\n"))
        return 0
    }

    /// Describes a PNG on disk — exposure and a luminance map — so a screenshot of the running
    /// app can be checked the same way a snapshot is:
    ///
    ///     Snooker --inspect /tmp/screen.png
    static func inspect(_ path: String) -> Int32 {
        guard let image = NSImage(contentsOfFile: path) else {
            FileHandle.standardError.write(Data("Cannot read \(path)\n".utf8))
            return 1
        }
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            FileHandle.standardError.write(Data("No bitmap data in \(path)\n".utf8))
            return 1
        }
        describe(rep, name: (path as NSString).lastPathComponent)
        return 0
    }

    private typealias Sample = (r: Double, g: Double, b: Double)

    /// The part of a range of columns that lies inside another: for following an edge from row to row,
    /// where the search window at the end of the picture has to be brought back in.
    private static func clamped(_ range: ClosedRange<Int>, to other: ClosedRange<Int>) -> ClosedRange<Int> {
        let low = max(range.lowerBound, other.lowerBound)
        let high = min(range.upperBound, other.upperBound)
        return low <= high ? low...high : other
    }

    private static func sample(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int) -> Sample {
        let cx = min(max(x, 0), rep.pixelsWide - 1)
        let cy = min(max(y, 0), rep.pixelsHigh - 1)
        guard let c = rep.colorAt(x: cx, y: cy)?.usingColorSpace(.deviceRGB) else { return (0, 0, 0) }
        return (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
    }

    private static func luminance(_ c: Sample) -> Double {
        0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
    }

    /// The **mean and the spread** of a small square of a render, which is what a textured surface has to
    /// be read with: one pixel of a carpet is one tuft, and a single sample of it says nothing about the
    /// carpet. The spread is the widest difference between the channels of any pixel in the patch, so a
    /// grey carpet and a grey patch of any other tone both come out near zero and a green one does not.
    private static func patch(_ rep: NSBitmapImageRep, _ x: Int, _ y: Int, radius: Int)
        -> (mean: Sample, spread: Double) {
        var total = (r: 0.0, g: 0.0, b: 0.0)
        var count = 0.0
        var spread = 0.0
        for dy in -radius...radius {
            for dx in -radius...radius {
                let c = sample(rep, x + dx, y + dy)
                total.r += c.r
                total.g += c.g
                total.b += c.b
                count += 1
                spread = max(spread, max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b)))
            }
        }
        return ((total.r / count, total.g / count, total.b / count), spread)
    }

    /// Exposure summary and a luminance map of a rendered frame.
    private static func describe(_ rep: NSBitmapImageRep, name: String) {
        print("\(name)  \(rep.pixelsWide)x\(rep.pixelsHigh)")
        reportStats(rep)
        reportMap(rep, marks: [])
    }

    /// How bright a frame is: mean luminance, the brightest point, and what proportion of the
    /// frame is blown out, black, or reading as cloth.
    private struct Exposure {
        var mean = 0.0
        var brightest = 0.0
        var blown = 0.0
        var black = 0.0
        var greenish = 0.0
    }

    private static func exposure(_ rep: NSBitmapImageRep) -> Exposure {
        let width = rep.pixelsWide, height = rep.pixelsHigh
        var total = 0.0, brightest = 0.0, blown = 0, black = 0, samples = 0
        var greenish = 0
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let c = sample(rep, x, y)
                let level = luminance(c)
                total += level
                brightest = max(brightest, level)
                if level > 0.96 { blown += 1 }
                if level < 0.02 { black += 1 }
                if c.g > c.r * 1.4, c.g > c.b * 1.4, level > 0.08 { greenish += 1 }
                samples += 1
            }
        }
        let count = Double(samples)
        return Exposure(mean: total / count, brightest: brightest,
                        blown: Double(blown) / count, black: Double(black) / count,
                        greenish: Double(greenish) / count)
    }

    private static func reportStats(_ rep: NSBitmapImageRep) {
        let e = exposure(rep)
        print(String(format: "  mean %.3f  max %.3f  blown %.1f%%  black %.1f%%  cloth-green %.1f%%",
                     e.mean, e.brightest, 100 * e.blown, 100 * e.black, 100 * e.greenish))
    }

    /// A luminance map of the frame, with the marked points lettered over it.
    private static func reportMap(_ rep: NSBitmapImageRep, marks: [(x: Int, y: Int, label: Character)]) {
        let width = rep.pixelsWide, height = rep.pixelsHigh
        let columns = 92, rows = 28
        let ramp = Array(" .:-=+*#%@")
        var grid = [[Character]](repeating: [Character](repeating: " ", count: columns), count: rows)
        for row in 0..<rows {
            for column in 0..<columns {
                let x = column * width / columns + width / columns / 2
                let y = row * height / rows + height / rows / 2
                let c = sample(rep, x, y)
                let index = min(ramp.count - 1, max(0, Int(luminance(c) * Double(ramp.count - 1) * 1.25)))
                grid[row][column] = ramp[index]
            }
        }
        for mark in marks {
            let column = min(columns - 1, max(0, mark.x * columns / width))
            let row = min(rows - 1, max(0, mark.y * rows / height))
            grid[row][column] = mark.label
        }
        for row in grid { print("  |" + String(row) + "|") }
    }

    /// Renders one fixed view — the same one snapshot 01 uses — with the lights scaled down by
    /// different amounts, and reports how bright each one comes out.
    private static func lightingProbe(_ table: Table3D, device: MTLDevice) {
        let driver = FrameDriver()
        table.use(.standing)
        table.exposureOffset = 0
        for _ in 0..<240 {
            table.update(with: driver, dt: 1.0 / 120.0)
        }
        print("lighting probe (the view of snapshot 01)")
        for scale in [1.0, 0.5, 0.25, 0.125, 0.06, 0.03] {
            table.lightScale = scale
            for _ in 0..<4 {
                table.update(with: driver, dt: 1.0 / 120.0)
            }
            guard let tiff = table.renderImage(size: size, device: device).tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { continue }
            let e = exposure(rep)
            print(String(format: "  lights x%.3f  mean %.3f  blown %.1f%%",
                         scale, e.mean, 100 * e.blown))
        }
        table.lightScale = 1
    }

    /// The cue meets the ball where the tip is, and the strength of a shot comes from how fast the
    /// mouse is moving the cue.
    private static func cueAndSpinProbe(_ table: Table3D, device: MTLDevice, into directory: URL) {
        let scene = TableScene(size: size)
        scene.scaleMode = .resizeFill
        scene.table3D = table
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.presentScene(scene)
        let driver = scene.controller
        table.holdFraming(.sighting)                  // down on the shot, for the picture
        _ = driver.placeCueBall(at: Vec2(1784, 889))
        var clock = CACurrentMediaTime()
        func frame() { clock += 1.0 / 60; scene.update(clock) }
        for _ in 0..<30 { frame() }

        print("cue and spin probe:")
        for (side, vertical, what) in [(0.0, 0.0, "no spin"), (0.5, 0.0, "full side"),
                                       (0.0, 0.5, "full follow"), (-0.3, -0.4, "draw and left")] {
            driver.spinSide = side
            driver.spinVertical = vertical
            frame()
            print(String(format: "  %-15@ tip %+5.1f mm across (striker's right) and %+5.1f mm up the ball, leaning %.2f deg",
                         what as NSString, table.cueTipOffset.across, table.cueTipOffset.up,
                         atan2(table.cueTipOffset.across, 1400) * 180 / .pi))
        }

        // And a picture: the cue on the ball with the tip out at the side.
        driver.spinSide = 0.5
        driver.spinVertical = 0.0
        for _ in 0..<30 { frame() }

        // A lifted cue: however far the butt is stood up, the tip still meets the ball on the sphere a
        // radius plus the gap from its middle, and the cue's own angle is the elevation — so the sweep
        // runs over the cue's angles themselves, from the bottom of the lift to the top.
        for degrees in [Table.cueStanceElevationDegrees, 20.0, 45.0, 90.0] {
            driver.spinSide = 0.0
            driver.spinVertical = 0.0
            driver.cueElevation = PhysicsWorld.cueLean(at: degrees * .pi / 180)
            for _ in 0..<30 { frame() }
            let centre = Table3D.scenePoint(driver.cueBall?.position ?? Vec2(1784, 889),
                                            height: Table.ballRadius)
            let reach = Double(simd_distance(table.cueTipWorld, centre)) * 1000
            let wanted = Table.ballRadius + table.cueTipDistance
            print(String(format: "  cue at %4.1f°: tip %.1f mm from the middle of the ball; a radius plus the %.0f mm gap is %.1f %@",
                         degrees, reach, table.cueTipDistance, wanted,
                         (abs(reach - wanted) < 0.5 ? "— on the ball" : "WRONG") as NSString))
        }
        driver.cueElevation = PhysicsWorld.cueLean(at: 0)
        driver.spinSide = 0.5
        for _ in 0..<30 { frame() }

        // Down on the shot with the cue stood up, the player stands up with it and keeps their head
        // above the cue. The eye is read back off the camera, which is where the picture is taken from.
        print("down on the shot, cue lifted:")
        _ = scene.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: "s", charactersIgnoringModifiers: "s",
                                                 isARepeat: false, keyCode: 0)!)
        for degrees in [PhysicsWorld.cueLean(at: 0) * 180 / .pi, 15.0, 30.0, 45.0, 90.0] {
            driver.cueElevation = degrees * .pi / 180
            for _ in 0..<120 { frame() }
            // The cue stands at the elevation the player's lift is, and the head rides the cue: see
            // `PhysicsWorld.cueLean` and `PlayerViewSolver.sighting`, whose rise stops climbing at 45°
            // however far the cue is stood up — a player standing a cue on end is on their feet.
            let rise = min(PhysicsWorld.cueLean(at: degrees * .pi / 180), 45 * .pi / 180)
            let cueAtTheEye = Table.ballRadius
                + PlayerCamera.Preset.sighting.standOff * tan(rise)
            print(String(format: "  cue at %4.1f°: eye %.0f mm above the cloth, the cue %.0f there — head above the cue by %.0f",
                         degrees, table.eyeHeight, cueAtTheEye, table.eyeHeight - cueAtTheEye))
        }
        driver.cueElevation = PhysicsWorld.cueLean(at: 0)
        driver.cancelCueAction()

        // Up and about: with the cue put away the player walks the table and the camera is over their
        // own feet, clear of the table however hard they walk at it; laying the cue puts the camera on
        // the line of the cue, standing off the ball and no closer to the table than their body allows.
        print("walking about the table:")
        driver.toggleCueHandling()                     // put the cue away
        for _ in 0..<120 { frame() }
        print(String(format: "  cue away: player at (%.0f, %.0f), clear of the table: %@",
                     driver.playerPosition.x, driver.playerPosition.y,
                     (PlayerWalk.isClearOfTheTable(driver.playerPosition) ? "yes" : "NO") as NSString))
        // Walk at the table a frame at a time, the way the keys do, and stop at the wood.
        for _ in 0..<180 { driver.walk(forward: 1, sideways: 0, over: 1.0 / 60) }
        for _ in 0..<60 { frame() }
        print(String(format: "  walked at it: player at (%.0f, %.0f), clear of the table: %@",
                     driver.playerPosition.x, driver.playerPosition.y,
                     (PlayerWalk.isClearOfTheTable(driver.playerPosition) ? "yes" : "NO") as NSString))
        driver.toggleCueHandling()                     // lay the cue on the table again
        for _ in 0..<120 { frame() }
        let away = driver.playerPosition - (driver.cueBall?.position ?? .zero)
        print(String(format: "  cue laid: the player stands %.0f mm from the ball (the standing stand-off is %.0f), clear: %@",
                     away.length, PlayerCamera.Preset.standing.standOff,
                     (PlayerWalk.isClearOfTheTable(driver.playerPosition) ? "yes" : "NO") as NSString))

        // Down on the shot over the middle of the table: the camera stays exactly above the line of the
        // cue, and comes no further inside the table than the eye-to-waist reach would let a player lean.
        // A fresh frame first, and the ball put down in the D, so that the driver is at the table rather
        // than waiting to place: then the cue ball can be put in the middle for the shot.
        driver.newFrame(startingPlayer: 0)
        _ = driver.placeCueBall(at: Vec2(Table.baulkLineX - 100, Table.centreY))
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.ballOn = .red
            state.ballPositions[BallID.cue] = Vec2(Table.length / 2, Table.centreY)
            state.ballPositions[BallID.firstRed] = Vec2(200, Table.centreY)
            state.cueBallInHand = false
            state.pending = nil
        }
        driver.syncWorldFromState()
        driver.aimAngle = 0
        table.holdFraming(.sighting)
        for _ in 0..<120 { frame() }
        table.holdFraming(nil)
        let aim = Vec2(cos(driver.aimAngle), sin(driver.aimAngle))
        let toTheBall = (driver.cueBall?.position ?? .zero) - table.cameraOnTheTable.position
        let offTheLine = (toTheBall - aim * toTheBall.dot(aim)).length
        let eye = table.cameraOnTheTable.position
        let inside = min(eye.x, Table.length - eye.x, eye.y, Table.width - eye.y)
        print(String(format: "  down on the shot over the middle: camera %.3f mm off the line of the cue, %.0f mm inside the side (the reach is %.0f), eye %.0f mm up",
                     offTheLine, inside, PlayerWalk.leanReach, table.cameraOnTheTable.height))
        driver.cancelCueAction()

        table.withCamera(simd_float3(0, 1.55, 0.35), lookingAt: simd_float3(-0.55, 0.02, 0), fieldOfView: 30) {
            print("  16: \(write(table.renderImage(size: size, device: device), name: "16-cue-on-the-ball", into: directory))")
        }

        // The same side spin, played towards either end: the tip has to be on the striker's right
        // whichever way they are facing, so it changes side on the table's own axes with the shot.
        driver.spinVertical = 0
        driver.spinSide = 0.5
        for (yaw, what) in [(0.0, "towards the top cushion"), (Double.pi, "towards the baulk cushion")] {
            driver.aimAngle = yaw
            for _ in 0..<20 { frame() }
            let aim = Vec2(cos(yaw), sin(yaw))
            let right = Vec2(aim.y, -aim.x)
            let wanted = driver.spinSide * Table.ballRadius
            print(String(format: "  side spin, %@: tip %+5.1f mm to the striker's right (table x %+5.1f, y %+5.1f), wanted %+5.1f",
                         what as NSString, table.cueTipWorldOffset.dot(right),
                         table.cueTipWorldOffset.x, table.cueTipWorldOffset.y, wanted))
        }

        // Strength: how fast the mouse has to move to make a shot. The cue's speed is the mouse's
        // travel times the mapping, divided by the time the frame took.
        func strikeWithAFlickOf(_ points: Double) -> (cue: Double, ball: Double) {
            let scene = TableScene(size: size)
            scene.table3D = table
            let view = SKView(frame: NSRect(origin: .zero, size: size))
            view.presentScene(scene)
            scene.controller.game.withState { state in
                state.ballsOnTable = [BallID.cue, BallID.firstRed]
                state.redsRemaining = 1
                state.ballOn = .red
                state.cueBallInHand = true
                state.pending = .placeCueBallInD
                state.ballPositions[BallID.cue] = Vec2(600, 889)
                state.ballPositions[BallID.firstRed] = Vec2(2200, 889)
            }
            scene.controller.syncWorldFromState()
            // Placing the ball is what puts the driver at the table, ready to strike.
            _ = scene.controller.placeCueBall(at: Vec2(600, 889))
            table.holdFraming(.sighting)
            var clock = CACurrentMediaTime()
            func frame() { clock += 1.0 / 60; scene.update(clock) }
            scene.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                                 timestamp: 0, windowNumber: 0, context: nil,
                                                 characters: "s", charactersIgnoringModifiers: "s",
                                                 isARepeat: false, keyCode: 0)!)
            // Draw the cue back over half a second, then flick it through in one frame.
            var x = 0.0, y = 0.0
            func steer(_ dx: Double, _ dy: Double) {
                x += dx; y += dy
                scene.steer(at: CGPoint(x: size.width / 2 + x, y: size.height / 2 + y), flags: [])
            }
            for _ in 0..<6 {
                steer(0, -20)
                frame()
            }
            steer(0, 130 * points / 40)
            frame()
            scene.keyUp(with: NSEvent.keyEvent(with: .keyUp, location: .zero, modifierFlags: [],
                                               timestamp: 0, windowNumber: 0, context: nil,
                                               characters: "s", charactersIgnoringModifiers: "s",
                                               isARepeat: false, keyCode: 0)!)
            table.holdFraming(nil)
            return (scene.controller.lastStrikeCueSpeed, scene.controller.cueBall?.velocity.length ?? 0)
        }

        print("  strength, for a flick of 40 points in one frame (2400 points a second):")
        let flick = strikeWithAFlickOf(40)
        print(String(format: "    cue travelling at %.0f mm/s, ball away at %.0f mm/s", flick.cue, flick.ball))
        print(String(format: "    at the old mapping of 0.9 mm a point the same flick was %.0f mm/s of cue, a little over half power",
                     40.0 * 0.9 * 60))
    }

    /// Fine aiming while down on the shot: with S held the mouse draws the cue, but Shift gives it back
    /// to the aim, at the aim's fine setting.
    private static func fineAimProbe(_ table: Table3D) {
        let scene = TableScene(size: size)
        scene.table3D = table
        let driver = scene.controller
        table.holdFraming(nil)
        _ = driver.placeCueBall(at: Vec2(600, 889))
        var clock = CACurrentMediaTime()
        func frame() { clock += 1.0 / 60; scene.update(clock) }
        func key(_ character: String, down: Bool) -> NSEvent {
            NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [],
                             timestamp: 0, windowNumber: 0, context: nil,
                             characters: character, charactersIgnoringModifiers: character,
                             isARepeat: false, keyCode: 0)!
        }
        var x = 0.0, y = 0.0
        func move(_ points: Double, shift: Bool, vertical: Double = 0) {
            var remaining = abs(points) + abs(vertical)
            while remaining > 0 {
                let step = min(10.0, remaining)
                x += points == 0 ? 0 : step * (points > 0 ? 1 : -1)
                y += vertical == 0 ? 0 : step * (vertical > 0 ? 1 : -1)
                remaining -= step
                scene.steer(at: CGPoint(x: size.width / 2 + x, y: size.height / 2 + y),
                            flags: shift ? [.shift] : [])
            }
        }
        func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

        print("fine aim probe (down on the shot with S held):")
        scene.keyDown(with: key("s", down: true))
        frame()
        print(String(format: "  S held: mode %@, aim %+.2f deg, cue %+.0f mm",
                     String(describing: driver.mode) as NSString, degrees(driver.aimAngle), driver.cueDraw))

        let aimBefore = driver.aimAngle
        let cueBefore = driver.cueDraw
        move(100, shift: false)
        frame()
        print(String(format: "  100 points right: aim %+.2f deg (was %+.2f), cue drawn %+.0f mm (was %+.0f)",
                     degrees(driver.aimAngle), degrees(aimBefore), driver.cueDraw, cueBefore))

        let aimMid = driver.aimAngle
        let cueAtMid = driver.cueDraw
        move(100, shift: true)
        frame()
        print(String(format: "  and with Shift: aim %+.2f deg (was %+.2f), cue %+.0f mm (was %+.0f)",
                     degrees(driver.aimAngle), degrees(aimMid), driver.cueDraw, cueAtMid))
        print(String(format: "  fine: %.3f degrees per point against %.3f with the cue in hand",
                     abs(degrees(driver.aimAngle - aimMid)) / 100,
                     abs(degrees(aimMid - aimBefore) / 100)))

        // Shift and S also look up and down: the same vertical movement the cue would use.
        let pitchBefore = degrees(table.pitch)
        move(0, shift: true, vertical: -60)
        frame()
        print(String(format: "  Shift and S, 60 points up: gaze %+.2f -> %+.2f deg, cue %+.0f mm",
                     pitchBefore, degrees(table.pitch), driver.cueDraw))

        // E takes the mouse for the tip on the ball, with S still held.
        let spinBefore = (driver.spinSide, driver.spinVertical)
        scene.keyDown(with: key("e", down: true))
        let cueBeforeSpin = driver.cueDraw
        move(60, shift: false, vertical: -40)
        frame()
        print(String(format: "  S and E, 60 right and 40 down: tip %+.2f right, %+.2f down (was %+.2f, %+.2f), cue %.0f mm (was %.0f)",
                     driver.spinSide, driver.spinVertical, spinBefore.0, spinBefore.1,
                     driver.cueDraw, cueBeforeSpin))
        scene.keyUp(with: key("e", down: false))
        scene.keyUp(with: key("s", down: false))
    }

    /// Where the player is standing, and what happens when they take the cue up and play: the camera
    /// is moved between standing at the table and down over the shot rather than snapped.
    private static func standingProbe(_ table: Table3D) {
        let scene = TableScene(size: size)
        scene.table3D = table
        let driver = scene.controller
        var clock = CACurrentMediaTime()
        func frame() { clock += 1.0 / 60; scene.update(clock) }
        func line(_ moment: String) {
            print(String(format: "  %-34@ eye %4.0f mm above the cloth, %@",
                         moment as NSString, table.eyeHeight, table.cameraLevel.title))
        }
        func key(_ character: String, down: Bool) -> NSEvent {
            NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero, modifierFlags: [],
                             timestamp: 0, windowNumber: 0, context: nil,
                             characters: character, charactersIgnoringModifiers: character,
                             isARepeat: false, keyCode: 0)!
        }

        print("standing probe:")
        table.holdFraming(nil)            // the captures pin the eye level; the game does not
        table.use(.standing)
        _ = driver.placeCueBall(at: Vec2(600, 889))
        for _ in 0..<60 { frame() }
        line("at the table:")

        scene.keyDown(with: key("s", down: true))
        for _ in 0..<30 { frame() }
        line("half a second after S:")

        scene.keyUp(with: key("s", down: false))
        for _ in 0..<60 { frame() }
        line("S let go without a shot:")

        driver.shoot(angle: 0, power: 0.5, side: 0, vertical: 0.4)
        for _ in 0..<20 { frame() }
        line("while the balls are running:")

        var waited = 0
        while driver.mode == .simulating, waited < 2400 { frame(); waited += 1 }
        for _ in 0..<60 { frame() }
        line("after they stop:")
    }

    /// The number keys for a colour, and P for picking the cue ball up again, driven through the
    /// scene's own key handler.
    private static func ballInHandProbe(_ table: Table3D) {
        let scene = TableScene(size: size)
        scene.table3D = table
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.presentScene(scene)
        let driver = scene.controller

        // The cue-ball widget is built when the scene goes into a view, where the HUD lives: the dashed
        // hairlines that cross at the middle of the ball are what tell the player where the middle is,
        // so the probe checks they are really there (a shape node with an empty path draws nothing).
        let widget = scene.spinWidgetParts
        print("  the cue-ball widget: \(widget.pieces) pieces, the dashed lines through the middle \(widget.hasTheMiddleLines ? "in place" : "WRONG: missing")")

        func press(_ key: String) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                               timestamp: 0, windowNumber: 0, context: nil,
                                               characters: key, charactersIgnoringModifiers: key,
                                               isARepeat: false, keyCode: 0) else { return }
            scene.keyDown(with: event)
        }

        print("ball in hand probe:")
        print("  the frame starts in hand: \(driver.canRepositionCueBall), mode \(driver.mode)")
        _ = driver.placeCueBall(at: Vec2(600, 889))
        print("  after placing it at (600, 889): mode \(driver.mode), may still move it \(driver.canRepositionCueBall)")
        press("p")
        print("  after pressing P: mode \(driver.mode), cue ball in hand \(driver.game.state.cueBallInHand)")
        _ = driver.placeCueBall(at: Vec2(700, 800))
        print("  put down again at \(driver.cueBall.map { "(\($0.position.x), \($0.position.y))" } ?? "—")")

        // The colour keys, in each of the ways a colour can be asked for.
        print("  colours on the table: \(driver.game.state.ballsOnTable.compactMap { BallID.colour(of: $0)?.rawValue }.sorted())")
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.yellow, BallID.green, BallID.brown, BallID.blue, BallID.pink]
            state.ballOn = .anyColour
            state.nominatedColour = nil
            state.pending = .nominateColour(options: [.yellow, .green, .brown, .blue, .pink])
        }
        driver.syncWorldFromState()
        press("5")
        print("  pressed 5 with the colours offered: nominated \(driver.nominatedColour?.rawValue ?? "nothing")")
        press("7")
        print("  pressed 7 with the Black off the table: nominated \(driver.nominatedColour?.rawValue ?? "nothing")")
        print("  and the eye level key still works: preset \(table.preset.rawValue)")

        driver.game.withState { state in
            state.pending = .nominateFreeBall(options: [.green, .blue, .pink])
        }
        driver.syncWorldFromState()
        press("6")
        print("  pressed 6 for a free ball: \(driver.game.state.freeBallNominee?.rawValue ?? "nothing")")

        // And **0** for no free ball: the keyboard's half of the No free ball button, which takes the offer
        // back and leaves the ball on to be played as it stands.
        driver.game.withState { state in
            state.freeBallNominee = .pink
            state.freeBallAvailable = true
            state.pending = .nominateFreeBall(options: [.green, .blue, .pink])
        }
        driver.syncWorldFromState()
        press("0")
        print("  pressed 0 for a free ball: nominee \(driver.game.state.freeBallNominee?.rawValue ?? "none"), "
              + "the offer taken back \(!driver.game.state.freeBallAvailable), pending \(String(describing: driver.pending))")
        let passesBefore = scene.keysPassedOn
        press("0")
        print("  pressed 0 with no free ball offered: \(scene.keysPassedOn - passesBefore) keys passed on to the system (wanted none)")
    }

    /// Whether the touching ball call reaches the screen: the referee's call, the label that carries
    /// it, and the ring round the ball it names (Rule 8).
    private static func touchingBallProbe(_ table: Table3D, device: MTLDevice, into directory: URL) {
        // Through the scene's own driver and its own view: the HUD is built when the scene is
        // presented, which is what puts the call on the screen.
        let scene = TableScene(size: size)
        scene.table3D = table
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.presentScene(scene)
        let driver = scene.controller
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
            state.redsRemaining = 1
            state.ballOn = .red
            state.cueBallInHand = false
            state.pending = nil
            state.ballPositions[BallID.cue] = Vec2(1784, 889)
            state.ballPositions[BallID.firstRed] = Vec2(1784 + Table.ballDiameter, 889)
            state.ballPositions[BallID.black] = Vec2(2500, 889)
        }
        driver.syncWorldFromState()
        for _ in 0..<10 {
            scene.update(0)
        }
        scene.refresh(force: true)

        print("touching ball probe (the cue ball resting against the red):")
        print("  touching by the engine \(driver.game.touchingBallsOn())")
        print("  the driver's call: \(driver.refereeCall ?? "—")")
        print("  on the screen:    \"\(scene.refereeCallOnScreen)\"")
        print("  rings shown on the table: \(table.touchingRingsShown) (\(table.touchingRingDiagnostics))")
        print("  the red's ball node: \(table.ballIsShown(BallID.firstRed))")
        print("  the cue's ball node: \(table.ballIsShown(BallID.cue))")

        // And where the ring falls: the cloth just outside the red should carry its amber. The balls
        // stay in the picture, since the ring hangs on the ball.
        // The capture a player sees: their own view of the table with the HUD over it, which is
        // where the call is written. Built exactly the way the harness builds its own HUD picture,
        // but from this scene, whose controller holds the touching state.
        table.use(.sighting)
        let captureView = SKView(frame: NSRect(origin: .zero, size: size))
        captureView.allowsTransparency = true
        let captureScene = TableScene(size: size)
        captureScene.scaleMode = .resizeFill
        captureScene.table3D = table
        captureView.presentScene(captureScene)
        let cueAt = Vec2(1784, 889)
        // 40 degrees off the line of aim, exactly a ball's diameter away.
        let restingAt = cueAt + Vec2(cos(40 * .pi / 180), sin(40 * .pi / 180)) * Table.ballDiameter
        captureScene.controller.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.black]
            state.redsRemaining = 1
            state.ballOn = .red
            state.cueBallInHand = false
            state.pending = nil
            state.ballPositions[BallID.cue] = cueAt
            state.ballPositions[BallID.firstRed] = restingAt
            state.ballPositions[BallID.black] = Vec2(2600, 1400)
        }
        captureScene.controller.syncWorldFromState()
        for _ in 0..<120 {
            captureScene.update(0)
            table.update(with: captureScene.controller, dt: 1.0 / 120.0)
        }
        captureScene.refresh(force: true)
        if let texture = captureView.texture(from: captureScene) {
            let hud = NSImage(cgImage: texture.cgImage(), size: size)
            let canvas = NSImage(size: size)
            canvas.lockFocus()
            table.renderImage(size: size, device: device).draw(in: NSRect(origin: .zero, size: size))
            hud.draw(in: NSRect(origin: .zero, size: size))
            canvas.unlockFocus()
            print("  14: \(write(canvas, name: "14-touching-ball-from-the-player", into: directory))")
        }

        // Everything inside the closure: the projection only means anything while the camera really is
        // overhead, and the ring hangs on the ball, so the balls stay in the picture.
        let redAt = Vec2(1784 + Table.ballDiameter, 889)
        // A camera straight above, but without the harness's habit of hiding the balls: the ring
        // hangs on a ball, so the balls have to be in the picture.
        // Below the plates, since those are between a high camera and the table.
        table.withCamera(simd_float3(0, 1.6, 0),
                         lookingAt: simd_float3(0, 0, 0),
                         fieldOfView: 34) {
            let image = table.renderImage(size: size, device: device)
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
            for distance in [26.0, 36.0, 42.0, 60.0] {
                let point = Vec2(redAt.x + distance, redAt.y)
                guard let p = table.project(Table3D.scenePoint(point), imageSize: size) else { continue }
                let c = sample(rep, Int(p.x), Int(p.y))
                print(String(format: "  %2.0f mm out from the red: #%02x%02x%02x%@",
                             distance, Int(c.r * 255), Int(c.g * 255), Int(c.b * 255),
                             (c.r > 0.7 && c.g > 0.55 && c.b < 0.4) ? "  ← the ring" : ""))
            }
            print("  wrote \(write(image, name: "15-touching-ball-from-above", into: directory))")

            // And a map of the ball with the cloth around it: the ring should show as a band.
            let ramp = Array(" .:-=+*#%@")
            print("  the red and the cloth around it, with a ring expected:")
            for row in stride(from: -70.0, through: 70.0, by: 7) {
                var line = "  |"
                for column in stride(from: -70.0, through: 70.0, by: 3.5) {
                    let point = Vec2(redAt.x + column, redAt.y + row)
                    guard let p = table.project(Table3D.scenePoint(point), imageSize: size) else { line.append(" "); continue }
                    let c = sample(rep, Int(p.x), Int(p.y))
                    let level = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
                    line.append(ramp[min(ramp.count - 1, max(0, Int(level * Double(ramp.count) * 1.1)))])
                }
                print(line + "|")
            }
        }
    }

    /// Which lights actually reach the ball. Each light in the scene is switched off in turn and the
    /// ball rendered again: a light that changes nothing on the ball is not reaching it, whatever the
    /// scene says is there.
    private static func lightContributionProbe(_ table: Table3D, device: MTLDevice) {
        let driver = FrameDriver()
        let ballAt = Table.blueSpot
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue]
            state.ballPositions = [BallID.cue: ballAt]
        }
        driver.syncWorldFromState()
        for _ in 0..<60 {
            table.update(with: driver, dt: 1.0 / 120.0)
        }
        let centre = Table3D.scenePoint(ballAt, height: Table.ballRadius)

        /// The ball's disc, rendered from close by.
        func render() -> (NSBitmapImageRep, CGRect)? {
            table.withCamera(simd_float3(centre.x, centre.y + 0.01, centre.z + 0.13),
                             lookingAt: centre,
                             fieldOfView: 40) {
                table.withBallsOnly {
                    let image = table.renderImage(size: size, device: device)
                    guard let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff) else { return nil }
                    // The box the ball covers on screen, from its centre and its radius.
                    let radius = Float(Table.ballRadius) / 1000
                    var low = CGPoint(x: CGFloat.greatestFiniteMagnitude,
                                      y: CGFloat.greatestFiniteMagnitude)
                    var high = CGPoint(x: -CGFloat.greatestFiniteMagnitude,
                                       y: -CGFloat.greatestFiniteMagnitude)
                    for dx in [-radius, radius] {
                        for dy in [-radius, radius] {
                            guard let p = table.project(centre + simd_float3(dx, dy, 0), imageSize: size) else { continue }
                            low.x = min(low.x, p.x); low.y = min(low.y, p.y)
                            high.x = max(high.x, p.x); high.y = max(high.y, p.y)
                        }
                    }
                    return (rep, CGRect(x: low.x, y: low.y, width: high.x - low.x, height: high.y - low.y))
                }
            }
        }

        guard let (baseline, box) = render() else { return }
        print("which lights reach the ball (the ball covers \(Int(box.width))x\(Int(box.height)) pixels):")
        for (index, light) in table.sceneLights.enumerated() {
            let was = light.intensity
            light.intensity = 0
            let without = render()
            light.intensity = was
            guard let (other, _) = without else { continue }
            var biggest = 0.0, samples = 0, changed = 0
            for y in stride(from: Int(box.minY), to: Int(box.maxY), by: 2) {
                for x in stride(from: Int(box.minX), to: Int(box.maxX), by: 2) {
                    guard x >= 0, y >= 0, x < baseline.pixelsWide, y < baseline.pixelsHigh,
                          let a = baseline.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                          let b = other.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let difference = (abs(Double(a.redComponent) - Double(b.redComponent))
                                      + abs(Double(a.greenComponent) - Double(b.greenComponent))
                                      + abs(Double(a.blueComponent) - Double(b.blueComponent))) / 3
                    biggest = max(biggest, difference)
                    if difference > 0.02 { changed += 1 }
                    samples += 1
                }
            }
            let share = samples > 0 ? 100 * Double(changed) / Double(samples) : 0
            print(String(format: "  light %2d (%@): changes the ball by up to %.3f, over %.1f%% of it",
                         index, String(describing: light.type.rawValue) as NSString, biggest, share))
        }
    }

    /// What a ball reflects. The cue ball is looked at from close by and sampled across its face:
    /// with its surroundings reflected it takes the colour of the lit cloth below it and the dark of
    /// the room at its edges, rather than being one flat colour all the way across.
    private static func ballReflectionProbe(_ table: Table3D, device: MTLDevice, into directory: URL) {
        let driver = FrameDriver()
        let ballAt = Table.blueSpot
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue]
            // Only this ball exists at all: a ball that is merely off the table is still drawn while
            // it drops into a pocket, and the samples would land on it instead.
            state.ballPositions = [BallID.cue: ballAt]
        }
        driver.syncWorldFromState()
        for _ in 0..<60 {
            table.update(with: driver, dt: 1.0 / 120.0)
        }

        // The middle of the ball, not the cloth under it: the offsets below are across its face.
        let centre = Table3D.scenePoint(ballAt, height: Table.ballRadius)

        /// The colour of the ball at a point on its face: offsets are fractions of its radius, with
        /// `across` to the right and `up` above its middle.
        func face(_ label: String, across: Float, up: Float, in rep: NSBitmapImageRep) -> String {
            let radius = Float(Table.ballRadius) / 1000
            let point = centre + simd_float3(across * radius, up * radius, 0)
            guard let s = table.project(point, imageSize: size) else { return "  \(label): off screen" }
            let c = sample(rep, Int(s.x), Int(s.y))
            return String(format: "  %-12@ #%02x%02x%02x", label as NSString,
                          Int(c.r * 255), Int(c.g * 255), Int(c.b * 255))
        }

        func readings() -> [String] {
            table.withCamera(simd_float3(centre.x, 0.10, centre.z + 0.33),
                             lookingAt: centre,
                             fieldOfView: 40) {
                // The ball on its own: the cue stands right behind it and would be what the samples
                // landed on otherwise.
                table.withBallsOnly {
                    let image = table.renderImage(size: size, device: device)
                    guard let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff) else { return [] }
                    describe(rep, name: "the cue ball, up close")
                    return [face("middle", across: 0, up: 0, in: rep),
                            face("left side", across: -0.6, up: 0, in: rep),
                            face("right side", across: 0.6, up: 0, in: rep),
                            face("lower half", across: 0, up: -0.6, in: rep),
                            face("upper half", across: 0, up: 0.6, in: rep)]
                }
            }
        }

        /// A fine scan across the ball's face, as a brightness ramp: the plates overhead should show
        /// up as separate bands of light rather than one wash.
        func scan(vertical: Bool) -> String {
            table.withCamera(simd_float3(centre.x, 0.10, centre.z + 0.33),
                             lookingAt: centre,
                             fieldOfView: 40) {
                table.withBallsOnly {
                    let image = table.renderImage(size: size, device: device)
                    guard let tiff = image.tiffRepresentation,
                          let rep = NSBitmapImageRep(data: tiff) else { return "" }
                    let ramp = Array(" .:-=+*#%@")
                    let radius = Float(Table.ballRadius) / 1000
                    return String((0..<24).map { step -> Character in
                        let fraction = Float(step) / 23 * 1.8 - 0.9
                        let point = centre + (vertical
                            ? simd_float3(0, fraction * radius, 0)
                            : simd_float3(fraction * radius, 0, 0))
                        guard let s = table.project(point, imageSize: size) else { return "?" }
                        let c = sample(rep, Int(s.x), Int(s.y))
                        let level = 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
                        return ramp[min(ramp.count - 1, max(0, Int(level * Double(ramp.count))))]
                    })
                }
            }
        }

        print("lights in the scene:")
        for light in table.lightInventory {
            print(String(format: "  %-9@ at (%6.2f, %6.2f, %6.2f) m, intensity %8.1f%@",
                         light.kind as NSString,
                         Double(light.position.x), Double(light.position.y), Double(light.position.z),
                         light.intensity, light.castsShadow ? ", casts a shadow" : ""))
        }
        print("ball reflection probe (the cue ball, up close)")
        print("  ball material: \(table.ballReflectionDescription)")
        for face in table.capturedSurroundings {
            print(String(format: "  captured %-18@ mean #%02x%02x%02x, %d bands across, %d down",
                         face.name as NSString,
                         Int(face.mean.0 * 255), Int(face.mean.1 * 255), Int(face.mean.2 * 255),
                         face.brightBandsAcross, face.brightBandsDown))
        }
        print("  the face that should hold the lamps — the ring round the table and the four over it:")
        for line in table.capturedFaceMap(2) { print(line) }
        print("  down the ball's face:  |\(String(scan(vertical: true)))|")
        print("  across the ball's face:|\(String(scan(vertical: false)))|")
        if let surroundings = table.capturedSurroundingsImage {
            _ = write(surroundings, name: "12-what-the-balls-reflect", into: directory)
        }
        print("  reflecting its surroundings:")
        for line in readings() { print(line) }
        table.ballsReflectSurroundings = false
        print("  with no reflection:")
        for line in readings() { print(line) }
        table.ballsReflectSurroundings = true

        // And the view the player actually has of the ball: standing behind it, down on the shot.
        table.use(.sighting)
        for _ in 0..<240 {
            table.update(with: driver, dt: 1.0 / 120.0)
        }
        // Very close, so that the reflections of the plates can be counted.
        table.withCamera(simd_float3(centre.x, centre.y + 0.01, centre.z + 0.13),
                         lookingAt: centre,
                         fieldOfView: 40) {
            table.withBallsOnly {
                let image = table.renderImage(size: size, device: device)
                _ = write(image, name: "13-the-cue-ball-up-close", into: directory)
                guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
                describe(rep, name: "the cue ball right up close")
            }
        }
        table.withBallsOnly {
            let image = table.renderImage(size: size, device: device)
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
            describe(rep, name: "the cue ball in the player's view")
        }
        table.use(.sighting)
    }

    /// The cue's own shadow on the cloth, which is the hardest thing on the table to cast.
    ///
    /// The cue is 9.8 mm across at the tip and 22 mm at the butt, and the four lamps over the corner
    /// pockets cast from 2.2 m with a 120° cone each, so one texel of their shadow map stands for 3.7 mm
    /// of cloth at `Table3D.cornerShadowMapSize` (7.4 mm when the map was 1024). A shadow narrower than
    /// the texels it is drawn in can only come out as a staircase, which is what the eye reads along the
    /// cue: this measures it. Two renders are taken, with the lights casting and not, and the difference
    /// between them **is** the shadow — how deep it comes out, how it falls away, and how far the centre
    /// of one strip of it wanders from the straight line it should lie on.
    private static func cueShadowProbe(_ table: Table3D, device: MTLDevice, into directory: URL) {
        print("cue shadow probe (the cue over the cloth, from the player's own view)")
        let driver = FrameDriver()
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue]
            state.ballPositions[BallID.cue] = Vec2(Table.length / 2, Table.centreY)
            state.cueBallInHand = false
            state.pending = nil
        }
        driver.syncWorldFromState()
        driver.aimAngle = 0                       // up the table: the cue runs away up the picture
        table.use(.sighting)
        for _ in 0..<240 { table.update(with: driver, dt: 1.0 / 120.0) }

        func levels(withShadows: Bool) -> [[Double]] {
            table.lightsCastShadows = withShadows
            let image = table.renderImage(size: size, device: device)
            write(image, name: withShadows ? "31-cue-shadow" : "32-cue-shadow-none", into: directory)
            guard let tiff = image.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff) else { return [] }
            return (0..<rep.pixelsHigh).map { y in
                (0..<rep.pixelsWide).map { x in luminance(sample(rep, x, y)) }
            }
        }

        let lit = levels(withShadows: true)
        let unlit = levels(withShadows: false)
        table.lightsCastShadows = true
        guard lit.count == unlit.count, let width = lit.first?.count, width > 0 else { return }
        // The shadow, as the light it takes away: positive where the shadow falls, times 255 so the
        // figures are the levels of the picture of a PNG.
        let shadow = zip(unlit, lit).map { row in zip(row.0, row.1).map { ($0 - $1) * 255 } }

        // The cue runs up the middle of the player's own view, so the shadow lies within a hand's width
        // of the middle column, in the lower part of the frame where the cue is at the table.
        let middle = width / 2
        let columns = (middle - 60)...(middle + 60)
        let rows = (lit.count / 2)..<(lit.count - 20)
        func deepestColumn(_ row: Int) -> Int {
            columns.max { shadow[row][$0] < shadow[row][$1] } ?? middle
        }
        let peakRow = rows.max { row, other in
            shadow[row][deepestColumn(row)] < shadow[other][deepestColumn(other)]
        } ?? rows.lowerBound
        let peakColumn = deepestColumn(peakRow)
        let peak = shadow[peakRow][peakColumn]
        // How wide the shadow comes out: the columns of a row that are carrying half the peak or more.
        let acrossHalfWidth = columns.filter { shadow[peakRow][$0] > peak / 2 }.count

        // Which strip to follow. The cue's shadow is **two** strips, not one: the lamps are at the four
        // corners, and a lamp casts the cue's shadow away from itself, so the two lamps at one end of the
        // table throw it onto one side of the cue and the two at the other end onto the other, with the
        // cloth showing between them. The deeper of the two at the row nearest the eye is followed, and
        // only on its own side of the cue, so the tracker cannot wander onto the other strip.
        let nearRow = rows.upperBound - 1
        let leftPeak = (columns.filter { $0 < middle }).max { shadow[nearRow][$0] < shadow[nearRow][$1] } ?? middle
        let rightPeak = (columns.filter { $0 > middle }).max { shadow[nearRow][$0] < shadow[nearRow][$1] } ?? middle
        let onTheRight = shadow[nearRow][rightPeak] >= shadow[nearRow][leftPeak]
        let search = onTheRight ? (middle + 2)...columns.upperBound : columns.lowerBound...(middle - 2)

        // And how straight the strip comes out: its **centre**, row by row, as the shadow-weighted
        // column of the row. An edge tracker would flip between the two edges of the strip; the centre
        // cannot. The strip is straight and so is its shadow, so the centres should lie on one line —
        // and a strip drawn in texels several pixels wide leaves that line in steps as the quantisation
        // shifts, where a strip drawn smoothly stays on it.
        var centres: [(row: Int, column: Double)] = []
        for row in rows {
            var total = 0.0, weighted = 0.0
            for column in search {
                let depth = max(0, shadow[row][column])
                total += depth
                weighted += depth * Double(column)
            }
            if total > 1 { centres.append((row, weighted / total)) }
        }
        // The line the centres should lie on — the strip is straight, and so is the shadow of a straight
        // thing — and how far they wander from it.
        let n = Double(centres.count)
        let sumRow = centres.reduce(0.0) { $0 + Double($1.row) }
        let sumColumn = centres.reduce(0.0) { $0 + $1.column }
        let sumRowColumn = centres.reduce(0.0) { $0 + Double($1.row) * $1.column }
        let sumRowSquared = centres.reduce(0.0) { $0 + Double($1.row) * Double($1.row) }
        let denominator = n * sumRowSquared - sumRow * sumRow
        let gradient = abs(denominator) > 1e-9 ? (n * sumRowColumn - sumRow * sumColumn) / denominator : 0
        let intercept = n > 0 ? (sumColumn - gradient * sumRow) / n : 0
        let residuals = centres.map { $0.column - (intercept + gradient * Double($0.row)) }
        let wander = n > 0 ? (residuals.map { $0 * $0 }.reduce(0, +) / n).squareRoot() : 0
        let steps = zip(centres, centres.dropFirst()).map { abs($1.column - $0.column) }

        // The same difference measured on a patch of cloth well clear of the cue: the shadow is all the
        // difference there should be between the two renders, so this is the noise the measure has to
        // beat — and a shadow that were not there at all would read like this.
        var farTotal = 0.0, farCount = 0.0
        for row in rows {
            for column in 40..<200 {
                farTotal += shadow[row][column]
                farCount += 1
            }
        }
        let farMean = farCount > 0 ? farTotal / farCount : 0

        print(String(format: "  the shadow at its darkest: %.2f levels of 255 in column %d (row %d), and %d columns of the row carry half of that or more",
                     peak, peakColumn, peakRow, acrossHalfWidth))
        let ramp = Array(" .:-=+*#%@")
        func line(_ values: [Double], scale: Double) -> String {
            String(values.map { value -> Character in
                let level = Int((value / max(scale, 1e-9) * Double(ramp.count - 1)).rounded())
                return ramp[min(ramp.count - 1, max(0, level))]
            })
        }
        // Drawn against a **fixed** scale of thirty levels of the 255, so that the shape of the shadow —
        // how deep it is and how its edge falls away — can be read the same way from one run to the next
        // as the shadow is tuned. See `Table3D.shadowDepth` and `shadowRadius`.
        print("  across it, columns \(columns.lowerBound) to \(columns.upperBound), thirty levels to the top of the ramp: |\(line(columns.map { shadow[peakRow][$0] }, scale: 30))|")
        print(String(format: "  along it, the %@ strip: its centre wanders %.2f pixels off the straight line it should lie on (worst step %.2f of a pixel from one row to the next), over %d rows",
                     (onTheRight ? "right-hand" : "left-hand") as NSString, wander, steps.max() ?? 0, centres.count))
        print(String(format: "  and the same difference over a patch of cloth clear of the cue: %.3f levels on average", farMean))
        let footprint = 2 * TableLightRig.heightAboveCloth * tan(60 * .pi / 180)
        print(String(format: "  (a shadow map of %.0f over the lamps' 120° cone at %.1f m puts one texel on %.2f mm of cloth; the cue is 9.8 mm across at the tip)",
                     Double(Table3D.cornerShadowMapSize), TableLightRig.heightAboveCloth / 1000,
                     footprint / Double(Table3D.cornerShadowMapSize)))
    }

    /// What the lights are worth under a ball: a ball on the cloth is looked at from close by and low
    /// down, and the cloth at its foot is compared with the cloth further off — once with the lights
    /// casting shadows and once without them.
    private static func shadowProbe(_ table: Table3D, device: MTLDevice) {
        let driver = FrameDriver()
        let ballAt = Table.blueSpot
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.black]
            // Only these two balls exist at all: a ball that is merely off the table is still drawn
            // while it drops into a pocket, and the samples could land on one of those instead.
            state.ballPositions = [BallID.cue: ballAt,
                                   BallID.black: Vec2(ballAt.x + 1400, ballAt.y)]
        }
        driver.syncWorldFromState()
        for _ in 0..<60 {
            table.update(with: driver, dt: 1.0 / 120.0)
        }

        // Looking at the ball from the near side of the table, low down, so that the cloth at its
        // foot is in view rather than hidden behind the ball. The readout runs outward from the ball.
        let centre = Table3D.scenePoint(ballAt)
        func readings() -> [String] {
            // Everything has to happen inside the closure: the projection only means anything while
            // the camera really is down beside the ball.
            table.withCamera(simd_float3(centre.x, 0.19, centre.z + 0.42),
                             lookingAt: centre,
                             fieldOfView: 48) {
                let image = table.renderImage(size: size, device: device)
                guard let tiff = image.tiffRepresentation,
                      let rep = NSBitmapImageRep(data: tiff) else { return [] }
                return [28.0, 31.0, 36.0, 45.0, 400.0].compactMap { distance in
                    // On the cloth, towards the camera, so nothing of the ball stands in the way.
                    let point = Vec2(ballAt.x, ballAt.y - distance)
                    guard let s = table.project(Table3D.scenePoint(point),
                                                imageSize: size) else { return nil }
                    let c = sample(rep, Int(s.x), Int(s.y))
                    return String(format: "  %4.0f mm from the ball: #%02x%02x%02x",
                                  distance, Int(c.r * 255), Int(c.g * 255), Int(c.b * 255))
                }
            }
        }

        print("shadow probe (a ball on the cloth, looked at from the side)")
        print("  with the plates casting shadows:")
        for line in readings() { print(line) }
        table.lightsCastShadows = false
        print("  with no shadows cast:")
        for line in readings() { print(line) }
        table.lightsCastShadows = true
    }

    /// The fixture itself, from two places the player never stands: underneath it looking up, where
    /// the three plates and the gaps between them should show, and off the end of the table looking
    /// along it, where the plates on the long sides should be seen turned down towards the cloth.
    private static func lightRigProbe(_ table: Table3D, device: MTLDevice, into directory: URL) {
        print("light rig probe (three plates, one down each long side and one up the middle)")

        // What the renderer was actually given: the plate measurements come out in the picture too
        // small to count, so they are read back from the scene itself.
        for (index, plate) in table.placedPlates.enumerated() {
            let along = Double(plate.position.x) * 1000 + Table.length / 2
            let across = Table.width / 2 - Double(plate.position.z) * 1000
            // Which way the plate looks, across the table: the scene's `z` runs against the engine's
            // `y`, so this is the engine's `y` component of the plate's face — positive looking
            // towards the top side of the table. A plate hung off to one side that looks back the
            // other way is looking in at the table.
            let looksTowards = -Double(plate.normal.z)
            let toTheMiddle = (across - Table.width / 2) * looksTowards
            let leaning: String
            if plate.tiltDegrees < 0.05 {
                leaning = "not turned"
            } else {
                leaning = toTheMiddle < 0 ? "turned down, looking in at the table"
                                          : "turned down, looking away from the table"
            }
            print(String(format: "  plate %d: %4.0f x %3.0f mm at (%6.0f, %5.0f) mm, %.3f m up, %.1f deg %@",
                         index + 1,
                         plate.size.alongTable * 1000, plate.size.acrossTable * 1000,
                         along, across, Double(plate.position.y), plate.tiltDegrees, leaning as NSString))
        }

        var written: [String] = []
        let under = table.withCamera(simd_float3(0, 0.05, 0),
                                     lookingAt: simd_float3(0, 2.5, 0),
                                     fieldOfView: 84) {
            table.withTableOnly { table.renderImage(size: size, device: device) }
        }
        if let tiff = under.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            describe(rep, name: "the light rig from underneath")
        }
        written.append(write(under, name: "10-light-rig-from-underneath", into: directory))

        let endOn = table.withCamera(simd_float3(3.1, 0.15, 0),
                                     lookingAt: simd_float3(0, 2.35, 0),
                                     fieldOfView: 55) {
            table.withTableOnly { table.renderImage(size: size, device: device) }
        }
        if let tiff = endOn.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) {
            describe(rep, name: "the light rig from the baulk end")
        }
        written.append(write(endOn, name: "11-light-rig-from-the-baulk-end", into: directory))
        print(written.joined(separator: "\n"))
    }

    /// Prints where the mouse steers the player's eye, so the feel of the control can be checked
    /// without a window: the middle of the window looks at the middle of the table, and the edges
    /// look out along the cushions.
    private static func steerProbe() {
        let scene = TableScene(size: size)
        scene.table3D = Table3D()
        scene.controller.placeCueBall(at: Vec2(Table.baulkLineX, Table.centreY - 120))
        print("steer probe (cue ball in the D)")

        /// The pointer, kept as an offset from the middle of the window, so the probe's movements
        /// are one continuous sweep the way a hand's would be.
        var x = 0.0
        /// Moves the mouse in little steps and steers, the way a hand does.
        func move(_ points: Double, flags: NSEvent.ModifierFlags = []) {
            var remaining = abs(points)
            while remaining > 0 {
                let move = min(10.0, remaining) * (points > 0 ? 1 : -1)
                x += move
                remaining -= abs(move)
                scene.steer(at: CGPoint(x: size.width / 2 + x, y: size.height / 2), flags: flags)
            }
        }

        // Coming back to the middle of the window must leave the aim where it was: it is movement
        // that turns the player, so the pointer can be picked up and put down.
        let start = scene.controller.aimAngle * 180 / .pi
        move(300)
        let turned = scene.controller.aimAngle * 180 / .pi
        move(-300)
        let returned = scene.controller.aimAngle * 180 / .pi
        print(String(format: "  mouse 300 points right: aim %+.1f deg; then 300 points back to the middle: %+.1f deg (started at %+.1f)",
                     turned, returned, start))

        // Shift sights finely: a tenth of the travel per degree.
        let beforeFine = scene.controller.aimAngle * 180 / .pi
        move(100, flags: [.shift])
        print(String(format: "  100 points with Shift down (fine sighting): aim %+.2f deg, from %+.2f",
                     scene.controller.aimAngle * 180 / .pi, beforeFine))

        // And a full circle: another 2400 points of travel, in steps of ten, which is about two
        // window widths. Nothing stops it at the edge of the window, because the pointer is put
        // back in the middle as it gets there and the aim follows movement, not position.
        var laps = 0.0
        var last = scene.controller.aimAngle
        var travelled = 0.0
        for _ in 0..<240 {
            travelled += 10
            move(10)
            let now = scene.controller.aimAngle
            var step = now - last
            while step > .pi { step -= 2 * .pi }
            while step < -.pi { step += 2 * .pi }
            laps += step / (2 * .pi)
            last = now
        }
        print(String(format: "  %.0f points of travel turns the player through %.2f of a full circle, with nothing to stop it",
                     travelled, abs(laps)))

        // Up and down raises and lowers the gaze, within what a player can actually hold.
        let pitchBefore = (scene.table3D?.pitch ?? 0) * 180 / .pi
        scene.steer(at: CGPoint(x: size.width / 2 + x, y: size.height / 2 + 100), flags: [])
        print(String(format: "  mouse 100 points up: eye raised from %+.1f to %+.1f deg, and it stops at %+.1f",
                     pitchBefore, (scene.table3D?.pitch ?? 0) * 180 / .pi,
                     PlayerCamera.pitchRange.upperBound * 180 / .pi))

        // The control is the **mouse's own movement**, not the places the pointer is seen at — which is
        // what makes it safe to capture the mouse and leave the pointer out of it altogether. Two
        // events carrying the same travel turn the player by the same amount wherever the pointer is
        // seen: what the pointer does is none of the aim's business.
        var aimWas = scene.controller.aimAngle * 180 / .pi
        func turnForTenPoints(at place: CGPoint) -> Double {
            scene.steer(at: place, moved: CGPoint(x: 10, y: 0), flags: [])
            let now = scene.controller.aimAngle * 180 / .pi
            defer { aimWas = now }
            return now - aimWas
        }
        let travelling = turnForTenPoints(at: CGPoint(x: size.width / 2 + 400, y: size.height / 2))
        let putBack = turnForTenPoints(at: CGPoint(x: size.width / 2, y: size.height / 2))
        print(String(format: "  ten points of mouse travel turns %+.2f deg, and the same ten points with the pointer 400 points away turns %+.2f — %@",
                     travelling, putBack,
                     (abs(travelling - putBack) < 1e-9
                      ? "the pointer's place is not the control" : "WRONG: the pointer's place was used as control") as NSString))

        // **The mouse steers only while the pointer is hidden**, and **Control** is the tap that takes the
        // pointer into the player's hand and gives it back to the game. With the pointer out, the mouse
        // steers nothing at all.
        func tapOption() {
            for flags: NSEvent.ModifierFlags in [[], [.control]] {
                guard let event = NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: flags,
                                                   timestamp: 0, windowNumber: 0, context: nil,
                                                   characters: "", charactersIgnoringModifiers: "",
                                                   isARepeat: false, keyCode: 59) else { continue }
                scene.flagsChanged(with: event)
            }
        }
        let aimedAt = scene.controller.aimAngle * 180 / .pi
        tapOption()
        scene.steer(at: CGPoint(x: size.width / 2, y: size.height / 2), flags: [])
        scene.steer(at: CGPoint(x: size.width / 2 + 200, y: size.height / 2), flags: [])
        let withThePointerOut = scene.controller.aimAngle * 180 / .pi
        tapOption()
        scene.steer(at: CGPoint(x: size.width / 2 + 200, y: size.height / 2), flags: [])
        scene.steer(at: CGPoint(x: size.width / 2 + 400, y: size.height / 2), flags: [])
        let withTheMouseBack = scene.controller.aimAngle * 180 / .pi
        print(String(format: "  the pointer out (Control): 200 points of mouse turn the view %+.1f to %+.1f deg — %@; the mouse back (Control again): 200 points turn it %+.1f to %+.1f — %@",
                     aimedAt, withThePointerOut,
                     (abs(withThePointerOut - aimedAt) < 1e-9 ? "nothing at all, as it should be" : "WRONG: it steered anyway") as NSString,
                     withThePointerOut, withTheMouseBack,
                     (abs(withTheMouseBack - withThePointerOut) > 1 ? "the view turns again" : "WRONG: still nothing") as NSString))
    }

    /// Drives the E and S keys through the scene's real key and mouse handlers, so the two held-key
    /// controls can be checked without a window: E puts the mouse on the cue ball's face and leaves
    /// the aim alone, S puts it on the cue and plays the shot as the tip comes through the ball.
    private static func cueControlProbe() {
        let scene = TableScene(size: size)
        let table = Table3D()
        scene.table3D = table
        scene.controller.placeCueBall(at: Vec2(Table.baulkLineX, Table.centreY - 120))
        print("cue control probe (E and S keys)")

        func keyEvent(_ character: String, down: Bool, repeats: Bool = false) -> NSEvent {
            NSEvent.keyEvent(with: down ? .keyDown : .keyUp,
                             location: .zero,
                             modifierFlags: [],
                             timestamp: 0,
                             windowNumber: 0,
                             context: nil,
                             characters: character,
                             charactersIgnoringModifiers: character,
                             isARepeat: repeats,
                             keyCode: 0)!
        }

        /// The pointer, kept as an offset from the middle of the window, moved in little steps the
        /// way a hand moves it.
        var x = 0.0, y = 0.0
        func move(x dx: Double, y dy: Double) {
            let steps = max(1, Int((abs(dx) + abs(dy)) / 10))
            for _ in 0..<steps {
                x += dx / Double(steps)
                y += dy / Double(steps)
                scene.steer(at: CGPoint(x: size.width / 2 + x, y: size.height / 2 + y), flags: [])
            }
        }
        func degrees(_ radians: Double) -> Double { radians * 180 / .pi }

        // The frame loop is what turns the mouse's travel into a cue speed, and what eases the camera to
        // a new eye level, so the probe steps it the way the app does.
        var clock = CACurrentMediaTime()
        func frame() {
            clock += 1.0 / 60
            scene.update(clock)
        }

        // **Z** and **X**, up and about with the cue put away: Z puts the mouse on the player's legs, so the
        // same sweep that turned the view a moment ago now walks them and the look stays where it was; X
        // ducks the eye down over the cloth to the balls' own height, and standing up puts it back.
        _ = scene.controller.placeCueBall(at: Vec2(Table.baulkLineX, Table.centreY - 120))
        scene.controller.standUp()
        if scene.controller.cueHandling != .putAway { scene.controller.toggleCueHandling() }
        // Let the camera settle at the standing level first, so the crouch is measured from where the
        // player's eye actually is rather than from a camera that has not been placed yet.
        for _ in 0..<30 {
            frame()
            table.update(with: scene.controller, dt: 1.0 / 60)
        }
        let standingAt = scene.controller.playerPosition
        let lookBefore = degrees(scene.controller.aimAngle)
        let eyeBefore = table.eyeHeight
        scene.keyDown(with: keyEvent("z", down: true))
        move(x: 200, y: 0)
        let walked = scene.controller.playerPosition.distance(to: standingAt)
        for _ in 0..<10 {                            // frames for the camera to come along with them
            frame()
            table.update(with: scene.controller, dt: 1.0 / 60)
        }
        let eyeOverTheirFeet = table.cameraOnTheTable.position.distance(to: scene.controller.playerPosition)
        print(String(format: "  Z held at the table (%@, ball on %@, eye %.0f mm from their feet), 200 points of mouse to the right: the player walks %.0f mm across (%.0f mm a point) and the look stays at %+.1f deg — %@",
                     String(describing: scene.controller.mode) as NSString,
                     (scene.controller.cueBall?.onTable == true ? "yes" : "no") as NSString,
                     eyeOverTheirFeet,
                     walked, walked / 200, degrees(scene.controller.aimAngle),
                     (walked > 100 && abs(degrees(scene.controller.aimAngle) - lookBefore) < 1e-9
                      ? "the mouse is the player's legs, not their head"
                      : "WRONG: Z did not walk them, or the look moved") as NSString))
        scene.keyUp(with: keyEvent("z", down: false))
        scene.keyDown(with: keyEvent("x", down: true))
        for _ in 0..<60 {
            frame()
            table.update(with: scene.controller, dt: 1.0 / 60)
        }
        let crouched = table.eyeHeight
        scene.keyUp(with: keyEvent("x", down: false))
        for _ in 0..<60 {
            frame()
            table.update(with: scene.controller, dt: 1.0 / 60)
        }
        print(String(format: "  X held: the eye came down from %.0f mm to %.0f mm above the cloth, and standing up put it back at %.0f mm — %@",
                     eyeBefore, crouched, table.eyeHeight,
                     (abs(crouched - PlayerCamera.crouchEyeHeight) < 2 && abs(table.eyeHeight - eyeBefore) < 20
                      ? "crouched to the height it should, and back up"
                      : "WRONG: the crouch is not the height it should be, or it did not come back") as NSString))

        // Held down, a key repeats: the system sends the press again and again. The repeats carry nothing
        // new, but they must not fall through to the responder chain either — an event that does is an
        // event the system answers with a beep, so a held key beeps once per repeat for as long as it is
        // down. Both keys are held here, repeats and all, first where they are usable and then with the
        // cue laid where they do nothing, and the count of events passed on has to stay at nothing.
        let passedOnBefore = scene.keysPassedOn
        for _ in 0..<20 {
            scene.keyDown(with: keyEvent("z", down: true, repeats: true))
            scene.keyDown(with: keyEvent("x", down: true, repeats: true))
        }
        scene.keyUp(with: keyEvent("z", down: false))
        scene.keyUp(with: keyEvent("x", down: false))
        scene.controller.toggleCueHandling()             // the cue laid: Z and X have nothing to do
        for _ in 0..<20 {
            scene.keyDown(with: keyEvent("z", down: true, repeats: true))
            scene.keyDown(with: keyEvent("x", down: true, repeats: true))
        }
        scene.keyUp(with: keyEvent("z", down: false))
        scene.keyUp(with: keyEvent("x", down: false))
        print(String(format: "  Z and X held down with the keyboard's own repeat, up and about and again with the cue laid: %d of their events were passed on to the system — %@",
                     scene.keysPassedOn - passedOnBefore,
                     (scene.keysPassedOn == passedOnBefore
                      ? "none, so there is nothing for it to beep at"
                      : "WRONG: the system would be beeping at them") as NSString))
        // And a key the game does **not** define still goes through, which is the count being live rather
        // than a number that never moves: one press, one event, and the beep the system owes it.
        scene.keyDown(with: keyEvent("q", down: true))
        print(String(format: "  a key the game does not define (Q) is passed on, one event for one press — %@",
                     (scene.keysPassedOn == passedOnBefore + 1 ? "so the count is live" : "WRONG: nothing is being counted") as NSString))
        // E: the tip moves on the ball, and the aim stays exactly where it was.
        let aimBefore = degrees(scene.controller.aimAngle)
        scene.keyDown(with: keyEvent("e", down: true))
        move(x: 120, y: -80)
        print(String(format: "  E held, 120 points right and 80 down: tip %+.2f right, %+.2f down the ball; aim %+.1f -> %+.1f deg",
                     scene.controller.spinSide, scene.controller.spinVertical, aimBefore, degrees(scene.controller.aimAngle)))
        scene.keyUp(with: keyEvent("e", down: false))

        // Let go and the mouse is back on the aim.
        let aimHeld = degrees(scene.controller.aimAngle)
        move(x: 100, y: 0)
        print(String(format: "  E released, 100 points right: aim %+.1f -> %+.1f deg",
                     aimHeld, degrees(scene.controller.aimAngle)))

        // S: the cue is drawn back by the mouse and driven through the ball.
        frame()
        table.update(with: scene.controller, dt: 1.0 / 60)
        let gapAtRest = table.cueTipDistance
        scene.keyDown(with: keyEvent("s", down: true))
        print(String(format: "  S held: mode %@, cue tip %.1f mm from the ball",
                     String(describing: scene.controller.mode), table.cueTipDistance))

        // A slow draw back: 160 points of travel over four frames, so the cue crawls back.
        for _ in 0..<4 {
            move(x: 0, y: -40)
            frame()
        }
        print(String(format: "  160 points back over 4 frames: cue drawn %.0f mm, cue speed %.0f mm/s, tip %.1f mm from the ball (was %.1f)",
                     scene.controller.cueDraw, scene.controller.cueSpeed, table.cueTipDistance, gapAtRest))

        // Part of the way forward, still slow: nothing struck.
        for _ in 0..<2 {
            move(x: 0, y: 40)
            frame()
        }
        print(String(format: "  80 points forward, not through yet: cue %.0f mm back, mode %@",
                     scene.controller.cueDraw, String(describing: scene.controller.mode)))

        // One quick flick through the ball: 120 points in a single frame is the shot's strength.
        move(x: 0, y: 120)
        frame()
        table.update(with: scene.controller, dt: 1.0 / 60)
        let cueSpeed = scene.controller.lastStrikeCueSpeed
        let offset = scene.controller.tipOffset
        print(String(format: "  flicked through in one frame: mode %@, cue travelling at %.0f mm/s (the mouse's %.0f, capped), tip %.2f of a radius off centre",
                     String(describing: scene.controller.mode), cueSpeed, 120 * 0.9 * 60, offset))
        print(String(format: "  the physics sends the ball away at %.0f mm/s; a frame of cloth friction later it is at %.0f",
                     FrameDriver.ballSpeed(fromCueSpeed: cueSpeed, tipOffset: offset),
                     scene.controller.cueBall?.velocity.length ?? 0))
        scene.controller.runStrokeToRest()
        print(String(format: "  shot over: tip %.2f right, %.2f down the ball — reset to the middle for the next stroke",
                     scene.controller.spinSide, scene.controller.spinVertical))
    }

    /// Checks that clicking the cloth through the first-person camera lands where it should: each
    /// known spot is projected onto the screen and then cast back to the table.
    private static func clickProbe(_ table: Table3D) {
        let driver = FrameDriver()
        table.use(.standing)
        for _ in 0..<240 {
            table.update(with: driver, dt: 1.0 / 120.0)
        }
        print("click probe (cue ball in hand)")
        for spot in [Table.brownSpot, Table.yellowSpot, Table.greenSpot, Vec2(Table.baulkLineX - 150, Table.centreY)] {
            guard let screen = table.project(Table3D.scenePoint(spot), imageSize: size),
                  // `project` works in image coordinates (origin top left) and `tablePoint` in view
                  // coordinates (origin bottom left), so flip before casting back.
                  let back = table.tablePoint(at: CGPoint(x: screen.x, y: size.height - screen.y),
                                              viewSize: size) else {
                print("  \(spot) could not be cast")
                continue
            }
            print(String(format: "  table (%4.0f,%4.0f) -> screen (%4.0f,%4.0f) -> table (%4.0f,%4.0f)  off by %.2f mm",
                         spot.x, spot.y, screen.x, screen.y, back.x, back.y, back.distance(to: spot)))
        }
    }

    /// Checks the shape of the table itself: where the cloth stops, where the pockets are cut, and
    /// how far the wood wraps round each pocket.
    private static func geometryProbe(_ table: Table3D) {
        let L = Table.length, W = Table.width
        let cuts = Table3D.pocketCuts()
        let cloth = Table3D.clothPath(cuts)
        let rail = Table3D.railPath(cuts)
        let slate = Table3D.slatePath(cuts)
        let checks: [(String, NSBezierPath, Vec2, Bool)] = [
            ("cloth, middle of the table", cloth, Vec2(L / 2, W / 2), true),
            ("cloth, above a middle pocket", cloth, Vec2(L / 2, 40), true),
            // The bed runs on into each pocket's throat, and is cut away only at the hole: it goes
            // under the cushions and the rails, which stand over it.
            ("cloth, in the middle pocket's mouth", cloth, Vec2(L / 2, 20), true),
            ("cloth, in the middle pocket's throat", cloth, Vec2(L / 2, -20), false),
            ("cloth, on down to the hole", cloth, Vec2(L / 2, -70), false),
            ("cloth, outside the playing area", cloth, Vec2(-10, W / 2), true),
            ("cloth, beside the hole at a middle pocket", cloth, Vec2(L / 2 - 60, -10), true),
            ("cloth, under the cushion", cloth, Vec2(L * 0.4, -30), true),
            ("cloth, into the corner's throat", cloth, Vec2(20, 20), true),
            ("cloth, corner still there", cloth, Vec2(60, 60), true),
            ("cloth, up to the hole", cloth, Vec2(11, 11), true),
            ("cloth, at the hole", cloth, cuts[.bottomLeft]!.holeCentre, false),
            ("rail, round the outside of a corner pocket", rail, Vec2(-104, -104), true),
            ("rail, inside a corner pocket", rail, Vec2(-55, -30), false),
            // The wood at a corner is the crescent between the hole and the table's outer edge, which
            // is now a good deal thinner than it was: the hole takes the ground the jaws' feet stand
            // over, so the land left is the difference between the two circles.
            ("rail, round the corner of a corner pocket", rail, Vec2(-105, -105), true),
            ("rail, behind the cushion", rail, Vec2(-104, W / 2), true),
            ("rail, where the cushion is", rail, Vec2(-20, W / 2), false),
            // The wood begins exactly where the cushion's top ends, at the same height, so the join is
            // one line with nothing standing proud of it and no groove down it for cloth to show in.
            ("rail, behind the back of the cushion", rail,
             Vec2(L * 0.4, -(Table.cushionDepth + 1)), true),
            ("rail, right up to the back of the cushion", rail,
             Vec2(L * 0.4, -(Table.cushionDepth + 0.1)), true),
            ("rail, where the cushion's top is", rail,
             Vec2(L * 0.4, -(Table.cushionDepth - 0.1)), false),
            ("rail, in the playing area", rail, Vec2(L * 0.4, 5), false),
            // The same join at the ends of the table, where the cushion's outward runs the other way:
            // the line the wood stops at is the far side of the table, so a sign taken the wrong way
            // sends the wood's cut off to the wrong end of the table.
            ("rail, right up to the back of the top cushion", rail,
             Vec2(L * 0.4, W + Table.cushionDepth + 0.1), true),
            ("rail, where the top cushion's top is", rail,
             Vec2(L * 0.4, W + Table.cushionDepth - 0.1), false),
            ("rail, right up to the back of the right cushion", rail,
             Vec2(L + Table.cushionDepth + 0.1, W / 2), true),
            ("rail, where the right cushion's top is", rail,
             Vec2(L + Table.cushionDepth - 0.1, W / 2), false),
            // The throat of a corner pocket is cut out of the wood along the 45°, and the wood beside
            // it is left: the cut is the slot, not the circle through the same points.
            ("rail, in a corner pocket's throat", rail,
             cuts[.bottomLeft]!.mouth + cuts[.bottomLeft]!.axis * 40, false),
            ("rail, beside a corner pocket's throat", rail,
             cuts[.bottomLeft]!.holeCentre
                + cuts[.bottomLeft]!.axis.perpendicular * (cuts[.bottomLeft]!.holeRadius + 6), true),
            // And the same along the baulk cushion, which is a run of its own.
            ("rail, behind the baulk cushion", rail,
             Vec2(-(Table.cushionDepth + 1), W / 2), true),
            ("rail, in the baulk playing area", rail, Vec2(5, W / 2), false),
            ("rail, behind the top cushion", rail,
             Vec2(L * 0.4, W + Table.cushionDepth + 1), true),
            ("rail, in the top playing area", rail, Vec2(L * 0.4, W - 5), false),
            ("rail, behind the right cushion", rail,
             Vec2(L + Table.cushionDepth + 1, W / 2), true),
            ("rail, in the right playing area", rail, Vec2(L - 5, W / 2), false),
            ("rail, round the outside of a middle pocket", rail, Vec2(L / 2, -138), true),
            ("rail, inside a middle pocket", rail, Vec2(L / 2, -70), false),
            ("rail, inside a middle pocket's passage", rail, Vec2(L / 2 + 20, -60), false),
            ("rail, beside a middle pocket's passage", rail, Vec2(L / 2 + 60, -60), true),
            ("rail, past the outside edge", rail, Vec2(-170, W / 2), false),
            ("slate, middle of the table", slate, Vec2(L / 2, W / 2), true),
            ("slate, in the middle pocket's mouth", slate, Vec2(L / 2, 20), true),
            ("slate, inside a middle pocket", slate, Vec2(L / 2, -20), false),
            ("slate, under the rails", slate, Vec2(-100, W / 2), true),
            ("slate, corner cut away", slate, Vec2(-20, -20), false),
            ("slate, past the outside edge", slate, Vec2(-170, -170), false),
        ]
        print("geometry probe")
        // The cushion's side: how it leans to the cloth, how high the top of the undercut is, and how
        // far its foot is behind it. Above that the profile runs straight up: the band of cushion that
        // stands square on the nose.
        let profile = Table3D.cushionProfile
        let nose = profile[2], atTheCloth = profile[1]
        let capTop = profile[3], backTop = profile[4]
        let foot = nose.0 - atTheCloth.0        // positive: the foot is out of the playing area
        let cap = capTop.1 - nose.1
        let standsSquare = abs(capTop.0 - nose.0) < 1e-9 && abs(cap - Table3D.cushionCapAboveNose) < 1e-9
        print(String(format: "  the cushion: the top of the undercut at %.2f mm, side leaning %.1f° to the cloth, foot %.1f mm behind it, and %.2f mm of cushion above it standing %@ — square to the cloth, straight up the face",
                     nose.1, atan2(nose.1 - atTheCloth.1, foot) * 180 / .pi, foot, cap,
                     (standsSquare ? "square" : "WRONG: not square") as NSString))
        // The cushion's top, and the wood behind it: the wood's top is the same height as the
        // cushion's, and its edge lands on the line the cushion's top ends at, so the two meet on one
        // line — no step, nothing overlapping, and nothing for the eye to read as a seam.
        let levelTop = abs(backTop.1 - capTop.1) < 1e-9
        let theWoodStandsAt = Table3D.railHeightAboveCloth - Table3D.cushionTopAboveCloth
        let howTheWoodMeets = abs(theWoodStandsAt) < 1e-9 && abs(Table3D.railClearanceFromCushion) < 1e-9
            ? "the wood's top is level with it and its edge lands on the line the top ends at, so the join is one line"
            : String(format: "WRONG: the wood stands %.1f mm clear of the cushion's top and begins %.1f mm short of (or under) its back, so the join is two lines",
                     theWoodStandsAt, Table3D.railClearanceFromCushion)
        print(String(format: "  the cushion's top: %@ at %.2f mm from the nose back %.0f mm, where the wood stands at %.2f mm — %@",
                     (levelTop ? "level" : "WRONG: not level") as NSString, backTop.1, -backTop.0,
                     Table3D.railHeightAboveCloth, howTheWoodMeets as NSString))
        // The jaws: the lean their sides carry, which is the cushion's own undercut taken square to
        // the jaw's own foot, so it is the same 65° at a corner as at a middle pocket and the same
        // from the cushion's face to the wood. The foot is the jaw's outline carried inwards by the
        // undercut, and the hole is cut to meet it where it crosses the cloth.
        let jawHeight = Table3D.jawSideHeight
        func angle(_ setback: Double) -> Double { atan2(jawHeight, setback) * 180 / .pi }
        // The wood the rails are cut to round a pocket: a straight throat of the mouth's own width,
        // closed by the hole's semicircle, leaning outwards as it comes down at the cushion's own 65°
        // — the undercut a jaw carries — so that at the top of the wood the cut is the mouth's width
        // and at the level of the cloth it is the rim of the hole. That is what sets a jaw's face and
        // the wood's edge beside it on one leaning surface, instead of the wood standing square to the
        // cloth where the jaw leans away from it.
        let leanAngle = atan(Table3D.jawSideHeight / Table3D.jawFootSetback) * 180 / .pi
        let leanRate = Table3D.jawFootSetback / Table3D.jawSideHeight        // millimetres out per millimetre down
        for pocket in [PocketID.bottomLeft, .bottomMiddle] {
            let cut = cuts[pocket]!
            let slot = Table3D.pocketSlot(cut)
            let acrossTheTop = slot[1].point.distance(to: slot[slot.count - 2].point)
            let opening = slot[1].setback
            // The cut stands square up the cushion's own band, so it is the drop from the **nose** that
            // opens it out.
            let acrossAtTheCloth = acrossTheTop + 2 * Table3D.cushionNoseAboveCloth * leanRate
            // That line is the jaws' own: the mouth plus a jaw's setback on each side, which is where
            // the two feet stand. The hole is cut a clearance wider than it on each side, so the rim
            // runs just outside the feet.
            let theFeetStandOn = cut.width + 2 * Table.pocketHoleSetback
            let atTheFeet = abs(acrossAtTheCloth - theFeetStandOn)
            let clearance = (cut.holeRadius * 2 - theFeetStandOn) / 2
            // A corner's hole is cut wider again than a middle pocket's, so the clearance the rim
            // stands out past the feet is that much more.
            let expected = Table.pocketHoleClearance
                + (pocket.isCorner ? Table.cornerPocketHoleExtra / 2 : 0)
            let atTheClearance = abs(clearance - expected)
            print(String(format: "  the wood round the %@ pocket: the cut is the mouth's %.1f mm across at the top of the wood, leaning %.1f° to the cloth — the jaws' own undercut — and comes out %.1f mm on each side over the wood's depth, so that at the level of the cloth it is %.2f mm across: the line the two jaws' feet stand on, %@, with the hole cut %.2f mm wider again than that on each side, %@",
                         pocket.rawValue as NSString, acrossTheTop, leanAngle, opening,
                         acrossAtTheCloth,
                         (atTheFeet < 0.02 ? "to a fiftieth of a millimetre" : "WRONG") as NSString,
                         clearance,
                         (atTheClearance < 0.02 ? "clear of each foot, as the hole is cut" : "WRONG") as NSString))
        }
        // And the wood itself, as the renderer lays it down: one piece for each pocket, meeting along
        // straight cuts across the wood from the line the wood stops at to the table's own edge. The
        // pieces are what `railPath` is the sum of, so the checks above are checks of the pieces; what
        // they cannot say is that the pieces *meet* — a seam between two of them would be a strip of
        // nothing down the rail. Each cut is a ray from the middle of the table, so the wood either
        // side of it is probed a little off the line, at the middle of its length.
        let pieces = Table3D.railPieces(cuts)
        let middle = Vec2(Table.length / 2, Table.width / 2)
        var gaps = 0
        for piece in pieces {
            // The cut the piece opens on runs from the line the wood stops at out to the table's own
            // edge, both ends on one ray from the middle of the table.
            let inner = piece[0].point, outer = piece[piece.count - 1].point
            let ray = (inner - middle).normalized
            let halfway = middle + ray * ((inner - middle).length + (outer - middle).length) / 2
            for side in [1.0, -1.0] where !Table3D.contains(rail, halfway + ray.perpendicular * side * 25) {
                gaps += 1
            }
        }
        print(String(format: "  the wood of the rails: %d pieces, one for each pocket, meeting along straight cuts across the wood — %@",
                     pieces.count,
                     (gaps == 0 ? "the wood either side of every cut is wood, so the pieces meet and the rail reads as one rail"
                                : "WRONG: there is a gap along \(gaps) of the cuts") as NSString))
        // The round on the wood's own outer edge, read back off the mesh the rail was built into: the
        // frame's rim is a bull nose, taken off with a radius a good deal wider than a cushion's own
        // edges carry, so the wood's top comes in at the table's edge and runs back out to it below.
        if let rim = table.railEdgeProfile() {
            let wanted = Table3D.railOuterEdgeRound
            let rightRadius = abs(rim.radius - wanted) < 0.05
            let rightTop = abs(rim.inAtTheTop - wanted) < 0.05
            let squareAt = Table3D.railHeightAboveCloth - wanted
            let rightSquare = abs(rim.backToTheEdge - squareAt) < 0.05
            print(String(format: "  the round on the wood's outer edge: radius %.2f mm, the top coming in by %.2f mm and the round running down to the square side at %.2f mm — %@",
                         rim.radius, rim.inAtTheTop, rim.backToTheEdge,
                         ((rightRadius && rightTop && rightSquare)
                          ? "the frame's rim is a bull nose, round right round the table"
                          : "WRONG: the wood's outer edge is not taken off as asked") as NSString))
        }
        if let coverage = table.railOuterEdgeCoverage() {
            let whole = coverage.smallest > Table3D.railOuterEdgeRound - 0.5
            print(String(format: "  the round runs the whole way round the wood's outer edge: all %d of the %d pieces' points come in by at least %.2f mm at the top — %@",
                         coverage.points, coverage.pieces, coverage.smallest,
                         (whole ? "no stretch of the rim is left square"
                                : "WRONG: a stretch of the rim is left square") as NSString))
        }
        for seam in table.railSeamShading() {
            print(String(format: "  the join between the rail's piece %d and piece %d, at (%.0f,%.0f): their shading normals come out %.1f° apart — %@",
                         seam.join, (seam.join + 1) % 6, seam.plan.x, seam.plan.y, seam.degrees,
                         (seam.degrees < 5 ? "the reflection reads on across the join"
                                           : "WRONG: a step in the reflection at the join") as NSString))
        }
        for pocket in [PocketID.bottomLeft, .bottomMiddle] {
            let cut = cuts[pocket]!
            let jaw = cut.jaws.0
            let side = Table3D.jawSide(jaw)
            // Which entries of the side are the round: they are laid down first, and stand exactly a
            // radius off the jaw's axis.
            let middle = jaw.centre
                + (jaw.atTheFace - jaw.centre + jaw.atTheThroat - jaw.centre).normalized * jaw.radius
            let round = PocketCut.arcPoints(centre: jaw.centre, radius: jaw.radius,
                                            from: jaw.atTheFace, to: jaw.atTheThroat, through: middle)
            let onTheRound = zip(side, round).prefix { $0.point.distance(to: $1) < 1e-6 }.count
            let endOfTheRound = side[max(0, onTheRound - 1)]
            let atTheWood = side.count > 1 ? side[side.count - 2] : endOfTheRound
            let feet = side.map { $0.point + $0.back * $0.setback }
            let held = abs(angle(atTheWood.setback) - angle(side[0].setback)) < 0.05
            let howItRuns = held
                ? String(format: "the same %.1f° at the end of the round and the same again where it runs into the wood, so the side is one lean from the cushion to the rail",
                         angle(atTheWood.setback))
                : String(format: "WRONG: %.1f° where it leaves the face but %.1f° into the wood, so the side does not hold the cushion's lean",
                         angle(side[0].setback), angle(atTheWood.setback))
            // How far behind its nose the foot is, measured square to the jaw's own outline: the
            // cushion's own setback, on either kind of pocket.
            let acrossTheTable = PocketCut.outward(at: jaw.tip)
            let depthOfTheFoot = abs((side[0].point - feet[0]).dot(acrossTheTable))
            // And where the jaw's side crosses the level of the cloth: that is the line the hole's rim
            // would sit on if it were cut exactly to the foot, and the hole is cut a clearance past it.
            let across = (jaw.centre - jaw.atTheThroat).normalized
            let atTheCloth = jaw.atTheThroat
                + across * (Table3D.jawFootSetback * Table3D.cushionNoseAboveCloth / Table3D.jawSideHeight)
            let pastTheFoot = cut.holeRadius - abs((cut.holeCentre - atTheCloth).dot(across))
            let expected = Table.pocketHoleClearance
                + (pocket.isCorner ? Table.cornerPocketHoleExtra / 2 : 0)
            let atTheClearance = abs(pastTheFoot - expected)
            print(String(format: "  a jaw of the %@ pocket: %.1f° where it leaves the cushion's face, and %@; its foot is %.1f mm behind its nose, and the hole's rim stands %.2f mm outside the side where it crosses the cloth — %@",
                         pocket.rawValue as NSString, angle(side[0].setback), howItRuns as NSString,
                         depthOfTheFoot, pastTheFoot,
                         (atTheClearance < 0.02 ? "clear of the foot, as the hole is cut" : "WRONG") as NSString))
        }
        // A jaw and the run of cushion it was cut from are one surface: nothing is rounded between
        // them, and they neither overlap in a step nor leave a gap, so a ray straight down on to the
        // join finds the cushion's top at its full height on both sides of it. The samples straddle
        // the join at a middle pocket, and the join with the wood behind.
        var joins: [(String, Double)] = []
        for (name, spot) in [
            ("1 mm inside the run", Vec2(Table.length / 2 - Table.middleJawGap - 51, -20)),
            ("1 mm inside the jaw", Vec2(Table.length / 2 - Table.middleJawGap - 49, -20)),
            ("5 mm inside the jaw", Vec2(Table.length / 2 - Table.middleJawGap - 45, -20)),
            ("on the line the wood stops at", Vec2(1200, -Table.cushionDepth)),
            ("1 mm outside that line", Vec2(1200, -(Table.cushionDepth + 1))),
        ] {
            let from = Table3D.scenePoint(spot, height: 200)
            let to = Table3D.scenePoint(spot, height: -60)
            let hits = table.scene.rootNode.hitTestWithSegment(from: SCNVector3(from), to: SCNVector3(to), options: nil)
            joins.append((name, hits.first.map { Double($0.worldCoordinates.y) * 1000 } ?? -1))
        }
        let level = Table3D.cushionTopAboveCloth
        let ragged = joins.filter { abs($0.1 - level) > 0.05 }
        print(String(format: "  the join between a jaw and the run it was cut from, and the join with the wood: %@ — the top comes out at %.2f mm from %@",
                     (ragged.isEmpty ? "flush at every sample" : "WRONG: \(ragged.map(\.0))") as NSString,
                     level, joins.map { String(format: "%.2f", $0.1) }.joined(separator: ", ") as NSString))
        let solids = table.jawSolids()
        let triangles = Set(solids.map(\.triangles))
        let from = solids.map(\.from).min() ?? 0, to = solids.map(\.to).max() ?? 0
        print("  the jaw solids: \(solids.count) of them, \(triangles.count == 1 ? "\(triangles.first ?? 0)" : "\(triangles.sorted())") triangles each, sides running \(String(format: "%.1f", from))…\(String(format: "%.1f", to)) mm")
        // The leaning side of a jaw is shaded as the surface it is, not a facet at a time: one normal
        // to each step of the leaning band, shared by the quads either side, so the round is turned
        // through rather than creased. The one place it is meant to turn sharply is the nose, where
        // the leaning band meets the band standing square above it — and that is a step between the
        // two bands, not along this one.
        var shadingLines: [String] = []
        for shading in table.jawShading() where !shadingLines.contains(shading.pocket.rawValue) {
            shadingLines.append(shading.pocket.rawValue)
            print(String(format: "  the side of the %@ pocket: %d steps, the widest turn from one step's normal to the next %.1f° (at step %d)",
                         shading.pocket.rawValue as NSString, shading.steps, shading.widestTurn, shading.widestAt))
        }
        // The flush join is not enough on its own: the run and the jaw are each shaded from their own
        // vertex normals, so the join reads as a step in the reflection unless the run's last normal
        // agrees with the jaw's first. The turn the wall of a jaw takes step to step is a degree or
        // two, so anything much over that across the seam is a break that shows.
        var seamLines: [String] = []
        for seam in table.seamShading() where !seamLines.contains(seam.pocket.rawValue) {
            seamLines.append(seam.pocket.rawValue)
            print(String(format: "  the join between the %@ pocket's jaw and the run it was cut from: the two sides' shading normals come out %.1f° apart — %@",
                         seam.pocket.rawValue as NSString, seam.degrees,
                         (seam.degrees < 5 ? "the reflection reads on across the join" : "WRONG: a step in the reflection at the join") as NSString))
        }
        // The curve of the foot — where the side meets the cloth — has to stay convex, or the jaw has
        // a dip in it. The measure is how far the foot comes back in, in millimetres.
        var footLines: [String] = []
        for foot in table.jawFootCurves() where !footLines.contains(foot.pocket.rawValue) {
            footLines.append(foot.pocket.rawValue)
            print(String(format: "  the foot of the %@ pocket: %d of its steps turn outward and the deepest it comes back in is %.2f mm — %@",
                         foot.pocket.rawValue as NSString, foot.outwardTurns, foot.deepestIn,
                         (foot.deepestIn < 0.5 ? "convex, with no dip in it" : "WRONG: the foot dips back in on itself") as NSString))
        }
        var wrong = 0
        for (name, path, point, expected) in checks {
            let actual = Table3D.contains(path, point)
            if actual != expected { wrong += 1 }
            print(String(format: "  %-46@ %@", name as NSString,
                         (actual == expected ? "ok" : "WRONG (expected \(expected))") as NSString))
        }
        if wrong == 0 {
            print("  all \(checks.count) checks agree with the shape a real table has")
        }
    }

    /// Reads the cloth and the balls off the scene, and looks along the cloth both ways: the nap runs
    /// from the baulk end towards the top, so the surface should come out smoother looking up the
    /// table, away from the baulk, than looking back down it into the fibres.
    private static func fabricProbe(_ table: Table3D, device: MTLDevice, into directory: URL) {
        print("fabric probe")
        let driver = FrameDriver()
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue]
            state.ballPositions[BallID.cue] = Vec2(600, Table.centreY)
            state.cueBallInHand = false
            state.pending = nil
        }
        driver.syncWorldFromState()
        for _ in 0..<240 { table.update(with: driver, dt: 1.0 / 120.0) }
        for line in table.materialReport() { print(line) }

        // The bed's own picture of itself, laid out flat, and the one thing a cloth has to have: its nap
        // must run **one way**. A fibre lies along the table, so the tone changes far more from one texel
        // to the next *across* the fibres than *along* them. Measured off the picture rather than taken
        // on trust, because a scatter would give the same average colour and no grain in it at all.
        let bed = Table3D.clothMaps()
        _ = write(bed.colour, name: "26-cloth-bed", into: directory)
        if let coordinates = table.clothTextureCoordinates() {
            print(String(format: "  the bed's own coordinates: %d of them, u over %.3f…%.3f, v over %.3f…%.3f",
                         coordinates.count, coordinates.u.lowerBound, coordinates.u.upperBound,
                         coordinates.v.lowerBound, coordinates.v.upperBound))
        } else {
            print("  the bed's own coordinates: WRONG: the cloth carries none, so its maps can only ever give one texel")
        }
        if let rep = bed.colour.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }) {
            var along = 0.0, across = 0.0, points = 0.0, darkest = 1.0, lightest = 0.0
            for y in stride(from: 4, to: rep.pixelsHigh - 4, by: 3) {
                for x in stride(from: 4, to: rep.pixelsWide - 4, by: 3) {
                    let here = luminance(sample(rep, x, y))
                    along += abs(luminance(sample(rep, x + 1, y)) - here)
                    across += abs(luminance(sample(rep, x, y + 1)) - here)
                    points += 1
                    darkest = min(darkest, here); lightest = max(lightest, here)
                }
            }
            let n = max(points, 1)
            let ratio = across / max(along, 1e-9)
            print(String(format: "  the bed, texel to texel: the tone steps %.4f along the table and %.4f across it, so the nap lies %.1f times longer than it is wide, and the whole cloth sits between %.3f and %.3f — %@",
                         along / n, across / n, ratio, darkest, lightest,
                         (ratio > 1.5 ? "a grain one way, as a nap has"
                                      : "WRONG: no grain one way — that is a scatter, not a nap") as NSString))
        }

        /// Looks along the cloth from one end of the table at the middle of it, and reads the cloth
        /// there: the same table, the same lamps, the same points — only the direction of the eye
        /// different.
        func clothReading(fromX: Double, lookingAtX: Double, label: String)
            -> (red: Double, green: Double, blue: Double, spread: Double, points: Int) {
            let eye = Table3D.scenePoint(Vec2(fromX, Table.centreY), height: 600)
            let middle = Table3D.scenePoint(Vec2(lookingAtX, Table.centreY), height: 20)
            var sums = (red: 0.0, green: 0.0, blue: 0.0), levels: [Double] = []
            table.withCamera(eye, lookingAt: middle, fieldOfView: 80) {
                let image = table.renderImage(size: size, device: device)
                write(image, name: label, into: directory)
                guard let rep = image.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }) else { return }
                let imageSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
                for x in stride(from: 1300.0, through: 2200.0, by: 100.0) {
                    for y in stride(from: 600.0, through: 1200.0, by: 100.0) {
                        guard let p = table.project(Table3D.scenePoint(Vec2(x, y)), imageSize: imageSize),
                              p.x > 1, p.x < CGFloat(rep.pixelsWide) - 1,
                              p.y > 1, p.y < CGFloat(rep.pixelsHigh) - 1 else { continue }
                        let c = sample(rep, Int(p.x), Int(p.y))
                        sums.red += c.r; sums.green += c.g; sums.blue += c.b
                        levels.append(luminance(c))
                    }
                }
            }
            let points = levels.count
            let n = Double(max(1, points))
            let mean = levels.reduce(0, +) / n
            let variance = levels.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
            return (sums.red / n, sums.green / n, sums.blue / n, variance.squareRoot(), points)
        }

        let upTheTable = clothReading(fromX: 300, lookingAtX: 2600, label: "17-cloth-up-the-table")
        let downTheTable = clothReading(fromX: Table.length - 300, lookingAtX: 1000, label: "18-cloth-down-the-table")
        let up = luminance((r: upTheTable.red, g: upTheTable.green, b: upTheTable.blue))
        let down = luminance((r: downTheTable.red, g: downTheTable.green, b: downTheTable.blue))
        // The nap runs from the baulk end towards the black, so the cloth does not read the same from
        // the two ends of the table: **into** the fibres — from the black end back down towards the
        // baulk — it comes up darker, and down the length of them it comes up lighter. That is the thing
        // being checked here: which way round it comes out is the nap's own business and not the code's.
        print(String(format: "  the nap: looking up the table, down the fibres #%02x%02x%02x, mean %.3f, spread %.4f over %d points",
                     Int(upTheTable.red * 255), Int(upTheTable.green * 255), Int(upTheTable.blue * 255),
                     up, upTheTable.spread, upTheTable.points))
        print(String(format: "           looking towards the baulk, into them #%02x%02x%02x, mean %.3f, spread %.4f over %d",
                     Int(downTheTable.red * 255), Int(downTheTable.green * 255), Int(downTheTable.blue * 255),
                     down, downTheTable.spread, downTheTable.points))
        let difference = (up - down) / max(up, 1e-9)
        print(String(format: "           so the cloth reads %.1f%% %@ looking towards the baulk — %@",
                     abs(difference) * 100,
                     (difference > 0 ? "darker" : "lighter") as NSString,
                     (up > down ? "the way a nap lies, with the fibres away from the baulk"
                                : "WRONG: the cloth reads lighter into the nap") as NSString))

        // And the cloth up close, close enough that one fibre of the nap is several pixels across. From
        // the length of the table the nap averages away to nothing and the cloth should read as one flat
        // green — the eye is coarser than the fibres out there — so this is the view where the pile has
        // to be there, magnified past what the eye can do, the way a magnifying glass or a raking light
        // shows it. The picture is written out and the grain measured off it.
        let eye = Table3D.scenePoint(Vec2(1200, Table.centreY - 260), height: 95)
        let lookingAt = Table3D.scenePoint(Vec2(1320, Table.centreY - 200), height: 0)
        table.withCamera(eye, lookingAt: lookingAt, fieldOfView: 40) {
            let image = table.renderImage(size: size, device: device)
            write(image, name: "27-cloth-up-close", into: directory)
            guard let rep = image.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }) else { return }
            let width = rep.pixelsWide, height = rep.pixelsHigh
            var along: [Double] = [], across: [Double] = []
            for y in stride(from: height / 2, to: height / 2 + 120, by: 3) {
                for x in stride(from: width / 4, to: width / 4 + 400, by: 3) {
                    let here = luminance(sample(rep, x, y))
                    along.append(abs(luminance(sample(rep, x + 1, y)) - here))
                    across.append(abs(luminance(sample(rep, x, y + 1)) - here))
                }
            }
            let n = Double(max(along.count, 1))
            let theLength = along.reduce(0, +) / n, theWidth = across.reduce(0, +) / n
            print(String(format: "  the bed under the eye: %.4f of full scale from one pixel to the next along the table, %.4f across it, so the pile shows %.1f times more across than along — %@",
                         theLength, theWidth, theWidth / max(theLength, 1e-9),
                         (theWidth > 0.004 && theWidth > 1.5 * theLength
                          ? "a nap with a grain in it"
                          : "WRONG: flat as paint, or a fuzz with no grain") as NSString))
        }

        // And a cushion, dressed in that same cloth: the eye just above the bed at the side of the
        // table, looking along a cushion's face with the bed below it. A cushion is the same cloth cut
        // and tacked on, so the two have to read as one cloth across the join at the cushion's foot —
        // the same green, the same weave, and the picture is written out so the join can be looked at.
        let cushionEye = Table3D.scenePoint(Vec2(1150, 260), height: 165)
        let cushionAt = Table3D.scenePoint(Vec2(1560, 30), height: 14)
        table.withCamera(cushionEye, lookingAt: cushionAt, fieldOfView: 45) {
            let image = table.renderImage(size: size, device: device)
            write(image, name: "28-cushion-up-close", into: directory)
            guard let rep = image.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }) else { return }
            // The cushion's face and the bed at its foot, one above the other down the middle of the frame:
            // the same cloth either side of the join, so the same green under the same light.
            let onTheFace = sample(rep, rep.pixelsWide / 2, rep.pixelsHigh / 3)
            let onTheBed = sample(rep, rep.pixelsWide / 2, rep.pixelsHigh * 3 / 4)
            func hue(_ c: Sample) -> (Double, Double) {
                let total = max(c.r + c.g + c.b, 1e-6)
                return (c.r / total, c.b / total)
            }
            let face = hue(onTheFace), bed = hue(onTheBed)
            let apart = max(abs(face.0 - bed.0), abs(face.1 - bed.1))
            print(String(format: "  the join at a cushion's foot: %@ on the cushion's face, %@ on the bed",
                         String(format: "#%02x%02x%02x", Int(onTheFace.r * 255), Int(onTheFace.g * 255), Int(onTheFace.b * 255)) as NSString,
                         String(format: "#%02x%02x%02x", Int(onTheBed.r * 255), Int(onTheBed.g * 255), Int(onTheBed.b * 255)) as NSString))
            if let covering = table.cushionCovering() {
                print(String(format: "  the cushions and the jaws are dressed in %@: the bed's own colour %@, its relief %@, its nap %@ — %@",
                             covering.named as NSString,
                             (covering.ownTexture ? "taken" : "NOT taken") as NSString,
                             (covering.relief ? "taken" : "NOT taken") as NSString,
                             (covering.nap ? "taken" : "NOT taken") as NSString,
                             (covering.ownTexture && covering.relief && covering.nap
                              ? "the same cloth as the bed"
                              : "WRONG: a covering of its own rather than the bed's cloth") as NSString))
            } else {
                print("  the cushions and the jaws: WRONG: nothing finds a cloth covering on them")
            }
            print(String(format: "  and the join reads within %.3f of one colour, either side of it", apart))
        }
    }

    /// Measures what the balls actually do, so the simulation can be checked against what
    /// billiard balls really do.
    private static func physicsProbe() {
        print("physics probe")

        // A ball rolled along a cushion into a corner pocket. It comes in along the cushion's face,
        // runs on to the jaw's round and is carried into the throat: whether it drops depends on
        // whether the path its centre takes crosses the hole's rim, which is what the hole being set
        // out behind the mouth moves. It is the difference between a corner that takes a ball run
        // along the cushion and one that rattles it back out.
        for (label, from, toTheCorner) in [
            ("along the cushion into a corner", Vec2(400, Table.ballRadius), Vec2(-1, 0)),
            ("up the table into a middle pocket", Vec2(Table.length / 2, 400), Vec2(0, -1)),
        ] {
            let roll = PhysicsWorld(balls: [
                Ball(id: BallID.cue, color: .white, position: from),
            ])
            roll.applyCueStrike(cueBallID: BallID.cue, direction: toTheCorner, power: 900, side: 0, vertical: 0.1)
            var clock = 0.0
            while clock < 12, roll.balls[0].onTable {
                roll.step(dt: 1.0 / 240.0)
                clock += 1.0 / 240.0
            }
            let ball = roll.balls[0]
            let nearest = PocketID.allCases.min {
                ball.position.distance(to: $0.cut.holeCentre) < ball.position.distance(to: $1.cut.holeCentre)
            }
            let howFarOff = nearest.map { ball.position.distance(to: $0.cut.holeCentre) - $0.cut.holeRadius } ?? 0
            print(String(format: "  %-34@ %@ after %.2f s, %.0f mm from the hole's rim",
                         label as NSString,
                         (ball.onTable ? "still on the table" : "potted") as NSString,
                         clock, howFarOff))
        }

        // A fan of shots into the bottom-left corner: the same pace from the same place, aimed at a
        // spread of points across the corner's mouth. This is the corner as a player meets it — some
        // of the fan is played at the mouth and some of it at the **throat** — so how many of the
        // thirteen it takes is what its jaws are worth. A corner that throws a ball back out shows up
        // here as a shot that is still on the table and is nowhere near a pocket.
        let corner = PocketID.bottomLeft.cut
        var taken = 0, thrownOut = 0
        for offset in stride(from: -30.0, through: 30.0, by: 5.0) {
            let from = Vec2(560, 560)
            let aim = corner.mouth + corner.axis.perpendicular * offset
            let shot = PhysicsWorld(balls: [Ball(id: BallID.cue, color: .white, position: from)])
            shot.applyCueStrike(cueBallID: BallID.cue, direction: (aim - from).normalized,
                                power: 1600, side: 0, vertical: 0.4)
            var clock = 0.0
            while clock < 8, shot.balls[0].onTable {
                shot.step(dt: 1.0 / 240.0)
                clock += 1.0 / 240.0
            }
            if shot.balls[0].onTable { thrownOut += 1 } else { taken += 1 }
        }
        print("  a fan of 13 shots across the bottom-left corner's mouth, at one pace: \(taken) taken by the pocket, \(thrownOut) left on the table")

        // How hard a surface holds a ball: the cushion's own grip, which a jaw's round, the run of
        // cushion it belongs to and the pocket's facing all read. It comes on with the speed of the hit
        // and goes as the square of how far the ball sank in, so a rattle is barely held and a driven
        // ball is held properly.
        var holds = ""
        for speed in [250.0, 500.0, 1000.0, 2000.0, 3000.0] {
            holds += String(format: "%.1f m/s: %2.0f%%   ", speed / 1000, PhysicsWorld.cushionHold(for: speed) * 100)
        }
        print("  the grab, on the rubber of a cushion or jaw and on the facing of a pocket alike — \(holds)")

        func report(_ label: String, _ world: PhysicsWorld) {
            var line = "  \(label.padding(toLength: 12, withPad: " ", startingAt: 0))"
            for ball in world.balls {
                line += String(format: "%@ v=%7.1f (%.1f, %.1f)  w=(%6.1f, %6.1f, %6.1f) | ",
                               ball.color.rawValue.prefix(2).padding(toLength: 2, withPad: " ", startingAt: 0),
                               ball.velocity.length, ball.velocity.x, ball.velocity.y,
                               ball.spin.x, ball.spin.y, ball.spin.z)
            }
            print(line)
        }

        // A full-ball shot with the cue ball rolling naturally.
        let world = PhysicsWorld(balls: [
            Ball(id: BallID.cue, color: .white, position: Vec2(900, 889)),
            Ball(id: BallID.firstRed, color: .red, position: Vec2(1400, 889)),
        ])
        world.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 1000, side: 0, vertical: 0.4)
        report("struck", world)
        let energyBefore = world.balls.map { $0.velocity.lengthSquared }.reduce(0, +)

        let start = world.balls.map(\.position)
        var contact = -1
        var frame = 0
        var clock = 0.0
        var momentumBeforeContact = 0.0
        while clock < 8 {
            momentumBeforeContact = world.balls.map(\.velocity.x).reduce(0, +)
            world.step(dt: 1.0 / 240.0)
            clock += 1.0 / 240.0
            frame += 1
            if contact < 0, world.balls[1].velocity.length > 1 {
                contact = frame
                report("contact", world)
                let momentumAfter = world.balls.map(\.velocity.x).reduce(0, +)
                let energyAfter = world.balls.map { $0.velocity.lengthSquared }.reduce(0, +)
                print(String(format: "  across the collision: momentum %8.1f -> %8.1f (%+.2f%%), kinetic energy %9.0f -> %9.0f (%.0f%%)",
                             momentumBeforeContact, momentumAfter,
                             100 * (momentumAfter - momentumBeforeContact) / momentumBeforeContact,
                             energyBefore, energyAfter, 100 * energyAfter / energyBefore))
            }
            if world.allAtRest { break }
        }
        let travelled = zip(world.balls, start).map { $0.position.distance(to: $1) }
        print(String(format: "  came to rest after %.2f s; travelled %.0f mm (cue) and %.0f mm (object)",
                     clock, travelled[0], travelled[1]))

        // A cut, to check the two balls leave at right angles.
        let cut = PhysicsWorld(balls: [
            Ball(id: BallID.cue, color: .white, position: Vec2(900, 889)),
            Ball(id: BallID.firstRed, color: .red, position: Vec2(1400, 889 + 26)),
        ])
        cut.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 1500, side: 0, vertical: 0.4)
        var cutClock = 0.0
        let cutBefore = cut.balls[0].velocity
        var lineOfCentres = Vec2(1, 0)
        while cutClock < 0.5, cut.balls[1].velocity.length < 1 {
            lineOfCentres = (cut.balls[1].position - cut.balls[0].position).normalized
            cut.step(dt: 1.0 / 240.0)
            cutClock += 1.0 / 240.0
        }
        cut.step(dt: 1.0 / 240.0)
        let cueOut = cut.balls[0].velocity, redOut = cut.balls[1].velocity
        let separation = cueOut.length > 1 && redOut.length > 1
            ? acos(max(-1, min(1, cueOut.normalized.dot(redOut.normalized)))) * 180 / .pi
            : 0
        let offLine = redOut.length > 1
            ? atan2(redOut.x * lineOfCentres.y - redOut.y * lineOfCentres.x,
                    redOut.dot(lineOfCentres)) * 180 / .pi : 0
        let lineAngle = atan2(lineOfCentres.y, lineOfCentres.x) * 180 / .pi
        let objectAngle = atan2(redOut.y, redOut.x) * 180 / .pi
        // The striker is going straight up the table, so a real table throws the object ball
        // slightly back towards that line: its angle should be a little *smaller* than the line of
        // centres, not larger.
        let thrownCorrectly = abs(objectAngle) < abs(lineAngle)
        print(String(format: "  cut: cue in %+.0f mm/s, cue out %.0f mm/s at %+.1f deg, object %.0f mm/s at %+.1f deg",
                     cutBefore.length, cueOut.length, atan2(cueOut.y, cueOut.x) * 180 / .pi,
                     redOut.length, atan2(redOut.y, redOut.x) * 180 / .pi))
        print(String(format: "  cut: the two balls leave %.1f deg apart (a real table gives about 90, %@)",
                     separation, (abs(separation - 90) < 10 ? "ok; throw pulls it a little under" : "WRONG") as NSString))
        print(String(format: "  cut: line of centres %+.1f deg, object ball leaves at %+.1f deg, %.1f deg off it (%@)",
                     lineAngle, objectAngle, abs(offLine),
                     (thrownCorrectly ? "thrown towards the line of the shot, as friction should" : "WRONG WAY") as NSString))

        // Off a cushion: straight on without side spin it should come straight back; with side spin
        // the cushion grips it and throws it sideways, which is a real effect but a modest one.
        for (label, side) in [("no side", 0.0), ("heavy side", 0.5)] {
            let cushion = PhysicsWorld(balls: [Ball(id: BallID.cue, color: .white, position: Vec2(3000, 889))])
            cushion.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 1200,
                                   side: side, vertical: 0.4)
            var clock = 0.0
            while clock < 6, cushion.balls[0].velocity.x > 0 {
                cushion.step(dt: 1.0 / 240.0)
                clock += 1.0 / 240.0
            }
            let out = cushion.balls[0].velocity
            print(String(format: "  off the cushion with %@: comes back %.0f mm/s, %.1f deg off the line it went in on",
                         label as NSString, out.length, atan2(out.y, -out.x) * 180 / .pi))
        }

        // A swerve: a lifted cue with side spin. The spin axis tilts with the cue, and the cloth turns
        // the barrel of spin about the line of the shot into a curve, so the ball comes off the line it
        // was aimed along — further the steeper the cue, and not at all with the tip on the middle.
        print("  a swerve, cue up with right side spin:")
        for (lift, side) in [(0.0, 0.5), (15.0, 0.5), (30.0, 0.5), (45.0, 0.5), (30.0, 0.0)] {
            let world = PhysicsWorld(balls: [Ball(id: BallID.cue, color: .white,
                                                  position: Vec2(400, Table.centreY))])
            world.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 2500,
                                 side: side, vertical: 0, elevation: lift * .pi / 180)
            var clock = 0.0
            var peak = Table.ballRadius
            while clock < 0.9, world.balls[0].onTable {
                world.step(dt: 1.0 / 480.0)
                clock += 1.0 / 480.0
                peak = max(peak, world.balls[0].height)
            }
            let ball = world.balls[0]
            let veer = ball.position.y - Table.centreY
            let ran = ball.position.x - 400
            print(String(format: "    cue up %2.0f° side %.1f: %.0f mm off the line of aim over %.0f mm (%.1f°), hop %.0f mm",
                         lift, side, veer, ran, atan2(veer, ran) * 180 / .pi, peak - Table.ballRadius))
        }
        // And the jump: a cue lifted hard enough puts the ball over another one, which Rule 20 calls a
        // jump shot and the rules call a foul (Rule 11(a)(x)).
        for lift in [20.0, 45.0] {
            let world = PhysicsWorld(balls: [
                Ball(id: BallID.cue, color: .white, position: Vec2(400, Table.centreY)),
                Ball(id: BallID.firstRed, color: .red, position: Vec2(700, Table.centreY)),
            ])
            world.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 4600,
                                 side: 0, vertical: 0, elevation: lift * .pi / 180)
            var clock = 0.0
            var wentOver = false
            while clock < 0.4 {
                world.clearEvents()
                world.step(dt: 1.0 / 480.0)
                clock += 1.0 / 480.0
                if world.events.contains(where: { if case .jumpShot = $0 { return true }; return false }) { wentOver = true }
            }
            print("    cue up \(Int(lift))°: clear over the Red: \(wentOver ? "yes — a jump shot, a foul" : "no")")
        }

        // A break, to see nothing comes out faster than it went in.
        let rack = Table.rackedReds()
        var breakBalls = [Ball(id: BallID.cue, color: .white, position: Vec2(Table.baulkLineX, Table.centreY - 120))]
        for (index, position) in rack.enumerated() {
            breakBalls.append(Ball(id: BallID.firstRed + index, color: .red, position: position))
        }
        let breakWorld = PhysicsWorld(balls: breakBalls)
        breakWorld.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 4000, side: 0, vertical: 0.4)
        var breakClock = 0.0, fastestAfter = 0.0
        while breakClock < 20, !breakWorld.allAtRest {
            breakWorld.step(dt: 1.0 / 240.0)
            breakClock += 1.0 / 240.0
            fastestAfter = max(fastestAfter, breakWorld.balls.dropFirst().map(\.velocity.length).max() ?? 0)
        }
        print(String(format: "  break at 4000 mm/s: fastest red %.0f mm/s (must stay under 4000), settled after %.1f s",
                     fastestAfter, breakClock))

        // Into a pocket. The bed is cut away at the hole, so the cloth carries the ball to the rim
        // and lets go: it falls the depth of the pocket from there. A ball played in hard reaches
        // the back of the pocket on the way down, and the back of a pocket is dead — the ball loses
        // nearly all of what it had, which is why a hard ball drops in rather than coming back out.
        for (label, power) in [("rolled in", 550.0), ("driven in", 2600.0)] {
            let pocket = PocketID.bottomMiddle
            let intoThePocket = PhysicsWorld(balls: [
                Ball(id: BallID.cue, color: .white, position: Vec2(pocket.position.x, 700)),
            ])
            intoThePocket.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(0, -1), power: power,
                                         side: 0, vertical: 0.4)
            var clock = 0.0
            var rimTime: Double?
            var rimSpeed = 0.0
            var backSpeedIn: Double?
            var backSpeedOut = 0.0
            var deepest = Table.ballRadius
            while clock < 8, intoThePocket.balls[0].onTable {
                let before = intoThePocket.balls[0]
                intoThePocket.step(dt: 1.0 / 240.0)
                clock += 1.0 / 240.0
                let after = intoThePocket.balls[0]
                if rimTime == nil, before.isOnTheCloth, after.height < Table.ballRadius {
                    rimTime = clock
                    rimSpeed = before.velocity.length
                }
                // The only thing that takes any speed off a ball in the air is the back of the
                // pocket, so a drop in the speed along the pocket's own line is that hit.
                let into = before.velocity.dot(pocket.cut.axis), out = after.velocity.dot(pocket.cut.axis)
                if backSpeedIn == nil, after.onTable, out < into - 1 {
                    backSpeedIn = into
                    backSpeedOut = out
                }
                deepest = min(deepest, after.height)
            }
            let ball = intoThePocket.balls[0]
            let drop = Table.ballRadius - deepest
            // Where it comes to rest: the top of a potted ball has to be below the mouth of the well
            // it has sunk into, or it is seen standing in the pocket as it is taken away.
            let top = ball.height + Table.ballRadius
            let outOfSight = top < -Table3D.pocketWellDepth
            print(String(format: "  %@ comes to rest with the top of it %.1f mm below the cloth (%@, the well is drawn %.0f mm deep)",
                         label as NSString, -top,
                         (outOfSight ? "out of sight" : "WRONG: still in view") as NSString,
                         Table3D.pocketWellDepth))
            if let rimTime, let backSpeedIn {
                print(String(format: "  %@ at %4.0f mm/s: to the rim in %.3f s at %.0f mm/s, fell %.0f mm, hit the back of the pocket at %.0f mm/s and left it at %.0f mm/s, potted after %.3f s into %@",
                             label as NSString, power, rimTime, rimSpeed, drop,
                             backSpeedIn, backSpeedOut, clock, ball.pottedInto?.rawValue ?? "nothing"))
            } else if let rimTime {
                print(String(format: "  %@ at %4.0f mm/s: to the rim in %.3f s at %.0f mm/s, fell %.0f mm and settled in the pocket after %.3f s into %@ (never reached the back)",
                             label as NSString, power, rimTime, rimSpeed, drop, clock,
                             ball.pottedInto?.rawValue ?? "nothing"))
            } else {
                print(String(format: "  %@ at %4.0f mm/s: never left the cloth (potted %@, on the table %@)",
                             label as NSString, power, ball.pottedInto?.rawValue ?? "nothing",
                             (ball.onTable ? "yes" : "no") as NSString))
            }
        }

        // Balls taken in off the line, where the shape of the pocket has to do the work: the jaws
        // carry them across the throat and the well only keeps them inside it. The measure is how
        // far the well ever has to push one in a single step.
        let entries: [(String, Vec2, Vec2, Double)] = [
            ("along a cushion into a corner", Vec2(900, Table.ballRadius), Vec2(-1, 0), 1600),
            ("hard along a cushion into a corner", Vec2(2600, Table.ballRadius), Vec2(-1, 0), 4000),
            ("into the middle pocket, square on", Vec2(PocketID.bottomMiddle.position.x, 700), Vec2(0, -1), 1600),
            ("into it 30 mm off the line", Vec2(PocketID.bottomMiddle.position.x + 30, 700), Vec2(0, -1), 1600),
        ]
        for (label, from, direction, power) in entries {
            let world = PhysicsWorld(balls: [Ball(id: BallID.cue, color: .white, position: from)])
            world.applyCueStrike(cueBallID: BallID.cue, direction: direction, power: power,
                                 side: 0, vertical: 0.4)
            var clock = 0.0
            while clock < 8, world.balls[0].onTable {
                world.step(dt: 1.0 / 240.0)
                clock += 1.0 / 240.0
            }
            print(String(format: "  %-36@: potted %@ after %.2f s, and the well pushed it at worst %.2f mm in one step",
                         label as NSString, world.balls[0].pottedInto?.rawValue ?? "nothing", clock,
                         world.largestPocketCorrection))
        }

        // A ball dropped onto the cloth: the bed is not a floor it sticks to, it bounces on it.
        let dropped = PhysicsWorld(balls: [
            Ball(id: BallID.cue, color: .white, position: Vec2(1200, 889), height: 400),
        ])
        var bounceClock = 0.0
        var apexAfterTheFirstLanding = 0.0
        var bounced = false
        while bounceClock < 3, !dropped.allAtRest {
            dropped.step(dt: 1.0 / 240.0)
            bounceClock += 1.0 / 240.0
            let ball = dropped.balls[0]
            if ball.verticalVelocity > 0 {
                bounced = true
                apexAfterTheFirstLanding = max(apexAfterTheFirstLanding, ball.height)
            }
        }
        print(String(format: "  dropped from 400 mm: settled after %.2f s at %.2f mm (a radius is %.2f), having bounced back up to %.2f mm",
                     bounceClock, dropped.balls[0].height, Table.ballRadius,
                     bounced ? apexAfterTheFirstLanding : 0))

        // Two collisions in a row: the cue ball into a red, that red into another red. Momentum,
        // angular momentum and energy are checked across each one.
        let line = PhysicsWorld(balls: [
            Ball(id: BallID.cue, color: .white, position: Vec2(900, 889)),
            Ball(id: BallID.firstRed, color: .red, position: Vec2(1400, 889)),
            Ball(id: BallID.firstRed + 1, color: .red, position: Vec2(1700, 889)),
        ])
        line.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: 1500, side: 0, vertical: 0.4)
        // Per unit mass, in mm and seconds: speed squared, and angular momentum in mm^2/s.
        let inertia = 2.0 / 5.0 * Table.ballRadius * Table.ballRadius
        func totals() -> (momentum: Double, angular: Double, energy: Double) {
            var momentum = 0.0, angular = 0.0, energy = 0.0
            for ball in line.balls {
                momentum += ball.velocity.x
                angular += ball.position.x * ball.velocity.y - ball.position.y * ball.velocity.x
                angular += inertia * ball.spin.z
                energy += ball.velocity.lengthSquared
                energy += inertia * (ball.spin.x * ball.spin.x + ball.spin.y * ball.spin.y + ball.spin.z * ball.spin.z)
            }
            return (momentum, angular, energy)
        }
        var previous = totals()
        var clock2 = 0.0
        var seen = Set<Int>()
        while clock2 < 6, !line.allAtRest {
            line.step(dt: 1.0 / 240.0)
            clock2 += 1.0 / 240.0
            let now = totals()
            // A ball that has just been struck, for the first time, marks a collision. Comparing
            // with the step before it isolates the collision itself from the cloth friction.
            for (index, ball) in line.balls.enumerated() where index > 0 && ball.velocity.length > 1 {
                guard !seen.contains(index) else { continue }
                seen.insert(index)
                print(String(format: "  collision %d, in one step: momentum %8.1f -> %8.1f (%.1f%%), angular momentum %.1f%% kept, energy %.1f%% kept",
                             seen.count, previous.momentum, now.momentum,
                             100 * now.momentum / previous.momentum,
                             100 * now.angular / previous.angular,
                             100 * now.energy / previous.energy))
            }
            previous = now
        }
        // And once it is all over, whether anything is left rolling the wrong way: a ball whose
        // spin is a long way from its direction of travel is sliding sideways, which looks wrong.
        for ball in line.balls {
            let speed = ball.velocity.length
            // Rolling means the contact point is still: v = (r * spin.y, -r * spin.x).
            let roll = Vec2(ball.spin.y, -ball.spin.x) * Table.ballRadius
            if speed > 1 {
                let mismatch = acos(max(-1, min(1, roll.normalized.dot(ball.velocity.normalized)))) * 180 / .pi
                print(String(format: "  %@: still moving at %.0f mm/s, rolling %.0f mm/s, %.0f deg askew",
                             ball.color.rawValue as NSString, speed, roll.length, mismatch))
            }
        }

        // Balls left barely moving, which is what a second collision leaves behind: a ball with no
        // spin at all slides, and the friction on it per step may be larger than the slip itself.
        for speed in [200.0, 60.0, 20.0, 10.0, 5.0] {
            let slow = PhysicsWorld(balls: [Ball(id: BallID.cue, color: .white, position: Vec2(1000, 889))])
            slow.applyCueStrike(cueBallID: BallID.cue, direction: Vec2(1, 0), power: speed, side: 0, vertical: 0)
            let from = slow.balls[0].position
            var t = 0.0
            var maxSlip = 0.0
            while t < 20, !slow.allAtRest {
                slow.step(dt: 1.0 / 240.0)
                t += 1.0 / 240.0
                let ball = slow.balls[0]
                if ball.velocity.length > 0.01 {
                    maxSlip = max(maxSlip, abs(ball.velocity.x - Table.ballRadius * ball.spin.y))
                }
            }
            let ball = slow.balls[0]
            print(String(format: "  set going at %5.0f mm/s: stopped after %5.2f s having rolled %6.0f mm, final speed %6.2f mm/s, worst slip %5.1f mm/s",
                         speed, t, ball.position.distance(to: from), ball.velocity.length, maxSlip))
        }
    }

    /// Checks the markings on the cloth: the "D" has to be a half-circle band drawn on the baulk
    /// side of the baulk line — not a wedge, and not on the far side of the line.
    private static func markingProbe(_ table: Table3D, device: MTLDevice) {
        let path = Table3D.dMarkingPath()
        let brown = Table.brownSpot
        func onTheCircle(_ radius: Double, _ degrees: Double) -> Vec2 {
            brown + Vec2(cos(degrees * .pi / 180), sin(degrees * .pi / 180)) * radius
        }
        let checks: [(String, Vec2, Bool)] = [
            ("D: on the band, towards the baulk end", onTheCircle(Table.dRadius, 180), true),
            ("D: on the band, at the yellow corner", onTheCircle(Table.dRadius, 270), true),
            ("D: on the band, at the green corner", onTheCircle(Table.dRadius, 90), true),
            ("D: inside the band", onTheCircle(Table.dRadius - 20, 180), false),
            ("D: outside the band", onTheCircle(Table.dRadius + 20, 180), false),
            ("D: in the middle of the half-circle", onTheCircle(Table.dRadius * 0.4, 180), false),
            ("D: the far side of the baulk line", onTheCircle(Table.dRadius, 0), false),
        ]
        print("marking probe")
        for (name, point, expected) in checks {
            let actual = Table3D.contains(path, point)
            print(String(format: "  %-42@ %@", name as NSString,
                         (actual == expected ? "ok" : "WRONG (expected \(expected))") as NSString))
        }

        // The D's corners sit on the baulk line, and the whole band is on the baulk side of it.
        let bounds = path.bounds
        let minX = bounds.minX * 1000 + Table.length / 2
        let maxX = bounds.maxX * 1000 + Table.length / 2
        let minY = bounds.minY * 1000 + Table.width / 2
        let maxY = bounds.maxY * 1000 + Table.width / 2
        print(String(format: "  D: spans x %.1f…%.1f mm, y %.1f…%.1f mm (the baulk line is at %.0f, the brown spot at (%.0f, %.0f))",
                     minX, maxX, minY, maxY, Table.baulkLineX, Table.brownSpot.x, Table.brownSpot.y))
        let correctSide = maxX <= Table.baulkLineX + 2 && minX > Table.baulkLineX - Table.dRadius - 2
        print("  D: \(correctSide ? "reaches the baulk line and no further, as it should" : "WRONG: it crosses the baulk line")")

        // And what the D looks like where it matters: from the player's own view. The markings are
        // found by rendering twice, once with them hidden, and keeping what changed.
        let driver = FrameDriver()
        driver.placeCueBall(at: Vec2(Table.baulkLineX, Table.centreY - 120))
        table.use(.sighting)
        for _ in 0..<240 { table.update(with: driver, dt: 1.0 / 120.0) }
        let marked = table.withTableOnly { table.renderImage(size: size, device: device) }
        let bare = table.withTableOnly {
            table.withMarkingsHidden { table.renderImage(size: size, device: device) }
        }
        differenceMap(marked, bare, name: "the markings on the cloth, from the player's view")

        // The same again from straight above, where the shape of the D can be read off directly.
        table.withOverheadCamera {
            let marked = table.renderImage(size: size, device: device)
            let bare = table.withMarkingsHidden { table.renderImage(size: size, device: device) }
            differenceDetail(marked, bare, table,
                             name: "the markings, from above",
                             x: 380...820, y: 540...1240, columns: 44, rows: 34)
            fitRenderedArc(marked, bare, table)
        }

    }

    /// Finds where the rendered "D" actually runs and measures it against the circle it should be.
    /// A path can be a perfect arc and still be drawn as a wedge, so this checks the pixels.
    private static func fitRenderedArc(_ marked: NSImage, _ bare: NSImage, _ table: Table3D) {
        guard let a = marked.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }),
              let b = bare.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }) else { return }
        let width = min(a.pixelsWide, b.pixelsWide), height = min(a.pixelsHigh, b.pixelsHigh)
        var radii: [Double] = []
        var nearest = Double.greatestFiniteMagnitude
        var furthest = 0.0
        for y in stride(from: 640.0, through: 1140.0, by: 40.0) {
            // Scan across the baulk half of the table for the marking.
            var edges: [Double] = []
            for x in stride(from: 400.0, through: 730.0, by: 2.0) {
                guard let p = table.project(Table3D.scenePoint(Vec2(x, y)),
                                            imageSize: CGSize(width: width, height: height)),
                      p.x > 1, p.x < CGFloat(width) - 1, p.y > 1, p.y < CGFloat(height) - 1 else { continue }
                var changed = false
                for dx in -1...1 {
                    for dy in -1...1 {
                        let before = sample(a, Int(p.x) + dx, Int(p.y) + dy)
                        let after = sample(b, Int(p.x) + dx, Int(p.y) + dy)
                        if abs(before.r - after.r) + abs(before.g - after.g) + abs(before.b - after.b) > 0.02 {
                            changed = true
                        }
                    }
                }
                if changed { edges.append(x) }
            }
            guard let first = edges.first, let last = edges.last else { continue }
            for x in [first, last] {
                let radius = hypot(x - Table.brownSpot.x, y - Table.brownSpot.y)
                radii.append(radius)
                nearest = min(nearest, radius)
                furthest = max(furthest, radius)
            }
        }
        let mean = radii.isEmpty ? 0 : radii.reduce(0, +) / Double(radii.count)
        print(String(format: "  the drawn D: the marking runs %.1f…%.1f mm from the brown spot (the rule is %.0f mm, drawn as a 3 mm band), mean %.1f",
                     nearest, furthest, Table.dRadius, mean))
    }

    /// Prints where two renders differ, over a rectangle of the table.
    private static func differenceDetail(
        _ marked: NSImage,
        _ bare: NSImage,
        _ table: Table3D,
        name: String,
        x xRange: ClosedRange<Double>,
        y yRange: ClosedRange<Double>,
        columns: Int,
        rows: Int
    ) {
        guard let a = marked.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }),
              let b = bare.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }) else { return }
        let width = min(a.pixelsWide, b.pixelsWide), height = min(a.pixelsHigh, b.pixelsHigh)
        print("  \(name) — x \(Int(xRange.lowerBound))…\(Int(xRange.upperBound)) mm, y \(Int(yRange.lowerBound))…\(Int(yRange.upperBound)) mm")
        for row in 0..<rows {
            var line = ""
            for column in 0..<columns {
                let px = xRange.lowerBound + (xRange.upperBound - xRange.lowerBound) * (Double(column) + 0.5) / Double(columns)
                let py = yRange.upperBound - (yRange.upperBound - yRange.lowerBound) * (Double(row) + 0.5) / Double(rows)
                guard let p = table.project(Table3D.scenePoint(Vec2(px, py)),
                                            imageSize: CGSize(width: width, height: height)),
                      p.x > 1, p.x < CGFloat(width) - 1, p.y > 1, p.y < CGFloat(height) - 1 else {
                    line.append("?")
                    continue
                }
                var changed = 0
                for dx in -2...2 {
                    for dy in -2...2 {
                        let before = sample(a, Int(p.x) + dx, Int(p.y) + dy)
                        let after = sample(b, Int(p.x) + dx, Int(p.y) + dy)
                        if abs(before.r - after.r) + abs(before.g - after.g) + abs(before.b - after.b) > 0.02 {
                            changed += 1
                        }
                    }
                }
                line.append(changed > 12 ? "#" : (changed > 3 ? "+" : "."))
            }
            print("  |" + line + "|")
        }
    }

    /// Prints where two renders of the same view differ, which is exactly where the markings are.
    private static func differenceMap(_ marked: NSImage, _ bare: NSImage, name: String) {
        guard let a = marked.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }),
              let b = bare.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }) else { return }
        let width = min(a.pixelsWide, b.pixelsWide), height = min(a.pixelsHigh, b.pixelsHigh)
        print("  \(name)")
        for row in 0..<28 {
            var line = ""
            for column in 0..<92 {
                let x0 = column * width / 92, x1 = (column + 1) * width / 92
                let y0 = row * height / 28, y1 = (row + 1) * height / 28
                var changed = 0, total = 0
                for x in stride(from: x0, to: x1, by: 2) {
                    for y in stride(from: y0, to: y1, by: 2) {
                        let before = sample(a, x, y), after = sample(b, x, y)
                        total += 1
                        if abs(before.r - after.r) + abs(before.g - after.g) + abs(before.b - after.b) > 0.02 {
                            changed += 1
                        }
                    }
                }
                line.append(total == 0 ? " " : (Double(changed) / Double(total) > 0.08 ? "#" : "."))
            }
            print("  |" + line + "|")
        }
    }

    /// Checks the cue end to end, and that the player's eye is directly above it.
    private static func cueProbe(_ table: Table3D) {
        print("cue probe")
        var joins = true
        for (previous, next) in zip(Table3D.cueSections, Table3D.cueSections.dropFirst()) {
            if abs(next.front - previous.back) > 0.001 {
                joins = false
                print("  GAP: \(previous.name) ends at \(previous.back), \(next.name) starts at \(next.front)")
            }
        }
        let sections = Table3D.cueSections
        let widest = sections.map(\.backRadius).max() ?? 0
        print(String(format: "  %d sections, %@, %.0f mm long, %.1f mm across the tip, %.1f mm across the butt",
                     sections.count,
                     (joins ? "all joined" : "NOT JOINED") as NSString,
                     (sections.last?.back ?? 0) - (sections.first?.front ?? 0),
                     (sections.first?.frontRadius ?? 0) * 2, widest * 2))

        // **The side of the cue is one straight line.** The stick is drawn as six lengths, and each of them
        // could put a step of its own into the silhouette — a length that is fat or thin for where it sits,
        // or that tapers at a rate of its own. So every length is checked against the one taper: its radii
        // are the taper's radii, its two ends meet its neighbours', and it rises at the same rate the whole
        // cue does. A kink anywhere shows on the side of the stick, which is what a player sights down.
        let overallRate = (Table.cueButtRadius - Table.cueTipRadius) / Table.cueLength
        var worstStep = 0.0, worstRate = 0.0
        for section in sections {
            let length = max(section.back - section.front, 1e-9)
            worstStep = max(worstStep, abs(section.frontRadius - Table.cueRadius(at: section.front)))
            worstStep = max(worstStep, abs(section.backRadius - Table.cueRadius(at: section.back)))
            worstRate = max(worstRate,
                            abs((section.backRadius - section.frontRadius) / length - overallRate))
        }
        for (previous, next) in zip(sections, sections.dropFirst()) {
            worstStep = max(worstStep, abs(next.frontRadius - previous.backRadius))
        }
        print(String(format: "  the side of it: every length rises at the whole stick's %.4f mm a millimetre, steps %.1e mm, and the worst any length is off the taper is %.1e mm — %@",
                     overallRate, worstStep, worstRate,
                     (worstStep < 1e-9 && worstRate < 1e-9
                      ? "straight, with no step and no kink in it"
                      : "WRONG: the side of the cue is not one taper") as NSString))

        // And the cue should sit under the player's eye: the eye on the line of aim, the cue ball
        // below it, the cue below that.
        let driver = FrameDriver()
        driver.placeCueBall(at: Vec2(Table.baulkLineX, Table.centreY - 120))
        for preset in PlayerCamera.Preset.allCases {
            table.use(preset)
            for _ in 0..<120 { table.update(with: driver, dt: 1.0 / 120.0) }
            guard let cueBall = driver.cueBall else { continue }
            let camera = PlayerViewSolver.camera(cueBall: cueBall.position, yaw: driver.aimAngle,
                                                 pitch: preset.pitch, preset: preset)
            let across = (camera.eye - cueBall.position)
                - Vec2(cos(driver.aimAngle), sin(driver.aimAngle)) * (camera.eye - cueBall.position).dot(Vec2(cos(driver.aimAngle), sin(driver.aimAngle)))
            print(String(format: "  %-10@ eye %6.0f mm behind the ball, %5.1f mm across the cue line, %5.0f mm above the cloth",
                         preset.title as NSString, (camera.eye - cueBall.position).length, across.length, camera.eyeHeight))
        }
    }

    /// The cue as the stick it is, and what the game does about it.
    ///
    /// Checks the girth the stick is judged at, where its own thickness stops it fitting behind the
    /// ball, and what settling the cue does for the positions a player runs into — lift the butt, put
    /// the tip up the ball, or both — and then shows the picture of it: the cue ball on a cushion with
    /// the cue settled where it fits, never drawn through the cushion and never taken away.
    private static func cueRoomProbe(_ table: Table3D, device: MTLDevice, into directory: URL) {
        print("cue room probe")
        // The shaft's own wood, laid out flat: the figure an ash cue is chosen for, at the size it is
        // drawn. The rectangle is the shaft's surface unwrapped — `u` round the shaft, `v` along it from
        // the tip (the top edge) to the butt (the bottom) — so the arrows should all point _up_ it.
        _ = write(Table3D.ashTexture(), name: "24-ash-shaft", into: directory)
        // And the tip's own colour, unwrapped the same way: `v` along the leather from the crown (the
        // top edge) to the ferrule (the bottom), so the top edge should be the green and the bottom
        // edge the dark grey. Read back off the picture rather than taken on trust.
        let tipTexture = Table3D.tipTexture()
        _ = write(tipTexture, name: "25-cue-tip", into: directory)
        if let tip = tipTexture.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }) {
            let crown = sample(tip, tip.pixelsWide / 2, 0)
            let ferrule = sample(tip, tip.pixelsWide / 2, tip.pixelsHigh - 1)
            func hex(_ c: Sample) -> String {
                String(format: "#%02x%02x%02x",
                       Int((c.r * 255).rounded()), Int((c.g * 255).rounded()), Int((c.b * 255).rounded()))
            }
            let lighter = luminance(crown) > luminance(ferrule)
            let greener = (crown.g - crown.b) > (ferrule.g - ferrule.b) + 0.10
            print("  the tip: \(hex(crown)) at the crown, \(hex(ferrule)) at the ferrule"
                  + (lighter && greener
                     ? " — lighter and greener at the crown, as it should be"
                     : " — WRONG: the crown should be the lighter, greener end"))
        }
        print(String(format: "  the stick: %.1f mm across the tip, %.1f at the joint (%.0f mm back), %.1f at the butt — one taper of %.4f mm a millimetre, judged in %d slices of %.0f mm",
                     Table.cueTipRadius * 2, Table.cueRadius(at: 950) * 2, 950.0, Table.cueButtRadius * 2,
                     (Table.cueButtRadius - Table.cueTipRadius) / Table.cueLength,
                     Table.cueGirth.count, Table.cueSlice))

        // Where the cue's own thickness stops it: the last cushion behind the ball that a cue lifted to
        // the game's own cap can clear. The cue is judged **level** now, so the lift it is measured at
        // has to be stated — `automaticLiftCap` is as far as the game will stand the butt up of its own
        // accord, which is the pose a jammed cue is settled into — and a level cue never clears a
        // cushion at all, which is why the room behind the ball has to be found for it.
        let lifted = FrameDriver.automaticLiftCap
        var crossing = 0.0
        for distance in stride(from: 0.0, through: 900.0, by: 1.0) {
            let world = PhysicsWorld(balls: [Ball(id: BallID.cue, color: .white,
                                                  position: Vec2(distance, Table.centreY))])
            if world.cueFits(cueBallID: BallID.cue, yaw: 0, elevation: lifted,
                             side: 0, vertical: 0, draw: 0) { crossing = distance; break }
        }
        let bare = (Table.cushionHeight - Table.ballRadius) / tan(lifted)
        print(String(format: "  a cue lifted to %.0f° clears a cushion %5.0f mm behind the ball (with no thickness to the stick it would be %.0f mm)",
                     lifted * 180 / .pi, crossing, bare))
        print(String(format: "  the game's own lifts: a place that needs settling comes up to %.0f° of butt and tops the ball to %.2f of a radius; a **spin change** does the same, and at that first cap lifts the tip to %.2f of a radius with the cue held there — only if that is not enough does the butt carry on to its second cap, %.0f° (the family's own end is %.0f°), and only past both is the spin settled to what fits",
                     FrameDriver.automaticLiftCap * 180 / .pi, FrameDriver.automaticTopSpin,
                     FrameDriver.spinLiftTop, FrameDriver.spinLiftSecondCap * 180 / .pi,
                     FrameDriver.spinLiftCap * 180 / .pi))

        // What settling does, in the positions a player runs into. The cue is put back to the player's
        // own angle — the bottom of the lift — and the game finds it room. The tip's offset printed
        // beside it is whatever the settle has left on the ball, which is where the room was found.
        print("  what settling the cue does, from the cue in its default place:")
        func settled(_ label: String, cue: Vec2, aim: Double, balls: [(Int, Vec2)]) {
            let d = FrameDriver()
            _ = d.placeCueBall(at: Vec2(600, 889))     // in hand, in the D: puts the player at the table
            d.game.withState { state in
                state.ballsOnTable = Set([BallID.cue] + balls.map(\.0))
                state.redsRemaining = balls.count
                state.ballOn = .red
                state.cueBallInHand = false
                state.pending = nil
                state.ballPositions[BallID.cue] = cue
                for (id, position) in balls { state.ballPositions[id] = position }
            }
            d.syncWorldFromState()
            d.aimAngle = aim
            // The player's own angle is **level**, and the pose is judged from there: the elevation
            // reported is what the settle does to a level cue, not what it did to some earlier pose.
            d.cueElevation = Table.cueStanceElevation
            let fitted = d.settleTheCue()
            print(String(format: "    %-26@ cue %4.1f°, tip %+.1f radii up the ball, %3.0f mm of draw, %@",
                         label as NSString, d.cueElevation * 180 / .pi, d.spinVertical, d.maximumCueDraw,
                         (fitted ? (d.needsTheCueStoodUp ? "settled for the player" : "a level cue had room")
                                 : "NOTHING FITS") as NSString))
        }
        settled("open table, up the table", cue: Vec2(1784, Table.centreY), aim: 0, balls: [])
        settled("open table, across it", cue: Vec2(1784, Table.centreY), aim: .pi / 2, balls: [])
        settled("cue ball on the cushion", cue: Vec2(1000, Table.cushionRestReach),
                aim: .pi / 2, balls: [(BallID.firstRed, Vec2(2200, Table.centreY))])
        settled("a Red 92 mm behind", cue: Vec2(1784, Table.centreY), aim: 0,
                balls: [(BallID.firstRed, Vec2(1784 - Table.ballDiameter - 40, Table.centreY))])
        settled("a Red against the back", cue: Vec2(1784, Table.centreY), aim: 0,
                balls: [(BallID.firstRed, Vec2(1784 - Table.ballDiameter, Table.centreY))])
        settled("a Red 120 mm behind and 80 across", cue: Vec2(1784, Table.centreY), aim: 0,
                balls: [(BallID.firstRed, Vec2(1784 - 120, Table.centreY + 80))])

        // What a **spin change** does with the room it finds, in the same positions. The cue starts where
        // the player has it — settled for the place, with the game's own top spin on the ball — and the
        // game answers the spin they ask for: the butt comes up to the first cap, the tip is lifted at
        // it, the butt carries on to the second, and only past both is the spin settled to what fits.
        print("  what a spin change does, from the cue where the player has it:")
        func spun(_ label: String, cue: Vec2, aim: Double, ball: Vec2?, side: Double, vertical: Double) {
            let d = FrameDriver()
            _ = d.placeCueBall(at: Vec2(600, 889))     // in hand, in the D: puts the player at the table
            d.game.withState { state in
                state.ballsOnTable = ball == nil ? [BallID.cue] : [BallID.cue, BallID.firstRed]
                state.redsRemaining = ball == nil ? 0 : 1
                state.ballOn = .red
                state.cueBallInHand = false
                state.pending = nil
                state.ballPositions[BallID.cue] = cue
                if let ball { state.ballPositions[BallID.firstRed] = ball }
            }
            d.syncWorldFromState()
            d.aimAngle = aim
            let settled = d.cueElevation
            d.setSpin(side: side, vertical: vertical)
            print(String(format: "    %-34@ cue %5.1f° (settled %5.1f°), tip %+.2f radii %@, %+.2f across, %3.0f mm of draw",
                         label as NSString, d.cueElevation * 180 / .pi, settled * 180 / .pi,
                         d.spinVertical, (d.spinVertical > vertical + 0.005 ? "LIFTED" : "as asked") as NSString,
                         d.spinSide, d.maximumCueDraw))
        }
        spun("open table, half a ball of side", cue: Vec2(1784, Table.centreY), aim: 0,
             ball: Vec2(2400, Table.centreY), side: 0.5, vertical: 0)
        spun("on the cushion, half a ball of side", cue: Vec2(1000, Table.cushionRestReach), aim: .pi / 2,
             ball: Vec2(2200, Table.centreY), side: 0.5, vertical: 0)
        spun("a Red 30 mm behind, half a ball of side", cue: Vec2(1784, Table.centreY), aim: 0,
             ball: Vec2(1784 - Table.ballDiameter - 30, Table.centreY), side: 0.5, vertical: 0)
        spun("a Red against the back, half a ball of side", cue: Vec2(1784, Table.centreY), aim: 0,
             ball: Vec2(1784 - Table.ballDiameter, Table.centreY), side: 0.5, vertical: 0)
        spun("on the cushion, side and screw back", cue: Vec2(1000, Table.cushionRestReach), aim: .pi / 2,
             ball: Vec2(2200, Table.centreY), side: 0.5, vertical: -0.4)

        // And the picture: the cue ball on the cushion, played away from it, with the cue settled where
        // the game has found it room — once as the game leaves it, and once with the player standing it
        // further up still.
        let picture = FrameDriver()
        _ = picture.placeCueBall(at: Vec2(600, 889))
        picture.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.redsRemaining = 1
            state.ballOn = .red
            state.cueBallInHand = false
            state.pending = nil
            state.ballPositions[BallID.cue] = Vec2(1000, Table.cushionRestReach)
            state.ballPositions[BallID.firstRed] = Vec2(2200, Table.centreY)
        }
        picture.syncWorldFromState()
        picture.aimAngle = .pi / 2                       // across the table, away from the cushion behind
        picture.settleTheCue()
        print(String(format: "  the picture: the cue settled at %.1f°, the tip %+.1f radii up the ball, %3.0f mm of draw; %@",
                     picture.cueElevation * 180 / .pi, picture.spinVertical, picture.maximumCueDraw,
                     (picture.needsTheCueStoodUp ? "the game stood the cue up for this place" : "a level cue had room") as NSString))
        _ = capture(table, picture, preset: .sighting, name: "22-cue-settled-on-the-cushion",
                    into: directory, device: device)
        picture.adjustElevation(by: 25 * .pi / 180)
        print(String(format: "  and lifted 25° by hand: cue at %.1f°, %3.0f mm of draw",
                     picture.cueElevation * 180 / .pi, picture.maximumCueDraw))
        _ = capture(table, picture, preset: .sighting, name: "23-cue-lifted-over-the-cushion",
                    into: directory, device: device)

        // And the cue and the player together. While the balls run the stick waits where the stroke was
        // played, whether the player is still down on the shot or has stood up: standing up does not
        // take the cue to the ball. It is when the stroke is over that the cue is carried to the ball
        // and laid at it, ready for the next shot.
        let follow = FrameDriver()
        _ = follow.placeCueBall(at: Vec2(600, 889))
        follow.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.redsRemaining = 1
            state.ballOn = .red
            state.cueBallInHand = false
            state.pending = nil
            state.ballPositions[BallID.cue] = Vec2(600, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2600, 889)
        }
        follow.syncWorldFromState()
        follow.aimAngle = 0
        let playedFrom = Vec2(600, 889)
        table.holdFraming(.sighting)
        var followClock = CACurrentMediaTime()
        func followFrame() {
            followClock += 1.0 / 60
            follow.update(dt: 1.0 / 60)          // the balls run: the scene alone would not move them
            table.update(with: follow, dt: 1.0 / 60)
        }
        // The **cue action**, not a shot called for by the book: the cue is drawn back by hand and pushed
        // through, which is the only way the follow-through happens at all — and the scene has to be shown
        // the cue charged, with a frame of its own, for the strike to be seen as one.
        _ = follow.beginCueAction()
        follow.moveCue(forwardByMillimetres: -120, over: 0.1)
        followFrame()                 // a frame while the cue is back: the scene sees it charged
        follow.moveCue(forwardByMillimetres: 260, over: 0.1)
        // And the follow-through: the mouse keeps pushing the cue on after the strike, and the tip stops
        // where the follow-through runs out — `FrameDriver.maxFollowThrough` from the middle of the ball —
        // sampled frame by frame through the stroke. The cue is level here, so the cloth never comes into
        // it and the cap is the whole of the answer.
        var followThroughSample = 0.0
        for _ in 0..<25 {
            follow.carryTheCue(forwardByMillimetres: FrameDriver.maxCueSpeed * (1.0 / 60), over: 1.0 / 60)
            followFrame()
            followThroughSample = max(followThroughSample, Double(simd_distance(
                table.cueTipWorld, Table3D.scenePoint(playedFrom, height: Table.ballRadius))) * 1000)
        }
        print(String(format: "  and following through on a level cue: the tip is carried %.0f mm past where the shot was played, of a maximum of %.0f%@",
                     followThroughSample, FrameDriver.maxFollowThrough,
                     (followThroughSample > FrameDriver.maxFollowThrough - 20
                      && followThroughSample < FrameDriver.maxFollowThrough + 20
                      ? " — the cue follows the ball through, and stops where the follow-through runs out"
                      : " — WRONG: the cue does not follow through, or runs past its maximum") as NSString))
        if let ball = follow.cueBall {
            let tipToTheBall = Double(simd_distance(table.cueTipWorld, Table3D.scenePoint(for: ball))) * 1000
            let tipToTheShot = Double(simd_distance(table.cueTipWorld,
                                                   Table3D.scenePoint(playedFrom, height: Table.ballRadius))) * 1000
            print(String(format: "  down on the shot, %@: the ball has run %.0f mm, the cue is %.0f mm from where the shot was played and %.0f mm from the ball",
                         (follow.isDownOnTheShot ? "still down" : "standing") as NSString,
                         ball.position.distance(to: playedFrom), tipToTheShot, tipToTheBall))
        }
        for _ in 0..<25 { followFrame() }
        follow.standUp()
        for _ in 0..<25 { followFrame() }
        if let ball = follow.cueBall {
            let tipToTheBall = Double(simd_distance(table.cueTipWorld, Table3D.scenePoint(for: ball))) * 1000
            let tipToTheShot = Double(simd_distance(table.cueTipWorld,
                                                   Table3D.scenePoint(playedFrom, height: Table.ballRadius))) * 1000
            print(String(format: "  stood up with the balls still running, %@: the ball has run %.0f mm, the cue is still %.0f mm from where the shot was played and %.0f mm from the ball",
                         (follow.isDownOnTheShot ? "still down" : "up") as NSString,
                         ball.position.distance(to: playedFrom), tipToTheShot, tipToTheBall))
        }
        follow.runStrokeToRest()
        for _ in 0..<120 { followFrame() }
        if let ball = follow.cueBall {
            let reach = Double(simd_distance(table.cueTipWorld, Table3D.scenePoint(for: ball))) * 1000
            print(String(format: "  and the stroke over: the cue is carried to the ball — tip %.1f mm from its middle (a radius plus the %.0f mm gap is %.1f)",
                         reach, table.cueTipDistance, Table.ballRadius + table.cueTipDistance))
        }

        // Up and about with the balls still running: a player who has stood up from the shot and put
        // the cue away is free to look around and walk about, and the eye goes over their own feet.
        table.holdFraming(nil)                 // the camera is the player's again, not the probe's
        table.use(.standing)                   // and at the eye level the app starts the player at
        let wandering = FrameDriver()
        _ = wandering.placeCueBall(at: Vec2(600, 889))
        wandering.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.redsRemaining = 1
            state.ballOn = .red
            state.cueBallInHand = false
            state.pending = nil
            state.ballPositions[BallID.cue] = Vec2(600, 889)
            state.ballPositions[BallID.firstRed] = Vec2(2600, 889)
        }
        wandering.syncWorldFromState()
        wandering.aimAngle = 0
        wandering.shoot(angle: 0, power: 0.4, side: 0, vertical: 0)
        var wanderClock = CACurrentMediaTime()
        func wanderFrame() {
            wanderClock += 1.0 / 60
            wandering.update(dt: 1.0 / 60)
            table.update(with: wandering, dt: 1.0 / 60)
        }
        for _ in 0..<20 { wanderFrame() }
        wandering.standUp()                  // S released
        wandering.toggleCueHandling()        // C: the cue put away
        let stoodAt = wandering.playerPosition
        let lookedFrom = wandering.aimAngle * 180 / .pi
        for _ in 0..<60 {                                                 // the arrow keys, held
            wandering.walk(forward: -1, sideways: 0, over: 1.0 / 60)      // walking back from the table
            wanderFrame()
        }
        let walked = wandering.playerPosition.distance(to: stoodAt)
        for _ in 0..<60 {                                                 // the mouse, turning the view
            wandering.turnTheAim(by: 0.6 / 60)
            wanderFrame()
        }
        let eyeIsOverTheirFeet = table.cameraOnTheTable.position.distance(to: wandering.playerPosition)
        print(String(format: "  put the cue away with the balls %@: the player walked %.0f mm, the view turned %+.0f°, the eye %.0f mm over the cloth and %.0f mm from their feet",
                     (wandering.mode == .simulating ? "still running" : "stopped") as NSString,
                     walked, wandering.aimAngle * 180 / .pi - lookedFrom, table.eyeHeight,
                     eyeIsOverTheirFeet))

        // And **X** held: crouched down over the cloth, the eye 150 mm above the bed and the balls at
        // their own height. The player walks up to the table and turns their look onto it first — that is
        // what a crouch is for, a look along the bed at the line of a pot — and the view is written out,
        // because a crouch is a thing to look through rather than a number to be read.
        for _ in 0..<90 {
            wandering.walk(forward: 1, sideways: 0, over: 1.0 / 60)       // walking up to the table
            wanderFrame()
        }
        let centre = Vec2(Table.length / 2, Table.centreY)
        wandering.aimAngle = atan2(centre.y - wandering.playerPosition.y,
                                   centre.x - wandering.playerPosition.x)
        table.setPitch(-12 * .pi / 180)                                   // looking along the bed, not down at it
        table.setCrouching(true)
        for _ in 0..<40 { wanderFrame() }
        print(String(format: "  crouched down over the cloth (X): the eye is %.0f mm above the bed, where standing it is %.0f mm",
                     table.eyeHeight, PlayerCamera.Preset.standing.eyeHeight))
        write(table.renderImage(size: size, device: device),
              name: "29-crouched-over-the-cloth", into: directory)
        table.setCrouching(false)
        for _ in 0..<40 { wanderFrame() }
        // The same spot and the same look, standing: the pair is what the crouch is worth.
        write(table.renderImage(size: size, device: device),
              name: "30-standing-over-the-cloth", into: directory)

        table.holdFraming(nil)
        table.holdFraming(nil)
    }

    /// The wooden rail: a ball can land on the wood, roll along it, come off it again onto the bed, or
    /// drop through the cut a pocket makes in it. Checks the parameters the wood is played with, and
    /// that a ball is only off the table when it comes to rest on the wood or goes past it.
    private static func railProbe() {
        print("rail probe")
        print(String(format: "  the cloth on the wood: rolling resistance %.3f (the bed's %.3f), restitution %.2f (the bed's %.2f)",
                     PhysicsWorld.railRollingResistance, PhysicsWorld.rollingResistance,
                     PhysicsWorld.railRestitution, PhysicsWorld.clothRestitution))
        let onTheWood = Table.cushionHeight + Table.ballRadius

        // Dropped onto the wood of the long rail, with a little pace along the table: how high it comes
        // back, how far it rolls, and what becomes of it when it stops.
        let dropped = PhysicsWorld(balls: [
            Ball(id: BallID.cue, color: .white, position: Vec2(1200, -60), velocity: Vec2(300, 0),
                 height: onTheWood + 40),
        ])
        var apex = 0.0, touchedDownAt = 0.0, clock = 0.0, landed = false
        while clock < 20, !dropped.allAtRest {
            dropped.step(dt: 1.0 / 480.0)
            clock += 1.0 / 480.0
            if dropped.balls[0].height <= onTheWood + 0.5 {
                if !landed { touchedDownAt = dropped.balls[0].position.x }
                landed = true
            }
            if landed { apex = max(apex, dropped.balls[0].height) }
        }
        let stopped = dropped.balls[0]
        print(String(format: "  a ball dropped on the wood: it comes back %.0f mm, rolls %.0f mm along the rail and stops there — %@",
                     apex - onTheWood, stopped.position.x - touchedDownAt,
                     (stopped.onTable ? "still in play" : "a ball forced off the table") as NSString))

        // And off the inner edge: back onto the bed, in play.
        let offTheRail = PhysicsWorld(balls: [
            Ball(id: BallID.cue, color: .white, position: Vec2(1200, -40), velocity: Vec2(0, 300),
                 height: onTheWood),
        ])
        var offClock = 0.0
        while offClock < 4 {
            offTheRail.step(dt: 1.0 / 480.0)
            offClock += 1.0 / 480.0
        }
        let back = offTheRail.balls[0]
        print(String(format: "  a ball rolling off the rail: it lands at y = %.0f mm, %.0f mm above the cloth, %@",
                     back.position.y, back.height - Table.ballRadius,
                     (offTheRail.isOffTheTable(back.position, atRest: true) ? "off the table" : "still in play") as NSString))

        // And the cut a pocket makes through the rail: the wood is not there, so a ball rolling along
        // it drops in.
        let middle = PocketID.bottomMiddle.position
        let pocket = PhysicsWorld(balls: [
            Ball(id: BallID.cue, color: .white, position: Vec2(middle.x, -40), velocity: Vec2(400, 0),
                 height: onTheWood),
        ])
        var pocketClock = 0.0
        while pocketClock < 6 {
            pocket.step(dt: 1.0 / 480.0)
            pocketClock += 1.0 / 480.0
        }
        print(String(format: "  a ball rolling along the wood over a middle pocket: %@",
                     (pocket.balls[0].pottedInto == .bottomMiddle
                      ? "potted through the cut in the rail" : "NOT potted") as NSString))
    }

    /// What a shot makes a noise with: every contact it produced, and the volume each is played at.
    /// A probe has no ears, and the level a weight works out to is the one thing that cannot be heard
    /// in an offscreen run — which is exactly what makes it worth printing.
    private static func noiseProbe() {
        print("what a shot makes a noise with (level = the volume it is played at)")
        func make(_ what: String, cue: Vec2, aim: Double, balls: [(Int, Vec2)], power: Double) {
            let driver = FrameDriver()
            _ = driver.placeCueBall(at: Vec2(Table.baulkLineX, Table.centreY))
            driver.game.withState { state in
                state.ballsOnTable = Set([BallID.cue] + balls.map(\.0))
                state.redsRemaining = balls.count
                state.ballOn = .red
                state.cueBallInHand = false
                state.pending = nil
                state.ballPositions[BallID.cue] = cue
                for (id, position) in balls { state.ballPositions[id] = position }
            }
            driver.syncWorldFromState()
            driver.aimAngle = aim
            driver.shoot(angle: aim, power: power, side: 0, vertical: 0)
            var made: [(impact: FrameDriver.Impact, at: Double)] = []
            var clock = 0.0
            while driver.mode == .simulating, clock < 12 {
                _ = driver.update(dt: 1.0 / 120.0)
                // The stick is the player's hand, and the hand is still: without this the parked cue
                // keeps the speed the strike left it with and goes on striking the ball as it comes
                // back, which the game never does.
                driver.carryTheCue(forwardByMillimetres: 0, over: 1.0 / 120.0)
                for impact in driver.takeImpacts() { made.append((impact, clock)) }
                clock += 1.0 / 120.0
            }
            let told = made.map { heard in
                String(format: "%@ %.0f mm/s → %.3f", heard.impact.kind.rawValue, heard.impact.speed,
                       GameAudio.level(of: heard.impact))
            }.joined(separator: ",  ")
            print("  \(what): \(told.isEmpty ? "nothing at all" : told)")
            // And how much of that is swallowed as the hop a cushion threw the ball into: the same test
            // the game plays by, so what is printed here and what is heard cannot drift apart.
            var lastWood = -Double.greatestFiniteMagnitude
            var swallowed = 0
            var shortestGap = Double.infinity
            for (impact, at) in made {
                if impact.kind == .bed, lastWood > -Double.greatestFiniteMagnitude {
                    shortestGap = min(shortestGap, at - lastWood)
                }
                if GameAudio.isTheHopAfterAWoodContact(impact, sinceTheWood: at - lastWood) { swallowed += 1 }
                if impact.kind == .cushion || impact.kind == .throat { lastWood = at }
            }
            if swallowed > 0 {
                print("    and \(swallowed) of those are the hop after a cushion or a throat, and are not played")
            } else if shortestGap < .infinity {
                // Nothing was swallowed, and the first cloth tap after a cushion says why: it came
                // after the window had run out, so it is a contact of its own.
                print(String(format: "    and the first cloth tap after a cushion came %.0f ms later, outside the %.0f ms window",
                             shortestGap * 1000, GameAudio.clothQuietAfterAWoodContact * 1000))
            }
        }
        // Across the table into the side cushion, softly and then hard. A hard cushion hit throws the
        // ball up off the cloth as well, so it makes two noises: the cushion, and the cloth it comes
        // back down on.
        // 1000 mm up the table: clear of the middle pocket, which is cut into the side cushion at the
        // table's own middle, so the ball really meets the cushion and not a hole in it.
        make("a soft shot into a cushion", cue: Vec2(1000, Table.centreY), aim: .pi / 2,
             balls: [], power: 0.12)
        make("a firm shot into a cushion", cue: Vec2(1000, Table.centreY), aim: .pi / 2,
             balls: [], power: 0.8)
        make("a firm shot into a ball", cue: Vec2(1000, Table.centreY), aim: 0,
             balls: [(BallID.firstRed, Vec2(2200, Table.centreY))], power: 0.8)
        // A ball into a corner's **throat**: one of the fan across the mouth, aimed wide enough that
        // what it meets is the facing rather than the hole. The throat is cut in the cushion's own
        // section, so it answers with a leaning face — the case the throat's half of the hop rule is
        // there for.
        let cut = PocketID.bottomLeft.cut
        let fromTheTable = Vec2(560, 560)
        let wideOfTheMouth = cut.mouth + cut.axis.perpendicular * 25 - fromTheTable
        make("a ball into a corner's throat", cue: fromTheTable,
             aim: atan2(wideOfTheMouth.y, wideOfTheMouth.x), balls: [], power: 0.267)
        // **The first break of a session** is the one sound in the game that has been called a fault:
        // the picture is still being warmed up, so the frames around the pack's collision are long ones,
        // and every substep of a long frame is drained into that one frame. This is what that is worth.
        do {
            let driver = FrameDriver()
            _ = driver.placeCueBall(at: Vec2(Table.baulkLineX, Table.centreY))
            driver.aimAngle = 0
            driver.shoot(angle: 0, power: 0.8, side: 0, vertical: 0)
            var worst = 0
            var frames = 0
            var clock = 0.0
            while driver.mode == .simulating, clock < 6 {
                let dt = frames < 10 ? 0.05 : 1.0 / 120.0     // the warm-up: ten frames of fifty
                _ = driver.update(dt: dt)
                driver.carryTheCue(forwardByMillimetres: 0, over: dt)
                worst = max(worst, driver.takeImpacts().filter { $0.kind == .ballOnBall }.count)
                clock += dt
                frames += 1
            }
            print("  a break with a slow start (ten frames of 50 ms): the worst frame carries \(worst) "
                  + "ball-on-ball contacts, and a chain of them inside "
                  + String(format: "%.0f ms", GameAudio.betweenContactsOfAKind * 1000)
                  + " is heard as the one crack it is, so they are not played as a run")
        }
    }

    /// Renders the player's own view with the ghost ball showing and reads the colour where it is
    /// drawn. A hint should be a blend with the cloth behind it, not a solid white ball.
    private static func ghostProbe(_ table: Table3D, device: MTLDevice) {
        let driver = FrameDriver()
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.ballPositions[BallID.firstRed] = Vec2(2200, 769)
            state.cueBallInHand = true
            state.pending = .placeCueBallInD
        }
        driver.syncWorldFromState()
        guard driver.placeCueBall(at: Vec2(737, 769)) else {
            print("  ghost ball: could not set up a shot to aim at")
            return
        }
        driver.aimAngle = 0                      // straight at the Red
        table.use(.sighting)
        table.aimingAids = .cueLine
        for _ in 0..<240 { table.update(with: driver, dt: 1.0 / 120.0) }

        guard let contact = driver.predictedFirstContact() else {
            print("  ghost ball: no contact to show")
            return
        }
        let image = table.renderImage(size: size, device: device)
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
        let imageSize = CGSize(width: rep.pixelsWide, height: rep.pixelsHigh)
        // Sampled on the ball's own surface, a little to the side of the aim line so the line's end
        // is not what gets read.
        let onTheGhost = contact.point + Vec2(0, 15)
        guard let p = table.project(Table3D.scenePoint(onTheGhost, height: Table.ballRadius),
                                    imageSize: imageSize) else { return }
        let found = sample(rep, Int(p.x), Int(p.y))
        let middle = table.project(Table3D.scenePoint(contact.point, height: Table.ballRadius), imageSize: imageSize) ?? .zero
        print(String(format: "  ghost ball: cue at (%.0f, %.0f) aiming %.0f°, first contact (%.0f, %.0f) at pixel (%.0f, %.0f) of %dx%d",
                     driver.cueBall?.position.x ?? -1, driver.cueBall?.position.y ?? -1,
                     driver.aimAngle * 180 / .pi, contact.point.x, contact.point.y, middle.x, middle.y,
                     rep.pixelsWide, rep.pixelsHigh))
        print(String(format: "  ghost ball: #%02x%02x%02x beside it (a solid white ball reads #ffffff)",
                     Int(found.r * 255), Int(found.g * 255), Int(found.b * 255)))

        // Anything the aids paint on the cloth that is not the ball itself is a shadow. Rendering
        // with and without them and looking sideways avoids the ball and the line.
        table.aimingAids = .off
        table.update(with: driver, dt: 1.0 / 120.0)   // let the aid layer actually go
        let bare = table.renderImage(size: size, device: device)
        table.aimingAids = .cueLine
        guard let marked = rep as NSBitmapImageRep?,
              let without = bare.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }) else { return }
        var worst = 0.0
        for degrees in stride(from: 0.0, to: 360.0, by: 45.0) where abs(sin(degrees * .pi / 180)) > 0.2 {
            for radius in [70.0, 110.0] {
                let offset = Vec2(cos(degrees * .pi / 180), sin(degrees * .pi / 180)) * radius
                guard let q = table.project(Table3D.scenePoint(contact.point + offset), imageSize: imageSize),
                      q.x > 1, q.x < CGFloat(without.pixelsWide) - 1,
                      q.y > 1, q.y < CGFloat(without.pixelsHigh) - 1 else { continue }
                let a = sample(marked, Int(q.x), Int(q.y)), b = sample(without, Int(q.x), Int(q.y))
                worst = max(worst, abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b))
            }
        }
        print(String(format: "  cloth beside the ghost: worst change when the aids are hidden %.3f (a shadow would show up here)",
                     worst))

        // And how much the ghost itself tints what is behind it: the Red ball is directly behind the
        // contact point, so this is the aid's own contribution over it.
        let behind = sample(without, Int(middle.x), Int(middle.y))
        let overTheAid = sample(marked, Int(middle.x), Int(middle.y))
        print(String(format: "  ghost ball over the Red: #%02x%02x%02x with the aid, #%02x%02x%02x without it",
                     Int(overTheAid.r * 255), Int(overTheAid.g * 255), Int(overTheAid.b * 255),
                     Int(behind.r * 255), Int(behind.g * 255), Int(behind.b * 255)))

        // Four points the same distance from the middle, all off the aim line. What the ball is
        // sitting over differs between them — which is the point of a transparent ball — so it is
        // the change the aid makes, not the raw colour, that has to come out the same: a ball drawn
        // in two layers would leave one of these at twice the density of the others.
        var coverages: [(String, Double)] = []
        for (name, offset, lift) in [("left", Vec2(0, 15), 0.0), ("right", Vec2(0, -15), 0.0),
                                     ("up", Vec2.zero, 15.0), ("down", Vec2.zero, -15.0)] {
            let point = offset == .zero ? contact.point : contact.point + offset
            let height = Table.ballRadius + lift
            guard let q = table.project(Table3D.scenePoint(point, height: height), imageSize: imageSize),
                  q.x > 1, q.x < CGFloat(rep.pixelsWide) - 1, q.y > 1, q.y < CGFloat(rep.pixelsHigh) - 1 else { continue }
            let aid = sample(marked, Int(q.x), Int(q.y)), plain = sample(without, Int(q.x), Int(q.y))
            coverages.append((name, abs(aid.r - plain.r) + abs(aid.g - plain.g) + abs(aid.b - plain.b)))
        }
        let list = coverages.map { String(format: "%@ %.3f", $0.0, $0.1) }.joined(separator: "  ")
        // These differ because a transparent ball shows more change over a dark background than a
        // bright one, which is expected; the picture below is what shows the ball is one layer.
        print(String(format: "  what the ghost adds at four points: %@", list as NSString))

        // And a picture of it, in screen space around the ghost's middle.
        print("  the aid's own pixels around the ghost (# strong, + faint):")
        let cx = Int(middle.x), cy = Int(middle.y)
        for row in stride(from: -24, through: 24, by: 3) {
            var line = ""
            for column in stride(from: -48, through: 48, by: 2) {
                let a = sample(marked, cx + column, cy + row), b = sample(without, cx + column, cy + row)
                let delta = abs(a.r - b.r) + abs(a.g - b.g) + abs(a.b - b.b)
                line.append(delta > 0.6 ? "#" : (delta > 0.1 ? "+" : "."))
            }
            print("  |\(line)|")
        }

        // The line the ball being aimed at will take. This shot is square, so the line of centres runs
        // straight on from the Red: it should be drawn on the second step and not the first, and it
        // should really paint — a node that is showing but paints nothing looks the same in code.
        let onTheLine = Vec2(2200, 769) + Vec2(200, 0)
        func clothOnTheLine(_ aids: Table3D.AimingAids) -> (drawn: Bool, brightness: Double) {
            table.aimingAids = aids
            table.update(with: driver, dt: 1.0 / 120.0)
            let shot = table.renderImage(size: size, device: device)
            guard let tiff = shot.tiffRepresentation, let picture = NSBitmapImageRep(data: tiff),
                  let q = table.project(Table3D.scenePoint(onTheLine, height: Table3D.markingHeightAboveCloth),
                                        imageSize: CGSize(width: picture.pixelsWide, height: picture.pixelsHigh))
            else { return (table.aimedBallLineShown, 0) }
            let c = sample(picture, Int(q.x), Int(q.y))
            return (table.aimedBallLineShown, Double(c.r) + Double(c.g) + Double(c.b))
        }
        let withIt = clothOnTheLine(.both)
        let withoutIt = clothOnTheLine(.off)
        let cueLineOnly = clothOnTheLine(.cueLine)
        print(String(format: "  the ball on's line: 400 mm on from the Red the cloth reads %.3f with it and %.3f without it — and %.3f with the line of aim alone, %@",
                     withIt.brightness, withoutIt.brightness, cueLineOnly.brightness,
                     (withIt.drawn && !cueLineOnly.drawn && withIt.brightness > withoutIt.brightness + 0.02
                      ? "so it is drawn on the second step only" : "WRONG: it is not drawn as it should be") as NSString))

        // And it turns red when the ball being aimed at is not one the cue ball may strike first: with
        // the Yellow the ball on and the Red the one being aimed at, the shot would be a foul.
        let green = withIt.brightness > withoutIt.brightness + 0.02 && !table.aimedBallLineIsFoul
        driver.game.withState { $0.ballOn = .colourOfSequence(.yellow) }
        table.aimingAids = .both
        table.update(with: driver, dt: 1.0 / 120.0)
        let foul = table.aimedBallLineIsFoul && table.aimedBallLineShown
        driver.game.withState { $0.ballOn = .red }
        table.update(with: driver, dt: 1.0 / 120.0)
        print("  the ball on's line: \(green ? "green" : "WRONG: not green") while the Red is on, and "
              + (foul ? "red" : "WRONG: not red") + " while it is not")

        // And a shot with nothing in the way at all, aimed at a cushion: the ghost goes to the
        // cushion, to the point the cue ball's centre will arrive at.
        let atACushion = FrameDriver()
        let from = Vec2(Table.baulkLineX - 100, Table.centreY - 100)
        atACushion.game.withState { state in
            state.ballsOnTable = [BallID.cue]
            state.ballPositions[BallID.cue] = from
            state.cueBallInHand = true
            state.pending = .placeCueBallInD
        }
        atACushion.syncWorldFromState()
        _ = atACushion.placeCueBall(at: from)
        atACushion.aimAngle = .pi / 2                 // straight up the table, at the top cushion
        // Aimed at a cushion there is no ball for a line to belong to, even on the second step.
        table.aimingAids = .both
        for _ in 0..<240 { table.update(with: atACushion, dt: 1.0 / 120.0) }
        print("  ghost ball at a cushion: the aids are on their second step and the ball on's line is "
              + (table.aimedBallLineShown ? "WRONG: drawn with no ball to belong to" : "not drawn"))
        table.aimingAids = .cueLine
        table.update(with: atACushion, dt: 1.0 / 120.0)
        guard let onTheCushion = atACushion.predictedFirstContact() else {
            print("  ghost ball at a cushion: no contact to show")
            return
        }
        let wanted = Vec2(from.x, Table.width - Table.ballRadius)
        print(String(format: "  ghost ball at a cushion: cue at (%.0f, %.0f) aiming %.0f°, contact %@ at (%.0f, %.0f), %.2f mm from where a ball's centre reaches the face",
                     from.x, from.y, atACushion.aimAngle * 180 / .pi,
                     "\(onTheCushion.contact)" as NSString,
                     onTheCushion.point.x, onTheCushion.point.y,
                     onTheCushion.point.distance(to: wanted)))

        // It is drawn on the cushion, and it casts nothing: with the aid hidden the cloth and the
        // cushion beside it are unchanged.
        let markedCushion = table.renderImage(size: size, device: device)
        table.aimingAids = .off
        table.update(with: atACushion, dt: 1.0 / 120.0)
        let plainCushion = table.renderImage(size: size, device: device)
        table.aimingAids = .cueLine
        guard let here = markedCushion.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }),
              let there = plainCushion.tiffRepresentation.flatMap({ NSBitmapImageRep(data: $0) }),
              let at = table.project(Table3D.scenePoint(onTheCushion.point, height: Table.ballRadius),
                                     imageSize: CGSize(width: here.pixelsWide, height: here.pixelsHigh)) else { return }
        let withTheAid = sample(here, Int(at.x), Int(at.y)), plain = sample(there, Int(at.x), Int(at.y))
        print(String(format: "  ghost ball at a cushion: #%02x%02x%02x over the cushion with the aid, #%02x%02x%02x without it",
                     Int(withTheAid.r * 255), Int(withTheAid.g * 255), Int(withTheAid.b * 255),
                     Int(plain.r * 255), Int(plain.g * 255), Int(plain.b * 255)))
    }

    /// Answers a foul twice over and counts the decision buttons each time. A set that is answered
    /// has to go away, or the next one lands on top of it and neither can be read.
    private static func buttonProbe() {
        let scene = TableScene(size: size)
        scene.table3D = Table3D()
        let driver = scene.controller
        print("button probe")
        for round in 1...3 {
            // One Red in clear view, the cue ball at the baulk end: hitting nothing is a foul and,
            // because the Red was there for the taking, a foul and a miss (Rule 14(b)).
            driver.game.withState { state in
                state.ballsOnTable = [BallID.cue, BallID.firstRed]
                state.ballPositions[BallID.cue] = Vec2(1000, 889)
                state.ballPositions[BallID.firstRed] = Vec2(3400, 250)
                state.ballOn = .red
                state.pending = nil
            }
            driver.syncWorldFromState()
            driver.aimAngle = .pi / 2          // across the table, nowhere near the Red
            driver.shoot(angle: .pi / 2, power: 0.8, side: 0, vertical: 0)
            driver.runStrokeToRest()
            scene.refresh(force: true)
            let foulButtons = scene.buttonNodesOnScreen
            let decision = driver.pending != nil
            var kind = "none"
            if case .afterMiss = driver.pending { kind = "foul and a miss" }
            else if case .afterFoul = driver.pending { kind = "foul" }
            if decision { driver.playFromPositionLeft() }
            scene.refresh(force: true)
            print(String(format: "  round %d: %@ — %d buttons with the choice to make, %d after answering",
                         round, kind as NSString, foulButtons, scene.buttonNodesOnScreen))
        }

        // One more foul, left unanswered, so the game is in a decision to build the colour choice
        // on top of: that is the state the game is really in when it asks which colour is on.
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.firstRed]
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.firstRed] = Vec2(3400, 250)
            state.ballOn = .red
            state.cueBallInHand = false
            state.pending = nil
        }
        driver.syncWorldFromState()
        driver.shoot(angle: .pi / 2, power: 0.7, side: 0, vertical: 0)
        driver.runStrokeToRest()
        print("  left deciding after a foul: mode \(driver.mode), may strike: \(driver.canStrike)")

        // Now the colour choice, in the state the game is really in when it asks.
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.yellow, BallID.green]
            state.ballOn = .anyColour
            state.nominatedColour = nil
            state.cueBallInHand = false
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.yellow] = Vec2(2000, 889)
            state.ballPositions[BallID.green] = Vec2(2500, 889)
            state.pending = .nominateColour(options: [.yellow, .green])
        }
        driver.syncWorldFromState()
        scene.refresh(force: true)
        print("  choosing a colour: \(scene.buttonNodesOnScreen) colours offered, mode \(driver.mode)")

        // The striker can look around the table while deciding: the aim must turn.
        let before = driver.aimAngle * 180 / .pi
        scene.steer(at: CGPoint(x: size.width / 2, y: size.height / 2), flags: [])
        scene.steer(at: CGPoint(x: size.width / 2 + 150, y: size.height / 2), flags: [])
        print(String(format: "  looked around while choosing: aim %+.1f to %+.1f deg, may strike: %@",
                     before, driver.aimAngle * 180 / .pi, (driver.canStrike ? "yes" : "no") as NSString))

        // Striking without declaring a colour: a seven point foul and a miss. The stroke is played
        // the way the player plays it, through the charge.
        driver.beginCharge(at: CACurrentMediaTime())
        driver.power = 0.4
        driver.releaseShot()
        driver.runStrokeToRest()
        scene.refresh(force: true)
        var undeclared = "nothing"
        if case .afterMiss = driver.pending { undeclared = "foul and a miss" }
        else if case .afterFoul = driver.pending { undeclared = "foul" }
        print("  struck without declaring: \(undeclared), scores \(driver.scores)")

        // And the colours stay on offer until the stroke is played, so the striker can change their
        // mind about which colour to go for.
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.yellow, BallID.green, BallID.brown,
                                  BallID.blue, BallID.pink, BallID.black]
            state.ballOn = .anyColour
            state.nominatedColour = nil
            state.cueBallInHand = false
            state.pending = .nominateColour(options: BallColor.coloursInAscendingOrder)
        }
        driver.syncWorldFromState()
        scene.refresh(force: true)
        print("  playing for a colour: \(scene.buttonNodesOnScreen) colours offered, none chosen")
        driver.chooseColour(.blue)
        scene.refresh(force: true)
        print("  chose blue: \(scene.buttonNodesOnScreen) buttons still up, blue chosen: \(driver.nominatedColour == .blue)")
        driver.chooseColour(.pink)
        scene.refresh(force: true)
        print("  changed mind to pink: \(driver.nominatedColour == .pink)")
        driver.shoot(angle: 0, power: 0.5, side: 0, vertical: 0)
        scene.refresh(force: true)
        print("  once the stroke is played: \(scene.buttonNodesOnScreen) buttons")

        // Only the Black left, the striker more than seven ahead: the frame is not over, and the
        // claim is a button rather than a decision the game makes for them (Section 2 Rule 1(b)).
        driver.newFrame(startingPlayer: 0)
        driver.game.withState { state in
            state.redsRemaining = 0
            state.ballsOnTable = [BallID.black]
            state.ballOn = .colourOfSequence(.black)
            state.ballPositions[BallID.black] = Vec2(3200, 889)
            state.scores = [48, 40]
        }
        driver.syncWorldFromState()
        _ = driver.placeCueBall(at: Vec2(Table.baulkLineX - 100, Table.centreY - 100))
        scene.refresh(force: true)
        print("  Black the only ball and eight ahead: mode \(driver.mode), may claim: \(driver.canClaimTheFrame), may strike: \(driver.canStrike), \(scene.buttonNodesOnScreen) button on screen, frame over: \(driver.isFrameOver)")
        driver.claimTheFrame()
        scene.refresh(force: true)
        print("  claimed the frame: \(scene.buttonNodesOnScreen) buttons, frame over: \(driver.isFrameOver), \(driver.status)")

        // Only the Black left with the *non*-striker more than seven ahead: the striker needs snookers, so
        // the frame is the non-striker's without being asked for (Section 2 Rule 1(c)) — it is awarded the
        // moment the position is noticed, and there is nothing left for a button to do.
        driver.newFrame(startingPlayer: 0)
        driver.game.withState { state in
            state.redsRemaining = 0
            state.ballsOnTable = [BallID.black]
            state.ballOn = .colourOfSequence(.black)
            state.ballPositions[BallID.black] = Vec2(3200, 889)
            state.scores = [40, 48]
        }
        driver.syncWorldFromState()
        _ = driver.placeCueBall(at: Vec2(Table.baulkLineX - 100, Table.centreY - 100))
        scene.refresh(force: true)
        print("  Black the only ball, the non-striker eight ahead: frame over: \(driver.isFrameOver), "
              + "winner: \(driver.winner.map { driver.playerNames[$0] } ?? "none"), "
              + "may claim: \(driver.canClaimTheFrame), \(scene.buttonNodesOnScreen) buttons on screen")
        print("  \(driver.status)")

        // Potting the Black to level the scores: the Black is re-spotted on its spot, the players
        // draw lots, and the winner plays from in-hand (Section 3 Rule 4(a)-(b)).
        driver.newFrame(startingPlayer: 0)
        driver.game.decideTheDraw = { 1 }
        driver.game.withState { state in
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.black)
            state.ballsOnTable = [BallID.black]
            state.ballPositions[BallID.black] = Vec2(400, 400)   // on the line into the corner
            state.scores = [33, 40]                              // seven behind: the Black levels it
        }
        driver.syncWorldFromState()
        _ = driver.placeCueBall(at: Vec2(737, 737))
        driver.shoot(angle: atan2(400.0 - 737.0, 400.0 - 737.0), power: 0.45, side: 0, vertical: -0.45)
        driver.runStrokeToRest()
        scene.refresh(force: true)
        let blackIsBack = driver.game.state.ballPositions[BallID.black].map { $0.distance(to: Table.blackSpot) < 0.001 } ?? false
        print("  potting the Black to level: scores \(driver.scores), re-spotted: \(driver.game.state.respottedBlack), on its spot: \(blackIsBack), cue ball in hand: \(driver.game.state.cueBallInHand), frame over: \(driver.isFrameOver)")
        print("  \(driver.status)")

        // N asks before it throws the frame away: two buttons go up, and neither answering nor keeping
        // the frame moves a ball.
        driver.newFrame(startingPlayer: 0)
        _ = driver.placeCueBall(at: Vec2(600, 889))
        scene.refresh(force: true)
        scene.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                             timestamp: 0, windowNumber: 0, context: nil,
                                             characters: "n", charactersIgnoringModifiers: "n",
                                             isARepeat: false, keyCode: 0)!)
        scene.refresh(force: true)
        print("  N pressed: asking \(driver.isAskingAboutANewFrame), \(scene.buttonNodesOnScreen) buttons on screen, mode still \(driver.mode), can strike: \(driver.canStrike)")
        driver.keepPlaying()
        scene.refresh(force: true)
        print("  kept the frame: asking \(driver.isAskingAboutANewFrame), \(scene.buttonNodesOnScreen) buttons, mode \(driver.mode)")
        driver.keepPlaying()

        // The frame being **over** is exactly when a new one is asked for, and there is nothing left to
        // guard: N starts one there and then, with no question in the way.
        driver.newFrame(startingPlayer: 0)
        _ = driver.placeCueBall(at: Vec2(600, 889))
        driver.game.withState { $0.frameOver = true; $0.winner = 0 }
        driver.syncWorldFromState()
        scene.refresh(force: true)
        scene.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                             timestamp: 0, windowNumber: 0, context: nil,
                                             characters: "n", charactersIgnoringModifiers: "n",
                                             isARepeat: false, keyCode: 0)!)
        scene.refresh(force: true)
        let frameOverButtons = scene.buttonNodesOnScreen
        print("  N pressed with the frame over: asking \(driver.isAskingAboutANewFrame), frame over: \(driver.isFrameOver), "
              + "\(frameOverButtons) buttons on screen, scores \(driver.scores) — "
              + ((!driver.isAskingAboutANewFrame && !driver.isFrameOver) ? "a new frame, with no question" : "WRONG: it asked anyway"))
        driver.keepPlaying()

        // R asks before it re-racks, exactly as N does: a re-rack nullifies every score in the frame
        // (Section 3 Rule 17), so it is not something to do on a slipped key.
        driver.game.withState { state in state.scores = [48, 40] }   // something for the question to guard
        let beforeTheQuestion = driver.scores
        guard let rKey = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                          timestamp: 0, windowNumber: 0, context: nil,
                                          characters: "r", charactersIgnoringModifiers: "r",
                                          isARepeat: false, keyCode: 0) else { return }
        scene.keyDown(with: rKey)
        scene.refresh(force: true)
        print("  R pressed: asking \(driver.isAskingAboutAReRack), \(scene.buttonNodesOnScreen) buttons on screen, may strike: \(driver.canStrike); the scores are still \(driver.scores)")
        driver.reRackTheFrame()
        scene.refresh(force: true)
        print("  and answering it: scores \(driver.scores) (were \(beforeTheQuestion))")

    }

    /// The score board the player reads: the frame number above it, and left to right a name, a score,
    /// the frames each player has won, a score, and a name. The harness has no eyes for the picture, so
    /// it prints what the board says and where the plates sit — that is what catches two plates drawn
    /// over one another, or the row running off the side of the window.
    private static func scoreBoardProbe() {
        // The HUD is built when the scene is presented, which is what puts the board on the screen.
        let scene = TableScene(size: size)
        scene.table3D = Table3D()
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.presentScene(scene)
        let driver = scene.controller

        print("score board probe")
        // The first player pots the last Black and takes the frame.
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.black]
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.black)
            state.cueBallInHand = false
            state.pending = nil
            state.scores = [60, 20]
            state.ballPositions[BallID.cue] = Vec2(737, 737)
            state.ballPositions[BallID.black] = Vec2(400, 400)
        }
        driver.syncWorldFromState()
        driver.shoot(angle: atan2(400.0 - 737.0, 400.0 - 737.0), power: 0.345, side: 0, vertical: -0.45)
        driver.runStrokeToRest()
        scene.refresh(force: true)
        print("  the frame won: \(driver.winner.map { driver.playerNames[$0] } ?? "none"), frames won \(driver.framesWon), frame \(driver.frameNumber)")
        reportTheBoard(scene, when: "at the end of the frame")

        // A new frame carries the frames won over and takes the next number.
        driver.startTheNewFrame()
        _ = driver.placeCueBall(at: Vec2(600, 889))
        driver.game.withState { $0.scores = [147, 6] }    // three digits, to fill the score plate
        scene.refresh(force: true)
        reportTheBoard(scene, when: "in the next frame")

        // The other player at the table: the turn marker moves to the other name plate.
        driver.game.withState { $0.currentPlayer = 1 }
        scene.refresh(force: true)
        reportTheBoard(scene, when: "with the second player at the table")

        // And the narrowest window the app allows, where the board's ends and the labels that share its
        // line are closest together: they still have to keep clear of each other.
        let narrow = TableScene(size: CGSize(width: 900, height: 620))
        narrow.table3D = Table3D()
        let narrowView = SKView(frame: NSRect(origin: .zero, size: narrow.size))
        narrowView.presentScene(narrow)
        narrow.refresh(force: true)
        let corner = narrow.topLineOnScreen
        let boardRight = narrow.scoreBoardPlateFrames.map(\.maxX).max() ?? 0
        let boardLeft = narrow.scoreBoardPlateFrames.map(\.minX).min() ?? 0
        print(String(format: "  at 900x620: the board is %d..%d, \"%@\" ends at %d, \"%@\" starts at %d",
                     Int(boardLeft), Int(boardRight),
                     corner.helpHint as NSString, Int(corner.helpFrame.maxX),
                     corner.view as NSString, Int(corner.viewFrame.minX)))
    }

    /// Everything the score board says, and where each of its plates sits, for the probe above.
    private static func reportTheBoard(_ scene: TableScene, when: String) {
        let board = scene.scoreBoardOnScreen
        print("  \(when):  \(board.frame)")
        print("    the plates: \(board.plates.joined(separator: " | "))")
        let frames = scene.scoreBoardPlateFrames
        // The plates are laid edge to edge, so a join is where one plate's left edge meets the last
        // one's right edge: anything crossing that line by more than a hair is two plates drawn over
        // each other, and anything stopping short of it is a gap in what should be one bar.
        let overlaps = (1..<frames.count).contains { frames[$0].minX < frames[$0 - 1].maxX - 0.5 }
        let joined = (1..<frames.count).allSatisfy { frames[$0].minX <= frames[$0 - 1].maxX + 0.5 }
        let inside = frames.allSatisfy { $0.minX >= 0 && $0.maxX <= size.width
                                        && $0.minY >= 0 && $0.maxY <= size.height }
        let left = Int(frames.map(\.minX).min() ?? 0)
        let right = Int(frames.map(\.maxX).max() ?? 0)
        let bottom = Int(frames.map(\.minY).min() ?? 0)
        let top = Int(frames.map(\.maxY).max() ?? 0)
        print("    the row: \(left)..\(right) across, \(bottom)..\(top) up — "
              + (overlaps ? "SOME plates overlapping" : "no two plates overlapping")
              + ", " + (joined ? "joined into one bar" : "NOT joined: a gap")
              + ", " + (inside ? "all inside the window" : "NOT all inside the window"))
        let marker = scene.scoreBoardMarkerOnScreen
        print("    the turn marker is drawn on plate \(marker.map(String.init) ?? "none") "
              + "(\(marker.map { board.plates[$0] } ?? "nobody") at the table)")
    }

    /// The help panel and the two questions Esc asks. The harness can press the keys and read the labels
    /// back, which is the whole of what these have to show: that Esc asks about a new game without
    /// clearing anything, that Esc again carries on where the match was, that answering it takes the
    /// match back to its first frame with nothing won, and that H shows and hides the list of controls.
    private static func helpProbe() {
        let scene = TableScene(size: size)
        scene.table3D = Table3D()
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.presentScene(scene)
        let driver = scene.controller

        print("help and new game probe")
        // A frame won and another one on the way, so that a new game has something to clear.
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.black]
            state.redsRemaining = 0
            state.ballOn = .colourOfSequence(.black)
            state.cueBallInHand = false
            state.pending = nil
            state.scores = [60, 20]
            state.ballPositions[BallID.cue] = Vec2(737, 737)
            state.ballPositions[BallID.black] = Vec2(400, 400)
        }
        driver.syncWorldFromState()
        driver.shoot(angle: atan2(400.0 - 737.0, 400.0 - 737.0), power: 0.345, side: 0, vertical: -0.45)
        driver.runStrokeToRest()
        driver.startTheNewFrame()
        _ = driver.placeCueBall(at: Vec2(600, 889))
        driver.game.withState { $0.scores = [31, 12] }
        scene.refresh(force: true)
        print("  before the question: frame \(driver.frameNumber), frames won \(driver.framesWon), scores \(driver.scores)")

        func press(_ characters: String, keyCode: UInt16) {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                               timestamp: 0, windowNumber: 0, context: nil,
                                               characters: characters, charactersIgnoringModifiers: characters,
                                               isARepeat: false, keyCode: keyCode) else { return }
            scene.keyDown(with: event)
            scene.refresh(force: true)
        }
        let escape = "\u{1b}"

        press(escape, keyCode: 53)
        print("  Esc: asking about a new game \(driver.isAskingAboutANewGame), may strike \(driver.canStrike), "
              + "\(scene.buttonNodesOnScreen) buttons")
        print("  the status line: \"\(scene.statusOnScreen)\"")

        press(escape, keyCode: 53)
        print("  Esc again: asking \(driver.isAskingAboutANewGame), and the match untouched — "
              + "frame \(driver.frameNumber), frames won \(driver.framesWon), scores \(driver.scores)")

        press(escape, keyCode: 53)
        driver.startTheNewGame()
        scene.refresh(force: true)
        print("  answering it: frame \(driver.frameNumber), frames won \(driver.framesWon), "
              + "scores \(driver.scores), mode \(driver.mode)")

        press("h", keyCode: 4)
        let panel = scene.helpPanelOnScreen
        let top = scene.topLineOnScreen
        print("  H: help shown \(panel.isShown), \(panel.lines.count) lines, panel "
              + "\(Int(panel.frame.width))x\(Int(panel.frame.height)) at x \(Int(panel.frame.midX)), y \(Int(panel.frame.midY))"
              + ", longest line \(Int(panel.widestLine))")
        print("  the top line: \"\(top.helpHint)\" at x \(Int(top.hintAt.x)), "
              + "\"\(top.view)\" at x \(Int(top.viewAt.x)), both at y \(Int(top.hintAt.y))")
        press("h", keyCode: 4)
        print("  H again: help shown \(scene.helpPanelOnScreen.isShown)")

        // F is the window's own switch and there is no window on the harness's scene to switch, so what the
        // probe can check is that the key is taken by the game rather than passed on for the system to beep.
        let passesBefore = scene.keysPassedOn
        press("f", keyCode: 3)
        print("  F: keys passed on to the system, \(scene.keysPassedOn - passesBefore) (wanted none)")
    }

    /// The two ways `N` can end a frame that is still on: the player with fewer points concedes it — it
    /// counts for the other and the next frame is racked — or, with the scores level, the frame is
    /// re-racked instead and nothing is won. The question says which of the two it will be, so the probe
    /// reads the question and the board back on either side of answering it.
    private static func newFrameProbe() {
        let scene = TableScene(size: size)
        scene.table3D = Table3D()
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.presentScene(scene)
        let driver = scene.controller

        print("new frame probe")
        guard driver.placeCueBall(at: Vec2(600, 889)) else { return }
        driver.game.withState { $0.scores = [40, 20] }         // Prof. Snoo ahead, Dr. Ker behind
        driver.askToStartANewFrame()
        scene.refresh(force: true)
        print("  behind: \"\(scene.statusOnScreen)\"")
        driver.startTheNewFrame()
        scene.refresh(force: true)
        print("  conceded: frames won \(driver.framesWon), frame \(driver.frameNumber), scores \(driver.scores)")
        print("  the log: \(driver.commentary.suffix(2).joined(separator: " / "))")

        guard driver.placeCueBall(at: Vec2(600, 889)) else { return }
        driver.game.withState { $0.scores = [12, 12] }         // level
        driver.askToStartANewFrame()
        scene.refresh(force: true)
        print("  level: \"\(scene.statusOnScreen)\"")
        driver.startTheNewFrame()
        scene.refresh(force: true)
        print("  re-racked: frames won \(driver.framesWon), frame \(driver.frameNumber), scores \(driver.scores)")
    }

    /// The caption under "Points remaining": it is on the screen exactly when the player at the table is
    /// behind by more than the table still holds, and off it otherwise — including when they are behind by
    /// exactly what the balls are worth, which they can catch up on the balls alone.
    private static func snookersProbe() {
        let scene = TableScene(size: size)
        scene.table3D = Table3D()
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.presentScene(scene)
        let driver = scene.controller

        print("snookers probe")
        func report(_ what: String) {
            scene.refresh(force: true)
            print("  \(what): points remaining \(driver.remainingPoints), needs snookers "
                  + "\(driver.theStrikerNeedsSnookers), on the screen \"\(scene.snookersRequiredOnScreen)\"")
        }
        // The picture of the line it belongs on, which the probe has no eyes for: a render of the HUD with
        // the caption's own row of it read back for the referee's amber.
        func amberWhereTheCaptionGoes() -> Int {
            guard let texture = view.texture(from: scene) else { return -1 }
            let rep = NSBitmapImageRep(cgImage: texture.cgImage())
            let pixelsPerPoint = CGFloat(rep.pixelsWide) / size.width
            var amber = 0
            for x in 14..<170 {
                for down in 130..<150 {
                    let c = sample(rep, Int(CGFloat(x) * pixelsPerPoint), Int(CGFloat(down) * pixelsPerPoint))
                    if c.r > 0.6, c.g > 0.4, c.b < 0.5 { amber += 1 }
                }
            }
            return amber
        }
        report("at the break, level")
        print("    nothing is written there yet: \(amberWhereTheCaptionGoes()) amber pixels")
        driver.game.withState { $0.scores = [0, 30] }
        report("thirty behind with the table full")

        // One Red and every colour left is 35 on: behind by 30 the striker can still win on the balls.
        func oneRedLeft(scores: [Int]) {
            driver.game.withState { state in
                state.redsRemaining = 1
                state.ballsOnTable = [BallID.cue, BallID.firstRed, BallID.yellow, BallID.green,
                                      BallID.brown, BallID.blue, BallID.pink, BallID.black]
                state.ballOn = .red
                state.pending = nil
                state.cueBallInHand = false
                state.scores = scores
            }
            driver.syncWorldFromState()
        }
        oneRedLeft(scores: [20, 50])
        report("thirty behind with one Red left")
        oneRedLeft(scores: [10, 50])
        report("forty behind with one Red left")
        print("    and now it is written there: \(amberWhereTheCaptionGoes()) amber pixels")
    }

    /// The way round the mouse's two axes are read, and what can and cannot change it. Taking the window
    /// full screen changes the size of the scene, and the same point on the screen is then a different place
    /// in it — so a reading taken across that change says nothing about the device, and learning the sign
    /// again from it is how a player's controls come out reversed (up and down, or both axes at once). The
    /// probe drives the same reading the app uses with the movements that happen around a resize.
    private static func mouseAxisProbe() {
        let scene = TableScene(size: size)
        print("mouse axis probe")
        func report(_ what: String) {
            let reading = scene.mouseAxisReading
            let x = "\(reading.x > 0 ? "+" : "-")\(reading.xIsLearned ? "" : "*")"
            let y = "\(reading.y > 0 ? "+" : "-")\(reading.yIsLearned ? "" : "*")"
            print("  \(what): x \(x), y \(y)")
        }
        report("at the start (a * is an axis still on its default, not yet learned)")

        // A mouse moving right and down, with the pointer going right and **up** the screen: the y deltas
        // and the places run opposite ways, which is the whole reason for learning an axis rather than
        // assuming it. This is the one kind of movement the sign may be learned from.
        _ = scene.readMouseMovement(delta: CGPoint(x: 10, y: 6), changedBy: CGPoint(x: 10, y: -6))
        report("after one plain movement")

        // A window taken full screen: the scene changes size, so the pointer's place jumps far further than
        // the mouse moved. Nothing can be learned from a place like that.
        _ = scene.readMouseMovement(delta: CGPoint(x: 4, y: 3), changedBy: CGPoint(x: -260, y: -180))
        print("    (that place pointed the other way: believed, it would have left both axes reversed)")
        report("after a place that jumped with the resize")

        // The game having put the pointer somewhere of its own accord: the place is not to be believed at
        // all for that one event, however it points.
        _ = scene.readMouseMovement(delta: CGPoint(x: 8, y: 5), changedBy: nil)
        report("with the place not to be believed")

        // And what a size change does to the places: the last one is thrown away, and they are left alone
        // until the window has settled.
        scene.didChangeSize(size)
        print("  a size change: the pointer's places believed now? \(scene.thePointerPlacesAreBelieved)")
        report("after the resize")

        // The movement itself is still read from the mouse's own deltas, whatever the places are doing: a
        // mouse moving right and down is a movement right and down the screen.
        let moved = scene.readMouseMovement(delta: CGPoint(x: 10, y: 6), changedBy: nil)
        print("  the movement (10, 6) reads as (\(Int(moved.x)), \(Int(moved.y)))")

        // And a device that delivers its axes the other way round is still put right: the first believable
        // movement teaches each sign, and the reading stands from then on.
        let otherWayRound = TableScene(size: size)
        _ = otherWayRound.readMouseMovement(delta: CGPoint(x: 10, y: 6), changedBy: CGPoint(x: -10, y: 6))
        let learned = otherWayRound.mouseAxisReading
        print("  a device the other way round, learned from one movement: x \(learned.x > 0 ? "+" : "-"), "
              + "y \(learned.y > 0 ? "+" : "-")")
        _ = otherWayRound.readMouseMovement(delta: CGPoint(x: 4, y: 3), changedBy: CGPoint(x: 260, y: 180))
        let afterwards = otherWayRound.mouseAxisReading
        print("  ... and a jumped place afterwards leaves it as it was: x \(afterwards.x > 0 ? "+" : "-"), "
              + "y \(afterwards.y > 0 ? "+" : "-")")
    }

    /// The colour the cue is on, taken as the striker's nomination. On a colour of their own choice with the
    /// cue on the Blue, the Blue is what they are playing for without a button being pressed; and a colour
    /// named by hand stands, whatever the cue is pointed at afterwards.
    private static func colourChoiceProbe() {
        let scene = TableScene(size: size)
        scene.table3D = Table3D()
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.presentScene(scene)
        let driver = scene.controller

        print("colour choice probe")
        // A striker on a colour of their own choice: the Yellow straight ahead, the Blue off to one side,
        // the Black beyond.
        driver.game.withState { state in
            state.ballsOnTable = [BallID.cue, BallID.yellow, BallID.blue, BallID.black]
            state.redsRemaining = 0
            state.ballOn = .anyColour
            state.nominatedColour = nil
            state.cueBallInHand = false
            state.pending = .nominateColour(options: [.yellow, .blue, .black])
            state.ballPositions[BallID.cue] = Vec2(1000, 889)
            state.ballPositions[BallID.yellow] = Vec2(2000, 889)
            state.ballPositions[BallID.blue] = Vec2(2000, 1300)
            state.ballPositions[BallID.black] = Vec2(3000, 889)
        }
        driver.syncWorldFromState()
        print("  on a colour of their choosing, nothing nominated yet: the game says "
              + "\"\(driver.ballOnDescription)\"")

        // The cue on to the Blue: that is the colour they are playing for, said with the cue rather than
        // with a button.
        driver.aimAngle = atan2(411, 1000)
        scene.refresh(force: true)
        print("  the cue on the Blue: \(driver.nominatedColour?.rawValue ?? "nothing") nominated, "
              + "the game says \"\(driver.ballOnDescription)\", \(scene.buttonNodesOnScreen) colours on offer")

        // And a colour named by hand stands, whatever the cue is pointed at afterwards — here the Yellow.
        driver.chooseColour(.black)
        driver.aimAngle = 0
        scene.refresh(force: true)
        print("  the Black named by hand, then the cue on the Yellow: "
              + "\(driver.nominatedColour?.rawValue ?? "nothing") nominated, "
              + "the game says \"\(driver.ballOnDescription)\"")
    }

    /// The line drawn for the ball being aimed at: how wide the stripe is and how solid, which is what the
    /// player sees of it and what the probe cannot see for itself, having no cloth and no eyes.
    private static func aimingAidProbe(_ table: Table3D) {
        let line = table.aimedBallLineFacts
        print("aiming aid probe")
        print(String(format: "  the aimed ball's line: %.0f mm across it (the table's own markings are 3 mm), "
                     + "opacity %.2f green, %.2f red",
                     line.stripeWidthMM, line.greenOpacity, line.redOpacity))
    }

    /// What the cushion does to a ball's angle: fired in at 30° to the cushion's normal, at three paces,
    /// and the angle it comes away at. The rubber grips harder the harder it is hit, so a firm ball comes
    /// off straighter — this is the figure to watch when `cushionFriction` is tuned, since nothing else in
    /// the game puts a number on the grab.
    private static func cushionGrabProbe() {
        print("cushion grab probe (a rolling ball into the cushion at 30° to the normal)")
        for speed in [700.0, 2000.0, 4000.0] {
            guard let bounce = cushionBounce(incident: 30, speed: speed) else { continue }
            let angle = atan2(abs(bounce.after.velocity.x), bounce.after.velocity.y) * 180 / .pi
            print(String(format: "  in at %4.0f mm/s: out at %4.1f° from the normal, side spin %+.0f rad/s",
                         speed, angle, bounce.after.spin.z))
        }
        print(String(format: "  (the coefficient is %.2f: raising it grips more, lowering it lets the ball "
                     + "come off closer to a plain reflection)", PhysicsWorld.cushionFriction))
    }

    /// Fires a naturally rolling ball at the bottom cushion at `incident` degrees to its normal, and hands
    /// back the ball as it was on the step before the contact and on the step of it.
    private static func cushionBounce(incident: Double, speed: Double) -> (before: Ball, after: Ball)? {
        let a = incident * .pi / 180
        var ball = Ball(id: BallID.cue, color: .white, position: Vec2(1000, 700))
        ball.velocity = Vec2(sin(a) * speed, -cos(a) * speed)
        ball.spin = Vec3(-ball.velocity.y / Table.ballRadius, ball.velocity.x / Table.ballRadius, 0)
        let world = PhysicsWorld(balls: [ball])
        var t = 0.0
        while t < 1.5 {
            let wasBefore = world.balls[0]
            world.step(dt: 1.0 / 480.0)
            t += 1.0 / 480.0
            if world.events.contains(where: { if case .cushion = $0 { return true }; return false }) {
                return (wasBefore, world.balls[0])
            }
            world.clearEvents()
        }
        return nil
    }

    /// The cursor, while the mouse is the game's: hidden, and **staying** hidden.
    ///
    /// One `hide` is not enough, and the probe is here to say what is done about it: the cursor is asked for
    /// again on every frame the game has the mouse, because a hide can be overtaken by an unhide sent before
    /// it — the one that went with the last release — and acted on after. The asking is counted, and past a
    /// few the game gives an older one back, so the count is bounded and never reaches nothing while the
    /// mouse is captured. Giving the mouse back gives every one of them back.
    ///
    /// The probe replaces the cursor itself with its own counter, so the walk hides nobody's pointer.
    private static func cursorProbe() {
        let scene = TableScene(size: size)
        print("cursor probe")

        // A single frame of the mouse being the game's: one hide asked for, one held.
        var walk = scene.walkTheCursorBookkeeping(forFrames: 1, givingItBack: false)
        print("  one frame of play: \(walk.hides) hide asked for, \(walk.held) held — the cursor is hidden")

        // A long stretch of play: still only the few the game holds in hand, and never none.
        walk = scene.walkTheCursorBookkeeping(forFrames: 600, givingItBack: false)
        print("  600 frames of play: \(walk.hides) hides asked for, \(walk.shows) given back as they went, "
              + "\(walk.held) held — the count is bounded and still not nothing")
        print("  (after the walk the game holds \(scene.cursorHidesHeld))")

        // And giving the mouse back: every hide the game was holding, given back, so the player has their
        // cursor again and the count is at nothing for the next capture to start from.
        let withTheMouseGivenBack = scene.walkTheCursorBookkeeping(forFrames: 600, givingItBack: true)
        print("  and then the mouse given back: \(withTheMouseGivenBack.held) were held and are given back, "
              + "\(scene.cursorHidesHeld) still held")
    }

    /// What the game asks the window for, and when.
    ///
    /// The point of the policy is that a table nobody is touching costs nothing and a shot does not: the
    /// frame loop is driven by hand here, and the rate the scene is asking for is read at each point in
    /// the play.
    private static func frameRateProbe() {
        print("frame rate probe")
        let scene = TableScene(size: size)
        scene.table3D = Table3D()
        _ = scene.controller.placeCueBall(at: Vec2(700, 800))
        var clock = 0.0
        /// Drives the frame loop the way the window does: a sixtieth of a second a frame.
        func frames(_ count: Int) {
            for _ in 0..<count {
                clock += 1.0 / 60.0
                scene.update(clock)
            }
        }
        /// Runs the frame loop over **real** time, which is the only way its own idle clock — and the
        /// camera's easing — can be seen to run out. The probe can put a second of frames through the
        /// loop in a few milliseconds; the scene is right not to call that a second of nothing happening.
        func run(seconds: Double) {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until {
                frames(1)
                Thread.sleep(forTimeInterval: 1.0 / 60.0)
            }
        }
        func key(_ character: String, down: Bool) {
            let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero,
                                         modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                         characters: character, charactersIgnoringModifiers: character,
                                         isARepeat: false, keyCode: 0)!
            if down { scene.keyDown(with: event) } else { scene.keyUp(with: event) }
        }

        // Nothing touched and nothing moving: one frame a second, which is what leaves the picture on the
        // screen and notices anything the game changes on its own, for near enough to nothing.
        run(seconds: 1.5)
        let whenStill = scene.frameRate
        print("  a second and a half of nothing: \(whenStill.rawValue) a second")

        // The player does something: 60 a second standing at the table.
        key("q", down: true)                      // a key the game does not use, which only wakes it
        run(seconds: 0.2)
        let whenStanding = scene.frameRate
        print("  a key pressed: \(whenStanding.rawValue) a second")

        // Down on the shot: 120.
        key("s", down: true)
        run(seconds: 0.2)
        let whenDown = scene.frameRate
        print("  the cue taken up (S): \(whenDown.rawValue) a second, down on the shot \(scene.controller.isDownOnTheShot)")

        // Let go, and let the table settle again: the camera eases back up to standing, and then there is
        // nothing left to draw.
        key("s", down: false)
        run(seconds: 0.3)
        let easing = scene.frameRate
        run(seconds: 2.0)
        print("  S let go: \(easing.rawValue) a second while the camera stands up, and "
              + "\(scene.frameRate.rawValue) a second once it has")

        // The balls running: 120 until they stop, and then nothing again.
        key("q", down: true)
        scene.controller.shoot(angle: 0.05, power: 0.85, side: 0.2, vertical: 0.3)
        run(seconds: 0.1)
        let whenRunning = scene.frameRate
        var framesDriven = 0
        while scene.controller.mode == .simulating, framesDriven < 60 * 40 {
            frames(1)
            framesDriven += 1
        }
        run(seconds: 2.0)
        let whenSettled = scene.frameRate
        print("  the balls running: \(whenRunning.rawValue) a second, and once they stop: \(whenSettled.rawValue) a second "
              + "(the stroke took \(framesDriven) frames)")

        let right = whenStill == .idle && whenStanding == .standing && whenDown == .playing
            && easing == .standing && whenRunning == .playing && whenSettled == .idle
        let verdict = right
            ? "idle for a table nobody is touching, 60 standing, 120 for a shot or the balls running — as asked"
            : "WRONG: the frame rate is not what the picture is worth"
        print("  \(verdict)")

        // And the dearest thing the HUD redraws: the spin limit belongs to the angle the cue stands at,
        // so it is worked out when the angle moves and not once a frame.
        let beforeTheQuietFrames = scene.spinOutlineBuilds
        frames(600)
        print("  600 frames with the cue where it stands: \(scene.spinOutlineBuilds - beforeTheQuietFrames) spin-limit outlines worked out")
        scene.controller.adjustElevation(by: 5 * .pi / 180)
        let beforeTheLift = scene.spinOutlineBuilds
        frames(60)
        print("  and 60 frames with the cue lifted by hand: \(scene.spinOutlineBuilds - beforeTheLift) of them, one for the lift")
    }

    /// The double hit: when the cue has struck the cue ball twice, and when it has only followed through.
    ///
    /// A stroke by hand is played **by the hand going on through the ball**: the same movement that brings
    /// the tip to the ball carries it on past. Left to the hand, the stick's speed after the strike is
    /// the hand's own, while the ball's is `1.75` times the stroke's — and the stroke's strength is the
    /// **average** of the push, which a flick's last frame is faster than — so a soft shot with the hand
    /// going on through it was called a second hit **14 ms** after the first contact, over and over, which
    /// is the foul the player met as coming from nowhere. The stick is carried forward no faster than it
    /// was going when it struck the ball now (`FrameDriver.carryTheCue`), and this plays the same shot ten
    /// ways — the hand stopping on the ball, going on at the same pace, easing back, snapping through a
    /// soft one, and heavy side — and reports which of them are second hits and which are follow-throughs.
    /// A ball that comes back to a stick left standing is a real foul, and is still reported.
    private static func doubleHitProbe() {
        print("double hit probe (the cue action, with the hand going on through the ball)")
        /// Plays one shot and reports what the game said about the cue and the cue ball.
        func play(_ name: String, back: Double, push: [Double], side: Double = 0) {
            let scene = TableScene(size: size)
            let table = Table3D()
            scene.table3D = table
            scene.controller.game.withState { state in
                state.ballsOnTable = [BallID.cue, BallID.firstRed]
                state.ballPositions[BallID.firstRed] = Vec2(Table.length / 2, Table.centreY)
                state.ballOn = .red
                state.cueBallInHand = true
                state.pending = .placeCueBallInD
            }
            scene.controller.syncWorldFromState()
            _ = scene.controller.placeCueBall(at: Vec2(Table.baulkLineX, Table.centreY))
            scene.controller.aimAngle = 0
            var clock = CACurrentMediaTime()
            var pointerY = 0.0
            func frame() {
                clock += 1.0 / 120
                scene.update(clock)
                table.update(with: scene.controller, dt: 1.0 / 120)
            }
            /// The hand: the pointer is moved a step at a time, the way one does.
            func hand(_ points: Double) {
                let steps = max(1, Int(abs(points) / 10))
                for _ in 0..<steps {
                    pointerY += points / Double(steps)
                    scene.steer(at: CGPoint(x: size.width / 2, y: size.height / 2 + pointerY), flags: [])
                }
            }
            func key(_ character: String, down: Bool) {
                let event = NSEvent.keyEvent(with: down ? .keyDown : .keyUp, location: .zero,
                                             modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                             characters: character, charactersIgnoringModifiers: character,
                                             isARepeat: false, keyCode: 0)!
                if down { scene.keyDown(with: event) } else { scene.keyUp(with: event) }
            }
            for _ in 0..<10 { frame() }                     // let the camera come to the table
            if side != 0 { scene.controller.setSpin(side: side, vertical: 0) }
            key("s", down: true)
            for _ in 0..<4 { hand(-back / 4); frame() }     // draw the cue back
            var ballSpeed = 0.0
            for points in push {                            // and drive it through
                hand(points)
                frame()
                if ballSpeed == 0, scene.controller.mode == .simulating {
                    ballSpeed = scene.controller.cueBall?.velocity.length ?? 0
                }
            }
            key("s", down: false)
            for _ in 0..<600 where scene.controller.mode == .simulating { frame() }
            let stroke = scene.controller.lastStroke
            let again = stroke?.secondsUntilTheCueBallWasStruckAgain
            let touched = stroke?.ballsTheCueTouched ?? []
            let foul = scene.controller.lastResult?.foul
            print(String(format: "  %-46@ cue %5.0f mm/s, ball %5.0f mm/s: %@",
                         name as NSString,
                         scene.controller.lastStrikeCueSpeed,
                         ballSpeed,
                         (again == nil && !touched.contains(BallID.cue)
                          ? "no second strike"
                          : String(format: "SECOND STRIKE %@ after %.0f ms%@", touched.contains(BallID.cue) ? "of the cue ball" : "of \(touched)",
                                   (again ?? 0) * 1000,
                                   foul.map { " — \($0.reason)" } ?? "") ) as NSString))
        }

        // The tip has to come back 20 mm before a push counts as a stroke, and the cue's rest place
        // leaves 30 mm between tip and ball, so a 56 mm draw (160 points) is a real backswing.
        play("the hand stops as the tip meets the ball", back: 160, push: [90, 90, 90])
        play("the hand goes on at the same pace", back: 160, push: [90, 90, 90, 90, 90])
        play("the hand goes on, easing back", back: 160, push: [90, 90, 90, 40, 20])
        play("a slow push that snaps through", back: 160, push: [40, 40, 40, 100, 100])
        play("a slow push, hand snapping at the ball", back: 160, push: [40, 40, 40, 40, 200, 200])
        play("a soft shot, then a hard flick through it", back: 160,
             push: [20, 20, 20, 20, 20, 20, 20, 20, 200, 200])
        play("the hand flicks through and goes on", back: 160, push: [60, 60, 120, 120, 120])
        play("the hand flicks hard through the ball", back: 160, push: [300])
        play("a soft shot, hand going on hard", back: 160, push: [50, 50, 50, 50, 200, 200])
        play("a soft shot with heavy side, hand going on", back: 160,
             push: [20, 20, 20, 20, 20, 20, 20, 20, 200, 200], side: 0.9)
    }

    /// The cue tip, as the material it is: one hardness, and the rest of the contact worked out from it.
    private static func tipProbe() {
        let tip = PhysicsWorld.self
        print("tip probe (leather of a stated hardness, and the contact it makes with the ball)")
        print(String(format: "  the tip is Shore D %.0f: modulus %.1f MPa, Poisson's ratio %.2f",
                     tip.cueTipShoreD, tip.cueTipYoungsModulus / 1e6, tip.cueTipPoissonsRatio))
        print(String(format: "  on a ball of %.1f mm, the contact is worth one radius of %.3f mm and one modulus of %.1f MPa",
                     Table.ballRadius, tip.cueTipContactRadius, tip.cueTipContactModulus / 1e6))
        print(String(format: "  restitution %.3f, so a full charge is a cue at %.0f mm/s and a ball at %.0f mm/s",
                     tip.cueTipRestitution, FrameDriver.maxCueSpeed, FrameDriver.maxPower))
        print("  and it is on the ball for less time the firmer the shot is:")
        for speed in [200.0, 500.0, 1000.0, 2000.0, FrameDriver.maxCueSpeed] {
            print(String(format: "    cue at %5.0f mm/s: %.2f ms on the ball, pressed %.2f mm into it",
                         speed, tip.cueTipContactSeconds(forCueSpeed: speed) * 1000,
                         tip.cueTipDeflection(forCueSpeed: speed)))
        }
        print("  and a softer or harder tip is a longer or shorter contact and a smaller or larger restitution:")
        for shoreD in [55.0, 60.0, 70.0, 80.0] {
            print(String(format: "    Shore D %.0f: restitution %.3f, %.2f ms on the ball at a full charge",
                         shoreD, tip.cueTipRestitution(tipAt: shoreD),
                         tip.cueTipContactSeconds(forCueSpeed: FrameDriver.maxCueSpeed, tipAt: shoreD) * 1000))
        }
    }

    /// What the game says of a break: the one line it leaves in the log, and not a line for every ball.
    ///
    /// A red, a black, and then a stroke that pots nothing: a break of eight. The readout on the screen
    /// carries the break as it is made, so the log has no business repeating it stroke by stroke — what
    /// it is for is what happened, and the thing that happened is the break, over.
    private static func breakLogProbe() {
        print("break log probe (a red, a black, then a miss)")
        let game = SnookerGame()
        game.beginFrame(startingPlayer: 0)
        guard game.placeCueBall(at: Vec2(600, 889)) else {
            print("  WRONG: could not put the cue ball down to start")
            return
        }
        var red = StrokeReport()
        red.firstContacts = [BallID.firstRed]
        red.potted = [BallID.firstRed]
        _ = game.applyStroke(red, cueBallPosition: Vec2(1200, 889))
        game.nominateColour(.black)
        var black = StrokeReport()
        black.firstContacts = [BallID.black]
        black.potted = [BallID.black]
        _ = game.applyStroke(black, cueBallPosition: Vec2(1300, 889))
        var miss = StrokeReport()
        miss.firstContacts = [BallID.firstRed + 1]     // another red, still on the table
        _ = game.applyStroke(miss, cueBallPosition: Vec2(1500, 889))

        for line in game.state.commentary { print("    \(line)") }
        let strokeLines = game.state.commentary.filter { $0.contains("scores") }
        print("  \(strokeLines.isEmpty ? "and nothing is said of the strokes that scored: the break, once it is over, is the one line" : "WRONG: a stroke that scored was written into the log")")
        let breakLines = game.state.commentary.filter { $0.hasPrefix("Prof. Snoo's break ends on") }
        print("  \(breakLines.count == 1 && breakLines[0].contains("8") ? "the break is said once, and it came to eight" : "WRONG: the break is said \(breakLines.count) times")")
    }

    /// The room the table stands in: the floor it stands on, the six pillars that carry it, and the four
    /// lamps that are the four spot lights.
    ///
    /// The floor's **size** and its material are read off the built scene — a seven-metre slab has no
    /// edge to measure in a photograph — while the one thing that *is* a picture, what the floor looks
    /// like under the lights, is sampled from a view straight down beside and beyond the table, where the
    /// slab is the only thing the camera finds.
    private static func roomProbe(_ table: Table3D, device: MTLDevice, into directory: URL) {
        let floor = table.floorFacts
        print(String(format: "  the floor: %5.0f x %5.0f mm — %.1f table lengths by %.1f widths — a %.0f mm slab, its face at %+.0f mm, where a ball forced off the table lands",
                     floor.length, floor.width, floor.length / Table.length, floor.width / Table.width,
                     floor.thickness, floor.top))
        print(String(format: "    %@, %@, roughness %.2f, metalness %.2f%@",
                     floor.covering as NSString, floor.lightingModel as NSString, floor.roughness,
                     floor.metalness,
                     (floor.lightingModel == SCNMaterial.LightingModel.lambert.rawValue
                      ? " — no specular term at all, which is as near a wholly diffuse floor as this renderer has"
                      : " — WRONG: the floor is not wholly diffuse, so it can catch a highlight") as NSString))

        let legs = table.legPlaces
        let frame = Table.cushionDepth + Table.railDepth
        let half = Table3D.legSection / 2
        // Every pillar has to stand **under the wood**: the body of the table runs from the cushion line
        // out to the frame's own edge, and a leg that reached past either would be outside it — one in
        // under the cloth, the other out in the air beyond the frame.
        let underTheFrame = legs.allSatisfy { leg in
            func inside(_ centre: Double, upTo edge: Double) -> Bool {
                centre - half >= -frame && centre + half <= edge + frame
            }
            return inside(leg.x, upTo: Table.length) && inside(leg.y, upTo: Table.width)
        }
        print("  the legs: \(legs.count) pillars standing on the floor, "
              + legs.map { String(format: "(%.0f, %.0f)", $0.x, $0.y) }.joined(separator: " "))
        print("    " + (legs.count == 6 && underTheFrame
                        ? "six of them — the two ends and the middle, down each long side — and every one of them stands under the frame"
                        : "WRONG: the legs are not six pillars, or one of them is not under the frame"))

        let lamps = table.lampPositions
        let spots = table.lightInventory.filter { $0.kind == "spot" }.map(\.position)
        let atTheLights = lamps.count == 4 && lamps.allSatisfy { lamp in
            spots.contains { simd_distance(lamp, $0) < 0.001 }
        }
        print("  the four lamps: "
              + lamps.map { String(format: "(%.2f, %.2f, %.2f)", $0.x, $0.y, $0.z) }.joined(separator: " "))
        print("    " + (atTheLights
                        ? "one at the place of each of the four spot lights"
                        : "WRONG: the lamps are not four, or not where the four spot lights are"))

        // The ring of small spotlights round the table: the lamps, the ones that carry a light, and how
        // far the ring stands off the table. The clearance is measured to the **table** — the frame's own
        // outer edge — which is what "500 mm from the table" means when the table is what has an edge.
        let ring = table.ringLampPlaces
        let ringCorners = table.ringCorners
        let ringRectangle = table.ringRectangle
        let pitch = table.ringPitch
        // Every lamp on the ring: as far outside the table in one direction as the ring is clear of it,
        // and within the table's own run in the other.
        let clearance = Table3D.ringClearance
        let onTheRectangle = ring.allSatisfy { place in
            let outX = max(0, max(-place.x, place.x - Table.length))
            let outY = max(0, max(-place.y, place.y - Table.width))
            let wanted = frame + clearance
            return abs(outX - wanted) < 0.5 || abs(outY - wanted) < 0.5
        }
        // **A lamp at every corner**, which is what a ring of spotlights round a table is for.
        let atTheCorners = ringCorners.allSatisfy { corner in
            ring.contains { $0.distance(to: corner) < 0.5 }
        }
        print(String(format: "  the ring: %d small lamps, %.0f mm apart down a long side and %.0f mm across a short one, on a %4.0f x %4.0f mm rectangle %.0f mm clear of the table, at the big lamps' own height — and no two of them are lights",
                     ring.count, pitch.along, pitch.across, ringRectangle.length, ringRectangle.width,
                     clearance))
        print("    " + (atTheCorners && onTheRectangle
                        ? "a lamp at each of the four corners and the rest evenly spaced between them"
                        : "WRONG: there is not a lamp at each corner, or one is off the rectangle"))
        // The lights in the room, counted: the renderer applies at most eight to any one object, and the
        // ring is lamps and not lights, so the room holds exactly the eight the table is lit by — every one
        // of them applied.
        let lights = table.lightInventory
        print("    \(lights.count) lights in the room"
              + (lights.count <= 8 ? " — the most any one object may be given, so every one of them is applied"
                                   : " — WRONG: more lights than the renderer will give one object"))

        table.withOverheadCamera {
            let image = table.renderImage(size: size, device: device)
            _ = write(image, name: "12-the-room-from-above", into: directory)
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
            // Far enough out that the line of sight clears the table: the camera is 4.4 m up and the floor
            // is 800 mm below the cloth, so a floor point 2.45 m out is seen past the rails, and one less
            // far out is seen through them — the cloth, from above.
            for (label, point) in [("past the long side", Vec2(Table.length / 2 + 2450, Table.width / 2)),
                                   ("past the baulk end", Vec2(Table.length / 2 - 2450, Table.width / 2))] {
                let world = Table3D.scenePoint(point, height: Table.floorHeight)
                guard let p = table.project(world, imageSize: size),
                      p.x > 0, p.x < size.width, p.y > 0, p.y < size.height else {
                    print("    the floor \(label): off the picture — WRONG: the floor is not where the camera can see it")
                    continue
                }
                let c = sample(rep, Int(p.x), Int(p.y))
                let spread = max(c.r, max(c.g, c.b)) - min(c.r, min(c.g, c.b))
                print(String(format: "    the floor %@: #%02x%02x%02x, spread %.3f%@",
                             label as NSString, Int(c.r * 255), Int(c.g * 255), Int(c.b * 255), spread,
                             (spread < 0.05 ? "" : " — WRONG: the floor is not grey") as NSString))
            }
        }

        // And the room as a picture, from the side and low down, which is the one view that holds the
        // floor, the legs and the lamps at once — the overhead views have the first two hidden behind the
        // table and the third taken out of the way.
        let eye = simd_float3(3.4, 0.15, 2.5)
        table.withCamera(eye, lookingAt: simd_float3(0, 0.35, 0), fieldOfView: 62) {
            let room = table.renderImage(size: size, device: device)
            _ = write(room, name: "13-the-room-from-the-side", into: directory)
            guard let tiff = room.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return }
            describe(rep, name: "the room, from the side")
            // The leg nearest the camera, read back off the render at the height of its middle: a pillar
            // is wood, and the floor it stands on is grey, so the two are told apart by colour. The middle
            // of a pillar is 400 mm below the cloth — the floor is at 800 below and the frame's underside
            // at 150 — so any height between those two will do.
            // The leg nearest the camera, which is the one at the far end of the long side towards it.
            let eyeOnTheTable = Vec2(Table.length / 2, Table.width / 2)
                + Vec2(Double(eye.x) * 1000, -Double(eye.z) * 1000)
            let nearLeg = legs.min { $0.distance(to: eyeOnTheTable) < $1.distance(to: eyeOnTheTable) }
                ?? Vec2(Table.length / 2, 22)
            let legMiddle = Table3D.scenePoint(nearLeg, height: -400)
            guard let p = table.project(legMiddle, imageSize: size),
                  p.x > 0, p.x < size.width, p.y > 0, p.y < size.height else {
                print("    the leg at (\(nearLeg.x), \(nearLeg.y)) mm: off the picture — WRONG: the leg is not where the camera can see it")
                return
            }
            let c = sample(rep, Int(p.x), Int(p.y))
            let wood = c.r > c.g && c.g > c.b && c.r > 0.15
            print(String(format: "    the leg at (%4.0f, %4.0f) mm, at the height of its middle: #%02x%02x%02x%@",
                         nearLeg.x, nearLeg.y, Int(c.r * 255), Int(c.g * 255), Int(c.b * 255),
                         (wood ? " — wood, as a leg should be"
                               : " — WRONG: the leg does not read as wood, so it may not be drawn there") as NSString))

            // And the carpet **is not lit by the ring**: the lamps are lamps and not lights, so the carpet
            // under a lamp has to look like the carpet between two of them. Where it does not, the ring is
            // laying circles on the floor again.
            // Two points on the **near lane** of the ring, where the camera can see the carpet: one under a
            // lamp of the ring and one midway between that lamp and the next one down the lane.
            let middle = Table.length / 2
            let lane = ring.filter { $0.y < 0 }
            let first = lane.min { abs($0.x - middle) < abs($1.x - middle) }
                ?? Vec2(middle, -(Table3D.ringClearance + 143))
            let nextLamp = ring[(ring.firstIndex { $0.distance(to: first) < 0.5 }.map { $0 + 1 } ?? 0)
                                % ring.count]
            var means: [Sample] = []
            for (label, point) in [("under a lamp of the ring", first),
                                   ("between two lamps of it", (first + nextLamp) / 2)] {
                let world = Table3D.scenePoint(point, height: Table.floorHeight + 1)
                guard let s = table.project(world, imageSize: size),
                      s.x > 0, s.x < size.width, s.y > 0, s.y < size.height else {
                    print("    the carpet \(label): off the picture")
                    continue
                }
                let carpet = patch(rep, Int(s.x), Int(s.y), radius: 3)
                means.append(carpet.mean)
                print(String(format: "    the carpet %@: mean #%02x%02x%02x, spread %.3f over a 7 x 7 patch",
                             label as NSString, Int(carpet.mean.r * 255), Int(carpet.mean.g * 255),
                             Int(carpet.mean.b * 255), carpet.spread))
            }
            if means.count == 2 {
                let difference = abs(means[0].r - means[1].r) + abs(means[0].g - means[1].g)
                    + abs(means[0].b - means[1].b)
                print(String(format: "    the two differ by %.3f of full scale%@", difference,
                             (difference < 0.05 ? " — the ring leaves no circles on the carpet"
                                                : " — WRONG: the ring is laying light on the carpet") as NSString))
            }
        }

        // What the balls reflect of the room: the **up** face of the capture they are given, where the
        // lamps are. The plates are the one thing left out of that capture, so a band of light up there is
        // a lamp, and an up face with no bands is a room with the lights on and nothing in it.
        let up = table.capturedSurroundings.first { $0.name.hasPrefix("+y") }
        let bands = (up?.brightBandsAcross ?? 0) + (up?.brightBandsDown ?? 0)
        print(String(format: "  what the balls reflect of the room: the up face of the capture holds %d bands of light%@",
                     bands, (bands > 0 ? " — the lamps are in the reflections"
                                       : " — WRONG: nothing over the table is reflected") as NSString))
        // And the capture is **grey**, which is what stops the room it lights from going green: the faces
        // are read back here because the first attempt at desaturating them failed silently and the probe
        // of the leg agreed with the code rather than with the eye.
        for face in table.capturedSurroundings {
            let spread = max(face.mean.0, max(face.mean.1, face.mean.2))
                - min(face.mean.0, min(face.mean.1, face.mean.2))
            guard spread > 0.03 else { continue }
            print(String(format: "    the captured %@ is not grey — #%02x%02x%02x — WRONG: the room's light is coloured",
                         face.name as NSString, Int(face.mean.0 * 255), Int(face.mean.1 * 255),
                         Int(face.mean.2 * 255)))
        }

        // The table's **shadow** on the carpet — the carpet under the middle of the table against the
        // carpet out in the open — and the legs and the frame, which are lit by the lamps and must take
        // **nothing** of the captured room: switching the reflections off must not change them at all.
        table.withCamera(eye, lookingAt: simd_float3(0, 0.35, 0), fieldOfView: 62) {
            func readings() -> (shadow: Sample, open: Sample, leg: Sample) {
                let image = table.renderImage(size: size, device: device)
                guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
                    return ((0, 0, 0), (0, 0, 0), (0, 0, 0))
                }
                func at(_ point: Vec2, height: Double) -> Sample {
                    guard let s = table.project(Table3D.scenePoint(point, height: height), imageSize: size),
                          s.x > 0, s.x < size.width, s.y > 0, s.y < size.height else { return (0, 0, 0) }
                    return patch(rep, Int(s.x), Int(s.y), radius: 3).mean
                }
                let middle = Vec2(Table.length / 2, Table.width / 2)
                return (at(middle, height: Table.floorHeight + 3),
                        at(Vec2(middle.x, -1143), height: Table.floorHeight + 3),
                        at(Vec2(3547, 22), height: -400))
            }
            let lit = readings()
            table.ballsReflectSurroundings = false
            let plain = readings()
            table.ballsReflectSurroundings = true
            for (label, mine, theirs) in [("under the table", lit.shadow, lit.open),
                                          ("the leg", lit.leg, plain.leg)] {
                print(String(format: "    %@: #%02x%02x%02x against #%02x%02x%02x",
                             label as NSString,
                             Int(mine.r * 255), Int(mine.g * 255), Int(mine.b * 255),
                             Int(theirs.r * 255), Int(theirs.g * 255), Int(theirs.b * 255)))
            }
            let depth = 1 - Double(lit.shadow.r + lit.shadow.g + lit.shadow.b)
                / max(1e-6, Double(lit.open.r + lit.open.g + lit.open.b))
            print(String(format: "    the shadow is %.0f%% deep%@", depth * 100,
                         (depth > 0.2 ? " — the table casts a shadow on the carpet"
                                      : " — WRONG: no shadow under the table worth the name") as NSString))
            // The wood may take the room's **light** — the capture is the scene's second light and always
            // was — but not its **colour**: what the room has to offer is a green cloth, and there is no
            // green light over a table. So the test is the green in it, with the reflection on and off.
            func green(_ c: Sample) -> Double { max(0, Double(c.g) - max(Double(c.r), Double(c.b))) }
            let litGreen = green(lit.leg), plainGreen = green(plain.leg)
            print(String(format: "    the leg is %.3f greener than it is warm with the room's reflection on, %.3f with it off%@",
                         litGreen, plainGreen,
                         (max(litGreen, plainGreen) < 0.02
                          ? " — the wood is lit by the lamps, and the room puts no colour on it"
                          : " — WRONG: the wood is picking up the green of the cloth") as NSString))
        }
    }

    /// Looks straight down at the finished table and reads the colour of the pockets, the rail, the
    /// cushions and the markings, which is how the rendered furniture is checked.
    private static func surfaceProbe(_ table: Table3D, device: MTLDevice, into directory: URL) {
        let L = Table.length, W = Table.width
        let cuts = Table3D.pocketCuts()

        /// What a sample should look like.
        ///
        /// The wood of the frame is the one warm surface out here — brown, and browner than it is
        /// green or blue — which is what tells it apart from the cloth, the pockets and the markings.
        func kind(_ c: Sample) -> String {
            let level = luminance(c)
            if level < 0.2 { return "dark" }
            if c.g > c.r * 1.25 && c.g > c.b * 1.25 { return "cloth" }
            if c.r > c.g * 1.2 && c.r > c.b * 1.4 { return "wood" }
            if level > 0.5 { return "light" }
            return "mid"
        }

        let checks: [(String, Vec2, String)] = [
            ("the middle pocket's hole", cuts[.bottomMiddle]!.holeCentre, "dark"),
            ("the middle pocket's passage", Vec2(L / 2, -30), "dark"),
            ("the corner pocket's hole", cuts[.bottomLeft]!.holeCentre, "dark"),
            // The surface runs on into each throat and stops at the hole, so the throat is cloth and
            // the hole is the pocket.
            ("the corner pocket's throat", Vec2(20, 20), "cloth"),
            // The rounded jaw stands at the tip of each cushion and curves away into the pocket, so
            // just behind the line of the jaws is cushion, not the hole. That is the rounding drawn
            // where the ball is played on one.
            // The jaw's round has cut the cushion back: at the tip the mouth is measured to there is
            // pocket now, and the cushion's round is where the cut runs out.
            ("the jaw's cut at the middle pocket, left", Vec2(L / 2 - Table.middleJawGap, -3), "cloth"),
            ("the jaw's cut at the middle pocket, right", Vec2(L / 2 + Table.middleJawGap, -3), "cloth"),
            ("the cushion's round at the middle pocket", Vec2(L / 2 - 80, -6), "cloth"),
            // The corner pocket's cut runs out at 45° with a wedge of cushion carrying the end of
            // each run back to meet it, and the wood wraps round the far side of the hole.
            // The corner pocket's hole reaches a little way back into the corner, which is why a
            // ball that leaves the mouth at the corner drops.
            ("the corner pocket's hole, inboard of the mouth", Vec2(-30, -30), "dark"),
            ("the cushion at the corner pocket's jaw", Vec2(45, -20), "cloth"),
            // The fall: the cushion's top rolling down to the jaw, a stretch either side of each
            // pocket. If the cut were drawn in the wrong place these would be pocket or slate.
            ("the cushion past the corner pocket's jaw", Vec2(70, -6), "cloth"),
            ("the cushion past the jaw at the middle pocket", Vec2(L / 2 - 109, -6), "cloth"),
            ("the cushion down the baulk side", Vec2(110, -6), "cloth"),
            ("the wood round the corner pocket", Vec2(-105, -105), "wood"),
            // The hole's edge is the mouth line itself, so the cloth runs right up to the mouth and
            // the pocket does not bite into the playing area.
            ("the cloth in front of the middle mouth", Vec2(L / 2, 10), "cloth"),
            ("cloth", Vec2(L * 0.4, W / 2), "cloth"),
            ("cloth near the cushion", Vec2(L * 0.4, 12), "cloth"),
            ("cushion top", Vec2(L * 0.4, -24), "cloth"),
            ("rail top", Vec2(L * 0.4, -104), "wood"),
            ("rail at the far side", Vec2(L * 0.4, W + 104), "wood"),
            // The land between a middle pocket's hole and the outer edge of the wood, which is what
            // the hole's own size has to leave: about ten millimetres on the pocket's centre line, and
            // more either side of it.
            ("the land past the middle pocket", Vec2(L / 2 + 45, -(Table.cushionDepth + 78)), "wood"),
            ("baulk line", Vec2(Table.baulkLineX, W * 0.3), "light"),
            ("brown spot", Table.brownSpot, "light"),
            ("blue spot", Table.blueSpot, "light"),
        ]

        // Everything has to happen inside the closure: the projection only means anything while
        // the camera really is overhead.
        let readings: [(String, String?, Sample)] = table.withOverheadCamera {
            let image = table.renderImage(size: size, device: device)
            write(image, name: "09-table-from-above", into: directory)
            guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
                print("  overhead render gave no bitmap (\(image.size), \(image.representations.count) reps)")
                return []
            }
            describe(rep, name: "09-table-from-above")
            let width = rep.pixelsWide, height = rep.pixelsHigh
            var readings: [(String, String?, Sample)] = []
            // A cross-section across the bottom middle pocket, from the outer edge of the rails to
            // beyond the mouth.
            for offset in stride(from: -110.0, through: 40.0, by: 20.0) {
                let point = Vec2(L / 2, cuts[.bottomMiddle]!.holeCentre.y + offset)
                guard let p = table.project(Table3D.scenePoint(point),
                                            imageSize: CGSize(width: width, height: height)),
                      p.x >= 0, p.x < CGFloat(width), p.y >= 0, p.y < CGFloat(height) else { continue }
                let c = sample(rep, Int(p.x), Int(p.y))
                readings.append((String(format: "across the bottom middle pocket, y=%+.0f", point.y), nil, c))
            }
            // And along the same pocket, to read the width of the passage off the render: it should
            // be the mouth's 78 mm the whole way from the cushion down to the hole.
            for offset in stride(from: -60.0, through: 60.0, by: 10.0) {
                let point = Vec2(L / 2 + offset, -10)
                guard let p = table.project(Table3D.scenePoint(point),
                                            imageSize: CGSize(width: width, height: height)),
                      p.x >= 0, p.x < CGFloat(width), p.y >= 0, p.y < CGFloat(height) else { continue }
                let c = sample(rep, Int(p.x), Int(p.y))
                readings.append((String(format: "across the bottom middle pocket, x=%+.0f", offset), nil, c))
            }
            // Down the corner pocket's own diagonal, and across its passage, where the cut is at 45°
            // and the wood wraps round the hole.
            let cut = cuts[.bottomLeft]!
            // And a cross-section across the face of a cushion, from the rail to the cloth: the side
            // is undercut, so the shading runs down the leaning face rather than stopping at an edge.
            for y in stride(from: -60.0, through: 5.0, by: 5.0) {
                let point = Vec2(L * 0.4, y)
                guard let p = table.project(Table3D.scenePoint(point),
                                            imageSize: CGSize(width: width, height: height)),
                      p.x >= 0, p.x < CGFloat(width), p.y >= 0, p.y < CGFloat(height) else { continue }
                let c = sample(rep, Int(p.x), Int(p.y))
                readings.append((String(format: "across the cushion's face, y=%+.0f", y), nil, c))
            }
            for along in stride(from: 0.0, through: 130.0, by: 15.0) {
                let point = cut.mouth + cut.axis * along
                guard let p = table.project(Table3D.scenePoint(point),
                                            imageSize: CGSize(width: width, height: height)),
                      p.x >= 0, p.x < CGFloat(width), p.y >= 0, p.y < CGFloat(height) else { continue }
                let c = sample(rep, Int(p.x), Int(p.y))
                readings.append((String(format: "down the corner pocket, %+.0f out", along), nil, c))
            }
            for across in stride(from: -60.0, through: 60.0, by: 15.0) {
                let point = cut.mouth + cut.axis * 20 + cut.axis.perpendicular * across
                guard let p = table.project(Table3D.scenePoint(point),
                                            imageSize: CGSize(width: width, height: height)),
                      p.x >= 0, p.x < CGFloat(width), p.y >= 0, p.y < CGFloat(height) else { continue }
                let c = sample(rep, Int(p.x), Int(p.y))
                readings.append((String(format: "across the corner pocket, %+.0f", across), nil, c))
            }
            // Across the join between a cushion and the wood, on the wood's own top: the wood's edge
            // is square here, so the surface should be wood from just behind the cushion's back
            // outwards, with no bevel and no cloth showing between the two.
            for outwards in [0.0, 1.0, 2.0, 4.0] {
                let point = Vec2(Table.length * 0.4, -(Table.cushionDepth + outwards))
                guard let p = table.project(Table3D.scenePoint(point, height: Table3D.railHeightAboveCloth),
                                            imageSize: CGSize(width: width, height: height)),
                      p.x >= 0, p.x < CGFloat(width), p.y >= 0, p.y < CGFloat(height) else { continue }
                let c = sample(rep, Int(p.x), Int(p.y))
                readings.append((String(format: "the wood behind the cushion, %+.0f mm out", outwards), nil, c))
            }
            for (name, point, expected) in checks {
                // The middle of the point, and, for a hairline marking thinner than a pixel, the
                // brightest of a few points around it.
                var candidates: [Sample] = []
                for offset in [Vec2.zero, Vec2(2, 0), Vec2(-2, 0), Vec2(0, 2), Vec2(0, -2)] {
                    guard let p = table.project(Table3D.scenePoint(point + offset),
                                                imageSize: CGSize(width: width, height: height)),
                          p.x >= 0, p.x < CGFloat(width), p.y >= 0, p.y < CGFloat(height) else { continue }
                    candidates.append(sample(rep, Int(p.x), Int(p.y)))
                }
                let middle = candidates.first
                let lightest = candidates.max { luminance($0) < luminance($1) }
                let found = expected == "light" ? lightest : middle
                if let found { readings.append((name, expected, found)) }
            }
            return readings
        }

        print("surface probe (looking straight down)")
        for (name, expected, found) in readings {
            let actual = kind(found)
            guard let expected else {
                print(String(format: "  %-46@ #%02x%02x%02x  %@",
                             name as NSString, Int(found.r * 255), Int(found.g * 255),
                             Int(found.b * 255), actual as NSString))
                continue
            }
            print(String(format: "  %-46@ #%02x%02x%02x  %@%@",
                         name as NSString, Int(found.r * 255), Int(found.g * 255), Int(found.b * 255),
                         actual as NSString,
                         (actual == expected ? "" : "  WRONG (expected \(expected))") as NSString))
        }
    }


    /// The HUD the app shows when the player switches back to the view from above.
    private static func topDownView(table: Table3D, driver: FrameDriver, device: MTLDevice) -> NSImage? {
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        let scene = TableScene(size: size)
        scene.scaleMode = .resizeFill
        scene.table3D = table
        view.presentScene(scene)
        scene.setViewMode(.topDown)
        scene.update(0)
        scene.refresh(force: true)
        guard let texture = view.texture(from: scene) else { return nil }
        return NSImage(cgImage: texture.cgImage(), size: size)
    }

    /// Settles the camera, renders, and writes one PNG.
    private static func capture(
        _ table: Table3D,
        _ driver: FrameDriver,
        preset: PlayerCamera.Preset,
        name: String,
        into directory: URL,
        device: MTLDevice
    ) -> [String] {
        table.holdFraming(preset)
        for _ in 0..<240 {
            table.update(with: driver, dt: 1.0 / 120.0)
        }
        let image = table.renderImage(size: size, device: device)
        report(image, name: name, table: table, driver: driver)
        return [write(image, name: name, into: directory)]
    }

    // MARK: - Text report

    /// Renders the snapshot as text: overall exposure, where each ball lands (with the colour
    /// actually found there) and a luminance map of the frame. This is how the 3D view is
    /// checked without looking at the pictures.
    private static func report(_ image: NSImage, name: String, table: Table3D, driver: FrameDriver) {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else {
            print("\(name): no bitmap data")
            return
        }
        let width = rep.pixelsWide, height = rep.pixelsHigh

        print("\(name)  \(width)x\(height)")
        reportStats(rep)

        // The cloth itself, at a few points up the table.
        for probe in [("cloth near", Vec2(1500, Table.centreY)),
                      ("cloth middle", Vec2(2500, Table.centreY)),
                      ("cloth side", Vec2(2500, Table.centreY - 600))] {
            guard let s = table.project(Table3D.scenePoint(probe.1),
                                        imageSize: CGSize(width: width, height: height)),
                  s.x >= 0, s.x < CGFloat(width), s.y >= 0, s.y < CGFloat(height) else { continue }
            let c = sample(rep, Int(s.x), Int(s.y))
            print(String(format: "  %-12@ #%02x%02x%02x",
                         probe.0 as NSString,
                         Int(c.r * 255), Int(c.g * 255), Int(c.b * 255)))
        }

        // Where each ball on the table lands, and what colour the ball actually is there. The
        // very centre of a ball is its specular highlight, so the body colour is taken from the
        // most saturated of a few points around the middle.
        var marks: [(x: Int, y: Int, label: Character)] = []
        for ball in driver.balls where ball.onTable {
            let imageSize = CGSize(width: width, height: height)
            let centre = Table3D.scenePoint(for: ball)
            guard let p = table.project(centre, imageSize: imageSize) else { continue }
            let radius: CGFloat
            if let rim = table.project(centre + simd_float3(0, Float(Table.ballRadius * 0.001), 0), imageSize: imageSize) {
                radius = max(2, min(40, (rim.y - p.y).magnitude))
            } else {
                radius = 4
            }
            let offsets: [(CGFloat, CGFloat)] = [(0, 0), (0.55, 0.55), (-0.55, 0.55), (0.55, -0.55), (-0.55, -0.55)]
            var found = sample(rep, Int(p.x), Int(p.y))
            // White and black have no colour to find, so for those report the brightest point.
            let wantsSaturation = ball.color != .white && ball.color != .black
            var best = -1.0
            for offset in offsets {
                let candidate = sample(rep, Int(p.x + offset.0 * radius), Int(p.y + offset.1 * radius))
                let score = wantsSaturation
                    ? max(candidate.r, max(candidate.g, candidate.b)) - min(candidate.r, min(candidate.g, candidate.b))
                    : luminance(candidate)
                if score > best {
                    best = score
                    found = candidate
                }
            }
            let inside = p.x >= 0 && p.x < CGFloat(width) && p.y >= 0 && p.y < CGFloat(height)
            let expected = ball.color.nsColor.usingColorSpace(.deviceRGB) ?? .white
            let expectedRGB = (Double(expected.redComponent), Double(expected.greenComponent), Double(expected.blueComponent))
            let distance = (pow(found.r - expectedRGB.0, 2) + pow(found.g - expectedRGB.1, 2)
                + pow(found.b - expectedRGB.2, 2)).squareRoot()
            print(String(format: "  %-6@ at (%4d,%4d) %4dpx  found #%02x%02x%02x expect #%02x%02x%02x  %@%@",
                         ball.color.rawValue as NSString, Int(p.x), Int(p.y), Int(radius),
                         Int(found.r * 255), Int(found.g * 255), Int(found.b * 255),
                         Int(expectedRGB.0 * 255), Int(expectedRGB.1 * 255), Int(expectedRGB.2 * 255),
                         distance < 0.30 ? "matches" as NSString : "off-colour" as NSString,
                         inside ? "" as NSString : " (off screen)" as NSString))
            if inside { marks.append((Int(p.x), Int(p.y), label(for: ball.color))) }
        }

        reportMap(rep, marks: marks)
    }

    private static func label(for colour: BallColor) -> Character {
        switch colour {
        case .red: return "r"
        case .yellow: return "y"
        case .green: return "g"
        case .brown: return "b"
        case .blue: return "u"
        case .pink: return "p"
        case .black: return "k"
        case .white: return "W"
        }
    }

    /// The SpriteKit HUD over the 3D render, which is what the window shows.
    private static func hudOverlay(table: Table3D, driver: FrameDriver, device: MTLDevice) -> NSImage? {
        let view = SKView(frame: NSRect(origin: .zero, size: size))
        view.allowsTransparency = true
        let scene = TableScene(size: size)
        scene.scaleMode = .resizeFill
        scene.table3D = table
        view.presentScene(scene)
        scene.update(0)
        table.update(with: driver, dt: 1.0 / 120.0)
        scene.refresh(force: true)
        guard let texture = view.texture(from: scene) else { return nil }
        let hud = NSImage(cgImage: texture.cgImage(), size: size)

        let canvas = NSImage(size: size)
        canvas.lockFocus()
        table.renderImage(size: size, device: device).draw(in: NSRect(origin: .zero, size: size))
        hud.draw(in: NSRect(origin: .zero, size: size))
        canvas.unlockFocus()
        return canvas
    }

    @discardableResult
    private static func write(_ image: NSImage, name: String, into directory: URL) -> String {
        let url = directory.appendingPathComponent("\(name).png")
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else {
            return "\(name): could not encode"
        }
        do {
            try png.write(to: url)
            return url.path
        } catch {
            return "\(name): \(error)"
        }
    }
}
