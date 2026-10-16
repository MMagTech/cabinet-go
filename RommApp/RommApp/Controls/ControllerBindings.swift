import GameController

/// Which physical button drives which emulator input.
///
/// One fixed map, CabinetOS's (docs/scope-handheld.md), with no remapping:
/// buttons are matched by position, so the bottom face button sends the
/// same input whatever it is labelled, A on Xbox, Cross on PlayStation, B
/// on a Nintendo pad, and the same input on the phone as on the console.
/// CabinetOS does the same through SDL's positional names
/// (frontend/src/main.cpp, the pad state built per frame).
///
/// This replaces a remappable table built for arcade's six-button fold,
/// which every platform without its own row inherited. On a handheld that
/// put the GBA's L on the right bumper and R on the right trigger, and
/// scrambled the DS and PSP shoulders the same way: the bug PS2 and
/// GameCube were given their own rows for on 2026-09-13, never fixed for
/// the handhelds.
enum ControllerBindings {
    /// GameController element name to RetroPad id.
    static let handheld: [String: Int] = [
        GCInputButtonA: RetroPad.b,             // bottom face
        GCInputButtonB: RetroPad.a,             // right face
        GCInputButtonX: RetroPad.y,             // left face
        GCInputButtonY: RetroPad.x,             // top face
        GCInputLeftShoulder: RetroPad.l,
        GCInputRightShoulder: RetroPad.r,
        GCInputLeftTrigger: RetroPad.l2,
        GCInputRightTrigger: RetroPad.r2,
        GCInputButtonMenu: RetroPad.start,
        GCInputButtonOptions: RetroPad.select,
        GCInputButtonHome: RetroPad.overlay,    // pause menu
    ]

    /// Everything platform-specific about how a pad reaches a game.
    struct PlatformProfile {
        let base: [String: Int]
        /// Whether the left stick is digitized into d-pad presses. True
        /// for every system whose only directional control is a d-pad, so
        /// the stick steers there too. False for PSP, whose nub the core
        /// reads as a true analog value: digitizing it as well would have
        /// one thumb press the nub and the d-pad at once, two separate
        /// controls on the real console (the same reason Dreamcast's Rush
        /// 2049 turned the camera while steering, 2026-08-16).
        let digitizesLeftStick: Bool
    }

    /// `platform` is the running game's `NativePlatform` raw value, or nil
    /// in the shell.
    static func profile(for platform: String?) -> PlatformProfile {
        // A plain string rather than NativePlatform.psp: the layout editor
        // compiles this file without the cores.
        PlatformProfile(base: handheld, digitizesLeftStick: platform != "psp")
    }

    /// The map a controller uses. The same for every pad model now that
    /// nothing is remappable; per-controller edits saved by older builds
    /// are ignored.
    static func effective(for controller: String, platform: String? = nil) -> [String: Int] {
        profile(for: platform).base
    }
}

/// The pause menu's second door, alongside the Home button: both stick
/// clicks held together, as on CabinetOS. Home alone is not enough: iOS
/// reserves some pads' Home button for its own accessory picker, and a
/// single button a thumb might rest on is one accidental press from
/// pausing a game. Clicking both sticks at once has no gameplay meaning on
/// any handheld, so it can never collide with play.
enum MenuHotkey {
    static let buttonA = GCInputLeftThumbstickButton
    static let buttonB = GCInputRightThumbstickButton
}

/// RetroPad ids, confirmed against the EmulatorJS 4.2.3 bundle and the
/// standard libretro joypad ordering.
enum RetroPad {
    static let b = 0, y = 1, select = 2, start = 3
    static let up = 4, down = 5, left = 6, right = 7
    static let a = 8, x = 9, l = 10, r = 11
    static let l2 = 12, r2 = 13

    /// Not a game input: opens the pause menu. The Home button sends it;
    /// both stick clicks together (`MenuHotkey`) are the second way in, for
    /// pads whose Home button iOS keeps for itself.
    static let overlay = -1

    /// EmulatorJS's own indices for its first and second analog sticks (16
    /// to 19, 20 to 23), confirmed against its source, not the standard
    /// RetroPad table above, and confirmed generic to the bridge itself
    /// rather than particular to any one core: N64's stick and C-buttons use
    /// them, Virtual Boy's second d-pad uses the same block for its own
    /// control scheme, and FBNeo's arcade cores route a twin-stick game's
    /// second joystick through the identical right-analog-stick indices.
    /// Anything in this range must go through `PlayerView.Input.send`'s
    /// magnitude path, `__cm`, never the boolean `__ci` one: EmulatorJS
    /// reads both through the same analog dispatch regardless of source.
    static func isAnalogAxis(_ id: Int) -> Bool { (16...23).contains(id) }
}
