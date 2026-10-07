#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
lyrics_check_dir=$(mktemp -d /tmp/boring-lyrics-credential.XXXXXX)
lyrics_check_service="local.vedanth.boringnotch.octave.credential-checks.$(uuidgen)"
trap '"$lyrics_check_dir/checks" remove "$lyrics_check_service" >/dev/null 2>&1 || true; rm -rf "$lyrics_check_dir"' EXIT
xcrun --sdk macosx swiftc -sdk "$SDKROOT" \
  boringNotch/helpers/LegacyKeychainAccess.swift boringNotch/helpers/SpicyLyricsCredential.swift \
  Scripts/LyricsCredentialChecks.swift -o "$lyrics_check_dir/checks"
codesign --force --sign "${BORING_CODESIGN_IDENTITY:-Boring Notch Octave Local}" \
  --identifier local.vedanth.boringnotch.octave.credential-checks "$lyrics_check_dir/checks"
cp "$lyrics_check_dir/checks" "$lyrics_check_dir/untrusted"
codesign --force --sign "${BORING_CODESIGN_IDENTITY:-Boring Notch Octave Local}" \
  --identifier local.vedanth.boringnotch.octave.untrusted-check "$lyrics_check_dir/untrusted"
"$lyrics_check_dir/checks" save "$lyrics_check_service"
"$lyrics_check_dir/checks" read "$lyrics_check_service"
"$lyrics_check_dir/checks" read "$lyrics_check_service"
"$lyrics_check_dir/untrusted" reject "$lyrics_check_service"
