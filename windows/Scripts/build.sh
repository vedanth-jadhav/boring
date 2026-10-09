#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
dotnet restore Boring.Native/Boring.Native.csproj --locked-mode -r win-x64
dotnet publish Boring.Native/Boring.Native.csproj -f net10.0-windows10.0.19041.0 -c Release -r win-x64 --self-contained true --no-restore -o artifacts/native
cd electron
npm ci
packager_args=(. BoringNotch --platform=win32 --arch=x64 --out=../artifacts/electron --overwrite --prune=true --asar --extra-resource=../artifacts/native '--ignore=^/tests' '--ignore=^/qa-output' '--ignore=^/package-lock.json' --app-version=1.0.0 --electron-version=44.7.0 --icon=assets/icon.ico)
if [[ -n "${ELECTRON_ZIP_DIR:-}" ]]; then packager_args+=("--electron-zip-dir=$ELECTRON_ZIP_DIR"); fi
npx --no-install electron-packager "${packager_args[@]}"
cd ..
python3 - <<'PY'
from pathlib import Path
import shutil, hashlib
root = Path.cwd()
app = root / 'artifacts/electron/BoringNotch-win32-x64'
shutil.copytree(root.parent / 'octave-brave-extension', app / 'octave-brave-extension', dirs_exist_ok=True)
shutil.copy2(root.parent/'LICENSE',app/'LICENSE-BoringNotch.txt')
shutil.copytree(root/'Licenses',app/'Licenses',dirs_exist_ok=True)
for source in [root.parent/'THIRD_PARTY_LICENSES',root/'THIRD_PARTY_NOTICES.md',root/'README.md',root/'QA.md',root/'Scripts/Install.ps1',root/'Scripts/Uninstall.ps1',root/'Scripts/Setup.cmd',root/'Scripts/Uninstall.cmd']:
    shutil.copy2(source, app/source.name)
archive = Path(shutil.make_archive(str(root/'artifacts/Boring-Notch-Octave-Windows-x64'), 'zip', app))
with archive.open('rb') as stream: checksum = hashlib.file_digest(stream, 'sha256').hexdigest()
archive.with_suffix('.zip.sha256').write_text(checksum+'\n')
print(archive)
PY
