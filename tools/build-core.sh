#!/bin/sh
# Generic native core builder. Same shape of output for every core: a single
# merged relocatable object whose only exported symbols are
# <prefix>_retro_* forwarders, so any number of cores can link into one
# binary without their retro_* names (or bundled zlib and friends)
# colliding. Usage: tools/build-core.sh <core-name>
set -e

cd "$(dirname "$0")/.."
NAME=$1
JOBS=$(sysctl -n hw.ncpu)

SDK=$(xcrun -sdk iphoneos --show-sdk-path)
MINVERSION_FLAG=-miphoneos-version-min=18.0
MAKE_PLATFORM=ios-arm64

case "$NAME" in
gambatte)
    PREFIX=gmb; REPO=https://github.com/libretro/gambatte-libretro.git
    MAKEDIR=.; MAKEFILE=Makefile.libretro; OUT=Gambatte; LIB=libgambatte_ios.a ;;
mgba)
    PREFIX=gba; REPO=https://github.com/libretro/mgba.git
    MAKEDIR=.; MAKEFILE=cmake; OUT=MGBA; LIB=libmgba_ios.a ;;
genesis_plus_gx)
    PREFIX=gpgx; REPO=https://github.com/libretro/Genesis-Plus-GX.git
    MAKEDIR=.; MAKEFILE=Makefile.libretro; OUT=GenesisPlusGX; LIB=libgenesis_plus_gx_ios.a ;;
beetle_ngp)
    PREFIX=ngp; REPO=https://github.com/libretro/beetle-ngp-libretro.git
    MAKEDIR=.; MAKEFILE=Makefile; OUT=BeetleNGP; LIB=libbeetle_ngp_ios.a ;;
gw)
    # Game & Watch, via MADrigal's simulators compiled to Lua. Plain Lua
    # 5.3 interpreter, no LuaJIT, so it clears the JIT boundary without
    # an exception.
    PREFIX=gw; REPO=https://github.com/libretro/gw-libretro.git
    MAKEDIR=.; MAKEFILE=Makefile.libretro; OUT=GW; LIB=libgw_ios.a ;;
vemulator)
    # The Dreamcast VMU itself, as a machine: an LC86K interpreter with a
    # 48x32 LCD, the smallest core here by two orders of magnitude. Plays
    # the minigames Dreamcast games download onto their save card (Chao
    # Adventure and friends), booting them straight out of the same
    # 128KB card image the DC save sync already stores; with
    # enable_flash_write on it commits every flash write back into that
    # file in real time, so the round-trip is the core's own behavior.
    # HLE boot, no BIOS file ever.
    PREFIX=vmu; REPO=https://github.com/libretro/vemulator-libretro.git
    MAKEDIR=.; MAKEFILE=Makefile; OUT=VeMUlator; LIB=libvemulator_ios.a ;;
melonds)
    # Nintendo DS. The libretro melonDS fork builds interpreter-only for
    # ios-arm64 out of the box (no JIT_ARCH set), so it clears the JIT
    # boundary without patching. Software renderer,
    # with the core's own threaded-3D option carrying the heavy frames;
    # FreeBIOS is compiled in, so direct boot needs no user firmware.
    # Chosen over desmume2015, whose no-JIT arm64 build does not even
    # link (MMU.cpp calls JIT hooks with DESMUME_JIT=0).
    PREFIX=mds; REPO=https://github.com/libretro/melonDS.git
    MAKEDIR=.; MAKEFILE=Makefile; OUT=MelonDS; LIB=libmelonds_ios.a ;;
*)
    echo "unknown core: $NAME" >&2; exit 1 ;;
esac

SPIKE=spikes/cores/$NAME
SRC=$SPIKE/src
OUTDIR=RommApp/RommApp/Native/$OUT

# The revision is pinned, and docs/core-manifest.json is where it lives.
#
# This used to be `git clone --depth 1`, which takes whatever upstream
# HEAD happens to be on the day it runs and records nothing. Because the
# clone only happens when the directory is absent, each checkout froze at
# a different day's HEAD, and eleven cores ended up shipping different
# revisions to different platforms. docs/core-manifest.md has the full
# account.
MANIFEST=docs/core-manifest.json
PIN=$(python3 -c "
import json,sys
try:
    d = json.load(open('$MANIFEST'))['cores']
except Exception as e:
    sys.exit('cannot read $MANIFEST: %s' % e)
c = d.get('$NAME')
if c is None:
    sys.exit('$NAME is not in $MANIFEST')
print(c.get('pinned_commit') or '')
") || exit 1

if [ -z "$PIN" ]; then
    echo "no pinned_commit for $NAME in $MANIFEST." >&2
    echo "Record the revision this core must build from before building it." >&2
    exit 1
fi

if [ ! -d "$SRC" ]; then
    # Fetching the pinned commit by SHA rather than cloning and then
    # checking out: one commit's worth of download, and it cannot drift.
    mkdir -p "$SRC"
    git -C "$SRC" init -q
    git -C "$SRC" remote add origin "$REPO"
    git -C "$SRC" fetch -q --depth 1 origin "$PIN"
    git -C "$SRC" checkout -q FETCH_HEAD
    git -C "$SRC" submodule update -q --init --recursive --depth 1
fi

# An existing tree at the wrong revision is refused rather than silently
# built, and rather than reset, since some trees carry local edits no
# script reproduces. Deleting it and re-running is the deliberate act.
HAVE=$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)
if [ "$HAVE" != "$PIN" ]; then
    echo "$NAME: $SRC is at $HAVE but the manifest pins $PIN." >&2
    echo "This tree predates pinning, or someone moved it. To rebuild at" >&2
    echo "the pinned revision:  rm -rf $SRC  and run this again." >&2
    echo "Check for local edits first: git -C $SRC status --short" >&2
    exit 1
fi

# Beetle PCE Fast's bundled zlib-1.2.11 lost the "!defined(__APPLE__)" guard
# on its classic-Mac-OS fdopen() stub at some point upstream. TARGET_OS_MAC
# is defined on every Apple platform, so the stub now fires unconditionally
# and corrupts stdio.h's real fdopen() declaration under a modern SDK,
# breaking the build. Patch it back rather than build a permanently-broken
# core.
# Applied to every bundled copy rather than one hardcoded path: Beetle
# PCE Fast keeps its zlib under deps/zlib-1.2.11, MAME 2003-Plus under
# src/lib/zlib, and any future core is free to invent a third home.
find "$SRC" -name zutil.h -print0 | while IFS= read -r -d '' ZUTIL_H; do
    sed -i '' 's/#if defined(MACOS) || defined(TARGET_OS_MAC)$/#if (defined(MACOS) || defined(TARGET_OS_MAC)) \&\& !defined(__APPLE__)/' "$ZUTIL_H"
done

# melonDS's libretro build has no background flush thread (__LIBRETRO__
# compiles it out) and instead debounce-flushes the .sav at the end of
# every retro_run, two seconds after the game's last SRAM write. Its
# retro_unload_game is NDS::DeInit() alone, so an in-game save made
# less than two seconds before quitting is silently dropped, and
# save-then-immediately-quit is exactly how people leave a game. This
# inserts the missing final flush; FlushSecondaryBuffer() writes only
# when un-flushed data is pending, so it is a no-op otherwise.
if [ "$NAME" = melonds ]; then
    perl -0pi -e 's/void retro_unload_game\(void\)\n\{\n   NDS::DeInit\(\);/void retro_unload_game(void)\n{\n   NDSCart_SRAMManager::FlushSecondaryBuffer();\n   NDS::DeInit();/' \
        "$SRC/src/libretro/libretro.cpp"
    grep -q 'FlushSecondaryBuffer();' "$SRC/src/libretro/libretro.cpp" || {
        echo "melonds unload-flush patch did not apply" >&2; exit 1; }
fi

# VeMUlator finds the loaded file's extension with strchr, the FIRST dot
# in the whole path, so any dot in a parent directory name makes every
# extension check miss and the card silently loads as nothing: no flash
# image, no write-through, a blank VMU with no error. Cabinet's own card
# path is kept dot-free on top of this, but the load must not hinge on a
# path convention a future directory rename could break. strrchr is the
# last dot, which is what "the extension" means.
if [ "$NAME" = vemulator ]; then
    sed -i '' 's/char \*ext = strchr(path/char *ext = strrchr(path/' "$SRC/main.cpp"
    grep -q 'strrchr(path' "$SRC/main.cpp" || {
        echo "vemulator strrchr patch did not apply" >&2; exit 1; }
fi

if [ "$MAKEFILE" = cmake ]; then
    # mGBA dropped Makefile.libretro; its CMake build has a libretro
    # target instead.
    CMAKE_FLAGS="-fno-common"
    cmake -S "$SRC" -B "$SPIKE/build" \
        -DCMAKE_SYSTEM_NAME=iOS \
        -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=18.0 \
        -DBUILD_LIBRETRO=ON -DBUILD_QT=OFF -DBUILD_SDL=OFF \
        -DUSE_FFMPEG=OFF -DUSE_SQLITE3=OFF -DUSE_DISCORD_RPC=OFF \
        -DUSE_EDITLINE=OFF -DUSE_ELF=OFF -DBUILD_GLES2=OFF \
        -DBUILD_GLES3=OFF -DBUILD_GL=OFF \
        -DCMAKE_C_FLAGS="$CMAKE_FLAGS" -DCMAKE_CXX_FLAGS="$CMAKE_FLAGS" \
        > "$SPIKE/cmake.log" 2>&1
    cmake --build "$SPIKE/build" --target mgba_libretro -j"$JOBS"
    SRC=$SPIKE/build
else
    # -fno-common: an uninitialized non-static global (gambatte's, snes9x's,
    # ProSystem's and GPGX's own "t_snd snd" among them) compiles as a
    # tentative-definition "common" symbol by default, and Apple's ld
    # -exported_symbols_list, the only thing standing between one core's
    # internals and another's, does not localize commons at all, verified
    # directly: a same-named regular symbol got hidden, a common one did
    # not. Two cores that happen to share an internal name silently share
    # one memory address for it instead of colliding at link time, which
    # is far worse: no error, just one core's code quietly reading and
    # writing through the other's differently-shaped struct. Found
    # 2026-08-08 from a real crash: FBNeo and Genesis Plus GX both have an
    # internal "snd", GPGX's audio init was corrupting memory through
    # FBNeo's entirely different one.
    # A PATH-shimmed wrapper, not CC=/CXX= overrides: some of these
    # Makefiles bake their own -arch/-isysroot cross-compile flags
    # directly into CC rather than CFLAGS, and a command-line CC=
    # override replaces that string outright, silently dropping the
    # iOS target and defaulting the final dylib link to the host Mac
    # (found the hard way: "building for macOS, but linking in object
    # file built for iOS"). Shimming the actual cc/c++ binaries on PATH
    # injects -fno-common into every real compiler invocation while
    # leaving whatever CC/CXX string each Makefile computed untouched.
    # Absolute, not $SPIKE/ccwrap: `make -C` changes the process's own
    # working directory before running any recipe, and a relative PATH
    # entry stops resolving to this directory the moment that happens,
    # falling through silently to the real system compiler with no
    # error and no -fno-common. Found 2026-08-10 chasing why a fresh
    # FCEUmm rebuild still shipped 92 unscoped common symbols despite
    # this wrapper existing and working correctly in isolation.
    WRAP="$(pwd)/$SPIKE/ccwrap"
    mkdir -p "$WRAP"
    real_cc=$(xcrun -sdk iphoneos -find clang)
    real_cxx=$(xcrun -sdk iphoneos -find clang++)
    printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cc" > "$WRAP/cc"
    printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cc" > "$WRAP/clang"
    printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cxx" > "$WRAP/c++"
    printf '#!/bin/sh\nexec "%s" -fno-common "$@"\n' "$real_cxx" > "$WRAP/clang++"
    chmod +x "$WRAP"/*
    PATH="$WRAP:$PATH" make -C "$SRC/$MAKEDIR" -f "$MAKEFILE" platform=$MAKE_PLATFORM -j"$JOBS"
fi

DYLIB=$(find "$SRC" -name '*_ios.dylib' | head -1)
if [ -z "$DYLIB" ]; then
    DYLIB=$(find "$SRC" -name '*.dylib' | head -1)
fi
[ -n "$DYLIB" ] || { echo "no dylib produced for $NAME" >&2; exit 1; }

# Generate the prefix wrapper from the app's own libretro.h so the
# script does not depend on where each core keeps its copy.
#
# The wrapper is emitted here rather than derived from a file in
# spikes/. It used to be sed-copied from
# spikes/BeetleSaturnStatic/bsat_wrapper.c, which is hand-written and
# gitignored, so this script could not run at all on a fresh clone of
# the repository. It is inline instead, with PFX_ substituted per core
# instead of a hardcoded prefix.
#
# The heredoc is quoted so nothing in the C text is expanded, and the
# prefix is applied afterwards by sed. Keep both of those: the comment
# below contains backticks that an unquoted heredoc would try to run.
WRAP=$SPIKE/${PREFIX}_wrapper.c
sed "s/PFX_/${PREFIX}_/g" > "$WRAP" <<'WRAPPER_EOF'
/* Prefix wrapper, generated by tools/build-core.sh. Apple's toolchain
 * ships no object-file symbol renamer, so the rename happens in C
 * instead: these prefixed functions are the only symbols the merged
 * core object exports, and the real retro_* definitions they call
 * become private to it via `ld -r -exported_symbols_list`. */

#include <stddef.h>
#include <stdbool.h>
#include "libretro.h"

unsigned PFX_retro_api_version(void) { return retro_api_version(); }
void PFX_retro_get_system_info(struct retro_system_info *info) { retro_get_system_info(info); }
void PFX_retro_get_system_av_info(struct retro_system_av_info *info) { retro_get_system_av_info(info); }
void PFX_retro_set_environment(retro_environment_t cb) { retro_set_environment(cb); }
void PFX_retro_set_video_refresh(retro_video_refresh_t cb) { retro_set_video_refresh(cb); }
void PFX_retro_set_audio_sample(retro_audio_sample_t cb) { retro_set_audio_sample(cb); }
void PFX_retro_set_audio_sample_batch(retro_audio_sample_batch_t cb) { retro_set_audio_sample_batch(cb); }
void PFX_retro_set_input_poll(retro_input_poll_t cb) { retro_set_input_poll(cb); }
void PFX_retro_set_input_state(retro_input_state_t cb) { retro_set_input_state(cb); }
void PFX_retro_set_controller_port_device(unsigned port, unsigned device) { retro_set_controller_port_device(port, device); }
void PFX_retro_init(void) { retro_init(); }
void PFX_retro_deinit(void) { retro_deinit(); }
void PFX_retro_reset(void) { retro_reset(); }
void PFX_retro_run(void) { retro_run(); }
bool PFX_retro_load_game(const struct retro_game_info *game) { return retro_load_game(game); }
bool PFX_retro_load_game_special(unsigned type, const struct retro_game_info *info, size_t num) { return retro_load_game_special(type, info, num); }
void PFX_retro_unload_game(void) { retro_unload_game(); }
unsigned PFX_retro_get_region(void) { return retro_get_region(); }
size_t PFX_retro_serialize_size(void) { return retro_serialize_size(); }
bool PFX_retro_serialize(void *data, size_t size) { return retro_serialize(data, size); }
bool PFX_retro_unserialize(const void *data, size_t size) { return retro_unserialize(data, size); }
void PFX_retro_cheat_reset(void) { retro_cheat_reset(); }
void PFX_retro_cheat_set(unsigned index, bool enabled, const char *code) { retro_cheat_set(index, enabled, code); }
void *PFX_retro_get_memory_data(unsigned id) { return retro_get_memory_data(id); }
size_t PFX_retro_get_memory_size(unsigned id) { return retro_get_memory_size(id); }
WRAPPER_EOF

cc -arch arm64 -isysroot "$SDK" "$MINVERSION_FLAG" -O2 \
    -I"RommApp/RommApp/Native/Libretro" -c "$WRAP" -o "$SPIKE/wrapper.o"

# Export exactly what the wrapper defines, nothing else. Deriving the
# list from the core dylib (as the Saturn script did) can catch stray
# retro_vfs_* helpers that are not part of the 25 entry points.
nm -g "$SPIKE/wrapper.o" | awk '/ T /{print $NF}' | sort -u > "$SPIKE/exports.txt"

find "$SRC" -name '*.o' ! -path '*wrapper*' > "$SPIKE/objects.txt"
ld -r -arch arm64 -syslibroot "$SDK" \
    "$SPIKE/wrapper.o" $(cat "$SPIKE/objects.txt") \
    -exported_symbols_list "$SPIKE/exports.txt" \
    -o "$SPIKE/combined.o"

mkdir -p "$OUTDIR"
rm -f "$OUTDIR/$LIB"
ar rcs "$OUTDIR/$LIB" "$SPIKE/combined.o"
echo "Wrote $OUTDIR/$LIB"
