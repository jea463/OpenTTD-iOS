# iOS assets and distribution notes

Research checked 2026-09-19. This is a development port, not a statement that App Store distribution is legally cleared or that Apple will approve it.

## Reproducible free graphics

Run `./ios/prepare-assets.sh` from any directory. An optional first argument changes the output root; the default is `build/ios-assets`. The script downloads data only, verifies SHA-256 before extracting, and preserves all upstream notices. It does not run downloaded scripts or code. Generated files and the download cache are under the upstream ignored `/build*` path.

- Release: OpenGFX 8.0 (2026-01-04).
- Binary: https://cdn.openttd.org/opengfx-releases/8.0/opengfx-8.0-all.zip
- Official checksum manifest: https://cdn.openttd.org/opengfx-releases/8.0/manifest.yaml
- Archive SHA-256: `43a0c1dabf39cb865394f3a6cc36d4da5c10ecfaaf55652043104806810903be`.
- Source commit: `e68bd9b7cb60305aa98c687b6836e0e0b08e2847` (upstream tag `8.0`).
- Source: https://github.com/OpenTTD/OpenGFX/tree/e68bd9b7cb60305aa98c687b6836e0e0b08e2847
- Source archive: https://github.com/OpenTTD/OpenGFX/archive/e68bd9b7cb60305aa98c687b6836e0e0b08e2847.tar.gz

The official ZIP contains `opengfx-8.0.tar`. The extracted `opengfx-8.0/license.txt` contains GPL version 2, and `readme.txt` explicitly licenses OpenGFX under GPLv2, lists credits, and attributes the GPLv2 Liberation Mono font used for monospaced characters. The release archive, rather than the BaNaNaS site's generic “Custom” label, is the inspected licensing evidence. The source repository's LICENSE and README agree. This establishes the inspected asset notices; it does not settle App Store compatibility.

Bundle the complete `build/ios-assets/baseset/opengfx-8.0` directory, including `opengfx.obg`, six `.grf` files, `license.txt`, `readme.txt`, `changelog.txt`, and generated `PROVENANCE.txt`. The application should locate this read-only baseset without a first-run download. Ship an accessible licenses/source view as part of the eventual release, and retain a corresponding-source delivery mechanism; a provenance URL alone is not a conclusion that every GPL distribution obligation is satisfied.

### Free sound effects

The same script also prepares the official latest stable OpenSFX 1.0.3 (2021-10-31) in `build/ios-assets/baseset/opensfx-1.0.3`. The existing bundle staging copies the entire baseset directory, including these sounds and notices. No original Transport Tycoon Deluxe sounds are used.

- Official release: https://www.openttd.org/downloads/opensfx-releases/latest
- Pinned binary: https://cdn.openttd.org/opensfx-releases/1.0.3/opensfx-1.0.3-all.zip
- SHA-256: `e0a218b7dd9438e701503b0f84c25a97c1c11b7c2f025323fb19d6db16ef3759`.
- Publisher manifest: https://cdn.openttd.org/opensfx-releases/1.0.3/manifest.yaml
- Corresponding source: https://cdn.openttd.org/opensfx-releases/1.0.3/opensfx-1.0.3-source.tar.xz
- Source SHA-256 from the publisher manifest: `43cacb3ca2d86e5729d19c7fcf2533e1bb9c9a32a39f515cf6cbe665ec32635c`.

The inspected binary archive contains `opensfx.cat`, `opensfx.obs`, `license.txt`, `readme.txt` with detailed sound credits, and `changelog.txt`. Its actual README licenses the sounds under Creative Commons Attribution-ShareAlike 3.0 Unported; other files are dual-licensed GPLv2-or-later / CDDL 1.1. The script preserves these files byte-for-byte and adds `PROVENANCE.txt`; sound content is unmodified. Preserve attribution and the license in distributions and review CC BY-SA restrictions, including effective technological measures, alongside the unresolved store-distribution review below. The generated bundle must expose the credits/license access in its eventual public-release UI.

OpenMSX music is not downloaded by this script. If added, verify its exact archive separately. Upstream identifies it as GPLv2: https://www.openttd.org/content-creators. Never package original Transport Tycoon Deluxe assets without separate rights.

## Native architecture and dependencies

### Static liblzma for title and save files

The bundled title save uses XZ/LZMA (`OTTX`). Build the iOS library with `./ios/prepare-dependencies.sh iphonesimulator`, or pass `iphoneos` for device arm64. The recipe uses the selected SDK from `xcrun`, a 16.0 deployment target, and CMake's iOS cross-build mode. It disables shared libraries, tests, command-line tools, scripts, translations and documentation. The resulting prefix is `build/ios-deps/<sdk>` with `lib/liblzma.a`, headers, and CMake package files. This does not use a host macOS library. The build needs a local CMake 3.20+ and Xcode command-line tools.

- Pinned stable XZ Utils: 5.8.4, released 2026-09-09; https://tukaani.org/xz/.
- Source release: https://github.com/tukaani-project/xz/releases/download/v5.8.4/xz-5.8.4.tar.gz
- SHA-256: `0014c7886930454fe8bd4228665b51af55eeae560ea135c9c4cd33f55b2591d9`.
- Publisher digest: the `xz-5.8.4.tar.gz` asset in https://api.github.com/repos/tukaani-project/xz/releases/tags/v5.8.4.
- Downloaded archive hash was checked against that official release asset digest. No OpenPGP signature verification is claimed.
- Actual release `COPYING` identifies liblzma as BSD Zero Clause License (0BSD). `COPYING` and `COPYING.0BSD` plus a build provenance manifest are copied to `share/licenses/xz` under the prefix. Include these notices with the application distribution. Other XZ utilities have different licenses but are not built by this recipe.

### Other native dependencies

Use public UIKit, Metal/MetalKit, and Foundation APIs with UIWindowScene lifecycle. iOS 16 is a reasonable initial deployment floor; the initial UIKit/MTKView design does not require iOS 17. Let UIKit own its main run loop, keep engine advancement bounded, and pause rendering/simulation when inactive. Save through the engine's normal save path before suspension. Handle drawable resizing, safe areas, keyboard appearance, and pointer/touch cancellation.

Link zlib from the selected iOS SDK, not host Homebrew libraries. The engine vendors fmt in `src/3rdparty/fmt`; preserve its notices. CMake treats ICU as optional and warns about right-to-left rendering when ICU/HarfBuzz are absent. A boot build may use existing fallbacks; do not describe this as full international text support. Either cross-build needed text libraries with notices or provide a complete public-API text solution for production. UIKeyInput alone does not support all multistage input methods; use UITextInput or a UIKit text field for composition. Do not rely on private ICU symbols from iOS system libraries.

Public references:

- https://developer.apple.com/documentation/metalkit/mtkview
- https://developer.apple.com/documentation/quartzcore/cadisplaylink
- https://developer.apple.com/documentation/uikit/transitioning-to-the-uikit-scene-based-life-cycle
- https://developer.apple.com/videos/play/wwdc2020/10094/
- https://developer.apple.com/documentation/uikit/uitextinput

## Distribution questions that remain open

OpenTTD is GPLv2 with separately licensed third-party components. Preserve notices and provide the exact corresponding source, including port changes and build scripts, through a compliant mechanism. GPLv2 sections 6 and 7 prohibit additional restrictions and address conflicting obligations. Apple's standard EULA includes usage/transfer restrictions, an open-source qualification, and support for custom EULAs. A custom EULA or public source repository alone does not prove compatibility. Before public distribution, review the current Developer Program agreement, media-service usage rules, EULA, signing/distribution conditions, and applicable copyright permissions with qualified counsel. Do not claim an upstream license exception or endorsement that has not been obtained.

- OpenTTD license: https://github.com/OpenTTD/OpenTTD/blob/master/COPYING.md
- Standard EULA: https://www.apple.com/legal/internet-services/itunes/dev/stdeula/
- Developer agreement: https://developer.apple.com/support/terms/apple-developer-program-license-agreement/
- App Review Guidelines: https://developer.apple.com/app-store/review/guidelines/

Guideline 2.5.2 restricts downloaded code that changes functionality. For an initial release profile, bundle the engine and approved content; disable native plugin loading and downloaded/imported AI or GameScript execution until their treatment has been reviewed. Review NewGRF behavior separately rather than assuming that an asset filename means it cannot change functionality. Guideline 4.7 has specific software exceptions with additional obligations, not blanket permission for every game scripting engine. These are recommended release constraints, not claims that this document implements those switches.

Keep saves and configuration in the app container; use user-directed Files import/export. Public release still needs device stability, lifecycle and input validation, complete privacy disclosures, licensed assets, source delivery, current SDK submission requirements, and reviewer instructions. TestFlight also has review requirements.

Historical references are https://github.com/zodttd/OpenTTD and https://github.com/pelya/openttd-android. They can inform mobile input design; their existence does not establish App Store legal compatibility.
