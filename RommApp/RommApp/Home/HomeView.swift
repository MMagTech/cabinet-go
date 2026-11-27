import SwiftUI
import UIKit

/// The launch screen. Resume first, not a library grid: the last game you
/// played, large, one tap back in. The library is a room you walk into from
/// here, not the front door.
///
/// The layout adapts to orientation rather than assuming portrait. A hero
/// sized for a tall screen fills a short one completely, hiding the rotation
/// shelf and the library entirely, so in landscape the hero becomes a wide
/// card and the rest sits beside it.
struct HomeView: View {
    @EnvironmentObject private var session: Session
    @ObservedObject private var compatibility = Compatibility.shared
    @ObservedObject private var networkMonitor = NetworkMonitor.shared
    @AppStorage(PlatformLabelSource.key) private var labelSourceRaw = PlatformLabelSource.platformName.rawValue
    private var labelSource: PlatformLabelSource {
        PlatformLabelSource(rawValue: labelSourceRaw) ?? .platformName
    }

    @State private var recent: [Rom] = []
    @State private var favorites: [Rom] = []
    @State private var loaded = false
    @State private var offline = false
    @State private var resuming: Rom?
    @State private var nativeDirectLaunch: NativeDirectLaunch?
    @State private var preparingResume = false
    @ObservedObject private var keptStore = KeptGameStore.shared
    @ObservedObject private var quickActions = QuickActionRouter.shared
    @State private var quickPushRecents = false
    @State private var quickPushFavorites = false

    /// Everything the player needs to start without the launch screen in
    /// front of it. Identifiable so it can drive a `fullScreenCover` the
    /// same way `resuming` does. State comes as raw bytes:
    /// `NativeLauncher.prepare` has already settled on-device against
    /// download before this is ever built.
    private struct NativeDirectLaunch: Identifiable {
        let id = UUID()
        let rom: Rom
        let core: NativeCore
        let initialState: Data?
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                let landscape = geometry.size.width > geometry.size.height
                // Nothing cached means nothing to show behind a banner, so
                // offline replaces the content rather than sitting above
                // it. Kept in a ScrollView so pull to refresh still works
                // as a second way to retry. The manual toggle bypasses
                // that emptiness check entirely: real signal loss with a
                // hero already on screen should not yank it away, but
                // choosing Offline Mode is a deliberate act, and it has
                // to visibly do something the instant it is flipped, not
                // wait for recent/favorites to happen to be empty
                // already or for a fresh launch to clear them (2026-08-07:
                // it took a force-quit and reopen to take effect).
                if networkMonitor.manualOfflineMode || (offline && recent.isEmpty && favorites.isEmpty) {
                    // Nothing cached to show above a banner, same as
                    // before, but there may be something better: any
                    // kept, native-capable game plays with zero
                    // connection, so resume-first still has an honest
                    // answer offline whenever one exists. The exact same
                    // view the library shows, not a second one built to
                    // look like it: one offline view, shown wherever the
                    // app needs one (2026-08-07: two copies had no reason
                    // to exist).
                    OfflineLibraryView(onRetry: load)
                } else if !loaded, recent.isEmpty, favorites.isEmpty {
                    // Something, anything, while the first load runs. This
                    // screen used to render nothing at all until the answer
                    // arrived, so a slow or failing connection looked like a
                    // hung app rather than one waiting on a server.
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if landscape {
                    // Landscape does not scroll as a page. The hero and its
                    // Resume button hold the left side still while only the
                    // rails beside them move, which is the whole point of
                    // the split: scrolling the page moved the one thing you
                    // came here to tap.
                    wideLayout(height: geometry.size.height)
                } else {
                    ScrollView { tallLayout(height: geometry.size.height) }
                }
            }
            // Shown only when a background sync pass actually uploaded
            // something (a queued save, a queued play-session report),
            // never for a no-op check: same "invisible when it applies
            // to nothing" rule the Offline Mode toggle already follows.
            // safeAreaInset rather than an overlay so it never covers the
            // toolbar or the hero underneath it, in either orientation,
            // without needing to be threaded into both layouts
            // separately.
            .safeAreaInset(edge: .top) {
                VStack(spacing: 0) {
                    if let summary = session.lastSyncSummary {
                        syncBanner(summary)
                    }
                    // A platform coming down, with its count and cancel,
                    // on the screen everyone lands on, so its progress is
                    // never somewhere to go looking for.
                    DownloadAllStatusCard()
                }
            }
            .onChange(of: session.lastSyncSummary) { _, summary in
                guard summary != nil else { return }
                Task {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    withAnimation { session.lastSyncSummary = nil }
                }
            }
            // No large title. The tab bar already names this screen, and
            // in landscape the large title overlapped the first rail's
            // header outright. Inline keeps the bar itself, which the
            // settings button needs.
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // Settings only. The library and search moved to the tab
                // bar, where a thumb actually rests: on a large phone the
                // top trailing corner is the worst place for the two
                // things reached every session. Settings earns its place
                // here precisely because it is reached rarely.
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        SettingsView()
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                // A real Toggle, not a plain button: a toolbar icon that
                // just triggers something is the wrong shape for a mode
                // that stays on, nothing in iOS treats Low Power Mode or
                // Airplane Mode itself as a one-shot action button. The
                // button style keeps it toolbar-sized while still
                // reading as a switch, filled when on the same way
                // Control Center's own toggles are; the airplane glyph
                // is deliberately the one iOS already uses for exactly
                // this idea, acting as though there is no signal.
                // Invisible, not merely disabled, when there is nothing
                // it could switch to, matching every other control this
                // app has cut back to only where it applies.
                if !KeptGameStore.shared.offlinePlatforms().isEmpty {
                    ToolbarItem(placement: .topBarLeading) {
                        // No explicit tint: the app has no custom accent
                        // color, so leaving this alone inherits the same
                        // system blue the Home tab icon already uses,
                        // guaranteed to match rather than a hardcoded
                        // guess at it.
                        Toggle(isOn: $networkMonitor.manualOfflineMode) {
                            Label("Offline Mode", systemImage: "airplane")
                        }
                        .toggleStyle(.button)
                    }
                }
            }
            .refreshable { await load() }
            // A game reached through Library, not Home's own resume flow,
            // has its own fullScreenCover and never touches `resuming`, so
            // the reload below never sees it close. Reappearing covers both:
            // it fires on first appearance same as `.task` would, and again
            // every time navigation brings Home back into view, favoriting
            // included.
            .onAppear {
                Task { await load() }
            }
            // Live, not just at the next natural reload: load() already
            // leaves recent/favorites untouched on a failed fetch (see
            // its own catch below), so re-running it the instant
            // connectivity changes can only correct the offline flag and
            // reveal the kept-games list sooner, never discard content
            // already on screen. Closes the gap where going offline
            // needed a manual re-navigation to notice (2026-08-07).
            .onChange(of: networkMonitor.isConnected) { _, _ in Task { await load() } }
            .onChange(of: networkMonitor.manualOfflineMode) { _, _ in Task { await load() } }
            .fullScreenCover(item: $resuming) { rom in
                NavigationStack { GameLaunchView(rom: rom) }
            }
            .onChange(of: resuming == nil) { _, playerClosed in
                if playerClosed { Task { await load() } }
            }
            .fullScreenCover(item: $nativeDirectLaunch) { launch in
                NativePlayerView(rom: launch.rom, core: launch.core, initialState: launch.initialState)
                    .environmentObject(session)
            }
            .onChange(of: nativeDirectLaunch == nil) { _, playerClosed in
                if playerClosed { Task { await load() } }
            }
            // Home's share of a quick action, taken when, and only when,
            // this screen can actually act on it: resume needs the recents
            // fetch to have landed, favorites needs the collection known.
            // Checked on every signal that could newly make one possible,
            // since a cold start sets the action before any of them.
            .onChange(of: quickActions.pending) { _, _ in consumeQuickAction() }
            .onChange(of: loaded) { _, _ in consumeQuickAction() }
            .onChange(of: session.favoriteCollection) { _, _ in consumeQuickAction() }
            .onAppear { consumeQuickAction() }
            .navigationDestination(isPresented: $quickPushRecents) {
                romList(.recentlyPlayed)
            }
            .navigationDestination(isPresented: $quickPushFavorites) {
                if let favorites = session.favoriteCollection {
                    romList(.collection(favorites))
                }
            }
        }
    }

    // MARK: Layouts

    private func tallLayout(height: CGFloat) -> some View {
        let hero = resumeHero
        let rails = (recentBesides(hero).isEmpty ? 0 : 1) + (favorites.isEmpty ? 0 : 1)
        let sizes = portraitSizes(for: height, rails: rails)
        return VStack(alignment: .leading, spacing: Self.tallSpacing) {
            if let hero {
                heroCard(for: hero, height: sizes.hero, wide: false)
                    .padding(.horizontal, 20)
            }
            // Outside the hero's own block, and that matters: when
            // nothing recent is playable here there is no hero, and the
            // shelf is the only way back to those games. The empty state
            // belongs to an empty library, not to an unplayable one.
            if !recentBesides(hero).isEmpty {
                rotationRow("Recent", recentBesides(hero), seeAll: .recentlyPlayed, coverHeight: sizes.cover)
            } else if loaded, recent.isEmpty {
                emptyState.padding(.horizontal, 20)
            }
            if !favorites.isEmpty {
                rotationRow(
                    "Favorites", favorites, seeAll: session.favoriteCollection.map { .collection($0) },
                    coverHeight: sizes.cover
                )
            }
        }
        .padding(.vertical, Self.tallPadding)
    }

    /// Portrait's gaps, named because the hero's height is worked out
    /// from them.
    private static let tallSpacing: CGFloat = 20
    private static let tallPadding: CGFloat = 16
    /// A rail cover's height, and the shortest a portrait rail may take
    /// it to on a shorter phone.
    private static let railCoverHeight: CGFloat = 133
    private static let railCoverFloor: CGFloat = 112
    /// The shortest portrait hero: below this the game you came back for
    /// is barely bigger than a rail cover.
    private static let heroFloor: CGFloat = 240

    /// Landscape: the hero takes the left, everything else stacks to its
    /// right, so nothing is pushed off a screen that is short but wide.
    private func wideLayout(height: CGFloat) -> some View {
        HStack(alignment: .top, spacing: 20) {
            if let hero = resumeHero {
                heroCard(for: hero, height: max(200, height - 40), wide: true)
                    .frame(maxWidth: 320)
                    .padding(.vertical, 20)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !recentBesides(resumeHero).isEmpty {
                        rotationRow("Recent", recentBesides(resumeHero), seeAll: .recentlyPlayed)
                    } else if loaded, recent.isEmpty {
                        emptyState.padding(.horizontal, 20)
                    }
                    if !favorites.isEmpty {
                        rotationRow(
                            "Favorites", favorites, seeAll: session.favoriteCollection.map { .collection($0) }
                        )
                    }
                }
            }
            // Bottom margin so the last row can still be scrolled fully
            // clear of the tab bar when you want to see it, even though it
            // rests underneath it.
            .contentMargins(.bottom, 80, for: .scrollContent)
            // The system's scroll edge effect tints this column's whole
            // area, not just the strip near a bar, which drew a hard
            // vertical seam down the middle of the screen where the column
            // met the hero beside it. The bars here float over content that
            // is already high contrast box art, so the effect buys nothing
            // and cost a visible join.
            .withoutScrollEdgeEffect()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
        .padding(.leading, 20)
        // The scrolling column runs the whole height of the screen and
        // carries on under the tab bar. Previously it was only as tall as
        // the hero beside it, so rows were sliced against the column's own
        // invisible bottom edge with dead white space below, which looked
        // broken rather than layered. Reaching the bottom also gives the
        // bar something to sit over, which is the only way its material
        // ever shows: glass over nothing just renders as a white pill.
        .ignoresSafeArea(.container, edges: .bottom)
    }

    // MARK: Pieces

    /// The full list behind a rail.
    @ViewBuilder
    private func romList(_ source: RomListView.Source) -> some View {
        RomListView(source: source)
    }

    /// Box art, always, the same visual language as every other card in
    /// the app. The hero used to show a captured game frame when one
    /// existed, which meant Home mixed two art styles depending on how the
    /// last session ended, and keeping those frames honest required a
    /// periodic in-game screenshot, standing work inside a process with
    /// no headroom to spare. Save screenshots still exist where they
    /// belong: attached to the save states themselves.
    private func heroArtwork(for rom: Rom, contentMode: ContentMode) -> some View {
        CoverImage(
            path: rom.pathCoverLarge ?? rom.pathCoverSmall,
            title: rom.displayName,
            contentMode: contentMode
        )
    }

    /// Portrait's hero takes a share of the screen rather than a fixed 360
    /// points, which dominated a small phone and looked timid on a large
    /// one, and gives back what the rails below it need, so Favorites ends
    /// above the tab bar instead of under it. The share alone did not: on
    /// an iPhone Air the second rail ran 79 points under the bar. When the
    /// hero reaches its floor the rail covers shrink, down to their own
    /// floor, which is meant to fit both rails on a regular sized iPhone; a phone
    /// shorter than that scrolls.
    private func portraitSizes(for available: CGFloat, rails: Int) -> (hero: CGFloat, cover: CGFloat) {
        let share = min(max(available * 0.45, 280), 460)
        guard rails > 0 else { return (share, Self.railCoverHeight) }
        let count = CGFloat(rails)
        let gaps = Self.tallPadding * 2 + Self.tallSpacing * count
        // What the hero and the covers share once the gaps and each
        // rail's two lines of text are taken out.
        let room = available - gaps - count * railTextHeight
        let cover = min(Self.railCoverHeight, max(Self.railCoverFloor, floor((room - Self.heroFloor) / count)))
        let hero = max(min(share, room - count * cover), Self.heroFloor)
        return (hero, cover)
    }

    /// A rail's header and caption, from the line heights of the fonts
    /// they use, the way `heroBandHeight` measures the band, so a larger
    /// text size is counted rather than run under the tab bar.
    private var railTextHeight: CGFloat {
        let header = UIFont.preferredFont(forTextStyle: .headline).lineHeight
        let caption = UIFont.preferredFont(forTextStyle: .caption1).lineHeight
        return ceil(header + 12 + 6 + caption)
    }

    /// Reserving a real row rather than overlaying text on the art (see
    /// the artwork comment below for why) only works if the row is
    /// actually tall enough for its own text. Measuring the real line
    /// heights of the fonts actually used, rather than guessing a
    /// constant, means this self-corrects if the fonts, the reader's text
    /// size or the padding ever change.
    private func heroBandHeight(wide: Bool) -> CGFloat {
        let titleStyle: UIFont.TextStyle = wide ? .headline : .title3
        let subtitleStyle: UIFont.TextStyle = wide ? .caption1 : .subheadline
        let titleHeight = UIFont.preferredFont(forTextStyle: titleStyle).lineHeight
        let subtitleHeight = UIFont.preferredFont(forTextStyle: subtitleStyle).lineHeight
        let lineSpacing: CGFloat = 2
        let verticalPadding: CGFloat = (wide ? 10 : 12) * 2
        return ceil(titleHeight + subtitleHeight + lineSpacing + verticalPadding)
    }

    private func heroCard(for rom: Rom, height: CGFloat, wide: Bool) -> some View {
        let bandHeight = heroBandHeight(wide: wide)
        let artHeight = max(0, height - bandHeight)
        return Button {
            resuming = rom
        } label: {
            VStack(spacing: 0) {
                // Fitted over a blurred copy of itself rather than cropped
                // to fill: box art is tall and the hero card is wide, so
                // filling would slice the art to a strip of its middle.
                // Fitting shows all of it, and the blurred backdrop fills
                // the leftovers with the art's own colours instead of
                // letterbox bars.
                //
                // Sized to `artHeight`, not the card's full height: this
                // row sits above the title band rather than behind it, so
                // there is no overlap left for the art to be hidden under.
                // The top padding keeps the fit image inset from the
                // card's own rounded top corners, which otherwise clip a
                // sliver off flush-fitted art (Contra's logo, seen the
                // same session); the bottom no longer needs it now that
                // the band, not the art, sits against the bottom corners.
                heroArtwork(for: rom, contentMode: .fit)
                    .padding(.top, 14)
                    .frame(maxWidth: .infinity)
                    .frame(height: artHeight)

                // A frosted band, not a black gradient. The gradient was
                // painting over the very backdrop that makes this card
                // worth looking at, leaving a slab of black under the
                // artwork. A material keeps the game's colours showing
                // through (the blurred fill behind spans the whole card,
                // this row included) while still giving the text a
                // surface it can be read against.
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(rom.displayName)
                            .font(wide ? .headline : .title3.bold())
                            .lineLimit(1)
                        Text(rom.platformLabel(source: labelSource, platformNames: session.platformNames))
                            .font(wide ? .caption : .subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, wide ? 12 : 16)
                // Room for the play button laid over the band's end, so a
                // long title stops short of it.
                .padding(.trailing, Self.resumeButtonSize + 8)
                .padding(.vertical, wide ? 10 : 12)
                .frame(maxWidth: .infinity)
                .frame(height: bandHeight)
                .background(.regularMaterial)
            }
            .frame(height: height)
            // A background rather than a ZStack layer. Stacked, the
            // filled copy is greedy about size and grew the whole card
            // past the edge of the screen; as a background it is sized
            // by the card instead of the other way round. Spans the
            // whole card, band included, so the material above still
            // reads the art's colour through it rather than plain grey.
            .background {
                heroArtwork(for: rom, contentMode: .fill)
                    .blur(radius: 20)
                    .overlay(Color.black.opacity(0.15))
                    .clipped()
            }
            .clipped()
            .clipShape(.rect(cornerRadius: 18))
            // Hit area, not just pixels. `.clipped()` clips drawing and
            // nothing else: the fill copy in the background overflows
            // this frame hugely (tall art scaled to fill a wide card),
            // and without an explicit shape the button's tappable area
            // followed it, invisibly, far above and below the card. In
            // portrait that swallowed taps on whatever sat next to the
            // hero, discovered when the phone-as-controller offer card
            // above it kept "opening the launcher" instead.
            .contentShape(.rect(cornerRadius: 18))
            .shadow(radius: 10, y: 5)
        }
        .buttonStyle(.plain)
        // A second, real button rather than decoration inside the first.
        // Resume means resume: it goes straight back into the game with
        // the choices already remembered for it, since the scope doc's
        // Home promises one tap into the last game and stopping at a
        // screen with a Play button on it is two. Tapping the artwork
        // still opens that screen, which is where you go to pick a
        // different state, change the core, or export.
        //
        // A round play button at the end of the band, the way Music and
        // Podcasts put play beside a title, not a labelled pill on the
        // art: the pill sat over the cover it was meant to show off. Laid
        // over the card rather than inside it, because a button inside
        // another button's label does not reliably get its own taps.
        .overlay(alignment: .bottomTrailing) {
            Button {
                Task { await beginResume(rom) }
            } label: {
                ZStack {
                    Circle().fill(Color.accentColor)
                    if preparingResume {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: Self.resumeButtonSize * 0.4, weight: .semibold))
                            .foregroundStyle(.white)
                            // The triangle's weight sits left of its box;
                            // nudged so it reads as centred in the circle.
                            .offset(x: Self.resumeButtonSize * 0.04)
                    }
                }
                .frame(width: Self.resumeButtonSize, height: Self.resumeButtonSize)
                .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .disabled(preparingResume)
            .accessibilityLabel("Resume")
            .frame(height: heroBandHeight(wide: wide))
            .padding(.trailing, wide ? 10 : 14)
        }
    }

    /// The hero's play button: the smallest comfortable touch target.
    private static let resumeButtonSize: CGFloat = 44

    private func consumeQuickAction() {
        guard let action = quickActions.pending else { return }
        switch action {
        case .search:
            // The tab bar's job, never this screen's.
            return
        case .resume:
            // No recents once loaded means nothing to resume; the action
            // dissolves into just opening the app, which is the honest
            // reading of Resume with nothing to resume into.
            guard loaded else { return }
            quickActions.pending = nil
            // The same promise the hero makes, made from the app icon,
            // so it picks the same game rather than the newest one.
            if let first = resumeHero {
                Task { await beginResume(first) }
            }
        case .recents:
            quickActions.pending = nil
            quickPushRecents = true
        case .favorites:
            guard session.favoriteCollection != nil else { return }
            quickActions.pending = nil
            quickPushFavorites = true
        }
    }

    /// Starts the last game without the launch screen in between.
    ///
    /// Falls back to that screen whenever there is a real question to
    /// answer: no core for the platform means nothing to launch, and any
    /// failure reaching the server is better spent on a screen that can
    /// explain itself than on a player that would just fail later.
    private func beginResume(_ rom: Rom) async {
        preparingResume = true
        defer { preparingResume = false }

        let canonicalSlug = rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions)
        guard PlatformSupport.isSupported(canonicalSlug: canonicalSlug, isArcade: rom.isArcade),
              let nativeCore = NativeCore.core(for: rom, canonicalSlug: canonicalSlug) else {
            resuming = rom
            return
        }
        await beginNativeResume(rom, core: nativeCore)
    }

    /// Loads the newest state this core wrote, regardless of which device
    /// wrote it, by weight of its timestamp: what makes switching between
    /// devices transparent. Compares server states against whatever is
    /// already on the device, same as `GameLaunchView`'s own launch path.
    private func beginNativeResume(_ rom: Rom, core: NativeCore) async {
        do {
            try await NativeLauncher.prepare(rom: rom, session: session)
        } catch {
            resuming = rom
            return
        }

        guard let states = try? await session.states(romId: rom.id) else {
            resuming = rom
            return
        }
        // Only states this core wrote. Feeding another emulator's
        // state into retro_unserialize does not fail, it hangs forever
        // at the frame the state captured: found when a state saved
        // during one accidental FBNeo session froze bowlrama under
        // MAME on both platforms, synced through the server. The pause
        // menu and GameLaunchView already filter exactly this way;
        // this path claimed to match them and missed the filter.
        let compatible = states.filter { $0.emulator == core.emulatorTag }
        guard !compatible.isEmpty else {
            nativeDirectLaunch = NativeDirectLaunch(rom: rom, core: core, initialState: nil)
            return
        }
        let newest = compatible.max { ($0.updatedAt ?? "") < ($1.updatedAt ?? "") }!

        // The copy already on this phone first: reading it costs nothing,
        // and a network round trip only slows down a game already sitting
        // on the device, matching `GameLaunchView.beginNativePlay`'s own
        // reasoning.
        if let local = keptStore.localState(for: rom.id), local.stateId == newest.id {
            nativeDirectLaunch = NativeDirectLaunch(rom: rom, core: core, initialState: local.data)
            return
        }
        guard let bytes = try? await session.stateContent(newest) else {
            resuming = rom
            return
        }
        nativeDirectLaunch = NativeDirectLaunch(rom: rom, core: core, initialState: bytes)
    }

    /// `seeAll` is the full list this rail is a preview of. Nil only
    /// transiently, before that destination has finished loading (the
    /// favorite collection isn't known until the first fetch lands), in
    /// which case the header is a plain label rather than a broken link.
    private func rotationRow(
        _ title: String, _ roms: [Rom], seeAll: RomListView.Source?,
        coverHeight: CGFloat = railCoverHeight
    ) -> some View {
        let coverWidth = (coverHeight * 0.75).rounded()
        return VStack(alignment: .leading, spacing: 12) {
            if let seeAll {
                NavigationLink {
                    romList(seeAll)
                } label: {
                    HStack(spacing: 4) {
                        Text(title)
                            .font(.headline)
                            .foregroundStyle(.primary)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 20)
            } else {
                Text(title)
                    .font(.headline)
                    .padding(.horizontal, 20)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(roms) { rom in
                        VStack(alignment: .leading, spacing: 6) {
                            Button {
                                resuming = rom
                            } label: {
                                CoverImage(path: rom.pathCoverSmall, title: rom.displayName)
                                    .frame(width: coverWidth, height: coverHeight)
                                    .clipShape(.rect(cornerRadius: 10))
                                    .contentShape(Rectangle())
                                    .compatibilityBadge(romId: rom.id, compact: true)
                                    .favoriteBadge(romId: rom.id, compact: true)
                                    .downloadBadge(romId: rom.id, compact: true)
                            }
                            .buttonStyle(.plain)
                            .gameContextMenu(rom: rom)

                            Text(rom.displayName)
                                .font(.caption)
                                .lineLimit(1)
                                .frame(width: coverWidth, alignment: .leading)
                                .foregroundStyle(
                                    compatibility.isMarked(rom.id) ? .secondary : .primary
                                )
                        }
                    }
                }
            }
            // Covers dissolve at the rail's leading edge rather than being
            // sliced in half by it. A screen edge is a boundary the eye
            // accepts without help, which is why Apple's own rails clip
            // hard, but in landscape this edge sits in the middle of the
            // screen with the hero beside it, and a clean vertical cut
            // there reads as a rendering fault. The mask covers only the
            // scrolling covers: fading the headers too would look like the
            // text itself was broken.
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black, location: 0.04),
                        .init(color: .black, location: 0.96),
                        .init(color: .clear, location: 1),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            }
            .contentMargins(.horizontal, 20, for: .scrollContent)
        }
    }

    /// A background sync just uploaded something the app was holding
    /// offline. Self-dismissing (see the onChange above), terse, matching
    /// every other offline-sync caption in this app: the fact that
    /// something uploaded is the whole message.
    private func syncBanner(_ summary: String) -> some View {
        Label(summary, systemImage: "checkmark.icloud")
            .font(.footnote.weight(.medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: .capsule)
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Nothing on the go yet")
                .font(.title3.bold())
            Text("Pick a game from the library. Whatever you play last shows up here for one tap resume.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    /// Only the recents call decides whether this reads as offline: it is
    /// the one every account makes, where favorites is empty for plenty of
    /// people legitimately. A failure that is not a connection problem
    /// keeps the old quiet behaviour, since Home has no good place to put
    /// a server side error and the library screen will explain it properly
    /// the moment they go looking.
    private func load() async {
        // Real suppression, not a cosmetic switch: manual offline mode
        // has to actually stop the app from spending a connection it was
        // told not to use, or the roaming/capped-data reason for having
        // it at all would not hold up. Genuine signal loss already
        // avoided this same round trip everywhere else tonight; this is
        // the same check, just also true when someone chose it.
        guard !networkMonitor.isOffline else {
            offline = true
            loaded = true
            return
        }

        // A session that just ended must reach the server before recents
        // are asked for, or the game played a moment ago sorts under the
        // one before it. No-op when nothing is pending.
        await session.waitForPendingPlayReport()
        // Concurrently, not one after the other. Sequentially, a slow or
        // dead connection paid the timeout twice before this screen could
        // say anything, which doubled the wait for the answer that matters
        // least.
        async let recentTask = session.recentlyPlayed()
        async let favoritesTask = session.favoriteRoms()

        var fetched: [Rom]?
        do {
            fetched = try await recentTask.items
            offline = false
        } catch RommError.offline {
            offline = true
        } catch {
            // Left as is on purpose, see above.
        }
        // Both set together: the hero's height depends on whether a
        // Favorites rail is below it, so recents shown first would draw
        // the hero tall and then shrink it when favorites arrived.
        let favs = try? await favoritesTask
        if let fetched { recent = fetched }
        if let favs { favorites = favs }
        loaded = true
    }

    /// The game the hero offers to carry on with: the most recent one
    /// this device can actually play.
    ///
    /// Resume is a promise. The hero says carry on with this, and a
    /// platform that has been taken off this device cannot carry on with
    /// anything: tapping it reaches a launch screen with a greyed-out
    /// Play button, which reads as the app being broken rather than as a
    /// system it no longer runs. Dreamcast going Mac only on 2026-09-01
    /// is the first platform this has applied to.
    ///
    /// SKIPPED FOR THE HERO ONLY, never dropped from the shelf below it.
    /// An unsupported game still belongs on Home and in the library:
    /// its launch screen is how somebody gets the rom and its BIOS out
    /// through Keep, to play in another emulator. Hiding it would take
    /// away the one thing this app can still do for that game. The hero
    /// is the single place that makes a promise, so it is the only
    /// place that has to be able to keep it.
    ///
    /// THE EXCEPTION: a Dreamcast game whose VMU card carries a minigame
    /// can lead the hero, because the card itself is playable here in
    /// the VMU core and that is the whole point of the phone-as-VMU
    /// design. It is also the thing most worth having on the way out of
    /// the house.
    private var resumeHero: Rom? {
        recent.first { PlatformSupport.canPlay($0, platformsVersions: session.platformsVersions) }
    }

    /// Everything recent except whichever game the hero took, so the
    /// shelf never shows the same cover twice and never loses one.
    private func recentBesides(_ hero: Rom?) -> [Rom] {
        guard let hero else { return recent }
        return recent.filter { $0.id != hero.id }
    }
}

private extension View {
    /// iOS 26 only, so it goes through here rather than putting an
    /// availability check in the middle of the layout.
    @ViewBuilder
    func withoutScrollEdgeEffect() -> some View {
        if #available(iOS 26.0, *) {
            self.scrollEdgeEffectHidden()
        } else {
            self
        }
    }
}
