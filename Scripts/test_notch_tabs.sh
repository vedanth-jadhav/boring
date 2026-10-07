#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
tab_binary_dir="$PWD/.build/$(uname -m)-apple-macosx/debug"
[[ -d "$tab_binary_dir/Modules" ]] || tab_binary_dir="$PWD/.build/debug"
tab_test_dir=$(mktemp -d /tmp/boring-tab-tests.XXXXXX)
trap 'rm -rf "$tab_test_dir"' EXIT
tab_defaults_objects=("$tab_binary_dir/Defaults.build/"*.o)
/usr/bin/xcrun --sdk macosx swiftc -swift-version 5 -warnings-as-errors \
  -parse-as-library -sdk "$SDKROOT" -I "$tab_binary_dir/Modules" \
  boringNotch/enums/generic.swift Scripts/NotchTabChecks.swift \
  "${tab_defaults_objects[@]}" -o "$tab_test_dir/checks"
"$tab_test_dir/checks"
