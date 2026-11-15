#!/usr/bin/env bash
# Phase 1 (Documentation/Plan.md §11): AppRuntime's ExampleUI in a hand-made
# app. Builds the app's universal bundle with AppRuntime's guest.py, links its
# Android slice into libapp.so with the host (AndroidHostApp), stages the
# Swift runtime and the bundle's Info.plist, and builds Android/example-ui.
# With --run it installs and starts the app on the connected emulator or
# device and drives it (Scripts/example-ui-check.py): it renders, and taps,
# typing, the lazy list and navigation reach the guest and back.
#
#   Scripts/example-ui.sh [--abi arm64-v8a|x86_64] [--run] [--accessibility] [--skip-bundle]
#
# --accessibility also audits each screen for TalkBack
# (Scripts/example-ui-check.py).
#
# Environment: as Scripts/example-app.sh, plus ANDROIDSWIFTUI_PATH, an
# AndroidSwiftUI checkout for composeui (../AndroidSwiftUI by default), and
# ANDROID_SERIAL, the device to run on (a running emulator by default).
set -euo pipefail

abi=arm64-v8a
run=0
skip_bundle=0
check_flags=()
while [ $# -gt 0 ]; do
    case "$1" in
        --abi) abi="$2"; shift 2 ;;
        --run) run=1; shift ;;
        --skip-bundle) skip_bundle=1; shift ;;
        --accessibility) check_flags+=(--accessibility); shift ;;
        -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done
case "$abi" in
    arm64-v8a) arch=aarch64 ;;
    x86_64) arch=x86_64 ;;
    *) echo "unsupported ABI: $abi (arm64-v8a or x86_64)" >&2; exit 2 ;;
esac
source "$(dirname "$0")/android-common.sh"

work="$root/.build/example-ui"
bundle="$work/org.pureswift.ExampleUI.app"

# 1. The app's universal bundle, with the ABI's slice.
if [ "$skip_bundle" = 0 ]; then
    python3 "$appruntime/Scripts/guest.py" bundle --package "$appruntime" --product ExampleUI \
        --target "android-$abi" --id org.pureswift.ExampleUI --name ExampleUI \
        --version 1.0 --build 1 --output "$work"
fi
slice="$bundle/lib/android-$abi/libapp.a"
[ -f "$slice" ] || { echo "no slice at $slice" >&2; exit 1; }

# 2. libapp.so: the host with the slice linked in, and what it needs.
library="$(build_host app "$slice" "$root/.build/android-$abi")"
stage_libraries "$library" "$work/jniLibs/$abi"
mkdir -p "$work/assets/rt"
cp "$bundle/Info.plist" "$work/assets/rt/Info.plist"
echo "jniLibs/$abi:"
ls -1 "$work/jniLibs/$abi" | sed 's/^/  /'

# 3. The APK.
gradle :example-ui:assembleDebug -PjniLibsDir="$work/jniLibs" -PassetsDir="$work/assets"
apk="$root/Android/example-ui/build/outputs/apk/debug/example-ui-debug.apk"
echo "apk: $apk"

# 4. Install, start and drive it.
if [ "$run" = 1 ]; then
    use_device
    "$adb" install -r "$apk" > /dev/null
    python3 "$root/Scripts/example-ui-check.py" --adb "$adb" --screens "$work/screens" ${check_flags[@]+"${check_flags[@]}"}
fi
