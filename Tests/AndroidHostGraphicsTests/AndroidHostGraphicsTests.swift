import AndroidHost
@testable import AndroidHostGraphics
import DynamicGraphics
import DynamicRuntime
import Testing

/// EGL as the tests set it up: it records what the hub asks, and runs a
/// frame when the test says.
final class FakeGraphicsSystem: GraphicsSystem {

    var log: [String] = []
    var attached: Set<Int32> = []
    var current: Int32?
    var refuseAttach = false
    var loseOnEnd = false
    var replaced = 0
    private var frame: ((Int64) -> Void)?

    var frameRequested: Bool { frame != nil }

    func attach(_ surface: Int32, window: UnsafeMutableRawPointer) -> Bool {
        guard !refuseAttach else { return false }
        attached.insert(surface)
        log.append("attach \(surface)")
        return true
    }

    func detach(_ surface: Int32) {
        attached.remove(surface)
        log.append("detach \(surface)")
    }

    func begin(_ surface: Int32) -> GraphicsResult {
        current = surface
        return .ok
    }

    func end(_ surface: Int32) -> GraphicsResult {
        current = nil
        log.append("present \(surface)")
        if loseOnEnd {
            loseOnEnd = false
            return .contextLost
        }
        return .ok
    }

    func replaceContext() -> Bool {
        replaced += 1
        log.append("new context")
        return true
    }

    func requestFrame(_ frame: @escaping (Int64) -> Void) {
        self.frame = frame
    }

    /// Input times are milliseconds since boot here, times a million.
    func timestamp(monotonic nanoseconds: Int64) -> Int64 {
        nanoseconds
    }

    /// Runs the requested frame, if there is one.
    @discardableResult
    func fire(_ timestamp: Int64) -> Bool {
        guard let frame else { return false }
        self.frame = nil
        frame(timestamp)
        return true
    }
}

/// A delegate that writes down each call, and whether GL was current.
final class RecordingDelegate: SurfaceDelegate {

    var events: [String] = []
    weak var system: FakeGraphicsSystem?
    var onPointer: ((Int32) -> Void)?

    func frame(_ surface: any Surface, timestamp: Int64, width: Int32, height: Int32) {
        events.append("frame \(timestamp) \(width)x\(height) current \(system?.current == surface.identifier())")
    }

    func resize(_ surface: any Surface, width: Int32, height: Int32, scale: Float) {
        events.append("resize \(width)x\(height)@\(scale) current \(system?.current != nil)")
    }

    func contextLost(_ surface: any Surface) {
        events.append("lost")
    }

    func contextRestored(_ surface: any Surface) {
        events.append("restored")
    }

    func pointer(_ surface: any Surface, id: Int32, kind: Int32, phase: Int32, x: Float, y: Float, buttons: Int32, timestamp: Int64) {
        let phases = ["down", "move", "up", "cancel"]
        events.append("pointer \(id) \(phases[Int(phase)]) kind \(kind) \(x),\(y) buttons \(buttons) at \(timestamp)")
        onPointer?(phase)
    }

    func pointerDelta(_ surface: any Surface, x: Float, y: Float, timestamp: Int64) {
        events.append("delta \(x),\(y) at \(timestamp)")
    }

    func scroll(_ surface: any Surface, x: Float, y: Float) {
        events.append("scroll \(x),\(y)")
    }

    func key(_ surface: any Surface, code: Int32, pressed: Bool, modifiers: Int32, isRepeat: Bool, timestamp: Int64) {
        events.append("key \(code) \(pressed ? "down" : "up") modifiers \(modifiers)\(isRepeat ? " repeat" : "")")
    }

    func focus(_ surface: any Surface, focused: Bool) {
        events.append("focus \(focused)")
    }

    func pointerCapture(_ surface: any Surface, captured: Bool) {
        events.append("capture \(captured)")
    }
}

final class FakeViews: SurfaceViews {
    var requests: [String] = []
    func setPointerCaptured(_ surface: Int32, captured: Bool) -> Bool {
        requests.append("\(surface) \(captured)")
        return captured
    }
}

/// A window pointer: the fake never dereferences it.
let window = UnsafeMutableRawPointer(bitPattern: 0x1000)!

/// A hub with a fake system, an active app, and one surface on screen.
func scene(attach: Bool = true) -> (SurfaceHub, FakeGraphicsSystem, RecordingDelegate, AndroidSurface) {
    let hub = SurfaceHub()
    let system = FakeGraphicsSystem()
    hub.use(system)
    let delegate = RecordingDelegate()
    delegate.system = system
    let surface = AndroidSurface(delegate: delegate, hub: hub)
    hub.setActive(true)
    if attach {
        hub.attach(surface.id, window: window, width: 200, height: 100, scale: 2)
    }
    return (hub, system, delegate, surface)
}

@Suite("Surface and frames")
struct SurfaceFrameTests {

    @Test func identifiersAreUniqueAndNeverReused() {
        let hub = SurfaceHub()
        hub.use(FakeGraphicsSystem())
        let delegate = RecordingDelegate()
        var first: AndroidSurface? = AndroidSurface(delegate: delegate, hub: hub)
        let firstID = first!.identifier()
        first = nil
        let second = AndroidSurface(delegate: delegate, hub: hub)
        #expect(firstID == 1)
        #expect(second.identifier() == 2)
    }

    @Test func noFramesWithoutAView() {
        let (_, system, _, _) = scene(attach: false)
        #expect(!system.frameRequested)
    }

    @Test func resizeComesBeforeTheFirstFrameAndGLIsCurrentOnlyInFrame() {
        let (_, system, delegate, surface) = scene()
        #expect(system.attached == [surface.id])
        #expect(system.fire(1_000))
        #expect(delegate.events == ["resize 200x100@2.0 current false", "frame 1000 200x100 current true"])
        #expect(system.current == nil)
        #expect(system.log.last == "present \(surface.id)")
        // Frames continue, without another resize.
        #expect(system.fire(2_000))
        #expect(delegate.events.last == "frame 2000 200x100 current true")
        #expect(delegate.events.count == 3)
    }

    @Test func aNewSizeIsReportedBeforeTheFrameThatUsesIt() {
        let (hub, system, delegate, surface) = scene()
        system.fire(1)
        hub.resize(surface.id, width: 300, height: 150, scale: 2)
        system.fire(2)
        #expect(delegate.events.suffix(2) == ["resize 300x150@2.0 current false", "frame 2 300x150 current true"])
    }

    @Test func noFramesWhileInactiveOrHidden() {
        let (hub, system, delegate, surface) = scene()
        hub.setActive(false)
        system.fire(1)
        #expect(delegate.events.isEmpty)
        #expect(!system.frameRequested)
        hub.setActive(true)
        hub.setVisible(surface.id, visible: false)
        system.fire(2)
        #expect(delegate.events.isEmpty)
        #expect(!system.frameRequested)
        hub.setVisible(surface.id, visible: true)
        #expect(system.fire(3))
        #expect(delegate.events.last == "frame 3 200x100 current true")
    }

    @Test func aReleasedSurfaceStopsDrawingAndADetachedViewReleasesItsDrawable() {
        var (hub, system, delegate, surface): (SurfaceHub, FakeGraphicsSystem, RecordingDelegate, AndroidSurface?) = scene()
        let id = surface!.id
        surface = nil
        system.fire(1)
        #expect(delegate.events.isEmpty)
        hub.detach(id)
        #expect(system.attached.isEmpty)
    }

    @Test func aRefusedViewGetsNoFrames() {
        let hub = SurfaceHub()
        let system = FakeGraphicsSystem()
        system.refuseAttach = true
        hub.use(system)
        let surface = AndroidSurface(delegate: RecordingDelegate(), hub: hub)
        hub.setActive(true)
        hub.attach(surface.id, window: window, width: 10, height: 10, scale: 1)
        #expect(!system.frameRequested)
    }

    @Test func aLostContextIsReplacedAndEverySurfaceHears() {
        let (hub, system, delegate, surface) = scene()
        let other = RecordingDelegate()
        let second = AndroidSurface(delegate: other, hub: hub)
        system.fire(1)
        system.loseOnEnd = true
        system.fire(2)
        #expect(system.replaced == 1)
        #expect(delegate.events.suffix(3) == ["frame 2 200x100 current true", "lost", "restored"])
        #expect(other.events == ["lost", "restored"])
        // Drawing goes on in the new context.
        #expect(system.fire(3))
        #expect(delegate.events.last == "frame 3 200x100 current true")
        _ = (surface, second)
    }
}

@Suite("Surface input")
struct SurfaceInputTests {

    typealias Action = InputMapping.Action

    @Test func movesAreCoalescedAndDeliveredBeforeTheFrame() {
        let (hub, system, delegate, surface) = scene()
        system.fire(1)
        delegate.events = []
        hub.pointer(surface.id, action: Action.down, isActionPointer: true, pointerID: 0, toolType: 1, x: 1, y: 1, buttonState: 0, eventTime: 10)
        hub.pointer(surface.id, action: Action.move, isActionPointer: false, pointerID: 0, toolType: 1, x: 2, y: 2, buttonState: 0, eventTime: 11)
        hub.pointer(surface.id, action: Action.move, isActionPointer: false, pointerID: 0, toolType: 1, x: 3, y: 3, buttonState: 0, eventTime: 12)
        #expect(delegate.events == ["pointer 1 down kind 0 1.0,1.0 buttons 1 at 10000000"])
        system.fire(20)
        #expect(delegate.events.suffix(2) == ["pointer 1 move kind 0 3.0,3.0 buttons 1 at 12000000", "frame 20 200x100 current true"])
    }

    @Test func aWaitingMoveIsSentBeforeTheUpThatFollowsIt() {
        let (hub, _, delegate, surface) = scene()
        hub.pointer(surface.id, action: Action.down, isActionPointer: true, pointerID: 0, toolType: 1, x: 1, y: 1, buttonState: 0, eventTime: 1)
        hub.pointer(surface.id, action: Action.move, isActionPointer: false, pointerID: 0, toolType: 1, x: 5, y: 5, buttonState: 0, eventTime: 2)
        hub.pointer(surface.id, action: Action.up, isActionPointer: true, pointerID: 0, toolType: 1, x: 5, y: 5, buttonState: 0, eventTime: 3)
        #expect(delegate.events == [
            "pointer 1 down kind 0 1.0,1.0 buttons 1 at 1000000",
            "pointer 1 move kind 0 5.0,5.0 buttons 1 at 2000000",
            "pointer 1 up kind 0 5.0,5.0 buttons 0 at 3000000",
        ])
    }

    @Test func aSecondFingerIsItsOwnPointer() {
        let (hub, _, delegate, surface) = scene()
        hub.pointer(surface.id, action: Action.down, isActionPointer: true, pointerID: 0, toolType: 1, x: 1, y: 1, buttonState: 0, eventTime: 1)
        // ACTION_POINTER_DOWN names both pointers; only the new one is down.
        hub.pointer(surface.id, action: Action.pointerDown, isActionPointer: false, pointerID: 0, toolType: 1, x: 1, y: 1, buttonState: 0, eventTime: 2)
        hub.pointer(surface.id, action: Action.pointerDown, isActionPointer: true, pointerID: 1, toolType: 1, x: 9, y: 9, buttonState: 0, eventTime: 2)
        #expect(delegate.events.last == "pointer 2 down kind 0 9.0,9.0 buttons 1 at 2000000")
        #expect(delegate.events.count == 2)
    }

    @Test func losingFocusCancelsPointersThenReportsIt() {
        let (hub, _, delegate, surface) = scene()
        hub.focus(surface.id, focused: true)
        hub.pointer(surface.id, action: Action.down, isActionPointer: true, pointerID: 0, toolType: 1, x: 4, y: 4, buttonState: 0, eventTime: 1)
        hub.focus(surface.id, focused: false)
        #expect(delegate.events.count == 4)
        #expect(delegate.events[0] == "focus true")
        #expect(delegate.events[2].hasPrefix("pointer 1 cancel kind 0 4.0,4.0 buttons 0"))
        #expect(delegate.events[3] == "focus false")
        // Said once.
        hub.focus(surface.id, focused: false)
        #expect(delegate.events.count == 4)
    }

    @Test func becomingInactiveEndsAllInput() {
        let (hub, _, delegate, surface) = scene()
        hub.focus(surface.id, focused: true)
        hub.captureChanged(surface.id, captured: true)
        hub.pointer(surface.id, action: Action.down, isActionPointer: true, pointerID: 0, toolType: 3, x: 4, y: 4, buttonState: 1, eventTime: 1)
        delegate.events = []
        hub.setActive(false)
        #expect(delegate.events.count == 3)
        #expect(delegate.events[0].hasPrefix("pointer 0 cancel kind 1"))
        #expect(delegate.events[1] == "focus false")
        #expect(delegate.events[2] == "capture false")
    }

    @Test func aCancelledGestureCancelsEveryContact() {
        let (hub, _, delegate, surface) = scene()
        hub.pointer(surface.id, action: Action.down, isActionPointer: true, pointerID: 0, toolType: 1, x: 1, y: 1, buttonState: 0, eventTime: 1)
        hub.pointer(surface.id, action: Action.pointerDown, isActionPointer: true, pointerID: 1, toolType: 1, x: 2, y: 2, buttonState: 0, eventTime: 1)
        hub.pointer(surface.id, action: Action.cancel, isActionPointer: false, pointerID: 0, toolType: 1, x: 1, y: 1, buttonState: 0, eventTime: 2)
        #expect(delegate.events.filter { $0.contains("cancel") }.count == 2)
        // No up follows a cancel.
        hub.pointer(surface.id, action: Action.up, isActionPointer: true, pointerID: 0, toolType: 1, x: 1, y: 1, buttonState: 0, eventTime: 3)
        #expect(delegate.events.count == 4)
    }

    @Test func keysAreMappedToPhysicalKeys() {
        let (hub, _, delegate, surface) = scene()
        // Space from a keyboard (KEY_SPACE 57), shift held.
        #expect(hub.key(surface.id, action: 0, keyCode: 62, scanCode: 57, metaState: 0x41, repeatCount: 0, eventTime: 1))
        // W where the layout puts Z: the scan code wins.
        #expect(hub.key(surface.id, action: 0, keyCode: 54, scanCode: 17, metaState: 0, repeatCount: 2, eventTime: 1))
        // adb's keys have no scan code.
        #expect(hub.key(surface.id, action: 1, keyCode: 62, scanCode: 0, metaState: 0x3000, repeatCount: 0, eventTime: 1))
        // Back stays the system's.
        #expect(!hub.key(surface.id, action: 0, keyCode: 4, scanCode: 158, metaState: 0, repeatCount: 0, eventTime: 1))
        #expect(delegate.events == [
            "key 44 down modifiers 1",
            "key 26 down modifiers 0 repeat",
            "key 44 up modifiers 2",
        ])
    }

    @Test func capturedMovementIsSummedIntoOneDeltaPerFrame() {
        let (hub, system, delegate, surface) = scene()
        let views = FakeViews()
        hub.views = views
        #expect(hub.setPointerCaptured(surface.id, captured: true))
        #expect(views.requests == ["\(surface.id) true"])
        hub.relative(surface.id, x: 1, y: 2, eventTime: 1)
        #expect(delegate.events.isEmpty)
        hub.captureChanged(surface.id, captured: true)
        hub.relative(surface.id, x: 1, y: 2, eventTime: 1)
        hub.relative(surface.id, x: 3, y: -1, eventTime: 2)
        system.fire(5)
        #expect(delegate.events.prefix(2) == ["capture true", "delta 4.0,1.0 at 2000000"])
    }

    @Test func scrollsAndHoversReachTheGuest() {
        let (hub, system, delegate, surface) = scene()
        hub.scroll(surface.id, horizontal: 0, vertical: 1, horizontalFactor: 64, verticalFactor: 64)
        hub.pointer(surface.id, action: Action.hoverMove, isActionPointer: true, pointerID: 0, toolType: 3, x: 7, y: 8, buttonState: 0, eventTime: 1)
        system.fire(9)
        // Input, then the size, then the frame.
        #expect(delegate.events == [
            "scroll -0.0,64.0",
            "pointer 0 move kind 1 7.0,8.0 buttons 0 at 1000000",
            "resize 200x100@2.0 current false",
            "frame 9 200x100 current true",
        ])
    }

    @Test func aGuestCallbackMayLetTheSurfaceGo() {
        var (hub, system, delegate, surface): (SurfaceHub, FakeGraphicsSystem, RecordingDelegate, AndroidSurface?) = scene()
        let id = surface!.id
        hub.pointer(id, action: Action.down, isActionPointer: true, pointerID: 0, toolType: 1, x: 1, y: 1, buttonState: 0, eventTime: 1)
        hub.pointer(id, action: Action.move, isActionPointer: false, pointerID: 0, toolType: 1, x: 2, y: 2, buttonState: 0, eventTime: 2)
        delegate.onPointer = { _ in surface = nil }
        system.fire(3)
        #expect(delegate.events.last?.hasPrefix("pointer 1 move") == true)
        #expect(!delegate.events.contains { $0.hasPrefix("frame") })
    }
}

@Suite("Input mapping")
struct InputMappingTests {

    typealias Action = InputMapping.Action

    @Test func pointerKindsAndIDs() {
        #expect(InputMapping.kind(toolType: 1) == .touch)
        #expect(InputMapping.kind(toolType: 2) == .pen)
        #expect(InputMapping.kind(toolType: 4) == .pen)
        #expect(InputMapping.kind(toolType: 3) == .mouse)
        #expect(InputMapping.kind(toolType: 0) == .touch)
        #expect(InputMapping.pointerID(0, kind: .mouse) == 0)
        #expect(InputMapping.pointerID(0, kind: .touch) == 1)
        #expect(InputMapping.pointerID(3, kind: .pen) == 4)
    }

    @Test func buttons() {
        #expect(InputMapping.buttons(kind: .mouse, action: Action.down, phase: .down, buttonState: 2) == .secondary)
        #expect(InputMapping.buttons(kind: .mouse, action: Action.down, phase: .down, buttonState: 0) == .primary)
        #expect(InputMapping.buttons(kind: .mouse, action: Action.hoverMove, phase: .move, buttonState: 0) == [])
        #expect(InputMapping.buttons(kind: .touch, action: Action.move, phase: .move, buttonState: 0) == .primary)
        #expect(InputMapping.buttons(kind: .touch, action: Action.up, phase: .up, buttonState: 0) == [])
        #expect(InputMapping.buttons(kind: .pen, action: Action.move, phase: .move, buttonState: 0x20) == [.primary, .secondary])
        #expect(InputMapping.buttons(kind: .pen, action: Action.hoverMove, phase: .move, buttonState: 0) == [])
    }

    @Test func phases() {
        #expect(InputMapping.phase(action: Action.pointerUp, isActionPointer: false) == nil)
        #expect(InputMapping.phase(action: Action.pointerUp, isActionPointer: true) == .up)
        #expect(InputMapping.phase(action: Action.buttonPress, isActionPointer: true) == .move)
        #expect(InputMapping.phase(action: 10, isActionPointer: true) == nil) // hover exit
        #expect(InputMapping.phase(action: 8, isActionPointer: true) == nil) // scroll
    }

    @Test func everyLetterAndDigitKeyHasItsPosition() {
        let rows = ["qwertyuiop", "asdfghjkl", "zxcvbnm"]
        let starts: [Int32] = [16, 30, 44]
        for (row, start) in zip(rows, starts) {
            for (offset, letter) in row.unicodeScalars.enumerated() {
                let usage = 0x04 + Int32(letter.value - 97)
                #expect(InputMapping.keyCode(scanCode: start + Int32(offset), keyCode: 0)?.rawValue == usage)
                // KEYCODE_A is 29.
                #expect(InputMapping.keyCode(scanCode: 0, keyCode: 29 + Int32(letter.value - 97))?.rawValue == usage)
            }
        }
        #expect(InputMapping.keyCode(scanCode: 2, keyCode: 0) == .digit(1))
        #expect(InputMapping.keyCode(scanCode: 11, keyCode: 0) == .digit(0))
        #expect(InputMapping.keyCode(scanCode: 0, keyCode: 7) == .digit(0))
        #expect(InputMapping.keyCode(scanCode: 0, keyCode: 16) == .digit(9))
        #expect(InputMapping.keyCode(scanCode: 103, keyCode: 0) == .up)
        #expect(InputMapping.keyCode(scanCode: 0, keyCode: 22) == .right)
        #expect(InputMapping.keyCode(scanCode: 88, keyCode: 0) == .function(12))
        #expect(InputMapping.keyCode(scanCode: 0, keyCode: 142) == .function(12))
        #expect(InputMapping.keyCode(scanCode: 1, keyCode: 111) == .escape)
        #expect(InputMapping.keyCode(scanCode: 42, keyCode: 0) == .leftShift)
        #expect(InputMapping.keyCode(scanCode: 0, keyCode: 24) == nil) // volume up
    }

    @Test func modifiers() {
        #expect(InputMapping.modifiers(metaState: 0x1 | 0x40) == .shift)
        #expect(InputMapping.modifiers(metaState: 0x2000 | 0x1000) == .control)
        #expect(InputMapping.modifiers(metaState: 0x12) == .alt)
        #expect(InputMapping.modifiers(metaState: 0x10000 | 0x1) == [.meta, .shift])
    }

    @Test func scrollDirections() {
        let up = InputMapping.scroll(horizontal: 0, vertical: 1, horizontalFactor: 10, verticalFactor: 20)
        #expect(up.y == 20)
        let right = InputMapping.scroll(horizontal: 1, vertical: 0, horizontalFactor: 10, verticalFactor: 20)
        #expect(right.x == -10)
    }
}
