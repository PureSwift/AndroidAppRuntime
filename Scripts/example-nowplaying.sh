#!/usr/bin/env bash
# Now playing, and playing in the background (Documentation/Plan.md
# §6.13): AppRuntime's ExampleMedia, with Scripts/ExampleNowPlaying/App.swift,
# which plays on in the background. Makes its songs and cover as
# Scripts/example-media.sh does (brew install lame), builds its universal
# bundle with guest.py, packages it with android-app, and runs
# Scripts/example-nowplaying-check.py, which drives it, its media session
# and its notification on the emulator: what's playing is shown, the media
# buttons play, pause, skip and change songs, and the songs go on with the
# app in the background.
#
#   Scripts/example-nowplaying.sh [--abi arm64-v8a|x86_64] [--engine native|wasm2c] [--skip-bundle]
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
        -h|--help) sed -n '2,17p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$abi" in
    arm64-v8a) arch=aarch64 ;;
    x86_64) arch=x86_64 ;;
    *) echo "unsupported ABI: $abi (arm64-v8a or x86_64)" >&2; exit 2 ;;
esac
source "$(dirname "$0")/android-common.sh"

work="$root/.build/example-nowplaying"
bundle="$work/org.pureswift.ExampleNowPlaying.app"

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
        --manifest "$root/Scripts/ExampleNowPlaying/App.swift" --resources "$resources" \
        --target "android-$abi" --output "$work"
fi

# 2. Package, install and start it, from a fresh install.
use_device
"$adb" uninstall org.pureswift.ExampleNowPlaying > /dev/null 2>&1 || true
"$adb" logcat -c
swift run android-app run "$bundle" --abi "$abi" --engine "$engine" --replace

# 3. Drive it.
python3 "$root/Scripts/example-nowplaying-check.py" --adb "$adb"
