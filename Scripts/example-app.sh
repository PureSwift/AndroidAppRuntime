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
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
abi=arm64-v8a
run=0
skip_slice=0
while [ $# -gt 0 ]; do
    case "$1" in
        --abi) abi="$2"; shift 2 ;;
        --run) run=1; shift ;;
        --skip-slice) skip_slice=1; shift ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *) echo "unknown argument: $1" >&2; exit 2 ;;
    esac
done

case "$abi" in
    arm64-v8a) arch=aarch64 ;;
    x86_64) arch=x86_64 ;;
    *) echo "unsupported ABI: $abi (arm64-v8a or x86_64)" >&2; exit 2 ;;
esac

appruntime="${APPRUNTIME_PATH:-$root/../AppRuntime}"
appruntime="$(cd "$appruntime" && pwd)"
export APPRUNTIME_PATH="$appruntime"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ndk="${ANDROID_NDK_HOME:-$(ls -d "$ANDROID_HOME"/ndk/* | sort -V | tail -1)}"
swift_sdk="${SWIFT_ANDROID_SDK:-swift-6.4.2-RELEASE_android}"
api=28
triple="$arch-unknown-linux-android$api"

# Swift 6.4 is required (.swift-version pins 6.4.2 for swiftly).
cd "$root"
swift_version="$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9]*\.[0-9]*\).*/\1/p' | head -1)"
if [ "$swift_version" != "6.4" ]; then
    echo "Swift 6.4 is required; found ${swift_version:-none}" >&2
    exit 1
fi

# 1. The app's sealed slice.
slice="$appruntime/.build/guest/ExampleApp/android-$abi/libapp.a"
if [ "$skip_slice" = 0 ]; then
    python3 "$appruntime/Scripts/guest.py" slice --package "$appruntime" --product ExampleApp --target "android-$abi"
fi
[ -f "$slice" ] || { echo "no slice at $slice" >&2; exit 1; }

# 2. The host's library, with the slice linked in.
scratch="$root/.build/android-$abi"
ANDROIDAPPRUNTIME_SLICE="$slice" swift build \
    --swift-sdk "$swift_sdk" --triple "$triple" \
    --scratch-path "$scratch" --product ExampleAppHost
library="$(find "$scratch" -name libExampleAppHost.so -path "*android-$arch*" | head -1)"
[ -n "$library" ] || library="$(find "$scratch" -name libExampleAppHost.so | head -1)"

# 3. jniLibs: the library, the Swift runtime libraries it needs, and the
#    NDK's libc++_shared.so.
readelf="$(ls "$ndk"/toolchains/llvm/prebuilt/*/bin/llvm-readelf | head -1)"
sdks="$HOME/Library/org.swift.swiftpm/swift-sdks"
[ -d "$sdks" ] || sdks="$HOME/.swiftpm/swift-sdks"
runtime_dir="$sdks/$swift_sdk.artifactbundle/swift-android/swift-resources/usr/lib/swift-$arch/android"
cxx="$(ls "$ndk"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/$arch-linux-android/libc++_shared.so | head -1)"
jnilibs="$root/.build/jniLibs/$abi"
rm -rf "$jnilibs"
mkdir -p "$jnilibs"
cp "$library" "$jnilibs/"

# The NEEDED closure, found in the SDK's runtime directory. The rest are
# system libraries (libc, libm, libdl, liblog, …).
queue=("$library")
while [ ${#queue[@]} -gt 0 ]; do
    current="${queue[0]}"
    queue=("${queue[@]:1}")
    for needed in $("$readelf" -d "$current" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
        [ -f "$jnilibs/$needed" ] && continue
        if [ -f "$runtime_dir/$needed" ]; then
            cp "$runtime_dir/$needed" "$jnilibs/"
            queue+=("$jnilibs/$needed")
        elif [ "$needed" = libc++_shared.so ]; then
            cp "$cxx" "$jnilibs/"
        fi
    done
done
# The Swift SDK's runtime is built with a newer NDK than its setup script
# requires (6.4.2's with NDK r29's clang), and needs that NDK's libc++.
nm="$(dirname "$readelf")/llvm-nm"
missing="$(comm -23 \
    <(for f in "$jnilibs"/*.so; do "$nm" -D --undefined-only "$f"; done | awk '/__ndk1/ {print $NF}' | sort -u) \
    <("$nm" -D --defined-only "$jnilibs/libc++_shared.so" | awk '{print $NF}' | sort -u))"
if [ -n "$missing" ]; then
    echo "libc++_shared.so from $ndk lacks symbols the Swift runtime needs:" >&2
    echo "$missing" | head -5 | sed 's/^/  /' >&2
    echo "Use a newer NDK (ANDROID_NDK_HOME); $swift_sdk needs NDK r29." >&2
    exit 1
fi

echo "jniLibs/$abi:"
ls -1 "$jnilibs" | sed 's/^/  /'

# 4. The APK.
# Gradle 8.14 runs on JDK 17 to 21; java_home falls back to newer ones, so
# each candidate's version is checked.
jdk_major() { "$1/bin/java" -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -1; }
if [ -z "${JAVA_HOME:-}" ]; then
    for candidate in \
        "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
        /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
        /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
        "$(/usr/libexec/java_home -v 21 2>/dev/null || true)" \
        "$(/usr/libexec/java_home -v 17 2>/dev/null || true)"; do
        major="$( [ -x "$candidate/bin/java" ] && jdk_major "$candidate" || true)"
        if [ -n "$major" ] && [ "$major" -ge 17 ] && [ "$major" -le 21 ]; then
            export JAVA_HOME="$candidate"
            break
        fi
    done
fi
[ -n "${JAVA_HOME:-}" ] || { echo "no JDK 17–21 found; set JAVA_HOME" >&2; exit 1; }
(cd "$root/Android" && ./gradlew -q :example-app:assembleDebug -PjniLibsDir="$root/.build/jniLibs")
apk="$root/Android/example-app/build/outputs/apk/debug/example-app-debug.apk"
echo "apk: $apk"

# 5. Install, start, and read the report from logcat.
if [ "$run" = 1 ]; then
    adb="$ANDROID_HOME/platform-tools/adb"
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
