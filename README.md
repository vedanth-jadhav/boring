# Boring Notch Octave

A private, customized build of Boring Notch for macOS, with Octave in Brave browser integration and timed karaoke lyrics.

## Download

Get the latest macOS disk image from [Releases](https://github.com/vedanth-jadhav/boring/releases/latest). Open the DMG and drag **Boring Notch Octave** to Applications.

This local build uses a separate app identifier and has no Sparkle updater feed. See [LOCAL_OCTAVE.md](LOCAL_OCTAVE.md) for build, install, and Brave extension setup instructions.

## Build from source

Requires Apple Command Line Tools for Xcode 27 with the macOS 27.x SDK and Apple
Swift 6.4. The app's deployment target remains macOS 14; native notch glass is
available on macOS 27, with a solid background on older systems. Build and package with:

```sh
bash Scripts/package_local.sh release
```

The source is based on [Boring Notch](https://github.com/TheBoredTeam/boring.notch) and includes its upstream license and third-party notices.
