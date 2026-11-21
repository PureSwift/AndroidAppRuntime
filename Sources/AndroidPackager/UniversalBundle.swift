import Crypto
import Foundation
import RuntimeHost

/// A universal bundle from AppRuntime's `guest.py bundle`: `Info.plist`,
/// `lib/<target>/libapp.a`, `wasm32/App.wasm`, and optionally `resources/`,
/// `icon.png` and `_CodeSignature/CodeResources`.
///
/// Besides the keys every host reads (`AppInfo`), the packager reads the
/// manifest's Android settings: `RTPlatforms.android`'s `MinSDK` and
/// `TargetSDK`, `RTPlatformExtras.android.extraManifest`, and
/// `RTCapabilityOptions`.
public struct UniversalBundle {

    public let url: URL

    public let info: AppInfo

    /// `CFBundleExecutable`.
    public let executable: String

    /// `CFBundleDisplayName`, `CFBundleName`, or the executable.
    public let displayName: String

    /// The name in each of `CFBundleLocalizations`, by language, from
    /// `resources/<language>.lproj/Manifest.strings` at `RTDisplayNameKey`.
    public let localizedDisplayNames: [String: String]

    /// `RTPlatforms`' platform names, or `nil` for a bundle built without a
    /// manifest.
    public let platforms: Set<String>?

    /// `RTPlatforms.android.MinSDK`.
    public let minSDK: Int?

    /// `RTPlatforms.android.TargetSDK`.
    public let targetSDK: Int?

    /// XML for `AndroidManifest.xml`'s `<manifest>`.
    public let extraManifest: String?

    /// `RTCapabilityOptions`: `required`, location's `access`, ….
    public let capabilityOptions: [String: [String: String]]

    /// `RTDocumentTypes`: the files the app opens.
    public let documentTypes: [DocumentType]

    /// A kind of file the app opens: its MIME types, MIME groups and
    /// extensions, and whether it changes them (`Editor`) or shows them.
    public struct DocumentType: Equatable, Sendable {
        public var types: [String]
        public var isEditor: Bool

        public init(types: [String], isEditor: Bool) {
            self.types = types
            self.isEditor = isEditor
        }
    }

    public init(url: URL) throws(PackagerError) {
        self.url = url.standardizedFileURL
        let plist = url.appendingPathComponent("Info.plist")
        guard let data = FileManager.default.contents(atPath: plist.path) else {
            throw PackagerError("\(url.path) is not a universal bundle: it has no Info.plist")
        }
        guard let dictionary = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw PackagerError("\(plist.path) is not a property list")
        }
        do {
            info = try AppInfo(infoDictionary: dictionary)
        } catch {
            throw PackagerError("\(plist.path): \(error)")
        }
        executable = dictionary["CFBundleExecutable"] as? String ?? ""
        displayName = dictionary["CFBundleDisplayName"] as? String
            ?? dictionary["CFBundleName"] as? String
            ?? executable

        var names: [String: String] = [:]
        if let key = dictionary["RTDisplayNameKey"] as? String {
            for language in dictionary["CFBundleLocalizations"] as? [String] ?? [] {
                let table = url.appendingPathComponent("resources/\(language).lproj/Manifest.strings")
                guard let data = FileManager.default.contents(atPath: table.path),
                      let strings = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: String],
                      let name = strings[key] else { continue }
                names[language] = name
            }
        }
        localizedDisplayNames = names

        let platforms = dictionary["RTPlatforms"] as? [String: [String: Any]]
        self.platforms = platforms.map { Set($0.keys) }
        minSDK = platforms?["android"]?["MinSDK"] as? Int
        targetSDK = platforms?["android"]?["TargetSDK"] as? Int
        let extras = dictionary["RTPlatformExtras"] as? [String: [String: Any]]
        extraManifest = extras?["android"]?["extraManifest"] as? String
        capabilityOptions = dictionary["RTCapabilityOptions"] as? [String: [String: String]] ?? [:]
        documentTypes = (dictionary["RTDocumentTypes"] as? [[String: Any]] ?? []).map {
            DocumentType(types: $0["Types"] as? [String] ?? [], isEditor: $0["Role"] as? String == "editor")
        }
    }

    /// The ABI's sealed slice, if the bundle has one.
    public func slice(_ abi: AndroidABI) -> URL? {
        existing("lib/\(abi.target)/libapp.a")
    }

    /// The ABIs the bundle has slices for.
    public var abis: [AndroidABI] {
        AndroidABI.allCases.filter { slice($0) != nil }
    }

    public var wasm: URL? {
        existing("wasm32/App.wasm")
    }

    /// How `abi`'s library is made: `preferred` when given, otherwise the
    /// slice if there is one, then `App.wasm` through wasm2c. Nil if the
    /// bundle has neither.
    public func engine(for abi: AndroidABI, preferred: Engine? = nil) -> Engine? {
        if let preferred {
            return preferred
        }
        if slice(abi) != nil {
            return .native
        }
        return wasm != nil ? .wasm2c : nil
    }

    /// The ABIs to package when none are asked for: those with slices, or
    /// the tested ones when only `App.wasm` can make them.
    public func defaultABIs(engine: Engine? = nil) -> [AndroidABI] {
        if engine != .wasm2c, !abis.isEmpty {
            return abis
        }
        return wasm != nil ? AndroidABI.allCases.filter(\.isSupported) : abis
    }

    public var icon: URL? {
        existing("icon.png")
    }

    public var resources: URL? {
        existing("resources")
    }

    private func existing(_ path: String) -> URL? {
        let url = url.appendingPathComponent(path)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    // MARK: Integrity

    /// Files whose contents don't match `_CodeSignature/CodeResources`,
    /// files it lists that are missing, and files it doesn't list. Empty
    /// for a bundle without one.
    public func codeResourceProblems() -> [String] {
        let manifest = url.appendingPathComponent("_CodeSignature/CodeResources")
        guard let data = FileManager.default.contents(atPath: manifest.path) else {
            return []
        }
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              let files = plist["files"] as? [String: Data] else {
            return ["_CodeSignature/CodeResources is malformed"]
        }
        var problems: [String] = []
        var listed = Set<String>()
        for (path, digest) in files.sorted(by: { $0.key < $1.key }) {
            listed.insert(path)
            guard let contents = FileManager.default.contents(atPath: url.appendingPathComponent(path).path) else {
                problems.append("\(path) is missing")
                continue
            }
            if Data(SHA256.hash(data: contents)) != digest {
                problems.append("\(path) was modified")
            }
        }
        for path in Self.files(under: url) where !listed.contains(path) && !path.hasPrefix("_CodeSignature/") {
            problems.append("\(path) was added")
        }
        return problems
    }

    /// Every regular file, as a path relative to `root`.
    static func files(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else {
            return []
        }
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        var files: [String] = []
        for case let file as URL in enumerator {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else { continue }
            let path = file.standardizedFileURL.resolvingSymlinksInPath().path
            guard path.hasPrefix(base + "/") else { continue }
            files.append(String(path.dropFirst(base.count + 1)))
        }
        return files.sorted()
    }
}
