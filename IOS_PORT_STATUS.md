# OpenTTD iOS port campaign

## Baseline

- Official stable: **15.3**, released 2026-04-04; checked 2026-09-19 at https://www.openttd.org/downloads/openttd-releases/latest and https://www.openttd.org/news/2026/04/04/openttd-15-3 . 16.0-beta3 is testing, not stable.
- Tag `15.3`, commit `14ec60f248547d4d062a1160f0fc26d742319888`; branch `ios-port` starts here.
- `origin` and `upstream`: https://github.com/OpenTTD/OpenTTD.git . Shallow stable checkout; deepen from upstream when history is needed. No public push.
- Preserve upstream GPL-2.0 license, source notices and bundled dependency/data licenses. No proprietary TTD assets.
- No AGENTS.md found in source or checked parent directories.
- Host: Xcode 27.0 (27A266a), iOS/iOS Simulator SDK 27.0, CMake 3.25.2, Ninja 1.13.2. Existing Homebrew libraries are macOS builds and must not leak into iOS linking.

## Architecture decision

UIKit owns process main, scene lifecycle and Metal presentation. A dedicated engine worker calls upstream `openttd_main` and remains in a blocking iOS `VideoDriver::MainLoop`. Set `is_game_threaded=false`: upstream `Tick()` then performs simulation, queued commands, input and drawing on that worker. Keep shared `GameLoop`, initialization and shutdown intact. UIKit events cross a synchronized queue; presentation gets a copied BGRA framebuffer, never live engine state. MainLoop must not return during normal operation because `openttd_main` immediately runs `PostMainLoop` and shuts down.

`VideoDriver::QueueOnMainThread` is an engine-driver queue drained by `Tick`, not a guarantee of the UIKit main thread. Native UI calls must be explicitly dispatched to UIKit main. Suspend ticking while inactive; reset timing appropriately on resume. Upstream world generation may create its own coordinated worker, so retain its locks and progress behavior.

## Observed source map

| Concern | Upstream boundaries |
| --- | --- |
| Target/platform/dependencies | `CMakeLists.txt`, `cmake/Options.cmake`, `cmake/CompileFlags.cmake`; APPLE currently assumes Cocoa desktop. Introduce explicit iOS condition instead of treating iOS as macOS. |
| Native generators | `src/strgen/CMakeLists.txt`, `src/settingsgen/CMakeLists.txt`, `src/lang/CMakeLists.txt`; native tools-only build exports targets, cross build imports via HOST_BINARY_DIR. |
| Engine startup/ticks | `src/openttd.cpp`: openttd_main, PostMainLoop, GameLoop, StateGameLoop. |
| Driver scheduling | `src/video/video_driver.hpp`, `src/video/video_driver.cpp`: protected Tick/StartGameThread/StopGameThread; single-thread mode supported. |
| Existing desktop implementation | `src/video/cocoa/cocoa_v.mm`, `src/video/cocoa/CMakeLists.txt`; do not compile AppKit for iOS. |
| Software rendering | `src/gfx.cpp`, `src/gfx_type.h`, `src/blitter/32bpp_anim.cpp`, `src/blitter/32bpp_base.hpp`; `_screen` framebuffer and upstream blitter stay authoritative. |
| OS hooks | `src/os/CMakeLists.txt`, `src/os/macosx/CMakeLists.txt`, `src/os/unix/CMakeLists.txt`, `src/os/unix/unix.cpp`; exclude osx_main/unix_main and desktop macOS hooks. Audit __APPLE__ assumptions. |
| Font support | `src/fontcache.cpp`, `src/fontcache/`, `src/os/macosx/font_osx.cpp`; baseline sprite fonts can avoid desktop CoreText/AppKit coupling. |
| Paths/base data | `src/fileio.cpp`, `src/fios.cpp`, `src/gfxinit.cpp`, `media/baseset/`; immutable bundle assets plus writable sandbox paths. |
| Network | `src/network/`, `src/network/core/`; preserve core, audit Unix discovery and optional HTTP dependencies. |
| Scripts | `src/script/`, `src/ai/`, `src/game/`, `src/3rdparty/squirrel/`; keep real script engine. |
| Saves | `src/saveload/`, `src/fileio.cpp`, `src/fios.cpp`; preserve native format, use writable Documents paths and validate reload. |

## Master campaign and acceptance

1. Native build: tools-only host generators; arm64 iOS Simulator bundle with SDK dependencies isolated; actual engine links. Also compile device target when simulator baseline works.
2. Initialization/data: bundle generated languages and upstream baseset metadata, licensed OpenGFX 8 assets; log successful discovery and initialization.
3. Real frame/menu: native BGRA software framebuffer presented through Metal; screenshot real upstream menu/intro world.
4. World ticks: create a real world and show simulation time advances without blocking UIKit.
5. Interaction: touch mouse mapping, pan/zoom, text entry, safe areas and resizing; verify actual engine menus and tools.
6. Persistence: save into sandbox, reload and compare game state; background/foreground lifecycle and autosave.
7. Mobile gameplay: validate building, vehicles, economy and usable iPad/iPhone layout; audio and remaining optional dependencies; packaging and license completeness.

## Validation and failed approaches

Baseline source checkout and SDK discovery complete. The native implementation and validation below supersede the initial planning stage. Initial full-history clone was too slow and was interrupted; exact-tag shallow clone completed. Concurrent work must wait for checkout completion before adding files (aborted clone cleanup can remove newly created untracked files).

## Native engine milestone (2026-09-19)

- Implemented explicit `WITH_IOS`/CMake iOS branch, native UIKit entry point, worker-owned iOS video driver and Metal framebuffer bridge. The engine uses upstream `32bpp-anim`, `VideoDriver::Tick`, world generation, scripting, networking core and save/load implementation.
- Host tools build and arm64 iOS Simulator build/link succeeded. SDK zlib and separately cross-compiled static liblzma 5.8.4 are used; optional PNG, HTTP/libcurl and external font libraries remain unavailable. Sprite fonts work. The initial milestone used null audio; pinned OpenSFX and native RemoteIO sound are now integrated and runtime output is evidenced below. Upstream compressed title world loads through liblzma.
- Installed and launched `org.openttd.ios.dev` on iPad Pro 11-inch (M5) Simulator, UDID `0123DB2A-57EA-41EB-968F-991C50D043F2`. PID 76075 logged UIKit/Metal initialization and first real framebuffer at 2026-09-19 21:37:39 local. Parent visually verified upstream title world and menu. Initial bundle missed UIDeviceFamily and launched in iPhone compatibility mode; the universal-device correction was subsequently rebuilt and verified.
- Source adapters: `src/os/ios/ios_engine.cpp`, `src/video/ios/ios_v.cpp`; shell: `src/os/ios/ios_application.mm`; shared contract `src/os/ios/ios_bridge.h`; build integration `cmake/IOS.cmake`, `ios/build.sh`.
- Build: `./ios/build.sh` for Simulator, `./ios/build.sh iphoneos` for unsigned device build. Missing pinned assets/dependencies are prepared automatically via the reproducible scripts in `ios/`. No signing identity or distribution is configured.
- Command-line test target is excluded from the default iOS build and simulator-side test discovery is disabled. Desktop target behavior is retained.
- Native iOS crash reports remain authoritative; no desktop signal handler is installed. External URL opening and clipboard are initially unavailable. Locale defaults to English; language files are bundled but full complex-script/TrueType support requires later work.

### Resolved implementation failures

1. Initial iOS CMake linked the plain and keyword `target_link_libraries` forms together; corrected to upstream's plain form.
2. Subdirectory source property did not apply ARC to root-owned executable; applied `-fobjc-arc` to the executable's Objective-C++ sources instead.
3. New adapter missed `<thread>` and dedicated-fork rejection missed `error_func.h`; compiler identified both and includes were added.
4. Native shell referenced CGPointZero/CGRectZero: explicitly linked CoreGraphics.

The validation matrix below records completed follow-up acceptance. Remaining work includes complete transport/economy gameplay coverage, physical-device input/audio/performance testing, international input, loupe observation and broad regression coverage.

### Follow-up verified

- Universal UIDeviceFamily (1,2) added and simulator app rebuilt/reinstalled. PID 78267 initialized at 21:39:09; first real frame at 21:39:10. Native iPadOS 27 window controls and resize handle visible. Later interaction evidence records a 1210 x 782 framebuffer and successful real-world construction.
- Screenshot: `build/validation/ios-menu-ipad.png`; console capture: `build/validation/ios-runtime-menu.log`. Both are local ignored evidence artifacts.
- Unsigned arm64 device app also compiled and linked successfully. `vtool -show-build build/ios-iphoneos/openttd.app/openttd` reports platform IOS, minOS16.0, SDK27.0. No physical-device run or signing is claimed.
- Linked dylib audit found only Apple frameworks/system libraries and SDK zlib; liblzma is static and compiled separately for each platform. No Homebrew runtime libraries leak into the app.

## Save compatibility validation (2026-09-19)

Parent created a real world on iPad Simulator, observed the date advance, and saved through the game's native Save UI as `Unnamed, 1950-04-06.sav`. A copy is `build/validation/ios-world-1950-04-06.sav` (93,208 bytes; SHA-256 `a3a74f1de873744b9b5eb121e44c85c7cc37cce47b4e14732a61179fa8bb28b4`).

Built a native macOS executable from the same stable-based sources in `build/host-validation` with `OPTION_DEDICATED=ON`, host zlib/liblzma, and no HTTP/PNG dependencies. This is a desktop executable, not the iOS executable under emulation. The validation sequence passed:

1. `-q` opened the exact iOS-created save and reported savegame version **362**, no NewGRFs.
2. The desktop engine loaded the entire game using `-g`, ran **100 null-driver ticks**, and wrote its own exit save. Debug logs show the title save version348 followed by the requested world version362, with no load failure.
3. `-q` reopened the desktop-written exit save, again reporting version362. Desktop output is 92,676 bytes, SHA-256 `072552e4d5f276d010849cdbf680a296c30deed4f15cf51706a571ebd4a0f039`.

Evidence directory: `build/validation/save-compatibility/run.r4pSVc/` contains metadata logs, full chunk load/save log, hashes and `save/autosave/exit.sav`. `ios/validate-save.sh` repeats this test with a fresh output directory on each run. `git diff 15.3 -- src/saveload` is empty: no save-format changes were made. Parent also loaded the desktop-resaved file back on iOS and observed the date advance to April 8; `build/validation/ios-desktop-save-reloaded.png` records that return leg.

On 2026-09-19, Xcode automatic signing with an Apple Personal Team produced a
valid arm64 device build using a unique development bundle identifier and
installed it on a connected iPhone running iOS 27.0. The first automated launch
was correctly denied until the user explicitly trusted the developer profile on
the phone. No private key, account, team identifier, provisioning profile,
personal bundle identifier, or device identifier is stored in the repository.
This establishes physical installation and provisioning, not full physical
device gameplay, audio, or performance acceptance.

## Native atomic resume implementation

- New `src/os/ios/ios_persistence.{h,cpp}` keeps native `.sav` files in Documents/save. On an engine-owner background request it saves config, then (only a normal stable game with no modal generation or open save/load dialog) performs a synchronous standard save to `resume-pending.sav`, verifies it with upstream SLO_CHECK, fsyncs, preserves the current verified file as `resume-previous.sav`, and atomically renames pending to `resume.sav`. Failures preserve prior recoverable files. Manual saves remain separate.
- Startup verifies current then previous and adds `-g` only for a usable candidate. Search paths must be initialized before SLO_CHECK even for absolute paths; an integration harness found this and it was fixed before installation. A persistent cumulative load-attempt marker suppresses repeated attempts that never reached a successful normal tick; both failed candidates lead to the menu. A confirmed normal tick or newly saved snapshot clears the marker.
- Config is written on background even from the menu, preserving survey preferences. Game saves defer during save/load dialogs because upstream preview checking uses global data also owned by that dialog.
- The combined Simulator app compiled/linked/signed with native-shell lifecycle integration. Parent subsequently tested Home/background save, termination and relaunch, and malformed-primary fallback on the actual iPad Simulator; runtime evidence is recorded below.
- Independent integration tests linked this exact persistence module against the real native macOS engine: first save, second-save backup, malformed current fallback to previous, interruption-marker fallback to menu, full previous-world load, marker clearance, and preserving the good backup while replacing a corrupt current all passed. Test files are isolated under `build/validation/persistence-fixture-v2`; harness and detailed `persistence-*.log` evidence are in `build/validation`.
- Parent additionally verified desktop-resaved output loading back into the iOS world and advancing to April8 (evidence `build/validation/ios-desktop-save-reloaded.png`), completing a demonstrated iOS → desktop → iOS roundtrip.

## Evidence-based validation matrix

This is a development milestone, not full MVP completion. Simulator checks are not physical-device checks. Evidence files below are local ignored artifacts under `build/validation` unless stated otherwise.

| Check | Result and evidence |
| --- | --- |
| iPad title/menu and larger native window | Observed real engine framebuffer; `ios-menu-ipad.png`, `ios-touch-runtime.log` (1210 x 782). |
| New world, simulation and rail construction | Parent observed new game, advancing date and placed railway; `ios-new-game-ipad.png`, `ios-touch-rail-built.png`. This does not establish full vehicle routing/economy acceptance. |
| Train construction and orders | Parent built stations and depot, purchased a locomotive and carriage and assigned two orders on iPad Simulator. `ios-train-orders.sav` is 99,592 bytes; desktop engine loaded it, ran 100 ticks and resaved successfully (`save-compatibility/run.qqC7kE`, version362). A profitable working service/end-to-end economy loop is not claimed. |
| Manual native save | Created through game UI; exact save and hash above. |
| Desktop compatibility and return to iOS | Desktop loaded version362, ran 100 ticks and resaved; parent reloaded desktop result on iOS. Logs under `save-compatibility/run.r4pSVc`, screenshot `ios-desktop-save-reloaded.png`. |
| Home/background snapshot and termination/relaunch | Parent performed lifecycle sequence. `ios-resume-runtime.log` records current snapshot selection and normal-game confirmation; `ios-background-resume.png` records restored world. |
| Malformed current snapshot fallback | Actual Simulator `ios-corrupt-recovery.log` records primary rejection, selection of `resume-previous.sav`, normal-game confirmation, and subsequent verified save. |
| Persistence failure cases | Separate real-engine host harness passed backup rotation, interruption marker and malformed-current cases; `persistence-*.log`. Not a substitute for device power-loss testing. |
| iPhone | Parent verified iPhone17e Simulator landscape menu, loaded `Phone railway.sav`, advancing ticks and one-finger pan. Viewport resizing was corrected. Software keyboard `p`, delete and Return/hide were exercised; Show Keyboard reopened it. No physical-phone claim. |
| Hardware input through Simulator | Parent verified hardware-text rename suffix `-QA` and F1 pause on iPad Simulator. Physical accessory testing remains open. |
| Native device build | Final combined source `28da769` built unsigned arm64 with Ninja; IOS/minOS16/SDK27 verified. Log `build/cache/ios-final-device-build.log`. No physical-device launch or signing claim. |
| Xcode generator | Final combined source `28da769` simulator Debug Xcode build succeeded, including ARC/audio/guarded iOS26 APIs; IOSSIMULATOR/minOS16/SDK27 verified. Log `build/cache/xcode-final-build.log`. No install/launch in this build check. |
| Assets and bundle identity | Both final bundles contain OpenGFX8.0, OpenSFX1.0.3, title data, English and license notices. Identifier `org.openttd.ios.dev`, marketing version `0.1.0`, build `1`. Pinned hashes verified; engine development version text may include a git suffix. These are development bundles, not release metadata. |
| Sound output | `ios-sound-input-runtime.log` records native output-only RemoteIO at 48 kHz stereo and 344,064 consumed frames with nonzero engine sound. Physical-device audibility/routes/interruption stress testing remains open. |
| Files integration | Parent observed the app Documents and save folder in native Files UI. External sharing, iCloud and document-provider roundtrips are untested; no in-game picker or cloud sync is claimed. |
| Precision loupe | Implemented and built; fast automated drag did not yield an observable loupe frame. Physical hold/drag verification pending. |
| iPad top control strip | Parent validation in progress; no additional acceptance asserted here. |
| IME, multiplayer and complete gameplay | Not accepted by this matrix. |

Known limits: sprite fonts and basic committed text, no proven IME composition; GPU presentation currently waits on completion on the UIKit thread; rendering/performance has not been profiled on physical hardware. Background time is finite and saves may be skipped while a modal generation/save-load operation is active. Store licensing, source delivery and review compliance remain unresolved. See `docs/ios/UPSTREAM_CHANGES.md` for the bounded source audit.

Final build audit: `git diff --check` passed. Diff to 15.3 remains empty for `src/saveload`, `src/pathfinder`, `src/economy.cpp`, `src/openttd.cpp`, `src/train_cmd.cpp` and `src/rail_cmd.cpp`. Final device dependencies are Apple frameworks/system libraries plus SDK zlib; liblzma is static, with no Homebrew runtime linkage. Compiling guarded iOS 26 APIs with a minimum iOS 16 target does not replace runtime testing on older OS versions.


## Final checkpoint observations

- At source `28da769`, the iPad 44-point top strip passed the rapid toolbar/menu tap sequence that previously triggered system window resizing. Fullscreen and narrow-window world rendering survived the test.
- Phone Simulator software keyboard typing, deletion, Return dismissal and native Show keyboard reopening were observed. The resized viewport fills the available width above the keyboard. Phone autorail drag constructed additional track; the recording `build/validation/ios-phone-precision.mov` documents the action, but automated input was too brief to establish the held-touch loupe visually.
- iPad software keyboard reopening remains unconfirmed in this Simulator session (the host keyboard delivered text correctly); validate on a touch-only physical iPad. Complex IME composition remains incomplete.
- Full touch MVP is **not** declared: station/depot/train purchase/two orders are demonstrated, but a connected profitable route, signal/bridge/tunnel workflows, comfortable phone targets, multitouch cancellation and sustained precision gestures still require work and testing. No physical peripheral, Bluetooth route, battery, thermal or App Store acceptance claim is made.
