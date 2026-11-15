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
        if !services.isEmpty {
            add(Permission("android.permission.FOREGROUND_SERVICE"))
        }
        if services.contains("location") {
            add(Permission("android.permission.FOREGROUND_SERVICE_LOCATION"))
        }
        if services.contains("connectedDevice") {
            add(Permission("android.permission.FOREGROUND_SERVICE_CONNECTED_DEVICE"))
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
                        </intent-filter>
                    </activity>\(service)
                </application>
            </manifest>
            """)
        return lines.joined(separator: "\n") + "\n"
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
