import UIKit

/// What colour each control is drawn in.
///
/// Muscle memory is colour based: people remember the red button, not
/// button one. Colours are computed from the layout's system and the input
/// id rather than stored in the layout files.
///
/// Only action buttons take colour. Start, Menu, the shoulders and the
/// stick stay neutral: they are not what a hand reaches for mid game, and
/// colouring everything would leave nothing to distinguish.
enum ControlTheme: String, CaseIterable {
    /// The colours the real hardware had, where the hardware had opinions.
    case system
    /// Every control the same neutral white, for anyone who finds colour
    /// noisy over game art.
    case monochrome

    static let key = "com.mmagtech.RommApp.controlTheme"

    static var current: ControlTheme {
        UserDefaults.standard.string(forKey: key).flatMap(ControlTheme.init) ?? .system
    }

    var label: String {
        switch self {
        case .system: return "System colours"
        case .monochrome: return "Monochrome"
        }
    }

    /// The tint for one control, or nil when it should stay neutral.
    ///
    /// Hues are chosen to survive the low fill opacity these controls are
    /// drawn at: saturated and mid bright, since a pale colour at 30 percent
    /// over bright game art is indistinguishable from white.
    func tint(system: String, input: Int?) -> UIColor? {
        // Ahead of the theme guard on purpose. Monochrome strips
        // decoration, never information: text labels render in both
        // themes, and the 2600's one button carries no text at all
        // because the real CX40's red dome said nothing. The red IS
        // that button's label, so it survives monochrome the same way
        // the "A" printed on a SNES button does. Every other tint in
        // this file is decoration over a labelled control and stays
        // behind the guard.
        if system == "atari2600", input == RetroPad.b { return .neoRed }
        guard self == .system, let input else { return nil }

        switch system {
        // Super Famicom's four colours, which the American SNES dropped and
        // most people picture anyway. "snes" was missing from this case for
        // as long as the theme existed, so the one console these colours
        // belong to drew plain white while every unknown platform got them.
        case "default", "snes":
            switch input {
            case RetroPad.a: return .neoRed
            case RetroPad.b: return .neoYellow
            case RetroPad.x: return .neoBlue
            case RetroPad.y: return .neoGreen
            default: return nil
            }
        // The DMG's two buttons were the same magenta, so they stay the same
        // here: telling them apart was never the colour's job.
        case "gb":
            switch input {
            case RetroPad.a, RetroPad.b: return .dmgMagenta
            default: return nil
            }
        // The shape colours on every DualShock ever made: green triangle,
        // red circle, blue cross, pink square. The layouts share ids, so
        // one case covers both.
        case "psx", "psp":
            switch input {
            case RetroPad.x: return .psTriangle
            case RetroPad.a: return .psCircle
            case RetroPad.b: return .psCross
            case RetroPad.y: return .psSquare
            default: return nil
            }
        // The N64 pad's blue A, green B, and yellow C cluster.
        //
        // Matched on the raw ids n64.json actually sends, not the generic
        // RetroPad.a/b/x/l/r constants: N64's real A and B are bound to
        // RetroPad's B and Y slots to match what mupen64plus-libretro-nx
        // reads (0/1), and the four C-buttons ride X/A/L/R (9/8/10/11)
        // rather than a second analog stick, per that file's own comment.
        case "n64":
            switch input {
            case 0: return .n64Blue
            case 1: return .n64Green
            case 9, 8, 10, 11: return .n64Yellow
            default: return nil
            }
        // The NES brick's two red squares, same colour on purpose, like
        // the Game Boy's magenta.
        case "nes":
            switch input {
            case RetroPad.a, RetroPad.b: return .nesRed
            default: return nil
            }
        // Saturn deliberately absent: its common pads (Japanese grey, US
        // black) have plain black buttons, and the colourful A/B/C pad is
        // a later variant, so the hardware has no one opinion to honour.
        default:
            return nil
        }
    }

}

private extension UIColor {
    static let neoRed = UIColor(red: 0.93, green: 0.24, blue: 0.24, alpha: 1)
    static let neoYellow = UIColor(red: 0.98, green: 0.80, blue: 0.20, alpha: 1)
    static let neoGreen = UIColor(red: 0.30, green: 0.82, blue: 0.42, alpha: 1)
    static let neoBlue = UIColor(red: 0.29, green: 0.56, blue: 0.98, alpha: 1)
    static let dmgMagenta = UIColor(red: 0.80, green: 0.31, blue: 0.55, alpha: 1)

    static let psTriangle = UIColor(red: 0.25, green: 0.78, blue: 0.52, alpha: 1)
    static let psCircle = UIColor(red: 0.94, green: 0.35, blue: 0.32, alpha: 1)
    static let psCross = UIColor(red: 0.42, green: 0.62, blue: 0.95, alpha: 1)
    static let psSquare = UIColor(red: 0.93, green: 0.48, blue: 0.70, alpha: 1)
    static let n64Blue = UIColor(red: 0.28, green: 0.47, blue: 0.94, alpha: 1)
    static let n64Green = UIColor(red: 0.30, green: 0.78, blue: 0.40, alpha: 1)
    static let n64Yellow = UIColor(red: 0.96, green: 0.78, blue: 0.20, alpha: 1)
    static let nesRed = UIColor(red: 0.86, green: 0.24, blue: 0.22, alpha: 1)
}
