import AndroidHost
import DynamicNFC
import DynamicRuntime

/// The `NFCReader` contract over `NfcAdapter.enableReaderMode` (`Plan.md`
/// §6.2). Reader mode needs the resumed Activity, so a session ends with
/// `appInBackground` when the app leaves the foreground. Android shows no
/// scan sheet: the alert message is ignored.
public final class AndroidNFCReader: NFCReader {

    let hub: NFCHub

    let handle: Int64

    /// Kept strongly (`Plan.md` §6).
    let delegate: any NFCReaderDelegate

    private(set) var active = false

    private(set) var ndefSession = false

    private var tagTypes = NFCTagTypes()

    /// Polling pauses after a detection, until `connect`, `restartPolling`
    /// or `invalidate`.
    private(set) var paused = false

    /// The tags of the last detection, and the one connected.
    private(set) var tags: [AndroidNFCTag] = []

    private(set) var connected: AndroidNFCTag?

    private var invalidated = false

    init(delegate: any NFCReaderDelegate, hub: NFCHub = .shared) {
        self.delegate = delegate
        self.hub = hub
        self.handle = hub.nextHandle()
        hub.register(self)
    }

    deinit {
        if active {
            hub.system.end(session: handle)
        }
        hub.unregister(handle)
    }

    public static func availability() -> Int32 {
        NFCHub.shared.system.availability()
    }

    public static func make(_ delegate: any NFCReaderDelegate) -> AndroidNFCReader {
        AndroidNFCReader(delegate: delegate)
    }

    public func begin(_ tagTypes: Int32, alertMessage: String?) {
        guard !invalidated else {
            delegate.didInvalidate(self, error: NFCError.systemBusy.rawValue, message: "This reader was invalidated; make a new one.")
            return
        }
        guard !active else { return }
        let types = NFCTagTypes(rawValue: tagTypes)
        let flags = NFCMapping.readerFlags(types)
        guard flags != 0, !types.contains(.ndef) || types == .ndef else {
            invalidate(with: .invalidParameter, message: "NDEF can't be combined with other tag types")
            return
        }
        switch NFCAvailability(rawValue: Self.availability()) {
        case .unsupported, nil:
            invalidate(with: .unsupported, message: "This device has no NFC.")
            return
        case .disabled:
            invalidate(with: .disabled, message: "NFC is turned off.")
            return
        case .available:
            break
        }
        guard hub.activeReader == nil else {
            invalidate(with: .systemBusy, message: "Another NFC session is active.")
            return
        }
        let result = hub.system.begin(session: handle, flags: flags)
        guard result == 0 else {
            invalidate(with: NFCError(code: result) ?? .unknown, message: nil)
            return
        }
        self.tagTypes = types
        ndefSession = types == .ndef
        active = true
        paused = false
        hub.activeReader = self
        delegate.didBecomeActive(self)
    }

    public func setAlertMessage(_ message: String) {}

    public func restartPolling() {
        guard active else { return }
        dropTags()
        paused = false
    }

    public func connect(_ tag: any NFCTag) {
        let own = HostObjects.own(tag, as: AndroidNFCTag.self)
        guard let tag = own, tag.reader === self, active else {
            if let tag = own {
                delegate.didConnect(self, tag: tag, error: NFCError.tagNotConnected.rawValue)
            }
            return
        }
        guard let technology = tag.technology else {
            delegate.didConnect(self, tag: tag, error: NFCError.tagConnectionLost.rawValue)
            return
        }
        connected = tag
        tag.pending.append(.connect)
        hub.system.connect(tag: tag.handle, technology: technology)
    }

    public func invalidate(_ errorMessage: String?) {
        invalidate(with: nil, message: errorMessage)
    }

    public func isActive() -> Bool {
        active
    }

    /// Ends the session and tells the delegate once.
    func invalidate(with error: NFCError?, message: String?) {
        guard !invalidated else { return }
        invalidated = true
        if active {
            active = false
            hub.system.end(session: handle)
        }
        if hub.activeReader === self {
            hub.activeReader = nil
        }
        dropTags()
        delegate.didInvalidate(self, error: error?.rawValue ?? 0, message: error == nil ? nil : message)
    }

    private func dropTags() {
        for tag in tags {
            tag.failPending()
            hub.system.release(tag: tag.handle)
            hub.tags[tag.handle] = nil
        }
        tags = []
        connected = nil
    }

    // MARK: Events

    func discovered(_ found: DiscoveredTag) {
        guard active, !paused else {
            hub.system.release(tag: found.handle)
            return
        }
        let (type, technology) = NFCMapping.type(found.technologies, ndefSession: ndefSession)
        let tag = AndroidNFCTag(found, type: type, technology: technology, reader: self)
        hub.tags[found.handle] = tag
        tags = [tag]
        paused = true
        delegate.didDetect(self, tags: tags)
    }
}

/// The `NFCTag` contract. Each operation gets one delegate callback; one
/// runs at a time on the tag's I/O thread, so they're answered in order.
public final class AndroidNFCTag: NFCTag {

    let handle: Int64

    let tagType: NFCTagType

    let technology: String?

    let uid: [UInt8]

    let historical: [UInt8]

    let maximumLength: Int32

    private(set) weak var reader: AndroidNFCReader?

    /// Operations sent and not answered, in order.
    var pending: [NFCOperation] = []

    init(_ tag: DiscoveredTag, type: NFCTagType, technology: String?, reader: AndroidNFCReader) {
        self.handle = tag.handle
        self.tagType = type
        self.technology = technology
        self.uid = tag.identifier
        self.historical = tag.historicalBytes
        self.maximumLength = tag.maximumTransceiveLength
        self.reader = reader
    }

    public func type() -> Int32 { tagType.rawValue }

    public func identifier() -> [UInt8] { reader?.ndefSession == true ? [] : uid }

    public func isAvailable() -> Bool {
        guard let reader, reader.connected === self else { return false }
        return reader.hub.system.isAvailable(tag: handle)
    }

    public func historicalBytes() -> [UInt8]? { historical.isEmpty ? nil : historical }

    /// Android selects no application for the app.
    public func selectedApplicationIdentifier() -> String? { nil }

    public func maximumTransceiveLength() -> Int32 { maximumLength }

    public func queryNDEFStatus() { send(.queryNDEF) }

    public func readNDEF() { send(.readNDEF) }

    public func writeNDEF(_ message: any NDEFMessage) {
        let message = AndroidNDEFMessage.copy(of: message)
        send(.writeNDEF, data: message.encoded())
    }

    public func writeLock() { send(.lock) }

    public func transceive(_ data: [UInt8]) {
        guard reader?.ndefSession != true else {
            fail(.transceive, NFCError.notAvailableInNDEFSession.rawValue)
            return
        }
        send(.transceive, data: data)
    }

    /// Sends an operation if the tag is connected; otherwise its callback
    /// fails at once.
    private func send(_ operation: NFCOperation, data: [UInt8] = []) {
        guard let reader, reader.connected === self, reader.active else {
            fail(operation, NFCError.tagNotConnected.rawValue)
            return
        }
        pending.append(operation)
        reader.hub.system.perform(operation, tag: handle, data: data)
    }

    /// The I/O thread's answer to the oldest operation.
    func completed(_ operation: NFCOperation, status: Int32, capacity: Int32, bytes: [UInt8], exception: String, message: String) {
        guard let index = pending.firstIndex(of: operation) else { return }
        pending.remove(at: index)
        let error = exception.isEmpty ? 0 : NFCMapping.error(exception: exception, message: message).rawValue
        guard let reader else { return }
        let delegate = reader.delegate
        switch operation {
        case .connect:
            delegate.didConnect(reader, tag: self, error: error)
        case .queryNDEF:
            delegate.didQueryNDEF(reader, tag: self, status: error == 0 ? status : NDEFStatus.notSupported.rawValue,
                                  capacity: error == 0 ? capacity : 0, error: error)
        case .readNDEF:
            let message = error == 0 && !bytes.isEmpty ? AndroidNDEFMessage.decode(bytes) : nil
            delegate.didReadNDEF(reader, tag: self, message: message, error: error)
        case .writeNDEF:
            delegate.didWriteNDEF(reader, tag: self, error: error)
        case .lock:
            delegate.didLock(reader, tag: self, error: error)
        case .transceive:
            delegate.didTransceive(reader, tag: self, response: error == 0 ? bytes : [], error: error)
        }
    }

    /// Every operation waiting fails: the tag or session went.
    func failPending() {
        let waiting = pending
        pending = []
        for operation in waiting {
            fail(operation, NFCError.tagConnectionLost.rawValue)
        }
    }

    private func fail(_ operation: NFCOperation, _ error: Int32) {
        guard let reader else { return }
        let delegate = reader.delegate
        switch operation {
        case .connect: delegate.didConnect(reader, tag: self, error: error)
        case .queryNDEF: delegate.didQueryNDEF(reader, tag: self, status: NDEFStatus.notSupported.rawValue, capacity: 0, error: error)
        case .readNDEF: delegate.didReadNDEF(reader, tag: self, message: nil, error: error)
        case .writeNDEF: delegate.didWriteNDEF(reader, tag: self, error: error)
        case .lock: delegate.didLock(reader, tag: self, error: error)
        case .transceive: delegate.didTransceive(reader, tag: self, response: [], error: error)
        }
    }
}

/// The readers, the session that's active, and the tags, by handle. Main
/// thread only.
public final class NFCHub {

    nonisolated(unsafe) public static let shared = NFCHub()

    /// Makes the system on first use; `AndroidHostApp` sets it.
    public var makeSystem: (() -> any NFCSystem)?

    private var _system: (any NFCSystem)?

    public var system: any NFCSystem {
        if let _system {
            return _system
        }
        guard let makeSystem else {
            fatalError("NFCHub.makeSystem isn't set")
        }
        let system = makeSystem()
        _system = system
        return system
    }

    private var readers: [Int64: WeakReader] = [:]

    var tags: [Int64: AndroidNFCTag] = [:]

    weak var activeReader: AndroidNFCReader?

    private var lastHandle: Int64 = 0

    public init() { }

    /// Replaces the system, for tests.
    public func use(_ system: (any NFCSystem)?) {
        _system = system
        readers = [:]
        tags = [:]
        activeReader = nil
    }

    func nextHandle() -> Int64 {
        lastHandle += 1
        return lastHandle
    }

    func register(_ reader: AndroidNFCReader) {
        readers[reader.handle] = WeakReader(reader: reader)
    }

    func unregister(_ handle: Int64) {
        readers[handle] = nil
    }

    // MARK: Events

    /// The app left the foreground: reader mode ends with it.
    public func appWentInactive() {
        activeReader?.invalidate(with: .appInBackground, message: "The app left the foreground.")
    }

    public func discovered(session: Int64, tag: DiscoveredTag) {
        guard let reader = readers[session]?.reader else {
            system.release(tag: tag.handle)
            return
        }
        reader.discovered(tag)
    }

    public func completed(tag: Int64, operation: Int32, status: Int32, capacity: Int32, bytes: [UInt8], exception: String, message: String) {
        guard let operation = NFCOperation(rawValue: operation) else { return }
        tags[tag]?.completed(operation, status: status, capacity: capacity, bytes: bytes, exception: exception, message: message)
    }
}

private struct WeakReader {
    weak var reader: AndroidNFCReader?
}

/// The NFC contracts (`Plan.md` §6.2): the reader role. `nfc` is an
/// install-time permission; `AndroidPermissions`' table checks the
/// hardware.
public enum AndroidHostNFC: HostModule {

    public static var contracts: [ContractDescriptor] {
        [
            NFCReaderProxy.descriptor, NFCReaderDelegateProxy.descriptor, NFCTagProxy.descriptor,
            NDEFMessageProxy.descriptor, NDEFRecordProxy.descriptor,
        ]
    }

    public static func register(in registrar: some ContractRegistrar) {
        NFCReaderProxy.register(AndroidNFCReader.self, in: registrar)
        NFCReaderDelegateProxy.registerInterface(in: registrar)
        NFCTagProxy.register(AndroidNFCTag.self, in: registrar)
        NDEFMessageProxy.register(AndroidNDEFMessage.self, in: registrar)
        NDEFRecordProxy.register(AndroidNDEFRecord.self, in: registrar)
    }
}
