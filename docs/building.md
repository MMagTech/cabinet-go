# Building Cabinet Go from source

Cabinet Go has no package manager and no dependencies. There is nothing to install,
no `pod install`, no Swift Package resolution step. Clone it and open it.

## What you need

- macOS with **Xcode 26 or later**
- An iPhone running iOS 18 or later
- An Apple ID

Xcode 26 is not optional. The app's deployment target is iOS 18, so it runs on
iOS 18 devices, but it calls a few iOS 26 APIs behind availability checks and
those still need the iOS 26 SDK to compile. On Xcode 16 the build fails on
`tabBarMinimizeBehavior` and `scrollEdgeEffectHidden`.

## Steps

1. Clone the repository and open `RommApp/RommApp.xcodeproj` in Xcode.

2. Select the **RommApp** target, go to **Signing & Capabilities**, and change
   the team to your own. The project has the maintainer's team ID committed in
   it, which will not work for you. A free Apple ID is enough.

3. Plug in your iPhone, pick it as the run destination, and build.

4. On first launch, enter your RomM server address. The app shows you a short
   code, you approve it in RomM's web interface under your profile, and that is
   the pairing done. No password is ever typed into the app.

## The Metal toolchain

Since Xcode 26 the Metal compiler is a separate download, matched to each
Xcode version, and the app has one Metal shader file. If the build stops
at `LibretroShaders.metal` with "missing Metal Toolchain", install it:

```sh
xcodebuild -downloadComponent MetalToolchain
```

An Xcode update does not bring the matching toolchain with it, so the
first build after each update can stop here again.

## The simulator builds, but cannot really run a game

The app links and runs in the Simulator: the native cores are
device-only static libraries, so they are excluded per SDK
(`EXCLUDED_SOURCE_FILE_NAMES[sdk=iphonesimulator*]`) rather than linked
unconditionally. That is enough for UI work, screens, layout,
navigation, without a physical device.

It is not enough to play anything. `NativeLauncher` throws a friendly
error rather than trying to load a core that is not there, so verifying
emulation still needs a real iPhone. A build for a device, even unsigned,
is also the only one that links the cores, so check one before calling a
change to the cores or the frontend done:

```sh
xcodebuild build -project RommApp/RommApp.xcodeproj -scheme RommApp \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO
```

## Three targets

**RommApp** builds Cabinet Go for iPhone.

**CabinetWidget** is the home screen widget and the download Live
Activity. It is embedded in the app and builds with it.

**LayoutEditor** is a separate tool for editing the on-screen control layouts in
`RommApp/RommApp/Resources/ControlLayouts`. It is a development utility, it is
not part of the app, and it is not in the released build. You can ignore it.

## The emulator cores

The eight native cores in `RommApp/RommApp/Native/*/lib*_ios.a` are prebuilt
and committed, so a normal build does not compile them: Gambatte, mGBA,
melonDS, PPSSPP, Genesis Plus GX, Beetle NeoPop, gw-libretro and VeMUlator.

If you want to rebuild one yourself, `tools/build-core.sh <core>` does it.
It clones the upstream libretro repository into `spikes/`, builds it, and
produces a single relocatable object whose only exported symbols are
prefixed `<prefix>_retro_*`. That prefixing matters: without it, cores that
each export `retro_run` and bundle their own copy of zlib cannot link into
one binary.

```sh
tools/build-core.sh gambatte
```

PPSSPP builds with CMake rather than a libretro Makefile, so it has its
own script, `tools/build-ppsspp.sh`.

Every core's upstream repository and the exact commit its library was built
from is listed in [licenses.md](licenses.md) and pinned in
[core-manifest.json](core-manifest.json).

## Other tools

`tools/lab/lab` is the way into the checks and measurements that need no
device; `tools/lab/lab stations` lists what each one covers.

## Design notes

[scope-handheld.md](scope-handheld.md) is the current plan: which systems
the app plays and why. [scope-v0.1.md](scope-v0.1.md) has the original
design and the reasoning behind the decisions that still stand, including
the JIT measurements behind which systems can run on a phone at all.
