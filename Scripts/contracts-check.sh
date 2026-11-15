#!/usr/bin/env bash
# Phase 3 (Documentation/Plan.md §11): checks the contract modules on the
# emulator. Builds Examples/ContractsCheck, a guest app that calls each
# contract and shows one ok or FAIL line per check, packages it with
# android-app, and runs Scripts/contracts-check.py, which makes the
# emulator's battery, location and so on change and waits for the app to
# report it.
#
#   Scripts/contracts-check.sh [--abi arm64-v8a|x86_64] [--engine native|wasm2c] [--skip-bundle]
#
# --engine wasm2c runs the app from its App.wasm, translated to C, instead
# of its slice (WABT's wasm2c must be installed: brew install wabt).
#
# Environment: as Scripts/example-ui.sh. ANDROID_SERIAL picks the device;
# a running emulator by default (the checks drive the emulator console).
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

work="$root/.build/contracts-check"
bundle="$work/org.pureswift.ContractsCheck.app"

# 1. The guest's universal bundle.
if [ "$skip_bundle" = 0 ]; then
    python3 "$appruntime/Scripts/guest.py" bundle --package "$root/Examples/ContractsCheck" \
        --manifest "$root/Examples/ContractsCheck/App.swift" --target "android-$abi" --output "$work"
fi

# 2. Trace the player, so the check reads every line the app shows, and
# start from a full battery on AC, so the check's change is a change.
use_device
"$adb" shell setprop log.tag.AppRuntime DEBUG
"$adb" logcat -c
"$adb" emu power ac on > /dev/null
"$adb" emu power capacity 100 > /dev/null
# A fresh install, so the location prompt shows.
"$adb" uninstall org.pureswift.ContractsCheck > /dev/null 2>&1 || true

# 3. Package, install and start it.
swift run android-app run "$bundle" --abi "$abi" --engine "$engine" --replace

# 4. Drive it.
python3 "$root/Scripts/contracts-check.py" --adb "$adb"
