import CAndroidHost
import DynamicFiles

#if os(Android)
/// The APK's assets through the NDK's `AAssetManager`, which any thread may
/// use. Whoever makes it keeps the Java `AssetManager` it came from.
public struct NDKAssets: AssetReader, @unchecked Sendable {

    /// The native `AAssetManager *`.
    let manager: UnsafeMutableRawPointer

    /// From `candroid_assets_from_java`.
    public init(manager: UnsafeMutableRawPointer) {
        self.manager = manager
    }

    public func length(_ path: String) -> Int64? {
        let length = candroid_asset_length(manager, path)
        return length < 0 ? nil : length
    }

    public func read(_ path: String, offset: Int64, length: Int64) throws(FileError) -> [UInt8]? {
        guard length > 0 else {
            return self.length(path) == nil ? nil : []
        }
        var bytes = [UInt8](repeating: 0, count: Int(length))
        let count = bytes.withUnsafeMutableBytes { buffer in
            candroid_asset_read(manager, path, offset, buffer.baseAddress, length)
        }
        switch count {
        case -1:
            return nil
        case ..<0:
            throw .unknown
        default:
            bytes.removeSubrange(Int(count)...)
            return bytes
        }
    }
}
#endif
