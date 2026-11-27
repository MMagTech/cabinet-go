import SwiftUI

@main
struct RommApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var session = Session()
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var networkMonitor = NetworkMonitor.shared

    init() {
        // Before anything reads the kept games' folders: the old save stores
        // go, once (GameSaves.removeOldStores).
        GameSaves.removeOldStores()
    }

    var body: some Scene {
        WindowGroup {
            // Debug builds with no such launch argument evaluate one
            // check here and boot normally.
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-cabinetVMUSkin") {
                // The stamped-skin bench: the VMU player straight at the
                // root, for eyeballing the shell against the approved
                // mock in a simulator, where no core can run. The boot
                // alert is dismissed by hand (dismiss on a root view is
                // a no-op) and every frontend-side behavior stays live:
                // the tilting cross, the depressing buttons, SLEEP's
                // fade and z animation, MENU and the LED rules.
                VMUPlayerView(
                    rom: Rom(
                        id: 0, name: "Skin bench", fsName: "skin-bench.chd",
                        fsNameNoTags: "skin-bench", fsNameNoExt: "skin-bench",
                        platformId: 0, platformSlug: "dc", platformFsSlug: "dc",
                        platformDisplayName: "Dreamcast", summary: nil,
                        pathCoverSmall: nil, pathCoverLarge: nil,
                        fsSizeBytes: 0, hasMultipleFiles: false, md5Hash: nil
                    ),
                    cardURL: FileManager.default.temporaryDirectory.appendingPathComponent("skin-bench-card.bin")
                )
                .environmentObject(session)
            } else {
                appContent
            }
            #else
            appContent
            #endif
        }
        // Edits in the Files app happen while this app is not looking,
        // and the moment it can look again is exactly here. Without
        // this, a game deleted in Files kept showing its toggle on
        // until its screen happened to reload.
        .onChange(of: session.stage) { _, stage in
            // A fresh pairing has nothing written at all, and somebody
            // may add the widget before they open the app a second time.
            if stage == .ready {
                WidgetWriter.refresh(session: session)
                SpotlightIndexer.refresh(session: session)
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                KeptGameStore.shared.reconcileFilesFolder()
                // Unconditional, unlike syncIfOnline below: this makes no
                // network call of its own, only reads
                // session.platformsVersions already sitting in memory
                // from whenever it was last fetched, so gating it behind
                // Offline Mode would block a fix that has nothing to do
                // with being online. Found 2026-08-08: wiring this into
                // syncIfOnline the first time meant it silently never ran
                // at all while Offline Mode was on, exactly the state
                // most likely on screen while someone is testing Offline
                // Mode.
                KeptGameStore.shared.healCanonicalSlugs(session: session)
                syncIfOnline()
            }
        }
        // Automatic, anywhere in the app, matching the rest of Offline
        // Mode: a queued save, or a stub entry from a past format
        // change, should not need its own game's screen revisited,
        // only a connection to actually use.
        .onChange(of: networkMonitor.isConnected) { _, isConnected in
            if isConnected { KeptGameStore.shared.healCanonicalSlugs(session: session) }
            syncIfOnline()
        }
        .onChange(of: networkMonitor.manualOfflineMode) { _, isManualOffline in
            if !isManualOffline { KeptGameStore.shared.healCanonicalSlugs(session: session) }
            syncIfOnline()
        }
    }

    private var appContent: some View {
        RootView()
            .environmentObject(session)
            // A widget press or a Spotlight result arrives here as a
            // cabinet:// URL. See DeepLink.swift.
            .handlesGameDeepLinks(session: session)
            .task {
                // A native core crash takes the whole app, so the only
                // moment it can be counted is the next launch.
                NativeSessionMarker.settleAtLaunch()
            }
    }

    private func syncIfOnline() {
        guard !networkMonitor.isOffline else { return }
        // The widget cannot fetch anything itself, so the app has to
        // leave it something current whenever it has a connection. Cheap
        // when nothing changed: unchanged covers are not rewritten.
        WidgetWriter.refresh(session: session)
        // Spotlight likewise, though it gates itself to a daily walk:
        // fourteen hundred games do not change between breakfast and
        // lunch, and the widget's recents do.
        SpotlightIndexer.refresh(session: session)
        Task {
            // The server's version first: it says whether RomM has save
            // channels, which every owed push waits on.
            await session.refreshServerVersion()
            // Every save and state still owed, sent without the game being
            // started: a save made offline reaches RomM at the next
            // foreground with a connection. Said nowhere, as on the TV.
            _ = await SavePush.sendAllOwed(GameSaves.server(session))
            let sessionsUploaded = await session.syncPendingPlaySessions()
            await KeptGameStore.shared.refreshStaleMetadata(session: session)
            if sessionsUploaded > 0 {
                session.lastSyncSummary = Self.summaryText(sessions: sessionsUploaded)
            }
        }
    }

    /// Terse on purpose, matching how every other offline-sync caption in
    /// this app reads: the fact that something uploaded is the whole
    /// message, nothing here needs restating why or how.
    private static func summaryText(sessions: Int) -> String {
        (sessions == 1 ? "1 play session" : "\(sessions) play sessions") + " uploaded"
    }
}
