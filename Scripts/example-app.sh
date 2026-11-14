#!/usr/bin/env bash
# Phase 0 (Documentation/Plan.md §11): builds AppRuntime's ExampleApp as a
# sealed Android slice, links it into libExampleAppHost.so with the host's
# Swift code, builds the APK, and with --run installs and starts it on the
# connected emulator or device and checks the report it logs.
#
#   Scripts/example-app.sh [--abi arm64-v8a|x86_64] [--run] [--skip-slice]
#
# Environment:
#   APPRUNTIME_PATH   AppRuntime checkout; ../AppRuntime by default
#   ANDROID_HOME      Android SDK; ~/Library/Android/sdk by default
#   ANDROID_NDK_HOME  NDK; the newest under $ANDROID_HOME/ndk by default
#   SWIFT_ANDROID_SDK Swift SDK id; swift-6.4.2-RELEASE_android by default
#   JAVA_HOME         JDK for Gradle (17–21); JDK 21 by default on macOS
#   ANDROID_SERIAL    the device to run on; a running emulator by default
set -euo pipefail

abi=arm64-v8a
run=0
skip_slice=0
while [ $# -gt 0 ]; do
    case "$1" in
        --abi) abi="$2"; shift 2 ;;
        --run) run=1; shift ;;
        --skip-slice) skip_slice=1; shift ;;
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

# 1. The app's sealed slice.
slice="$appruntime/.build/guest/ExampleApp/android-$abi/libapp.a"
if [ "$skip_slice" = 0 ]; then
    python3 "$appruntime/Scripts/guest.py" slice --package "$appruntime" --product ExampleApp --target "android-$abi"
fi
[ -f "$slice" ] || { echo "no slice at $slice" >&2; exit 1; }

# 2. The host's library, with the slice linked in, and what it needs.
library="$(build_host ExampleAppHost "$slice" "$root/.build/android-$abi")"
jnilibs="$root/.build/jniLibs/$abi"
stage_libraries "$library" "$jnilibs"
echo "jniLibs/$abi:"
ls -1 "$jnilibs" | sed 's/^/  /'

# 3. The APK.
gradle :example-app:assembleDebug -PjniLibsDir="$root/.build/jniLibs"
apk="$root/Android/example-app/build/outputs/apk/debug/example-app-debug.apk"
echo "apk: $apk"

# 4. Install, start, and read the report from logcat.
if [ "$run" = 1 ]; then
    use_device
    "$adb" install -r "$apk" > /dev/null
    "$adb" logcat -c
    "$adb" shell am force-stop org.pureswift.appruntime.example
    "$adb" shell am start -W -n org.pureswift.appruntime.example/.ExampleAppActivity > /dev/null
    for _ in $(seq 1 30); do
        report="$("$adb" logcat -d -v raw -s ExampleApp:I)"
        echo "$report" | grep -qE "^(PASS|FAIL):" && break
        sleep 1
    done
    echo "$report"
    if ! echo "$report" | grep -q "^PASS:"; then
        "$adb" logcat -d -b crash | tail -40 >&2
        exit 1
    fi
fi
