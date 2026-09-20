#!/bin/sh
# Download pinned, verified free graphics and sound. No downloaded code is run.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
OUTPUT=${1:-"$ROOT/build/ios-assets"}
CACHE="$ROOT/build/cache"
VERSION=8.0
ARCHIVE="opengfx-$VERSION-all.zip"
URL="https://cdn.openttd.org/opengfx-releases/$VERSION/$ARCHIVE"
SHA256=43a0c1dabf39cb865394f3a6cc36d4da5c10ecfaaf55652043104806810903be
SOURCE=e68bd9b7cb60305aa98c687b6836e0e0b08e2847

mkdir -p "$CACHE" "$OUTPUT/baseset"
if [ ! -f "$CACHE/$ARCHIVE" ]; then
    curl --fail --location --retry 2 --connect-timeout 20 --max-time 180 \
        "$URL" -o "$CACHE/$ARCHIVE.partial"
    mv "$CACHE/$ARCHIVE.partial" "$CACHE/$ARCHIVE"
fi
ACTUAL=$(shasum -a 256 "$CACHE/$ARCHIVE" | awk '{print $1}')
if [ "$ACTUAL" != "$SHA256" ]; then
    printf '%s\n' "OpenGFX checksum mismatch: $CACHE/$ARCHIVE" >&2
    exit 1
fi

# The official ZIP wraps one TAR. Preserve every upstream notice in the base set.
STAGING=$(mktemp -d "$CACHE/opengfx-stage.XXXXXX")
trap 'rm -rf "$STAGING"' EXIT HUP INT TERM
unzip -p "$CACHE/$ARCHIVE" "opengfx-$VERSION.tar" > "$STAGING/base.tar"
tar -xf "$STAGING/base.tar" -C "$STAGING"
for FILE in opengfx.obg ogfx1_base.grf ogfxc_arctic.grf ogfxh_tropical.grf \
    ogfxt_toyland.grf ogfxe_extra.grf ogfxi_logos.grf license.txt readme.txt; do
    test -s "$STAGING/opengfx-$VERSION/$FILE"
done
cp -R "$STAGING/opengfx-$VERSION" "$OUTPUT/baseset/"
cat > "$OUTPUT/baseset/opengfx-$VERSION/PROVENANCE.txt" <<EOF
OpenGFX $VERSION, unmodified official binary graphics release
Archive: $URL
SHA256: $SHA256
Checksum publisher: https://cdn.openttd.org/opengfx-releases/$VERSION/manifest.yaml
Source: https://github.com/OpenTTD/OpenGFX/tree/$SOURCE
Source archive: https://github.com/OpenTTD/OpenGFX/archive/$SOURCE.tar.gz
License: GNU General Public License version 2; see license.txt
Copyright, credits and font attribution: see readme.txt
This provenance file is added by the iOS packaging script.
EOF
printf 'Prepared OpenGFX %s at %s/baseset/opengfx-%s\n' "$VERSION" "$OUTPUT" "$VERSION"

SFX_VERSION=1.0.3
SFX_ARCHIVE="opensfx-$SFX_VERSION-all.zip"
SFX_URL="https://cdn.openttd.org/opensfx-releases/$SFX_VERSION/$SFX_ARCHIVE"
SFX_SHA256=e0a218b7dd9438e701503b0f84c25a97c1c11b7c2f025323fb19d6db16ef3759
if [ ! -f "$CACHE/$SFX_ARCHIVE" ]; then
    curl --fail --location --retry 2 --connect-timeout 20 --max-time 180 \
        "$SFX_URL" -o "$CACHE/$SFX_ARCHIVE.partial"
    mv "$CACHE/$SFX_ARCHIVE.partial" "$CACHE/$SFX_ARCHIVE"
fi
SFX_ACTUAL=$(shasum -a 256 "$CACHE/$SFX_ARCHIVE" | awk '{print $1}')
if [ "$SFX_ACTUAL" != "$SFX_SHA256" ]; then
    printf '%s\n' "OpenSFX checksum mismatch: $CACHE/$SFX_ARCHIVE" >&2
    exit 1
fi
unzip -p "$CACHE/$SFX_ARCHIVE" "opensfx-$SFX_VERSION.tar" > "$STAGING/sound.tar"
tar -xf "$STAGING/sound.tar" -C "$STAGING"
for FILE in opensfx.obs opensfx.cat license.txt readme.txt changelog.txt; do
    test -s "$STAGING/opensfx-$SFX_VERSION/$FILE"
done
cp -R "$STAGING/opensfx-$SFX_VERSION" "$OUTPUT/baseset/"
cat > "$OUTPUT/baseset/opensfx-$SFX_VERSION/PROVENANCE.txt" <<EOF
OpenSFX $SFX_VERSION, unmodified official binary sound release
Archive: $SFX_URL
SHA256: $SFX_SHA256
Checksum publisher: https://cdn.openttd.org/opensfx-releases/$SFX_VERSION/manifest.yaml
Source: https://cdn.openttd.org/opensfx-releases/$SFX_VERSION/opensfx-$SFX_VERSION-source.tar.xz
Source SHA256 (publisher manifest): 43cacb3ca2d86e5729d19c7fcf2533e1bb9c9a32a39f515cf6cbe665ec32635c
Project: https://github.com/OpenTTD/OpenSFX
Sounds: Creative Commons Attribution-ShareAlike 3.0 Unported
Other files: GPL version 2 or later / CDDL 1.1 dual license
Full license text and sound attribution: license.txt and readme.txt
No sound content modified. This provenance file is added by iOS packaging.
EOF
printf 'Prepared OpenSFX %s at %s/baseset/opensfx-%s\n' "$SFX_VERSION" "$OUTPUT" "$SFX_VERSION"
