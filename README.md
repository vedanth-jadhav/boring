# Boring Notch Octave

**Boring Notch Octave is Vedanth Jadhav’s maintained version of Boring Notch for macOS.** It builds on [TheBoredTeam’s original Boring Notch](https://github.com/TheBoredTeam/boring.notch) and adds a Brave + Octave music experience, karaoke lyrics, focus sessions, and a custom local release flow.

This repository is the source for **Boring Notch Octave**. It is an independently maintained fork, not an official release of TheBoredTeam’s app.

## Demo

[![Watch the Boring Notch Octave demo](assets/boring-notch-octave-demo.gif)](assets/boring-notch-octave-demo.mov)

[Open the full 13-second screen recording](assets/boring-notch-octave-demo.mov).

## What changed from upstream

The project starts from [TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch), based on upstream commit [`fb26431`](https://github.com/TheBoredTeam/boring.notch/commit/fb2643121741c6ba6102d5ef2b2c7a787f26fad1). [Compare this version with that upstream baseline](https://github.com/vedanth-jadhav/boring/compare/fb2643121741c6ba6102d5ef2b2c7a787f26fad1...main). The main additions and changes in this version are:

- **Octave in Brave:** a browser extension and native bridge connect Octave playback, controls, audio visualization, and lyrics to the notch.
- **Karaoke lyrics:** word-level timing and highlighting, vocal-aware lyric layout, and romanization for Hindi, Punjabi, and Urdu. Hindi, Hinglish, Punjabi, and Urdu lyrics with line-only timestamps get syllable-weighted estimated word timing.
- **Focus sessions:** a notch-based focus timer with duration controls and session state.
- **Liquid glass and notch polish:** updated glass treatments, music activity layouts, lyric rendering, and interaction details, with fallbacks for older macOS versions.
- **Local app delivery:** a separate app identity, signing setup, Brave bridge installer, and scripts that build, install, launch, and verify this customized app.

See [LOCAL_OCTAVE.md](LOCAL_OCTAVE.md) for the Octave bridge and local setup, and [Scripts/PerformanceFindings.md](Scripts/PerformanceFindings.md) for implementation notes and verification details.

## Download

Download the latest **Boring Notch Octave** DMG from [this repository’s Releases](https://github.com/vedanth-jadhav/boring/releases/latest). Open the DMG and drag the app to Applications. Since this release is not signed with an Apple Developer ID, macOS will ask you to approve it the first time: Control-click the app in Applications, choose **Open**, then confirm **Open**. If macOS blocks it, use **System Settings → Privacy & Security → Open Anyway**, then Control-click and open it again. Full steps, including a Terminal fallback, are in [RELEASE_INSTALL.md](RELEASE_INSTALL.md) and on the DMG. The Octave in Brave integration needs the one-time extension setup described in [LOCAL_OCTAVE.md](LOCAL_OCTAVE.md).

This build uses its own app identifier, has no automatic updater, and does not use TheBoredTeam’s Sparkle update feed. Install updates from this repository’s releases.

## Build and install from source

The project targets macOS 14 and later. The local build currently requires Apple Command Line Tools for Xcode 27, including the macOS 27 SDK and Swift 6.4. For the complete toolchain and Brave setup, see [LOCAL_OCTAVE.md](LOCAL_OCTAVE.md).

```sh
git clone https://github.com/vedanth-jadhav/boring.git
cd boring
bash Scripts/install_local.sh release
```

The installer builds and signs the app with the local signing identity, archives older installed copies, installs and launches the new build, and checks the running executable. For active development, use `bash Scripts/install_local.sh debug`.

## Attribution and license

The original Boring Notch project was created by [TheBoredTeam](https://github.com/TheBoredTeam/boring.notch). This version retains the upstream project’s GPL-3.0 license and required third-party notices; see [LICENSE](LICENSE) and [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES). The Octave integration and changes listed above are maintained in this repository by [Vedanth Jadhav](https://github.com/vedanth-jadhav).
