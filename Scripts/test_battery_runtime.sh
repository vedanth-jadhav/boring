#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
battery_check_dir=$(mktemp -d /tmp/boring-battery-runtime.XXXXXX)
trap 'rm -rf "$battery_check_dir"' EXIT
xcrun swiftc -swift-version 5 -parse-as-library -sdk "$SDKROOT" \
  boringNotch/managers/BatteryRuntimeEstimator.swift Scripts/BatteryRuntimeChecks.swift \
  -framework IOKit -o "$battery_check_dir/checks"
"$battery_check_dir/checks"
