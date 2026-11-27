import SwiftUI
import MetalKit
import AVFoundation
import QuartzCore

/// Fullscreen native-player screen, core-agnostic. Drives retro_run off
/// MTKView's own display-link-backed draw loop through LibretroFrontend,
/// uploads each frame into a Metal texture aspect-fit with no
/// shaders/filters, and feeds the core's audio batches into an
/// AVAudioEngine source node. The caller (NativeLauncher) has already
/// activated the right core and loaded the game before this appears.
struct NativePlayerView: View {
    let rom: Rom
    let core: NativeCore
    /// The sitting's saves, from the launch (NativeLauncher.prepare): the
    /// start's pick, and what is gathered at pause, background and Quit.
    /// Nil for a core with no saves, and for a bench run.
    var saves: GameSaves?
    /// A state picked on the launch screen, restored shortly after boot.
    var initialState: Data?

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss
    @StateObject private var renderer = NativePlayerRenderer()
    @ObservedObject private var controllers = GameControllerManager.shared
    /// Whether a television is showing the picture. See ExternalDisplay.swift.
    @ObservedObject private var external = ExternalDisplay.shared
    @State private var previousControllerSend: ((Int, Int, Bool) -> Void)?
    @State private var previousControllerStick: ((Int, Float, Float) -> Void)?
    @State private var previousControllerMenu: (() -> Void)?
    @State private var previousControllerDisconnect: ((Int) -> Void)?
    @State private var menuVisible = false
    @State private var menuBusy = false
    /// The touch controls' visibility slider, from Settings.
    @AppStorage("com.mmagtech.RommApp.controlOpacity") private var controlOpacity = 0.7
    @Environment(\.scenePhase) private var scenePhase
    @State private var startedAt: Date?
    /// What the game says over itself for a few seconds, the TV's pill: the
    /// start's notice ("Continuing from another device") and the pause
    /// menu's answers ("State saved"). Drawn over the picture and over the
    /// menu, so nothing on screen moves and the menu never changes size.
    @State private var notice: GameNotice.Shown?

    private var canonicalSlug: String {
        rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions)
    }

    /// The platform this rom actually runs as, for shader storage/
    /// availability. Falls back to arcade's platform when resolution
    /// somehow fails (it never should have gotten this far otherwise,
    /// `NativeLauncher.prepare` already required a resolved platform to
    /// reach this screen at all), matching `core`'s own required-not-
    /// optional treatment upstream.
    private var platform: NativePlatform {
        NativePlatform.platform(for: rom, canonicalSlug: canonicalSlug) ?? .arcade
    }

    /// The bundled per-platform touch layout.
    private var controlLayout: ControlLayout {
        // A missing layout file already trips forPlatform's assertion in
        // a debug build; a release build draws no pad rather than crash.
        return ControlLayout.forPlatform(slug: canonicalSlug)
            ?? ControlLayout(system: "default", items: [], landscapeItems: nil, headroom: nil)
    }

    private func layoutItems(landscape: Bool) -> [ControlLayout.Item] {
        // Tap-the-artwork games keep only Menu, synthesized here rather
        // than filtered from gw.json: that file's portrait items are
        // strip-normalised and this presentation is full screen, so the
        // pill needs coordinates in this space, one corner, small.
        if platform == .gameAndWatch {
            return [ControlLayout.Item(
                kind: .pill, label: "Menu", input: -1, inputs: nil,
                frame: ControlLayout.Rect(x: 0.03, y: 0.015, w: 0.14, h: 0.042),
                extended: ControlLayout.Rect(x: 0.01, y: 0.005, w: 0.18, h: 0.062),
                fourWay: nil)]
        }
        return controlLayout.items(landscape: landscape)
    }

    /// The tap-the-artwork map for a Game & Watch game, when the
    /// extractor mapped this one. Nil means the game fell back to the
    /// small pad in gw.json, which stays the honest fallback.
    private var gwSpec: GWHotspots? {
        platform == .gameAndWatch ? GWHotspots.spec(for: rom.fsName) : nil
    }

    /// The height of the portrait control strip below the picture.
    private var controlStripHeight: CGFloat { 330 }

    private func handlePointer(_ x: Double, _ y: Double, _ down: Bool) {
        // gw-libretro reads its pointer on port 2, stated in its own
        // controller_info; melonDS's touchscreen reads port 0.
        let port = platform == .gameAndWatch ? 2 : 0
        LibretroFrontend.shared.setPointerX(Float(x), y: Float(y), down: down, port: port)
    }

    private func handleInput(_ id: Int, down: Bool) {
        if id == RetroPad.overlay {
            if down { openMenu() }
            return
        }
        // Touch is always player 1: there is deliberately no second-player
        // touch layout, so port 0 is the only port the overlay ever drives.
        renderer.setButton(id, down: down, port: 0)
    }

    /// `ids` is unused here on purpose: a touch stick is always the left
    /// analog stick, and LibretroFrontend already knows which analog index
    /// that is.
    private func handleStick(_ ids: [Int], x: Double, y: Double) {
        renderer.setStick(x: x, y: y, port: 0)
    }

    private func openMenu() {
        renderer.paused = true
        withAnimation(PauseMenu.fade) { menuVisible = true }
        // Say so on the television, which is still showing the frozen
        // frame. Harmless with no television attached.
        ExternalDisplay.shared.isPaused = true
        // The phone's copy of a battery, written and marked owed; sent when
        // the game is left.
        saves?.gatherBattery(renderer)
        saves?.keepOwed()
    }

    /// Whether the first frame must wait for the battery to be seated: a
    /// game must not boot past its own save check before its save is in.
    private var holdsForBattery: Bool {
        saves?.form.kind == .battery
    }

    /// What changed, marked and sent while iOS lets the app finish: the
    /// app may be ended in the background with no warning.
    private func leaveInBackground() {
        saves?.gatherBattery(renderer)
        saves?.gatherFiles()
        guard let sending = saves?.leave(session: session) else { return }
        let id = UIApplication.shared.beginBackgroundTask(withName: "Send the game's save")
        Task {
            await sending.value
            UIApplication.shared.endBackgroundTask(id)
        }
    }

    private func closeMenu() {
        withAnimation(PauseMenu.fade) { menuVisible = false }
        renderer.paused = false
        ExternalDisplay.shared.isPaused = false
    }

    var body: some View {
        GeometryReader { geometry in
            let isLandscape = geometry.size.width > geometry.size.height
            let showsControls = !controllers.isConnected

            ZStack {
                if isLandscape || !showsControls || platform == .gameAndWatch {
                    // Full screen canvas, pad in the gutters (or hidden with a
                    // controller connected).
                    ZStack {
                        // Exactly one MTKView may hold this renderer at a
                        // time. Two would run two draw loops and advance
                        // the core twice a frame, so when the television
                        // has the picture the phone draws none.
                        if !external.showsGameExternally {
                            MetalGameView(renderer: renderer)
                            if core == .melonDS {
                                DSTouchScreenView(sendPointer: handlePointer)
                            }
                            // The artwork's own buttons are the pad; see
                            // GWHotspots. Under the control pad so the
                            // Menu pill still wins its corner.
                            if let spec = gwSpec {
                                GWTapView(spec: spec, send: handleInput,
                                          displayAspect: { renderer.displayAspect })
                            } else if platform == .gameAndWatch {
                                // The Lua simulators read the pointer and
                                // match their own declared tap zones, so
                                // there is nothing to extract and nothing
                                // to maintain: hand the tap over and the
                                // game does the rest. Any Lua game added
                                // later works with no tool run.
                                GWPointerView(send: handlePointer,
                                              displayAspect: { renderer.displayAspect })
                            }
                        }
                        if showsControls {
                            TouchControlPad(items: layoutItems(landscape: isLandscape), send: handleInput, sendStick: handleStick, system: controlLayout.system, opacity: controlOpacity)
                                .allowsHitTesting(!menuVisible)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .background(Color.black)
                } else {
                    // Portrait: the pad's items are normalised against a
                    // bottom strip, not the full screen, so the canvas keeps
                    // exactly the height it always has. The canvas stays below the top safe area so the island
                    // never eats the picture.
                    //
                    // The pad itself can be taller than the strip it is
                    // normalised against: `headroom` (zero for every layout
                    // that does not ask for it, so this reproduces the old
                    // plain split pixel for pixel) grows the pad upward from
                    // the bottom edge to overlap the canvas's own last bit,
                    // for a pad too crowded to fit the strip alone. Opacity
                    // keeps the overlap legible, the same deal landscape
                    // already makes everywhere.
                    let padHeight = controlStripHeight * (1 + (controlLayout.headroom ?? 0))
                    ZStack(alignment: .top) {
                        if !external.showsGameExternally {
                            ZStack {
                                MetalGameView(renderer: renderer)
                                if core == .melonDS {
                                    DSTouchScreenView(sendPointer: handlePointer)
                                }
                            }
                            .frame(height: max(geometry.size.height - controlStripHeight, 0))
                        }
                        // Moulded in portrait, where the controls sit on
                        // their own strip below the picture rather than
                        // over it, so an opaque control hides nothing.
                        // The visibility slider still works: it is the
                        // pad view's own alpha, so a moulded control
                        // fades as a whole and keeps its depth on the
                        // way down. Landscape deliberately stays flat,
                        // A deliberate call: there the controls flank a
                        // centred picture, and a wide game or a rotated
                        // arcade board shrinks those gutters until they
                        // really are sitting on it.
                        TouchControlPad(items: layoutItems(landscape: false), send: handleInput, sendStick: handleStick, system: controlLayout.system, material: RaisedControls.isOn, opacity: controlOpacity)
                            .allowsHitTesting(!menuVisible)
                            .frame(height: padHeight)
                            .frame(maxHeight: .infinity, alignment: .bottom)
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }

                if menuVisible {
                    PauseMenu.backdrop
                    pauseMenu
                        .transition(PauseMenu.cardArrives)
                        .zIndex(PauseMenu.cardLayer)
                }
            }
            .overlay(alignment: .top) {
                if let notice {
                    GameNotice(words: notice.words, tone: notice.tone)
                        .id(notice.id)
                        .padding(.top, 12)
                        .transition(.opacity)
                        .allowsHitTesting(false)
                }
            }
        }
        .background(Color.black.ignoresSafeArea())
        // Tell the server this game is being played: the heartbeat is
        // presence, repeated as a liveness signal. Without it a natively played game never reached Home's
        // resume list or RomM's own, since nothing else on the native path
        // ever tells the server a session happened. There is no gate: by
        // the time this screen exists the game is loaded and running.
        .task {
            if startedAt == nil { startedAt = Date() }
            saves?.seat(renderer)
            renderer.awaitingSaveRAM = false
            if let words = saves?.notice {
                say(words, words == GameSaves.couldNotUseNewest ? .problem : .info)
            }
            while !Task.isCancelled {
                await session.reportPlaying(romId: rom.id)
                try? await Task.sleep(for: .seconds(60))
            }
        }
        // The save's picture: the battery looked at once a second while the
        // game runs (GameSaves.look). Battery cores only.
        .task {
            guard holdsForBattery else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                saves?.look(renderer)
            }
        }
        .onAppear {
            // The manager is started here, not assumed started: a fresh
            // launch straight into a game once left every controller silent.
            GameControllerManager.shared.start()
            // N64 needs its own base bindings; see ControllerBindings.n64.
            GameControllerManager.shared.activePlatform = platform.rawValue
            // Offer this game to a television if one is attached. Harmless
            // when none is: the window that reads this does not exist, and
            // showsGameExternally stays false, so the phone draws as it
            // always has. See ExternalDisplay.swift.
            ExternalDisplay.shared.renderer = renderer
            // A running game is being watched even when nothing touches the screen, and with a physical
            // controller nothing ever does. Without this the screen dims
            // and locks mid-game.
            UIApplication.shared.isIdleTimerDisabled = true
            // A Game & Watch plays in its artwork's own orientation,
            // a deliberate call: the tap surface needs the picture large,
            // and a wide unit held tall is neither. The lock releases
            // with the player.
            if let spec = gwSpec {
                if spec.isLandscape { OrientationLock.lockToLandscape() }
                else { OrientationLock.lockToPortrait() }
            }
            previousControllerSend = GameControllerManager.shared.send
            previousControllerStick = GameControllerManager.shared.sendStick
            previousControllerMenu = GameControllerManager.shared.onMenu
            previousControllerDisconnect = GameControllerManager.shared.onDisconnect
            GameControllerManager.shared.send = { [weak renderer] player, id, down in
                renderer?.setButton(id, down: down, port: player)
            }
            // The continuous form, alongside the digitized d-pad bits
            // .send already carries: N64 and Dreamcast read this. FBNeo
            // also asks for it (a "fake analog" fallback in its own input
            // code) and is deliberately refused in LibretroFrontend's
            // inputState; see the comment there and cabinet#3.
            GameControllerManager.shared.sendStick = { [weak renderer] player, x, y in
                renderer?.setStick(x: Double(x), y: Double(y), port: player)
            }
            GameControllerManager.shared.onMenu = { openMenu() }
            // Nobody is holding anything after a disconnect, so pause into
            // the menu rather than letting the game run on unattended.
            // Player 1 losing their pad stops the game, since the person
            // who can drive the menu is now holding nothing. Player 2
            // dropping leaves player 1 playing: pausing on them would
            // interrupt a game the remaining player can still control.
            GameControllerManager.shared.onDisconnect = { player in
                if player == 0 { openMenu() }
            }
            renderer.pendingState = initialState
            // Held before the first frame ever runs, until the battery is
            // seated (GameSaves.seat, in the task above), whichever of the
            // two runs first.
            renderer.awaitingSaveRAM = holdsForBattery && !(saves?.seated ?? true)
            renderer.shader = NativeShader.current(for: platform)
            // Two screens with the hinge break, melonDS only; false
            // leaves every other core's draw path untouched. See
            // DSScreenLayout.swift.
            renderer.dsDualScreen = core == .melonDS
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            // Release the artwork-orientation lock a Game & Watch took.
            if platform == .gameAndWatch { OrientationLock.unlock() }
            // Take the picture back off the television. Guarded the same
            // way the platform claim below is, so a second game's view
            // that has already claimed it keeps it.
            if ExternalDisplay.shared.renderer === renderer {
                ExternalDisplay.shared.renderer = nil
                ExternalDisplay.shared.isPaused = false
            }
            // Guarded: if another game's view already claimed the
            // platform (lifecycle interleave), its claim stands.
            if GameControllerManager.shared.activePlatform == platform.rawValue {
                GameControllerManager.shared.activePlatform = nil
            }
            GameControllerManager.shared.send = previousControllerSend
            GameControllerManager.shared.sendStick = previousControllerStick
            GameControllerManager.shared.onMenu = previousControllerMenu
            GameControllerManager.shared.onDisconnect = previousControllerDisconnect
            // The session POST is what stamps last played; the heartbeat
            // alone is not history. Handed to Session as a trackable task
            // so Home's refresh can wait for it instead of racing it.
            if let startedAt {
                session.reportPlaySessionEnded(romId: rom.id, start: startedAt, end: Date())
            }
            // The core gets a real shutdown at quit, the way RetroArch
            // closes content, instead of lingering loaded until the next
            // launch's lazy teardown: retro_unload_game is the one moment
            // file-writing cores flush their saves (Sega CD's bram_save,
            // Neo Geo Pocket's flash_commit, FBNeo's NVRAM and high
            // scores), and the lazy unload used to fire after the
            // directory those flushes wrote into was already deleted.
            // Runs after the pause capture above has already snapshotted
            // memory-API save RAM, mirroring RetroArch's own close order
            // (SRAM save, then core_unload_game). Safe against the draw
            // loop: runFrame and the snapshot methods all guard on the
            // loaded flag this clears. The battery is read first, while
            // the core still holds it; a core's own file after, once the
            // unload has made it write.
            saves?.gatherBattery(renderer)
            LibretroFrontend.shared.unloadGame()
            saves?.gatherFiles()
            saves?.leave(session: session)
            // An un-kept game's downloaded files have no life after the
            // session; a kept game's live elsewhere and survive this.
            NativeLauncher.cleanUpTempDirectories()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                renderer.paused = true
                leaveInBackground()
            } else if phase == .active && !menuVisible {
                renderer.paused = false
            }
        }
    }

    /// The pause menu's card, 280pt wide, with a "Paused" subtitle, over
    /// PauseMenu.backdrop. Quit leads, in the spot a stray tap is cheapest;
    /// Resume trails, in the spot a reaching thumb naturally lands.
    private var pauseMenu: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text(rom.displayName)
                    .font(.headline)
                    .lineLimit(1)
                Text("Paused")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                Button(role: .destructive) {
                    dismiss()
                } label: {
                    Label("Quit", systemImage: "xmark")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                Menu {
                    ForEach(NativeShader.available(for: platform)) { candidate in
                        Button {
                            renderer.shader = candidate
                            NativeShader.setCurrent(candidate, for: platform)
                        } label: {
                            if candidate == renderer.shader {
                                Label(candidate.label, systemImage: "checkmark")
                            } else {
                                Text(candidate.label)
                            }
                        }
                    }
                } label: {
                    Label("Shader", systemImage: "camera.filters")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                // Game & Watch has no save states (the core cannot
                // serialize), so the slots hide rather than fail.
                if platform.supportsSaveStates {
                Button {
                    saveState()
                } label: {
                    Label("Save state", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                Button {
                    loadLatestState()
                } label: {
                    Label("Load latest state", systemImage: "arrow.uturn.backward")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                }
                Button {
                    closeMenu()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: 280)
        .padding(24)
        .pauseMenuCard()
        .padding(40)
        .disabled(menuBusy)
    }

    /// Mirrors RomM's own player's naming exactly (RomM 5.1.0's
    /// buildStateName): the rom's short name plus an ISO timestamp with
    /// colons and dots flattened to dashes, T to a space, Z dropped.
    private func stateFileStem() -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let stamp = formatter.string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
            .replacingOccurrences(of: "T", with: " ")
            .replacingOccurrences(of: "Z", with: "")
        return "\(rom.fsNameNoExt) [\(stamp)]"
    }

    /// A STATE IS WRITTEN ON THE PHONE FIRST, for every game, and marked
    /// owed in the game's push (GameSaves.keepState): no connection, and no
    /// end of the app, loses it. It goes up inside the game's snapshot when
    /// the game is left. "State saved", the TV's words, in the pill.
    private func saveState() {
        guard let saves, let state = LibretroFrontend.shared.serializeState() else {
            say("Couldn't save a state", .problem)
            return
        }
        // Taken while the pause menu still holds the exact frame being saved.
        let screenshot = renderer.screenshotPNG()
        if saves.keepState(state, picture: screenshot, stem: stateFileStem()) {
            say(GameSaves.stateSaved, .done)
        } else {
            say("Couldn't save a state", .problem)
        }
    }

    /// The newest of the three states the game offers (GameSaves.offeredStates):
    /// RomM's with a connection, else the phone's own.
    private func loadLatestState() {
        menuBusy = true
        Task {
            let offered = await GameSaves.offeredStates(romId: rom.id, tag: core.emulatorTag, session: session)
            defer { menuBusy = false }
            guard let newest = offered.first else {
                say("No saved state for this game", .problem)
                return
            }
            guard let bytes = await GameSaves.stateBytes(newest, session: session) else {
                say("Couldn't reach RomM", .problem)
                return
            }
            if LibretroFrontend.shared.unserializeState(bytes) {
                closeMenu()
            } else {
                say("Couldn't load that state", .problem)
            }
        }
    }

    /// A notice, as long as it takes to read: the TV's rule, 1.5 s and 60 ms
    /// a character, from 2.5 s to 4.5 s. One at a time: a newer one takes
    /// the pill's place, and an older one's clock never ends the newer.
    private func say(_ words: String, _ tone: GameNotice.Tone) {
        let shown = GameNotice.Shown(words: words, tone: tone)
        withAnimation { notice = shown }
        let seconds = min(max(1.5 + 0.06 * Double(words.count), 2.5), 4.5)
        Task {
            try? await Task.sleep(for: .seconds(seconds))
            if notice?.id == shown.id { withAnimation { notice = nil } }
        }
    }
}

/// HOW THE PAUSE MENU COMES AND GOES, the TV's numbers (CabinetOS's
/// panels.h, kOverlayFade, and pausemenu.cpp): 620 ms on the design
/// system's cubic ease-in-out, the card rising slightly as it arrives and
/// sinking as it leaves. The TV tuned them with MMagTech on 2026-09-22:
/// 350 ms read as the menu arriving "in pieces", which turned out to be
/// speed, and an ease-out exit snaps away at the end. The phone's 200 ms
/// ease-out looked abrupt for the same reasons (2026-11-26).
///
/// Nothing else on screen moves or leaves: the touch controls stay where
/// they are, under a backdrop dark enough that they read as background,
/// and the card has a light edge and a shadow so it never reads as one
/// shape with the D-pad it can sit over in portrait (seen on an iPhone Air
/// in Pokemon Red). The controls fading out with the menu instead was
/// tried the same day and looked abrupt: they left, and came back after
/// the game was already running again. The VMU player's menu
/// (VMUPlayerView) uses the same, so every player's menu comes and goes
/// alike.
enum PauseMenu {
    static var fade: Animation { .timingCurve(0.65, 0, 0.35, 1, duration: 0.62 * slow) }
    /// `-cabinetMenuSlow 10` in a debug build stretches the fade so it can be
    /// watched in slow motion (PauseMenuBench), as the TV's menu fade flag does.
    private static var slow: Double {
        #if DEBUG
        let asked = UserDefaults.standard.double(forKey: "cabinetMenuSlow")
        return asked > 0 ? asked : 1
        #else
        return 1
        #endif
    }
    static let dim = 0.7
    /// The TV's 24 of its 1,080 rows, near enough the same share of a
    /// phone's height.
    static let rise: CGFloat = 20

    /// Each with its own place in the stack: a view leaving a ZStack with
    /// no zIndex is dropped at once instead of animated out, so Resume
    /// cut the menu away in one frame (photographed in PauseMenuBench,
    /// 2026-11-26).
    static var backdrop: some View {
        Color.black.opacity(dim)
            .ignoresSafeArea()
            .transition(.opacity)
            .zIndex(1)
    }

    static let cardLayer: Double = 2

    static var cardArrives: AnyTransition {
        .opacity.combined(with: .offset(y: rise))
    }
}

extension View {
    /// The pause menu's card, SOLID, NOT GLASS, as the TV's (CabinetOS's
    /// pausemenu.cpp): a dark fill with a light edge and a shadow, drawn as
    /// one flattened picture so the whole card fades as one. With iOS's
    /// material and each piece fading on its own, the blue Resume button
    /// arrived well ahead of the card and the backdrop (photographed in
    /// PauseMenuBench, 2026-11-26). Always dark, like the game around it.
    func pauseMenuCard() -> some View {
        background(Color(white: 0.165), in: .rect(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))
            .environment(\.colorScheme, .dark)
            .compositingGroup()
            .shadow(color: .black.opacity(0.4), radius: 16, y: 6)
    }
}

/// WHAT THE GAME SAYS OVER ITSELF: the start's notice (GameSaves.notice) and
/// the pause menu's answers, the TV's pill in the phone's own look. iOS's
/// thick glass in its dark form, so it reads the same over a Game Boy's
/// white screen and a dark one, and the TV's dot before the words, its
/// colour saying which kind of answer it is (CabinetOS's notice.cpp): white
/// for news, the TV's cyan for something done, its amber for a problem.
/// The pause menu's answers were a line inside the menu's card, which grew
/// and pushed its buttons down; the TV moved the same line out of its menu
/// into the pill on 2026-09-23.
struct GameNotice: View {
    enum Tone { case info, done, problem }

    /// One showing of a notice: the same words twice are two showings.
    struct Shown: Equatable {
        let words: String
        let tone: Tone
        let id = UUID()
    }

    let words: String
    let tone: Tone

    private var dot: Color {
        switch tone {
        case .info: return Color.white.opacity(0.7)
        case .done: return Color(red: 0x58 / 255.0, green: 0xE8 / 255.0, blue: 0xF6 / 255.0)
        case .problem: return Color(red: 1.0, green: 0xC4 / 255.0, blue: 0x57 / 255.0)
        }
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(dot)
                .frame(width: 7, height: 7)
            Text(words)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.ultraThickMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5))
        .environment(\.colorScheme, .dark)
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
    }
}

#if DEBUG
/// The pause menu coming and going over a Game Boy's white screen and a
/// stand-in D-pad, on its own (`-cabinetPauseMenuBench`, RommApp), so its
/// fade can be watched and photographed in a simulator, where no game can
/// start; `-cabinetMenuSlow 10` slows it. The card is built the way the
/// player's is: the same modifiers and the same button styles.
struct PauseMenuBench: View {
    @State private var shown = false

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                Color(white: 0.97)
                ZStack {
                    Color.black
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(white: 0.22))
                        .frame(width: 150, height: 50)
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(white: 0.22))
                        .frame(width: 50, height: 150)
                }
            }
            .ignoresSafeArea()
            if shown {
                PauseMenu.backdrop
                card.transition(PauseMenu.cardArrives).zIndex(PauseMenu.cardLayer)
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                withAnimation(PauseMenu.fade) { shown.toggle() }
                try? await Task.sleep(for: .seconds(12))
            }
        }
    }

    private var card: some View {
        VStack(spacing: 18) {
            VStack(spacing: 4) {
                Text("Pokemon Red Version").font(.headline).lineLimit(1)
                Text("Paused").font(.caption).foregroundStyle(.secondary)
            }
            VStack(spacing: 10) {
                Button(role: .destructive) {} label: {
                    Label("Quit", systemImage: "xmark").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                Button {} label: {
                    Label("Save state", systemImage: "square.and.arrow.down").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                Button {} label: {
                    Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: 280)
        .padding(24)
        .pauseMenuCard()
        .padding(40)
    }
}

/// The game's notices on their own, for judging them without starting a
/// game (`-cabinetNoticeGallery`, RommApp): one of each tone over a Game
/// Boy's white screen and over a dark one, where the player draws them.
struct NoticeGallery: View {
    var body: some View {
        VStack(spacing: 0) {
            panel(Color(white: 0.97), GameSaves.continuingElsewhere, .info)
            panel(Color(white: 0.97), GameSaves.stateSaved, .done)
            panel(Color(white: 0.97), GameSaves.couldNotUseNewest, .problem)
            panel(Color(white: 0.10), GameSaves.continuingElsewhere, .info)
            panel(Color(white: 0.10), GameSaves.stateSaved, .done)
            panel(Color(white: 0.10), GameSaves.couldNotUseNewest, .problem)
        }
        .background(Color.black)
        .ignoresSafeArea()
    }

    private func panel(_ screen: Color, _ words: String, _ tone: GameNotice.Tone) -> some View {
        screen
            .overlay(alignment: .top) {
                GameNotice(words: words, tone: tone)
                    .padding(.top, 40)
            }
    }
}
#endif

/// The DS bottom screen as a touch surface, layered over the Metal view
/// when melonDS runs. Occupies exactly DSScreenLayout's bottom-screen
/// rect, so a finger on the picture is a stylus on the touchscreen and
/// a finger anywhere else falls through to the control pad beneath.
/// Drags that wander off the screen's edge clamp to it (see
/// DSScreenLayout.pointer) until the finger lifts, the way a stylus
/// pressed against the bezel would keep contact.
private struct DSTouchScreenView: View {
    let sendPointer: (_ x: Double, _ y: Double, _ down: Bool) -> Void

    var body: some View {
        GeometryReader { geo in
            let rect = DSScreenLayout.bottomScreenRect(in: geo.size)
            if rect.width > 0, rect.height > 0 {
                Color.clear
                    .contentShape(Rectangle())
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .gesture(
                        DragGesture(minimumDistance: 0, coordinateSpace: .named("dsPlayerSurface"))
                            .onChanged { g in
                                let p = DSScreenLayout.pointer(for: g.location, in: geo.size)
                                sendPointer(Double(p.x), Double(p.y), true)
                            }
                            .onEnded { g in
                                let p = DSScreenLayout.pointer(for: g.location, in: geo.size)
                                sendPointer(Double(p.x), Double(p.y), false)
                            }
                    )
            }
        }
        .coordinateSpace(name: "dsPlayerSurface")
    }
}
