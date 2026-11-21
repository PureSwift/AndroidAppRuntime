import AndroidHost
import AndroidHostClipboard
import SwiftJava

/// The Kotlin `ClipboardSystem` (`:appruntime-contracts`).
@JavaClass("org.pureswift.appruntime.contracts.ClipboardSystem")
open class JavaClipboardSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func available() -> Int32
    @JavaMethod open func clear()
    @JavaMethod open func writeText(_ text: String, _ url: String, _ sensitive: Bool)
    @JavaMethod open func writeImage(_ bytes: [Int8], _ fileExtension: String, _ sensitive: Bool) -> Int32
    @JavaMethod open func error() -> Int32
    @JavaMethod open func readText() -> [String]
    @JavaMethod open func readURL() -> [String]
    @JavaMethod open func readImage() -> [Int8]
    @JavaMethod open func imageType() -> String
}

extension JavaClipboardSystem: ClipboardSystem {

    public func writeText(_ text: String, url: String, sensitive: Bool) {
        writeText(text, url, sensitive)
    }

    public func writeImage(_ bytes: [UInt8], fileExtension: String, sensitive: Bool) -> Int32 {
        writeImage(bytes.map { Int8(bitPattern: $0) }, fileExtension, sensitive)
    }

    public func readError() -> Int32 {
        error()
    }

    public func readImage() -> [UInt8] {
        let bytes: [Int8] = readImage()
        return bytes.map { UInt8(bitPattern: $0) }
    }
}
