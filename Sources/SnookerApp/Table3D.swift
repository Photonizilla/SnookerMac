import AppKit
import CoreImage
import Metal
import SceneKit
import SnookerCore
import simd

/// The 3D "in person" table.
///
/// The scene is built once out of the same geometry the top-down view uses — 3569 x 1778 mm
/// of cloth, cushions that stop at the pocket jaws, wooden rails and the six pockets — and is
/// then kept in step with the frame driver: the balls, the cue, the ghost ball and the camera
/// are updated every frame.
///
/// # Scene axes
///
/// The scene is in metres with `y` up, so that SceneKit's lighting and shadow distances behave.
/// The table's long axis runs along `x` with the baulk cushion at the `-x` end, and the engine's
/// `y` runs along `-z`. That handedness matters: it is what puts the striker's right hand at
/// `+z`, so the Yellow Spot lands on the right of the view exactly as it does in the top-down
/// view and on a real table.
final class Table3D {

    // MARK: - Furniture dimensions (millimetres)
    //
    // Only the playing area, the balls, the spots and the mouth of each pocket come from the rule
    // book. Everything below is the shape of a real table wrapped around them: the nose of the
    // cushion is on the boundary the rules measure to, so the playing area is untouched.

    private enum Furniture {
        /// Cloth-covered rubber behind the cushion face. The rails stop here as well, and the
        /// pockets are cut back to reach it, so the two share the value `Table` fixes.
        static var cushionDepth: Double { Table.cushionDepth }
        /// Height of the nose above the cloth: the top of the cushion's undercut, where its side stops
        /// leaning in. The physics plays on the same figure — see `Table.cushionNoseHeight`.
        static var noseHeight: Double { Table.cushionNoseHeight }
        /// How much more cushion stands **square** on top of the nose: a plain vertical band added over
        /// it, with no lean in it at all, so the cushion is that much taller than its undercut alone.
        static var cushionCap: Double { Table.cushionCap }
        /// Height of a cushion's top: the nose, and the square band above it.
        static var cushionHeight: Double { Table.cushionHeight }
        /// How far a cushion runs on into the jaw at the end of its run, so that the two **overlap**
        /// rather than meeting face to face: two faces left exactly together flicker at a grazing
        /// angle, which reads as a seam down the join. Half a millimetre, and buried inside the jaw.
        static let jawOverlap: Double = 0.5
        /// How round a cushion's edges are: the radius its top edges are taken off with, and the radius
        /// of the fillet where its leaning face meets the square band over its nose. Small enough to
        /// leave a stretch of the square band between the two.
        static let edgeRound: Double = 3
        static var noseRound: Double { Table.cushionNoseRound }
        /// The angle between the cushion's side and the cloth. It is not a right angle: the side is
        /// cut back under the nose, so the nose overhangs the cloth and the cushion's foot sits back
        /// behind it — the reverse angle a real cushion is cut with.
        static var cushionFaceDegrees: Double { Table.cushionFaceDegrees }
        /// How far the cushion's foot is set back behind its nose: the cushion's side is cut back
        /// under the nose by this much over the height of the cushion.
        static var undercut: Double {
            (noseHeight + clothThickness) / tan(cushionFaceDegrees * .pi / 180)
        }
        /// Wooden rail behind the cushion: the width of the wood between the back of a cushion and
        /// the edge of the table. The player walks around the same footprint, so `Table` owns it.
        static var railDepth: Double { Table.railDepth }
        /// How high the wood stands above the cloth. It is the height of the cushion's own top, cap and
        /// all: the border is **level** with the rubber, so the two meet on one line along the join and there
        /// is no step between them for the eye to read as a seam. The wood used to stand two
        /// millimetres proud with its edge two millimetres in over the back of the cushion, and that
        /// pair of lines — the wood's top edge and the cushion's back edge, at different heights and
        /// different places — is what read as the rail being out of line with the cushion.
        static var railHeight: Double { cushionHeight }
        /// How far clear of the back of a cushion the wood's own edge runs. It is **zero**: the wood
        /// begins exactly where the cushion's top ends, so the join is one line — cushion to wood,
        /// level, with nothing overlapping and no crack to flicker down. A hair of a step here shows
        /// as a seam, and a chamfer shows worse: it slopes away where the back of the cushion stands
        /// square, which reads as the rail being out of line with it.
        static let railClearance: Double = 0
        /// Radius the corners of the table's outer outline are taken off with, in the plan.
        static let railEdge: Double = 26
        /// How round the **outer edge** of the rail is: the radius the wood's outer top edge is taken
        /// off with, running right round the table. It is a far wider round than a cushion's own edges
        /// carry, so the frame's outer edge reads as a bull nose rather than a bare arris.
        static let railEdgeRound: Double = 15
        /// Cloth and the slate below it.
        static let clothThickness: Double = 3
        static let slateDepth: Double = 42
        /// Frame hanging below the slates, and how deep a pocket looks before it closes off.
        static let frameDepth: Double = 105
        /// How deep the well below each hole is drawn. It is not the depth of the pocket the
        /// simulation gives a ball (`Table.pocketDepth`, which is deeper than a ball is wide): the
        /// well is lined in black, and the body of the table is drawn solid behind it, so a ball that
        /// sinks past this is out of sight — which is where it should be by the time it is potted.
        static let pocketWell: Double = 44
        /// Legs: plain round **pillars** from the floor up to the frame. There are six of them — the two
        /// ends of the table and the middle of it, down each long side — because a table 3.57 m long wants
        /// carrying in the middle as well as at its ends, which is how a full-size table is made. A pillar
        /// rather than a block: under a table this size a round column reads as a leg, and the shadow it
        /// lays on the floor is a line rather than a slab.
        static let legSection: Double = 150
        static let legInset: Double = 90
        /// Where a pillar's foot is: **on the floor**, which is `Table.floorHeight` below the cloth — and
        /// a few millimetres into it, so that the foot is buried in the slab rather than laid on its
        /// surface, where the two faces would flicker against each other.
        static var legFoot: Double { Table.floorHeight - 5 }

        /// The floor of the room: **three table lengths by four table widths**, centred under the table,
        /// with its face at `Table.floorHeight` — the height a ball forced off the table falls to, which
        /// the physics has always had under the cloth. Light grey **carpet**, and as near a wholly diffuse
        /// surface as the renderer has: see `floorMaterial` and `carpetMaps`.
        static var floorLength: Double { 3 * Table.length }
        static var floorWidth: Double { 4 * Table.width }
        static let floorThickness: Double = 40
        /// How many tiles of the carpet run each way over the floor. The tiles are square on the floor —
        /// 10707/24 across it and 7112/16 along it are both about 445 mm — so the weave does not stretch
        /// one way, whatever the two sizes are.
        static let carpetTilesAlong: Double = 24
        static let carpetTilesAcross: Double = 16

        /// The **ring of small spotlights** round the table: how far out from the playing area they hang —
        /// **1 m clear of the table** (the frame's own outer edge is 143 mm out, so the ring is 1143 mm from
        /// the cushion line), at the height the four big spot lights hang at, so the whole rig over the
        /// table is on one plane.
        static let ringClearance: Double = 1000
        /// How the lamps are spaced round the ring: each side is divided into this many equal runs, so a
        /// lamp stands at **every corner** and the spaces between them are the same all the way down a side
        /// and across from one side to the next. The four corners are counted once each, by the side they
        /// begin, so the ring is 2 x 6 + 2 x 4 = 20 lamps: 976 mm apart along a long side and 1016 mm across
        /// a short one, which is a ring of lamps rather than a row of dots.
        static let ringDivisionsAlong: Int = 6
        static let ringDivisionsAcross: Int = 4
        /// How big a small lamp is: the diameter of its body, and the length of it from the mouth to the top
        /// of its stem. Small next to the four over the table, which are 264 mm across the mouth.
        static let smallLampDiameter: Double = 104
        static let smallLampHeight: Double = 160
    }

    private static var outerX: Double { Furniture.cushionDepth + Furniture.railDepth }
    private static var outerY: Double { Furniture.cushionDepth + Furniture.railDepth }
    /// How far clear of the **table's** own outer edge the ring of small spotlights stands, in
    /// millimetres. Read by the probe, which checks the ring against it.
    static var ringClearance: Double { Furniture.ringClearance }
    /// How thick a leg is, across, in millimetres. Read by the probe, which checks that every pillar
    /// stands under the wood and no part of it reaches past the frame.
    static var legSection: Double { Furniture.legSection }

    /// Where the six legs stand, in the table's own coordinates: three down each long side — the two
    /// ends of the table and the middle of it — each one set in from the **outside of the frame** by
    /// `legInset`, and as far again as its own half-section, so the pillar stands under the wood with its
    /// own width of it left showing beyond. Outside the playing area, which is what puts them under the
    /// frame rather than under the cloth.
    private static var legPillars: [Vec2] {
        let inset = Table3D.outerX - Furniture.legInset - Furniture.legSection / 2
        let ends = [-inset, Table.length + inset]
        let sides = [-inset, Table.width + inset]
        return (ends + [Table.length / 2]).flatMap { x in sides.map { y in Vec2(x, y) } }
    }

    /// The four corners of the ring's rectangle, in order round it: the rectangle is the table's **outer
    /// edge** with `ringClearance` of floor outside it — 1000 mm clear of the frame, 1143 mm out from the
    /// cushion line.
    private static var ringCorners: [Vec2] {
        let out = Table3D.outerX + Furniture.ringClearance
        return [Vec2(-out, -out), Vec2(Table.length + out, -out),
                Vec2(Table.length + out, Table.width + out), Vec2(-out, Table.width + out)]
    }

    /// Where the lamps of the ring stand, in the table's own coordinates: each of the four sides divided
    /// into equal runs, so that a lamp stands **at every corner** and the spaces between them are even all
    /// the way round. A side's own corner is the one it starts at, which is why no side puts a lamp at the
    /// corner it ends on: the next side does that, and each corner is counted once.
    private static var ringPlaces: [Vec2] {
        let corners = Table3D.ringCorners
        return (0..<4).flatMap { side -> [Vec2] in
            let from = corners[side], to = corners[(side + 1) % 4]
            // The runs down the two long sides, and across the two short ones: side 0 is a long side,
            // side 1 a short one, and they alternate.
            let runs = side % 2 == 0 ? Furniture.ringDivisionsAlong : Furniture.ringDivisionsAcross
            return (0..<runs).map { step in
                from + (to - from) * (Double(step) / Double(runs))
            }
        }
    }


    /// The six cushion runs, matching `PhysicsWorld.makeCushions()`. The gaps between them are
    /// the pocket openings.
    private struct Side {
        let a: Vec2
        let b: Vec2
        /// Unit vector pointing away from the playing area.
        let outward: Vec2

        var along: Vec2 { (b - a).normalized }

        /// The run with its jaws taken off, so the cushion stops where each jaw's round begins.
        func trimmed(start: Double, end: Double) -> Side {
            Side(a: a + along * start, b: b - along * end, outward: outward)
        }
    }

    private static var sides: [Side] {
        let L = Table.length, W = Table.width
        let cg = Table.cornerJawGap, mg = Table.middleJawGap
        return [
            Side(a: Vec2(cg, 0), b: Vec2(L / 2 - mg, 0), outward: Vec2(0, -1)),
            Side(a: Vec2(L / 2 + mg, 0), b: Vec2(L - cg, 0), outward: Vec2(0, -1)),
            Side(a: Vec2(cg, W), b: Vec2(L / 2 - mg, W), outward: Vec2(0, 1)),
            Side(a: Vec2(L / 2 + mg, W), b: Vec2(L - cg, W), outward: Vec2(0, 1)),
            Side(a: Vec2(0, cg), b: Vec2(0, W - cg), outward: Vec2(-1, 0)),
            Side(a: Vec2(L, cg), b: Vec2(L, W - cg), outward: Vec2(1, 0)),
        ]
    }

    // MARK: - Coordinates

    /// Millimetres to metres. Everything in the scene is in metres.
    private static func metres(_ millimetres: Double) -> CGFloat { CGFloat(millimetres * 0.001) }
    private static func metresF(_ millimetres: Double) -> Float { Float(millimetres * 0.001) }

    /// An engine point (and optional height above the cloth) in scene coordinates.
    private static func point(_ p: Vec2, height: Double = 0) -> simd_float3 {
        simd_float3(
            metresF(p.x - Table.length / 2),
            metresF(height),
            metresF(Table.width / 2 - p.y)
        )
    }

    /// Back from scene coordinates to the table plane.
    private static func tablePoint(_ v: simd_float3) -> Vec2 {
        Vec2(Double(v.x) * 1000 + Table.length / 2, Table.width / 2 - Double(v.z) * 1000)
    }

    // MARK: - State

    /// The view, when there is one. Snapshots render the same scene with `SCNRenderer`.
    private(set) var view: SCNView?
    let scene = SCNScene()

    private let cameraNode = SCNNode()
    private let ballLayer = SCNNode()
    private let cueLayer = SCNNode()
    private let aimLayer = SCNNode()
    private let markingLayer = SCNNode()
    private let cueNode = SCNNode()
    private let ghostNode = SCNNode()
    private let aimLineNode = SCNNode()
    private let ballLineNode = SCNNode()
    /// The line for the ball being aimed at is drawn in one of two colours: **green** while that ball
    /// is one the cue ball may strike first, and **red** when it is not.
    private let ballLineMaterial = SCNMaterial()
    private let ballLineFoulMaterial = SCNMaterial()

    private var ballNodes: [Int: SCNNode] = [:]
    /// The twelve jaw solids, kept so the snapshot harness can report what they came out as.
    private var jawNodes: [(pocket: PocketID, jaw: PocketCut.Jaw, node: SCNNode)] = []
    /// The six runs of straight cushion, kept for the same reason: the harness reads their shading
    /// back off them where each one runs into the jaw it was cut from.
    private var runNodes: [SCNNode] = []
    /// The six pieces of wooden rail, kept so the harness can read the round on the table's own outer
    /// edge back off the mesh it was built into.
    private var railNodes: [(pocket: PocketID, node: SCNNode)] = []
    /// The ring drawn round a ball the cue ball is touching (Rule 8(a)), by ball.
    private var touchingRings: [Int: SCNNode] = [:]
    /// Which balls to ring: told to the scene each frame by the driver.
    private var touching: Set<Int> = []
    private var markedForDropping = Set<Int>()

    /// The key the fade after a pot runs under, so a ball that is spotted again can call it off.
    private static let dropAction = "drop-into-the-pocket"

    /// Which of the three camera positions the player is standing in.
    /// The eye level the player stands at. They are standing at the table by default and get down
    /// over the ball only to play (see `body`).
    private(set) var preset: PlayerCamera.Preset = .standing

    /// How far down over the shot the player is: 0 standing at the table, 1 down on the ball. Moved
    /// rather than set, so that taking the cue up and the end of a stroke are smooth.
    private var body: Double = 0

    /// Where the offscreen captures have put the player's body, if anywhere: a capture asks for a
    /// particular eye level and should get exactly that rather than the level the game would stand
    /// them at.
    private var heldFraming: PlayerCamera.Preset?

    /// Which eye level the camera is using now, for the label on the screen.
    var cameraLevel: PlayerCamera.Preset {
        if heldFraming == .sighting { return .sighting }
        return body > 0.5 ? .sighting : preset
    }
    /// How far the gaze is raised or lowered. The yaw comes from the frame driver's line of aim.
    private(set) var pitch = PlayerCamera.Preset.sighting.pitch
    /// Whether the player is **crouched** down over the cloth, looking along it at the balls.
    ///
    /// Crouching is not a stance to be left in, like the eye-level presets: a player ducks down for a
    /// look and comes straight back up, so it is a state to hold rather than a level to choose. While it
    /// holds, the **eye** comes down to `PlayerCamera.crouchEyeHeight` above the cloth — 150 mm — and
    /// nothing else moves: the feet stay where they are, the walk and the look carry on, and the eye
    /// goes back up to the standing level the moment the key is let go.
    private(set) var isCrouching = false
    /// The **X** key: the player ducking down over the cloth, or standing back up.
    func setCrouching(_ crouching: Bool) {
        isCrouching = crouching
    }
    /// What the aiming aids show. `G` steps through them.
    ///
    /// The first is the cue ball's own line: where it will meet something, with the ghost ball drawn
    /// at the contact. The second **adds the line of the ball it meets** — where that ball is going to
    /// be sent — which is the half of a shot the cue's own line does not say anything about.
    enum AimingAids: String, CaseIterable, Sendable {
        case off
        case cueLine
        case both

        /// The next one the `G` key asks for.
        var stepped: AimingAids {
            switch self {
            case .off: return .cueLine
            case .cueLine: return .both
            case .both: return .off
            }
        }

        /// What it is doing, for the menu item that shows which step it is on.
        var title: String {
            switch self {
            case .off: return "off"
            case .cueLine: return "the line of aim"
            case .both: return "the line of aim and the ball on's line"
            }
        }
    }

    var aimingAids: AimingAids = .cueLine

    /// How long the aimed ball's line is drawn, in millimetres. It is a fixed length rather than the
    /// distance the ball will really travel, which depends on pace and on what it runs into: the line
    /// is a direction, and a direction is all a player can be told before the shot.
    private static let aimedBallLineLength: Double = 400

    /// The `G` key: on to the next of the aiming aids.
    func stepTheAimingAids() {
        aimingAids = aimingAids.stepped
    }

    /// Whether a line is being drawn for the ball the shot is aimed at: read by the offscreen probe,
    /// which cannot tell a hidden node from one that is showing but paints nothing.
    var aimedBallLineShown: Bool {
        aimingAids == .both && !aimLayer.isHidden && !ballLineNode.isHidden
    }

    /// Whether that line is being drawn in its **red** — the ball it belongs to is not one the cue ball
    /// may strike first. Read by the offscreen probe, which cannot tell one material from another.
    var aimedBallLineIsFoul: Bool {
        ballLineNode.geometry?.firstMaterial === ballLineFoulMaterial
    }

    /// What the line for the ball being aimed at is drawn as, for the offscreen probe: how wide the stripe
    /// is across the line, in millimetres, and how opaque each of its two colours is. The probe cannot see
    /// the cloth, so this is how the line's own build is read back.
    var aimedBallLineFacts: (stripeWidthMM: Double, greenOpacity: Double, redOpacity: Double) {
        let width = (ballLineNode.geometry as? SCNBox).map { Double($0.length) * 1000 } ?? 0
        return (width, Double(ballLineMaterial.transparency), Double(ballLineFoulMaterial.transparency))
    }

    /// How high a marking stands above the cloth, in millimetres: enough that the cloth and the
    /// marking do not fight for the same pixels, little enough that it reads as painted on it. The
    /// table's own markings and the aimed ball's line are both laid at this height.
    static let markingHeightAboveCloth: Double = 0.1
    /// Overall exposure of the rendered scene, in stops. Negative darkens. Set so that the cloth
    /// reads as green baize under its lights rather than washing out to white.
    var exposureOffset: Double = 0

    /// Multiplies the table lights. Handy for tuning the look without rebuilding the scene.
    var lightScale: Double = 1

    /// Whether the plates cast shadows. Kept switchable so the offscreen probe can measure what the
    /// shadows are worth by rendering the same view with and without them.
    var lightsCastShadows: Bool = true {
        didSet {
            for light in plateLights { light.castsShadow = lightsCastShadows }
            for light in cornerLights { light.castsShadow = lightsCastShadows }
        }
    }

    /// Whether the balls reflect their surroundings. Kept switchable so the offscreen probe can
    /// measure what the reflection is worth by rendering the same view with and without it.
    var ballsReflectSurroundings: Bool = true {
        didSet { applyBallReflection() }
    }

    private var plateLights: [SCNLight] = []
    /// The four lights over the corner pockets, which are the ones that cast shadows.
    private var cornerLights: [SCNLight] = []
    /// Whether a ball's node is on show, for the offscreen probe.
    func ballIsShown(_ id: Int) -> String {
        guard let node = ballNodes[id] else { return "no node" }
        return "hidden \(node.isHidden), opacity \(node.opacity), at \(node.simdPosition)"
    }

    /// How high the player's eye is above the cloth, in millimetres, for the offscreen probe.
    var eyeHeight: Double { Double(cameraNode.simdWorldPosition.y) * 1000 }

    /// How many balls are wearing the touching ring, for the offscreen probe.
    var touchingRingsShown: Int { touchingRings.values.filter { !$0.isHidden && !($0.parent?.isHidden ?? false) }.count }
    /// How many balls have a ring at all, and what the scene was last told to ring.
    var touchingRingDiagnostics: String { "rings built \(touchingRings.count), set to ring \(touching.sorted())" }

    /// What the polished surfaces reflect: the lit table, captured from over its middle.
    private var reflectionEnvironment: NSImage?

    /// The lights themselves, for the probe to switch one off at a time.
    var sceneLights: [SCNLight] {
        var found: [SCNLight] = []
        scene.rootNode.enumerateHierarchy { node, _ in
            if let light = node.light { found.append(light) }
        }
        return found
    }

    /// Every light in the scene, as the renderer has it: what kind it is, where it is, and how
    /// bright. Read by the probe, because the answer to "why does only one light show in the ball"
    /// depends on what is actually there.
    var lightInventory: [(kind: String, position: simd_float3, intensity: Double, castsShadow: Bool)] {
        var found: [(String, simd_float3, Double, Bool)] = []
        scene.rootNode.enumerateHierarchy { node, _ in
            guard let light = node.light else { return }
            let kind: String
            switch light.type {
            case .area: kind = "area"
            case .spot: kind = "spot"
            case .ambient: kind = "ambient"
            case .omni: kind = "omni"
            case .directional: kind = "directional"
            case .probe: kind = "probe"
            case .IES: kind = "IES"
            default: kind = "other"
            }
            found.append((kind, node.simdWorldPosition, Double(light.intensity), light.castsShadow))
        }
        return found
    }

    /// The capture itself, for the probe to write out: six faces of 512 pixels in a row.
    var capturedSurroundingsImage: NSImage? { reflectionEnvironment }
    /// The same capture as the six faces of a cube map, which is how SceneKit is given it.
    private var reflectionFaces: [NSImage]?
    /// The three plate panels themselves, kept apart from their lights so a view from above the table
    /// can look past the fixture.
    private var panelNodes: [SCNNode] = []
    /// The four lamps at the corner lights, kept apart from their lights for the same reason: a view from
    /// above the table looks past the fixture, and the light stays on the table.
    private var lampNodes: [SCNNode] = []
    /// The twenty small lamps of the ring round the table, kept apart for the same reason again.
    private var ringLampNodes: [SCNNode] = []
    /// Everything hanging over the table that is drawn rather than lit: the plates, the four lamps and
    /// the twenty small ones. They go out of a view from above the table together — and out of the
    /// capture of the room that the balls reflect — while their lights stay in.
    private var fixtureNodes: [SCNNode] { panelNodes + lampNodes + ringLampNodes }
    private var ambientLight: SCNLight?
    /// One plate of the rig. Three of them light the table: each panel of the fixture is a light.
    ///
    /// The figure is set so that the cloth reads as it did under the two shades the rig replaced,
    /// and was measured with `--lighting-probe`. It is SceneKit's own scale rather than a lamp's
    /// output: its area lights are far dimmer for a given figure than its spot lights.
    private static let plateIntensity: Double = 10200
    /// One light over a corner pocket. These are for the shadows, and are kept well under the
    /// plates so that they fill the corners without leaving four bright pools of their own.
    private static let cornerLightIntensity: Double = 14

    /// The side of the corner lights' shadow map, in texels.
    ///
    /// The four lamps cast from `TableLightRig.heightAboveCloth` with a 120° cone each, so the map's
    /// footprint is several metres of table and **one texel of it stands for millimetres of cloth** —
    /// 7.4 mm at 1024, 3.7 at 2048, 1.9 at 4096. Everything the table casts is drawn in those texels:
    /// a ball is 52.5 mm across and comes out of any of them, but the **cue** is 9.8 mm across at the tip
    /// and 22 at the butt, and a shadow narrower than the texels it is drawn in can only come out as a
    /// staircase. The offscreen probe measures the cue's shadow against this figure.
    static let cornerShadowMapSize: CGFloat = 2048
    /// How dark the lamps' shadows are: the fraction of a lamp's light a shadowed piece of cloth loses.
    /// A shadow is a **shading** of the cloth rather than a hole in it, so this is under the whole lamp:
    /// black at full alpha — which is what it was — reads as the cloth being cut out under the cue. Six
    /// tenths is the figure that keeps the cue's shadow a shadow — the probe reads it as 13.4 levels of
    /// the 255, where taking the whole lamp away made it 24.4 — without losing the contact a ball has
    /// with the cloth.
    static let shadowDepth: CGFloat = 0.6
    /// How much of the captured surroundings the polished surfaces pick up. The cloth should be lit by the
    /// plates and not by the reflection of the room, so this is small rather than nothing: the **balls**
    /// are what it is for, and a ball that does not show the lamps over it — small, sharp, each one where
    /// the light it sits under comes from — is a ball that is being polished for nothing. It was 0.5, which
    /// put the room's reflections under the balls' own highlights and showed nothing of them; doubled, the
    /// lamps read on the balls and the cloth moves by a couple of parts in a hundred, which is checked.
    private static let environmentIntensity: Double = 1.0
    /// The side of one face of the captured surroundings, in pixels.
    private static let environmentFaceSize = 512
    /// The room's own light: a flat, unshadowed wash under everything, which is what a floor away from
    /// the table is lit by. It is a good deal brighter than the token it began as because it is the only
    /// light the **floor** has: the plates hang over the cloth and reach a couple of metres past it and
    /// no further, so without this the floor of the room came out near-black, which is not a floor at
    /// all. The figures are far enough apart that this is a wash on the table (a per cent or two of what
    /// the plates give it) and the whole of the floor's light, which is exactly what an ambient light is
    /// for.
    private static let ambientIntensity: Double = 380

    /// Where the player is standing: the cue ball, eased from shot to shot so that the view
    /// follows the balls rather than jumping when a stroke ends.
    private var anchor = Table.brownSpot
    private var anchorReady = false
    private var cameraReady = false

    /// Where the cue was when the stroke was played, so it stays put while the balls run.
    private var cueHold: (position: Vec2, yaw: Double)?
    /// Where the cue is being carried from one shot to the next.
    private var cueAnchor: (position: Vec2, yaw: Double)?

    /// Where the tip is on the ball's face, in millimetres from its middle: to the striker's right and
    /// up the ball. Read by the offscreen probe, which cannot measure the picture.
    private(set) var cueTipOffset: (across: Double, up: Double) = (0, 0)
    /// Where the tip is drawn, off the middle of the ball, in the table's own coordinates. The
    /// snapshot harness reads it back to check the tip is on the side the player asked for.
    private(set) var cueTipWorldOffset: Vec2 = .zero

    /// How far the tip of the cue stands off the cue ball's centre, in millimetres: the cue's rest
    /// position at the lowest, further back the harder the shot is being drawn. Read by the
    /// offscreen probe, which cannot look at the picture.
    private(set) var cueTipDistance: Double = Table.cueTipGap

    /// Where the tip of the cue is, in the scene: the probe reads it back with the tip lifted to check
    /// that the cue still meets the ball on the same sphere — a radius plus the gap from the middle.
    private(set) var cueTipWorld: simd_float3 = .zero

    /// Where the camera is in the table's own coordinates and height, after the last update: the probe
    /// reads it back to check that down on the shot it stays exactly above the line of the cue.
    private(set) var cameraOnTheTable = (position: Vec2.zero, height: 0.0)

    /// What the camera is looking at, after the last update. Kept so the snapshot harness can
    /// project scene points onto the rendered image.
    private var gazePoint3 = simd_float3(1, 0, 0)

    // MARK: - Life cycle

    /// Builds the scene. Pass a view to display it; leave it out to render offscreen.
    init(view: SCNView? = nil) {
        self.view = view
        scene.background.contents = NSColor(calibratedRed: 0.045, green: 0.05, blue: 0.06, alpha: 1)
        scene.rootNode.addChildNode(ballLayer)
        scene.rootNode.addChildNode(cueLayer)
        scene.rootNode.addChildNode(aimLayer)
        scene.rootNode.addChildNode(markingLayer)
        scene.rootNode.addChildNode(cameraNode)

        buildFurniture()
        buildCue()
        buildAimingAids()
        buildCamera()

        if let view {
            view.scene = scene
            view.pointOfView = cameraNode
            view.backgroundColor = scene.background.contents as? NSColor ?? .black
            view.antialiasingMode = Table3D.antialiasing
            view.preferredFramesPerSecond = 120
            view.isPlaying = true
            view.allowsCameraControl = false
        }
    }

    /// How the table is antialiased, on the view and in the offscreen renders alike: 4× multisampling.
    /// The harness renders with the same setting, so the pictures it takes are the picture the player is
    /// shown.
    static let antialiasing: SCNAntialiasingMode = .multisampling4X

    // MARK: - Static furniture

    private func buildFurniture() {
        let cuts = Table3D.pocketCuts()
        let wood = Table3D.railMaterial()
        let cushion = Table3D.cushionMaterial()
        let clothTop = 0.0
        let slateTop = clothTop - Furniture.clothThickness
        let slateBottom = slateTop - Furniture.slateDepth

        // Cloth: the playing area, cut back to the mouth of each corner pocket.
        scene.rootNode.addChildNode(Table3D.slab(
            path: Table3D.clothPath(cuts),
            thickness: Furniture.clothThickness,
            top: clothTop,
            material: Table3D.clothMaterial()
        ))

        // Slate, with the pockets through it. Slightly inside the frame so the two do not share a
        // face.
        scene.rootNode.addChildNode(Table3D.slab(
            path: Table3D.slatePath(cuts),
            thickness: Furniture.slateDepth,
            top: slateTop,
            material: Table3D.slateMaterial()
        ))

        // Rails: the wood round the outside, with the pockets cut into its inner edge. SceneKit
        // cannot draw one ring with those cuts in it — ask it for that and it fills the whole table
        // with wood — so the rail is laid down as one slab for each pocket, each carrying that
        // pocket's own throat, and the pieces meet along straight cuts across the wood. The wood is
        // built rather than extruded because the throat leans: its cut face is the cushion's own 65°
        // undercut carried on into the wood, so that the wood's edge and the jaw beside it are one
        // leaning surface.
        for (index, piece) in Table3D.railPieces(cuts).enumerated() {
            let railNode = Table3D.leaningSolid(
                piece,
                top: Furniture.railHeight,
                leanFrom: Furniture.noseHeight,
                bottom: -(Furniture.clothThickness + 1),
                closes: true,
                material: wood
            )
            scene.rootNode.addChildNode(railNode)
            railNodes.append((Table3D.railWalk[index].pocket, railNode))
        }

        // Cushions: a profile swept along each run — the nose on the boundary the rules measure to,
        // its top eased off, thickening back to where the rail takes over. A run stops where the
        // jaw's round begins, and the round carries it the rest of the way into the pocket.
        for run in Table3D.sides {
            let trim = run.trimmed(start: Table3D.jawSetback(at: run.a) - Furniture.jawOverlap,
                                   end: Table3D.jawSetback(at: run.b) - Furniture.jawOverlap)
            let runNode = Table3D.cushionNode(trim, material: cushion)
            runNodes.append(runNode)
            scene.rootNode.addChildNode(runNode)
        }

        // The jaws: at each pocket the end of each cushion is cut back with a round of
        // `Table.jawRadius` whose axis is perpendicular to the table, so the cushion is the same
        // height the whole way along and only its plan is cut. The round is what joins the straight
        // cushion, its face, to the pocket's throat — and it is the same circle the ball bounces
        // off, so what is drawn and what is played against are one shape.
        for pocket in PocketID.allCases {
            let cut = cuts[pocket]!
            for jaw in [cut.jaws.0, cut.jaws.1] {
                let node = Table3D.jawNode(jaw, material: cushion)
                scene.rootNode.addChildNode(node)
                jawNodes.append((pocket, jaw, node))
            }
        }

        // Pockets: the table's surface is cut away at each hole, and the hole drops away, lined in
        // black. The round hole is the whole pocket: the surface runs on into the throat around it.
        let lining = Table3D.pocketMaterial()
        for pocket in PocketID.allCases {
            let cut = cuts[pocket]!
            let well = SCNCylinder(radius: Table3D.metres(cut.holeRadius),
                                   height: Table3D.metres(Furniture.pocketWell - 2))
            well.radialSegmentCount = 96
            well.firstMaterial = lining
            let node = SCNNode(geometry: well)
            node.simdPosition = Table3D.point(cut.holeCentre,
                                              height: -2 - (Furniture.pocketWell - 2) / 2)
            scene.rootNode.addChildNode(node)
        }

        // The body below the slates.
        scene.rootNode.addChildNode(Table3D.slab(
            path: Table3D.outerPath(inset: 0),
            thickness: Furniture.frameDepth,
            top: slateBottom,
            material: wood
        ))

        // The floor the table stands on: a plain slab under the whole room, its face at
        // `Table.floorHeight` — the height the physics lands a ball forced off the table at — so the
        // floor the simulation has always had under the cloth is the floor the eye sees, and the feet of
        // the legs meet it. Light grey, with nothing specular in it at all: see `floorMaterial`.
        let floor = SCNBox(
            width: Table3D.metres(Furniture.floorLength),
            height: Table3D.metres(Furniture.floorThickness),
            length: Table3D.metres(Furniture.floorWidth),
            chamferRadius: 0
        )
        floor.firstMaterial = Table3D.floorMaterial()
        let floorNode = SCNNode(geometry: floor)
        floorNode.name = "floor"
        floorNode.simdPosition = Table3D.point(Vec2(Table.length / 2, Table.width / 2),
                                               height: Table.floorHeight - Furniture.floorThickness / 2)
        scene.rootNode.addChildNode(floorNode)

        // Six pillars from the floor to the frame. Their heads carry on up into the body of the frame,
        // where they are buried, so there is no joint to see where the leg meets the table.
        let legHead = slateBottom - 10
        for centre in Table3D.legPillars {
            let pillar = SCNCylinder(radius: Table3D.metres(Furniture.legSection / 2),
                                     height: Table3D.metres(legHead - Furniture.legFoot))
            pillar.radialSegmentCount = 72
            pillar.firstMaterial = wood
            let node = SCNNode(geometry: pillar)
            node.name = "leg"
            node.simdPosition = Table3D.point(centre, height: (legHead + Furniture.legFoot) / 2)
            scene.rootNode.addChildNode(node)
        }

        // The table's **shadow** on the carpet: a soft black shape the size of the table's plan, a
        // couple of millimetres above the carpet and drawn from `tableShadowMap`. See that for why it is drawn and not
        // cast. It is unlit, so it does not glow and takes no light of its own; it only takes the carpet
        // down where the table stands over it.
        let shadow = SCNPlane(width: Table3D.metres(Table3D.shadowQuadLength),
                              height: Table3D.metres(Table3D.shadowQuadWidth))
        shadow.firstMaterial = Table3D.tableShadowMaterial()
        let shadowNode = SCNNode(geometry: shadow)
        shadowNode.name = "table shadow"
        shadowNode.castsShadow = false
        shadowNode.simdOrientation = simd_quatf(angle: -.pi / 2, axis: simd_float3(1, 0, 0))
        shadowNode.simdPosition = Table3D.point(Vec2(Table.length / 2, Table.width / 2),
                                               height: Table.floorHeight + 2)
        scene.rootNode.addChildNode(shadowNode)

        buildMarkings()
    }

    /// The baulk line, the "D" and the six spots, laid on the cloth the way they are marked on a
    /// real table. The positions are the rule book's.
    private func buildMarkings() {
        let marking = Table3D.markingMaterial()

        let line = SCNBox(
            width: Table3D.metres(3),
            height: Table3D.metres(0.5),
            length: Table3D.metres(Table.width),
            chamferRadius: 0
        )
        line.firstMaterial = marking
        let lineNode = SCNNode(geometry: line)
        lineNode.simdPosition = Table3D.point(Vec2(Table.baulkLineX, Table.width / 2),
                                              height: Table3D.markingHeightAboveCloth)
        markingLayer.addChildNode(lineNode)

        // The "D": a hairline arc of the rule book's radius, on the baulk side of the line.
        markingLayer.addChildNode(Table3D.slab(
            path: Table3D.dMarkingPath(),
            thickness: 0.5,
            top: 0.35,
            material: marking
        ))

        for (_, spot) in Table.allSpots {
            let dot = SCNCylinder(radius: Table3D.metres(3.5), height: Table3D.metres(0.5))
            dot.radialSegmentCount = 32
            dot.firstMaterial = marking
            let node = SCNNode(geometry: dot)
            node.simdPosition = Table3D.point(spot, height: Table3D.markingHeightAboveCloth)
            markingLayer.addChildNode(node)
        }
    }

    /// The "D": a band of the rule book's radius, drawn on the baulk side of the baulk line.
    static func dMarkingPath() -> NSBezierPath {
        let path = NSBezierPath()
        let outer = Table.dRadius + 1.5
        let inner = Table.dRadius - 1.5
        // Out along the outer radius from one corner of the D to the other, passing through the
        // baulk end, then back along the inner radius the other way round, so the band is closed.
        addArc(path, centre: Table3D.plan(Table.brownSpot), radius: Table3D.planRadius(outer),
               from: 90, to: 270, continuing: false)
        addArc(path, centre: Table3D.plan(Table.brownSpot), radius: Table3D.planRadius(inner),
               from: 270, to: 90, clockwise: true)
        path.close()
        return path
    }
    // MARK: - The shape of the table
    //
    // The furniture is drawn flat, in the table's own millimetres, and then laid on the table: a
    // path's x runs up the table and its y runs across, the way the engine's does.

    /// An engine point as a point in a flat path, in metres about the table's centre.
    private static func plan(_ p: Vec2) -> CGPoint {
        CGPoint(x: CGFloat((p.x - Table.length / 2) * 0.001),
                y: CGFloat((p.y - Table.width / 2) * 0.001))
    }

    private static func planRadius(_ millimetres: Double) -> CGFloat {
        CGFloat(millimetres * 0.001)
    }

    /// An engine direction in the scene, where the engine's y runs along `-z`.
    private static func direction(_ d: Vec2) -> simd_float3 {
        simd_float3(Float(d.x), 0, Float(-d.y))
    }

    /// The cut of every pocket, which is what the table is shaped around.
    static func pocketCuts() -> [PocketID: PocketCut] {
        var cuts: [PocketID: PocketCut] = [:]
        for pocket in PocketID.allCases { cuts[pocket] = pocket.cut }
        return cuts
    }

    /// A pocket's outline as a flat path of its own.
    static func voidPath(_ cut: PocketCut) -> NSBezierPath {
        let path = NSBezierPath()
        for (index, point) in cut.outline().enumerated() {
            if index == 0 { path.move(to: plan(point)) } else { path.line(to: plan(point)) }
        }
        path.close()
        return path
    }

    /// A run of table points as a flat path laid on the table, closed: the shape one slab is cut to.
    static func flatPath(_ points: [Vec2]) -> NSBezierPath {
        let path = NSBezierPath()
        for (index, point) in points.enumerated() {
            if index == 0 { path.move(to: plan(point)) } else { path.line(to: plan(point)) }
        }
        path.close()
        return path
    }

    /// How far the wood's cut round a pocket opens out between the top of the wood and the bottom of
    /// it: the cut stands square down the cushion's own band over the nose, and below that leans at
    /// the cushion's 65° to the cloth — the same undercut a jaw carries — so it is the drop from the
    /// **nose** to the bottom of the slab that opens it out.
    static var railCutOpening: Double {
        (Furniture.noseHeight + Furniture.clothThickness + 1) / tan(Furniture.cushionFaceDegrees * .pi / 180)
    }

    /// The outline the wood is cut to round a pocket, and the way that outline leans as it comes down.
    ///
    /// At the **top of the wood** the cut is a straight throat of the **mouth's** own width either side
    /// of the pocket's axis, closed by the hole's semicircle: 78 mm across, which is the line the jaws'
    /// noses stand on. It leans outwards as it comes down at the cushion's own 65° to the cloth — the
    /// undercut a jaw carries — so that at the level of the cloth it is 109.09 mm across, the line the
    /// two jaws' feet stand on. The hole itself is cut wider again than that — `pocketHoleClearance` on
    /// each side, and 20 mm more at a corner — and the cut opens on down to the bottom of the wood. A
    /// jaw's face and the wood's edge beside it are then one and the same leaning surface, tangent to
    /// one another down the whole length of the throat, rather than the wood standing square where the
    /// jaw leans away from it.
    ///
    /// Each point comes with the direction its side is set back in and how far. The two ends are the
    /// exception: they stand on the line the wood stops at, and that face is square, so their feet
    /// slide **along** that line rather than striking off it.
    static func pocketSlot(_ cut: PocketCut,
                           openingOut out: Double = Table3D.railCutOpening
    ) -> [Edge] {
        let d = Table.cushionDepth + Furniture.railClearance
        let across = cut.axis.perpendicular
        let mouth = cut.width / 2
        let far = cut.holeCentre + cut.axis * mouth
        /// Where one side of the throat meets the line the wood stops at, on the table's side of the
        /// hole: the crossing behind the hole is on the far side of the pocket and no use to the walk.
        func whereTheSideMeetsTheWood(_ offset: Double) -> Vec2? {
            let touching = cut.holeCentre + across * offset
            var best: (point: Vec2, along: Double)?
            for tip in [cut.tipA, cut.tipB] {
                let outward = PocketCut.outward(at: tip)
                let rate = cut.axis.dot(outward)
                guard abs(rate) > 1e-9 else { continue }          // this side runs parallel to it
                // The line the wood stops at is `d` out from the cushion's own face, measured the way
                // that cushion's outward points: 48 mm out from a middle pocket's cushion is y = -48,
                // but from the top cushion it is y = 1778 + 48, and the tip stands on the face.
                let line = d + outward.dot(tip)
                let reach = (line - touching.dot(outward)) / rate
                guard reach < 0 else { continue }                 // that crossing is behind the hole
                if best == nil || reach > (best?.along ?? 0) {
                    best = (touching + cut.axis * reach, reach)
                }
            }
            return best?.point
        }

        let touching = [cut.holeCentre + across * mouth, cut.holeCentre - across * mouth]
        let ends = [whereTheSideMeetsTheWood(mouth), whereTheSideMeetsTheWood(-mouth)]
        // Taken the way the walk round the table takes them: the end nearest one jaw tip first, and
        // the end nearest the other last.
        var order = [0, 1]
        if let a = ends[0], let b = ends[1],
           b.distance(to: cut.tipA) + a.distance(to: cut.tipB)
            < a.distance(to: cut.tipA) + b.distance(to: cut.tipB) {
            order = [1, 0]
        }
        guard let first = ends[order[0]], let last = ends[order[1]] else {
            return [Edge(point: far)]
        }
        // The feet of the two ends: the same lines where they meet the wood once the cut has opened out
        // to the bottom of the slab, so that the ends slide along the wood rather than lean across it.
        let feet = [whereTheSideMeetsTheWood(mouth + out), whereTheSideMeetsTheWood(-mouth - out)]
        func end(_ index: Int, at point: Vec2?) -> Edge {
            guard let point, let foot = feet[index] else { return Edge(point: point ?? far) }
            let slide = foot - point
            return Edge(point: point, back: slide.normalized, setback: slide.length)
        }
        return [end(order[0], at: first)]
            + PocketCut.arcPoints(centre: cut.holeCentre, radius: mouth,
                                  from: touching[order[0]], to: touching[order[1]],
                                  through: far, step: 4)
                .map { Edge(point: $0, back: ($0 - cut.holeCentre).normalized, setback: out) }
            + [end(order[1], at: last)]
    }

    /// Adds a loop of points as a subpath of its own, wound the way asked, so that holes can be cut
    /// with the opposite winding to the shape around them.
    private static func addLoop(_ path: NSBezierPath, _ points: [Vec2], counterclockwise: Bool) {
        guard points.count > 2 else { return }
        let run = ((signedArea(points) > 0) == counterclockwise) ? points : points.reversed()
        for (index, point) in run.enumerated() {
            if index == 0 { path.move(to: plan(point)) } else { path.line(to: plan(point)) }
        }
        path.close()
    }

    /// Twice the signed area of a loop: positive when it runs counter-clockwise in the plan.
    private static func signedArea(_ points: [Vec2]) -> Double {
        var sum = 0.0
        for index in points.indices {
            let a = points[index], b = points[(index + 1) % points.count]
            sum += a.x * b.y - b.x * a.y
        }
        return sum
    }

    /// Adds an arc as a run of short straight segments, wound the way we ask.
    ///
    /// SceneKit flattens a path's curves itself, and measured in the scene's own units that is very
    /// coarse: a quarter circle of 292 mm came out as a single straight line, which turned the "D"
    /// into a wedge and each pocket into a triangle. Laying the segments down here avoids that.
    private static func addArc(
        _ path: NSBezierPath,
        centre: CGPoint,
        radius: CGFloat,
        from start: Double,
        to end: Double,
        clockwise: Bool = false,
        continuing: Bool = true,
        step: Double = 3
    ) {
        var sweep = end - start
        if clockwise {
            while sweep > 0 { sweep -= 360 }
            // A whole turn clockwise sweeps -360, not 0: normalising 360 down to nothing drew a
            // point instead of a circle, which left the slate's pockets uncut.
            if sweep == 0 { sweep = -360 }
        } else {
            while sweep < 0 { sweep += 360 }
            if sweep == 0 { sweep = 360 }
        }
        let count = max(2, Int(abs(sweep) / step) + 1)
        for index in 0...count {
            let radians = (start + sweep * Double(index) / Double(count)) * .pi / 180
            let point = CGPoint(x: centre.x + radius * CGFloat(cos(radians)),
                                y: centre.y + radius * CGFloat(sin(radians)))
            if index == 0, !continuing { path.move(to: point) } else { path.line(to: point) }
        }
    }

    /// The cloth: the bed, cut away at each pocket's hole and nowhere else.
    ///
    /// It runs on under the cushions and the rails, which stand over it, so the only places the cloth
    /// is seen to stop are the holes. The surface therefore runs into each pocket's throat and forms
    /// part of the hole at the end of it.
    static func clothPath(_ cuts: [PocketID: PocketCut]) -> NSBezierPath {
        let path = outerPath(inset: 1)
        for pocket in PocketID.allCases { addHole(path, cuts[pocket]!) }
        return path
    }

    /// The wood the rails are made of, as one path per pocket: **the shape the probe reads**, rather
    /// than the shape the renderer draws.
    ///
    /// The renderer lays each piece down as a slab of its own (see `railPieces`), because SceneKit
    /// will not draw one path carrying more than one pocket's cut. The pieces are separate loops that
    /// meet along the cuts between them, so a single path holding every one of them is the rail the
    /// renderer puts together, and the probe can ask it whether a point is in the wood.
    static func railPath(_ cuts: [PocketID: PocketCut]) -> NSBezierPath {
        let path = NSBezierPath()
        for piece in Table3D.railPieces(cuts) {
            addLoop(path, piece.map(\.point), counterclockwise: true)
        }
        return path
    }

    /// The pockets in the order the walk round the table's inner line meets them — the line the wood
    /// stops at, which is the back of the cushions — and whether each pocket's cut is taken against
    /// the walk. The pockets on the long sides run with it; the ones at the ends of the table are met
    /// on the other hand, so their cuts are turned round.
    static let railWalk: [(pocket: PocketID, against: Bool)] = [
        (.bottomLeft, true), (.bottomMiddle, false), (.bottomRight, false),
        (.topRight, true), (.topMiddle, true), (.topLeft, false),
    ]

    /// The points of a flat path, back in table millimetres.
    private static func polyline(of path: NSBezierPath) -> [Vec2] {
        var points: [Vec2] = []
        var element = [NSPoint](repeating: .zero, count: 3)
        for index in 0..<path.elementCount {
            let kind = path.element(at: index, associatedPoints: &element)
            guard kind == .moveTo || kind == .lineTo else { continue }
            let point = Vec2(Double(element[0].x) * 1000 + Table.length / 2,
                             Double(element[0].y) * 1000 + Table.width / 2)
            // An arc is begun with a step at the very place the line before it ended, so the polyline
            // would carry that place twice. A step of no length has no direction of its own, and the
            // round read off it comes out anywhere, so the repeat is dropped here.
            if let last = points.last, last.distance(to: point) < 1e-6 { continue }
            points.append(point)
        }
        return points
    }

    /// The wood of the rails, as **one piece for each pocket**.
    ///
    /// SceneKit draws a simple outline — one loop, with a pocket's throat cut into it — but it cannot
    /// draw a *ring* with those cuts in it as well: ask it for that and it fills the whole table with
    /// wood. So the rail is cut into pieces, one per pocket, each running from the middle of the
    /// stretch of cushion before that pocket to the middle of the stretch after it, with the pocket's
    /// own throat cut into it. A piece is one loop and no more, which is what SceneKit can do, and
    /// the pieces meet along the cuts between them, so the wood still reads as one rail.
    ///
    /// A piece is the wood between two rays from the middle of the table: its inner side is the line
    /// the wood stops at, with that pocket's throat cut into it, and its outer side is the table's own
    /// outline between the two rays, taken the near way round — past the corner the piece stands at,
    /// never further. Each piece takes the pocket it is named for; the piece before it ends on the
    /// same ray, so the two meet exactly. Only the throat leans: every other edge of the piece is
    /// square to the cloth, so the wood stands level with the cushion along its back and the table's
    /// own edge stands plumb.
    static func railPieces(_ cuts: [PocketID: PocketCut]) -> [[Edge]] {
        let middle = Vec2(Table.length / 2, Table.width / 2)
        let outer = Table3D.polyline(of: Table3D.outerPath(inset: 0))
        let blocks = Table3D.railWalk.map { pocket, against -> [Edge] in
            let slot = Table3D.pocketSlot(cuts[pocket]!)
            return against ? Array(slot.reversed()) : slot
        }
        /// Where the ray from the middle of the table through a point meets the table's own outline,
        /// and how far round that outline the meeting point lies, counted in edges: `3.5` is the
        /// middle of the edge from the outline's fourth point to its fifth.
        ///
        /// The table's own outline is straight along each side — the corner is the only place it has
        /// points to spare — so where a ray meets it is found by arithmetic on the edge, not by
        /// looking for a point near it: the nearest point of the outline to a piece's end is a corner
        /// of the table, and a piece cut to that is a bow tie SceneKit will not draw.
        func outToTheEdge(_ p: Vec2) -> (point: Vec2, along: Double) {
            let arm = p - middle
            var best = (point: p, along: 0.0, run: Double.infinity)
            for index in outer.indices {
                let a = outer[index], b = outer[(index + 1) % outer.count]
                let side = b - a
                let across = arm.x * side.y - arm.y * side.x
                guard abs(across) > 1e-12 else { continue }
                let fromA = a - middle
                let along = (fromA.x * side.y - fromA.y * side.x) / across
                let onTheSide = (fromA.x * arm.y - fromA.y * arm.x) / across
                guard along > 1e-9, onTheSide > -1e-9, onTheSide < 1 + 1e-9 else { continue }
                if along < best.run {
                    best = (middle + arm * along,
                            Double(index) + min(1, max(0, onTheSide)),
                            along)
                }
            }
            return (best.point, best.along)
        }
        /// The table's own outline between the far ends of two rays, the near way round: the
        /// outline's own points between the two, and `last` — where the second ray meets it — on the
        /// tail.
        func theEdge(from: Double, to: Double, endingAt last: Vec2) -> [Vec2] {
            let count = Double(outer.count)
            var step = to - from
            while step > count / 2 { step -= count }
            while step < -count / 2 { step += count }
            var points: [Vec2] = []
            // Taken in the order the piece runs, which is the way the outline is walked when the
            // piece runs with it and the other way when it runs against: laid down in the outline's
            // own order either way, the corner comes out as a bow tie. How far each of the outline's
            // points is from the start of the run, measured **along** the run, is what puts them in
            // that order — the walk wraps round the end of the outline, so the points on the far side
            // of the wrap come first when the piece runs against the outline.
            var run: [(along: Double, point: Vec2)] = []
            for index in outer.indices {
                var turned = Double(index) - from
                if step > 0 {
                    while turned <= 0 { turned += count }
                } else {
                    while turned >= 0 { turned -= count }
                }
                if abs(turned) < abs(step) - 1e-9 { run.append((abs(turned), outer[index])) }
            }
            points = run.sorted { $0.along < $1.along }.map(\.point)
            points.append(last)
            return points
        }
        /// A point of the wood with no lean of its own: square to the cloth, as the line the wood
        /// stops at and the table's own outline are. `over` says whether the edge along its top is
        /// rounded: the outer edge of the table and the pockets are, and the joins — the line the wood
        /// stops at, where the cushion stands against it, and the cuts between the pieces — are not.
        ///
        /// The run round the table's own outline carries `Furniture.railEdgeRound`: the wood's outer
        /// edge is taken off with a wide round, so the frame's rim is a bull nose. The points off a
        /// pocket's cut are left at the default, a cushion's own radius, so the wood's edge beside a
        /// jaw matches the jaw it runs on into.
        func square(_ p: Vec2, over: Bool = true) -> Edge {
            Edge(point: p, round: over ? Furniture.railEdgeRound : 0)
        }
        /// A piece's outline with any point repeated at the same place taken out, the loop's own ends
        /// counting as neighbours. Two points in a row at one place leave a step of no length between
        /// them, and the round-over read off a step with no direction of its own comes out anywhere —
        /// so the repeat is dropped. Where the two carry different rounds, the wider is kept, so a
        /// point that is meant to be rounded is never thrown away in favour of a square one.
        func withoutRepeats(_ loop: [Edge]) -> [Edge] {
            var out: [Edge] = []
            for edge in loop {
                if let last = out.last, last.point.distance(to: edge.point) < 1e-6 {
                    out[out.count - 1].round = max(out[out.count - 1].round, edge.round)
                    continue
                }
                out.append(edge)
            }
            if out.count > 2, let first = out.first, let last = out.last,
               first.point.distance(to: last.point) < 1e-6 {
                out[0].round = max(first.round, last.round)
                out.removeLast()
            }
            return out
        }
        return blocks.indices.map { index in
            let before = blocks[(index + blocks.count - 1) % blocks.count]
            let after = blocks[(index + 1) % blocks.count]
            let start = (before.last!.point + blocks[index].first!.point) * 0.5
            let finish = (blocks[index].last!.point + after.first!.point) * 0.5
            let startEdge = outToTheEdge(start)
            let finishEdge = outToTheEdge(finish)
            let edge = theEdge(from: finishEdge.along, to: startEdge.along, endingAt: startEdge.point)
            // The outer edge of the table is rounded over, and the round runs on across the cuts
            // between the pieces: the cut's own face is buried between two pieces and both of them
            // carry the same ramp up it, so nothing shows. It is the line the wood stops at that is
            // left square, since the cushion stands against it there and a round would cut a groove
            // down the join.
            let run = edge.dropLast().map { square($0) } + [square(edge.last!)]
            return withoutRepeats([square(start, over: false)] + blocks[index]
                + [square(finish, over: false), square(finishEdge.point)] + run)
        }
    }


    /// Lays a flat path on the table as a slab whose top surface sits `top` millimetres above the
    /// cloth.
    ///
    /// `lean` slides the plan outwards as the slab comes down, in millimetres out per millimetre
    /// down: the top face stays where the path put it, and the base ends up behind it.
    private static func slab(
        path: NSBezierPath,
        thickness: Double,
        top: Double,
        chamfer: Double = 0,
        lean: Vec2 = .zero,
        material: SCNMaterial
    ) -> SCNNode {
        let shape = SCNShape(path: path, extrusionDepth: metres(thickness))
        shape.chamferRadius = metres(chamfer)
        shape.firstMaterial = material
        let node = SCNNode(geometry: shape)
        let bounds = node.boundingBox
        let measured = Double(bounds.max.z) - Double(bounds.min.z)
        let depth = Double(metres(thickness))
        let topZ = measured > depth * 0.5 ? Double(bounds.max.z) : depth / 2
        let shift = lean * topZ
        node.simdTransform = simd_float4x4(columns: (
            simd_float4(1, 0, 0, 0),
            simd_float4(0, 0, -1, 0),
            simd_float4(Float(-lean.x), 1, Float(lean.y), 0),
            simd_float4(Float(shift.x), Float(metres(top)) - Float(topZ), Float(-shift.y), 1)
        ))
        return node
    }

    /// How far back from a tip a cushion stops: the round is tangent to the face that far in.
    private static func jawSetback(at tip: Vec2) -> Double {
        // A tip on the long cushion away from its ends is a middle pocket's jaw: a square corner
        // there, so the round takes a full radius off the cushion. A corner pocket's jaw is a 135°
        // corner, where the tangent is shorter by the tan of half the angle.
        Table3D.isAMiddlePocket(tip) ? Table.jawRadius : Table.jawRadius / tan(67.5 * .pi / 180)
    }

    /// Whether a tip is one of a middle pocket's pair. The two middle pockets are the only jaws whose
    /// cushion runs straight into them, rather than the round meeting a corner's throat.
    static func isAMiddlePocket(_ tip: Vec2) -> Bool {
        let onTheLongCushion = abs(tip.y) < 1e-9 || abs(tip.y - Table.width) < 1e-9
        return onTheLongCushion
            && abs(abs(tip.x - Table.length / 2) - Table.middleJawGap) < 1e-6
    }

    /// Which way a cushion goes back from one of its tips.
    private static func outward(at tip: Vec2) -> Vec2 {
        PocketCut.outward(at: tip)
    }

    /// How tall the side of a jaw is, from the bottom of the cloth up to the nose, and how far its
    /// foot is set back where the jaw takes the cushion's own undercut. The side's angle to the
    /// cloth is made of the two of them, which is what the snapshot probe measures.
    static var jawSideHeight: Double { Furniture.noseHeight + Furniture.clothThickness }
    static var jawFootSetback: Double { Furniture.undercut }
    /// How high the wood of the border stands above the cloth, and how far clear of a cushion's back
    /// its inner edge runs. The snapshot probe reads both.
    static var railHeightAboveCloth: Double { Furniture.railHeight }
    static var railClearanceFromCushion: Double { Furniture.railClearance }
    /// The radius the wood's own outer edge is taken off with. The snapshot probe reads it back off
    /// the built mesh and checks it against this.
    static var railOuterEdgeRound: Double { Furniture.railEdgeRound }
    /// How high the cushion's own top is, for comparing with the wood's.
    static var cushionTopAboveCloth: Double { Furniture.cushionHeight }
    /// How high the cushion stands square above its own nose.
    static var cushionCapAboveNose: Double { Furniture.cushionCap }
    /// How high the top of the cushion's undercut is: where its side stops leaning in.
    static var cushionNoseAboveCloth: Double { Furniture.noseHeight }
    /// How deep the pocket well is drawn, which is where a potted ball passes out of sight.
    static var pocketWellDepth: Double { Furniture.pocketWell }

    /// The round at the end of a cushion: the piece of cushion between the round where it leaves the
    /// face, the round itself, and the throat the round runs into. The cushion is the same height the
    /// whole way along, and only the jaw's side changes — see `jawSide`.
    private static func jawNode(_ jaw: PocketCut.Jaw, material: SCNMaterial) -> SCNNode {
        leaningSolid(jawSide(jaw),
                     top: Furniture.cushionHeight,
                     leanFrom: Furniture.noseHeight,
                     bottom: -Furniture.clothThickness,
                     closes: false,
                     material: material)
    }

    /// A cushion: its profile swept along the run, with the nose on the boundary the rules measure
    /// the playing area to.
    ///
    /// The side leans in under the nose, and the last few millimetres of the cushion's height stand
    /// **square** on top of it: a plain vertical band, so the face of the cushion has a square edge
    /// above its undercut rather than running on up the same lean.
    static var cushionProfile: [(Double, Double)] {
        let bottom = -Furniture.clothThickness
        let nose = Furniture.noseHeight
        let lean = 1 / tan(Furniture.cushionFaceDegrees * .pi / 180)
        return [
            (-(nose - bottom) * lean, bottom),      // the foot of the side, under the cloth
            (-nose * lean, 0),                      // where the side meets the cloth
            (0, nose),                              // the nose, overhanging the foot
            (0, nose + Furniture.cushionCap),       // and straight up the square band above it
            (-Furniture.cushionDepth, nose + Furniture.cushionCap),   // the top, level back to the wood
            (-Furniture.cushionDepth, bottom),
        ]
    }

    /// A cushion: a run built the same way as a jaw and the wood, rather than a profile pushed out
    /// along it.
    ///
    /// The outline is the rectangle the cushion stands on — from one end of the run to the other, and
    /// back along the wood — and the one edge of it that is not square is the face, which leans out
    /// under the nose. The top of the solid is that rectangle at the cushion's own height, so the
    /// top is flat from the face back to the wood; the square band above the nose, the lean below it
    /// and the ends are all in the same solid. **It is not extruded from the profile**: SceneKit fills
    /// a path shaped like that with its convex hull, which takes the square band off the face — the
    /// cushion comes out pointed, with the top sloping away from the nose — and it is only the top
    /// that comes out level.
    private static func cushionNode(_ run: Side, material: SCNMaterial) -> SCNNode {
        // The cushion's body stands **behind** its face, the way the run's own outward points: the face
        // is the boundary the rules measure the playing area to, and the rubber is outside it.
        // The **face** is rounded over — the one edge of the cushion that shows — and it is rounded the
        // same way the whole length of the run and on into the jaw, with no easing out at the ends. The
        // back, where the wood stands against the cushion, and the two ends, where a jaw takes over, are
        // left square: a square edge keeps its own line, so the top is flat right up to the line the
        // wood stops at and the run and the jaw meet flush.
        let behind = run.outward
        let depth = Furniture.cushionDepth
        let outline: [Edge] = [
            Edge(point: run.a, back: behind, setback: Furniture.undercut),
            Edge(point: run.b, back: behind, setback: Furniture.undercut),
            Edge(point: run.b + behind * depth, round: 0),
            Edge(point: run.a + behind * depth, round: 0),
        ]
        return leaningSolid(outline,
                            top: Furniture.cushionHeight,
                            leanFrom: Furniture.noseHeight,
                            bottom: -Furniture.clothThickness,
                            closes: true,
                            material: material)
    }


    /// The side of one jaw of a pocket: its plan path round from the cushion's face to the pocket,
    /// the direction its side is set back in at each point of that path, and how far — in
    /// millimetres — it is set back there, which is how far the foot of the jaw lies behind the
    /// nose above it.
    ///
    /// In plan a jaw is the round of `Table.jawRadius` the cushion is cut back with, run on along the
    /// throat to the cushion's base and closed off at the end of the cushion's face. In section it is
    /// the cushion's own undercut — the side leaning out under its nose — carried on the whole way:
    /// round the round, down the throat, and into the wood. The lean is taken **square to the jaw's
    /// own outline**, which is what a cushion's undercut is: 65° to the cloth, over the height of the
    /// cushion, measured in the direction the side is set back in. So the foot is the outline itself
    /// carried inwards by the undercut along its own perpendicular.
    static func jawSide(_ jaw: PocketCut.Jaw) -> [Edge] {
        let outward = Table3D.outward(at: jaw.tip)
        let depth = Furniture.cushionDepth
        let throat = (jaw.atTheThroat - jaw.tip).normalized
        func howDeep(_ point: Vec2) -> Double { (point - jaw.atTheFace).dot(outward) }
        /// Where a line through `from` in `along` reaches the depth the cushion's base sits at.
        func atTheBase(_ from: Vec2, along: Vec2) -> Vec2 {
            let rate = along.dot(outward)
            guard abs(rate) > 1e-9 else { return from }
            return from + along * ((depth - howDeep(from)) / rate)
        }

        let middle = jaw.centre
            + (jaw.atTheFace - jaw.centre + jaw.atTheThroat - jaw.centre).normalized * jaw.radius
        let round = PocketCut.arcPoints(centre: jaw.centre, radius: jaw.radius,
                                        from: jaw.atTheFace, to: jaw.atTheThroat, through: middle)
        // The side is set back square to the jaw's own outline: the round's radius where the path is
        // the round, and the one direction square to the throat where the path is the throat. The two
        // are the same direction where they meet, because the throat is tangent to the round there.
        let acrossTheThroat = (jaw.centre - jaw.atTheThroat).normalized
        let setback = Furniture.undercut
        var side: [Edge] = []

        for point in round {
            // Round the jaw to the pocket, stopping where the cushion's own base does. The round carries
            // on unbroken from the run of cushion this jaw was cut from: the first point of all is
            // rounded like the rest, and it is the edge where the jaw meets the run that is left square.
            if howDeep(point) <= depth + 1e-9 {
                side.append(Edge(point: point, back: (jaw.centre - point).normalized, setback: setback))
                continue
            }
            if let last = side.last {
                side.append(Edge(point: atTheBase(last.point, along: point - last.point),
                                 back: acrossTheThroat, setback: setback))
            }
            break
        }
        if let last = side.last, howDeep(last.point) < depth - 1e-9 {
            side.append(Edge(point: atTheBase(last.point, along: throat),
                             back: acrossTheThroat, setback: setback))
        }
        // Back along the base and up the end of the cushion to the face, taking the cushion's own
        // undercut so that the jaw and the cushion meet flush.
        side.append(Edge(point: jaw.atTheFace + outward * depth, back: outward,
                         setback: Furniture.undercut, round: 0))
        return side
    }

    /// The triangles of a simple outline by ear clipping: the wood of the rail has a pocket's throat
    /// bitten out of it, so it is not convex and its faces cannot be left to a fan.
    ///
    /// The points that carry no corner are dropped first — a point repeated, or one lying in line on
    /// the straight run between its neighbours. A long edge of the rail is a run of such points, and
    /// left in they lie on the edge of every ear along it: no ear is ever found, and the face comes
    /// out with a bite of its own missing.
    private static func triangulate(_ points: [Vec2]) -> [(Int, Int, Int)] {
        var run: [Int] = []
        for index in points.indices {
            if let last = run.last, points[index].distance(to: points[last]) < 1e-9 { continue }
            run.append(index)
        }
        if run.count > 2, let first = run.first, let last = run.last,
           points[first].distance(to: points[last]) < 1e-9 {
            run.removeLast()
        }
        var ring = run
        // Clip the ears off a counter-clockwise ring.
        if signedArea(ring.map { points[$0] }) < 0 { ring.reverse() }
        var triangles: [(Int, Int, Int)] = []
        var attempts = 0
        while ring.count > 3, attempts < points.count * points.count {
            var clipped = false
            for position in ring.indices {
                let before = ring[(position + ring.count - 1) % ring.count]
                let here = ring[position]
                let after = ring[(position + 1) % ring.count]
                let a = points[before], b = points[here], c = points[after]
                // A corner that turns outwards, with no other point of the ring inside it, is an ear.
                guard (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x) > 1e-9 else { continue }
                var clear = true
                for other in ring where other != before && other != here && other != after {
                    let p = points[other]
                    let ab = (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
                    let bc = (c.x - b.x) * (p.y - b.y) - (c.y - b.y) * (p.x - b.x)
                    let ca = (a.x - c.x) * (p.y - c.y) - (a.y - c.y) * (p.x - c.x)
                    if ab >= -1e-9 && bc >= -1e-9 && ca >= -1e-9 { clear = false; break }
                }
                guard clear else { continue }
                triangles.append((before, here, after))
                ring.remove(at: position)
                clipped = true
                break
            }
            attempts += 1
            if !clipped { break }
        }
        if ring.count == 3 { triangles.append((ring[0], ring[1], ring[2])) }
        return triangles
    }

    /// A solid laid on the table from a run of points taken at the height of its top, each with the
    /// direction its side is set back in and how far.
    ///
    /// The top of the solid follows the points and stands **square** down to `leanFrom`; below that
    /// the sides lean, their feet following the points carried along those back directions. So one
    /// part of an outline can lean while another stands square to the cloth — which is how a jaw's
    /// round runs into the cushion's face — and a face can stand square above its own undercut, which
    /// is what the band of cushion on top of the nose is.
    ///
    /// `closes` says whether the run goes right round the solid. The pieces of the wood do; a jaw's
    /// side does not — it stops against the cushion it was cut from — so that one is closed across
    /// with one more face rather than left open.
    /// One point of a solid's outline, taken at the top of the solid: where it stands in the plan,
    /// which way its side is set back in as the solid comes down and how far, and the **radius** the
    /// edge along the top of that side is rounded over with — `0` for a square edge.
    ///
    /// A point whose edge runs on into another solid — the line the wood stops at, where the cushion
    /// stands against it, or a cut between two pieces of the wood — is left square (`round: 0`): a
    /// round there would cut a groove along a join that is meant to be one line. The radius is a
    /// property of the point, not of the solid, so the wood's own wide outer round and the cushion's
    /// narrow one can run into one another on the same piece.
    struct Edge {
        var point: Vec2
        var back: Vec2 = .zero
        var setback: Double = 0
        var round: Double = Furniture.edgeRound
    }

    /// A solid laid on the table from a run of points taken at the height of its top.
    ///
    /// Its section is swept from the top down through a run of levels: the **round-over** at the top,
    /// which carries the square side over into the flat top in a quarter circle; the band standing
    /// square below it; the **fillet** at the nose, carrying that square side into the lean, tangent
    /// to both so the wall has no crease left in it; and the lean itself, down to the foot. So a
    /// cushion's face is rounded where the cloth meets it, rounded at the nose, and square between —
    /// and the wood's edges are rounded over the same way.
    ///
    /// The round-over's radius belongs to the **point of the outline**, not to the solid, so one piece
    /// can carry a wide round on one of its edges and a narrow one on another: the wood's outer rim is
    /// a 15 mm bull nose while its edge beside a pocket's cut keeps the cushion's own 3 mm, and the two
    /// run into one another on the same piece. The levels have to reach down through the widest radius
    /// the piece carries, and each edge is brought in at each height by its own radius — a quarter
    /// circle for a square edge, and for an edge that is leaning as well, the same round taken off a
    /// line the lean has already carried down.
    ///
    /// `closes` says whether the run goes right round the solid. The pieces of the wood do; a jaw's
    /// side does not — it stops against the cushion it was cut from — so that one is closed across
    /// with one more face rather than left open.
    private static func leaningSolid(_ outline: [Edge],
                                     top: Double,
                                     leanFrom: Double,
                                     bottom: Double,
                                     closes: Bool,
                                     material: SCNMaterial) -> SCNNode {
        guard outline.count > 2 else { return SCNNode() }
        let count = outline.count
        let steps = closes ? count : count - 1
        // The last step of an outline that does not close is the face cut across the end of it — a
        // jaw's base — and it is not part of the surface being shaded, so it is left out of the run of
        // normals: taken in, it turns the shading of the round by its own whole angle at the last
        // vertex.
        let smoothed = closes ? steps : steps - 1
        func step(_ position: Int) -> (a: Int, b: Int) {
            (position % count, (position + 1) % count)
        }
        /// Which way the outside of a wall faces, in the plan: the outline of a solid runs
        /// counter-clockwise about the middle of the table for the wood and for a jaw at a corner, and
        /// the other way for the two pockets at the ends of the table, so it is the winding that says
        /// which hand the outside is on.
        let counterClockwise = signedArea(outline.map(\.point)) >= 0
        func outwards(_ from: Vec2, _ to: Vec2) -> Vec2 {
            let along = to - from
            return (counterClockwise ? Vec2(along.y, -along.x) : Vec2(-along.y, along.x)).normalized
        }
        /// One outward direction for each point of the outline, between the steps either side of it:
        /// the round-over comes in along it, and the wall is shaded by it.
        let planNormals: [Vec2] = (0..<count).map { position in
            let before = outwards(outline[(position + count - 1) % count].point, outline[position].point)
            let after = outwards(outline[position].point, outline[(position + 1) % count].point)
            let average = before + after
            return average.length > 1e-9 ? average.normalized : after
        }

        // MARK: The levels the section is swept through

        /// The round-over each **edge** of the outline carries: the radius it is taken off with along
        /// the top. An edge is rounded over when **both** of the points at its ends are, and then with
        /// the smaller of the two radii that meet there; a join — the line the wood stops at, or the end
        /// of a cushion where a jaw runs on from it — is square at both ends, so the edge that runs into
        /// it is square too, and the top surface is not pulled away from the join.
        let roundings: [Double] = (0..<count).map { position in
            let (a, b) = step(position)
            guard outline[a].round > 0, outline[b].round > 0 else { return 0 }
            return min(outline[a].round, outline[b].round)
        }
        /// The widest round-over the section carries anywhere: the quarter circle the levels have to
        /// reach right down through, so the roundest edge a piece carries is drawn as round as it is.
        let widestRound = roundings.max() ?? 0

        // The section's own shape is the band over the nose and the lean below it, and the nose fillet
        // is where the two turn into one another. The lean is laid down as knots first — 0 on the square
        // band, turning round the fillet, 1 at the foot — and the round-over then sampled over the same
        // heights, so a level below the fillet, which a round wider than the cushion's own cap reaches,
        // still reads its lean off the same curve rather than falling off the end of it.
        let noseRound = Furniture.noseRound
        let leanSlope = Furniture.undercut / (Furniture.noseHeight + Furniture.clothThickness)
        let noseAngle = atan(leanSlope)                              // the lean's angle off the square side
        let noseCentre = leanFrom + noseRound * ((leanSlope * leanSlope + 1).squareRoot() - 1) / leanSlope
        var knots: [(height: Double, lean: Double)] = [
            // The band standing square between the round-over and the nose, up to the fillet's tangent.
            (noseCentre, 0),
        ]
        // The fillet, carrying the square side into the lean: tangent to both, so no crease is left.
        for sample in 0...3 {
            let turned = noseAngle * Double(sample) / 3
            knots.append((noseCentre - noseRound * sin(turned),
                          noseRound * (1 - cos(turned)) / Furniture.undercut))
        }
        // And the lean itself, down to the foot.
        knots.append((bottom, 1))
        /// How much of its own set-back the section carries at a height: 0 above the nose, 1 below the
        /// fillet, and the fillet's own curve between — read off the knots, so a level anywhere in the
        /// section finds the lean the surface has there.
        func lean(at height: Double) -> Double {
            if height >= knots[0].height { return knots[0].lean }
            if height <= knots[knots.count - 1].height { return knots[knots.count - 1].lean }
            for index in 1..<knots.count {
                let high = knots[index - 1], low = knots[index]
                guard height <= high.height, height >= low.height else { continue }
                let span = high.height - low.height
                guard span > 1e-12 else { return low.lean }
                return low.lean + (high.lean - low.lean) * (height - low.height) / span
            }
            return 0
        }

        /// One level of the sweep: how high it stands, and how much of its own set-back the section
        /// carries there. The round-over is read off the height **per edge** rather than carried by the
        /// level, so a wide edge and a narrow one are swept through the same run of rings and each is
        /// brought in by its own radius.
        var levelHeights: [Double] = knots.map(\.height)
        // The round-over: a quarter circle, from the square side up to the top, where the surface has
        // come in by the whole radius and turned right over on to the flat. Sampled through the widest
        // radius the section carries, so the levels cover the roundest edge's own fall.
        let roundSteps = max(4, Int((widestRound / 1.5).rounded(.up)))
        if widestRound > 0 {
            for sample in 0...roundSteps {
                let turned = Double(sample) / Double(roundSteps) * Double.pi / 2
                levelHeights.append(top - widestRound * (1 - sin(turned)))
            }
        }
        // Taken from the top down, with a height that repeats (the fillet's own start, or a round-over
        // sample landing on a knot) swept once rather than twice.
        var levels: [(height: Double, lean: Double)] = []
        for height in levelHeights.sorted(by: >)
        where levels.last.map({ abs($0.height - height) > 1e-9 }) ?? true {
            levels.append((height, lean(at: height)))
        }

        // MARK: The mesh

        var vertices: [simd_float3] = []
        var normals: [simd_float3] = []
        var texcoords: [CGPoint] = []
        var indices: [Int32] = []
        func vertex(_ position: simd_float3, _ normal: simd_float3, _ uv: CGPoint) -> Int32 {
            vertices.append(position); normals.append(normal); texcoords.append(uv)
            return Int32(vertices.count - 1)
        }
        /// A point of the table at a height, with the texture coordinate the wood's grain is read at:
        /// the plan position across the whole table's own box, so that the grain runs on unbroken from
        /// one piece of the rail to the next.
        func at(_ p: Vec2, _ height: Double) -> (position: simd_float3, uv: CGPoint) {
            (point(p, height: height),
             CGPoint(x: CGFloat((p.x + outerX) / (Table.length + 2 * outerX)),
                     y: CGFloat((p.y + outerY) / (Table.width + 2 * outerY))))
        }
        /// How far the round-over has brought an edge in at a height: none above the round, the whole
        /// radius once the quarter circle has turned right over on to the flat, and the arc between.
        func broughtIn(_ edge: Int, at height: Double) -> Double {
            let radius = roundings[edge]
            guard radius > 0 else { return 0 }
            // The quarter circle is struck from the centre a radius below the top, so the surface has
            // come in by the whole radius where it meets the square side and by nothing at the top.
            let rise = height - (top - radius)
            guard rise > 0 else { return 0 }
            guard rise < radius else { return radius }
            return radius - (radius * radius - rise * rise).squareRoot()
        }
        /// Where a point of the outline stands with the sweep's own lean carried along its set-back
        /// direction, before the round-over is taken off it.
        func leaned(_ index: Int, _ lean: Double) -> Vec2 {
            let here = outline[index]
            return here.point + here.back * (here.setback * lean)
        }
        /// One edge of the outline at a level: the line its two ends are carried to, brought in by the
        /// round-over it carries there.
        func edgeLine(_ edge: Int, _ lean: Double, _ amount: Double) -> (through: Vec2, along: Vec2) {
            let (a, b) = step(edge)
            let from = leaned(a, lean), to = leaned(b, lean)
            let inward = Vec2(-outwards(from, to).x, -outwards(from, to).y)
            return (from + inward * amount, (to - from).normalized)
        }
        /// Where two lines cross.
        func crossing(_ one: (through: Vec2, along: Vec2), _ two: (through: Vec2, along: Vec2)) -> Vec2 {
            let across = one.along.x * two.along.y - one.along.y * two.along.x
            guard abs(across) > 1e-9 else { return one.through }
            let between = two.through - one.through
            return one.through + one.along * ((between.x * two.along.y - between.y * two.along.x) / across)
        }
        /// Where a point of the outline stands at one level of the sweep: carried along its own
        /// set-back direction by the lean, and brought in by the round-over — the cross of the offset
        /// lines of the two edges that meet there, so a square edge keeps its own line and the round
        /// slides along it rather than pulling the surface away from it.
        func plan(_ index: Int, _ level: (height: Double, lean: Double)) -> Vec2 {
            // The edge before this point and the edge after it, round the loop: on an outline that does
            // not close, `count - 1` is the edge that closes it — the face across the end — which is an
            // edge of the top face just as much as any other.
            let before = (index + count - 1) % count, after = index % count
            let beforeIn = broughtIn(before, at: level.height)
            let afterIn = broughtIn(after, at: level.height)
            // A step of no length has no direction of its own, so the cross of its line with another
            // comes out anywhere: where one of the two is like that the point is left where the lean
            // put it rather than flung off along the piece.
            func hasLength(_ edge: Int) -> Bool {
                let (a, b) = step(edge)
                return outline[a].point.distance(to: outline[b].point) > 1e-6
            }
            guard beforeIn > 0 || afterIn > 0 else { return leaned(index, level.lean) }
            guard hasLength(before), hasLength(after) else { return leaned(index, level.lean) }
            return crossing(edgeLine(before, level.lean, beforeIn),
                            edgeLine(after, level.lean, afterIn))
        }
        // One normal for every step of every band of the wall.
        var bandNormals: [[simd_float3]] = []
        for level in 1..<levels.count {
            let above = levels[level - 1], below = levels[level]
            bandNormals.append((0..<smoothed).map { position in
                let (a, b) = step(position)
                let along = at(plan(b, above), above.height).position - at(plan(a, above), above.height).position
                let descent = at(plan(a, below), below.height).position - at(plan(a, above), above.height).position
                let out = direction(planNormals[a])
                let area = simd_cross(along, descent)
                let size = simd_length(area)
                guard size > 1e-12 else { return out }
                let normal = area / size
                return simd_dot(normal, out) < 0 ? -normal : normal
            })
        }
        /// One vertex for every point of the outline at every level, its normal the average of the
        /// steps that run into it — along the outline and up and down the section — so the wall is
        /// shaded as the surface it is.
        ///
        /// A step has as much say in that average as it is **long**: a long straight edge meeting a
        /// short one at a corner keeps its own normal, rather than being pulled round the corner by
        /// it. That is what keeps the join between a run of cushion and its jaw seamless — the run's
        /// face meets the square end the jaw was cut from at a right angle, and weighing the two by
        /// length leaves the face's own normal on the join, which is the normal the jaw beside it is
        /// shaded with. A curve, whose steps are all much the same length, is smoothed as before.
        let stepWeights: [Double] = (0..<smoothed).map { position in
            let (a, b) = step(position)
            return max(outline[a].point.distance(to: outline[b].point), 1e-6)
        }
        func ringNormals(_ level: Int) -> [simd_float3] {
            /// Which step of a band a point of the outline takes its normal from, wrapping round an
            /// outline that closes and holding at the ends of one that does not.
            func place(_ index: Int, in band: Int) -> Int {
                let held = bandNormals[band].count
                if closes { return ((index % held) + held) % held }
                return min(max(index, 0), held - 1)
            }
            let bands = [level - 1, level].filter { $0 >= 0 && $0 < bandNormals.count }
            return (0..<count).map { position in
                // A band whose step is a **join** — a face left square because another solid stands
                // against it, or because a neighbouring piece of the rail shares the cut — is not part
                // of the surface this piece shows. Its line is where the surface runs on into the next
                // piece, so where the surface beside it carries on the join is left out of the average:
                // taken in, a long buried cut drags the reflection at the rim of the wood round with it,
                // and the two pieces beside the cut come out shaded differently.
                var hasASurface = false
                for band in bands {
                    for index in [position - 1, position] where roundings[place(index, in: band)] > 0 {
                        hasASurface = true
                    }
                }
                var average = simd_float3.zero
                for band in bands {
                    for index in [position - 1, position] {
                        let held = place(index, in: band)
                        if hasASurface, roundings[held] <= 0 { continue }
                        average += bandNormals[band][held] * Float(stepWeights[held])
                    }
                }
                return simd_length(average) > 1e-9 ? simd_normalize(average) : direction(planNormals[position])
            }
        }

        var ringIndices: [[Int32]] = []
        for level in levels.indices {
            let normalsHere = ringNormals(level)
            ringIndices.append((0..<count).map { position in
                vertex(at(plan(position, levels[level]), levels[level].height).position,
                       normalsHere[position],
                       at(plan(position, levels[level]), levels[level].height).uv)
            })
        }
        /// One triangle between four corners of the wall, wound to face the way `towards` points.
        func face(_ a: Int32, _ b: Int32, _ c: Int32, _ d: Int32, towards outward: simd_float3) {
            for (first, second, third) in [(a, b, c), (a, c, d)] {
                let area = simd_cross(vertices[Int(second)] - vertices[Int(first)],
                                      vertices[Int(third)] - vertices[Int(first)])
                indices += simd_dot(area, outward) >= 0 ? [first, second, third] : [first, third, second]
            }
        }
        for level in 1..<levels.count {
            for position in 0..<steps {
                let (a, b) = step(position)
                // A run that does not close has no normal of its own for the last step — that step is
                // the face cut across the end — so the one before it faces the quad instead.
                let outward = bandNormals[level - 1][closes ? position : min(smoothed - 1, position)]
                face(ringIndices[level - 1][a], ringIndices[level - 1][b],
                     ringIndices[level][b], ringIndices[level][a], towards: outward)
            }
        }
        if !closes {
            // The last step, from the base of the cushion back up to its face: the end of the cushion,
            // cut off square, swept through the same levels.
            let base = count - 1, atTheFace = 0
            let cut = direction((outline[base].back + outline[atTheFace].back).normalized)
            for level in 1..<levels.count {
                face(ringIndices[level - 1][base], ringIndices[level - 1][atTheFace],
                     ringIndices[level][atTheFace], ringIndices[level][base], towards: cut)
            }
        }
        // The top of the solid and the underside of its foot: the outline's own triangles at those
        // levels, taken the way that faces up and down.
        func flatFace(_ level: Int, towards outward: simd_float3) {
            let here = (0..<count).map { plan($0, levels[level]) }
            for (a, b, c) in Table3D.triangulate(here) {
                let corners = [a, b, c].map { index in
                    at(here[index], levels[level].height)
                }
                let area = simd_cross(corners[1].position - corners[0].position,
                                      corners[2].position - corners[0].position)
                let size = simd_length(area)
                guard size > 1e-12 else { continue }
                var normal = area / size
                var second = corners[1], third = corners[2]
                if simd_dot(normal, outward) < 0 { normal = -normal; second = corners[2]; third = corners[1] }
                indices += [vertex(corners[0].position, normal, corners[0].uv),
                            vertex(second.position, normal, second.uv),
                            vertex(third.position, normal, third.uv)]
            }
        }
        flatFace(0, towards: simd_float3(0, 1, 0))
        flatFace(levels.count - 1, towards: simd_float3(0, -1, 0))

        let geometry = SCNGeometry(
            sources: [SCNGeometrySource(vertices: vertices.map { SCNVector3($0) }),
                      SCNGeometrySource(normals: normals.map { SCNVector3($0) }),
                      SCNGeometrySource(textureCoordinates: texcoords)],
            elements: [SCNGeometryElement(indices: indices, primitiveType: .triangles)]
        )
        let surface = (material.copy() as? SCNMaterial) ?? material
        surface.isDoubleSided = true
        geometry.firstMaterial = surface
        return SCNNode(geometry: geometry)
    }


    /// Whether a point of the table plane falls inside a flat path. The snapshot harness uses this to
    /// check the shape of the table without having to look at it.
    static func contains(_ path: NSBezierPath, _ point: Vec2) -> Bool {
        path.contains(plan(point))
    }

    /// What the cloth and the balls are made of, read back off the built scene: the figures the
    /// renderer is really carrying, rather than the ones the code meant to set.
    func materialReport() -> [String] {
        var seen = Set<String>()
        var lines: [String] = []
        func say(_ material: SCNMaterial) {
            guard let name = material.name, !seen.contains(name) else { return }
            seen.insert(name)
            func value(_ property: SCNMaterialProperty) -> String {
                if let number = property.contents as? NSNumber { return String(format: "%.2f", number.doubleValue) }
                return property.contents == nil ? "-" : "mapped"
            }
            lines.append(String(format: "  %-7@ roughness %@, metalness %@, clear coat %@%@%@",
                                name as NSString, value(material.roughness) as NSString,
                                value(material.metalness) as NSString, value(material.clearCoat) as NSString,
                                material.diffuse.contents is NSImage ? ", its own texture" : "",
                                material.normal.contents is NSImage ? ", weave relief" : "",
                                (material.shaderModifiers ?? [:]).isEmpty ? "" : ", nap"))
        }
        func visit(_ node: SCNNode) {
            if let material = node.geometry?.firstMaterial { say(material) }
            for child in node.childNodes { visit(child) }
        }
        visit(scene.rootNode)
        return lines.sorted()
    }

    /// What the jaw solids came out as: how many triangles each is drawn with, and the heights its
    /// side runs between.
    func jawSolids() -> [(pocket: PocketID, triangles: Int, from: Double, to: Double)] {
        jawNodes.map { pocket, _, node in
            let box = node.boundingBox
            return (pocket, node.geometry?.elements.first?.primitiveCount ?? 0,
                    Double(box.min.y) * 1000, Double(box.max.y) * 1000)
        }
    }

    /// The joins between the six pieces of the wooden rail, read back off the solids themselves: how
    /// far apart the two pieces' shading normals come out at the place they meet on the table's own
    /// outer edge.
    ///
    /// The pieces meet flush — the geometry probe checks that the wood either side of every cut is
    /// wood — but each is shaded from its own vertex normals, so a join where those disagree reads as a
    /// step in the reflection even though the surface is unbroken. The figure is the widest disagreement
    /// at the join, taken over the whole of the outer edge's round-over.
    func railSeamShading() -> [(join: Int, degrees: Double, plan: Vec2)] {
        let pieces = Table3D.railPieces(Table3D.pocketCuts())
        func read(_ source: SCNGeometrySource) -> [simd_float3] {
            var held: [simd_float3] = []
            source.data.withUnsafeBytes { raw in
                for index in 0..<source.vectorCount {
                    let base = source.dataOffset + index * source.dataStride
                    held.append(simd_float3(raw.load(fromByteOffset: base, as: Float.self),
                                            raw.load(fromByteOffset: base + 4, as: Float.self),
                                            raw.load(fromByteOffset: base + 8, as: Float.self)))
                }
            }
            return held
        }
        var joins: [(join: Int, degrees: Double, plan: Vec2)] = []
        for k in pieces.indices {
            let next = (k + 1) % pieces.count
            guard k < railNodes.count, next < railNodes.count,
                  let geometryA = railNodes[k].node.geometry,
                  let geometryB = railNodes[next].node.geometry,
                  let va = geometryA.sources(for: .vertex).first,
                  let na = geometryA.sources(for: .normal).first,
                  let vb = geometryB.sources(for: .vertex).first,
                  let nb = geometryB.sources(for: .normal).first else { continue }
            let countA = pieces[k].count, countB = pieces[next].count
            // The place the two pieces meet away from the table's middle: the end of the first piece's
            // own cut, which is the last point of the second piece's run.
            let joinPlan = pieces[next][countB - 1].point
            guard let indexA = pieces[k].firstIndex(where: { $0.point.distance(to: joinPlan) < 1e-6 }) else { continue }
            let verticesA = read(va), normalsA = read(na), verticesB = read(vb), normalsB = read(nb)
            let rings = min(verticesA.count / countA, verticesB.count / countB)
            var widest = 0.0
            for ring in 0..<rings {
                let a = normalsA[ring * countA + indexA]
                let b = normalsB[ring * countB + (countB - 1)]
                // The flat top and underside of a piece are laid down after the rings of the wall, out of
                // step with them: their normals stand square up and down, so they are left out here.
                guard abs(a.y) < 0.999, abs(b.y) < 0.999 else { continue }
                let dot = max(-1, min(1, simd_dot(a, b)))
                widest = max(widest, Double(acos(dot)) * 180 / .pi)
            }
            joins.append((k, widest, joinPlan))
        }
        return joins
    }

    /// The cloth's own texture coordinates, read back off the built scene: how many the bed carries and
    /// the box they run over.
    ///
    /// A surface whose coordinates all sit at one point takes a single texel of the cloth's maps and
    /// comes out a flat colour, however good the maps are — so a bed is not dressed until its
    /// coordinates are known, and the harness reads them rather than trusting the material.
    func clothTextureCoordinates() -> (count: Int, u: ClosedRange<Double>, v: ClosedRange<Double>)? {
        var found: SCNGeometry?
        func walk(_ node: SCNNode) {
            if found == nil, node.geometry?.firstMaterial?.name == "cloth" { found = node.geometry }
            for child in node.childNodes { walk(child) }
        }
        walk(scene.rootNode)
        guard let geometry = found, let source = geometry.sources(for: .texcoord).first else { return nil }
        var us: [Double] = [], vs: [Double] = []
        source.data.withUnsafeBytes { raw in
            let width = source.bytesPerComponent
            for i in 0..<source.vectorCount where width == 4 {
                let base = source.dataOffset + i * source.dataStride
                guard base + 2 * width <= raw.count else { break }
                us.append(Double(raw.loadUnaligned(fromByteOffset: base, as: Float.self)))
                vs.append(Double(raw.loadUnaligned(fromByteOffset: base + width, as: Float.self)))
            }
        }
        guard let uLow = us.min(), let uHigh = us.max(),
              let vLow = vs.min(), let vHigh = vs.max() else { return nil }
        return (us.count, uLow...uHigh, vLow...vHigh)
    }

    /// What the cushions and the jaws are dressed in, read back off the built scene: whether the cloth
    /// covering is the **bed's own**, which is a cloth only if its colour, its relief and its nap are
    /// all the bed's. A green mixed by eye to sit near the cloth is exactly what a cushion covering is
    /// not, so the harness asks the material rather than the picture.
    func cushionCovering() -> (named: String, ownTexture: Bool, relief: Bool, nap: Bool)? {
        var found: SCNMaterial?
        func walk(_ node: SCNNode) {
            if found == nil, let material = node.geometry?.firstMaterial,
               material.name?.hasPrefix("cloth (") == true { found = material }
            for child in node.childNodes { walk(child) }
        }
        walk(scene.rootNode)
        guard let material = found, let name = material.name else { return nil }
        return (name,
                material.diffuse.contents is NSImage,
                material.normal.contents is NSImage,
                !(material.shaderModifiers ?? [:]).isEmpty)
    }

    /// Whether the round runs the whole way round the wood's outer edge, read back off the built mesh:
    /// every point of every piece's outer edge, at the top of its section, brought in by the round's
    /// own radius. A point left square — which is what a step of no length in the outline used to come
    /// out as — would be back out at the table's own edge and read nought.
    func railOuterEdgeCoverage() -> (pieces: Int, points: Int, smallest: Double)? {
        let pieces = Table3D.railPieces(Table3D.pocketCuts())
        var points = 0
        var smallest = Double.infinity
        for (index, outline) in pieces.enumerated() {
            guard index < railNodes.count,
                  let source = railNodes[index].node.geometry?.sources(for: .vertex).first,
                  source.usesFloatComponents, source.componentsPerVector == 3 else { continue }
            var held: [simd_float3] = []
            source.data.withUnsafeBytes { raw in
                for at in 0..<min(outline.count, source.vectorCount) {
                    let base = source.dataOffset + at * source.dataStride
                    held.append(simd_float3(raw.load(fromByteOffset: base, as: Float.self),
                                            raw.load(fromByteOffset: base + 4, as: Float.self),
                                            raw.load(fromByteOffset: base + 8, as: Float.self)))
                }
            }
            guard held.count == outline.count else { continue }
            for at in outline.indices where outline[at].round >= Furniture.railEdgeRound - 0.5 {
                points += 1
                smallest = min(smallest, outline[at].point.distance(to: Table3D.tablePoint(held[at])))
            }
        }
        guard points > 0, smallest.isFinite else { return nil }
        return (pieces.count, points, smallest)
    }

    /// What the round on the **outer edge** of the wood came out as, read back off the built mesh.
    ///
    /// The piece over the bottom middle pocket is the one to read: its outer side is the bottom run of
    /// the table, straight the whole way and standing at `y = -(cushionDepth + railDepth)`, so a
    /// vertex's height and how far it has come in from that line are the whole of the round's section.
    /// Three figures come back: the radius the edge is taken off with, how far the surface comes in at
    /// the top, and the height at which it is back out at the table's own edge.
    func railEdgeProfile() -> (radius: Double, inAtTheTop: Double, backToTheEdge: Double)? {
        let pieces = Table3D.railPieces(Table3D.pocketCuts())
        guard let index = railNodes.firstIndex(where: { $0.pocket == .bottomMiddle }),
              let geometry = railNodes[index].node.geometry,
              let source = geometry.sources(for: .vertex).first,
              let normalsOff = geometry.sources(for: .normal).first,
              source.usesFloatComponents, source.componentsPerVector == 3,
              normalsOff.usesFloatComponents, normalsOff.componentsPerVector == 3,
              index < pieces.count else { return nil }
        let outline = pieces[index]
        // The last two points of the piece are the two ends of the run along the table's own bottom
        // edge — the straight stretch between the two cuts — and the vertices are laid down one ring of
        // `outline.count` to a level, so those two of every ring are the outer edge's own section.
        // The flat top and underside of the piece are laid down after the rings, out of step with them:
        // their normals stand square up and down, so they are told off from the wall's own and left out.
        let onTheOuterEdge = Set([outline.count - 2, outline.count - 1])
        let theEdge = -(Furniture.cushionDepth + Furniture.railDepth)
        func read(_ source: SCNGeometrySource) -> [simd_float3] {
            var held: [simd_float3] = []
            source.data.withUnsafeBytes { raw in
                for index in 0..<source.vectorCount {
                    let base = source.dataOffset + index * source.dataStride
                    held.append(simd_float3(raw.load(fromByteOffset: base, as: Float.self),
                                            raw.load(fromByteOffset: base + 4, as: Float.self),
                                            raw.load(fromByteOffset: base + 8, as: Float.self)))
                }
            }
            return held
        }
        let vertices = read(source), normals = read(normalsOff)
        guard vertices.count == normals.count else { return nil }
        var section: [(inBy: Double, height: Double)] = []
        for index in vertices.indices
        where onTheOuterEdge.contains(index % outline.count) && abs(Double(normals[index].y)) < 1 - 1e-4 {
            section.append((Table3D.tablePoint(vertices[index]).y - theEdge,
                            Double(vertices[index].y) * 1000))
        }
        guard let top = section.max(by: { $0.height < $1.height }) else { return nil }
        // The square side under the round: the highest place the surface is still out at the edge.
        // The vertices are read back as floats, so "out at the edge" is judged to a hundredth of a
        // millimetre rather than exactly.
        let backToTheEdge = section.filter { $0.inBy < 0.01 }.map(\.height).max() ?? 0
        // The radius, off the quarter circle: struck from a centre a radius below the top and out at
        // the edge, so each point of the round gives `r = (inBy² + (height - backToTheEdge)²) / 2·inBy`.
        let heights = section.filter { $0.inBy > 0.5 && $0.inBy < Furniture.railEdgeRound - 0.5 }
        let radius = heights.isEmpty ? 0
            : heights.map { point in
                let drop = point.height - backToTheEdge
                return (point.inBy * point.inBy + drop * drop) / (2 * point.inBy)
            }.reduce(0, +) / Double(heights.count)
        return (radius, top.inBy, backToTheEdge)
    }

    /// How smoothly the side of each jaw is shaded: the widest angle between the normals at two
    /// neighbouring points of it, and how many of them the side is shaded from.
    func jawShading() -> [(pocket: PocketID, steps: Int, widestTurn: Double, widestAt: Int)] {
        jawNodes.map { pocket, jaw, node in
            let outline = Table3D.jawSide(jaw)
            let steps = outline.count
            guard let source = node.geometry?.sources(for: .normal).first,
                  let held = node.geometry?.sources(for: .vertex).first,
                  source.usesFloatComponents, source.componentsPerVector == 3,
                  held.usesFloatComponents, held.componentsPerVector == 3 else { return (pocket, 0, 0, 0) }
            var normals: [simd_float3] = [], heights: [Double] = []
            func read(_ source: SCNGeometrySource) {
                source.data.withUnsafeBytes { raw in
                    for index in 0..<source.vectorCount {
                        let base = source.dataOffset + index * source.dataStride
                        let three = simd_float3(raw.load(fromByteOffset: base, as: Float.self),
                                                raw.load(fromByteOffset: base + 4, as: Float.self),
                                                raw.load(fromByteOffset: base + 8, as: Float.self))
                        if source.semantic == .normal { normals.append(three) } else { heights.append(Double(three.y) * 1000) }
                    }
                }
            }
            read(source); read(held)
            // The wall's vertices are laid down a level at a time, `steps` of them to a level, from the
            // top of the solid down: the leaning band the ball is played against is the last of them,
            // at the lowest height the solid stands at.
            let levels = Set(heights.map { ($0 * 100).rounded() }).count
            let first = (levels - 1) * steps
            guard first >= 0, first + steps <= normals.count else { return (pocket, steps, 0, 0) }
            var widest = 0.0
            var widestAt = 0
            for step in 0..<(steps - 1) {
                let here = normals[first + step], next = normals[first + step + 1]
                let angle = Double(acos(max(-1, min(1, simd_dot(here, next))))) * 180 / .pi
                if angle > widest { widest = angle; widestAt = step }
            }
            return (pocket, steps, widest, widestAt)
        }
    }

    /// The join between a run of straight cushion and the jaw it was cut from, read back off the
    /// solids themselves: how far apart the two sides' shading normals come out there, in degrees.
    ///
    /// The two solids meet flush — `Snapshot` checks the tops come out level on both sides of the
    /// seam — but each is shaded from its own vertex normals, so a join where those normals disagree
    /// reads as a step in the reflection even though the surface is unbroken. The normals compared
    /// are the run's own last point and the jaw's first, at the foot of the wall: the leaning face
    /// the ball is played against.
    func seamShading() -> [(pocket: PocketID, degrees: Double)] {
        /// The normals of a solid's wall at its own foot, with where each stands in plan. The foot is
        /// the lowest level of the sweep, and only the wall is kept off it: the vertices of the flat
        /// faces above and below stand at the same plan points but point straight up and down, so the
        /// wall's own are told from them by their normals being neither.
        func foot(_ node: SCNNode) -> [(normal: simd_float3, plan: Vec2)] {
            guard let normalSource = node.geometry?.sources(for: .normal).first,
                  let vertexSource = node.geometry?.sources(for: .vertex).first,
                  normalSource.usesFloatComponents, normalSource.componentsPerVector == 3,
                  vertexSource.usesFloatComponents, vertexSource.componentsPerVector == 3 else { return [] }
            func read(_ source: SCNGeometrySource) -> [simd_float3] {
                var out: [simd_float3] = []
                source.data.withUnsafeBytes { raw in
                    for index in 0..<source.vectorCount {
                        let base = source.dataOffset + index * source.dataStride
                        out.append(simd_float3(raw.load(fromByteOffset: base, as: Float.self),
                                               raw.load(fromByteOffset: base + 4, as: Float.self),
                                               raw.load(fromByteOffset: base + 8, as: Float.self)))
                    }
                }
                return out
            }
            let normals = read(normalSource), vertices = read(vertexSource)
            guard normals.count == vertices.count, !vertices.isEmpty else { return [] }
            let floor = vertices.map { Double($0.y) }.min() ?? 0
            return vertices.indices.compactMap { index in
                let at = vertices[index]
                guard abs(Double(at.y) - floor) < 1e-6, abs(Double(normals[index].y)) < 0.8 else { return nil }
                // The scene's own axes, in millimetres: the same frame the joint is taken in below.
                return (normals[index], Vec2(Double(at.x) * 1000, Double(at.z) * 1000))
            }
        }
        let runs = runNodes.map { foot($0) }
        return jawNodes.map { pocket, jaw, node in
            // The join is where the jaw's round leaves the cushion's face, not the tip the mouth is
            // measured between: the round is cut back from that tip by its own tangent.
            let seam = Table3D.scenePoint(jaw.atTheFace)
            let joint = Vec2(Double(seam.x) * 1000, Double(seam.z) * 1000)
            /// The wall point of a set nearest the joint, and how far off it is.
            func nearest(_ points: [(normal: simd_float3, plan: Vec2)]) -> (normal: simd_float3, far: Double)? {
                points.map { ($0.normal, $0.plan.distance(to: joint)) }
                      .min { $0.1 < $1.1 }
                      .map { (normal: $0.0, far: $0.1) }
            }
            guard let jawSide = nearest(foot(node)),
                  let runSide = runs.compactMap({ nearest($0) }).min(by: { $0.far < $1.far }) else {
                return (pocket, -1)
            }
            let dot = max(-1, min(1, simd_dot(runSide.normal, jawSide.normal)))
            return (pocket, Double(acos(dot)) * 180 / .pi)
        }
    }

    /// How the curve of each jaw's foot runs: the foot is where the side of the jaw meets the cloth,
    /// and it should be **convex**, curving outward with no dip back into the jaw. The measure is how
    /// far it comes back in, in millimetres.
    func jawFootCurves() -> [(pocket: PocketID, outwardTurns: Int, deepestIn: Double)] {
        jawNodes.map { pocket, jaw, _ in
            let side = Table3D.jawSide(jaw)
            let feet = side.map { $0.point + $0.back * $0.setback }
            func turn(_ a: Vec2, _ b: Vec2, _ c: Vec2) -> Double {
                let along = b - a, next = c - b
                guard along.length > 1e-9, next.length > 1e-9 else { return 0 }
                return atan2(along.x * next.y - along.y * next.x, along.dot(next)) * 180 / .pi
            }
            var outwardIsPositive = true
            for index in 1..<(side.count - 1) {
                let path = turn(side[index - 1].point, side[index].point, side[index + 1].point)
                if abs(path) > 1e-6 { outwardIsPositive = path > 0; break }
            }
            var outwardTurns = 0, deepestIn = 0.0
            for index in 1..<(feet.count - 2) {
                let chord = feet[index + 1] - feet[index - 1]
                let toThePoint = feet[index] - feet[index - 1]
                guard chord.length > 1e-9 else { continue }
                let sag = (chord.x * toThePoint.y - chord.y * toThePoint.x) / chord.length
                let outwards = outwardIsPositive ? -sag : sag
                if outwards > 1e-6 { outwardTurns += 1 }
                if outwards < -1e-6 { deepestIn = max(deepestIn, -outwards) }
            }
            return (pocket, outwardTurns, deepestIn)
        }
    }

    /// The slate: the whole footprint, with each pocket's hole cut through it.
    static func slatePath(_ cuts: [PocketID: PocketCut]) -> NSBezierPath {
        let path = outerPath(inset: 2)
        for pocket in PocketID.allCases { addHole(path, cuts[pocket]!) }
        return path
    }

    /// A pocket's hole, wound the other way so it is cut out of the shape around it.
    private static func addHole(_ path: NSBezierPath, _ cut: PocketCut) {
        addLoop(path, PocketCut.circlePoints(centre: cut.holeCentre, radius: cut.holeRadius),
                counterclockwise: false)
    }

    /// The outside edge of the table, counter-clockwise with the corners taken off.
    private static func outerPath(inset: Double) -> NSBezierPath {
        let x0 = -outerX + inset, x1 = Table.length + outerX - inset
        let y0 = -outerY + inset, y1 = Table.width + outerY - inset
        let r = Furniture.railEdge
        let path = NSBezierPath()
        path.move(to: plan(Vec2(x0 + r, y0)))
        path.line(to: plan(Vec2(x1 - r, y0)))
        addArc(path, centre: plan(Vec2(x1 - r, y0 + r)), radius: planRadius(r), from: 270, to: 360)
        path.line(to: plan(Vec2(x1, y1 - r)))
        addArc(path, centre: plan(Vec2(x1 - r, y1 - r)), radius: planRadius(r), from: 0, to: 90)
        path.line(to: plan(Vec2(x0 + r, y1)))
        addArc(path, centre: plan(Vec2(x0 + r, y1 - r)), radius: planRadius(r), from: 90, to: 180)
        path.line(to: plan(Vec2(x0, y0 + r)))
        addArc(path, centre: plan(Vec2(x0 + r, y0 + r)), radius: planRadius(r), from: 180, to: 270)
        path.close()
        return path
    }

    // MARK: - Materials

    /// The **baize**, as it is dressed on to whatever it is covering: the bed the balls run on, or the
    /// cushions they bounce off.
    ///
    /// A table has one cloth on it. The bed and the cushions are the same piece of cloth cut up and
    /// tacked down, so both are dressed from the same maps, with the same nap lying the same way and
    /// the same weave — and they carry their texture coordinates in the same table-wide box, so the
    /// tiling below lands the weave at the same size on the cushions as on the bed and it runs on
    /// across the join at the foot of a cushion instead of starting again there.
    private static func clothMaterial(named name: String = "cloth") -> SCNMaterial {
        let maps = Table3D.clothMaps()
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = maps.colour
        material.roughness.contents = maps.roughness
        material.normal.contents = maps.normal
        material.normal.intensity = 1.0
        material.metalness.contents = 0.0
        for property in [material.diffuse, material.roughness, material.normal] {
            property.wrapS = .repeat
            property.wrapT = .repeat
            // Tiles over the bed: the nap is laid on the cloth at **two tiles to one of the other
            // sections** — half a tile to 150 mm — because a pile is finer than any tile this size can
            // hold, and where the picture runs out the tiling is what makes a fibre smaller. The repeat
            // is 150 mm of cloth, which is nothing to see on a nap: the figure has no shape in it to
            // give the repeat away, only grain.
            property.contentsTransform = SCNMatrix4MakeScale(24, 12, 1)
            property.mipFilter = .linear
        }
        material.name = name
        // The nap: the fibres brushed from the baulk end towards the top, so the cloth reads along
        // them looking up the table and into them looking back down it.
        material.shaderModifiers = [.surface: Table3D.clothNap]
        return material
    }

    /// The nap of the cloth, in the shader.
    ///
    /// Cloth is brushed one way — the fibres lie from the baulk end of the table towards the black — and
    /// a surface like that does not look the same from the two ends of the table. Looking **into** the
    /// fibres, from the black end back down towards the baulk, the cloth comes up a shade **darker**;
    /// looking the other way, down the length of them, a shade **lighter**. That is the one thing a
    /// texture cannot do, because a texture is fixed in the surface's own space and this lives in the
    /// eye's, so the nap is a direction here in the table's space — `+x` being away from the baulk — and
    /// the shading is modulated along it: the roughness is **taken down looking along the fibres** and
    /// left as the maps have it looking into them, which tightens the lamps' reflections one way and
    /// lets them lie flat the other; and the light the fibres carry down their length is added to the
    /// colour looking along them, which is the other half of the same effect. The roughness only ever
    /// comes down, so a wool cloth stays as matte as its maps say and the nap can make it no glossier.
    ///
    /// Which of the two ways that comes out darker is a property of this rig's lights rather than
    /// something the code can argue: so it is **measured**. `--snapshots` reads the same cloth from both
    /// ends of the table and fails if looking into the nap comes out the lighter way round.
    ///
    /// The nap also **shades itself**. Looking into the fibres — from the black end of the table back
    /// down it towards the baulk — is looking at their ends, with the shadows between them, so the cloth
    /// comes up darker that way; looking the other way, down the length of the fibres, it comes up
    /// lighter. A shading model this simple has no pile to shadow itself with, so the fibres' own shade
    /// is carried in the colour, which is the one place it can do the same work.
    private static let clothNap = """
    #pragma body
    float3 nap = normalize((scn_node.normalTransform * float4(1.0, 0.0, 0.0, 0.0)).xyz);
    float facing = dot(normalize(_surface.view), nap);
    _surface.roughness *= mix(0.66, 1.0, smoothstep(-0.55, 0.55, facing));
    _surface.emission += _surface.diffuse * mix(0.30, 0.0, smoothstep(-0.55, 0.55, facing));
    """

    /// A cushion, and the jaws that carry its ends round a pocket: **the bed's own cloth**, tacked on.
    ///
    /// It used to be a colour of its own — a flat green mixed by eye to sit near the cloth — which is
    /// what a cushion looks like in a photograph and not what it is: a covering cut from the same roll,
    /// lying the same way, with the same weave and the same pile. It is the bed's material under
    /// another name, and the name is what lets the harness tell the two apart when it reads the bed's
    /// own coordinates back.
    private static func cushionMaterial() -> SCNMaterial {
        Table3D.clothMaterial(named: "cloth (cushions)")
    }

    /// The wood the frame is made of: **one brown, and no figure at all**.
    ///
    /// A rail used to carry the grain of timber — nine lengths of it wandering down the table, with a
    /// fine ripple over the top — drawn as a tone over the wood's own colour, `(104, 52, 26)`. That tone
    /// is gone: every pixel of a rail is the same brown now, which is what makes the frame **monochrome**
    /// in the plain sense of the word — one colour and nothing else.
    ///
    /// The brown is that colour at the tone its grain averaged, **0.86** of it — `#592c16` — so the frame
    /// comes out as light as it did with the figure drawn on it: the change is a loss of figure and not a
    /// change of tone. The number the material carries is a shade under that, because a flat colour and a
    /// picture of one are not put through the renderer's colour handling alike; measured against the
    /// render, this is the value that comes out the mid-brown the grain averaged to. It is still timber
    /// under the lamps, so a rail's top, its outer edge and the shadowed face below it come out at
    /// different brightnesses — that is the light falling on one colour, not a second colour in the wood.
    static let railWood = NSColor(calibratedRed: 0.276, green: 0.138, blue: 0.069, alpha: 1)

    private static func railMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = railWood
        material.roughness.contents = 0.28
        material.metalness.contents = 0.0
        material.clearCoat.contents = 0.6
        material.clearCoatRoughness.contents = 0.12
        material.name = "rail (one brown)"
        return material
    }

    private static func slateMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.11, alpha: 1)
        material.roughness.contents = 0.6
        material.metalness.contents = 0.0
        return material
    }

    /// The grey the floor is painted, and the light it is lit by. Light grey rather than white: a white
    /// floor under these lights is the brightest thing in the room, and the eye goes to it instead of to
    /// the table.
    static let floorGrey = NSColor(calibratedWhite: 0.72, alpha: 1)

    /// The floor: light grey **carpet**, and **almost wholly diffuse** — which for this renderer means
    /// *wholly* diffuse, since `lambert` has no specular term to give at all. That is the point of a
    /// carpet on the floor: the only things in the room that shine are the balls and the polished wood,
    /// and a sheen on a floor under lamps reads as ice. The roughness and metalness are set under the
    /// lighting model as well, so that a change of model cannot quietly turn the floor shiny.
    ///
    /// The covering itself is `carpetMaps`: a loop pile about a centimetre from loop to loop, tiled square
    /// on the floor whatever size it is cut to. Its relief is in the normal map, which is where a surface
    /// that takes no specular keeps what it has of a surface at all.
    /// The table's shadow: black, unlit, and blended by its own alpha — see `tableShadowMap`.
    private static func tableShadowMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = Table3D.tableShadowMap()
        material.writesToDepthBuffer = false
        material.isDoubleSided = false
        material.name = "table shadow (drawn)"
        return material
    }

    private static func floorMaterial() -> SCNMaterial {
        let maps = Table3D.carpetMaps()
        let material = SCNMaterial()
        material.lightingModel = .lambert
        material.diffuse.contents = maps.colour
        material.normal.contents = maps.normal
        material.normal.intensity = 1.0
        material.roughness.contents = 1.0
        material.metalness.contents = 0.0
        for property in [material.diffuse, material.normal] {
            property.wrapS = .repeat
            property.wrapT = .repeat
            property.contentsTransform = SCNMatrix4MakeScale(
                CGFloat(Furniture.carpetTilesAlong), CGFloat(Furniture.carpetTilesAcross), 1
            )
            property.mipFilter = .linear
        }
        material.name = "floor (light grey carpet)"
        return material
    }

    private static func pocketMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        // The lining is dull cloth and leather, so it takes no specular: a pocket has to read as a
        // hole, not as a shiny black disc.
        material.lightingModel = .lambert
        material.diffuse.contents = NSColor(calibratedWhite: 0.015, alpha: 1)
        material.roughness.contents = 0.95
        material.metalness.contents = 0.0
        return material
    }

    /// The baulk line, the "D" and the spots.
    private static func markingMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        // Chalked on to the cloth rather than painted: a pale line, not a light strip.
        material.diffuse.contents = NSColor(calibratedRed: 0.45, green: 0.47, blue: 0.42, alpha: 1)
        material.roughness.contents = 0.9
        material.metalness.contents = 0.0
        return material
    }

    private static func ballMaterial(for colour: BallColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = colour.nsColor
        // Glassy: buffed to a high polish with a strong clear coat over it, so that the ball shows
        // what is around it — the cloth under it, the rails, the plates overhead — rather than a wash
        // of its own colour with one highlight on it. The coat is very slightly dulled, which keeps
        // the reflections from reading as a bathroom mirror, and the bit of metalness carries the
        // light that would scatter off the surface as pale colour into the reflection instead.
        material.roughness.contents = 0.05
        material.metalness.contents = 0.3
        material.clearCoat.contents = 0.9
        material.clearCoatRoughness.contents = 0.02
        material.name = colour.rawValue
        return material
    }

    /// The **baize**, as three maps taken off one height field so that they line up: its colour, how
    /// rough it is, and the relief of its nap.
    ///
    /// A snooker cloth is baize — a tightly woven wool, thin and taut over the slate, carrying the
    /// shortest of brushed naps. It is not felt and it is not velvet, and the whole difference is that
    /// its fibres all lie **the same way**: carded and laid down directionally when the cloth was made,
    /// so a raking light shows a field of fine fibres lying along the table towards the black, like
    /// grass flattened by a wind that never changes. That nap is what these maps are made of — thousands
    /// of fine streaks, long along the fibre and narrow across it, with the odd tuft standing proud of
    /// its neighbours. The weave the nap lies on is finer than a picture this size can hold, and a pile
    /// covers a weave anyway: what shows at the surface of a real cloth is the pile.
    ///
    /// Up close the fibres differ from one another strongly — that is what a pile is — but at a distance
    /// all of it averages away to nothing, because from the length of the table a fibre and even a clump
    /// of them are under a pixel across. So the cloth reads as one flat, faintly dusty green from
    /// standing height, and only comes up as a nap where the light rakes across it or the eye is close
    /// enough to resolve a fibre.
    static func clothMaps(side: Int = 1024) -> (colour: NSImage, roughness: NSImage, normal: NSImage) {
        // A fibre here is a dozen texels long and one or two across. Twelve tiles run the length of the
        // table, so on the cloth that is a fibre of three or four millimetres lying over one of half a
        // millimetre — the size of the marks a brushed nap leaves, rather than the fibres themselves,
        // which are far finer than any picture of this cloth could hold.
        var height = [Double](repeating: 0, count: side * side)

        /// A lattice point hashed to a fraction, so that a field can be built out of those points.
        func lattice(_ i: Int, _ j: Int) -> Double {
            var h = UInt64(bitPattern: Int64(i &* 73_856_093 ^ j &* 19_349_663)) &+ 0x9E37_79B9_7F4A_7C15
            h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
            h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((h ^ (h >> 31)) >> 11) / Double(UInt64(1) << 53)
        }

        /// Value noise: the lattice smoothed between its points, so the field can be asked for at any
        /// scale — **long in one direction and short in the other, as a fibre lying on the cloth is**.
        func noise(_ x: Double, _ y: Double) -> Double {
            let ix = x.rounded(.down), iy = y.rounded(.down)
            let fx = x - ix, fy = y - iy
            let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
            let i = Int(ix), j = Int(iy)
            let a = lattice(i, j), b = lattice(i + 1, j)
            let c = lattice(i, j + 1), d = lattice(i + 1, j + 1)
            let near = a + (b - a) * sx, far = c + (d - c) * sx
            return near + (far - near) * sy
        }

        for y in 0..<side {
            for x in 0..<side {
                let u = Double(x), v = Double(y)
                // The nap: fibres lying along `u`, which is the length of the table and the way the nap
                // runs — from the baulk end towards the black. Three runs of fibres one inside another:
                // the **fibres** themselves, a texel across and a few long, each with a tone of its own
                // so that neighbours are not alike; and the **clumps** they lie in, where the brush rode
                // over them. Both are at the finest this picture can hold — a fibre is one texel wide,
                // so the nap is as fine as the cloth is going to be drawn, and what is left at any
                // distance is the grain of it rather than the fibres.
                let fibres = noise(u / 7.0, v / 1.0)
                let clumps = noise(u / 4.0, v / 1.6)
                let nap = 0.92 * fibres + 0.08 * clumps
                height[y * side + x] = max(0, min(1, 0.5 + 0.42 * (nap - 0.5)))
            }
        }

        let image = { (value: (Int, Int) -> (Double, Double, Double)) in
            Table3D.texture(side: side, value)
        }

        let colour = image { x, y in
            // Matte wool: the tone rides on the nap, fibre by fibre, so the cloth is one green with a
            // grain in it rather than a pattern — and the grain averages away at any distance. What lifts
            // it is **dust** — chalk off the tip and the
            // loose fibres the brush pulled up — which is rare, faint, and greyer than the wool, and is
            // what makes a cloth read as dusty rather than as clean.
            let tone = 0.99 + 0.60 * (height[y * side + x] - 0.5)
            let dust = lattice(x &* 3 &+ 11, y &* 5 &+ 7) > 0.9985 ? 1.0 : 0.0
            return (0.072 * tone + 0.06 * dust,
                    0.330 * tone + 0.055 * dust,
                    0.158 * tone + 0.06 * dust)
        }
        let roughness = image { x, y in
            // Nearly light-absorbing: wool is the least shiny thing on a table and the nap scatters what
            // falls on it. The crowns of the fibres are a shade smoother than the gaps between them,
            // which is all the sheen the surface has of its own.
            let r = 0.935 - 0.09 * (height[y * side + x] - 0.5)
            return (r, r, r)
        }
        let normal = image { x, y in
            let left = height[y * side + max(0, x - 1)], right = height[y * side + min(side - 1, x + 1)]
            let below = height[max(0, y - 1) * side + x], above = height[min(side - 1, y + 1) * side + x]
            // The relief of the nap, in the normal: the fibres are lifted by a fraction of their own
            // breadth, which is what a raking light picks out. Measured against the maps, this puts the
            // surface a degree or two off true from fibre to fibre — a fine grain rather than a shag,
            // smooth to the eye at a distance, where the fibres are under a pixel each.
            let dx = (right - left) * 0.65, dy = (above - below) * 0.65
            let length = (dx * dx + dy * dy + 1).squareRoot()
            return (0.5 - 0.5 * dx / length, 0.5 - 0.5 * dy / length, 0.5 + 0.5 / length)
        }
        return (colour, roughness, normal)
    }

    /// A texture of `side` by `side` pixels, from a closure that gives each texel its colour. Used by the
    /// cloth and by the carpet, which are the two surfaces in the scene that are made of a woven thing.
    private static func texture(side: Int, _ value: (Int, Int) -> (Double, Double, Double)) -> NSImage {
        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32
        )
        if let bitmap, let data = bitmap.bitmapData {
            for y in 0..<side {
                for x in 0..<side {
                    let (r, g, b) = value(x, y)
                    let index = (y * side + x) * 4
                    data[index + 0] = UInt8(max(0, min(255, r * 255)))
                    data[index + 1] = UInt8(max(0, min(255, g * 255)))
                    data[index + 2] = UInt8(max(0, min(255, b * 255)))
                    data[index + 3] = 255
                }
            }
        }
        let image = NSImage(size: NSSize(width: side, height: side))
        if let bitmap { image.addRepresentation(bitmap) }
        return image
    }

    // MARK: - The table's shadow, and the carpet it falls on

    /// How far the table's **shadow** reaches past its own edge on the carpet, in millimetres, and how dark
    /// it is in the middle of it. See `tableShadowMap` for why the shadow is drawn rather than cast.
    static let shadowPenumbra: Double = 500
    static let shadowStrength: Double = 0.5

    /// The **shadow of the table** on the carpet, as a soft black shape the size of the table's own plan: an
    /// image whose alpha is 1 under the table and falls away to nothing over `shadowPenumbra` of carpet
    /// outside its edge.
    ///
    /// It is **drawn rather than cast**, and it has to be. The room's shadow-casting lights are the four
    /// small spots over the corner pockets and the plates cannot cast one at all — SceneKit's shadows come
    /// from spot and directional lights only — and of the light that falls on the carpet, nearly all of it
    /// comes from those three plates and from the room's wash, neither of which can be shadowed. A light
    /// bright enough to throw the table's shadow on the floor would have to be brighter than the rig itself,
    /// and it would light the cloth as well and change the table's figure out of all recognition. So the
    /// shadow is a thing the scene draws: black, unlit, laid on the carpet two millimetres above it, and the
    /// right size — bigger than the table by the penumbra, because the light that would cast it comes from
    /// above and spills outward.
    static func tableShadowMap(side: Int = 256) -> NSImage {
        let quadLength = Table3D.shadowQuadLength
        let quadWidth = Table3D.shadowQuadWidth
        let halfLength = (Table.length + 2 * Table3D.outerX) / 2
        let halfWidth = (Table.width + 2 * Table3D.outerX) / 2
        let corner = Furniture.railEdge

        let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * 4, bitsPerPixel: 32
        )
        if let bitmap, let data = bitmap.bitmapData {
            for row in 0..<side {
                for column in 0..<side {
                    // The texel in the table's own coordinates: the quad is centred on the table.
                    let x = (Double(column) / Double(side - 1) - 0.5) * quadLength
                    let y = (Double(row) / Double(side - 1) - 0.5) * quadWidth
                    // How far outside the frame's own outline the texel is, with the corners taken off:
                    // the signed distance to a rounded rectangle, negative inside it.
                    let dx = abs(x) - (halfLength - corner)
                    let dy = abs(y) - (halfWidth - corner)
                    let outside = (max(dx, 0) * max(dx, 0) + max(dy, 0) * max(dy, 0)).squareRoot()
                    let distance = outside + min(max(dx, dy), 0) - corner
                    let fade = 1 - smoothstep(0, 1, distance / Table3D.shadowPenumbra)
                    let index = (row * side + column) * 4
                    // Black, with the shadow in the alpha: a matte of light on the carpet.
                    data[index + 0] = 0
                    data[index + 1] = 0
                    data[index + 2] = 0
                    data[index + 3] = UInt8(max(0, min(255, Table3D.shadowStrength * fade * 255)))
                }
            }
        }
        let image = NSImage(size: NSSize(width: side, height: side))
        if let bitmap { image.addRepresentation(bitmap) }
        return image
    }

    /// The same image with the colour taken out of it, every pixel set to its own brightness. Used on the
    /// captured surroundings, which are a **light** in this scene as well as a reflection — see
    /// `captureSurroundingsIfNeeded`.
    /// This image with the colour taken out of it. Core Image does the work: a colour control with the
    /// saturation at nought, on the GPU, over a 512-pixel face and a six-face strip.
    ///
    /// It is worth being blunt about why this is a filter rather than a loop over the pixels: the first
    /// attempt at it built a copy of each face and set every pixel by hand, and the copy silently came back
    /// nil and the function quietly returned the original image. The surroundings stayed green, the wood
    /// kept its green sheen, and the probe — which measured the *leg* and found no green in it — agreed
    /// with the code rather than with the eye. What caught it was reading the captured faces back: they
    /// were still green. So the capture is checked for colour as well as made grey.
    static func greyedImage(_ image: NSImage) -> NSImage {
        guard let tiff = image.tiffRepresentation, let source = CIImage(data: tiff) else { return image }
        let greyed = source.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
        let context = CIContext(options: nil)
        guard let cg = context.createCGImage(greyed, from: greyed.extent) else { return image }
        return NSImage(cgImage: cg, size: image.size)
    }

    /// The shape's own smoothstep, so the penumbra has no edge to it.
    private static func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = max(0, min(1, (x - edge0) / (edge1 - edge0)))
        return t * t * (3 - 2 * t)
    }

    /// The size of the quad the table's shadow is drawn on: the table's own plan with room for the
    /// penumbra and a little carpet beyond it.
    static var shadowQuadLength: Double {
        Table.length + 2 * Table3D.outerX + 2 * Table3D.shadowPenumbra + 2 * Table3D.shadowMargin
    }
    static var shadowQuadWidth: Double {
        Table.width + 2 * Table3D.outerX + 2 * Table3D.shadowPenumbra + 2 * Table3D.shadowMargin
    }
    private static let shadowMargin: Double = 100

    // MARK: - The carpet

    /// The **carpet**: what the floor of the room is covered with — a loop-pile woven wool, drawn as the
    /// weave it is rather than as a photograph of one.
    ///
    /// A carpet is coarse where the baize is fine. A tuft of pile is a **loop of yarn** pulled through a
    /// woven backing: the loops stand in rows about a centimetre apart with the backing dark in the seams
    /// between them, each loop is a rounded top of its own and a shade off its neighbours, and the whole
    /// surface carries the slower variegation of the dye and of the way the pile has been laid. So the
    /// maps are a **grid of domes**, one per tuft, with the seams between the rows and the variegation
    /// over the top of them — and no figure of any larger size, which is what lets a tile of them repeat
    /// over a floor ten metres long without the eye finding the seam.
    ///
    /// The tiling is square on the floor — see `Furniture.carpetTilesAlong` — so a tuft is a little over
    /// a centimetre across whatever size the floor is cut to. At the distance a floor is looked at, the
    /// grid averages away into grey with a grain in it; where the eye comes near to it, the rows of loops
    /// are what it is looking at. A carpet is also the least shiny thing in the room, so the material is
    /// `lambert` — see `floorMaterial` — and the pile's relief is carried in the normal map, which is
    /// where a surface with no specular of its own has to keep it.
    static func carpetMaps(side: Int = 512) -> (colour: NSImage, normal: NSImage) {
        // Tufts to a tile. At the floor's tiling this is a loop a little over a centimetre across: fine
        // enough that a room's floor of it reads as one grey, coarse enough that the loops can be seen.
        let tufts = 36
        let pitch = Double(side) / Double(tufts)
        var height = [Double](repeating: 0, count: side * side)
        var variegation = [Double](repeating: 0, count: side * side)

        /// A lattice point hashed to a fraction, so that a field can be built out of those points.
        func lattice(_ i: Int, _ j: Int) -> Double {
            var h = UInt64(bitPattern: Int64(i &* 73_856_093 ^ j &* 19_349_663)) &+ 0x9E37_79B9_7F4A_7C15
            h = (h ^ (h >> 30)) &* 0xBF58_476D_1CE4_E5B9
            h = (h ^ (h >> 27)) &* 0x94D0_49BB_1331_11EB
            return Double((h ^ (h >> 31)) >> 11) / Double(UInt64(1) << 53)
        }

        /// Value noise, for the variegation: smooth, and longer than a tuft, so the dyelot wanders over
        /// a few of them at a time rather than speckling one at a time.
        func noise(_ x: Double, _ y: Double) -> Double {
            let ix = x.rounded(.down), iy = y.rounded(.down)
            let fx = x - ix, fy = y - iy
            let sx = fx * fx * (3 - 2 * fx), sy = fy * fy * (3 - 2 * fy)
            let i = Int(ix), j = Int(iy)
            let a = lattice(i, j), b = lattice(i + 1, j)
            let c = lattice(i, j + 1), d = lattice(i + 1, j + 1)
            let near = a + (b - a) * sx, far = c + (d - c) * sx
            return near + (far - near) * sy
        }

        for y in 0..<side {
            for x in 0..<side {
                let u = Double(x) / pitch, v = Double(y) / pitch
                let i = Int(u.rounded(.down)), j = Int(v.rounded(.down))
                let du = u - Double(i) - 0.5, dv = v - Double(j) - 0.5
                // One loop: a rounded top that falls away into the seam where the backing shows between
                // the rows. The fall is quick enough that the seam is a seam and not a slope.
                let rise = max(0, 1 - (du * du + dv * dv) / 0.30)
                let dome = rise * rise * (3 - 2 * rise)
                // The rows ride over the weft of the backing under them, so every other row of loops
                // stands a little higher — which is the weave showing through the pile — and the loops
                // themselves are not all the same height, because a pile is not.
                let weft = j % 2 == 0 ? 1.0 : 0.88
                let tuft = 0.70 + 0.60 * lattice(i, j)
                height[y * side + x] = max(0, min(1, 0.18 + 0.82 * dome * weft * tuft))
                variegation[y * side + x] = noise(Double(x) / 42.0, Double(y) / 42.0)
            }
        }

        let grey = Table3D.floorGrey.usingColorSpace(.genericGray)?.whiteComponent ?? 0.72
        let colour = Table3D.texture(side: side) { x, y in
            // Grey wool. The tone rides on the loops — the crown of a loop catches the light and the
            // seam between two rows of them is in its own shadow — and over that rides the variegation,
            // which is the dye and the lie of the pile rather than any figure in it.
            let h = height[y * side + x]
            let shade = 0.72 + 0.30 * (h - 0.35)
            let tint = 0.94 + 0.12 * variegation[y * side + x]
            return (grey * shade * tint, grey * shade * tint, grey * shade * tint * 1.015)
        }
        let normal = Table3D.texture(side: side) { x, y in
            let left = height[y * side + max(0, x - 1)], right = height[y * side + min(side - 1, x + 1)]
            let below = height[max(0, y - 1) * side + x], above = height[min(side - 1, y + 1) * side + x]
            // The relief of the pile: a loop is lifted by its own breadth, so the normals come off the
            // surface at a steep angle round every tuft — far steeper than the nap of the cloth, which is
            // the whole difference between a pile you can see and a pile you cannot.
            let dx = (right - left) * 1.6, dy = (above - below) * 1.6
            let length = (dx * dx + dy * dy + 1).squareRoot()
            return (0.5 - 0.5 * dx / length, 0.5 - 0.5 * dy / length, 0.5 + 0.5 / length)
        }
        return (colour, normal)
    }

    // MARK: - Cue

    /// **Ash**, the wood a snooker cue's shaft is made of: a pale cream timber whose grain reads as a run
    /// of **arrows**. A cone's own mapping runs `u` round the shaft and `v` along it, so the figure is
    /// drawn in those terms: `u` is the trip round the shaft and wraps, `v` runs along it — 0 at the tip
    /// and 1 at the butt — and a mark is a curve through the two of them.
    ///
    /// One thing is drawn, and it is why a player picks ash over maple: **the arrows**. Each one is a
    /// single **parabola**, its vertex the tip and its arms opening back towards the butt, so the figure
    /// is a close run of chevrons that a player sights down. Nothing is drawn *along* the length of the
    /// shaft — the figure of an ash shaft of this grade *is* the arrows — and the grain between them is
    /// left as ground.
    ///
    /// What is drawn is the timber, not a picture of one: a pale ground, the figure over it, and a fine
    /// variation across the grain so the surface is not one flat tone.
    static func ashTexture() -> NSImage {
        let side = 512
        let bytesPerRow = side * 4
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: bytesPerRow, bitsPerPixel: 32
        ), let data = rep.bitmapData else {
            return NSImage(size: NSSize(width: side, height: side))
        }

        /// How far round the shaft `u` is from `at`, the short way — so a line that runs over the seam
        /// where the surface closes on itself is one line and not two.
        func across(_ u: Double, from at: Double) -> Double {
            var d = u - at
            d -= (d + 0.5).rounded(.down)
            return d
        }
        /// The arrows at a point — each one drawn as a single **arch**, not as a left arm and a right arm.
        ///
        /// An arm of an ash arrow is half of a **parabola** and not a straight line: `u = point ±
        /// √(opening · run)`, the two halves meeting at the point and bowing away from one another as
        /// they run. Drawing the two halves as two separate strokes leaves them to meet end to end, and
        /// that meeting is the weak place in the figure: the two ends between them leave a thin spot, or
        /// a hole, at the very middle of the head, and a step where each arm begins. So the arch is drawn
        /// the way a pen draws a curve — **one stroke, of one breadth, held square to the curve as it
        /// goes**: every pixel within a pen's breadth of the curve takes ink, and takes it in proportion
        /// to how deep it lies in the swath. There is then no join in the head to come out thin: the head
        /// is round and as solid as the arms, and the arms are the same stroke running on, opening as
        /// they run back towards the butt.
        func arrows(_ u: Double, _ v: Double) -> Double {
            // **Two columns** of arrows round the shaft, and ten to a column down it.
            let acrossTheShaft = 2, alongTheShaft = 10
            // The arms reach three points down the shaft, so each fade begins again over the arrows
            // below it and the columns read as a close run of overlapping chevrons rather than as
            // separate marks.
            let reach = 0.30          // how far an arm runs, along the shaft, before it fades out
            // Each arch is a **parabola with its vertex at the tip**: `u = point ± √(opening · run)`. The
            // arms therefore leave the head almost along the shaft and *straighten* as they run back
            // towards the butt, which is what an ash arrow does — a long hairpin laid along the shaft,
            // not a flare. There is no tip drawn on top of it: the vertex **is** the tip.
            //
            // **Three quarters of the width of 0.20**: an arm stands `√opening` off the axis at a run of
            // 1, so the width goes as the **square root** of this — three quarters as wide is nine
            // sixteenths of the number (0.20 · 0.75²), and twice as wide is four times it.
            let opening = 0.1125
            // The pen's **breadth**, and the one number that sets how heavy the figure is: the swath is
            // every pixel within half of this of the curve, so this is the width of an arm and the width
            // of the round head alike — one breadth, kept square to the curve, is what makes the head
            // come out as wide as the arms and not thinner.
            let width = 0.036
            var dark = 0.0
            for acrossIndex in 0..<acrossTheShaft {
                for alongIndex in 0..<alongTheShaft {
                    let pointU = (Double(acrossIndex) + 0.5) / Double(acrossTheShaft)
                    let pointV = (Double(alongIndex) + 0.5) / Double(alongTheShaft)
                    // The point is the tip-ward end of the arch and the arms run back from it: `v` runs 0
                    // at the tip to 1 at the butt, so an arch's arms are on the **larger** side of its
                    // point, and the point is what the player sees pointing at the tip.
                    let run = v - pointV
                    // The swath reaches half a pen above the vertex — the round head — and half a pen
                    // past the reach of the arms, and no further: outside that there is no ink at all,
                    // which is what keeps a pixel from being asked about every one of the arrows.
                    guard run > -width, run < reach + width else { continue }
                    for side in [-1.0, 1.0] {
                        // The **nearest point of this arm to the pixel**: `u(t) = point ± √(opening · t)`
                        // with `v(t) = point + t`. Newton, started from the pixel's own run along the
                        // shaft. The wider the arch, the harder its own bend pulls the answer about, so
                        // this runs to a ten-thousandth of the pen — five steps, and the arch can be
                        // widened again without the pen coming out the wrong shape.
                        var t = max(run, 1e-9)
                        for _ in 0..<5 {
                            let arm = (opening * t).squareRoot()
                            let slope = side * opening / (2 * max(arm, 1e-12))
                            t = max(t + ((u - (pointU + side * arm)) * slope + (v - (pointV + t)))
                                    / (slope * slope + 1), 1e-9)
                        }
                        // How far the pixel stands off the curve, **square to the curve**: inside the pen
                        // it takes ink in proportion to how deep in the swath it lies. It is the swath
                        // that holds the arch's breadth — head, bend and arms alike — so no part of the
                        // figure is thinner than another.
                        let arm = (opening * t).squareRoot()
                        let du = across(u, from: pointU + side * arm)
                        let dv = v - (pointV + t)
                        let away = (du * du + dv * dv).squareRoot()
                        guard away < width else { continue }
                        let fade = 1 - t / reach
                        guard fade > 0 else { continue }
                        dark = max(dark, fade * (1 - away / width))
                    }
                }
            }
            return dark
        }

        for y in 0..<side {
            for x in 0..<side {
                let u = Double(x) / Double(side)
                let v = Double(y) / Double(side)
                let figure = sin(u * .pi * 2 * 34 + v * 7) * 0.5 + sin(v * .pi * 2 * 21) * 0.5
                // Nothing else is drawn over the ground: the arrows **are** the figure, and are meant to
                // be read on their own. How deep they go is the one number here out of the timber's own
                // range — a shade off the ground rather than a painted line — so the figure is a
                // lightening or darkening of the wood and never a black mark laid over it.
                let tone = 0.97 + figure * 0.02 - arrows(u, v) * 0.55
                let index = (y * side + x) * 4
                data[index + 0] = UInt8(min(255, 236 * tone))
                data[index + 1] = UInt8(min(255, 214 * tone))
                data[index + 2] = UInt8(min(255, 176 * tone))
                data[index + 3] = 255
            }
        }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    /// The cue's tip, as the leather it is: **green at the crown**, going down the leather to a dark grey
    /// where it is glued to the ferrule.
    ///
    /// A tip is not one colour. The crown is the end that is chalked and the end the ball is struck
    /// with, and the leather there is pale and green; down at the brass it is the same leather gone
    /// hard and dark. So the tip is drawn as the gradient it is, laid along the leather: on the
    /// cylinder's own mapping `v` runs along it — 0 at the crown and 1 at the ferrule — and the colour
    /// walks the whole way down without a step in it.
    static func tipTexture() -> NSImage {
        let side = 64
        let bytesPerRow = side * 4
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: bytesPerRow, bitsPerPixel: 32
        ), let data = rep.bitmapData else {
            return NSImage(size: NSSize(width: side, height: side))
        }
        // The two ends of the leather. The tip's own length of the cue carries the crown's colour, so
        // anything that wants one colour for the tip wants this one.
        let crown = Table3D.cueTipCrown
        let ferrule = Table3D.cueTipAtTheFerrule
        for y in 0..<side {
            // `v` runs 0 at the crown to 1 at the ferrule, so the **top row of the picture is the
            // crown** and the bottom row is where the tip meets the brass.
            let t = Double(y) / Double(side - 1)
            let red = crown.redComponent + (ferrule.redComponent - crown.redComponent) * t
            let green = crown.greenComponent + (ferrule.greenComponent - crown.greenComponent) * t
            let blue = crown.blueComponent + (ferrule.blueComponent - crown.blueComponent) * t
            for x in 0..<side {
                let index = (y * side + x) * 4
                data[index + 0] = UInt8(min(255, max(0, red * 255)))
                data[index + 1] = UInt8(min(255, max(0, green * 255)))
                data[index + 2] = UInt8(min(255, max(0, blue * 255)))
                data[index + 3] = 255
            }
        }
        let image = NSImage(size: NSSize(width: side, height: side))
        image.addRepresentation(rep)
        return image
    }

    private func buildCue() {
        // Built along +x with the tip at the origin, so the node's orientation can simply be the
        // line of aim: the cue then points where the cue ball is going.
        //
        // The sections join end to end — tip, ferrule, shaft, joint and butt — and taper the way a
        // real cue does, from about 9.8 mm across the tip to 22 mm across the butt. The sequence
        // is checked in the snapshot harness, so a section cannot quietly come out short and leave
        // the cue chopped off in the middle.
        for section in Table3D.cueSections {
            let height = Table3D.metres(section.back - section.front)
            let geometry: SCNGeometry
            if abs(section.frontRadius - section.backRadius) < 0.01 {
                geometry = SCNCylinder(radius: Table3D.metres(section.frontRadius), height: height)
            } else {
                // The cone's narrow end faces the ball, which is +x in the cue's own frame.
                geometry = SCNCone(topRadius: Table3D.metres(section.frontRadius),
                                   bottomRadius: Table3D.metres(section.backRadius),
                                   height: height)
            }
            // Two lengths of a cue are not one colour: the shaft is **ash**, whose own grain is drawn on
            // it, and the tip is **green at the crown going down to a dark grey** at the brass,
            // which is a gradient and not a colour at all. The rest — the ferrule, the joint, the ebony
            // butt and the bumper — are the materials a cue is dressed in, and are flat colours.
            switch section.name {
            case "tip": geometry.firstMaterial = Table3D.tipMaterial()
            case "shaft": geometry.firstMaterial = Table3D.ashShaftMaterial()
            default: geometry.firstMaterial = Table3D.cueMaterial(section.colour)
            }
            let node = SCNNode(geometry: geometry)
            node.simdOrientation = simd_quatf(angle: -Float.pi / 2, axis: simd_float3(0, 0, 1))
            node.simdPosition = simd_float3(Table3D.metresF(-(section.front + section.back) / 2), 0, 0)
            cueNode.addChildNode(node)
        }

        cueLayer.addChildNode(cueNode)
    }

    /// One length of the cue, measured back from the tip in millimetres.
    struct CueSection {
        let name: String
        let front: Double
        let back: Double
        let frontRadius: Double
        let backRadius: Double
        let colour: NSColor
    }

    /// The cue tip's own two colours: the **green** of a chalked crown, and the **dark grey** the leather
    /// goes down where it is glued to the ferrule. `tipTexture()` walks from one to the other, and the
    /// tip's `colour` below is the crown's, for anything that wants a single colour for it.
    ///
    /// The green is the **middle of the graduation the tip was first drawn with** — halfway between the
    /// pale green the crown started as and the grey at the ferrule — so the tip now sits at the tone the
    /// middle of its own gradient had, and reads as a quieter thing on the end of the cue.
    static let cueTipCrown = NSColor(calibratedRed: 0.375, green: 0.505, blue: 0.305, alpha: 1)
    static let cueTipAtTheFerrule = NSColor(calibratedRed: 0.15, green: 0.15, blue: 0.16, alpha: 1)

    /// One length of the cue, its girth taken from the stick's own taper rather than given by hand.
    ///
    /// The sections are lengths **of one cue** — one straight cone from the tip to the butt — so their
    /// radii are read off `Table.cueRadius` at the distance each length runs between. Nothing here can
    /// put a step in the side of the stick, because no length carries a radius of its own.
    private static func cueSection(_ name: String, _ front: Double, _ back: Double,
                                   _ colour: NSColor) -> CueSection {
        CueSection(name: name, front: front, back: back,
                   frontRadius: Table.cueRadius(at: front), backRadius: Table.cueRadius(at: back),
                   colour: colour)
    }

    /// A cue, tip to butt: **1400 mm long, 9.8 mm across the tip and 22 mm across the butt**, with the
    /// side a straight line between them. See `Table.cueRadius` for the taper itself.
    static let cueSections: [CueSection] = [
        // The tip is **green at the crown going down to a dark grey** at its base, so it is drawn
        // as a gradient rather than in this one colour — see `tipTexture()` and `tipMaterial()`.
        cueSection("tip", 0, 9, Table3D.cueTipCrown),
        // The ferrule is the bronze band behind the tip: a short, warm metal collar, 8 mm of it.
        cueSection("ferrule", 9, 17, NSColor(calibratedRed: 0.72, green: 0.53, blue: 0.26, alpha: 1)),
        cueSection("shaft", 17, 934, NSColor(calibratedRed: 0.74, green: 0.60, blue: 0.40, alpha: 1)),
        cueSection("joint", 934, 952, NSColor(calibratedRed: 0.72, green: 0.82, blue: 0.88, alpha: 1)),
        cueSection("butt", 952, 1387, NSColor(calibratedRed: 0.13, green: 0.09, blue: 0.07, alpha: 1)),
        cueSection("bumper", 1387, 1400, NSColor(calibratedWhite: 0.06, alpha: 1)),
    ]

    private static func cueMaterial(_ colour: NSColor) -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = colour
        material.roughness.contents = 0.22
        material.metalness.contents = 0.0
        material.clearCoat.contents = 0.8
        return material
    }

    /// The shaft's own material: the ash texture under a cue-maker's varnish, which is a thin clear coat
    /// over a barely-there roughness — a shaft is polished, and it should catch the light along its
    /// length the way a varnished stick does.
    private static func ashShaftMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = ashTexture()
        material.diffuse.wrapS = .repeat
        material.diffuse.wrapT = .repeat
        material.roughness.contents = 0.26
        material.metalness.contents = 0.0
        material.clearCoat.contents = 0.7
        material.clearCoatRoughness.contents = 0.15
        material.name = "cue shaft (ash)"
        return material
    }

    /// The tip's own material: the leather, from the green of the chalked crown down to the grey at the
    /// brass. It is dressed exactly as the rest of the cue's furniture is — the same roughness and the
    /// same coat — so the only thing that marks the tip out is the colour the leather is.
    private static func tipMaterial() -> SCNMaterial {
        let material = cueMaterial(Table3D.cueTipCrown)
        material.diffuse.contents = tipTexture()
        // Clamped rather than repeated: the two ends of the leather are the two ends of the picture, and
        // the tip's own ends should take those colours and not wrap round to the other one.
        material.diffuse.wrapS = .clamp
        material.diffuse.wrapT = .clamp
        material.name = "cue tip (green to dark grey)"
        return material
    }

    // MARK: - Aiming aids

    private func buildAimingAids() {
        // The ghost ball shows where the cue ball would first make contact. It is a hint rather than
        // a ball, so it is drawn faintly: a flat unreflective shading, no glow, and no shadow on the
        // cloth. A highlight or a shadow underneath it is what makes it read as a ball in play.
        let ghost = SCNSphere(radius: Table3D.metres(Table.ballRadius))
        ghost.segmentCount = 32
        let ghostMaterial = SCNMaterial()
        // Unlit: a shaded ball is dark on the side facing the player, because the lamps are overhead,
        // and a reflective one catches a highlight. This way it is a flat, faint marker whose only
        // character is what shows through it.
        ghostMaterial.lightingModel = .constant
        ghostMaterial.diffuse.contents = NSColor(calibratedWhite: 0.85, alpha: 1)
        ghostMaterial.transparency = 0.35
        // One-sided: the faces of a sphere's far half point away and are dropped, so the ball is a
        // single even layer of colour. Drawn double sided, the near and far halves both blend and,
        // with no ordering within one piece of geometry, one half comes out at twice the density.
        ghostMaterial.isDoubleSided = false
        ghost.firstMaterial = ghostMaterial
        ghostNode.geometry = ghost
        ghostNode.castsShadow = false
        aimLayer.addChildNode(ghostNode)

        let line = SCNCylinder(radius: Table3D.metres(1.8), height: 1)
        let lineMaterial = SCNMaterial()
        lineMaterial.lightingModel = .constant
        lineMaterial.diffuse.contents = NSColor(calibratedWhite: 0.95, alpha: 0.5)
        lineMaterial.transparency = 0.5
        line.firstMaterial = lineMaterial
        aimLineNode.geometry = line
        aimLineNode.castsShadow = false
        aimLineNode.simdOrientation = simd_quatf(angle: .pi / 2, axis: simd_float3(0, 0, 1))
        aimLayer.addChildNode(aimLineNode)

        // Where the ball being aimed at is going. The cue ball sends it off along the **line of
        // centres** at the moment of contact, so this line starts at that ball's own middle and runs
        // away from the ghost ball.
        //
        // It is **painted on the cloth** rather than held over it — a flat stripe of the same build as
        // the table's own markings — and it is **green** while the ball it belongs to is one the cue
        // ball may strike first, turning **red** when it is not: aiming at a ball that is not on is a
        // foul, and the line says so before the stroke is played rather than after. It is **solid** and
        // drawn wider than the table's own markings are — twice the 3 mm of the baulk line — so that it
        // reads at a glance from the far end of the table rather than having to be looked for.
        let ballLine = SCNBox(width: 1, height: Table3D.metres(0.5), length: Table3D.metres(6),
                              chamferRadius: 0)
        ballLineMaterial.lightingModel = .constant
        ballLineMaterial.diffuse.contents = NSColor(calibratedRed: 0.45, green: 1.0, blue: 0.5, alpha: 1)
        ballLineFoulMaterial.lightingModel = .constant
        ballLineFoulMaterial.diffuse.contents = NSColor(calibratedRed: 1.0, green: 0.25, blue: 0.2, alpha: 1)
        ballLine.firstMaterial = ballLineMaterial
        ballLineNode.geometry = ballLine
        ballLineNode.castsShadow = false
        ballLineNode.isHidden = true
        aimLayer.addChildNode(ballLineNode)
    }

    // MARK: - Camera

    private func buildCamera() {
        let camera = SCNCamera()
        camera.fieldOfView = CGFloat(preset.fieldOfView)
        camera.zNear = 0.02
        camera.zFar = 60
        camera.wantsHDR = true
        // **The exposure is fixed.** Left to adapt, the camera brightens the whole picture as the eye
        // turns from the cloth to the dark room and back, which reads as the table changing colour under
        // the player rather than as the light it is standing in — and it costs a pass every frame to
        // work the average out. One exposure, set by `exposureOffset`, does not move.
        camera.wantsExposureAdaptation = false
        camera.bloomIntensity = 0.15
        camera.bloomThreshold = 0.90
        camera.bloomBlurRadius = 12
        cameraNode.camera = camera

        // The overhead light a real table is played under: three long rectangular plates, one down
        // the middle of the table and one along each of its long sides, hanging 2.2 m over the cloth.
        // The two plates along the sides are turned down towards the table, which is what the fixture
        // does; the middle one looks straight down.
        let ambient = SCNLight()
        ambient.type = .ambient
        ambient.intensity = CGFloat(Table3D.ambientIntensity)
        ambient.color = NSColor(calibratedRed: 0.92, green: 0.95, blue: 1.0, alpha: 1)
        ambientLight = ambient
        let ambientNode = SCNNode()
        ambientNode.light = ambient
        scene.rootNode.addChildNode(ambientNode)

        // One rectangular area light per plate, and the plate is the whole length of the table's
        // light. There are three of them and four corner lights, so seven lights in the scene —
        // which matters, because SceneKit applies **at most eight lights to any one object** and a
        // ball is one object. With nine plates and the four corner lights, five of the plates were
        // being dropped without a word, and a ball was lit and reflecting whichever eight the
        // renderer happened to choose.
        for row in TableLightRig.plates {
            let light = SCNLight()
            light.type = .area
            light.areaType = .rectangle
            light.areaExtents = simd_float3(Table3D.metresF(TableLightRig.plateLength),
                                            Table3D.metresF(TableLightRig.plateWidth), 0)
            light.intensity = CGFloat(Table3D.plateIntensity)
            plateLights.append(light)
            light.color = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.92, alpha: 1)
            light.attenuationStartDistance = 0.4
            light.attenuationEndDistance = 6.0
            light.drawsArea = false
            let node = SCNNode()
            node.light = light
            node.simdPosition = Table3D.point(row.centre, height: row.height)
            node.simdOrientation = Table3D.panelOrientation(tiltDegrees: row.tilt)
            scene.rootNode.addChildNode(node)
        }

        // The fixture itself, drawn at the same measurements as the light that stands in for it.
        for plate in TableLightRig.plates {
            let node = SCNNode()
            node.simdPosition = Table3D.point(plate.centre, height: plate.height)
            node.simdOrientation = Table3D.panelOrientation(tiltDegrees: plate.tilt)

            // The panel itself hangs on the light rather than being the light, so that the fixture
            // can be taken out of a view from above the table — where it would otherwise stand
            // between the camera and the cloth — without taking its light away with it.
            let panel = SCNPlane(width: Table3D.metres(TableLightRig.plateLength),
                                 height: Table3D.metres(TableLightRig.plateWidth))
            panel.firstMaterial = Table3D.panelMaterial()
            node.geometry = panel
            node.castsShadow = false
            panelNodes.append(node)

            scene.rootNode.addChildNode(node)
        }

        // A light over each corner pocket, 2.2 m up and looking straight down. These are what puts a
        // shadow under a ball: an area light cannot cast one, and a ball with nothing under it does
        // not look like it is resting on the cloth. Being over the corners, their shadows fall
        // outward from the middle of the table, and their light fills the corners the plates do not
        // quite reach.
        for pocket in [PocketID.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let light = SCNLight()
            light.type = .spot
            light.spotInnerAngle = 60
            light.spotOuterAngle = 120
            light.intensity = CGFloat(Table3D.cornerLightIntensity)
            cornerLights.append(light)
            light.color = NSColor(calibratedRed: 1.0, green: 0.97, blue: 0.92, alpha: 1)
            light.attenuationStartDistance = 0.4
            light.attenuationEndDistance = 6.0
            light.castsShadow = lightsCastShadows
            light.shadowSampleCount = 16
            // The blur is in shadow-map texels, so it is measured against the map: at this size a texel
            // is 3.7 mm of cloth, and two of them spread the edge of a shadow by 7.4 mm — soft enough to
            // carry the map's own steps, and still well short of the 52.5 mm a ball is across, so the
            // shadow under a ball is a shadow and not a smudge. See `shadowColor` for its depth.
            light.shadowRadius = 2.0
            light.shadowMapSize = CGSize(width: Table3D.cornerShadowMapSize,
                                         height: Table3D.cornerShadowMapSize)
            light.shadowMode = .forward
            // **How dark a shadow is**: what a shadowed piece of cloth keeps of the light. Black at full
            // alpha takes all of it away; this one takes six tenths, so a shadow is a shading of the
            // cloth rather than a hole in it, and a ball still reads as sitting on it.
            // `Table3D.shadowDepth` is the figure, and the offscreen probe measures the cue's shadow
            // against it.
            light.shadowColor = NSColor(calibratedWhite: 0, alpha: Table3D.shadowDepth)
            let node = SCNNode()
            node.light = light
            node.simdPosition = Table3D.point(pocket.position, height: TableLightRig.heightAboveCloth)
            node.simdEulerAngles = simd_float3(Float(-Double.pi / 2), 0, 0)
            scene.rootNode.addChildNode(node)
        }

        // And the four lights themselves, drawn: a **spot lamp** at each of those four places, so that
        // the corner lights are lamps in the room rather than four invisible points. The lamp hangs on
        // the light rather than being it — the same arrangement as the plates, and for the same
        // reason — and it does not cast a shadow, because the light it houses is inside it: a lamp that
        // shadowed its own spotlight would take the light off the table.
        for pocket in [PocketID.topLeft, .topRight, .bottomLeft, .bottomRight] {
            let lamp = Table3D.spotLamp()
            lamp.simdPosition = Table3D.point(pocket.position, height: TableLightRig.heightAboveCloth)
            lampNodes.append(lamp)
            scene.rootNode.addChildNode(lamp)
        }

        // The **ring of small spotlights** round the table: a lamp at every corner of it and the rest evenly
        // spaced down the sides between them, 1 m clear of the frame's own edge and on the same plane as the
        // four big ones, each looking straight down.
        //
        // They are **lamps and not lights**, and that is the point of them. A light inside one of these lays
        // a circle of its own on the carpet — twenty bright circles round the table, each where a lamp is,
        // which is neither a carpet nor a room — and the table is lit already. What a ring of lamps is *for*
        // here is to be **seen**: they stand round the table with their glass alight, and the balls reflect
        // them, which is what the eye reads a rig by. A lamp that houses no light has no cone to throw
        // either, so there is nothing of the ring to fall on the cloth.
        for place in Table3D.ringPlaces {
            let lamp = Table3D.smallSpotLamp()
            lamp.simdPosition = Table3D.point(place, height: TableLightRig.heightAboveCloth)
            ringLampNodes.append(lamp)
            scene.rootNode.addChildNode(lamp)
        }

        // And then look at the room from over the middle of the table and keep the picture: that is
        // what the polished surfaces go on to reflect.
    }

    /// Looks at the room from where the balls are — the height of a ball's middle, because taken from
    /// higher up the reflections show a room seen from above and lose the rails and the cloth a ball
    /// on the table actually has around it — and keeps the picture.
    ///
    /// This is done on the first frame rather than as the scene is built, so that the rack is already
    /// on the table: the balls then reflect each other as well as everything else that is lit.
    private func captureSurroundingsIfNeeded(with driver: FrameDriver) {
        guard reflectionFaces == nil, driver.balls.contains(where: \.onTable) else { return }
        // The plates are left out of the capture, and only the plates. They are three rectangles the size of
        // the table: left in, they come back through the environment as soft bands smeared across the seams
        // of the cube, which is neither right nor recognisable.
        //
        // The **lamps** are left in, which is the point of their being objects rather than lights: a ball
        // under a rig shows the lamps in its reflection — small, sharp and in their own places — and a room
        // whose lamps were missing from the reflections of the things on the table would be a room with the
        // lights turned off in it. It matters most for the ring, which is lamps and nothing else: taken out
        // of the capture, there would be no sign of it anywhere in the room but the lamps themselves.
        let panelsWereHidden = panelNodes.map(\.isHidden)
        for panel in panelNodes { panel.isHidden = true }
        let surroundings = Table3D.captureSurroundings(
            of: scene,
            from: Table3D.point(Vec2(Table.length / 2, Table.width / 2), height: Table.ballRadius)
        )
        for (panel, hidden) in zip(panelNodes, panelsWereHidden) { panel.isHidden = hidden }
        // And it goes to the scene **grey**. The capture is not only a reflection: SceneKit uses the same
        // environment to light everything in the scene that is smooth enough to take it — and that is more
        // than the balls. It is taken from over the middle of the table, so it is mostly green cloth, and it
        // was putting a green sheen on the rails' outer faces, on the frame below them and on the legs:
        // there is no green light in this room, and the wood is lit by the lamps. Taking the colour out of
        // the environment leaves the light it was always meant to be — the room's second light — and leaves
        // the green where it belongs, in the cloth's own colour and in the paint on the balls.
        reflectionEnvironment = surroundings?.strip.greyed()
        reflectionFaces = surroundings?.faces.map { $0.greyed() }
        applyBallReflection()
    }

    /// Renders the scene as the six faces of a cube map and lays them out in a strip — +x, -x, +y,
    /// -y, +z, -z, which is the order SceneKit wants — each 90 degrees of view.
    ///
    /// This is the "second" light: not the lamps themselves but what they have lit. Taken from over
    /// the middle of the table it holds the panels overhead, the cloth and the rails around, and the
    /// dark of the room beyond, and a ball that reflects it shows the table it is sitting on rather
    /// than a highlight and a void.
    ///
    /// SceneKit has a light probe of its own that captures this every frame, but it fills in nothing
    /// when the scene is rendered offscreen — which is how the snapshots are taken, and how this was
    /// checked — so the capture is made here instead, once, and handed to the scene as an image.
    /// The surroundings as the six faces of a cube map, and the same six laid out in a strip for the
    /// probe to measure.
    struct Surroundings {
        var faces: [NSImage]
        var strip: NSImage
    }

    private static func captureSurroundings(of scene: SCNScene, from position: simd_float3) -> Surroundings? {
        // A captured face occasionally comes back empty — a renderer that has not drawn anything yet
        // — and an empty capture is a ball with nothing to reflect. Take it again if it comes out
        // black, and keep whatever the last attempt gives.
        var captured: Surroundings?
        for _ in 0..<3 {
            captured = renderSurroundings(of: scene, from: position)
            if let surroundings = captured, meanBrightness(of: surroundings.strip) > 0.02 { return surroundings }
        }
        return captured
    }

    /// The average brightness of a captured surroundings image, from 0 to 1.
    private static func meanBrightness(of image: NSImage) -> Double {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return 0 }
        var total = 0.0, samples = 0
        for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
            for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                total += Double(c.redComponent + c.greenComponent + c.blueComponent) / 3
                samples += 1
            }
        }
        return samples > 0 ? total / Double(samples) : 0
    }

    /// One attempt at the six faces of the surroundings.
    private static func renderSurroundings(of scene: SCNScene, from position: simd_float3) -> Surroundings? {
        guard let device = MTLCreateSystemDefaultDevice() else { return nil }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene

        let camera = SCNCamera()
        camera.fieldOfView = 90
        camera.zNear = 0.01
        camera.zFar = 60
        camera.wantsHDR = true
        // The capture is taken once and kept, so it has to come out the same every time: no adaptation.
        camera.wantsExposureAdaptation = false
        let node = SCNNode()
        node.camera = camera
        node.simdPosition = position
        scene.rootNode.addChildNode(node)
        renderer.pointOfView = node
        defer { node.removeFromParentNode() }

        // Right, left, up, down, front, back, with an up direction that is not itself along the
        // direction being looked in.
        let faces: [(direction: simd_float3, up: simd_float3)] = [
            (simd_float3(1, 0, 0), simd_float3(0, 1, 0)),
            (simd_float3(-1, 0, 0), simd_float3(0, 1, 0)),
            (simd_float3(0, 1, 0), simd_float3(0, 0, -1)),
            (simd_float3(0, -1, 0), simd_float3(0, 0, 1)),
            (simd_float3(0, 0, 1), simd_float3(0, 1, 0)),
            (simd_float3(0, 0, -1), simd_float3(0, 1, 0)),
        ]

        let side = environmentFaceSize
        // The six faces are drawn into a bitmap of our own rather than into a focused image: drawing
        // through `lockFocus` in a process with no window sometimes comes out blank, and a blank
        // capture is a ball with nothing to reflect.
        guard let strip = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side * faces.count, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: side * faces.count * 4, bitsPerPixel: 32
        ), let context = NSGraphicsContext(bitmapImageRep: strip) else { return nil }

        // Render one frame before the capture, so that the lights' shadow maps have been built. Taken
        // cold, the capture can come out with no shadows in it at all, and then the reflections vary
        // from one run to the next.
        node.look(at: SCNVector3(position + simd_float3(0, -1, 0)),
                  up: SCNVector3(0, 0, 1),
                  localFront: SCNVector3(0, 0, -1))
        _ = renderer.snapshot(atTime: 0, with: CGSize(width: side, height: side), antialiasingMode: .none)

        var rendered: [NSImage] = []
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        for (index, face) in faces.enumerated() {
            node.look(at: SCNVector3(position + face.direction),
                      up: SCNVector3(face.up),
                      localFront: SCNVector3(0, 0, -1))
            let image = renderer.snapshot(atTime: 0,
                                          with: CGSize(width: side, height: side),
                                          antialiasingMode: .none)
            image.draw(in: NSRect(x: index * side, y: 0, width: side, height: side))
            rendered.append(image)
        }
        NSGraphicsContext.restoreGraphicsState()

        let stripImage = NSImage(size: NSSize(width: side * faces.count, height: side))
        stripImage.addRepresentation(strip)
        return Surroundings(faces: rendered, strip: stripImage)
    }

    /// Where a plate faces, and how it is turned down.
    ///
    /// An area light shines along its own `-z`, and an `SCNPlane` is the same rectangle lying in its
    /// `xy` plane, so both want the node turned a quarter turn about the table's long axis to hang
    /// under the ceiling and shine at the cloth. The tilt is then taken off that: a plate is turned
    /// down by dropping its edge away from the middle of the table, which turns its face in towards
    /// the table. In the scene's coordinates that edge is on the `-z` side of the plate, which is why
    /// the tilt is subtracted rather than added.
    private static func panelOrientation(tiltDegrees: Double) -> simd_quatf {
        let quarterTurnDown = -Double.pi / 2
        return simd_quatf(angle: Float(quarterTurnDown - tiltDegrees * .pi / 180),
                          axis: simd_float3(1, 0, 0))
    }

    /// A plate: a white diffuser with a dark edge, lit from behind so that it reads as a light.
    private static func panelMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .constant
        material.diffuse.contents = NSColor(calibratedWhite: 0.97, alpha: 1)
        material.emission.contents = NSColor(calibratedWhite: 0.55, alpha: 1)
        material.isDoubleSided = true
        return material
    }

    // MARK: - The four lamps

    /// A **spot lamp**: the fixture over a corner pocket, which is also the shape of the light itself —
    /// a shallow shade that opens downwards with the glass under its mouth alight, a body above it, and
    /// the little cap the body is finished with. It is built with the **mouth of the shade at its own
    /// origin**, so the caller puts it at the place the light is and the light comes out of the lamp.
    ///
    /// Nothing here casts a shadow: the light is inside this, and a lamp that shadowed its own spotlight
    /// would take the light off the table.
    private static func spotLamp() -> SCNNode {
        let node = SCNNode()
        node.name = "spot lamp"
        node.castsShadow = false

        // The shade: a cone with its wide end down, 96 mm deep and 264 mm across the mouth, which is the
        // shape a spotlight is drawn as. Its own bottom face closes the mouth, and the glass sits under
        // it.
        let shade = SCNCone(topRadius: Table3D.metres(46),
                            bottomRadius: Table3D.metres(132),
                            height: Table3D.metres(96))
        shade.radialSegmentCount = 64
        shade.firstMaterial = Table3D.lampBodyMaterial()
        let shadeNode = SCNNode(geometry: shade)
        shadeNode.castsShadow = false
        shadeNode.simdPosition = simd_float3(0, Table3D.metresF(48), 0)
        node.addChildNode(shadeNode)

        // The glass, just under the mouth and a little narrower than it, so the shade's own rim shows
        // round it and the lamp reads as a lamp rather than as a lit disc. It is the light, so it is
        // drawn unlit.
        let glass = SCNCylinder(radius: Table3D.metres(122), height: Table3D.metres(5))
        glass.radialSegmentCount = 64
        glass.firstMaterial = Table3D.panelMaterial()
        let glassNode = SCNNode(geometry: glass)
        glassNode.castsShadow = false
        glassNode.simdPosition = simd_float3(0, Table3D.metresF(-4), 0)
        node.addChildNode(glassNode)

        // The body: a plain barrel above the shade, and the cap on top of it.
        let barrel = SCNCylinder(radius: Table3D.metres(46), height: Table3D.metres(120))
        barrel.radialSegmentCount = 64
        barrel.firstMaterial = Table3D.lampBodyMaterial()
        let barrelNode = SCNNode(geometry: barrel)
        barrelNode.castsShadow = false
        barrelNode.simdPosition = simd_float3(0, Table3D.metresF(156), 0)
        node.addChildNode(barrelNode)

        let cap = SCNCylinder(radius: Table3D.metres(54), height: Table3D.metres(14))
        cap.radialSegmentCount = 64
        cap.firstMaterial = Table3D.lampBodyMaterial()
        let capNode = SCNNode(geometry: cap)
        capNode.castsShadow = false
        capNode.simdPosition = simd_float3(0, Table3D.metresF(223), 0)
        node.addChildNode(capNode)

        return node
    }

    /// A **small spotlight**: the lamp a ring of them round a table is made of, and a different shape from
    /// the four big ones on purpose.
    ///
    /// The big lamp is a *shade*: a wide cone opening downwards, which is what a lamp hung over a table
    /// looks like from underneath. A ring of those, small, reads as a row of little cones — the shape of a
    /// **can**, which is what a small spotlight is, is a barrel with the glass set in its mouth and a stem
    /// on top to hang it by: a cylinder, a collar at the mouth and a stem, and no cone anywhere in it.
    ///
    /// It is built about the **mouth of the barrel**, like the big lamp, so the caller puts it where the
    /// light is. Nothing in it casts a shadow, for the same reason: the light is inside it.
    private static func smallSpotLamp() -> SCNNode {
        let node = SCNNode()
        node.name = "small spot lamp"
        node.castsShadow = false
        let radius = Furniture.smallLampDiameter / 2

        // The barrel: the body of the can, its mouth at the origin and its length above it.
        let barrel = SCNCylinder(radius: Table3D.metres(radius), height: Table3D.metres(96))
        barrel.radialSegmentCount = 64
        barrel.firstMaterial = Table3D.lampBodyMaterial()
        let barrelNode = SCNNode(geometry: barrel)
        barrelNode.castsShadow = false
        barrelNode.simdPosition = simd_float3(0, Table3D.metresF(48), 0)
        node.addChildNode(barrelNode)

        // The collar at the mouth: a short ring a little wider than the barrel, which is the rim the glass
        // is set back into.
        let collar = SCNCylinder(radius: Table3D.metres(radius + 7), height: Table3D.metres(14))
        collar.radialSegmentCount = 64
        collar.firstMaterial = Table3D.lampBodyMaterial()
        let collarNode = SCNNode(geometry: collar)
        collarNode.castsShadow = false
        collarNode.simdPosition = simd_float3(0, Table3D.metresF(7), 0)
        node.addChildNode(collarNode)

        // The glass, under the collar and a little narrower than it: it is the light, so it is drawn unlit.
        let glass = SCNCylinder(radius: Table3D.metres(radius - 6), height: Table3D.metres(5))
        glass.radialSegmentCount = 64
        glass.firstMaterial = Table3D.panelMaterial()
        let glassNode = SCNNode(geometry: glass)
        glassNode.castsShadow = false
        glassNode.simdPosition = simd_float3(0, Table3D.metresF(-4), 0)
        node.addChildNode(glassNode)

        // The stem it hangs by, and the little knob on the end of it.
        let stem = SCNCylinder(radius: Table3D.metres(11), height: Table3D.metres(44))
        stem.radialSegmentCount = 24
        stem.firstMaterial = Table3D.lampBodyMaterial()
        let stemNode = SCNNode(geometry: stem)
        stemNode.castsShadow = false
        stemNode.simdPosition = simd_float3(0, Table3D.metresF(118), 0)
        node.addChildNode(stemNode)

        let knob = SCNCylinder(radius: Table3D.metres(20), height: Table3D.metres(12))
        knob.radialSegmentCount = 32
        knob.firstMaterial = Table3D.lampBodyMaterial()
        let knobNode = SCNNode(geometry: knob)
        knobNode.castsShadow = false
        knobNode.simdPosition = simd_float3(0, Table3D.metresF(146), 0)
        node.addChildNode(knobNode)

        return node
    }

    /// The metal a lamp is made of: dark, and not shiny — the lamps hang over the table all evening, and
    /// a polished one is a bright thing in the corner of the eye. Rough enough to keep the highlight
    /// broad and dim, and metal enough to read as a fitting rather than as a black shape.
    private static func lampBodyMaterial() -> SCNMaterial {
        let material = SCNMaterial()
        material.lightingModel = .physicallyBased
        material.diffuse.contents = NSColor(calibratedRed: 0.17, green: 0.18, blue: 0.20, alpha: 1)
        material.roughness.contents = 0.62
        material.metalness.contents = 0.35
        material.name = "lamp (dark metal)"
        return material
    }

    private func applyLightScale() {
        for light in plateLights {
            light.intensity = CGFloat(Table3D.plateIntensity * lightScale)
        }
        for light in cornerLights {
            light.intensity = CGFloat(Table3D.cornerLightIntensity * lightScale)
        }
        ambientLight?.intensity = CGFloat(Table3D.ambientIntensity * lightScale)
        applyBallReflection()
    }

    /// Points the polished surfaces at the captured surroundings.
    ///
    /// This has to be the scene's lighting environment: a physically based material ignores its own
    /// `reflective` property — assigning the capture there changes not one pixel of the render — and
    /// SceneKit has no per-material environment. So the whole scene is lit by the capture, which is
    /// no bad thing: it is what puts the light that bounced off the rails back on to the cloth.
    private func applyBallReflection() {
        scene.lightingEnvironment.contents = ballsReflectSurroundings ? reflectionFaces : nil
        scene.lightingEnvironment.intensity = CGFloat(Table3D.environmentIntensity)
    }

    /// What the balls are reflecting, for the offscreen probe: whether anything was captured to
    /// reflect at all, and how strongly it is being reflected.
    var ballReflectionDescription: String {
        let contents = scene.lightingEnvironment.contents
        var brightness = "—"
        if let image = reflectionEnvironment,
           let tiff = image.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff) {
            var total = 0.0, samples = 0
            for y in stride(from: 0, to: rep.pixelsHigh, by: 4) {
                for x in stride(from: 0, to: rep.pixelsWide, by: 4) {
                    guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    total += Double(c.redComponent + c.greenComponent + c.blueComponent) / 3
                    samples += 1
                }
            }
            brightness = samples > 0 ? String(format: "%.3f", total / Double(samples)) : "empty"
        }
        return "reflecting \(contents == nil ? "nothing — no environment captured" : "an environment") at \(scene.lightingEnvironment.intensity), mean brightness \(brightness)"
    }

    /// The six faces of the captured surroundings, for the offscreen probe: the mean colour of each,
    /// and how many bands of light each one holds across its middle. The strip is +x, -x, +y, -y,
    /// +z, -z, so the third face is the one looking **up**, at the lamps: the plates are left out of
    /// the capture and the lamps are not, so what that face holds is the ring and the four over the
    /// table, each lamp a band of its own.
    var capturedSurroundings: [(name: String, mean: (Double, Double, Double), brightBandsAcross: Int, brightBandsDown: Int)] {
        guard let image = reflectionEnvironment,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return [] }
        let side = Table3D.environmentFaceSize
        let names = ["+x", "-x", "+y (the lamps)", "-y (the cloth)", "+z", "-z"]
        return names.enumerated().map { index, name in
            var total = (0.0, 0.0, 0.0)
            var samples = 0
            for y in 0..<side {
                for x in 0..<side {
                    guard let c = rep.colorAt(x: index * side + x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    total.0 += Double(c.redComponent)
                    total.1 += Double(c.greenComponent)
                    total.2 += Double(c.blueComponent)
                    samples += 1
                }
            }
            let count = Double(max(samples, 1))

            /// Bands of light along a line through the face: the plates show up as runs of bright
            /// pixels with dark between them.
            func bands(horizontal: Bool) -> Int {
                var inBand = false, found = 0
                for step in 0..<side {
                    let x = horizontal ? step : side / 2
                    let y = horizontal ? side / 2 : step
                    guard let c = rep.colorAt(x: index * side + x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                    let bright = (Double(c.redComponent) + Double(c.greenComponent) + Double(c.blueComponent)) / 3 > 0.45
                    if bright && !inBand { found += 1 }
                    inBand = bright
                }
                return found
            }

            return (name, (total.0 / count, total.1 / count, total.2 / count),
                    bands(horizontal: true), bands(horizontal: false))
        }
    }

    /// A coarse picture of one face of the captured surroundings, for the offscreen probe: which
    /// panels are in it and where.
    func capturedFaceMap(_ index: Int, columns: Int = 64, rows: Int = 24) -> [String] {
        guard let image = reflectionEnvironment,
              let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else { return [] }
        let side = Table3D.environmentFaceSize
        let ramp = Array(" .:-=+*#%@")
        return (0..<rows).map { row in
            var line = ""
            for column in 0..<columns {
                let x = index * side + column * side / columns + side / columns / 2
                let y = row * side / rows + side / rows / 2
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { line.append(" "); continue }
                let level = (Double(c.redComponent) + Double(c.greenComponent) + Double(c.blueComponent)) / 3
                line.append(ramp[min(ramp.count - 1, max(0, Int(level * Double(ramp.count) * 1.15)))])
            }
            return "  |" + line + "|"
        }
    }

    // MARK: - Per-frame update

    /// Brings the scene up to date: balls, cue, aids and the player's eye.
    /// `watching` is true when somebody else is at the table and the player is only watching: the camera
    /// then stands over the player's **own** feet and follows their own head, and `lookYaw` is which way
    /// that head is turned — where the cue is pointing is not the watcher's business.
    func update(with driver: FrameDriver, dt: Double, watching: Bool = false, lookYaw: Double = 0) {
        captureSurroundingsIfNeeded(with: driver)
        touching = Set(driver.touchingBalls)
        let step = min(max(dt, 1.0 / 240.0), 1.0 / 20.0)
        let cueBallOnTable = driver.cueBall?.onTable ?? false
        let aiming = driver.mode == .aiming || driver.mode == .charging

        // What the last frame drew, so that this one can say whether anything moved: the camera and the
        // cue are the only things here that ease on their own between events (the balls move only while
        // the frame driver is running them, which the scene already knows about). See
        // `thePictureIsStill`.
        let cameraWas = (cameraNode.simdPosition, cameraNode.simdOrientation.vector)
        let cueWas = cueNode.simdPosition

        updateAnchor(with: driver, aiming: aiming, dt: step)
        updateBalls(with: driver, dt: step)
        updateCue(with: driver, dt: step)
        // The aim line and the ghost belong to the cue: with it put away the player is only walking, and
        // there is no shot lined up to draw.
        updateAimingAids(with: driver, aiming: aiming && driver.cueHandling == .laid)
        updateCamera(with: driver, aiming: aiming, cueBallOnTable: cueBallOnTable, dt: step,
                     watching: watching, lookYaw: lookYaw)

        // A ball on its way into a pocket is fading, and a fade is drawn by the renderer rather than by
        // anything here: it counts as moving until it is done.
        thePictureIsStill = markedForDropping.isEmpty
            && simd_distance(cameraWas.0, cameraNode.simdPosition) < 1e-5
            && simd_distance(cameraWas.1, cameraNode.simdOrientation.vector) < 1e-6
            && simd_distance(cueWas, cueNode.simdPosition) < 1e-5
    }

    /// Whether the last frame drew the same picture as the one before it, to a hundredth of a
    /// millimetre and a millionth of a turn. The frame loop stops asking for frames once the picture has
    /// settled; this is what "settled" means, and it is why a drawing that is still is not drawn again.
    private(set) var thePictureIsStill = false

    /// How far the camera and the cue come towards a new place in one frame: a third of the way in a
    /// fortieth of a second, and the same easing whatever the frame rate is. Those two are *positions*
    /// that ease rather than run, so they are moved by the **time** the frame took and not by the frame:
    /// a table drawn at 60 frames a second and one drawn at 120 have to carry the cue and swing the
    /// camera at the same speed, or every change of frame rate would show up as the picture changing gear.
    private static func howFarTheCameraComesIn(over dt: Double) -> Double {
        1 - exp(-max(dt, 0) / 0.033)
    }

    /// Follows the cue ball, but lets go of it during a stroke: a real player stands still and
    /// watches the balls run, rather than walking with them.
    private func updateAnchor(with driver: FrameDriver, aiming: Bool, dt: Double) {
        if driver.mode == .simulating {
            return
        }
        let target: Vec2
        if driver.mode == .placingCueBall || !(driver.cueBall?.onTable ?? false) {
            // Standing behind the D, waiting to place the cue ball.
            target = Table.brownSpot
        } else {
            target = driver.cueBall?.position ?? Table.brownSpot
        }
        guard anchorReady else {
            anchor = target
            anchorReady = true
            return
        }
        if aiming {
            anchor = target
        } else {
            anchor = anchor + (target - anchor) * Table3D.howFarTheCameraComesIn(over: dt)
        }
    }

    private func updateBalls(with driver: FrameDriver, dt: Double) {
        var live = Set<Int>()
        for ball in driver.balls {
            live.insert(ball.id)
            let node: SCNNode
            if let existing = ballNodes[ball.id] {
                node = existing
            } else {
                let sphere = SCNSphere(radius: Table3D.metres(Table.ballRadius))
                sphere.segmentCount = 48
                let material = Table3D.ballMaterial(for: ball.color)
                sphere.firstMaterial = material
                let created = SCNNode(geometry: sphere)
                // A ring on the cloth around the ball, shown when the cue ball is touching it: a
                // referee indicates which ball the cue ball is against (Rule 8(a)), and this is that
                // indication — a call on its own is hard to read off a table of balls.
                // A flat disc lying on the cloth under the ball, wider than the ball: the ball hides
                // its middle and what is left showing is a ring round the ball's foot. A disc rather
                // than a torus because a torus's ring stands in its own plane and barely shows from
                // above, which is where the player is.
                let ring = SCNCylinder(radius: Table3D.metres(Table.ballRadius + 16),
                                       height: Table3D.metres(0.6))
                let ringMaterial = SCNMaterial()
                ringMaterial.lightingModel = .constant
                ringMaterial.diffuse.contents = NSColor(calibratedRed: 1.0, green: 0.85, blue: 0.25, alpha: 1)
                ring.firstMaterial = ringMaterial
                let ringNode = SCNNode(geometry: ring)
                ringNode.simdPosition = simd_float3(0, -Float(Table.ballRadius) / 1000 + 0.0005, 0)
                ringNode.isHidden = true
                ringNode.castsShadow = false
                created.addChildNode(ringNode)
                touchingRings[ball.id] = ringNode

                ballNodes[ball.id] = created
                ballLayer.addChildNode(created)
                node = created
            }

            if ball.onTable {
                markedForDropping.remove(ball.id)
                // A ball can be potted and spotted again before the last of it has faded: the ball
                // coming back is what settles that, not the action finishing.
                node.removeAction(forKey: Table3D.dropAction)
                node.isHidden = false
                node.opacity = 1
                touchingRings[ball.id]?.isHidden = !touching.contains(ball.id)
                node.simdPosition = Table3D.point(ball.position, height: ball.height)
            } else if ball.isFalling {
                // Forced off the table and still in the air: it is drawn where the fall has it and
                // hidden only once it lands. See `PhysicsWorld.fallToTheFloor`.
                markedForDropping.remove(ball.id)
                node.removeAction(forKey: Table3D.dropAction)
                node.isHidden = false
                node.opacity = 1
                touchingRings[ball.id]?.isHidden = true
                node.simdPosition = Table3D.point(ball.position, height: ball.height)
            } else if !markedForDropping.contains(ball.id) {
                markedForDropping.insert(ball.id)
                node.simdPosition = Table3D.point(ball.position, height: ball.height)
                drop(node)
            }
        }
        for (id, node) in ballNodes where !live.contains(id) {
            node.isHidden = true
        }
    }

    /// Sees off a ball that has dropped into its pocket.
    ///
    /// The fall is the simulation's own, and a pocket is deeper than a ball is wide: by the time a
    /// ball is potted the physics has run it down past the well, and the body of the table is drawn
    /// solid behind it, so nothing of the ball is in sight. It is taken away from the bottom of the
    /// pocket here — the short fade is for the odd angle where a corner of it might still show —
    /// rather than made to fade out where it can be watched doing it.
    private func drop(_ node: SCNNode) {
        node.runAction(.sequence([.wait(duration: 0.05), .fadeOut(duration: 0.2)]),
                       forKey: Table3D.dropAction) {
            node.isHidden = true
            node.opacity = 1
        }
    }

    private func updateCue(with driver: FrameDriver, dt: Double) {
        guard let cue = driver.cueBall, cue.onTable, !driver.isFrameOver else {
            cueNode.isHidden = true
            return
        }
        // With the cue put away the player is only walking about: there is no cue on the table to draw.
        guard driver.cueHandling == .laid else {
            cueNode.isHidden = true
            return
        }
        // Where the cue is held for this stroke: where the shot was played from. It is taken down here,
        // before anything is drawn, because while the *physical* cue is on the table the drawing returns
        // early below — and the hold has to be the shot's own place, not wherever the ball has got to by
        // the time the player stands up and hands the drawing back to the aim.
        if driver.mode == .simulating, cueHold == nil {
            cueHold = (driver.strokeWasPlayedFrom, driver.aimAngle)
        }
        // Once the shot is away the stick is a thing on the table the player keeps moving, so it is
        // drawn where the physics has it — where the mouse has taken it — rather than from the aim.
        if driver.mode == .simulating, let struck = driver.cueOnTheTable {
            cueNode.isHidden = false
            cueNode.simdPosition = Table3D.point(Vec2(struck.tip.x, struck.tip.y), height: struck.tip.z)
            // The node's own +x runs from the butt to the tip; the scene's axes are the table's, with
            // the third across the table: see `Table3D.point`.
            cueNode.simdOrientation = simd_quatf(
                from: simd_float3(1, 0, 0),
                to: simd_float3(Float(struck.axis.x), Float(struck.axis.z), Float(-struck.axis.y)))
            cueTipWorld = cueNode.simdPosition
            return
        }
        cueNode.isHidden = false

        // How far the player hits the ball: the tip's own height on the ball's face, and the angle the
        // cue stands at — both of which the rest of this function needs for the cue's own lean.
        let up = driver.spinVertical * Table.ballRadius          // follow positive
        let lift = PhysicsWorld.cueLean(at: driver.cueElevation)

        // The cue stands where the hand — the player's or the game's own — has drawn it, and nowhere else:
        // while a charge is in hand the meter fills and the cue **does not move** (it stands at its rest
        // place off the ball, which is where the stroke will be played from), and once the button is let go
        // the charged shot's own cue action draws it back and brings it through. The **follow-through** is
        // not drawn from here: once the shot is away the stick is the physics' own and is drawn where it
        // has been carried (the simulation above returns), capped at `FrameDriver.maxFollowThrough` — see
        // `FrameDriver.carryTheCue`.
        var gap = Table.cueTipGap
        if driver.mode == .charging, driver.isMovingTheCue { gap = Table.cueTipGap + driver.cueDraw }

        // The cue stays where the stroke was played while the balls run — the player does not walk
        // after them, and standing up does not lay the stick at the ball either: it is left on the
        // table at the shot's own place until the stroke is over. It is then carried to the next shot
        // rather than jumping there, which is when it is laid at the ball again.
        var goal = (cue.position, driver.aimAngle)
        if driver.mode == .simulating {
            goal = cueHold ?? goal
        } else {
            cueHold = nil
        }
        if let anchor = cueAnchor {
            cueAnchor = (anchor.position
                         + (goal.0 - anchor.position) * Table3D.howFarTheCameraComesIn(over: dt), goal.1)
        } else {
            cueAnchor = goal
        }
        let carried = cueAnchor ?? goal
        // The cue meets the ball where the player is hitting it. With spin set, the tip is off the
        // middle of the ball — a fraction of its radius, so up to half a ball to either side — and
        // the cue leans in towards that point with its butt at the hand, which is the same lean that
        // makes a ball squirt away from the side it was struck.
        let aim = Vec2(cos(carried.yaw), sin(carried.yaw))
        // The striker's right, whichever way they are facing: the aim turned a quarter turn. It has
        // to be taken off the aim — a fixed direction across the table puts the tip on the wrong
        // side of the ball as soon as the shot is played towards the other end.
        let right = Vec2(aim.y, -aim.x)
        let across = driver.spinSide * Table.ballRadius           // to the striker's right, in millimetres
        cueTipOffset = (across: across, up: up)
        cueTipWorldOffset = right * across
        let along = Table3D.cueSections.map(\.back).max() ?? 1400
        let lean = atan2(across, along)      // about the vertical, towards the striker's right
        let tilt = atan2(up, along)          // about the horizontal, upwards for follow

        // The cue is a stick and not a shadow, and the 3D view draws it where the physics will let it
        // lie: it is never drawn through the thing behind it, so it stands off only as far as there is
        // room to draw it back. See `PhysicsWorld.cueFits`.
        if driver.mode != .simulating {
            gap = min(gap, Table.cueTipGap + driver.maximumCueDraw)
        }

        // The node's own frame has +x along the cue towards the tip, +z to the striker's right and +y
        // up, so the lean is a turn about y and the tilt a turn about z, taken off the line of aim.
        // The lift goes on the tilt: standing the cue up turns +x, which points at the ball, downwards.
        cueNode.simdOrientation = simd_quatf(angle: Float(carried.yaw) - Float(lean), axis: simd_float3(0, 1, 0))
            * simd_quatf(angle: Float(tilt) - Float(lift), axis: simd_float3(0, 0, 1))
        // The tip sits on the surface of the ball, where the player is aiming it, and the cue stands
        // off from that by `gap`: measured from the middle of the ball, the tip is out at the ball's
        // radius plus the gap along the cue's own axis, which is shorter than that along the line of
        // aim when the tip is off to a side or the cue is stood up.
        let reach = Table.ballRadius + gap
        let surface = max(0, reach * reach - across * across - up * up).squareRoot()
        let tipOnTheBall = Table3D.point(carried.position, height: Table.ballRadius)
        // The cue's own frame in the scene: its axis towards the ball, and the face square to it — up
        // the face, which leans with the cue, and to the striker's right.
        let axis = simd_float3(Float(aim.x * cos(lift)), Float(-sin(lift)), Float(-aim.y * cos(lift)))
        let faceUp = simd_float3(Float(aim.x * sin(lift)), Float(cos(lift)), Float(-aim.y * sin(lift)))
        let faceRight = simd_float3(Float(right.x), 0, Float(-right.y))
        cueNode.simdPosition = tipOnTheBall
            + faceUp * Table3D.metresF(up)
            + faceRight * Table3D.metresF(across)
            - axis * Table3D.metresF(surface)
        cueTipWorld = cueNode.simdPosition
        cueTipDistance = gap
    }

    private func updateAimingAids(with driver: FrameDriver, aiming: Bool) {
        let visible = aimingAids != .off && aiming
        aimLayer.isHidden = !visible
        guard visible, let cue = driver.cueBall, cue.onTable else { return }

        let contact = driver.predictedFirstContact()
        let end = contact?.point ?? (cue.position + Vec2(cos(driver.aimAngle), sin(driver.aimAngle)) * 1200)
        let length = max(1, (end - cue.position).length)
        aimLineNode.simdPosition = Table3D.point((cue.position + end) / 2, height: Table.ballRadius)
        aimLineNode.simdScale = simd_float3(1, Table3D.metresF(length), 1)
        aimLineNode.simdOrientation = simd_quatf(angle: Float(driver.aimAngle), axis: simd_float3(0, 1, 0))
            * simd_quatf(angle: -.pi / 2, axis: simd_float3(0, 0, 1))
        ghostNode.isHidden = contact == nil
        if let contact {
            ghostNode.simdPosition = Table3D.point(contact.point, height: Table.ballRadius)
        }
        drawTheLineOfTheBallBeingMet(with: driver, contact: contact)
    }

    /// The line the ball being aimed at will take after the contact.
    ///
    /// A cue ball meeting an object ball sends it away along the **line of centres** between them at
    /// the moment they touch — from the ghost ball's middle through the object ball's — so the line is
    /// drawn from that ball's own middle, that way, `aimedBallLineLength` long. Nothing is shown when
    /// the shot meets a cushion instead, or when the aids are set to the cue's line alone.
    private func drawTheLineOfTheBallBeingMet(
        with driver: FrameDriver,
        contact: (point: Vec2, contact: FrameDriver.AimContact)?
    ) {
        guard aimingAids == .both,
              let contact, case .ball(let id) = contact.contact,
              let ball = driver.balls.first(where: { $0.id == id && $0.onTable }) else {
            ballLineNode.isHidden = true
            return
        }
        let away = ball.position - contact.point
        guard away.length > 1e-6 else {
            ballLineNode.isHidden = true
            return
        }
        let direction = away.normalized
        let length = Table3D.aimedBallLineLength
        ballLineNode.isHidden = false
        // **Red** if the ball it belongs to is not one the cue ball may strike first: the shot is a foul
        // before it is played, and the line says so. See `SnookerGame.legalFirstContacts`.
        ballLineNode.geometry?.firstMaterial =
            driver.game.legalFirstContacts().contains(id) ? ballLineMaterial : ballLineFoulMaterial
        ballLineNode.simdPosition = Table3D.point(ball.position + direction * (length / 2),
                                                  height: Table3D.markingHeightAboveCloth)
        ballLineNode.simdScale = simd_float3(Table3D.metresF(length), 1, 1)
        // The stripe's own +x runs along it, and a turn about the table's upright takes that to the
        // direction the ball will go — the same turn the line of aim takes off the aim angle.
        ballLineNode.simdOrientation = simd_quatf(angle: Float(atan2(direction.y, direction.x)),
                                                  axis: simd_float3(0, 1, 0))
    }

    private func updateCamera(with driver: FrameDriver, aiming: Bool, cueBallOnTable: Bool, dt: Double,
                              watching: Bool, lookYaw: Double) {
        // When the player has the cue ball in hand the camera drops back to a standing view of
        // the D, so the whole of it is on screen to click into.
        let placing = driver.mode == .placingCueBall || !cueBallOnTable
        let upright = preset == .sighting ? PlayerCamera.Preset.standing : preset

        // The player stands at the table and gets down over the ball to play, so the camera is moved
        // between the two framings rather than snapped between presets: taking the cue up — the S cue
        // action, or holding a charge — brings them down over the shot, and the stroke stands them up
        // again once the balls have stopped.
        // A watcher is never down on the shot, whatever the player who *is* at the table is doing with the
        // cue: the shot being played is not theirs to get down over.
        let downOnTheShot = !placing && !watching && driver.isDownOnTheShot
        if let held = heldFraming {
            body = held == .sighting ? 1 : 0
        } else {
            body += ((downOnTheShot ? 1 : 0) - body) * (1 - exp(-dt / 0.12))
        }
        // The cue's lift comes into the framing too: down on the shot the player's head rides the cue,
        // so a cue stood up for a swerve stands the player up with it. See `PlayerViewSolver.sighting`.
        let framing = PlayerViewSolver.framing(from: upright, to: .sighting, body,
                                               elevation: driver.cueElevation)

        let preset: PlayerCamera.Preset = placing ? .standing : upright
        let yaw = placing ? 0 : (watching ? lookYaw : driver.aimAngle)
        // The gaze the player has chosen, plus however much the body has tilted getting down.
        let pitch = placing
            ? PlayerCamera.Preset.standing.pitch
            : self.pitch + (framing.pitch - upright.pitch)

        // Where the eye is. **Up and about with the cue put away**, it is over the player's own feet
        // and the mouse looks about; **with the cue laid** — and down on the shot — it comes round the
        // cue, `standOff` back from the ball on the line of aim, which is the circle the player walks as
        // they swing the cue. The body stays outside the table either way; down on the shot the eye may
        // lean in over the cushion, but no further than the eye-to-waist reach.
        // Whether the player is down over the shot comes from the body rather than the mode, so a
        // held framing is honoured: it is the body that decides whether the eye may lean in.
        let leaning = body > 0.5
        let walking = !placing && !leaning && (driver.cueHandling == .putAway || watching)
        let eye: Vec2
        let eyeHeight: Double
        if walking {
            eye = driver.playerPosition
            // Crouched down over the cloth the eye comes to the height a player ducks to, and it is the
            // **eye** that comes down: their feet, their line of sight and their walk all carry on.
            eyeHeight = isCrouching ? PlayerCamera.crouchEyeHeight : framing.eyeHeight
        } else {
            // Exactly above the cue, at `standOff` back from the ball along the line of aim — and the
            // stand-off is what gives way when the player could not stand there: walking up to the
            // table the body has to be clear of the wood, down on the shot the lean has to keep the eye
            // within the eye-to-waist reach of the side. Nothing shifts sideways: the distance comes
            // off the line, so the camera is always over the cue.
            let away = Vec2(-cos(yaw), -sin(yaw))
            let clearance = leaning
                ? PlayerWalk.leaningStandOff(from: anchor, away: away)
                : PlayerWalk.clearStandOff(from: anchor, away: away)
            eye = anchor + away * max(framing.standOff, clearance)
            eyeHeight = framing.eyeHeight
        }

        let solved = PlayerViewSolver.camera(eye: eye, eyeHeight: eyeHeight, yaw: yaw, pitch: pitch,
                                             fieldOfView: framing.fieldOfView)
        cameraOnTheTable = (solved.eye, solved.eyeHeight)
        let eyeInTheScene = Table3D.point(solved.eye, height: solved.eyeHeight)
        // Up and about the player looks where they like; over a shot the gaze closes back onto the line
        // of aim, converging up the table the way a player sights down the cue.
        let gaze = walking
            ? solved.gazePoint(distance: 3000)
            : solved.convergencePoint(aimLinePoint: anchor, converge: preset.converge)

        if cameraReady {
            let ease = Float(1 - exp(-dt / 0.08))
            cameraNode.simdPosition = cameraNode.simdPosition + (eyeInTheScene - cameraNode.simdPosition) * ease
        } else {
            cameraNode.simdPosition = eyeInTheScene
            cameraReady = true
        }
        cameraNode.look(at: SCNVector3(Table3D.point(gaze.position, height: gaze.height)),
                        up: SCNVector3(0, 1, 0),
                        localFront: SCNVector3(0, 0, -1))
        gazePoint3 = Table3D.point(gaze.position, height: gaze.height)
        cameraNode.camera?.fieldOfView = CGFloat(framing.fieldOfView)
        cameraNode.camera?.exposureOffset = CGFloat(exposureOffset)
        applyLightScale()
    }

    // MARK: - Input helpers

    /// Changes camera position, keeping the gaze where it is.
    func use(_ preset: PlayerCamera.Preset) {
        self.preset = preset
        pitch = preset.pitch
    }

    /// Pins the player's body where a capture wants it, and lets go with nil. Only the offscreen
    /// captures use it.
    func holdFraming(_ level: PlayerCamera.Preset?) {
        heldFraming = level
    }

    /// Raises or lowers the gaze, within the range a player can actually hold.
    func setPitch(_ value: Double) {
        pitch = PlayerViewSolver.clampPitch(value)
    }

    /// The camera's three axes, as they stand.
    private func cameraBasis() -> (eye: simd_float3, forward: simd_float3, right: simd_float3, up: simd_float3, tanHalf: Float, aspect: Float)? {
        guard let camera = cameraNode.camera else { return nil }
        // Read the axes off the camera rather than rebuild them, so this holds however the camera
        // is placed — including looking straight down, where "the world's up" says nothing.
        let transform = cameraNode.simdTransform
        let right = simd_normalize(simd_float3(transform.columns.0.x, transform.columns.0.y, transform.columns.0.z))
        let up = simd_normalize(simd_float3(transform.columns.1.x, transform.columns.1.y, transform.columns.1.z))
        let forward = -simd_normalize(simd_float3(transform.columns.2.x, transform.columns.2.y, transform.columns.2.z))
        return (cameraNode.simdPosition, forward, right, up,
                tanf(Float(camera.fieldOfView) * .pi / 360), aspectRatio)
    }

    /// Aspect ratio the camera is currently framing.
    private var aspectRatio: Float {
        guard let view, view.bounds.height > 0 else { return 16.0 / 9.0 }
        return Float(view.bounds.width / view.bounds.height)
    }

    /// The point on the cloth under a point in the view, for placing the cue ball. The ray is
    /// built from the camera itself rather than from SceneKit's unprojection, so it agrees exactly
    /// with `project(_:imageSize:)` and with what is on screen.
    func tablePoint(at viewPoint: CGPoint, viewSize: CGSize) -> Vec2? {
        guard viewSize.width > 0, viewSize.height > 0, let basis = cameraBasis() else { return nil }
        let ndcX = Float(viewPoint.x / viewSize.width) * 2 - 1
        let ndcY = Float(viewPoint.y / viewSize.height) * 2 - 1
        let direction = simd_normalize(basis.forward
            + basis.right * (ndcX * basis.tanHalf * aspectRatio)
            + basis.up * (ndcY * basis.tanHalf))
        guard abs(direction.y) > 1e-6 else { return nil }
        let distance = -basis.eye.y / direction.y
        guard distance > 0 else { return nil }
        return Table3D.tablePoint(basis.eye + direction * distance)
    }

    /// Projects a scene point onto the rendered image — origin at the top left — using the camera
    /// as it stands, so the snapshot harness can check where things land.
    func project(_ world: simd_float3, imageSize: CGSize) -> CGPoint? {
        guard let basis = cameraBasis() else { return nil }
        let relative = world - basis.eye
        let depth = simd_dot(relative, basis.forward)
        guard depth > 0.05 else { return nil }
        let horizontal = simd_dot(relative, basis.right)
        let vertical = simd_dot(relative, basis.up)
        let aspect = Float(imageSize.width / imageSize.height)
        let x = (horizontal / depth) / (basis.tanHalf * aspect)
        let y = (vertical / depth) / basis.tanHalf
        guard x.isFinite, y.isFinite else { return nil }
        return CGPoint(x: CGFloat(x * 0.5 + 0.5) * imageSize.width,
                       y: CGFloat(1 - (y * 0.5 + 0.5)) * imageSize.height)
    }

    /// Where a given ball sits in the scene.
    static func scenePoint(for ball: Ball) -> simd_float3 {
        point(ball.position, height: Table.ballRadius)
    }

    /// Where a point on the cloth — or at a height above it — sits in the scene.
    static func scenePoint(_ clothPoint: Vec2, height: Double = 0) -> simd_float3 {
        point(clothPoint, height: height)
    }

    // MARK: - Offscreen rendering (for snapshots)

    /// Renders the current scene with an offscreen renderer, using the same scene graph the
    /// view shows.
    func renderImage(size: CGSize, device: MTLDevice) -> NSImage {
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false
        return renderer.snapshot(atTime: 0, with: size, antialiasingMode: Table3D.antialiasing)
    }

    /// Runs `body` with the camera looking straight down at the table, so the shape of the
    /// furniture can be checked offscreen. Used by the snapshot harness.
    ///
    /// The fixture goes with it: from straight above, the plates and the four lamps stand between the
    /// camera and the cloth, and a look at the furniture is a look at the furniture. Their lights stay.
    func withOverheadCamera<T>(_ body: () throws -> T) rethrows -> T {
        let transform = cameraNode.simdTransform
        let fov = cameraNode.camera?.fieldOfView ?? 50
        let gaze = gazePoint3
        // Straight down, with the engine's x to the right and its y up, as in the top-down view.
        cameraNode.simdPosition = simd_float3(0, 4.4, 0)
        gazePoint3 = simd_float3(0, 0, 0)
        cameraNode.look(at: SCNVector3(0, 0, 0), up: SCNVector3(0, 0, -1), localFront: SCNVector3(0, 0, -1))
        cameraNode.camera?.fieldOfView = 34
        let fixturesWereHidden = fixtureNodes.map(\.isHidden)
        for fixture in fixtureNodes { fixture.isHidden = true }
        defer {
            cameraNode.simdTransform = transform
            gazePoint3 = gaze
            cameraNode.camera?.fieldOfView = fov
            for (fixture, hidden) in zip(fixtureNodes, fixturesWereHidden) { fixture.isHidden = hidden }
        }
        return try withTableOnly(body)
    }

    /// One plate of the light rig, as the renderer has it: where it hangs, how big it is, and how far
    /// it is turned down. Read by the offscreen probe, which cannot measure a 20 mm gap in a picture.
    struct PlacedPlate {
        /// The middle of the plate, in scene metres.
        var position: simd_float3
        /// The size of the plate, in metres: its first value along the table, the second across it.
        var size: (alongTable: Double, acrossTable: Double)
        /// How far the plate is turned down, in degrees, as `TableLightRig` means it.
        var tiltDegrees: Double
        /// The direction the plate faces, in scene coordinates.
        var normal: simd_float3
    }

    /// The floor of the room as it was built: how big it is, where its face is, and what it is made of.
    /// Read by the offscreen probe, which cannot measure a seven-metre slab in a picture.
    struct FloorFacts {
        var length: Double
        var width: Double
        var top: Double
        var thickness: Double
        /// What the floor is covered with, as the material names it.
        var covering: String
        var lightingModel: String
        var roughness: Double
        var metalness: Double
    }

    /// The floor, read back off the built scene.
    var floorFacts: FloorFacts {
        let node = scene.rootNode.childNode(withName: "floor", recursively: false)
        let box = node?.geometry as? SCNBox
        let material = box?.firstMaterial
        let height = Double(box?.height ?? 0) * 1000
        return FloorFacts(
            length: Double(box?.width ?? 0) * 1000,
            width: Double(box?.length ?? 0) * 1000,
            top: Double(node?.simdWorldPosition.y ?? 0) * 1000 + height / 2,
            thickness: height,
            covering: material?.name ?? "none",
            lightingModel: material?.lightingModel.rawValue ?? "none",
            roughness: Double(material?.roughness.contents as? Double ?? 0),
            metalness: Double(material?.metalness.contents as? Double ?? 0)
        )
    }

    /// Where the six legs stand, in the table's own coordinates. Read by the offscreen probe, which
    /// checks that there are six of them and that every one stands under the frame.
    var legPlaces: [Vec2] { Table3D.legPillars }

    /// Where the twenty small lamps of the ring stand, in the table's own coordinates. Read by the
    /// offscreen probe, which checks the ring's clearance to the table and that a lamp stands at each
    /// of the four corners.
    var ringLampPlaces: [Vec2] { Table3D.ringPlaces }
    /// The four corners of the ring's rectangle.
    var ringCorners: [Vec2] { Table3D.ringCorners }
    /// The rectangle the ring runs round, and how far apart its lamps are, in millimetres. The rectangle
    /// is the table's own outer edge with `ringClearance` of floor outside it.
    var ringRectangle: (length: Double, width: Double) {
        (Table.length + 2 * (Table3D.outerX + Furniture.ringClearance),
         Table.width + 2 * (Table3D.outerX + Furniture.ringClearance))
    }
    /// How far apart the lamps are down a long side and across a short one.
    var ringPitch: (along: Double, across: Double) {
        (ringRectangle.length / Double(Furniture.ringDivisionsAlong),
         ringRectangle.width / Double(Furniture.ringDivisionsAcross))
    }

    /// Where the four lamps hang, in scene metres. Read by the offscreen probe, which checks them
    /// against the four spot lights: a lamp is there because its light is.
    var lampPositions: [simd_float3] { lampNodes.map(\.simdWorldPosition) }

    /// The three plates as they were built, in the order `TableLightRig.plates` gives them.
    var placedPlates: [PlacedPlate] {
        panelNodes.compactMap { node in
            guard let plane = node.geometry as? SCNPlane else { return nil }
            // The plate's own face looks along its node's -z, so the angle that face makes with
            // straight down is the tilt.
            let normal = node.simdWorldOrientation.act(simd_float3(0, 0, -1))
            let down = max(-1, min(1, -Double(normal.y)))
            return PlacedPlate(position: node.simdWorldPosition,
                               size: (Double(plane.width), Double(plane.height)),
                               tiltDegrees: acos(down) * 180 / .pi,
                               normal: normal)
        }
    }

    /// Looks from somewhere the player never stands — under the light rig, or end on to it — for the
    /// probe that checks the fixture. Positions are in scene metres.
    func withCamera<T>(_ position: simd_float3,
                       lookingAt target: simd_float3,
                       fieldOfView: Double,
                       _ body: () throws -> T) rethrows -> T {
        let transform = cameraNode.simdTransform
        let fov = cameraNode.camera?.fieldOfView ?? 50
        cameraNode.simdPosition = position
        cameraNode.look(at: SCNVector3(target), up: SCNVector3(0, 0, -1), localFront: SCNVector3(0, 0, -1))
        cameraNode.camera?.fieldOfView = CGFloat(fieldOfView)
        defer {
            cameraNode.simdTransform = transform
            cameraNode.camera?.fieldOfView = fov
        }
        return try body()
    }

    /// Hides the cue and the aiming aids, leaving the balls: a close look at one ball would otherwise
    /// be a close look at whichever of them the cue happens to be standing in front of.
    func withBallsOnly<T>(_ body: () throws -> T) rethrows -> T {
        let hidden = (cueLayer.isHidden, aimLayer.isHidden)
        cueLayer.isHidden = true
        aimLayer.isHidden = true
        defer { (cueLayer.isHidden, aimLayer.isHidden) = hidden }
        return try body()
    }

    /// Hides the balls, cue and aiming aids, which only get in the way of checking the furniture.
    func withTableOnly<T>(_ body: () throws -> T) rethrows -> T {
        let hidden = (ballLayer.isHidden, cueLayer.isHidden, aimLayer.isHidden)
        ballLayer.isHidden = true
        cueLayer.isHidden = true
        aimLayer.isHidden = true
        defer { (ballLayer.isHidden, cueLayer.isHidden, aimLayer.isHidden) = hidden }
        return try body()
    }

    /// Hides the markings on the cloth, so they can be picked out of a render by difference.
    func withMarkingsHidden<T>(_ body: () throws -> T) rethrows -> T {
        let hidden = markingLayer.isHidden
        markingLayer.isHidden = true
        defer { markingLayer.isHidden = hidden }
        return try body()
    }
}

extension BallColor {
    /// The colour a ball is painted in the 3D view.
    var nsColor: NSColor {
        switch self {
        case .red: return NSColor(calibratedRed: 0.74, green: 0.07, blue: 0.08, alpha: 1)
        case .yellow: return NSColor(calibratedRed: 0.95, green: 0.78, blue: 0.06, alpha: 1)
        case .green: return NSColor(calibratedRed: 0.04, green: 0.42, blue: 0.14, alpha: 1)
        case .brown: return NSColor(calibratedRed: 0.43, green: 0.24, blue: 0.07, alpha: 1)
        case .blue: return NSColor(calibratedRed: 0.06, green: 0.22, blue: 0.74, alpha: 1)
        case .pink: return NSColor(calibratedRed: 0.96, green: 0.47, blue: 0.63, alpha: 1)
        case .black: return NSColor(calibratedWhite: 0.05, alpha: 1)
        case .white: return NSColor(calibratedWhite: 0.97, alpha: 1)
        }
    }

    /// Cushions are covered in the same cloth as the bed, but darker.
    var cushionNSColor: NSColor {
        switch self {
        case .green: return NSColor(calibratedRed: 0.04, green: 0.30, blue: 0.13, alpha: 1)
        default: return .green
        }
    }
}

extension NSImage {
    /// This image with the colour taken out of it: every pixel set to its own brightness.
    func greyed() -> NSImage { Table3D.greyedImage(self) }
}
