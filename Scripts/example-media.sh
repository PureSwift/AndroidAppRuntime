#!/usr/bin/env bash
# Media players (Documentation/Plan.md §6.10): AppRuntime's ExampleMedia, a
# small music player. Makes its songs (short tones, encoded with LAME:
# brew install lame) and cover into the bundle's resources, builds its
# universal bundle with guest.py and Scripts/ExampleMedia/App.swift,
# packages it with android-app, and runs Scripts/example-media-check.py,
# which drives it on the emulator: songs play, pause, skip and follow one
# another, the app pauses them when it leaves the front, and its video
# player is a PlayerView.
#
#   Scripts/example-media.sh [--abi arm64-v8a|x86_64] [--engine native|wasm2c] [--skip-bundle]
#
# --engine wasm2c runs it from its App.wasm (WABT's wasm2c must be
# installed: brew install wabt).
#
# Environment: as Scripts/example-ui.sh.
set -euo pipefail

abi=arm64-v8a
engine=native
skip_bundle=0
while [ $# -gt 0 ]; do
    case "$1" in
        --abi) abi="$2"; shift 2 ;;
        --engine) engine="$2"; shift 2 ;;
        --skip-bundle) skip_bundle=1; shift ;;
        -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$abi" in
    arm64-v8a) arch=aarch64 ;;
    x86_64) arch=x86_64 ;;
    *) echo "unsupported ABI: $abi (arm64-v8a or x86_64)" >&2; exit 2 ;;
esac
source "$(dirname "$0")/android-common.sh"

work="$root/.build/example-media"
bundle="$work/org.pureswift.ExampleMedia.app"

# 1. The songs and the cover, then the app's universal bundle: its slice
#    and App.wasm.
if [ "$skip_bundle" = 0 ]; then
    resources="$work/resources"
    mkdir -p "$resources/music"
    python3 "$root/Scripts/example-media-check.py" --make-resources "$resources"
    for song in morning noon night; do
        lame --quiet -b 64 "$resources/music/$song.wav" "$resources/music/$song.mp3"
        rm "$resources/music/$song.wav"
    done
    python3 "$appruntime/Scripts/guest.py" bundle --package "$appruntime" \
        --manifest "$root/Scripts/ExampleMedia/App.swift" --resources "$resources" \
        --target "android-$abi" --output "$work"
fi

# 2. Package, install and start it, from a fresh install.
use_device
"$adb" uninstall org.pureswift.ExampleMedia > /dev/null 2>&1 || true
"$adb" logcat -c
swift run android-app run "$bundle" --abi "$abi" --engine "$engine" --replace

# 3. Drive it.
python3 "$root/Scripts/example-media-check.py" --adb "$adb"
