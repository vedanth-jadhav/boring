#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
octave_artwork_dir=$(mktemp -d /tmp/boring-octave-artwork.XXXXXX)
trap 'rm -rf "$octave_artwork_dir"' EXIT
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -sdk "$SDKROOT" \
  boringNotch/models/{PlaybackState,LyricLine,LyricPhoneticTiming,LyricPlaybackClock,LyricsRomanizer,RomanizationLexicon}.swift \
  boringNotch/MediaControllers/{MediaControllerProtocol,MediaAppBundleID,OctaveController}.swift \
  Scripts/OctaveArtworkChecks.swift -o "$octave_artwork_dir/checks"
"$octave_artwork_dir/checks"
