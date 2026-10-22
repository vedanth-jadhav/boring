"""Keep the credential broker's signed identity across source/toolchain/cache changes."""
import fcntl
import hashlib
import os
from pathlib import Path
import platform
import plistlib
import re
import ssl
import subprocess
import sys
import tempfile

destination = Path(sys.argv[1])
signer = sys.argv[2]
identifier = 'local.vedanth.boringnotch.octave.LyricsKeychain'
architecture = platform.machine()
certificate = None
if signer != '-':
    pem = subprocess.check_output(['security', 'find-certificate', '-c', signer, '-p'], text=True)
    certificate = hashlib.sha1(ssl.PEM_cert_to_DER_cert(pem)).hexdigest()
requirement = f'=identifier "{identifier}"'
if certificate:
    requirement += f' and certificate leaf = H"{certificate}"'
store = Path(os.environ.get('BORING_LYRICS_HELPER_STORE',
    str(Path.home() / 'Library/Application Support/Boring Notch/Credential Helper')))
store = store / (certificate or 'ad-hoc') / architecture / 'v1'
store.mkdir(parents=True, exist_ok=True, mode=0o700)
installed = Path(os.environ.get('BORING_LYRICS_INSTALLED_APP', '/Applications/Boring Notch Octave.app'))
installed = installed / 'Contents/XPCServices/LyricsKeychain.xpc'
pinned = store / 'LyricsKeychain.xpc'


def valid(bundle):
    try:
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        if (info.get('CFBundleIdentifier') != identifier
                or info.get('CFBundleExecutable') != 'LyricsKeychain'
                or info.get('CFBundleVersion') != '1'
                or info.get('XPCService') != {'ServiceType': 'Application', 'JoinExistingSession': True}):
            return False
        executable = bundle / 'Contents/MacOS/LyricsKeychain'
        inspection_environment = {key: value for key, value in os.environ.items() if key != 'SDKROOT'}
        arches = subprocess.check_output(['lipo', '-archs', str(executable)], text=True,
                                         env=inspection_environment).split()
        return architecture in arches and subprocess.run(
            ['codesign', '--verify', '--strict', '-R', requirement, str(bundle)],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0
    except (OSError, ValueError, plistlib.InvalidFileException, subprocess.CalledProcessError):
        return False


def copy_verified(source, target):
    target.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.lyrics-stage-', dir=target.parent) as staging:
        staged = Path(staging) / target.name
        subprocess.run(['ditto', str(source), str(staged)], check=True)
        if not valid(staged):
            raise RuntimeError('Credential helper failed signature or compatibility verification.')
        if target.exists():
            raise RuntimeError(f'Refusing to overwrite credential helper: {target}')
        os.rename(staged, target)


def code_hash(bundle):
    details = subprocess.check_output(['codesign', '-dv', '--verbose=4', str(bundle)], stderr=subprocess.STDOUT, text=True)
    return re.search(r'^CDHash=(.+)$', details, re.MULTILINE).group(1)


with (store / '.lock').open('a') as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    # This executable is a storage identity, not a disposable compiler cache. Changes to
    # protocol v1 require an explicit migration, never an automatic broker replacement.
    if pinned.exists() and not valid(pinned):
        raise RuntimeError('Pinned credential helper is damaged; preserved it instead of resetting Keychain access.')
    if certificate and valid(installed):
        source = installed
        if not pinned.exists():
            copy_verified(source, pinned)
        elif code_hash(pinned) != code_hash(installed):
            raise RuntimeError('Installed and pinned credential helpers differ; an explicit storage migration is required.')
    elif pinned.exists():
        source = pinned
    else:
        with tempfile.TemporaryDirectory(prefix='.lyrics-build-', dir=store) as staging:
            built = Path(staging) / 'LyricsKeychain.xpc'
            executable = built / 'Contents/MacOS/LyricsKeychain'
            executable.parent.mkdir(parents=True)
            sources = ['LyricsKeychainHelper/main.swift', 'Shared/LyricsKeychainProtocol.swift',
                       'boringNotch/helpers/LegacyKeychainAccess.swift', 'boringNotch/helpers/SpicyLyricsCredential.swift']
            subprocess.run(['xcrun', '--sdk', 'macosx', 'swiftc', '-swift-version', '5', '-O',
                            '-target', f'{architecture}-apple-macosx14.0', '-sdk', os.environ['SDKROOT'],
                            *sources, '-o', str(executable)], check=True)
            info = {'CFBundleIdentifier': identifier, 'CFBundleName': 'Boring Notch Lyrics',
                    'CFBundleExecutable': 'LyricsKeychain', 'CFBundlePackageType': 'XPC!',
                    'CFBundleVersion': '1',
                    'XPCService': {'ServiceType': 'Application', 'JoinExistingSession': True}}
            (built / 'Contents/Info.plist').write_bytes(plistlib.dumps(info))
            subprocess.run(['codesign', '--force', '--sign', signer, str(built)], check=True)
            copy_verified(built, pinned)
        source = pinned
    copy_verified(source, destination)
    print(f'Preserved credential helper: {source}')
