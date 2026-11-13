# AndroidAppRuntime

The Android host for [AppRuntime](https://github.com/PureSwift/AppRuntime)
apps. An AppRuntime app is guest code only: a universal bundle with
`App.wasm` and native `libapp.a` slices. This repository will turn one into
an Android app:

- the **host runtime**, in Swift: the Activity shell, the main looper, the
  runtime core behind `rt.h`, and the contract implementations over the
  Android SDK, through [swift-java](https://github.com/swiftlang/swift-java),
  [AndroidKit](https://github.com/PureSwift/Android) and
  [AndroidBluetooth](https://github.com/PureSwift/AndroidBluetooth);
- the **SwiftUI player**: [AndroidSwiftUI](https://github.com/PureSwift/AndroidSwiftUI)'s
  Compose interpreter, behind an adapter for AppRuntime's render IR;
- the **packager**, `android-app`, which turns a universal bundle into a
  signed APK or App Bundle.

**Status:** phase 0 of the [plan](Documentation/Plan.md): AppRuntime's
`ExampleApp`, from its sealed Android slice, linked into a library that a
bare Activity loads. It builds and loads in the emulator. Running `rt_main`
needs NDK r29 (the plan's status has the details).

It is the counterpart of
[DarwinAppRuntime](https://github.com/PureSwift/DarwinAppRuntime) and
[LinuxAppRuntime](https://github.com/PureSwift/LinuxAppRuntime).

## Building

Swift 6.4 is required (`.swift-version` pins 6.4.2), with the Swift SDK
for Android set up with NDK r29:

```sh
swift sdk install https://download.swift.org/swift-6.4.2-release/android-sdk/swift-6.4.2-RELEASE/swift-6.4.2-RELEASE_android.artifactbundle.tar.gz \
    --checksum 4d6ad63ea74becd58e123ff58b1b48c3be5ec0db0dff0ea5abe37ac007dd3233
ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/29.0.14206865 \
    ~/Library/org.swift.swiftpm/swift-sdks/swift-6.4.2-RELEASE_android.artifactbundle/swift-android/scripts/setup-android-sdk.sh
```

Then, with an AppRuntime checkout next to this one (or `APPRUNTIME_PATH`)
and an emulator running:

```sh
ANDROID_NDK_HOME=~/Library/Android/sdk/ndk/29.0.14206865 Scripts/example-app.sh --run
```

The script builds `ExampleApp`'s slice with AppRuntime's `guest.py`, links it
into `libExampleAppHost.so`, builds `Android/example-app` with Gradle (on a
JDK from 17 to 21), installs it, and checks the report it logs.
