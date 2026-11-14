/// An Android ABI the packager builds for (`Plan.md` §2), and where its
/// pieces are: the bundle's slice, the Swift SDK's triple and runtime, and
/// the NDK's `libc++`.
public enum AndroidABI: String, CaseIterable, Sendable {

    case arm64 = "arm64-v8a"

    case x86_64 = "x86_64"

    /// Its slice exists, but its sealed helpers haven't run on hardware.
    case armv7 = "armeabi-v7a"

    /// The minimum API, which the Swift SDK's triples name.
    public static let minimumAPI = 28

    /// The bundle's target ID: `lib/<target>/libapp.a`.
    public var target: String {
        "android-\(rawValue)"
    }

    /// The Swift SDK's architecture.
    public var arch: String {
        switch self {
        case .arm64: "aarch64"
        case .x86_64: "x86_64"
        case .armv7: "armv7"
        }
    }

    /// `swift build --triple`.
    public var triple: String {
        switch self {
        case .armv7: "armv7-unknown-linux-androideabi\(Self.minimumAPI)"
        default: "\(arch)-unknown-linux-android\(Self.minimumAPI)"
        }
    }

    /// The NDK sysroot's library directory.
    public var ndkTriple: String {
        switch self {
        case .arm64: "aarch64-linux-android"
        case .x86_64: "x86_64-linux-android"
        case .armv7: "arm-linux-androideabi"
        }
    }

    /// The ELF `e_machine` of its objects.
    public var elfMachine: UInt16 {
        switch self {
        case .arm64: 183
        case .x86_64: 62
        case .armv7: 40
        }
    }

    /// Whether it's in the plan's scope (§2); others build with a warning.
    public var isSupported: Bool {
        self != .armv7
    }
}
