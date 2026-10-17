#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
artwork_test_dir=$(mktemp -d /tmp/boring-media-artwork.XXXXXX)
trap 'rm -rf "$artwork_test_dir"' EXIT
python3 - "$artwork_test_dir" <<'PY'
# The Spotify production file is compiled directly. For YouTube Music, copy
# only the production artwork state properties, updatePlaybackState method, and
# startArtworkFetch helper into the fixture; a wrapper calls the extracted
# implementation so assertions exercise shipping logic without hand-written copies.
from pathlib import Path
import sys

template = Path('Scripts/MediaArtworkHarness.swift.in').read_text()
source = Path('boringNotch/MediaControllers/YouTubeMusicController/YouTubeMusicController.swift').read_text()

properties = '\n'.join(line for line in source.splitlines() if line.startswith('    private var artwork'))
def extract_function(signature):
    start = source.index(signature)
    open_brace = source.index('{', start)
    depth = 0
    for index in range(open_brace, len(source)):
        if source[index] == '{':
            depth += 1
        elif source[index] == '}':
            depth -= 1
            if depth == 0:
                return source[start:index + 1]
    raise SystemExit(f'could not locate the balanced production function: {signature}')

method = extract_function('    private func updatePlaybackState(with response: PlaybackResponse) async {')
helper = extract_function('    private func startArtworkFetch(imageURL: String, url: URL, requestID: UUID) {')
template = template.replace('__YTM_PROPERTIES__', properties.rstrip())
template = template.replace('__YTM_METHOD__', method)
template = template.replace('__YTM_HELPER__', helper)
Path(sys.argv[1], 'MediaArtworkHarness.swift').write_text(template)
PY
xcrun swiftc -swift-version 5 -parse-as-library \
  boringNotch/models/PlaybackState.swift \
  boringNotch/MediaControllers/MediaAppBundleID.swift \
  boringNotch/MediaControllers/MediaControllerProtocol.swift \
  boringNotch/MediaControllers/SpotifyController.swift \
  "$artwork_test_dir/MediaArtworkHarness.swift" \
  -o "$artwork_test_dir/media-artwork-checks"
"$artwork_test_dir/media-artwork-checks"
