import Foundation

/// The bundle's images as Android drawables, so the player's `Image(name)`
/// finds them with Android's own density selection, and composeui applies
/// their modifiers as for any image.
///
/// `resources/**/<name>[@2x|@3x].<png|jpg|jpeg|webp|gif>` becomes
/// `res/drawable-<density>/rt_<name>`: no suffix is 1x (`mdpi`, a point per
/// pixel, as on iOS), `@2x` is `xhdpi` and `@3x` `xxhdpi`. Resource names
/// allow only `[a-z0-9_]`, so the name is lowercased with other characters
/// as `_`; the player's adapter maps `Image` names the same way.
public enum ImageResources {

    public static let extensions: Set<String> = ["png", "jpg", "jpeg", "webp", "gif"]

    /// One image file: its drawable name and density folder.
    public struct Entry: Equatable, Sendable {
        public var source: URL
        public var resource: String
        public var folder: String
    }

    /// The drawable name for an image name, as the adapter computes it.
    public static func resourceName(_ name: String) -> String {
        var base = name
        if let dot = base.lastIndex(of: "."), extensions.contains(base[base.index(after: dot)...].lowercased()) {
            base = String(base[..<dot])
        }
        let safe = base.lowercased().unicodeScalars.map { scalar -> Character in
            switch scalar {
            case "a"..."z", "0"..."9", "_": Character(scalar)
            default: "_"
            }
        }
        return "rt_" + String(safe)
    }

    /// The scale suffix of a file's base name: 1, 2 or 3.
    static func scale(_ base: String) -> (name: String, scale: Int) {
        for scale in [3, 2] where base.hasSuffix("@\(scale)x") {
            return (String(base.dropLast(3)), scale)
        }
        return (base, 1)
    }

    static func folder(scale: Int) -> String {
        switch scale {
        case 3: "drawable-xxhdpi"
        case 2: "drawable-xhdpi"
        default: "drawable-mdpi"
        }
    }

    /// The images under `resources`, and a warning for each name that two
    /// images share once made safe.
    public static func entries(in resources: URL) -> (entries: [Entry], warnings: [String]) {
        let files = FileManager.default
        guard let enumerator = files.enumerator(at: resources, includingPropertiesForKeys: nil) else {
            return ([], [])
        }
        var entries: [Entry] = []
        var warnings: [String] = []
        var claimed: [String: String] = [:]
        let urls = enumerator.compactMap { $0 as? URL }.sorted { $0.path < $1.path }
        for url in urls where extensions.contains(url.pathExtension.lowercased()) {
            // Localized copies (.lproj) stay where the bundle has them.
            if url.pathComponents.contains(where: { $0.hasSuffix(".lproj") }) {
                continue
            }
            let (name, scale) = scale(url.deletingPathExtension().lastPathComponent)
            let resource = resourceName(name)
            let key = "\(resource)/\(scale)"
            if let other = claimed[key] {
                warnings.append("\(url.lastPathComponent) and \(other) are both the drawable \(resource); the first is used")
                continue
            }
            claimed[key] = url.lastPathComponent
            entries.append(Entry(source: url, resource: resource, folder: folder(scale: scale)))
        }
        return (entries, warnings)
    }
}
