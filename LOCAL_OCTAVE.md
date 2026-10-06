# Local Octave build

This build is for macOS and Octave in Brave Browser. It uses a separate app ID,
`local.vedanth.boringnotch.octave`. The local installer maintains one active
copy in `/Applications/Boring Notch Octave.app`.

## Build and install

The macOS Command Line Tools are sufficient. No Xcode or Apple Developer account
is needed. Use Command Line Tools for Xcode 27, including the macOS 27.x SDK
and Apple Swift 6.4. The scripts invoke `/usr/bin/xcrun`, resolve the canonical
selected SDK path, and reject older SDKs or conflicting environment overrides.
Verbose builds print the actual compiler command (`-sdk …/MacOSX27.x.sdk`).
The linker receives an explicit macOS platform tuple and packaging verifies
`LC_BUILD_VERSION` records SDK 27.x, independently of the macOS 14 minimum OS.
The package uses Swift tools version 6.0, Swift 5 language mode, and a macOS 14
deployment target; these settings do not select the SDK.

Standalone CLT 27 omits `SwiftUIMacros`. `ViewState` explicitly aliases Apple's
public `SwiftUI.State<Value>` property wrapper to retain this fork's existing
state semantics without that macro plugin. `prepare_spm.sh` applies the same
selection to the pinned dependencies and retains its existing public
EnvironmentKey replacement and removal of development previews. No SDK files
are modified, and no older SDK is used.

The packaging script creates a stable, trusted local code signing identity the first
time it runs.

```sh
bash Scripts/install_local.sh release
bash Scripts/install_octave_bridge.sh
```

The bridge installer uses `Scripts/install_local.sh --skip-build` to stop running
Boring Notch copies, archive older installed bundles under
`~/Library/Application Support/Boring Notch/Archived Builds`, install the signed
bundle in `/Applications`, and launch it. It verifies the installed executable's
checksum and that exactly one instance runs from that path. To build, install,
and launch without reinstalling the browser bridge, run
`bash Scripts/install_local.sh release`.

For active development, use `bash Scripts/install_local.sh debug` after changes.
It rebuilds, stops the running app, archives duplicate bundles, installs the
fresh build, and launches it from `/Applications`. Builds reuse
`.build` and cached dependencies, preserve unchanged helper inputs, and use one
build job by default to limit CPU load. Swift compiler jobs and threads are
also limited to one, and builds run at lower scheduling priority (`nice 10`).
The CLI selects SwiftPM's supported native build engine because CLT 27's
default Swift Build engine overrides the compiler thread limit.
Set `BORING_BUILD_JOBS` to deliberately change the package job limit. Rebuilds use
the same signing identity and bundle ID. The installer places native messaging
manifests in Brave's directory and the Chrome compatibility directory used by
some Brave versions.

## One-time Brave setup

1. Open `brave://extensions` in the Brave profile where you use Octave.
2. Turn on **Developer mode**, then select **Load unpacked**.
3. Select this repository's `octave-brave-extension` folder, or the bundled
   extension folder in `/Applications/Boring Notch Octave.app/Contents/Resources/`.
4. Reload the Octave tab.
5. Select **Octave in Brave** as Boring Notch's music source.

The extension is limited to `https://music.octavestreaming.com/`. Brave launches
the packaged native messaging host, which connects to a user-only Unix socket.
Music commands never require activating Brave or selecting the Octave tab.

The notch reads Octave's audio deck for position and uses Octave's own shuffle
cycle (off → shuffle → smart shuffle when smart shuffle is enabled in Octave's
settings and its backend is available). Lyrics come from Octave's `https://api.octavestreaming.com/api/lyrics`
endpoint, with the existing lyrics service as fallback. The real-time bars
capture Brave's audio utility process; macOS audio capture permission must be
granted for the signed local app. Reload the unpacked extension at
`brave://extensions` after changing its files.

The local package has no Sparkle feed or update key and disables the updater UI.
It cannot install upstream releases over this custom build. macOS may reject
the self-signed app under Gatekeeper if it is quarantined after copying from
another Mac; local packaging and opening it on this Mac works without
notarization.

Lyrics are romanised by default for Hindi, Punjabi (Gurmukhi and Shahmukhi),
and Urdu. Disable **Romanise Hindi, Punjabi and Urdu lyrics** under Media
controls to read the original script. Octave's rich lyrics retain exact word
start/end times for the white shimmer. Hindi, Hinglish, Punjabi and Urdu sources
with only line timestamps use a syllable-weighted word shimmer. Its word times
are approximate and stay within the source line window; other line-only sources
keep their phrase sheen. Untimed lyrics display their first readable line and have no
word highlight. Urdu spellings without written vowels may be approximate.

The shimmer follows each source word's audio phase directly, with a soft
attack up to 120 ms, release up to 180 ms, and one broad eased reflection.
Short syllables scale both fades to fit their exact timing; there is no
independent word-fade timer. Browser sample times
are retained across the native bridge, and clock drift above 12 ms is corrected.
Display refresh and the provider's alignment still determine visible accuracy.
Lyrics stay visible through intros, gaps, and outros: the first phrase is
previewed, then each lead phrase stays until the next begins. Empty timestamp
markers do not blank the row. Only words inside their sung start/end window
shimmer. Sequential parenthesised ad-libs stay inline; overlapping backing
vocals use a second row only within their own vocal window. Single vocals
reserve no empty second row. Words return to a constant resting brightness.
Rapid verses use stationary whole-word phrase pages with gentle crossfades.
Romanisation preserves original tokens, punctuation and
English, and never translates the lyrics' meaning.
