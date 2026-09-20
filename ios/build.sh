#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
sdk="${1:-iphonesimulator}"
case "$sdk" in iphonesimulator|iphoneos) ;; *) echo "Usage: $0 [iphonesimulator|iphoneos]" >&2; exit 2 ;; esac
./ios/prepare-assets.sh
[[ -f "build/ios-deps/$sdk/lib/liblzma.a" ]] || ./ios/prepare-dependencies.sh "$sdk"
build_dir="build/ios-${sdk}"
deps="$PWD/build/ios-deps/${sdk}"
cmake -S . -B build/host-tools -G Ninja -DOPTION_TOOLS_ONLY=ON -DCMAKE_BUILD_TYPE=Release
cmake --build build/host-tools --target tools -j 8
cmake -S . -B "$build_dir" -G Ninja \
  -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$(xcrun --sdk "$sdk" --show-sdk-path)" \
  -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 \
  -DCMAKE_BUILD_TYPE=Debug -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO \
  -DHOST_BINARY_DIR="$PWD/build/host-tools" \
  -DLIBLZMA_INCLUDE_DIR="$deps/include" -DLIBLZMA_LIBRARY="$deps/lib/liblzma.a" \
  -DPERSONAL_DIR=Documents/OpenTTD -DSHARED_DIR='(not set)' -DGLOBAL_DIR='(not set)' \
  -DCMAKE_DISABLE_FIND_PACKAGE_LZO=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_PNG=TRUE \
  -DCMAKE_DISABLE_FIND_PACKAGE_CURL=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_Allegro=TRUE \
  -DCMAKE_DISABLE_FIND_PACKAGE_OpusFile=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_unofficial-breakpad=TRUE \
  -DCMAKE_DISABLE_FIND_PACKAGE_Grfcodec=TRUE -DCMAKE_DISABLE_FIND_PACKAGE_Pandoc=TRUE
cmake --build "$build_dir" --target openttd -j 8
if [[ "$sdk" == iphonesimulator ]]; then
  codesign --force --sign - "$build_dir/openttd.app"
fi
