#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
regression_dir=$(mktemp -d /tmp/boring-targeted-checks.XXXXXX)
trap 'rm -rf "$regression_dir"' EXIT
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -sdk "$SDKROOT" \
  boringNotch/helpers/{LegacyKeychainAccess,SpicyLyricsCredential}.swift \
  boringNotch/managers/SpicyLyricsClient.swift \
  boringNotch/models/{SpicyLyricsPayload,LyricLine,LyricPhoneticTiming,LyricPlaybackClock,LyricAttribution,LyricsRomanizer,RomanizationLexicon,PlaybackState}.swift \
  boringNotch/MediaControllers/{MediaControllerProtocol,MediaAppBundleID,OctaveController}.swift \
  boringNotch/components/Shelf/Models/{ShelfItem,Bookmark}.swift \
  boringNotch/components/Shelf/Services/{ShelfDropService,ShelfPersistenceService,ShelfFileLibrary,TemporaryFileStorageService}.swift \
  boringNotch/components/Shelf/ViewModels/ShelfStateViewModel.swift \
  boringNotch/extensions/NSItemProvider+LoadHelpers.swift \
  boringNotch/extensions/URL+SecurityScoped.swift \
  Scripts/TargetedRegressionChecks.swift -o "$regression_dir/checks"
"$regression_dir/checks"
