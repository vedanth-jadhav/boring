#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
terminal_binary_dir="$PWD/.build/$(uname -m)-apple-macosx/release"
terminal_test_dir=$(mktemp -d /tmp/boring-terminal-monitor.XXXXXX)
trap 'rm -rf "$terminal_test_dir"' EXIT
terminal_defaults_objects=("$terminal_binary_dir/Defaults.build/"*.o)
/usr/bin/xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  -sdk "$SDKROOT" -I "$terminal_binary_dir/Modules" \
  boringNotch/models/Terminal/TerminalSessionSupport.swift \
  boringNotch/models/Terminal/TerminalSessionSnapshot.swift \
  boringNotch/models/Terminal/TerminalApplication.swift \
  boringNotch/managers/Terminal/TerminalSessionBackend.swift \
  boringNotch/managers/Terminal/NotchTerminalManager.swift \
  Scripts/TerminalManagerLifecycleChecks.swift "${terminal_defaults_objects[@]}" \
  -o "$terminal_test_dir/checks"
"$terminal_test_dir/checks"
