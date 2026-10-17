#!/bin/bash
# Compile and exercise production manager/view-model code with synthetic services and snapshots.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh

runtime_check_dir=$(mktemp -d /tmp/boring-calendar-battery.XXXXXX)
trap 'rm -rf "$runtime_check_dir"' EXIT
runtime_binary_dir="$PWD/.build/$(uname -m)-apple-macosx/debug"
[[ -d "$runtime_binary_dir/Modules" ]] || runtime_binary_dir="$PWD/.build/debug"
[[ -d "$runtime_binary_dir/Modules" ]] || {
  echo "A built Defaults module is required for the standalone runtime checks." >&2
  exit 1
}
runtime_defaults_objects=("$runtime_binary_dir/Defaults.build/"*.o)
[[ -e "${runtime_defaults_objects[0]}" ]] || {
  echo "Defaults build objects are missing; run a SwiftPM build first." >&2
  exit 1
}

/usr/bin/xcrun --sdk macosx swiftc -frontend -parse \
  boringNotch/Providers/CalendarServiceProviding.swift \
  boringNotchTests/CalendarManagerRegressionTests.swift \
  boringNotchTests/BatterySnapshotTests.swift
/usr/bin/xcrun --sdk macosx swiftc -swift-version 5 -typecheck -sdk "$SDKROOT" \
  boringNotch/models/CalendarModel.swift \
  boringNotch/models/EventModel.swift \
  boringNotch/models/MeetingLink.swift \
  boringNotch/Providers/MeetingLinkDetector.swift \
  boringNotch/Providers/CalendarServiceProviding.swift \
  Scripts/CalendarProviderTypecheckSupport.swift
/usr/bin/xcrun --sdk macosx swiftc \
  -swift-version 5 -parse-as-library -target "$(uname -m)-apple-macosx14.0" \
  -sdk "$SDKROOT" \
  -I "$runtime_binary_dir/Modules" \
  boringNotch/managers/CalendarManager.swift \
  boringNotch/managers/BatteryActivityManager.swift \
  boringNotch/models/BatteryStatusViewModel.swift \
  Scripts/CalendarBatteryRuntimeSupport.swift \
  "${runtime_defaults_objects[@]}" \
  -framework IOKit \
  -o "$runtime_check_dir/checks"
"$runtime_check_dir/checks"
