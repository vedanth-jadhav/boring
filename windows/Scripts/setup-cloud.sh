#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
tool_root=/workspace/.tools
mkdir -p "$tool_root"
if [[ ! -x "$tool_root/dotnet/dotnet" ]] || ! "$tool_root/dotnet/dotnet" --list-sdks | rg -q '^10\.0\.401 '; then
  curl -fsSL https://dot.net/v1/dotnet-install.sh -o "$tool_root/dotnet-install.sh"
  bash "$tool_root/dotnet-install.sh" --version 10.0.401 --install-dir "$tool_root/dotnet" --no-path
fi
export PATH="$tool_root/dotnet:$PATH"
node -e 'if (Number(process.versions.node.split(".")[0]) < 24) throw Error("Node 24 or newer is required")'
cd "$repo_root/windows"
dotnet restore Boring.Native/Boring.Native.csproj --locked-mode -r win-x64
dotnet restore Boring.Tests/Boring.Tests.csproj --locked-mode
dotnet build Boring.Native/Boring.Native.csproj -c Release --no-restore
cd electron
npm ci
# curl honors this environment's HTTPS proxy; Electron 44's lazy Node fetch may not.
# Verify the official runtime before extracting it. No credentials are needed.
case "$(uname -m)" in x86_64) electron_arch=x64 ;; aarch64) electron_arch=arm64 ;; *) echo 'Unsupported development architecture' >&2; exit 1 ;; esac
cache_root="$tool_root/electron-downloads"
mkdir -p "$cache_root"
electron_archive="electron-v44.7.0-linux-$electron_arch.zip"
release_root=https://github.com/electron/electron/releases/download/v44.7.0
curl -fsSL "$release_root/SHASUMS256.txt" -o "$cache_root/SHASUMS256.txt"
if [[ ! -f "$cache_root/$electron_archive" ]]; then curl -fL "$release_root/$electron_archive" -o "$cache_root/$electron_archive"; fi
python3 - "$cache_root" "$electron_archive" <<'PY'
import hashlib,sys,zipfile
from pathlib import Path
cache=Path(sys.argv[1]);name=sys.argv[2];archive=cache/name
expected={line.split()[1].lstrip('*'):line.split()[0] for line in (cache/'SHASUMS256.txt').read_text().splitlines() if line.strip()}[name]
with archive.open('rb') as stream: actual=hashlib.file_digest(stream,'sha256').hexdigest()
if actual!=expected: raise SystemExit('Electron checksum mismatch; delete the cached archive and retry')
dest=Path('node_modules/electron/dist');dest.mkdir(parents=True,exist_ok=True)
with zipfile.ZipFile(archive) as zipped: zipped.extractall(dest)
(dest/'electron').chmod(0o755)
Path('node_modules/electron/path.txt').write_text('electron')
print('Official Electron runtime verified and installed')
PY
