#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
volume_check_dir=$(mktemp -d /tmp/boring-volume-startup.XXXXXX)
trap 'rm -rf "$volume_check_dir"' EXIT
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -sdk "$SDKROOT" \
  boringNotch/components/OSD/Managers/XPC/VolumeManager.swift \
  Scripts/VolumeStartupChecks.swift -o "$volume_check_dir/checks"
for scenario in increase repeat decrease fine mute software-mute absolute unreadable; do
  "$volume_check_dir/checks" "$scenario"
done
