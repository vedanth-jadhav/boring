#!/bin/bash
# Source this file so every CLI step uses the same Apple compiler and SDK.
set -euo pipefail
toolchain_error() {
  echo "Boring Notch toolchain error: $*" >&2
  echo "Install/select Apple Command Line Tools for Xcode 27 (xcode-select), then retry." >&2
  exit 1
}
[[ -z "${TOOLCHAINS:-}" ]] || toolchain_error "Unset TOOLCHAINS; this build requires Apple's selected toolchain."
selected_sdk=$(/usr/bin/xcrun --sdk macosx --show-sdk-path) || toolchain_error "No macOS SDK found."
selected_sdk=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$selected_sdk")
selected_sdk_version=$(/usr/bin/xcrun --sdk macosx --show-sdk-version)
[[ "$selected_sdk_version" == 27.* ]] || toolchain_error "Selected SDK is $selected_sdk_version; macOS 27.x SDK is required."
if [[ -n "${SDKROOT:-}" ]]; then
  requested_sdk=$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$SDKROOT")
  [[ "$requested_sdk" == "$selected_sdk" ]] || toolchain_error "SDKROOT=$SDKROOT conflicts with selected SDK $selected_sdk. Unset SDKROOT."
fi
selected_swift=$(/usr/bin/xcrun --sdk macosx --find swift)
[[ -z "${SWIFT_EXEC:-}" || "$SWIFT_EXEC" == "$selected_swift" ]] || toolchain_error "SWIFT_EXEC overrides Apple's selected Swift compiler. Unset it."
compiler_version=$(/usr/bin/xcrun --sdk macosx swift --version)
[[ "$compiler_version" == *"Apple Swift version"* ]] || toolchain_error "Selected compiler is not Apple Swift."
python3 - "$compiler_version" <<'PY' || toolchain_error "Apple Swift 6.4 or newer is required."
import re, sys
match = re.search(r'Apple Swift version (\d+)\.(\d+)', sys.argv[1])
sys.exit(0 if match and tuple(map(int, match.groups())) >= (6, 4) else 1)
PY
export SDKROOT="$selected_sdk"
apple_swift() { /usr/bin/xcrun --sdk macosx swift "$@"; }
echo "SDK: $SDKROOT ($selected_sdk_version)" >&2
echo "$compiler_version" >&2
