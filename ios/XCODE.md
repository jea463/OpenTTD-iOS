# Open the native iOS port in Xcode

The project uses UIKit and Metal with the C++ OpenTTD engine. It targets arm64 and iOS 16 or later. Start from the repository root on a Mac with Xcode, its iOS SDKs, CMake and Ninja available.

## Physical iPhone or iPad

The easiest setup creates a stable, unique development bundle identifier in the
ignored `build` directory, generates the project, and opens it:

```sh
brew install cmake ninja
./ios/open-xcode.sh
```

To use a bundle identifier you control, pass it explicitly:

```sh
./ios/open-xcode.sh com.yourname.openttddev
```

The setup script prepares pinned OpenGFX/OpenSFX assets, builds a matching static
liblzma when missing, builds/reuses the native host tools, and generates a device
Xcode project separately from the Ninja build directories. You can also run the
lower-level generator directly:

```sh
IOS_BUNDLE_IDENTIFIER=com.yourname.openttddev ./ios/configure-xcode.sh iphoneos
```

1. Select the `openttd` scheme, not `ALL_BUILD` or `openttd_test`.
2. In Xcode Settings, sign into your own Apple Account. Select the `openttd` target and its Signing & Capabilities tab, then choose your team. Automatic signing is enabled by the generator. Confirm the bundle identifier matches the value printed by the setup script.
3. Connect and trust your iPhone/iPad, enable Developer Mode when prompted, and choose that physical device as the run destination.
4. Build and Run. Xcode may need to create/download development signing assets for your account.

Signing belongs to the person building the app. No account, certificate, team,
provisioning profile, or signing credential is stored in this repository or
modified by these scripts. Xcode creates or downloads the builder's development
signing assets after they choose a team.

The generated project is disposable. CMake regeneration can replace changes made directly in Xcode; keep the bundle identifier in the configure command and reselect your team if necessary. Do not edit the generated Info.plist. The identifier flows from the `IOS_BUNDLE_IDENTIFIER` CMake cache value into both the target setting and the generated plist. Rerunning the script without the environment override restores the default identifier.

## Simulator

```sh
./ios/configure-xcode.sh iphonesimulator
open build/ios-xcode-iphonesimulator/OpenTTD.xcodeproj
```

Select the `openttd` scheme and an arm64 iPhone or iPad simulator. This is a separate project linked to the simulator liblzma. **Do not switch a device project to a simulator destination, or vice versa:** their static dependency archives are compiled for different platforms despite both being arm64. Regenerate/open the appropriate project instead. Intel/x86_64 simulators are not configured by this recipe.

For a build without launching a simulator:

```sh
xcodebuild -project build/ios-xcode-iphonesimulator/OpenTTD.xcodeproj \
  -scheme openttd -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build
```

That command intentionally produces an unsigned verification build. Let Xcode perform its normal signing when using Run; do not set `CODE_SIGNING_ALLOWED=NO` permanently in the Xcode project.

## Resources and scope

Verified on the development machine: both generated projects list the `openttd`
scheme. The simulator Xcode Debug build succeeds and stages the title save,
language files, OpenGFX/OpenSFX, and dependency license notices. The arm64 device
build also signs with an Apple Personal Team and installs on a physical iPhone.
The recorded first launch remained blocked until the device explicitly trusted
that developer profile, as required by iOS.

The app's post-build step stages language files, the title save and base data, OpenGFX, compatibility data, and license notices into the bundle. The build uses the selected iOS SDK's zlib and the platform-specific prefix `build/ios-deps/<sdk>` for liblzma. Asset/source pins and remaining public-distribution questions are recorded in [IOS_APP_STORE_NOTES.md](../IOS_APP_STORE_NOTES.md).

This is a development build workflow, not an App Store submission workflow. Physical signing and device runtime validation require the user's own team and device. See Apple's [device and simulator guide](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices) and [Developer Mode guide](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device/).
