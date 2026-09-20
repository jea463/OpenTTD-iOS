#!/bin/sh
# Prepare and open a native iPhone/iPad Xcode project for personal installation.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

if [ "$(uname -s)" != "Darwin" ]; then
    printf '%s\n' "This setup must run on macOS." >&2
    exit 1
fi

for tool in xcodebuild xcrun cmake ninja curl unzip tar shasum; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        printf 'Missing required tool: %s\n' "$tool" >&2
        if [ "$tool" = cmake ] || [ "$tool" = ninja ]; then
            printf '%s\n' "Install build tools with: brew install cmake ninja" >&2
        fi
        exit 1
    fi
done

if ! xcodebuild -version >/dev/null 2>&1; then
    printf '%s\n' "Select a full Xcode installation before continuing." >&2
    printf '%s\n' "Example: sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
    exit 1
fi

IDENTIFIER_FILE="$ROOT/build/ios-bundle-identifier"
if [ "$#" -gt 1 ]; then
    printf 'Usage: %s [bundle-identifier]\n' "$0" >&2
    exit 2
elif [ "$#" -eq 1 ]; then
    BUNDLE_IDENTIFIER=$1
elif [ -n "${IOS_BUNDLE_IDENTIFIER:-}" ]; then
    BUNDLE_IDENTIFIER=$IOS_BUNDLE_IDENTIFIER
elif [ -s "$IDENTIFIER_FILE" ]; then
    BUNDLE_IDENTIFIER=$(cat "$IDENTIFIER_FILE")
else
    mkdir -p "$ROOT/build"
    SUFFIX=$(uuidgen | tr '[:upper:]' '[:lower:]' | tr -d '-' | cut -c1-12)
    BUNDLE_IDENTIFIER="org.openttd.ios.dev.dev$SUFFIX"
    printf '%s\n' "$BUNDLE_IDENTIFIER" > "$IDENTIFIER_FILE"
fi

case "$BUNDLE_IDENTIFIER" in
    *[!A-Za-z0-9.-]*|.*|*.)
        printf 'Invalid bundle identifier: %s\n' "$BUNDLE_IDENTIFIER" >&2
        exit 2
        ;;
esac

printf 'Preparing OpenTTD with bundle identifier %s\n' "$BUNDLE_IDENTIFIER"
IOS_BUNDLE_IDENTIFIER="$BUNDLE_IDENTIFIER" ./ios/configure-xcode.sh iphoneos

set -- "$ROOT/build/ios-xcode-iphoneos/"*.xcodeproj
PROJECT=$1
test -d "$PROJECT"
printf '\nOpening %s\n' "$PROJECT"
printf '%s\n' "In Xcode, select the openttd target, choose your Team under Signing & Capabilities, select your device, and press Run."
open "$PROJECT"
