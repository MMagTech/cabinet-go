# Working notes for Claude

This file describes Cabinet Go: its architecture, its conventions, its history,
and the technical findings that cost real time to learn. Anything a
contributor who has never met the author could not act on, or that would be
just as true on a different project, does not belong here.

Read `docs/scope-handheld.md` before doing anything substantial. It is the
current plan: Cabinet Go is the handheld half of CabinetOS, and it records
which systems the app plays and why. `docs/scope-v0.1.md` carries the
original design and the reasoning behind the decisions that still stand.

## Writing conventions

- Never use `--` (a double hyphen) or an em dash. Not in prose, not in comments,
  not in commit messages, not in UI copy. Use commas, colons, or separate
  sentences.
- Plain sentences over bullet soup in comments and documentation.

## Git conventions

- Work on `dev`. `main` is the release branch and carries the full history.
- `main` normally only moves when a release is cut. The one exception is a
  commit that touches no app code at all, README, ROADMAP, `docs/`, since
  `main` is what a visitor to the repo actually lands on and those files
  reflect the project regardless of what has or hasn't shipped yet. A
  docs-only commit can go straight to both branches. Anything that touches
  code, even a one-line fix, waits for a real release cut.
- Releases are tagged on `main` as `ios-v<version>`. The tags of the old
  Cabinet apps (`tvos-v...`, `mac-v...`, and the two oldest iOS tags,
  `v0.1.0-alpha` and `v0.2.0-alpha`) keep their names.
- To cut a release, in order: first set the target's `MARKETING_VERSION` in
  the project to match the tag being cut, and bump `CURRENT_PROJECT_VERSION`
  if the build will also go to TestFlight (Apple requires a unique build
  number per upload). Verify the project version matches the tag before
  tagging; the iOS 0.2.0-alpha release shipped reporting "0.1" because this
  step was skipped. Then archive the `RommApp` scheme with
  `xcodebuild archive` and `CODE_SIGNING_ALLOWED=NO`, copy the built `.app`
  into a `Payload/` folder and zip it as an unsigned `.ipa`, then
  `gh release create` with the tag and `gh release upload` the IPA.
- The old squash-merge-only rule is retired. Decided 2026-08-09, at launch: the
  history is public and complete on purpose, including the messy parts. Do not
  squash it away or propose hiding branches.
- A fix on one branch and a refactor that moves the same code on another
  branch merge cleanly and silently drop the fix. There is no conflict and
  nothing in the diff to see. It cost the native player's stereo audio for
  five days: `72f8a4e` fixed it in `NativePlayerView.swift`, the tvOS
  branch had already moved that code to `NativePlayerAudio.swift`, and the
  merge in `263bdf0` kept the move and dropped the fix (found 2026-08-16).
  After merging any branch that has diverged for more than a day, list what
  the merged-in side changed and confirm each change still exists where
  that code now lives.
- `SECURITY.md` stays in the repository root.

## Project shape

Native SwiftUI shell running the handheld systems through eight libretro
cores compiled into the app: Gambatte, mGBA, melonDS, PPSSPP, Genesis Plus
GX, Beetle NeoPop, gw-libretro, and VeMUlator for the Dreamcast VMU
minigames.

The JIT boundary is why. Cores compiled into the app process are interpreter
only, since Apple allows no JIT there. Every handheld system an interpreter
can carry runs natively, which buys real fullscreen, native input and
offline play; systems that need a dynamic recompiler belong to CabinetOS.
That split is settled; do not propose moving a dynarec-dependent system into
the app process.

Home is resume first, not a library grid. One tap back into the last game.

iOS's one ambient, content-derived background lives on the game launch
screen, the game's own cover blurred behind it, the same contained way
Music treats Now Playing. Do not spread that into iOS's app-shell chrome,
lists, tab bar, settings; that reads as skinning rather than the
platform's own idiom. Decided deliberately, not a gap to fill in later.

## Persisted data

Any change to a persisted local data format needs a non-destructive
migration path decided at the same time, not discovered as data loss later.

## Blast radius: say it out loud before touching shared code

Eight cores run through a handful of shared files. `LibretroFrontend`,
`NativePlayerRenderer`, `NativePlayerAudio`, `GameControllerManager` and the
control layouts are the main ones. A fix aimed at one core lands on all of
them unless it is deliberately scoped.

- **State the two lists before building.** Which cores actually execute
  the lines being changed, and which ones the change is
  meant to help. If those lists differ, say so explicitly, in those
  words, and get agreement before writing code. Do not decide alone that
  the difference is harmless.
- **Prefer additive.** A new enum case, a new flag defaulting to today's
  behaviour, a new branch. Never edit an existing shared branch when an
  additive change would do, so untouched cores run byte-identical code.
- **Scope the fix as narrowly as the evidence.** A finding measured on
  one core belongs behind a check for that core, in the frontend where
  core identity already lives, not in the shared path "because it should
  be harmless everywhere".
- **Test the blast radius, not the target.** Before calling it done, run
  a game on at least one core per affected class, not only the core that
  motivated the work. For the render path that means one core per pixel
  format plus the hardware-rendered core, PPSSPP.

Two regressions on 2026-08-16 are why this section exists, both from
Dreamcast fixes placed in shared code back when the app still carried the
console cores, and both found on real hardware
after the work was called done: an audio governor built for
Flycast's free-running emulation thread went into the shared draw loop
and slowed N64 down, and a teardown condition widened for Flycast went
into the shared load path and turned an N64 relaunch into a crash in
GLideN64's `TexrectDrawer::destroy`. Both were one-line widenings that
looked harmless. Neither was.

## Things that are settled

- Auth is RomM's device authorization flow. Not username and password, not
  cookie sharing, not a pasted token.
- Save states are slot based because that is what RomM's asset model stores.
- Control layouts are data, not code. One file per system or profile, trait keyed.
- Touch input copies DeltaCore's approach: extended hit frames, overlapping d-pad
  rects, continuous d-pad reporting. Read their approach, do not copy their code.
  Delta is AGPLv3 and this project is MIT.
- Physical controllers are captured natively with `GameController`.
- Any change touching controller input (GameControllerManager, inputState,
  the send/sendStick wiring) must be verified on a real device with a real
  Bluetooth pad on a PSP game that uses the analog nub, the only analog
  stick left, before it is called done. A commit once claimed exactly
  this verification while introducing exactly this bug; the touch overlay
  and the menus exercising fine proves nothing about the pad path.

## Things marked verify

The scope doc's Open items list flags what is still unverified; most of the
original seven are resolved now, check the list itself rather than trusting a
count here, it will only go stale again. Do not build on a remaining item
silently. If a task depends on one, say so and confirm before assuming.

The instance is at `your-romm-server.example` and `/api/docs` is authoritative for
endpoint shapes. Prefer checking it over assuming RomM's API from memory.
RomM has no dedicated API version and ships fast with no changelog; see
`docs/checking-romm-compatibility.md` before assuming a new RomM release
did not change something Cabinet depends on.

## Do not

- Add dependencies. No DI framework, no networking library, no architecture
  scaffolding. `URLSession` and Swift concurrency are enough, and that is a
  settled decision rather than a default to revisit. Raise it as a proposal
  first if something genuinely cannot be done without one.
- Generate the API client from `openapi.json`. That is exactly why the existing
  third party iOS client breaks across RomM versions. Hand written calls, not
  generated.

## Kept games and the Files mirror

Never walk the Files mirror once per kept game, and never do a file
walk on the main thread at launch. `KeptGameStore.reconcileFilesFolder`
once called `filesFolderInodes()`, a walk of every file under Documents,
inside `ensureLinks` for every kept game: quadratic, on the main thread,
at launch and on every return to the foreground. Fine at fifty games,
and at four hundred it froze the app on every foreground, starved the
Download All queue (which lives on the main actor), and tripped the
launch watchdog: a black screen, then a kill. Found 2026-09-03 on a
real phone. The reconcile now walks the mirror once, off the main
thread, and hands the main actor only its decisions; Remove All walks
once for the platform. Keep it that way, and time any new launch work
against a library of hundreds, not the simulator's handful.

## SwiftUI and Metal

A CAMetalLayer that is a UIView's backing layer is not opaque, and
`UIView.isOpaque` does not make it so: that property is a `draw(_:)`
hint and never reaches the layer, whose own default is false. A
non-opaque layer is composited with the drawable's alpha channel, so
an emulator that writes the game's framebuffer alpha into its
drawable shows a pixel-perfect frame as a black screen. Set
`layer.isOpaque = true` on any Metal surface a core presents into.
Found 2026-09-01 by reading the presented drawable back.

Never publish state that re-renders the view currently presenting
something. It tears the presentation down: a shared flag flipped from a
launch screen's `onAppear`, observed by the shell, made that screen open
and immediately close.

Apple's documentation pages are JavaScript rendered and fetch as an
empty shell. The content is served as JSON at
`https://developer.apple.com/tutorials/data/documentation/<path>.json`;
`primaryContentSections` carries the prose and code, `topicSections`
lists every property on a class.
