import Foundation

/// Where the player is standing and what they are looking at, for the first-person
/// ("in person") 3D view.
///
/// Positions are in the engine's table coordinates, in millimetres: `x` runs from the
/// baulk cushion to the top cushion and `y` across the table. As in `Table`, a player
/// standing at the baulk end looking down the table has the lower `y` on their right.
public struct PlayerCamera: Equatable, Sendable {

    /// How far back the player stands and how high their eye is.
    public enum Preset: String, CaseIterable, Sendable {
        /// Down on the shot: the eye is close to the cue, sighting along it.
        case sighting
        /// Standing at the table holding the cue, before getting down.
        case standing
        /// A raised view from further back, taking in the whole table.
        case raised

        public var title: String {
            switch self {
            case .sighting: return "on the shot"
            case .standing: return "standing"
            case .raised: return "raised"
            }
        }

        /// Distance the eye sits behind the cue ball, in millimetres.
        public var standOff: Double {
            switch self {
            // Far enough back that the whole "D" is in view: standing right over it, its near edge
            // falls below the bottom of the frame and the table reads as a triangle.
            case .sighting: return 620
            case .standing: return 1080
            case .raised: return 1760
            }
        }

        /// Height of the eye above the cloth, in millimetres.
        ///
        /// A table is about 850 mm high, so a standing player's eye is roughly 800 mm
        /// above the cloth and a player down on the shot is near 235 mm.
        public var eyeHeight: Double {
            switch self {
            case .sighting: return 235
            case .standing: return 810
            case .raised: return 1790
            }
        }

        /// How far the player looks down at the cloth, in radians.
        public var pitch: Double {
            switch self {
            case .sighting: return -14 * .pi / 180
            case .standing: return -24 * .pi / 180
            case .raised: return -38 * .pi / 180
            }
        }

        /// Vertical field of view, in degrees.
        public var fieldOfView: Double {
            switch self {
            case .sighting, .standing: return 52
            case .raised: return 46
            }
        }

        /// How far up the line of aim the player's gaze converges, in millimetres.
        ///
        /// A player stands a little to one side of the cue but looks along the shot, so the view
        /// closes back onto the line of aim rather than running parallel to it.
        public var converge: Double {
            switch self {
            case .sighting: return 1800
            case .standing: return 3000
            case .raised: return 4500
            }
        }
    }

    /// A point on the line of sight.
    public struct GazePoint: Equatable, Sendable {
        public var position: Vec2
        /// Height above the cloth, in millimetres.
        public var height: Double

        public init(position: Vec2, height: Double) {
            self.position = position
            self.height = height
        }
    }

    /// The eye position in the table plane.
    public var eye: Vec2
    /// Height of the eye above the cloth, in millimetres.
    public var eyeHeight: Double
    /// Direction of gaze in radians, measured the same way as `FrameDriver.aimAngle`.
    public var yaw: Double
    /// Gaze elevation in radians: negative looks down at the cloth.
    public var pitch: Double
    /// Vertical field of view, in degrees.
    public var fieldOfView: Double

    /// The limits within which the gaze may be raised or lowered. Anything beyond
    /// straight down or straight up leaves the table behind the player.
    public static let pitchRange: ClosedRange<Double> = (-72 * .pi / 180)...(20 * .pi / 180)

    /// How high the eye is when the player **crouches** down over the cloth: 150 mm above the table
    /// surface, which is low enough to look along the bed at a ball's own height and see the line of a
    /// pot. It is a height to duck to for a look rather than a stance to stand in — the feet stay where
    /// they are and the eye comes back up when the player straightens — so it is a height of its own and
    /// not one of the presets.
    public static let crouchEyeHeight: Double = 150

    /// A point on the line of sight, `distance` millimetres from the eye.
    public func gazePoint(distance: Double) -> GazePoint {
        let flat = cos(pitch) * distance
        let direction = Vec2(cos(yaw), sin(yaw))
        return GazePoint(position: eye + direction * flat, height: eyeHeight + sin(pitch) * distance)
    }

    /// Where the player is looking: a point on the line of aim, `converge` millimetres beyond
    /// `aimLinePoint`, at the depth that the gaze elevation asks for.
    public func convergencePoint(aimLinePoint: Vec2, converge: Double) -> GazePoint {
        let direction = Vec2(cos(yaw), sin(yaw))
        let target = aimLinePoint + direction * converge
        let horizontal = (target - eye).length
        return GazePoint(position: target, height: eyeHeight + tan(pitch) * horizontal)
    }
}

/// Works out where the player's eye sits for a given cue ball and line of aim.
public enum PlayerViewSolver {

    /// The camera for a player standing at `eye`, looking along `yaw` and `pitch`: where the player has
    /// walked to with the cue put away, rather than standing over the shot.
    public static func camera(eye: Vec2, eyeHeight: Double, yaw: Double, pitch: Double,
                              fieldOfView: Double) -> PlayerCamera {
        PlayerCamera(eye: eye, eyeHeight: eyeHeight, yaw: yaw, pitch: clampPitch(pitch),
                     fieldOfView: fieldOfView)
    }

    /// The camera for a player sighting along `yaw` from behind the cue ball.
    ///
    /// The eye sits **directly above the line of aim**, so the player sights straight down the
    /// cue: the cue itself is always directly below the eye, running away up the view.
    public static func camera(
        cueBall: Vec2,
        yaw: Double,
        pitch: Double,
        preset: PlayerCamera.Preset
    ) -> PlayerCamera {
        let forward = Vec2(cos(yaw), sin(yaw))
        let eye = cueBall - forward * preset.standOff
        return PlayerCamera(
            eye: eye,
            eyeHeight: preset.eyeHeight,
            yaw: yaw,
            pitch: clampPitch(pitch),
            fieldOfView: preset.fieldOfView
        )
    }

    /// Keeps a gaze elevation inside `PlayerCamera.pitchRange`.
    public static func clampPitch(_ pitch: Double) -> Double {
        min(max(pitch, PlayerCamera.pitchRange.lowerBound), PlayerCamera.pitchRange.upperBound)
    }

    /// The same camera, from framing given as numbers rather than as one of the presets.
    ///
    /// Standing at the table and down on the shot are the same position solved from different
    /// numbers, so a player getting down is a matter of moving between them: the game interpolates
    /// the stand-off, the eye height, the gaze and the field of view and asks for the camera here.
    public static func camera(cueBall: Vec2,
                              yaw: Double,
                              pitch: Double,
                              standOff: Double,
                              eyeHeight: Double,
                              fieldOfView: Double) -> PlayerCamera {
        let forward = Vec2(cos(yaw), sin(yaw))
        let eye = cueBall - forward * standOff
        return PlayerCamera(
            eye: eye,
            eyeHeight: eyeHeight,
            yaw: yaw,
            pitch: clampPitch(pitch),
            fieldOfView: fieldOfView
        )
    }

    /// One framing between two of the presets: `t` of 0 is the first, 1 the second.
    public static func framing(from start: PlayerCamera.Preset,
                               to end: PlayerCamera.Preset,
                               _ t: Double,
                               elevation: Double = 0)
        -> (standOff: Double, eyeHeight: Double, pitch: Double, fieldOfView: Double) {
        let blend = min(max(t, 0), 1)
        // Down on the shot the head rides the cue: a cue stood up takes the eye up with it and tips
        // the gaze down to match, so the player is still looking along the cue with their head above
        // it. Any other preset is used as it is.
        let ending = end == .sighting
            ? sighting(standOff: end.standOff, elevation: elevation)
            : (eyeHeight: end.eyeHeight, pitch: end.pitch)
        return (start.standOff + (end.standOff - start.standOff) * blend,
                start.eyeHeight + (ending.eyeHeight - start.eyeHeight) * blend,
                start.pitch + (ending.pitch - start.pitch) * blend,
                start.fieldOfView + (end.fieldOfView - start.fieldOfView) * blend)
    }

    /// Down on the shot with the cue stood up: where the eye sits and how far it looks down.
    ///
    /// The eye sits above the line of aim, `standOff` behind the ball. The cue passes through the ball
    /// at the cue's own angle, so at the eye's place along the table it stands `standOff · tan(lift)`
    /// higher than it does with the cue level — and the player stands up with it, keeping the same
    /// clearance over the cue they had before. The gaze tips down by the lift as well, so they are
    /// still looking along the cue rather than over it. At 45° the player is all but standing again.
    ///
    /// **Straight up** is the end of that: the cue can be stood right up to 90°, and a head down the
    /// *line of the cue* that far up would be a head away for ever, so the rise stops climbing at 45°.
    /// A player standing a cue on end is on their feet looking down at the ball, and it is the gaze —
    /// which tips all the way with the cue, clamped at `pitchRange` — that says so.
    public static func sighting(standOff: Double, elevation: Double)
        -> (eyeHeight: Double, pitch: Double) {
        let preset = PlayerCamera.Preset.sighting
        let lift = min(max(elevation, 0), PhysicsWorld.maxCueElevation)
        let risingWith = min(lift, 45 * .pi / 180)
        return (preset.eyeHeight + standOff * tan(risingWith), preset.pitch - lift)
    }
}

/// The player up and about: where their body stands, how they walk about the table, and how far they
/// may lean over it. Positions are in the engine's table coordinates, in millimetres.
public enum PlayerWalk {

    /// How wide the player's body is on the floor. It is what keeps them off the table: their centre
    /// stands this far clear of the table's own footprint — the wood included — wherever they are.
    public static let bodyRadius: Double = 250

    /// How far a player leaning over a shot can reach past the side of the table: eye to waist. Down on
    /// the shot the camera may come **inside** the table, but no further in than the body would let it
    /// lean while the waist stays outside.
    public static let leanReach: Double = 450

    /// How fast the player walks, in millimetres a second: a stroll about the table.
    public static let pace: Double = 900

    /// The table's footprint with the player's body added: inside this, the body overlaps the table.
    private static var clearance: Double { Table.tableSurround + bodyRadius }
    private static var farX: Double { Table.length + clearance }
    private static var farY: Double { Table.width + clearance }

    /// True when the player's body standing at `p` is clear of the table.
    public static func isClearOfTheTable(_ p: Vec2) -> Bool {
        p.x <= -clearance || p.x >= farX || p.y <= -clearance || p.y >= farY
    }

    /// `p` pushed out of the table if the body would overlap it, by the shortest way.
    public static func clearOfTheTable(_ p: Vec2) -> Vec2 {
        guard !isClearOfTheTable(p) else { return p }
        let left = p.x + clearance, right = farX - p.x
        let bottom = p.y + clearance, top = farY - p.y
        let nearest = min(left, right, bottom, top)
        if nearest == left { return Vec2(-clearance, p.y) }
        if nearest == right { return Vec2(farX, p.y) }
        if nearest == bottom { return Vec2(p.x, -clearance) }
        return Vec2(p.x, farY)
    }

    /// One step of `forward` — along the way the player is looking — and `sideways` to their right,
    /// with their body kept clear of the table. A step that would put them on it is taken as far as it
    /// can be: forwards or across on its own, whichever is still clear, so they walk along the edge
    /// rather than being shunted round it.
    public static func step(from p: Vec2, forward: Double, sideways: Double, yaw: Double) -> Vec2 {
        let ahead = Vec2(cos(yaw), sin(yaw))
        let right = Vec2(ahead.y, -ahead.x)
        let whole = p + ahead * forward + right * sideways
        if isClearOfTheTable(whole) { return whole }
        let aheadOnly = p + ahead * forward
        if isClearOfTheTable(aheadOnly) { return aheadOnly }
        let acrossOnly = p + right * sideways
        if isClearOfTheTable(acrossOnly) { return acrossOnly }
        return p
    }

    /// How far back from the ball the player has to stand, going `away` from it, for their body to be
    /// clear of the table. The ball is on the table, so a player standing straight behind it is clear
    /// by the time they reach the near edge of the wood: shooting across the table, right at it.
    public static func clearStandOff(from ball: Vec2, away: Vec2) -> Double {
        let dir = away.normalized
        guard dir.length > 0 else { return 0 }
        func leaving(_ p: Double, _ d: Double, _ low: Double, _ high: Double) -> Double? {
            guard abs(d) > 1e-9 else { return nil }
            let distance = ((d > 0 ? high : low) - p) / d
            return distance > 1e-9 ? distance : nil
        }
        let ways = [leaving(ball.x, dir.x, -clearance, farX), leaving(ball.y, dir.y, -clearance, farY)]
        return ways.compactMap { $0 }.min() ?? 0
    }

    /// How far back from the ball a camera has to stand, going `away` from it, to be no further inside
    /// the table than a player leaning over it could look.
    ///
    /// Down on the shot the camera may come **in over the cushion** — the eye leans over the table while
    /// the waist stays outside — but never deeper inside than the eye-to-waist reach, which is what
    /// standing back from a ball in the middle of the table means. It is a limit and not a target, so a
    /// ball near a cushion needs nothing: a ball already within the reach takes a stand-off of 0. And it
    /// comes off the distance *along the line of the cue*, so the camera is always exactly above the cue
    /// rather than being shunted sideways to get out of the table.
    public static func leaningStandOff(from ball: Vec2, away: Vec2) -> Double {
        let dir = away.normalized
        guard dir.length > 0 else { return 0 }
        // Deeper inside than the reach: in x and in y both.
        guard ball.x > leanReach, ball.x < Table.length - leanReach,
              ball.y > leanReach, ball.y < Table.width - leanReach else { return 0 }
        func leaving(_ p: Double, _ d: Double, _ low: Double, _ high: Double) -> Double? {
            guard abs(d) > 1e-9 else { return nil }
            let distance = ((d > 0 ? high : low) - p) / d
            return distance > 1e-9 ? distance : nil
        }
        let ways = [leaving(ball.x, dir.x, leanReach, Table.length - leanReach),
                    leaving(ball.y, dir.y, leanReach, Table.width - leanReach)]
        return ways.compactMap { $0 }.min() ?? 0
    }
}
