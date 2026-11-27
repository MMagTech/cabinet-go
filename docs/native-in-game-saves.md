# In-game saves in the native player

How the phone keeps a game's own saves and its save states, and what each
core taught on the way, so the findings do not have to be rediscovered.
The plan these follow is the save channels part of
[scope-handheld.md](scope-handheld.md).

## Two different things both called saving

A **save state** is a snapshot of the whole machine, the emulator equivalent
of a bookmark. In Cabinet Go a save state only ever happens when someone
taps Save state in the pause menu. Nothing writes one automatically.

An **in-game save** is the game saving itself, through whatever the real
hardware had: a battery inside the cartridge, a flash chip, a memory stick,
a VMU. It is what happens when you save inside Zelda or Pokémon, and it is
what a player assumes is safe once the game says it saved.

## How saves move

Both go to RomM 5.5's save channels, exactly as CabinetOS sends them, so a
game saved on the phone carries on at the TV and back. The code is a port
of CabinetOS's, file for file:

| Job | The phone | CabinetOS |
|---|---|---|
| Which save a start continues from | `Native/SavePick.swift` | `savepick` |
| What a game owes RomM, where it is aimed, RomM's answers | `Native/SavePush.swift` | `savepush` |
| RomM's channels and saves as last seen, the snapshot held | `Native/SaveMirror.swift` | `savemirror` |
| RomM's words for channels and snapshots | `Auth/RommSnapshots.swift` | `romm_snapshots`, `romm_types.h` |
| RomM's content hash | `Native/SaveHash.swift` | `romm::contentHash` |
| Each core's save and the form it travels in | `Native/SaveForm.swift` | `savetable`, `toOwnForm` |
| A sitting's saves gathered and put back | `Native/GameSaves.swift` | `saves.cpp` |

`tools/lab/lab check saves` runs CabinetOS's own case tables for the rule
and the push against these files in the simulator, with RomM's answers as
the write-test RomM gave them.

The start runs before the core loads (`NativeLauncher.finishLaunch`): a
file or a folder save is put in place there, and a battery is seated as the
first frame runs (`GameSaves.seat`). The phone's own copy is written at the
pause menu, at background and at Quit; what changed is sent at background
and at Quit, and anything that waited goes at the next foreground with a
connection. A state is written on the phone first and goes inside the
game's snapshot.

## Each core's save

Every extra file a core keeps beside a save travels with it, each core read
in its pinned source:

| System | Core | The save | Notes |
|---|---|---|---|
| Game Boy, Game Boy Color | Gambatte | battery, with its 8-byte clock | One zip of `<game>.srm` and `<game>.rtc`. A clock that only ticked is no new save. |
| Game Boy Advance | mGBA | battery | The libretro core keeps no clock file at the pin. |
| Game Gear | Genesis Plus GX | battery | |
| Neo Geo Pocket Color | Beetle NeoPop | `<game>.flash` | Written only as the game closes. |
| Nintendo DS | melonDS | `<game>.sav` | Flushed two seconds after the game's last write, and at unload through Cabinet's patch. |
| PSP | PPSSPP | `PSP/SAVEDATA` folders | One zip rooted at SAVEDATA. |
| Dreamcast VMU | VeMUlator | the 128 KB card | Pushed as Flycast's save under `flycast-native`. |
| Game & Watch | gw-libretro | none | No saves and no states. |

## What each core teaches

- **Game Boy Advance**: the battery's size is unstable early on, reporting
  the 128 KB maximum until the core has worked out which save type the game
  uses. A shorter save is the same save with the rest blank, so two reads
  are compared that way (`SaveForm.sameBattery`), and restoring copies the
  smaller of the save and the region.
- **Game Gear**: Genesis Plus GX starts its battery at 64 KB and trims it
  once the game runs; save RAM that was never written reports zero.
- **Game Boy and Game Boy Color**: the real-time clock lives in a separate
  region. Saving only the battery loses the clock, which Pokémon Gold and
  Silver depend on.
- **Neo Geo Pocket**: Beetle NeoPop writes its flash file only inside
  `retro_unload_game`, so a sitting iOS ends before Quit loses what was saved
  since launch, as it does on the TV after a crash. The file starts with
  NeoPop's id, `0x0053`.
- **Nintendo DS**: stock `retro_unload_game` never flushed, so a save made
  less than two seconds before quitting was dropped. Cabinet's core build
  patches the final flush in (`tools/build-core.sh`). A DS file is a power
  of two from 512 bytes to 32 MB; DeSmuME's is 122 bytes longer and is not
  this core's.
- **A file a core wrote is kept even when the app is ended**: a file or
  folder save that changed since it was last put in place or sent is owed
  at the next start, before the pick, so an older copy is never written
  over it.

## The stale cache, worth knowing before testing sync

Cross-device sync once appeared to work per platform and then failed on the
one game played over and over. RomM sends ETag and Last-Modified but no
Cache-Control, and paths like `/api/saves/{id}/content` do not change when
the bytes behind them do, so URLSession applied HTTP heuristic freshness
and answered from its own store without contacting the server. Requests
bypass the cache (`reloadIgnoringLocalCacheData` in `RommClient.request`).

Two lessons for the next person testing sync. A first fetch on a device is
always cold and always looks correct, so a single pass per system proves
nothing about staleness; play the same game several times. And a save that
reaches the core being valid is not enough, since a stale save is perfectly
valid: compare it against what RomM holds now.
