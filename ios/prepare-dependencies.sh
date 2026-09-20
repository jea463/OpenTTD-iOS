#!/bin/sh
# Build the pinned upstream liblzma for an iOS SDK; never link host libraries.
set -eu
ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
SDK=${1:-iphonesimulator}
case "$SDK" in iphonesimulator|iphoneos) ;; *) printf 'Usage: %s [iphonesimulator|iphoneos]\n' "$0" >&2; exit 2 ;; esac
VERSION=5.8.4
SHA256=0014c7886930454fe8bd4228665b51af55eeae560ea135c9c4cd33f55b2591d9
URL="https://github.com/tukaani-project/xz/releases/download/v$VERSION/xz-$VERSION.tar.gz"
CACHE="$ROOT/build/cache"
ARCHIVE="$CACHE/xz-$VERSION.tar.gz"
PREFIX="$ROOT/build/ios-deps/$SDK"
BUILD="$ROOT/build/ios-deps-build/$SDK/xz-$VERSION"
mkdir -p "$CACHE" "$PREFIX"
if [ ! -f "$ARCHIVE" ]; then
    curl --fail --location --retry 2 --connect-timeout 20 --max-time 180 "$URL" -o "$ARCHIVE.partial"
    mv "$ARCHIVE.partial" "$ARCHIVE"
fi
ACTUAL=$(shasum -a 256 "$ARCHIVE" | awk '{print $1}')
if [ "$ACTUAL" != "$SHA256" ]; then
    printf 'XZ checksum mismatch: %s\n' "$ARCHIVE" >&2
    exit 1
fi
# Extract the verified release each time so the configured source matches the pin.
tar -xzf "$ARCHIVE" -C "$CACHE"
SOURCE="$CACHE/xz-$VERSION"
SDK_PATH=$(xcrun --sdk "$SDK" --show-sdk-path)
COMPILER=$(xcrun --sdk "$SDK" --find clang)
cmake -S "$SOURCE" -B "$BUILD" -G 'Unix Makefiles' \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_SYSROOT="$SDK_PATH" \
    -DCMAKE_C_COMPILER="$COMPILER" -DCMAKE_OSX_ARCHITECTURES=arm64 \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=16.0 -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PREFIX" -DBUILD_SHARED_LIBS=OFF \
    -DBUILD_TESTING=OFF -DXZ_TOOL_XZ=OFF -DXZ_TOOL_XZDEC=OFF \
    -DXZ_TOOL_LZMADEC=OFF -DXZ_TOOL_LZMAINFO=OFF -DXZ_TOOL_SCRIPTS=OFF \
    -DXZ_DOC=OFF -DXZ_DOXYGEN=OFF -DXZ_NLS=OFF
cmake --build "$BUILD" --parallel 4
cmake --install "$BUILD"
mkdir -p "$PREFIX/share/licenses/xz"
cp "$SOURCE/COPYING" "$SOURCE/COPYING.0BSD" "$PREFIX/share/licenses/xz/"
cat > "$PREFIX/share/licenses/xz/PROVENANCE.txt" <<EOF
XZ Utils $VERSION; static liblzma only (BSD Zero Clause License / 0BSD)
Source: $URL
SHA256: $SHA256
Publisher digest: https://api.github.com/repos/tukaani-project/xz/releases/tags/v$VERSION
Release: https://github.com/tukaani-project/xz/releases/tag/v$VERSION
SDK: $SDK ($SDK_PATH)
Architecture: arm64
Minimum iOS deployment: 16.0
Build recipe: ios/prepare-dependencies.sh in the OpenTTD iOS source tree
EOF
test -s "$PREFIX/lib/liblzma.a"
test -s "$PREFIX/include/lzma.h"
printf 'Prepared static liblzma %s at %s\n' "$VERSION" "$PREFIX"
