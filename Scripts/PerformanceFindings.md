# Performance changes and verification

The changes separate content preparation from clock sampling, bound animation
cadence, remove optical effects where they are invisible, and tie audio work to
visible consumers. The original findings were source-based; these changes do
not establish a measured CPU or battery improvement by themselves.

| Findings | Result |
| --- | --- |
| 1 | Exact lyrics sample at up to 30 fps (10 with Reduce Motion). Vocal splitting, identities, short-word counts and activity intervals are prepared with each response. Frames are cached between vocal boundaries; layout keys use row identity, dimensions and romanization. |
| 2 | Only actively sung words instantiate the shimmer overlay. Other words use static opacity. Fitting/paged lines have no outer fade mask. Word anchors use a prepared binary-search index that preserves source order; page lookup and accessibility text are prepared once. |
| 3 | LRC rows use static whole-word pages with explicit timestamp scheduling, preserving long-line readability without per-word shimmer. Paused playback has only an immediate schedule entry. |
| 4 | Both slider layouts tick at 250 ms only while playing with positive rate. Direct anchor/state observation preserves paused external seeks and track changes. |
| 5–6 | Shadow rendering uses only the silhouette, with its interior cut out to preserve transparent glass. The music controls have no compositing group. |
| 7, 11 | Closed surfaces use `Glass.identity`, which disables the effect while preserving the content tree through open/close. There is one outer notch clip. Appearance → Reduce glass selects the opaque fallback. |
| 8 | Artwork lighting uses an average-color radial gradient. The paused dimming overlay has no blur and retains rounded corners. The existing close-transition blur is bounded to the transition. |
| 9 | Marquee motion uses a cancellable task with pauses between cycles and a rasterized glyph group. Short text has no duplicate. Width/text/Reduce Motion changes restart the task. |
| 10 | Compact lyric height comes from point size and displayed row count. There is no height GeometryReader or preference loop. |
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
- `bash Scripts/test_performance.sh`: 36 Swift checks, including the existing
  lyrics suites, cache invalidation, precise boundaries, playback rate,
  downsampling/color, AppKit visibility, consumer lifetime and shell subscriptions;
  also runs browser parser/clock/reconnection/dedup/buffering tests.
- `bash Scripts/test_focus_session.sh`: production focus state machine and IOPM
  lifecycle checks.
- `bash Scripts/test_notifications.sh --skip-build`: 13 notification checks,
  including content rendering, burst queues, application opening and helper behavior.
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
