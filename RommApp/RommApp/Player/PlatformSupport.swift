import Foundation

/// Whether this app can actually put a game on screen: the handheld
/// systems (docs/scope-handheld.md), each through its native core.
///
/// The single source of truth for that, shared by the library, the launch
/// screen's Play guard, Home, the widget and Spotlight, so they can never
/// disagree about which games this covers.
enum PlatformSupport {
    /// RomM's ARCADE_SYSTEMS, the metadata slugs whose games run on the
    /// arcade cores. One copy, shared with `Rom.isArcade`, so the library
    /// sections and the rom-level checks cannot drift apart.
    static let arcadeSlugs: Set<String> = ["arcade", "neogeoaes", "neogeomvs", "neo-geo-cd"]

    /// The systems the iPhone app plays: the ones made to be held
    /// (docs/scope-handheld.md). The test for adding one is whether it was
    /// played in your hands; CabinetOS is the console for everything else.
    /// Dreamcast is not here: only its VMU minigames play, through
    /// `canPlay`'s exception below.
    static let handheldPlatforms: Set<NativePlatform> = [
        .gb, .gbc, .gba, .nds, .psp, .gameGear, .ngpc, .gameAndWatch,
    ]

    /// `isSupported` for a platform as RomM lists it, resolved the same way
    /// a rom's platform is.
    static func isSupported(_ platform: Platform, platformsVersions: [String: String]) -> Bool {
        isSupported(
            canonicalSlug: Rom.canonicalSlug(forFolder: platform.fsSlug, platformsVersions: platformsVersions),
            isArcade: arcadeSlugs.contains(platform.slug))
    }

    static func isSupported(canonicalSlug: String, isArcade: Bool = false) -> Bool {
        // Native cores only, and only the handhelds. Arcade, the home
        // consoles and the keyboard machines are not offered on the
        // phone; their games live on in RomM and play on CabinetOS.
        guard !isArcade,
              let platform = NativePlatform.platform(bySlug: canonicalSlug, isArcade: false) else {
            return false
        }
        return handheldPlatforms.contains(platform)
    }

    /// Whether this device can actually start this game.
    ///
    /// The same question `isSupported` answers, asked about a rom, plus
    /// the one exception that is not about platforms at all: on the
    /// iPhone a Dreamcast game whose VMU card carries a minigame IS
    /// playable, in the VMU core, even though Dreamcast is not.
    ///
    /// Lives here rather than in a view because two different places
    /// offer a game to continue and each of them is a promise: Home's
    /// hero and the widget. The first version of this filter only fixed Home, which left the
    /// widget on somebody's Home Screen still offering a GameCube game
    /// to a phone that cannot run one.
    ///
    /// NOT for browsing. A list someone scrolls should still show the
    /// games this device cannot play, because their launch screen is how
    /// the rom and its BIOS get out through Keep. Only use this where
    /// tapping is meant to start something.
    /// Takes the versions map rather than the session so the widget and
    /// top shelf writers, which are not main-actor bound, can ask too.
    static func canPlay(_ rom: Rom, platformsVersions: [String: String]) -> Bool {
        let slug = rom.canonicalPlatformSlug(platformsVersions: platformsVersions)
        if isSupported(canonicalSlug: slug, isArcade: rom.isArcade) { return true }
        if NativePlatform.platform(for: rom, canonicalSlug: slug) == .dreamcast,
           let card = VMULauncher.currentCard(romId: rom.id),
           VMUCard.minigameName(card) != nil {
            return true
        }
        return false
    }
}
