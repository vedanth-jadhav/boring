# Windows port QA — 2026-10-08

Architecture: Electron 44.7.0, sandboxed local renderer; .NET SDK 10.0.401 with a self-contained Windows x64 native helper. Tested on the Linux cloud desktop, with Windows cross-compilation. This file records observed scope; it is not a Windows hardware certification.

## Automated checks

- Native helper: Release builds for net10.0 and net10.0-windows10.0.19041.0 with warnings treated as errors.
- 18 .NET tests: deadlines, pause/resume/restart, corrupted settings, exact lyrics and stale-track handling, attested romanization, bounded/truncated IPC, local calendar recurrence, Codex snapshot deduplication, real image/PDF/ZIP output and preservation of original files/folders.
- 8 Electron tests: continuous spring reversal, refresh-rate-independent trajectories, reduced motion, playback sampling/background vocals, fragmented/out-of-order native replies, error handling and helper shutdown.
- Existing Octave parser, overlapping-vocal, precise-clock and reconnect regression: passed.

## Desktop QA

The actual Electron window is inspected on a 1440 × 900 desktop and a 390 logical-pixel adaptive viewport. Three-step onboarding, feature selection, floating/edge placement, music/lyrics, focus, caffeine, shelf, calendar/reminders, Codex, system availability, mirror and settings are exercised. Playback commands use the actual framed native host and named pipe. File operations use real managed copies. Demo music, calendar events and Codex session totals are fixtures, not an authenticated user's data.

The first visual pass found asynchronous Codex clipping and small-display sizing; these were corrected together. The independent Impeccable reviewer returned **ship** for all 18 required still captures with no material UI fixes. This verdict does not certify motion or Windows hardware. Actual cursor QA separately observed compact 204 px → open 640 px, a closing trajectory at 210.20 px → reopened 640 px, and immediate reduced-motion snapping, with no renderer exceptions. A Linux-only X11 cursor query handles Chromium’s stale cached pointer while its development window is click-through; Windows uses Electron’s native cursor API. The final demo is a recording of the real desktop window, not a mockup.

## Platform limits

Windows media sessions, WASAPI/volume, acrylic/opaque fallback, camera privacy, Windows Share/Nearby Sharing, brightness, tray/global shortcut, fullscreen detection, startup and registry installation require a Windows runtime for final validation. The unsigned x64 distribution and per-user setup are built here; Linux cannot execute the Windows installer or test physical Windows devices.

The macOS source is preserved. The repository's Mac installation check cannot complete on this host because xcrun and the macOS SDK are unavailable. An existing Python release suite has unrelated stale workflow/scheme failures; those are not reported as passing by this port.

## Distribution checks

The actual PowerShell build completed on this host, including locked Windows restore, self-contained publish and Electron packaging. Package inspection confirmed both Windows PE executables, ASAR, original extension, per-user setup/uninstall scripts and license notices, with no rejected Avalonia runtime or QA/personal profile files. All PowerShell scripts parse. The reusable cloud setup ran successfully with official Electron SHA256 verification.

Latest user steering added restrained blue selected/hover/pressed/focus materials and pale-blue primary onboarding actions. Geometry/layout are preserved. The updated full desktop recording completed at 3m14s with no renderer errors; its overlay explicitly identifies the Linux host and demo fixtures. Keyboard focus was verified with actual Tab/Shift+Tab input.

The final blue-control review returned **ship** for 18 captures and inspected recording samples. Installer/uninstaller stop and wait for only the owned installed Electron/helper processes before replacing/removing binaries; Windows execution remains outside the validated scope.

## Resume QA confirmation

A fresh-profile pass on 2026-10-08 repeated all 26 automated tests and the original Octave regressions successfully. The current Windows native target compiled with zero warnings and zero errors. No new application defects were found in this pass.

The actual Electron UI passed onboarding selection, native-bridge pause/play/next, focus countdown and pause/reset, real ZIP/PDF/JPEG generation, reminder persistence, and inspection of all main pages. Sixteen fresh page captures showed no horizontal overflow at 680 or 390 logical pixels. Actual cursor input measured 204 px collapsed, 640 px expanded, and 302.14 px during closing before reopening to 640 px. Reduced motion snapped immediately. The renderer reported no exceptions. Actual Tab/Shift+Tab verified the 2 px blue keyboard focus ring; hover feedback was inspected separately.

Release verification checked ZIP CRCs, SHA256, Windows executable headers, byte equality of packaged renderer/main/preload/geometry code, the published helper and installer scripts, and the absence of rejected Avalonia/QA-profile files. All PowerShell scripts parsed successfully. The existing full demo is H.264, 1280 × 990, 60 fps, 193.9 seconds; sampled frames were inspected. Windows runtime and physical-device limits above still apply.
