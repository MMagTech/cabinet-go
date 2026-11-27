#!/bin/sh
# Builds the saves harness against the REAL save files for the iOS
# simulator and runs it there headless: CabinetOS's case tables for the
# same rules, against RomM's recorded answers (fixtures/). Green exit 0.
# Needs a booted simulator (any iPhone); boots the first available one if
# none is. Writes only to a scratch folder of the simulator's own.
set -e
cd "$(dirname "$0")/../../.."

SDK=$(xcrun --show-sdk-path --sdk iphonesimulator)
OUT=/tmp/cabinet-saves-test
xcrun --sdk iphonesimulator swiftc \
  -sdk "$SDK" -target arm64-apple-ios18.0-simulator \
  -D DEBUG \
  RommApp/RommApp/Auth/RommModels.swift \
  RommApp/RommApp/Auth/RommSnapshots.swift \
  RommApp/RommApp/Native/SaveRowNames.swift \
  RommApp/RommApp/Native/SaveZip.swift \
  RommApp/RommApp/Native/SaveHash.swift \
  RommApp/RommApp/Native/SaveMirror.swift \
  RommApp/RommApp/Native/SavePick.swift \
  RommApp/RommApp/Native/SavePush.swift \
  RommApp/RommApp/Native/SaveForm.swift \
  tools/lab/saves/main.swift \
  -o "$OUT"

BOOTED=$(xcrun simctl list devices booted | grep -o '[A-F0-9-]\{36\}' | head -1)
if [ -z "$BOOTED" ]; then
  BOOTED=$(xcrun simctl list devices available | grep 'iPhone' | grep -o '[A-F0-9-]\{36\}' | head -1)
  xcrun simctl boot "$BOOTED"
fi
# The fixtures go beside the harness: a simulator's process cannot read a
# folder macOS keeps private (Documents, where a checkout often is) and
# waits on it for ever.
FIXTURES=/tmp/cabinet-saves-fixtures
rm -rf "$FIXTURES"
cp -R tools/lab/saves/fixtures "$FIXTURES"
xcrun simctl spawn "$BOOTED" "$OUT" "$FIXTURES"
