# Install Boring Notch Octave

This release targets macOS 14 or later. It is ad-hoc signed because the
maintainer does not have an Apple Developer ID certificate. macOS will therefore
ask you to approve opening the app the first time. The app has no automatic
updater; download a newer DMG from the project's GitHub Releases when you want
to update.

1. Open the downloaded `Boring-Notch-Octave-*-macOS.dmg` file.
2. Drag **Boring Notch Octave** onto the **Applications** shortcut in the DMG.
3. Eject the mounted disk image.
4. In Applications, Control-click **Boring Notch Octave** and choose **Open**.
5. In the confirmation dialog, choose **Open** again. The first launch may take
   a short while while macOS verifies the app.

If macOS blocks the first launch, open **System Settings → Privacy & Security**,
scroll to the Security section, and choose **Open Anyway** for Boring Notch
Octave. Then Control-click the app in Applications and choose **Open** once more.

If that button does not appear, remove the download quarantine flag from this
app only in Terminal, then open it from Applications:

```sh
xattr -dr com.apple.quarantine "/Applications/Boring Notch Octave.app"
```

The app asks separately for access to features such as screen/audio capture,
calendar, or reminders when you enable them. The Octave in Brave integration
also needs the one-time extension setup in [LOCAL_OCTAVE.md](LOCAL_OCTAVE.md).

To check the downloaded DMG before opening it, compare its SHA-256 with the
matching `.sha256` file published alongside it in GitHub Releases:

```sh
shasum -a 256 ~/Downloads/Boring-Notch-Octave-*-macOS.dmg
```
