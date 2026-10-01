#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="$HOME/Applications/Boring Notch Octave.app"
source_app="$PWD/build/Boring Notch Octave.app"
if [[ ! -d "$source_app" ]]; then echo "Package the app first." >&2; exit 1; fi
mkdir -p "$HOME/Applications" \
  "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts" \
  "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
staging=$(mktemp -d "$HOME/Applications/.boring-octave.XXXXXX")
trap 'rm -rf "$staging"' EXIT
ditto "$source_app" "$staging/Boring Notch Octave.app"
codesign --verify --deep --strict "$staging/Boring Notch Octave.app"
# A merge copy leaves old bundle signatures in Resources after a rebuild.
# Replace the complete local app so every installed file matches the seal.
rm -rf "$app"
mv "$staging/Boring Notch Octave.app" "$app"
codesign --verify --deep --strict "$app"
manifest="$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts/com.boringnotch.local.octave.json"
python3 - "$manifest" "$app/Contents/Resources/octave-native-host.py" <<'PY'
import json,pathlib,sys
pathlib.Path(sys.argv[1]).write_text(json.dumps({
  'name':'com.boringnotch.local.octave', 'description':'Local Octave bridge for Boring Notch',
  'path':sys.argv[2], 'type':'stdio',
  'allowed_origins':['chrome-extension://ckcfhbbgdlpnbcbdgjmcaophnkhnlkae/']
},indent=2)+'\n')
PY
cp "$manifest" "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.boringnotch.local.octave.json"
echo "Installed $app"
echo "Load $PWD/octave-brave-extension as an unpacked extension at brave://extensions."
