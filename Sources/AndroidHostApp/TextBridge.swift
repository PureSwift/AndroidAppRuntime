import AndroidHost
import AndroidHostText
import SwiftJava

/// The Kotlin `TextSystem` (`:appruntime-contracts`): one `EditText` per text.
@JavaClass("org.pureswift.appruntime.contracts.TextSystem")
open class JavaTextSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func make(_ id: Int32)
    @JavaMethod open func destroy(_ id: Int32)
    @JavaMethod open func length(_ id: Int32) -> Int32
    @JavaMethod open func text(_ id: Int32, _ start: Int32, _ end: Int32) -> String
    @JavaMethod open func lineCount(_ id: Int32) -> Int32
    @JavaMethod open func line(_ id: Int32, _ location: Int32) -> Int32
    @JavaMethod open func lineStart(_ id: Int32, _ line: Int32) -> Int32
    @JavaMethod open func setText(_ id: Int32, _ text: String)
    @JavaMethod open func replace(_ id: Int32, _ start: Int32, _ end: Int32, _ text: String)
    @JavaMethod open func selectionStart(_ id: Int32) -> Int32
    @JavaMethod open func selectionEnd(_ id: Int32) -> Int32
    @JavaMethod open func select(_ id: Int32, _ start: Int32, _ end: Int32)
    @JavaMethod open func reveal(_ id: Int32, _ start: Int32, _ end: Int32)
}

extension JavaTextSystem: TextSystem {

    public func text(_ id: Int32, start: Int32, end: Int32) -> String { text(id, start, end) }
    public func line(_ id: Int32, location: Int32) -> Int32 { line(id, location) }
    public func lineStart(_ id: Int32, line: Int32) -> Int32 { lineStart(id, line) }
    public func setText(_ id: Int32, text: String) { setText(id, text) }
    public func replace(_ id: Int32, start: Int32, end: Int32, text: String) { replace(id, start, end, text) }
    public func select(_ id: Int32, start: Int32, end: Int32) { select(id, start, end) }
    public func reveal(_ id: Int32, start: Int32, end: Int32) { reveal(id, start, end) }
}

/// What the texts' `EditText`s report, on the main thread.
@JavaClass("org.pureswift.appruntime.contracts.TextNatives")
open class TextNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.TextNatives")
extension TextNatives {

    @JavaMethod
    public func edited(_ id: Int32, _ location: Int32, _ removed: String, _ inserted: String) {
        TextHub.shared.edited(id, location: location, removed: removed, inserted: inserted)
    }

    @JavaMethod
    public func selected(_ id: Int32) {
        TextHub.shared.selected(id)
    }
}
