import Foundation

/// A human name for each bundled layout file, and what real platform slugs
/// resolve to it.
///
/// Copied by hand from `ControlLayout.forPlatform(slug:)`'s switch, not
/// derived from it: that switch is not data the editor's target can read at
/// runtime, only Swift the compiler resolves. Keeping this list is the
/// tradeoff, and it only needs revisiting when a platform is added there,
/// which is rare enough that a stale entry here is an acceptable risk next
/// to the alternative of duplicating the switch as a lookup table.
struct LayoutName {
    let file: String
    let title: String
    let slugs: String

    static let all: [LayoutName] = [
        LayoutName(file: "default", title: "Fallback pad", slugs: "anything with no fixed digital pad this app can honestly draw"),
        LayoutName(file: "gamegear", title: "Sega Game Gear", slugs: "gamegear"),
        LayoutName(file: "gb", title: "Game Boy", slugs: "gb, gbc, dmg, and the Light/Pocket revisions"),
        LayoutName(file: "gba", title: "Game Boy Advance", slugs: "gba, SP, Micro"),
        LayoutName(file: "nds", title: "Nintendo DS", slugs: "nds, DS Lite, DSi, DSi XL"),
        LayoutName(file: "ngpc", title: "Neo Geo Pocket", slugs: "Neo Geo Pocket, Pocket Color"),
        LayoutName(file: "gw", title: "Game & Watch", slugs: "the picture is the controller: taps press the drawn buttons; this is the surface plus Menu"),
        LayoutName(file: "psp", title: "PlayStation Portable", slugs: "psp"),
    ]

    static func title(for file: String) -> String? {
        all.first { $0.file == file }?.title
    }
}
