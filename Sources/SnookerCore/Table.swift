import Foundation

/// Ball colours and their values, per Section 3 Rule 1(a) of the WPBSA rules.
public enum BallColor: String, CaseIterable, Codable, Sendable {
    case red, yellow, green, brown, blue, pink, black, white

    /// Point value. The cue ball (white) is not an object ball and has no value.
    public var value: Int {
        switch self {
        case .red: return 1
        case .yellow: return 2
        case .green: return 3
        case .brown: return 4
        case .blue: return 5
        case .pink: return 6
        case .black: return 7
        case .white: return 0
        }
    }

    public var isColour: Bool { self != .red && self != .white }

    /// The six colours in ascending order (Section 3 Rule 3(h)(iii)).
    public static let coloursInAscendingOrder: [BallColor] = [.yellow, .green, .brown, .blue, .pink, .black]
}

/// Table geometry, from Section 1 Rule 1 of the WPBSA rules.
///
/// Coordinates are millimetres in the table plane:
///   x = 0 at the face of the Bottom (Baulk) cushion, increasing to the Top cushion;
///   y = 0 at one side cushion, increasing to the other.
/// A player standing at the baulk end looking down the table has `y = 0` on their right,
/// which is why the Yellow Spot is at the lower y of the two "D" corners.
public enum Table {
    /// Playing area within the cushion faces: 3569 mm x 1778 mm.
    public static let length: Double = 3569.0
    public static let width: Double = 1778.0

    /// Balls: 52.5 mm diameter (Section 1 Rule 2(b)).
    public static let ballDiameter: Double = 52.5
    public static let ballRadius: Double = 26.25

    /// How far below the cloth the floor of the room stands, in millimetres: a snooker table's bed is
    /// about 800 mm above the floor, which is what a ball forced off the table has to fall before it
    /// lands — and, having landed, is gone. See `PhysicsWorld.fallToTheFloor`.
    public static let floorHeight: Double = -800

    /// How close two balls have to be, over and above their diameter, to count as touching.
    ///
    /// Two balls touch when the distance between their centres is the ball's diameter, and the solver
    /// leaves a ball that has rolled up against another at *exactly* that: it pushes any overlap out
    /// every step, so a resting contact is 52.5 mm to the last place the arithmetic holds. The margin
    /// is there for that arithmetic and nothing else — a twentieth of a millimetre, a thousandth of a
    /// ball's diameter — so a ball that is genuinely a sliver clear of another is not called touching.
    public static let touchingTolerance: Double = 0.05
    public static let ballMass: Double = 0.142  // kg, typical 142 g snooker ball

    // MARK: The cue

    /// A cue, tip to butt: about 1400 mm, which is what a snooker cue measures.
    ///
    /// The cue is a stick and not a shadow: it cannot pass through a ball, a cushion or the rail, so its
    /// length and its own girth are what decide whether there is room behind the cue ball to play at
    /// all. See `PhysicsWorld.cueFits`.
    public static let cueLength: Double = 1400.0
    /// How far the tip stands off the ball at rest, in millimetres: the cue's rest position, which the
    /// player draws it back from.
    public static let cueTipGap: Double = 30.0
    /// The cue's girth: **one taper, and one rate of change to it**, from the tip to the butt.
    ///
    /// A snooker cue is a very long cone — 9.8 mm across the tip and about 22 mm across the butt — with
    /// its side a **straight line** between the two. The stick is dressed in sections, tip and ferrule,
    /// shaft, joint, butt and bumper, but those are lengths *of* one taper and not steps in it: a step
    /// anywhere along the cue shows as a kink in its side, and the side of a cue is the line a player
    /// sights down.
    public static let cueTipRadius: Double = 4.9
    public static let cueButtRadius: Double = 11.0

    /// How fat the cue is `distance` millimetres back from the tip: the straight taper, at one rate from
    /// end to end. The picture and the physics both take their girth from here, so the stick that is
    /// judged and the stick that is drawn are one stick.
    public static func cueRadius(at distance: Double) -> Double {
        cueTipRadius + (cueButtRadius - cueTipRadius) * min(1, max(0, distance / cueLength))
    }

    /// The cue's girth along its length, tip first: how fat the stick is, length by length.
    ///
    /// The cue is not a line: a stick has to be judged as the body it is rather than as the shadow down
    /// its middle — a shaft can pass where a butt cannot — so each length of it is given its **widest**
    /// measurement here, which is where the stick is thickest and so where it first fouls.
    ///
    /// The lengths are **short** — a slice every `cueSlice` — because the taper is continuous and each of
    /// them is judged at its own widest point. Long lengths were right when the stick was drawn in
    /// sections, and they are wrong now: a shaft-length slice of a straight taper is judged at the
    /// thickness of its *back* end along the whole of its front, so the thin end of the cue would be made
    /// to keep the room the fat end needs, and the game would stand the butt up for shots that have room
    /// for the stick the player is actually holding.
    public static let cueSlice: Double = 25.0
    public static let cueGirth: [(front: Double, back: Double, radius: Double)] = {
        var lengths: [(front: Double, back: Double, radius: Double)] = []
        var front = 0.0
        while front < cueLength {
            let back = min(cueLength, front + cueSlice)
            lengths.append((front: front, back: back, radius: cueRadius(at: back)))
            front = back
        }
        return lengths
    }()
    /// The tip is not flat: it is a dome, with this radius of curvature. It is what a player chalks and
    /// what meets the ball — a spherical cap, about 1 mm deeper at its crown than at its rim across the
    /// 9.8 mm the tip is wide.
    ///
    /// The game plays the strike as the impulse of a tip that flattens against the ball (see
    /// `PhysicsWorld.applyCueStrike`), so the dome is not what angles the shot. What it does do is
    /// decide when the tip has *touched something*: a cue driven on into the cloth or a cushion stops
    /// when the dome reaches it, and the lowest point of the dome is not the crown once the cue is
    /// stood up. See `PhysicsWorld.theTipReachesDownTo`.
    public static let cueTipCurvature: Double = 12.0
    /// How far up the cue stands with the player's lift at its lowest: the angle their own stance gives
    /// it, and the floor the elevation control works from.
    ///
    /// It is the cue's **own angle**, not an offset hidden inside the model: the elevation the player
    /// sets is the angle of the stick, the widget reads that angle off, and the strike is played along
    /// it. The bottom of the lift is **level**: a cue may be held flat, and on the open table that is
    /// what a player does.
    ///
    /// It still matters, because a cue lying flat fouls the near cushion on almost any shot: a
    /// cushion's top stands 38.3375 mm up and a flat cue runs at the middle of the ball, 26.25 mm, so
    /// the stick would have to pass through the cushion and the wood of the rail behind it to reach the
    /// player's hand. The game does not refuse the shot for it and does not hold the cue up on the
    /// player's behalf: it **settles** the cue where it fits (`FrameDriver.settleTheCue`), lifting the
    /// butt — and topping the ball, if it must — only for the shots where the obstruction is plain to
    /// the eye, with the cue ball close to a cushion or a ball close behind it. What the floor is
    /// really for is the *aim*: a level cue is a line at the height of the ball's middle, which is
    /// what the player is sighting along.
    public static let cueStanceElevationDegrees: Double = 0
    /// `cueStanceElevationDegrees` in radians.
    public static var cueStanceElevation: Double { cueStanceElevationDegrees * .pi / 180 }

    // MARK: The cushions

    /// Height of a cushion's nose above the cloth: the top of the undercut, where the leaning face
    /// stops and the square band over it begins.
    ///
    /// It is **above the ball's centre** — the ball is 52.5 mm across and so rides with its centre
    /// 26.25 mm up, and the nose stands 7.0875 mm higher again. The ball therefore meets the cushion
    /// above its own equator, with the contact point off the middle of the ball by that much, and
    /// the ball tucks a millimetre in under the nose when it comes to rest: its centre
    /// stands `cushionRestReach` (about 25.28 mm) from the face rather than a full radius. That
    /// offset is what makes the cushion answer along a line above the ball's centre, so it turns the
    /// ball over as it bounces — see `PhysicsWorld`'s cushion collision.
    public static let cushionNoseHeight: Double = 33.3375
    /// How much more cushion stands square on top of the nose: a plain vertical band.
    public static let cushionCap: Double = 5.0
    /// The top of a cushion: the nose, and the square band above it.
    public static var cushionHeight: Double { cushionNoseHeight + cushionCap }
    /// The angle between a cushion's side and the cloth. It is not a right angle: the side is cut
    /// back under the nose, so the nose overhangs the cloth and the ball meets it above its equator
    /// rather than at the foot of a square face.
    public static let cushionFaceDegrees: Double = 65.0
    /// How round the edge of the nose is, where the square band is carried into the lean below it.
    public static let cushionNoseRound: Double = 3.0
    /// How far the foot of a cushion stands behind its nose at the level of the cloth.
    public static var cushionFootSetback: Double {
        cushionNoseHeight / tan(cushionFaceDegrees * .pi / 180)
    }

    /// How far a ball's centre stands out from a cushion's face when the ball is on the cloth and
    /// has come to rest against it. The nose is above the equator, so the ball reaches the face
    /// before its middle does and the centre comes in closer than a radius.
    public static var cushionRestReach: Double {
        let rise = cushionNoseHeight - ballRadius
        return (ballRadius * ballRadius - rise * rise).squareRoot()
    }

    /// How far the floor of a pocket is below the cloth. A ball that drops in falls this far and
    /// comes to rest there, standing on the bottom of the pocket.
    ///
    /// Deep enough that the ball is out of sight before it is taken off the table. A pocket is deeper
    /// than a ball is wide, so a ball sinking into one is hidden behind the cloth and the wood long
    /// before it reaches the bottom: at 44 mm the ball came to rest with the top of it still standing
    /// above the cloth, in plain view, and it was seen to fade away rather than to drop out of sight.
    public static let pocketDepth: Double = 110

    /// Baulk-line is 737 mm from the face of the Bottom cushion (Section 1 Rule 1(d)).
    public static let baulkLineX: Double = 737.0
    /// The "D" has a radius of 292 mm (Section 1 Rule 1(e)).
    public static let dRadius: Double = 292.0
    /// Black spot is 324 mm from the face of the Top cushion (Section 1 Rule 1(f)(iv)).
    public static let blackSpotFromTop: Double = 324.0

    public static var centreY: Double { width / 2 }

    // MARK: Spots (Section 1 Rule 1(f))

    public static let brownSpot = Vec2(baulkLineX, centreY)
    /// Right-hand corner of the "D" seen from the baulk end.
    public static let yellowSpot = Vec2(baulkLineX, centreY - dRadius)
    /// Left-hand corner of the "D" seen from the baulk end.
    public static let greenSpot = Vec2(baulkLineX, centreY + dRadius)
    /// Midway between the faces of the Top and Bottom cushions.
    public static let blueSpot = Vec2(length / 2, centreY)
    /// Midway between the Blue Spot and a point below the Top cushion face.
    public static let pinkSpot = Vec2((length / 2 + length) / 2, centreY)
    public static let blackSpot = Vec2(length - blackSpotFromTop, centreY)

    public static func spot(for color: BallColor) -> Vec2? {
        switch color {
        case .yellow: return yellowSpot
        case .green: return greenSpot
        case .brown: return brownSpot
        case .blue: return blueSpot
        case .pink: return pinkSpot
        case .black: return blackSpot
        case .red, .white: return nil
        }
    }

    /// Spots in the order a colour looks for a free home: own spot, then the highest
    /// value spot available (Section 3 Rule 7(e)/(f)).
    public static let allSpots: [(BallColor, Vec2)] = [
        (.black, blackSpot),
        (.pink, pinkSpot),
        (.blue, blueSpot),
        (.brown, brownSpot),
        (.green, greenSpot),
        (.yellow, yellowSpot),
    ]

    // MARK: Pockets (Section 1 Rule 1(g))

    /// Jaw openings, measured between the two jaw tips — the ends of the cushion faces, which is
    /// what a mouth is measured across on a real table. A ball is potted when its centre passes
    /// through into the pocket (see `PocketCut`).
    ///
    /// The rule book's middle pocket is 98 mm, but the table here is cut with middle pockets the
    /// same width as the corners: 78 mm, which is what the hole in the slate is cut to as well.
    public static let cornerPocketMouth: Double = 78.0
    public static let middlePocketMouth: Double = 78.0
    /// How round a jaw is. A jaw is the end of a cushion: the cushion is cut back there, and the cut
    /// is a round of this radius whose axis is perpendicular to the table, so the cushion is the
    /// same height the whole way along. The round is what joins the straight cushion — its face — to
    /// the pocket's throat, and it is the same circle the ball bounces off, so what is drawn and
    /// what is played on are one shape.
    public static let jawRadius: Double = 50.0
    /// How far back from the cushion faces the wood of the rails stops. The pocket has to reach
    /// this far out, or bare slate would show between the pocket and the wood.
    public static let cushionDepth: Double = 48.0
    /// How wide the wooden rail is behind a cushion. The playing area plus a cushion plus a rail on
    /// every side is the table's own footprint, which is what the player walks around.
    public static let railDepth: Double = 95.0
    /// How far the table reaches beyond the playing area on each side: the cushion and its rail.
    public static var tableSurround: Double { cushionDepth + railDepth }

    /// How far past the line the jaws' feet stand on the hole is cut, on each side.
    ///
    /// With no clearance the rim would be cut exactly to the foot of each jaw; this much leaves the
    /// rim just outside it, so the jaw's foot stands clear over the hole and the cloth's edge is
    /// tucked behind the jaw's own lean rather than showing as a sliver of cloth along the rim.
    public static let pocketHoleClearance: Double = 1.0
    /// How much wider than a middle pocket's a **corner's** hole is cut, in diameter.
    ///
    /// A corner takes the ball off two cushions at once, so its hole is opened out by this much more
    /// than a middle pocket's. It is paid for out of the wood around it: the crescent between a
    /// corner's hole and the table's own outer edge comes down from 32.2 mm at its thinnest to
    /// 22.2 mm, which still leaves the rail a solid width of wood to wrap the pocket with. A middle
    /// pocket has no such room — its hole is already within 13 mm of the outer edge — so it is left
    /// as it is.
    public static let cornerPocketHoleExtra: Double = 20.0
    /// The hole a **middle** pocket is cut with, in the slate and in the cloth above it. The mouth is
    /// measured between the jaws and is 78 mm; the hole opens out beyond that by the jaws' own
    /// setback on each side — see `pocketHoleSetback` — so the foot of each jaw stands over the hole
    /// rather than over cloth, and a ball in the throat has somewhere to go. And then out by
    /// `pocketHoleClearance` again, so its rim runs just past the foot of each jaw rather than being
    /// cut exactly to it: 78 + 2 × 15.5455 + 2 × 1.0 = 111.0911 mm.
    public static let middlePocketHoleDiameter: Double =
        middlePocketMouth + 2 * (pocketHoleSetback + pocketHoleClearance)
    /// The hole a **corner** is cut with: a middle pocket's own, and `cornerPocketHoleExtra` wider
    /// again — 111.0911 + 20 = 131.0911 mm — so its rim stands 11 mm outside the foot of each jaw
    /// rather than a millimetre, and the hole comes 10 mm nearer the mouth.
    public static let cornerPocketHoleDiameter: Double =
        middlePocketHoleDiameter + cornerPocketHoleExtra
    /// The hole this pocket is cut with: the corners' own, or a middle pocket's.
    public static func pocketHoleDiameter(for pocket: PocketID) -> Double {
        pocket.isCorner ? cornerPocketHoleDiameter : middlePocketHoleDiameter
    }
    /// How far the foot of a jaw stands behind its nose at the level of the cloth: the cushion's own
    /// setback, `cushionFootSetback` — the nose height over tan 65° — and, with `pocketHoleClearance`,
    /// how far the hole is cut out past it on each side.
    ///
    /// It is the *level of the cloth* rather than the bottom of the cloth that is meant, because that
    /// is where a ball meets a jaw: the nose overhangs the foot, so the two come out together.
    public static var pocketHoleSetback: Double { cushionFootSetback }
    /// How much further out than that the hole is set, down each cushion the pocket is cut in.
    ///
    /// This is what puts the hole away from the mouth: a ball is on the cloth until its centre
    /// crosses the hole's rim, so the further out the hole is, the further into the throat a ball has
    /// to travel before it falls — and the less of the fall is spent in the jaws.
    public static let pocketHolePull: Double = 20.0

    /// Where the jaws stand. A corner pocket's two tips are `cornerJawGap` from the corner along
    /// each cushion, so the two of them are `cornerJawGap * sqrt(2)` apart — the 78 mm the mouth is
    /// measured as; a middle pocket's are `middleJawGap` either side of the middle of the table,
    /// straight across it. Each jaw's rounded nose then sits `jawRadius` further out, tangent to
    /// its cushion face, where `PhysicsWorld` and `Table3D` both put it.
    public static let cornerJawGap: Double = cornerPocketMouth / 2.0.squareRoot()
    public static let middleJawGap: Double = middlePocketMouth / 2

    // MARK: Reds (Section 3 Rule 2(a)(i))

    /// The apex red sits as close to the Pink Spot as possible without occupying it,
    /// with the triangle opening toward the baulk cushion.
    public static func rackedReds() -> [Vec2] {
        let rowSpacing = ballDiameter * cos(.pi / 6)      // equilateral triangle rows
        let lateralSpacing = ballDiameter
        let apex = Vec2(pinkSpot.x + ballDiameter + 1.0, pinkSpot.y)
        var positions: [Vec2] = []
        for row in 0..<5 {
            for index in 0...row {
                let x = apex.x + Double(row) * rowSpacing
                let y = apex.y + (Double(index) - Double(row) / 2) * lateralSpacing
                positions.append(Vec2(x, y))
            }
        }
        return positions
    }

    /// Point on the baulk-line side of the "D" used for in-hand placement checks.
    public static func isInsideD(_ p: Vec2) -> Bool {
        guard p.x <= baulkLineX else { return false }
        let d = p - brownSpot
        return d.length <= dRadius
    }
}

/// A ball in play.
public struct Ball: Identifiable, Equatable, Sendable {
    public let id: Int
    public let color: BallColor
    public var position: Vec2
    /// Velocity in mm/s.
    public var velocity: Vec2
    /// Angular velocity in rad/s (x/y tilt = follow or draw, z = side spin).
    public var spin: Vec3
    /// How high the ball's centre stands above the cloth, in millimetres. A ball running on the
    /// cloth has its centre a radius up; one that has been bounced off the cloth is higher, and one
    /// in a pocket is lower.
    public var height: Double
    /// Vertical velocity of the centre in mm/s, positive upwards.
    public var verticalVelocity: Double
    public var onTable: Bool
    /// True while a ball that has been forced off the table is falling to the floor: off the table as
    /// far as the rules are concerned — see `PhysicsWorld.takeBallsOffTheTable` — but still drawn,
    /// until it lands. A ball that is neither on the table nor falling is gone.
    public var isFalling: Bool
    /// Where the ball came to rest if potted (for the marker / display).
    public var pottedInto: PocketID?

    public init(id: Int, color: BallColor, position: Vec2, velocity: Vec2 = .zero, spin: Vec3 = .zero,
                height: Double = Table.ballRadius, verticalVelocity: Double = 0, onTable: Bool = true,
                isFalling: Bool = false) {
        self.id = id
        self.color = color
        self.position = position
        self.velocity = velocity
        self.spin = spin
        self.height = height
        self.verticalVelocity = verticalVelocity
        self.onTable = onTable
        self.isFalling = isFalling
        self.pottedInto = nil
    }

    /// True while the ball is running on the cloth: not in the air, and not down a pocket.
    public var isOnTheCloth: Bool { abs(height - Table.ballRadius) <= 0.01 }

    public var isMoving: Bool {
        velocity.length > 0.5 || spin.length > 0.25 || !isOnTheCloth || abs(verticalVelocity) > 0.5
    }
}

/// The light that hangs over the table in the 3D view: three long rectangular plates, one along each
/// side of the table and one down the middle, the outer two turned down towards the cloth.
///
/// They began as nine smaller plates in a three by three with 20 mm between neighbours, but the gaps
/// inside a row are 20 mm at 2.2 m — invisible, and nothing like the gap across the table — so each
/// row of three is one plate. The 20 mm between the plates across the table is kept: that gap is
/// wide enough to be seen, and is what makes the light read as three plates rather than one.
///
/// Nothing in the rules of the game depends on any of this. It is here, away from the renderer, so
/// that the fixture can be measured — a plate in the wrong place or at the wrong angle would show up
/// as a puzzle in the picture, and this says what the picture should be.
public enum TableLightRig {
    /// One plate of the rig.
    public struct Plate: Equatable, Sendable {
        /// The middle of the plate, over the cloth, in the table's own coordinates: `x` in
        /// millimetres from the baulk cushion along the table, and `y` across it from the bottom
        /// cushion.
        public let centre: Vec2
        /// How high the middle of the plate is above the cloth, in millimetres.
        public let height: Double
        /// How far the plate is turned down, in degrees: positive drops the plate's edge on the `+y`
        /// side of the table, so a plate hung off to one side has its outer edge down and its face
        /// looking in towards the middle of the table. The middle plate is not turned at all.
        public let tilt: Double

        public init(centre: Vec2, height: Double, tilt: Double) {
            self.centre = centre
            self.height = height
            self.tilt = tilt
        }

        /// True for the two plates along the sides, which are the ones turned down.
        public var isTurnedDown: Bool { tilt != 0 }
    }

    /// A plate: the length of the table's light, 400 mm across. It is shorter than the playing area —
    /// 3164 mm against the table's 3569 — so the rig stops a little inside each cushion line, 202 mm at
    /// each end, rather than reaching out over them.
    public static let plateLength: Double = 3164
    public static let plateWidth: Double = 400
    /// The gap between two plates next to each other, across the table.
    public static let gap: Double = 20
    /// The middle of the rig hangs this far above the middle of the table. The four lights over the
    /// corner pockets hang at the same height, so the whole light comes down together.
    public static let heightAboveCloth: Double = 2200
    /// The two plates along the sides are turned down by this much.
    public static let outerTiltDegrees: Double = 10

    /// How far apart the middles of two plates next to each other are, across the table.
    public static var pitchAcrossTable: Double { plateWidth + gap }

    /// How far a turned-down plate has to be dropped so that its edge along the middle of the rig
    /// meets the plate next to it.
    ///
    /// A plate turns about its own middle, so turning it down lifts the edge on the middle side by
    /// half its width times the sine of the angle. Dropping the plate by that much puts that edge
    /// back level with the plate across the middle, and the rig then reads as one light with its
    /// sides folded down.
    public static var dropForTurnedDownPlate: Double {
        (plateWidth / 2) * sin(outerTiltDegrees * .pi / 180)
    }

    /// The three plates, centred on the middle of the table: one down the middle, one along each side.
    public static let plates: [Plate] = {
        var plates: [Plate] = []
        for row in -1...1 {
            let tilt = Double(row) * outerTiltDegrees
            plates.append(Plate(centre: Vec2(Table.length / 2,
                                             Table.width / 2 + Double(row) * pitchAcrossTable),
                                height: heightAboveCloth - (tilt == 0 ? 0 : dropForTurnedDownPlate),
                                tilt: tilt))
        }
        return plates
    }()

    /// How far the rig reaches from the middle of the table, along it and across it.
    public static var halfLength: Double { plateLength / 2 }
    public static var halfWidth: Double { (plateWidth * 3 + gap * 2) / 2 }
}

public enum PocketID: String, CaseIterable, Codable, Sendable {
    case topLeft, topMiddle, topRight, bottomLeft, bottomMiddle, bottomRight

    /// The cut of this pocket: where its mouth is, the way it runs into the table and the hole at
    /// the end of it.
    public var cut: PocketCut { PocketCut(self) }

    /// The mouth this pocket is cut to. Every pocket on this table is 78 mm — the rule book's middle
    /// pocket is a wider 98 mm, but the middle pockets here are cut like the corners.
    public var mouth: Double {
        switch self {
        case .topMiddle, .bottomMiddle: return Table.middlePocketMouth
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return Table.cornerPocketMouth
        }
    }

    public var isCorner: Bool {
        switch self {
        case .topMiddle, .bottomMiddle: return false
        case .topLeft, .topRight, .bottomLeft, .bottomRight: return true
        }
    }

    /// Where the pocket is, for anything that only needs a point: the middle of the hole.
    public var position: Vec2 { cut.holeCentre }
}

/// The cut of one pocket.
///
/// Rule 1(g) fixes the mouth — 78 mm between the tips of the two cushions at a corner — and this
/// table cuts its middle pockets to the same 78 mm (the rule book's middle pocket is 98 mm). This is
/// the pocket drawn and played on around that width: a **passage of the same width as the mouth**
/// running straight from the mouth to a **round hole the jaws stand over**. The throat neither
/// narrows nor widens on the way — the jaws lean out as they rise, but their feet are set back along
/// the throat, not across it — so the hole opens out past the passage by the jaws' own setback on
/// each side. A corner pocket runs out along the 45° diagonal, a middle pocket square to the cushion.
public struct PocketCut: Sendable {
    public let pocket: PocketID
    /// The middle of the mouth: the point where the pocket leaves the playing area.
    public let mouth: Vec2
    /// Unit vector from the mouth into the pocket, down the passage.
    public let axis: Vec2
    /// The two ends of the mouth: the tips of the cushions either side of it.
    public let tipA: Vec2
    public let tipB: Vec2
    /// The width of the mouth, which is also the width of the passage. The hole is wider: see
    /// `holeRadius`.
    public let width: Double
    /// How far the passage runs from the mouth before the hole opens out.
    public let passageLength: Double
    /// The radius of the hole: `Table.pocketHoleDiameter(for:)`, which is the mouth's width plus the
    /// jaws' setback on each side and the clearance past each foot, and at a corner the corner's own
    /// extra width again.
    public let holeRadius: Double
    /// The middle of the hole: the mouth carried `passageLength` down the passage, and then out along
    /// the outward of **every cushion the pocket is cut in** by the jaws' own setback plus
    /// `Table.pocketHolePull` — along both of the cushion faces that meet at a corner, and square to
    /// its own cushion at a middle pocket. The setback clears the jaws' feet; the pull is what puts
    /// the hole that much further from the mouth, so a ball has further to travel into the throat
    /// before it falls. The effect is that the hole grows outwards without its near edge moving in
    /// towards the table: the rim keeps to the line it was cut to where a ball running along a
    /// cushion meets it.
    public let holeCentre: Vec2
    /// The two jaws: the round at the end of the cushion either side of the pocket.
    public let jaws: (Jaw, Jaw)

    /// One jaw: the round at the end of a cushion, joining the straight cushion to the throat.
    public struct Jaw: Sendable {
        /// The tip of the cushion: the point the mouth is measured between.
        public let tip: Vec2
        /// Where the round's axis is, in the table's plane.
        public let centre: Vec2
        public let radius: Double
        /// Where the round leaves the cushion's straight face.
        public let atTheFace: Vec2
        /// Where it reaches the pocket's throat.
        public let atTheThroat: Vec2
    }

    /// A jaw for the tip of a cushion whose face runs towards the back of the table along `face` and
    /// whose pocket runs away down `throat`.
    ///
    /// The round is tangent to both, so it carries the face into the throat without a corner in
    /// between — which is what a jaw is: a round of `Table.jawRadius` cut where the cushion ends.
    static func makeJaw(tip: Vec2, face: Vec2, throat: Vec2) -> Jaw {
        let radius = Table.jawRadius
        let corner = acos(max(-1, min(1, face.dot(throat))))     // the angle the round rounds off
        let reach = radius / sin(corner / 2)                     // tip to the round's centre
        let tangent = radius / tan(corner / 2)                   // tip to where the round meets a side
        return Jaw(tip: tip,
                   centre: tip + (face + throat).normalized * reach,
                   radius: radius,
                   atTheFace: tip + face * tangent,
                   atTheThroat: tip + throat * tangent)
    }

    /// Which way the cushion runs from one of its tips: away from the pocket.
    static func faceAway(from tip: Vec2, pocket centre: Vec2) -> Vec2 {
        // The tip is on a cushion line; the cushion runs along it, away from the pocket.
        if abs(tip.y) < 1e-9 || abs(tip.y - Table.width) < 1e-9 {
            return Vec2(tip.x >= centre.x ? 1 : -1, 0)
        }
        return Vec2(0, tip.y >= centre.y ? 1 : -1)
    }

    /// Which way a cushion's outward runs from one of its tips: away from the playing area, square to
    /// the cushion the tip stands on.
    public static func outward(at tip: Vec2) -> Vec2 {
        if abs(tip.y) < 1e-9 { return Vec2(0, -1) }
        if abs(tip.y - Table.width) < 1e-9 { return Vec2(0, 1) }
        if abs(tip.x) < 1e-9 { return Vec2(-1, 0) }
        return Vec2(1, 0)
    }

    /// Where the hole meets the sides of the passage: the two points of the hole furthest across.
    public var tangents: (Vec2, Vec2) {
        let across = axis.perpendicular * holeRadius
        return (holeCentre + across, holeCentre - across)
    }

    /// Whether a ball's centre at `point` has passed into the pocket.
    ///
    /// The table's surface runs on into the pocket's throat and is cut away at the hole, so the ball
    /// is supported until its centre is over the hole itself, and that is where it falls.
    public func contains(_ point: Vec2) -> Bool {
        point.distance(to: holeCentre) <= holeRadius
    }

    /// A run of points right round a circle, sampled every `step` degrees.
    public static func circlePoints(centre: Vec2, radius: Double, step: Double = 2) -> [Vec2] {
        let count = max(12, Int(360 / step))
        return (0..<count).map { index in
            let a = 2 * Double.pi * Double(index) / Double(count)
            return Vec2(centre.x + radius * cos(a), centre.y + radius * sin(a))
        }
    }

    /// A run of points along a circle, from one point to another the way round that passes through a
    /// third, sampled every `step` degrees.
    ///
    /// The outlines are laid down as runs of short straight segments rather than left to SceneKit,
    /// which flattens curves in the scene's own units: a quarter circle of 292 mm came out as one
    /// straight line, which was enough to turn the "D" into a wedge and each pocket into a triangle.
    public static func arcPoints(
        centre: Vec2, radius: Double, from: Vec2, to: Vec2, through: Vec2, step: Double = 2
    ) -> [Vec2] {
        func angle(_ p: Vec2) -> Double { atan2(p.y - centre.y, p.x - centre.x) }
        func turn(_ a: Double) -> Double {
            (a.truncatingRemainder(dividingBy: 2 * .pi) + 2 * .pi).truncatingRemainder(dividingBy: 2 * .pi)
        }
        let start = angle(from)
        let counterclockwise = turn(angle(through) - start) < turn(angle(to) - start)
        var sweep = angle(to) - start
        if counterclockwise {
            while sweep < 0 { sweep += 2 * .pi }
        } else {
            while sweep > 0 { sweep -= 2 * .pi }
        }
        let count = max(2, Int(abs(sweep) / (step * .pi / 180)) + 1)
        return (0...count).map { index in
            let a = start + sweep * Double(index) / Double(count)
            return Vec2(centre.x + radius * cos(a), centre.y + radius * sin(a))
        }
    }

    /// The points two circles share, if any.
    static func meetings(_ c1: Vec2, _ r1: Double, _ c2: Vec2, _ r2: Double) -> [Vec2] {
        let between = c2 - c1
        let d = between.length
        guard d > 1e-9, d <= r1 + r2, d >= abs(r1 - r2) else { return [] }
        let along = (r1 * r1 - r2 * r2 + d * d) / (2 * d)
        let across = (r1 * r1 - along * along).squareRoot()
        let unit = between / d
        let foot = c1 + unit * along
        let side = unit.perpendicular * across
        return across < 1e-9 ? [foot] : [foot + side, foot - side]
    }

    /// Where a jaw's round leaves the pocket: the point of the round nearest the hole, which is
    /// where it meets the hole's circle, or the end of the throat if the round never reaches it.
    func meeting(of jaw: Jaw) -> Vec2 {
        func angle(_ p: Vec2) -> Double { atan2(p.y - jaw.centre.y, p.x - jaw.centre.x) }
        let sweep = atan2(sin(angle(jaw.atTheThroat) - angle(jaw.atTheFace)),
                          cos(angle(jaw.atTheThroat) - angle(jaw.atTheFace)))
        let hits = PocketCut.meetings(jaw.centre, jaw.radius, holeCentre, holeRadius).filter { hit in
            // On the round itself, not on the rest of its circle.
            let toHit = atan2(sin(angle(hit) - angle(jaw.atTheFace)),
                              cos(angle(hit) - angle(jaw.atTheFace)))
            return toHit * sweep >= 0 && abs(toHit) <= abs(sweep) + 1e-9
        }
        return hits.first ?? jaw.atTheThroat
    }

    /// The outline of the pocket: from where one jaw leaves the cushion's face, round the jaw's
    /// round to the hole, round the hole and back up the other jaw. The run closes along the mouth
    /// line from the second jaw's face back to the first.
    public func outline(step: Double = 2) -> [Vec2] {
        func jawRun(_ jaw: Jaw) -> [Vec2] {
            let meet = meeting(of: jaw)
            let via = jaw.centre
                + (jaw.atTheFace - jaw.centre + jaw.atTheThroat - jaw.centre).normalized * jaw.radius
            // Round the jaw's round to wherever it leaves the pocket, then straight down the throat
            // if it is the throat that carries it to the hole.
            let onTheRound = meet.distance(to: jaw.atTheThroat) > 1e-6
            var run = PocketCut.arcPoints(centre: jaw.centre, radius: jaw.radius,
                                          from: jaw.atTheFace, to: onTheRound ? meet : jaw.atTheThroat,
                                          through: via, step: step)
            if !onTheRound { run.append(meet) }
            return run
        }

        let far = holeCentre + (holeCentre - mouth).normalized * holeRadius
        var points = jawRun(jaws.0)
        let leftMeet = points.removeLast()
        points.append(leftMeet)
        let rightMeet = meeting(of: jaws.1)
        points += PocketCut.arcPoints(centre: holeCentre, radius: holeRadius,
                                      from: leftMeet, to: rightMeet, through: far, step: step)
            .dropFirst().dropLast()
        points.append(rightMeet)
        points += jawRun(jaws.1).reversed()
        return points
    }

    init(_ pocket: PocketID) {
        let L = Table.length, W = Table.width
        let d = Table.cushionDepth
        let corner = Table.cornerJawGap, middle = Table.middleJawGap
        let diagonal = 1 / 2.0.squareRoot()
        var railInner = 0.0          // how far the passage has to reach to get past the rails
        switch pocket {
        case .bottomLeft:
            mouth = Vec2(corner / 2, corner / 2); axis = Vec2(-diagonal, -diagonal)
            tipA = Vec2(corner, 0); tipB = Vec2(0, corner)
            railInner = d * 2.0.squareRoot() + pocket.mouth / 2
        case .bottomRight:
            mouth = Vec2(L - corner / 2, corner / 2); axis = Vec2(diagonal, -diagonal)
            tipA = Vec2(L - corner, 0); tipB = Vec2(L, corner)
            railInner = d * 2.0.squareRoot() + pocket.mouth / 2
        case .topRight:
            mouth = Vec2(L - corner / 2, W - corner / 2); axis = Vec2(diagonal, diagonal)
            tipA = Vec2(L - corner, W); tipB = Vec2(L, W - corner)
            railInner = d * 2.0.squareRoot() + pocket.mouth / 2
        case .topLeft:
            mouth = Vec2(corner / 2, W - corner / 2); axis = Vec2(-diagonal, diagonal)
            tipA = Vec2(corner, W); tipB = Vec2(0, W - corner)
            railInner = d * 2.0.squareRoot() + pocket.mouth / 2
        case .bottomMiddle:
            mouth = Vec2(L / 2, 0); axis = Vec2(0, -1)
            tipA = Vec2(L / 2 - middle, 0); tipB = Vec2(L / 2 + middle, 0)
            railInner = d
        case .topMiddle:
            mouth = Vec2(L / 2, W); axis = Vec2(0, 1)
            tipA = Vec2(L / 2 - middle, W); tipB = Vec2(L / 2 + middle, W)
            railInner = d
        }
        self.pocket = pocket
        self.width = pocket.mouth
        self.holeRadius = Table.pocketHoleDiameter(for: pocket) / 2
        // The hole sits as far out as it must: far enough that it covers the ground between the
        // mouth and the inner edge of the rails, so the wood meets the pocket and no bare slate is
        // left showing, and never nearer in than its own radius, which would have the hole break
        // back through the mouth into the playing area.
        self.passageLength = max(pocket.mouth / 2, railInner - pocket.mouth / 2)
        // And then out past that by the jaws' own setback and the pull, once for each cushion the
        // pocket is cut in: a corner is cut into two cushions, so its hole moves out along both.
        let cushionA = PocketCut.outward(at: tipA), cushionB = PocketCut.outward(at: tipB)
        let cushions = cushionA == cushionB ? [cushionA] : [cushionA, cushionB]
        let holeMiddle = cushions.reduce(mouth + axis * passageLength) {
            $0 + $1 * (Table.pocketHoleSetback + Table.pocketHolePull)
        }
        self.holeCentre = holeMiddle
        self.jaws = (PocketCut.makeJaw(tip: tipA,
                                       face: PocketCut.faceAway(from: tipA, pocket: holeMiddle),
                                       throat: axis),
                     PocketCut.makeJaw(tip: tipB,
                                       face: PocketCut.faceAway(from: tipB, pocket: holeMiddle),
                                       throat: axis))
    }
}
