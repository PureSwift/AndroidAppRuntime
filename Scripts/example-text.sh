#!/usr/bin/env bash
# Text (Documentation/Plan.md §6.16): AppRuntime's ExampleText, a small
# editor over a text the host holds. Builds its universal bundle with
# guest.py, with a welcome.txt resource in CRLF, packages it with
# android-app, and runs Scripts/example-text-check.py, which drives it on
# the emulator: the text opens in an EditText, takes the keyboard and gives
# it back with @FocusState, is typed into, undone and redone, found in and
# replaced in, and saved in CRLF again, and a note is kept through a
# binding.
#
#   Scripts/example-text.sh [--abi arm64-v8a|x86_64] [--engine native|wasm2c] [--skip-bundle]
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

work="$root/.build/example-text"
bundle="$work/org.pureswift.ExampleText.app"

# 1. The app's universal bundle: its slice, App.wasm, and the text it opens.
if [ "$skip_bundle" = 0 ]; then
    resources="$work/resources"
    rm -rf "$resources"
    mkdir -p "$resources"
    printf 'Hello, editor.\r\nThe second line.\r\n' > "$resources/welcome.txt"
    python3 "$appruntime/Scripts/guest.py" bundle --package "$appruntime" --product ExampleText \
        --target "android-$abi" --id org.pureswift.ExampleText --name ExampleText \
        --version 1.0 --build 1 --resources "$resources" --output "$work"
fi

# 2. Package, install and start it, from a fresh install.
use_device
"$adb" uninstall org.pureswift.ExampleText > /dev/null 2>&1 || true
"$adb" logcat -c
swift run android-app run "$bundle" --abi "$abi" --engine "$engine" --replace

# 3. Drive it.
python3 "$root/Scripts/example-text-check.py" --adb "$adb"
