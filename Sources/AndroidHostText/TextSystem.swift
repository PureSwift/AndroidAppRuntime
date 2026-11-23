/// What a text asks of Android's `EditText` (`Plan.md` §6.16): the Kotlin
/// `TextSystem`, one `EditText` per text, by the identifier its
/// `TextEditor` node carries. Tests use a fake. Positions are UTF-16 units,
/// inside the text. Main thread only; what the user does comes back through
/// `TextHub`, and what this is asked to do isn't reported.
public protocol TextSystem: AnyObject {

    /// Makes text `id`'s `EditText`, off screen and empty.
    func make(_ id: Int32)

    /// Takes the view off screen and lets it go.
    func destroy(_ id: Int32)

    func length(_ id: Int32) -> Int32

    func text(_ id: Int32, start: Int32, end: Int32) -> String

    /// At least 1: lines end at `\n`.
    func lineCount(_ id: Int32) -> Int32

    func line(_ id: Int32, location: Int32) -> Int32

    /// Where a line starts, or -1 past the last.
    func lineStart(_ id: Int32, line: Int32) -> Int32

    /// A new text, with the caret at the start.
    func setText(_ id: Int32, text: String)

    func replace(_ id: Int32, start: Int32, end: Int32, text: String)

    /// Where the selection starts and ends, as `EditText` says: the start
    /// is after the end when the user selected backwards.
    func selectionStart(_ id: Int32) -> Int32

    func selectionEnd(_ id: Int32) -> Int32

    func select(_ id: Int32, start: Int32, end: Int32)

    /// Scrolls the range into view, once the text is shown.
    func reveal(_ id: Int32, start: Int32, end: Int32)
}
