# Android host — Plan

**Status:** phase 0 (§11) is done. `ExampleApp`'s `android-arm64-v8a` slice
runs in the emulator (API 36, arm64) from a bare Activity, and passes every
check AppRuntime's `Packages/LinkedSlice` test makes on macOS. That covers
calls both ways, every wire type, typed throws, identity, capabilities, and
async tasks resumed by the clock. What phase 0 found:

- **Swift 6.4.2 builds everything for Android.** The 6.4.2 Swift SDK for
  Android builds AppRuntime's host modules (`RuntimeCore`, `RuntimeNative`,
  `DynamicRuntime`, `DynamicUI`, the contract modules, `ExampleHost`),
  swift-java and AndroidKit for `aarch64-unknown-linux-android28`.
- **The slice fits bionic.** `ExampleApp`'s `android-arm64-v8a` slice
  imports only `abort`, `arc4random_buf`, `clock_gettime`, `free`,
  `malloc`, `memcmp`, `memmove`, `memset`, `posix_memalign` and `write`
  from libc, all in bionic at API 28. It links into `libExampleAppHost.so`
  with swift-java.
- **The arm64 slice needs heap pointer tagging off.**
  - The slice is compiled for `aarch64-unknown-linux-gnu` (AppRuntime's
    `guest.py`, for its Embedded concurrency modules). That target's
    Embedded stdlib keeps String's flags in a pointer's top byte.
  - Android 11+ tags heap pointers in that byte (`0xb4…`), so the slice
    took its own native strings for foreign ones and trapped in
    `String.UTF8View._foreignIndex(after:)`. The full runtime is built for
    Android, which leaves the top byte alone, so only the slice fails.
  - With `android:allowNativeHeapPointerTagging="false"`, every check
    passes. That flag is a workaround: the fix is a slice whose Embedded
    stdlib is built for an Android triple (§9.1). x86_64 has no tagging.
- **The 6.4.2 SDK needs NDK r30's `libc++_shared.so`.**
  - Its runtime is built with NDK r30's clang (`r574158c`; r29's is
    `r563880c`). `libswiftCore.so` uses `std::__hash_memory`, which r27's
    and r29's libc++ lack.
  - Its setup script accepts NDK r27 anyway, so the build succeeds and the
    library fails to load at run time. `Scripts/example-app.sh` checks
    every libc++ symbol the runtime needs when it stages the libraries.
  - With the SDK set up with NDK r30, `Scripts/example-app.sh --run`
    passes from a clean build.
- **The Swift runtime is dynamic for now** (decision 4).
  - Swift 6.4's build system passes `--static-swift-stdlib`, `-Xswiftc` and
    `-Xlinker` to the macOS builds of the package's macros too, and the
    macro links then fail.
  - The deprecated native build system keeps them apart, but the SDK has
    no static `_FoundationCShims` or `_FoundationCollections`, which
    swift-java's Foundation import needs.
  - The APK carries the SDK's runtime libraries instead (about 15, from
    `libswiftCore.so` to `libFoundationEssentials.so`; no ICU).
- **The SDK's toolset already links with `-z max-page-size=16384`**, so
  16 KB pages need nothing from the host.
- **Gradle 8.14 needs a JDK from 17 to 21.** `java_home -v 21` falls back
  to newer JDKs, so `Scripts/example-app.sh` checks each candidate's
  version.

This is the Android host for [AppRuntime](https://github.com/PureSwift/AppRuntime)
apps, the counterpart of DarwinAppRuntime and LinuxAppRuntime. An AppRuntime
app is guest code only: a universal bundle with `App.wasm` and native
`libapp.a` slices (`android-arm64-v8a`, `android-armeabi-v7a`,
`android-x86_64`). This repository turns that bundle into an Android app.
It covers four parts:

- the **host runtime**: the Activity shell, the main looper, the runtime
  core behind `rt.h`, the built-in contracts, and the contract
  implementations over the Android SDK;
- the **SwiftUI player**: AndroidSwiftUI's Compose interpreter (`composeui`)
  behind an adapter for AppRuntime's render IR;
- **Bluetooth**, through PureSwift/AndroidBluetooth's bindings;
- the **packager**, `android-app`, which turns a universal bundle into a
  signed APK or App Bundle.

References like §7.6 point to `Documentation/DynamicRuntime.md` in
AppRuntime. The render IR is defined in `Documentation/RenderIR.md` there.

The plan builds on four existing projects:

| Project | What this host takes from it |
|---|---|
| [swiftlang/swift-java](https://github.com/swiftlang/swift-java) | JNI from Swift: `@JavaClass` wrappers, `@JavaImplementation` for `native` methods, jextract (JNI mode) for Kotlin → Swift calls, thread attachment, the cached app class loader |
| [PureSwift/Android](https://github.com/PureSwift/Android) (AndroidKit) | Generated bindings to `android.*`: `os`, `app`, `content`, `location`, `nfc`, `net`, `hardware` and others |
| [PureSwift/AndroidBluetooth](https://github.com/PureSwift/AndroidBluetooth) | Bindings to `android.bluetooth` and `android.bluetooth.le`; Kotlin callback adapters that forward to Swift event sinks |
| [PureSwift/AndroidSwiftUI](https://github.com/PureSwift/AndroidSwiftUI) | `composeui`, a Compose Multiplatform interpreter for a render tree almost identical to AppRuntime's; the `androidbridge` shell pattern and the main-looper posting |

## 1. Decisions

1. **The host is written in Swift, not Kotlin.**
   - AppRuntime's design (§2.3, §5) sketched Kotlin contract implementations
     behind a C JNI shim.
   - This plan uses the Swift-registry backend instead, as Darwin and Linux
     do. The host links `RuntimeCore` and `RuntimeNative`, and implements
     contracts in Swift against the generated proxies.
   - It calls Android through swift-java bindings: AndroidKit and
     AndroidBluetooth.
   - **Why:**
     - The runtime core, the startup checks, the module pattern and the tests
       stay the same as on the other two hosts.
     - The bindings already exist.
     - The JNI backend (DynamicRuntime.md §6) is never needed: it would cover only apps that
       call `android.*` directly, which this plan leaves out.
   - DynamicRuntime.md's Android rows (§2.3, §5, §6.1, §9.4) are updated to
     match (§9.1).
2. **Kotlin is used only where Android requires it:**
   - the `Application` and `Activity`;
   - the Compose player;
   - small adapter classes for Android's abstract callback classes
     (`ScanCallback`, `BluetoothGattCallback`, …).

   swift-java can't implement a Java interface or subclass a Java class at
   run time; it has no `Proxy` support. So every listener needs a Kotlin or
   Java class that forwards to Swift.
3. **The player is `composeui`, reached from Kotlin.**
   - The guest's IR bytes cross JNI as one `byte[]` per update.
   - A Kotlin decoder (`RenderCodec.kt`, a port of AppRuntime's
     `RenderCodec`) builds composeui's `ViewNode`s directly.
   - **Why:**
     - One JNI call per update, not one per node.
     - No dependency on AndroidSwiftUI's Swift evaluator: its `ComposeUI`
       target depends on `SwiftUICore`.
     - The adapter can be tested on the desktop JVM with no emulator.
4. **One shared library per ABI.**
   - `libapp.so` contains the host's Swift modules, the runtime core and
     the app's sealed slice (or its wasm2c output).
   - The Swift runtime should be linked statically, so the APK carries
     `libapp.so` and `libc++_shared.so`. For now it's dynamic: the SDK's
     runtime libraries go in the APK too (Status above).
   - The host uses `FoundationEssentials` only, keeping ICU's data out of
     the APK. Formatting goes through `android.icu.text` instead (§6).
5. **Minimum API 28 (Android 9).**
   - The Swift SDK for Android's triples are `…-linux-android28`, and
     AndroidKit's and AndroidBluetooth's CI start at 28.
   - The default `targetSdk` is 35.
   - AppRuntime's manifest examples say `minSDK: 26`. The packager raises
     a lower `minSDK` to 28 with a warning, and the examples change (§9.1).
6. **Toolchain: Swift 6.4 is required.**
   - The package's tools version is 6.4, and `.swift-version` pins 6.4.2,
     AppRuntime's.
   - It uses the matching Swift SDK for Android,
     `swift-6.4.2-RELEASE_android`, set up with NDK r30 (Status above).
   - Gradle needs a JDK from 17 to 21.
   - The upstream projects build with 6.3.x today; all of them build with
     6.4.2 too.

## 2. Scope

| In | Later |
|---|---|
| arm64-v8a (devices, Apple-silicon emulators) and x86_64 (Intel emulators, Chromebooks) | armeabi-v7a: the slice exists, but its sealed helpers haven't run on hardware |
| Native slices linked into `libapp.so` | wasm2c (AppRuntime's shim, as on Darwin and Linux); WasmKit for development |
| One Activity, one renderer | Multiple windows, split screen as separate scenes |
| `Renderer`, the built-ins, Bluetooth `Central`, Location, Device, Networking, Formatting | Motion, NFC, the Bluetooth peripheral role, background modes |
| Debug APKs, signed release APKs and AABs | Play upload, Play Feature Delivery |

## 3. Process model

```
┌──────────────────────────── APK ────────────────────────────────┐
│ Kotlin (classes.dex)                                            │
│   AppRuntimeApplication  → System.loadLibrary("app")            │
│   AppRuntimeActivity     → lifecycle, permissions, intents      │
│   composeui + IR adapter → Compose UI, events → native          │
│   callback adapters      → ScanCallback, GattCallback, …        │
│ ─────────────────────────── JNI ─────────────────────────────── │
│ lib/<abi>/libapp.so                                             │
│   AndroidHostApp: JNI_OnLoad, @JavaImplementation natives       │
│   AndroidHost: AppHost, MainLooper, clock, built-ins            │
│   contract modules: Bluetooth, Location, Device, …              │
│   RuntimeCore + RuntimeNative (rt_* symbols)                    │
│   the app's sealed slice (libapp.a) or its wasm2c output        │
│ lib/<abi>/libc++_shared.so                                      │
└─────────────────────────────────────────────────────────────────┘
```

### 3.1 The main thread

- **Everything that calls the guest runs on Android's main thread** (§6.4).
  Three kinds of call arrive there:
  - Kotlin → Swift calls: UI events, lifecycle, permission results, rows.
    These already arrive on the main thread.
  - Android listeners: `LocationListener` and `SensorEventListener` take a
    main `Looper` or `Handler`; `connectGatt` takes one on API 26+.
  - Work from other threads: Binder callbacks, the networking executor.
    These are posted to the main looper.
- **`MainLooper`** is the host's main loop, mirroring Linux's `MainLoop`. It
  has two parts:
  - a job queue other threads post to, woken through an `eventfd` that is
    registered with the main `ALooper` (swift-android-native's
    `AndroidLooper`);
  - timers on a `timerfd` registered the same way.
- **The clock** is `MainLooperClock`, the `HostClock`:
  - `now` reads `CLOCK_BOOTTIME`, which keeps counting through deep sleep,
    like Darwin's `mach_continuous_time`;
  - `schedule` uses the looper's timers.
- **No `DispatchQueue.main` and no main actor.** AndroidSwiftUI found that
  JNI from a native dispatch drain loses the app class loader: `FindClass`
  fails with `NoClassDefFoundError`. Looper callbacks run on the Java main
  thread, where the class loader is right. swift-java also caches the
  loader in `JNI_OnLoad`.
- **Every host→guest call** runs inside `GuestExecutor.enter`, as on the
  other hosts. The guest's update goes out before the call returns.

## 4. Modules

AndroidKit already uses names like `AndroidLocation`, `AndroidNFC` and
`AndroidOS`, and AndroidBluetooth is its own module, so this host prefixes
its modules with `AndroidHost`.

| Module | Contents |
|---|---|
| `AndroidHost` | `AppHost` (the checks, the built-ins, the modules, `rt_main`), `AppInfo`, `HostModule`, `MainLooper`, `MainLooperClock`, `AndroidPermissions`, `AndroidBundle`, `AndroidApplication` |
| `AndroidHostUI` | The `Renderer` contract: it forwards `apply` / `replaceSubtree` bytes to Kotlin, and Kotlin's `event` / `rowCount` / `row` calls to the guest's `RendererDelegate` |
| `AndroidHostBluetooth` | `Central`, `Peripheral`, `Service`, `Characteristic`, `Descriptor`, `Advertisement` over AndroidBluetooth |
| `AndroidHostLocation` | `LocationManager` over `android.location` |
| `AndroidHostDevice` | `Device` over `Build`, `BatteryManager`, `Configuration`, `Settings.Secure` |
| `AndroidHostNetworking` | `HTTPSession` over `java.net.HttpURLConnection` |
| `AndroidHostFormatting` | Number and date formatting over `android.icu.text` |
| `AndroidHostMotion`, `AndroidHostNFC` | Phase 3: NDK sensors (`ASensorManager`) and `NfcAdapter` reader mode |
| `AndroidHostApp` | `JNI_OnLoad` and the `@JavaImplementation` natives of the Kotlin shell. It links every module, plus `CRuntime` |
| `AndroidPackager`, `android-app` | The packager (§8) |

The Gradle side lives in `Android/`:

| Gradle module | Contents |
|---|---|
| `:appruntime-shell` | `AppRuntimeApplication`, `AppRuntimeActivity` (a `ComponentActivity`), `NativeHost` (the `external fun`s), `HostContext` |
| `:appruntime-ui` | The IR adapter: `RenderCodec.kt`, `IRAdapter.kt`, `AppRuntimeSink` (composeui's `CallbackSink`). It depends on `composeui` |
| `:appruntime-callbacks` | The Kotlin listener adapters for each contract module; AndroidBluetooth's two adapters move here from its demo (§9.3) |
| `:template` | The app module the packager copies and fills in (§8) |

The Swift package depends on AppRuntime without its `GuestExports` trait,
like the other hosts. The slice's `rt_dispatch` and `rt_finalize` are then
the only copies linked (DarwinAppRuntime's `HostRuntime.md` §8).

## 5. Startup

1. **`AppRuntimeApplication.onCreate`** calls
   `System.loadLibrary("app")`.
   - `JNI_OnLoad` runs swift-java's setup: it adopts the VM and caches the
     class loader.
   - It also calls `MainLooper.install()` on the main thread.
2. **`AppRuntimeActivity.onCreate`** calls `NativeHost.start(activity,
   savedState)`. The app's keys come from the APK, not a file path:
   - `RTABIVersion`, `RTContracts` and `RTCapabilities` from
     `assets/rt/Info.plist`, which the packager copies from the universal
     bundle;
   - the id, version and build from `PackageManager`.
3. **Check the ABI and contract versions** (§7.6). A failure means a
   corrupt app, because the packager already checked. A debug build shows
   the error; a release build logs it and finishes the Activity.
4. **Set up the runtime:**
   - `NativeRuntime.shared.bindDirectly()`;
   - set the capabilities and the clock;
   - register the built-ins;
   - register each module whose contracts the app uses (§14's allowlist).
5. **Call `rt_main`.** When the guest calls `Renderer.make`, `AndroidHostUI`
   asks the Activity to `setContent { AppRuntimeRoot(store) }`. The first
   tree is in the store before `rt_main` returns.
6. **From then on**, the guest runs only when Android calls in: events,
   listeners, timers and lifecycle.

Configuration changes (rotation, dark mode, locale) must not restart the
guest:

- The Activity declares `android:configChanges` for them, and Compose
  re-lays out.
- If the system kills and recreates the Activity anyway, the guest keeps
  running in the process and the new Activity re-attaches to the existing
  renderer.
- A new process starts the guest from scratch. That matches iOS, where an
  app relaunched after termination starts over.

## 6. Contracts

The rules are the same as DarwinAppRuntime's `HostRuntime.md` §5:

- **Permissions first:** `make` and `authorizationStatus` never prompt.
- **Main thread:** delegates are called on the main thread only.
- **Ownership:** the implementation holds its delegate proxy strongly.
- **Errors:** each failure maps to the contract's error codes, with
  `unknown` for anything else, and is logged.
- **Identity:** one wrapper per Android object.

Each Android object Swift keeps is a swift-java global reference, released
with the wrapper.

### 6.1 Built-ins

| Built-in | Android |
|---|---|
| `Clock` | `MainLooperClock` (§3.1) |
| `Permissions` | See the table below. `status` uses `checkSelfPermission`, plus `shouldShowRequestPermissionRationale` and a "requested before" flag in `SharedPreferences` to tell `notDetermined` from `denied`. `request` calls `ActivityCompat.requestPermissions`, and the Activity forwards `onRequestPermissionsResult`. A capability the manifest doesn't declare is `denied`; one the device lacks (`FEATURE_BLUETOOTH_LE`, `FEATURE_NFC`) is `unavailable` |
| `Bundle` | `identifier` is the package name, `version` is `versionName`, `build` is `versionCode`, and `preferredLanguages` is `LocaleList.getDefault()`. Localized strings come from the bundle's `.lproj` folders, which the packager copies to `assets/rt/` and Swift reads through `AAssetManager`, so lookups behave as on the other hosts |
| `Application` | `state` comes from the Activity's lifecycle (resumed → active, started → inactive, stopped → background); `onTrimMemory(TRIM_MEMORY_RUNNING_LOW)` and above sends a memory warning; `ACTION_VIEW` intents (launch and `onNewIntent`) go to `open:url:` |

Permissions by capability:

| Capability | Runtime permissions |
|---|---|
| `bluetooth` | `BLUETOOTH_SCAN` (with `neverForLocation`) and `BLUETOOTH_CONNECT` on API 31+; `ACCESS_FINE_LOCATION` on API 28–30 |
| `location(.whenInUse)` | `ACCESS_FINE_LOCATION` and `ACCESS_COARSE_LOCATION` |
| `location(.always)` | The above, then `ACCESS_BACKGROUND_LOCATION` as a second request (API 29+; Android requires the two steps) |
| `motion` | `ACTIVITY_RECOGNITION` (API 29+), for the step counter |
| `notifications` | `POST_NOTIFICATIONS` (API 33+) |
| `camera` | `CAMERA` |
| `nfc`, `localNetwork` | Install-time permissions with no prompt (`NFC`, `INTERNET`, `ACCESS_NETWORK_STATE`), so always `authorized` once declared |

### 6.2 Contract modules

| Contract | Android | Notes |
|---|---|---|
| Bluetooth `Central` and friends | `BluetoothLeScanner`, `BluetoothGatt`, through AndroidBluetooth | The `Central` contract is implemented directly over AndroidBluetooth's bindings, not over its `GATT.CentralManager` (`AndroidCentral`): that API's `async` and actor model doesn't fit a delegate contract on the main thread. GATT operations are queued per device, one at a time, as Android requires (DynamicRuntime.md's host obligations). `connectGatt(…, TRANSPORT_LE, handler)` delivers `BluetoothGattCallback` on the main looper. `Peripheral.identifier` is the MAC address. Scan modes map to `ScanSettings` (`SCAN_MODE_LOW_POWER`, `BALANCED`, `LOW_LATENCY`). The connection timeout is a main-looper timer. `GATT_*` statuses map to `BluetoothError` |
| `LocationManager` | `android.location.LocationManager` | The fused provider when available (API 31+), otherwise GPS and network. Updates go through `requestLocationUpdates(…, Looper.getMainLooper())`. Google Play services is not used, so apps work on any device. Accuracy maps to `ACCURACY_FINE` / `ACCURACY_COARSE` and the provider choice. Full accuracy is a precise-location request on API 31+ |
| `Device` | `Build`, `BatteryManager` (a sticky `ACTION_BATTERY_CHANGED` receiver while monitoring), `Configuration` and `Display` rotation | `vendorIdentifier` is `Settings.Secure.ANDROID_ID`, which is scoped to the app's signing key, the closest match to `identifierForVendor` |
| `HTTPSession` | `HttpURLConnection` on a host-owned executor | It uses the platform's TLS, proxy and network-security config. Results, redirects and challenges are posted to the main looper. A redirect asks the guest on the main thread while the worker waits, so the guest is still called synchronously |
| Formatting | `android.icu.text.NumberFormat`, `DateFormat`, `SimpleDateFormat` (API 24+) | Formatters are cached per locale and style. ICU ships in the OS, so the APK carries no ICU data |
| Motion (phase 3) | `ASensorManager` (NDK) through swift-android-native's `AndroidHardware` | Accelerometer, gyroscope, `TYPE_PRESSURE` for the altimeter, `TYPE_STEP_COUNTER` for the pedometer. Timestamps are already `CLOCK_BOOTTIME` nanoseconds. `ActivityRecognizer` needs Google Play services, so it reports `isAvailable == false` |
| `NFCReader` (phase 3) | `NfcAdapter.enableReaderMode` with the tag technologies requested | Reader mode needs the resumed Activity, so the reader session follows the lifecycle |

## 7. The SwiftUI player

### 7.1 Data flow

```
guest ─apply/replaceSubtree─► AndroidHostUI ─byte[]─► RenderCodec.kt ─► IRAdapter ─► composeui TreeStore ─► Compose
  ▲                                                                                       │
  └── RendererDelegate ◄── NativeHost.event / rowCount / row ◄── AppRuntimeSink ◄─────────┘
```

- **`apply`** replaces the tree in `TreeStore`. **`replaceSubtree`** uses
  `TreeStore.patch`.
- composeui keys its nodes by string ID, and the adapter uses the decimal
  node ID. Compose's identity then follows the guest's IDs, so native
  state survives updates: scroll position, focus, and a text field's
  selection.
- **Events.** composeui calls a `CallbackSink` with callback IDs taken from
  node props (`onTap`, `onSubmit`, `onIncrement`, …).
  - The adapter assigns those IDs. It keeps a table from each callback ID
    to a (node ID, event kind, value transform) entry, and rebuilds the
    entries for each subtree it replaces.
  - `AppRuntimeSink` turns a call into `NativeHost.event(nodeID, kind,
    payload)`, which is one JNI call into `RendererDelegate.event` inside
    `GuestExecutor.enter`.
  - The guest's answer is in the store before the call returns, as on
    Darwin.
- **Lazy rows.** composeui's `itemNode(id, index)` calls
  `NativeHost.row(listID, index)`. The bytes are decoded and cached by the
  list's `revision`, as the IR requires.
- **Control sync.** The IR's rule is "take the guest's value only when it
  differs from what was last rendered". composeui's `TextField` already
  re-syncs that way, and the adapter checks every control against it.

### 7.2 Vocabulary

composeui already renders most of the IR. The adapter maps names and
props, and a few nodes need work in composeui itself:

| IR | composeui | Work |
|---|---|---|
| `Text`, `Image`, `Label`, `Spacer`, `Divider`, `Color`, stacks, `ScrollView`, `Button`, `Toggle`, `TextField`, `Slider`, `ProgressView`, `Picker`, `List`, `Section`, `Form`, `DisclosureGroup`, lazy stacks and grids, `Menu`, `Link`, `TabView` | Same names | Props renamed, events wired |
| `Stepper` | `onIncrement` / `onDecrement` | The adapter sends `change(value ± step)`, clamped |
| `NavStack`, `NavLevel`, `ToolbarItem` | `NavStack` with a `titles` prop and `onPop` | The adapter flattens the levels. System back (predictive back on API 33+) sends `pop` |
| `Sheet`, `Alert` (`style: dialog`) | `Sheet`, `Alert`, `ConfirmationDialog` | Dismissal sends `change(false)` |
| `Tab` | Children of `TabView` | Title and `systemImage` become the tab item |
| `Grid`, `GridRow` | — | Add to composeui (a `Row` per `GridRow`, columns sized to the widest cell) |
| `SwipeActions` | — | Add to composeui (`SwipeToDismissBox`), or a long-press menu at first |
| `Searchable` | — | Add to composeui (Material 3 `SearchBar`) |
| Unknown types and modifiers | `EmptyView` | Logged once per type: the vocabulary is add-only |

Modifiers map one to one: `padding`, `frame`, `offset`, `background`,
`foregroundColor`, `tint`, `opacity`, `cornerRadius`, `border`, `shadow`,
`font` and its weight, `italic`, `lineLimit`, `multilineTextAlignment`,
`disabled`, `onTapGesture` and the accessibility modifiers.
`accessibilityIdentifier` becomes Compose's `testTag`, with
`testTagsAsResourceId` on, so UI Automator can find nodes by ID.

**Look:** Material 3 with dynamic color on API 31+. Named colors map to
Material's palette in light and dark. SF Symbol names map to Material icons
for the common ones; the rest show a placeholder, as on Linux.

## 8. The packager

`android-app` turns a universal bundle into an APK or AAB. Its commands
mirror `darwin-app` and `linux-app`:

```sh
android-app validate App.app
android-app package App.app --abi arm64-v8a --abi x86_64 [--engine native|wasm2c] [--release --keystore K --alias A] [--aab]
android-app run App.app            # installs on the running emulator or device with adb, and starts it
android-app gradle App.app         # writes the Gradle project, for Android Studio
```

The pipeline:

1. **Validate.** The bundle's contracts must all be implemented here, and
   its capabilities must match its contracts. The manifest must list an
   `android` platform, with `minSDK` raised to 28 if lower. Each requested
   ABI needs a slice, or `App.wasm` with `--engine wasm2c`.
2. **Build `libapp.so` per ABI.**
   - The packager generates a SwiftPM package that links `AndroidHostApp`
     with the slice. That is the same per-app approach as `darwin-app`, and
     it reuses the work directory between builds.
   - It builds with `swift build --swift-sdk swift-6.4.2-RELEASE_android
     --triple <arch>-unknown-linux-android28`. Flags for the Android link
     go in the generated package, limited to Android: Swift 6.4's build
     system would also apply command-line flags to the macOS builds of
     macros.
   - The SDK's toolset links with `-z max-page-size=16384`, the 16 KB page
     alignment Play requires for `targetSdk` 35 apps.
   - With `--engine wasm2c`, AppRuntime's `Scripts/wasm2c-shim.py build`
     makes the `libapp.a` instead.
3. **Write `AndroidManifest.xml`.** It holds:
   - the package, `versionCode` (the build number) and `versionName`;
   - `minSdk` and `targetSdk`;
   - the label (`@string/app_name`, per language) and the icon;
   - the permissions from §6.1;
   - `uses-feature` entries (`bluetooth_le`, `nfc`, `sensor.*`), marked
     `required` for capabilities marked `.required()`;
   - an intent filter for each URL scheme;
   - the app's `android.extraManifest`, merged into `<manifest>`.
4. **Resources.**
   - The icon is rendered at each mipmap density, plus an adaptive icon.
   - `res/values-<lang>/strings.xml` gets the app's name from
     `Manifest.strings`.
   - `assets/rt/` gets the bundle's `Info.plist`, the `.lproj` folders and
     the app's resources.
5. **Build.** The packager fills `:template` into a work-directory Gradle
   project and runs `assembleDebug`, `assembleRelease` or `bundleRelease`.
   It uses Gradle rather than raw `aapt2` / `d8` because Compose needs the
   Kotlin compiler plugin and Maven dependencies.
   - **Debug** builds use the debug keystore.
   - **Release** builds sign with the given keystore (`apksigner` v2/v3
     through Gradle's `signingConfig`), and run R8 with keep rules for the
     JNI entry points and the swift-java wrappers.

The packager only reads the universal bundle, and never compiles guest
Swift, which keeps apps and hosts versioned independently (§7.5).

## 9. Changes needed elsewhere

### 9.1 AppRuntime

1. **An arm64 slice that works with tagged pointers.** Phase 0 ran
   `ExampleApp`'s slice on bionic: its libc imports are all there, and
   `aarch64-linux.c`'s private glibc pieces don't get in the way. But the
   slice's Embedded stdlib, built for `aarch64-unknown-linux-gnu`, keeps
   String's flags in a pointer's top byte, which Android's heap tags use
   (Status). `android-arm64-v8a` needs an Embedded stdlib and concurrency
   runtime built for `aarch64-unknown-linux-android`, so the slice uses
   Android's spare-bit masks. Until then, hosts turn tagging off.
2. **Shared host code.** `AppInfo`, `AppHost`'s checks and `HostModule` are
   the same on every host. LinuxAppRuntime's plan put off moving them into
   AppRuntime "once a third host needs them", and this is the third host.
   They become a `RuntimeHost` module before this host copies them.
3. **Docs and examples.**
   - DynamicRuntime.md's Android rows (§2.3, §5, §6.1, §9.4) describe a
     Swift host, with Kotlin only for the shell, the player and the
     listener adapters.
   - The manifest examples' `minSDK: 26` becomes 28.
4. **Toolchain.** Host builds of `RuntimeCore`, `RuntimeNative`,
   `DynamicRuntime` and the contract modules for
   `aarch64-unknown-linux-android28` and `x86_64-unknown-linux-android28`,
   in AppRuntime's CI.

### 9.2 AndroidSwiftUI

- `composeui` must be usable without the Swift evaluator: published as a
  Maven artifact (GitHub Packages or `mavenLocal`), or consumed as a Gradle
  included build of a pinned checkout.
- New nodes: `Grid` / `GridRow`, `SwipeActions` and `Searchable` (§7.2).
- `SwiftBridge.sink` is global, which is fine with one renderer per
  process. Multiple scenes would need a sink per `TreeStore`.

### 9.3 AndroidBluetooth, AndroidKit, swift-java

- **AndroidBluetooth:**
  - The Kotlin `ScanCallback` and `BluetoothGattCallback` adapters move
    from `Demo/` into a library module, so hosts can depend on them.
  - The `connectGatt` overload that takes a `Handler` is bound, if it isn't
    already.
  - Its permission check covers `BLUETOOTH_CONNECT`.
- **AndroidKit:** the classes this host needs and doesn't find yet are
  added through wrap-java:
  - `ComponentActivity`;
  - `ActivityCompat`;
  - `LocaleList`;
  - `android.icu.text`;
  - `HttpURLConnection` (from swift-java's `JavaNet`).
- **All three, and swift-android-native,** must build with Swift 6.4.2 and
  the 6.4.2 Android SDK. The upstream projects are pinned to `main` and
  `master` branches today, so this host pins revisions in
  `Package.resolved`.

## 10. Testing

- **Swift logic with no JNI:** the error tables, the permission and
  capability mapping, UUID and scan-record parsing, the GATT queue,
  `AppInfo` and the startup checks. These run with `swift test` on macOS,
  against fakes, the way Darwin and Linux test their mappings.
- **The IR adapter:** `RenderCodec.kt` is checked against byte fixtures
  that AppRuntime's `RenderCodecTests` write. The adapter and composeui are
  tested with Compose's desktop UI tests (`desktopTest`), as composeui
  already does, so no emulator is needed.
- **On the emulator:**
  - the JNI paths (startup, looper, clock, permissions, location with a
    mock provider, networking against a local server) run as
    instrumentation tests;
  - `ExampleUI` end to end: UI Automator finds nodes by
    `accessibilityIdentifier`, taps, types and navigates, and takes a
    screenshot of each screen.
  - The local arm64 `android-36` image covers this. CI uses API 28 and 35
    images, x86_64 on Linux runners.
- **Hardware:** Bluetooth and NFC need a device, so they get manual runs.

## 11. Phases

0. **Toolchain spike.**
   - Install the Swift 6.4.2 Android SDK.
   - Build AppRuntime's host modules, swift-java and AndroidKit for
     `aarch64-unknown-linux-android28`.
   - Link `ExampleApp`'s `android-arm64-v8a` slice into a `.so`, load it
     from a bare Activity on the emulator, and run `rt_main`.
   - This proves the slice on bionic and the 6.4.2 stack (§9.1.1).
   - `Scripts/example-app.sh` does it: it builds the slice, links it into
     `libExampleAppHost.so` (`Sources/ExampleAppHost`), stages the runtime
     libraries, builds `Android/example-app`, and with `--run` starts it on
     the emulator. It checks the report against the same lines as
     AppRuntime's `Packages/LinkedSlice` test.
1. **Host runtime and player.**
   - `RuntimeHost` lands in AppRuntime.
   - Build `AndroidHost`, `AndroidHostUI`, `AndroidHostApp`, the shell and
     the IR adapter.
   - Done when `ExampleUI` runs on the emulator from a hand-made Gradle
     project: it renders, and taps, typing, the lazy list and navigation
     reach the guest and back.
2. **Packager.** `android-app validate`, `package` (debug APK, then signed
   release APK and AAB), `run` and `gradle`. Done when `ExampleUI` packages
   from its universal bundle and runs.
3. **Contracts:**
   - Bluetooth, Location, Device, Networking and Formatting;
   - then Motion and NFC.

   Each is unit-tested through its mappings and run on the emulator where
   Android allows it.
4. **More:**
   - wasm2c;
   - the x86_64 and armeabi-v7a ABIs on hardware;
   - composeui's missing nodes;
   - images from the bundle;
   - TalkBack checks;
   - background location and Bluetooth (foreground services).

## 12. Open questions

- **Gradle in the packager.** Requiring Gradle and a JDK on the build
  machine is heavy for a packager. One alternative: ship the shell, the
  adapter and composeui prebuilt as `classes.dex` plus resources, and build
  the APK with `aapt2`, `zipalign` and `apksigner` only. That is faster and
  has no Maven at package time, but the prebuilt dex has to be versioned
  with the host. Gradle comes first because it's the shortest path.
- **Process death.** Android may kill the process in the background. The
  guest has no state restoration contract, so it starts over, as on iOS.
  `onSaveInstanceState` could later carry a guest-provided blob, which
  would need a new `Application` method.
- **Peripheral role.** AndroidBluetooth binds `BluetoothGattServer` and the
  advertiser, but no contract covers the peripheral role yet.
- **Play services.** This plan avoids it. An optional module could use the
  fused location provider and activity recognition on devices that have
  it.
