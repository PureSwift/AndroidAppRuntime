#!/usr/bin/env bash
# Model store (Documentation/Plan.md §6.7): AppRuntime's ExampleModel,
# to-dos in lists kept with CoreModel. Builds its universal bundle with
# guest.py, packages it with android-app, and runs
# Scripts/example-model-check.py, which drives it on the emulator: to-dos
# are added, changed, filtered, counted through a relationship and deleted,
# their rows are in the app's SQLite file, and they're kept across launches.
#
#   Scripts/example-model.sh [--abi arm64-v8a|x86_64] [--engine native|wasm2c] [--skip-bundle]
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

work="$root/.build/example-model"
bundle="$work/org.pureswift.ExampleModel.app"

# 1. The app's universal bundle: its slice and App.wasm.
if [ "$skip_bundle" = 0 ]; then
    python3 "$appruntime/Scripts/guest.py" bundle --package "$appruntime" --product ExampleModel \
        --target "android-$abi" --id org.pureswift.ExampleModel --name ExampleModel \
        --version 1.0 --build 1 --output "$work"
fi

# 2. Package, install and start it, from a fresh install.
use_device
"$adb" uninstall org.pureswift.ExampleModel > /dev/null 2>&1 || true
"$adb" logcat -c
swift run android-app run "$bundle" --abi "$abi" --engine "$engine" --replace

# 3. Drive it.
python3 "$root/Scripts/example-model-check.py" --adb "$adb"
