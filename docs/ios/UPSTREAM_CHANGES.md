# Native iOS changes relative to OpenTTD 15.3

Baseline: upstream tag `15.3`, commit `14ec60f248547d4d062a1160f0fc26d742319888`. This inventory covers the port's modified upstream files at the bounded audit on 2026-09-19, with newly added native files grouped separately. Sound and pointer work was still being integrated; consult the final diff and validation status for subsequent changes.

## Modified upstream files

| File | Reason for change |
| --- | --- |
| `CMakeLists.txt` | Preserve requested iOS deployment target; define WITH_IOS; constrain cross-build dependency lookup; exclude desktop Cocoa/OpenGL assumptions; exclude the iOS test executable from default builds and host-side test discovery; select native iOS bundle packaging. Desktop branches remain available. |
| `src/dedicated.cpp` | Exclude fork-based daemonization on iOS and report an explicit unsupported-operation error instead. Adds error-function declaration. |
| `src/music/CMakeLists.txt` | Exclude Cocoa MIDI and external Unix MIDI process drivers on iOS. Null music remains available. |
| `src/os/CMakeLists.txt` | Include the new native iOS platform directory only for iOS builds. |
| `src/os/macosx/CMakeLists.txt` | Keep macOS hooks and desktop process entry point out of the UIKit executable. |
| `src/os/unix/library_loader_unix.cpp` | Use the existing unsupported dynamic-library path on iOS; external native plugins cannot load. |
| `src/os/unix/unix.cpp` | Avoid macOS headers/hooks, retain stderr-based error reporting, and set iOS thread names through the public pthread API. |
| `src/sound/CMakeLists.txt` | Exclude the macOS sound backend from iOS and include the new iOS sound directory. Native iOS sound integration is handled in the new backend rather than altering the engine mixer. |
| `src/stdafx.h` | Avoid the macOS-specific precompiled-header branch on iOS. |
| `src/video/CMakeLists.txt` | Include the native iOS video backend conditionally. |
| `src/video/cocoa/CMakeLists.txt` | Exclude desktop Cocoa and Cocoa/OpenGL video sources from iOS. |

`git diff 15.3 -- src/saveload` is empty at audit time. There are no native save-format/chunk/version modifications. The core simulation, economy, world generation, pathfinding and upstream software blitter remain upstream implementations. The iOS/desktop/iOS save roundtrip demonstrates compatibility for the tested game, not exhaustive compatibility with all historical versions, compression modes or NewGRFs.

## New native files and tooling

- `src/os/ios/`: UIKit process/scene shell, synchronized event/frame bridge, worker entry point and OS hooks, plus engine-owned resume persistence. Resume snapshots call upstream save/load code and are ordinary `.sav` files.
- `src/video/ios/`: custom VideoDriver using upstream Tick and 32bpp-anim, framebuffer storage and mobile input mapping. It translates native input into engine events; it does not implement a replacement game.
- `src/sound/ios/`: new native sound backend adapts the upstream mixer to public Apple audio APIs. Its runtime validation must be reported separately from bundled sound-data preparation.
- `cmake/IOS.cmake`: frameworks, Objective-C++ ARC (including explicit Xcode ARC setting), configurable bundle identifier and post-build bundle resource/notices staging.
- `ios/Info.plist.in`: universal iPhone/iPad configuration, scene lifecycle, indirect input, supported orientations and app identity. Files document-sharing keys expose the app Documents area, not an in-game document picker, Open In URL handling or cloud synchronization. Parent observed Documents/save in native Files UI; external sharing and iCloud/provider roundtrips remain untested.
- `ios/build.sh`, `ios/configure-xcode.sh`: separate SDK/architecture build trees, matching liblzma prefixes, host generator reuse and Xcode developer handoff. Device and Simulator projects must not be interchanged merely because both use arm64.
- `ios/prepare-assets.sh`, `ios/prepare-dependencies.sh`: versioned official OpenGFX/OpenSFX and XZ/liblzma downloads with pinned hashes and preserved notices. Generated data and build products stay in ignored build directories.
- `ios/validate-save.sh`: real desktop-engine save load/tick/resave compatibility validation.
- Root `IOS_*.md`, `ios/*.md` and `docs/ios/*.md`: requirements, source/license notes, controls, signing/Files instructions, test evidence and handoff. These do not themselves enable or enforce a release policy.

## Engineering tradeoffs and audit findings

### Engine and presentation ownership

UIKit owns its event loop; a dedicated worker owns normal engine ticks and blocking VideoDriver::MainLoop. `is_game_threaded=false` avoids adding a second ordinary game loop, but upstream coordinated world-generation work is retained. Native events cross a mutex-protected queue. The engine copies pixels under the frame mutex; UIKit never reads the live `_screen` buffer.

The Metal texture is shared CPU/GPU storage. The audited implementation waits for the submitted command buffer to complete before reusing it, so no unsynchronized CPU overwrite of an in-flight GPU read was identified. That wait occurs on the UIKit thread and is a latency/power tradeoff, not a proven scalable renderer. A future texture ring needs explicit completion ownership; simply deleting the wait would introduce a data hazard. Full-frame copies/uploads and continuous presentation need physical-device profiling.

The queue coalesces pointer motion but not every gesture event; high-rate input can produce avoidable queued work. Resizing reallocates the engine framebuffer. No stress/thermal/memory-pressure acceptance is claimed. The single-scene/global-engine design deliberately does not support independent multiwindow games.

### Persistence

Persistence checks engine-thread ownership and defers normal-game snapshots during modal generation or the save/load dialog. It saves to pending, checks the result, syncs, preserves a verified predecessor, then promotes using same-directory rename. Background expiration ends the UIKit lease; it does not promote a partial file. Finite background time can still interrupt a large save, and the latest unsaved gameplay cannot be guaranteed after forced termination.

Upstream `SLO_CHECK` is a preview/structural check, not a full execution of every load chunk. A candidate can pass this check and fail later. The persistent load-attempt marker limits repeated automatic attempts and the previous snapshot provides recovery on a later launch. There is no claim of immediate same-process fallback for every deeper load failure. Directory fsync errors are not surfaced, so absolute power-loss durability is not established. These limits are distinct from the successful malformed-primary and normal resume tests.

### Input, packaging and release gaps

The audited text-field delegate rejects all native edits and forwards replacement strings directly. This handles basic committed text but prevents proper marked-text composition; Chinese/Japanese/Korean IME support is not accepted. This actionable limitation was reported to the shell owner. Pointer/keyboard coverage and cancellation handling require evidence for the final integrated backend.

Sprite fonts omit complete complex-script/TrueType coverage. SDK-only zlib and platform-specific static liblzma avoid host-library contamination; neither optional PNG nor HTTP/libcurl is available in the initial build. Music is not implemented. Native sound and sound assets are separate concerns: the integrated Simulator logs now show RemoteIO consuming nonzero engine audio, while physical-device routes and interruptions remain untested.

No confirmed severe shared-frame or persistence ownership race was found in this bounded review. This is not a comprehensive concurrency/security audit. Physical devices, background deadlines under load, all transport/economy workflows, accessibility and performance remain acceptance work. GPL/CC BY-SA and App Store distribution compatibility remain unresolved; do not interpret local build success as release clearance.
