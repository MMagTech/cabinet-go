import SwiftUI

/// The screen between picking a game and playing it, built natively.
///
/// RomM's own player page already does this job, and the game itself still
/// runs there. What this replaces is only the presentation: the choices are
/// gathered here in a screen that follows iOS conventions and lays out for
/// the shape of the display, then handed to RomM through the same
/// localStorage keys its page reads on load.
///
/// That is the whole coupling. Nothing here reimplements core selection, ROM
/// streaming, save handling or emulation. If a future RomM renames a key, the
/// value is ignored and its page falls back to its own defaults, which is
/// exactly the behaviour before this screen existed.
struct GameLaunchView: View {
    @ObservedObject private var compatibility = Compatibility.shared
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue
    private var labelSource: PlatformLabelSource {
        PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName
    }
    let rom: Rom

    @EnvironmentObject private var session: Session
    @Environment(\.dismiss) private var dismiss

    /// Whether this game has an emulator config worth offering to
    /// throw away; see resetSettingsCard.
    @State private var hasCoreSettings = false
    @State private var playingNative = false
    @State private var nativeInitialState: Data?
    @State private var firmware: [Firmware] = []
    /// Firmware the server knows about but cannot actually serve: the entry
    /// exists, the file behind it is gone. Silently hiding these looked
    /// like the platform needed no BIOS at all, and the first sign of
    /// trouble was a game booting to black.
    @State private var missingFirmware: [Firmware] = []
    @State private var saves: [GameSave] = []
    @State private var states: [GameState] = []
    @State private var selectedSave: GameSave?
    @State private var selectedState: GameState?
    /// Only the three most recent states show without asking, since a
    /// filename told nobody anything and a long list of them was the
    /// actual reason this card needed thumbnails and dates at all.
    @State private var showAllStates = false
    @State private var deletingAssetIds: Set<Int> = []
    @State private var viewingScreenshot: ScreenshotTarget?

    private struct ScreenshotTarget: Identifiable {
        let id = UUID()
        let path: String?
        let title: String
    }
    @State private var pendingStateDelete: GameState?
    @State private var pendingSaveDelete: GameSave?
    @State private var loading = true
    @State private var preparingPlay = false
    /// The native download's fraction complete, shown as a percentage on
    /// the launch button in place of an indeterminate spinner: a bare
    /// spinner gives no signal on a large title, indistinguishable from a
    /// stall, on a phone connection that can take a while for a multi-GB
    /// PS1 disc.
    @State private var downloadProgress: Double = 0
    @State private var playError: String?
    /// The platform's canonical slug, resolved once here and threaded to
    /// everything downstream that needs it, rather than recomputed
    /// piecemeal. See `Rom.canonicalPlatformSlug`.
    @State private var canonicalSlug = ""
    /// A keyboard machine, not a gamepad one. See ComputerPlatforms: this
    /// app does not offer touch play for these, on purpose, not yet.
    @State private var isComputerPlatform = false
    @State private var togglingFavorite = false
    @State private var favoriteError: String?
    @ObservedObject private var keptStore = KeptGameStore.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @StateObject private var exporter = RomExporter()
    @State private var showingExportSheet = false
    /// Whatever export was last attempted, so Retry repeats the same one
    /// (ROM alone, ROM and BIOS, or BIOS alone) rather than only ever
    /// retrying the plain ROM case.
    @State private var retryExport: (() -> Void)?

    /// The VMU row's state, Dreamcast only: a GAME-type file on this
    /// game's memory card is a minigame the game downloaded there, and
    /// the row is the one door to playing it (the VMU is never a
    /// platform, never in the library). Detection parses the same card
    /// the boot would open, prefetched so a card saved on another
    /// device counts.
    @State private var vmuMinigame: String?
    @State private var vmuPreparing = false
    @State private var playingVMU = false
    @State private var vmuCardURL: URL?

    /// Whether the scroll content is resting at its top, the only moment a
    /// downward drag should be read as "dismiss" rather than "scroll".
    @State private var isScrolledToTop = true
    /// How far the whole screen has been dragged down, for the
    /// hand-rolled swipe-to-dismiss below: `fullScreenCover`, unlike
    /// `sheet`, has no interactive dismiss gesture of its own.
    @State private var dragOffset: CGFloat = 0

    private static let dismissThreshold: CGFloat = 120

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ScrollView {
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: ScrollOffsetKey.self, value: proxy.frame(in: .named("gameLaunchScroll")).minY
                    )
                }
                .frame(height: 0)

                if landscape {
                    // A short wide screen has width to spare and almost no
                    // height, so the option cards sit side by side rather
                    // than stacking into a column that needs scrolling.
                    // Identity sits on the left where the eye starts; the
                    // action leads the column beside it, full width, where
                    // a primary button has room to read as one.
                    HStack(alignment: .top, spacing: 20) {
                        // Identity on the left, choices and the action on
                        // the right. The cover stays small because a
                        // landscape phone leaves roughly 318 points once the
                        // navigation bar and padding take theirs.
                        VStack(spacing: 10) {
                            cover(maxWidth: 115)
                            titleBlock(centred: true)
                        }
                        .frame(width: 170)

                        VStack(spacing: 12) {
                            // The action leads the column, matching
                            // portrait's order exactly: identity, Play,
                            // then the options. It had drifted below the
                            // option cards here while portrait kept it
                            // beside the title (reported 2026-08-20).
                            if loading || isPlayableHere { playButton }

                            if showsKeepCard { keepCard }

                            // No dead button on unsupported systems (the
                            // playButton guard above): the library section,
                            // the platform label and the storage-only card
                            // already say everything a permanently grey
                            // "Unsupported" restated. Game-level states on
                            // supported systems keep the live button.
                            if isComputerPlatform { computerPlatformCard }
                            downloadStatusCard
                            vmuCard
                            compatibilityCard
                            resetSettingsCard
                            if !states.isEmpty || !saves.isEmpty { resumeCard }
                        }
                        .frame(maxWidth: .infinity, alignment: .top)
                    }
                    .padding(20)
                } else {
                    VStack(spacing: 20) {
                        cover(maxWidth: 200)
                        titleBlock(centred: true)
                        if loading || isPlayableHere { playButton }
                        options
                    }
                    .padding(20)
                }
            }
            .coordinateSpace(name: "gameLaunchScroll")
            .onPreferenceChange(ScrollOffsetKey.self) { isScrolledToTop = $0 >= -1 }
            .offset(y: dragOffset)
            .simultaneousGesture(dismissDragGesture)
        }
        .background { ambientBackdrop }
        // Music's Now Playing rule: while artwork is the backdrop the
        // screen styles itself dark regardless of the system setting, so
        // labels and cards read over the art instead of fighting it. A
        // game with no cover keeps the plain grouped background and the
        // system's own appearance. Applied here, before the sheet and
        // cover modifiers below, so presented screens keep the system
        // appearance rather than inheriting the override.
        .environment(\.colorScheme, hasAmbientArt ? .dark : systemColorScheme)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                routeIndicator
            }
            ToolbarItem(placement: .topBarTrailing) {
                exportButton
            }
            ToolbarItem(placement: .topBarTrailing) {
                favoriteButton
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Close") { dismiss() }
            }
        }
        .sheet(isPresented: Binding(
            get: { exporter.exportURLs != nil }, set: { if !$0 { exporter.finishExport() } }
        )) {
            if let urls = exporter.exportURLs {
                DocumentExporter(urls: urls) { exporter.finishExport() }
            }
        }
        .task { await load() }
        .onAppear { refreshCoreSettings() }
        .fullScreenCover(isPresented: $playingNative) {
            if let core = NativeCore.core(for: rom, canonicalSlug: canonicalSlug) {
                NativePlayerView(rom: rom, core: core, initialState: nativeInitialState)
                    .environmentObject(session)
            }
        }
        .fullScreenCover(isPresented: $playingVMU) {
            if let vmuCardURL {
                VMUPlayerView(rom: rom, cardURL: vmuCardURL)
                    .environmentObject(session)
            }
        }
        // One alert serves every way a launch can fail, so its title must
        // not claim to know which way: it used to say "Couldn't load that
        // state" while showing a retro_load_game failure, which pointed
        // the first real MAME bug report at save states instead of the
        // romset.
        .alert(
            "Couldn't start the game",
            isPresented: Binding(get: { playError != nil }, set: { if !$0 { playError = nil } })
        ) {
            Button("OK") { playError = nil }
        } message: {
            Text(playError ?? "")
        }
        .sheet(item: $viewingScreenshot) { target in
            ScreenshotViewer(path: target.path, title: target.title)
        }
    }

    // MARK: Pieces

    /// Which address this screen's downloads will actually use, shown only
    /// to someone who has set a second one and therefore has a choice to
    /// know about. Everyone else sees nothing at all.
    ///
    /// It lives here rather than in Settings' own row because the download
    /// happens here, and it matters beyond speed: a home connection can be
    /// metered, and a round trip out to the internet and back spends that
    /// allowance twice for bytes that never had to leave the house. A
    /// glance is enough, which is why this is a plain status icon and not
    /// a warning. It says local just as readily as it says internet, so it
    /// reads as information rather than something being wrong.
    ///
    /// A router, deliberately not a house: the tab bar already spends a
    /// house on Home, and two houses meaning different things is worse than
    /// no icon. The title stays on the Label even though the toolbar
    /// renders it icon only, so VoiceOver still reads it.
    @ViewBuilder
    private var routeIndicator: some View {
        if session.localServerURL != nil {
            Label(
                playWillUseLocalNetwork ? "Local network" : "Internet",
                systemImage: playWillUseLocalNetwork ? "wifi.router" : "globe"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
    }

    /// Whether pressing Play right now keeps its traffic on the local
    /// network. The player always downloads through this app, so it
    /// follows the address this app is using like everything else.
    ///
    /// This is also the whole of the nudge. Somebody watching a globe turn
    /// into a router the moment they switch Download on has been told what
    /// that toggle is worth, without a word of explanation on screen.
    private var playWillUseLocalNetwork: Bool {
        session.isUsingLocalAddress
    }

    /// A star, not a card: this is a status toggle someone glances at and
    /// taps in passing, not a decision that needs its own explanation on
    /// the screen.
    private var favoriteButton: some View {
        Button {
            let romId = rom.id
            togglingFavorite = true
            Task {
                do {
                    try await session.toggleFavorite(romId: romId)
                } catch {
                    favoriteError = error.localizedDescription
                }
                togglingFavorite = false
            }
        } label: {
            Image(systemName: session.isFavorite(romId: rom.id) ? "heart.fill" : "heart")
                .foregroundStyle(session.isFavorite(romId: rom.id) ? .pink : .primary)
        }
        .disabled(togglingFavorite)
        .alert(
            "Couldn't update favorites",
            isPresented: Binding(get: { favoriteError != nil }, set: { if !$0 { favoriteError = nil } }),
            presenting: favoriteError
        ) { _ in
            Button("OK") { favoriteError = nil }
        } message: { message in
            Text(message)
        }
    }

    /// The single source of truth for whether this app can put the game on
    /// screen at all: `PlatformSupport.isSupported`, the same check that
    /// decides the library's Supported/Unsupported split. Reused here so
    /// Play cannot stay live for a platform the library already calls
    /// unsupported, the zero-core dead end this download feature replaces.
    /// Calls through rather than re-deriving `!isComputerPlatform &&
    /// !cores.isEmpty` locally: that copy silently fell out of sync with
    /// the real check when it grew native-core awareness, exactly the
    /// class of bug a single source of truth is supposed to prevent.
    private var isPlatformSupported: Bool {
        PlatformSupport.isSupported(canonicalSlug: canonicalSlug, isArcade: rom.isArcade)
    }

    /// One visible action, no exceptions: a game with the keep toggle
    /// shows no export button at all. The kept files, firmware included,
    /// are all in the Files app's Games folder, so there is nothing left
    /// for an export menu to offer that the folder does not already
    /// hold. This menu survives only where Keep cannot exist,
    /// unsupported platforms, keyboard machines, multi-file games,
    /// because there it is the only way to the file. Its earlier
    /// BIOS-only remnant on playable games was the last hedge of the
    /// three-eras accretion this redesign removed, and Marcus caught it
    /// within the hour.
    @ViewBuilder
    private var exportButton: some View {
        if !loading, !showsKeepCard {
            Button {
                showingExportSheet = true
            } label: {
                // The share arrow, up and out, never the download arrow:
                // everything behind this button sends bytes away from
                // the app.
                Image(systemName: "square.and.arrow.up")
            }
            // Attached here, not at the screen root: a confirmationDialog
            // anchors its arrow to whatever view carries this modifier, so
            // it has to sit on the actual toolbar button, not the whole
            // screen, or the arrow points at the wrong place.
            .confirmationDialog("Export", isPresented: $showingExportSheet, titleVisibility: .visible) {
                if !firmware.isEmpty {
                    Button("Export ROM and BIOS") { startExport(includeFirmware: true) }
                    // Always offered on its own, not just folded into
                    // the combined button above: if a previously
                    // exported BIOS file gets deleted or moved outside
                    // this app, this is the only way back to it, since
                    // the app has no visibility into Files once a file
                    // has been handed over.
                    Button("Export BIOS") { startFirmwareOnlyExport() }
                }
                Button("Export ROM") { startExport(includeFirmware: false) }
            }
            .onChange(of: exporter.state) { _, state in
                if case .failed(let message) = state {
                    DiagnosticsLog.record(context: "Export", message: message, romVersion: session.serverVersion)
                }
            }
        }
    }

    /// The local files that can satisfy an export without touching the
    /// network, or nil when any requested piece is not already on this
    /// phone, in which case the whole export downloads as before rather
    /// than mixing local and fetched halves.
    private func keptExportURLs(includeFirmware: Bool) -> [URL]? {
        guard !rom.hasMultipleFiles,
              let romURL = keptStore.fileURL(romId: rom.id, fileName: rom.fsName)
        else { return nil }
        guard includeFirmware else { return [romURL] }
        guard let bios = firmware.first,
              let biosURL = keptStore.fileURL(romId: rom.id, fileName: bios.fileName)
        else { return nil }
        return [romURL, biosURL]
    }

    private func startExport(includeFirmware: Bool) {
        retryExport = { [self] in startExport(includeFirmware: includeFirmware) }
        // A kept game's files were downloaded by this app and verified at
        // keep time; exporting them is a copy, not a second download.
        if let urls = keptExportURLs(includeFirmware: includeFirmware) {
            exporter.presentLocal(urls: urls)
            return
        }
        Task {
            do {
                var files: [(request: URLRequest, suggestedName: String)] = []
                var folderName: String?

                if rom.hasMultipleFiles {
                    // RomM's own zip endpoint is broken through the reverse
                    // proxy (scope doc, Open items), so each file is fetched
                    // on its own and exported as a folder instead.
                    let romFiles = try await session.romFiles(romId: rom.id)
                    for file in romFiles {
                        let fileRequest = try await session.romFileContentRequest(romId: rom.id, file: file)
                        files.append((fileRequest, file.fileName))
                    }
                    folderName = rom.fsName
                } else {
                    let romRequest = try await session.romContentRequest(rom)
                    files.append((romRequest, rom.fsName))
                }

                if includeFirmware, let bios = firmware.first {
                    let firmwareRequest = try await session.firmwareContentRequest(bios)
                    files.append((firmwareRequest, bios.fileName))
                }
                exporter.start(files: files, folderName: folderName)
            } catch {
                exporter.fail("Couldn't reach the server.")
            }
        }
    }

    /// The BIOS on its own, reachable any time regardless of whether it was
    /// bundled with a ROM before: the app cannot see whether a file handed
    /// to Files earlier is still there.
    private func startFirmwareOnlyExport() {
        guard let bios = firmware.first else { return }
        retryExport = { [self] in startFirmwareOnlyExport() }
        if let biosURL = keptStore.fileURL(romId: rom.id, fileName: bios.fileName) {
            exporter.presentLocal(urls: [biosURL])
            return
        }
        Task {
            do {
                let firmwareRequest = try await session.firmwareContentRequest(bios)
                exporter.start(files: [(firmwareRequest, bios.fileName)])
            } catch {
                exporter.fail("Couldn't reach the server.")
            }
        }
    }

    @Environment(\.colorScheme) private var systemColorScheme

    private var hasAmbientArt: Bool {
        (rom.pathCoverLarge ?? rom.pathCoverSmall) != nil
    }

    /// Not an app-shell backdrop but this one modal screen, the same
    /// contained place Music blurs album art behind Now Playing. The
    /// game's own cover, blurred past recognition, so the screen carries
    /// the game's colour; the scrim keeps every card and label readable over
    /// whatever the art happens to be. Reuses the exact cover path the
    /// identity block loads, so the image is already in CoverCache.
    @ViewBuilder
    private var ambientBackdrop: some View {
        if hasAmbientArt {
            ZStack {
                Color(.systemGroupedBackground)
                CoverImage(
                    path: rom.pathCoverLarge ?? rom.pathCoverSmall,
                    title: "", showsPlaceholder: false
                )
                // Scaled, not stretched: blur samples past the view's
                // edges, and without the extra pixels the border of the
                // image reads as a vignette.
                .scaleEffect(1.4)
                .blur(radius: 60)
                .saturation(0.8)
                .overlay(Color.black.opacity(0.45))
            }
            .clipped()
            .ignoresSafeArea()
        } else {
            Color(.systemGroupedBackground)
        }
    }

    private func cover(maxWidth: CGFloat) -> some View {
        CoverImage(path: rom.pathCoverLarge ?? rom.pathCoverSmall, title: rom.displayName)
            .aspectRatio(3.0 / 4.0, contentMode: .fit)
            .frame(maxWidth: maxWidth)
            .clipShape(.rect(cornerRadius: 14))
            .shadow(radius: 10, y: 5)
    }

    private func titleBlock(centred: Bool) -> some View {
        VStack(alignment: centred ? .center : .leading, spacing: 4) {
            Text(rom.displayName)
                .font(.title2.bold())
                .multilineTextAlignment(centred ? .center : .leading)
            Text(rom.platformLabel(source: labelSource, platformNames: session.platformNames))
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: centred ? .center : .leading)
    }

    private var playButton: some View {
        Button {
            // Remembering itself already happened the moment the choice was
            // made, see the onChange handlers above.
            Task { await beginPlay() }
        } label: {
            if preparingPlay {
                Text("\(Int(downloadProgress * 100))%")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            } else {
                Label(playLabel, systemImage: isComputerPlatform ? "keyboard" : "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
            }
        }
        .buttonStyle(.borderedProminent)
        .disabled(loading || !isPlatformSupported || preparingPlay)
    }

    private func beginPlay() async {
        await beginNativePlay()
    }

    /// Downloads before presenting the player, so a failure surfaces here
    /// as an alert instead of a black screen with no explanation.
    private func beginNativePlay() async {
        preparingPlay = true
        downloadProgress = 0
        defer { preparingPlay = false }
        do {
            try await NativeLauncher.prepare(rom: rom, session: session) { fraction in
                downloadProgress = fraction
            }
            if let selectedState {
                // The local copy first, not as an offline fallback but
                // as the normal path: when it is the same state, reading
                // it costs nothing and a network round trip would only
                // slow down a game that is already sitting on the phone.
                // A network fetch only happens for a state Keep never
                // cached, which needs a connection either way.
                if let local = keptStore.localState(for: rom.id), local.stateId == selectedState.id {
                    nativeInitialState = local.data
                } else if let pending = keptStore.pendingStates(for: rom.id)
                    .first(where: { $0.stem.hashValue == selectedState.id }),
                    let data = try? Data(contentsOf: pending.stateURL) {
                    // A save still waiting to upload: the only copy of
                    // it is the one on this phone, network or not.
                    nativeInitialState = data
                } else {
                    guard let bytes = try? await session.stateContent(selectedState) else {
                        playError = "Couldn't reach the server to load that state."
                        return
                    }
                    nativeInitialState = bytes
                }
            } else {
                nativeInitialState = nil
            }
            playingNative = true
        } catch {
            playError = error.localizedDescription
        }
    }

    private var playLabel: String {
        if !loading && !isPlatformSupported { return "Unsupported" }
        return selectedState != nil || selectedSave != nil ? "Resume" : "Play"
    }

    /// Why the button above is not a button right now. A keyboard machine
    /// has no fixed pad this app can honestly draw, so it does not try,
    /// rather than offering a control scheme that looks like it works and
    /// does not. Download support, once the app has any, is the planned
    /// way to still get this game, through a real emulator on a real
    /// keyboard instead.
    private var computerPlatformCard: some View {
        LaunchCard(title: "Needs a keyboard", systemImage: "keyboard") {
            Text("This platform is controlled with a keyboard, not a game pad, and this app does not offer that yet. A future version may let you download the ROM to play it in another emulator.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var downloadStatusCard: some View {
        switch exporter.state {
        case .idle:
            EmptyView()
        case .downloading(let fraction, let received, let total):
            LaunchCard(title: "Exporting ROM", systemImage: "square.and.arrow.up") {
                VStack(alignment: .leading, spacing: 8) {
                    if total > 0 {
                        Text("\(byteCount(received)) of \(byteCount(total))")
                            .font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: fraction)
                    } else {
                        ProgressView()
                    }
                    Button("Cancel", role: .destructive) { exporter.cancel() }
                        .font(.callout)
                }
            }
        case .failed(let message):
            LaunchCard(title: "Couldn't export the ROM", systemImage: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 10) {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Dismiss") { exporter.cancel() }
                        Spacer()
                        Button("Retry") { retryExport?() }
                    }
                    .font(.callout)
                }
            }
        }
    }

    private func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    /// A queued save's file date, in the same format a server
    /// `updatedAt` string arrives in, so `RommDate.relativeLabel` reads
    /// it identically either way.
    private static func isoStamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Landscape only: cards flow into as many columns as the width allows,
    /// so two or three of them do not become a scrolling column.
    @ViewBuilder
    private var optionsGrid: some View {
        if loading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading options").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            LazyVGrid(
                // 210 rather than 250: the space left beside the cover is
                // about 500 points, and 250 wide columns fit only once, which
                // stacked the cards and stretched each to hold two words.
                columns: [GridItem(.adaptive(minimum: 210), spacing: 12, alignment: .top)],
                alignment: .leading,
                spacing: 12
            ) {
                if isComputerPlatform { computerPlatformCard }
                downloadStatusCard
                // Unsupported platforms have always left a way to the
                // file so it can be played in another emulator, and Keep
                // is that way here: the game and its BIOS land in the
                // Files app's Games folder.
                if showsKeepCard { keepCard }
                vmuCard
                resetSettingsCard
                if !states.isEmpty || !saves.isEmpty { resumeCard }
            }
        }
    }

    @ViewBuilder
    private var options: some View {
        if loading {
            HStack(spacing: 10) {
                ProgressView()
                Text("Loading options").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 14) {
                if isComputerPlatform { computerPlatformCard }
                downloadStatusCard
                // Unsupported platforms have always left a way to the
                // file so it can be played in another emulator, and Keep
                // is that way here: the game and its BIOS land in the
                // Files app's Games folder.
                if showsKeepCard { keepCard }
                vmuCard
                resetSettingsCard
                if !states.isEmpty || !saves.isEmpty { resumeCard }
            }
        }
    }

    /// The way out of a game whose emulator settings have gone bad.
    /// MAME writes DIP switches and input assignments per game when a
    /// game exits and reapplies them at every launch, so one bad value
    /// used to mean a permanently unplayable game with no recourse
    /// inside the app. Cabinet keeps MAME's own menu shut now, but
    /// devices poisoned before that fix still need this, and so would
    /// any future core with the same habit.
    ///
    /// Only shown when there is something to remove, so it is silent on
    /// almost every game, and pressing it makes the card go, because
    /// the config it offered to delete is gone.
    @ViewBuilder
    private var resetSettingsCard: some View {
        if hasCoreSettings, let core = NativeCore.core(for: rom, canonicalSlug: canonicalSlug) {
            // Not "Emulator settings": that reads global, and Cabinet has
            // a genuinely global one in Settings > Native cores. What
            // this clears is the emulator's own config for this one
            // game.
            LaunchCard(title: "Troubleshoot", systemImage: "wrench.and.screwdriver") {
                VStack(alignment: .leading, spacing: 10) {
                    Button("Reset", role: .destructive) {
                        NativeLauncher.resetCoreSettings(romId: rom.id, core: core)
                        hasCoreSettings = false
                    }
                    .font(.callout)
                    Text("Clears this game's emulator settings. Saves are kept.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func refreshCoreSettings() {
        guard let core = NativeCore.core(for: rom, canonicalSlug: canonicalSlug) else {
            hasCoreSettings = false
            return
        }
        hasCoreSettings = NativeLauncher.hasCoreSettings(romId: rom.id, core: core)
    }

    /// The way into the minigame this game downloaded onto its memory
    /// card. Boots the card itself in the VMU player; progress writes
    /// straight back into the same save the Dreamcast session uses, so
    /// there is nothing to pick and nothing to manage. Deliberately not
    /// behind the experimental-cores gate: the VMU core is not the
    /// gated Dreamcast core, and the card is real whether or not DC
    /// itself may launch here today.
    @ViewBuilder
    private var vmuCard: some View {
        if let name = vmuMinigame {
            LaunchCard(title: "VMU", systemImage: "memorychip") {
                VStack(alignment: .leading, spacing: 10) {
                    Button {
                        startVMUPlay()
                    } label: {
                        if vmuPreparing {
                            ProgressView()
                        } else {
                            Text("Play \(name)")
                        }
                    }
                    .font(.callout)
                    .disabled(vmuPreparing)
                }
            }
        }
    }

    private func startVMUPlay() {
        vmuPreparing = true
        Task {
            let url = await VMULauncher.prepare(rom: rom, session: session)
            vmuPreparing = false
            guard let url else {
                playError = "The memory card couldn't be placed for the VMU."
                return
            }
            vmuCardURL = url
            playingVMU = true
        }
    }

    /// Says what is known about this game running here, and never more
    /// than one thing: either it has been marked, or the app has watched
    /// it die enough times to raise the subject. Silent otherwise, which
    /// is almost always.
    @ViewBuilder
    private var compatibilityCard: some View {
        if compatibility.isMarked(rom.id) {
            LaunchCard(title: "Marked as incompatible", systemImage: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("You marked this game as incompatible on this phone. It will still play if you want to try again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Mark as compatible") {
                        compatibility.setMarked(false, romId: rom.id)
                    }
                    .font(.callout)
                }
            }
        } else if compatibility.shouldSuggestMark(romId: rom.id) {
            LaunchCard(title: "This game keeps closing", systemImage: "exclamationmark.triangle") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("It has closed itself \(compatibility.crashes(romId: rom.id)) times on this phone while playing. Some games do not run well here.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button("Mark as incompatible") {
                        compatibility.setMarked(true, romId: rom.id)
                    }
                    .font(.callout)
                }
            }
        }
    }

    /// One storage toggle for every game, playable or not; only the
    /// promise in the fine print varies. Unsupported systems included
    /// on purpose: those are exactly the games whose files someone
    /// wants for another emulator, and the toggle-into-Files flow
    /// serves that better than an export picker. Native-capable games
    /// mirror `NativeLauncher.prepare`'s own gates (a Saturn game that
    /// is not a single-file chd gets no toggle rather than a kept copy
    /// nothing can boot). The one true gate left is multi-file ROMs,
    /// which the download machinery cannot fetch yet; they keep the
    /// export menu until keep learns multi-file, a capability gap with
    /// a named successor, not a design carve-out.
    private var showsKeepCard: Bool {
        if let core = NativeCore.core(for: rom, canonicalSlug: canonicalSlug) {
            if core == .beetleSaturn {
                return !rom.hasMultipleFiles && rom.fsName.lowercased().hasSuffix(".chd")
            }
            return true
        }
        return !rom.hasMultipleFiles
    }

    /// Whether this app can put the game on screen in any player, which
    /// decides whether the storage captions may promise play at all.
    private var isPlayableHere: Bool {
        NativeCore.core(for: rom, canonicalSlug: canonicalSlug) != nil || isPlatformSupported
    }

    private var keepBinding: Binding<Bool> {
        Binding(
            get: { keptStore.kept(romId: rom.id) != nil || keptStore.downloading[rom.id] != nil },
            set: { wantKept in
                if wantKept {
                    keptStore.keep(rom: rom, session: session)
                } else {
                    keptStore.remove(romId: rom.id)
                }
            }
        )
    }

    /// One toggle, one copy: keeping stores the ROM and firmware
    /// permanently, the player boots straight from it, Export copies
    /// from it. Removal
    /// lives on the same toggle, and the Storage screen lists every kept
    /// game in one place.
    private var keepCard: some View {
        // "Storage": the card shares its name and icon with
        // Settings > Storage, two views of the same concept, with the
        // per-game promise in the caption.
        LaunchCard(title: "Storage", systemImage: "internaldrive") {
            let isKept = keptStore.kept(romId: rom.id) != nil
            // No toggle at all once a game is kept and there is no
            // connection: the one action here is destructive, and
            // offline it is permanent until signal returns, exactly the
            // fat-finger risk on a cramped tray table with no way back
            // Marcus flagged. There is no offline use for the freed
            // space either, keeping something else still needs a
            // connection, so nothing real is lost by waiting. Files
            // stays the deliberate path for removing a kept game,
            // untouched by this. A game that is not yet kept keeps its
            // toggle visible, just disabled: starting a download that
            // fails is an annoyance, not a loss, so it is greyed rather
            // than hidden, the same distinction this app draws
            // everywhere else between temporarily and permanently
            // unavailable.
            if !(networkMonitor.isOffline && isKept) {
                Toggle("Download", isOn: keepBinding)
                    .disabled(networkMonitor.isOffline && !isKept)
            }

            if let progress = keptStore.downloading[rom.id] {
                VStack(alignment: .leading, spacing: 8) {
                    if progress.totalBytes > 0 {
                        Text("\(byteCount(progress.receivedBytes)) of \(byteCount(progress.totalBytes))")
                            .font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: min(progress.fraction, 1))
                    } else {
                        ProgressView()
                    }
                }
            } else if isKept {
                Text(keptCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                let pending = keptStore.pendingStateCount(for: rom.id)
                if pending > 0 {
                    Text("\(pending) save\(pending == 1 ? "" : "s") waiting to upload")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if MemoryCardStore.shared.anyPendingUpload(romId: rom.id) {
                    Text("In-game save waiting to upload")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let error = keptStore.errors[rom.id] {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if networkMonitor.isOffline {
                Text("Needs a connection to download.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                Text(keepCaption)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The promise, stated only where it is true: a game this phone plays
    /// plays without a connection once kept. The BIOS is never mentioned,
    /// it comes along as plumbing, and the Files app is not mentioned
    /// either: where the file lives is a learn-once fact the Storage
    /// screen teaches, not a promise worth repeating on every game.
    private var keptCaption: String {
        let size = keptStore.kept(romId: rom.id).map { byteCount($0.totalBytes) } ?? ""
        guard NativeCore.core(for: rom, canonicalSlug: canonicalSlug) != nil else { return "\(size) on this iPhone." }
        return "\(size) on this iPhone. Plays without a connection."
    }

    private var keepCaption: String {
        let size = byteCount(rom.fsSizeBytes)
        guard NativeCore.core(for: rom, canonicalSlug: canonicalSlug) != nil else { return "About \(size)." }
        return "About \(size). Plays without a connection."
    }

    private var visibleStates: [GameState] {
        // Already newest first, see `load()`, so this is exactly the
        // recent handful the card promises.
        showAllStates ? states : Array(states.prefix(3))
    }

    private var resumeCard: some View {
        LaunchCard(title: "Resume from", systemImage: "clock.arrow.circlepath") {
            // States are greyed out when written by a different core, because
            // a memory snapshot cannot be loaded by an emulator that did not
            // make it. Saves survive a core change, so they are never greyed.
            ForEach(visibleStates) { state in
                stateRow(state)
            }
            if states.count > 3, !showAllStates {
                Button("Show all \(states.count) states") { showAllStates = true }
                    .font(.footnote)
                    .padding(.leading, 30)
            }
            ForEach(saves) { save in
                saveRow(save)
            }
        }
        .confirmationDialog(
            "Delete this state?",
            isPresented: Binding(
                get: { pendingStateDelete != nil }, set: { if !$0 { pendingStateDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let state = pendingStateDelete { Task { await deleteState(state) } }
            }
        } message: {
            // The one real consequence, spelled out, rather than a generic
            // warning: deleting the newest state changes what Resume does
            // next time, every other one is just cleanup.
            Text(
                pendingStateDelete?.id == states.first?.id
                    ? "This is what Resume currently loads. Deleting it means Resume will use your next most recent save instead."
                    : "This can't be undone."
            )
        }
        .confirmationDialog(
            "Delete this save?",
            isPresented: Binding(
                get: { pendingSaveDelete != nil }, set: { if !$0 { pendingSaveDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                if let save = pendingSaveDelete { Task { await deleteSave(save) } }
            }
        } message: {
            Text("This can't be undone.")
        }
    }

    private func stateEnabled(_ state: GameState) -> Bool {
        // A core can only restore states its own build wrote.
        let nativeTag = NativeCore.core(for: rom, canonicalSlug: canonicalSlug)?.emulatorTag
        return nativeTag != nil && state.emulator == nativeTag
    }

    private func stateRow(_ state: GameState) -> some View {
        let enabled = stateEnabled(state)
        return HStack(spacing: 10) {
            Button {
                selectedState = selectedState?.id == state.id ? nil : state
                selectedSave = nil
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: selectedState?.id == state.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(
                            selectedState?.id == state.id ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)
                        )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(RommDate.relativeLabel(state.updatedAt)).lineLimit(1)
                        Text(state.emulator.map { "state, \($0)" } ?? "state")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!enabled)
            .opacity(enabled ? 1 : 0.4)
            rowMenu(
                screenshotPath: state.screenshotPath, title: RommDate.relativeLabel(state.updatedAt),
                delete: { pendingStateDelete = state }
            )
        }
        .opacity(deletingAssetIds.contains(state.id) ? 0.4 : 1)
    }

    /// A save the native player loads on its own every launch (a PS1
    /// memory card), rather than one the person picks here. Shown as
    /// information, not a choice: offering a radio button for something
    /// that happens regardless would be a lie.
    private func saveLoadsAutomatically(_ save: GameSave) -> Bool {
        save.emulator == NativeCore.core(for: rom, canonicalSlug: canonicalSlug)?.emulatorTag
    }

    private func saveRow(_ save: GameSave) -> some View {
        let automatic = saveLoadsAutomatically(save)
        return HStack(spacing: 10) {
            Button {
                selectedSave = selectedSave?.id == save.id ? nil : save
                selectedState = nil
            } label: {
                HStack(spacing: 10) {
                    Image(
                        systemName: automatic
                            ? "checkmark.circle"
                            : selectedSave?.id == save.id ? "checkmark.circle.fill" : "circle"
                    )
                    .foregroundStyle(
                        automatic || selectedSave?.id == save.id
                            ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary)
                    )
                    VStack(alignment: .leading, spacing: 1) {
                        Text(RommDate.relativeLabel(save.updatedAt)).lineLimit(1)
                        Text(automatic ? "memory card, loads automatically" : "save")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(automatic)
            rowMenu(
                screenshotPath: save.screenshotPath, title: RommDate.relativeLabel(save.updatedAt),
                delete: { pendingSaveDelete = save }
            )
        }
        .opacity(deletingAssetIds.contains(save.id) ? 0.4 : 1)
    }

    /// A menu button, not `.swipeActions`: this card is a plain stack, not
    /// a `List`, and swipe actions only exist inside one, the pattern iOS
    /// itself reserves for genuine lists of comparable rows, Mail and
    /// Messages among them, not a form of distinct configuration cards like
    /// this screen. A menu is the native answer for a form row, matching
    /// how Settings itself handles a destructive action inline.
    ///
    /// Screenshot is left off the menu entirely when there is none to
    /// show, rather than shown disabled: nothing to act on, nothing to
    /// grey out. The option exists again at all because captures at save
    /// time work now, the frame grabbed on the way into the pause; every
    /// state saved before that fix simply has no screenshot to offer.
    private func rowMenu(
        screenshotPath: String?, title: String, delete: @escaping () -> Void
    ) -> some View {
        Menu {
            if screenshotPath != nil {
                Button("Screenshot", systemImage: "photo") {
                    viewingScreenshot = ScreenshotTarget(path: screenshotPath, title: title)
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive, action: delete)
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
        }
    }

    private func deleteState(_ state: GameState) async {
        deletingAssetIds.insert(state.id)
        defer { deletingAssetIds.remove(state.id) }
        do {
            try await session.deleteStates(ids: [state.id])
            states.removeAll { $0.id == state.id }
            if selectedState?.id == state.id { selectedState = nil }
        } catch {
            DiagnosticsLog.record(
                context: "Delete state", message: error.localizedDescription, romVersion: session.serverVersion
            )
        }
    }

    private func deleteSave(_ save: GameSave) async {
        deletingAssetIds.insert(save.id)
        defer { deletingAssetIds.remove(save.id) }
        do {
            try await session.deleteSaves(ids: [save.id])
            saves.removeAll { $0.id == save.id }
            if selectedSave?.id == save.id { selectedSave = nil }
        } catch {
            DiagnosticsLog.record(
                context: "Delete save", message: error.localizedDescription, romVersion: session.serverVersion
            )
        }
    }

    private func choiceRow(
        label: String, detail: String, selected: Bool, enabled: Bool, tap: @escaping () -> Void
    ) -> some View {
        Button(action: tap) {
            HStack(spacing: 10) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                VStack(alignment: .leading, spacing: 1) {
                    Text(label).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.4)
    }

    // MARK: Data

    private func load() async {
        keptStore.reconcileFilesFolder()
        // A no-op once `platformsVersions` already holds something; a
        // real retry when it doesn't, the exact gap Session's own doc
        // comment on this method names: a launch that reaches a game's
        // screen before that mapping ever loaded computes `canonicalSlug`
        // against the empty fallback, the raw unmapped folder slug, which
        // resolves to no platform and reads as Unsupported for the rest
        // of the screen's life. `LibraryView` already calls this on its
        // own load for the identical reason; this screen never did.
        // Found 2026-08-08 from a video showing a kept arcade game stuck
        // on "Unsupported" until closed and reopened, which only worked
        // because platformsVersions had finished loading by then.
        await session.loadPlatformConfigIfNeeded()
        canonicalSlug = rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions)
        isComputerPlatform = ComputerPlatforms.contains(canonicalSlug)

        // Offline, these three would only ever run out the clock on a
        // timeout: NetworkMonitor already knows the answer without
        // waiting to be told. A kept game still gets a Resume-from row
        // either way, synthesized below from what Keep already
        // downloaded, so skipping the fetch costs it nothing.
        if !NetworkMonitor.shared.isOffline {
            async let firmwareTask = try? session.firmware(platformId: rom.platformId)
            async let savesTask = try? session.saves(romId: rom.id)
            async let statesTask = try? session.states(romId: rom.id)

            let allFirmware = await firmwareTask ?? []
            firmware = allFirmware.filter { !$0.missingFromFS }
            missingFirmware = allFirmware.filter { $0.missingFromFS }
            saves = await savesTask ?? []
            states = (await statesTask ?? []).sorted { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }

            // Free, quiet upkeep: this game's local snapshot, if it has
            // one, stays current whenever there happens to be a
            // connection, so an offline session later reflects the
            // newest state Cabinet has actually seen, not just whatever
            // was newest back when the game was first kept.
            if keptStore.kept(romId: rom.id) != nil {
                keptStore.refreshCachedState(rom: rom, liveStates: states, session: session)
            }
        } else {
            firmware = []
            missingFirmware = []
            saves = []
            states = []
        }

        // A kept game's local states belong in the list either way:
        // offline they are the only thing there is to offer, online they
        // are already present above unless a refresh has not caught up
        // yet, in which case showing both would be the same state twice
        // under two different labels. Every queued save gets its own
        // row too, not just the newest, so a trip with several saves
        // offers every one of them back, not only the last.
        if let core = NativeCore.core(for: rom, canonicalSlug: canonicalSlug) {
            if let local = keptStore.localState(for: rom.id),
               !states.contains(where: { $0.id == local.stateId }) {
                states.append(GameState(localStateId: local.stateId, updatedAt: local.updatedAt, emulator: core.emulatorTag))
            }
            for pending in keptStore.pendingStates(for: rom.id) {
                let syntheticId = pending.stem.hashValue
                guard !states.contains(where: { $0.id == syntheticId }) else { continue }
                states.append(
                    GameState(
                        localStateId: syntheticId, updatedAt: Self.isoStamp(pending.savedAt), emulator: core.emulatorTag
                    )
                )
            }
            states.sort { ($0.updatedAt ?? "") > ($1.updatedAt ?? "") }
        }

        // The VMU row. Prefetch keeps the local card current when a
        // connection exists (a no-op when the server stamp has not
        // moved), then detection parses whatever card would actually
        // boot.
        if NativePlatform.platform(for: rom, canonicalSlug: canonicalSlug) == .dreamcast {
            if !NetworkMonitor.shared.isOffline {
                await MemoryCardStore.shared.prefetchFromServer(rom: rom, platform: .dreamcast, session: session)
            }
            if let card = VMULauncher.currentCard(romId: rom.id) {
                vmuMinigame = VMUCard.minigameName(card)
            }
        }

        loading = false
    }

    /// Hand-rolled swipe-to-dismiss: `fullScreenCover`, unlike `sheet`, has
    /// no interactive dismiss gesture built in. Only reads a downward drag
    /// as "dismiss" while the scroll content is already at its top, so it
    /// cannot fight normal scrolling further down the screen.
    private var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 20, coordinateSpace: .local)
            .onChanged { value in
                guard isScrolledToTop, value.translation.height > 0 else { return }
                dragOffset = value.translation.height
            }
            .onEnded { value in
                guard isScrolledToTop, value.translation.height > 0 else {
                    withAnimation(.spring) { dragOffset = 0 }
                    return
                }
                if value.translation.height > Self.dismissThreshold {
                    dismiss()
                } else {
                    withAnimation(.spring) { dragOffset = 0 }
                }
            }
    }
}

private struct ScrollOffsetKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

/// A grouped card, so the screen reads like Settings rather than a web form.
private struct LaunchCard<Content: View>: View {
    let title: String
    let systemImage: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: systemImage)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 14))
    }
}
