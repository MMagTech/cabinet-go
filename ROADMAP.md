# Roadmap

Where Cabinet Go is headed. Nothing here is a promise or a deadline, this
is a project worked on as time allows, but it is the real direction, not a
wishlist that gets ignored. The plan behind it, and why the app plays the
systems it does, is [docs/scope-handheld.md](docs/scope-handheld.md).

If something here interests you, or you want to pick one up, open an
issue or a discussion first so the approach can be talked through before
any code gets written.

## Next

- **Dreamcast VMU minigames back in the library.** The VMU player is built,
  but with the library showing only handheld systems there is no way to
  reach a Dreamcast game's launch screen and its VMU row. The plan is a
  Dreamcast entry listing only the games whose memory card holds a
  minigame, labelled as the VMU.
- **A clean first launch for phones that played the old systems.** Saves a
  phone still owes RomM for a system that left get sent first; only then
  are that system's kept games and local files removed.
- **Saves through RomM's save channels**, moving in step with CabinetOS so
  saves keep crossing between the two.

## Being explored

- **Lynx and WonderSwan.** Both pass the handheld test. Each needs a native
  core, and under the rule that CabinetOS is the reference for every shared
  system, they would land on CabinetOS first.
- **A native touch control restyle.** The current on-screen controls are
  functional but read a little flat next to the rest of the app. A restyle
  direction has been discussed, not built.

## Known rough edges

Things that work but waste effort, with a known fix rather than an open
question.

- **The BIOS gets downloaded more often than it needs to be.** A
  platform's firmware comes down once per launch for any game you have not
  kept. Kept games already do the right thing: firmware is shelved in one
  folder per platform and nothing is downloaded at launch. The fix is to
  point the other path at that same shelf, so the pattern already exists
  in the code. A second, smaller part of the same fix is only downloading
  firmware the platform's core actually uses, rather than everything the
  server lists for it.

A few ideas got explored just as seriously and reached a real answer
instead of an open question. Those live in
[docs/settled.md](docs/settled.md) rather than here.
