import AndroidHostFiles
import Foundation

/// The index of the bundle's resources the host lists them from
/// (`assets/rt/resources.index`, `Plan.md` §6.5): the NDK can open an
/// asset, but can't list an asset directory's subdirectories.
public enum ResourceIndex {

    /// What Gradle leaves out of the assets: its default list without
    /// `.*` and `<dir>_*`, so a resource whose name starts with `.` or a
    /// folder whose name starts with `_` is in the APK, as it is in the
    /// bundle on every other host.
    public static let ignoredAssets = "!.svn:!.git:!.ds_store:!*.scc:!CVS:!thumbs.db:!picasa.ini:!*~"

    /// Whether Gradle leaves a file or folder named `name` out, by
    /// `ignoredAssets`. Case doesn't matter, as it doesn't to aapt.
    public static func isIgnored(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return [".svn", ".git", ".ds_store", "cvs", "thumbs.db", "picasa.ini"].contains(lowered)
            || lowered.hasSuffix(".scc") || lowered.hasSuffix("~")
    }

    /// The paths of the files under `resources`, relative to it, without
    /// the ignored ones or what's in an ignored folder.
    public static func files(in resources: URL) -> [String] {
        let root = resources.standardizedFileURL.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else {
            return []
        }
        var files: [String] = []
        for case let url as URL in enumerator {
            let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            if isIgnored(url.lastPathComponent) {
                if isDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard !isDirectory else {
                continue
            }
            let full = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(root.path + "/") else { continue }
            let path = String(full.dropFirst(root.path.count + 1))
            // A name with a line break can't be in the index.
            guard !path.contains("\n"), BundleIndex.isValid(path) else { continue }
            files.append(path)
        }
        return files
    }

    /// The index's text for the files under `resources`, or for none.
    public static func text(for resources: URL?) -> String {
        BundleIndex.text(files: resources.map(files(in:)) ?? [])
    }
}
