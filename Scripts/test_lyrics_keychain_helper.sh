#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
lyrics_dir=$(mktemp -d /tmp/boring-lyrics-xpc.XXXXXX)
lyrics_service="local.vedanth.boringnotch.octave.credential-checks.$(uuidgen)"
lyrics_app="$lyrics_dir/Checks.app"
lyrics_helper="$lyrics_app/Contents/XPCServices/LyricsKeychain.xpc"
lyrics_identity="${BORING_CODESIGN_IDENTITY:-Boring Notch Octave Local}"
trap 'if [[ -x "$lyrics_helper/Contents/MacOS/LyricsKeychain" ]]; then "$lyrics_helper/Contents/MacOS/LyricsKeychain" remove-fixtures >/dev/null 2>&1 || true; fi; rm -rf "$lyrics_dir"' EXIT
mkdir -p "$lyrics_app/Contents/MacOS" "$lyrics_helper/Contents/MacOS"
xcrun swiftc -swift-version 5 -sdk "$SDKROOT" \
  boringNotch/helpers/LegacyKeychainAccess.swift boringNotch/helpers/SpicyLyricsCredential.swift \
  Scripts/LyricsCredentialChecks.swift -o "$lyrics_dir/direct"
codesign --force --sign "$lyrics_identity" --identifier local.vedanth.boringnotch.octave "$lyrics_dir/direct"
python3 - "$lyrics_app" "$lyrics_service" <<'PY'
import pathlib, plistlib, sys
app = pathlib.Path(sys.argv[1])
for target, identifier, executable, package in (
    (app, 'local.vedanth.boringnotch.octave', 'Checks', 'APPL'),
    (app/'Contents/XPCServices/LyricsKeychain.xpc', 'local.vedanth.boringnotch.octave.LyricsKeychain', 'LyricsKeychain', 'XPC!')):
    info = {'CFBundleIdentifier': identifier, 'CFBundleExecutable': executable,
            'CFBundlePackageType': package, 'BNKeychainFixtureService': sys.argv[2]}
    if package == 'XPC!': info['XPCService'] = {'ServiceType': 'Application', 'JoinExistingSession': True}
    (target/'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
xcrun swiftc -swift-version 5 -sdk "$SDKROOT" -D KEYCHAIN_FIXTURE \
  LyricsKeychainHelper/main.swift Shared/LyricsKeychainProtocol.swift \
  boringNotch/helpers/LegacyKeychainAccess.swift boringNotch/helpers/SpicyLyricsCredential.swift \
  -o "$lyrics_helper/Contents/MacOS/LyricsKeychain"
codesign --force --sign "$lyrics_identity" "$lyrics_helper"
build_caller() {
  xcrun swiftc -swift-version 5 -sdk "$SDKROOT" -D KEYCHAIN_FIXTURE -D BORING_LOCAL_BUILD "$@" \
    Shared/LyricsKeychainProtocol.swift boringNotch/helpers/LyricsKeychainClient.swift \
    boringNotch/helpers/LegacyKeychainAccess.swift boringNotch/helpers/SpicyLyricsCredential.swift \
    Scripts/LyricsCredentialChecks.swift -o "$lyrics_app/Contents/MacOS/Checks"
  codesign --force --sign "$lyrics_identity" "$lyrics_app"
}
build_caller
# An already-authorized legacy key is migrated without an extra prompt.
"$lyrics_helper/Contents/MacOS/LyricsKeychain" seed-legacy
"$lyrics_app/Contents/MacOS/Checks" authorize "$lyrics_service"
"$lyrics_helper/Contents/MacOS/LyricsKeychain" verify-migration
"$lyrics_helper/Contents/MacOS/LyricsKeychain" remove-fixtures
"$lyrics_helper/Contents/MacOS/LyricsKeychain" seed-legacy
"$lyrics_app/Contents/MacOS/Checks" read "$lyrics_service"
"$lyrics_helper/Contents/MacOS/LyricsKeychain" verify-migration
# New keys use the helper directly, with no macOS authorization dialog.
"$lyrics_app/Contents/MacOS/Checks" save "$lyrics_service"
"$lyrics_app/Contents/MacOS/Checks" read "$lyrics_service"
lyrics_hash_before=$(codesign -dv --verbose=4 "$lyrics_helper" 2>&1 | sed -n 's/^CDHash=//p')
[[ -n "$lyrics_hash_before" ]]
build_caller -D KEYCHAIN_REBUILT_FIXTURE
"$lyrics_app/Contents/MacOS/Checks" read "$lyrics_service"
"$lyrics_app/Contents/MacOS/Checks" read "$lyrics_service"
lyrics_hash_after=$(codesign -dv --verbose=4 "$lyrics_helper" 2>&1 | sed -n 's/^CDHash=//p')
[[ "$lyrics_hash_before" == "$lyrics_hash_after" ]]
echo "PASS: changed app executable retains prompt-free Keychain access with the same helper hash"
# A different application identifier cannot fetch the key through this helper.
codesign --force --sign "$lyrics_identity" --identifier local.vedanth.boringnotch.octave.untrusted-check "$lyrics_app"
"$lyrics_app/Contents/MacOS/Checks" reject-xpc "$lyrics_service"
echo "MANUAL: authorization of a pre-existing user credential still requires the user's macOS password dialog once."
