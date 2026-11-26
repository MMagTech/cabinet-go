# The phone as the VMU

The Dreamcast's Visual Memory Unit was two devices in one shell: the
memory card, and a tiny handheld with a 48x32 monochrome LCD that games
drew on through the controller (Sonic Adventure's Chao status, Resident
Evil Code: Veronica's hidden health readout) and downloaded whole
minigames onto (Chao Adventure: carry your creature away from the
console, raise it on the go, sync it back). Cabinet Go gives the phone
the second half: it plays those minigames, because a VMU was the thing
you took away from the console.

Everything in this document is settled and built as of 2026-08-29. It
records the design so its boundaries are legible; the reasoning that got
here is compressed, not omitted. Which Dreamcast games show in the
library, and how the card crosses with CabinetOS, is in
[scope-handheld.md](scope-handheld.md).

## The minigame player

When a Dreamcast game's memory card
carries a GAME-type file, that game's launch screen grows a VMU row.
Tapping it boots the card in VeMUlator (core #22, the smallest core in
the app by two orders of magnitude), fullscreen, portrait, with the
phone drawn edge to edge as the VMU itself: cream shell, connector cap,
slate bezel, sage LCD with chunky pixels, a molded cross d-pad that
tilts toward the pressed wing, mint A and lavender B that visibly
depress, SLEEP and MENU pills flanking the speaker grille. The skin is
the feature, and it is a game surface, so the ambient-restraint rule is
not violated. The stamped reference is `spikes/vmu/vmu-skin-mock2.html`,
approved to the pixel; `VMUPlayerView` transcribes it.

## The card is the save

There is no new save type and no new sync path. The VMU player opens
and writes the exact card file RomM already stores as the Dreamcast
game's save (the Flycast row, `<name> (Cabinet).srm`): VeMUlator's
`enable_flash_write` commits every emulated flash write into the file
in real time, so the phone's local card is always current, even through
an app kill, and `VMULauncher.prepare` reconciles any orphaned play
file back into the store's write-first queue before every boot. Uploads
happen on quit and on backgrounding, through the same durable pending
queue every battery save rides. No mid-play uploads: churn without
benefit.

The VMU is never a platform. It does not appear in RomM, the library,
settings, or the emulator picker; the minigame is cargo inside a DC
game's save, and the launch-screen row is the only door.

Play follows the normal remote flow: fetch the latest card, play, upload
on exit. Fully offline works exactly when the card was already on the
phone.

## MENU, SLEEP, and the LED

VeMUlator deliberately ships with the real MODE button disconnected
(its own source documents that clicking MODE without a BIOS hangs the
HLE boot) and never maps SLEEP, so both buttons are frontend-side, and
nothing may ever send `RETRO_DEVICE_ID_JOYPAD_START` to the core:

- **MENU** opens Cabinet's in-player menu (resume, quit), truer to the
  real button's 1999 return-to-menu role than a hard exit. Honest
  labels over museum labels: the pill says MENU because that is what it
  opens.
- **SLEEP** pauses the core and fades the LCD over a deliberate 0.6
  seconds into the sleep animation: a 1-bit pixel Cabinet low in the
  frame, two z's rising one at a time on a 600ms cadence (the stamped
  frames live in `Resources/VMU/`). Tap again to wake. Wholly
  period-appropriate; the real VMU BIOS filled idle screens with little
  animations.
- **The LED** lights for exactly three reasons: a steady ember while
  asleep, lit while MENU is held, one blink as the menu closes. The
  real VMU had no LED; this one is kept as fun and kept quiet.

Buttons give a haptic tick honoring the existing Rumble setting. All
audio comes from the emulated VMU's own beeper through the normal core
audio path; the skin makes no sounds of its own.

## What settled it

The spike (`spikes/vmu/notes-SPIKE.md`, passed 2026-08-29 in an
afternoon): VeMUlator builds untouched, HLE-boots full card images with
no BIOS file, auto-launches the GAME file, and write-through is the
core's default behavior, not something built here. All ten real DC
saves on the server were full 128KB card images; a homebrew game
injected at block 0 of a real card booted with the existing save
intact. Three of the ten cards parse as zero files because those games
never wrote a save (their FATs allocate no user blocks), which is a
fact about the cards, not a parser gap.
