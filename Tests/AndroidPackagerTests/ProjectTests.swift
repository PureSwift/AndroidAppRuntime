@testable import AndroidPackager
import Foundation
import Testing

/// The manifest, the Gradle project, staging the libraries, and the steps
/// `package` and `run` take.
@Suite struct ProjectTests {

    let directory = TemporaryDirectory()

    func bundle(_ info: [String: Any] = Fixtures.info(), icon: Bool = false, names: [String: String] = [:]) throws -> UniversalBundle {
        try UniversalBundle(url: Fixtures.bundle(in: directory, info: info, icon: icon, names: names))
    }

    func read(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: Manifest

    @Test func asksForEachCapabilitysPermissions() throws {
        let info = Fixtures.info([
            "RTCapabilities": ["bluetooth", "location", "network"],
            "RTCapabilityOptions": ["location": ["access": "always"], "bluetooth": ["required": "true"]],
        ])
        let writer = ManifestWriter(bundle: try bundle(info))
        let names = writer.permissions.map(\.name)
        #expect(names == [
            "android.permission.ACCESS_FINE_LOCATION", "android.permission.ACCESS_COARSE_LOCATION",
            "android.permission.ACCESS_BACKGROUND_LOCATION", "android.permission.BLUETOOTH_SCAN",
            "android.permission.BLUETOOTH_CONNECT", "android.permission.BLUETOOTH", "android.permission.BLUETOOTH_ADMIN",
            "android.permission.INTERNET", "android.permission.ACCESS_NETWORK_STATE",
            "android.permission.FOREGROUND_SERVICE", "android.permission.FOREGROUND_SERVICE_LOCATION",
        ])
        // Location for every API, since the app uses it; not only to scan.
        #expect(writer.permissions.first { $0.name == "android.permission.ACCESS_FINE_LOCATION" }?.maxSDK == nil)
        #expect(writer.features == [
            .init(name: "android.hardware.bluetooth_le", required: true),
            .init(name: "android.hardware.location", required: false),
        ])
        let manifest = writer.manifest
        #expect(manifest.contains(#"<uses-permission android:name="android.permission.BLUETOOTH_SCAN" android:usesPermissionFlags="neverForLocation" />"#))
        #expect(manifest.contains(#"<uses-permission android:name="android.permission.BLUETOOTH" android:maxSdkVersion="30" />"#))
        #expect(manifest.contains(#"<uses-feature android:name="android.hardware.bluetooth_le" android:required="true" />"#))
        #expect(manifest.contains("org.pureswift.appruntime.AppRuntimeActivity"))
        #expect(manifest.contains(#"android:allowNativeHeapPointerTagging="false""#))
        #expect(!manifest.contains("android:icon"))
    }

    @Test func requiresGLESForTheGraphicsCapability() throws {
        let plain = ManifestWriter(bundle: try bundle())
        #expect(plain.glESVersion == nil)
        #expect(!plain.manifest.contains("glEsVersion"))
        let writer = ManifestWriter(bundle: try bundle(Fixtures.info(["RTCapabilities": ["graphics"]])))
        #expect(writer.glESVersion == "0x00020000")
        #expect(writer.permissions.isEmpty)
        #expect(writer.manifest.contains(#"<uses-feature android:glEsVersion="0x00020000" android:required="true" />"#))
        let three = ManifestWriter(bundle: try bundle(Fixtures.info([
            "RTCapabilities": ["graphics"], "RTCapabilityOptions": ["graphics": ["api": "gles3"]],
        ])))
        #expect(three.glESVersion == "0x00030000")
    }

    @Test func catchesASignInsRedirectForEachScheme() throws {
        let plain = ManifestWriter(bundle: try bundle())
        #expect(!plain.manifest.contains("AuthenticationRedirectActivity"))
        let writer = ManifestWriter(bundle: try bundle(Fixtures.info([
            "RTCapabilities": ["secrets"],
            "RTAuthenticationSchemes": ["com.example.mail", "com.example.calendar"],
        ])))
        #expect(writer.bundle.authenticationSchemes == ["com.example.mail", "com.example.calendar"])
        #expect(writer.permissions.isEmpty)
        let document = try XMLDocument(xmlString: writer.manifest)
        let activities = try document.nodes(forXPath: "/manifest/application/activity/@android:name").compactMap(\.stringValue)
        #expect(activities == ["org.pureswift.appruntime.AppRuntimeActivity", "org.pureswift.appruntime.contracts.AuthenticationRedirectActivity"])
        let schemes = try document.nodes(forXPath: "//activity[2]/intent-filter/data/@android:scheme").compactMap(\.stringValue)
        #expect(schemes == ["com.example.mail", "com.example.calendar"])
        let categories = try document.nodes(forXPath: "//activity[2]/intent-filter[1]/category/@android:name").compactMap(\.stringValue)
        #expect(categories == ["android.intent.category.DEFAULT", "android.intent.category.BROWSABLE"])
    }

    @Test func asksToWriteContactsUnlessTheAppOnlyReads() throws {
        let writes = ManifestWriter(bundle: try bundle(Fixtures.info(["RTCapabilities": ["contacts"],
                                                                      "RTCapabilityOptions": ["contacts": ["access": "readWrite"]]])))
        #expect(writes.permissions.map(\.name) == ["android.permission.READ_CONTACTS", "android.permission.WRITE_CONTACTS"])
        let reads = ManifestWriter(bundle: try bundle(Fixtures.info(["RTCapabilities": ["contacts"],
                                                                     "RTCapabilityOptions": ["contacts": ["access": "readOnly"]]])))
        #expect(reads.permissions.map(\.name) == ["android.permission.READ_CONTACTS"])
    }

    /// Both at either level: Android's provider reads nothing without
    /// READ_CALENDAR, not even where to add an event.
    @Test func asksForBothCalendarPermissionsAtEitherLevel() throws {
        for access in ["full", "writeOnly"] {
            let writer = ManifestWriter(bundle: try bundle(Fixtures.info(["RTCapabilities": ["calendars"],
                                                                          "RTCapabilityOptions": ["calendars": ["access": access]]])))
            #expect(writer.permissions.map(\.name) == ["android.permission.READ_CALENDAR", "android.permission.WRITE_CALENDAR"])
        }
    }

    @Test func declaresTheNotificationsReceiverAndPermissions() throws {
        let plain = ManifestWriter(bundle: try bundle())
        #expect(!plain.manifest.contains("NotificationReceiver"))
        let writer = ManifestWriter(bundle: try bundle(Fixtures.info(["RTCapabilities": ["notifications"]])))
        #expect(writer.permissions.map(\.name) == [
            "android.permission.POST_NOTIFICATIONS", "android.permission.RECEIVE_BOOT_COMPLETED",
        ])
        let document = try XMLDocument(xmlString: writer.manifest)
        let receivers = try document.nodes(forXPath: "/manifest/application/receiver/@android:name").compactMap(\.stringValue)
        #expect(receivers == ["org.pureswift.appruntime.contracts.NotificationReceiver"])
        let actions = try document.nodes(forXPath: "/manifest/application/receiver/intent-filter/action/@android:name").compactMap(\.stringValue)
        #expect(actions.contains("android.intent.action.BOOT_COMPLETED"))
        #expect(actions.contains("android.intent.action.TIMEZONE_CHANGED"))
        let exact = ManifestWriter(bundle: try bundle(Fixtures.info([
            "RTCapabilities": ["notifications"], "RTCapabilityOptions": ["notifications": ["exactTiming": "true"]],
        ])))
        #expect(exact.permissions.map(\.name).last == "android.permission.SCHEDULE_EXACT_ALARM")
    }

    @Test func opensTheAppsDocumentTypesByMIMEType() throws {
        let plain = ManifestWriter(bundle: try bundle())
        #expect(!plain.manifest.contains("android.intent.action.VIEW"))
        let info = Fixtures.info([
            "RTCapabilities": ["userFiles"],
            "RTDocumentTypes": [
                ["Name": "Image", "Types": ["image/*"], "Role": "viewer"],
                ["Name": "Text", "Types": ["text/plain", ".md"], "Role": "editor"],
                // Only extensions: Android can't match it, so it's left out.
                ["Name": "Track", "Types": [".gpx"], "Role": "viewer"],
            ],
        ])
        let writer = ManifestWriter(bundle: try bundle(info))
        #expect(writer.bundle.documentTypes == [
            .init(types: ["image/*"], isEditor: false),
            .init(types: ["text/plain", ".md"], isEditor: true),
            .init(types: [".gpx"], isEditor: false),
        ])
        #expect(writer.permissions.isEmpty)
        let document = try XMLDocument(xmlString: writer.manifest)
        let filters = try document.nodes(forXPath: "/manifest/application/activity/intent-filter")
        // The launcher's, the images' and the text's.
        #expect(filters.count == 3)
        let actions = try document.nodes(forXPath: "/manifest/application/activity/intent-filter/action/@android:name").compactMap(\.stringValue)
        #expect(actions == [
            "android.intent.action.MAIN",
            "android.intent.action.VIEW",
            "android.intent.action.VIEW", "android.intent.action.EDIT",
        ])
        let mimeTypes = try document.nodes(forXPath: "//data/@android:mimeType").compactMap(\.stringValue)
        #expect(mimeTypes == ["image/*", "text/plain"])
        #expect(try document.nodes(forXPath: "//data/@android:scheme").compactMap(\.stringValue) == ["content", "content"])
    }

    @Test func playsOnInTheBackgroundWhereTheManifestSays() throws {
        let plain = ManifestWriter(bundle: try bundle(Fixtures.info(["RTCapabilities": ["audio"]])))
        #expect(!plain.playsInBackground)
        #expect(!plain.manifest.contains("NowPlayingService"))
        #expect(!plain.permissions.contains { $0.name.hasPrefix("android.permission.FOREGROUND_SERVICE") })
        let writer = ManifestWriter(bundle: try bundle(Fixtures.info([
            "RTCapabilities": ["audio"],
            "RTCapabilityOptions": ["audio": ["background": "true"]],
        ])))
        #expect(writer.playsInBackground)
        #expect(writer.permissions.map(\.name) == [
            "android.permission.FOREGROUND_SERVICE", "android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK",
        ])
        let document = try XMLDocument(xmlString: writer.manifest)
        let types = try document.nodes(forXPath: "/manifest/application/service/@android:foregroundServiceType").compactMap(\.stringValue)
        #expect(types == ["mediaPlayback"])
        let names = try document.nodes(forXPath: "/manifest/application/service/@android:name").compactMap(\.stringValue)
        #expect(names == ["org.pureswift.appruntime.contracts.NowPlayingService"])
    }

    @Test func declaresTheForegroundServiceForBackgroundWork() throws {
        let plain = ManifestWriter(bundle: try bundle(Fixtures.info(["RTCapabilities": ["location", "bluetooth"]])))
        #expect(plain.foregroundServiceTypes.isEmpty)
        #expect(!plain.manifest.contains("HostService"))
        #expect(!plain.permissions.contains { $0.name.hasPrefix("android.permission.FOREGROUND_SERVICE") })
        let info = Fixtures.info([
            "RTCapabilities": ["location", "bluetooth"],
            "RTCapabilityOptions": ["location": ["access": "always"], "bluetooth": ["background": "true"]],
        ])
        var writer = ManifestWriter(bundle: try bundle(info))
        #expect(writer.foregroundServiceTypes == ["location", "connectedDevice"])
        #expect(writer.permissions.map(\.name).suffix(3) == [
            "android.permission.FOREGROUND_SERVICE", "android.permission.FOREGROUND_SERVICE_LOCATION",
            "android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE",
        ])
        #expect(writer.manifest.contains(#"android:foregroundServiceType="location|connectedDevice""#))
        // wasm2c's code needs no tagging workaround.
        writer.hasNativeARM64Slice = false
        #expect(writer.manifest.contains(#"android:allowNativeHeapPointerTagging="true""#))
        #expect(!writer.manifest.contains("String's flags"))
        for manifest in [writer.manifest, plain.manifest] {
            let document = try XMLDocument(xmlString: manifest)
            #expect(try document.nodes(forXPath: "/manifest/application/activity").count == 1)
        }
        #expect(try XMLDocument(xmlString: writer.manifest).nodes(forXPath: "/manifest/application/service").count == 1)
    }

    @Test func scansForBluetoothWithLocationOnOlderAPIsOnly() throws {
        let writer = ManifestWriter(bundle: try bundle(Fixtures.info(["RTCapabilities": ["bluetooth"]])))
        #expect(writer.permissions.first { $0.name == "android.permission.ACCESS_FINE_LOCATION" }?.maxSDK == 30)
    }

    @Test func mergesTheAppsExtraManifest() throws {
        let info = Fixtures.info(["RTPlatformExtras": ["android": ["extraManifest": "<queries>\n  <package android:name=\"a.b\" />\n</queries>"]]])
        let manifest = ManifestWriter(bundle: try bundle(info)).manifest
        #expect(manifest.contains("    <queries>\n      <package android:name=\"a.b\" />\n    </queries>"))
    }

    @Test func namesTheAppInEachLanguage() throws {
        let writer = ManifestWriter(bundle: try bundle(names: ["en": "Weather", "pt-BR": "Tempo", "zh-Hans": "天气"]))
        #expect(Set(writer.strings.keys) == ["values", "values-en", "values-pt-rBR", "values-b+zh+Hans"])
        #expect(writer.strings["values-pt-rBR"]?.contains("<string name=\"app_name\">Tempo</string>") == true)
        #expect(ManifestWriter.escapeString("Tom's <App> & @co") == "Tom\\'s &lt;App&gt; &amp; @co")
        #expect(ManifestWriter.escapeString("@home") == "\\@home")
        #expect(ManifestWriter.resourceQualifier("ES") == "es")
    }

    // MARK: Gradle project

    @Test func writesTheGradleProject() throws {
        let host = Fixtures.hostPackage(in: directory)
        let signing = GradleProject.Signing(keystore: URL(fileURLWithPath: "/keys/release.jks"), alias: "release")
        let project = GradleProject(directory: directory.url.appendingPathComponent("gradle"), hostPackage: host,
                                    bundle: try bundle(icon: true, names: ["en": "Weather", "es": "Tiempo"]),
                                    abis: [.arm64, .x86_64], signing: signing)
        try project.write()
        let root = project.directory
        let build = try read(root.appendingPathComponent("app/build.gradle.kts"))
        #expect(build.contains(#"applicationId = "org.example.Weather""#))
        #expect(build.contains("minSdk = 28"))
        #expect(build.contains("targetSdk = 35"))
        #expect(build.contains("versionCode = 7"))
        #expect(build.contains(#"versionName = "1.2""#))
        #expect(build.contains(#"abiFilters += listOf("arm64-v8a", "x86_64")"#))
        #expect(build.contains(#"storeFile = file("/keys/release.jks")"#))
        #expect(build.contains(#"System.getenv("ANDROID_KEYSTORE_PASSWORD")"#))
        #expect(build.contains("isMinifyEnabled = true"))
        let settings = try read(root.appendingPathComponent("settings.gradle.kts"))
        #expect(settings.contains(host.appendingPathComponent("Android/appruntime-shell").path))
        #expect(settings.contains(host.appendingPathComponent("Android/appruntime-contracts").path))
        for path in ["gradlew", "gradle/wrapper/gradle-wrapper.properties", "build.gradle.kts", "app/src/main/AndroidManifest.xml",
                     "app/src/main/res/values/strings.xml", "app/src/main/res/values-es/strings.xml",
                     "app/src/main/res/mipmap-xxxhdpi/ic_launcher.png", "app/src/main/assets/rt/Info.plist",
                     "app/src/main/assets/rt/resources/es.lproj/Manifest.strings"] {
            #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), "\(path)")
        }
        #expect(try read(root.appendingPathComponent("app/src/main/AndroidManifest.xml")).contains(#"android:icon="@mipmap/ic_launcher""#))
    }

    @Test func makesTheAppsImagesDrawables() throws {
        let url = Fixtures.bundle(in: directory)
        for path in ["Logo.png", "Logo@2x.png", "Logo@3x.png", "icons/Star-Filled.JPG", "icons/star_filled.jpg", "notes.txt", "es.lproj/Logo.png"] {
            directory.write(Data([0x89]), to: "Weather.app/resources/\(path)")
        }
        #expect(ImageResources.resourceName("Logo") == "rt_logo")
        #expect(ImageResources.resourceName("Star-Filled.png") == "rt_star_filled")
        #expect(ImageResources.resourceName("Ünïcode 2") == "rt__n_code_2")
        let project = GradleProject(directory: directory.url.appendingPathComponent("project"),
                                    hostPackage: Fixtures.hostPackage(in: directory), bundle: try UniversalBundle(url: url), abis: [.arm64])
        let warnings = try project.write()
        #expect(warnings == ["star_filled.jpg and Star-Filled.JPG are both the drawable rt_star_filled; the first is used"])
        let res = project.directory.appendingPathComponent("app/src/main/res")
        for file in ["drawable-mdpi/rt_logo.png", "drawable-xhdpi/rt_logo.png", "drawable-xxhdpi/rt_logo.png", "drawable-mdpi/rt_star_filled.jpg"] {
            #expect(FileManager.default.fileExists(atPath: res.appendingPathComponent(file).path), "\(file)")
        }
        #expect(!FileManager.default.fileExists(atPath: res.appendingPathComponent("drawable-mdpi/rt_notes.txt").path))
    }

    @Test func indexesTheResourcesForFiles() throws {
        let url = Fixtures.bundle(in: directory)
        for path in ["welcome.txt", "levels/1.map", "levels/boss/3.map", ".hidden", "_private/key.txt",
                     ".DS_Store", "levels/.ds_store", ".git/HEAD", "CVS/Entries", "notes.txt~", "Thumbs.db"] {
            directory.write(Data([0x41]), to: "Weather.app/resources/\(path)")
        }
        let project = GradleProject(directory: directory.url.appendingPathComponent("project"),
                                    hostPackage: Fixtures.hostPackage(in: directory), bundle: try UniversalBundle(url: url), abis: [.arm64])
        try project.write()
        let index = try read(project.directory.appendingPathComponent("app/src/main/assets/rt/resources.index"))
        #expect(index == """
            .hidden
            _private/key.txt
            levels/1.map
            levels/boss/3.map
            welcome.txt

            """)
        // Gradle keeps what starts with "." or "_", as the index has it.
        let build = try read(project.directory.appendingPathComponent("app/build.gradle.kts"))
        #expect(build.contains(#"ignoreAssetsPattern = "!.svn:!.git:!.ds_store:!*.scc:!CVS:!thumbs.db:!picasa.ini:!*~""#))
    }

    @Test func indexesNoResourcesForABundleWithout() throws {
        let url = Fixtures.bundle(in: directory)
        let project = GradleProject(directory: directory.url.appendingPathComponent("project"),
                                    hostPackage: Fixtures.hostPackage(in: directory), bundle: try UniversalBundle(url: url), abis: [.arm64])
        try project.write()
        #expect(try read(project.directory.appendingPathComponent("app/src/main/assets/rt/resources.index")) == "")
    }

    @Test func rewritesResourcesTheAppDropped() throws {
        let host = Fixtures.hostPackage(in: directory)
        let url = directory.url.appendingPathComponent("gradle")
        try GradleProject(directory: url, hostPackage: host, bundle: try bundle(icon: true), abis: [.arm64]).write()
        try FileManager.default.removeItem(at: directory.url.appendingPathComponent("Weather.app/icon.png"))
        try GradleProject(directory: url, hostPackage: host, bundle: try bundle(), abis: [.arm64]).write()
        #expect(!FileManager.default.fileExists(atPath: url.appendingPathComponent("app/src/main/res/mipmap-xxxhdpi").path))
    }

    @Test func refusesUnsignedReleases() throws {
        let project = GradleProject(directory: directory.url, hostPackage: directory.url, bundle: try bundle(), abis: [.arm64])
        let toolchain = Toolchain(androidHome: directory.url, ndk: directory.url, swiftSDKs: directory.url)
        #expect(throws: PackagerError("a release build needs a keystore: pass --keystore and --alias")) {
            try project.build(.bundle, androidSwiftUI: directory.url, toolchain: toolchain, runner: FakeRunner())
        }
    }

    // MARK: Staging and packaging

    /// A toolchain whose Swift SDK and NDK are in the temporary directory.
    func toolchain() -> Toolchain {
        let toolchain = Toolchain(androidHome: directory.url.appendingPathComponent("sdk"),
                                  ndk: directory.url.appendingPathComponent("ndk"),
                                  swiftSDKs: directory.url.appendingPathComponent("swift-sdks"))
        directory.write("", to: "ndk/toolchains/llvm/prebuilt/darwin-x86_64/bin/llvm-readelf")
        for name in ["libswiftCore.so", "libFoundationEssentials.so", "libswift_Concurrency.so"] {
            let runtime = toolchain.swiftRuntime(.arm64).path.dropFirst(directory.url.path.count + 1)
            directory.write(name, to: "\(runtime)/\(name)")
        }
        let cxx = toolchain.libcxx(.arm64).path.dropFirst(directory.url.path.count + 1)
        directory.write("libc++", to: String(cxx))
        return toolchain
    }

    /// Answers `llvm-readelf -d` and `llvm-nm` like the NDK's tools.
    func libraryTools(missing: Bool = false) -> FakeRunner {
        let runner = FakeRunner()
        let needed = [
            "libapp.so": ["libswiftCore.so", "libFoundationEssentials.so", "liblog.so"],
            "libFoundationEssentials.so": ["libswiftCore.so", "libswift_Concurrency.so"],
            "libswiftCore.so": ["libc++_shared.so", "libc.so"],
        ]
        runner.answer = { arguments in
            let file = URL(fileURLWithPath: arguments.last!).lastPathComponent
            if arguments[0].hasSuffix("llvm-readelf") {
                return (needed[file] ?? []).map { " 0x0000000000000001 (NEEDED) Shared library: [\($0)]" }.joined(separator: "\n")
            }
            if arguments.contains("--undefined-only") {
                return file == "libswiftCore.so" ? "                 U _ZNSt6__ndk113__hash_memoryEPKvm\n                 U malloc" : ""
            }
            return missing ? "0000000000001000 T _ZNSt6__ndk14cout" : "0000000000001000 T _ZNSt6__ndk113__hash_memoryEPKvm"
        }
        return runner
    }

    @Test func stagesTheRuntimeTheLibraryNeeds() throws {
        let toolchain = toolchain()
        directory.write("app", to: "build/libapp.so")
        let staged = directory.url.appendingPathComponent("jniLibs/arm64-v8a")
        try toolchain.stage(directory.url.appendingPathComponent("build/libapp.so"), abi: .arm64, into: staged, runner: libraryTools())
        let names = try FileManager.default.contentsOfDirectory(atPath: staged.path).sorted()
        #expect(names == ["libFoundationEssentials.so", "libapp.so", "libc++_shared.so", "libswiftCore.so", "libswift_Concurrency.so"])
    }

    @Test func refusesAnNDKWhoseLibcxxIsTooOld() throws {
        let toolchain = toolchain()
        directory.write("app", to: "build/libapp.so")
        #expect(throws: PackagerError.self) {
            try toolchain.stage(directory.url.appendingPathComponent("build/libapp.so"), abi: .arm64,
                                into: directory.url.appendingPathComponent("jniLibs/arm64-v8a"), runner: libraryTools(missing: true))
        }
    }

    @Test func buildsEachABIWithItsSlice() throws {
        let host = Fixtures.hostPackage(in: directory)
        let url = Fixtures.bundle(in: directory, slices: [.arm64: 183])
        var options = Packager.Options(abis: [.arm64], hostPackage: host, androidSwiftUI: directory.url,
                                       workRoot: directory.url.appendingPathComponent("work"))
        options.output = .debugAPK
        let runner = libraryTools()
        let tools = runner.answer
        let bin = directory.url.appendingPathComponent("bin")
        directory.write("app", to: "bin/libapp.so")
        runner.answer = { (arguments: [String]) throws(PackagerError) -> String in
            if arguments.first == "swift" {
                return arguments.contains("--show-bin-path") ? "Planning…\n\(bin.path)\n" : ""
            }
            return try tools(arguments)
        }
        let packager = Packager(bundle: try UniversalBundle(url: url), options: options, toolchain: toolchain(), runner: runner)
        let (project, diagnostics) = try packager.prepare()
        #expect(diagnostics.allSatisfy { $0.severity == .warning })
        let build = try #require(runner.commands.first { $0.first == "swift" })
        #expect(build.contains("--triple") && build.contains("aarch64-unknown-linux-android28"))
        #expect(build.contains("app") && build.contains("debug"))
        #expect(runner.environments[runner.commands.firstIndex(of: build)!]["ANDROIDAPPRUNTIME_SLICE"]
                == url.appendingPathComponent("lib/android-arm64-v8a/libapp.a").path)
        #expect(FileManager.default.fileExists(atPath: project.jniLibs.appendingPathComponent("arm64-v8a/libswiftCore.so").path))
    }

    @Test func translatesAppWasmForAnABIWithoutASlice() throws {
        let host = Fixtures.hostPackage(in: directory)
        let url = Fixtures.bundle(in: directory, slices: [.arm64: 183], wasm: true)
        var options = Packager.Options(abis: [.x86_64], hostPackage: host, androidSwiftUI: directory.url,
                                       workRoot: directory.url.appendingPathComponent("work"))
        let runner = libraryTools()
        let tools = runner.answer
        let bin = directory.url.appendingPathComponent("bin")
        directory.write("app", to: "bin/libapp.so")
        runner.answer = { (arguments: [String]) throws(PackagerError) -> String in
            if arguments.first == "swift" {
                return arguments.contains("--show-bin-path") ? "\(bin.path)\n" : ""
            }
            return arguments.first?.hasSuffix("llvm-readelf") == true || arguments.contains("--undefined-only")
                || arguments.first?.hasSuffix("llvm-nm") == true ? try tools(arguments) : ""
        }
        var packager = Packager(bundle: try UniversalBundle(url: url), options: options, toolchain: toolchain(), runner: runner)
        #expect(throws: PackagerError.self, "wasm2c needs AppRuntime's shim") {
            try packager.buildLibrary(.x86_64)
        }
        options.appRuntime = directory.url.appendingPathComponent("AppRuntime")
        packager.options = options
        var wasm2c = Wasm2c(appRuntime: options.appRuntime!, toolchain: packager.toolchain)
        wasm2c.wabt = .init(wasm2c: URL(fileURLWithPath: "/wabt/bin/wasm2c"), runtime: URL(fileURLWithPath: "/wabt/share/wabt/wasm2c"),
                            include: URL(fileURLWithPath: "/wabt/include"))
        let work = directory.url.appendingPathComponent("work/wasm2c")
        let archive = try wasm2c.build(try #require(packager.bundle.wasm), abi: .x86_64, in: work, runner: runner)
        #expect(archive == work.appendingPathComponent("libapp.a"))
        let tools0 = runner.commands.map { URL(fileURLWithPath: $0[0]).lastPathComponent }
        #expect(tools0 == ["wasm2c", "python3", "clang", "clang", "clang", "clang", "ld.lld", "llvm-objcopy", "llvm-ar"])
        let compile = try #require(runner.commands.first { $0[0].hasSuffix("clang") })
        #expect(compile.contains("--target=x86_64-linux-android28"))
        #expect(compile.contains("-DWASM_RT_SKIP_SIGNAL_RECOVERY=1"))
        #expect(compile.contains("/wabt/include"))
        let objcopy = try #require(runner.commands.first { $0[0].hasSuffix("llvm-objcopy") })
        #expect(objcopy.filter { $0.hasPrefix("--keep-global-symbol=") }.count == 3)
        #expect(objcopy.contains { $0.hasPrefix("--add-section=.rt_abi=") })
        #expect(objcopy.contains { $0.hasPrefix("--add-section=.rt_contracts=") })
        #expect(!objcopy.contains { $0.hasPrefix("--add-section=.rt_manifest=") }, "the module has no manifest section")
        #expect(AndroidABI.armv7.clangTarget == "armv7a-linux-androideabi28")
    }

    @Test func compilesTheGLShimForAModuleThatDraws() throws {
        let module = Fixtures.wasm(sections: ["rt.abi": [1, 0, 0, 0]],
                                   imports: [("rt", "rt_call"), ("env.gl", "glClear"), ("env.gl", "glViewport")])
        #expect(WasmModule.imports(module).map { "\($0.module).\($0.name)" } == ["rt.rt_call", "env.gl.glClear", "env.gl.glViewport"])
        #expect(WasmModule.customSections(module).keys.sorted() == ["rt.abi"])
        let wasm = directory.url.appendingPathComponent("App.wasm")
        try module.write(to: wasm)
        let runner = FakeRunner()
        let appRuntime = directory.url.appendingPathComponent("AppRuntime")
        var wasm2c = Wasm2c(appRuntime: appRuntime, toolchain: toolchain())
        wasm2c.wabt = .init(wasm2c: URL(fileURLWithPath: "/wabt/bin/wasm2c"), runtime: URL(fileURLWithPath: "/wabt/share/wabt/wasm2c"))
        _ = try wasm2c.build(wasm, abi: .arm64, in: directory.url.appendingPathComponent("work"), runner: runner)
        let compiles = runner.commands.filter { $0[0].hasSuffix("clang") }
        #expect(compiles.count == 5)
        #expect(compiles.allSatisfy { $0.contains("-DRT_GL_DIRECT") && $0.contains(appRuntime.appendingPathComponent("Sources/CGLES2/include").path) })
        #expect(compiles.last?.contains(appRuntime.appendingPathComponent("Sources/CRuntimeGL/gl_shim.c").path) == true)
        // A module that doesn't draw doesn't get it.
        try Fixtures.wasm(sections: [:], imports: [("rt", "rt_call")]).write(to: wasm)
        let plain = FakeRunner()
        _ = try wasm2c.build(wasm, abi: .arm64, in: directory.url.appendingPathComponent("plain"), runner: plain)
        #expect(plain.commands.filter { $0[0].hasSuffix("clang") }.count == 4)
        #expect(!plain.commands.joined().contains("-DRT_GL_DIRECT"))
    }

    @Test func refusesToPackageWhatFailsValidation() throws {
        let host = Fixtures.hostPackage(in: directory)
        let url = Fixtures.bundle(in: directory, info: Fixtures.info(["CFBundleVersion": "beta"]))
        let options = Packager.Options(abis: [.arm64], hostPackage: host, androidSwiftUI: directory.url,
                                       workRoot: directory.url.appendingPathComponent("work"))
        let runner = FakeRunner()
        let packager = Packager(bundle: try UniversalBundle(url: url), options: options, toolchain: toolchain(), runner: runner)
        #expect(throws: PackagerError.self) {
            try packager.package()
        }
        #expect(runner.commands.isEmpty)
    }

    @Test func runsOnAnEmulatorUnlessToldOtherwise() throws {
        let runner = FakeRunner()
        runner.answer = { _ in "List of devices attached\nR58M123ABC\tdevice\nemulator-5556\toffline\nemulator-5554\tdevice\n" }
        let options = Packager.Options(abis: [.arm64], hostPackage: directory.url, androidSwiftUI: directory.url)
        let packager = Packager(bundle: try bundle(), options: options, toolchain: toolchain(), runner: runner)
        #expect(try packager.emulator() == "emulator-5554")
        runner.answer = { _ in "List of devices attached\nR58M123ABC\tdevice\n" }
        #expect(throws: PackagerError.self) {
            try packager.emulator()
        }
    }

    @Test func explainsAnInstallSignedWithAnotherKey() throws {
        let host = Fixtures.hostPackage(in: directory)
        let url = Fixtures.bundle(in: directory)
        let runner = libraryTools()
        let tools = runner.answer
        let bin = directory.url.appendingPathComponent("bin")
        directory.write("app", to: "bin/libapp.so")
        runner.answer = { (arguments: [String]) throws(PackagerError) -> String in
            switch arguments.first {
            case "swift": return arguments.contains("--show-bin-path") ? bin.path : ""
            case let tool? where tool.hasSuffix("gradlew"):
                self.directory.write("apk", to: "work/org.example.Weather/gradle/\(GradleProject.Output.debugAPK.path)")
                return ""
            case let tool? where tool.hasSuffix("adb") && arguments.contains("install"):
                throw PackagerError("Failure [INSTALL_FAILED_UPDATE_INCOMPATIBLE: signatures do not match]")
            case let tool? where tool.hasSuffix("adb"):
                return ""
            default: return try tools(arguments)
            }
        }
        let options = Packager.Options(abis: [.arm64], hostPackage: host, androidSwiftUI: directory.url,
                                       workRoot: directory.url.appendingPathComponent("work"))
        let packager = Packager(bundle: try UniversalBundle(url: url), options: options, toolchain: toolchain(), runner: runner)
        #expect(throws: PackagerError.self) {
            try packager.run(serial: "emulator-5554")
        }
        #expect(!runner.commands.contains { $0.contains("uninstall") })
        #expect(throws: PackagerError.self) {
            try packager.run(serial: "emulator-5554", replace: true)
        }
        #expect(runner.commands.contains { $0.suffix(2) == ["uninstall", "org.example.Weather"] })
    }

    @Test func parsesTheNDKToolsOutput() {
        let dynamic = """
            Dynamic section at offset 0x1000 contains 3 entries:
              Tag                Type     Name/Value
              0x0000000000000001 (NEEDED) Shared library: [libswiftCore.so]
              0x000000000000000e (SONAME) Library soname: [libapp.so]
            """
        #expect(Toolchain.neededLibraries(dynamic) == ["libswiftCore.so"])
        #expect(Toolchain.symbols("                 U malloc\n0000000000001000 T main") == ["malloc", "main"])
    }
}
