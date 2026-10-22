#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -z "${SDKROOT:-}" ]]; then source Scripts/toolchain.sh; fi
exec python3 Scripts/package_lyrics_keychain.py "$@"
