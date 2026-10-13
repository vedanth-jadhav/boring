#!/bin/bash
# Exercise the integrated engine with fake power/process services and temporary journals.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
caffeine_check_dir=$(mktemp -d /tmp/boring-caffeine-checks.XXXXXX)
trap 'rm -rf "$caffeine_check_dir"' EXIT
sources=(ThirdParty/CaffeineEngine/CaffeineEngine.swift ThirdParty/CaffeineEngine/{Core,System,Model,Store}/*.swift)
/usr/bin/xcrun --sdk macosx swiftc -swift-version 6 -parse-as-library -sdk "$SDKROOT" \
  -target arm64-apple-macosx14.0 "${sources[@]}" Scripts/CaffeineEngineChecks.swift -o "$caffeine_check_dir/checks"
BORING_CAFFEINE_HOME="$caffeine_check_dir/runtime" "$caffeine_check_dir/checks"
