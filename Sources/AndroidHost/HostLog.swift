import CAndroidHost
#if canImport(Android)
import Android
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// The host's messages: logcat on Android (tag `AppRuntime`), standard error
/// elsewhere.
public enum HostLog {

    /// Whether `debug` messages are written.
    nonisolated(unsafe) public static var verbose = false

    /// The messages written, while it isn't `nil`; for tests.
    nonisolated(unsafe) public static var recorded: [String]?

    public static func debug(_ message: @autoclosure () -> String) {
        if verbose {
            write(3, "debug", message())
        }
    }

    public static func info(_ message: String) {
        write(4, "info", message)
    }

    public static func warning(_ message: String) {
        write(5, "warning", message)
    }

    public static func error(_ message: String) {
        write(6, "error", message)
    }

    /// `priority` is an `android_LogPriority`.
    private static func write(_ priority: Int32, _ level: String, _ message: String) {
        recorded?.append("\(level): \(message)")
        #if os(Android)
        _ = __android_log_write(priority, "AppRuntime", message)
        #else
        fputs("android-app-host: \(level): \(message)\n", stderr)
        #endif
    }
}
