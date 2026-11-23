import AndroidHost
import DynamicRuntime
import DynamicText
import RuntimeHost
import RuntimeText

/// Every text, by identifier, and what their `EditText`s report: the
/// Kotlin side's `TextNatives` call these on the main thread. Main thread
/// only.
public final class TextHub {

    nonisolated(unsafe) public static let shared = TextHub()

    /// Makes the system on first use; `AndroidHostApp` sets it.
    public var makeSystem: (() -> any TextSystem)?

    private var _system: (any TextSystem)?

    var system: any TextSystem {
        if let _system {
            return _system
        }
        guard let makeSystem else {
            fatalError("TextHub.makeSystem isn't set")
        }
        let system = makeSystem()
        _system = system
        return system
    }

    private struct Entry {
        weak var engine: EditTextEngine?
    }

    private var engines: [Int32: Entry] = [:]

    public init() { }

    /// Replaces the system, for tests.
    public func use(_ system: (any TextSystem)?) {
        _system = system
        engines = [:]
    }

    func register(_ engine: EditTextEngine) {
        engines[engine.id] = Entry(engine: engine)
    }

    func unregister(_ id: Int32) {
        engines[id] = nil
    }

    // MARK: From the views

    /// The user's edit of text `id`: `removed` at `location` became `inserted`.
    public func edited(_ id: Int32, location: Int32, removed: String, inserted: String) {
        engines[id]?.engine?.userEdited(at: Int(location), removed: removed, inserted: inserted)
    }

    /// Text `id`'s selection moved.
    public func selected(_ id: Int32) {
        engines[id]?.engine?.selectionMoved()
    }
}

/// `HostTextStorage`'s platform on Android: an `EditText` per text.
public final class AndroidTextPlatform: TextPlatform {

    /// `EditText` lays out the whole text, and a phone holds it: a
    /// megabyte's worth of UTF-16 units, far less than the Darwin host's.
    public static let maximumLength = 1 << 20

    public init() { }

    public func makeEngine(for storage: HostTextStorage) -> any TextEngine {
        EditTextEngine(storage: storage, system: TextHub.shared.system)
    }

    public var maximumLength: Int {
        Self.maximumLength
    }
}

/// The text contract (`Plan.md` §6.16): AppRuntime's `HostTextStorage`,
/// which reads and writes files off the main thread, through `HostFiles`;
/// decodes and encodes the five encodings every host has; keeps `\n` as
/// the only line break; moves positions out of surrogate pairs; keeps
/// whether the text is modified; and searches. This module gives it an
/// `EditText` per text. No capability: a text is memory, and its files are
/// reached by `Files`' rules.
public enum AndroidHostText: HostModule {

    public static var contracts: [ContractDescriptor] {
        HostTextModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostTextModule.register(in: registrar)
    }

    /// Points `HostTextStorage` at the Kotlin `TextSystem`, and its answers
    /// at the main looper. Main thread.
    public static func configure(_ makeSystem: @escaping () -> any TextSystem) {
        TextHub.shared.makeSystem = makeSystem
        HostTextStorage.platform = AndroidTextPlatform()
        HostTextStorage.deliver = { job in MainLooper.shared.post(job) }
    }
}
