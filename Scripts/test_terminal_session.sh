#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
mkdir -p build/validation
/usr/bin/xcrun --sdk macosx swiftc -parse-as-library \
  boringNotch/models/Terminal/TerminalSessionSupport.swift \
  boringNotch/models/Terminal/TerminalSessionSnapshot.swift \
  boringNotch/managers/Terminal/TerminalSessionBackend.swift \
  Scripts/TerminalSessionChecks.swift \
  -o build/validation/terminal-session-checks
build/validation/terminal-session-checks
