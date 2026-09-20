#!/bin/bash
# Generate a separate native Xcode project for exactly one iOS platform.
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${1:-iphoneos}"
case "$sdk" in iphoneos|iphonesimulator) ;; *) echo "Usage: $0 [iphoneos|iphonesimulator]" >&2; exit 2 ;; esac
./ios/prepare-assets.sh
[[ -f "build/ios-deps/$sdk/lib/liblzma.a" && -f "build/ios-deps/$sdk/include/lzma.h" ]] || ./ios/prepare-dependencies.sh "$sdk"
cmake -S . -B build/host-tools -G Ninja -DOPTION_TOOLS_ONLY=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build/host-tools --target tools -j 8
deps="$PWD/build/ios-deps/$sdk"
build_dir="build/ios-xcode-$sdk"
cmake -S . -B "$build_dir" -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
  -DCMAKE_XCODE_GENERATE_SCHEME=ON \
  -DIOS_BUNDLE_IDENTIFIER="${IOS_BUNDLE_IDENTIFIER:-org.openttd.ios.dev}" \
  -DHOST_BINARY_DIR="$PWD/build/host-tools" \
  -DLIBLZMA_INCLUDE_DIR="$deps/include" -DLIBLZMA_LIBRARY="$deps/lib/liblzma.a" \
  -DPERSONAL_DIR=Documents/OpenTTD -DSHARED_DIR='(not set)' -DGLOBAL_DIR='(not set)' \
  -DCMAKE_DISABLE_FIND_PACKAGE_LZO=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_PNG=TRUE \
  -DCMAKE_DISABLE_FIND_PACKAGE_CURL=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_Allegro=TRUE \
  -DCMAKE_DISABLE_FIND_PACKAGE_OpusFile=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_unofficial-breakpad=TRUE \
  -DCMAKE_DISABLE_FIND_PACKAGE_Grfcodec=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_Pandoc=TRUE
printf '\nGenerated %s/OpenTTD.xcodeproj\nSelect the openttd scheme; use only %s destinations in this project.\n' "$PWD/$build_dir" "$sdk"
