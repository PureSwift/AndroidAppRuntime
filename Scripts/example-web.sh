#!/usr/bin/env bash
# Web views (Documentation/Plan.md §6.4): AppRuntime's ExampleWeb, a small
# browser around a WebView. Builds its universal bundle with guest.py,
# packages it with android-app, and runs Scripts/example-web-check.py,
# which drives it on the emulator: swift.org loads and its title shows, a
# script counts its links, an address loads another page, and back and
# forward go between them.
#
#   Scripts/example-web.sh [--abi arm64-v8a|x86_64] [--engine native|wasm2c] [--no-network] [--skip-bundle]
#
# --no-network builds the app without the network capability: the page
# must fail to load, with WebError.Code.notPermitted, and nothing else
# reaches the network. --engine wasm2c runs it from its App.wasm (WABT's
# wasm2c must be installed: brew install wabt).
#
# Environment: as Scripts/example-ui.sh. The emulator needs the Internet.
set -euo pipefail

abi=arm64-v8a
engine=native
network=1
skip_bundle=0
while [ $# -gt 0 ]; do
    case "$1" in
        --abi) abi="$2"; shift 2 ;;
        --engine) engine="$2"; shift 2 ;;
        --no-network) network=0; shift ;;
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

if [ "$network" = 1 ]; then
    work="$root/.build/example-web"
    capabilities=(--capability network)
    check=()
else
    work="$root/.build/example-web-offline"
    capabilities=()
    check=(--no-network)
fi
bundle="$work/org.pureswift.ExampleWeb.app"

# 1. The app's universal bundle: its slice and App.wasm.
if [ "$skip_bundle" = 0 ]; then
    python3 "$appruntime/Scripts/guest.py" bundle --package "$appruntime" --product ExampleWeb \
        --target "android-$abi" --id org.pureswift.ExampleWeb --name ExampleWeb \
        --version 1.0 --build 1 ${capabilities[@]+"${capabilities[@]}"} --output "$work"
fi

# 2. Package, install and start it, from a fresh install.
use_device
"$adb" uninstall org.pureswift.ExampleWeb > /dev/null 2>&1 || true
"$adb" logcat -c
swift run android-app run "$bundle" --abi "$abi" --engine "$engine" --replace

# 3. Drive it.
python3 "$root/Scripts/example-web-check.py" --adb "$adb" ${check[@]+"${check[@]}"}
