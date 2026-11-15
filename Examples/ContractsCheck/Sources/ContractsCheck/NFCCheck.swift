import DynamicNFC
import DynamicRuntime

/// `NFCReader`: availability, and a session that fails as it should where
/// there's no NFC (the emulator), or starts where there is.
final class NFCCheck: NFCReaderDelegate {

    let report: Report

    var reader: NFCReader?

    private var availability: Int32 = 0

    init(report: Report) {
        self.report = report
    }

    func run() {
        availability = NFCReaderProxy.availability()
        report.note("nfc.availability \(availability)")
        let record = NDEFRecordProxy.makeURI("https://example.com/a")
        report.check(record?.uri() == "https://example.com/a" && record?.payload().first == 0x04, "nfc.record uri")
        let text = NDEFRecordProxy.makeText("hej", locale: "sv")
        report.check(text.text() == "hej", "nfc.record text")
        let reader = NFCReaderProxy.make(self)
        self.reader = reader
        reader.begin(NFCTagTypes.ndef.rawValue, alertMessage: "Hold a tag near the phone")
    }

    func didBecomeActive(_ reader: NFCReader) {
        report.check(availability == NFCAvailability.available.rawValue, "nfc.didBecomeActive")
        reader.invalidate(nil)
    }

    func didInvalidate(_ reader: NFCReader, error: Int32, message: String?) {
        let expected: Int32 = switch NFCAvailability(rawValue: availability) {
        case .unsupported: NFCError.unsupported.rawValue
        case .disabled: NFCError.disabled.rawValue
        default: 0
        }
        report.check(error == expected, "nfc.didInvalidate \(error)")
        report.note("nfc.done")
        Checks.location?.requestAlways()
    }

    func didDetect(_ reader: NFCReader, tags: [NFCTag]) {}
    func didConnect(_ reader: NFCReader, tag: NFCTag, error: Int32) {}
    func didQueryNDEF(_ reader: NFCReader, tag: NFCTag, status: Int32, capacity: Int32, error: Int32) {}
    func didReadNDEF(_ reader: NFCReader, tag: NFCTag, message: NDEFMessage?, error: Int32) {}
    func didWriteNDEF(_ reader: NFCReader, tag: NFCTag, error: Int32) {}
    func didLock(_ reader: NFCReader, tag: NFCTag, error: Int32) {}
    func didTransceive(_ reader: NFCReader, tag: NFCTag, response: [UInt8], error: Int32) {}
}
