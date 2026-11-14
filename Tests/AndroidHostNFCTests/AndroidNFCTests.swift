import AndroidHost
@testable import AndroidHostNFC
import DynamicNFC
import DynamicRuntime
import Testing

/// An NFC adapter the tests drive.
final class FakeNFCSystem: NFCSystem {

    var available: NFCAvailability = .available
    var begun: [(Int64, Int32)] = []
    var ended: [Int64] = []
    var connects: [(Int64, String)] = []
    var operations: [(NFCOperation, Int64, [UInt8])] = []
    var released: [Int64] = []
    var connected = true

    func availability() -> Int32 { available.rawValue }

    func begin(session: Int64, flags: Int32) -> Int32 {
        begun.append((session, flags))
        return 0
    }

    func end(session: Int64) { ended.append(session) }
    func connect(tag: Int64, technology: String) { connects.append((tag, technology)) }
    func perform(_ operation: NFCOperation, tag: Int64, data: [UInt8]) { operations.append((operation, tag, data)) }
    func isAvailable(tag: Int64) -> Bool { connected }
    func release(tag: Int64) { released.append(tag) }
}

final class RecordingReaderDelegate: NFCReaderDelegate {

    var events: [String] = []
    var tags: [any NFCTag] = []
    var messages: [(any NDEFMessage)?] = []

    func didBecomeActive(_ reader: any NFCReader) { events.append("active") }

    func didDetect(_ reader: any NFCReader, tags: [any NFCTag]) {
        events.append("detect \(tags.map { $0.type() })")
        self.tags = tags
    }

    func didConnect(_ reader: any NFCReader, tag: any NFCTag, error: Int32) { events.append("connect \(error)") }

    func didQueryNDEF(_ reader: any NFCReader, tag: any NFCTag, status: Int32, capacity: Int32, error: Int32) {
        events.append("query \(status) \(capacity) \(error)")
    }

    func didReadNDEF(_ reader: any NFCReader, tag: any NFCTag, message: (any NDEFMessage)?, error: Int32) {
        events.append("read \(error)")
        messages.append(message)
    }

    func didWriteNDEF(_ reader: any NFCReader, tag: any NFCTag, error: Int32) { events.append("write \(error)") }
    func didLock(_ reader: any NFCReader, tag: any NFCTag, error: Int32) { events.append("lock \(error)") }

    func didTransceive(_ reader: any NFCReader, tag: any NFCTag, response: [UInt8], error: Int32) {
        events.append("transceive \(response) \(error)")
    }

    func didInvalidate(_ reader: any NFCReader, error: Int32, message: String?) { events.append("invalidate \(error)") }
}

/// Serialized: the hub is shared.
@Suite(.serialized) struct AndroidNFCTests {

    let system = FakeNFCSystem()
    let hub = NFCHub.shared

    init() {
        hub.use(system)
    }

    func smartCard(_ handle: Int64 = 100) -> DiscoveredTag {
        DiscoveredTag(handle: handle, technologies: [NFCMapping.isoDep, NFCMapping.nfcA, NFCMapping.ndef],
                      identifier: [4, 0x8A, 0x2B], historicalBytes: [0x80], maximumTransceiveLength: 261)
    }

    @Test func maps() {
        #expect(NFCMapping.readerFlags(.ndef) == 0x10F)
        #expect(NFCMapping.readerFlags(.iso14443) == 0x103)
        #expect(NFCMapping.readerFlags([.iso15693, .iso18092]) == 0x10C)
        #expect(NFCMapping.readerFlags([]) == 0)
        #expect(NFCMapping.type([NFCMapping.nfcA, NFCMapping.mifareUltralight], ndefSession: false) == (.miFare, NFCMapping.nfcA))
        #expect(NFCMapping.type([NFCMapping.nfcV], ndefSession: false) == (.iso15693, NFCMapping.nfcV))
        #expect(NFCMapping.type([NFCMapping.nfcF], ndefSession: false) == (.feliCa, NFCMapping.nfcF))
        #expect(NFCMapping.type([NFCMapping.isoDep, NFCMapping.ndef], ndefSession: true) == (.ndef, NFCMapping.ndef))
        #expect(NFCMapping.type(["android.nfc.tech.NfcBarcode"], ndefSession: false) == (.unknown, nil))
        #expect(NFCMapping.error(exception: "android.nfc.TagLostException", message: "") == .tagConnectionLost)
        #expect(NFCMapping.error(exception: "android.nfc.FormatException", message: "") == .invalidParameter)
        #expect(NFCMapping.error(exception: "ReadOnly", message: "") == .tagReadOnly)
        #expect(NFCMapping.error(exception: "java.io.IOException", message: "Transceive failed") == .transceiveFailed)
    }

    @Test func failsWithoutNFC() {
        system.available = .unsupported
        let delegate = RecordingReaderDelegate()
        AndroidNFCReader(delegate: delegate).begin(NFCTagTypes.ndef.rawValue, alertMessage: nil)
        #expect(delegate.events == ["invalidate \(NFCError.unsupported.rawValue)"])
        system.available = .disabled
        let off = RecordingReaderDelegate()
        AndroidNFCReader(delegate: off).begin(NFCTagTypes.ndef.rawValue, alertMessage: nil)
        #expect(off.events == ["invalidate \(NFCError.disabled.rawValue)"])
        #expect(system.begun.isEmpty)
        system.available = .available
        let mixed = RecordingReaderDelegate()
        AndroidNFCReader(delegate: mixed).begin(NFCTagTypes([.ndef, .iso14443]).rawValue, alertMessage: nil)
        #expect(mixed.events == ["invalidate \(NFCError.invalidParameter.rawValue)"])
    }

    @Test func runsOneSessionAtATime() {
        let first = AndroidNFCReader(delegate: RecordingReaderDelegate())
        first.begin(NFCTagTypes.iso14443.rawValue, alertMessage: "Hold near")
        #expect(first.isActive())
        let delegate = RecordingReaderDelegate()
        AndroidNFCReader(delegate: delegate).begin(NFCTagTypes.iso14443.rawValue, alertMessage: nil)
        #expect(delegate.events == ["invalidate \(NFCError.systemBusy.rawValue)"])
        hub.appWentInactive()
        #expect(!first.isActive())
        #expect(system.ended == [first.handle])
    }

    @Test func detectsConnectsAndTransceives() throws {
        let delegate = RecordingReaderDelegate()
        let reader = AndroidNFCReader(delegate: delegate)
        reader.begin(NFCTagTypes.iso14443.rawValue, alertMessage: nil)
        hub.discovered(session: reader.handle, tag: smartCard())
        hub.discovered(session: reader.handle, tag: smartCard(101))
        #expect(delegate.events == ["active", "detect [1]"], "polling pauses after a detection")
        #expect(system.released == [101])
        let tag = try #require(delegate.tags.first)
        #expect(tag.identifier() == [4, 0x8A, 0x2B])
        #expect(tag.historicalBytes() == [0x80])
        #expect(tag.maximumTransceiveLength() == 261)
        tag.transceive([0x00, 0xA4])
        #expect(delegate.events.last == "transceive [] \(NFCError.tagNotConnected.rawValue)")
        reader.connect(tag)
        #expect(system.connects.first?.1 == NFCMapping.isoDep)
        hub.completed(tag: 100, operation: NFCOperation.connect.rawValue, status: 0, capacity: 0, bytes: [], exception: "", message: "")
        tag.transceive([0x00, 0xA4])
        hub.completed(tag: 100, operation: NFCOperation.transceive.rawValue, status: 0, capacity: 0, bytes: [0x90, 0x00], exception: "", message: "")
        tag.transceive([0x00, 0xB0])
        hub.completed(tag: 100, operation: NFCOperation.transceive.rawValue, status: 0, capacity: 0, bytes: [], exception: "android.nfc.TagLostException", message: "")
        #expect(delegate.events.suffix(3) == ["connect 0", "transceive [144, 0] 0", "transceive [] \(NFCError.tagConnectionLost.rawValue)"])
        #expect(tag.isAvailable())
    }

    @Test func readsAndWritesNDEF() throws {
        let delegate = RecordingReaderDelegate()
        let reader = AndroidNFCReader(delegate: delegate)
        reader.begin(NFCTagTypes.ndef.rawValue, alertMessage: nil)
        hub.discovered(session: reader.handle, tag: smartCard())
        let tag = try #require(delegate.tags.first)
        #expect(tag.type() == NFCTagType.ndef.rawValue)
        #expect(tag.identifier().isEmpty, "no UID in an NDEF session, as on iOS")
        reader.connect(tag)
        #expect(system.connects.first?.1 == NFCMapping.ndef)
        hub.completed(tag: 100, operation: NFCOperation.connect.rawValue, status: 0, capacity: 0, bytes: [], exception: "", message: "")
        tag.queryNDEFStatus()
        hub.completed(tag: 100, operation: NFCOperation.queryNDEF.rawValue, status: NDEFStatus.readWrite.rawValue, capacity: 137, bytes: [], exception: "", message: "")
        let message = AndroidNDEFMessage.make([AndroidNDEFRecord.makeURI("https://example.com")!])
        tag.writeNDEF(message)
        let written = try #require(system.operations.last)
        #expect(written.0 == .writeNDEF)
        #expect(written.2 == message.encoded())
        hub.completed(tag: 100, operation: NFCOperation.writeNDEF.rawValue, status: 0, capacity: 0, bytes: [], exception: "", message: "")
        tag.readNDEF()
        hub.completed(tag: 100, operation: NFCOperation.readNDEF.rawValue, status: 0, capacity: 0, bytes: message.encoded(), exception: "", message: "")
        tag.transceive([1])
        #expect(delegate.events.suffix(5) == ["connect 0", "query 1 137 0", "write 0", "read 0", "transceive [] \(NFCError.notAvailableInNDEFSession.rawValue)"])
        #expect(delegate.messages.last??.records().first?.uri() == "https://example.com")
    }

    @Test func failsPendingOperationsWhenTheSessionEnds() throws {
        let delegate = RecordingReaderDelegate()
        let reader = AndroidNFCReader(delegate: delegate)
        reader.begin(NFCTagTypes.iso14443.rawValue, alertMessage: nil)
        hub.discovered(session: reader.handle, tag: smartCard())
        let tag = try #require(delegate.tags.first)
        reader.connect(tag)
        hub.completed(tag: 100, operation: NFCOperation.connect.rawValue, status: 0, capacity: 0, bytes: [], exception: "", message: "")
        tag.readNDEF()
        reader.invalidate(nil)
        #expect(delegate.events.suffix(2) == ["read \(NFCError.tagConnectionLost.rawValue)", "invalidate 0"])
        reader.begin(NFCTagTypes.iso14443.rawValue, alertMessage: nil)
        #expect(delegate.events.last == "invalidate \(NFCError.systemBusy.rawValue)", "an invalidated reader can't begin again")
        #expect(!reader.isActive())
    }

    @Test func registersEveryContract() {
        #expect(AndroidHostNFC.contracts.count == 5)
    }
}
