import Foundation

/// Platforms whose native input is a keyboard, not a gamepad.
///
/// A C64, Amiga or DOS machine is not a shape a touch overlay can honestly
/// take: a handful of face buttons cannot stand in for a keyboard's worth of
/// commands and shortcuts, and pretending otherwise produces a control
/// scheme that looks like it works and does not. Every other platform this
/// app knows about, console, handheld or arcade, has a real fixed pad this
/// app can draw. These do not, so this app does not try to play them yet.
///
/// This is a settled decision, not a gap waiting to be filled: an on screen
/// keyboard is a real feature with its own design, and building a bad one
/// tonight would be worse than building none. See the scope doc's Next
/// section. A physical Bluetooth keyboard should already work regardless of
/// this list, since nothing in this app intercepts hardware keyboard events
/// before they reach the webview, though that has not been confirmed on a
/// real keyboard yet.
///
/// Keyed by the same canonical slug everything else in the player resolves
/// through, `Rom.canonicalPlatformSlug`, never the raw IGDB slug: the whole
/// reason that resolution exists is that a rom's own platform_slug cannot be
/// trusted to already be this value.
enum ComputerPlatforms {
    private static let slugs: Set<String> = [
        "acpc", "c-plus-4", "c128", "c64", "commmodore-128",
        "commodore-64c", "cpet", "dos", "vic-20", "zxs",
    ]

    static func contains(_ canonicalSlug: String) -> Bool {
        slugs.contains(canonicalSlug)
    }
}

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
    /// Lives here rather than in a view because THREE different places
    /// offer a game to continue and every one of them is a promise:
    /// Home's hero, the iPhone widget, and the Apple TV top shelf. The
    /// first version of this filter only fixed Home, which left the
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
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if NativePlatform.platform(for: rom, canonicalSlug: slug) == .dreamcast,
           let card = VMULauncher.currentCard(romId: rom.id),
           VMUCard.minigameName(card) != nil {
            return true
        }
        #endif
        return false
    }
}
