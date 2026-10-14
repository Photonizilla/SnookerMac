import Foundation

public enum CushionSide: String, Equatable, Sendable {
    case bottom, top, left, right
}

/// Things that happen during a stroke. The rules engine adjudicates from these.
public enum PhysicsEvent: Equatable, Sendable {
    /// Two balls collided; `relativeSpeed` is the closing speed in mm/s.
    case ballBall(a: Int, b: Int, relativeSpeed: Double)
    /// A ball rebounded off a cushion; `speed` is the closing speed along the cushion's own normal, in
    /// mm/s. A straight run and a jaw report alike — they are one rubber, see `bounceOffFace`.
    case cushion(ball: Int, side: CushionSide, speed: Double)
    /// A ball struck the cut of a pocket **behind** a jaw — the throat — which is a dead wood facing
    /// rather than rubber. `speed` is the closing speed into it, in mm/s. See `bounceOffThroat`.
    case throat(ball: Int, speed: Double)
    /// A ball came down on the cloth over the **wood of the rail** behind a cushion — timber under the
    /// same cloth — and bounced. `speed` is the speed it met it with, in mm/s.
    case rail(ball: Int, speed: Double)
    /// A ball came back down on the cloth of the **bed** — slate under it, rather than the timber of a
    /// rail — and bounced. `speed` is the speed it met it with, in mm/s.
    case bed(ball: Int, speed: Double)
    /// A ball forced off the table reached the floor. `speed` is the speed it met it with, in mm/s.
    case landed(ball: Int, speed: Double)
    /// A ball met the **wood at the back of a pocket** — the far side of the well below the hole, or
    /// one of its sides — on its way in. `speed` is the speed it went into it with, in mm/s. It is
    /// wood, the same as the rail's, and is reported so that it can be heard as wood.
    case pocketWood(ball: Int, speed: Double)
    /// A ball dropped into a pocket.
    case pocketed(ball: Int, pocket: PocketID)
    /// A ball left the table: it came to rest off the playing area and not in a pocket, which
    /// Section 2 Rule 14 calls a ball forced off the table.
    case forcedOffTable(ball: Int)
    /// The cue ball passed over part of an object ball before it had hit one, which Section 2 Rule 20
    /// makes a jump shot — a foul (Rule 11(a)(x)). The ball it went over is named.
    case jumpShot(over: Int)
    /// The cue itself touched a ball in play: the tip of it, or the side of the stick (Rule 11(b)(vi)
    /// — a ball contacted with the player's equipment is a foul). A cue ball touched again after the
    /// stroke has left it is the double hit of Rule 11(a)(ii), and is reported the same way.
    /// The stick met a ball in play. `after` is how long the stroke had been running, in seconds —
    /// zero at the strike — so a second touch of the cue ball can be timed from the first, and `speed`
    /// is what the stick was travelling at when it did it, in mm/s.
    case cueTouched(ball: Int, after: Double, speed: Double)
}

/// The cue, as the physics sees it: a tapered stick whose tip is at a place on the table, running back
/// along `axis`, with the tip travelling along that axis at `speed`.
///
/// The cue is the player's hand and it is many times the weight of a ball, so the physics treats it as
/// **infinitely heavy**: nothing a ball does to it moves it. It is not integrated at all — the player's
/// mouse sets its speed and the box carries it along — and every ball it meets is answered as a
/// collision with a body that does not budge. That is also why the tip's own limit — the friction of
/// the leather, see `PhysicsWorld.cueTipFriction` — is what settles the spin rather than the cue being
/// knocked off line.
public struct Cue: Sendable, Equatable {
    /// The tip's end, in the table's own coordinates: x and y across the cloth, z above it.
    public var tip: Vec3
    /// Unit vector from the butt towards the tip.
    public var axis: Vec3
    /// How fast the tip is travelling along `axis`, in mm/s, towards the ball.
    public var speed: Double

    public init(tip: Vec3, axis: Vec3, speed: Double) {
        self.tip = tip
        self.axis = axis
        self.speed = speed
    }
}

/// A cushion is a line segment the balls bounce off, with a small "jaw" collider at
/// each end where the cushion meets a pocket opening.
struct Cushion {
    let side: CushionSide
    let a: Vec2
    let b: Vec2
    /// Unit normal pointing into the playing area.
    let normal: Vec2
}

/// Rigid-body style billiard simulation in millimetres.
///
/// Each ball carries velocity and a full 3D angular velocity. The simulation resolves
/// slip at the cloth contact point: while the contact point slides, kinetic friction
/// both slows the ball and changes its spin (this is what produces draw, follow and
/// to a lesser extent swerve); once the ball is rolling, rolling resistance applies.
public final class PhysicsWorld {
    // MARK: Tunables

    /// Cloth sliding friction, for a fast competition cloth. A club cloth is nearer 0.20; the
    /// lower figure both quickens the slide and lets a ball that has just come off a cushion
    /// keep a little more of what the cushion gave it.
    public static let slidingFriction = 0.15
    /// Rolling resistance of a competition snooker cloth: 0.010 is 0.098 m/s², so a ball rolling
    /// at 800 mm/s runs 3.26 m before the cloth stops it, and a 2 m/s shot crosses the table.
    public static let rollingResistance = 0.010
    /// Ball-to-ball restitution.
    public static let ballRestitution = 0.95
    /// Ball-to-ball friction (produces throw).
    public static let ballFriction = 0.06
    /// Cushion restitution: how much of a ball's speed the rubber gives back, along the face normal.
    ///
    /// It is the figure along the cushion's own normal, which leans down as well as in where the ball
    /// meets the nose above its middle (see `bounceOffSegment`), so what comes straight back along
    /// the table is a little less than this. 0.87 tunes a square hit to come back at about 0.8 of
    /// its approach — a lively competition cushion. The jaws are cut from the same rubber, so
    /// `bounceOffJaw` reads it too.
    public static let cushionRestitution = 0.87
    /// Cushion friction: how strongly the cushion couples to tangential motion and spin — how much the
    /// rubber **grabs** the ball as it goes into it, turning it off the angle it came in at and taking
    /// spin off it (and putting the other sort on). 0.19 is a little under the competition figure this
    /// started at (0.22), which takes some of the grab out of a cushion: raising it grips more, lowering
    /// it lets the ball come off closer to a plain reflection.
    public static let cushionFriction = 0.19
    /// Shore A hardness of the cushion's rubber. A real competition cushion is moulded to about this
    /// — 43 on the Shore A scale — which fixes the rubber's elastic modulus, and through it how far a
    /// ball sinks into the cushion when it is played at it. See `cushionGripDepth`.
    public static let cushionShoreA = 43.0
    /// How much stiffer the rubber is under an impact than the Shore A hardness says.
    ///
    /// Shore A is measured slowly, and rubber is not: its modulus climbs with how fast it is deformed,
    /// and a ball on a cushion deforms it in about a millisecond. Taking the hardness at face value
    /// (which this did at first) had the ball sinking six millimetres into the cushion at 3 m/s, with a
    /// contact patch two thirds of the ball's own width — and the grip that came of it turned every
    /// hard ball back along the normal, which is not how a snooker cushion plays. The dynamic modulus
    /// of filled rubber at impact rates is two to four times its static one; three is a fair figure,
    /// and it puts the sink at 1.7 mm at 1 m/s and 7.1 mm at the fastest a ball leaves the cue with
    /// (6 m/s, the top of the range the game is played over).
    public static let cushionImpactStiffening = 3.0
    /// How deep a ball has to sink into the cushion, as a fraction of its own radius, for the rubber
    /// to have it completely and carry all of its sideways motion away, leaving nothing of the angle
    /// it came in at.
    ///
    /// The speed dependence is physical: a ball compresses the rubber by the Hertz impact depth,
    /// which grows as the fourth fifth power of the normal approach speed and shrinks with the
    /// rubber's impact modulus (`cushionShoreA`, stiffened by `cushionImpactStiffening`). How the
    /// grip follows that depth is a judgement. It goes as the square, so a slow shot — barely denting
    /// the cushion — keeps nearly all its angle, and the effect comes on with speed. Set this where a
    /// ball still has to come off a cushion the way a real one does: at 0.40 the grip is a quarter of
    /// the way on at about 4 m/s and 45% of it at the hardest shot in the game, 6 m/s, so the rebound
    /// angle gives up a few degrees there, not most of it.
    ///
    /// The **jaws** are the same rubber and the same measure — a ball that rattles in the jaws of a
    /// pocket is held exactly as it would be by the cushion the jaw is the end of — and a pocket's own
    /// facing reads it too: see `bounceOffThroat`, and `cushionHold`, which is the one place the
    /// measure is worked out.
    public static let cushionGripDepth = 0.40
    /// Spin about the vertical axis decays a little faster than rolling spin.
    public static let sideSpinDecay = 0.55
    /// How hard the nap of the cloth pushes a ball that is turning about the vertical.
    ///
    /// The cloth is brushed, and its fibres lie one way along the table: the nap runs from the
    /// baulk end towards the black end, which in this file's coordinates is the +x direction (the
    /// Table's own +x, from the face of the Baulk cushion to the Top cushion). Seen from above with
    /// the baulk at the bottom, that is "up the table".
    ///
    /// Side spin drags the cloth under the ball across the nap, and the brushed fibres answer with
    /// a small sideways push: a ball turning clockwise seen from above is carried towards the green
    /// side, and one turning anti-clockwise towards the yellow. The yellow spot is at this file's
    /// lower y (the "D" corner on the striker's right), so the yellow side is the low-y side and the
    /// green is the high-y side. `spin.z` is positive for the anti-clockwise turn, so the push is
    /// `-spin.z` along y. This figure is how many mm/s² of sideways acceleration the ball feels for
    /// each rad/s of side spin; it is small, a few millimetres of drift over a long shot rather than
    /// a curve you would see at a glance.
    public static let napSpinDrift = 0.03
    /// Speed below which a ball is considered stopped (mm/s).
    public static let restSpeed = 6.0
    /// Restitution of the cloth: how much of a ball's downward speed comes back off the bed when it
    /// lands on it. The cloth is soft and deadens the bounce by half.
    public static let clothRestitution = 0.5
    // MARK: The tip

    /// How hard the cue's leather is, in **Shore D**: the one figure the tip is given, and the one the
    /// whole of the contact between the cue and the ball is worked out from.
    ///
    /// Tips are sold on this scale — a soft one is about 55, a medium about 65, a hard one 75 to 80 —
    /// and 70 is a firm playing tip: crisp, and it keeps its shape under the hardest stroke. Nothing
    /// else about the tip is set by hand. Its modulus, the stiffness of the contact it makes, how long
    /// it is on the ball, how far it presses into it and what the ball comes away with all follow from
    /// this number: see `cueTipContactSeconds(forCueSpeed:)` and `cueTipRestitution`.
    public static let cueTipShoreD: Double = 70

    /// The Young's modulus of the leather, in pascals, for a tip of a given hardness.
    ///
    /// For an elastomer the hardness **is** the stiffness, read through the shape of the indentor, so
    /// the two are one chart apart. On the **D** scale that chart is `10^(0.04 S - 0.7)` MPa — Gent's
    /// relation, which is how a cushion's hardness is read here (`cushionShoreA`, and 0.0235 a point on
    /// that scale), carried up on to the harder scale's own slope, because a point of D is worth about
    /// one and a half points of A. It puts a Shore D 40 leather at 8 MPa, 50 at 20, 60 at 50, 70 at 125
    /// and 80 at 315, which is where an elastomer of each of those hardnesses sits on the modulus
    /// charts.
    public static func cueTipYoungsModulus(tipAt shoreD: Double = cueTipShoreD) -> Double {
        pow(10.0, 0.04 * shoreD - 0.7) * 1_000_000
    }

    /// The Young's modulus of the tip the cue is wearing.
    public static var cueTipYoungsModulus: Double { cueTipYoungsModulus() }

    /// Poisson's ratio of the leather. A rubber does not compress when it is pressed — it is displaced —
    /// and a half is what that means for the contact.
    public static let cueTipPoissonsRatio = 0.5

    /// The ball's own elasticity. The rest of the simulation takes a ball as rigid, and it is right to;
    /// a **contact** is between two bodies, and the second of them is a phenolic resin — 4 GPa, Poisson's
    /// ratio about 0.35 — so it is a thousand times the leather's stiffness and barely deforms, but it
    /// is there.
    public static let ballYoungsModulus = 4.0e9
    public static let ballPoissonsRatio = 0.35

    /// The **hertzian** pair the tip's dome and the ball make between them: the one radius the two
    /// bodies are worth as a contact — the dome's curvature is `Table.cueTipCurvature` — and the one
    /// modulus.
    public static var cueTipContactRadius: Double {
        1 / (1 / Table.cueTipCurvature + 1 / Table.ballRadius)
    }

    public static func cueTipContactModulus(tipAt shoreD: Double = cueTipShoreD) -> Double {
        1 / ((1 - cueTipPoissonsRatio * cueTipPoissonsRatio) / cueTipYoungsModulus(tipAt: shoreD)
                    + (1 - ballPoissonsRatio * ballPoissonsRatio) / ballYoungsModulus)
    }

    /// The modulus of the contact the tip the cue is wearing makes with the ball.
    public static var cueTipContactModulus: Double { cueTipContactModulus() }

    /// The mass the contact is worth. The cue is the player's hand and does not budge for a ball, so
    /// what the ball is bounced off is infinitely heavier than it and the pair's mass is the ball's own.
    static var cueTipContactMass: Double { Table.ballMass }

    /// How long the tip is **on the ball** when it strikes one at `cueSpeed`, in seconds.
    ///
    /// A strike is not an instant: the leather presses into the ball and springs back out of it, and the
    /// time that takes is the Hertz contact time,
    /// `t = 2.87 (m² / (R E² v))^(1/5)`. It **narrows** as the shot gets firmer — a fifth root, so a
    /// shot eight times as hard is on the ball for about two thirds of the time — and the whole of it is
    /// the moment the tip has the ball, which is the stroke's **one contact** (see `grabTheCueBall`). A
    /// Shore D 70 tip is on the ball for about 1.4 ms at a full charge and about 2 ms at the gentlest
    /// shot the meter will play, which is the range cue tips are measured in.
    public static func cueTipContactSeconds(forCueSpeed cueSpeed: Double,
                                            tipAt shoreD: Double = cueTipShoreD) -> Double {
        let speed = max(abs(cueSpeed), 1) / 1000                       // m/s
        let modulus = cueTipContactModulus(tipAt: shoreD)
        let radius = cueTipContactRadius / 1000                        // m
        return 2.87 * pow(cueTipContactMass * cueTipContactMass
                          / (radius * modulus * modulus * speed), 0.2)
    }

    /// How far the leather is pressed into the ball at the peak of the contact, in millimetres: the
    /// Hertz impact depth `(15 m v² / (16 sqrt(R) E))^(2/5)` — the same depth a cushion is read by in
    /// `cushionHold`, here for the tip's own contact. A full charge presses the leather about 1.6 mm
    /// into the ball; the gentlest charge, well under half a millimetre.
    public static func cueTipDeflection(forCueSpeed cueSpeed: Double,
                                        tipAt shoreD: Double = cueTipShoreD) -> Double {
        pow(15 * cueTipContactMass * cueTipSpeedInMetres(cueSpeed) * cueTipSpeedInMetres(cueSpeed)
            / (16 * (cueTipContactRadius / 1000).squareRoot()
               * cueTipContactModulus(tipAt: shoreD)), 0.4) * 1000
    }

    static func cueTipSpeedInMetres(_ cueSpeed: Double) -> Double {
        max(abs(cueSpeed), 1) / 1000
    }

    /// How stiff the contact is at the peak of a strike at `cueSpeed`: the Hertz force there over the
    /// deflection there, `(4/3) E sqrt(R d)`. A firmer tip is a stiffer contact, and so is a firmer
    /// strike, because the leather is pressed further into the ball.
    static func cueTipStiffness(tipAt shoreD: Double, struckAt cueSpeed: Double) -> Double {
        let modulus = cueTipContactModulus(tipAt: shoreD)
        let radius = cueTipContactRadius / 1000                        // m
        let speed = cueTipSpeedInMetres(cueSpeed)
        let deflection = pow(15 * cueTipContactMass * speed * speed
                             / (16 * radius.squareRoot() * modulus), 0.4)
        return (4.0 / 3.0) * modulus * (radius * deflection).squareRoot()
    }

    /// The restitution the game is played with, and the tip it is read from.
    ///
    /// Hardness gives the contact's stiffness and says nothing about how much of the energy the leather
    /// hands back. How lossy a material is, is its own property and a different one — a tip can be hard
    /// and dead, or soft and lively — so the damping is the one thing here taken from outside the
    /// hardness, and it is taken from the tip the game's own feel was set at: a Shore D
    /// `cueTipTunedShoreD` tip, returning `cueTipTunedRestitution`, three quarters of what it took,
    /// which is the middle of the range cue tips are measured over. Change `cueTipShoreD` and the tip is
    /// a different one; leave it and the leather is the same.
    public static let cueTipTunedRestitution = 0.75
    public static let cueTipTunedShoreD = 70.0

    /// The strike the contact is read at: a full charge, which is where the power scale's top is set —
    /// the cue at `FrameDriver.maxPower / (1 + cueTipTunedRestitution)`.
    static var cueTipReferenceSpeed: Double {
        FrameDriver.maxPower / (1 + cueTipTunedRestitution)
    }

    /// The damping of the leather, in N·s/m: the one constant the hardness does not give, solved from
    /// the tip the game was tuned with returning `cueTipTunedRestitution` at the reference strike. It
    /// belongs to the leather and does not move when the hardness does — pressing a tip harder makes it
    /// stiffer, not more lossy — and that is what lets the hardness carry the restitution with it.
    static var cueTipDamping: Double {
        let stiffness = cueTipStiffness(tipAt: cueTipTunedShoreD, struckAt: cueTipReferenceSpeed)
        return 2 * contactDampingRatio(forRestitution: cueTipTunedRestitution)
            * (stiffness * cueTipContactMass).squareRoot()
    }

    /// The damping ratio that leaves a spring-damper coming away at `restitution`:
    /// `e = exp(-pi z / sqrt(1 - z²))`, turned round for `z`.
    static func contactDampingRatio(forRestitution restitution: Double) -> Double {
        let a = -log(min(max(restitution, 1e-6), 1)) / Double.pi
        return a / (1 + a * a).squareRoot()
    }

    /// How much of the strike the ball has, `share` of the way through the contact: 0 when the tip takes
    /// the standing ball, 1 when the leather lets it go.
    ///
    /// The tip and the ball are a **spring with damping in it**, and the ball is the mass at the end of it:
    /// driven by a striker going at a steady speed, the ball answers
    /// `1 - e^(-z w t) (cos w_d t - (z w / w_d) sin w_d t)`, which is nothing at all at the first touch,
    /// everything at the release — by the contact's own `1 + e` — and in between it *builds*: the ball is
    /// standing while the leather presses into it, and the whole of the strike is spent on it only as the
    /// tip comes out again. The damping ratio is the one the tip's own restitution gives, and the frequency
    /// is the one the Hertz time gives, so both of the contact's figures are the tip's.
    static func cueContactShape(_ share: Double) -> Double {
        let zeta = contactDampingRatio(forRestitution: cueTipRestitution)
        let damping = zeta / (1 - zeta * zeta).squareRoot()
        let through = share * Double.pi
        return (1 - exp(-damping * through) * (cos(through) - damping * sin(through)))
            / (1 + cueTipRestitution)
    }

    /// How far the leather is pressed into the ball, `share` of the way through the contact, in millimetres:
    /// the same spring's own answer, `(v / w_d) e^(-z w t) sin w_d t`, with the **tip's** speed for `v`.
    ///
    /// It is nothing at the first touch and nothing again at the release, and the most of it in between —
    /// 1.6 mm at a full charge, which is what the tip's own deflection for that speed is worth — so the tip
    /// is seen to go **into** the ball and come back out of it, and the ball travels exactly as far in that
    /// time as the tip does. See `cueTipDeflection(forCueSpeed:)`, which is the same depth read off the
    /// tip's own strike.
    private static func cueContactDeflection(_ contact: CueContact, at share: Double) -> Double {
        let zeta = contactDampingRatio(forRestitution: cueTipRestitution)
        let damping = zeta / (1 - zeta * zeta).squareRoot()
        let through = share * Double.pi
        // The spring's own profile, scaled so that the most it presses in is the depth the tip's own strike
        // is worth (`cueTipDeflection`): the same leather, seen at the same speed, presses the same way.
        let most = atan(1 / damping)
        let peak = exp(-damping * most) * sin(most)
        guard peak > 1e-9 else { return 0 }
        return cueTipDeflection(forCueSpeed: contact.tipSpeed)
            * exp(-damping * through) * sin(through) / peak
    }

    /// Restitution of the tip against the ball: the speed the ball comes away with, over the speed the
    /// tip met it with. See `FrameDriver.ballSpeed`, which is the collision this is the restitution of.
    ///
    /// It comes out of the same contact the time does. The ball is bounced off the leather as off a
    /// spring with damping in it, and a spring-damper comes away at `e = exp(-pi z / sqrt(1 - z²))` with
    /// `z = c / (2 sqrt(k m))` — the damping as a fraction of the contact's own stiffness. Hardness
    /// gives `k`; the damping is the leather's own and is fixed. So a **harder** tip is a stiffer
    /// contact with the same damping in it, which is a smaller fraction of it, and the ball is on it for
    /// less time and comes off it with more of its speed: soft to hard, the model returns 0.61 at Shore
    /// D 55, 0.75 at 70 and 0.82 at 80, and is on the ball for 2.4 ms, 1.4 ms and 1.0 ms in that order.
    /// That is the direction, and about the size, of what players report of a hard tip against a soft
    /// one.
    public static func cueTipRestitution(tipAt shoreD: Double = cueTipShoreD) -> Double {
        let stiffness = cueTipStiffness(tipAt: shoreD, struckAt: cueTipReferenceSpeed)
        let z = cueTipDamping / (2 * (stiffness * cueTipContactMass).squareRoot())
        return exp(-Double.pi * z / (1 - z * z).squareRoot())
    }

    /// The restitution of the tip the cue is wearing.
    public static var cueTipRestitution: Double { cueTipRestitution() }
    /// Rolling resistance of the cloth where it is stretched over the wood of a rail rather than over
    /// the slate of the bed.
    ///
    /// A ball rolling along a rail is on the same cloth, but not on the same thing under it: the bed is
    /// stone, and a ball rolls a long way on it (`rollingResistance`), while a rail is a narrower strip
    /// of timber with the cloth drawn over it and carries a little more of the ball's way off. 0.014 is
    /// 0.137 m/s² against the bed's 0.098, so a ball rolling along a rail goes about three quarters of
    /// the distance the same ball would have covered on the bed.
    public static let railRollingResistance = 0.014
    /// Restitution of the cloth on the wood of a rail: how much of a ball's downward speed comes back
    /// when it lands there. The bed is slate under the cloth and gives back half
    /// (`clothRestitution`); the rail is timber under the same cloth, and timber damps a little more.
    public static let railRestitution = 0.4
    /// A bounce off the cloth smaller than this is not a bounce at all: the ball is settled (mm/s).
    public static let bounceRest = 60.0
    /// Restitution of the walls of a pocket. A ball that runs into the back of a pocket is all but
    /// stopped by it — that is why a ball played hard into a pocket drops rather than comes back
    /// out — and it is this deadness that the figure stands for.
    public static let pocketRestitution = 0.2
    /// Restitution of a pocket's **throat**: the straight cut either side of a pocket, running from
    /// where a jaw's round leaves off to the hole.
    ///
    /// It is not the cushion's rubber. A jaw is the cushion's end cut off where the pocket begins, and
    /// that end is round; the throat behind it is a cut in the wood with a facing on it, and a ball
    /// that meets the facing comes back **half** of what it brought and no more, where the rubber gives
    /// back nearly all of it.
    ///
    /// It is the figure along the facing's own normal, which leans down as well as in — the throat is
    /// cut in the cushion's own section, see `bounceOffThroat` — so what comes straight back along the
    /// table is a little less than this, exactly as it is on a cushion.
    ///
    /// How much that is worth is a matter of measure rather than of argument. The probe plays a fan of
    /// thirteen shots across a corner's mouth at one pace, and the corner takes nine of them, so the
    /// restitution is not what the corner's own behaviour turns on — the **grab** the facing has of
    /// the ball is, see `bounceOffThroat`.
    public static let throatRestitution = 0.5
    /// How much of the speed along a pocket's facing the facing takes out of a ball that meets it, as a
    /// fraction per contact: the facing grips what slides along it rather than letting it run.
    public static let throatFriction = 0.3
    /// Fraction of a hard, low tip's speed that lifts the ball off the cloth.
    ///
    /// A cue striking below the centre pinches the ball between the tip and the cloth, and the
    /// cloth springs back: a hard screw shot is played with the ball hopping a little, which is the
    /// one thing in the game that puts a ball in the air. How much of the pinch comes back is a
    /// judgement rather than a measurement — it depends on how the ball and the cloth deform, which
    /// this model does not simulate — so the figure is set to give the few millimetres a hard screw
    /// shot really has and nothing at all on a medium one.
    public static let hopFromALowTip = 0.12

    /// The most the cue may be lifted, in radians: the elevation the player sets with the mouse when
    /// the elevation key is held. The cue can be stood right up — 90°, straight down at the ball — for
    /// a full massé; the strike that comes of it is played along the cue's own axis, so a cue stood up
    /// drives the ball into the cloth rather than along it.
    public static let maxCueElevation = 90.0 * Double.pi / 180

    /// How low the dome of the cue's tip reaches, in millimetres above the cloth, when the tip's crown
    /// is at `tip` and the stick runs back along `axis`.
    ///
    /// The tip is a spherical cap of `Table.cueTipCurvature` centred on the stick's axis
    /// (`Table.cueGirth` is the half-width it is cut off at), so the lowest point of the tip is the
    /// point of that sphere pointing straight down — while that direction is within the cap. Once the
    /// cue is stood up past the cap's own half-angle, the *rim* is the lowest part instead, and it is
    /// the rim that reaches the cloth first.
    public static func theTipReachesDownTo(tip: Vec3, along axis: Vec3) -> Double {
        let curvature = Table.cueTipCurvature
        // The dome's own half-width is the **tip's** radius, and not the widest of the lengths behind
        // it: the cap is the leather at the very end of the stick, where the taper starts.
        let halfWidth = Table.cueTipRadius
        let halfAngle = asin(min(1, halfWidth / curvature))
        // The centre of curvature sits behind the crown, on the axis; the cap is the part of its sphere
        // within `halfAngle` of the axis.
        let centre = tip - axis * curvature
        let towardsTheCloth = Vec3(0, 0, -1)
        let angleBetween = acos(max(-1, min(1, towardsTheCloth.dot(axis))))
        // The cap's lowest point is the one whose own direction is nearest straight down, and a
        // direction `x` degrees from straight down stands `-cos(x)` of the way down.
        let lowestDirection = -cos(max(0, angleBetween - halfAngle))
        return centre.z + curvature * lowestDirection
    }

    /// Whether the cue can stand with its tip at `tip`, the stick running back along `axis`: the dome of
    /// the tip above whatever is under it — the cloth of the bed, the cloth on the wood of the rail, or
    /// the open floor of a pocket — and the stick itself clear of the cushion and the rail.
    ///
    /// This is what stops a cue driven on into the table: a follow-through is short because a real cue's
    /// tip comes up against the cloth, and a cue pushed across the table comes up against the cushion.
    public func theCueTipCanStand(at tip: Vec3, along axis: Vec3) -> Bool {
        // The cloth, or the wood of the surround, under the tip: over a pocket there is nothing under it,
        // and a tip may go down into the pocket's mouth.
        if let under = surfaceUnder(Vec2(tip.x, tip.y)),
           PhysicsWorld.theTipReachesDownTo(tip: tip, along: axis) < under {
            return false
        }
        // And the cushion and the rail, which the stick may not pass through either.
        let halfWidth = Table.cueTipRadius
        for wall in PhysicsWorld.surround where wall.distanceToTheWood(tip) < halfWidth {
            return false
        }
        return true
    }

    /// How much of the tip's grip the leather can give the ball: the coefficient of **static friction**
    /// between a well-chalked tip and a ball.
    ///
    /// It is the figure that decides where a tip lets go. The cue drives the ball along its own axis at
    /// an offset `b` from the middle of the ball, so the impulse has a part across the ball's face as
    /// well as into it: the sideways part is `b` and the part into the face is `sqrt(1 - (b/r)²)` of
    /// the whole. The tip keeps its grip while
    /// `b <= μ · sqrt(r² - b²)`, which is `b/r <= μ / sqrt(1 + μ²)`, and slips past it — a **miscue**,
    /// the tip skating off the ball with the shot's spin lost. Chalked leather on a phenolic ball is
    /// about 0.8, which puts the grip's own limit at `0.8 / √(1 + 0.8²)` — **0.625 of a ball radius**,
    /// further out than the half a radius a player takes as the edge of the ball they can hit safely.
    /// Past it the game settles the spin down to the limit rather than letting the tip slip: see
    /// `FrameDriver.setSpin`.
    public static let cueTipFriction = 0.8

    /// The furthest off the middle of the ball a tip can strike without slipping, in ball radii: the
    /// limit `cueTipFriction` puts on the offset, `μ / √(1 + μ²)` — 0.625 of a radius for the 0.8 of a
    /// chalked tip.
    public static var cueTipOffsetLimit: Double {
        let mu = cueTipFriction
        return mu / (1 + mu * mu).squareRoot()
    }

    /// How far off the middle the tip may be **put**, in ball radii: one radius, the edge of the ball.
    /// A tip further out than that is not touching the ball at all. The player is free to go all the
    /// way there — past the leather's own grip, where the strike slips and gives no more spin.
    public static let maximumTipOffset: Double = 1

    /// The speed the ball comes off a strike with, as a multiple of the cue's own speed, for a tip
    /// offset `k` of a ball radius: see `FrameDriver.ballSpeed`, of which this is the shape.
    static func strikeSpeed(_ k: Double) -> Double {
        (1 + cueTipRestitution) / (1 + 2.5 * k * k)
    }

    /// How fast the ball separates from the tip **along the cue's own line**, as a multiple of the
    /// cue's own speed, for a strike whose tip is `k` of a ball radius off centre in the direction
    /// `angle` — 0 across the ball to the striker's right, `π/2` up its face for follow — with the cue
    /// standing at `elevation`.
    ///
    /// A strike sends the ball away along the line of the cue at `strikeSpeed` times the cue's speed.
    /// For the stroke to be **one contact** the ball has to stay in front of the tip, so that the cue
    /// can never run it down — the double hit of Rule 11(a)(ii). Two things take that lead back:
    ///
    ///  * an elevated cue drives the ball **into the cloth**, and the part of the strike that goes down
    ///    is given up: the lead along the cue's line is `cos²θ` of the ball's speed, not all of it;
    ///  * the cloth answers with a normal impulse — what stops the ball going through the bed — and
    ///    with it a friction impulse of up to `μ` of that, along the ball's own surface slip at the
    ///    bed. That slip is where the tip's *direction* comes in: `u = (cosθ − 2.5k_up,
    ///    2.5k_side·sinθ)`, so a shot with the tip below the middle slides the bed the other way and
    ///    the friction pushes the ball **on**, while the tip above the middle has the friction holding
    ///    it back.
    ///
    /// The test is `separationAlongTheCue(…) ≥ 1`: the ball keeps at least the cue's own speed along
    /// the line of the cue, so no follow-through — however long or hard — can catch it. It is
    /// independent of the strength of the strike, which is why "hard enough" is all the assumption
    /// needed. At a level cue it comes to `1 + 2.5k² ≤ 1.75`, the `√0.3` of a radius the ball's own
    /// speed sets; elevation takes it in from there, and above about 37° it closes to nothing, because
    /// a cue pressed down on the ball only bounces it back up its own line.
    public static func separationAlongTheCue(offset k: Double, angle: Double,
                                             elevation: Double) -> Double {
        let sinT = sin(elevation), cosT = cos(elevation)
        let side = k * cos(angle), up = k * sin(angle)
        let alongTheSlip = cosT - 2.5 * up
        let acrossTheSlip = 2.5 * side * sinT
        let slip = (alongTheSlip * alongTheSlip + acrossTheSlip * acrossTheSlip).squareRoot()
        let frictionActs = slip > 1e-9 ? alongTheSlip / slip : 1
        return strikeSpeed(k) * (cosT * cosT - slidingFriction * sinT * cosT * frictionActs)
    }

    /// Where the tip may be put along one direction of the ball's face, of a ball radius.
    public struct SpinRange: Equatable, Sendable {
        public var lower: Double
        public var upper: Double
        public init(lower: Double, upper: Double) {
            self.lower = lower
            self.upper = upper
        }
    }

    /// The offsets along the direction `angle` that keep the ball in front of the cue, of a ball
    /// radius, with the cue standing at `elevation`: the leather's own grip, `cueTipOffsetLimit`, and
    /// inside that where `separationAlongTheCue` holds.
    ///
    /// There can be **more than one run of them**, and that is the point of the second one. Small
    /// offsets leave the ball under-spinning: its surface runs forward on the cloth, the bed's friction
    /// drags it back, and the ball loses its lead faster than the cue does. Past about `0.4` of a radius
    /// up the face — the offset that leaves the ball rolling naturally — the slip reverses, the friction
    /// pushes the ball **on**, and a run of larger offsets the cue cannot catch opens up again. So
    /// standing the cue up does not simply shrink the spin: at 30°, for instance, the follow side is
    /// `[0, 0.28]` **and** `[0.35, 0.41]`, with the gap between them dead. The boundary closes for good
    /// by about 36°, where even the largest offset that still leaves the ball moving cannot outrun a cue
    /// driven down on it.
    public static func spinRange(angle: Double, elevation: Double) -> [SpinRange] {
        let cap = cueTipOffsetLimit
        let steps = 600
        let step = cap / Double(steps)
        func outruns(_ k: Double) -> Bool {
            separationAlongTheCue(offset: k, angle: angle, elevation: elevation) > 1
        }
        func edge(_ inside: Double, goingUp: Bool) -> Double {
            var low = inside
            var high = inside + (goingUp ? step : -step)
            for _ in 0..<40 {
                let middle = (low + high) / 2
                if outruns(middle) { low = middle } else { high = middle }
            }
            return low
        }
        var ranges: [SpinRange] = []
        var runStart: Int?
        for index in 0...steps {
            if outruns(cap * Double(index) / Double(steps)) {
                if runStart == nil { runStart = index }
            } else if let start = runStart {
                let lower = start == 0 ? 0 : edge(cap * Double(start) / Double(steps), goingUp: false)
                let upper = edge(cap * Double(index - 1) / Double(steps), goingUp: true)
                ranges.append(SpinRange(lower: lower, upper: upper))
                runStart = nil
            }
        }
        if let start = runStart {
            let lower = start == 0 ? 0 : edge(cap * Double(start) / Double(steps), goingUp: false)
            ranges.append(SpinRange(lower: lower, upper: cap))
        }
        return ranges
    }

    /// The furthest out along `angle` that is still allowed: the outer end of the last run, or 0 where
    /// there is none. See `spinRange` for the runs themselves.
    public static func spinLimit(angle: Double, elevation: Double) -> Double {
        spinRange(angle: angle, elevation: elevation).last?.upper ?? 0
    }

    /// The nearest offset to `wanted` along `angle` that is allowed: the wanted offset itself when it
    /// is inside a run, and otherwise the end of the run nearest to it.
    public static func allowedSpin(_ wanted: Double, angle: Double, elevation: Double) -> Double {
        let runs = spinRange(angle: angle, elevation: elevation)
        guard !runs.isEmpty else { return 0 }
        var best = runs[0].lower
        var bestDistance = Double.greatestFiniteMagnitude
        for run in runs {
            if wanted >= run.lower, wanted <= run.upper { return wanted }
            for candidate in [run.lower, run.upper] where abs(candidate - wanted) < bestDistance {
                best = candidate
                bestDistance = abs(candidate - wanted)
            }
        }
        return best
    }

    /// The spin limit as the widget draws it: the outer edge of the allowed region, and the inner edge
    /// of any hole in it, each as `(side, vertical)` pairs of a ball radius round the directions in
    /// order. The inner outline is 0 at the angles where the region reaches the middle, so a caller
    /// drawing it leaves those angles out rather than closing the curve through them.
    public static func spinLimitOutline(elevation: Double, samples: Int = 180)
        -> (outer: [(side: Double, vertical: Double)], inner: [(side: Double, vertical: Double)]) {
        var outer: [(side: Double, vertical: Double)] = []
        var inner: [(side: Double, vertical: Double)] = []
        for index in 0..<samples {
            let angle = 2 * Double.pi * Double(index) / Double(samples)
            let runs = spinRange(angle: angle, elevation: elevation)
            let out = runs.last?.upper ?? 0
            let within = runs.first.map { $0.lower <= 1e-9 ? 0 : $0.lower } ?? 0
            outer.append((side: out * cos(angle), vertical: out * sin(angle)))
            inner.append((side: within * cos(angle), vertical: within * sin(angle)))
        }
        return (outer, inner)
    }

    /// Sliding friction along the **side** of the stick, if a ball runs into the shaft or the butt:
    /// varnished wood on a ball, and nothing like the grip of the tip's leather.
    public static let cueShaftFriction = 0.15
    /// Restitution of the side of the stick: varnished wood on a ball, which gives back about three
    /// fifths of what it takes — the tip's leather gives back more, and the cushion's rubber more again.
    public static let cueShaftRestitution = 0.6

    static let gravity = 9810.0

    public private(set) var balls: [Ball]
    public private(set) var events: [PhysicsEvent] = []
    /// How long the stroke has been running, in seconds: set to zero by the strike itself
    /// (`applyCueStrike`), and advanced by every step of the simulation after it. It is what times a
    /// second touch of the cue ball from the first.
    public private(set) var clock: Double = 0
    /// The largest distance a ball has been pushed in one step by the walls of a pocket, over the
    /// life of this world (millimetres). It is a diagnostic: a ball should be guided into a pocket
    /// by the shape of it rather than snapped onto the middle of the hole, and this is the measure
    /// of how much snapping is going on.
    public private(set) var largestPocketCorrection: Double = 0

    /// The ball last struck by the cue, which is the one the jump rule watches. It is remembered here
    /// rather than looked up, so that the physics does not have to know which id the game gives the
    /// cue ball.
    private var struckBall: Int?
    /// Whether the struck ball has hit another one since it was struck. A ball that has already hit
    /// one may jump over another (Section 2 Rule 20(a)); before that, going over any part of another
    /// ball is a jump shot. See `takeJumps`.
    private var struckBallHasHitABall = false
    /// The balls the struck ball has passed over since it was struck, so that a jump over one ball is
    /// reported once rather than on every step the ball is over it.
    private var jumpedOver: Set<Int> = []

    private let cushions: [Cushion]
    /// The rounded ends of the cushions, with the two things the collision needs beyond the circle:
    /// **where the round runs out into the pocket's throat** (`atTheThroat`, as a direction from the
    /// jaw's own axis) and whether this jaw stands at a **corner**, whose throat is a wall of its own.
    private let jawTips: [(centre: Vec2, radius: Double, side: CushionSide,
                           atTheThroat: Vec2, hasAThroat: Bool)]
    /// The straight sides of a **corner** pocket's throat: from where each jaw's round leaves off, down
    /// the cut to the hole, as the walls a ball meets once it is past the round.
    private let throats: [(a: Vec2, b: Vec2, inward: Vec2)]
    /// The cue, when the player has it on the table: the game sets its place and its speed, and the
    /// simulation carries it along and answers the balls it runs into. See `Cue`.
    public var cue: Cue?
    /// Which balls the cue is touching, so that going into contact with one is reported once rather
    /// than on every step the contact lasts.
    private var ballsTheCueIsTouching: Set<Int> = []
    /// The strike being played: the ball the tip has just taken, what the ball is going to leave with, and
    /// how far into the contact it is. Nil when no tip has the ball.
    ///
    /// A strike is not an instant. The tip takes the **standing** ball, the leather presses into it and
    /// springs back out of it, and the ball is at the speed and spin the strike is worth only once the tip
    /// has let it go: the contact is a spring with the ball at the end of it, and this is the two bodies of
    /// it. The whole of that moment is the stroke's **one** contact, so nothing is reported for it — and the
    /// ball is put in the set the cue is touching by hand, so that when the tip does let go there is nothing
    /// to report until something comes back to the stick. See `grabTheCueBall`.
    private struct CueContact {
        var ball: Int
        /// What the ball leaves with: its velocity, including the hop a low tip gives it, and its spin.
        var velocity: Vec3
        var spin: Vec3
        /// The speed the *tip* is going at, which the compression of the leather is read from. Set from the
        /// cue by `grabTheCueBall`.
        var tipSpeed: Double
        /// How long the tip is on the ball for — `cueTipContactSeconds(forCueSpeed:)`, set from the cue's own
        /// speed by `grabTheCueBall` — and how much of it has gone.
        var seconds: Double
        var elapsed: Double
    }
    private var cueContact: CueContact?

    /// Whether a strike's own **contact** is still being played: the tip has the ball and the ball has not
    /// got the strike's velocity and spin yet. A test or a probe that reads what a strike has done waits for
    /// this to be over. See `CueContact`.
    public var aStrikeIsBeingPlayed: Bool { cueContact != nil }
    /// Each pocket and its cut, in `PocketID.allCases` order. The cuts are worked out once: the
    /// simulation asks for them on every ball on every step.
    private let pockets: [(id: PocketID, cut: PocketCut)]
    /// The pockets as the balls meet them on every step, flattened out of the cuts: looking a ball up
    /// against six of `PocketCut`s, twelve fields apiece, on every ball on every step is a great deal
    /// of copying to ask one question about a circle.
    private let pocketGeometry: [PocketGeometry]

    /// One pocket as the balls meet it: the hole in the bed, and the passage the bed runs into.
    private struct PocketGeometry {
        let id: PocketID
        let holeCentre: Vec2
        let holeRadius: Double
        let mouth: Vec2
        let axis: Vec2
        let passage: Double
        let halfWidth: Double
    }

    public init(balls: [Ball]) {
        self.balls = balls
        self.cushions = PhysicsWorld.makeCushions()
        self.jawTips = PhysicsWorld.makeJawTips()
        self.throats = PhysicsWorld.makeThroats()
        self.pockets = PocketID.allCases.map { ($0, $0.cut) }
        self.pocketGeometry = self.pockets.map { (id, cut) in
            PocketGeometry(id: id, holeCentre: cut.holeCentre, holeRadius: cut.holeRadius,
                           mouth: cut.mouth, axis: cut.axis, passage: cut.passageLength,
                           halfWidth: cut.width / 2)
        }
    }

    // MARK: Table furniture

    private static func makeCushions() -> [Cushion] {
        let L = Table.length, W = Table.width
        let cg = Table.cornerJawGap, mg = Table.middleJawGap
        // The cushions stop where each jaw's round begins, so the round is the end of the cushion.
        let corner = Table.jawRadius / tan(67.5 * .pi / 180)      // the 135° corner at a corner pocket
        let middle = Table.jawRadius                               // the 90° corner at a middle pocket
        let a = cg + corner, m = mg + middle
        return [
            // The two long cushions (y = 0 and y = W) each carry a middle pocket, so
            // each is split into two segments.
            Cushion(side: .bottom, a: Vec2(a, 0), b: Vec2(L / 2 - m, 0), normal: Vec2(0, 1)),
            Cushion(side: .bottom, a: Vec2(L / 2 + m, 0), b: Vec2(L - a, 0), normal: Vec2(0, 1)),
            Cushion(side: .top, a: Vec2(a, W), b: Vec2(L / 2 - m, W), normal: Vec2(0, -1)),
            Cushion(side: .top, a: Vec2(L / 2 + m, W), b: Vec2(L - a, W), normal: Vec2(0, -1)),
            // The two short cushions have no middle pocket.
            Cushion(side: .left, a: Vec2(0, a), b: Vec2(0, W - a), normal: Vec2(1, 0)),
            Cushion(side: .right, a: Vec2(L, a), b: Vec2(L, W - a), normal: Vec2(-1, 0)),
        ]
    }

    /// Rounded ends of the cushions at each pocket opening; balls bounce off these, which is what
    /// makes a ball rattle in the jaws rather than always drop.
    ///
    /// Each jaw is the round of `Table.jawRadius` the cushion is cut back with where it meets the
    /// pocket: it is tangent to the cushion's face and to the throat, so a ball running along the
    /// cushion leaves the cushion where the round begins and grazes round the jaw.
    private static func makeJawTips() -> [(centre: Vec2, radius: Double, side: CushionSide,
                                            atTheThroat: Vec2, hasAThroat: Bool)] {
        PocketID.allCases.flatMap { pocket in
            let cut = pocket.cut
            return [cut.jaws.0, cut.jaws.1].map {
                (centre: $0.centre, radius: $0.radius, side: PhysicsWorld.side(of: $0.tip),
                 atTheThroat: $0.atTheThroat - $0.centre, hasAThroat: pocket.isCorner)
            }
        }
    }

    /// The straight sides of every **corner** pocket's throat, as the walls the balls meet.
    ///
    /// A corner takes the ball off two cushions at once and at any angle across a quarter of the
    /// table, so a ball very often comes into its mouth *along* the throat rather than across it: the
    /// contact it makes is on the last of the jaw's round, where the round is meeting the throat, and
    /// a ball met there by rubber is thrown back across the mouth and out. Past that line the surface
    /// is the pocket's own facing, and the throat is what a ball is played on back there — see
    /// `bounceOffThroat`. The middle pockets have the same cut, but a ball crosses their throats
    /// squarely and meets the hole before the facing has anything to say, so they are left as they are.
    private static func makeThroats() -> [(a: Vec2, b: Vec2, inward: Vec2)] {
        PocketID.allCases.filter(\.isCorner).flatMap { pocket -> [(a: Vec2, b: Vec2, inward: Vec2)] in
            let cut = pocket.cut
            return [cut.jaws.0, cut.jaws.1].map { jaw in
                // Along the throat, from where the round leaves off to the point level with the hole.
                let a = jaw.atTheThroat
                let toTheHole = (cut.holeCentre - a).dot(cut.axis)
                let b = a + cut.axis * max(0, toTheHole)
                // And inward: the way across the throat, towards the pocket's own axis.
                let toTheMiddle = cut.mouth - a
                let inward = (toTheMiddle - cut.axis * toTheMiddle.dot(cut.axis)).normalized
                return (a: a, b: b, inward: inward)
            }
        }
    }

    /// Which cushion a tip stands at the end of, from its place on the table.
    private static func side(of tip: Vec2) -> CushionSide {
        if abs(tip.y) < 1e-9 { return .bottom }
        if abs(tip.y - Table.width) < 1e-9 { return .top }
        if abs(tip.x) < 1e-9 { return .left }
        return .right
    }

    /// The nearest point of the segment `a`–`b` to `p`.
    private static func nearestPoint(_ p: Vec2, from a: Vec2, to b: Vec2) -> Vec2 {
        let ab = b - a
        let lengthSquared = ab.lengthSquared
        guard lengthSquared > 0 else { return a }
        let t = max(0, min(1, (p - a).dot(ab) / lengthSquared))
        return a + ab * t
    }

    /// How far a ball's centre is from the nearest part of a cushion's face, and which way the face
    /// points there, worked in the vertical section square to the run.
    ///
    /// `out` is distance into the table from the line of the nose — the line the rules measure the
    /// playing area to, where the square band over the nose stands — and `up` is height above the
    /// cloth. The cushion's material lies at `out <= face(up)`, and the section is the shape of a
    /// real cushion, the same one `Table3D` draws:
    ///
    ///  * the **leaning side**, from its foot at the cloth set back behind the nose
    ///    (`Table.cushionFootSetback`), rising into the table at `Table.cushionFaceDegrees`;
    ///  * the **round** of `Table.cushionNoseRound` that carries the lean into the square band; and
    ///  * the **square band**, standing on the nose line up to the cushion's top.
    ///
    /// The normal returned points out of the cushion into the playing area, so its second part is
    /// negative where the face leans back under the nose: a ball on the cloth meets the nose above
    /// its own equator, and the cushion answers along a line that is angled down as well as in.
    static func cushionFace(out: Double, up: Double) -> (distance: Double, normal: Vec2) {
        let nose = Table.cushionNoseHeight
        let top = Table.cushionHeight
        let round = Table.cushionNoseRound
        let alpha = Table.cushionFaceDegrees * .pi / 180
        let foot = Vec2(-Table.cushionFootSetback, 0)
        // The round's centre stands `round` behind the nose line and `round` clear of the lean.
        let centre = Vec2(-round, nose + round * (1 - sin(alpha)) / cos(alpha))
        let onTheLean = centre + Vec2(round * sin(alpha), -round * cos(alpha))
        let onTheBand = Vec2(0, centre.y)
        let bandTop = Vec2(0, top)

        let p = Vec2(out, up)
        var candidates = [
            nearestPoint(p, from: foot, to: onTheLean),
            nearestPoint(p, from: onTheBand, to: bandTop),
        ]
        // The round, when p is either off its flat neighbours or pressed inside it. Its own arc runs
        // from the point it leaves the lean to the point it reaches the band.
        let spoke = p - centre
        let turn = atan2(spoke.y, spoke.x)
        if spoke.length < round || (turn >= alpha - .pi / 2 && turn <= 0) {
            candidates.append(centre + spoke.normalized * round)
        }

        var best = (distance: Double.greatestFiniteMagnitude, normal: Vec2(1, 0))
        for q in candidates {
            let away = p - q
            let length = away.length
            guard length > 1e-9 else { continue }
            if length < best.distance { best = (length, away / length) }
        }
        return best
    }

    /// Where the rounded jaws stand: a circle of `Table.jawRadius` at each end of every cushion
    /// run, which is both what a ball bounces off here and what `Table3D` draws. Exposed so the
    /// opening the rules fix can be checked against the shape the ball is played on.
    public static var jawCircles: [(centre: Vec2, radius: Double)] {
        makeJawTips().map { (centre: $0.centre, radius: $0.radius) }
    }

    /// One side of the table's surround — the cushion along that side and the wood of the rail behind
    /// it — as a wall the cue cannot pass through.
    ///
    /// A ball meets the cushion's own section (see `cushionFace`), but a cue is a stick passing *over*
    /// the cushion, and what it meets there is the whole surround as one piece: the leaning face of the
    /// cushion from the cloth up to the nose, the square band above it, and — at the same height, since
    /// the top of a rail is cut to the top of its cushion — the flat wood running out to the table's
    /// outer edge. In section it is one wall whose front is the cushion's face and whose top is
    /// `Table.cushionHeight`, so the cue clears it exactly when it passes over that top.
    ///
    /// The pocket mouths are not cut out of it. A cue running over the jaws is a cue running out of the
    /// playing area at the one place the cushion is interrupted, and treating the wall as unbroken there
    /// keeps the cue out of the pockets' wood as well; the cost is that a cue laid across a pocket mouth
    /// is judged against the cushion that is missing rather than the hole below it.
    private struct Wall {
        /// The inward normal of the nose line.
        let normal: Vec2
        /// Where the nose line stands: `normal · p` for any point `p` on it.
        let standOff: Double

        /// How far a point stands out from the nose line, positive into the playing area.
        func out(_ p: Vec2) -> Double { normal.dot(p) - standOff }

        /// How far a point stands from the wood and rubber of this side of the surround — the leaning
        /// face under the nose, the square band above it and the flat top of the rail behind — and 0
        /// when the point is inside it.
        ///
        /// The section is the shape `cushionFace` gives a ball and `Table3D` draws: the face leaning
        /// back at `Table.cushionFaceDegrees` from its foot to the nose, the square band standing on the
        /// nose line above that, and the top of the rail cut to the same height as the top of the
        /// cushion. A point is inside when it is behind the face at its own height and below the top;
        /// otherwise the answer is the nearest of those three surfaces.
        func distanceToTheWood(_ p: Vec3) -> Double {
            let out0 = out(Vec2(p.x, p.y))
            let z = p.z
            let nose = Table.cushionNoseHeight
            let top = Table.cushionHeight
            let slope = 1 / tan(Table.cushionFaceDegrees * .pi / 180)
            // The face at this height: the leaning side below the nose, the square band above it.
            let face = z <= nose ? (-Table.cushionFootSetback + slope * z) : 0
            if z <= top, out0 <= face { return 0 }
            let q = Vec2(out0, z)
            let foot = Vec2(-Table.cushionFootSetback, 0)
            let atTheNose = Vec2(0, nose)
            var best = Double.greatestFiniteMagnitude
            func keep(_ boundary: Vec2) { best = min(best, q.distance(to: boundary)) }
            keep(PhysicsWorld.nearestPoint(q, from: foot, to: atTheNose))            // the leaning face
            keep(PhysicsWorld.nearestPoint(q, from: atTheNose, to: Vec2(0, top)))    // the square band
            // The flat top of the rail runs out over the wood from the nose line.
            keep(out0 <= 0 ? Vec2(out0, top) : Vec2(0, top))
            return best
        }
    }

    /// The four sides of the surround, as the cue meets them. Each is the cushion's face swept along
    /// the whole side — see `Wall`.
    private static let surround: [Wall] = [
        Wall(normal: Vec2(0, 1), standOff: 0),                 // the bottom cushion, y = 0
        Wall(normal: Vec2(0, -1), standOff: -Table.width),     // the top cushion, y = width
        Wall(normal: Vec2(1, 0), standOff: 0),                 // the left cushion, x = 0
        Wall(normal: Vec2(-1, 0), standOff: -Table.length),    // the right cushion, x = length
    ]

    // MARK: State queries

    public var allAtRest: Bool {
        // A ball that is spinning is still moving, even with no speed to speak of: the spin is
        // about to be turned into motion by the cloth. Ignoring that ended a stroke while the cue
        // ball was still following through, which is exactly what a second collision leaves behind.
        // A ball that is off the cloth — in the air, or dropping into a pocket — is moving too: the
        // stroke cannot be over until every ball has come back to the bed or is down a pocket.
        !balls.contains { $0.onTable && !atRest($0) }
    }

    /// Whether a ball has come to rest where it is: nothing left of its speed or its spin, and sitting
    /// on whatever is under it — the cloth of the bed, or the cloth on the wood of a rail.
    private func atRest(_ ball: Ball) -> Bool {
        let stirring = Self.restSpeed / Table.ballRadius
        guard ball.velocity.length <= Self.restSpeed,
              ball.spin.length <= stirring,
              abs(ball.verticalVelocity) <= Self.restSpeed,
              let under = surfaceUnder(ball.position) else { return false }
        return abs(ball.height - Table.ballRadius - under) <= 0.5
    }

    /// How high the surface under a ball's centre stands above the cloth: the bed (0), the cloth on the
    /// wood of the surround (`Table.cushionHeight`), or nothing at all. Nothing means a hole — a ball
    /// over a pocket, which is cut through whatever was under it — or the floor, out past the wood of
    /// the rail.
    ///
    /// The wood is the ring between the playing area and the table's own outer edge, less the pockets:
    /// a pocket's mouth and throat are cut through the rail, so a ball there is over the pocket rather
    /// than on the wood (`inAPocket`). Over the playing area the bed is the surface, and a pocket's
    /// hole in it is left to `pocketUnder`, which knows the hole's rim from the cloth around it.
    private func surfaceUnder(_ position: Vec2) -> Double? {
        // A ball well inside the playing area is on the bed: the pockets are all cut within a ball's
        // width of the cushions, so there is nothing else to ask about.
        let clearOfEveryPocket = position.x > Table.ballDiameter
            && position.x < Table.length - Table.ballDiameter
            && position.y > Table.ballDiameter
            && position.y < Table.width - Table.ballDiameter
        if clearOfEveryPocket { return 0 }
        // A hole is a hole, whatever is under it and whatever is over it.
        if pocketIndexOfTheHole(under: position) != nil { return nil }
        // The bed runs on into the pockets' throats: a ball rolling in off the cloth is carried by the
        // cloth until its centre crosses the hole's rim, which is what `contains` has just asked about.
        if inThePlayingArea(position) || inAPocketPassage(position) { return 0 }
        let surround = Table.tableSurround
        let overTheWood = position.x >= -surround && position.x <= Table.length + surround
            && position.y >= -surround && position.y <= Table.width + surround
        return overTheWood ? Table.cushionHeight : nil
    }

    private func inThePlayingArea(_ position: Vec2) -> Bool {
        position.x >= 0 && position.x <= Table.length && position.y >= 0 && position.y <= Table.width
    }

    /// Whether a ball's plan position is in a pocket's **passage**: the throat between the mouth and the
    /// hole, through which the bed still runs and over which the cloth still carries a ball.
    private func inAPocketPassage(_ position: Vec2) -> Bool {
        for pocket in pocketGeometry {
            let offset = position - pocket.mouth
            let along = offset.dot(pocket.axis)
            let across = abs(offset.dot(pocket.axis.perpendicular))
            if along >= 0, along <= pocket.passage, across <= pocket.halfWidth { return true }
        }
        return false
    }

    /// Which pocket's hole a ball's centre is over, if any.
    private func pocketIndexOfTheHole(under position: Vec2) -> Int? {
        for index in pocketGeometry.indices {
            let pocket = pocketGeometry[index]
            let dx = position.x - pocket.holeCentre.x
            let dy = position.y - pocket.holeCentre.y
            if dx * dx + dy * dy <= pocket.holeRadius * pocket.holeRadius { return index }
        }
        return nil
    }

    public func index(of id: Int) -> Int? {
        balls.firstIndex { $0.id == id }
    }

    public func ball(id: Int) -> Ball? {
        balls.first { $0.id == id }
    }

    public func setBall(_ ball: Ball) {
        if let i = index(of: ball.id) { balls[i] = ball }
    }

    /// Where a ball's centre would first reach a cushion — or the round at the end of one — if it
    /// were sent from `origin` along `direction` and nothing else got in the way.
    ///
    /// The point is the ball's own centre, standing a radius off the cushion, which is where the ball
    /// would come to rest against it: the ghost a player wants to see when they are aiming at a
    /// cushion rather than at a ball. `distance` is how far along the line it is.
    public func firstCushionContact(from origin: Vec2, direction: Vec2)
        -> (point: Vec2, side: CushionSide, distance: Double)? {
        let dir = direction.normalized
        guard dir.length > 0 else { return nil }
        var best: (point: Vec2, side: CushionSide, distance: Double)?
        func keep(_ point: Vec2, _ side: CushionSide) {
            let distance = (point - origin).dot(dir)
            guard distance > 1e-9 else { return }
            // Only a point the ball would really be at on this line: the line from the origin has to
            // pass through it.
            guard (origin + dir * distance).distance(to: point) < 0.001 else { return }
            if best == nil || distance < best!.distance { best = (point, side, distance) }
        }

        for cushion in cushions {
            // The face: the ball meets the nose, which stands above its centre, so its centre comes
            // in `cushionRestReach` — a hair inside a radius — before the ball touches the line of
            // the face. See `bounceOffSegment`.
            let closing = dir.dot(cushion.normal)
            guard closing < -1e-9 else { continue }
            let along = (Table.cushionRestReach - (origin - cushion.a).dot(cushion.normal)) / closing
            guard along > 1e-9 else { continue }
            let contact = origin + dir * along
            // And only while the ball is alongside this run, not past the end of it into the jaw.
            let run = cushion.b - cushion.a
            let offset = (contact - cushion.a).dot(run) / run.lengthSquared
            guard offset >= 0, offset <= 1 else { continue }
            keep(contact, cushion.side)
        }

        for jaw in jawTips {
            // The round at the end of a cushion: the ball's centre comes within its own reach of the
            // jaw's round, and that reach is the same one the straight runs use — the ball tucks under
            // the nose there too. See `bounceOffJaw`.
            let toTheCentre = jaw.centre - origin
            let reach = Table.cushionRestReach + jaw.radius
            let closest = toTheCentre.dot(dir)
            let squared = toTheCentre.lengthSquared - closest * closest
            guard squared <= reach * reach else { continue }
            let distance = closest - (reach * reach - squared).squareRoot()
            guard distance > 1e-9 else { continue }
            keep(origin + dir * distance, jaw.side)
        }
        return best
    }

    // MARK: The room behind the ball

    /// The angle the cue actually stands at, for the lift the elevation control is asking for: never
    /// flatter than the player's own stance gives it (`Table.cueStanceElevationDegrees`) and never
    /// further up than a cue can be stood without scooping the ball.
    ///
    /// The elevation *is* that angle — the widget reads it, the cue is drawn at it, the room behind the
    /// ball is judged on it and the strike is played along it — so this only has work to do for a caller
    /// that asks for a lift below the stance's own floor.
    public static func cueLean(at elevation: Double) -> Double {
        min(maxCueElevation, max(Table.cueStanceElevation, elevation))
    }

    /// Where the cue's own line lies at a pose: the point on the ball's face the tip strikes, and the
    /// unit vector the stick runs back along from there.
    ///
    /// The line runs **through the tip's contact**, not through the middle of the ball. A tip struck up
    /// the face or out at the side meets the ball there, and the stick behind it is carried up or over
    /// with it — which is the whole of "the cue moves when spin is added", and it is the same
    /// construction `applyCueStrike` uses, so what the stick is judged against is the line the ball
    /// will be struck along. The one place it pays more than it costs: a tip struck up the ball lifts
    /// the line of the stick, so a topped ball can be struck where a level one has no room.
    public static func cueLine(ballCentre: Vec3, yaw: Double, elevation: Double,
                               side: Double, vertical: Double) -> (tip: Vec3, axis: Vec3) {
        let r = Table.ballRadius
        let lift = cueLean(at: elevation)
        let s = max(-maximumTipOffset, min(maximumTipOffset, side)) * r
        let h = max(-maximumTipOffset, min(maximumTipOffset, vertical)) * r
        let dir = Vec2(cos(yaw), sin(yaw))
        // The striker's left, as `applyCueStrike` has it: side spin sends the contact across to the
        // right, which is the other way.
        let across = Vec3(-dir.y, dir.x, 0)
        let tip = Vec3(ballCentre.x, ballCentre.y, ballCentre.z)
            + Vec3(dir.x * sin(lift), dir.y * sin(lift), cos(lift)) * h
            - across * s
        return (tip, Vec3(dir.x * cos(lift), dir.y * cos(lift), -sin(lift)))
    }

    /// Whether the cue can be laid at the ball and played at this pose — the stick being a stick: its
    /// whole length behind the tip, at its own thickness, at the angle it stands at, with the tip where
    /// the player's spin is striking the ball, and with room for the **stroke**.
    ///
    /// `draw` is how far back from its rest place the player takes the tip; the tip travels from the
    /// ball's face out to there, and the stick has to be clear of every place it passes through on the
    /// way — so what is judged is the cue *swept* over that travel, which is the cue itself with the
    /// butt's length of it carried on by the distance the butt moves. That matters where a cushion is
    /// behind the ball: the tip can be in a place it fits (against the ball, tucked under the nose) and
    /// still have nowhere to go as it comes back, and it is the coming back that has to be clear.
    ///
    /// The cue is judged as the tapered lengths of `Table.cueGirth`, so the thin tip is not made to keep
    /// the butt's distance and the fat butt is not allowed the tip's. Balls are checked as the capsules
    /// they are, exactly. The surround is walked a step at a time (`cueStep`), because its face leans,
    /// its nose overhangs and the stick's own thickness changes as it goes: the samples are close
    /// enough together that the spheres of the step overlap, which is what makes walking it the same as
    /// covering it.
    public func cueFits(cueBallID: Int, yaw: Double, elevation: Double, side: Double = 0,
                        vertical: Double = 0, draw: Double = 0) -> Bool {
        guard let cueBall = ball(id: cueBallID) else { return true }
        let (tip, axis) = PhysicsWorld.cueLine(
            ballCentre: Vec3(cueBall.position.x, cueBall.position.y, cueBall.height),
            yaw: yaw, elevation: elevation, side: side, vertical: vertical)
        // The stick swept over the stroke: the tip's end travels from the ball out to the drawn place,
        // and the butt travels the same distance beyond where the cue's own length already puts it.
        let travel = Table.cueTipGap + max(0, draw)
        let butt = Table.cueGirth[Table.cueGirth.count - 2]
        let bumper = Table.cueGirth[Table.cueGirth.count - 1]
        var girths = Array(Table.cueGirth.dropLast(2))
        girths.append((front: butt.front, back: butt.back + travel, radius: butt.radius))
        girths.append((front: bumper.front + travel, back: bumper.back + travel,
                       radius: bumper.radius))

        for other in balls where other.onTable && other.id != cueBall.id {
            let centre = Vec3(other.position.x, other.position.y, other.height)
            for girth in girths {
                let near = tip - axis * girth.front
                let far = tip - axis * girth.back
                if PhysicsWorld.distance(from: centre, toTheSegment: near, far)
                    < Table.ballRadius + girth.radius { return false }
            }
        }

        // Only the sides the cue runs at can stop it: one it never comes within a hand's width of costs
        // nothing to skip, and most shots are nowhere near three of the four.
        let farEnd = tip - axis * (girths.last?.back ?? Table.cueLength)
        let walls = PhysicsWorld.surround.filter { wall in
            min(wall.out(Vec2(tip.x, tip.y)), wall.out(Vec2(farEnd.x, farEnd.y))) < 20
        }
        for girth in girths {
            var along = girth.front
            while true {
                let point = tip - axis * along
                for wall in walls where wall.distanceToTheWood(point) < girth.radius {
                    return false
                }
                if along >= girth.back { break }
                along = min(along + PhysicsWorld.cueStep, girth.back)
            }
        }
        return true
    }

    /// How far apart the samples down the cue are when it is judged against the surround, in
    /// millimetres. Short enough that the samples' spheres overlap at the tip, the thinnest part of the
    /// stick, so walking the cue is the same as covering the whole of it.
    static let cueStep: Double = 5.0

    /// The distance from a point to a line segment, in three dimensions.
    private static func distance(from p: Vec3, toTheSegment a: Vec3, _ b: Vec3) -> Double {
        let ab = b - a
        let lengthSquared = ab.dot(ab)
        guard lengthSquared > 0 else { return (p - a).length }
        let t = max(0, min(1, (p - a).dot(ab) / lengthSquared))
        return (p - (a + ab * t)).length
    }

    // MARK: Cue strike

    /// Begins a cue strike. `power` is the ball's speed along the cue in mm/s, `side` and `vertical`
    /// are the tip's offsets from the middle of the ball as a fraction of its radius (clamped to
    /// `cueTipOffsetLimit`, the leather's own grip), and `elevation` is the angle the cue stands at, in
    /// radians — the cue's own elevation, which the game keeps at or above the player's stance
    /// (`Table.cueStanceElevation`) even though a raw call
    /// here may pass anything (`PhysicsWorld.cueLean` is what the game asks for).
    ///
    /// Everything comes out of the one impulse. The tip strikes along the **cue's own axis**, at a
    /// point on the ball's face square to that axis, so the velocity the ball takes is along the axis
    /// and the spin is the impulse's moment about the middle of the ball,
    /// `omega = (5 / 2 r²) (r_tip × J)`. Level, that is the old `omega = (5 v / 2 r²)(h t + s z)`
    /// exactly; lifted, the spin axis tilts with the cue — side spin gains a barrel of spin about the
    /// line of the shot, and the ball is driven down into the cloth — and that tilt is what the cloth
    /// turns into the curve of a swerve.
    ///
    /// What the impulse works out is what the ball is **going to leave with**: the strike is not an instant,
    /// and the ball has that velocity and spin only when the tip has pressed into it and let it go. This
    /// begins the **contact**; `resolveTheCue` drives the ball through it, and `grabTheCueBall` — which a
    /// stroke calls the moment it has struck — reads the tip's own time on the ball off the cue's speed. A
    /// strike played with no cue on the table is on the ball for the tip's time for the speed the strike is
    /// worth. See `CueContact`.
    public func applyCueStrike(cueBallID: Int, direction: Vec2, power: Double, side: Double,
                               vertical: Double, elevation: Double = 0) {
        guard let i = index(of: cueBallID) else { return }
        let dir = direction.normalized
        guard dir.length > 0 else { return }
        let r = Table.ballRadius
        let s = max(-Self.cueTipOffsetLimit, min(Self.cueTipOffsetLimit, side)) * r
        let h = max(-Self.cueTipOffsetLimit, min(Self.cueTipOffsetLimit, vertical)) * r
        let lift = max(0, min(Self.maxCueElevation, elevation))
        // The stroke starts here: the clock a second touch of the cue ball is timed against.
        clock = 0
        let sinLift = sin(lift), cosLift = cos(lift)

        // The cue's own frame: the impulse goes along the cue towards the ball (when the butt is up the
        // tip drives *down*), `upTheFace` is square to it in the shot's vertical plane, and `across` is
        // the aim turned a quarter turn — which is the striker's left.
        let across = Vec3(dir.perpendicular.x, dir.perpendicular.y, 0)
        let upTheFace = Vec3(dir.x * sinLift, dir.y * sinLift, cosLift)
        // Where the tip strikes: `vertical` up the face, `side` to the striker's right, which is the
        // other way from `across`.
        let tip = upTheFace * h - across * s

        // A touch of squirt: the ball leaves away from the side the tip struck, so right side sends
        // it slightly to the left. Then the impulse itself, along the cue.
        let squirt = 0.022 * (s / r)
        let struckDir = Vec2(dir.x * cos(squirt) - dir.y * sin(squirt),
                             dir.x * sin(squirt) + dir.y * cos(squirt))
        let impulse = Vec3(struckDir.x * cosLift, struckDir.y * cosLift, -sinLift) * power
        var omega = tip.cross(impulse) * (5.0 / (2 * r * r))

        // A lifted cue drives the ball into the cloth, and the cloth gives back some of the press as a
        // hop; a level cue with the tip below the middle pinches the ball the same way. A level cue at
        // the middle leaves the ball on the cloth.
        let leaving = Vec3(impulse.x, impulse.y,
                           impulse.z + max(0, -h / r) * Self.hopFromALowTip * power * cosLift)
        omega.z = max(-260, min(260, omega.z))
        // The ball does **not** leave yet. A strike is not an instant: the tip takes the ball — standing
        // where it is — and the leather presses into it and springs back out, and the ball has the velocity
        // and spin above only once the tip has let it go. What this does is *begin* the contact; the ball
        // is driven through it a step at a time by `resolveTheCue`. See `CueContact`.
        //
        // The contact's own two figures are the tip's, and the tip's speed is the ball's put back through
        // the strike — `(1 + e) V / (1 + 2.5k²)` the other way about. A strike played with the cue on the
        // table has `grabTheCueBall` refine them from the cue's actual speed, which is the same figure read
        // off the stick itself; one played without it, as a test or a probe may, is read from the strike.
        let offset = min(1, (s * s + h * h).squareRoot() / r)
        let tipSpeed = power / Self.strikeSpeed(offset)
        cueContact = CueContact(ball: cueBallID, velocity: leaving, spin: omega, tipSpeed: tipSpeed,
                                seconds: Self.cueTipContactSeconds(forCueSpeed: tipSpeed), elapsed: 0)
        balls[i].height = Table.ballRadius
        balls[i].onTable = true
        balls[i].pottedInto = nil
        struckBall = cueBallID
        struckBallHasHitABall = false
        jumpedOver.removeAll()
    }

    // MARK: Integration

    /// Advances the simulation by `dt` seconds, subdividing so no ball jumps more than
    /// ~1.5 mm in a single integration step (keeps collisions and pockets reliable).
    public func step(dt: Double) {
        var remaining = dt
        while remaining > 1e-9 {
            // A step is short enough that no ball moves more than a millimetre and a half in it — and short
            // enough for a strike's own **contact**, where the ball goes from standing to the speed of the
            // shot in about a millisecond. A contact is not resolved by one four-millisecond step: the
            // whole of it happens between two of the ball's positions, and the ball loses the first half of
            // its first frame of travel — which is what let a hard charged shot's own follow-through, jumping
            // forward once a frame, land inside the ball it had just sent away. See `CueContact`.
            var maxSpeed = balls.filter { $0.onTable }.map { $0.velocity.length }.max() ?? 0
            if let contact = cueContact { maxSpeed = max(maxSpeed, contact.velocity.length) }
            let cap = maxSpeed > 1 ? 1.5 / maxSpeed : remaining
            let h = min(remaining, cap, 1.0 / 240.0)
            clock += h
            integrate(h)
            resolveCollisions(over: h)
            resolveTheCue(dt: h)
            settleVertically(h)
            remaining -= h
        }
        takeJumps()
        takeBallsOffTheTable()
        fallToTheFloor(dt)
    }

    /// The tip has struck the ball: it has **hold of it** for a moment, and is carried with it. The whole
    /// moment is the one contact the stroke is made of, so nothing is reported for it; the ball is put
    /// in the set of balls the cue is touching by hand, so that when the tip lets go and the ball runs
    /// free there is nothing to report until it — or another ball — comes back to the stick.
    ///
    /// The hold is the contact itself: the leather is on the ball for the Hertz contact time of the
    /// strike it is playing — see `cueTipContactSeconds(forCueSpeed:)` — so a firmer shot is on the ball
    /// for less of it. It is read off the cue's own speed, which is the only thing the two ways of
    /// playing a stroke differ in, so a shot played by hand and one played by charge are each held for
    /// what their own strike is worth.
    public func grabTheCueBall(_ id: Int, with cue: Cue) {
        self.cue = cue
        guard index(of: id) != nil else { return }
        // How long the tip is on the ball is the contact's own Hertz time, read off the speed the cue is
        // going at: a firmer shot is on the ball for less of it. See `cueTipContactSeconds(forCueSpeed:)`.
        cueContact?.seconds = PhysicsWorld.cueTipContactSeconds(forCueSpeed: cue.speed)
        cueContact?.tipSpeed = cue.speed
        ballsTheCueIsTouching.insert(id)
    }

    /// Whether the ball `id` is on the stick: in the tip's own hold after a strike, or touching it.
    ///
    /// It is how the stroke outside the physics tells when the **cue ball has left the cue** — the last
    /// moment the leather has it, which is where a charged shot's follow-through takes its beat. See
    /// `FrameDriver.carryTheChargedFollowThrough`.
    public func theCueIsOn(_ id: Int) -> Bool {
        ballsTheCueIsTouching.contains(id)
    }

    /// How far the stick is to be carried **this frame**, in millimetres along its own axis, and the speed it
    /// is being driven at. The stroke hands the travel in once a frame — see `FrameDriver.carryCue` — and the
    /// simulation **walks it out a step at a time**, with the balls: the tip goes along with them rather than
    /// jumping a whole frame's worth once a frame.
    ///
    /// That is the whole of the cue's physics after the strike, and it is what a real stick does. A cue going
    /// at a constant speed can never run down a ball it has sent away, because the ball leaves at `1 + e`
    /// times the cue's speed and the gap only grows; and a cue *can* still catch a ball that has been stopped
    /// by an object ball, which is the double hit a real player cannot play out of when the cue ball is close
    /// to what it is playing at — the very shot the foul exists to prevent. See `resolveTheCue`.
    public var theCueIsToBeCarriedBy: Double = 0
    /// The speed the stroke is driving the stick at, in mm/s: what the tip's own surface is doing at anything
    /// it meets, and the rate the travel above is walked out at.
    public var theCueIsDrivenAt: Double = 0
    /// How much of it the frame's steps have made. The stroke sets it back to nothing as it hands the frame's
    /// travel in, and reads it back for the speed it is showing.
    public var theCueWasCarriedBy: Double = 0

    /// Answers every ball the cue has run into.
    ///
    /// The cue's **travel** is the player's, step by step: the stroke asks for so many millimetres a frame
    /// and this walks them out (see `theCueIsToBeCarriedBy`), so a stick left alone stays where it is left
    /// and one being moved goes **with the balls** rather than jumping a frame's worth at once. What the cue
    /// has besides its place is a **speed**, which is what its surface is doing at the contact. The cue does
    /// not budge for a ball either — it is the player's hand and has infinite mass — so a contact is the
    /// ball's alone to answer: it is pushed out of the stick, turned along
    /// the contact normal with the restitution of whatever part it met, and rubbed along the face by
    /// that part's friction. A ball met by the **tip's face** is struck along the cue's own axis (the
    /// leather deforms over the ball and pushes it squarely); one met by the **side** of the shaft or
    /// the butt is pushed away from the axis. Either way it is a ball in play contacted by the player's
    /// equipment, which the rules call a foul (Rule 11(b)(vi)), so the contact is reported.
    private func resolveTheCue(dt: Double) {
        // The stick's **own travel** for this frame, walked out with the balls: it is what the stroke's hand —
        // the player's or the game's — has asked for, and making it a step at a time is the whole of the cue's
        // physics after the strike. A cue going at a constant speed cannot run down the ball it has sent away
        // (the ball leaves at `1 + e` times the cue's speed and the gap only grows), and it *can* still catch a
        // ball that has been stopped by an object ball — the double hit a real player cannot play out of when
        // the cue ball is close to what it is playing at. See `theCueIsToBeCarriedBy`.
        let stillToBeCarried = theCueIsToBeCarriedBy - theCueWasCarriedBy
        if cueContact == nil, stillToBeCarried != 0 {
            // Not while the tip has the ball: it is the ball's own then, and is placed by it.
            let asked = theCueIsDrivenAt * dt
            let travel = abs(asked) < abs(stillToBeCarried) ? asked : stillToBeCarried
            theCueWasCarriedBy += carryTheCueTip(alongTheAxisBy: travel)
        }

        // The **contact** of the strike being played comes first, and whether or not a cue is drawn: the tip
        // has the ball and the ball is driven through the contact, and that is what the ball's velocity and
        // spin are made of. See `CueContact`.
        var held: CueContact?
        if var contact = cueContact, let i = index(of: contact.ball) {
            contact.elapsed += dt
            let share = contact.seconds > 0 ? min(1, contact.elapsed / contact.seconds) : 1
            // The ball is driven by the tip through the contact: it is standing when the tip takes it, and it
            // has the whole of the strike's velocity and spin when the leather lets go.
            let through = PhysicsWorld.cueContactShape(share)
            balls[i].velocity = Vec2(contact.velocity.x, contact.velocity.y) * through
            balls[i].verticalVelocity = contact.velocity.z * through
            balls[i].spin = contact.spin * through
            held = contact
            if contact.elapsed >= contact.seconds {
                // The leather has let go. The ball is left **exactly** at what the strike was worth, so that
                // the step the contact happened to end on is not asked to be the last word on it.
                balls[i].velocity = Vec2(contact.velocity.x, contact.velocity.y)
                balls[i].verticalVelocity = contact.velocity.z
                balls[i].spin = contact.spin
                cueContact = nil
            } else {
                cueContact = contact
            }
        }

        guard let cue = cue else {
            ballsTheCueIsTouching.removeAll()
            return
        }

        var touching: Set<Int> = []
        // The tip's own part of it: the tip goes where the ball it has goes — the crown pressed into it by
        // the leather's own compression — and the stick is not asked to collide with the ball. That whole
        // moment is the *one* contact of the stroke, so nothing is reported for it.
        if let contact = held, let i = index(of: contact.ball) {
            let centre = Vec3(balls[i].position.x, balls[i].position.y, balls[i].height)
            let share = contact.seconds > 0 ? min(1, contact.elapsed / contact.seconds) : 1
            let pressedIn = PhysicsWorld.cueContactDeflection(contact, at: share)
            let toTheTip = cue.tip - centre
            let offset = toTheTip - cue.axis * toTheTip.dot(cue.axis)
            let across = min(offset.length, Table.ballRadius * 0.99)
            let reach = max(0, (Table.ballRadius * Table.ballRadius - across * across).squareRoot()
                            - pressedIn)
            let sideways = offset.length > 1e-9 ? offset.normalized * across : Vec3.zero
            self.cue?.tip = centre + sideways - cue.axis * reach
            // The tip is going with the ball it has: what its own surface is doing at the contact is what the
            // ball's is.
            self.cue?.speed = balls[i].velocity.dot(Vec2(cue.axis.x, cue.axis.y))
            touching.insert(contact.ball)
        }
        for i in balls.indices where balls[i].onTable {
            guard balls[i].id != held?.ball else { continue }
            var ball = balls[i]
            let centre = Vec3(ball.position.x, ball.position.y, ball.height)
            guard let contact = cueContact(with: centre) else { continue }

            // Out of the stick, along the contact normal — and never below the bed, which holds it up.
            ball.position += Vec2(contact.normal.x, contact.normal.y) * contact.depth
            ball.height += contact.normal.z * contact.depth
            if ball.height < Table.ballRadius { ball.height = Table.ballRadius }

            // The contact point on the ball, and what is happening there: the ball's surface against the
            // stick's own surface, which is going along the cue's axis at the cue's speed.
            let arm = contact.normal * -Table.ballRadius
            let onTheBall = Vec3(ball.velocity.x, ball.velocity.y, ball.verticalVelocity)
                + ball.spin.cross(arm)
            let onTheCue = cue.axis * cue.speed
            var relative = onTheBall - onTheCue
            let approach = relative.dot(contact.normal)
            if approach < 0 {
                // Into the stick: the ball takes the impulse of a collision with an infinitely heavy
                // body, through whatever restitution that part of the cue has — the tip's leather, or
                // the varnished wood of the shaft.
                let restitution = contact.onTheTip ? Self.cueTipRestitution : Self.cueShaftRestitution
                let normalImpulse = -(1 + restitution) * approach * Table.ballMass
                ball.velocity += Vec2(contact.normal.x, contact.normal.y)
                    * (normalImpulse / Table.ballMass)
                ball.verticalVelocity += contact.normal.z * (normalImpulse / Table.ballMass)

                // And the friction, which is what grips the ball and turns it. It is limited by the
                // coefficient of the part of the stick that touched — the leather's grip at the tip, the
                // wood's along the side — so a ball met off the middle of the tip can be turned, and one
                // that runs into the side of the shaft barely at all.
                relative = Vec3(ball.velocity.x, ball.velocity.y, ball.verticalVelocity)
                    + ball.spin.cross(arm) - onTheCue
                let slip = relative - contact.normal * relative.dot(contact.normal)
                if slip.length > 1e-9 {
                    let needed = slip.length * Table.ballMass * 2.0 / 7.0
                    let grip = (contact.onTheTip ? Self.cueTipFriction : Self.cueShaftFriction)
                        * normalImpulse
                    let impulse = slip.normalized * -min(needed, grip)
                    ball.velocity += Vec2(impulse.x, impulse.y) / Table.ballMass
                    ball.verticalVelocity += impulse.z / Table.ballMass
                    ball.spin += arm.cross(impulse)
                        * (5.0 / (2 * Table.ballRadius * Table.ballRadius))
                }
            }
            ball.onTable = true
            balls[i] = ball
            touching.insert(ball.id)
        }

        // A ball the cue has just come into contact with: reported once, not once a step.
        for id in touching.subtracting(ballsTheCueIsTouching) {
            events.append(.cueTouched(ball: id, after: clock, speed: abs(cue.speed)))
        }
        ballsTheCueIsTouching = touching
    }

    /// Moves the tip along the stick's own axis by `travel`, or as much of it as the table allows, and returns
    /// what was moved. A stick is a stick: the cloth and the cushion and the rail stop it, and it stops there.
    private func carryTheCueTip(alongTheAxisBy travel: Double) -> Double {
        guard let cue = cue, travel != 0 else { return 0 }
        let axis = cue.axis
        func clear(_ moved: Double) -> Bool {
            theCueTipCanStand(at: cue.tip + axis * moved, along: axis)
        }
        var allowed = travel
        if !clear(travel) {
            var low = 0.0, high = travel
            for _ in 0..<10 {
                let middle = (low + high) / 2
                if clear(middle) { low = middle } else { high = middle }
            }
            allowed = low
        }
        self.cue?.tip += axis * allowed
        return allowed
    }

    /// Where the cue and a ball meet, if they do: the direction out of the cue, how deep the ball is
    /// into it, and which part of the stick it met.
    private func cueContact(with centre: Vec3) -> (normal: Vec3, depth: Double, onTheTip: Bool)? {
        guard let cue else { return nil }
        var best: (normal: Vec3, depth: Double, onTheTip: Bool)?
        func keep(_ candidate: (normal: Vec3, depth: Double, onTheTip: Bool)) {
            if best == nil || candidate.depth > best!.depth { best = candidate }
        }

        // The side of the stick, length by length of `Table.cueGirth`.
        //
        // Only the *side*: a ball beyond the tip's own end is the tip's business, and is answered by
        // the face below rather than by the rounded corner the segment's end would otherwise put on it.
        let beyondTheTip = (centre - cue.tip).dot(cue.axis) > 0
        for girth in Table.cueGirth {
            if beyondTheTip, girth.front == 0 { continue }
            let front = cue.tip - cue.axis * girth.front
            let back = cue.tip - cue.axis * girth.back
            let closest = PhysicsWorld.closestPoint(to: centre, onTheSegment: front, back)
            let away = centre - closest
            let distance = away.length
            let reach = girth.radius + Table.ballRadius
            guard distance < reach, distance > 1e-9 else { continue }
            keep((away.normalized, reach - distance, false))
        }

        // And the tip's own face: a ball in front of the tip is met squarely by it, along the cue's
        // axis, whatever part of the face it is on. That is what a cue does — the tip flattens against
        // the ball and pushes it down the line of the stick rather than off to the side.
        let alongTheAxis = (centre - cue.tip).dot(cue.axis)
        if alongTheAxis > 0, alongTheAxis < Table.ballRadius {
            let across = (centre - cue.tip - cue.axis * alongTheAxis).length
            let onTheFace = (Table.cueGirth.first?.radius ?? Table.ballRadius) + Table.ballRadius
            if across <= onTheFace {
                keep((cue.axis, Table.ballRadius - alongTheAxis, true))
            }
        }
        return best
    }

    /// The closest point to `p` on the segment `a`–`b`, in three dimensions.
    private static func closestPoint(to p: Vec3, onTheSegment a: Vec3, _ b: Vec3) -> Vec3 {
        let ab = b - a
        let lengthSquared = ab.dot(ab)
        guard lengthSquared > 0 else { return a }
        let t = max(0, min(1, (p - a).dot(ab) / lengthSquared))
        return a + ab * t
    }

    /// A jump shot, in the sense of Section 2 Rule 20: the cue ball passes over any part of an object
    /// ball. A ball that has already hit one object ball may jump over another (Rule 20(a)), so only a
    /// jump made **before the first contact** is reported — the ball clearing an obstruction. The ball
    /// is over another when their plan circles overlap and the cue ball is clear above it.
    private func takeJumps() {
        guard let struck = struckBall, let cueIndex = index(of: struck), balls[cueIndex].onTable else { return }
        let cue = balls[cueIndex]
        guard !struckBallHasHitABall else { return }
        for ball in balls where ball.onTable && ball.id != struck {
            guard !jumpedOver.contains(ball.id) else { continue }
            guard cue.position.distance(to: ball.position) < Table.ballDiameter else { continue }
            guard cue.height - Table.ballRadius > ball.height + Table.ballRadius else { continue }
            jumpedOver.insert(ball.id)
            events.append(.jumpShot(over: ball.id))
        }
    }

    /// A ball that has left the table is off it (Section 2 Rule 14), and is taken out of the simulation
    /// at once rather than tracked on any further: it no longer holds the stroke up, so when the balls
    /// still on the table stop, the stroke is over and the rules engine gets the ball as one forced off
    /// the table.
    private func takeBallsOffTheTable() {
        for i in balls.indices where balls[i].onTable {
            guard isOffTheTable(balls[i].position, atRest: atRest(balls[i])) else { continue }
            // Off the table for the rules from this moment — the stroke no longer waits on it, and the
            // report says the ball was forced off — but it is still a ball in the air, so it is left to
            // fall to the floor before it goes: see `fallToTheFloor`.
            balls[i].onTable = false
            balls[i].isFalling = true
            balls[i].pottedInto = nil
            events.append(.forcedOffTable(ball: balls[i].id))
        }
    }

    /// Lets a ball that has been forced off the table fall to the floor. The rules have had it since
    /// the moment it left (`takeBallsOffTheTable`); this is the picture of it, and the floor is
    /// `Table.floorHeight` — a table's bed is about 800 mm up. Gravity, the floor, and then it is gone:
    /// a ball neither on the table nor falling is not drawn at all.
    private func fallToTheFloor(_ dt: Double) {
        let restingHeight = Table.floorHeight + Table.ballRadius
        for i in balls.indices where balls[i].isFalling {
            balls[i].verticalVelocity -= Self.gravity * dt
            balls[i].height += balls[i].verticalVelocity * dt
            balls[i].position += balls[i].velocity * dt
            guard balls[i].height <= restingHeight else { continue }
            events.append(.landed(ball: balls[i].id, speed: abs(balls[i].verticalVelocity)))
            balls[i].height = restingHeight
            balls[i].velocity = .zero
            balls[i].spin = .zero
            balls[i].verticalVelocity = 0
            balls[i].isFalling = false
        }
    }

    private func integrate(_ dt: Double) {
        let r = Table.ballRadius
        let inertiaFactor = 5.0 / (2.0 * r)
        for i in balls.indices where balls[i].onTable {
            var b = balls[i]
            var v = b.velocity
            var w = b.spin

            // The cloth only pushes on a ball it can reach: a ball in the air, or one on its way down
            // a pocket, keeps the spin it left with. The ball has to be sitting on the surface under
            // it — the bed, or the cloth on the wood of a rail — and not merely over it.
            guard let surface = surfaceUnder(b.position),
                  abs(b.height - Table.ballRadius - surface) <= 0.01 else {
                b.position += v * dt
                balls[i] = b
                continue
            }

            if v.length > 0.01 || abs(w.z) > 0.01 || w.x != 0 || w.y != 0 {
                // The nap. The brushed fibres of the cloth run along +x (from the baulk end towards
                // the black), and the sideways push they give a ball that is turning about the
                // vertical is across them, along y: towards the green side (high y) for a clockwise
                // turn and towards the yellow (low y) for an anti-clockwise one. Side spin is
                // `w.z`, positive for the anti-clockwise turn, so the push goes the other way.
                //
                // It is the **bed's** cloth that is brushed: the strips on the rails are cut and laid
                // along their own length, so a ball rolling along a rail is not carried across it.
                if surface <= 0 { v.y -= Self.napSpinDrift * w.z * dt }
                // Velocity of the material point touching the cloth.
                let u = Vec2(v.x - r * w.y, v.y + r * w.x)
                let slip = u.length

                if slip > Self.restSpeed * 0.5 {
                    // Sliding: kinetic friction opposes the slip, and its moment changes spin.
                    //
                    // The impulse is capped at what the cloth can supply in one step, and at what
                    // is needed to take the slip away, whichever is smaller. Applying the full
                    // step's friction to a small slip reverses it, and a ball that reverses its
                    // slip every step has its friction cancel out: a ball left barely moving by a
                    // collision would chatter on the spot and crawl for hundreds of millimetres
                    // instead of stopping. Taking the smaller of the two leaves it rolling.
                    let a = Self.slidingFriction * Self.gravity
                    let change = min(a * dt, slip * 2.0 / 7.0)
                    let dir = u.normalized
                    let ax = -change / dt * dir.x, ay = -change / dt * dir.y
                    v += Vec2(ax, ay) * dt
                    w.x += inertiaFactor * ay * dt
                    w.y += inertiaFactor * (-ax) * dt
                    // Slip also bleeds a little vertical spin.
                    w.z *= exp(-Self.sideSpinDecay * 0.35 * dt)
                } else {
                    // Rolling: keep the no-slip relation and apply rolling resistance.
                    let speed = v.length
                    if speed > 0.01 {
                        // The wood of a rail carries more of the ball's way off than the slate of the
                        // bed does: see `railRollingResistance`.
                        let a = (surface > 0 ? Self.railRollingResistance : Self.rollingResistance)
                            * Self.gravity
                        v -= v.normalized * (a * dt)
                    }
                    w.x = -v.y / r
                    w.y = v.x / r
                    w.z *= exp(-Self.sideSpinDecay * dt)
                }

                b.velocity = v
                b.spin = w
                b.position += v * dt + Vec2(0, 0) * dt

                if b.velocity.length < Self.restSpeed && slip <= Self.restSpeed * 0.5 {
                    b.velocity = .zero
                    b.spin = Vec3(0, 0, b.spin.z * 0.5)
                    if abs(b.spin.z) < 0.4 { b.spin = .zero }
                }
            } else {
                b.velocity = .zero
                b.spin = .zero
            }
            balls[i] = b
        }
    }

    private func resolveCollisions(over h: Double) {
        // Ball vs cushion.
        for i in balls.indices where balls[i].onTable {
            for cushion in cushions {
                bounceOffSegment(index: i, segmentA: cushion.a, segmentB: cushion.b, normal: cushion.normal, side: cushion.side)
            }
            for jaw in jawTips {
                bounceOffJaw(index: i, centre: jaw.centre, radius: jaw.radius, side: jaw.side,
                             atTheThroat: jaw.atTheThroat, hasAThroat: jaw.hasAThroat)
            }
            for throat in throats {
                bounceOffThroat(index: i, a: throat.a, b: throat.b, inward: throat.inward)
            }
        }

        // A ball cannot be *inside* the wood. One that has got in behind a cushion — a rattle that
        // slipped past a jaw and up under the overhang — is turned back out into the playing area
        // rather than left in the rail or quietly called off the table: the wood is the cushion's own
        // body, and the ball is on the wrong side of its face. The wood is dead next to the cushion's
        // rubber, so what was carrying the ball into it comes back at a fifth.
        for i in balls.indices where balls[i].onTable {
            var ball = balls[i]
            let point = Vec3(ball.position.x, ball.position.y, ball.height)
            guard surfaceUnder(ball.position) == Table.cushionHeight,
                  let wall = PhysicsWorld.surround.min(by: {
                      $0.distanceToTheWood(point) < $1.distanceToTheWood(point)
                  }),
                  wall.distanceToTheWood(point) == 0
            else { continue }
            for _ in 0..<8 {
                let face = PhysicsWorld.cushionFace(out: wall.out(ball.position), up: ball.height)
                guard face.distance < Table.ballRadius else { break }
                // Away from the material, which is the way from the ball to the nearest of the face.
                let push = face.distance + Table.ballRadius
                ball.position += wall.normal * (push * -face.normal.x)
                ball.height += push * -face.normal.y
            }
            let inward = ball.velocity.dot(wall.normal)
            if inward < 0 {
                ball.velocity -= wall.normal * (inward * 1.2)
                events.append(.rail(ball: ball.id, speed: -inward))
            }
            if ball.height < Table.ballRadius { ball.height = Table.ballRadius }
            balls[i] = ball
        }

        // Ball vs ball.
        for i in balls.indices {
            guard balls[i].onTable else { continue }
            for j in (i + 1)..<balls.count where balls[j].onTable {
                resolveBallPair(i, j, over: h)
            }
        }
    }

    /// Bounces a ball off a straight run of cushion.
    ///
    /// The cushion is not a wall in the plane of the table. Its nose stands above the ball's centre
    /// (`Table.cushionNoseHeight` is 7.09 mm above the 26.25 mm a ball on the cloth rides at), so the
    /// ball meets the face **above its own equator** and the contact point is off the middle of the
    /// ball. The collision is worked in three dimensions — the ball's velocity has its height as well
    /// as its place, and its spin is a full vector — and the impulse at that contact does what the
    /// old two-dimensional model could not:
    ///
    ///  * it reverses the ball along the face normal with the cushion's restitution, as before;
    ///  * it rubs along the face, opposing the slip of the ball's own surface there (capped by the
    ///    friction the cushion can supply), which turns the ball about the **vertical** (side spin,
    ///    as before) *and* about the **horizontal** axis along the cushion — a ball running into a
    ///    cushion comes away with its run taken off it, checking, because the grip is above its
    ///    middle;
    ///  * and because the contact is above the middle, the friction can throw the ball **up off the
    ///    cloth**: a ball rolling in has its surface running *down* the face, and the friction that
    ///    stops that slip points up the face, so it lifts the ball. A ball with backspin meets the
    ///    same face the other way, its surface running *up* it, and the friction presses down.
    ///
    /// The vertical motion that comes out of this is left to the rest of the simulation: gravity
    /// brings the ball back to the bed and the bed bounces it, so a hard cushion can put a small hop
    /// on a ball and it may leave the cloth for a moment.
    ///
    /// The section is the one `Table3D` draws, read from `Table`, so what is played on and what is
    /// drawn are one shape. Its normal leans down as well as in, so the cushion's answer presses the
    /// ball into the bed as well as turning it over; the cloth carries that downward part and gives
    /// some of it back, which is where the hop comes from. The single `cushionRestitution` figure is
    /// the effective one for the bounce that results.
    private func bounceOffSegment(index i: Int, segmentA: Vec2, segmentB: Vec2, normal: Vec2, side: CushionSide) {
        let ball = balls[i]
        let ab = segmentB - segmentA
        let len2 = ab.lengthSquared
        guard len2 > 0 else { return }
        var t = (ball.position - segmentA).dot(ab) / len2
        t = max(0, min(1, t))
        let closest = segmentA + ab * t
        let delta = ball.position - closest
        let distance = delta.length
        let n = distance > 1e-6 ? delta / distance : normal
        guard n.dot(normal) > 0.2 else { return }  // behind the cushion face
        bounceOffFace(index: i, out: distance, n: n, side: side)
    }

    /// Bounces a ball off the round at the end of a cushion — a jaw.
    ///
    /// A jaw is not a different thing from a cushion: it is the same rubber, cut off where the pocket
    /// begins, and the section `Table3D` sweeps along the run is swept round the jaw's own round of
    /// `Table.jawRadius` as well. So the ball meets the jaw's nose above its own equator exactly as it
    /// meets a run's, and the whole collision below is shared: the out distance is how far the ball's
    /// centre stands out from the round, which is its distance from the jaw's axis less the jaw's own
    /// radius, and the normal is the line out from that axis.
    private func bounceOffJaw(index i: Int, centre: Vec2, radius: Double, side: CushionSide,
                             atTheThroat: Vec2, hasAThroat: Bool) {
        let delta = balls[i].position - centre
        let distance = delta.length
        guard distance > 1e-9 else { return }
        let n = delta / distance
        // Where the round has run out into the throat the rubber has run out too: past that line the
        // ball is meeting the pocket's own facing, which is a dead thing. It is handed over to the
        // throat wall rather than answered here — a ball arriving along the throat makes its contact
        // exactly on that line, and answered by rubber it is thrown back across the mouth and out.
        if hasAThroat, n.dot(atTheThroat) > 0 { return }
        bounceOffFace(index: i, out: distance - radius, n: n, side: side)
    }

    /// Bounces a ball off a pocket's throat: one straight side of the cut, running from the jaw's round
    /// down to the hole.
    ///
    /// The **surface** is the cushion's own: the wood's edge beside a jaw is cut in the same section,
    /// leaning at the same 65° to the cloth, so a ball here is answered against the same leaning face
    /// it meets on a cushion — tucked in under the nose, turned by the grip above its middle, and
    /// lifted by a hard one — rather than by a wall standing square to the cloth. See
    /// `bounceOffTheFace`.
    ///
    /// The **material** is not a cushion's. The throat is a cut in the wood with a facing on it rather
    /// than rubber: the ball comes back **half** of what it brought, and the facing grips what slides
    /// along it, so a ball that has come into a corner at a shallow angle is **taken in** rather than
    /// thrown out. Nothing is announced: a pocket's facing is not a cushion, and a ball meeting one has
    /// not been in contact with a cushion.
    private func bounceOffThroat(index i: Int, a: Vec2, b: Vec2, inward: Vec2) {
        let ball = balls[i]
        let closest = PhysicsWorld.nearestPoint(ball.position, from: a, to: b)
        let away = ball.position - closest
        let distance = away.length
        // Out of the facing, the short way — along the line out from the nearest point of it, or along
        // the facing's own inward when the ball's centre is right on it and there is no line to take.
        let n = distance > 1e-9 ? away / distance : inward
        guard n.dot(inward) > 0.2 else { return }     // the far side of the throat, not this one
        let id = ball.id
        if let speed = bounceOffTheFace(index: i, out: distance, n: n,
                                        restitution: Self.throatRestitution,
                                        friction: Self.throatFriction) {
            events.append(.throat(ball: id, speed: speed))
        }
    }

    /// Bounces a ball off a cushion face, straight run or jaw: `out` is how far the ball's centre
    /// stands from the line of the nose, into the playing area, and `n` is the direction across the
    /// face in the plane of the table.
    private func bounceOffFace(index i: Int, out: Double, n: Vec2, side: CushionSide) {
        let id = balls[i].id
        if let speed = bounceOffTheFace(index: i, out: out, n: n,
                                        restitution: Self.cushionRestitution,
                                        friction: Self.cushionFriction) {
            events.append(.cushion(ball: id, side: side, speed: speed))
        }
    }

    /// Answers a ball against the cushion's **own section** — the leaning side, the round over the nose
    /// and the square band above it, the shape the table is drawn with — at whatever it has run into: a
    /// straight run, the round at the end of one, or the dead facing of a pocket's throat behind a jaw.
    ///
    /// `out` is how far the ball's centre stands from the line of the nose, into the table, and `n` is
    /// the direction across the face there. `restitution` and `friction` are what the **material** is
    /// made of, and that is the one thing a pocket's facing and a cushion's rubber do not share: rubber
    /// gives back most of what it takes, and a facing gives back half of it and grips what slides along
    /// it. Everything else is the shape's — the contact above the ball's own equator, the tuck in under
    /// the nose, the spin the answer carries, and the lift a hard one can put on the ball — and is the
    /// same for both.
    ///
    /// Returns the closing speed when the ball was answered, and nil when it was not touching the face
    /// at all; reporting the contact is the caller's, because a cushion and a pocket's throat are not
    /// the same thing to the rules however alike they are to play on.
    @discardableResult
    private func bounceOffTheFace(index i: Int, out: Double, n: Vec2,
                                  restitution: Double, friction: Double) -> Double? {
        var ball = balls[i]
        // Where the ball meets the cushion, and how far it has pressed in. The face's section — the
        // leaning side, the round over the nose and the square band above it — is what fixes the
        // contact point, and because the nose stands above the ball's centre the contact is off the
        // middle of the ball and the normal leans down as well as in.
        let r = Table.ballRadius
        // Nothing to do unless the ball is at the face at all: the section lies at or behind the line
        // of the nose, so a centre further out than a radius cannot be touching it. This is what keeps
        // the twelve jaws from costing anything until a ball is among them.
        guard out < r else { return nil }
        let onTheBed = ball.height >= r - 0.5
        let face = PhysicsWorld.cushionFace(out: out, up: ball.height)
        guard face.distance < r else { return nil }
        let penetration = r - face.distance

        // Push the ball out of the face, along the face's own normal. A ball on the cloth is pressed
        // down a little by this and the cloth pushes back; one in the air is turned down the same way.
        // The bed is solid: the cloth holds the ball up, so the push can never take it below the bed
        // and into a pocket it is not over.
        ball.position += n * (penetration * face.normal.x)
        ball.height += penetration * face.normal.y
        if onTheBed { ball.height = max(ball.height, r) }

        // The normal, in three dimensions: the section's own normal swung along the run's.
        let n3 = Vec3(n.x * face.normal.x, n.y * face.normal.x, face.normal.y)
        var v = Vec3(ball.velocity.x, ball.velocity.y, ball.verticalVelocity)
        let vn = v.dot(n3)
        guard vn < 0 else { balls[i] = ball; return nil }

        // The point of the ball that touches, from its centre: a radius out along the normal.
        let contact = n3 * -r

        // The face answers along its normal, with the material's restitution.
        let normalImpulse = -(1 + restitution) * vn
        v += n3 * normalImpulse

        // The ball's surface at the contact is moving at v + w x contact, and the cushion is still, so
        // the slip is that less its part along the normal. Friction opposes it; it takes (2/7) of the
        // slip to stop it, the seven halves being the ball's moment of inertia (2/5 m r^2) as it shows
        // at a contact on the surface.
        let surface = v + ball.spin.cross(contact)
        let slip = surface - n3 * surface.dot(n3)
        if slip.length > 1e-9 {
            let magnitude = min(slip.length * 2.0 / 7.0, friction * normalImpulse)
            let impulse = slip.normalized * -magnitude
            v += impulse
            // The impulse acts at the contact, so it turns the ball about the axis through its centre
            // perpendicular to both the contact arm and the impulse.
            ball.spin += contact.cross(impulse) * (5.0 / (2 * r * r))
        }

        // The rubber holds the ball. A ball that has pressed into the cushion is wrapped by it, and
        // the deeper it has gone the more completely the dimple has it, until the contact is *stuck*
        // rather than sliding. A stuck contact is a different thing from the friction above, and the
        // two have to be kept apart: the friction rubs along the face against the slip, but the dimple
        // holds the ball, so the ball leaves **along the face normal** — the sideways momentum it
        // arrived with is swallowed by the rubber, and nothing of its angle is left. That is what makes
        // a hard ball come off straight back and run up and down the table while a slow one, barely
        // denting the cushion, keeps its angle.
        //
        // A stuck ball still carries its angular momentum about the point it is held by: it can turn,
        // because the rubber lets it, so the side spin it arrived with and the turning effect of the
        // momentum across the face both go round it — `w' = (L_p / I)` with `L_p` taken about the
        // contact. Blending the two outcomes by how stuck the contact is keeps the friction and the
        // grip from undoing one another, which they did when both were impulses in turn.
        let hold = Self.cushionHold(for: vn)
        if hold > 0 {
            let stuckVelocity = n3 * (-restitution * vn)
            // The impulses so far all acted at the contact, so the ball's angular momentum about it
            // is whatever it was when the ball arrived — read it off the state now.
            let angularMomentum = ball.spin * (2.0 / 5.0 * r * r) + (n3 * r).cross(v)
            let stuckSpin = angularMomentum * (5.0 / (2.0 * r * r))
            v = v * (1 - hold) + stuckVelocity * hold
            ball.spin = ball.spin * (1 - hold) + stuckSpin * hold
        }

        ball.velocity = Vec2(v.x, v.y)
        ball.verticalVelocity = v.z
        balls[i] = ball
        return -vn
    }

    /// How completely the cushion holds the ball at an impact: 0 while the ball barely dents the
    /// rubber, 1 once it has sunk `cushionGripDepth` of a radius into it and the dimple has the ball.
    ///
    /// A ball compresses the cushion by the Hertz impact depth
    /// `d = (15 m v² / (16 sqrt(R) E))^(2/5)`, which grows with the normal approach speed and shrinks
    /// with the rubber's elastic modulus `E` — and `E` is the hardness the cushion is moulded to
    /// (`cushionShoreA`, through Gent's relation), stiffened for the rate of an impact
    /// (`cushionImpactStiffening`). The grip follows the square of the sink: barely there on a slow
    /// shot, and still a good way short of complete at the hardest one.
    /// One measure for all of them: the rubber of a run and of a jaw, and the leather facing of the
    /// pocket behind them. "The jaws grab the way the cushions do" is this function being read three
    /// times, and not a resemblance in a comment.
    public static func cushionHold(for normalSpeed: Double) -> Double {
        guard cushionGripDepth > 0 else { return 0 }
        let modulus = pow(10.0, 0.0235 * cushionShoreA - 0.6403) * 1_000_000   // Pa, static
            * cushionImpactStiffening                                           // at impact rate
        let speed = abs(normalSpeed) / 1000                                    // m/s
        let radius = Table.ballRadius / 1000                                   // m
        let sink = pow(15 * Table.ballMass * speed * speed
                       / (16 * radius.squareRoot() * modulus), 0.4) / radius
        let fraction = sink / cushionGripDepth
        return min(1, fraction * fraction)
    }

    /// Resolves one ball-on-ball collision, **at the place the two balls touched**.
    ///
    /// Subdividing the step keeps a ball from moving far in one step, but two balls closing on each
    /// other move twice as far between them, and an overlap found at the end of a step is an overlap
    /// that has already happened: the line of centres there is no longer the line they met on, and the
    /// ball is sent off a degree or two wide of the true one — wider, the faster the shot, which is the
    /// last thing a cut should depend on. So the pair is walked back along its own velocities to the
    /// time the two were exactly a diameter apart, answered there, and walked forward again over the
    /// rest of the step.
    private func resolveBallPair(_ i: Int, _ j: Int, over h: Double) {
        var a = balls[i], b = balls[j]
        let r = Table.ballRadius
        let diameter = Table.ballDiameter
        // Two balls meet as **spheres**, not as discs: a ball that has bounced up off the cloth clears
        // one sitting under it instead of colliding with it on the plan. Everything below is in three
        // dimensions for that reason, and because the contact point is where the arithmetic has to be
        // done: a ball's height is as much a part of where it meets another as its place is.
        func apart(_ from: Ball, _ to: Ball) -> Vec3 {
            Vec3(to.position.x - from.position.x, to.position.y - from.position.y,
                 to.height - from.height)
        }
        func velocity(_ ball: Ball) -> Vec3 {
            Vec3(ball.velocity.x, ball.velocity.y, ball.verticalVelocity)
        }

        let now = apart(a, b)
        guard now.lengthSquared < diameter * diameter else { return }
        let relative = velocity(a) - velocity(b)

        // **When** they touched: the pair walked back along its own closing motion. `|p − v t| = d` is a
        // quadratic in `t`, and with the pair overlapped now the root that matters is the later one —
        // the first time in this step that they were exactly a diameter apart.
        var back = 0.0
        let closing = now.dot(relative)
        let speedSquared = relative.lengthSquared
        if closing > 0, speedSquared > 1e-12 {
            let discriminant = closing * closing - speedSquared * (now.lengthSquared - diameter * diameter)
            if discriminant >= 0 {
                // Of the two times the pair was exactly a diameter apart, it is the **nearer** one that
                // is the touch: the other is the far side of the pair's own approach, before the step.
                let touched = (discriminant.squareRoot() - closing) / speedSquared
                if touched > 0, touched <= h { back = touched }
            }
        }
        if back > 0 {
            a.position -= a.velocity * back
            a.height -= a.verticalVelocity * back
            b.position -= b.velocity * back
            b.height -= b.verticalVelocity * back
        } else {
            // Already inside one another when the step began, which a contact of last resort can leave:
            // pushed apart the shortest way rather than left overlapped, with no impulse — they are not
            // coming together, or there is no longer a moment in this step at which they touched.
            let overlap = diameter - now.length
            let n = now.normalized
            a.position -= Vec2(n.x, n.y) * (overlap / 2)
            a.height -= n.z * (overlap / 2)
            b.position += Vec2(n.x, n.y) * (overlap / 2)
            b.height += n.z * (overlap / 2)
            balls[i] = a
            balls[j] = b
            return
        }

        // At the touch: the line of centres is the line they met on, and everything below is worked in
        // that frame.
        let separation = apart(a, b)
        let n3 = separation.length > 1e-9 ? separation.normalized : Vec3(1, 0, 0)
        let approach = velocity(a) - velocity(b)
        let vn = approach.dot(n3)
        if vn > 0 {
            // What each ball was doing vertically before it was struck, so that what the collision did
            // *to* it can be told from what it was already doing. See `heldUpByTheCloth` below.
            let aWasRising = a.verticalVelocity
            let bWasRising = b.verticalVelocity
            // The impulse along the line of centres: equal masses, so each ball's change is half of it,
            // with the ball's own restitution.
            let jn = (1 + Self.ballRestitution) * vn / 2
            a.velocity -= Vec2(n3.x, n3.y) * jn
            a.verticalVelocity -= n3.z * jn
            b.velocity += Vec2(n3.x, n3.y) * jn
            b.verticalVelocity += n3.z * jn

            // **What rubs at the contact point.** The two balls touch at one point of each, a radius out
            // along the line of centres, and what slides there is the velocity of *those points*: each
            // ball's centre carried to the touch, `v + w × (r n)` — a ball with follow or draw has its
            // surface moving there even when its centre is not, and a ball turning about the vertical
            // has it moving across the face. The two arms point opposite ways, so the spins enter as a
            // **sum**: `u = (v_a − v_b) + (w_a + w_b) × r n`. Friction opposes that slip, and it is what
            // throws the object ball towards the striker's line and drags the cue ball with it.
            let arm = n3 * r
            let contactSlip = (velocity(a) - velocity(b)) + (a.spin + b.spin).cross(arm)
            let slip = contactSlip - n3 * contactSlip.dot(n3)
            if slip.length > 1e-9 {
                // The impulse that takes the slip away at the touch on two equal spheres is a **seventh**
                // of it — the two balls' own changes are `2 · J`, and the spin the impulse gives them
                // carries `5 · J` back to the contact point — and it is capped at what friction can
                // supply over the normal impulse. The cap is what a real throw is limited by: the
                // object ball is sent off at no more than `atan(ballFriction)` of the line of centres.
                let speed = slip.length / 7
                let impulse = slip.normalized * -min(speed, Self.ballFriction * jn)
                a.velocity += Vec2(impulse.x, impulse.y)
                a.verticalVelocity += impulse.z
                b.velocity -= Vec2(impulse.x, impulse.y)
                b.verticalVelocity -= impulse.z
                // The impulse acts **at the contact point**, so it turns each ball about the axis
                // through both its centre and the arm: `Δw = (arm × J) / (2/5 r²)`, and the same for
                // each ball, because b's arm and its impulse are both the other way round.
                let coupling = 5 / (2 * r * r)
                a.spin += arm.cross(impulse) * coupling
                b.spin += arm.cross(impulse) * coupling
            }

            // **The cloth, during the contact.** The impulse just applied has a *vertical* part — from
            // the line of centres when the two balls are at different heights, and from the friction
            // whenever the slip at the contact is not level, which is any ball carrying follow or draw —
            // and a ball resting on the bed cannot be driven down into it. The bed answers that part
            // with a normal impulse of its own, and a normal impulse on the cloth comes with the cloth's
            // **friction**: the cloth opposes the slide of the ball's own patch, `u = v − r(w × ẑ)`, so a
            // collision that presses a ball into the cloth also drags it along and turns it. That is the
            // same friction the cloth is given every other step (see `integrate`); what is new is that
            // the collision is one of the things that presses a ball into the cloth, and it happens
            // between two of those steps.
            //
            // A ball the collision has lifted is not held: it is off the cloth for the moment, and the
            // bed has nothing to say to it. What is *not* put back is the cloth's own springiness: the
            // bed's restitution belongs to a ball arriving at the cloth at a pace of its own (see
            // `settleVertically`), and a hop from a screw shot has its own rule (`hopFromALowTip`).
            func heldUpByTheCloth(_ ball: inout Ball, havingRisenBy rise: Double) {
                let pressed = ball.verticalVelocity - rise
                guard pressed < 0,
                      let surface = surfaceUnder(ball.position),
                      abs(ball.height - Table.ballRadius - surface) <= 0.01 else { return }
                // The bed's own impulse — the ball's vertical motion given back what the collision took
                // from it — and then the friction that comes with a normal impulse on the cloth.
                let normalImpulse = -pressed
                ball.verticalVelocity = rise
                let patch = Vec2(ball.velocity.x - Table.ballRadius * ball.spin.y,
                                 ball.velocity.y + Table.ballRadius * ball.spin.x)
                guard patch.length > 1e-9 else { return }
                let friction = min(patch.length * 2 / 7, Self.slidingFriction * normalImpulse)
                let alongTheCloth = patch.normalized * -friction
                ball.velocity += alongTheCloth
                // It acts at the bottom of the ball, a radius below its middle, so it turns the ball as
                // well as carrying it: `Δw = (arm × J) / (2/5 r²)` about the axis through both.
                let underTheBall = Vec3(0, 0, -Table.ballRadius)
                ball.spin += underTheBall.cross(Vec3(alongTheCloth.x, alongTheCloth.y, 0))
                    * (5 / (2 * Table.ballRadius * Table.ballRadius))
            }
            heldUpByTheCloth(&a, havingRisenBy: aWasRising)
            heldUpByTheCloth(&b, havingRisenBy: bWasRising)

            events.append(.ballBall(a: a.id, b: b.id, relativeSpeed: vn))
            if a.id == struckBall || b.id == struckBall { struckBallHasHitABall = true }
        }

        // And on with the step from the touch, at the velocities the collision has left them with.
        if back > 0 {
            a.position += a.velocity * back
            a.height += a.verticalVelocity * back
            b.position += b.velocity * back
            b.height += b.verticalVelocity * back
        }
        balls[i] = a
        balls[j] = b
    }

    // MARK: The ball's height

    /// Moves the centre of mass up and down under gravity, and settles what happens to the ball when
    /// it comes down: the cloth holds it up, and a pocket does not.
    ///
    /// This is what a pocket is, physically. The bed runs on into the throat and is cut away at the
    /// hole, so a ball rolling in from the mouth is carried by the cloth until its centre crosses
    /// the rim of the hole, and then there is nothing under it and it falls. A ball that is still
    /// travelling when it gets there runs on into the back of the pocket on the way down, and the
    /// back of a pocket is dead: it takes nearly all of a ball's speed, which is exactly why a ball
    /// played hard into a pocket drops in rather than bouncing back out across the table.
    private func settleVertically(_ dt: Double) {
        let onTheFloorOfThePocket = Table.ballRadius - Table.pocketDepth
        for i in balls.indices where balls[i].onTable {
            var b = balls[i]
            b.verticalVelocity -= Self.gravity * dt
            b.height += b.verticalVelocity * dt

            let under = surfaceUnder(b.position)
            if let pocket = pocketUnder(b), b.height <= Table.ballRadius + 1e-6 {
                // Over the hole, with no cloth under it: it is falling into the pocket.
                holdInsideTheWell(&b, of: pocket.cut)
                if b.height <= onTheFloorOfThePocket {
                    b.height = onTheFloorOfThePocket
                    b.verticalVelocity = 0
                    b.velocity = .zero
                    b.spin = .zero
                    b.onTable = false
                    b.pottedInto = pocket
                    events.append(.pocketed(ball: b.id, pocket: pocket))
                }
            } else if let under, b.height <= Table.ballRadius + under {
                // The cloth catches it — the cloth of the bed, or the cloth on the wood of a rail,
                // which is timber under it rather than stone and gives back a little less of the drop.
                b.height = Table.ballRadius + under
                if b.verticalVelocity < -Self.bounceRest {
                    let speed = -b.verticalVelocity
                    b.verticalVelocity = speed * (under > 0 ? Self.railRestitution : Self.clothRestitution)
                    // What it came down on is worth reporting either way: a ball on the cloth of the
                    // bed has the slate under it, and one on the cloth over a rail has timber.
                    events.append(under > 0 ? .rail(ball: b.id, speed: speed)
                                            : .bed(ball: b.id, speed: speed))
                } else {
                    b.verticalVelocity = 0
                }
            }
            balls[i] = b
        }
    }

    /// The pocket a ball is going into, if any.
    ///
    /// The first thing to look for is a hole the ball's centre is over: the cloth is cut away there
    /// and the ball is no longer held up. Failing that, a ball already below the cloth can only be
    /// in a pocket — it cannot climb back onto the bed — so it belongs to the pocket it is nearest,
    /// which keeps a ball that has hit the back of a pocket and run back up the throat falling and
    /// in rather than reappearing on the cloth under the rails.
    private func pocketUnder(_ ball: Ball) -> PocketID? {
        if let index = pocketIndexOfTheHole(under: ball.position) { return pocketGeometry[index].id }
        guard ball.height < Table.ballRadius - 0.5 else { return nil }
        var nearest: PocketGeometry?
        var nearestDistance = Double.greatestFiniteMagnitude
        for pocket in pocketGeometry {
            let distance = pocket.holeCentre.distance(to: ball.position)
            if distance < nearestDistance { nearest = pocket; nearestDistance = distance }
        }
        guard let nearest, nearestDistance <= nearest.holeRadius + Table.ballDiameter else { return nil }
        return nearest.id
    }

    /// Whether a ball whose centre is at `position` is still in a pocket's keeping: over the mouth,
    /// down the throat between the jaws, or over the hole. A ball there is in the pocket, not off
    /// the table, however far outside the playing area its centre has gone.
    private func inAPocket(_ position: Vec2) -> Bool {
        for pocket in pocketGeometry {
            if position.distance(to: pocket.holeCentre) <= pocket.holeRadius { return true }
            let offset = position - pocket.mouth
            let along = offset.dot(pocket.axis)
            let across = abs(offset.dot(pocket.axis.perpendicular))
            let reach = pocket.mouth.distance(to: pocket.holeCentre) + pocket.holeRadius
            // A ball wide enough to be touching a jaw, and reaching from the mouth to the far side
            // of the hole. Generous on purpose: a ball at the jaws must never be called off the table.
            let halfWidth = max(pocket.halfWidth, pocket.holeRadius) + Table.ballRadius
            if along >= -Table.ballRadius && along <= reach && across <= halfWidth { return true }
        }
        return false
    }

    /// Whether a ball whose centre is at `position` has left the table. Section 2 Rule 14: a ball is
    /// forced off the table if it comes to rest other than on the playing area or in a pocket.
    ///
    /// Three things put a ball off the table, and no others. Out **past the wood of the rail**: it is
    /// over the floor, with nothing to come back to. Come to **rest on the wood of the rail**, or on
    /// the top of a cushion — the wood is not the playing area, and a ball that stops up there is off
    /// the table even though it is still over the table's footprint. And, as before, come to rest
    /// anywhere else off the playing area. A ball merely *over* the wood is not off the table: it may
    /// bounce or roll back onto the cloth, and only what it does when it stops decides.
    public func isOffTheTable(_ position: Vec2, atRest: Bool = false) -> Bool {
        guard let under = surfaceUnder(position) else {
            // Over a pocket, or out past the rail. A pocket is not off the table; the floor is.
            return !inAPocket(position)
        }
        if under > 0, atRest { return true }     // stopped on the wood of the rail, or on a cushion
        return false
    }

    /// Holds a ball that is falling into a pocket inside the well below the hole.
    ///
    /// The well is a cylinder the width of the hole, and it is closed: the sides, the back of the
    /// pocket, and the near side, where the rim of the hole is. A ball is a sphere, so while it is
    /// standing in the well its centre cannot come within its own radius of any of that. Above the
    /// cloth the rim does the same job, and the room closes as the ball drops past it: at the cloth
    /// the ball's widest section is its own equator, so the rim lets the centre right out to the edge
    /// of the hole, and by the time the ball is below the bed it has only the well's width less a ball
    /// to move in — which is the rim carrying the ball's centre in as the ball tips over it. Contact
    /// with any of the wall is dead: see `pocketRestitution`.
    private func holdInsideTheWell(_ b: inout Ball, of cut: PocketCut) {
        let down = max(0, min(Table.ballRadius, b.height))
        let section = (Table.ballRadius * Table.ballRadius - down * down).squareRoot()
        let room = max(0, cut.holeRadius - section)

        let across = cut.axis.perpendicular
        let offset = b.position - cut.holeCentre
        var along = offset.dot(cut.axis), side = offset.dot(across)
        var alongSpeed = b.velocity.dot(cut.axis), sideSpeed = b.velocity.dot(across)
        var pushedBack = false
        // How hard the ball went into whichever wall it met, kept for the report below: it is the wood
        // of the pocket's own back and sides that it ran into.
        var intoTheWood = 0.0
        if side > room {
            side = room; pushedBack = true
            if sideSpeed > 0 { intoTheWood = max(intoTheWood, sideSpeed); sideSpeed = -sideSpeed * Self.pocketRestitution }
        }
        if side < -room {
            side = -room; pushedBack = true
            if sideSpeed < 0 { intoTheWood = max(intoTheWood, -sideSpeed); sideSpeed = -sideSpeed * Self.pocketRestitution }
        }
        if along > room {
            along = room; pushedBack = true
            if alongSpeed > 0 { intoTheWood = max(intoTheWood, alongSpeed); alongSpeed = -alongSpeed * Self.pocketRestitution }
        }
        if along < -room {
            along = -room; pushedBack = true
            if alongSpeed < 0 { intoTheWood = max(intoTheWood, -alongSpeed); alongSpeed = -alongSpeed * Self.pocketRestitution }
        }
        if pushedBack {
            let inside = cut.holeCentre + cut.axis * along + across * side
            largestPocketCorrection = max(largestPocketCorrection, inside.distance(to: b.position))
            b.position = inside
            b.velocity = cut.axis * alongSpeed + across * sideSpeed
            if intoTheWood > 0 { events.append(.pocketWood(ball: b.id, speed: intoTheWood)) }
        }
    }

    public func clearEvents() { events.removeAll() }

    public func stopAll() {
        for i in balls.indices {
            // A ball on its way to the floor is not part of the stroke: it is off the table already, and
            // it goes on falling — see `fallToTheFloor`.
            if balls[i].isFalling { continue }
            balls[i].velocity = .zero
            balls[i].spin = .zero
            balls[i].verticalVelocity = 0
            // A ball that is down a pocket stays down; every other ball is on whatever is under it —
            // the cloth of the bed, or the cloth on the wood of a rail.
            if balls[i].onTable {
                balls[i].height = Table.ballRadius + (surfaceUnder(balls[i].position) ?? 0)
            }
        }
    }

    /// Puts a ball back exactly as it was, for a caller rebuilding the world around a stroke: it is how
    /// a ball that is falling off the table is carried over into the new world. See
    /// `FrameDriver.syncWorldFromState`.
    public func putBack(_ ball: Ball) {
        guard let i = index(of: ball.id) else { return }
        balls[i] = ball
    }

    /// Places a ball on the table (used when spotting colours and setting up the rack).
    public func place(ballID: Int, at position: Vec2) {
        guard let i = index(of: ballID) else { return }
        balls[i].position = position
        balls[i].velocity = .zero
        balls[i].spin = .zero
        balls[i].height = Table.ballRadius
        balls[i].verticalVelocity = 0
        balls[i].onTable = true
        balls[i].isFalling = false
        balls[i].pottedInto = nil
    }
}
