#!/bin/bash
set -euo pipefail
# Build this isolated service only when its own source, toolchain, or signer changes.
# The main app's version and code hash must never change its Keychain partition.
lyrics_destination="$1"
lyrics_signer="$2"
lyrics_fingerprint=$(python3 - "$lyrics_signer" "$compiler_version" <<'PY'
import hashlib, pathlib, subprocess, sys
digest = hashlib.sha256()
for source in ('Scripts/package_lyrics_keychain.sh', 'LyricsKeychainHelper/main.swift', 'Shared/LyricsKeychainProtocol.swift',
               'boringNotch/helpers/LegacyKeychainAccess.swift', 'boringNotch/helpers/SpicyLyricsCredential.swift'):
    digest.update(pathlib.Path(source).read_bytes())
digest.update(sys.argv[2].encode())
if sys.argv[1] == '-':
    digest.update(b'ad-hoc-signing-identity')
else:
    digest.update(subprocess.check_output(['security', 'find-certificate', '-c', sys.argv[1], '-p']))
print(digest.hexdigest())
PY
)
lyrics_cached="$PWD/.build/lyrics-keychain/$lyrics_fingerprint/LyricsKeychain.xpc"
if [[ ! -d "$lyrics_cached" ]]; then
  mkdir -p "$lyrics_cached/Contents/MacOS"
  xcrun --sdk macosx swiftc -swift-version 5 -O -target "$(uname -m)-apple-macosx14.0" -sdk "$SDKROOT" \
    LyricsKeychainHelper/main.swift Shared/LyricsKeychainProtocol.swift \
    boringNotch/helpers/LegacyKeychainAccess.swift boringNotch/helpers/SpicyLyricsCredential.swift \
    -o "$lyrics_cached/Contents/MacOS/LyricsKeychain"
  python3 - "$lyrics_cached" "$lyrics_fingerprint" <<'PY'
import pathlib, plistlib, sys
info = {'CFBundleIdentifier': 'local.vedanth.boringnotch.octave.LyricsKeychain',
        'CFBundleName': 'Boring Notch Lyrics', 'CFBundleExecutable': 'LyricsKeychain',
        'CFBundlePackageType': 'XPC!', 'CFBundleVersion': '1',
        'BNSourceFingerprint': sys.argv[2],
        'XPCService': {'ServiceType': 'Application', 'JoinExistingSession': True}}
(pathlib.Path(sys.argv[1]) / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
  codesign --force --sign "$lyrics_signer" "$lyrics_cached"
fi
codesign --verify --strict "$lyrics_cached"
ditto "$lyrics_cached" "$lyrics_destination"
