#!/bin/bash
# Build a distributable, ad-hoc signed DMG for Macs without a Developer ID.
set -euo pipefail
cd "$(dirname "$0")/.."

version="${1:-2.8.1}"
if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "Usage: $0 [major.minor.patch]" >&2
  exit 2
fi

export BORING_APP_VERSION="$version"
export BORING_CODESIGN_IDENTITY=-
bash Scripts/package_local.sh release

release_dir="$PWD/build/releases"
stage="$release_dir/stage"
app_name="Boring Notch Octave.app"
dmg="$release_dir/Boring-Notch-Octave-$version-macOS.dmg"
mkdir -p "$release_dir"
rm -rf "$stage" "$dmg"
mkdir -p "$stage"
ditto "build/$app_name" "$stage/$app_name"

# Developer ID signing and notarization require a paid Apple developer account.
# Ad-hoc signing preserves the nested XPC/framework signature structure while
# allowing the recipient to make the first-launch Gatekeeper decision.
codesign --force --deep --sign - --timestamp=none "$stage/$app_name"
codesign --verify --deep --strict --verbose=2 "$stage/$app_name"
ln -s /Applications "$stage/Applications"
cp RELEASE_INSTALL.md "$stage/Read Me - Installation.txt"
cp LOCAL_OCTAVE.md "$stage/LOCAL_OCTAVE.md"

hdiutil create -volname "Boring Notch Octave $version" \
  -srcfolder "$stage" -ov -format UDZO "$dmg"
shasum -a 256 "$dmg" | tee "$dmg.sha256"
rm -rf "$stage"
echo "Created $dmg"
