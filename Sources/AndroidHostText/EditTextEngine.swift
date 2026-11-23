import DynamicText
import RuntimeText

/// One text: an `EditText` the Kotlin `TextSystem` holds, whose `Editable`
/// is the text. It lives as long as the guest's `TextStorage`, on screen or
/// not; a `TextEditor` node shows it while it names it.
///
/// - The engine keeps the undo history itself: `EditText` has none an app
///   can call. Each step is an edit with the text it removed, from the user
///   or the guest. Typing on from where the last keystroke left off is the
///   same step, and so is a keyboard's rewriting of the word it's
///   composing, which `EditText` reports as replacing it.
/// - The user's edits come from a `TextWatcher`, with what they removed and
///   put in; the guest's aren't reported, since the engine made them.
/// - Kotlin turns typed and pasted `\r\n` and `\r` into `\n`.
///
/// Main thread only.
final class EditTextEngine: TextEngine {

    private(set) weak var storage: HostTextStorage?

    /// The text's identifier, the storage's and its node's.
    let id: Int32

    private let system: any TextSystem

    private var done: [TextChange] = []

    private var undone: [TextChange] = []

    /// The user's latest step, while typing can still extend it.
    private var typing: TextChange?

    /// The selection as last heard of: what the user's next edit started
    /// from, since `EditText` has moved it by the time the edit's told.
    private var known = 0 ..< 0

    init(storage: HostTextStorage, system: any TextSystem) {
        self.storage = storage
        self.id = storage.identifier()
        self.system = system
        system.make(id)
        TextHub.shared.register(self)
    }

    deinit {
        TextHub.shared.unregister(id)
        system.destroy(id)
    }

    // MARK: Reading

    var length: Int {
        Int(system.length(id))
    }

    func text(in range: Range<Int>) -> String {
        system.text(id, start: Int32(clamping: range.lowerBound), end: Int32(clamping: range.upperBound))
    }

    var lineCount: Int {
        Int(system.lineCount(id))
    }

    func line(at location: Int) -> Int {
        Int(system.line(id, location: Int32(clamping: location)))
    }

    func lineStart(_ line: Int) -> Int? {
        let start = system.lineStart(id, line: Int32(clamping: line))
        return start < 0 ? nil : Int(start)
    }

    var selection: Range<Int> {
        get {
            let start = Int(system.selectionStart(id))
            let end = Int(system.selectionEnd(id))
            return min(start, end) ..< max(start, end)
        }
        set {
            system.select(id, start: Int32(clamping: newValue.lowerBound), end: Int32(clamping: newValue.upperBound))
            known = newValue
        }
    }

    // MARK: Changing

    func setText(_ text: String) {
        let removed = length
        system.setText(id, text: text)
        known = 0 ..< 0
        done = []
        undone = []
        typing = nil
        storage?.edited(at: 0, removed: removed, inserted: text.utf16.count)
        undoChanged()
        storage?.selectionChanged()
    }

    func replace(_ range: Range<Int>, with text: String) {
        let before = selection
        let removed = self.text(in: range)
        system.replace(id, start: Int32(clamping: range.lowerBound), end: Int32(clamping: range.upperBound), text: text)
        let inserted = text.utf16.count
        let lower = TextPositions.adjusting(before.lowerBound, forEditAt: range.lowerBound, removed: range.count, inserted: inserted)
        let upper = TextPositions.adjusting(before.upperBound, forEditAt: range.lowerBound, removed: range.count, inserted: inserted)
        record(TextChange(location: range.lowerBound, removed: removed, inserted: text,
                          selectionBefore: before, selectionAfter: lower ..< max(lower, upper)))
        typing = nil
        storage?.edited(at: range.lowerBound, removed: range.count, inserted: inserted)
        undoChanged()
    }

    func undo() {
        typing = nil
        if let change = done.popLast() {
            revert(change.location, removing: change.inserted, putting: change.removed, selection: change.selectionBefore)
            undone.append(change)
        }
        undoChanged()
        storage?.selectionChanged()
    }

    func redo() {
        typing = nil
        if let change = undone.popLast() {
            revert(change.location, removing: change.removed, putting: change.inserted, selection: change.selectionAfter)
            done.append(change)
        }
        undoChanged()
        storage?.selectionChanged()
    }

    func reveal(_ range: Range<Int>) {
        system.reveal(id, start: Int32(clamping: range.lowerBound), end: Int32(clamping: range.upperBound))
    }

    /// A step of the history, applied: the selection is put back before
    /// the edit is told, so the guest hears of it once.
    private func revert(_ location: Int, removing: String, putting: String, selection: Range<Int>) {
        let removed = removing.utf16.count
        system.replace(id, start: Int32(clamping: location), end: Int32(clamping: location + removed), text: putting)
        self.selection = selection
        storage?.edited(at: location, removed: removed, inserted: putting.utf16.count)
    }

    private func record(_ change: TextChange) {
        done.append(change)
        undone = []
    }

    private func undoChanged() {
        storage?.undoChanged(canUndo: !done.isEmpty, canRedo: !undone.isEmpty)
    }

    // MARK: From the view

    /// The user's edit: `removed` at `location` became `inserted`.
    func userEdited(at location: Int, removed: String, inserted: String) {
        let after = selection
        if let typing, typing === done.last, typing.extends(location: location, removed: removed, inserted: inserted) {
            typing.extend(location: location, removed: removed, inserted: inserted, selection: after)
        } else {
            let change = TextChange(location: location, removed: removed, inserted: inserted,
                                    selectionBefore: known, selectionAfter: after)
            record(change)
            typing = change.inserted.isEmpty || change.inserted.contains("\n") ? nil : change
        }
        known = after
        storage?.edited(at: location, removed: removed.utf16.count, inserted: inserted.utf16.count)
        undoChanged()
    }

    /// The selection moved, by the user's hand or the view's.
    func selectionMoved() {
        let selection = self.selection
        if let typing, selection != typing.selectionAfter {
            // Typing somewhere else is another step.
            self.typing = nil
        }
        known = selection
        storage?.selectionChanged()
    }
}

/// One step of a text's history: `removed` at `location` became
/// `inserted`. A class, so typing can extend the latest step.
final class TextChange {

    let location: Int

    let removed: String

    private(set) var inserted: String

    /// The selection to put back when it's undone.
    let selectionBefore: Range<Int>

    /// And when it's redone.
    private(set) var selectionAfter: Range<Int>

    init(location: Int, removed: String, inserted: String, selectionBefore: Range<Int>, selectionAfter: Range<Int>) {
        self.location = location
        self.removed = removed
        self.inserted = inserted
        self.selectionBefore = selectionBefore
        self.selectionAfter = selectionAfter
    }

    /// Whether an edit of the user's goes on from this one: it starts
    /// inside what this put in, removes only from there to its end, and
    /// puts in no line break.
    func extends(location: Int, removed: String, inserted: String) -> Bool {
        let units = Array(self.inserted.utf16)
        let offset = location - self.location
        guard offset >= 0, offset <= units.count, !inserted.contains("\n") else { return false }
        return Array(removed.utf16) == Array(units[offset...])
    }

    func extend(location: Int, removed: String, inserted: String, selection: Range<Int>) {
        let units = Array(self.inserted.utf16)
        self.inserted = String(decoding: units[..<(location - self.location)], as: UTF16.self) + inserted
        selectionAfter = selection
    }
}
