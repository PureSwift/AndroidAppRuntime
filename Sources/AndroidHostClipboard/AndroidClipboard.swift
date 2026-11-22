import AndroidHost
import DynamicClipboard
import DynamicRuntime
import RuntimeClipboard
import RuntimeHost

/// What `AndroidClipboardPlatform` asks Android, through the Kotlin
/// `org.pureswift.appruntime.contracts.ClipboardSystem` (`AndroidHostApp`
/// binds it). Main thread only.
public protocol ClipboardSystem: AnyObject {

    /// Bits, 1 text, 2 a URL, 4 an image, from the clip's description.
    func available() -> Int32

    func clear()

    /// Text, with the URL too when `url` isn't empty.
    func writeText(_ text: String, url: String, sensitive: Bool)

    /// An image file, PNG or JPEG: a `PasteboardError`, or 0. `unknown`
    /// comes as -1, since its raw value is 0.
    func writeImage(_ bytes: [UInt8], fileExtension: String, sensitive: Bool) -> Int32

    /// The `PasteboardError` the last read left; 0 for none, and -1 for
    /// `unknown`.
    func readError() -> Int32

    /// The text, or none.
    func readText() -> [String]

    /// The URL, or none.
    func readURL() -> [String]

    /// The image, or empty; its type is `imageType()`.
    func readImage() -> [UInt8]

    func imageType() -> String
}

/// The clipboard on Android (`Plan.md` §6.11): AppRuntime's `HostClipboard`
/// over `ClipboardManager`. A URL is the clip's URI, with its text; an
/// image is a file of the app's cache, shared through a `FileProvider`.
/// Main thread only.
public final class AndroidClipboardPlatform: ClipboardPlatform {

    let system: any ClipboardSystem

    public init(system: any ClipboardSystem) {
        self.system = system
    }

    public func available() -> ClipboardKinds {
        ClipboardKinds(rawValue: system.available())
    }

    public func clear() {
        system.clear()
    }

    public func write(_ content: HostClipboardContent, isSensitive: Bool, completion: @escaping (PasteboardError?) -> Void) {
        switch content {
        case .text(let text, let url):
            system.writeText(text, url: url ?? "", sensitive: isSensitive)
            completion(nil)
        case .image(let data, let type):
            let code = system.writeImage(data, fileExtension: type.fileExtension, sensitive: isSensitive)
            completion(code == 0 ? nil : PasteboardError(rawValue: code) ?? .unknown)
        }
    }

    public func read(_ kind: ClipboardKind, completion: @escaping (Result<HostClipboardContent?, PasteboardError>) -> Void) {
        let content: HostClipboardContent?
        switch kind {
        case .text:
            content = system.readText().first.map { .text($0, url: nil) }
        case .url:
            content = system.readURL().first.map { .text("", url: $0) }
        case .image:
            let data = system.readImage()
            let type = PasteboardImageType(rawValue: system.imageType())
            content = data.isEmpty ? nil : type.map { .image(data, type: $0) }
        }
        let error = system.readError()
        guard error == 0 else {
            completion(.failure(PasteboardError(rawValue: error) ?? .unknown))
            return
        }
        completion(.success(content))
    }
}

/// The clipboard module (`Plan.md` §6.11).
public enum AndroidHostClipboard: HostModule {

    /// Points `HostClipboard` at Android's clipboard. Main thread.
    public static func configure(_ platform: AndroidClipboardPlatform) {
        HostClipboard.platform = platform
        HostClipboard.deliver = { job in MainLooper.shared.post(job) }
    }

    public static var contracts: [ContractDescriptor] {
        HostClipboardModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostClipboardModule.register(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        HostClipboardModule.permissionProviders()
    }
}
