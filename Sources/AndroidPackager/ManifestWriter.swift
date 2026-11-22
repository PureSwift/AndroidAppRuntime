import RuntimeABI

/// The app's `AndroidManifest.xml` and string resources (`Plan.md` §8.3,
/// §8.4). The package, versions and SDK levels go in the Gradle build, which
/// merges them in.
public struct ManifestWriter {

    public var bundle: UniversalBundle

    /// Whether the APK has a native arm64 slice, which needs heap pointer
    /// tagging off (`Plan.md` §9.1). wasm2c's code doesn't.
    public var hasNativeARM64Slice = true

    public init(bundle: UniversalBundle) {
        self.bundle = bundle
    }

    // MARK: Background work

    /// `foregroundServiceType`s the host's service needs: `location` for
    /// `location(.always)`, `connectedDevice` for Bluetooth with the
    /// `background` option.
    public var foregroundServiceTypes: [String] {
        let capabilities = Set(bundle.info.capabilities.map(\.rawValue))
        var types: [String] = []
        if capabilities.contains("location"), bundle.capabilityOptions["location"]?["access"] == "always" {
            types.append("location")
        }
        if capabilities.contains("bluetooth"), bundle.capabilityOptions["bluetooth"]?["background"] == "true" {
            types.append("connectedDevice")
        }
        return types
    }

    /// Whether the app plays on in the background: `.audio(background:
    /// true)`. The now-playing service is then in the foreground while it
    /// plays (Plan.md §6.13).
    public var playsInBackground: Bool {
        bundle.info.capabilities.contains { $0.rawValue == "audio" } && bundle.capabilityOptions["audio"]?["background"] == "true"
    }

    // MARK: Permissions

    /// A `<uses-permission>`.
    public struct Permission: Equatable, Sendable {
        public var name: String
        /// The highest API it applies to.
        public var maxSDK: Int?
        /// `android:usesPermissionFlags`.
        public var flags: String?

        init(_ name: String, maxSDK: Int? = nil, flags: String? = nil) {
            self.name = name
            self.maxSDK = maxSDK
            self.flags = flags
        }
    }

    /// A `<uses-feature>`.
    public struct Feature: Equatable, Sendable {
        public var name: String
        public var required: Bool
    }

    /// The runtime and install-time permissions for the app's capabilities
    /// (§6.1), each once.
    public var permissions: [Permission] {
        let capabilities = Set(bundle.info.capabilities.map(\.rawValue))
        var permissions: [Permission] = []
        func add(_ permission: Permission) {
            if !permissions.contains(where: { $0.name == permission.name }) {
                permissions.append(permission)
            }
        }
        if capabilities.contains("location") {
            add(Permission("android.permission.ACCESS_FINE_LOCATION"))
            add(Permission("android.permission.ACCESS_COARSE_LOCATION"))
            if bundle.capabilityOptions["location"]?["access"] == "always" {
                add(Permission("android.permission.ACCESS_BACKGROUND_LOCATION"))
            }
        }
        if capabilities.contains("bluetooth") {
            add(Permission("android.permission.BLUETOOTH_SCAN", flags: "neverForLocation"))
            add(Permission("android.permission.BLUETOOTH_CONNECT"))
            // API 28–30: the legacy permissions, and location to scan.
            add(Permission("android.permission.BLUETOOTH", maxSDK: 30))
            add(Permission("android.permission.BLUETOOTH_ADMIN", maxSDK: 30))
            add(Permission("android.permission.ACCESS_FINE_LOCATION", maxSDK: 30))
        }
        if capabilities.contains("motion") {
            add(Permission("android.permission.ACTIVITY_RECOGNITION"))
        }
        if capabilities.contains("notifications") {
            add(Permission("android.permission.POST_NOTIFICATIONS"))
            // Scheduled notifications are set again after a restart.
            add(Permission("android.permission.RECEIVE_BOOT_COMPLETED"))
            if bundle.capabilityOptions["notifications"]?["exactTiming"] == "true" {
                // The user's setting, from Android 12: requestExactTiming opens it.
                add(Permission("android.permission.SCHEDULE_EXACT_ALARM"))
            }
        }
        if capabilities.contains("camera") {
            add(Permission("android.permission.CAMERA"))
        }
        if capabilities.contains("nfc") {
            add(Permission("android.permission.NFC"))
        }
        if capabilities.contains("network") || capabilities.contains("localNetwork") {
            add(Permission("android.permission.INTERNET"))
            add(Permission("android.permission.ACCESS_NETWORK_STATE"))
        }
        let services = foregroundServiceTypes
        if !services.isEmpty || playsInBackground {
            add(Permission("android.permission.FOREGROUND_SERVICE"))
        }
        if services.contains("location") {
            add(Permission("android.permission.FOREGROUND_SERVICE_LOCATION"))
        }
        if services.contains("connectedDevice") {
            add(Permission("android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"))
        }
        if playsInBackground {
            add(Permission("android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"))
        }
        return permissions
    }

    /// Hardware the app uses; required only for a capability marked
    /// `.required()`, so stores still offer the app to devices without it.
    public var features: [Feature] {
        let names: [(capability: String, feature: String)] = [
            ("bluetooth", "android.hardware.bluetooth_le"),
            ("location", "android.hardware.location"),
            ("camera", "android.hardware.camera"),
            ("nfc", "android.hardware.nfc"),
        ]
        let capabilities = Set(bundle.info.capabilities.map(\.rawValue))
        return names.filter { capabilities.contains($0.capability) }.map {
            Feature(name: $0.feature, required: bundle.capabilityOptions[$0.capability]?["required"] == "true")
        }
    }

    /// The GLES version `<uses-feature android:glEsVersion>` requires for the
    /// `graphics` capability (DynamicRuntime.md §8.3): 2.0, or 3.0 for
    /// `.graphics(.gles3)`. Every device has 2.0, so it's always required.
    public var glESVersion: String? {
        guard bundle.info.capabilities.contains(where: { $0.rawValue == "graphics" }) else { return nil }
        return bundle.capabilityOptions["graphics"]?["api"] == "gles3" ? "0x00030000" : "0x00020000"
    }

    // MARK: The manifest

    /// `AndroidManifest.xml`: permissions, features, the app's extra XML, and
    /// the shell's Application and Activity.
    public var manifest: String {
        var lines = [
            #"<?xml version="1.0" encoding="utf-8"?>"#,
            "<!-- Generated by android-app for \(Self.escape(bundle.info.identifier)). -->",
            #"<manifest xmlns:android="http://schemas.android.com/apk/res/android">"#,
        ]
        for permission in permissions {
            var line = #"    <uses-permission android:name="\#(permission.name)""#
            if let flags = permission.flags {
                line += #" android:usesPermissionFlags="\#(flags)""#
            }
            if let maxSDK = permission.maxSDK {
                line += #" android:maxSdkVersion="\#(maxSDK)""#
            }
            lines.append(line + " />")
        }
        for feature in features {
            lines.append(#"    <uses-feature android:name="\#(feature.name)" android:required="\#(feature.required)" />"#)
        }
        if let glESVersion {
            lines.append(#"    <uses-feature android:glEsVersion="\#(glESVersion)" android:required="true" />"#)
        }
        if let extra = bundle.extraManifest, !extra.isEmpty {
            lines.append("    <!-- The app's android.extraManifest. -->")
            lines += extra.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }
        }
        let icon = bundle.icon != nil ? "\n        android:icon=\"@mipmap/ic_launcher\"" : ""
        let tagging = hasNativeARM64Slice ? """

                <!--
                    allowNativeHeapPointerTagging: the arm64 slice's Embedded stdlib
                    keeps String's flags in a pointer's top byte, where Android 11+
                    tags heap pointers (AndroidAppRuntime's Plan.md §9.1).
                -->
            """ : "\n"
        var service = ""
        let types = foregroundServiceTypes
        if !types.isEmpty {
            service = """

                    <!-- Keeps background location and Bluetooth going (Plan.md §6.2). -->
                    <service
                        android:name="org.pureswift.appruntime.contracts.HostService"
                        android:exported="false"
                        android:foregroundServiceType="\(types.joined(separator: "|"))" />
            """
        }
        lines.append("""
            \(tagging)
                <application
                    android:name="org.pureswift.appruntime.AppRuntimeApplication"
                    android:label="@string/app_name"\(icon)
                    android:extractNativeLibs="false"
                    android:allowNativeHeapPointerTagging="\(hasNativeARM64Slice ? "false" : "true")"
                    android:theme="@android:style/Theme.DeviceDefault.NoActionBar">

                    <activity
                        android:name="org.pureswift.appruntime.AppRuntimeActivity"
                        android:exported="true"
                        android:launchMode="singleTask"
                        android:windowSoftInputMode="adjustResize"
                        android:configChanges="orientation|screenSize|screenLayout|smallestScreenSize|keyboard|keyboardHidden|navigation|uiMode|locale|layoutDirection|density|fontScale">
                        <intent-filter>
                            <action android:name="android.intent.action.MAIN" />
                            <category android:name="android.intent.category.LAUNCHER" />
                        </intent-filter>\(documentFilters)
                    </activity>\(service)\(nowPlayingService)\(notificationReceiver)\(authenticationRedirect)
                </application>
            </manifest>
            """)
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: Now playing

    /// For an app that plays in the background, the contracts module's
    /// now-playing service, with the type it needs to be in the foreground
    /// while it plays; the manifest merger adds it to the module's.
    var nowPlayingService: String {
        guard playsInBackground else { return "" }
        return """

                <!-- Plays on in the background (Plan.md §6.13). -->
                <service
                    android:name="org.pureswift.appruntime.contracts.NowPlayingService"
                    android:foregroundServiceType="mediaPlayback" />
        """
    }

    // MARK: Sign-in

    /// The activity a sign-in's redirect opens: one intent filter for each
    /// of the app's schemes (Plan.md §6.12).
    var authenticationRedirect: String {
        guard !bundle.authenticationSchemes.isEmpty else { return "" }
        var lines = [
            "",
            "",
            "        <!-- Catches a sign-in's redirect, and hands it to the app (Plan.md §6.12). -->",
            "        <activity",
            #"            android:name="org.pureswift.appruntime.contracts.AuthenticationRedirectActivity""#,
            #"            android:exported="true""#,
            #"            android:excludeFromRecents="true""#,
            #"            android:theme="@android:style/Theme.Translucent.NoTitleBar">"#,
        ]
        for scheme in bundle.authenticationSchemes {
            lines += [
                "            <intent-filter>",
                #"                <action android:name="android.intent.action.VIEW" />"#,
                #"                <category android:name="android.intent.category.DEFAULT" />"#,
                #"                <category android:name="android.intent.category.BROWSABLE" />"#,
                #"                <data android:scheme="\#(Self.escape(scheme))" />"#,
                "            </intent-filter>",
            ]
        }
        lines.append("        </activity>")
        return lines.joined(separator: "\n")
    }

    // MARK: Notifications

    /// The receiver for scheduled notifications' alarms, and for setting
    /// them again after a restart, an update, or a change of the clock.
    var notificationReceiver: String {
        guard bundle.info.capabilities.contains(where: { $0.rawValue == "notifications" }) else { return "" }
        return """

                <!-- Posts scheduled notifications with the app closed (Plan.md §6.9). -->
                <receiver
                    android:name="org.pureswift.appruntime.contracts.NotificationReceiver"
                    android:exported="false">
                    <intent-filter>
                        <action android:name="android.intent.action.BOOT_COMPLETED" />
                        <action android:name="android.intent.action.MY_PACKAGE_REPLACED" />
                        <action android:name="android.intent.action.TIME_SET" />
                        <action android:name="android.intent.action.TIMEZONE_CHANGED" />
                    </intent-filter>
                </receiver>
        """
    }

    // MARK: Documents

    /// An `ACTION_VIEW` filter for each document type, with `ACTION_EDIT`
    /// for an editor, by MIME type: Android can't match by extension
    /// reliably, so a type given only by extensions isn't registered
    /// (Documents.md, "The manifest").
    var documentFilters: String {
        var filters = ""
        for type in bundle.documentTypes {
            let mimeTypes = type.types.filter { !$0.hasPrefix(".") && $0.contains("/") }
            guard !mimeTypes.isEmpty else { continue }
            var lines = ["", "            <intent-filter>", #"                <action android:name="android.intent.action.VIEW" />"#]
            if type.isEditor {
                lines.append(#"                <action android:name="android.intent.action.EDIT" />"#)
            }
            lines.append(#"                <category android:name="android.intent.category.DEFAULT" />"#)
            lines.append(#"                <data android:scheme="content" />"#)
            for mimeType in mimeTypes {
                lines.append(#"                <data android:mimeType="\#(Self.escape(mimeType))" />"#)
            }
            lines.append("            </intent-filter>")
            filters += lines.joined(separator: "\n")
        }
        return filters
    }

    // MARK: Strings

    /// `res/<folder>/strings.xml` by folder: the app's name, in `values` and
    /// each language that has its own.
    public var strings: [String: String] {
        var files = ["values": Self.stringsXML(name: bundle.displayName)]
        for (language, name) in bundle.localizedDisplayNames {
            files["values-\(Self.resourceQualifier(language))"] = Self.stringsXML(name: name)
        }
        return files
    }

    static func stringsXML(name: String) -> String {
        """
        <?xml version="1.0" encoding="utf-8"?>
        <resources>
            <string name="app_name">\(escapeString(name))</string>
        </resources>

        """
    }

    /// A BCP 47 tag as a resource qualifier: `es`, `pt-BR` → `pt-rBR`,
    /// `zh-Hans` → `b+zh+Hans`.
    public static func resourceQualifier(_ language: String) -> String {
        let parts = language.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        switch parts.count {
        case 1:
            return parts[0].lowercased()
        case 2 where parts[1].count == 2 && parts[1].allSatisfy(\.isLetter):
            return "\(parts[0].lowercased())-r\(parts[1].uppercased())"
        default:
            return "b+" + parts.joined(separator: "+")
        }
    }

    /// Text for an XML attribute or element.
    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// Text for a string resource, which also treats `'`, `\`, and a
    /// leading `@` or `?` specially.
    static func escapeString(_ text: String) -> String {
        var escaped = escape(text)
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        if escaped.hasPrefix("@") || escaped.hasPrefix("?") {
            escaped = "\\" + escaped
        }
        return escaped
    }
}
