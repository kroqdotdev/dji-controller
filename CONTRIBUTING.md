# Contributing to Lavboard

Thanks for helping out. Bug reports, fixes, protocol findings, support for more mic systems and new features are all welcome.

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
for package in Packages/*/; do swift test --package-path "$package"; done
```

The app tests cover the real-time mixer, the resampler, track settings and updates; each package under `Packages/` tests its own module (the DJI tests cover the DUML framing, status decoding and command encoding). None of them need hardware, and CI runs all of them on every pull request.

## Adding a mic system

Lavboard supports wireless mic systems through modules: one Swift package per system under `Packages/`, built on the `MicSystem` contract in [`Packages/MicSystemKit`](Packages/MicSystemKit/Sources/MicSystemKit/MicSystem.swift). A module talks to its receiver and reports what it knows. It never draws UI and never touches the audio engine, so it can't break the mixer, and every system gets the same console look.

### What a module provides

Required:

- `id`, `name` and `transmitterCount`. The `id` is saved with every track that uses the system, so never change it after a release.
- `isReceiver(_:)`: recognises the receiver's CoreAudio input device, usually by its USB vendor and product ID.
- `transmitters`: one `TransmitterState` per slot (connected, battery, gain and so on; leave unknown fields nil).
- `audioChannel(forSlot:)`: which channel of the receiver's audio carries each transmitter, in the current mode.

Optional. Implement only what the hardware supports, and the app shows only those controls:

| Capability | Shown as |
|---|---|
| `gain` and `setGain(_:slot:)` | A mic gain stepper on the strip |
| `battery` and `charging` in `TransmitterState` | A battery icon on the strip |
| `canRecordOnTransmitters` and `setTransmitterRecording(_:)` | "Backup on mics" in the transport bar |
| `modes`, `currentModeID`, `setMode(_:)`, `modeSwitchWarning(to:)` | A mode menu in the toolbar, with a confirmation when the module warns |
| `settings`, `settingsNote`, `set(_:to:)` | A section in Settings with toggles and choices |
| `notice` | A banner above the desk, optionally with a button that switches mode |

### Steps

1. Copy [`Packages/MicSystemTemplate`](Packages/MicSystemTemplate) to `Packages/<YourSystem>`, rename the package, target and type, and pick an `id` (lowercase with dashes, such as `rode-wireless-pro`).
2. Start audio-only: fill in `isReceiver(_:)` and `audioChannel(forSlot:)`. With the receiver plugged in, its transmitters appear under **Add track**.
3. Register the module: add the package under `packages:` and to the Lavboard target's `dependencies:` in `project.yml`, list the type in `MicSystems.all` in `App/MicSystems.swift`, and add a row to the table in the README.
4. Add controls as you work out the receiver's protocol. A module reaches its receiver through a `ControlLink`, a plain byte pipe. On macOS, `USBBulkLink` in MicSystemKit opens a USB vendor interface and streams its bulk endpoints, which is how the DJI module talks to its receiver. On iOS, `ExternalAccessoryLink` in the `MicSystemAccessory` library opens an MFi accessory's protocol instead; it lives in a separate library because App Store builds can only declare accessory protocols with the maker's approval. Take the link in an initializer, as `DJIMicMini2S(link:)` does, so an app can run the module audio-only. A system that uses HID or Bluetooth LE can use those instead; whatever it needs stays inside the module.
5. Test the decoding with real captured traffic, as `Packages/DJIMicMini2S/Tests` does, and run `swift test --package-path Packages/<YourSystem>`.

### Rules for modules

- **Never send anything destructive without the user's explicit confirmation**: commands that erase recordings, factory-reset or reboot hardware. Document every parameter the module sends, and what it does, next to its definition.
- **Confirm changes** from the receiver's own status reports rather than assuming a command worked; report unconfirmed gain as `pendingGainDB`.
- **Hop to the main actor** before touching state from USB or other callbacks.
- **Say what you tested on**: the hardware, firmware and modes, in the pull request.

Modules are compiled into the app and reviewed as pull requests. Lavboard deliberately doesn't load plug-ins at runtime: notarization and the hardened runtime depend on library validation, and code that talks to hardware deserves review.

### On Windows

The Windows app in [`windows/`](windows/README.md) has the same contract in C#: `IMicSystem` in [`windows/src/Lavboard.Core/MicSystems.cs`](windows/src/Lavboard.Core/MicSystems.cs). A Windows module is one class under `windows/src/Lavboard.Core/MicSystems/`, listed in `App.Live()` in `windows/src/Lavboard/App.xaml.cs`. Use the same `id` as the macOS module, so saved tracks mean the same thing on both. `IsReceiver` gets the endpoint's USB IDs (`AudioDevice.IsUsb(vendor, products)`). Windows has no control link yet, so Windows modules are audio-only for now, like [`DjiMicMini2S.cs`](windows/src/Lavboard.Core/MicSystems/DjiMicMini2S.cs).

### Working without hardware

Debug builds include a fake two-transmitter system that uses the Mac's built-in microphone as its "receiver". Every capability is simulated, which is handy for interface work:

```sh
defaults write com.sauerdev.lavboard.debug FakeMicSystem -bool true    # then relaunch a debug build
defaults delete com.sauerdev.lavboard.debug FakeMicSystem               # turn it off again
```

## Testing with a receiver

Debug builds run as `com.sauerdev.lavboard.debug`, with their own settings and microphone permission, so they can sit next to an installed copy of Lavboard without touching it. Their settings live in that domain (`defaults read com.sauerdev.lavboard.debug`).

Most real-world behaviour needs a supported receiver plugged in. Debug builds include a command bridge, so you can exercise the app from a shell:

```sh
swiftc -O -o /tmp/lavctl tools/lavctl.swift
/tmp/lavctl "status /tmp/status.json"   # receiver, transmitters, engine and meters as JSON
/tmp/lavctl "snapshot /tmp/window.png"  # render the window to a PNG
/tmp/lavctl "gain 2 3"                   # set TX2 to +3 dB on the first system with hardware gain
```

Other commands are listed in `App/DebugBridge.swift`. Restore any setting you change while testing.

To refresh the README screenshot, switch on all four transmitters and run `tools/readme-screenshot.sh`. It stages demo labels and speech, captures the window and restores your settings.

The Python scripts in `tools/` talk to the DJI receiver directly and are handy for protocol work, and a good model for exploring another receiver. Quit the app first, because only one process can hold the receiver's control interface.

## Protocol safety

Receivers can have destructive commands, and they rarely ask before acting. On the DJI Mic Mini 2S, parameter `0x07` sent to a transmitter **formats it and deletes every recording**, and `0x23` sent to the receiver reboots it. Neither is exposed in the app. No module may send a command like that without an explicit confirmation from the user.

When you add a DJI parameter, document what it does in `Packages/DJIMicMini2S/Sources/DJIMicMini2S/MicProtocol.swift`, confirm the change through the receiver's status pushes, and add a decoding test using a real captured frame. Other modules follow the same pattern.

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

`scripts/release.sh` archives the app, signs it with Developer ID through the Apple Developer account signed into Xcode, notarizes it, packages a DMG and signs an update feed (`appcast.xml`) for it:

```sh
scripts/release.sh 0.2.0 --notarize --publish
```

`--publish` creates a draft GitHub release with the DMG and `appcast.xml` attached; review it on GitHub, then publish it. Installed copies read `appcast.xml` from the latest published release and offer the update. Bump the driver's `CFBundleVersion` in `project.yml` whenever the stream device changes, so existing installs offer the driver update too.

### Windows

Windows releases are separate, tagged `windows-v<version>`. Push a tag and the **Windows release** workflow builds, tests and packs the app with [Velopack](https://velopack.io), then publishes a release with the installer and the update feed:

```sh
git tag windows-v0.1.0 && git push origin windows-v0.1.0
```

Windows releases are never marked latest, because the macOS app reads `appcast.xml` from the latest release; installed Windows copies find the newest `windows-v` release themselves. Builds aren't code-signed yet, so SmartScreen warns on first run. Run the workflow by hand to build and pack without publishing. See [`windows/README.md`](windows/README.md#releasing) for packing locally and testing updates.

### Update signing key

Updates are signed with a Sparkle EdDSA key that lives in the maintainer's login keychain; its public half is `SUPublicEDKey` in `project.yml`. The first release on a new Mac asks for keychain access: choose **Always Allow**. Keep an offline backup of the private key, because installed copies can't verify updates signed with any other key:

```sh
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -x lavboard-update-key.txt   # export
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys -f lavboard-update-key.txt   # import on another Mac
```

### Testing an update locally

Debug builds don't check the public feed: they run as `com.sauerdev.lavboard.debug`, and Sparkle can't replace an app with one that has a different bundle identifier. They only check a test feed set in `LavboardTestFeedURL`, so the test update must be a debug build too. Build a newer debug version into a folder, sign a feed for it and serve the folder (Sparkle only downloads over http or https):

```sh
xcodebuild -project Lavboard.xcodeproj -scheme Lavboard -configuration Debug -derivedDataPath build/update-test MARKETING_VERSION=9.9.9 -quiet
mkdir -p feed && ditto -c -k --keepParent build/update-test/Build/Products/Debug/Lavboard.app feed/Lavboard-9.9.9.zip
build/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_appcast --download-url-prefix http://127.0.0.1:8765/ feed/
python3 -m http.server 8765 --bind 127.0.0.1 --directory feed
defaults write com.sauerdev.lavboard.debug LavboardTestFeedURL http://127.0.0.1:8765/appcast.xml
```

Launch an older debug build: the update button appears within a few seconds. Remove the test feed afterwards with `defaults delete com.sauerdev.lavboard.debug LavboardTestFeedURL`.

## License

Lavboard is licensed under GPL-3.0. By contributing, you agree that your contributions are licensed under the same terms.
