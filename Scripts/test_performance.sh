#!/bin/bash
# Run the production performance paths and XCTest methods without requiring Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
performance_binary_dir="$PWD/.build/$(uname -m)-apple-macosx/debug"
[[ -d "$performance_binary_dir/Modules" ]] || performance_binary_dir="$PWD/.build/debug"
[[ -d "$performance_binary_dir/Modules" ]] || { echo "Build the app with SwiftPM's native build system first." >&2; exit 1; }
performance_test_dir=$(mktemp -d /tmp/boring-performance-tests.XXXXXX)
trap 'rm -rf "$performance_test_dir"' EXIT
python3 - "$performance_test_dir" <<'PY'
from pathlib import Path
import re, sys
classes = ['LyricsTimingTests', 'LyricsPrecisionTests', 'LyricsServiceTimingTests', 'PerformanceRegressionTests']
sources = []
runner = ['@main struct PerformanceTestRunner {', ' @MainActor static func main() async throws {',
          '  NSApplication.shared.setActivationPolicy(.prohibited)']
count = 0
for cls in classes:
    source = Path('boringNotchTests/'+cls+'.swift').read_text().replace('import XCTest\n', '').replace('@testable import boringNotch\n', '')
    sources.append(source)
    runner.append('  let '+cls.lower()+' = '+cls+'()')
    for name, asynchronous, throwing in re.findall(r'func (test\w+)\(\)( async)?( throws)?', source):
        runner.append('  '+('try ' if throwing else '')+('await ' if asynchronous else '')+cls.lower()+'.'+name+'()')
        runner.append('  print("PASS '+cls+'.'+name+'")')
        count += 1
runner += ['  checkShellSubscription()', '  checkVisibleCaptureConsumers()',
           '  print("'+str(count + 2)+' performance regression checks passed")', ' }', '}']
(Path(sys.argv[1])/'Tests.swift').write_text('\n'.join(sources+runner))
PY
performance_objects=("$performance_binary_dir/Defaults.build/"*.o)
/usr/bin/xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -D BORING_LOCAL_BUILD \
  -I "$performance_binary_dir/Modules" \
  boringNotch/models/Lyric{Line,Timeline,VocalFrame,WordPhase,PlaybackClock}.swift \
  boringNotch/models/LyricsRomanizer.swift boringNotch/managers/LyricsService.swift \
  boringNotch/MediaControllers/MediaAppBundleID.swift boringNotch/helpers/AppleScriptHelper.swift \
  boringNotch/components/LiveActivities/LyricTextLayout.swift boringNotch/extensions/NSImage+Extensions.swift \
  boringNotch/components/Music/MusicVisualizer.swift boringNotch/components/LiveActivities/NotchMusicState.swift \
  Scripts/PerformanceLifecycleChecks.swift Scripts/PerformanceTestSupport.swift "$performance_test_dir/Tests.swift" \
  "${performance_objects[@]}" -o "$performance_test_dir/checks"
"$performance_test_dir/checks"
node Scripts/test_octave_lyrics.cjs
