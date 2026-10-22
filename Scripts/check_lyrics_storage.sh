#!/bin/bash
# A prompt-free diagnostic using the installed broker; never prints the API key.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
lyrics_probe=$(mktemp -d /tmp/boring-lyrics-probe.XXXXXX)
trap 'rm -rf "$lyrics_probe"' EXIT
lyrics_app="$lyrics_probe/Probe.app"
mkdir -p "$lyrics_app/Contents/MacOS" "$lyrics_app/Contents/XPCServices"
ditto '/Applications/Boring Notch Octave.app/Contents/XPCServices/LyricsKeychain.xpc' \
  "$lyrics_app/Contents/XPCServices/LyricsKeychain.xpc"
python3 - "$lyrics_app/Contents/Info.plist" <<'PY'
import pathlib, plistlib, sys
pathlib.Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'local.vedanth.boringnotch.octave',
    'CFBundleExecutable': 'Probe', 'CFBundlePackageType': 'APPL'}))
PY
xcrun swiftc -swift-version 5 -sdk "$SDKROOT" -D BORING_LOCAL_BUILD \
  Shared/LyricsKeychainProtocol.swift boringNotch/helpers/LyricsKeychainClient.swift \
  boringNotch/helpers/LegacyKeychainAccess.swift boringNotch/helpers/SpicyLyricsCredential.swift \
  Scripts/LyricsCredentialChecks.swift -o "$lyrics_app/Contents/MacOS/Probe"
codesign --force --sign "${BORING_CODESIGN_IDENTITY:-Boring Notch Octave Local}" "$lyrics_app"
"$lyrics_app/Contents/MacOS/Probe" probe local.vedanth.boringnotch.octave.spicy-lyrics
