import DynamicGraphics

/// Android's input as the `SurfaceDelegate` contract has it (§8.6). Kotlin
/// passes `MotionEvent`'s and `KeyEvent`'s raw values; this maps them.
public enum InputMapping {

    // MARK: Pointers

    /// `MotionEvent.ACTION_*`.
    public enum Action {
        public static let down: Int32 = 0
        public static let up: Int32 = 1
        public static let move: Int32 = 2
        public static let cancel: Int32 = 3
        public static let pointerDown: Int32 = 5
        public static let pointerUp: Int32 = 6
        public static let hoverMove: Int32 = 7
        public static let hoverEnter: Int32 = 9
        public static let buttonPress: Int32 = 11
        public static let buttonRelease: Int32 = 12
    }

    /// `MotionEvent.TOOL_TYPE_*`.
    public enum ToolType {
        public static let finger: Int32 = 1
        public static let stylus: Int32 = 2
        public static let mouse: Int32 = 3
        public static let eraser: Int32 = 4
    }

    /// `MotionEvent.BUTTON_STYLUS_PRIMARY`.
    static let stylusPrimary: Int32 = 0x20

    public static func kind(toolType: Int32) -> PointerKind {
        switch toolType {
        case ToolType.mouse: .mouse
        case ToolType.stylus, ToolType.eraser: .pen
        default: .touch
        }
    }

    /// The phase for one pointer of an event: `isActionPointer` says
    /// whether the event's action is about this pointer. Nil when this
    /// pointer has nothing to report.
    public static func phase(action: Int32, isActionPointer: Bool) -> PointerPhase? {
        switch action {
        case Action.down, Action.pointerDown: isActionPointer ? .down : nil
        case Action.up, Action.pointerUp: isActionPointer ? .up : nil
        case Action.move, Action.hoverMove, Action.hoverEnter, Action.buttonPress, Action.buttonRelease: .move
        case Action.cancel: .cancel
        default: nil
        }
    }

    /// The contract's pointer ID: the mouse is always 0, so Android's IDs,
    /// which start at 0, move up one.
    public static func pointerID(_ id: Int32, kind: PointerKind) -> Int32 {
        kind == .mouse ? 0 : id + 1
    }

    /// The buttons held. A touch or pen in contact holds `primary`; a
    /// hovering one holds none. `MotionEvent.BUTTON_PRIMARY`, `SECONDARY`
    /// and `TERTIARY` are the contract's bits already.
    public static func buttons(kind: PointerKind, action: Int32, phase: PointerPhase, buttonState: Int32) -> PointerButtons {
        let hovering = action == Action.hoverMove || action == Action.hoverEnter
        switch kind {
        case .mouse:
            let held = PointerButtons(rawValue: buttonState & 7)
            // Some mice, and adb's, report a press with no buttons.
            return held.isEmpty && phase == .down ? .primary : held
        case .touch, .pen:
            guard !hovering, phase == .down || phase == .move else { return [] }
            var held: PointerButtons = .primary
            if kind == .pen, buttonState & stylusPrimary != 0 {
                held.insert(.secondary)
            }
            return held
        }
    }

    /// A wheel or trackpad's `AXIS_HSCROLL` and `AXIS_VSCROLL`, times
    /// `ViewConfiguration`'s scaled scroll factors, as the pixels content
    /// moves: up a notch (`AXIS_VSCROLL` 1) moves it down; right moves it
    /// left.
    public static func scroll(horizontal: Float, vertical: Float, horizontalFactor: Float, verticalFactor: Float) -> (x: Float, y: Float) {
        (-horizontal * horizontalFactor, vertical * verticalFactor)
    }

    // MARK: Keys

    /// `KeyEvent.META_*` to `KeyModifiers`.
    public static func modifiers(metaState: Int32) -> KeyModifiers {
        var modifiers: KeyModifiers = []
        if metaState & 0x1 != 0 { modifiers.insert(.shift) }
        if metaState & 0x1000 != 0 { modifiers.insert(.control) }
        if metaState & 0x2 != 0 { modifiers.insert(.alt) }
        if metaState & 0x10000 != 0 { modifiers.insert(.meta) }
        return modifiers
    }

    /// The physical key: from the scan code, a Linux key code, which names
    /// the position; else, for keys with no scan code (`adb shell input`,
    /// some virtual keyboards), from the key code. Nil for keys the
    /// contract doesn't carry, such as Back and the volume keys, which
    /// stay the system's.
    public static func keyCode(scanCode: Int32, keyCode: Int32) -> KeyCode? {
        if scanCode != 0, let usage = scanCodes[scanCode] {
            return KeyCode(rawValue: usage)
        }
        return keyCodes[keyCode].map(KeyCode.init(rawValue:))
    }

    /// Linux `KEY_*` codes to HID usage IDs (page 0x07).
    static let scanCodes: [Int32: Int32] = {
        var table: [Int32: Int32] = [
            1: 0x29, 12: 0x2D, 13: 0x2E, 14: 0x2A, 15: 0x2B,
            26: 0x2F, 27: 0x30, 28: 0x28, 29: 0xE0,
            39: 0x33, 40: 0x34, 41: 0x35, 42: 0xE1, 43: 0x31,
            51: 0x36, 52: 0x37, 53: 0x38, 54: 0xE5, 55: 0x55, 56: 0xE2, 57: 0x2C, 58: 0x39,
            69: 0x53, 70: 0x47,
            71: 0x5F, 72: 0x60, 73: 0x61, 74: 0x56, 75: 0x5C, 76: 0x5D, 77: 0x5E, 78: 0x57,
            79: 0x59, 80: 0x5A, 81: 0x5B, 82: 0x62, 83: 0x63,
            86: 0x64, 87: 0x44, 88: 0x45, 96: 0x58, 97: 0xE4, 98: 0x54, 99: 0x46, 100: 0xE6,
            102: 0x4A, 103: 0x52, 104: 0x4B, 105: 0x50, 106: 0x4F, 107: 0x4D, 108: 0x51, 109: 0x4E,
            110: 0x49, 111: 0x4C, 119: 0x48, 125: 0xE3, 126: 0xE7, 127: 0x65,
        ]
        // 1 to 9, then 0.
        for digit in Int32(1)...10 {
            table[digit + 1] = 0x1D + digit
        }
        // The letter rows, as positions.
        let rows: [(first: Int32, letters: String)] = [(16, "qwertyuiop"), (30, "asdfghjkl"), (44, "zxcvbnm")]
        for row in rows {
            for (offset, letter) in row.letters.unicodeScalars.enumerated() {
                table[row.first + Int32(offset)] = 0x04 + Int32(letter.value - 97)
            }
        }
        // F1 to F10.
        for number in Int32(0)..<10 {
            table[59 + number] = 0x3A + number
        }
        return table
    }()

    /// `KeyEvent.KEYCODE_*` to HID usage IDs, for keys without a scan code.
    static let keyCodes: [Int32: Int32] = {
        var table: [Int32: Int32] = [
            7: 0x27,
            19: 0x52, 20: 0x51, 21: 0x50, 22: 0x4F,
            55: 0x36, 56: 0x37, 57: 0xE2, 58: 0xE6, 59: 0xE1, 60: 0xE5, 61: 0x2B, 62: 0x2C,
            66: 0x28, 67: 0x2A, 68: 0x35, 69: 0x2D, 70: 0x2E, 71: 0x2F, 72: 0x30, 73: 0x31,
            74: 0x33, 75: 0x34, 76: 0x38, 92: 0x4B, 93: 0x4E,
            111: 0x29, 112: 0x4C, 113: 0xE0, 114: 0xE4, 115: 0x39, 116: 0x47, 117: 0xE3, 118: 0xE7,
            120: 0x46, 121: 0x48, 122: 0x4A, 123: 0x4D, 124: 0x49,
            143: 0x53, 144: 0x62, 154: 0x54, 155: 0x55, 156: 0x56, 157: 0x57, 158: 0x63, 160: 0x58,
        ]
        // 1 to 9.
        for digit in Int32(1)...9 {
            table[7 + digit] = 0x1D + digit
        }
        // A to Z are in order in both.
        for letter in Int32(0)..<26 {
            table[29 + letter] = 0x04 + letter
        }
        // F1 to F12.
        for number in Int32(0)..<12 {
            table[131 + number] = 0x3A + number
        }
        // Keypad 1 to 9.
        for digit in Int32(0)..<9 {
            table[145 + digit] = 0x59 + digit
        }
        return table
    }()
}
