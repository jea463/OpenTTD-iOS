#!/bin/bash
# Validate an iOS-created save using the native macOS build of the same engine.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [[ $# -ne 1 || ! -f "$1" ]]; then
    echo "Usage: $0 /absolute/path/to/ios-created.sav" >&2
    exit 2
fi
save="$(cd "$(dirname "$1")" && pwd)/$(basename "$1")"
host="$root/build/host-validation"
evidence="$root/build/validation/save-compatibility"
mkdir -p "$evidence"
output="$(mktemp -d "$evidence/run.XXXXXX")"
[[ -x "$host/openttd" ]] || { echo "Build the macOS validation executable in build/host-validation first (see ios/README.md)." >&2; exit 2; }
cp -R "$root/build/ios-assets/baseset/opengfx-8.0" "$host/baseset/"
# -c ensures all config/save output stays in this isolated validation directory.
cat > "$output/openttd.cfg" <<'CONFIG'
[gui]
autosave_on_exit = true
CONFIG
shasum -a 256 "$save" > "$output/input.sha256"
"$host/openttd" -c "$output/openttd.cfg" -q "$save" > "$output/metadata.log" 2>&1
"$host/openttd" -c "$output/openttd.cfg" -v null:ticks=100 -s null -m null -g "$save" -d sl=2 > "$output/full-load.log" 2>&1
[[ -s "$output/save/autosave/exit.sav" ]] || { echo "Full load produced no exit save; inspect $output/full-load.log" >&2; exit 1; }
"$host/openttd" -c "$output/openttd.cfg" -q "$output/save/autosave/exit.sav" > "$output/roundtrip-metadata.log" 2>&1
shasum -a 256 "$output/save/autosave/exit.sav" > "$output/roundtrip.sha256"
echo "Metadata check, full load + 100 ticks, and desktop exit-save readback passed. Evidence: $output"
