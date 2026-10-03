#!/bin/bash
# Install one signed local build, retire stale copies, and verify what launches.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ "${1:-release}" != "--skip-build" ]]; then
  bash Scripts/package_local.sh "${1:-release}"
fi

python3 - <<'PY'
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import signal
import subprocess
import tempfile
import time

source = Path.cwd() / 'build/Boring Notch Octave.app'
installed = Path('/Applications/Boring Notch Octave.app')
identifiers = {'local.vedanth.boringnotch.octave', 'theboringteam.boringnotch'}
registrar = '/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister'

def info(app):
    return plistlib.loads((app / 'Contents/Info.plist').read_bytes())

def executable(app):
    return app / 'Contents/MacOS' / info(app)['CFBundleExecutable']

def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

manifest = info(source)
if manifest['CFBundleIdentifier'] != 'local.vedanth.boringnotch.octave':
    raise SystemExit('Refusing to install an unexpected application.')
subprocess.run(['codesign', '--verify', '--deep', '--strict', str(source)], check=True)
expected_digest = digest(executable(source))

copies = []
names = {manifest['CFBundleExecutable']}
for root in (Path('/Applications'), Path.home() / 'Applications'):
    if not root.exists():
        continue
    for app in root.glob('*.app'):
        try:
            details = info(app)
        except (OSError, plistlib.InvalidFileException):
            continue
        if details.get('CFBundleIdentifier') in identifiers:
            copies.append(app)
            names.add(details['CFBundleExecutable'])

def running():
    output = subprocess.check_output(['ps', '-axo', 'pid=,comm='], text=True)
    result = []
    for line in output.splitlines():
        parts = line.strip().split(None, 1)
        if len(parts) == 2 and Path(parts[1]).name in names:
            result.append((int(parts[0]), parts[1]))
    return result

# Stage and validate before stopping the current app or moving any installed copy.
staging = Path(tempfile.mkdtemp(prefix='.boring-install-', dir='/Applications'))
staged_app = staging / installed.name
try:
    subprocess.run(['ditto', str(source), str(staged_app)], check=True)
    subprocess.run(['codesign', '--verify', '--deep', '--strict', str(staged_app)], check=True)
    if digest(executable(staged_app)) != expected_digest:
        raise RuntimeError('Staged executable differs from the built executable.')

    for pid, path in running():
        print(f'Stopping {pid}: {path}', flush=True)
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + 5
    while running() and time.monotonic() < deadline:
        time.sleep(0.1)
    for pid, path in running():
        os.kill(pid, signal.SIGKILL)

    archive = Path.home() / 'Library/Application Support/Boring Notch/Archived Builds' / datetime.datetime.now().strftime('%Y%m%d-%H%M%S-%f')
    archive.mkdir(parents=True)
    for index, app in enumerate(copies):
        subprocess.run([registrar, '-u', str(app)], check=False, stdout=subprocess.DEVNULL)
        destination = archive / f'{index + 1}-{app.name}.archived'
        shutil.move(str(app), str(destination))
        print(f'Archived {app} → {destination}', flush=True)

    os.replace(staged_app, installed)
    subprocess.run([registrar, '-f', '-R', str(installed)], check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['open', '-a', str(installed)], check=True)
    deadline = time.monotonic() + 8
    while not running() and time.monotonic() < deadline:
        time.sleep(0.1)
    active = running()
    installed_executable = executable(installed)
    if len(active) != 1 or active[0][1] != str(installed_executable):
        raise RuntimeError(f'Expected one process from {installed}; found {active}')
    if digest(installed_executable) != expected_digest:
        raise RuntimeError('Installed executable differs from the built executable.')

    evidence = {
        'application': str(installed), 'build': manifest['CFBundleVersion'],
        'sha256': expected_digest, 'pid': active[0][0], 'archive': str(archive)
    }
    evidence_path = Path('build/validation/installed-build.json')
    evidence_path.parent.mkdir(parents=True, exist_ok=True)
    evidence_path.write_text(json.dumps(evidence, indent=2) + '\n')
    print(json.dumps(evidence, indent=2), flush=True)
finally:
    shutil.rmtree(staging, ignore_errors=True)
PY
