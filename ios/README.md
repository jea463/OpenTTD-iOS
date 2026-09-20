# Native iOS development

The port keeps the OpenTTD 15.3 engine and uses a UIKit/Metal platform adapter. The main UIKit thread presents copies of the software framebuffer. A separate engine thread runs upstream initialization and the normal single-owner game/video tick loop.

## Build

Requires full Xcode with iOS SDKs, CMake and Ninja. From the repository root:

```sh
./ios/build.sh                 # arm64 iOS Simulator
./ios/build.sh iphoneos        # unsigned arm64 device application
```

The script builds native strgen/settingsgen tools, prepares pinned verified OpenGFX/OpenSFX assets and static liblzma when absent, and cross-builds the app. Outputs are `build/ios-iphonesimulator/openttd.app` and `build/ios-iphoneos/openttd.app`. Simulator app is ad-hoc signed. Device signing and provisioning are deliberately left to the developer.

```sh
xcrun simctl install booted build/ios-iphonesimulator/openttd.app
xcrun simctl launch --console-pty booted org.openttd.ios.dev
```

Assets and third-party licenses are bundled. No original commercial TTD graphics are required. Save/config/content directories live in the application Documents container; bundled resources are immutable. Removing the app removes its sandbox unless exported first.

For the simplest personal-device setup, install CMake and Ninja with Homebrew and
run `./ios/open-xcode.sh`. For complete physical-device signing steps, see
[XCODE.md](XCODE.md). For standard saves in Files, see [FILES.md](FILES.md).

## Current limitations

Sprite fonts only, English locale default, no music playback, PNG or HTTP content downloading. Native sound effects use RemoteIO and bundled OpenSFX; physical audio routes and interruptions still need device testing. Full engine scripting, world simulation and native saves remain present. Native crash reports are used. External URLs and clipboard are not yet bridged. See `IOS_PORT_STATUS.md`, `IOS_CONTROLS.md` and `IOS_APP_STORE_NOTES.md` for validation and remaining work.

## Desktop save compatibility check

Build a native macOS validation binary with the same sources:

```sh
cmake -S . -B build/host-validation -G Ninja -DCMAKE_BUILD_TYPE=Release \
  -DOPTION_DEDICATED=ON -DCMAKE_DISABLE_FIND_PACKAGE_PNG=TRUE \
  -DCMAKE_DISABLE_FIND_PACKAGE_CURL=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_LZO=TRUE \
  -DCMAKE_DISABLE_FIND_PACKAGE_unofficial-breakpad=TRUE \
  -DCMAKE_DISABLE_FIND_PACKAGE_Pandoc=TRUE
cmake --build build/host-validation --target openttd -j 8
./ios/validate-save.sh /absolute/path/to/ios-created.sav
```

This checks metadata, loads the whole game through the desktop save loader, runs 100 null-driver ticks, saves a desktop copy, and checks that copy. It does not alter the input save. Evidence is written beneath `build/validation/save-compatibility/`.
