import AppKit
import SpriteKit
import SnookerCore
import QuartzCore

/// Renders the table and HUD, and turns mouse/keyboard input into game actions.
final class TableScene: SKScene {

    /// Which view the player is looking at the table through.
    enum ViewMode {
        /// The whole table from above, with the HUD around it.
        case topDown
        /// The player's own view: the 3D table fills the window and this scene becomes a
        /// transparent HUD with a small plan of the table in the corner.
        case firstPerson
    }

    /// One plate of the score board: a coloured panel with a word or a number on it, and — on the two
    /// name plates — the black triangle that says whose turn it is. A plate is placed by moving its
    /// panel; its label and its marker are laid out inside it.
    private final class ScorePlate {
        /// What a plate holds, which is what sets how wide it is: a name is given room that follows the
        /// name, while a score is fixed wide enough for three digits and the frames for two, so the
        /// board does not shuffle about as the numbers go up.
        enum Kind {
            case name
            case score
            case frames
        }

        let panel = SKShapeNode()
        let label = SKLabelNode()
        let marker = SKShapeNode()
        var kind: Kind = .score
    }

    let controller = FrameDriver()

    // MARK: - The computer opponent

    /// The computers, by the seat each is playing: empty is a game between two people, which is what the
    /// game has always been. The menu fills one of the two seats; both can be filled, and then the game
    /// plays itself.
    private var computers: [Int: ComputerPlayer] = [:]
    /// Whether a decision is being worked out right now.
    private var isThinking = false
    /// The position a decision has already been asked about, so that the same one is not asked about
    /// again and again — which is what a computer that answers "nothing to do" would otherwise cause.
    private var askedAbout: String?
    /// The answer, when it comes back from the thinking queue.
    private var answer: ComputerPlayer.Action?
    /// A shot that has been lined up and is waiting its moment: the cue is seen to settle on the ball
    /// before the stroke is played, rather than the balls simply going.
    private var shotOwed: Shot?
    private var shotOwedAt: TimeInterval = 0
    /// Deciding means playing shots out — tens of them, on copies of the frame — so it is done off the
    /// main thread and the picture keeps being drawn while the computer thinks.
    private static let thinking = DispatchQueue(label: "snooker.the.computer", qos: .userInitiated)
    /// How long the cue stands on the ball before the stroke is played.
    private static let theTurnOfTheCue: TimeInterval = 0.55

    /// Whether the computer is the one to play now.
    var theComputerIsAtTheTable: Bool {
        computerAtTheTable != nil
    }

    /// The computer whose turn it is, if any.
    private var computerAtTheTable: ComputerPlayer? {
        guard !controller.isFrameOver else { return nil }
        return computers[controller.game.state.currentPlayer]
    }

    var computerOpponentIsOn: Bool { !computers.isEmpty }
    /// Whether a computer at the table is running on a learned network rather than the search.
    var computerIsDeepLearned: Bool {
        computers.values.contains { $0.decideEverything != nil || $0.policy != nil || $0.shotPolicy != nil }
    }
    /// Whether the computer is playing that seat.
    func isPlayingTheComputer(_ seat: Int) -> Bool { computers[seat] != nil }
    var computerDifficulty: ComputerPlayer.Difficulty {
        computers[1]?.difficulty ?? computers.values.first?.difficulty ?? .medium
    }

    /// Who plays the two seats of a new game. It is the answer to the question Escape asks, and the one
    /// choice the game needs from a player who is starting again.
    enum GameMode: String, CaseIterable, Sendable {
        case humanVersusHuman = "Human vs Human"
        case humanVersusComputer = "Human vs Computer"
        case computerVersusComputer = "Computer vs Computer"

        var asksForADifficulty: Bool { self != .humanVersusHuman }
        var isAllComputer: Bool { self == .computerVersusComputer }
    }

    /// The mode whose difficulty is being chosen now, if the player is part-way through answering the
    /// new-game question: picking a mode with a computer in it asks one more thing.
    private var modeAwaitingADifficulty: GameMode?
    /// True while a game between two computers is **paused**: the question is up and neither of them plays.
    private(set) var theGameIsPaused = false

    /// The ESC menu's **Deep Learned** switch. It only has a meaning in the Exact mode: there it chooses
    /// between the exact *search* player and the exact *network* player. In the other difficulties it is
    /// shown and toggled, and ignored — there is no trained network for them yet.
    private(set) var deepLearnedIsOn = false

    func toggleDeepLearning() {
        deepLearnedIsOn.toggle()
        requestRefresh()
    }

    /// Starts a new match with the players the player asked for: two people, a person and the computer, or
    /// the computer against itself. The seat the computer takes in a human game is drawn at random, so
    /// that a game against it is a game against it and not always the same seat.
    func startNewGame(mode: GameMode, difficulty: ComputerPlayer.Difficulty = .medium) {
        let deepLearned = deepLearnedIsOn && difficulty == .exact
        for seat in 0...1 { setComputerOpponent(false, playing: seat) }
        switch mode {
        case .humanVersusHuman:
            break
        case .humanVersusComputer:
            setComputerOpponent(true, difficulty: difficulty, playing: Bool.random() ? 0 : 1,
                                deepLearned: deepLearned)
        case .computerVersusComputer:
            for seat in 0...1 {
                setComputerOpponent(true, difficulty: difficulty, playing: seat,
                                    deepLearned: deepLearned)
            }
        }
        theGameIsPaused = false
        modeAwaitingADifficulty = nil
        controller.keepPlaying()
        controller.startTheNewGame()
        wake()
        requestRefresh()
    }

    /// What **Escape** does. It asks about a new game and puts the question away again — except in a game
    /// between two computers, where there is nobody at the table to ask and the question is a **pause**:
    /// the picture stops where it is until the player says to carry on.
    func escapePressed() {
        if controller.isAskingAboutANewGame {
            keepPlaying()
            return
        }
        // Whatever is in hand goes down first: a cue drawn back or a charge building is not something to
        // leave half-played under a question.
        controller.cancelCueAction()
        isHoldingCueKey = false
        modeAwaitingADifficulty = nil
        theGameIsPaused = computers.count == 2
        controller.askToStartANewGame()
        requestRefresh()
    }

    /// Puts the new-game question away and lets the game carry on.
    func keepPlaying() {
        controller.keepPlaying()
        modeAwaitingADifficulty = nil
        theGameIsPaused = false
        wake()
        requestRefresh()
    }

    /// Turns the computer opponent on or off. Playing, it takes the second player's seat — the game's own
    /// "Dr. Ker" — and the first player is the person at the keyboard.
    func setComputerOpponent(_ on: Bool, difficulty: ComputerPlayer.Difficulty = .medium,
                             playing player: Int = 1,
                             aimError: Double? = nil,
                             deepLearned: Bool = false) {
        if on {
            let computer = ComputerPlayer(playerIndex: player, difficulty: difficulty)
            // A cue action that never misses is not a player anyone would recognise: it is left slightly
            // fallible, and the search it runs takes that into account before it chooses. How fallible is
            // the difficulty's own business unless the caller has said otherwise.
            computer.aimError = aimError ?? difficulty.aimError
            if deepLearned, difficulty == .exact {
                let decider = LearnedPolicy.loadEverything(
                    path: Models.url("Decider2.mlmodelc").path, describe: false)
                let shot = LearnedPolicy.loadCandidate(
                    path: Models.url("Candidate2.mlmodelc").path, describe: false)
                if let decider, let shot {
                    computer.decideEverything = decider
                    computer.shotPolicy = shot
                } else {
                    print("the learned models did not load: the exact player stays the search")
                }
            }
            computers[player] = computer
        } else {
            computers[player] = nil
        }
        isThinking = false
        askedAbout = nil
        answer = nil
        shotOwed = nil
        wake()
        requestRefresh()
    }

    func setComputerDifficulty(_ difficulty: ComputerPlayer.Difficulty) {
        for computer in computers.values { computer.difficulty = difficulty }
    }

    /// What the frame is, in a line: enough of it that a decision already asked about can be told from a
    /// decision worth asking about again. The balls only move while a stroke is running or a cue ball is
    /// being placed, and both of those show up here.
    private var thePositionInShort: String {
        let state = controller.game.state
        return "\(state.currentPlayer)|\(controller.mode)|\(state.pending != nil)|\(state.cueBallInHand)"
            + "|\(state.ballOn)|\(state.redsRemaining)|\(state.scores[0])-\(state.scores[1])"
    }

    /// The 3D table, when the app has one. `nil` in a headless test harness.
    var table3D: Table3D?
    /// The game's sound, when the app has any. `nil` in a headless test harness, which makes it silent:
    /// the contacts are still drained each frame, they are simply not played.
    var audio: GameAudio?
    private(set) var viewMode: ViewMode = .firstPerson
    /// Called when the player switches between the two views, so the app can show or hide
    /// the 3D view behind this one.
    var onViewModeChange: ((ViewMode) -> Void)?

    /// What the window is being asked to draw, and how often.
    ///
    /// Drawing is the whole of the game's cost when the table is not moving, so the game **asks** for
    /// frames rather than taking them: 120 a second while anything is *being played* — down on the shot,
    /// the cue being drawn, the balls running or falling, the player walking — 60 standing at the table
    /// looking about, and one a second once neither the player nor the table has moved for a moment,
    /// which leaves the picture on the screen, and notices anything that changed of its own accord, for
    /// near enough to nothing. `wantedFrameRate` is the whole of that decision. The app applies it to the
    /// two views; the scene already owns its own `SKView`'s rate through `view`.
    enum FrameRate: Int {
        case idle = 1
        case standing = 60
        case playing = 120
    }
    var onFrameRateChange: ((FrameRate) -> Void)?
    /// The rate now being asked for.
    private(set) var frameRate: FrameRate = .playing
    /// When the player last did something: the idle clock. See `wantedFrameRate`.
    private var lastActivity: TimeInterval = 0
    /// Whether a redraw is owed to something the player has done. See `requestRefresh`.
    private var wantsRefresh = false

    /// How long the table has to be still, with nothing done to it, before the game stops asking for
    /// frames. Long enough that the camera's own easing has finished — it settles in about half a
    /// second — and that a held arrow key's first repeat has arrived.
    private static let theTableStandsStillFor: TimeInterval = 1.0

    /// How many decision buttons are on screen. The snapshot harness uses this to check that the
    /// buttons for a foul go away once the choice has been made.
    /// The referee's call as it stands on the screen, for the offscreen probe.
    var refereeCallOnScreen: String { callLabel.isHidden ? "" : (callLabel.text ?? "") }

    /// What the score board reads, for the offscreen probe: the frame number and the six plates left
    /// to right. The harness has no eyes for the picture, so this is how it checks that the board is
    /// built and filled in as it should be.
    var scoreBoardOnScreen: (frame: String, plates: [String]) {
        (frameNumberLabel.text ?? "", scorePlates.map { $0.label.text ?? "" })
    }

    /// Which name plate is showing the black turn marker, for the offscreen probe: the index of the
    /// plate it is drawn on, or nil when none is. A shape with no path draws nothing, so this reads the
    /// path as well as the flag that would hide it.
    var scoreBoardMarkerOnScreen: Int? {
        scorePlates.firstIndex { !$0.marker.isHidden && !($0.marker.path?.isEmpty ?? true) }
    }

    /// Where each plate of the score board is drawn, for the offscreen probe: two plates over one
    /// another, or a row that runs off the side of the window, is not something a reading of the words
    /// on it would catch.
    var scoreBoardPlateFrames: [CGRect] {
        scorePlates.map { plate in
            let bounds = plate.panel.path?.boundingBox ?? .zero
            return bounds.offsetBy(dx: plate.panel.position.x, dy: plate.panel.position.y)
        }
    }

    /// The status line as it stands on the screen, for the offscreen probe: the question the player is
    /// being asked is most of what it says.
    var statusOnScreen: String { statusLabel.text ?? "" }

    /// The caption under "Points remaining" as it stands on the screen, for the offscreen probe: empty
    /// unless the player at the table needs snookers.
    var snookersRequiredOnScreen: String { snookersLabel.isHidden ? "" : (snookersLabel.text ?? "") }

    /// Whether the help panel is up, what it lists, where it sits on the screen, and how wide the longest
    /// line of it is — for the offscreen probe, which has no eyes for the panel itself. The two widths
    /// together are the check that the words are not running out of the panel they are drawn on.
    var helpPanelOnScreen: (isShown: Bool, lines: [String], frame: CGRect, widestLine: CGFloat) {
        let panel = helpLayer.children.first
        let rect = (panel?.frame ?? .zero)
            .offsetBy(dx: helpLayer.position.x, dy: helpLayer.position.y)
        let widest = panel?.children.compactMap { $0 as? SKLabelNode }
            .map(\.frame.width).max() ?? 0
        return (isShowingHelp, TableScene.helpList.map(\.text), rect, widest)
    }

    /// The two labels of the screen's top line, and where they sit, for the offscreen probe: the help
    /// hint at the left of it and the view the player is looking through at the right.
    var topLineOnScreen: (helpHint: String, hintAt: CGPoint, helpFrame: CGRect,
                          view: String, viewAt: CGPoint, viewFrame: CGRect) {
        (hintLabel.text ?? "", hintLabel.position, hintLabel.frame,
         viewLabel.text ?? "", viewLabel.position, viewLabel.frame)
    }

    /// Hands the mouse's movement through the same reading the app uses, for the offscreen probe: real
    /// mouse events need a window to belong to, so the probe gives the deltas and the places over directly.
    @discardableResult
    func readMouseMovement(delta: CGPoint, changedBy change: CGPoint?) -> CGPoint {
        readMovement(delta: delta, changedBy: change)
    }

    /// The way round each axis of the mouse is being read, and whether each has been learned yet, for the
    /// offscreen probe: a reversal is this reading having been learned wrongly, so it is what a probe has to
    /// look at.
    var mouseAxisReading: (x: CGFloat, y: CGFloat, xIsLearned: Bool, yIsLearned: Bool) {
        (mouseXTurns, mouseYTurns, mouseXIsLearned, mouseYIsLearned)
    }

    /// Whether the pointer's places are worth comparing with the mouse's own movement just now — false for
    /// a moment after the window has changed size — for the offscreen probe.
    var thePointerPlacesAreBelieved: Bool { !theSizeIsSettling }

    /// What the cue-ball widget is made of: how many pieces it is drawn from, and whether the dashed
    /// hairlines that cross at the middle of the ball are among them. The snapshot harness uses this to
    /// check that the widget is put together as it should be — a shape node with an empty path draws
    /// nothing and says nothing about it.
    var spinWidgetParts: (pieces: Int, hasTheMiddleLines: Bool) {
        (spinNode.children.count,
         spinNode.children.contains { $0.name == "the middle of the ball" })
    }

    var buttonNodesOnScreen: Int {
        buttonLayer.children.filter { $0 is SKShapeNode }.count
    }

    // Layers
    private let tableLayer = SKNode()
    private let ballLayer = SKNode()
    private let hudLayer = SKNode()
    private let overlayLayer = SKNode()
    /// The decision buttons live here on their own, so that building a new set can clear the last
    /// one rather than leaving it on screen.
    private let buttonLayer = SKNode()
    /// The help panel, on top of everything else: H opens and closes it, and the game plays on behind it.
    private let helpLayer = SKNode()
    /// Whether the help panel is on the screen.
    private var isShowingHelp = false

    private var ballNodes: [Int: SKShapeNode] = [:]
    /// The line of aim and the ghost ball: built once, and then only moved. See `updateAiming`.
    private var aimLine = SKShapeNode()
    private var ghostBall = SKShapeNode()
    /// The strength meter: a fixed bar, scaled by the power. See `updatePower`.
    private var powerFill = SKShapeNode()
    private var powerTrack = SKShapeNode()
    private var spinNode = SKNode()
    private var spinDot = SKShapeNode()
    private var spinLimit = SKShapeNode()
    private var spinGrip = SKShapeNode()
    private var spinCaption = SKLabelNode()
    private var cueCaption = SKLabelNode()
    /// The spin-limit outline as it was last built, and the angle of the cue it belongs to. The outline
    /// depends on that angle and nothing else, and it is the dearest thing drawn. See `updateSpinDot`.
    private var spinOutline: (elevation: Double, path: CGPath)?
    /// How many times the outline has been worked out, for the offscreen probe: it is the dearest thing
    /// the HUD draws, and it belongs to the angle rather than to the frame. See `updateSpinDot`.
    private(set) var spinOutlineBuilds = 0
    /// The angle the cue's caption was last written for, in degrees, so that a label is not rebuilt on
    /// every frame. See `updateSpinDot`.
    private var captionedElevation: Double?

    /// The six plates of the score board, left to right: the first player's name, their score, the
    /// frames each of the two has won, the second player's score, and the second player's name. See
    /// `buildScoreBoard`.
    private var scorePlates: [ScorePlate] = []
    /// The frame number, above the board: which frame of the match is being played.
    private var frameNumberLabel = SKLabelNode()
    /// The black rule round the score board and the black lines between its plates, drawn as one shape
    /// over the plates. See `boardRulesPath`.
    private let scoreBoardRules = SKShapeNode()
    private var breakLabel = SKLabelNode()
    private var ballOnLabel = SKLabelNode()
    private var remainingLabel = SKLabelNode()
    /// The caption that goes under "Points remaining": "Snookers required", shown only when it is true of
    /// the player at the table.
    private var snookersLabel = SKLabelNode()
    private var statusLabel = SKLabelNode()
    private var viewLabel = SKLabelNode()
    private var hintLabel = SKLabelNode()
    private var commentaryLabels: [SKLabelNode] = []
    /// What the referee has just called: the touching ball, when there is one (Rule 8(a)).
    private var callLabel = SKLabelNode()
    private var overlayTitle = SKLabelNode()
    private var overlayDetail = SKLabelNode()

    private struct Button {
        let rect: CGRect          // in scene coordinates
        let action: () -> Void
    }
    private var buttons: [Button] = []
    /// The colours the striker may play at while they are on a colour of their own choice.
    private var colourChoices: [BallColor] = []

    /// The colour a number key stands for, by the value Section 1 Rule 1(a) gives it.
    private static func colour(forNumberKey key: String?) -> BallColor? {
        switch key {
        case "2": return .yellow
        case "3": return .green
        case "4": return .brown
        case "5": return .blue
        case "6": return .pink
        case "7": return .black
        default: return nil
        }
    }

    // Layout
    private var unit: CGFloat = 0.1          // scene points per millimetre
    private var tableOrigin: CGPoint = .zero
    private let railMM: CGFloat = 78
    /// How much of the top of the window the HUD keeps for itself: the score board and its frame
    /// number, and the four lines under it — the last of which, "Snookers required", is only there when
    /// it applies, but the room is kept for it either way so that the table never has to move. The table
    /// is drawn below this.
    private let hudTop: CGFloat = 152
    private let hudBottom: CGFloat = 118
    private let margin: CGFloat = 18

    private var lastUpdateTime: TimeInterval = 0
    private var lastSignature: String = ""
    private var isDraggingSpin = false
    /// Where the pointer was on the last mouse event, so the view is steered by movement rather
    /// than by where the pointer has got to.
    private var lastPointer: CGPoint?
    private var isReady = false
    /// Held-key controls: E moves the tip on the cue ball, S draws the cue back and pushes it
    /// through. Aiming only listens to the mouse while neither is down.
    private var isHoldingSpinKey = false
    private var isHoldingCueKey = false
    /// Hold **B** and the mouse raises and lowers the cue instead of sighting the shot: the cue lifted
    /// at an angle strikes down at the ball, and with side spin set the cloth curves it into a swerve.
    private var isHoldingElevationKey = false
    /// The arrow keys being held while the player is up and about with the cue put away, so that the
    /// walk is read in the frame loop rather than stepped by the keyboard's own repeat.
    private var heldWalkKeys: Set<UInt16> = []
    /// Held while the mouse is the player's **legs** rather than their head: **Z**. With it down the
    /// mouse's movement is a walk — forward and back along the way they are looking, and across it — and
    /// the look is left exactly where it was, so the player walks the way they are facing.
    private var isHoldingWalkKey = false
    /// How far the mouse's own travel walks the player, in millimetres a point. A sweep of the mouse
    /// across the window is a few strides of the table, and a nudge is a step: the walk follows the hand
    /// rather than the clock, so there is no speed to it and nothing to tune but this.
    private static let walkMillimetresPerPoint: Double = 4
    /// How many key events the scene has passed on to the responder chain, which is what the system
    /// answers with a beep. Read back by the harness: a key the game defines — the letters it acts on,
    /// the arrows, the digits — must never be one of them, held down or tapped.
    private(set) var keysPassedOn = 0

    /// True when the arrows walk the player and the mouse looks about: first-person, standing up with
    /// the cue put away. That is so over a shot, while deciding what to do next — and **while the balls
    /// run**, once the player has stood up from the shot and put the cue away: a player who has done
    /// that is free to walk about the table and watch the balls from wherever they like. Down on the
    /// shot, or with the cue laid on the table, the arrows sight the shot instead.
    private var canWalkAbout: Bool {
        viewMode == .firstPerson
            && controller.cueHandling == .putAway
            && !controller.isDownOnTheShot
            && (controller.mode == .aiming || controller.mode == .charging
                || controller.mode == .decision || controller.mode == .simulating)
    }

    /// Whether the player is up and about rather than at the table. It is true with the cue put away, and
    /// it is true **while the computer is at the table**: nobody who is watching a shot is standing at it.
    private var thePlayerMayWalkAbout: Bool {
        guard viewMode == .firstPerson else { return false }
        if theComputerIsAtTheTable { return true }
        return canWalkAbout
    }

    /// Which way the **watcher's own head** is turned, while the computer is at the table: the aim belongs
    /// to the computer's cue and looking about is not the same thing as steering it. It is taken up from
    /// the aim the moment the computer's turn begins, so that the view does not jump.
    private(set) var watchingYaw: Double = 0
    /// How far the mouse has moved the cue so far this frame, waiting for the frame loop to apply it.
    /// The cue is moved once a frame rather than once an event so that its speed — which is the
    /// shot's strength — is measured over a known time rather than over the gaps between mouse
    /// events, which the system is free to coalesce.
    private var pendingCueTravel: Double = 0

    private let clothColor = SKColor(red: 0.06, green: 0.42, blue: 0.19, alpha: 1)
    /// The rail, in the plan view's own flat colours: the same **wood-like brown** the table is framed
    /// in, so the plan and the table are one table seen two ways.
    private let railColor = SKColor(red: 0.28, green: 0.16, blue: 0.08, alpha: 1)
    private let pocketColor = SKColor(red: 0.03, green: 0.03, blue: 0.04, alpha: 1)
    private let panelColor = SKColor(red: 0.10, green: 0.11, blue: 0.13, alpha: 1)

    // MARK: - Scene lifecycle

    override func didMove(to view: SKView) {
        applyBackground()
        addChild(tableLayer)
        addChild(ballLayer)
        addChild(hudLayer)
        addChild(buttonLayer)
        addChild(overlayLayer)
        addChild(helpLayer)
        buildStaticTable()
        buildHUD()
        isReady = true
        layout()
        refresh(force: true)
        // A moment of frames at the start, so the first thing drawn is drawn smoothly.
        lastActivity = CACurrentMediaTime()
        setFrameRate(.standing)
        // A captured mouse must be given back the moment the game stops being the frontmost thing, and
        // the moment it goes away altogether: see `giveTheMouseBack`.
        for notification in [NSApplication.didResignActiveNotification,
                             NSWindow.didResignKeyNotification] {
            NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) {
                [weak self] _ in self?.giveTheMouseBack()
            }
        }
    }

    override func willMove(from view: SKView) {
        super.willMove(from: view)
        giveTheMouseBack()
    }

    deinit {
        // The pointer is the whole machine's, not the game's: whatever else happens, it is reconnected
        // and shown on the way out.
        CGAssociateMouseAndMouseCursorPosition(1)      // _CGCursorIsVisible-ish: `boolean_t`, 1 is on
        NSCursor.unhide()
    }

    override func didChangeSize(_ oldSize: CGSize) {
        super.didChangeSize(oldSize)
        // The pointer's last place was read in the scene of the old size, and the same point on the screen
        // is a different place in the scene of this one: throw it away, and hold off believing the pointer's
        // places until the size has settled. A full-screen switch resizes the window over several frames,
        // and nothing about the pointer can be read across that.
        lastPointer = nil
        theSizeIsSettlingUntil = CACurrentMediaTime() + TableScene.theSizeTakesToSettle
        layout()
    }

    // MARK: - Coordinate helpers

    private func point(_ p: Vec2) -> CGPoint {
        CGPoint(x: tableOrigin.x + CGFloat(p.x) * unit, y: tableOrigin.y + CGFloat(p.y) * unit)
    }

    private func tablePoint(_ p: CGPoint) -> Vec2 {
        Vec2(Double((p.x - tableOrigin.x) / unit), Double((p.y - tableOrigin.y) / unit))
    }

    private func layout() {
        guard isReady else { return }
        layoutTable()
        layoutHUD()
        refresh(force: true)
    }

    /// The plan of the table, drawn full size in the top-down view and as a small map in the
    /// corner of the first-person view.
    private var minimapRect: CGRect {
        let aspect = (CGFloat(Table.length) + railMM * 2) / (CGFloat(Table.width) + railMM * 2)
        let width = min(max(size.width * 0.30, 220), 380)
        let height = width / aspect
        // The plan drops clear of the score board, which reaches down the top of the window further
        // than the frame number's own line used to.
        return CGRect(x: size.width - width - margin, y: size.height - height - 64,
                      width: width, height: height)
    }

    private func layoutTable() {
        let area: CGRect
        switch viewMode {
        case .topDown:
            area = CGRect(x: margin, y: hudBottom,
                          width: size.width - margin * 2,
                          height: size.height - hudTop - hudBottom)
        case .firstPerson:
            area = minimapRect
        }
        let tableWidthMM = CGFloat(Table.length) + railMM * 2
        let tableHeightMM = CGFloat(Table.width) + railMM * 2
        unit = min(area.width / tableWidthMM, area.height / tableHeightMM)
        let drawnWidth = tableWidthMM * unit
        let drawnHeight = tableHeightMM * unit
        tableOrigin = CGPoint(x: area.midX - drawnWidth / 2 + railMM * unit,
                              y: area.midY - drawnHeight / 2 + railMM * unit)
        rebuildTableGeometry()
    }

    /// Switches view, moving the table between the full area and the corner map.
    func setViewMode(_ mode: ViewMode, notify: Bool = true) {
        guard viewMode != mode else { return }
        viewMode = mode
        applyBackground()
        lastSignature = ""
        layout()
        if notify { onViewModeChange?(mode) }
    }

    /// The first-person view is a transparent HUD over the 3D scene; the top-down view is the
    /// whole picture and paints its own background.
    private func applyBackground() {
        backgroundColor = viewMode == .firstPerson
            ? .clear
            : SKColor(red: 0.07, green: 0.07, blue: 0.09, alpha: 1)
    }

    func toggleViewMode() {
        setViewMode(viewMode == .topDown ? .firstPerson : .topDown)
    }

    // MARK: - Table drawing

    private func buildStaticTable() {
        tableLayer.removeAllChildren()
    }

    private func rebuildTableGeometry() {
        tableLayer.removeAllChildren()

        // In the first-person view the plan of the table sits over the 3D scene, so it needs a
        // panel behind it to stay readable.
        if viewMode == .firstPerson {
            let panel = SKShapeNode(rect: minimapRect.insetBy(dx: -10, dy: -10), cornerRadius: 12)
            panel.fillColor = SKColor(white: 0.03, alpha: 0.66)
            panel.strokeColor = SKColor(white: 0.55, alpha: 0.30)
            panel.lineWidth = 1
            panel.zPosition = -1
            tableLayer.addChild(panel)
        }

        let clothRect = CGRect(x: point(.zero).x, y: point(.zero).y,
                               width: CGFloat(Table.length) * unit,
                               height: CGFloat(Table.width) * unit)

        // Wooden rails behind the cloth.
        let rails = SKShapeNode(rect: clothRect.insetBy(dx: -railMM * unit, dy: -railMM * unit),
                                cornerRadius: 10 * unit)
        rails.fillColor = railColor
        rails.strokeColor = SKColor(red: 0.16, green: 0.09, blue: 0.04, alpha: 1)
        rails.lineWidth = 2
        tableLayer.addChild(rails)

        // Cloth.
        let cloth = SKShapeNode(rect: clothRect)
        cloth.fillColor = clothColor
        cloth.strokeColor = .clear
        tableLayer.addChild(cloth)

        // Pockets: the hole each one is cut with. The cloth runs on into the throat around it, so
        // the hole is what the plan shows.
        for pocket in PocketID.allCases {
            let cut = pocket.cut
            let node = SKShapeNode(circleOfRadius: CGFloat(cut.holeRadius) * unit)
            node.position = point(cut.holeCentre)
            node.fillColor = pocketColor
            node.strokeColor = SKColor(white: 0.15, alpha: 1)
            node.lineWidth = 1
            tableLayer.addChild(node)
        }

        // Baulk line and the "D".
        let baulkPath = CGMutablePath()
        baulkPath.move(to: point(Vec2(Table.baulkLineX, 0)))
        baulkPath.addLine(to: point(Vec2(Table.baulkLineX, Table.width)))
        let baulkLine = SKShapeNode(path: baulkPath)
        baulkLine.strokeColor = SKColor(white: 0.95, alpha: 0.75)
        baulkLine.lineWidth = 1.5
        tableLayer.addChild(baulkLine)

        let dPath = CGMutablePath()
        dPath.addArc(center: point(Table.brownSpot),
                     radius: CGFloat(Table.dRadius) * unit,
                     startAngle: .pi / 2, endAngle: 3 * .pi / 2, clockwise: false)
        let dNode = SKShapeNode(path: dPath)
        dNode.strokeColor = SKColor(white: 0.95, alpha: 0.75)
        dNode.lineWidth = 1.5
        tableLayer.addChild(dNode)

        // Spots.
        for (_, spot) in Table.allSpots {
            let dot = SKShapeNode(circleOfRadius: max(1.2, CGFloat(Table.ballRadius) * unit * 0.18))
            dot.position = point(spot)
            dot.fillColor = SKColor(white: 0.95, alpha: 0.85)
            dot.strokeColor = .clear
            tableLayer.addChild(dot)
        }
    }

    // MARK: - HUD

    private func buildHUD() {
        hudLayer.removeAllChildren()
        buildScoreBoard()

        for label in [breakLabel, ballOnLabel, remainingLabel] {
            label.fontSize = 14
            label.horizontalAlignmentMode = .left
            label.verticalAlignmentMode = .center
            label.fontColor = SKColor(white: 0.85, alpha: 1)
            hudLayer.addChild(label)
        }
        // And the one line that only appears when it is true: the striker is behind by more than the table
        // still holds, and only fouls will bring them back. It is set in the referee's own amber, since it
        // is the same sort of statement — something the player needs to be told about the frame.
        snookersLabel.text = "Snookers required"
        snookersLabel.fontName = "Helvetica Neue Bold"
        snookersLabel.fontSize = 14
        snookersLabel.horizontalAlignmentMode = .left
        snookersLabel.verticalAlignmentMode = .center
        snookersLabel.fontColor = SKColor(calibratedRed: 1.0, green: 0.85, blue: 0.25, alpha: 1)
        hudLayer.addChild(snookersLabel)

        statusLabel.fontSize = 16
        statusLabel.horizontalAlignmentMode = .left
        statusLabel.verticalAlignmentMode = .center
        statusLabel.fontColor = .white
        hudLayer.addChild(statusLabel)

        viewLabel.fontSize = 13
        viewLabel.fontName = "Helvetica Neue Medium"
        viewLabel.horizontalAlignmentMode = .right
        viewLabel.verticalAlignmentMode = .center
        viewLabel.fontColor = SKColor(white: 0.92, alpha: 1)
        hudLayer.addChild(viewLabel)

        // The one hint that stays on the screen, at the top left of it: the whole of the controls is a
        // page behind H rather than a line at the top for the eye to keep going back to.
        hintLabel.fontSize = 12
        hintLabel.fontName = "Helvetica Neue Medium"
        hintLabel.text = "Press H for help"
        hintLabel.horizontalAlignmentMode = .left
        hintLabel.verticalAlignmentMode = .center
        hintLabel.fontColor = SKColor(white: 0.62, alpha: 1)
        hudLayer.addChild(hintLabel)

        // The referee's call, where a player will see it: above the status line, in its own colour,
        // rather than buried in the log with everything else.
        callLabel.fontName = "Helvetica Neue Medium"
        callLabel.fontSize = 15
        callLabel.horizontalAlignmentMode = .left
        callLabel.verticalAlignmentMode = .center
        callLabel.fontColor = SKColor(calibratedRed: 1.0, green: 0.85, blue: 0.25, alpha: 1)
        hudLayer.addChild(callLabel)

        commentaryLabels = []
        for _ in 0..<3 {
            let label = SKLabelNode(fontNamed: "Helvetica Neue")
            label.fontSize = 12
            label.horizontalAlignmentMode = .left
            label.verticalAlignmentMode = .center
            label.fontColor = SKColor(white: 0.7, alpha: 1)
            commentaryLabels.append(label)
            hudLayer.addChild(label)
        }

        // Power bar.
        powerTrack = SKShapeNode(rect: .zero, cornerRadius: 6)
        powerTrack.fillColor = SKColor(white: 0.18, alpha: 1)
        powerTrack.strokeColor = SKColor(white: 0.3, alpha: 1)
        hudLayer.addChild(powerTrack)
        powerFill = SKShapeNode(rect: .zero, cornerRadius: 6)
        // The bar is drawn at its **full** width and scaled down to the power, so that the frame it is
        // drawn in never changes: see `updatePower`.
        powerFill.path = TableScene.powerBarPath
        powerFill.strokeColor = .clear
        hudLayer.addChild(powerFill)

        // The line of aim and the ghost ball, on the layers the balls are on: built here, once, and
        // only moved from then on. See `updateAiming`.
        aimLine.strokeColor = SKColor(white: 1, alpha: 0.55)
        aimLine.lineWidth = 1.2
        aimLine.zPosition = 5
        aimLine.isHidden = true
        ballLayer.addChild(aimLine)
        ghostBall.strokeColor = SKColor(white: 1, alpha: 0.5)
        ghostBall.fillColor = SKColor(white: 1, alpha: 0.08)
        ghostBall.lineWidth = 1
        ghostBall.zPosition = 5
        ghostBall.isHidden = true
        ballLayer.addChild(ghostBall)

        // Spin widget.
        spinNode = SKNode()
        let ball = SKShapeNode(circleOfRadius: TableScene.spinWidgetRadius)
        ball.fillColor = SKColor(white: 0.93, alpha: 1)
        ball.strokeColor = SKColor(white: 1, alpha: 0.8)
        ball.lineWidth = 2
        spinNode.addChild(ball)
        // A **vertical and a horizontal hairline through the middle of the ball**, dashed so that they
        // are not mistaken for a limit and do not hide the ball they are drawn on: they are there to say
        // where the *middle* is, since that is where the tip's offset is read from and the very place a
        // spot of spin is easiest to lose.
        let cross = CGMutablePath()
        cross.move(to: CGPoint(x: -TableScene.spinWidgetRadius, y: 0))
        cross.addLine(to: CGPoint(x: TableScene.spinWidgetRadius, y: 0))
        cross.move(to: CGPoint(x: 0, y: -TableScene.spinWidgetRadius))
        cross.addLine(to: CGPoint(x: 0, y: TableScene.spinWidgetRadius))
        let middles = SKShapeNode(path: cross.copy(dashingWithPhase: 0, lengths: [4, 4]))
        middles.name = "the middle of the ball"
        middles.strokeColor = SKColor(white: 0.5, alpha: 0.7)
        middles.lineWidth = 1
        spinNode.addChild(middles)
        // Two thin solid lines, both of them only **shown** — the tip can be put anywhere on the ball.
        // The first is where a strike would leave the ball able to be caught by the cue and called a
        // second hit (`PhysicsWorld.spinRange`): a circle for a level cue, pulled in most of all on the
        // screw side as the cue stands up, closed to nothing near vertical, and opening a hole in the
        // middle where a heavy follow is allowed and a light one is not. The second is the leather's
        // own grip (`PhysicsWorld.cueTipOffsetLimit`), where the tip starts to slip and give no more
        // spin. The white ball is the cue ball at its own scale, so both are drawn where the tip's own
        // offset would put them, and the red dot is exactly where the tip is striking.
        spinLimit = SKShapeNode()
        spinLimit.fillColor = .clear
        spinLimit.strokeColor = SKColor(white: 0.45, alpha: 0.95)
        spinLimit.lineWidth = 1
        spinNode.addChild(spinLimit)
        spinGrip = SKShapeNode(circleOfRadius: CGFloat(PhysicsWorld.cueTipOffsetLimit) * TableScene.spinWidgetRadius)
        spinGrip.fillColor = .clear
        spinGrip.strokeColor = SKColor(white: 0.62, alpha: 0.8)
        spinGrip.lineWidth = 1
        spinNode.addChild(spinGrip)
        spinDot = SKShapeNode(circleOfRadius: 6)
        spinDot.fillColor = SKColor(red: 0.8, green: 0.1, blue: 0.1, alpha: 1)
        spinDot.strokeColor = .clear
        spinNode.addChild(spinDot)
        spinCaption = SKLabelNode(text: "spin")
        spinCaption.fontName = "Helvetica Neue"
        spinCaption.fontSize = 11
        spinCaption.fontColor = SKColor(white: 0.65, alpha: 1)
        spinCaption.position = CGPoint(x: 0, y: -(TableScene.spinWidgetRadius + 16))
        spinNode.addChild(spinCaption)
        // And how far the cue is lifted, which is the other half of a swerve and has no widget of its
        // own: the tip on the ball says where the spin is, this says how much of it the cloth will
        // curve with.
        cueCaption = SKLabelNode(text: String(format: "cue %.1f°", Table.cueStanceElevationDegrees))
        cueCaption.fontName = "Helvetica Neue"
        cueCaption.fontSize = 11
        cueCaption.fontColor = SKColor(white: 0.65, alpha: 1)
        cueCaption.position = CGPoint(x: 0, y: -(TableScene.spinWidgetRadius + 30))
        spinNode.addChild(cueCaption)
        hudLayer.addChild(spinNode)

        // Overlay for end of frame.
        overlayLayer.removeAllChildren()
        overlayTitle.fontSize = 30
        overlayTitle.fontName = "Helvetica Neue Bold"
        overlayTitle.fontColor = .white
        overlayTitle.verticalAlignmentMode = .center
        overlayTitle.horizontalAlignmentMode = .center
        overlayLayer.addChild(overlayTitle)
        overlayDetail.fontSize = 16
        overlayDetail.fontName = "Helvetica Neue"
        overlayDetail.fontColor = SKColor(white: 0.85, alpha: 1)
        overlayDetail.verticalAlignmentMode = .center
        overlayDetail.horizontalAlignmentMode = .center
        overlayLayer.addChild(overlayDetail)

        buildHelpPanel()
    }

    /// The controls, as the help panel lists them: a heading, and the keys under it. Kept here as data,
    /// so the whole of what the game can be told to do is in one place to read.
    private static let helpList: [(text: String, isHeading: Bool)] = [
        ("Playing the shot", true),
        ("Mouse — aim; while you play, the pointer belongs to the game", false),
        ("Hold the mouse button, or Space — charge the power bar, let go to play", false),
        ("S (hold) — cue action: back draws the cue, forward pushes it through", false),
        ("E (hold) — tip on the ball: across for side, up and down for follow or screw", false),
        ("B (hold) — cue elevation: up stands the cue up, down lays it level", false),
        ("Shift — with S or the arrows: a finer and slower aim", false),
        ("Arrows — fine aim; up and down tilt the eye", false),
        ("Click — place the cue ball in the \"D\"; P picks it up again", false),
        ("2 3 4 5 6 7 — the colour on, by its value; 0 — no free ball", false),

        ("Seeing the table", true),
        ("V — the player's view, or the whole table from above", false),
        ("2 3 — eye level: standing at the table, raised; ⌘1 — on the shot", false),
        ("G — aiming aids: off, the line of aim, and the ball it will send away", false),
        ("C — the cue away to walk about, or laid on the table", false),
        ("Z (hold) — the mouse walks you; X (hold) ducks your eye over the cloth", false),
        ("Control — tap for the pointer, tap again to give it back", false),
        ("F — full screen, and back again", false),

        ("The game", true),
        ("N — a new frame: the scores go and the match carries on (asks first)", false),
        ("R — re-rack the frame: every score in it goes (asks first)", false),
        ("Esc — a new game: human or computer, easy, medium or hard (asks first; pauses a computer game)", false),
        ("Shift-C — concede the frame", false),
        ("M — sound on or off", false),
        ("P O R U — after a foul: play on, offender plays, replace the balls, undo", false),
        ("H — open or close this panel", false),
    ]

    /// Builds the help panel: one plate in the middle of the window with `helpList` written down it. It
    /// is a static page, so it is built once — only its being shown or hidden changes.
    private func buildHelpPanel() {
        helpLayer.removeAllChildren()
        let lineHeight: CGFloat = 17
        let inset: CGFloat = 26
        let titleHeight: CGFloat = 40
        let lines = TableScene.helpList
        // Measure the longest line so the panel is only as wide as the words on it need.
        var widest: CGFloat = 0
        for line in lines {
            let ruler = SKLabelNode(fontNamed: line.isHeading ? "Helvetica Neue Bold" : "Helvetica Neue")
            ruler.fontSize = line.isHeading ? 12 : 11.5
            ruler.text = line.text
            widest = max(widest, ruler.frame.width)
        }
        let width = widest + inset * 2
        let height = titleHeight + CGFloat(lines.count) * lineHeight + inset
        let panel = SKShapeNode(rect: CGRect(x: -width / 2, y: -height / 2, width: width, height: height),
                                cornerRadius: 10)
        panel.fillColor = SKColor(white: 0.05, alpha: 0.94)
        panel.strokeColor = SKColor(white: 1, alpha: 0.35)
        panel.lineWidth = 1
        helpLayer.addChild(panel)

        let title = SKLabelNode(fontNamed: "Helvetica Neue Bold")
        title.text = "Controls"
        title.fontSize = 17
        title.fontColor = .white
        title.horizontalAlignmentMode = .center
        title.verticalAlignmentMode = .center
        title.position = CGPoint(x: 0, y: height / 2 - titleHeight / 2)
        panel.addChild(title)

        var y = height / 2 - titleHeight - lineHeight / 2
        for line in lines {
            let label = SKLabelNode(fontNamed: line.isHeading ? "Helvetica Neue Bold" : "Helvetica Neue")
            label.text = line.text
            label.fontSize = line.isHeading ? 12 : 11.5
            label.fontColor = line.isHeading
                ? SKColor(calibratedRed: 1, green: 0.85, blue: 0.25, alpha: 1)
                : SKColor(white: 0.9, alpha: 1)
            label.horizontalAlignmentMode = .left
            label.verticalAlignmentMode = .center
            label.position = CGPoint(x: -width / 2 + inset, y: y)
            panel.addChild(label)
            y -= lineHeight
        }
        helpLayer.isHidden = !isShowingHelp
    }

    /// The score board's plate colours, kept together so the three read as one scheme: a name is black
    /// on yellow, a score black on white, and the frames a player has won white on teal.
    private static let namePlateColour = SKColor(calibratedRed: 1.0, green: 0.84, blue: 0.0, alpha: 1)
    private static let scorePlateColour = SKColor(white: 0.97, alpha: 1)
    private static let framesPlateColour = SKColor(calibratedRed: 0.0, green: 0.51, blue: 0.51, alpha: 1)

    /// How much of the ends of the score board's own line is kept clear for the two labels that share it:
    /// "Press H for help" at the left and the view's name at the right, and the window's margin with them.
    /// See `layoutScoreBoard`.
    private static let roomForTheCornerLabels: CGFloat = 118

    /// Builds the score board: six plates, and above them the frame number. Left to right they are the
    /// first player's name, their score, the frames each of the two has won, then the second player's
    /// score and name — the two boards mirrored about the middle, so each player's column reads from the
    /// outside in. The plates lie edge to edge, one connected bar, and each of the two names sits
    /// against its own end of it. The frames are set in bold, the same size as the scores: they are the
    /// numbers a match is decided on.
    private func buildScoreBoard() {
        scorePlates = []
        // (what it holds, font, size, text colour, plate colour), one entry per plate, left to right.
        let plates: [(kind: ScorePlate.Kind, font: String, size: CGFloat, text: SKColor, plate: SKColor)] = [
            (.name, "Helvetica Neue Medium", 18, .black, TableScene.namePlateColour),    // first player's name
            (.score, "Helvetica Neue Medium", 18, .black, TableScene.scorePlateColour),  // first player's score
            (.frames, "Helvetica Neue Bold", 18, .white, TableScene.framesPlateColour),  // frames won, first
            (.frames, "Helvetica Neue Bold", 18, .white, TableScene.framesPlateColour),  // frames won, second
            (.score, "Helvetica Neue Medium", 18, .black, TableScene.scorePlateColour),  // second player's score
            (.name, "Helvetica Neue Medium", 18, .black, TableScene.namePlateColour),    // second player's name
        ]
        for (index, specification) in plates.enumerated() {
            let plate = ScorePlate()
            plate.kind = specification.kind
            plate.panel.fillColor = specification.plate
            plate.panel.strokeColor = .clear
            plate.panel.lineWidth = 0
            plate.label.fontName = specification.font
            plate.label.fontSize = specification.size
            plate.label.fontColor = specification.text
            plate.label.horizontalAlignmentMode = .center
            plate.label.verticalAlignmentMode = .center
            plate.panel.addChild(plate.label)
            // Only the two names carry the turn marker, so only they are given one to draw.
            if index == 0 || index == 5 {
                plate.marker.fillColor = .black
                plate.marker.strokeColor = .clear
                plate.marker.lineWidth = 0
                plate.panel.addChild(plate.marker)
            }
            hudLayer.addChild(plate.panel)
            scorePlates.append(plate)
        }
        // The black rule round the bar, and the black line at each join, drawn over the plates: without
        // them the six runs of colour are one board with six parts only by a hair's breadth.
        scoreBoardRules.fillColor = .clear
        scoreBoardRules.strokeColor = .black
        scoreBoardRules.lineWidth = 1
        hudLayer.addChild(scoreBoardRules)
        frameNumberLabel.fontName = "Helvetica Neue Medium"
        frameNumberLabel.fontSize = 13
        frameNumberLabel.fontColor = SKColor(white: 0.92, alpha: 1)
        frameNumberLabel.horizontalAlignmentMode = .center
        frameNumberLabel.verticalAlignmentMode = .center
        hudLayer.addChild(frameNumberLabel)
    }

    /// Fills the board in with the scores as they stand and lays it across the top of the screen. A name
    /// plate is measured from the name on it — twice the room of a number, and eight tenths of that —
    /// and its name is set against its own end of the bar, left or right; the score and frames plates
    /// are fixed widths, and the row is centred as a whole.
    private func layoutScoreBoard() {
        guard scorePlates.count == 6 else { return }
        let names = controller.playerNames
        let scores = controller.scores
        let frames = controller.framesWon
        func nameOf(_ index: Int) -> String { index < names.count ? names[index] : "Player" }
        func scoreOf(_ index: Int) -> String { "\(index < scores.count ? scores[index] : 0)" }
        func framesOf(_ index: Int) -> String { "\(index < frames.count ? frames[index] : 0)" }
        let words = [nameOf(0), scoreOf(0), framesOf(0), framesOf(1), scoreOf(1), nameOf(1)]

        // The plates are laid edge to edge: one bar, not six chips with daylight between them.
        let gap: CGFloat = 0
        let padding: CGFloat = 20
        let height: CGFloat = 34
        for (index, plate) in scorePlates.enumerated() { plate.label.text = words[index] }
        // Both name plates are given the room the **longer** of the two names needs — twice a number's
        // room, and eight tenths of that again — so the two ends of the board come out the same size
        // whatever the names are: neither name looks more cramped than the other, and the board either
        // side of the middle is symmetrical.
        var nameWidth: CGFloat = 0
        var scoreWidth: CGFloat = 0
        var framesWidth: CGFloat = 0
        for plate in scorePlates {
            let wanted: CGFloat
            switch plate.kind {
            case .name:
                wanted = max(48, plate.label.frame.width + padding * 2) * 2 * 0.8
                nameWidth = max(nameWidth, wanted)
            case .score:
                wanted = TableScene.widthHolding(digits: 3, in: plate.label, padding: padding)
                scoreWidth = max(scoreWidth, wanted)
            case .frames:
                wanted = TableScene.widthHolding(digits: 2, in: plate.label, padding: padding)
                framesWidth = max(framesWidth, wanted)
            }
        }
        // The row is centred, and the help hint and the view's own name sit at the two ends of the same
        // line: the board is kept clear of them, so that on a narrow window the name plates give way
        // rather than the words at the two ends running into each other.
        let widestThatFits = size.width - (margin + TableScene.roomForTheCornerLabels) * 2
        let numbersWidth = scoreWidth * 2 + framesWidth * 2
        nameWidth = min(nameWidth, max(120, (widestThatFits - numbersWidth) / 2))
        let widths: [CGFloat] = scorePlates.map { plate in
            switch plate.kind {
            case .name: return nameWidth
            case .score: return scoreWidth
            case .frames: return framesWidth
            }
        }
        let total = widths.reduce(0, +) + gap * CGFloat(scorePlates.count - 1)
        var x = (size.width - total) / 2
        let rowCentreY = size.height - 44
        for (index, plate) in scorePlates.enumerated() {
            let width = widths[index]
            // The first player's name reads from the left of the bar, the second player's from the
            // right; the numbers in between sit in the middle of their own plates.
            plate.label.horizontalAlignmentMode = index == 0 ? .left : (index == 5 ? .right : .center)
            plate.label.position = CGPoint(x: index == 0 ? -width / 2 + padding
                                                   : (index == 5 ? width / 2 - padding : 0),
                                           y: 0)
            plate.panel.path = TableScene.platePath(width: width, height: height,
                                                    roundingTheLeftEnd: index == 0,
                                                    roundingTheRightEnd: index == 5)
            plate.panel.position = CGPoint(x: x + width / 2, y: rowCentreY)
            // The player at the table is picked out by the black triangle on their own name plate, at
            // the far end of it from the name and pointing back at it. Its point carries the whole angle,
            // a right angle, so the triangle is as deep as it is wide at its base.
            if plate.kind == .name {
                let markerSize: CGFloat = 9
                // Sat close to the score plate, clear of the black line that marks the join.
                let base = (index == 0 ? width / 2 - 8 : -width / 2 + 8)
                let apex = index == 0 ? base - markerSize : base + markerSize
                let path = CGMutablePath()
                path.move(to: CGPoint(x: apex, y: 0))
                path.addLine(to: CGPoint(x: base, y: markerSize))
                path.addLine(to: CGPoint(x: base, y: -markerSize))
                path.closeSubpath()
                plate.marker.path = path
                plate.marker.isHidden = !((index == 0 && controller.currentPlayer == 0)
                                          || (index == 5 && controller.currentPlayer == 1))
            }
            x += width + gap
        }
        scoreBoardRules.path = TableScene.boardRulesPath(widths: widths, height: height)
        scoreBoardRules.position = CGPoint(x: size.width / 2, y: rowCentreY)
        frameNumberLabel.text = "Frame \(controller.frameNumber)"
        frameNumberLabel.position = CGPoint(x: size.width / 2, y: size.height - 15)
    }

    /// The black rules of the score board as one path, centred on the origin: the outline of the whole
    /// bar, rounded at its two ends exactly as the outer plates are cut, and a line across it wherever
    /// one plate meets the next.
    private static func boardRulesPath(widths: [CGFloat], height: CGFloat) -> CGPath {
        let total = widths.reduce(0, +)
        let path = CGMutablePath()
        path.addPath(platePath(width: total, height: height,
                               roundingTheLeftEnd: true, roundingTheRightEnd: true))
        var join = -total / 2
        for width in widths.dropLast() {
            join += width
            path.move(to: CGPoint(x: join, y: -height / 2))
            path.addLine(to: CGPoint(x: join, y: height / 2))
        }
        return path
    }

    /// How wide a plate has to be to hold `digits` digits in the font the label carries, with the
    /// plate's own padding either side. A spare label does the measuring — the score and frames plates
    /// are fixed widths, so a number that grows a digit does not move anything else on the board.
    private static func widthHolding(digits: Int, in label: SKLabelNode, padding: CGFloat) -> CGFloat {
        let ruler = SKLabelNode(fontNamed: label.fontName)
        ruler.fontSize = label.fontSize
        ruler.text = String(repeating: "8", count: digits)
        return ruler.frame.width + padding * 2
    }

    /// The path of one plate of the score board. The plates lie edge to edge, so only the two ends of
    /// the bar are rounded — the first player's name at one end and the second's at the other — and
    /// every join between plates is left square, which is what lets the six read as one connected bar.
    private static func platePath(width: CGFloat, height: CGFloat,
                                  roundingTheLeftEnd: Bool, roundingTheRightEnd: Bool) -> CGPath {
        let radius: CGFloat = 6
        let left = -width / 2, right = width / 2
        let bottom = -height / 2, top = height / 2
        let leftCorner = roundingTheLeftEnd ? radius : 0
        let rightCorner = roundingTheRightEnd ? radius : 0
        let path = CGMutablePath()
        path.move(to: CGPoint(x: left + leftCorner, y: bottom))
        path.addLine(to: CGPoint(x: right - rightCorner, y: bottom))
        if rightCorner > 0 {
            path.addQuadCurve(to: CGPoint(x: right, y: bottom + rightCorner),
                              control: CGPoint(x: right, y: bottom))
            path.addLine(to: CGPoint(x: right, y: top - rightCorner))
            path.addQuadCurve(to: CGPoint(x: right - rightCorner, y: top),
                              control: CGPoint(x: right, y: top))
        } else {
            path.addLine(to: CGPoint(x: right, y: top))
        }
        path.addLine(to: CGPoint(x: left + leftCorner, y: top))
        if leftCorner > 0 {
            path.addQuadCurve(to: CGPoint(x: left, y: top - leftCorner),
                              control: CGPoint(x: left, y: top))
            path.addLine(to: CGPoint(x: left, y: bottom + leftCorner))
            path.addQuadCurve(to: CGPoint(x: left + leftCorner, y: bottom),
                              control: CGPoint(x: left, y: bottom))
        } else {
            path.addLine(to: CGPoint(x: left, y: bottom))
        }
        path.closeSubpath()
        return path
    }

    private func layoutHUD() {
        let top = size.height - 34
        layoutScoreBoard()
        // The log lines sit under the score board, which now takes the top of the screen.
        breakLabel.position = CGPoint(x: margin, y: top - 46)
        ballOnLabel.position = CGPoint(x: margin, y: top - 66)
        remainingLabel.position = CGPoint(x: margin, y: top - 86)
        snookersLabel.position = CGPoint(x: margin, y: top - 106)
        statusLabel.position = CGPoint(x: margin, y: hudBottom - 30)
        callLabel.position = CGPoint(x: margin, y: hudBottom - 8)
        // The top line of the screen, clear of the score board's own ends: the help hint at the left of
        // it and the view the player is looking through at the right.
        hintLabel.position = CGPoint(x: margin, y: top)
        viewLabel.position = CGPoint(x: size.width - margin, y: top)
        helpLayer.position = CGPoint(x: size.width / 2, y: size.height / 2)
        for (index, label) in commentaryLabels.enumerated() {
            label.position = CGPoint(x: margin, y: hudBottom - 72 - CGFloat(index) * 15)
        }
        powerTrack.path = TableScene.powerBarPath
        // The ghost ball is a ball's own size on the cloth, so its circle belongs to the layout: it is
        // set here rather than per frame, and `updateAiming` only moves it.
        let ghostRadius = CGFloat(Table.ballRadius) * unit
        ghostBall.path = CGPath(ellipseIn: CGRect(x: -ghostRadius, y: -ghostRadius,
                                                 width: ghostRadius * 2, height: ghostRadius * 2),
                                transform: nil)
        // The strength meter sits **above** the captions and the game log, directly under the status
        // line: it is read at a glance while the cue is being drawn, and the log is read after the shot,
        // so the bar should not be laid over either of them.
        powerTrack.position = CGPoint(x: margin, y: hudBottom - 54)
        spinNode.position = CGPoint(x: size.width - TableScene.spinWidgetRadius - 36,
                                    y: TableScene.spinWidgetRadius + 54)
    }

    private func stateSignature() -> String {
        var parts: [String] = []
        parts.append(String(describing: controller.mode))
        parts.append(controller.scores.map(String.init).joined(separator: "-"))
        parts.append(controller.framesWon.map(String.init).joined(separator: "-"))
        parts.append(String(controller.frameNumber))
        parts.append(controller.currentPlayer.description)
        parts.append(controller.ballOnDescription)
        parts.append(controller.remainingPoints.description)
        parts.append(controller.theStrikerNeedsSnookers ? "snookers required" : "-")
        parts.append(controller.nominatedColour?.rawValue ?? "-")
        parts.append(controller.isFrameOver ? "over" : "live")
        parts.append(String(describing: controller.pending))
        parts.append(controller.isAskingAboutANewFrame ? "asked about a new frame" : "-")
        parts.append(controller.isAskingAboutAReRack ? "asked about a re-rack" : "-")
        parts.append(controller.isAskingAboutANewGame ? "asked about a new game" : "-")
        parts.append(theGameIsPaused ? "paused" : "-")
        parts.append(modeAwaitingADifficulty?.rawValue ?? "-")
        parts.append(computers.count == 2 ? "computer against computer" : "\(computers.count) computers")
        parts.append(isShowingHelp ? "help up" : "-")
        parts.append(controller.cueHandling.rawValue)
        parts.append(controller.status)
        parts.append(viewMode == .firstPerson ? "3D" : "2D")
        parts.append(table3D?.preset.rawValue ?? "")
        parts.append(table3D?.aimingAids.rawValue ?? "")
        parts.append(String(format: "%.1f", controller.cueElevation * 180 / .pi))
        parts.append(controller.refereeCall ?? "")
        return parts.joined(separator: "|")
    }

    // MARK: - Per-frame refresh

    // MARK: - The computer's turn

    /// The computer's cue is on the table while its stroke runs, and a ball coming back at the stick is a
    /// ball met with the player's own equipment — a foul (Rule 11(b)(vi)), and the one thing a player
    /// watching the balls does something about. The computer takes it up in time and lays it again for its
    /// next stroke.
    private func theComputerLooksAfterItsCue() {
        guard theComputerIsAtTheTable else { return }
        if controller.aBallIsHeadingForTheCue {
            controller.takeTheCueOffTheTable()
            requestRefresh()
            return
        }
        // Balls at rest, the frame alive, and the stick not on the table: it is laid again behind the ball,
        // ready for the next stroke — which cannot be played without it.
        if controller.cueHandling == .putAway, controller.mode != .simulating,
           !controller.ballsAreFalling, !controller.isFrameOver {
            controller.putTheCueBackOnTheTable()
            requestRefresh()
        }
    }

    /// Asks the computer what to do when it is its turn, and does it when the answer comes back.
    ///
    /// The deciding happens on another queue — it plays tens of shots out, and the picture has to keep
    /// being drawn while it does — but everything that touches the frame happens here, on the main thread,
    /// where the mouse and the keys are also answered.
    private func giveTheComputerItsTurn() {
        guard let computer = computerAtTheTable else { return }
        // Nothing is decided while the new-game question is up, or while a game between two computers is
        // paused: the question is a pause, and a computer that played on through it would not be one.
        guard !theGameIsPaused, !controller.isAskingAboutANewGame, !controller.isAskingAboutANewFrame,
              !controller.isAskingAboutAReRack else { return }

        // A shot that has been lined up is played when its moment comes.
        if let shot = shotOwed {
            guard CACurrentMediaTime() >= shotOwedAt else { return }
            shotOwed = nil
            // Struck the way the **player** strikes one — a charge, and the cue action it leaves behind —
            // so that what the computer plays is the stroke the search played out, and the tip's own
            // contact with the ball is what gives it its speed.
            controller.playCharged(shot, at: CACurrentMediaTime())
            wake()
            requestRefresh()
            return
        }

        // While a stroke is running there is nothing to decide, and when the frame is over there never
        // will be again.
        guard controller.mode != .simulating, !controller.ballsAreFalling,
              theComputerIsAtTheTable else { return }

        if let answer {
            self.answer = nil
            isThinking = false
            doIt(answer, as: computer)
            // A computer that has nothing to do in a position must not be asked about it again the moment
            // the answer lands: the position has not changed, so neither would the answer, and the frame
            // loop would ask a hundred times a second for ever.
            if case .wait = answer { askedAbout = thePositionInShort } else { askedAbout = nil }
            return
        }

        guard !isThinking, askedAbout != thePositionInShort else { return }
        isThinking = true
        askedAbout = thePositionInShort
        // The frame the decision is about, held on to: the search reads it and plays its shots out on
        // copies of it, and nothing moves while it does — the balls are at rest and it is the computer's
        // turn, so the mouse has nothing to steer and the keys nothing to play.
        let frame = controller
        TableScene.thinking.async { [weak self] in
            let action = computer.nextAction(for: frame)
            DispatchQueue.main.async {
                guard let self else { return }
                self.answer = action
                self.wake()
            }
        }
    }

    /// Carries out one of the computer's decisions on the frame it is looking at.
    private func doIt(_ action: ComputerPlayer.Action, as computer: ComputerPlayer) {
        guard !controller.isFrameOver,
              !theGameIsPaused, !controller.isAskingAboutANewGame,
              controller.game.state.currentPlayer == computer.playerIndex else { return }
        switch action {
        case .shoot(let shot):
            guard controller.canStrike else { return }
            // The cue is put on the line and the tip on the ball first, and the stroke follows a moment
            // later: a player is seen to get down and play, rather than the balls going by themselves.
            controller.aimAngle = shot.angle
            controller.setSpin(side: shot.side, vertical: shot.vertical)
            shotOwed = shot
            shotOwedAt = CACurrentMediaTime() + TableScene.theTurnOfTheCue
        case .wait:
            break
        case .reRack:
            // Section 3 Rule 17, and the answer to two players fouling at a position neither of them can
            // make anything of: the frame is racked again rather than played on for ever.
            controller.reRack()
        default:
            // Everything else — a colour, a free ball, where to put the cue ball, what to do after a foul
            // — is the game's own business and takes no time at all.
            _ = ComputerMatch.apply(action, to: controller)
        }
        wake()
        requestRefresh()
    }

    /// Something has changed what the screen shows — a key, a click, the mouse while a key is held.
    /// The redraw itself is done **once a frame**, in the frame loop, so a burst of events (a key
    /// repeating, the mouse being moved with a key down) costs one redraw rather than one each, and a
    /// redraw is never done twice in a frame.
    private func requestRefresh() { wantsRefresh = true }

    /// The player has done something: the idle clock goes back, the next frame is one frame long
    /// rather than the whole still spell, and frames are asked for again if none were.
    private func wake() {
        lastActivity = CACurrentMediaTime()
        guard frameRate == .idle else { return }
        // Coming back from a still spell: the frame that answers this event is one frame long, and not
        // the whole of the spell — which the walk, the charge and the camera's own easing all read.
        lastUpdateTime = 0
        setFrameRate(.standing)
        // And ask for the frame now, rather than at the end of the second the still spell was counting.
        view?.needsDisplay = true
    }

    /// Asks the window for frames at `rate`; see `FrameRate`.
    private func setFrameRate(_ rate: FrameRate) {
        guard frameRate != rate else { return }
        frameRate = rate
        view?.preferredFramesPerSecond = rate.rawValue
        onFrameRateChange?(rate)
    }

    /// The rate the picture is worth now. See `FrameRate`.
    private func wantedFrameRate() -> FrameRate {
        // The computer thinking, or its cue standing on the ball, is the picture being worth drawing: the
        // aim is moving and the stroke is coming.
        if isThinking || shotOwed != nil { return .standing }
        // The shot being played, or the table running: the frame rate that matters.
        if controller.isDownOnTheShot || controller.mode == .simulating || controller.ballsAreFalling
            || controller.isMovingTheCue || !heldWalkKeys.isEmpty || isHoldingWalkKey || isDraggingSpin {
            return .playing
        }
        guard CACurrentMediaTime() - lastActivity > TableScene.theTableStandsStillFor else {
            return .standing
        }
        // Nothing done and nothing moving: the camera and the cue are the only things that ease between
        // events, so the picture is still once they have stopped.
        return (table3D?.thePictureIsStill ?? true) ? .idle : .standing
    }

    func refresh(force: Bool = false) {
        let signature = stateSignature()
        let changed = force || signature != lastSignature
        if changed {
            lastSignature = signature
            buttons.removeAll()
            overlayLayer.children.forEach { $0.isHidden = true }
            helpLayer.isHidden = !isShowingHelp
            updateHUDText()
            buildDecisionButtons()
            if controller.isFrameOver {
                showFrameOver()
            }
        }
        updateBalls()
        updateAiming()
        updatePower()
        updateSpinDot()
    }

    private func updateHUDText() {
        layoutScoreBoard()
        breakLabel.text = "Break: \(controller.breakScore)"
        ballOnLabel.text = "Ball on: \(controller.ballOnDescription)"
        remainingLabel.text = "Points remaining: \(controller.remainingPoints)"
        snookersLabel.isHidden = !controller.theStrikerNeedsSnookers
        // The cue with no room behind the ball says so itself: there is nothing the player can do at
        // the table until they lift the butt, so it is added to the line they are reading.
        if controller.isAskingAboutANewGame {
            if let mode = modeAwaitingADifficulty {
                statusLabel.text = "\(mode.rawValue): how hard should the computer be?"
            } else if theGameIsPaused {
                statusLabel.text = "Paused. A new game begins from frame 1, with every score lost."
                    + " Carry on, or choose who plays."
            } else {
                statusLabel.text = "A new game? The frames won and every score will be lost."
                    + " Choose who plays, or press Esc to carry on."
            }
        } else if controller.isAskingAboutANewFrame {
            statusLabel.text = "Start a new frame? " + controller.whatANewFrameMeans
        } else if controller.isAskingAboutAReRack {
            statusLabel.text = "Re-rack the frame? Every score in it will be lost."
        } else {
            statusLabel.text = controller.status
        }
        callLabel.text = controller.refereeCall ?? ""
        callLabel.isHidden = controller.refereeCall == nil
        updateViewLabel()
        let log = controller.commentary.suffix(3).map { $0 }
        for (index, label) in commentaryLabels.enumerated() {
            label.text = index < log.count ? log[log.count - 1 - index] : ""
        }
    }

    private func updateViewLabel() {
        switch viewMode {
        case .firstPerson:
            let preset = table3D?.preset ?? .sighting
            viewLabel.text = "3D — \(preset.title)"
        case .topDown:
            viewLabel.text = "Top-down"
        }
    }

    private func showFrameOver() {
        overlayTitle.isHidden = false
        overlayDetail.isHidden = false
        if let winner = controller.winner {
            overlayTitle.text = "\(controller.playerNames[winner]) wins the frame"
        } else {
            overlayTitle.text = "Frame tied"
        }
        let scoreLine = "\(controller.scores[0]) - \(controller.scores[1])"
        if controller.isAskingAboutANewGame {
            overlayDetail.text = "\(scoreLine)      start a new game, from frame 1?"
        } else if controller.isAskingAboutANewFrame {
            overlayDetail.text = "\(scoreLine)      start a new frame?"
        } else {
            overlayDetail.text = "\(scoreLine)      press N for a new frame"
        }
        overlayTitle.position = CGPoint(x: size.width / 2, y: size.height / 2 + 16)
        overlayDetail.position = CGPoint(x: size.width / 2, y: size.height / 2 - 20)
    }

    private func updateBalls() {
        var live = Set<Int>()
        for ball in controller.balls where ball.onTable || ball.isFalling {
            live.insert(ball.id)
            let node: SKShapeNode
            if let existing = ballNodes[ball.id] {
                node = existing
            } else {
                node = makeBallNode(for: ball)
                ballNodes[ball.id] = node
                ballLayer.addChild(node)
            }
            node.isHidden = false
            node.position = point(ball.position)
            node.setScale(max(0.2, unit * CGFloat(Table.ballRadius)))
        }
        for (id, node) in ballNodes where !live.contains(id) {
            node.isHidden = true
        }
    }

    private func makeBallNode(for ball: Ball) -> SKShapeNode {
        let node = SKShapeNode(circleOfRadius: 1)   // unit circle, scaled per layout
        node.fillColor = colour(for: ball.color)
        node.strokeColor = .clear
        node.lineWidth = 0
        // A soft highlight gives the balls a little volume.
        let highlight = SKShapeNode(circleOfRadius: 0.34)
        highlight.fillColor = SKColor(white: 1, alpha: 0.28)
        highlight.strokeColor = .clear
        highlight.position = CGPoint(x: -0.28, y: 0.28)
        node.addChild(highlight)
        return node
    }

    private func colour(for color: BallColor) -> SKColor {
        switch color {
        case .red: return SKColor(red: 0.75, green: 0.09, blue: 0.10, alpha: 1)
        case .yellow: return SKColor(red: 0.93, green: 0.78, blue: 0.09, alpha: 1)
        case .green: return SKColor(red: 0.06, green: 0.45, blue: 0.16, alpha: 1)
        case .brown: return SKColor(red: 0.45, green: 0.26, blue: 0.09, alpha: 1)
        case .blue: return SKColor(red: 0.09, green: 0.25, blue: 0.75, alpha: 1)
        case .pink: return SKColor(red: 0.95, green: 0.45, blue: 0.62, alpha: 1)
        case .black: return SKColor(white: 0.08, alpha: 1)
        case .white: return SKColor(white: 0.96, alpha: 1)
        }
    }

    private func updateAiming() {
        // The two nodes are built once (see `buildHUD`) and only ever moved: a shape node made afresh
        // every frame is built, added to the scene and thrown away again sixty times a second, and what
        // actually changes from frame to frame is the line's path and the ghost's place.
        guard controller.mode == .aiming || controller.mode == .charging,
              let cue = controller.cueBall, cue.onTable else {
            aimLine.isHidden = true
            ghostBall.isHidden = true
            return
        }

        // Where the shot first meets something — asked for **once**, and the line and the ghost both
        // read from it. (It used to be asked for twice a frame, and the answer cannot have changed.)
        let contact = controller.predictedFirstContact()
        let direction = Vec2(cos(controller.aimAngle), sin(controller.aimAngle))
        let start = point(cue.position)
        let end = contact.map { point($0.point) } ?? point(cue.position + direction * 1500)
        let path = CGMutablePath()
        path.move(to: start)
        path.addLine(to: end)
        aimLine.path = path
        aimLine.isHidden = false

        if let contact {
            ghostBall.position = point(contact.point)
            ghostBall.isHidden = false
        } else {
            ghostBall.isHidden = true
        }
    }

    private func updatePower() {
        // The bar is the track's own shape, **scaled**: a path built afresh each frame is re-tessellated
        // and re-uploaded each frame, and the only thing that changes is how far along the bar is.
        powerFill.position = powerTrack.position
        powerFill.xScale = CGFloat(max(0.03, controller.power))
        let p = controller.power
        powerFill.fillColor = SKColor(red: 0.2 + 0.8 * CGFloat(p), green: 0.7 - 0.4 * CGFloat(p), blue: 0.25, alpha: 1)
    }

    private func updateSpinDot() {
        let radius = TableScene.spinWidgetRadius
        // The dot is exactly where the tip is: the white ball is the cue ball, and the tip's offset is
        // its true fraction of the ball's radius, not stretched to the widget's edge.
        spinDot.position = CGPoint(x: CGFloat(controller.spinSide) * radius,
                                   y: CGFloat(controller.spinVertical) * radius)
        // And the solid outline is the limit for the cue's own angle. It belongs to that angle and
        // nothing else, and it is the dearest thing on the screen to work out — the limit is found by
        // walking three hundred offsets, and the outline is three hundred of those — so it is worked
        // out when the angle changes and kept until it changes again, rather than every frame. The
        // widget is redrawn every frame, but the angle is not.
        if spinOutline?.elevation != controller.cueElevation {
            let path = TableScene.spinLimitPath(elevation: controller.cueElevation, radius: radius)
            spinOutline = (controller.cueElevation, path)
            spinOutlineBuilds += 1
            spinLimit.path = path
        }
        // The angle the cue stands at, and with it how much of a swerve the shot has in it. It is the
        // cue's *own* elevation — the bottom of the lift is the level the player's stance gives it —
        // so the widget reads that angle rather than calling it level at some number of its own.
        let degrees = controller.cueElevation * 180 / .pi
        // The caption is written when the angle has moved a tenth of a degree: setting a label's text
        // rebuilds the label, and this one changes as often as the outline does.
        if captionedElevation == nil || abs(captionedElevation! - degrees) > 0.05 {
            captionedElevation = degrees
            cueCaption.text = String(format: "cue %.1f°", degrees)
            cueCaption.fontColor = degrees < Table.cueStanceElevationDegrees + 0.5
                ? SKColor(white: 0.65, alpha: 1)
                : SKColor(red: 0.95, green: 0.75, blue: 0.4, alpha: 1)
        }
    }

    /// The outline the spin limit is drawn as, at the angle the cue stands at: the boundary of the
    /// offsets a strike can be played at, and — where the region has a **hole** in it, a band of offsets
    /// that cannot get the ball away from the tip — the inner edge of it too. See
    /// `PhysicsWorld.spinLimitOutline`.
    private static func spinLimitPath(elevation: Double, radius: CGFloat) -> CGPath {
        let outline = PhysicsWorld.spinLimitOutline(elevation: elevation)
        let path = CGMutablePath()
        var started = false
        for point in outline.outer {
            let corner = CGPoint(x: CGFloat(point.side) * radius,
                                 y: CGFloat(point.vertical) * radius)
            if started { path.addLine(to: corner) } else { path.move(to: corner); started = true }
        }
        path.closeSubpath()
        var inAHole = false
        for point in outline.inner {
            let corner = CGPoint(x: CGFloat(point.side) * radius,
                                 y: CGFloat(point.vertical) * radius)
            let hasHole = point.side != 0 || point.vertical != 0
            if hasHole {
                if inAHole { path.addLine(to: corner) } else { path.move(to: corner) }
            }
            inAHole = hasHole
        }
        return path
    }

    // MARK: - Decision buttons

    private func addButton(
        title: String,
        at position: CGPoint,
        width: CGFloat = 150,
        chosen: Bool = false,
        action: @escaping () -> Void
    ) {
        let rect = CGRect(x: position.x - width / 2, y: position.y - 16, width: width, height: 32)
        let node = SKShapeNode(rect: rect, cornerRadius: 6)
        node.fillColor = chosen
            ? SKColor(red: 0.20, green: 0.42, blue: 0.27, alpha: 1)
            : SKColor(red: 0.16, green: 0.30, blue: 0.45, alpha: 1)
        node.strokeColor = chosen ? SKColor(white: 0.95, alpha: 0.9) : SKColor(white: 0.6, alpha: 0.6)
        node.lineWidth = chosen ? 2 : 1
        let label = SKLabelNode(text: title)
        label.fontName = "Helvetica Neue Medium"
        label.fontSize = 13
        label.fontColor = .white
        label.verticalAlignmentMode = .center
        label.horizontalAlignmentMode = .center
        label.position = CGPoint(x: position.x, y: position.y)
        buttonLayer.addChild(node)
        buttonLayer.addChild(label)
        buttons.append(Button(rect: rect, action: action))
    }

    private func buildDecisionButtons() {
        // Clear whatever the last decision put up first, before the early return below: a decision
        // that has been answered has no pending choice, and the buttons for it have to go with it
        // rather than staying on screen for the next shot to be drawn over.
        buttonLayer.removeAllChildren()
        let y = hudBottom - 78
        // The new-game question puts two rows of buttons up, and the lower of them still has to be on the
        // screen: the HUD's own bottom is 118 points up, so the rows sit inside it.
        let firstRow = hudBottom - 52
        let secondRow = hudBottom - 88

        // Starting a new game is confirmed first: it takes the whole match back to the start — the frames
        // won and the frame in progress with them — and Esc is as easy to catch as any other key.
        if controller.isAskingAboutANewGame {
            // The modes **are** the answer to the question: who plays the two seats. A mode with a
            // computer in it asks one more thing — how hard — and then the game begins.
            if let mode = modeAwaitingADifficulty {
                let difficulties: [ComputerPlayer.Difficulty] = [.easy, .medium, .hard, .exact]
                for (index, difficulty) in difficulties.enumerated() {
                    let x = size.width / 2 + (Double(index) - 1.5) * 160
                    addButton(title: difficulty.rawValue.capitalized,
                              at: CGPoint(x: x, y: firstRow), width: 140) { [weak self] in
                        self?.startNewGame(mode: mode, difficulty: difficulty)
                    }
                }
                // The switch only has a meaning in Exact: there it chooses the network over the search.
                addButton(title: deepLearnedIsOn ? "Deep Learned: On" : "Deep Learned: Off",
                          at: CGPoint(x: size.width / 2 - 110, y: secondRow), width: 200,
                          chosen: deepLearnedIsOn) { [weak self] in
                    self?.toggleDeepLearning()
                }
                addButton(title: "Back", at: CGPoint(x: size.width / 2 + 120, y: secondRow), width: 110) { [weak self] in
                    guard let self else { return }
                    self.modeAwaitingADifficulty = nil
                    self.requestRefresh()
                }
                return
            }
            let spacing = 210.0
            for (index, mode) in GameMode.allCases.enumerated() {
                let x = size.width / 2 + (Double(index) - 1) * spacing
                addButton(title: mode.rawValue, at: CGPoint(x: x, y: firstRow), width: 200) { [weak self] in
                    guard let self else { return }
                    if mode.asksForADifficulty {
                        self.modeAwaitingADifficulty = mode
                        self.requestRefresh()
                    } else {
                        self.startNewGame(mode: mode)
                    }
                }
            }
            addButton(title: theGameIsPaused ? "Carry on" : "Keep playing",
                      at: CGPoint(x: size.width / 2, y: secondRow), width: 170) { [weak self] in
                self?.keepPlaying()
            }
            return
        }

        // Starting a new frame is confirmed the same way: the frame in progress is thrown away by it and N is
        // close to the other keys. Two buttons, and the frame does not move until one is taken — and
        // this comes **before** the frame-over return below, because the frame being over is exactly
        // when a new one is most likely to be asked for.
        if controller.isAskingAboutANewFrame {
            addButton(title: "Start a new frame", at: CGPoint(x: size.width / 2 - 110, y: y), width: 200) { [weak self] in
                guard let self else { return }
                self.controller.startTheNewFrame()
                self.requestRefresh()
            }
            addButton(title: "Keep playing", at: CGPoint(x: size.width / 2 + 110, y: y), width: 170) { [weak self] in
                guard let self else { return }
                self.controller.keepPlaying()
                self.requestRefresh()
            }
            return
        }

        // A re-rack is confirmed the same way, and for the same reason: every score in the frame goes
        // with it (Section 3 Rule 17).
        if controller.isAskingAboutAReRack {
            addButton(title: "Re-rack the frame", at: CGPoint(x: size.width / 2 - 110, y: y), width: 200) { [weak self] in
                guard let self else { return }
                self.controller.reRackTheFrame()
                self.requestRefresh()
            }
            addButton(title: "Keep playing", at: CGPoint(x: size.width / 2 + 110, y: y), width: 170) { [weak self] in
                guard let self else { return }
                self.controller.keepPlaying()
                self.requestRefresh()
            }
            return
        }

        guard !controller.isFrameOver else { return }

        guard let pending = controller.pending else {
            // Nothing to decide: the striker is playing a colour of their choice, and the colours
            // stay on offer until they play the stroke, so they can change their mind (Rule 13
            // lets the striker change which ball on they will attempt).
            if controller.isPlayingForAColour, controller.mode == .aiming || controller.mode == .charging {
                // Read off the table rather than remembered from the question: the aim can answer the
                // question before the scene has ever seen it asked, and the colours have to stay on offer
                // either way.
                showColours(controller.coloursOnTheTable, at: y)
            }
            // Only the Black left and the striker more than seven ahead: the frame is theirs to
            // claim (Section 2 Rule 1(b)), but they are not made to. The button is here for them to
            // take it or, playing on, to pot the Black and end the frame that way (Rule 4(a)).
            if controller.canClaimTheFrame {
                addButton(title: "Claim the frame", at: CGPoint(x: size.width / 2, y: y), width: 190) { [weak self] in
                    guard let self else { return }
                    self.controller.claimTheFrame()
                    self.requestRefresh()
                }
            }
            return
        }
        switch pending {
        case .nominateColour(let options):
            colourChoices = options.isEmpty ? BallColor.coloursInAscendingOrder : options
            showColours(colourChoices, at: y)
        case .nominateFreeBall(let options):
            let colours = options.isEmpty ? BallColor.coloursInAscendingOrder : options
            let x = showColours(colours, at: y, choosingFreeBall: true)
            addButton(title: "No free ball", at: CGPoint(x: x + 40, y: y), width: 130) { [weak self] in
                self?.controller.declineFreeBall()
            }
        case .afterFoul(let decision):
            // After a foul the balls stay where they lie, so there are two things the non-offender
            // can do (Rules 10(f) and 10(h)). A foul committed before the stroke is one of the few
            // cases where they can be put back instead (Rule 10(i)), and then there are three.
            decisionRow(y: y, original: decision.canRequestOriginalPosition)
        case .afterMiss(let decision):
            // Rule 14(b): after a Foul and a Miss the non-offender can play from the position left,
            // ask the offender to play again from there, or have the balls replaced and the
            // offender play again from the original position.
            decisionRow(y: y, original: decision.canRequestOriginalPosition)
        case .placeCueBallInD, .placeCueBallAnywhere:
            break
        }
    }

    /// The colours the striker may play at, laid out in a row with the one they have chosen picked
    /// out. Returns the x just past the row, so a caller can put something after it.
    @discardableResult
    private func showColours(_ colours: [BallColor], at y: CGFloat, choosingFreeBall: Bool = false) -> CGFloat {
        let width: CGFloat = 92
        let gap: CGFloat = 8
        let total = CGFloat(colours.count) * width + CGFloat(max(0, colours.count - 1)) * gap
        var x = size.width / 2 - total / 2 + width / 2
        for colour in colours {
            let chosen = !choosingFreeBall && controller.nominatedColour == colour
            addButton(title: colour.rawValue.capitalized, at: CGPoint(x: x, y: y),
                      width: width, chosen: chosen) { [weak self] in
                guard let self else { return }
                if choosingFreeBall {
                    self.controller.chooseFreeBall(colour)
                } else {
                    self.controller.chooseColour(colour)
                }
            }
            x += width + gap
        }
        return x
    }

    /// The choices open to the non-offender after a foul, laid out in a row and spaced so that none
    /// of them touches another.
    private func decisionRow(y: CGFloat, original: Bool) {
        var choices: [(title: String, width: CGFloat, action: () -> Void)] = [
            ("Play from here", 160, { [weak self] in self?.controller.playFromPositionLeft() }),
            ("Offender plays from here", 220, { [weak self] in self?.controller.askOffenderToPlayAgain() }),
        ]
        if original {
            choices.append(("Replace balls, offender plays", 250, { [weak self] in
                self?.controller.requestOriginalPosition()
            }))
        }
        let gap: CGFloat = 24
        let total = choices.reduce(0) { $0 + $1.width } + gap * CGFloat(choices.count - 1)
        var x = size.width / 2 - total / 2
        for choice in choices {
            addButton(title: choice.title, at: CGPoint(x: x + choice.width / 2, y: y),
                      width: choice.width, action: choice.action)
            x += choice.width + gap
        }
    }

    // MARK: - Input

    override func mouseMoved(with event: NSEvent) {
        wake()
        let location = event.location(in: self)
        steer(at: location, moved: mouseMovement(of: event, to: location), flags: event.modifierFlags)
    }

    override func mouseDragged(with event: NSEvent) {
        wake()
        let location = event.location(in: self)
        if isDraggingSpin {
            updateSpin(from: location)
        } else {
            steer(at: location, moved: mouseMovement(of: event, to: location), flags: event.modifierFlags)
        }
    }

    /// The mouse's **own movement** in an event, in the scene's own sense — across, and up the screen.
    ///
    /// The event's **deltas** are what the mouse itself did since the last event. They come from the
    /// device, not from the place the pointer was seen at, and that is the whole point of reading them:
    /// the mouse is captured while the game has it — the pointer is uncoupled from it and hidden (see
    /// `keepTheMouseAsTheGames`) — so the pointer is no longer the thing to read. What the pointer does
    /// is none of the aim's business: whatever becomes of the *pointer*, the mouse's own movement is
    /// still the mouse's.
    ///
    /// The **direction** of each axis is learned once, from the first change in the place the pointer was
    /// seen at that can be believed. It is learned rather than assumed because the mouse's deltas and the
    /// pointer's places come from different parts of the system, and there is no reason to take the risk of
    /// an axis arriving the other way round; and it is learned **once** because the answer is a property of
    /// the device, so every later chance to "learn" it again is really just a chance to get it wrong.
    ///
    /// A change in the pointer's place cannot be believed in two cases. One is the event right after the
    /// game has put the pointer somewhere itself, or while the window is settling into a new size, when the
    /// same point on the screen is a different place in the scene. The other is a place that has moved
    /// further than the mouse did: the pointer only ever goes where the mouse sends it, so a place that has
    /// jumped further than the mouse's own movement was moved by something else.
    private func mouseMovement(of event: NSEvent, to location: CGPoint) -> CGPoint {
        let change = (ignoreTheNextMovement || theSizeIsSettling) ? nil : lastPointer.map {
            CGPoint(x: location.x - $0.x, y: location.y - $0.y)
        }
        ignoreTheNextMovement = false
        return readMovement(delta: CGPoint(x: event.deltaX, y: event.deltaY), changedBy: change)
    }

    /// The mouse's own movement in the game's sense, from the mouse's delta and — while an axis is still
    /// unlearned — the change in the pointer's place to compare it with.
    ///
    /// The comparison is kept to the two that can be read plainly: both have moved a point or more, and the
    /// place has **not** moved further than the mouse's own delta says it should have. Mouse acceleration
    /// lets the pointer outrun the raw delta, so the allowance is generous — three times, and a few points
    /// over for the very smallest movements — and a place that has outrun it by more than that is not a
    /// place the mouse sent anywhere.
    private func readMovement(delta: CGPoint, changedBy change: CGPoint?) -> CGPoint {
        func whichWay(_ delta: CGFloat, as change: CGFloat?,
                      sign: inout CGFloat, isLearned: inout Bool) -> CGFloat {
            if !isLearned, let change,
               abs(delta) > 1, abs(change) > 1, abs(change) <= abs(delta) * 3 + 3 {
                sign = (delta < 0) == (change < 0) ? 1 : -1
                isLearned = true
            }
            return delta * sign
        }
        return CGPoint(x: whichWay(delta.x, as: change?.x, sign: &mouseXTurns, isLearned: &mouseXIsLearned),
                       y: whichWay(delta.y, as: change?.y, sign: &mouseYTurns, isLearned: &mouseYIsLearned))
    }

    /// Turns mouse movement into the game's pointing: a table position in the top-down view, and
    /// the player's own line of sight — where they are standing and how they are looking — in the
    /// first-person view.
    ///
    /// The first-person view follows the mouse's *movement*, not where the pointer is, so the
    /// number of turns the player can make is not limited by the size of the window: when the
    /// pointer nears an edge it is put back in the middle, and carrying on from there is the same
    /// as any other movement.
    ///
    /// **The mouse steers only while the pointer is hidden.** With the pointer shown it is a pointer, and
    /// it steers nothing at all — the player is free to take it wherever the screen wants it, and the view
    /// stays exactly where they left it.
    ///
    /// `moved` is the mouse's own movement for this event, from `movement(of:)`. A caller that has no
    /// such thing to hand — the offscreen probe, which drives this with places rather than events —
    /// passes nothing, and the movement is read from the places instead.
    func steer(at location: CGPoint, moved: CGPoint? = nil, flags: NSEvent.ModifierFlags) {
        if viewMode == .firstPerson, !theMouseIsTheGames {
            lastPointer = location
            return
        }
        // Somebody else at the table: the mouse is the player's **own head** and not the cue's. They can
        // walk about it (hold Z), look where they like and duck down over the cloth (X), and none of it
        // touches the shot the computer is playing — the cue stays where the computer has left it.
        if theComputerIsAtTheTable {
            let previous = lastPointer ?? location
            let travelled = moved ?? CGPoint(x: location.x - previous.x, y: location.y - previous.y)
            lastPointer = location
            guard viewMode == .firstPerson, travelled != .zero else { return }
            if isHoldingWalkKey, !isHoldingCueKey, !isHoldingSpinKey {
                controller.walk(byForward: Double(travelled.y) * Self.walkMillimetresPerPoint,
                                sideways: Double(travelled.x) * Self.walkMillimetresPerPoint,
                                along: watchingYaw)
            } else {
                let perPoint = (flags.contains(.shift) ? 0.015 : 0.15) * Double.pi / 180
                watchingYaw -= Double(travelled.x) * perPoint
                table3D?.setPitch((table3D?.pitch ?? 0) + Double(travelled.y) * perPoint)
            }
            requestRefresh()
            return
        }
        // While a key is down the mouse belongs to it — to the tip on the ball, or to the cue — so
        // the aim is left exactly where it was.
        if viewMode == .firstPerson, takeCueControls(at: location, moved: moved, flags: flags) { return }

        guard viewMode == .firstPerson, let table3D else {
            lastPointer = location
            controller.movePointer(to: tablePoint(location))
            return
        }
        // Only steer while the player is at the table: over a shot, or working out what to do next.
        // Looking round is exactly what you want when you are choosing a colour or deciding what to
        // do after a foul, so those count — and so does watching the balls run **with the cue put
        // away**, since a player who has stood up and put it away is free to walk about. Placing the
        // cue ball does not: the eye stays where it is.
        let atTheTable = controller.mode == .aiming || controller.mode == .charging
            || controller.mode == .decision || (controller.mode == .simulating && canWalkAbout)
        guard atTheTable else {
            lastPointer = location
            return
        }
        let previous = lastPointer ?? location
        lastPointer = location

        let travelled = moved ?? CGPoint(x: location.x - previous.x, y: location.y - previous.y)
        // **Z** held puts the mouse on the player's legs instead of their head: the movement walks them —
        // forward and back along the way they are facing, and across it — and the look is left exactly
        // where it was, which is what walking with your eyes open is. The walk follows the hand: as far as
        // the mouse has moved is as far as the player goes, and it stops when the hand does.
        if thePlayerMayWalkAbout, isHoldingWalkKey {
            if travelled != .zero {
                controller.walk(byForward: Double(travelled.y) * Self.walkMillimetresPerPoint,
                                sideways: Double(travelled.x) * Self.walkMillimetresPerPoint)
                requestRefresh()
            }
            return
        }
        if travelled != .zero {
            // Degrees of turn per point of travel: about two window widths to a full circle, and a
            // tenth of that with Shift down, for sighting a fine cut.
            let perPoint = (flags.contains(.shift) ? 0.015 : 0.15) * Double.pi / 180
            // Moving the mouse right turns the player to their right, which is towards the lower y.
            // The turn goes through the driver's own steering so that the cue is settled at the ball
            // again as the aim comes round: see `FrameDriver.turnTheAim`.
            controller.turnTheAim(by: -Double(travelled.x) * perPoint)
            // Raising and lowering the gaze: up the screen looks further up the table.
            table3D.setPitch(table3D.pitch + Double(travelled.y) * perPoint)
        }
    }

    /// The held-key controls, in the player's own view: **E** puts the mouse on the cue ball's face,
    /// so moving it chooses where the tip strikes — across for side, up and down for follow and
    /// screw back — **S** puts it on the cue, so moving it back draws the cue and moving it forward
    /// pushes the cue through the ball, and **B** puts it on the cue's *angle*, so moving it up and
    /// down lifts and lowers the butt. All are movement controls, like the aim, so the range is not
    /// limited by the size of the window.
    ///
    /// Returns true when the movement belonged to one of them, so that the caller leaves the aim
    /// alone. The S key wins if both are held, because it is the one with visible state to finish.
    private func takeCueControls(at location: CGPoint, moved: CGPoint? = nil,
                                 flags: NSEvent.ModifierFlags) -> Bool {
        // With the balls running the player still has the cue: the mouse is the stick's, not the
        // aim's, and S held down is what keeps it so.
        let playingOn = controller.mode == .simulating
        let atTheTable = controller.mode == .aiming || controller.mode == .charging
            || controller.mode == .decision || playingOn
        guard atTheTable else { return false }
        // What the mouse is doing, in order of who wants it while the player is down on the shot:
        // Shift gives it back to the aim, at the aim's fine setting; E gives it to the tip on the ball;
        // and S on its own uses it for the cue. So a player can get down with S, sight the shot with
        // Shift, set the spin with E, and draw the cue with the mouse alone.
        let aimingFinely = isHoldingCueKey && flags.contains(.shift)
        // The cue is only the mouse's when there *is* one: with it put away, S does nothing and the
        // mouse is the player's look, so they can walk about with the balls running.
        let drawingTheCue = isHoldingCueKey
            && (controller.isMovingTheCue || (playingOn && controller.cueHandling == .laid))
            && !aimingFinely && !isHoldingSpinKey
        let placingTheTip = isHoldingSpinKey && !drawingTheCue
        let liftingTheCue = isHoldingElevationKey
        guard drawingTheCue || placingTheTip || liftingTheCue else { return false }

        let previous = lastPointer ?? location
        lastPointer = location
        let travelled = moved ?? CGPoint(x: location.x - previous.x, y: location.y - previous.y)
        // Shift slows either control down for a fine adjustment, the way it does for the aim.
        let fine: CGFloat = flags.contains(.shift) ? 0.25 : 1

        if liftingTheCue {
            // Up the screen raises the butt: the cue is stood up over the ball, to strike down at it.
            controller.adjustElevation(by: Double(travelled.y) * TableScene.elevationPerPoint * Double(fine))
        } else if drawingTheCue {
            // Up the screen is towards the ball: the cue goes forward as the mouse does. The travel
            // is put into the frame loop rather than applied here, because the shot's strength is
            // the speed the cue is moving at, and that needs a time to divide the travel by.
            pendingCueTravel += Double(travelled.y) * TableScene.cueMillimetresPerPoint * Double(fine)
        } else {
            // Across moves the tip to the striker's own right, up towards the top of the ball.
            controller.adjustSpin(side: Double(travelled.x) * TableScene.spinPerPoint * Double(fine),
                                  vertical: Double(travelled.y) * TableScene.spinPerPoint * Double(fine))
            requestRefresh()
        }
        return true
    }

    /// Walks the player about the table while they are up and about with the cue put away: the up and
    /// down arrows go forward and back along the way they are looking, the left and right arrows across
    /// it. Held keys, read here over the frame's own time, so the walk is smooth.
    private func applyWalking(dt: Double) {
        guard thePlayerMayWalkAbout, !heldWalkKeys.isEmpty else { return }
        let forward = (heldWalkKeys.contains(126) ? 1.0 : 0) - (heldWalkKeys.contains(125) ? 1.0 : 0)
        let sideways = (heldWalkKeys.contains(124) ? 1.0 : 0) - (heldWalkKeys.contains(123) ? 1.0 : 0)
        guard forward != 0 || sideways != 0 else { return }
        if controller.isWatching {
            // The watcher walks along the way **they** are looking, which is not the way the cue points.
            controller.walk(byForward: forward * PlayerWalk.pace * dt,
                            sideways: sideways * PlayerWalk.pace * dt,
                            along: watchingYaw)
        } else {
            controller.walk(forward: forward, sideways: sideways, over: dt)
        }
        requestRefresh()
    }

    /// Moves the cue by everything the mouse has done to it since the last frame, over the time that
    /// frame took. That is what makes the shot's strength the speed of the cue: the same flick of the
    /// mouse at half the frame rate is still the same speed of cue.
    private func applyCueTravel(dt: Double) {
        // Once the shot is away the cue is still the player's: the mouse carries the stick along its
        // own line — the follow-through, a push, or pulling it clear of the balls — and any ball it
        // runs into is a foul. See `FrameDriver.carryTheCue`.
        if controller.mode == .simulating {
            let travel = pendingCueTravel
            pendingCueTravel = 0
            // A cue action the **game** is playing is not the mouse's to spoil: a charged shot's stroke is
            // pre-programmed, and the mouse is out of it from the moment the button is let go.
            if !controller.theCueActionIsTheGames {
                controller.carryTheCue(forwardByMillimetres: travel, over: dt)
            }
            return
        }
        guard controller.isMovingTheCue, !controller.theCueActionIsTheGames else {
            pendingCueTravel = 0
            return
        }
        let travel = pendingCueTravel
        pendingCueTravel = 0
        // Moving the cue visits this every frame, including the frames where the mouse is still: the
        // cue's speed falls back to nothing, and the shot it would play with it.
        if controller.moveCue(forwardByMillimetres: travel, over: dt) {
            requestRefresh()
        }
    }

    /// Millimetres of cue travel per point of mouse travel: the cue action's **sensitivity** and nothing
    /// else. The strength of a shot is the speed of the cue, and the mouse is the only thing setting that
    /// speed, so halving this halves what the same hand movement is worth: a finer cue action, a push worth
    /// playing that is longer and steadier, and twice the travel to draw the cue right back. At a third of a
    /// millimetre a point the whole 400 mm pull-back is some 1140 points of mouse, and a brisk push of 1000
    /// points a second leaves the ball about a tenth of full power.
    private static let cueMillimetresPerPoint: CGFloat = 0.35
    /// How big the spin widget's ball is drawn, in points: one ball radius of the cue ball as the
    /// player sees it on this graph. The tip's offset is drawn at exactly that scale, so the middle of
    /// the ball is the middle of the graph and its edge is the edge.
    private static let spinWidgetRadius: CGFloat = 68
    /// The strength meter's own shape, full width: the bar is the track scaled to the power, so the
    /// path is built once and never rebuilt. See `updatePower`.
    private static let powerBarPath = CGPath(roundedRect: CGRect(x: 0, y: 0, width: 260, height: 14),
                                            cornerWidth: 6, cornerHeight: 6, transform: nil)
    /// Tip offset (a fraction of the ball's radius) per point of mouse travel: 200 points takes the
    /// tip from the middle of the ball to about half a radius off centre.
    private static let spinPerPoint: CGFloat = 0.0025
    /// Radians of cue elevation per point of mouse travel: 200 points takes the cue from level to as
    /// far up as it can be lifted.
    private static let elevationPerPoint: CGFloat = CGFloat(PhysicsWorld.maxCueElevation) / 200

    /// Whether the game wants the mouse: the player's own view, playing, and not in the middle of a drag.
    ///
    /// A choice on the screen does **not** take the mouse away, and does not put the pointer up in front
    /// of the player either: questions are answered with the keys, and the pointer is there when the
    /// player asks for it with **Control** — see `keepTheMouseAsTheGames`.
    private var theGameWantsTheMouse: Bool {
        guard viewMode == .firstPerson, !isDraggingSpin else { return false }
        // A question does not take the mouse away, and does not put the pointer up for the player either
        // — not even the three that guard a whole frame, which are the ones most often asked at the end of
        // one. They are answered with the keys, or with the buttons by a player who has taken the pointer
        // out to click them: see `keepTheMouseAsTheGames`.
        if controller.isAskingAboutANewFrame || controller.isAskingAboutAReRack
            || controller.isAskingAboutANewGame { return true }
        switch controller.mode {
        case .aiming, .charging, .decision, .simulating: return true
        default: return false
        }
    }

    /// Whether the player has asked for the pointer with **Control**. It is a **toggle** and not a hold:
    /// one tap puts the pointer in their hand, the next gives the mouse back to the game.
    private var thePlayerWantsThePointer = false
    /// Whether the Control key is down now, so that a tap of it can be told from the key's own repeat.
    private var isHoldingControlKey = false
    /// Whether the mouse is the **game's**: the game wants it and the player has not asked for the pointer.
    ///
    /// **The control follows this and nothing else.** While it holds, the mouse steers and the pointer is
    /// hidden; while it does not, the pointer is the player's and **the mouse steers nothing at all** —
    /// the view stays exactly where it was left, whatever is done with the pointer. That is the rule the
    /// whole of this is built on: hidden, the mouse is the game's; shown, it is a pointer.
    private var theMouseIsTheGames: Bool { theGameWantsTheMouse && !thePlayerWantsThePointer }
    /// Whether the pointer is hidden now, with the mouse uncoupled from it — which is the state the
    /// window's own business: it is set by `keepTheMouseAsTheGames`, and only while there is a window for
    /// the mouse's movements to be reported to.
    private var pointerIsHidden = false

    /// Where the player's pointer was when the game took the mouse, to give it back where they left it.
    private var thePlaceToGiveThePointerBack: CGPoint?
    /// One movement after the game has put the pointer somewhere itself is the game's doing and not the
    /// player's, and is left out of the control.
    private var ignoreTheNextMovement = false
    /// Which way round each axis of the mouse's own movement comes: x across, y up the screen. The
    /// mouse's deltas and the pointer's places come from different parts of the system, so which way
    /// each axis runs is *learned* from the first event where both can be seen and believed, rather than
    /// assumed — see `mouseMovement(of:to:)`. Once learned it is **kept**: the way round an axis comes is
    /// a property of the device and the system and not of the moment, and re-learning it from a moment
    /// when the pointer was somewhere unexpected is how the controls come out reversed.
    private var mouseXTurns: CGFloat = 1
    private var mouseYTurns: CGFloat = -1
    /// Whether each axis has been learned yet. Until it has, every believable event is a chance to learn
    /// it; after it has, the reading stands.
    private var mouseXIsLearned = false
    private var mouseYIsLearned = false

    /// When the window's size last changed, the pointer's places stop meaning anything for a moment: the
    /// scene is a different size from the one the last place was read in, and a window that has just been
    /// taken full screen — or given back — is still moving. See `didChangeSize`.
    private static let theSizeTakesToSettle: TimeInterval = 1.0
    private var theSizeIsSettlingUntil: TimeInterval = 0
    private var theSizeIsSettling: Bool { CACurrentMediaTime() < theSizeIsSettlingUntil }

    /// Takes the mouse for the game, or gives it back, as the game's need for it and the player's own
    /// asking change: `theGameWantsTheMouse` and `thePlayerWantsThePointer`.
    ///
    /// Capturing is three things together: the pointer is **uncoupled** from the mouse
    /// (`CGAssociateMouseAndMouseCursorPosition(false)`), so that moving the mouse does not move the
    /// pointer at all and the screen's edges never come into it; the pointer is **hidden**, and asked to be
    /// hidden again on every frame the game has the mouse (see `keepTheCursorOutOfTheWay`), because one
    /// hide can be undone after the event by an older unhide or by the system; and it is put in the middle
    /// of the window and left there, since nothing is going to move it and it is the window's events the
    /// mouse's movements are reported to. The mouse's own movement — the event's deltas — is then the whole
    /// of the control: no edge to run into, no clamp, nothing to recentre, and no pointer in the way of the
    /// view.
    ///
    /// Giving it back reconnects the pointer, shows it, and puts it back where the player left it. That
    /// happens whenever the game stops wanting the mouse or the player asks for the pointer, and the
    /// moment the window stops being the active one: a captured mouse must never be left behind for
    /// somebody who has switched to another application.
    private func keepTheMouseAsTheGames() {
        guard let view, let window = view.window else { return }
        let hide = theMouseIsTheGames && window.isKeyWindow && NSApp.isActive
        // The cursor is kept out of the way for as long as the mouse is the game's, and not only at the
        // moment it is taken: the one hide a capture asks for can be undone afterwards by the unhide that
        // went with the last release arriving late, and a cursor left standing in the middle of the screen
        // with the mouse still captured is the one thing the capture is there to prevent.
        if hide { keepTheCursorOutOfTheWay() }
        guard hide != pointerIsHidden else { return }
        guard hide else { giveTheMouseBack(); return }
        thePlaceToGiveThePointerBack = NSEvent.mouseLocation
        CGAssociateMouseAndMouseCursorPosition(0)  // off: the pointer stops following the mouse
        // With the pointer hidden there is nothing to see, but the *window* under it still matters: the
        // mouse's movements are reported to whatever window the pointer is over, so the pointer is put in
        // the middle of this one, to be sure they are reported here.
        let middle = CGPoint(x: size.width / 2, y: size.height / 2)
        CGWarpMouseCursorPosition(window.convertPoint(toScreen: view.convert(middle, to: nil)))
        ignoreTheNextMovement = true
        pointerIsHidden = true
    }

    /// How many hides of the cursor the game holds while the mouse is its own. It only ever needs the one,
    /// and it keeps a few in hand: a hide can be undone behind the game's back — by the unhide that went
    /// with the last release, or by the system resetting the count when the app stops being the frontmost
    /// one — and nothing can be asked whether that has happened. See `keepTheCursorOutOfTheWay`.
    private static let hidesOfTheCursorToHold = 4
    /// How many of them are being held just now.
    private var hidesOfTheCursorTheGameHolds = 0

    /// How the game asks for the cursor to be hidden or shown. It is a function so that the offscreen probe
    /// can walk the bookkeeping without a cursor of its own — and so that a harness, which is nobody's
    /// window, never hides the cursor of whoever is running it.
    var askForTheCursor: (Bool) -> Void = { hide in
        if hide { NSCursor.hide() } else { NSCursor.unhide() }
    }

    /// Takes the cursor away for this frame, for as long as the mouse is the game's.
    ///
    /// Asking again on every frame is what makes the hiding stick: a hide can be overtaken by an unhide that
    /// was sent before it and acted on after, and asking again puts a newer hide on top of it. Each one is
    /// counted, and past the few the game holds at once each new hide is answered by giving an older one
    /// back — which brings the count down by one without ever bringing it to nothing, so the cursor is
    /// hidden the whole time it is wanted hidden and the two sides of the count still balance: every hide
    /// the game is holding is given back when the mouse is.
    private func keepTheCursorOutOfTheWay() {
        askForTheCursor(true)
        hidesOfTheCursorTheGameHolds += 1
        if hidesOfTheCursorTheGameHolds > TableScene.hidesOfTheCursorToHold {
            askForTheCursor(false)
            hidesOfTheCursorTheGameHolds -= 1
        }
    }

    /// Gives the cursor back: every hide the game is holding, and no more.
    private func giveTheCursorBack() {
        while hidesOfTheCursorTheGameHolds > 0 {
            askForTheCursor(false)
            hidesOfTheCursorTheGameHolds -= 1
        }
    }

    /// Walks the cursor's bookkeeping for the offscreen probe: `frames` of the mouse being the game's, and
    /// then the cursor given back. Returns what was asked for and what is still being held. The arithmetic
    /// is the part that can go wrong — a count that drifts shows the cursor while the mouse is captured, or
    /// leaves it hidden after the mouse is given back — and it can be walked through with no cursor in
    /// sight, since `askForTheCursor` is what the probe replaces.
    @discardableResult
    func walkTheCursorBookkeeping(forFrames frames: Int,
                                  givingItBack: Bool) -> (hides: Int, shows: Int, held: Int) {
        var hides = 0, shows = 0
        let theRealThing = askForTheCursor
        askForTheCursor = { hide in if hide { hides += 1 } else { shows += 1 } }
        defer { askForTheCursor = theRealThing }
        // The probe starts from nothing held: whatever the last run left, it is not this run's business.
        hidesOfTheCursorTheGameHolds = 0
        for _ in 0..<frames { keepTheCursorOutOfTheWay() }
        let heldWhilePlaying = hidesOfTheCursorTheGameHolds
        if givingItBack { giveTheCursorBack() }
        return (hides, shows, heldWhilePlaying)
    }

    /// How many hides of the cursor the game is holding now, for the offscreen probe.
    var cursorHidesHeld: Int { hidesOfTheCursorTheGameHolds }

    /// Reconnects the pointer, shows it and puts it back where the player left it.
    private func giveTheMouseBack() {
        guard pointerIsHidden else { return }
        CGAssociateMouseAndMouseCursorPosition(1)      // on: the pointer follows the mouse again
        if let place = thePlaceToGiveThePointerBack {
            CGWarpMouseCursorPosition(place)
            thePlaceToGiveThePointerBack = nil
            ignoreTheNextMovement = true
        }
        giveTheCursorBack()
        pointerIsHidden = false
    }

    /// **Control**: the pointer in the player's hand, or the mouse in the game's. A tap either way — the
    /// state itself is settled in the frame loop, by `keepTheMouseAsTheGames`.
    private func toggleThePointer() {
        thePlayerWantsThePointer.toggle()
    }

    /// Whether the question after a foul (or a miss) is the one on the screen — the `P`, `O` and `R`
    /// keys' business.
    private var theFoulQuestionIsOnScreen: Bool {
        switch controller.pending {
        case .afterFoul, .afterMiss: return true
        default: return false
        }
    }

    /// Whether that question offers the balls being put back and the offender playing again from the
    /// original position (Rules 10(i) and 14(b)), which is the only answer `R` gives.
    private var theBallsMayBePutBack: Bool {
        switch controller.pending {
        case .afterFoul(let decision): return decision.canRequestOriginalPosition
        case .afterMiss(let decision): return decision.canRequestOriginalPosition
        default: return false
        }
    }

    override func mouseDown(with event: NSEvent) {
        wake()
        let location = event.location(in: self)

        // Buttons first.
        for button in buttons where button.rect.contains(location) {
            // Choosing something in the middle of a shot abandons the shot rather than letting the
            // release finish it off.
            controller.cancelCharge()
            button.action()
            requestRefresh()
            return
        }

        // The computer's turn: the table is not the player's to touch. The buttons above still work, so
        // the game's own questions can be answered by hand if they want to.
        if theComputerIsAtTheTable { return }

        if spinNode.frame.insetBy(dx: -12, dy: -12).contains(location) {
            isDraggingSpin = true
            updateSpin(from: location)
            return
        }

        if controller.mode == .placingCueBall {
            // In the first-person view the click has to be cast onto the cloth from where the
            // player is standing; from above it is simply the point under the pointer.
            let point = (viewMode == .firstPerson ? table3D?.tablePoint(at: location, viewSize: size) : nil)
                ?? tablePoint(location)
            if controller.placeCueBall(at: point) {
                requestRefresh()
            } else {
                controller.movePointer(to: point)
            }
            return
        }

        // A click on the cue ball itself picks it up again, while it may still be moved: the ball is
        // placed in hand and has not been struck yet (Section 3 Rule 5).
        if controller.canRepositionCueBall, let cue = controller.cueBall, cue.onTable,
           let onScreen = table3D?.project(Table3D.scenePoint(for: cue), imageSize: size),
           hypot(location.x - onScreen.x, location.y - onScreen.y) < ballScreenRadius(of: cue) {
            controller.repositionCueBall()
            requestRefresh()
            return
        }

        // In the first-person view the pointer is the player's line of sight, which the mouse
        // already set; turning the click into a table position here would throw the aim away.
        if viewMode == .topDown {
            controller.movePointer(to: tablePoint(location))
        }
        // While a key is driving the tip or the cue, a click is not a way to start a shot.
        guard !isHoldingSpinKey, !isHoldingCueKey else { return }
        controller.beginCharge(at: CACurrentMediaTime())
    }

    /// How wide a ball is on screen, in points, so that a click on one can be told from a click at
    /// the cloth beside it.
    private func ballScreenRadius(of ball: Ball) -> CGFloat {
        guard let table3D,
              let centre = table3D.project(Table3D.scenePoint(for: ball), imageSize: size),
              let edge = table3D.project(Table3D.scenePoint(ball.position + Vec2(Table.ballRadius, 0),
                                                            height: Table.ballRadius),
                                         imageSize: size) else { return 0 }
        return max(8, hypot(edge.x - centre.x, edge.y - centre.y))
    }

    override func mouseUp(with event: NSEvent) {
        wake()
        if isDraggingSpin {
            isDraggingSpin = false
            return
        }
        // The cue action plays its own stroke as the tip comes through the ball, so letting go of
        // the button must not play a second one.
        if controller.mode == .charging, !controller.isMovingTheCue {
            controller.releaseShot()
            requestRefresh()
        }
    }

    private func updateSpin(from location: CGPoint) {
        let centre = spinNode.position
        let dx = Double((location.x - centre.x) / TableScene.spinWidgetRadius)
        let dy = Double((location.y - centre.y) / TableScene.spinWidgetRadius)
        // The graph is the ball, so a drag to its edge is a tip on the edge of the ball — and the
        // player is free to go there, past both of the lines drawn on it. Only the ball itself stops
        // the tip: a touch outside its face is not a touch.
        let magnitude = (dx * dx + dy * dy).squareRoot()
        let scale = magnitude > 1 ? 1 / magnitude : 1
        let clampedX = dx * scale
        let clampedY = dy * scale
        // The drag goes through the driver, which stops the tip where the cue runs out of room behind
        // the ball rather than carrying the stick into it: see `FrameDriver.setSpin`.
        controller.setSpin(side: clampedX, vertical: clampedY)
    }

    override func keyDown(with event: NSEvent) {
        wake()
        // **Z** held puts the mouse on the player's legs and **X** held ducks their eye down over the
        // cloth. Both are keys to keep hold of, so the press sets the state and the release clears it, and
        // the key's own repeat carries nothing new — but the repeat still has to be **taken**. A key event
        // that falls through to the responder chain is a key the system answers with a beep, and a held
        // key repeats: left to fall through, Z and X beeped once per repeat for as long as they were held.
        // So every one of their events is dealt with here, whether or not the player is in a place to use
        // the key, and only the first press does anything.
        if let character = event.charactersIgnoringModifiers?.lowercased(),
           character == "z" || character == "x" {
            if thePlayerMayWalkAbout, !event.isARepeat {
                if character == "z" { isHoldingWalkKey = true } else { table3D?.setCrouching(true) }
                requestRefresh()
            }
            return
        }
        // Up and about with the cue put away the arrows walk the player about rather than sighting
        // finely: they are held keys, read in the frame loop, so the walk is smooth and does not wait
        // on the keyboard's own repeat.
        if thePlayerMayWalkAbout, (123...126).contains(Int(event.keyCode)) {
            heldWalkKeys.insert(event.keyCode)
            return
        }
        // Arrow keys sight the shot finely, which the mouse on its own is too coarse for. Held down
        // they carry on, like the walk above and the keys the mouse is given to.
        if viewMode == .firstPerson, let table3D {
            let fine = event.modifierFlags.contains(.shift) ? 0.02 : 0.2
            switch event.keyCode {
            case 123, 124:
                controller.turnTheAim(by: -(event.keyCode == 124 ? 1 : -1) * fine * .pi / 180)
                requestRefresh()
                return
            case 125, 126:
                table3D.setPitch(table3D.pitch + (event.keyCode == 126 ? 1 : -1) * fine * .pi / 180)
                requestRefresh()
                return
            default:
                break
            }
        }
        // Everything past here is an **action** rather than a key to hold: taken once, on the press. A
        // repeat of it would only do the same thing over again — and redraw the screen over again — so
        // a held key's repeats are taken here and dropped. Without this, holding `N`, `F` or `H` went on
        // firing, and the keys that are not the game's fell through to beep once per repeat.
        if event.isARepeat { return }
        // The letters on the question after a foul (or a miss): the non-offender answers from the
        // keyboard, so that nothing has to be put up in front of them to click. **P** plays from here,
        // **O** asks the offender to play from here, and **R** has the balls replaced and the offender
        // play again from the original position — where the rules leave that open. **U**, while the
        // answer can still be taken back, puts the question again.
        if event.charactersIgnoringModifiers?.lowercased() == "u", controller.canChooseSomethingElse {
            controller.chooseSomethingElse()
            requestRefresh()
            return
        }
        if theFoulQuestionIsOnScreen {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "p":
                controller.playFromPositionLeft()
                requestRefresh()
                return
            case "o":
                controller.askOffenderToPlayAgain()
                requestRefresh()
                return
            case "r" where theBallsMayBePutBack:
                controller.requestOriginalPosition()
                requestRefresh()
                return
            default:
                break
            }
        }
        // The number keys pick a colour by its value (Section 1 Rule 1(a)): 2 Yellow, 3 Green,
        // 4 Brown, 5 Blue, 6 Pink, 7 Black — for the colour being nominated, or for a free ball
        // standing in for the ball on. Handled before the eyed levels below, so that away from a
        // colour choice these numbers keep their other job.
        // **0** is the free ball answered with nothing: there is no free ball, and the ball on is played as
        // it stands. It is the keyboard's half of the **No free ball** button, and the key is taken whether
        // or not that question is on the screen, so that it never falls through to be a beep.
        if event.charactersIgnoringModifiers == "0" {
            if case .nominateFreeBall? = controller.pending {
                controller.declineFreeBall()
                requestRefresh()
            }
            return
        }
        if let colour = TableScene.colour(forNumberKey: event.charactersIgnoringModifiers) {
            if case .nominateColour(let options)? = controller.pending, options.contains(colour) {
                controller.chooseColour(colour)
                requestRefresh()
                return
            }
            if case .nominateFreeBall(let options)? = controller.pending, options.contains(colour) {
                controller.chooseFreeBall(colour)
                requestRefresh()
                return
            }
            if controller.isPlayingForAColour {
                controller.chooseColour(colour)
                requestRefresh()
                return
            }
        }

        // P picks the cue ball up again, to be placed somewhere else.
        if event.charactersIgnoringModifiers?.lowercased() == "p", controller.canRepositionCueBall {
            controller.repositionCueBall()
            requestRefresh()
            return
        }

        switch event.charactersIgnoringModifiers?.lowercased() {
        case "n":
            // Not straight to a new frame: N sits next to the other keys and the frame in progress is
            // worth more than a slip of the hand, so it asks first — unless the frame is **over**, when
            // a new one is what the player is asking for and there is nothing left to guard.
            if controller.isFrameOver {
                controller.startTheNewFrame()
            } else {
                controller.askToStartANewFrame()
            }
            requestRefresh()
        case "r":
            // R asks first, as N does: a re-rack nullifies the whole frame's scores (Section 3 Rule 17).
            controller.askToReRack()
            requestRefresh()
        case "c" where !event.modifierFlags.contains(.shift):
            // C puts the cue away or lays it on the table. Conceding is Shift-C (and the Game menu),
            // which the menu picks up before the key gets here.
            controller.toggleCueHandling()
            requestRefresh()
        case "v":
            toggleViewMode()
        case "m":
            // M is the sound: on or off, and the game plays on either way.
            audio?.isMuted.toggle()
        case "g":
            // G steps round the aiming aids: off, the line of aim, and then that line with the line the
            // ball being met is going to take.
            table3D?.stepTheAimingAids()
            requestRefresh()
        case "e":
            // Hold E and the mouse moves the tip on the cue ball instead of the aim.
            guard !controller.isWatching else { break }
            isHoldingSpinKey = true
            requestRefresh()
        case "b":
            // Hold B and the mouse lifts and lowers the cue: with side spin set, a lifted cue strikes
            // down at the ball and the cloth curves the shot into a swerve.
            guard !controller.isWatching else { break }
            isHoldingElevationKey = true
            requestRefresh()
        case "s":
            // Hold S and the mouse draws the cue back and pushes it through the ball.
            guard !controller.isWatching else { break }
            if !isHoldingCueKey, controller.beginCueAction() {
                isHoldingCueKey = true
                requestRefresh()
            }
        case "1", "2", "3":
            // The eye level for standing at the table: getting down over the shot is what S does, so
            // 1 and 2 both stand the player up and 3 raises them.
            guard viewMode == .firstPerson, let table3D else { break }
            let preset: PlayerCamera.Preset = event.charactersIgnoringModifiers == "3" ? .raised : .standing
            table3D.use(preset)
            requestRefresh()
        case " ":
            if !isHoldingSpinKey, !isHoldingCueKey, !controller.isWatching, controller.canStrike {
                controller.beginCharge(at: CACurrentMediaTime())
            }
        case "h":
            // H opens and closes the panel that has the whole of the controls on it. The game plays on
            // behind it: it is a page to read, not a pause.
            isShowingHelp.toggle()
            requestRefresh()
        case "f":
            // F takes the window full screen and brings it back. It is the window's own business rather
            // than the game's, so the scene only asks: the picture re-lays itself out when the window
            // changes size, which `didChangeSize` sees.
            view?.window?.toggleFullScreen(nil)
        case "\u{1b}":
            // Esc asks about a new game — clearing the frames won and every score — and Esc again puts the
            // question away: nothing is thrown away until it is answered with a button. In a game between
            // two computers it is also the **pause**.
            escapePressed()
        default:
            // Nothing in the game wanted this key, so it goes on to the responder chain — where the
            // window answers an unhandled key with a beep. Counted so the harness can hold a key the game
            // **does** define down, repeats and all, and check that none of its events end up here.
            keysPassedOn += 1
            super.keyDown(with: event)
        }
    }

    /// **Control** is a **tap** and not a hold: one tap takes the pointer into the player's hand and the
    /// next gives the mouse back to the game, so a screen that wants the pointer can be dealt with without
    /// holding a key down. A modifier on its own is a `flagsChanged`, not a `keyDown`, which is why it is
    /// read here too; 59 and 62 are the left and right Control keys.
    override func flagsChanged(with event: NSEvent) {
        wake()
        if event.keyCode == 59 || event.keyCode == 62 {
            let isDown = event.modifierFlags.contains(.control)
            if isDown, !isHoldingControlKey { toggleThePointer() }
            isHoldingControlKey = isDown
        }
        super.flagsChanged(with: event)
    }

    override func keyUp(with event: NSEvent) {
        wake()
        heldWalkKeys.remove(event.keyCode)
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "z":
            // Let go and the mouse is the player's look again, from wherever they have walked to.
            isHoldingWalkKey = false
            requestRefresh()
        case "x":
            // Standing up: the eye goes back to the level the player's stance has it at.
            table3D?.setCrouching(false)
            requestRefresh()
        case "e":
            isHoldingSpinKey = false
        case "b":
            // Letting go leaves the cue where it is raised to: the shot is still the player's to play.
            isHoldingElevationKey = false
            requestRefresh()
        case "s":
            // Let go without pushing the cue through the ball and the shot is never played: the cue
            // goes back to its rest position. With the balls already running, letting go is the player
            // standing up from the shot: the cue stays on the table, where the mouse has left it.
            isHoldingCueKey = false
            controller.cancelCueAction()
            controller.standUp()
            requestRefresh()
        case " " where controller.mode == .charging && !controller.isMovingTheCue:
            controller.releaseShot()
            requestRefresh()
        default:
            super.keyUp(with: event)
        }
    }

    // MARK: - Frame loop

    override func update(_ currentTime: TimeInterval) {
        let dt = lastUpdateTime == 0 ? 1.0 / 120.0 : min(0.05, currentTime - lastUpdateTime)
        lastUpdateTime = currentTime

        applyWalking(dt: dt)
        // Whose turn it is decides whether the mouse is the player's own head or the cue's. While the
        // computer is at the table the player is only watching — and the moment that begins, the watcher
        // takes up the aim the computer is facing along, so that the view does not jump.
        let watching = theComputerIsAtTheTable
        if watching, !controller.isWatching { watchingYaw = controller.aimAngle }
        controller.isWatching = watching
        controller.updateCharge(at: CACurrentMediaTime())
        // The mouse's travel is handed to the stroke **before** the frame's steps, and the stick is carried by
        // the simulation along with the balls — a step at a time — rather than jumping a frame's worth at
        // once: a player pushing the mouse forward on the frame of the strike cannot shove the tip into a ball
        // that is already running away from it, and the tip and the balls are moved together. See
        // `FrameDriver.carryTheCue` and `PhysicsWorld.theCueIsToBeCarriedBy`.
        applyCueTravel(dt: dt)
        if controller.mode == .simulating {
            let finished = controller.update(dt: dt)
            if finished { requestRefresh() }
        } else if controller.ballsAreFalling {
            // A ball forced off the table is off it as far as the rules are concerned, but it is still
            // in the air: it is let fall the rest of the way here, between strokes.
            controller.letTheBallsFall(dt: dt)
        }
        if viewMode == .firstPerson {
            table3D?.update(with: controller, dt: dt, watching: controller.isWatching,
                            lookYaw: watchingYaw)
        }
        // And the computer's turn, if it is: it is asked what to do, and does it when it has decided.
        theComputerLooksAfterItsCue()
        giveTheComputerItsTurn()
        // **Control** is the pointer's own key: a tap takes the pointer into the player's hand and the next
        // tap gives the mouse back to the game. It is read from the modifier state every frame, and not
        // only from a `flagsChanged`, because a modifier on its own has no key event of its own and the
        // state is the same thing those events would say — only always there. `flagsChanged` still has
        // its say (see `flagsChanged(with:)`); both go through `isHoldingControlKey`, so a tap is a tap
        // whichever of them catches it, and never two.
        let controlIsDown = view?.window?.isKeyWindow == true && NSApp.isActive
            && NSEvent.modifierFlags.contains(.control)
        if controlIsDown, !isHoldingControlKey { toggleThePointer() }
        isHoldingControlKey = controlIsDown
        // The mouse is taken for the game, or given back, between frames: see `keepTheMouseAsTheGames`.
        keepTheMouseAsTheGames()

        // What this frame made a noise with — the strike, if there was one, and every contact the balls
        // made — taken once so that nothing is ever played twice. The contacts are drained whether or
        // not there is any sound to put them through; the harness has none, and is silent.
        let impacts = controller.takeImpacts()
        if let audio, !impacts.isEmpty {
            if viewMode == .firstPerson, let table3D {
                audio.play(impacts,
                           ear: table3D.cameraOnTheTable.position,
                           forward: Vec2(cos(controller.aimAngle), sin(controller.aimAngle)))
            } else {
                audio.play(impacts)
            }
        }
        // The one redraw of the frame, for everything that has happened since the last one.
        let force = wantsRefresh
        wantsRefresh = false
        refresh(force: force)
        // And what the next frame is worth: a frame of play, a frame at the table, or nothing until
        // something moves again. See `FrameRate`.
        setFrameRate(wantedFrameRate())
    }
}
