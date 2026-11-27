import Foundation

/// The shader list started as RomM/EmulatorJS's own bundled set per
/// docs/scope-native-core-settings.md, then got culled on device: the two
/// ScaleHQ scalers and crt-geom looked bad enough in this Metal port that
/// they were dropped on sight (2026-08-07). SABR and four CRT variants
/// survived, plus "Sharp" as the unfiltered default. Two handheld-specific
/// shaders (LCD, Game Boy) joined 2026-08-08, gated to the platforms they
/// actually apply to by `NativeShader.available(for:)`, not offered
/// everywhere like the original six. A choice stored under a dropped
/// shader's old raw value simply fails the enum init and falls back to
/// Sharp. `crtGeom` joined 2026-08-11, console/arcade only via the same
/// `available(for:)` gating the handheld pair uses in the other
/// direction; despite the name collision, it is a new single-pass
/// curved-screen effect built from scratch, not the multi-pass
/// crt-geom.slang port dropped on 2026-08-07.
///
/// The pause menu calls it the Look, as the TV does, and the handheld
/// looks carry the TV's names (CabinetOS's `frontend/src/looks.cpp`):
/// Plain, LCD 3x, and the Game Boy's three dot matrix screens
/// (LibretroShaders.metal says how each is drawn). SABR stays on the
/// phone's handhelds, which the TV does not offer.
enum NativeShader: String, CaseIterable, Identifiable {
    case sharp
    case sabr
    case crtAperture
    case crtEasymode
    case crtMattias
    case crtBeam
    case crtCaligari
    case crtGeom
    case lcd
    /// The original Game Boy's green screen. Its raw value is the old
    /// single "Game Boy" look's, so a Game Boy that had it keeps a dot
    /// matrix (`current(for:)` moves a Game Boy Color to its own).
    case dotMatrix = "gameBoy"
    case dotMatrixPocket
    case dotMatrixColor
    /// The VMU minigame player's screen, set by VMUPlayerView directly
    /// and offered in NO platform's menu: the skin is the whole
    /// presentation there and a shader picker is exactly the kind of
    /// setting the player deliberately does not have. available(for:)
    /// lists it for no platform, which is load-bearing, not tidiness.
    case vmuLCD

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sharp: return "Plain"
        case .sabr: return "SABR"
        case .crtAperture: return "CRT (aperture)"
        case .crtEasymode: return "CRT (easymode)"
        case .crtMattias: return "CRT (mattias)"
        case .crtBeam: return "CRT (beam)"
        case .crtCaligari: return "CRT (caligari)"
        case .crtGeom: return "CRT (curved)"
        case .lcd: return "LCD 3x"
        case .dotMatrix: return "Dot matrix"
        case .dotMatrixPocket: return "Dot matrix Pocket"
        case .dotMatrixColor: return "Dot matrix"
        case .vmuLCD: return "VMU"
        }
    }

    /// The Metal fragment function this shader draws with. `.sharp` reuses
    /// the frontend's original passthrough function rather than a
    /// `shader_`-prefixed one of its own.
    var fragmentFunctionName: String {
        switch self {
        case .sharp: return "libretro_fragment"
        case .sabr: return "shader_sabr_fragment"
        case .crtAperture: return "shader_crt_aperture_fragment"
        case .crtEasymode: return "shader_crt_easymode_fragment"
        case .crtMattias: return "shader_crt_mattias_fragment"
        case .crtBeam: return "shader_crt_beam_fragment"
        case .crtCaligari: return "shader_crt_caligari_fragment"
        case .crtGeom: return "shader_crt_geom_fragment"
        case .lcd: return "shader_lcd_fragment"
        case .dotMatrix: return "shader_dot_matrix_fragment"
        case .dotMatrixPocket: return "shader_dot_matrix_pocket_fragment"
        case .dotMatrixColor: return "shader_dot_matrix_color_fragment"
        case .vmuLCD: return "shader_vmu_lcd_fragment"
        }
    }

    /// The looks worth offering for a platform, in the TV's order. A look
    /// draws the screen a system was played on, so the CRT looks go only
    /// to the systems played on a television, and the handhelds, which had
    /// their own LCD screens, get LCD 3x, the TV's handheld look, in their
    /// place (found 2026-08-08). The Game Boy adds its green and Pocket dot
    /// matrix screens, and the Game Boy Color its own, which keeps the
    /// game's colours, since a green screen turns a colour game green
    /// (CabinetOS's looks.cpp). Game & Watch, Virtual Boy and Vectrex have
    /// only Plain, so no Look row, as the TV gives them no look: Game &
    /// Watch draws the device's own artwork, so a look would draw over a
    /// photo, and the Virtual Boy's red LED screen and the Vectrex's
    /// vector screen were neither a television nor a grid of pixels.
    ///
    /// Every platform is named, with no default, so a new one has to be
    /// placed here before the app builds: PSP, Game & Watch, Virtual Boy
    /// and Vectrex were added after the handheld rule and got the CRT
    /// looks unseen.
    static func available(for platform: NativePlatform) -> [NativeShader] {
        switch platform {
        case .gb:
            return [.sharp, .sabr, .lcd, .dotMatrix, .dotMatrixPocket]
        case .gbc:
            return [.sharp, .sabr, .lcd, .dotMatrixColor]
        case .gba, .gameGear, .ngpc, .nds, .psp:
            return [.sharp, .sabr, .lcd]
        case .gameAndWatch, .virtualBoy, .vectrex:
            return [.sharp]
        case .arcade, .saturn, .genesis, .segaCD, .masterSystem, .sega32X,
             .tg16, .tgCD, .snes, .nes, .atari7800, .psx, .dreamcast, .n64,
             .atari2600, .threeDO:
            return [.sharp, .sabr, .crtAperture, .crtEasymode, .crtMattias,
                    .crtBeam, .crtCaligari, .crtGeom]
        }
    }

    private static func key(for platform: NativePlatform) -> String {
        "com.mmagtech.RommApp.nativeShader.\(platform.storageKey)"
    }

    /// Stored per platform, not per core: Genesis Plus GX alone serves
    /// four platforms, and a shader chosen for Genesis silently carrying
    /// into Sega CD/Master System/Game Gear was a real, if harmless until
    /// now, instance of the same core-vs-platform storage bug core
    /// options were redesigned around. Fixed alongside the handheld work
    /// since it needed touching this file anyway. A value from a
    /// shader this platform no longer offers (e.g. a CRT choice under a
    /// now-handheld-filtered platform) falls back to Sharp rather than
    /// being trusted.
    static func current(for platform: NativePlatform) -> NativeShader {
        guard let stored = UserDefaults.standard.string(forKey: key(for: platform)),
              var shader = NativeShader(rawValue: stored)
        else { return .sharp }
        // The old "Game Boy" look served both Game Boys; on the Color its
        // successor is the dot matrix that keeps the colours.
        if shader == .dotMatrix && platform == .gbc { shader = .dotMatrixColor }
        return available(for: platform).contains(shader) ? shader : .sharp
    }

    static func setCurrent(_ shader: NativeShader, for platform: NativePlatform) {
        UserDefaults.standard.set(shader.rawValue, forKey: key(for: platform))
    }
}
