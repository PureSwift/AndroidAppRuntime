import AndroidHost
import DynamicPhotos
import DynamicRuntime
import RuntimeHost
import RuntimePhotos

/// What the photo library asks of `MediaStore` (`Plan.md` §6.18): the
/// Kotlin `PhotoSystem`. Tests use a fake. The reading, adding and
/// originals are called off the main thread, each followed by `error()`
/// on the same thread; deleting and observing on the main thread.
public protocol PhotoSystem: AnyObject {

    /// The last call's error on this thread: a `PhotoLibraryError`, -1 for
    /// `unknown`, 0 for none.
    func error() -> Int32

    /// `kind`: 0 both, 1 image, 2 video. `album` empty: the whole library.
    /// Newest first.
    func identifiers(_ kind: Int32, album: String) -> [String]

    /// Seven strings for each asset still there.
    func assets(_ identifiers: [String]) -> [String]

    /// Four strings for each album.
    func albums() -> [String]

    /// Copies a file in; the new asset's seven strings.
    func add(_ path: String, kind: Int32) -> [String]

    /// The original, copied out: its path, MIME type and name.
    func original(_ identifier: String) -> [String]

    func release(_ path: String)

    /// Answered by `PhotoHub.deleted` with `request`.
    func delete(_ identifiers: [String], request: Int32)

    /// Starts `PhotoHub.changed` reports.
    func observe()
}

/// `HostPhotos`' store over `MediaStore`. Off the main thread, one call at
/// a time, as `HostPhotos` calls it.
public final class AndroidPhotoStore: PhotoStore, @unchecked Sendable {

    let system: any PhotoSystem

    public init(system: any PhotoSystem) {
        self.system = system
    }

    /// The call's answer, or its error.
    private func checked<T>(_ value: T) throws(PhotoLibraryError) -> T {
        let code = system.error()
        guard code == 0 else {
            throw PhotoLibraryError(rawValue: code) ?? .unknown
        }
        return value
    }

    public func add(fileAt path: String, kind: PhotoKind) throws(PhotoLibraryError) -> PhotoAsset {
        let fields = try checked(system.add(path, kind: kind.rawValue))
        guard let asset = PhotoAsset.assets(fields).first else { throw .unknown }
        return asset
    }

    public func identifiers(of kind: PhotoKind?, in album: String?) throws(PhotoLibraryError) -> [String] {
        try checked(system.identifiers(kind?.rawValue ?? 0, album: album ?? ""))
    }

    public func assets(withIDs identifiers: [String]) throws(PhotoLibraryError) -> [PhotoAsset] {
        guard !identifiers.isEmpty else { return [] }
        return PhotoAsset.assets(try checked(system.assets(identifiers)))
    }

    public func albums() throws(PhotoLibraryError) -> [PhotoAlbum] {
        let fields = try checked(system.albums())
        var albums: [PhotoAlbum] = []
        var index = 0
        while index + 4 <= fields.count {
            defer { index += 4 }
            albums.append(PhotoAlbum(id: fields[index], title: fields[index + 1], count: Int(fields[index + 2]) ?? 0,
                                     kind: PhotoAlbum.Kind(rawValue: Int32(fields[index + 3]) ?? 2) ?? .smart))
        }
        return albums
    }

    public func original(of identifier: String) throws(PhotoLibraryError) -> HostPhotoOriginal {
        let fields = try checked(system.original(identifier))
        guard fields.count >= 3 else { throw .unknown }
        return HostPhotoOriginal(path: fields[0], contentType: fields[1], name: fields[2].isEmpty ? nil : fields[2])
    }

    public func release(_ original: HostPhotoOriginal) {
        system.release(original.path)
    }
}

/// What the library reports: the Kotlin side's `PhotoNatives` call these
/// on the main thread. Main thread only.
public final class PhotoHub {

    nonisolated(unsafe) public static let shared = PhotoHub()

    private var deletions: [Int32: (Result<Void, PhotoLibraryError>) -> Void] = [:]

    private var nextDeletion: Int32 = 1

    public init() { }

    /// Asks the system to delete, through its own question where it has one.
    func delete(_ identifiers: [String], system: any PhotoSystem, completion: @escaping (Result<Void, PhotoLibraryError>) -> Void) {
        let request = nextDeletion
        nextDeletion += 1
        deletions[request] = completion
        system.delete(identifiers, request: request)
    }

    /// A deletion is over: 0, or a `PhotoLibraryError` (-1 `unknown`).
    public func deleted(_ request: Int32, error: Int32) {
        guard let completion = deletions.removeValue(forKey: request) else { return }
        completion(error == 0 ? .success(()) : .failure(PhotoLibraryError(rawValue: error) ?? .unknown))
    }

    /// The library changed.
    public func changed() {
        HostPhotos.libraryChanged()
    }
}

/// The photo library contract (`Plan.md` §6.18): AppRuntime's `HostPhotos`
/// over `AndroidPhotoStore`. It needs `.photoLibrary`, `.addOnly` or
/// `.readWrite`; the access is Android's media permissions.
public enum AndroidHostPhotos: HostModule {

    public static let readImages = "android.permission.READ_MEDIA_IMAGES"
    public static let readVideo = "android.permission.READ_MEDIA_VIDEO"
    public static let readSelected = "android.permission.READ_MEDIA_VISUAL_USER_SELECTED"
    public static let readStorage = "android.permission.READ_EXTERNAL_STORAGE"
    public static let writeStorage = "android.permission.WRITE_EXTERNAL_STORAGE"

    /// What reading the whole library needs at `api`, and what the photos
    /// the user chose need: Android 14's partial access.
    public static func readPermissions(api: Int32) -> (all: [String], chosen: String?) {
        if api >= 34 {
            return ([readImages, readVideo], readSelected)
        }
        if api >= 33 {
            return ([readImages, readVideo], nil)
        }
        return ([readStorage], nil)
    }

    /// What adding needs at `api`: nothing from Android 10.
    public static func addPermissions(api: Int32) -> [String] {
        api >= 29 ? [] : [writeStorage]
    }

    /// What the user granted, for an app that reads or only adds.
    public static func access(allowsReading: Bool, system: any PermissionSystem) -> PhotoLibraryAccess {
        let api = system.apiLevel
        let adding = addPermissions(api: api)
        let addOnly: PhotoLibraryAccess? = adding.allSatisfy(system.isGranted) ? .addOnly : nil
        guard allowsReading else {
            if let addOnly { return addOnly }
            return adding.contains(where: system.wasRequested) ? .denied : .notDetermined
        }
        let (all, chosen) = readPermissions(api: api)
        if all.allSatisfy(system.isGranted) {
            return .authorized
        }
        if let chosen, system.isGranted(chosen) {
            return .limited
        }
        if (all + [chosen].compactMap { $0 }).contains(where: system.wasRequested) {
            return .denied
        }
        // Adding needs no leave from Android 10; `requestAccess` still asks
        // to read.
        return addOnly ?? .notDetermined
    }

    nonisolated(unsafe) static var system: (any PhotoSystem)?

    nonisolated(unsafe) private static var observing = false

    /// Points `HostPhotos` at `MediaStore`. `allowsReading`: the manifest
    /// declares `.readWrite`. Main thread.
    public static func configure(_ system: any PhotoSystem, allowsReading: Bool) {
        Self.system = system
        observing = false
        HostPhotos.store = AndroidPhotoStore(system: system)
        HostPhotos.allowsReading = allowsReading
        HostPhotos.deliver = { job in MainLooper.shared.post(job) }
        HostPhotos.requester = { completion in
            guard let permissions = AndroidPermissions.system else {
                completion(HostPhotos.access)
                return
            }
            let api = permissions.apiLevel
            var asked = addPermissions(api: api)
            if HostPhotos.allowsReading {
                let (all, chosen) = readPermissions(api: api)
                asked += all + [chosen].compactMap { $0 }
            }
            guard !asked.isEmpty else {
                refresh()
                completion(HostPhotos.access)
                return
            }
            AndroidPermissions.request(asked) { _ in
                refresh()
                completion(HostPhotos.access)
            }
        }
        HostPhotos.deleter = { identifiers, completion in
            PhotoHub.shared.delete(identifiers, system: system, completion: completion)
        }
        refresh()
    }

    /// What Android says now: when the app starts, after a request, and
    /// when it comes back to the front, since the user may have changed it
    /// in Settings. Main thread.
    public static func refresh() {
        guard let system, let permissions = AndroidPermissions.system else { return }
        HostPhotos.access = access(allowsReading: HostPhotos.allowsReading, system: permissions)
        if HostPhotos.effectiveAccess.allowsReading, !observing {
            observing = true
            system.observe()
        }
    }

    /// Forgets the configuration, for tests.
    static func reset() {
        system = nil
        observing = false
    }

    public static var contracts: [ContractDescriptor] {
        HostPhotosModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostPhotosModule.register(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        HostPhotosModule.permissionProviders()
    }
}
