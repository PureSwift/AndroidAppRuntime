import DynamicRuntime
import RuntimeHost

/// The built-in `Bundle` contract (`AppBundle` in Swift).
///
/// - The identifier, version and build come from the app's keys, which the
///   shell reads from the APK (`assets/rt/Info.plist`).
/// - `preferredLanguages` is `LocaleList.getDefault()`'s tags, which the
///   shell passes in and updates when the locale changes.
/// - Localized strings come from the bundle's `.lproj` folders in
///   `assets/rt/`, through `resource`. Until the shell reads assets, there
///   are none.
public final class AndroidBundle: AppBundle {

    /// The app's keys. Set before the guest starts.
    nonisolated(unsafe) public static var info = AppInfo(identifier: "", abiVersion: 0)

    /// BCP 47 tags, most preferred first.
    nonisolated(unsafe) public static var languages: [String] = ["en"]

    /// Reads a file of the bundle's resources, such as
    /// `en.lproj/Localizable.strings`; `nil` when there's none.
    nonisolated(unsafe) public static var resource: ((String) -> [UInt8]?)?

    public static func identifier() -> String {
        info.identifier
    }

    public static func version() -> String {
        info.version
    }

    public static func build() -> String {
        info.build
    }

    public static func preferredLanguages() -> [String] {
        languages.isEmpty ? ["en"] : languages
    }

    public static func localizedString(_ key: String, table: String?) -> String? {
        // `.strings` tables need the shell's asset reader (phase 2).
        nil
    }
}
