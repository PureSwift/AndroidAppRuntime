import AndroidHost
import DynamicGraphics

/// A drawable's size as the guest last heard it from `resize`.
struct DrawableSize: Equatable {
    var width: Int32
    var height: Int32
    var scale: Float
}

/// Every surface and the views showing them (§8.2, §8.6): it gives a
/// surface frames while its view is on screen and the app is active,
/// delivers the view's input, and replaces a lost context. Main thread
/// only.
///
/// The Kotlin `GraphicsView`s report through `AndroidHostApp`'s
/// `GraphicsNatives`; a view says which surface it shows by its ID.
public final class SurfaceHub {

    nonisolated(unsafe) public static let shared = SurfaceHub()

    /// Makes the system on first use; `AndroidHostApp` sets it.
    public var makeSystem: (() -> any GraphicsSystem)?

    /// The views' pointer capture; `AndroidHostApp` sets it.
    public var views: (any SurfaceViews)?

    private var _system: (any GraphicsSystem)?

    var system: any GraphicsSystem {
        if let _system {
            return _system
        }
        guard let makeSystem else {
            fatalError("SurfaceHub.makeSystem isn't set")
        }
        let system = makeSystem()
        _system = system
        return system
    }

    private final class Entry {
        weak var surface: AndroidSurface?
        init(_ surface: AndroidSurface) {
            self.surface = surface
        }
    }

    private var surfaces: [Int32: Entry] = [:]

    private var nextID: Int32 = 1

    /// A pointer's latest position.
    struct Pointer {
        var kind: PointerKind
        var x: Float
        var y: Float
        var buttons: PointerButtons
        var timestamp: Int64
    }

    /// A view showing a surface, with a drawable.
    struct View {
        var size: DrawableSize
        var visible = true
        var focused = false
        var captured = false
        /// Pointers in contact, by the contract's ID.
        var contacts: [Int32: Pointer] = [:]
        /// Moves waiting for the next frame, one per pointer.
        var moves: [Int32: Pointer] = [:]
        /// Captured movement waiting for the next frame, summed.
        var delta: (x: Float, y: Float, timestamp: Int64)?
    }

    private(set) var windows: [Int32: View] = [:]

    /// Whether the app is active (`ApplicationState`); no frames otherwise.
    public private(set) var isActive = false

    private var frameRequested = false

    /// False once a lost context couldn't be replaced: nothing draws.
    private var hasContext = true

    public init() { }

    /// Replaces the system, for tests.
    public func use(_ system: (any GraphicsSystem)?) {
        _system = system
        surfaces = [:]
        windows = [:]
        isActive = false
        frameRequested = false
        hasContext = true
    }

    // MARK: Surfaces

    func register(_ surface: AndroidSurface) -> Int32 {
        let id = nextID
        nextID += 1
        surfaces[id] = Entry(surface)
        return id
    }

    func unregister(_ id: Int32) {
        surfaces[id] = nil
    }

    private func live(_ id: Int32) -> AndroidSurface? {
        surfaces[id]?.surface
    }

    func setPointerCaptured(_ id: Int32, captured: Bool) -> Bool {
        guard windows[id] != nil, let views else { return false }
        return views.setPointerCaptured(id, captured: captured)
    }

    // MARK: Views

    /// A view showing surface `id` has a window: a drawable for it, and
    /// frames.
    public func attach(_ id: Int32, window: UnsafeMutableRawPointer, width: Int32, height: Int32, scale: Float) {
        if windows[id] != nil {
            detach(id)
        }
        guard system.attach(id, window: window) else {
            HostLog.error("GLSurface \(id): EGL can't draw in its view")
            return
        }
        windows[id] = View(size: DrawableSize(width: width, height: height, scale: scale))
        requestFrameIfNeeded()
    }

    /// The view's size in pixels, or its scale, changed; the guest hears
    /// before the next frame.
    public func resize(_ id: Int32, width: Int32, height: Int32, scale: Float) {
        windows[id]?.size = DrawableSize(width: width, height: height, scale: scale)
    }

    /// The view's window is gone, or the view left the tree.
    public func detach(_ id: Int32) {
        guard windows[id] != nil else { return }
        endInput(id)
        system.detach(id)
        windows[id] = nil
    }

    /// Whether the view is visible; a hidden one gets no frames.
    public func setVisible(_ id: Int32, visible: Bool) {
        guard windows[id] != nil else { return }
        windows[id]?.visible = visible
        if !visible {
            cancelPointers(id)
        }
        requestFrameIfNeeded()
    }

    /// The app's state: frames run only while it's active, and becoming
    /// inactive ends every view's input.
    public func setActive(_ active: Bool) {
        isActive = active
        if active {
            requestFrameIfNeeded()
        } else {
            for id in windows.keys.sorted() {
                endInput(id)
            }
        }
    }

    // MARK: Input

    /// One pointer of a `MotionEvent`, with its raw values (`InputMapping`).
    /// `eventTime` is `MotionEvent.getEventTime()`, in milliseconds.
    public func pointer(_ id: Int32, action: Int32, isActionPointer: Bool, pointerID: Int32, toolType: Int32,
                        x: Float, y: Float, buttonState: Int32, eventTime: Int64) {
        guard windows[id] != nil, let surface = live(id),
              let phase = InputMapping.phase(action: action, isActionPointer: isActionPointer) else { return }
        let kind = InputMapping.kind(toolType: toolType)
        let pointer = InputMapping.pointerID(pointerID, kind: kind)
        let buttons = InputMapping.buttons(kind: kind, action: action, phase: phase, buttonState: buttonState)
        let event = Pointer(kind: kind, x: x, y: y, buttons: buttons, timestamp: system.timestamp(monotonic: eventTime * 1_000_000))
        switch phase {
        case .move:
            if windows[id]?.contacts[pointer] != nil {
                windows[id]?.contacts[pointer] = event
            }
            windows[id]?.moves[pointer] = event
            requestFrameIfNeeded()
        case .down:
            flushMove(id, pointer: pointer, surface: surface)
            windows[id]?.contacts[pointer] = event
            send(surface, pointer: pointer, phase: .down, event)
        case .up:
            guard windows[id]?.contacts[pointer] != nil else { return }
            flushMove(id, pointer: pointer, surface: surface)
            windows[id]?.contacts[pointer] = nil
            send(surface, pointer: pointer, phase: .up, event)
        case .cancel:
            cancelPointers(id)
        }
    }

    /// A wheel or trackpad scroll's raw axes and the view's scroll factors.
    public func scroll(_ id: Int32, horizontal: Float, vertical: Float, horizontalFactor: Float, verticalFactor: Float) {
        guard windows[id] != nil, let surface = live(id) else { return }
        let (x, y) = InputMapping.scroll(horizontal: horizontal, vertical: vertical,
                                         horizontalFactor: horizontalFactor, verticalFactor: verticalFactor)
        surface.delegate.scroll(surface, x: x, y: y)
    }

    /// A `KeyEvent` (`ACTION_DOWN` 0 or `ACTION_UP` 1); whether the surface
    /// took it. Keys the contract doesn't carry stay the system's.
    public func key(_ id: Int32, action: Int32, keyCode: Int32, scanCode: Int32, metaState: Int32,
                    repeatCount: Int32, eventTime: Int64) -> Bool {
        guard windows[id] != nil, let surface = live(id), action == 0 || action == 1,
              let code = InputMapping.keyCode(scanCode: scanCode, keyCode: keyCode) else { return false }
        surface.delegate.key(surface, code: code.rawValue, pressed: action == 0,
                             modifiers: InputMapping.modifiers(metaState: metaState).rawValue,
                             isRepeat: repeatCount > 0, timestamp: system.timestamp(monotonic: eventTime * 1_000_000))
        return true
    }

    /// The view gained or lost keyboard focus, in a window that has it.
    /// Before a loss, every pointer in contact is cancelled.
    public func focus(_ id: Int32, focused: Bool) {
        guard let view = windows[id], view.focused != focused else { return }
        if !focused {
            cancelPointers(id)
        }
        windows[id]?.focused = focused
        if let surface = live(id) {
            surface.delegate.focus(surface, focused: focused)
        }
    }

    /// Pointer capture began or ended (`View.onPointerCaptureChange`).
    public func captureChanged(_ id: Int32, captured: Bool) {
        guard let view = windows[id], view.captured != captured else { return }
        windows[id]?.captured = captured
        if let surface = live(id) {
            surface.delegate.pointerCapture(surface, captured: captured)
        }
    }

    /// Captured mouse movement, in pixels; summed until the next frame.
    public func relative(_ id: Int32, x: Float, y: Float, eventTime: Int64) {
        guard windows[id]?.captured == true else { return }
        let timestamp = system.timestamp(monotonic: eventTime * 1_000_000)
        let sum = windows[id]?.delta
        windows[id]?.delta = ((sum?.x ?? 0) + x, (sum?.y ?? 0) + y, timestamp)
        requestFrameIfNeeded()
    }

    private func send(_ surface: AndroidSurface, pointer: Int32, phase: PointerPhase, _ event: Pointer) {
        surface.delegate.pointer(surface, id: pointer, kind: event.kind.rawValue, phase: phase.rawValue,
                                 x: event.x, y: event.y, buttons: event.buttons.rawValue, timestamp: event.timestamp)
    }

    /// Sends `pointer`'s waiting move, so it comes before what follows.
    private func flushMove(_ id: Int32, pointer: Int32, surface: AndroidSurface) {
        guard let move = windows[id]?.moves.removeValue(forKey: pointer) else { return }
        send(surface, pointer: pointer, phase: .move, move)
    }

    /// Sends every waiting move and the captured movement, before a frame.
    private func flushInput(_ id: Int32, surface: AndroidSurface) {
        let moves = windows[id]?.moves ?? [:]
        windows[id]?.moves = [:]
        for pointer in moves.keys.sorted() {
            send(surface, pointer: pointer, phase: .move, moves[pointer]!)
        }
        if let delta = windows[id]?.delta {
            windows[id]?.delta = nil
            surface.delegate.pointerDelta(surface, x: delta.x, y: delta.y, timestamp: delta.timestamp)
        }
    }

    /// Cancels every pointer in contact, dropping waiting moves.
    private func cancelPointers(_ id: Int32) {
        guard let view = windows[id] else { return }
        windows[id]?.moves = [:]
        windows[id]?.delta = nil
        windows[id]?.contacts = [:]
        guard let surface = live(id) else { return }
        let now = MainLooper.now()
        for pointer in view.contacts.keys.sorted() {
            var event = view.contacts[pointer]!
            event.buttons = []
            event.timestamp = now
            send(surface, pointer: pointer, phase: .cancel, event)
        }
    }

    /// No stuck input (§8.6): pointers cancelled, then focus and capture
    /// lost.
    private func endInput(_ id: Int32) {
        focus(id, focused: false)
        cancelPointers(id)
        captureChanged(id, captured: false)
    }

    // MARK: Frames

    private func requestFrameIfNeeded() {
        guard isActive, hasContext, !frameRequested,
              windows.contains(where: { $0.value.visible && live($0.key) != nil }) else { return }
        frameRequested = true
        system.requestFrame { [weak self] timestamp in
            self?.frame(timestamp: timestamp)
        }
    }

    /// A display refresh: each visible view's waiting input, then its
    /// surface's frame, in the context, presented.
    func frame(timestamp: Int64) {
        frameRequested = false
        guard isActive, hasContext else { return }
        var lost = false
        for id in windows.keys.sorted() {
            guard windows[id]?.visible == true else { continue }
            if let surface = live(id) {
                flushInput(id, surface: surface)
            }
            // The guest may have let the surface go in an input callback.
            guard let surface = live(id), let size = windows[id]?.size, size.width > 0, size.height > 0 else { continue }
            if surface.reported != size {
                surface.reported = size
                surface.delegate.resize(surface, width: size.width, height: size.height, scale: size.scale)
            }
            switch system.begin(id) {
            case .failed:
                continue
            case .contextLost:
                lost = true
            case .ok:
                surface.delegate.frame(surface, timestamp: timestamp, width: size.width, height: size.height)
                lost = system.end(id) == .contextLost
            }
            if lost {
                break
            }
        }
        if lost {
            replaceContext()
        }
        requestFrameIfNeeded()
    }

    /// Every surface hears the context is gone, then, with a new one, that
    /// it's back (§8.2).
    private func replaceContext() {
        let lost = surfaces.keys.sorted().compactMap { live($0) }
        for surface in lost {
            surface.delegate.contextLost(surface)
        }
        guard system.replaceContext() else {
            HostLog.error("the GL context was lost and no new one could be made; surfaces stop drawing")
            hasContext = false
            return
        }
        for surface in lost where live(surface.id) != nil {
            surface.delegate.contextRestored(surface)
        }
    }
}
