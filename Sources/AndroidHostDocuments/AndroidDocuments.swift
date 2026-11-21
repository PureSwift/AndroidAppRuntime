import AndroidHost
import AndroidHostFiles
import DynamicDocuments
import DynamicFiles
import DynamicRuntime
import RuntimeHost

/// What `AndroidDocuments` asks Android, through the Kotlin
/// `org.pureswift.appruntime.contracts.DocumentSystem` (`AndroidHostApp`
/// binds it). Main thread only.
public protocol DocumentPickerSystem: AnyObject {

    /// Shows `ACTION_OPEN_DOCUMENT`. Its URIs come back through
    /// `AndroidDocuments.didPick(id:uris:)`. False when there's no Activity
    /// to show it from.
    func pick(id: Int32, types: [String], multiple: Bool, write: Bool) -> Bool

    /// Shows `ACTION_OPEN_DOCUMENT_TREE`. Its folder comes back as the
    /// document at the top of the tree.
    func pickFolder(id: Int32, write: Bool) -> Bool

    /// Shows `ACTION_CREATE_DOCUMENT`, suggesting `name`.
    func export(id: Int32, name: String) -> Bool

    /// Keeps the access to `uri` past this run, and gives its key: empty
    /// when the provider can't keep it, `"-"` when Android keeps no more.
    func remember(uri: String, isDirectory: Bool, write: Bool) -> String

    /// The URI, `"1"` for a folder, and `"1"` for writable, a key was kept
    /// for. Empty for a key that isn't one; only the URI when the access
    /// was taken back.
    func recall(_ key: String) -> [String]

    func forget(_ key: String)
}

/// The `Documents` contract on Android (`Plan.md` §6.8): the Storage
/// Access Framework's pickers, over the app's Activity.
///
/// - What's picked becomes a grant in `DocumentGrants`, which `Files`
///   reaches by content URI for as long as the guest holds it.
/// - One picker at a time; a second is `busy`. With no Activity, a picker
///   is `notAllowed`.
/// - A save picker makes an empty document, and the file is copied into
///   it, on the files queue.
/// - A bookmark is a persisted URI permission, under a key kept in a
///   preferences file of the host's own.
/// - Files the app is opened with wait, ungranted, until the guest
///   listens.
///
/// Main thread only.
public final class AndroidDocuments: Documents {

    nonisolated(unsafe) private static var instance = AndroidDocuments()

    /// The Kotlin side. Without one, every picker is `unsupported`.
    nonisolated(unsafe) public static var system: (any DocumentPickerSystem)?

    /// Runs an answer on the main thread, later.
    nonisolated(unsafe) public static var deliver: (@escaping @Sendable () -> Void) -> Void = { job in
        MainLooper.shared.post(job)
    }

    /// The files whose queue reads providers and copies exports.
    nonisolated(unsafe) public static var files: () -> AndroidFiles = { AndroidFiles.shared() }

    /// What a picker that's showing was asked for.
    enum Request {
        case pick(multiple: Bool, access: DocumentAccess)
        case folder(access: DocumentAccess)
        case export(directory: Int32, path: String)
    }

    private var showing: (id: Int32, request: Request, callback: any DocumentCallback)?

    private var nextID: Int32 = 0

    private var delegate: (any DocumentsDelegate)?

    /// Files the app was opened with while nothing listened.
    private var waiting: [Opened] = []

    struct Opened {
        var uri: String
        var info: ContentInfo
        var isWritable: Bool
    }

    init() { }

    public static func shared() -> AndroidDocuments {
        instance
    }

    /// Forgets the system, what's showing and what waits, for tests.
    public static func reset() {
        system = nil
        instance = AndroidDocuments()
    }

    // MARK: Answers

    /// Calls `answer` with the callback, on the main thread and later.
    static func later(_ callback: any DocumentCallback, _ answer: @escaping (any DocumentCallback) -> Void) {
        let held = MainThreadHeld((callback, answer))
        deliver {
            guard let (callback, answer) = held.take() else { return }
            answer(callback)
        }
    }

    static func fail(_ callback: any DocumentCallback, _ error: DocumentError) {
        later(callback) { $0.didFail(error.rawValue) }
    }

    /// A provider's error, as a picker's.
    static func documentError(_ error: FileError) -> DocumentError {
        switch error {
        case .notFound: .notFound
        case .notPermitted: .notPermitted
        default: .unknown
        }
    }

    // MARK: Documents

    /// Shows a picker through `show`, unless one is showing or there's no
    /// system.
    private func present(_ request: Request, _ callback: any DocumentCallback, _ show: (any DocumentPickerSystem, Int32) -> Bool) {
        guard let system = Self.system else {
            Self.fail(callback, .unsupported)
            return
        }
        guard showing == nil else {
            Self.fail(callback, .busy)
            return
        }
        let id = nextID
        nextID = (nextID + 1) & 0xff
        showing = (id, request, callback)
        guard show(system, id) else {
            showing = nil
            Self.fail(callback, .notAllowed)
            return
        }
    }

    public func pick(_ types: [String], multiple: Bool, access: Int32, callback: any DocumentCallback) {
        let access = DocumentAccess(rawValue: access) ?? .read
        present(.pick(multiple: multiple, access: access), callback) { system, id in
            system.pick(id: id, types: types, multiple: multiple, write: access == .readWrite)
        }
    }

    public func pickFolder(_ access: Int32, callback: any DocumentCallback) {
        let access = DocumentAccess(rawValue: access) ?? .read
        present(.folder(access: access), callback) { system, id in
            system.pickFolder(id: id, write: access == .readWrite)
        }
    }

    public func export(_ directory: Int32, path: String, name: String, callback: any DocumentCallback) {
        guard Self.system != nil else {
            Self.fail(callback, .unsupported)
            return
        }
        // Only a file is saved: check it's there before the picker shows.
        let held = MainThreadHeld(callback)
        Self.files().checkExport(directory, path: path) { [self] error in
            guard let callback = held.take() else { return }
            if let error {
                Self.fail(callback, error == .notPermitted ? .notPermitted : .notFound)
                return
            }
            present(.export(directory: directory, path: path), callback) { system, id in
                system.export(id: id, name: name)
            }
        }
    }

    public func resolve(_ bookmark: String, callback: any DocumentCallback) {
        guard let system = Self.system else {
            Self.fail(callback, .unsupported)
            return
        }
        let kept = system.recall(bookmark)
        guard let uri = kept.first else {
            Self.fail(callback, .notFound)
            return
        }
        guard kept.count == 3 else {
            Self.fail(callback, .notPermitted)
            return
        }
        let isWritable = kept[2] == "1"
        let held = MainThreadHeld(callback)
        Self.files().describe([uri]) { results in
            guard let callback = held.take() else { return }
            switch results[0] {
            case .success(let info):
                callback.didPick([AndroidDocumentGrant(uri: uri, info: info, isWritable: isWritable && info.isWritable)])
            case .failure(let error):
                callback.didFail(Self.documentError(error).rawValue)
            }
        }
    }

    public func forget(_ bookmark: String) {
        Self.system?.forget(bookmark)
    }

    public func setDelegate(_ delegate: (any DocumentsDelegate)?) {
        self.delegate = delegate
        guard delegate != nil, !waiting.isEmpty else { return }
        let held = MainThreadHeld(self)
        Self.deliver {
            // Still listening, and to the same documents object.
            guard let documents = held.take(), let delegate = documents.delegate, !documents.waiting.isEmpty else { return }
            let waiting = documents.waiting
            documents.waiting = []
            delegate.didOpen(waiting.map { AndroidDocumentGrant(uri: $0.uri, info: $0.info, isWritable: $0.isWritable) })
        }
    }

    // MARK: From Android

    /// A picker's URIs, from the Activity's result; none when the user
    /// cancelled. Main thread.
    public static func didPick(id: Int32, uris: [String]) {
        instance.picked(id: id, uris: uris)
    }

    private func picked(id: Int32, uris: [String]) {
        guard let (expected, request, callback) = showing, expected == id else { return }
        showing = nil
        guard !uris.isEmpty else {
            Self.later(callback) { $0.didPick([]) }
            return
        }
        let held = MainThreadHeld(callback)
        switch request {
        case .pick(let multiple, let access):
            // One file is all a picker for one may give.
            let picked = multiple ? uris : Array(uris.prefix(1))
            Self.files().describe(picked) { results in
                guard let callback = held.take() else { return }
                Self.answer(callback, picked, results, access: access)
            }
        case .folder(let access):
            Self.files().describe([uris[0]]) { results in
                guard let callback = held.take() else { return }
                Self.answer(callback, [uris[0]], results, access: access)
            }
        case .export(let directory, let path):
            let uri = uris[0]
            Self.files().export(directory, path: path, to: uri) { error in
                if let error {
                    guard let callback = held.take() else { return }
                    callback.didFail(error == .notPermitted ? DocumentError.notPermitted.rawValue : DocumentError.unknown.rawValue)
                    return
                }
                Self.files().describe([uri]) { results in
                    guard let callback = held.take() else { return }
                    // The save picker grants reading and writing.
                    Self.answer(callback, [uri], results, access: .readWrite)
                }
            }
        }
    }

    /// Grants what the provider described, or fails with the first error.
    private static func answer(_ callback: any DocumentCallback, _ uris: [String], _ results: [Result<ContentInfo, FileError>], access: DocumentAccess) {
        var grants: [any DocumentGrant] = []
        for (uri, result) in zip(uris, results) {
            switch result {
            case .success(let info):
                grants.append(AndroidDocumentGrant(uri: uri, info: info, isWritable: access == .readWrite && info.isWritable))
            case .failure(let error):
                callback.didFail(documentError(error).rawValue)
                return
            }
        }
        callback.didPick(grants)
    }

    /// Files the app was opened with, from an `ACTION_VIEW` or
    /// `ACTION_EDIT` intent. Main thread.
    public static func open(uris: [String], writable: Bool) {
        guard !uris.isEmpty else { return }
        files().describe(uris) { results in
            var opened: [Opened] = []
            for (uri, result) in zip(uris, results) {
                let info: ContentInfo
                switch result {
                case .success(let described):
                    info = described
                case .failure(let error):
                    HostLog.error("Documents: \(uri) can't be opened: error \(error.rawValue)")
                    continue
                }
                opened.append(Opened(uri: uri, info: info, isWritable: writable && info.isWritable))
            }
            instance.opened(opened)
        }
    }

    private func opened(_ documents: [Opened]) {
        guard !documents.isEmpty else { return }
        if let delegate {
            delegate.didOpen(documents.map { AndroidDocumentGrant(uri: $0.uri, info: $0.info, isWritable: $0.isWritable) })
        } else {
            waiting += documents
        }
    }
}

/// One document the guest holds: a grant in `DocumentGrants` for as long as
/// this object lives.
final class AndroidDocumentGrant: DocumentGrant {

    let uri: String

    let info: ContentInfo

    let writable: Bool

    let granted: FileDirectory

    init(uri: String, info: ContentInfo, isWritable: Bool) {
        self.uri = uri
        self.info = info
        self.writable = isWritable
        self.granted = DocumentGrants.grant(ContentGrant(uri: uri, kind: info.kind, isWritable: isWritable))
    }

    deinit {
        DocumentGrants.revoke(granted)
    }

    func directory() -> Int32 {
        granted.rawValue
    }

    func name() -> String {
        info.name
    }

    func kind() -> Int32 {
        info.kind.rawValue
    }

    func contentType() -> String? {
        info.contentType
    }

    func isWritable() -> Bool {
        writable
    }

    func bookmark(_ callback: any DocumentCallback) {
        guard let system = AndroidDocuments.system else {
            AndroidDocuments.fail(callback, .unsupported)
            return
        }
        let key = system.remember(uri: uri, isDirectory: info.kind == .directory, write: writable)
        switch key {
        case "":
            // Open-with, or a provider that keeps nothing.
            AndroidDocuments.fail(callback, .unsupported)
        case "-":
            AndroidDocuments.fail(callback, .limitReached)
        default:
            AndroidDocuments.later(callback) { $0.didBookmark(key) }
        }
    }
}

/// The documents module: `Documents`, its grants, and their callbacks.
public enum AndroidHostDocuments: HostModule {

    public static var contracts: [ContractDescriptor] {
        [DocumentsProxy.descriptor, DocumentGrantProxy.descriptor, DocumentCallbackProxy.descriptor, DocumentsDelegateProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        DocumentsProxy.register(AndroidDocuments.self, in: registrar)
        DocumentGrantProxy.register(AndroidDocumentGrant.self, in: registrar)
        DocumentCallbackProxy.registerInterface(in: registrar)
        DocumentsDelegateProxy.registerInterface(in: registrar)
    }

    /// The pickers ask the user themselves, so there's nothing to grant.
    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        [.userFiles: GrantedPermission()]
    }
}
