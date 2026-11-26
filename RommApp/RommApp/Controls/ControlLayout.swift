import CoreGraphics
import Foundation

/// A control layout, loaded from a bundled JSON file. Layouts are data, not
/// code: adding a system is a file, not a view hierarchy.
///
/// All frames are normalised 0 to 1 against the control strip the host hands
/// the pad view, not the screen, so one layout serves every phone size.
/// Every element carries two rects, per DeltaCore's model: `frame` is what
/// gets drawn, `extended` is what gets hit tested. The gap between them is
/// the single highest impact detail in how touch controls feel.
struct ControlLayout: Decodable {
    let system: String
    /// Portrait items, normalised against the bottom control strip.
    let items: [Item]
    /// Landscape items, normalised against the full screen, placed in the
    /// gutters flanking the centred canvas. Optional: a layout without them
    /// falls back to portrait items, which will look wrong but still work.
    let landscapeItems: [Item]?
    /// The phone-as-controller arrangement: landscape, but with no
    /// picture to leave room for, so the controls can own the whole
    /// screen. `landscapeItems` are authored to sit in the gutters
    /// around a centred game, which is right when the game is there
    /// and wrong on a companion panel, where it left the controls
    /// hugging the bezels with the middle half of the screen empty.
    /// Measured 2026-08-23: those layouts use 13 to 21 per cent of the
    /// screen, and their buttons are a quarter to a sixth of the area
    /// of the hand-tuned arcade companion's.
    ///
    /// Optional, and the panel falls back to `landscapeItems` without
    /// one, exactly as landscape falls back to portrait. Nintendo DS
    /// deliberately has none: its panel DOES show a picture, the
    /// streamed bottom screen, so the gutter shape is correct there.
    let companionItems: [Item]?
    /// Extra portrait strip height, as a fraction of the normal strip, for
    /// pads too crowded to fit in it (N64's stick, d-pad, four face buttons,
    /// C cluster and three shoulders is a lot more than a two button Game
    /// Boy pad). Zero for every layout that does not opt in, which keeps
    /// their coordinates exactly what they have always meant: this only
    /// grows the strip a layout is normalised against when the layout asks
    /// for it, so nothing else in the library shifts.
    let headroom: Double?

    /// The arrangement for a phone driving a television: the
    /// companion set when the layout carries one, the landscape set
    /// otherwise.
    func companionOrLandscapeItems() -> [Item] {
        if let companion = companionItems, !companion.isEmpty { return companion }
        return items(landscape: true)
    }

    func items(landscape: Bool) -> [Item] {
        // Nil coalescing alone would hand back an empty landscape array as
        // though it were a real layout, leaving nothing to draw and nothing
        // to touch. Empty falls back the same as missing.
        guard landscape, let wide = landscapeItems, !wide.isEmpty else { return items }
        return wide
    }

    struct Item: Decodable {
        enum Kind: String, Decodable {
            /// A continuous analog control. Unlike every other kind here,
            /// its ids are not RetroPad button ids: EmulatorJS reads a
            /// stick through `GameManager.simulateInput` at four dedicated
            /// indices, one per direction, each carrying a magnitude from
            /// 0 to 0x7fff rather than a boolean down/up. Confirmed against
            /// EmulatorJS's own on screen stick, `data/src/emulator.js`,
            /// not assumed from the RetroPad table above.
            case dpad, button, pill, stick
        }

        let kind: Kind
        let label: String?
        /// RetroArch device id for single controls (B 0, Select 2, Start 3,
        /// A 8, L 10, R 11), confirmed against the EmulatorJS 4.2.3 bundle.
        let input: Int?
        /// D-pad only: up, down, left, right, in that order.
        /// Stick only: x-positive, x-negative, y-positive, y-negative, the
        /// same order and meaning as EmulatorJS's own `inputValues`.
        let inputs: [Int]?
        let frame: Rect
        let extended: Rect
        /// D-pad only. Four way sticks actively suppress diagonals: Pac-Man
        /// and Donkey Kong misbehave when fed two directions at once.
        let fourWay: Bool?
    }

    struct Rect: Decodable {
        let x: Double
        let y: Double
        let w: Double
        let h: Double

        func resolved(in size: CGSize) -> CGRect {
            CGRect(
                x: x * size.width,
                y: y * size.height,
                width: w * size.width,
                height: h * size.height
            )
        }
    }

    /// The layout for a platform slug, falling back to the generic pad.
    /// One file per real pad shape under Resources/ControlLayouts, not one
    /// per platform: a Game Boy Pocket and a Game Boy Light are the same
    /// controller wearing a different name, and get the same file.
    ///
    /// Keyed by canonical slug (`Rom.canonicalPlatformSlug`), the same
    /// contract every other platform keyed lookup in this app follows.
    /// The slugs here are the handheld systems this app plays
    /// (`PlatformSupport.handheldPlatforms`); anything else gets `default`.
    static func forPlatform(slug: String) -> ControlLayout? {
        let name: String
        switch slug {
        case "gb", "gbc", "dmg", "game-boy-light", "game-boy-pocket":
            name = "gb"
        case "gba", "game-boy-adavance-sp", "game-boy-micro":
            name = "gba"
        case "psp":
            name = "psp"
        // Game & Watch, under whichever name the folder carries: the
        // platform is custom, so the slug is whatever someone typed, and
        // "LCD Handhelds" is an honest name for a library that is only
        // a quarter Nintendo. NativeCore falls back to the .mgw
        // extension for the same reason.
        case "game-and-watch", "game & watch", "game and watch", "gameandwatch",
             "lcd handhelds", "lcd-handhelds", "handheld electronic game":
            name = "gw"
        case "nds", "nintendo-ds-lite", "nintendo-dsi", "nintendo-dsi-xl":
            name = "nds"
        case "gamegear":
            name = "gamegear"
        case "neo-geo-pocket", "neo-geo-pocket-color":
            name = "ngpc"
        default:
            name = "default"
        }
        guard let url = Bundle.main.url(forResource: name, withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let layout = try? JSONDecoder().decode(ControlLayout.self, from: data)
        else {
            assertionFailure("Missing or invalid control layout \(name).json")
            return nil
        }
        return layout
    }
}
