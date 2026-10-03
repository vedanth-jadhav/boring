#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
app="/Applications/Boring Notch Octave.app"
if [[ ! -d "$PWD/build/Boring Notch Octave.app" ]]; then echo "Package the app first." >&2; exit 1; fi
bash Scripts/install_local.sh --skip-build
mkdir -p \
  "$HOME/Library/Application Support/BraveSoftware/Brave-Browser/NativeMessagingHosts" \
  "$HOME/Library/Application Support/Google/Chrome/NativeMessagingHosts"
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
