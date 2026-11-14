import DynamicNFC

/// What the NFC contracts ask Android, through the Kotlin
/// `org.pureswift.appruntime.contracts.NfcSystem` (`AndroidHostApp` binds
/// it): `NfcAdapter.enableReaderMode` on the resumed Activity, and tag I/O
/// on a background thread, whose results reach `NFCHub` on the main
/// thread. Main thread only.
public protocol NFCSystem: AnyObject {

    /// An `NFCAvailability` raw value.
    func availability() -> Int32

    /// Starts reader mode with `NfcAdapter.FLAG_READER_*` flags; 0, or an
    /// `NFCError` raw value. Tags go to `NFCHub.discovered` with `session`.
    func begin(session: Int64, flags: Int32) -> Int32

    func end(session: Int64)

    /// Connects `tag` through a technology class such as
    /// `android.nfc.tech.IsoDep`.
    func connect(tag: Int64, technology: String)

    func perform(_ operation: NFCOperation, tag: Int64, data: [UInt8])

    /// Whether the tag is still connected.
    func isAvailable(tag: Int64) -> Bool

    /// Forgets the tags of a session.
    func release(tag: Int64)
}

/// A tag operation, by its code in the natives.
public enum NFCOperation: Int32, Sendable {
    case connect = 0
    case queryNDEF = 1
    case readNDEF = 2
    case writeNDEF = 3
    case lock = 4
    case transceive = 5
}

/// A discovered `android.nfc.Tag`.
public struct DiscoveredTag: Equatable, Sendable {

    public var handle: Int64

    /// `Tag.getTechList()`.
    public var technologies: [String]

    public var identifier: [UInt8]

    /// IsoDep's historical bytes, NfcA's for ISO 14443-4; empty if none.
    public var historicalBytes: [UInt8]

    /// The technology's `getMaxTransceiveLength`.
    public var maximumTransceiveLength: Int32

    public init(handle: Int64, technologies: [String], identifier: [UInt8], historicalBytes: [UInt8], maximumTransceiveLength: Int32) {
        self.handle = handle
        self.technologies = technologies
        self.identifier = identifier
        self.historicalBytes = historicalBytes
        self.maximumTransceiveLength = maximumTransceiveLength
    }
}

/// Android's NFC values to the contract's. Pure, so tests check them on
/// macOS.
enum NFCMapping {

    static let isoDep = "android.nfc.tech.IsoDep"
    static let nfcA = "android.nfc.tech.NfcA"
    static let nfcF = "android.nfc.tech.NfcF"
    static let nfcV = "android.nfc.tech.NfcV"
    static let ndef = "android.nfc.tech.Ndef"
    static let mifareUltralight = "android.nfc.tech.MifareUltralight"

    /// `NfcAdapter.FLAG_READER_*` for polling options: NFC-A and B for ISO
    /// 14443, F for 18092, V for 15693, all of them for NDEF. Reader mode
    /// skips Android's own NDEF check, which would delay the callback.
    static func readerFlags(_ types: NFCTagTypes) -> Int32 {
        let a: Int32 = 0x1, b: Int32 = 0x2, f: Int32 = 0x4, v: Int32 = 0x8, noSounds: Int32 = 0x100
        var flags: Int32 = 0
        if types.contains(.ndef) {
            flags |= a | b | f | v
        }
        if types.contains(.iso14443) {
            flags |= a | b
        }
        if types.contains(.iso18092) {
            flags |= f
        }
        if types.contains(.iso15693) {
            flags |= v
        }
        return flags == 0 ? 0 : flags | noSounds
    }

    /// The contract's type and the technology its commands go through.
    static func type(_ technologies: [String], ndefSession: Bool) -> (NFCTagType, String?) {
        if ndefSession {
            return (.ndef, technologies.contains(ndef) ? ndef : nil)
        }
        if technologies.contains(isoDep) {
            return (.iso7816, isoDep)
        }
        if technologies.contains(nfcV) {
            return (.iso15693, nfcV)
        }
        if technologies.contains(nfcF) {
            return (.feliCa, nfcF)
        }
        if technologies.contains(mifareUltralight) || technologies.contains(nfcA) {
            return (.miFare, nfcA)
        }
        return (.unknown, technologies.contains(ndef) ? ndef : nil)
    }

    /// A Java exception's class and message to the contract's code.
    static func error(exception: String, message: String) -> NFCError {
        let name = exception.split(separator: ".").last.map(String.init) ?? exception
        switch name {
        case "TagLostException": return .tagConnectionLost
        case "FormatException": return .invalidParameter
        case "ReadOnly": return .tagReadOnly
        case "Capacity": return .capacityExceeded
        case "NotNDEF": return .ndefNotSupported
        case "IOException" where message.lowercased().contains("transceive"): return .transceiveFailed
        case "IOException": return .tagConnectionLost
        case "SecurityException": return .tagConnectionLost
        default: return .unknown
        }
    }
}
