#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
battery_layout_dir=$(mktemp -d /tmp/boring-battery-layout.XXXXXX)
trap 'rm -rf "$battery_layout_dir"' EXIT
python3 - "$battery_layout_dir" "${1:-boringNotch/ContentView.swift}" <<'PY'
from pathlib import Path
import re
import sys

source = Path(sys.argv[2]).read_text()
width = source.split('&& vm.notchState == .closed && showPowerStatusNotifications {', 1)[1].split('} else if', 1)[0]
row = source.split('&& vm.notchState == .closed && showPowerStatusNotifications {', 2)[2].split('} else if', 1)[0]
row = row.replace('.frame(width: vm.closedNotchSize.width)', '.frame(width: vm.closedNotchSize.width).background(CenterProbe())')
side = re.search(r'private let batteryNotificationSideWidth: CGFloat = [^\n]+', source)
template = Path('Scripts/BatteryNotificationChecks.swift.in').read_text()
template = template.replace('__SIDE_WIDTH__', side.group() if side else '')
template = template.replace('__WIDTH__', width).replace('__ROW__', row)
Path(sys.argv[1], 'Checks.swift').write_text(template)
PY
xcrun swiftc -swift-version 5 -parse-as-library -sdk "$SDKROOT" \
  "$battery_layout_dir/Checks.swift" -o "$battery_layout_dir/checks"
"$battery_layout_dir/checks"
