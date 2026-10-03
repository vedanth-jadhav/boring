#!/bin/bash
# Runs the XCTest test methods with assertion shims when CLT has no XCTest.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
if [[ "${1:-}" == "--skip-build" ]]; then
  # Read existing native artifacts without taking SwiftPM's build lock.
  binary_dir="$PWD/.build/$(uname -m)-apple-macosx/debug"
  [[ -d "$binary_dir/Modules" ]] || binary_dir="$PWD/.build/debug"
  [[ -d "$binary_dir/Modules" ]] || { echo "Build the debug app first." >&2; exit 1; }
else
  bash Scripts/prepare_spm.sh
  apple_swift build --build-system native --jobs 2 -Xswiftc -j2 -c debug --product boringNotch > /tmp/boring-notifications-build.log 2>&1
  binary_dir=$(apple_swift build --build-system native -c debug --show-bin-path)
fi
test_directory=$(mktemp -d /tmp/boring-notification-tests.XXXXXX)
trap 'rm -rf "$test_directory"' EXIT
python3 - "$test_directory" <<'PY'
from pathlib import Path
import re, sys
source = Path('boringNotchTests/NotificationMirroringTests.swift').read_text()
source = source.replace('import XCTest\n', '').replace('@testable import boringNotch\n', '')
tests = re.findall(r'func (test\w+)\(\)( async)?( throws)?', source)
runner = ['\n@main struct NotificationTestRunner {', ' @MainActor static func main() async throws {',
          '  NSApplication.shared.setActivationPolicy(.prohibited)', '  let suite = NotificationMirroringTests()']
for name, asynchronous, throwing in tests:
    runner.append('  '+('try ' if throwing else '')+('await ' if asynchronous else '')+'suite.'+name+'()')
    runner.append('  print("PASS '+name+'")')
runner += ['  print("'+str(len(tests))+' notification tests passed")', ' }', '}']
(Path(sys.argv[1])/'NotificationTests.swift').write_text(source+'\n'.join(runner))
PY
objects=()
for object in "$binary_dir/Defaults.build/"*.o "$binary_dir/AsyncXPCConnection.build/"*.o; do
  objects+=("$object")
done
/usr/bin/xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -D BORING_LOCAL_BUILD \
  -I "$binary_dir/Modules" \
  Shared/BoringNotchXPCHelperProtocol.swift Shared/Notification*.swift Shared/NativeBannerMatch.swift \
  boringNotch/XPCHelperClient/XPCHelperClient.swift boringNotch/helpers/AppIcons.swift boringNotch/extensions/ConditionalModifier.swift \
  boringNotch/Notifications/*.swift boringNotch/Notifications/Views/*.swift \
  boringNotch/animations/drop.swift boringNotch/components/Notch/NotchShape.swift boringNotch/components/LiquidGlassBackground.swift \
  boringNotch/components/NativeNotchGlass.swift boringNotch/components/NotchGlassDimming.swift \
  Scripts/NotificationTestSupport.swift "$test_directory/NotificationTests.swift" \
  "${objects[@]}" -o "$test_directory/NotificationTests"
"$test_directory/NotificationTests"
