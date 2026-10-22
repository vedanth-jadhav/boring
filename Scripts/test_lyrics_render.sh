#!/bin/bash
# Compare native on-screen rendering with HEAD, or a supplied renderer snapshot.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
lyrics_render_dir=$(mktemp -d /tmp/boring-lyric-render.XXXXXX)
trap 'rm -rf "$lyrics_render_dir"' EXIT
lyrics_output="$PWD/build/validation/lyrics-motion"
mkdir -p "$lyrics_output" "$lyrics_render_dir/baseline"
lyrics_models=(boringNotch/models/Lyric{Line,Timeline,VocalFrame,WordPhase,PlaybackClock,PhoneticTiming}.swift)
lyrics_views=(boringNotch/components/LiveActivities/{KaraokeLyricLineView,LyricCanvasView,LyricTextLayout}.swift)
lyrics_baseline=()
lyrics_common=(boringNotch/models/LyricsRomanizer.swift boringNotch/models/RomanizationLexicon.swift Scripts/LyricRenderChecks.swift)
lyrics_native=(boringNotch/models/LyricHandoffPhase.swift boringNotch/components/LiveActivities/{LyricPaintLayer,LyricPaintView}.swift)
if [[ -n "${1:-}" ]]; then
  for name in LyricWordPhase LyricCanvasView LyricTextLayout; do
    [[ -f "$1/$name.swift" ]] || { echo "Missing baseline snapshot: $1/$name.swift" >&2; exit 1; }
  done
  # Snapshot the changed paint/model/layout files before a visual refinement.
  for source in "${lyrics_models[@]}" "${lyrics_views[@]}" "${lyrics_native[@]}"; do
    snapshot="$1/$(basename "$source")"
    if [[ -f "$snapshot" ]]; then lyrics_baseline+=("$snapshot"); else lyrics_baseline+=("$source"); fi
  done
  lyrics_baseline_flags=(-D LYRIC_RENDER_CHECKS)
else
  for source in "${lyrics_models[@]}" "${lyrics_views[@]}" boringNotch/components/LiveActivities/HighlightedLyricWord.swift; do
    target="$lyrics_render_dir/baseline/$(basename "$source")"
    git show "HEAD:$source" > "$target"
    lyrics_baseline+=("$target")
  done
  lyrics_baseline_flags=(-D LYRIC_MOTION_BASELINE)
fi
xcrun swiftc -O -swift-version 5 -parse-as-library -sdk "$SDKROOT" "${lyrics_baseline_flags[@]}" \
  "${lyrics_baseline[@]}" "${lyrics_common[@]}" -o "$lyrics_render_dir/before"
xcrun swiftc -O -swift-version 5 -parse-as-library -sdk "$SDKROOT" -D LYRIC_RENDER_CHECKS \
  "${lyrics_models[@]}" "${lyrics_views[@]}" "${lyrics_common[@]}" \
  "${lyrics_native[@]}" \
  -o "$lyrics_render_dir/after"
for version in before after; do
  for mode in active paused silence; do
    "$lyrics_render_dir/$version" "$mode" > "$lyrics_output/$version-$mode.json"
    cat "$lyrics_output/$version-$mode.json"
  done
done
"$lyrics_render_dir/after" render "$lyrics_render_dir/frames"
ffmpeg -v error -y -framerate 60 -i "$lyrics_render_dir/frames/%04d.png" -c:v libx264 -crf 17 -pix_fmt yuv420p "$lyrics_output/preview.mp4"
ffmpeg -v error -y -i "$lyrics_output/preview.mp4" -vf 'fps=1,tile=3x4' -frames:v 1 "$lyrics_output/contact.png"
python3 - "$lyrics_output" <<'PY'
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
for mode in ('active', 'paused', 'silence'):
    baseline = json.loads((root/f'before-{mode}.json').read_text())
    before = baseline['cpu_percent_one_core']
    measured = json.loads((root/f'after-{mode}.json').read_text())
    after = measured['cpu_percent_one_core']
    print(f'{mode}: {before:.2f}% -> {after:.2f}% of one CPU core')
    assert after < max(before * 1.1, before + 1), f'{mode} rendering regressed beyond the measurement margin'
    if mode == 'active':
        assert after < 25, 'Three lyric lanes exceeded the CPU budget'
        assert measured['frame_ticks'] >= 100, 'Native display link did not animate on screen'
        assert measured['paints'] >= 50, 'Native view did not paint the measured frames'
        if 'frame_ticks' in baseline:
            assert measured['frame_ticks'] >= baseline['frame_ticks'] * 0.85, 'Lower CPU came with lost animation cadence'
    else:
        assert measured['frame_ticks'] == 0, 'An idle lyric row kept its display link running'
print('PASS: active, paused and silent native rendering remain within the CPU regression budget')
PY
