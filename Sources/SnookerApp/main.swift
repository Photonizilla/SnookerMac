import AppKit
import SceneKit
import SpriteKit
import SnookerCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    private var window: NSWindow!
    private var scene: TableScene!
    private var table3D: Table3D!
    private var table3DView: SCNView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()

        let rect = NSRect(x: 0, y: 0, width: 1180, height: 760)
        window = NSWindow(contentRect: rect,
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered,
                          defer: false)
        window.title = "Snooker"
        window.center()
        window.minSize = NSSize(width: 900, height: 620)

        let container = NSView(frame: rect)
        container.autoresizingMask = [.width, .height]

        // The 3D table sits at the back of the window; the SpriteKit scene is a transparent HUD
        // over it, and goes opaque again when the player switches to the top-down view.
        table3DView = SCNView(frame: rect)
        table3DView.autoresizingMask = [.width, .height]
        container.addSubview(table3DView)
        table3D = Table3D(view: table3DView)

        let view = SKView(frame: rect)
        view.ignoresSiblingOrder = true
        view.preferredFramesPerSecond = 120
        view.autoresizingMask = [.width, .height]
        view.allowsTransparency = true
        container.addSubview(view)

        scene = TableScene(size: rect.size)
        scene.scaleMode = .resizeFill
        scene.table3D = table3D
        scene.audio = GameAudio()
        scene.onViewModeChange = { [weak self] mode in self?.apply(mode) }
        scene.onFrameRateChange = { [weak self] rate in self?.apply(rate) }
        view.presentScene(scene)

        window.contentView = container
        window.acceptsMouseMovedEvents = true
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        NSApp.activate(ignoringOtherApps: true)
        apply(scene.viewMode)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// The rate the game is being drawn at, as the scene last asked for it. See `TableScene.FrameRate`.
    private var currentRate: TableScene.FrameRate = .standing

    /// Starts and stops the 3D renderer as the player moves between the two views.
    private func apply(_ mode: TableScene.ViewMode) {
        table3DView.isPlaying = mode == .firstPerson && currentRate != .idle
    }

    /// What the scene's frame rate means for the 3D table: it is drawn at the rate the scene asks for,
    /// and stopped outright when the scene has nothing to draw — the picture stays on the screen, and
    /// nothing is spent keeping it there. The HUD's own rate the scene sets for itself, through the
    /// `SKView` it is presented in.
    private func apply(_ rate: TableScene.FrameRate) {
        currentRate = rate
        table3DView.preferredFramesPerSecond = max(1, rate.rawValue)
        table3DView.isPlaying = rate != .idle && scene.viewMode == .firstPerson
    }

    private func buildMenu() {
        let mainMenu = NSMenu()

        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Snooker", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Snooker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        let gameItem = NSMenuItem()
        mainMenu.addItem(gameItem)
        let gameMenu = NSMenu(title: "Game")
        gameMenu.addItem(withTitle: "New Frame", action: #selector(newFrame), keyEquivalent: "n")
        // No key equivalent: Esc is the scene's own, the way V and G are, and a key the menu took would
        // never reach it.
        gameMenu.addItem(withTitle: "New Game…", action: #selector(newGame), keyEquivalent: "")
        gameMenu.addItem(withTitle: "Re-rack (Stalemate)", action: #selector(askToReRack), keyEquivalent: "r")
        // Shift-C: plain C is the cue, put away or laid on the table, which is the handier key.
        let concedeItem = gameMenu.addItem(withTitle: "Concede Frame", action: #selector(concede), keyEquivalent: "c")
        concedeItem.keyEquivalentModifierMask = [.shift]
        gameMenu.addItem(withTitle: "Claim the Frame", action: #selector(claimTheFrame), keyEquivalent: "")
        gameMenu.addItem(.separator())
        // Who plays the two seats is the question **New Game** asks (Esc asks it too), so there is nothing
        // to set here: the modes and the difficulty are on the question's own buttons.
        gameItem.submenu = gameMenu

        let viewItem = NSMenuItem()
        mainMenu.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(withTitle: "Player's View", action: #selector(showPlayerView), keyEquivalent: "v")
        viewMenu.addItem(withTitle: "Top-down View", action: #selector(showTopDownView), keyEquivalent: "t")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Eye Level: On the Shot", action: #selector(eyeOnTheShot), keyEquivalent: "1")
        viewMenu.addItem(withTitle: "Eye Level: Standing", action: #selector(eyeStanding), keyEquivalent: "2")
        viewMenu.addItem(withTitle: "Eye Level: Raised", action: #selector(eyeRaised), keyEquivalent: "3")
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Aiming Aids", action: #selector(toggleAids), keyEquivalent: "g")
        viewMenu.addItem(.separator())
        // No key equivalents on these two: plain F and plain M are the scene's own (`TableScene.keyDown`),
        // the way V and G are, and a key the menu took would never reach it.
        viewMenu.addItem(withTitle: "Full Screen", action: #selector(toggleFullScreen), keyEquivalent: "")
        viewMenu.addItem(withTitle: "Mute Sound", action: #selector(toggleSound), keyEquivalent: "")
        viewItem.submenu = viewMenu

        NSApp.mainMenu = mainMenu
    }

    // While the non-offender is deciding what happens after a foul, the letters on those choices belong
    // to the table: R is "Replace balls, offender plays" there, not a re-rack. The menu steps aside for
    // the questions whose answers are on the screen (see `TableScene.keyDown`).
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(toggleSound) {
            menuItem.title = (scene?.audio?.isMuted ?? false) ? "Unmute Sound" : "Mute Sound"
            return scene?.audio != nil
        }
        if menuItem.action == #selector(toggleAids) {
            menuItem.title = "Aiming Aids: \(table3D?.aimingAids.title ?? "off")"
            return table3D != nil
        }
        guard menuItem.action == #selector(askToReRack) || menuItem.action == #selector(newFrame) else {
            return true
        }
        switch scene?.controller.pending {
        case .afterFoul, .afterMiss: return false
        default: return true
        }
    }

    @objc private func newFrame() {
        guard let controller = scene?.controller else { return }
        // With the frame already **over** there is nothing to guard: a new frame is what the player is
        // asking for, so N (or the menu item) just starts one. During a frame it asks first.
        if controller.isFrameOver {
            controller.startTheNewFrame()
        } else {
            controller.askToStartANewFrame()
        }
        scene?.refresh(force: true)
    }
    @objc private func askToReRack() { scene?.controller.askToReRack(); scene?.refresh(force: true) }
    @objc private func newGame() { scene?.controller.askToStartANewGame(); scene?.refresh(force: true) }
    @objc private func concede() { scene?.controller.concede(); scene?.refresh(force: true) }
    @objc private func claimTheFrame() { scene?.controller.claimTheFrame(); scene?.refresh(force: true) }


    @objc private func showPlayerView() { scene?.setViewMode(.firstPerson) }
    @objc private func showTopDownView() { scene?.setViewMode(.topDown) }
    @objc private func eyeOnTheShot() { useEyeLevel(.sighting) }
    @objc private func eyeStanding() { useEyeLevel(.standing) }
    @objc private func eyeRaised() { useEyeLevel(.raised) }
    @objc private func toggleAids() {
        table3D?.stepTheAimingAids()
        scene?.refresh(force: true)
    }

    /// The sound, on or off: the sound item in the View menu shows which.
    @objc private func toggleSound() {
        scene?.audio?.isMuted.toggle()
    }

    /// The window full screen, and back: the same switch `F` reaches in the scene.
    @objc private func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    private func useEyeLevel(_ preset: PlayerCamera.Preset) {
        scene?.setViewMode(.firstPerson)
        table3D?.use(preset)
        scene?.refresh(force: true)
    }
}

// The computer player, played headless: two computers play whole frames with no window open, which is
// how the player is measured before there is anything to watch. `--ai-play [frames]` plays frames and
// logs them; `--ai-benchmark [shots]` reports what one decision costs. `--easy` and `--hard` set the
// strength, and `--quiet` leaves only the tally.
if let index = CommandLine.arguments.firstIndex(of: "--ai-play") {
    let count = CommandLine.arguments.count > index + 1
        ? Int(CommandLine.arguments[index + 1]) ?? 1 : 1
    exit(ComputerOpponent.playFrames(count, options: ComputerOpponent.Options(CommandLine.arguments)))
}

if let index = CommandLine.arguments.firstIndex(of: "--ai-benchmark") {
    let count = CommandLine.arguments.count > index + 1
        ? Int(CommandLine.arguments[index + 1]) ?? 200 : 200
    exit(ComputerOpponent.benchmark(shots: count))
}

if CommandLine.arguments.contains("--ai-probe") {
    exit(ComputerOpponent.probe())
}

if CommandLine.arguments.contains("--ai-roll") {
    exit(ComputerOpponent.roll())
}

// Positions, and what they are for: `--ai-export` writes what a player scored from each of a set of
// random positions, for a network to be trained on; `--ai-measure` says what the player did with them,
// which is the benchmark any change to the player is measured against.
if let index = CommandLine.arguments.firstIndex(of: "--ai-export-policy") {
    guard CommandLine.arguments.count > index + 1,
          !CommandLine.arguments[index + 1].hasPrefix("--") else {
        print("--ai-export-policy needs a path to write to")
        exit(2)
    }
    exit(ComputerOpponent.exportPolicy(path: CommandLine.arguments[index + 1],
                                       options: ComputerOpponent.Options(CommandLine.arguments)))
}

// The policy playing itself, with the Hard player labelling the positions it visits: the states are the
// network's own, the targets are the strong player's. `--ai-selfplay <path> --policy <model>`.
if let index = CommandLine.arguments.firstIndex(of: "--ai-selfplay") {
    guard CommandLine.arguments.count > index + 1,
          !CommandLine.arguments[index + 1].hasPrefix("--") else {
        print("--ai-selfplay needs a path to write to")
        exit(2)
    }
    exit(ComputerOpponent.selfPlay(path: CommandLine.arguments[index + 1],
                                   options: ComputerOpponent.Options(CommandLine.arguments)))
}

if let index = CommandLine.arguments.firstIndex(of: "--ai-export") {
    guard CommandLine.arguments.count > index + 1,
          !CommandLine.arguments[index + 1].hasPrefix("--") else {
        print("--ai-export needs a path to write to")
        exit(2)
    }
    exit(ComputerOpponent.export(path: CommandLine.arguments[index + 1],
                                 options: ComputerOpponent.Options(CommandLine.arguments)))
}

if CommandLine.arguments.contains("--ai-measure") {
    exit(ComputerOpponent.measure(options: ComputerOpponent.Options(CommandLine.arguments)))
}

if CommandLine.arguments.contains("--ai-escape-check") {
    exit(ComputerOpponent.escapeCheck(options: ComputerOpponent.Options(CommandLine.arguments)))
}

// What the aim error does to the computer's *choices*, as opposed to its misses.
if CommandLine.arguments.contains("--ai-choices") {
    exit(ComputerOpponent.choices(options: ComputerOpponent.Options(CommandLine.arguments)))
}

// What a cushion does to a ball that arrives at an angle: what the routes are aimed from.
if CommandLine.arguments.contains("--ai-cushion") {
    exit(ComputerOpponent.cushion(options: ComputerOpponent.Options(CommandLine.arguments)))
}

// The computer at the table in the window's own scene, with no window: the one piece of the player that
// the core's tests cannot reach.
if CommandLine.arguments.contains("--computer-check") {
    exit(ComputerOpponent.computerCheck(options: ComputerOpponent.Options(CommandLine.arguments)))
}

if CommandLine.arguments.contains("--ui-check") {
    exit(ComputerOpponent.uiCheck(options: ComputerOpponent.Options(CommandLine.arguments)))
}

// Where a model's operations would run, without playing anything: the Neural Engine, the GPU or the CPU.
if CommandLine.arguments.contains("--ai-compare") {
    exit(ComputerOpponent.compare(options: ComputerOpponent.Options(CommandLine.arguments)))
}

// Where a model's operations would run, without playing anything: the Neural Engine, the GPU or the CPU.
if let index = CommandLine.arguments.firstIndex(of: "--ai-model-plan") {
    guard CommandLine.arguments.count > index + 1 else {
        print("--ai-model-plan needs a model to look at")
        exit(2)
    }
    _ = LearnedValue.load(path: CommandLine.arguments[index + 1])
    exit(0)
}

// Snapshot mode renders the 3D table offscreen instead of opening a window, so the view can be
// checked without a display. Used while developing the 3D view; harmless otherwise.
if let index = CommandLine.arguments.firstIndex(of: "--snapshots") {
    let directory = CommandLine.arguments.count > index + 1
        ? URL(fileURLWithPath: CommandLine.arguments[index + 1])
        : URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("snooker-snapshots")
    exit(Snapshots.run(into: directory))
}

if let index = CommandLine.arguments.firstIndex(of: "--inspect") {
    guard CommandLine.arguments.count > index + 1 else { exit(2) }
    exit(Snapshots.inspect(CommandLine.arguments[index + 1]))
}

// Sound check builds every synthesised sound, reports it, and starts the engine: the whole of the
// audio path, checked where there is nothing to listen to. A directory may be given to write each
// sound out as a WAV.
if let index = CommandLine.arguments.firstIndex(of: "--sound-check") {
    let directory = CommandLine.arguments.count > index + 1
        ? URL(fileURLWithPath: CommandLine.arguments[index + 1])
        : nil
    exit(GameAudio.soundCheck(into: directory) ? 0 : 1)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.setActivationPolicy(.regular)
application.run()
