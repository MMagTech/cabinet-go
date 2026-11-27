# Cabinet Go

The handheld half of [CabinetOS](https://github.com/MMagTech/cabinetos).

[RomM](https://github.com/rommapp/romm) manages your game collection: the
library, the metadata, the cover art, the saves. CabinetOS is the console
under your television that plays it. Cabinet Go is the one you take with
you: the handheld systems from your own RomM library, played natively on
your iPhone, with your saves kept on your own server.

**Cabinet Go is in development and has no release yet.**

## What it plays

Game Boy, Game Boy Color, Game Boy Advance, Nintendo DS, PSP, Game Gear,
Neo Geo Pocket Color and Game & Watch, through emulators built into the
app.

The rule for what belongs is one question: was it played in your hands?
Console games stay with CabinetOS. To play one away from the television,
stream it from CabinetOS with Moonlight.

## What you get

**Offline play.** Keep a game on your phone and it plays with no signal and
no server at all: on a plane, on the subway, anywhere.

**Your saves on your server.** In-game saves and save states go to your
RomM server's save channels, the way CabinetOS sends them, so a game saved
on the phone carries on at the TV and back. Needs RomM 5.5 or newer.

**A whole platform in one go.** Download All keeps every game on a system
at once, through the system's own background downloader, over Wi-Fi only,
with its progress in the Dynamic Island and on the Lock Screen.

**Your controller just works.** Any controller your iPhone supports, with
buttons matched by position the way CabinetOS does it, so the bottom face
button does the same thing on both. Touch controls too, a layout per system,
in portrait and landscape.

**Each machine played its own way.** A Nintendo DS uses both screens and
the touchscreen. Game & Watch has no on-screen controls at all: the machine
fills the screen and you press its buttons by pressing them. The Game Boy
Advance cartridges with sensors inside, WarioWare Twisted among them, read
your phone's own motion.

**On the home screen and in Spotlight.** A widget shows what you played
last, your recents or your favourites, and typing a game's name into the
phone's own search opens it.

## What you need

- A [RomM](https://github.com/rommapp/romm) server with your games on it
- An iPhone running iOS 18 or later

Cabinet Go does not come with any games. It plays yours. It never asks for
your password: you approve the phone in RomM itself, with RomM's own device
authorization.

To build it yourself, see [docs/building.md](docs/building.md).

## Thanks

Cabinet Go exists because of the [RomM team](https://github.com/rommapp/romm).
The library, the metadata and the save model are all their work. Cabinet Go
is just a way to enjoy it in your pocket. If you like it, go star their
project, it is where the real work lives.

## How it was made

I am not a programmer. Cabinet Go was built with AI assistance, by me,
because I wanted this app to exist and it did not. The entire history is
here, unedited, so you can see how it was made and judge for yourself.

## Licences

Cabinet Go is MIT. The emulators it uses keep their own licences, listed in
[docs/licenses.md](docs/licenses.md) and in the app under Settings.

Cabinet Go is free, is not sold, and takes no donations. Some of those
emulators require exactly that, so it stays that way.

Security issues: [SECURITY.md](SECURITY.md).
