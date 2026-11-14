# Shared by the build scripts: sourced, not run.
#
# Sets root, appruntime, ANDROID_HOME, ndk, swift_sdk and triple, and
# defines:
#   build_host PRODUCT SLICE SCRATCH  builds a host library with a slice linked in
#   stage_libraries LIBRARY DIR        copies it and the Swift runtime it needs
#   use_jdk                            picks a JDK Gradle 8.14 runs on
#   use_device                         picks the device adb uses
#   gradle ARGS...                     runs the Gradle wrapper in Android/
#
# Needs abi and arch set first.

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
appruntime="${APPRUNTIME_PATH:-$root/../AppRuntime}"
appruntime="$(cd "$appruntime" && pwd)"
export APPRUNTIME_PATH="$appruntime"
export ANDROID_HOME="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ndk="${ANDROID_NDK_HOME:-$(ls -d "$ANDROID_HOME"/ndk/* | sort -V | tail -1)}"
swift_sdk="${SWIFT_ANDROID_SDK:-swift-6.4.2-RELEASE_android}"
api=28
triple="$arch-unknown-linux-android$api"
adb="$ANDROID_HOME/platform-tools/adb"

# Swift 6.4 is required (.swift-version pins 6.4.2 for swiftly).
cd "$root"
swift_version="$(swift --version 2>&1 | sed -n 's/.*Swift version \([0-9]*\.[0-9]*\).*/\1/p' | head -1)"
if [ "$swift_version" != "6.4" ]; then
    echo "Swift 6.4 is required; found ${swift_version:-none}" >&2
    exit 1
fi

# Builds PRODUCT for the ABI with SLICE linked in; prints the library's path.
build_host() {
    local product="$1" slice="$2" scratch="$3"
    ANDROIDAPPRUNTIME_SLICE="$slice" swift build \
        --swift-sdk "$swift_sdk" --triple "$triple" \
        --scratch-path "$scratch" --product "$product" >&2
    local library
    library="$(find "$scratch" -name "lib$product.so" -path "*android-$arch*" | head -1)"
    [ -n "$library" ] || library="$(find "$scratch" -name "lib$product.so" | head -1)"
    [ -n "$library" ] || { echo "no lib$product.so in $scratch" >&2; exit 1; }
    echo "$library"
}

# Copies LIBRARY to DIR with the closure of the Swift runtime libraries it
# needs, from the SDK, and the NDK's libc++_shared.so. The rest are system
# libraries (libc, libm, libdl, liblog, libandroid, …).
stage_libraries() {
    local library="$1" dir="$2"
    local readelf sdks runtime_dir cxx
    readelf="$(ls "$ndk"/toolchains/llvm/prebuilt/*/bin/llvm-readelf | head -1)"
    sdks="$HOME/Library/org.swift.swiftpm/swift-sdks"
    [ -d "$sdks" ] || sdks="$HOME/.swiftpm/swift-sdks"
    runtime_dir="$sdks/$swift_sdk.artifactbundle/swift-android/swift-resources/usr/lib/swift-$arch/android"
    cxx="$(ls "$ndk"/toolchains/llvm/prebuilt/*/sysroot/usr/lib/$arch-linux-android/libc++_shared.so | head -1)"
    rm -rf "$dir"
    mkdir -p "$dir"
    cp "$library" "$dir/"
    local queue=("$library") current needed
    while [ ${#queue[@]} -gt 0 ]; do
        current="${queue[0]}"
        queue=("${queue[@]:1}")
        for needed in $("$readelf" -d "$current" | sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'); do
            [ -f "$dir/$needed" ] && continue
            if [ -f "$runtime_dir/$needed" ]; then
                cp "$runtime_dir/$needed" "$dir/"
                queue+=("$dir/$needed")
            elif [ "$needed" = libc++_shared.so ]; then
                cp "$cxx" "$dir/"
            fi
        done
    done
    # The Swift SDK's runtime is built with a newer NDK than its setup script
    # requires (6.4.2's with NDK r30's clang, r574158c), and needs that NDK's
    # libc++.
    local nm missing
    nm="$(dirname "$readelf")/llvm-nm"
    missing="$(comm -23 \
        <(for f in "$dir"/*.so; do "$nm" -D --undefined-only "$f"; done | awk '/__ndk1/ {print $NF}' | sort -u) \
        <("$nm" -D --defined-only "$dir/libc++_shared.so" | awk '{print $NF}' | sort -u))"
    if [ -n "$missing" ]; then
        echo "libc++_shared.so from $ndk lacks symbols the Swift runtime needs:" >&2
        echo "$missing" | head -5 | sed 's/^/  /' >&2
        echo "Use a newer NDK (ANDROID_NDK_HOME); $swift_sdk needs NDK r30." >&2
        exit 1
    fi
}

# Gradle 8.14 runs on JDK 17 to 21; java_home falls back to newer ones, so
# each candidate's version is checked.
use_jdk() {
    [ -n "${JAVA_HOME:-}" ] && return
    local candidate major
    for candidate in \
        "/Applications/Android Studio.app/Contents/jbr/Contents/Home" \
        /opt/homebrew/opt/openjdk@21/libexec/openjdk.jdk/Contents/Home \
        /opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
        "$(/usr/libexec/java_home -v 21 2>/dev/null || true)" \
        "$(/usr/libexec/java_home -v 17 2>/dev/null || true)"; do
        [ -x "$candidate/bin/java" ] || continue
        major="$("$candidate/bin/java" -version 2>&1 | sed -n 's/.*version "\([0-9]*\).*/\1/p' | head -1)"
        if [ -n "$major" ] && [ "$major" -ge 17 ] && [ "$major" -le 21 ]; then
            export JAVA_HOME="$candidate"
            return
        fi
    done
    echo "no JDK 17–21 found; set JAVA_HOME" >&2
    exit 1
}

# The device to run on: ANDROID_SERIAL, or else a running emulator, so a
# phone that happens to be plugged in isn't used unasked.
use_device() {
    if [ -z "${ANDROID_SERIAL:-}" ]; then
        ANDROID_SERIAL="$("$adb" devices | awk '$1 ~ /^emulator-/ && $2 == "device" {print $1; exit}')"
        [ -n "$ANDROID_SERIAL" ] || { echo "no emulator running; start one or set ANDROID_SERIAL" >&2; exit 1; }
    fi
    export ANDROID_SERIAL
    echo "device: $ANDROID_SERIAL"
}

gradle() {
    use_jdk
    (cd "$root/Android" && ./gradlew -q "$@")
}
