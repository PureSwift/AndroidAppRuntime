import Testing
import AndroidHost
import DynamicText
import RuntimeText
@testable import AndroidHostText

/// The Kotlin side's texts, in memory: each `EditText`'s units and
/// selection, with the calls the engine made. The user's edits are made
/// here and told to `TextHub` as the `TextWatcher` tells them: the edit,
/// then the selection.
final class ScriptedTexts: TextSystem {

    struct Text {
        var units: [UInt16] = []
        var start = 0
        var end = 0
    }

    var texts: [Int32: Text] = [:]

    var calls: [String] = []

    func make(_ id: Int32) {
        texts[id] = Text()
        calls.append("make")
    }

    func destroy(_ id: Int32) {
        texts[id] = nil
        calls.append("destroy")
    }

    func string(_ id: Int32) -> String {
        String(decoding: texts[id]?.units ?? [], as: UTF16.self)
    }

    func length(_ id: Int32) -> Int32 {
        Int32(texts[id]?.units.count ?? 0)
    }

    func text(_ id: Int32, start: Int32, end: Int32) -> String {
        String(decoding: texts[id]!.units[Int(start) ..< Int(end)], as: UTF16.self)
    }

    func lineCount(_ id: Int32) -> Int32 {
        Int32(texts[id]!.units.filter { $0 == 0x0A }.count + 1)
    }

    func line(_ id: Int32, location: Int32) -> Int32 {
        Int32(texts[id]!.units[..<Int(location)].filter { $0 == 0x0A }.count)
    }

    func lineStart(_ id: Int32, line: Int32) -> Int32 {
        if line == 0 { return 0 }
        var seen: Int32 = 0
        for (index, unit) in texts[id]!.units.enumerated() where unit == 0x0A {
            seen += 1
            if seen == line { return Int32(index + 1) }
        }
        return -1
    }

    func setText(_ id: Int32, text: String) {
        texts[id] = Text(units: Array(text.utf16))
        calls.append("setText")
    }

    /// As `Editable.replace` leaves it here: the caret after what went in,
    /// which isn't the contract's rule, so the engine's has to win.
    func replace(_ id: Int32, start: Int32, end: Int32, text: String) {
        texts[id]!.units.replaceSubrange(Int(start) ..< Int(end), with: text.utf16)
        let caret = Int(start) + text.utf16.count
        texts[id]!.start = caret
        texts[id]!.end = caret
        calls.append("replace \(start) \(end) \(text)")
    }

    func selectionStart(_ id: Int32) -> Int32 {
        Int32(texts[id]!.start)
    }

    func selectionEnd(_ id: Int32) -> Int32 {
        Int32(texts[id]!.end)
    }

    func select(_ id: Int32, start: Int32, end: Int32) {
        texts[id]!.start = Int(start)
        texts[id]!.end = Int(end)
    }

    func reveal(_ id: Int32, start: Int32, end: Int32) {
        calls.append("reveal \(start) \(end)")
    }

    // MARK: As the user

    /// Replaces `start ..< end` with `text`, leaving the caret after it.
    func edit(_ id: Int32, _ start: Int, _ end: Int, _ text: String) {
        let removed = String(decoding: texts[id]!.units[start ..< end], as: UTF16.self)
        texts[id]!.units.replaceSubrange(start ..< end, with: text.utf16)
        texts[id]!.start = start + text.utf16.count
        texts[id]!.end = start + text.utf16.count
        TextHub.shared.edited(id, location: Int32(start), removed: removed, inserted: text)
        TextHub.shared.selected(id)
    }

    /// Types at the caret, in place of what's selected.
    func type(_ id: Int32, _ text: String) {
        let selection = texts[id]!
        edit(id, min(selection.start, selection.end), max(selection.start, selection.end), text)
    }

    /// Drags the selection, or taps the caret somewhere.
    func touch(_ id: Int32, _ start: Int, _ end: Int? = nil) {
        texts[id]!.start = start
        texts[id]!.end = end ?? start
        TextHub.shared.selected(id)
    }
}

/// What the guest hears.
final class Recorder: TextStorageDelegate {

    var events: [String] = []

    func didEdit(_ location: Int32, removed: Int32, inserted: Int32, length: Int32) {
        events.append("edit \(location) -\(removed) +\(inserted) = \(length)")
    }

    func didChangeSelection(_ location: Int32, length: Int32) {
        events.append("select \(location) \(length)")
    }

    func didChangeModified(_ modified: Bool) {
        events.append("modified \(modified)")
    }

    func didChangeUndo(_ canUndo: Bool, canRedo: Bool) {
        events.append("undo \(canUndo) \(canRedo)")
    }

    func take() -> [String] {
        defer { events = [] }
        return events
    }
}

/// `HostTextStorage` over `EditTextEngine`, over the scripted `EditText`s:
/// what the guest hears of its own edits and the user's, and the history.
/// Serialized: the platform and `TextHub` are global.
@Suite(.serialized) final class AndroidTextTests {

    let system = ScriptedTexts()

    let recorder = Recorder()

    init() {
        TextHub.shared.use(system)
        HostTextStorage.platform = AndroidTextPlatform()
    }

    deinit {
        HostTextStorage.reset()
        TextHub.shared.use(nil)
    }

    func storage(_ text: String = "") -> (HostTextStorage, Int32) {
        let storage = HostTextStorage.make(recorder)
        if !text.isEmpty {
            storage.setText(text)
        }
        _ = recorder.take()
        return (storage, storage.identifier())
    }

    @Test func aTextIsAnEditTextForAsLongAsTheGuestHoldsIt() {
        var storage: HostTextStorage? = HostTextStorage.make(recorder)
        let id = storage!.identifier()
        #expect(system.texts[id] != nil)
        #expect(system.calls == ["make"])
        #expect(HostTextStorage.maximumLength() == 1 << 20)
        storage = nil
        #expect(system.texts[id] == nil)
        #expect(system.calls == ["make", "destroy"])
        // What it says afterwards goes nowhere.
        TextHub.shared.selected(id)
    }

    @Test func aNewTextIsOneEditWithNoHistory() {
        let (storage, id) = storage()
        storage.setText("one\r\ntwo")
        #expect(system.string(id) == "one\ntwo")
        #expect(recorder.take() == ["edit 0 -0 +7 = 7"])
        storage.replace(0, length: 3, text: "1")
        _ = recorder.take()
        // The caret was after the "1"; a new text puts it at the start.
        storage.setText("three")
        #expect(recorder.take() == ["edit 0 -5 +5 = 5", "undo false false", "modified false", "select 0 0"])
        #expect(storage.length() == 5)
    }

    @Test func theGuestsEditIsOneStepAndTheSelectionFollowsTheRule() {
        let (storage, id) = storage("hello world")
        storage.setSelection(6, length: 5)
        #expect(recorder.take() == ["select 6 5"])
        storage.replace(0, length: 5, text: "hi")
        #expect(system.string(id) == "hi world")
        // `EditText` put the caret after "hi"; the contract's rule moves
        // the selection with the text after the edit.
        #expect(recorder.take() == ["edit 0 -5 +2 = 8", "modified true", "undo true false", "select 3 5"])
        #expect(storage.text() == "hi world")

        storage.undo()
        #expect(system.string(id) == "hello world")
        #expect(recorder.take() == ["edit 0 -2 +5 = 11", "select 6 5", "undo false true"])
        storage.redo()
        #expect(system.string(id) == "hi world")
        #expect(recorder.take() == ["edit 0 -5 +2 = 8", "select 3 5", "undo true false"])
        // Nothing to redo: nothing happens.
        storage.redo()
        #expect(recorder.take() == [])
    }

    @Test func theUsersEditIsToldWithTheSelectionAfterIt() {
        let (storage, id) = storage("ab")
        system.touch(id, 1)
        #expect(recorder.take() == ["select 1 0"])
        system.type(id, "X")
        #expect(storage.text() == "aXb")
        #expect(recorder.take() == ["edit 1 -0 +1 = 3", "modified true", "select 2 0", "undo true false"])
        // Selecting backwards is still a range.
        system.touch(id, 3, 0)
        #expect(recorder.take() == ["select 0 3"])
    }

    @Test func typingIsOneStepUntilALineBreak() {
        let (storage, id) = storage()
        for key in ["h", "e", "y", "\n", "y", "o"] {
            system.type(id, key)
        }
        #expect(system.string(id) == "hey\nyo")
        storage.undo()
        #expect(system.string(id) == "hey\n")
        storage.undo()
        #expect(system.string(id) == "hey")
        storage.undo()
        #expect(system.string(id) == "")
        #expect(recorder.events.suffix(1) == ["undo false true"])
        storage.redo()
        #expect(system.string(id) == "hey")
        #expect(system.texts[id]!.start == 3)
        storage.redo()
        storage.redo()
        #expect(system.string(id) == "hey\nyo")
        #expect(system.texts[id]!.start == 6)
    }

    @Test func aKeyboardRewritingTheWordItComposesIsTheSameStep() {
        let (storage, id) = storage("I ")
        system.touch(id, 2)
        // Gboard replaces the word it's composing at each key, and once more
        // with its correction and a space.
        system.edit(id, 2, 2, "s")
        system.edit(id, 2, 3, "sa")
        system.edit(id, 2, 4, "saq")
        system.edit(id, 2, 5, "sa")
        system.edit(id, 2, 4, "saw ")
        #expect(system.string(id) == "I saw ")
        storage.undo()
        #expect(system.string(id) == "I ")
        #expect(system.texts[id]!.start == 2)
        storage.redo()
        #expect(system.string(id) == "I saw ")
    }

    @Test func movingTheCaretEndsTheStep() {
        let (storage, id) = storage()
        system.type(id, "a")
        system.type(id, "b")
        system.touch(id, 0)
        system.type(id, "c")
        #expect(system.string(id) == "cab")
        storage.undo()
        #expect(system.string(id) == "ab")
        #expect(system.texts[id]!.start == 0)
        storage.undo()
        #expect(system.string(id) == "")
    }

    @Test func theGuestsEditEndsTheUsersStepAndANewEditDropsTheRedo() {
        let (storage, id) = storage()
        system.type(id, "a")
        storage.replace(1, length: 0, text: "!")
        system.type(id, "b")
        #expect(system.string(id) == "a!b")
        storage.undo()
        #expect(system.string(id) == "a!")
        storage.undo()
        #expect(system.string(id) == "a")
        _ = recorder.take()
        system.type(id, "z")
        #expect(recorder.take().contains("undo true false"))
        storage.redo()
        #expect(system.string(id) == "az")
    }

    @Test func linesAndPositionsComeFromTheView() {
        let (storage, id) = storage("one\ntwo\nthree")
        #expect(storage.lineCount() == 3)
        #expect(storage.line(5) == 1)
        #expect(storage.lineStart(2) == 8)
        #expect(storage.lineStart(3) == -1)
        #expect(storage.substring(4, length: 3) == "two")
        // Past the end: cut to the text.
        #expect(storage.substring(8, length: 99) == "three")
        storage.reveal(4, length: 3)
        #expect(system.calls.last == "reveal 4 7")
        #expect(system.texts[id] != nil)
    }
}
