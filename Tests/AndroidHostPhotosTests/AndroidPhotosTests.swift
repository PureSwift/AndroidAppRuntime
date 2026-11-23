import Testing
import AndroidHost
import DynamicPhotos
import DynamicRuntime
import RuntimePhotos
@testable import AndroidHostPhotos

/// The Kotlin side's `MediaStore`, in memory: assets as their seven
/// strings, newest first, with the calls the store made.
final class ScriptedMedia: PhotoSystem, @unchecked Sendable {

    var assets: [[String]] = [
        ["image/3", "1", "3000", "4000", "3000", "0", "1"],
        ["video/2", "2", "2000", "1920", "1080", "12500", "0"],
        ["image/1", "1", "1000", "640", "480", "0", "0"],
    ]

    /// Bucket of each asset.
    var buckets: [String: String] = ["image/3": "10", "video/2": "20", "image/1": "10"]

    var calls: [String] = []

    /// The error every reading call leaves; 0 for none.
    var failing: Int32 = 0

    func error() -> Int32 { failing }

    func identifiers(_ kind: Int32, album: String) -> [String] {
        calls.append("identifiers \(kind) \(album)")
        return assets.filter { (kind == 0 || $0[1] == String(kind)) && (album.isEmpty || buckets[$0[0]] == album) }.map { $0[0] }
    }

    func assets(_ identifiers: [String]) -> [String] {
        calls.append("assets \(identifiers)")
        // In the provider's order, not the fetch's.
        return assets.filter { identifiers.contains($0[0]) }.reversed().flatMap { $0 }
    }

    func albums() -> [String] {
        ["10", "Camera", "2", "1", "20", "Movies", "1", "1"]
    }

    func add(_ path: String, kind: Int32) -> [String] {
        calls.append("add \(path) \(kind)")
        return ["image/4", "1", "4000", "10", "20", "0", "0"]
    }

    func original(_ identifier: String) -> [String] {
        calls.append("original \(identifier)")
        return ["/cache/photo-originals/x/IMG_1.jpg", "image/jpeg", "IMG_1.jpg"]
    }

    func release(_ path: String) {
        calls.append("release \(path)")
    }

    var deletions: [(identifiers: [String], request: Int32)] = []

    func delete(_ identifiers: [String], request: Int32) {
        deletions.append((identifiers, request))
    }

    var observing = 0

    func observe() {
        observing += 1
    }
}

final class Permissions: PermissionSystem {

    var apiLevel: Int32 = 34
    var granted: Set<String> = []
    var requested: Set<String> = []
    var requests: [(permissions: [String], id: Int32)] = []

    func isGranted(_ permission: String) -> Bool { granted.contains(permission) }
    func wasRequested(_ permission: String) -> Bool { requested.contains(permission) }
    func isDeclared(_ permission: String) -> Bool { true }
    func hasFeature(_ feature: String) -> Bool { true }

    func request(_ permissions: [String], id: Int32) -> Bool {
        requests.append((permissions, id))
        requested.formUnion(permissions)
        return true
    }
}

/// What the guest hears.
final class Answer: PhotoCallback, PhotosDelegate {

    var events: [String] = []

    var results: (any PhotoResults)?

    func didComplete() { events.append("complete") }
    func didChangeAccess(_ access: Int32) { events.append("access \(access)") }
    func didAdd(_ fields: [String]) { events.append("added \(fields.first ?? "nothing")") }

    func didFetch(_ results: any PhotoResults) {
        self.results = results
        events.append("fetched \(results.count())")
    }

    func didListAssets(_ fields: [String]) { events.append("assets \(PhotoAsset.assets(fields).map(\.id))") }
    func didFindAsset(_ fields: [String]) { events.append("found \(fields.first ?? "nothing")") }

    func didListAlbums(_ fields: [String]) {
        events.append("albums \(stride(from: 1, to: fields.count, by: 4).map { fields[$0] })")
    }

    func didOpenFile(_ file: any PhotoFileGrant) { events.append("file \(file.name())") }
    func didFail(_ error: Int32) { events.append("fail \(error)") }
    func didChange() { events.append("changed") }
}

/// `HostPhotos` over `AndroidPhotoStore`, over a scripted `MediaStore`,
/// and Android's permissions as access. Serialized: the contract and the
/// permissions are global.
@Suite(.serialized) final class AndroidPhotosTests {

    let media = ScriptedMedia()

    let permissions = Permissions()

    let answer = Answer()

    var photos: HostPhotos { HostPhotos.shared() }

    init() {
        HostPhotos.reset()
        AndroidHostPhotos.reset()
        AndroidPermissions.reset()
        AndroidPermissions.system = permissions
    }

    deinit {
        HostPhotos.reset()
        AndroidHostPhotos.reset()
        AndroidPermissions.reset()
        AndroidPermissions.system = nil
    }

    func configure(allowsReading: Bool = true) {
        AndroidHostPhotos.configure(media, allowsReading: allowsReading)
        HostPhotos.work = { $0() }
        HostPhotos.deliver = { $0() }
    }

    func grant(_ permissions: String...) {
        self.permissions.granted.formUnion(permissions)
        self.permissions.requested.formUnion(permissions)
    }

    @Test func accessIsAndroidsMediaPermissions() {
        let all = [AndroidHostPhotos.readImages, AndroidHostPhotos.readVideo]
        func access(_ allowsReading: Bool = true) -> PhotoLibraryAccess {
            AndroidHostPhotos.access(allowsReading: allowsReading, system: permissions)
        }
        // Adding needs no leave; reading hasn't been asked for.
        #expect(access() == .addOnly)
        #expect(access(false) == .addOnly)
        // Android 14's choice of some photos.
        grant(AndroidHostPhotos.readSelected)
        #expect(access() == .limited)
        grant(AndroidHostPhotos.readImages, AndroidHostPhotos.readVideo)
        #expect(access() == .authorized)
        // Refused.
        permissions.granted = []
        #expect(access() == .denied)
        // Android 13 has no partial access; before it, storage.
        permissions.apiLevel = 33
        permissions.requested = []
        #expect(AndroidHostPhotos.readPermissions(api: 33).all == all)
        #expect(AndroidHostPhotos.readPermissions(api: 33).chosen == nil)
        #expect(AndroidHostPhotos.readPermissions(api: 32).all == [AndroidHostPhotos.readStorage])
        // Android 9 needs leave to add too.
        permissions.apiLevel = 28
        #expect(access(false) == .notDetermined)
        grant(AndroidHostPhotos.writeStorage)
        #expect(access(false) == .addOnly)
        #expect(access() == .addOnly)
    }

    @Test func asksForWhatTheManifestDeclares() {
        configure()
        #expect(photos.access() == PhotoLibraryAccess.addOnly.rawValue)
        photos.requestAccess(answer)
        let request = permissions.requests.last
        #expect(request?.permissions == [AndroidHostPhotos.readImages, AndroidHostPhotos.readVideo, AndroidHostPhotos.readSelected])
        permissions.granted = [AndroidHostPhotos.readSelected]
        AndroidPermissions.didRequest(id: request?.id ?? 0, permissions: request?.permissions ?? [], granted: [false, false, true])
        #expect(answer.events == ["access \(PhotoLibraryAccess.limited.rawValue)"])
        // Reading is allowed: the library is watched, once.
        #expect(media.observing == 1)
        AndroidHostPhotos.refresh()
        #expect(media.observing == 1)
    }

    @Test func anAppThatOnlyAddsIsAskedNothing() {
        configure(allowsReading: false)
        photos.requestAccess(answer)
        #expect(permissions.requests.isEmpty)
        #expect(answer.events == ["access \(PhotoLibraryAccess.addOnly.rawValue)"])
        #expect(media.observing == 0)
    }

    @Test func fetchesNewestFirstAPageAtATime() {
        grant(AndroidHostPhotos.readImages, AndroidHostPhotos.readVideo)
        configure()
        photos.fetch(0, album: "", callback: answer)
        #expect(answer.events == ["fetched 3"])
        answer.results?.assets(0, count: 2, callback: answer)
        // The fetch's order, whatever order the provider gives.
        #expect(answer.events.last == "assets [\"image/3\", \"video/2\"]")
        #expect(media.calls == ["identifiers 0 ", "assets [\"image/3\", \"video/2\"]"])
        photos.fetch(PhotoKind.image.rawValue, album: "10", callback: answer)
        #expect(answer.events.last == "fetched 2")
        #expect(media.calls.last == "identifiers 1 10")
    }

    @Test func anAssetCrossesWithItsFields() throws {
        let store = AndroidPhotoStore(system: media)
        let video = try #require(try store.assets(withIDs: ["video/2"]).first)
        #expect(video == PhotoAsset(id: "video/2", kind: .video, creationDate: 2000, width: 1920, height: 1080, duration: 12.5))
        let image = try #require(try store.assets(withIDs: ["image/3"]).first)
        #expect(image.isFavorite)
        #expect(try store.assets(withIDs: []) == [])
        #expect(try store.add(fileAt: "/data/shot.jpg", kind: .image).id == "image/4")
        #expect(media.calls.last == "add /data/shot.jpg 1")
    }

    @Test func listsAlbumsAsBuckets() throws {
        let albums = try AndroidPhotoStore(system: media).albums()
        #expect(albums == [PhotoAlbum(id: "10", title: "Camera", count: 2, kind: .user),
                           PhotoAlbum(id: "20", title: "Movies", count: 1, kind: .user)])
    }

    @Test func anOriginalIsACopyRemovedWhenReleased() throws {
        let store = AndroidPhotoStore(system: media)
        let original = try store.original(of: "image/1")
        #expect(original == HostPhotoOriginal(path: "/cache/photo-originals/x/IMG_1.jpg", contentType: "image/jpeg", name: "IMG_1.jpg"))
        store.release(original)
        #expect(media.calls.last == "release /cache/photo-originals/x/IMG_1.jpg")
    }

    @Test func androidsErrorsAreTheContracts() {
        let store = AndroidPhotoStore(system: media)
        media.failing = PhotoLibraryError.notFound.rawValue
        #expect(throws: PhotoLibraryError.notFound) { try store.identifiers(of: nil, in: "99") }
        media.failing = PhotoLibraryError.notAuthorized.rawValue
        #expect(throws: PhotoLibraryError.notAuthorized) { try store.albums() }
        // Unknown, which can't be 0.
        media.failing = -1
        #expect(throws: PhotoLibraryError.unknown) { try store.original(of: "image/1") }
    }

    @Test func deletesThroughTheSystemsQuestion() {
        grant(AndroidHostPhotos.readImages, AndroidHostPhotos.readVideo)
        configure()
        photos.delete(["image/1", "video/2"], callback: answer)
        let deletion = media.deletions.last
        #expect(deletion?.identifiers == ["image/1", "video/2"])
        #expect(answer.events.isEmpty)
        PhotoHub.shared.deleted(deletion?.request ?? 0, error: 0)
        #expect(answer.events.first == "complete")
        // Refused.
        photos.delete(["image/3"], callback: answer)
        PhotoHub.shared.deleted(media.deletions.last?.request ?? 0, error: PhotoLibraryError.cancelledByUser.rawValue)
        #expect(answer.events.contains("fail \(PhotoLibraryError.cancelledByUser.rawValue)"))
        // An answer for nothing goes nowhere.
        PhotoHub.shared.deleted(999, error: 0)
    }

    @Test func aChangeReachesTheGuest() {
        grant(AndroidHostPhotos.readImages, AndroidHostPhotos.readVideo)
        configure()
        photos.setDelegate(answer)
        PhotoHub.shared.changed()
        #expect(answer.events == ["changed"])
    }
}
