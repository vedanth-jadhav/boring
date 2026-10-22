#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
lyrics_objects="$PWD/.build/$(uname -m)-apple-macosx/debug"
[[ -d "$lyrics_objects/Modules" ]] || lyrics_objects="$PWD/.build/debug"
lyrics_checks=$(mktemp -d /tmp/boring-lyrics-settings.XXXXXX)
trap 'rm -rf "$lyrics_checks"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -sdk "$SDKROOT" -I "$lyrics_objects/Modules" \
  boringNotch/managers/EnhancedLyricsSettingsModel.swift Scripts/LyricsSettingsChecks.swift \
  "$lyrics_objects/Defaults.build/"*.o -o "$lyrics_checks/checks"
"$lyrics_checks/checks"
