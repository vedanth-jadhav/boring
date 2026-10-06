#!/bin/bash
# Swift CLI build, bundle, and stable local signing. No Xcode or Apple account.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
configuration="${1:-release}"
build_jobs="${BORING_BUILD_JOBS:-1}"
[[ "$build_jobs" =~ ^[1-9][0-9]*$ ]] || toolchain_error "BORING_BUILD_JOBS must be a positive integer."
# SwiftPM's job limit and the Swift driver's concurrency are separate. Keep
# each compiler single-threaded, and let foreground apps take priority.
build_flags=(--jobs "$build_jobs" -Xswiftc -j1 -Xswiftc -num-threads -Xswiftc 1)
low_priority_swift_build() {
  # CLT 27's Swift Build engine appends its own CPU-count thread setting after
  # -Xswiftc flags. SwiftPM's native scheduler honors the explicit job limit.
  /usr/bin/nice -n 10 /usr/bin/xcrun --sdk macosx swift build --build-system native "${build_flags[@]}" "$@"
}
# Swift Build in CLT 27 can stamp the deployment version as the linked SDK.
# Supply the public linker platform tuple explicitly; the SDK and minimum OS
# are different inputs. This preserves the existing macOS 14 deployment target.
sdk_link_flags=(-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$selected_sdk_version")
app="$PWD/build/Boring Notch Octave.app"
identity="${BORING_CODESIGN_IDENTITY:-Boring Notch Octave Local}"
app_version="${BORING_APP_VERSION:-2.8.1-local}"
bash Scripts/prepare_spm.sh
if [[ "$identity" != "-" ]] && ! security find-identity -v -p codesigning | grep -Fq "\"$identity\""; then
  bash Scripts/setup_local_signing.sh
fi
low_priority_swift_build -v -c "$configuration" --skip-update --sdk "$SDKROOT" "${sdk_link_flags[@]}" --product boringNotch
low_priority_swift_build -v -c "$configuration" --skip-update --sdk "$SDKROOT" "${sdk_link_flags[@]}" --product BoringNotchXPCHelper
binary_dir=$(apple_swift build --build-system native -c "$configuration" --show-bin-path)
for binary in boringNotch BoringNotchXPCHelper; do
  /usr/bin/xcrun otool -l "$binary_dir/$binary" | python3 -c '
import re, sys
text = sys.stdin.read()
match = re.search(r"cmd LC_BUILD_VERSION\s+cmdsize \d+\s+platform \d+\s+minos [\d.]+\s+sdk ([\d.]+)", text)
if not match or match.group(1) != sys.argv[1]:
    sys.exit("SDK verification failed: linked binary does not record selected macOS " + sys.argv[1] + " SDK")
print("Verified linked SDK:", match.group(1))
' "$selected_sdk_version"
done
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" \
  "$app/Contents/Frameworks" "$app/Contents/PrivateFrameworks" \
  "$app/Contents/XPCServices/BoringNotchXPCHelper.xpc/Contents/MacOS"
cp "$binary_dir/boringNotch" "$app/Contents/MacOS/boringNotch"
cp "$binary_dir/BoringNotchXPCHelper" "$app/Contents/XPCServices/BoringNotchXPCHelper.xpc/Contents/MacOS/"
cp boringNotch/boring.m4a "$app/Contents/Resources/"
cp -R boringNotch/Resources/Romanization "$app/Contents/Resources/"
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

python3 - "$app" "$app_version" <<'PY'
import datetime, pathlib, plistlib, sys
app=pathlib.Path(sys.argv[1]); contents=app/'Contents'
build_date = datetime.datetime.now(datetime.timezone.utc)
build_version = build_date.strftime('%Y%m%d%H%M%S')
info={
  'CFBundleName':'Boring Notch Octave','CFBundleDisplayName':'Boring Notch Octave',
  'CFBundleIdentifier':'local.vedanth.boringnotch.octave',
  'CFBundleExecutable':'boringNotch','CFBundlePackageType':'APPL',
  'CFBundleShortVersionString':sys.argv[2],'CFBundleVersion':build_version,
  'BNLocalBuildDate':build_date.isoformat(),
  'LSMinimumSystemVersion':'14.0','LSUIElement':True,
  'CFBundleIconFile':'BoringNotch.icns','NSAppleEventsUsageDescription':'Controls music playback.',
  'NSAudioCaptureUsageDescription':'Displays a waveform for the selected music source.',
  'NSCameraUsageDescription':'Displays the camera in the notch.',
  'NSCalendarsUsageDescription':'Displays calendar events.',
  'NSRemindersUsageDescription':'Displays reminders.',
  'SUEnableAutomaticChecks':False,'SUAllowsAutomaticUpdates':False,
  'BNLocalBuild':True
}
(contents/'Info.plist').write_bytes(plistlib.dumps(info))
helper=contents/'XPCServices/BoringNotchXPCHelper.xpc/Contents'
h={'CFBundleIdentifier':'local.vedanth.boringnotch.octave.BoringNotchXPCHelper',
   'CFBundleExecutable':'BoringNotchXPCHelper','CFBundlePackageType':'XPC!',
   'CFBundleShortVersionString':sys.argv[2],'CFBundleVersion':build_version,
   'XPCService':{'ServiceType':'Application'}}
(helper/'Info.plist').write_bytes(plistlib.dumps(h))
PY

for framework in "$binary_dir"/*.framework; do
  if [[ -d "$framework" ]]; then cp -R "$framework" "$app/Contents/Frameworks/"; fi
done
for bundle in "$binary_dir"/*.bundle; do
  if [[ -d "$bundle" ]]; then cp -R "$bundle" "$app/Contents/Resources/"; fi
done
install_name_tool -add_rpath '@executable_path/../Frameworks' "$app/Contents/MacOS/boringNotch" 2>/dev/null || true
# Native SwiftPM preserves read-only checkout resource permissions on copy.
# Make only staged bundle resources writable before stripping attributes.
chmod -R u+w "$app/Contents/Resources"
xattr -cr "$app"
find "$app" -name '._*' -delete
find "$app/Contents/Frameworks" "$app/Contents/PrivateFrameworks" -name '*.framework' -maxdepth 1 -print0 | while IFS= read -r -d '' framework; do
  codesign --force --deep --sign "$identity" "$framework"
done
codesign --force --sign "$identity" "$app/Contents/XPCServices/BoringNotchXPCHelper.xpc"
codesign --force --sign "$identity" "$app"
codesign --verify --deep --strict --verbose=2 "$app"
echo "$app"
