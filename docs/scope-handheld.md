# Cabinet the handheld, scope

Status: decided 2026-10-15, built in part. Steps 1 and 2 of the order
of work below are done, the gate in part (the allowlist, the platform
name fix, the fixed controller map and the PSP save layout), step 4
in part (the webview, arcade's data and the console cores themselves;
their code paths inside the shared files remain), and saves through
RomM's save channels (below). This document is the plan for
Cabinet 2.0 and the removals around it. Where it disagrees with an older
scope doc or with CLAUDE.md, this document is the newer decision, and
those files are rewritten to match in the last phase below.

## What Cabinet becomes

Cabinet is the handheld half of a pair. CabinetOS
([MMagTech/cabinetos](https://github.com/MMagTech/cabinetos)) is the
console: a small PC under the television, running every system up to
the Switch, with real JIT, four players, Wii Remotes and light guns.
Cabinet on the iPhone runs the systems that were made to be held, and
nothing else. Console games still reach the phone, by streaming from
CabinetOS with Moonlight, at home or away.

The test for any system, now and later, is one question: was it played
in your hands? The Game Boy, the PSP and Game & Watch pass. The Virtual
Boy does not, even though its box called it portable, because it sat on
a stand on a table. A rule anyone can apply in one second is the point;
a blurrier line would be argued about one system at a time forever.

Why the split is right, so it is not reopened without a new reason:

- Apple allows no JIT in an App Store app, so every system that needs a
  dynamic recompiler was always going to be second best on the phone
  and the Apple TV. CabinetOS has no such limit.
- Most of Cabinet's complexity came from what is leaving: arcade, three
  platforms through shared files, the webview, remapping. What remains
  is the part that is easiest to make excellent.
- iOS has never been on the App Store, so the reshape happens before
  launch rather than taking things away from people later.

The cost, stated plainly: console games on the phone now need the
console at home to be reachable. SNES on a plane is no longer possible.
That is accepted.

## The handheld set

| System | Core | Emulator tag | Notes |
|---|---|---|---|
| Game Boy, Game Boy Color | Gambatte | `gambatte-native` | Clock carts also write `.rtc` |
| Game Boy Advance | mGBA | `mgba-native` | Cartridge sensors stay (WarioWare Twisted) |
| Nintendo DS | melonDS | `melonds-native` | Two screens, touch |
| PSP | PPSSPP | `ppsspp-native` | The only hardware-rendered core left, through ANGLE |
| Game Gear | Genesis Plus GX | `gpgx-native` | |
| Neo Geo Pocket Color | Beetle NeoPop | `ngp-native` | The same core runs the mono Neo Geo Pocket |
| Game & Watch | gw-libretro | none | iOS only; CabinetOS leaves it out, so no continuity |
| Dreamcast VMU | VeMUlator | the card's `flycast-native` row | Minigames only, see below |

RomM's platform aliases map into this set so the filter never hides a
playable game: `nintendo-dsi`, `nintendo-ds-lite` and `nintendo-dsi-xl`
resolve to the DS core (today they are unmapped and fall to the
webview), and both Neo Geo Pocket slugs resolve to Beetle NeoPop, as
`NativeCore.swift` already does for them.

Lynx and WonderSwan pass the test and are not in the set. Each needs a
native core, and under the continuity rule below it lands on CabinetOS
first. That is a later addition, not part of 2.0.

### Leaving

Arcade (FBNeo and MAME 2003-Plus), N64, Dreamcast gameplay, PlayStation,
Saturn, Sega CD, 32X, 3DO, NES, SNES, Genesis and Master System, PC
Engine and TurboGrafx-CD, Atari 2600 and 7800, Vectrex, Virtual Boy, and
every system that only ran in the webview.

With them go the experimental cores switch, light guns, tilt as an
arcade stick, the arcade control profile chain and its 59 layouts, the
arcade masters workflow, NVRAM sync, multi-disc, PS1 memory cards and
most firmware handling (GBA and DS firmware is optional).

## The library shows only what plays

This reverses the rule from 2026-09-01 that browsing stays unfiltered so
an unsupported game keeps its launch screen and its Keep route to the
file. That rule served a phone that was one of three Cabinet apps. Now
RomM's own web page is the place to fetch a file, and CabinetOS plays
everything else.

One allowlist, checked in one place (`PlatformSupport`), decides every
surface: the platform list, search, collections, favourites, the
recently played and recently added shelves, Home's resume hero, the
widget and Spotlight. A collection with no handheld games in it is
hidden. Recently played matters most: a game just played on CabinetOS
must not appear as something the phone can resume.

The unsupported state and everything that only existed for it go away:
the export-only launch screen, the keyboard computer checks, the
"cannot play this" copy.

### Dreamcast, for its VMU

Dreamcast stays in the library, showing only the games whose memory card
holds a VMU minigame, and Play opens the VMU player. Chao Adventure is
found under Sonic Adventure, where anyone would look for it.

- The filter is the minigame, not the card. Most Dreamcast games save to
  the VMU without putting a game on it, and a card with no minigame
  would open to nothing. The check already exists, as the VMU exception
  in `PlatformSupport.canPlay`.
- To find them: each Dreamcast game's card, the save a start would
  continue from under `flycast-native` (`SavePick`), looked through for
  a game file, the answer kept against that save's content hash.
- When no card qualifies, the platform does not appear at all.
- The label says VMU ("Dreamcast VMU", or the VMU in place of the disc
  art), so nobody opens it expecting Dreamcast gameplay.
- CabinetOS's Flycast keeps the card as the game's save in its save
  channel under `flycast-native`, the save the VMU player reads and
  writes, so the Chao loop crosses between the two apps by the one rule
  for every save. A VMU holds one minigame at a time, so each game's
  card is whatever was on the VMU when that game was last played. The
  newest card wins, as one physical VMU did.

## Platform names: the RomM 5.3.0 break

Since RomM 5.3.0, `/api/config` returns `PLATFORMS_VERSIONS` with every
key lowercased (`_validated_platform_map` in
`backend/config/config_manager.py`). Cabinet looks the table up with the
folder name in its original case, so "Game Boy" misses "game boy",
falls back to "game boy" as a slug, and nothing knows it. On a 5.3.1
server 30 of 38 platforms resolve wrong and show as unsupported.

The lookup lives at `LibraryModels.swift` (`canonicalPlatformSlug`) and
`LibraryView.swift` (`isSupported`). The fix lowercases the keys once
where `Session` stores the table, keeping an exact-case lookup as the
fallback for 5.1 and 5.2 servers. It goes into 2.0, since the allowlist
reads the same value. `docs/checking-romm-compatibility.md` gains a
step that runs real slug resolution on the live `/api/config` and
`/api/platforms`, because a check of field names and types missed this.

## Controls

The model is CabinetOS's: no mapping screen at all, buttons matched by
position, so the bottom face button does the same thing whatever it is
labelled and on whichever app.

| Pad | RetroPad |
|---|---|
| Bottom face (A on Xbox, Cross, B on Nintendo) | B |
| Right face | A |
| Left face | Y |
| Top face | X |
| Left bumper, right bumper | L, R |
| Left trigger, right trigger | L2, R2 |
| Stick clicks | L3, R3 |
| Menu, Options | Start, Select |

The pause menu opens from the Home button as today, and from both stick
clicks together, as on CabinetOS.

This fixes a live bug. `ControllerBindings.profile(for:)` gives every
platform without its own row the arcade six-button fold, so on a pad
today the GBA's L sits on the right bumper, R on the right trigger, and
the left bumper sends nothing the GBA uses. DS and PSP shoulders are
scrambled the same way. PS2 and GameCube were fixed for this on
2026-09-13; the handhelds never were.

Also to settle: the default profile digitizes the left stick into d-pad
presses, so on PSP the nub may press the d-pad as well as move the
analog stick, the problem the N64 and PS2 rows exist to prevent. PSP
gets a row with digitizing off if so.

Leaving: the remap screen, the two arcade presets, per-controller saved
edits, and the configurable pause-menu buttons. CLAUDE.md's rule that
controller changes are verified on Smash TV leaves with arcade; its
replacement is a PSP game that uses the nub, the only analog stick left.

Touch layouts drop from 85 files to 8: `gb`, `gba`, `nds`, `psp`,
`gamegear`, `ngpc`, `gw` and `default`. Each loses its
`companionItems`, which existed for the phone-as-controller feature, and
keeps portrait and landscape.

## Continuity with CabinetOS

The only promise: where a system exists on both, save states and memory
work between the two, both ways. Systems on one side only promise
nothing.

CabinetOS is the reference. For every shared system, Cabinet matches
CabinetOS's core, pinned revision, emulator tag, file names and the
option values that change what a save state holds, never the other way
round. CabinetOS already builds its libretro cores at the commits in
`docs/core-manifest.json` and writes Cabinet's tags and row names, so
most of the contract is in place. What is left:

- **Saves and states go through RomM's save channels**, the way
  CabinetOS sends them, with the same tags, the same file names and
  the same zip layouts (below).
- **Option values that touch state.** Compare each handheld core's
  options with CabinetOS's `cores/options/<core>.txt` and its overrides
  in `catalog.cpp`, and adopt CabinetOS's value wherever a difference
  reaches the save state. Known: Cabinet sends `ngp_language=english`
  explicitly, CabinetOS leaves the core default. Display-only options
  (mGBA frame blending, Game Boy colorization) do not matter.
- **Recompiler against interpreter cannot be matched.** CabinetOS runs
  DS and PSP with recompilers; iOS cannot. A state holds the machine,
  not the CPU engine, and CabinetOS has already cross-loaded a Tetris DS
  state, but only Game Boy and that DS test are proven so far.
- **Local core edits.** The three cores with unscripted edits (FBNeo,
  Mupen64Plus, Flycast) all leave. melonDS keeps its scripted SRAM flush
  patch, which does not touch the state format.

The proof is a cross-app test on real devices: for each system in the
set, a save state made on the phone loaded on CabinetOS and the
reverse, and one in-game save each way. The VMU card gets the Chao
round trip.

## RomM save channels

Built 2026-11-26 (step 5), the same way CabinetOS uses them since its
2026.11.22.2 build, and on the same RomM: 5.5.0-beta.1 or newer, which
says so in its heartbeat (`SAVE_SYNC`). On an older RomM the phone
neither reads nor writes saves, says nothing, and sends what waited once
the server is updated. RomM's code at that tag is the line, as its
documentation still describes 5.4's slots.

- **Which save a game starts from:** CabinetOS's one rule, ported whole
  (`SavePick.swift`, from its `savepick`): the newest save RomM holds for
  the person that the phone can use, in any channel, by when it was made.
  Nothing is asked. A save the phone still owes is sent first and then
  weighed. Another emulator's save is asked of RomM in the phone's form
  and checked. RomM's rows from before channels are not read.
- **Where it saves:** into the channel it continued from, else the
  person's "default", made when missing; "softcore" beside a hardcore
  one; a push RomM keeps as a branch goes on top only when the phone's
  save was made later (`SavePush.swift`, from its `savepush`).
- **When:** at Quit, and when the app goes to the background, since iOS
  can end a backgrounded app with no warning. The phone's own copy is
  written first every time; nothing changed, nothing sent. What waited
  goes at the next foreground with a connection.
- **States:** written on the phone first and sent inside the game's
  snapshot. The game offers the three newest under the core's tag
  wherever they are on RomM, so a state made on the TV is among the
  phone's three and the other way round.
- **Each phone is its own RomM device** (client `cabinet-go`); every
  CabinetOS console is one device of its own.
- **Nothing is deleted on RomM.** RomM owns looking at and deleting
  saves; going back to an older one is "Restore as current" on RomM's
  website.

Sigil's coverage of the set, at the commit RomM 5.5.0-beta.1 builds in:
Game Boy and Game Boy Color are converted, clock included; PSP and the
Dreamcast VMU are synced; GBA, DS, Game Gear and Neo Geo Pocket pass
through as stored, so another app's save is used only when the same
emulator made it. Sigil names Neo Geo Pocket `mednafen_ngp`.

## Removed alongside

**tvOS and the Mac** are gone, not frozen, decided 2026-10-15. Their
TestFlight builds are expired and their GitHub releases deleted; the
git tags stay, since the history is public on purpose. The tvOS App
Store version was approved but never had availability set, so it was
never downloadable. Their targets, the top shelf extension, and the
Mac and tvOS copies of ANGLE leave `dev`.

**The webview player**, about 4,000 lines, iOS only: `PlayerView.swift`,
`EmulatorCacheBridge.swift`, `BootCurtain.swift`, `CoreHints.swift`,
`PlayerNetworkLog.swift`, the web parts of `LaunchChoices`,
`LaunchModels`, `GameLaunchView`, `StorageView` and `HomeView`, and
`cores.json`. EmulatorJS states never load in a native core, so the
continuity rule needs it gone anyway.

**The phone as a controller**: pairing, controller-only guest mode, the
live VMU screen, phone light gun aim, and the netplay design. It was
never verified on hardware, and CabinetOS answers the same needs with
real pads, Wii Remotes and Sinden light guns. The standalone VMU
minigame player stays.

## Data already on phones

Persisted data changes need their migration decided now, not found as
loss later.

Saves are not migrated (decided 2026-11-26: saves and states already on
phones may be lost). The first start of the save channels build deletes
the old slot model's stores: `MemoryCards/` with its `meta.json`, and
each kept game's `pending-states` folder and cached `state.dat`,
anything still owed in them included (`GameSaves.removeOldStores`). The
per-game `CoreSaves/` folders stay: they are what the cores read.

The first launch of 2.0 also:

1. Removes, per leaving platform: kept downloads and their Files mirror
   entries and core save folders.
2. Clears the webview's EmulatorJS cache and the dead settings: the
   experimental cores switch, per-game player choice, the arcade core
   choice, saved controller bindings and hotkey buttons.

## Order of work

Each step builds, gets played on a phone, and is its own commit or
small set of commits. The plan was to delete nothing until the gate had
shipped and been lived with; on 2026-11-26 the deletions came first
instead, since no phone can start a leaving system once the allowlist is
in. The save channels build (2026-11-26) removed the old save code with
the leaving systems' save paths: saves on phones are not migrated (Data
already on phones, below).

1. Tag the current `dev` as `pre-handheld`.
2. Take the tvOS and Mac targets out of the project, so later deletions
   from shared files need to keep only one app compiling.
3. **Cabinet 2.0, the gate.** The handheld allowlist on every surface,
   the platform name fix, the Dreamcast VMU view, the fixed controller
   map, the PSP save layout, the data migration. Version 2.0.0, tag
   `ios-v2.0.0`. TestFlight first, to the External Testers group
   explicitly (uploading does not distribute), before the current
   builds expire around 2026-12-03.
4. Delete in layers, least tangled first: the webview; the pairing
   pieces, after checking what the touch controls share with them;
   arcade; the console cores and their static libraries (the VMU player
   keeps the `flycast-native` card handling); the shared render path,
   keeping only what PSP needs.
5. Options alignment and the cross-app test.
6. Docs: CLAUDE.md (project shape, platform boundaries, blast radius,
   the controller rule, the FBNeo rule, the tvOS and Mac Catalyst
   sections), README with its tvOS and Mac links removed, ROADMAP,
   `licenses.md`, `checking-romm-compatibility.md`.

Each layer is tested on the whole set, not one game: Game Boy (software
rendered), PSP (the hardware render path), DS (two screens and touch)
and the VMU (its card rides on Dreamcast's save handling).

## App Review

The 1.0.1 submission was not rejected for a defect: under Guideline 2.1
App Review asked for a list of the supported emulators, because the
description said twenty-three. 2.0 answers that up front in the review
notes: mGBA, Gambatte, melonDS, PPSSPP, Genesis Plus GX, Beetle NeoPop,
gw-libretro and VeMUlator, all compiled into the app, no code
downloaded, no games included. The description is rewritten for the
handheld, since it currently promises an Apple TV app, the iPhone as a
controller and arcade.

Review ran on an iPad Air in compatibility mode, although the app is
iPhone only, so 2.0 is checked there too.

The app record has no availability set in any territory. 2.0 needs
countries chosen in Pricing and Availability or it will not be on sale
either, and since iOS and tvOS share the record, setting availability
may expose the old tvOS version again. Settle that at release, through
Last-Compatible Version Settings or with Apple.

## Open

- The exact VMU label.
- Whether the PSP nub needs its own controller row (measure first).
- The handheld equivalent of the old pad check: which PSP game.
- Lynx and WonderSwan, after CabinetOS adds them, if it does.
