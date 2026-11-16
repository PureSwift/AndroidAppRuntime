#!/usr/bin/env bash
# Surfaces (Documentation/Plan.md §6.3): AppRuntime's ExampleGL, a triangle
# drawn with OpenGL ES 2.0 in a GLSurface, with SwiftUI controls around it.
# Builds its universal bundle with guest.py, packages it with android-app,
# and runs Scripts/example-gl-check.py, which reads the screen's pixels:
# the triangle draws and turns, a tap on it reverses the turn, Space pauses
# it, and it draws again after the app comes back from the background.
#
#   Scripts/example-gl.sh [--abi arm64-v8a|x86_64] [--engine native|wasm2c] [--skip-bundle]
#
# --engine wasm2c runs it from its App.wasm, translated to C, with
# AppRuntime's GL shim (WABT's wasm2c must be installed: brew install wabt).
#
# Environment: as Scripts/example-ui.sh. ANDROID_SERIAL picks the device;
# a running emulator by default.
set -euo pipefail

abi=arm64-v8a
engine=native
skip_bundle=0
while [ $# -gt 0 ]; do
    case "$1" in
        --abi) abi="$2"; shift 2 ;;
        --engine) engine="$2"; shift 2 ;;
        --skip-bundle) skip_bundle=1; shift ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$abi" in
    arm64-v8a) arch=aarch64 ;;
    x86_64) arch=x86_64 ;;
    *) echo "unsupported ABI: $abi (arm64-v8a or x86_64)" >&2; exit 2 ;;
esac
source "$(dirname "$0")/android-common.sh"

work="$root/.build/example-gl"
bundle="$work/org.pureswift.ExampleGL.app"

# 1. The app's universal bundle: its slice and App.wasm, declaring graphics.
if [ "$skip_bundle" = 0 ]; then
    python3 "$appruntime/Scripts/guest.py" bundle --package "$appruntime" --product ExampleGL \
        --target "android-$abi" --id org.pureswift.ExampleGL --name ExampleGL \
        --version 1.0 --build 1 --capability graphics --output "$work"
fi

# 2. Package, install and start it.
use_device
"$adb" logcat -c
swift run android-app run "$bundle" --abi "$abi" --engine "$engine" --replace

# 3. Look at it.
python3 "$root/Scripts/example-gl-check.py" --adb "$adb" --screens "$work/screens-$engine"
