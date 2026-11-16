#!/usr/bin/env bash
# Files (Documentation/Plan.md §6.5): AppRuntime's ExampleFiles, a notebook
# kept as text files. Builds its universal bundle with guest.py, with a
# welcome.txt resource, packages it with android-app, and runs
# Scripts/example-files-check.py, which drives it on the emulator: the
# welcome text comes from the bundle, notes are saved, listed, opened,
# exported and deleted, the files are where the host puts them, notes are
# kept when the app starts again, and temporary is emptied.
#
#   Scripts/example-files.sh [--abi arm64-v8a|x86_64] [--engine native|wasm2c] [--skip-bundle]
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

work="$root/.build/example-files"
bundle="$work/org.pureswift.ExampleFiles.app"

# 1. The app's universal bundle: its slice, App.wasm, and its resources,
#    with a file and folder whose names Gradle would leave out by default.
if [ "$skip_bundle" = 0 ]; then
    resources="$work/resources"
    rm -rf "$resources"
    mkdir -p "$resources/levels/_extra"
    printf 'Welcome to the notebook, from the bundle.' > "$resources/welcome.txt"
    printf 'LEVEL ONE' > "$resources/levels/1.map"
    printf 'extra' > "$resources/levels/_extra/2.map"
    printf 'hidden' > "$resources/.hidden"
    python3 "$appruntime/Scripts/guest.py" bundle --package "$appruntime" --product ExampleFiles \
        --target "android-$abi" --id org.pureswift.ExampleFiles --name ExampleFiles \
        --version 1.0 --build 1 --resources "$resources" --output "$work"
fi

# 2. Package, install and start it, from a fresh install.
use_device
"$adb" uninstall org.pureswift.ExampleFiles > /dev/null 2>&1 || true
"$adb" logcat -c
swift run android-app run "$bundle" --abi "$abi" --engine "$engine" --replace

# 3. Drive it.
python3 "$root/Scripts/example-files-check.py" --adb "$adb" \
    --apk "$root/.build/android-app/org.pureswift.ExampleFiles/out/org.pureswift.ExampleFiles-1.0-debug.apk"
