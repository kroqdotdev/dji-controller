# Contributing to Lavboard

Thanks for helping out. Bug reports, fixes, protocol findings and new features are all welcome.

For anything bigger than a small fix, open an issue first so we can agree on the approach before you spend time on it.

## Getting set up

You need macOS 15 or later, Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
xcodegen generate
open Lavboard.xcodeproj
```

The Xcode project is generated from `project.yml` and is not committed. Edit `project.yml`, never the generated project.

Builds are ad-hoc signed by default. To sign with your own Apple Development identity (macOS then keeps the microphone permission across rebuilds), create `Config/Local.xcconfig`. It is git-ignored:

```
DEVELOPMENT_TEAM = YOURTEAMID
CODE_SIGN_IDENTITY = Apple Development
```

## Running the tests

```sh
xcodebuild -project Lavboard.xcodeproj -scheme Lavboard test
```

The tests cover the DUML framing, status decoding, command encoding and the real-time mixer. None of them need hardware, and CI runs them on every pull request.

## Testing with a receiver

Most real-world behaviour needs a DJI Mic Mini 2S receiver plugged in. Debug builds include a command bridge, so you can exercise the app from a shell:

```sh
swiftc -O -o /tmp/lavctl tools/lavctl.swift
/tmp/lavctl "status /tmp/status.json"   # receiver, transmitters, engine and meters as JSON
/tmp/lavctl "snapshot /tmp/window.png"  # render the window to a PNG
/tmp/lavctl "gain 2 3"                   # set TX2 to +3 dB
```

Other commands are listed in `App/DebugBridge.swift`. Restore any setting you change while testing.

The Python scripts in `tools/` talk to the receiver directly and are handy for protocol work. Quit the app first, because only one process can hold the receiver's control interface.

## Protocol safety

Some receiver parameters are destructive. Parameter `0x07` sent to a transmitter **formats it and deletes every recording without asking**, and `0x23` sent to the receiver reboots it. Neither is exposed in the app, and new code must never send them without an explicit confirmation from the user.

When you add a parameter, document what it does in `App/Device/MicProtocol.swift`, confirm the change through the receiver's status pushes, and add a decoding test using a real captured frame.

## Code guidelines

- **Match the surrounding code**: naming, comment density and structure.
- **Real-time audio:** nothing called from `AudioCoreIOProc` may allocate, lock, log or touch Objective-C or Swift objects. Hand data across threads with atomics or the ring buffer.
- **UI:** use the tokens in `App/UI/Theme.swift` (palette, fonts, corner radii). Red is reserved for "muted" and "recording". Labels are sentence case. Every control needs an accessibility label.
- **BlackHole** in `Vendor/BlackHole` stays unmodified. Configure the stream device through `Driver/StreamDriverConfig.h`.

## Pull requests

1. Branch from `main` and keep each pull request focused on one change.
2. Make sure the tests pass and add tests for new logic.
3. Describe what you tested on real hardware, if anything, and include a screenshot for UI changes.
4. CI must pass before merging. Pull requests are squash-merged, so the title becomes the commit message: write it as a short imperative sentence, such as "Add per-mic pan".

## Releasing (maintainers)

`scripts/release.sh` archives the app, signs it with Developer ID through the Apple Developer account signed into Xcode, notarizes it and packages a DMG:

```sh
scripts/release.sh 0.2.0 --notarize --publish
```

`--publish` creates a draft GitHub release with the DMG attached; review it on GitHub, then publish it. Bump the driver's `CFBundleVersion` in `project.yml` whenever the stream device changes, so existing installs offer the update.

## License

Lavboard is licensed under GPL-3.0. By contributing, you agree that your contributions are licensed under the same terms.
