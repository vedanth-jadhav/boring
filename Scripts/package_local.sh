#!/bin/bash
# Swift CLI build, bundle, and stable local signing. No Xcode or Apple account.
set -euo pipefail
cd "$(dirname "$0")/.."
configuration="${1:-release}"
build_jobs="${BORING_BUILD_JOBS:-2}"
app="$PWD/build/Boring Notch Octave.app"
identity="Boring Notch Octave Local"
bash Scripts/prepare_spm.sh
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
if ! security find-identity -v -p codesigning | grep -Fq "\"$identity\""; then
  bash Scripts/setup_local_signing.sh
fi
swift build -c "$configuration" --jobs "$build_jobs" --skip-update --product boringNotch
swift build -c "$configuration" --jobs "$build_jobs" --skip-update --product BoringNotchXPCHelper
binary_dir=$(swift build -c "$configuration" --show-bin-path)
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" \
  "$app/Contents/Frameworks" "$app/Contents/PrivateFrameworks" \
  "$app/Contents/XPCServices/BoringNotchXPCHelper.xpc/Contents/MacOS"
cp "$binary_dir/boringNotch" "$app/Contents/MacOS/boringNotch"
cp "$binary_dir/BoringNotchXPCHelper" "$app/Contents/XPCServices/BoringNotchXPCHelper.xpc/Contents/MacOS/"
cp boringNotch/boring.m4a "$app/Contents/Resources/"
cp mediaremote-adapter/mediaremote-adapter.pl mediaremote-adapter/MediaRemoteAdapterTestClient "$app/Contents/Resources/"
cp -R mediaremote-adapter/MediaRemoteAdapter.framework "$app/Contents/PrivateFrameworks/"
cp octave-brave-extension/native_host.py "$app/Contents/Resources/octave-native-host.py"
cp -R octave-brave-extension "$app/Contents/Resources/octave-brave-extension"
chmod +x "$app/Contents/Resources/octave-native-host.py"

# Command Line Tools do not include a working asset catalog compiler. Copy
# named images as bundle resources and build a standard icon with iconutil.
python3 - "$app/Contents/Resources" <<'PY'
import json, pathlib, shutil, sys
root = pathlib.Path('boringNotch/Assets.xcassets')
destination = pathlib.Path(sys.argv[1])
for directory in root.glob('*.imageset'):
    manifest = json.loads((directory/'Contents.json').read_text())
    images = [item.get('filename') for item in manifest.get('images', []) if item.get('filename')]
    if not images: continue
    source = directory/images[0]
    shutil.copy2(source, destination/(directory.stem + source.suffix))
for directory in root.glob('*.symbolset'):
    manifest = json.loads((directory/'Contents.json').read_text())
    for item in manifest.get('symbols', []):
        if item.get('filename'):
            source = directory/item['filename']
            shutil.copy2(source, destination/(directory.stem + source.suffix))
PY
icon_source='boringNotch/Assets.xcassets/AppIcon.appiconset/notch-stage-icon2 10.png'
iconset="$PWD/.build/BoringNotch.iconset"
mkdir -p "$iconset"
for size in 16 32 128 256 512; do
  sips -s format png -z "$size" "$size" "$icon_source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
done
for size in 16 32 128 256 512; do
  double=$((size * 2))
  sips -s format png -z "$double" "$double" "$icon_source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/BoringNotch.icns"

python3 - "$app" <<'PY'
import pathlib, plistlib, sys
app=pathlib.Path(sys.argv[1]); contents=app/'Contents'
info={
  'CFBundleName':'Boring Notch Octave','CFBundleDisplayName':'Boring Notch Octave',
  'CFBundleIdentifier':'local.vedanth.boringnotch.octave',
  'CFBundleExecutable':'boringNotch','CFBundlePackageType':'APPL',
  'CFBundleShortVersionString':'2.8.1-local','CFBundleVersion':'1',
  'LSMinimumSystemVersion':'14.0','LSUIElement':True,
  'CFBundleIconFile':'BoringNotch.icns','NSAppleEventsUsageDescription':'Controls supported music apps.',
  'NSAudioCaptureUsageDescription':'Displays a waveform for the selected music source.',
  'NSCameraUsageDescription':'Displays the camera in the notch.',
  'NSContactsUsageDescription':'Matches contacts to notifications.',
  'NSCalendarsUsageDescription':'Displays calendar events.',
  'NSRemindersUsageDescription':'Displays reminders.',
  'SUEnableAutomaticChecks':False,'SUAllowsAutomaticUpdates':False,
  'BNLocalBuild':True
}
(contents/'Info.plist').write_bytes(plistlib.dumps(info))
helper=contents/'XPCServices/BoringNotchXPCHelper.xpc/Contents'
h={'CFBundleIdentifier':'local.vedanth.boringnotch.octave.BoringNotchXPCHelper',
   'CFBundleExecutable':'BoringNotchXPCHelper','CFBundlePackageType':'XPC!',
   'CFBundleShortVersionString':'2.8.1-local','CFBundleVersion':'1',
   'XPCService':{'ServiceType':'Application'},
   'NSAppleEventsUsageDescription':'Replies to messages at your request.'}
(helper/'Info.plist').write_bytes(plistlib.dumps(h))
PY

for framework in "$binary_dir"/*.framework; do
  if [[ -d "$framework" ]]; then cp -R "$framework" "$app/Contents/Frameworks/"; fi
done
for bundle in "$binary_dir"/*.bundle; do
  if [[ -d "$bundle" ]]; then cp -R "$bundle" "$app/Contents/Resources/"; fi
done
install_name_tool -add_rpath '@executable_path/../Frameworks' "$app/Contents/MacOS/boringNotch" 2>/dev/null || true
xattr -cr "$app"
find "$app" -name '._*' -delete
find "$app/Contents/Frameworks" "$app/Contents/PrivateFrameworks" -name '*.framework' -maxdepth 1 -print0 | while IFS= read -r -d '' framework; do
  codesign --force --deep --sign "$identity" "$framework"
done
codesign --force --sign "$identity" "$app/Contents/XPCServices/BoringNotchXPCHelper.xpc"
codesign --force --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
echo "$app"
