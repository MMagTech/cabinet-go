import SwiftUI

// What a game's cover and row carry besides the art, everywhere a game is
// shown (Home's rails, the Library, Search): the favorite star, the
// download ring, and the long-press menu.

/// A star in the top-leading corner, shown only when the game is
/// favorited. Reads at a glance in a grid without opening anything.
private struct FavoriteBadge: ViewModifier {
    @EnvironmentObject private var session: Session
    let romId: Int
    var compact = false

    func body(content: Content) -> some View {
        content.overlay(alignment: .topLeading) {
            if session.isFavorite(romId: romId) {
                Image(systemName: "heart.fill")
                    .font(compact ? .caption2 : .footnote)
                    .foregroundStyle(.pink)
                    .padding(compact ? 4 : 6)
                    .background(.regularMaterial, in: .circle)
                    .padding(compact ? 4 : 6)
            }
        }
    }
}

/// A small ring wherever a badge or an inline icon already lives,
/// visible only while `KeptGameStore` actually has this game
/// downloading, gone the instant it finishes or fails. Bound to the
/// real byte progress, not a spinner, the same determinate-ring idiom
/// the App Store uses on its own icons; this app already speaks that
/// idiom for loading state everywhere else (a dimmed area with a
/// centered `ProgressView`), so a real percentage here is a natural
/// extension of it, not a new pattern. Deliberately not a permanent
/// "kept" badge once the download finishes: that state already lives
/// in Storage, and restating it on every cover forever would be one
/// more thing this app was trying all day to stop doing.
/// A download's own ring: a faint track with an arc that fills clockwise,
/// the shape App Store, Music and TV draw for the same job. Drawn by hand
/// because SwiftUI's circular style has no determinate form on UIKit
/// platforms; Apple's page: "in cases where no determinate circular
/// progress view style is available, circular progress views use an
/// indeterminate style". So a real fraction went in and a spinner came
/// out, on every platform this app ships to. The fraction is real:
/// bytes received over the server's length, or over RomM's own size for
/// the file when the server sends none. Only a download with neither
/// still spins. No stop square inside, the App Store's has it because a
/// tap cancels, and this badge does not.
private struct DownloadProgressRing: View {
    @ObservedObject private var keptStore = KeptGameStore.shared
    let romId: Int

    var body: some View {
        if let progress = keptStore.downloading[romId] {
            if progress.totalBytes > 0 {
                let fraction = min(max(progress.fraction, 0), 1)
                // Softened to sit as lightly on the cover as the star
                // does: a full-strength tint ring read heavier than the
                // favorite badge beside it (2026-09-02).
                ZStack {
                    Circle()
                        .stroke(.tint.opacity(0.2), lineWidth: 2)
                    Circle()
                        .trim(from: 0, to: fraction)
                        .stroke(.tint.opacity(0.8), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.25), value: fraction)
                }
                .frame(width: 14, height: 14)
                .accessibilityLabel("Downloading")
                .accessibilityValue("\(Int(fraction * 100)) percent")
            } else {
                ProgressView()
                    .controlSize(.mini)
            }
        }
    }
}

/// The long press menu, used everywhere a game can be tapped. A press
/// rather than a swipe because a cover grid has no swipe to give, and one
/// gesture across both views is worth more than the better gesture in one
/// of them. Favoriting lives in the same menu rather than its own: two
/// long-press menus on one view do not merge, the second silently wins, so
/// every question a list can't otherwise answer without opening the game
/// belongs in this one place. Download joined it the same way: deciding to
/// keep a game used to mean opening its full launch screen for one toggle.
private struct GameContextMenu: ViewModifier {
    @ObservedObject private var keptStore = KeptGameStore.shared
    @EnvironmentObject private var session: Session
    let rom: Rom

    func body(content: Content) -> some View {
        let romId = rom.id
        let favorited = session.isFavorite(romId: romId)
        return content.contextMenu {
            Button {
                Task { try? await session.toggleFavorite(romId: romId) }
            } label: {
                Label(
                    favorited ? "Unfavorite" : "Favorite",
                    systemImage: favorited ? "heart.slash" : "heart"
                )
            }
            // Same eligibility as the launch screen's Storage card, same
            // underlying calls: this is a second door, not a second
            // mechanism. Three labels, not two, since this menu has no
            // companion caption line the way the launch screen's toggle
            // does to explain an in-progress download on its own.
            if KeptGameStore.isKeepable(
                rom, canonicalSlug: rom.canonicalPlatformSlug(platformsVersions: session.platformsVersions)
            ) {
                if keptStore.downloading[romId] != nil {
                    Button {
                        keptStore.remove(romId: romId)
                    } label: {
                        Label("Cancel Download", systemImage: "xmark.circle")
                    }
                } else if keptStore.kept(romId: romId) != nil {
                    // Destructive, red with the trash can, the way
                    // Podcasts and Music draw Remove Download and the
                    // way the platform's Remove All Downloads already
                    // reads; the two sat side by side in different
                    // colours (2026-09-03).
                    Button(role: .destructive) {
                        keptStore.remove(romId: romId)
                    } label: {
                        Label("Remove Download", systemImage: "trash")
                    }
                } else {
                    Button {
                        keptStore.keep(rom: rom, session: session)
                    } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
            }
        }
    }
}

extension View {
    func favoriteBadge(romId: Int, compact: Bool = false) -> some View {
        modifier(FavoriteBadge(romId: romId, compact: compact))
    }

    /// A small ring badge, matching `favoriteBadge`'s own corner-circle
    /// styling, visible only while this game is actively downloading, in
    /// the bottom-trailing corner, clear of the star in the top-leading
    /// one.
    func downloadBadge(romId: Int, compact: Bool = false) -> some View {
        overlay(alignment: .bottomTrailing) {
            if KeptGameStore.shared.downloading[romId] != nil {
                DownloadProgressRing(romId: romId)
                    .padding(compact ? 4 : 6)
                    .background(.regularMaterial, in: .circle)
                    .padding(compact ? 4 : 6)
            }
        }
    }

    func gameContextMenu(rom: Rom) -> some View {
        modifier(GameContextMenu(rom: rom))
    }
}
