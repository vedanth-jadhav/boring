#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
caffeine_input_dir=$(mktemp -d /tmp/boring-caffeine-input.XXXXXX)
trap 'rm -rf "$caffeine_input_dir"' EXIT
/usr/bin/xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -sdk "$SDKROOT" \
  boringNotch/components/Notch/NotchKeyboardFocus.swift \
  boringNotch/components/Focus/CaffeineSearchTextField.swift \
  boringNotch/components/Focus/CaffeineSearchField.swift Scripts/CaffeineInputChecks.swift \
  -o "$caffeine_input_dir/checks"
"$caffeine_input_dir/checks"
bash Scripts/test_caffeine_panel.sh
