import AVFoundation
import SnookerCore

/// The game's sound: every contact the frame reports, played as it happens.
///
/// **The sounds are made here, in code.** The project carries no assets and is written from scratch,
/// and a table's noises are simple enough to build: a click is a burst of noise through a narrow band
/// that dies away in a few tens of milliseconds, and a knock is the same with a low resonance under it
/// for body. Each material is a handful of numbers — where its noise is centred, how sharply, and how
/// fast it falls away — and a few variants of each, so that a break of fifteen balls is not one sample
/// played over and over.
///
/// **Nothing here decides what happens.** The physics reports every contact as `FrameDriver.Impact` —
/// what, where, and how hard — and this only turns that into sound: nothing is played that was not
/// reported, and the headless harness never builds an engine at all, so a probe stays silent.
final class GameAudio {

    /// Whether the player has asked for silence. A mute stops the voices already speaking as well.
    var isMuted = false {
        didSet { if isMuted { for voice in voices { voice.stop() } } }
    }

    /// The engine and the voices it plays through. One voice plays one contact, so the pool is the
    /// polyphony: a break sends a good few balls into each other on one frame, and past this many the
    /// quietest of the frame are dropped rather than the oldest cut off mid-thud.
    private let engine = AVAudioEngine()
    private let format: AVAudioFormat
    private var voices: [AVAudioPlayerNode] = []
    private var nextVoice = 0
    private static let voiceCount = 16

    /// What each material plays: the recorded sample where there is one, and a synthesised stand-in
    /// where there is not — so every kind of contact has a voice whether or not a file was given for it.
    /// A synthesised material is built as a few variants and used in turn, so that the same contact
    /// twice in a row is not the same sample twice in a row.
    private var samples: [FrameDriver.Impact.Kind: [AVAudioPCMBuffer]] = [:]
    private var variantsUsed: [FrameDriver.Impact.Kind: Int] = [:]
    private static let variantCount = 3
    /// When each kind was last played, on the same clock the rest of the engine uses: what keeps a
    /// pack's chain of contacts from being heard as a buzz. See `betweenContactsOfAKind`.
    private var lastPlayedAt: [FrameDriver.Impact.Kind: Double] = [:]
    /// The engine asking to be told when the output device changes under it.
    private var configurationObserver: NSObjectProtocol?

    deinit {
        if let configurationObserver {
            NotificationCenter.default.removeObserver(configurationObserver)
        }
    }

    /// Builds the sounds and starts the engine. Nil when there is no audio to be had at all — the game
    /// is then silent and everything else carries on.
    init?() {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            return nil
        }
        self.format = format
        for _ in 0..<GameAudio.voiceCount {
            let voice = AVAudioPlayerNode()
            engine.attach(voice)
            engine.connect(voice, to: engine.mainMixerNode, format: format)
            voices.append(voice)
        }
        // A file first, the synthesised sound for anything without one. The same file may serve two
        // kinds — the cue on the cue ball is the cue on a ball — so it is read once.
        var read: [String: AVAudioPCMBuffer] = [:]
        for kind in FrameDriver.Impact.Kind.allCases {
            variantsUsed[kind] = 0
            guard let name = GameAudio.files[kind] else {
                samples[kind] = GameAudio.synthesised(kind, in: format)
                continue
            }
            let buffer = read[name] ?? GameAudio.recorded(name, in: format)
            guard let buffer else {
                // The file is named for this material but is not there: the synth stands in for it.
                samples[kind] = GameAudio.synthesised(kind, in: format)
                continue
            }
            read[name] = buffer
            samples[kind] = [buffer]
        }
        engine.prepare()
        do { try engine.start() } catch { return nil }
        // **Warm the voices through.** The first buffers scheduled on a node that has never played can
        // be late by a good part of a frame — the engine's output is only really running once something
        // has been played through it — and the first sound of a session is a pack being hit, where a
        // little lateness is heard as the same click arriving several times over. A couple of
        // milliseconds of silence through every voice at launch settles that before it can be heard.
        warmTheVoices()
        // **The output can change under the engine** — a headset plugged in or pulled out — and the
        // system stops it when it does. Left alone the game simply goes silent for the rest of the
        // session, so it is started again here, with the voices reconnected: a change of device changes
        // the format the mixer works in, and a node left connected at the old one plays nothing.
        configurationObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main
        ) { [weak self] _ in self?.theOutputDeviceChanged() }
        return
    }

    /// A few milliseconds of nothing, for waking the engine's output up before anything is played
    /// through it.
    private static func silence(in format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 128),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = 128
        for frame in 0..<Int(buffer.frameLength) { channel[frame] = 0 }
        return buffer
    }

    /// Plays that silence through every voice and starts them: the engine's output is only really
    /// running once something has been played through it, at launch and again after a device change.
    private func warmTheVoices() {
        guard let silence = GameAudio.silence(in: format) else { return }
        for voice in voices {
            voice.scheduleBuffer(silence, at: nil, options: [])
            voice.play()
        }
    }

    /// The output has changed — a headset plugged in or pulled out — and the system has stopped the
    /// engine. It is started again, with every voice taken off the old format and put back on the new.
    private func theOutputDeviceChanged() {
        for voice in voices {
            voice.stop()
            engine.disconnectNodeOutput(voice)
            engine.connect(voice, to: engine.mainMixerNode, format: format)
        }
        engine.prepare()
        try? engine.start()
        warmTheVoices()
    }

    // MARK: - Playing what the frame reports

    /// Plays the contacts a frame has made. Give it the player's `ear` and the way they are looking and
    /// each contact is placed left or right of them; leave them out and nothing is panned.
    func play(_ impacts: [FrameDriver.Impact], ear: Vec2? = nil, forward: Vec2? = nil) {
        guard !isMuted, engine.isRunning, !impacts.isEmpty else { return }
        // Chosen in the order they happened, not by loudness: a cushion sets the clock that swallows
        // the hop it throws the ball into, and that hop comes after it.
        let now = ProcessInfo.processInfo.systemUptime
        var chosen: [FrameDriver.Impact] = []
        for impact in impacts {
            guard !GameAudio.silent.contains(impact.kind) else { continue }
            // A contact with no speed to it makes no sound: two balls resting against each other report
            // a closing speed of a hair every step, and that is a touch and not a hit.
            guard impact.speed >= GameAudio.silenceSpeed else { continue }
            // A ball that comes back down on the cloth just after a cushion or a throat is that
            // contact's own hop, and is not a second noise for one hit.
            if GameAudio.isTheHopAfterAWoodContact(impact, sinceTheWood: now - lastWoodContactAt) {
                continue
            }
            if impact.kind == .cushion || impact.kind == .throat { lastWoodContactAt = now }
            chosen.append(impact)
        }
        // Then the loudest of those, as many as there are voices, and **no more than one of any one kind
        // inside `betweenContactsOfAKind`**: a pack's chain is one crack to the ear, and a run of the
        // same click inside that window is a buzz rather than a break. See that constant.
        for impact in chosen.sorted(by: { $0.speed > $1.speed }).prefix(GameAudio.voiceCount) {
            // And a contact the level comes out at nothing for is not played at all, rather than taking
            // a voice to say nothing with: wood under four metres a second, and nowhere else.
            let level = GameAudio.level(of: impact)
            guard level > 0 else { continue }
            if let last = lastPlayedAt[impact.kind], now - last < GameAudio.betweenContactsOfAKind {
                continue
            }
            lastPlayedAt[impact.kind] = now
            play(impact, at: level, ear: ear, forward: forward)
        }
    }

    private func play(_ impact: FrameDriver.Impact, at level: Double, ear: Vec2?, forward: Vec2?) {
        guard let set = samples[impact.kind], !set.isEmpty else { return }
        let variant = variantsUsed[impact.kind, default: 0] % set.count
        variantsUsed[impact.kind] = variant + 1

        let voice = voices[nextVoice]
        nextVoice = (nextVoice + 1) % voices.count
        voice.volume = Float(min(1, level * Double.random(in: 0.96...1.03)))
        // The pitch is left where the sample has it, with a hair of jitter so that a run of the same
        // contact is not the same sample exactly; the *speed* of a contact is heard as its loudness.
        voice.rate = Float(Double.random(in: 0.985...1.015))
        voice.pan = Float(GameAudio.pan(of: impact, ear: ear, forward: forward))
        // The interrupt means a voice reused on this frame drops what it was playing and takes the new
        // contact, rather than queueing it up to be heard a moment late.
        voice.scheduleBuffer(set[variant], at: nil, options: .interrupts)
        if !voice.isPlaying { voice.play() }
    }

    /// How loud a contact is: **in proportion to the speed it was made at** — the closing speed of the
    /// two bodies that met — measured against a reference of its own for each material, and no louder
    /// than full scale. Half the speed is half the volume, nothing is silent that has any speed at all,
    /// and a contact with no speed of its own says nothing (see `silenceSpeed`).
    static func level(of impact: FrameDriver.Impact) -> Double {
        // **The wood of a rail is the one contact that has to be loud to be heard at all.** It is wood,
        // and wood is only struck hard on this table: a ball coming down on the rail does so at a hop's
        // speed, and it is the wood at the back of a pocket that is hit at speed. So it is silent below
        // four metres a second, comes in at half volume there, and is at full volume by eight.
        if impact.kind == .rail {
            guard impact.speed >= railQuietBelow else { return 0 }
            return 0.5 + 0.5 * min(1, (impact.speed - railQuietBelow) / (railFullAt - railQuietBelow))
        }
        let weight = weight[impact.kind] ?? 1
        let reference = referenceSpeed[impact.kind] ?? 1500
        return weight * min(1, impact.speed / reference)
    }

    /// Where a contact was, left or right of the player: how far it stands off the line they are
    /// looking along, as a fraction of half the table's width. Half-strength, because a pan is a cue
    /// rather than a pair of headphones.
    private static func pan(of impact: FrameDriver.Impact, ear: Vec2?, forward: Vec2?) -> Double {
        guard let ear, let forward, forward.length > 0 else { return 0 }
        let right = Vec2(forward.y, -forward.x)
        return max(-1, min(1, (impact.at - ear).dot(right) / (Table.width / 2))) * 0.5
    }

    /// The speed at which a contact of each kind is as loud as it gets, its volume being in proportion
    /// to its speed up to there. The kinds meet the ball very differently — a cushion takes one at a
    /// couple of metres a second, a stroke leaves the cue ball at up to six, the wood of a rail only
    /// what a hop brings down on it, and a ball that has fallen to the floor is at three or four — so
    /// each is measured against its own.
    private static let referenceSpeed: [FrameDriver.Impact.Kind: Double] = [
        .strike: 4000,
        .ballOnBall: 2500,
        .cushion: 2000,
        .throat: 1200,
        .bed: 500,          // a ball coming back down on the cloth: a hop, not a shot
        .floor: 4000,       // it has fallen a table's height, so it always arrives at about this
        .cueOnBall: 2500,
    ]

    /// The voice each material is given in the mix: a click of ball on ball is the loudest thing on a
    /// table; a ball landing on the floor is a solid thud; the stroke and the stick on a ball are set
    /// under it, and the cushion, the throat and the cloth of the bed well under that.
    private static let weight: [FrameDriver.Impact.Kind: Double] = [
        .strike: 0.3, .ballOnBall: 1.0, .cushion: 0.05, .throat: 0.05,
        .bed: 0.2, .floor: 0.8, .cueOnBall: 0.3,
    ]

    /// Where the rail's own rule bites: silent to `railQuietBelow`, half volume there, full at
    /// `railFullAt`. See `level(of:)`.
    private static let railQuietBelow: Double = 4000
    private static let railFullAt: Double = 8000

    /// Below this, no contact is heard at all. Two balls that are **touching** report a closing speed
    /// of a hair as the solver keeps them apart, and a touch is not a hit: nothing is played for it.
    private static let silenceSpeed: Double = 12

    /// The closest two contacts **of one kind** are played, in seconds.
    ///
    /// A frame that carried a long stretch of the simulation collects a pack's whole collision chain
    /// into one instant, and that happens on the **first break of a session**: the picture is still
    /// being warmed up, a frame that should take eight milliseconds takes fifty, and each of its
    /// substeps reports its own contacts into that frame. Playing them all is a buzz, and playing them
    /// a few milliseconds apart is worse — a run at a few milliseconds is a **pitch** of a few hundred
    /// hertz, not a set of clicks, which is why it is heard above the clack rather than beside it.
    ///
    /// So a kind is played at most once in this long. Twenty milliseconds is about where the ear stops
    /// fusing two clicks into one, so a pack's chain arrives as the one crack it sounds like, and two
    /// contacts that really are separate — a ball off one cushion and then another — are still two.
    static let betweenContactsOfAKind: Double = 0.02

    /// How long after a cushion or a throat a ball coming back down on the cloth is taken to be that
    /// contact's own hop rather than a contact of its own.
    ///
    /// A cushion answers a ball **above its own equator** — the nose overhangs the cloth — so part of
    /// its answer throws the ball up off the cloth, and the ball lands again a moment later. Without
    /// this, one cushion would make two noises: the cushion, and then the cloth, which is the louder of
    /// the two and the busiest sound on the table. The ball's flight is its own: a hop of a few
    /// millimetres is forty milliseconds, and one of a hundred millimetres is three hundred, so the
    /// window is long enough for the hop a hard hit throws and short enough that the next shot is not
    /// swallowed with it.
    static let clothQuietAfterAWoodContact: Double = 0.4

    /// Whether a contact is swallowed by that rule. Shared with `--sound-check`, so that what the probe
    /// reports is decided by the same line the game plays by.
    static func isTheHopAfterAWoodContact(_ impact: FrameDriver.Impact, sinceTheWood ago: Double) -> Bool {
        impact.kind == .bed && ago < clothQuietAfterAWoodContact
    }

    /// The clock at the last cushion or throat played. `systemUptime` is a clock that cannot go
    /// backwards, and one that is only read here.
    private var lastWoodContactAt: Double = 0

    /// The kinds that make **no sound at all**. A ball reaching the bottom of a pocket is not a
    /// collision — there is nothing for it to be in proportion to — and the game is silent as it drops.
    private static let silent: Set<FrameDriver.Impact.Kind> = [.pocket]

    /// The recorded sample for each material, by the name of the file in the app's own resources. A kind
    /// left out of this — or whose file is missing — is played with its synthesised sound instead.
    private static let files: [FrameDriver.Impact.Kind: String] = [
        .strike: "cue-ball",
        .ballOnBall: "ball-ball",
        .cushion: "cushion",
        .throat: "throat",
        .rail: "ball-rail",
        // A ball coming back down on the cloth of the bed; the throat's own recording is what a ball
        // landing on the table sounds like.
        .bed: "throat",
        .floor: "drop",
        // The same recorded sample: a ball knocked by the stick is a ball hit by leather, as the cue
        // ball is.
        .cueOnBall: "cue-ball",
    ]

    // MARK: - The sounds themselves

    /// What one material sounds like: where its noise is centred and how sharply it is filtered, how
    /// fast it falls away, and the low resonance under it that gives it a body.
    private struct Recipe {
        var centre: Double      // band-pass centre, Hz
        var q: Double           // how narrow the band is
        var decay: Double       // seconds for the noise to fall to nothing
        var tone: Double        // a struck resonance under it, Hz (0 for none)
        var toneDecay: Double
        var toneMix: Double
        var knocks: Int         // separate knocks in the one sound: a pot rattles on the way in
        var spacing: Double     // seconds between them
    }

    private static let palette: [FrameDriver.Impact.Kind: Recipe] = [
        // The tip on the cue ball: a short, bright "tock" with a ring under it.
        .strike: Recipe(centre: 2600, q: 1.1, decay: 0.040, tone: 1500, toneDecay: 0.020,
                        toneMix: 0.30, knocks: 1, spacing: 0),
        // Ball on ball: the classic high click — brighter and shorter than anything else on the table.
        .ballOnBall: Recipe(centre: 3600, q: 1.6, decay: 0.028, tone: 0, toneDecay: 0,
                            toneMix: 0, knocks: 1, spacing: 0),
        // The rubber: a dull thud with a low body under it.
        .cushion: Recipe(centre: 700, q: 0.8, decay: 0.090, tone: 170, toneDecay: 0.070,
                         toneMix: 0.45, knocks: 1, spacing: 0),
        // The dead facing of a pocket's throat: duller and deader than the rubber behind it.
        .throat: Recipe(centre: 950, q: 0.9, decay: 0.055, tone: 0, toneDecay: 0,
                        toneMix: 0, knocks: 1, spacing: 0),
        // A ball coming back down on the cloth of the bed — the stand-in for the throat's recording,
        // which is what plays when the file is there.
        .bed: Recipe(centre: 900, q: 0.9, decay: 0.050, tone: 0, toneDecay: 0,
                     toneMix: 0, knocks: 1, spacing: 0),
        // The wood of the rail under its cloth: a knock with a note in it.
        .rail: Recipe(centre: 480, q: 0.7, decay: 0.045, tone: 300, toneDecay: 0.090,
                      toneMix: 0.60, knocks: 1, spacing: 0),
        // The stick knocking a ball in play: a duller, deader click than ball on ball.
        .cueOnBall: Recipe(centre: 1800, q: 1.0, decay: 0.050, tone: 0, toneDecay: 0,
                           toneMix: 0, knocks: 1, spacing: 0),
    ]

    private static func synthesised(_ kind: FrameDriver.Impact.Kind, in format: AVAudioFormat)
        -> [AVAudioPCMBuffer] {
        guard let recipe = palette[kind] else { return [] }
        return (0..<variantCount).compactMap { index in
            render(recipe, seed: UInt64(index) &* 0x9E37_79B9 &+ UInt64(kind.rawValue.count) &+ 1,
                   in: format)
        }
    }

    /// Reads one recorded sample out of the app's own resources, in the format the voices speak.
    ///
    /// The file may be any rate and any number of channels — the samples here are 44.1 or 48 kHz
    /// stereo — so it is converted to the voices' mono, at the engine's rate, once, at launch. Nil
    /// when there is no such file: the synthesised sound stands in for that material.
    private static func recorded(_ name: String, in format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "flac"),
              let file = try? AVAudioFile(forReading: url) else { return nil }
        let source = file.processingFormat
        let frames = AVAudioFrameCount(file.length)
        guard frames > 0,
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: frames) else { return nil }
        do { try file.read(into: input) } catch { return nil }
        if source.sampleRate == format.sampleRate, source.channelCount == format.channelCount {
            return normalised(input)
        }
        return converted(input, from: source, to: format).map(normalised)
    }

    /// Brings a recorded sample up to the same peak as the rest.
    ///
    /// The files were recorded by different people with different gear, and they arrive at very
    /// different levels — the quietest of these peaks some thirteen decibels below the loudest — so
    /// without this the mix would be decided by whoever held the microphone. What is left to set the
    /// balance is `weight`, and what is left to set the strength of a contact is its speed.
    private static func normalised(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer {
        guard let channel = buffer.floatChannelData?[0] else { return buffer }
        let count = Int(buffer.frameLength)
        var peak = 0.0
        for i in 0..<count { peak = max(peak, abs(Double(channel[i]))) }
        guard peak > 1e-9 else { return buffer }
        let gain = 0.85 / peak
        for i in 0..<count { channel[i] = Float(Double(channel[i]) * gain) }
        return buffer
    }

    /// The sample in the voices' own format — mono, at the engine's rate — through the system's
    /// converter, which is the one place resampling is done rather than by hand.
    private static func converted(_ input: AVAudioPCMBuffer, from source: AVAudioFormat,
                                  to format: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: source, to: format) else { return nil }
        let ratio = format.sampleRate / source.sampleRate
        let capacity = AVAudioFrameCount(Double(input.frameLength) * ratio + 64)
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return nil }
        var handedOver = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if handedOver { status.pointee = .endOfStream; return nil }
            handedOver = true
            status.pointee = .haveData
            return input
        }
        return error == nil && output.frameLength > 0 ? output : nil
    }

    /// Builds one sound: noise struck at `knocks` moments and passed through a band-pass, with a low
    /// resonance added under it, normalised so that every material comes out at the same peak and with
    /// neither end of it a step.
    private static func render(_ recipe: Recipe, seed: UInt64, in format: AVAudioFormat)
        -> AVAudioPCMBuffer? {
        let rate = format.sampleRate
        let seconds = recipe.decay * 1.6
            + recipe.spacing * Double(max(0, recipe.knocks - 1)) + 0.01
        let count = max(1, Int(seconds * rate))
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)),
              let channel = buffer.floatChannelData?[0] else { return nil }
        buffer.frameLength = AVAudioFrameCount(count)

        var noise = SeededNoise(seed: seed)
        var excitation = [Double](repeating: 0, count: count)
        let fall = recipe.decay / 6.9      // down to a thousandth over the decay
        for knock in 0..<max(1, recipe.knocks) {
            let start = Double(knock) * recipe.spacing
            for i in 0..<count {
                let t = Double(i) / rate - start
                guard t >= 0, t < recipe.decay * 1.6 else { continue }
                excitation[i] += noise.next() * exp(-t / fall)
            }
        }
        let filtered = bandPass(excitation, centre: recipe.centre, q: recipe.q, rate: rate)
        for i in 0..<count {
            let t = Double(i) / rate
            var v = filtered[i]
            if recipe.tone > 0 {
                v += sin(2 * .pi * recipe.tone * t)
                    * exp(-t / (recipe.toneDecay / 6.9)) * recipe.toneMix
            }
            channel[i] = Float(v)
        }

        var peak = 0.0
        for i in 0..<count { peak = max(peak, abs(Double(channel[i]))) }
        guard peak > 1e-9 else { return nil }
        let gain = 0.9 / peak
        for i in 0..<count { channel[i] = Float(Double(channel[i]) * gain) }
        // A short ramp off each end, so the sound does not begin or end on a step of its own. Half a
        // millisecond is enough not to click and short enough to leave a click's attack on it.
        let fade = max(1, min(Int(0.0005 * rate), count / 4))
        for i in 0..<min(fade, count) {
            let g = Float(i) / Float(fade)
            channel[i] *= g
            channel[count - 1 - i] *= g
        }
        return buffer
    }

    /// A second-order band-pass, the usual cookbook one: what is left of a burst of noise once
    /// everything outside the band is taken away is the ring of the material it was passed through.
    private static func bandPass(_ x: [Double], centre: Double, q: Double, rate: Double) -> [Double] {
        let w0 = 2 * Double.pi * centre / rate
        let alpha = sin(w0) / (2 * max(0.05, q))
        let a0 = 1 + alpha
        let b0 = alpha / a0, b2 = -alpha / a0
        let a1 = -2 * cos(w0) / a0, a2 = (1 - alpha) / a0
        var y = [Double](repeating: 0, count: x.count)
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in x.indices {
            let v = b0 * x[i] + b2 * x2 - a1 * y1 - a2 * y2
            y[i] = v
            x2 = x1; x1 = x[i]
            y2 = y1; y1 = v
        }
        return y
    }

    /// White noise from a seed, so a sound is the same every launch: a table should not sound
    /// different each time the game is opened, and a probe can be compared with itself.
    private struct SeededNoise {
        private var state: UInt64
        init(seed: UInt64) { state = seed | 1 }
        mutating func next() -> Double {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Double(state >> 11) / Double(UInt64(1) << 53) * 2 - 1
        }
    }

    // MARK: - Checking it without a screen or an ear

    /// Builds every sound and reports it — how long it is, how loud, and how much there is to it — and
    /// starts the engine, so the whole of the audio path can be checked where there is nothing to
    /// listen to. Used by `--sound-check`; each sound is written out as a WAV when given a directory.
    @discardableResult
    static func soundCheck(into directory: URL?) -> Bool {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1) else {
            print("  WRONG: no audio format to build a sound in")
            return false
        }
        print("sound check — the recorded sample where one is given, the synthesised sound where not")
        var allGood = true
        for kind in FrameDriver.Impact.Kind.allCases {
            if GameAudio.silent.contains(kind) {
                print(String(format: "  %-11@ silent, and meant to be", kind.rawValue as NSString))
                continue
            }
            let name = GameAudio.files[kind]
            let from = name.flatMap { GameAudio.recorded($0, in: format) }
            let set = from.map { [$0] } ?? synthesised(kind, in: format)
            guard let first = set.first, let channel = first.floatChannelData?[0] else {
                print("  \(kind.rawValue): WRONG — nothing was built")
                allGood = false
                continue
            }
            var peak = 0.0, energy = 0.0
            for i in 0..<Int(first.frameLength) {
                let v = Double(channel[i])
                peak = max(peak, abs(v))
                energy += v * v
            }
            let milliseconds = Double(first.frameLength) / format.sampleRate * 1000
            let rms = (energy / Double(first.frameLength)).squareRoot()
            let source = from != nil ? "recorded \(name ?? "").flac" : "synthesised, \(set.count) variants"
            print(String(format: "  %-11@ %-28@ %4.0f ms, peak %.2f, rms %.3f",
                         kind.rawValue as NSString, source as NSString, milliseconds, peak, rms))
            if let directory {
                for (index, buffer) in set.enumerated() {
                    let url = directory.appendingPathComponent("\(kind.rawValue)-\(index).wav")
                    do { try write(buffer, to: url) } catch {
                        print("    (could not write \(url.lastPathComponent): \(error))")
                    }
                }
            }
        }
        if let audio = GameAudio() {
            audio.isMuted = true     // a check is not a performance
            print("  the engine starts, with \(audio.voices.count) voices")
        } else {
            print("  the engine would not start (no audio to play to) — the game is silent, not broken")
        }
        // The mix: what each material's ceiling is, and the speed it reaches it at, so the tuning can
        // be read back rather than taken on trust.
        let mix = FrameDriver.Impact.Kind.allCases
            .filter { $0 != .rail && !silent.contains($0) }
            .sorted { (weight[$0] ?? 1) > (weight[$1] ?? 1) }
            .map { kind in
                String(format: "%@ %.3f at %.1f m/s", kind.rawValue, weight[kind] ?? 1,
                       (referenceSpeed[kind] ?? 1500) / 1000)
            }
            .joined(separator: ",  ")
        print("  the mix: \(mix)")
        // The one contact whose volume is not simply in proportion to its speed: wood, which is only
        // struck hard on this table.
        let rail = [3000.0, 4000.0, 6000.0, 8000.0].map { speed in
            String(format: "%.0f m/s → %.2f", speed / 1000,
                   level(of: FrameDriver.Impact(kind: .rail, at: .zero, speed: speed)))
        }.joined(separator: ",  ")
        print("  the rail: \(rail)")
        return allGood
    }

    private static func write(_ buffer: AVAudioPCMBuffer, to url: URL) throws {
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: buffer.format.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        try file.write(from: buffer)
    }
}
