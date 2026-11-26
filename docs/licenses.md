# Licences

Cabinet's own source is MIT. The emulator cores it links are not, and each keeps
its own terms. This page lists everything the app binary contains, where it came
from, and the exact commit it was built from.

The same list, with every licence readable in full, is in the app under
Settings, Licenses.

## Why the distinction matters

Several of these cores are free for non-commercial use but may not be sold.
Cabinet is free, is not sold, and takes no donations, which is what keeps those
cores legitimate in this build. That is a deliberate constraint on the project,
not an oversight: adding a sponsor button or charging for the app would break
it.

Cabinet ships no games and no BIOS files.

## Cabinet

| | |
|---|---|
| Licence | MIT |
| Source | This repository |

Covers everything under `RommApp/` except the prebuilt `lib*.a` files listed
below and the third party C sources in `RommApp/RommApp/Native/Archive`.

## Emulator cores

Each of these is a prebuilt static library in `RommApp/RommApp/Native/<name>/`.
None of them were modified. They were built from upstream with
`tools/build-core.sh`, which is in this repository, so anyone can reproduce them
from the commits below.

| Core | Systems | Licence | Upstream | Commit |
|---|---|---|---|---|
| Gambatte | Game Boy, Game Boy Color | GPL v2 | [libretro/gambatte-libretro](https://github.com/libretro/gambatte-libretro) | `96174369b3c3` |
| mGBA | Game Boy Advance | MPL 2.0 | [libretro/mgba](https://github.com/libretro/mgba) | `e31759b24e7a` |
| Genesis Plus GX | Game Gear | Free for non-commercial use | [libretro/Genesis-Plus-GX](https://github.com/libretro/Genesis-Plus-GX) | `84fcf2ec8e6b` |
| Beetle NeoPop | Neo Geo Pocket Color | GPL v2 | [libretro/beetle-ngp-libretro](https://github.com/libretro/beetle-ngp-libretro) | `a50d5ac288a8` |
| melonDS | Nintendo DS | GPL v3 | [libretro/melonDS](https://github.com/libretro/melonDS) | `66b5d2634cd0` |
| DraStic FreeBIOS | DS BIOS replacement inside melonDS | BSD 2-clause | bundled in the fork above | `66b5d2634cd0` |
| PPSSPP | PSP | GPL v2 or later | [hrydgard/ppsspp](https://github.com/hrydgard/ppsspp) | `c989c2553e10` |
| gw-libretro | Game & Watch | zlib | [libretro/gw-libretro](https://github.com/libretro/gw-libretro) | `91d599b951e7` |
| VeMUlator | Dreamcast VMU minigames | GPL v3 | [libretro/vemulator-libretro](https://github.com/libretro/vemulator-libretro) | `27a062f6ae53` |

The GPL v2 cores are statically linked, which makes the distributed app a
combined work under those terms. The corresponding source is the upstream commit
named above, unmodified, built with `tools/build-core.sh` from this repository.

## Supporting libraries

| Library | Used for | Licence |
|---|---|---|
| libretro-common | The core interface the cores are built against | MIT |
| zlib | ROM decompression | zlib licence |
| libchdr | Reading CHD compressed disc images | BSD |
| Zstandard | Disc image decompression | BSD |
| LZMA SDK | Archive decompression | Public domain |
| Tremor | CD audio decoding | BSD |
| inih | Config parsing, built into mGBA | BSD |
| FFmpeg | Video and audio decoding inside PPSSPP, the prebuilt static build PPSSPP's own tree carries for iOS ([hrydgard/ppsspp-ffmpeg](https://github.com/hrydgard/ppsspp-ffmpeg) `b87f7c6d522d`), configured without its GPL parts | LGPL v2.1 or later |
| Lua | Script interpreter: Lua 5.4.7 inside PPSSPP ([hrydgard/ppsspp-lua](https://github.com/hrydgard/ppsspp-lua) `7648485f14e8`), and Lua 5.3.0 inside gw-libretro, which runs the Game & Watch simulations | MIT |
| bzip2 | Decompression inside gw-libretro | BSD-style |
