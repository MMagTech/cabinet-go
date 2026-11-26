// The controls lab: runs GameControllerManager's real direction state
// machines and ControllerBindings' fixed map headless in the iOS
// simulator, driving them through the DEBUG test seam exactly the way a
// physical pad's handlers do. Built after 2026-08-20, when an
// experimental per-frame poll cleared stick-held directions and killed
// the left stick: the class of bug this file exists to catch before a
// device ever sees it.
//
// Build and run: tools/lab/controls/run.sh (simctl spawn on a booted
// simulator; no UI, exit code 0 on green).

import Foundation
import GameController

@MainActor
func runTests() -> Int {
    var failures = 0
    func check(_ cond: Bool, _ name: String) {
        if cond { print("PASS  \(name)") } else { failures += 1; print("FAIL  \(name)") }
    }

    let mgr = GameControllerManager.shared
    var events: [(player: Int, id: Int, down: Bool)] = []
    var stickEvents: [(player: Int, x: Float, y: Float)] = []
    mgr.send = { player, id, down in events.append((player, id, down)) }
    mgr.sendStick = { player, x, y in stickEvents.append((player, x, y)) }
    func reset() { events.removeAll(); stickEvents.removeAll() }

    // 1. The regression class: on a digitizing platform, no other
    // source's release may drop a stick-held direction.
    mgr.activePlatform = "gba"
    reset()
    mgr._testInjectStick(x: 1.0, y: 0)
    check(events.contains { $0 == (0, RetroPad.right, true) },
          "gba: stick right presses the direction")
    reset()
    mgr._testInjectDpad(RetroPad.right, down: false)
    check(events.isEmpty,
          "gba: phantom d-pad release cannot drop a stick-held direction")
    mgr._testInjectDpad(RetroPad.right, down: true)
    check(events.isEmpty,
          "gba: d-pad press on an already-held direction emits nothing")
    mgr._testInjectDpad(RetroPad.right, down: false)
    check(events.isEmpty,
          "gba: d-pad release while the stick still holds emits nothing")
    mgr._testInjectStick(x: 0, y: 0)
    check(events.contains { $0 == (0, RetroPad.right, false) },
          "gba: stick release finally releases the direction")

    // 2. Union the other way round: the stick may not drop a d-pad hold.
    reset()
    mgr._testInjectDpad(RetroPad.left, down: true)
    check(events.contains { $0 == (0, RetroPad.left, true) },
          "gba: d-pad press reaches the game")
    reset()
    mgr._testInjectStick(x: -1.0, y: 0)
    check(events.isEmpty,
          "gba: stick engaging an already-held direction emits nothing")
    mgr._testInjectStick(x: 0, y: 0)
    check(events.isEmpty,
          "gba: stick release while the d-pad still holds emits nothing")
    mgr._testInjectDpad(RetroPad.left, down: false)
    check(events.contains { $0 == (0, RetroPad.left, false) },
          "gba: d-pad release finally releases the direction")

    // 3. Hysteresis: engage above 0.5, hold through 0.45, release below
    // 0.4.
    reset()
    mgr._testInjectStick(x: 0.45, y: 0)
    check(events.isEmpty, "hysteresis: 0.45 does not engage")
    mgr._testInjectStick(x: 0.6, y: 0)
    check(events.contains { $0 == (0, RetroPad.right, true) }, "hysteresis: 0.6 engages")
    reset()
    mgr._testInjectStick(x: 0.45, y: 0)
    check(events.isEmpty, "hysteresis: held through 0.45")
    mgr._testInjectStick(x: 0.3, y: 0)
    check(events.contains { $0 == (0, RetroPad.right, false) }, "hysteresis: 0.3 releases")

    // 4. The stick's analog value always flows, with y turned to
    // libretro's down-positive convention.
    reset()
    mgr._testInjectStick(x: 0.2, y: 0.7)
    check(stickEvents.contains { $0.player == 0 && $0.x == 0.2 && $0.y == -0.7 },
          "gba: analog value reaches sendStick, y flipped")
    mgr._testInjectStick(x: 0, y: 0)

    // 5. PSP reads the nub as analog and does not digitize it, so one
    // thumb never works the nub and the d-pad at once.
    mgr.activePlatform = "psp"
    reset()
    mgr._testInjectStick(x: 1.0, y: 0)
    check(!events.contains { $0.id == RetroPad.right },
          "psp: stick presses no d-pad direction")
    check(stickEvents.contains { $0.player == 0 && $0.x == 1.0 },
          "psp: analog value reaches sendStick")
    mgr._testInjectStick(x: 0, y: 0)
    reset()
    mgr._testInjectDpad(RetroPad.up, down: true)
    check(events.contains { $0 == (0, RetroPad.up, true) },
          "psp: the d-pad still presses directions")
    mgr._testInjectDpad(RetroPad.up, down: false)

    // 6. A mode change mid-hold releases the stick's claims.
    mgr.activePlatform = "gba"
    reset()
    mgr._testInjectStick(x: 1.0, y: 0)
    check(events.contains { $0 == (0, RetroPad.right, true) }, "transition: held on gba")
    reset()
    mgr.activePlatform = "psp"
    check(events.contains { $0 == (0, RetroPad.right, false) },
          "transition: switching to psp releases the held direction")
    mgr._testInjectStick(x: 0, y: 0)
    mgr.activePlatform = nil

    // 7. Players are independent.
    mgr.activePlatform = "gba"
    reset()
    mgr._testInjectStick(x: 1.0, y: 0, player: 1)
    check(events.contains { $0 == (1, RetroPad.right, true) }, "p2: stick right presses")
    check(!events.contains { $0.player == 0 }, "p2: no bleed into player 1")
    mgr._testInjectDpad(RetroPad.right, down: false, player: 0)
    mgr._testInjectStick(x: 0, y: 0, player: 1)
    check(events.contains { $0 == (1, RetroPad.right, false) }, "p2: release")

    // 8. One fixed map, by position: the bottom face button is the
    // RetroPad's B whatever it is labelled, as on CabinetOS.
    let map = ControllerBindings.handheld
    check(map[GCInputButtonA] == RetroPad.b && map[GCInputButtonB] == RetroPad.a
          && map[GCInputButtonX] == RetroPad.y && map[GCInputButtonY] == RetroPad.x,
          "map: faces by position (bottom B, right A, left Y, top X)")
    check(map[GCInputLeftShoulder] == RetroPad.l && map[GCInputRightShoulder] == RetroPad.r,
          "map: bumpers are L and R")
    check(map[GCInputLeftTrigger] == RetroPad.l2 && map[GCInputRightTrigger] == RetroPad.r2,
          "map: triggers are L2 and R2")
    check(map[GCInputButtonMenu] == RetroPad.start && map[GCInputButtonOptions] == RetroPad.select,
          "map: Menu is Start, Options is Select")
    check(map[GCInputButtonHome] == RetroPad.overlay, "map: Home opens the pause menu")
    check(map[MenuHotkey.buttonA] == nil && map[MenuHotkey.buttonB] == nil,
          "map: the stick clicks carry no game input, only the menu hotkey")

    // 9. Every platform gets the same map; only PSP stops digitizing.
    for p in ["gb", "gbc", "gba", "gameGear", "ngpc", "nds", "gameAndWatch", "unknownfuture"] {
        let prof = ControllerBindings.profile(for: p)
        check(prof.base == map && prof.digitizesLeftStick,
              "profile[\(p)]: the fixed map, digitizing on")
    }
    check(ControllerBindings.profile(for: nil).base == map
          && ControllerBindings.profile(for: nil).digitizesLeftStick,
          "profile[nil, the shell]: the fixed map, digitizing on")
    let psp = ControllerBindings.profile(for: "psp")
    check(psp.base == map && !psp.digitizesLeftStick,
          "profile[psp]: the fixed map, digitizing off")

    // 10. No pad model gets a map of its own: nothing is remappable.
    check(ControllerBindings.effective(for: "Xbox Wireless Controller") == map
          && ControllerBindings.effective(for: "DualSense Wireless Controller", platform: "psp") == map
          && ControllerBindings.effective(for: "unknown", platform: "nds") == map,
          "effective: every pad and platform resolves to the fixed map")

    // 11. A platform change releases anything held, so no press can
    // straddle a game change and orphan its release.
    mgr.activePlatform = "gba"
    reset()
    mgr._testInjectDpad(RetroPad.up, down: true)
    check(events.contains { $0 == (0, RetroPad.up, true) }, "switch: held before the change")
    reset()
    mgr.activePlatform = "nds"
    check(events.contains { $0 == (0, RetroPad.up, false) },
          "switch: platform change releases held inputs")
    mgr.activePlatform = nil

    print(failures == 0 ? "ALL GREEN" : "\(failures) FAILURES")
    return failures
}

exit(Int32(MainActor.assumeIsolated { runTests() }))
