import AndroidHost
@testable import AndroidHostUI
import DynamicUI
import Testing

/// The renderer forwards the guest's bytes to the surface, and the surface's
/// events and row requests to the guest. `AndroidHostUI` is global, so the
/// tests run one at a time.
@Suite(.serialized) struct AndroidRendererTests {

    final class Surface: RenderSurface {

        var trees: [[UInt8]] = []

        var replacements: [(UInt64, [UInt8])] = []

        func apply(_ tree: [UInt8]) {
            trees.append(tree)
        }

        func replaceSubtree(_ id: UInt64, tree: [UInt8]) {
            replacements.append((id, tree))
        }
    }

    final class Delegate: RendererDelegate {

        var events: [(UInt64, Int32, [UInt8])] = []

        func event(_ node: [UInt8], kind: Int32, payload: [UInt8]) {
            events.append((try! RenderCodec.decode(id: node), kind, payload))
        }

        func rowCount(_ list: [UInt8]) -> Int32 {
            Int32(try! RenderCodec.decode(id: list) % 100)
        }

        func row(_ list: [UInt8], index: Int32) -> [UInt8] {
            RenderCodec.encode(RenderNode("Text", id: try! RenderCodec.decode(id: list) + UInt64(index),
                                          props: ["text": .string("Row \(index)")]))
        }
    }

    @Test func forwardsUpdatesToTheSurface() {
        let surface = Surface()
        AndroidHostUI.surface = surface
        defer { AndroidHostUI.surface = nil }
        let renderer = AndroidRenderer.make(Delegate())
        #expect(AndroidHostUI.renderer === renderer)

        let tree = RenderCodec.encode(RenderNode("Text", id: 7, props: ["text": "Hi"]))
        renderer.apply(tree)
        renderer.replaceSubtree(RenderCodec.encode(id: .max), tree: tree)
        // Not a node ID: logged and dropped.
        renderer.replaceSubtree([1, 2], tree: tree)
        #expect(surface.trees == [tree])
        #expect(surface.replacements.count == 1)
        #expect(surface.replacements.first?.0 == .max)
        #expect(surface.replacements.first?.1 == tree)
    }

    @Test func forwardsEventsAndRowsToTheGuest() throws {
        let delegate = Delegate()
        let renderer = AndroidRenderer.make(delegate)
        let payload = RenderCodec.encode(payload: .string("Ada"))
        renderer.event(0xFFFF_0000_0000_0001, kind: RenderEventKind.change.rawValue, payload: payload)
        #expect(delegate.events.count == 1)
        #expect(delegate.events.first?.0 == 0xFFFF_0000_0000_0001)
        #expect(delegate.events.first?.1 == RenderEventKind.change.rawValue)
        #expect(delegate.events.first?.2 == payload)

        #expect(renderer.rowCount(342) == 42)
        let row = try RenderCodec.decode(renderer.row(40, index: 2))
        #expect(row.id == 42)
        #expect(row.props["text"] == .string("Row 2"))
    }

    @Test func forgetsARendererTheGuestReleased() {
        var renderer: AndroidRenderer? = AndroidRenderer.make(Delegate())
        #expect(AndroidHostUI.renderer != nil)
        renderer = nil
        #expect(renderer == nil)
        #expect(AndroidHostUI.renderer == nil)
    }

    @Test func registersTheRendererContracts() {
        #expect(AndroidHostUI.contracts.map(\.name) == ["org.pureswift.ui.Renderer", "org.pureswift.ui.RendererDelegate"])
        #expect(AndroidHostUI.isUsed(by: ["org.pureswift.ui.Renderer"]))
    }
}
