# Performance changes and verification

The changes separate content preparation from clock sampling, bound animation
cadence, remove optical effects where they are invisible, and tie audio work to
visible consumers. The original findings were source-based; these changes do
not establish a measured CPU or battery improvement by themselves.

| Findings | Result |
| --- | --- |
| 1 | Row selection uses explicit source-timestamp scheduling. Exact vocal timing samples the active row at 60 fps on one canvas; estimates and phrase sheen use 30 fps unless dense vocals need 60 fps. Translation, font measurement, paging and row selection remain outside the frame loop. Vocal splitting, identities and activity intervals are prepared with each response. Frames are cached between vocal boundaries; layout keys use row identity, dimensions and romanization. |
| 2 | The active word uses a feathered white light front and a soft crest over fixed glyph positions and sizes. There is no word lift, scaling, shadow, underline, glyph overlay/mask or geometry reader. Words under 180 ms light fully at onset. The last glyph settles into completed ink without an end flash. Pause/buffering freezes the sweep; Reduce Motion uses steady ink. Long lines page at source timestamps; expanded romanized tokens are measured and fitted on cache miss. |
| 3 | Hindi/Hinglish/Punjabi/Urdu line-only sources use estimated syllable-weighted word windows within the source line bounds. Exact provider timestamps remain distinct and take priority. Other line-only sources keep the phrase sheen. Paused playback has only an immediate row schedule entry and pauses active-text animation. |
| 4 | Both slider layouts tick at 250 ms only while playing with positive rate. Direct anchor/state observation preserves paused external seeks and track changes. |
| 5–6 | Shadow rendering uses only the silhouette, with its interior cut out to preserve transparent glass. The music controls have no compositing group. |
| 7, 11 | Closed surfaces use `Glass.identity`, which disables the effect while preserving the content tree through open/close. There is one outer notch clip. Appearance → Reduce glass selects the opaque fallback. |
| 8 | Artwork lighting uses an average-color radial gradient. The paused dimming overlay has no blur and retains rounded corners. The existing close-transition blur is bounded to the transition. |
| 9 | Marquee motion uses a cancellable task with pauses between cycles and a rasterized glyph group. Short text has no duplicate. Width/text/Reduce Motion changes restart the task. |
| 10 | Both open layouts show one primary lyric line at a fixed height derived from point size. Backing vocal boundaries do not resize the player. The view and canvas keep their identities across line/page handoffs, and hidden backing vocals have no display schedule. There is no height GeometryReader or preference loop. |
| 12 | Browser metadata dedup excludes position/sample time. Events use a separate handler so event objects cannot force every timeupdate. Clock discontinuities publish immediately; playing heartbeats use 5 s. Buffering freezes the extrapolated clock and reconnection requests a fresh anchor. Native jitter tolerance is 150 ms with a 5 s forced anchor interval. |
| 13, 23 | The shell subscribes only to playing/idle/notice state, with deduplication. Closed media content and peek labels have independent views. Brightness/volume observations are removed. Shell preferences use `@Default`, and activity/content/width calculations are shared within each body pass. Existing Combine consumers remain compatible. |
| 14, 22 | Visualizers register when attached to a visible window and release demand on hide, occlusion, removal or dismantling. Capture requires consumers plus playing/enabled state and suspends for system/display sleep and screen lock. FFT/lifecycle queues use utility QoS and FFT timer leeway is 10 ms. Audio input delivery retains a responsive queue. Offscreen decorative animations stop. |
| 15 | Accessibility authorization checks use a 60 s interval with 10 s tolerance, plus startup, app activation and AX operations. Revocation detection remains available to this accessory app. |
| 16 | Artwork decodes directly to a maximum 256-pixel thumbnail on a utility queue. Average color samples at most 64×64. AppKit-only image formats retain the previous decode fallback. |
| 17 | Apple Music transfers artwork only when the persistent track ID changes (or artwork is unavailable). Metadata and position refresh independently; overlapping refresh requests are coalesced. Missing persistent IDs fall back to metadata identity. |
| 18 | Valid content detection latches. Until detection, pasteboard probes are throttled to 150 ms: checking only the first mouse event would miss source apps that start dragging later. |
| 19–21, 24 | ISO formatter is reused, paused focus timelines stop, and dimming stops are static. The original 17-stop contrast profile is retained. Background Apple Events and color analysis use utility priority; clicked transport commands retain user-initiated priority. |
| 25 | The delayed provider-first fetch rechecks cancellation, track identity and provider cache before starting a web request. Provider responses cancel active fallback tasks. |
| 26 | Pinned MacroVisionKit 0.2.0 uses workspace/screen-change notifications; source inspection found no internal polling timer. Instruments confirmation remains outstanding. |

## Automated validation

- `swift build --build-system native --product boringNotch`.
- `bash Scripts/test_performance.sh`: 60 Swift checks, including the existing
  lyrics suites, cache invalidation, precise boundaries, event scheduling, playback rate,
  Unicode normalization, broader-script romanization, the Iraaday example,
  bundled pronunciation indexes and expanded-token fitting,
  downsampling/color, AppKit visibility, consumer lifetime and shell subscriptions;
  also runs browser parser/clock/reconnection/dedup/buffering tests.
- `bash Scripts/test_focus_session.sh`: production focus state machine and IOPM
  lifecycle checks.
- `git diff --check`.

The selected Command Line Tools SDK has no XCTest framework. The CLI runner
compiles the production code unchanged, executes the XCTest methods with
fail-fast assertions, and isolates capture/manager dependencies with test doubles.
Full XCTest/Xcode UI tests and Instruments/WindowServer/powermetrics comparisons
remain separate validation steps. No zero-regression or quantified battery claim
is made from source inspection and automated checks alone.

The browser extension and an already-open Octave page must be reloaded to run
the new page-side bridge; installing the macOS app only updates native behavior.

Apple documents the no-effect identity variant at
[Glass.identity](https://developer.apple.com/documentation/swiftui/glass/identity),
and the visibility lifecycle at
[NSWindow.didChangeOcclusionStateNotification](https://developer.apple.com/documentation/appkit/nswindow/didchangeocclusionstatenotification).

## Pronunciation data and rendering

Hindi/Punjabi/Urdu romanization first checks curated spellings, then 88,100
human-attested entries derived from Dakshina v1.0, then conservative script
rules. Optional Urdu vowel marks and Arabic letter variants use the same lookup
key; explicit Punjabi addak still doubles the consonant. Other scripts use
Foundation's Unicode Latin transform. Existing Latin text stays intact.
The 2,412,229-byte data set is memory-mapped, binary-searched and loaded only for
the script needed. Converted strings and measured layouts stay cached outside
the animation path. Runtime requires no extra process, inference or network.

The actual Iraaday provider response contains LRC line timings (42.58–47.91 s
for the reported line), rather than exact word alignment. Its phrase now gets
a text-only sweep, and the Urdu line reads “kaisa samaa hai, hum tum yahaan hain.”
The UI cannot establish word timing absent from the source. Human romanization
also varies by context; the table improves lexical coverage rather than
establishing a measured tenfold pronunciation accuracy increase.

A local optimized CLI benchmark of the real Iraaday response measured 0.826 ms
for the first full-song conversion (original: 0.362 ms), then 3.183 µs per cached
lookup over 100,000 calls (original: 3.001 µs). This measures conversion/cache
work, not whole-application CPU or battery usage. The raw run is saved in
`build/validation/romanization-benchmark.txt`.

For Majboor and Banda Kaam Ka, Octave currently supplies only LRCLIB line
timestamps. The Hindi/Hinglish fallback now enables individual word sheen,
with syllable weights prepared once per response rather than using script
character counts. Native and romanized display share the same estimated clock.
English line-only behavior and all exact provider word stamps are preserved.
The full responses passed 143 and 423 word-window checks respectively, including
native/romanized page coverage. An optimized CLI sample measured preparation
at 0.73/3.95 ms and cached page/phase sampling at 0.47/0.68 microseconds per
sample. These are model/layout measurements, not application CPU or battery
measurements. Evidence: `build/validation/hinglish-highlight-validation.txt`.
