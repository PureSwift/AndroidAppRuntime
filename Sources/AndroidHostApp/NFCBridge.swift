import AndroidHostNFC
import SwiftJava

/// The Kotlin `NfcSystem` (`:appruntime-contracts`).
@JavaClass("org.pureswift.appruntime.contracts.NfcSystem")
open class JavaNFCSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func availability() -> Int32
    @JavaMethod open func begin(_ session: Int64, _ flags: Int32) -> Int32
    @JavaMethod open func end(_ session: Int64)
    @JavaMethod open func connect(_ tag: Int64, _ technology: String)
    @JavaMethod open func perform(_ operation: Int32, _ tag: Int64, _ data: [UInt8])
    @JavaMethod open func isAvailable(_ tag: Int64) -> Bool
    @JavaMethod open func release(_ tag: Int64)
}

/// `AndroidHostNFC`'s system over the Kotlin class.
final class AndroidNFCSystem: NFCSystem {

    let java = JavaNFCSystem()

    func availability() -> Int32 { java.availability() }

    func begin(session: Int64, flags: Int32) -> Int32 { java.begin(session, flags) }

    func end(session: Int64) { java.end(session) }

    func connect(tag: Int64, technology: String) { java.connect(tag, technology) }

    func perform(_ operation: NFCOperation, tag: Int64, data: [UInt8]) {
        java.perform(operation.rawValue, tag, data)
    }

    func isAvailable(tag: Int64) -> Bool { java.isAvailable(tag) }

    func release(tag: Int64) { java.release(tag) }
}

/// The Kotlin `NfcNatives` object.
@JavaClass("org.pureswift.appruntime.contracts.NfcNatives")
open class NfcNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.NfcNatives")
extension NfcNatives {

    @JavaMethod
    public func discovered(_ session: Int64, _ tag: Int64, _ technologies: [String], _ identifier: [UInt8],
                           _ historicalBytes: [UInt8], _ maximumTransceiveLength: Int32) {
        NFCHub.shared.discovered(session: session, tag: DiscoveredTag(
            handle: tag, technologies: technologies, identifier: identifier, historicalBytes: historicalBytes,
            maximumTransceiveLength: maximumTransceiveLength
        ))
    }

    @JavaMethod
    public func completed(_ tag: Int64, _ operation: Int32, _ status: Int32, _ capacity: Int32, _ bytes: [UInt8],
                          _ exception: String, _ message: String) {
        NFCHub.shared.completed(tag: tag, operation: operation, status: status, capacity: capacity, bytes: bytes,
                                exception: exception, message: message)
    }
}
