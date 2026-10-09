# Boring Notch Octave for Windows

The original black island, rebuilt in **Electron 44** with a **.NET 10 native Windows helper**. The floating layout fits screens without a notch; edge placement retains the original silhouette. The macOS application remains available separately.

## Install

Windows 10 22H2 / Windows 11, x64. The complete ZIP includes Electron and the .NET runtime. No administrator privileges, Python or developer tools are needed.

1. Extract **all** files from `Boring-Notch-Octave-Windows-x64.zip`.
2. Double-click **Setup.cmd**. It installs for your Windows account, registers the browser bridge, adds a Start menu shortcut and an entry in Installed apps, then opens onboarding. Windows may ask whether to run this unsigned download.
3. Choose **Music & lyrics**, **Focus & your day**, **Files & sharing**, and/or **Your PC & tools**. Choose floating, original edge or corner placement. Change any choice in Settings later.

`BoringNotch.exe` also runs portably; use Setup to register Octave's native messaging host. Install location: `%LOCALAPPDATA%\Programs\BoringNotch`. Personal data: `%LOCALAPPDATA%\BoringNotch`. Installed apps or **Uninstall.cmd** removes the installed application while keeping settings and shelf copies. Startup is optional in onboarding. There is no automatic updater or signing certificate in this build.

For Octave, open `brave://extensions`, enable Developer mode and load the installed `octave-brave-extension` folder. Reload Octave, then choose **Settings → Music → Music source → Octave in Brave** in the island. The app must be running. The extension reconnects automatically; its pinned ID matches the original macOS extension. Setup also registers the host with Chrome and Edge. Loading an unpacked extension is a browser-controlled step and is not bypassed by the installer.

## Behavior

Rest the pointer on the island for 160 ms to open it. Leaving starts a 420 ms grace period, then a critically damped spring folds the surface back. Re-entering during collapse reverses the same spring without restarting its position or velocity. Artwork remains one shared element throughout the morph. File dialogs, active operations and focused text inputs keep the island open. Dragging files onto it opens the shelf.

**Ctrl+Windows+B** shows/hides the island; **Escape** collapses it. The tray opens Settings and quits. Placement follows the selected display's working area and DPI; removing a display falls back to an available one. Fullscreen hiding is optional. Reduced motion removes spatial transitions and moving lyric highlights. Native Windows acrylic replaces Apple Liquid Glass; disabled Windows transparency, high contrast, unavailable composition or the Glass switch selects the opaque surface. The transparent canvas passes desktop clicks outside the visible island.

The open music surface is 640 × 190 logical pixels; compact mode is 204 × 34. Small desktops adapt the open width. Animation frames stop when geometry settles; playback interpolation runs only while the expanded music page is playing. Camera and WASAPI visualization stop when their page closes. A native message pump handles WinRT callbacks, while bounded IPC keeps file/network work from blocking cursor motion.

## Windows replacements

| Feature | Implementation |
| --- | --- |
| Music | Windows Global System Media Transport Controls: sessions, metadata, artwork, play/pause, skip and seek. Individual players determine which controls they expose. |
| Octave | Original browser extension, current-user named pipe and bounded native messaging. Bidirectional playback commands; no TCP server or Python dependency. |
| Lyrics | Provider-supplied word times, separate backing vocals and sampled playback clock. Shared Hindi/Punjabi/Urdu attested romanization data. Optional LRCLIB lookup supplies cached line-timed/plain lyrics. |
| Visualization | Opt-in WASAPI loopback FFT, local processing, active only in the expanded music page. Compact bars indicate playback; they are not an audio spectrum. |
| Focus | Deadline-based timer with pause/resume/reset, restart restoration and optional Windows sleep prevention. Caffeine runs its own stay-awake countdown. |
| Calendar | Local ICS imports, timezone/recurrence expansion and reminders. Re-import exports to refresh; this is not a live calendar-account sync. |
| Files | Managed copies; file/folder drop, drag out, open/reveal/export, ZIP, image conversion/resizing and image-to-PDF/PDF merging. Removing a shelf item never removes the original. |
| Screenshots | Windows virtual-desktop capture with the island temporarily hidden. Protected content can be excluded by Windows. |
| Sharing | Windows Share UI, with Nearby Sharing when enabled; replaces AirDrop. |
| System | Battery/AC, endpoint volume/mute/device changes and compact volume feedback. Laptop brightness uses Windows CIM; external monitors may require their own controls. |
| Mirror | Windows camera preview, no microphone, recording or upload. Stops on collapse, page change or exit; Windows privacy settings govern access. |
| Codex | Cached local JSONL session totals and recorded quota; manual plan refresh uses the existing Codex CLI sign-in. |

AppleScript, XPC, SkyLight and Apple Liquid Glass are replaced by the Windows service and desktop compositor. Windows has no universal keyboard-backlight API. Exact karaoke timing requires provider-supplied word timing; line lyrics are not presented as exact timing. The macOS Spicy Lyrics API-key integration is not used by this edition.

## Build and development

Install Node 24 and the .NET SDK in `global.json` (10.0.401, with compatible feature-band roll-forward). From `windows/`:

```powershell
dotnet restore Boring.Native/Boring.Native.csproj --locked-mode -r win-x64
dotnet test Boring.Tests/Boring.Tests.csproj -c Release
cd electron
npm ci
npm test
cd ..
./Scripts/Build.ps1
```

Build publishes a self-contained Windows helper, packages Electron with ASAR, includes the original extension and notices, and writes a ZIP plus SHA-256 in `artifacts/`. GitHub Actions performs the same build on Windows. Linux can cross-package with `bash Scripts/build.sh`; a cached official Electron ZIP can be supplied with `-ElectronZipDirectory` / `ELECTRON_ZIP_DIR`.

For the Linux development UI, build the helper with `dotnet build Boring.Native -c Release`, then run `npm start` in `electron/` with a desktop display. Set `DOTNET_HOST` if dotnet is not on PATH and `BORING_DATA_HOME` to an isolated directory. Native Windows actions show explicit unavailable states on Linux. Cloud setup is `bash windows/Scripts/setup-cloud.sh` from the repository root.

## Privacy and validation

Local features do not upload personal files. **Find lyrics** sends track metadata to LRCLIB only when clicked. HTTPS artwork is bounded and decoded locally. **Refresh plan allowance** reads existing Codex CLI credentials only on request and sends them to a fixed ChatGPT endpoint without redirects; it neither logs/persists credentials nor changes CLI sign-in. Renderer navigation/network access is blocked by CSP, and the sandboxed renderer uses an allowlisted native bridge.

See [QA.md](QA.md) for observed checks and limitations. The recorded demo runs the actual Electron interface and native helper on the Linux cloud desktop with disclosed music/calendar/log fixtures. Cross-building does **not** validate Windows registry installation, acrylic, GSMTC, WASAPI, camera, sharing, laptop brightness or Windows shortcut behavior on hardware.

GPL-3.0. Original: TheBoredTeam; fork: Vedanth Jadhav. Dakshina romanization data: CC-BY-SA-4.0, with original attribution bundled beside the data. Other bundled licenses are listed in `THIRD_PARTY_NOTICES.md`, Electron's `LICENSE` and `LICENSES.chromium.html`.
