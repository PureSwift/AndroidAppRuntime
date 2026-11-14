import AndroidHost
import DynamicRuntime
import DynamicUI
import RuntimeABI

/// The player's side of a renderer (`Plan.md` §7.1): the Kotlin store that
/// composeui renders. Trees cross JNI as the guest encoded them, one
/// `byte[]` per update, and Kotlin's `RenderCodec` decodes them.
public protocol RenderSurface: AnyObject {

    /// Replaces everything with `tree`.
    func apply(_ tree: [UInt8])

    /// Replaces the node `id` and its subtree with `tree`.
    func replaceSubtree(_ id: UInt64, tree: [UInt8])
}

/// The `Renderer` contract: forwards the guest's updates to the surface, and
/// the surface's events and row requests to the guest's `RendererDelegate`.
///
/// One renderer per process, as composeui's sink is global (§9.2).
public final class AndroidRenderer: Renderer {

    let delegate: any RendererDelegate

    init(delegate: any RendererDelegate) {
        self.delegate = delegate
    }

    public static func make(_ delegate: any RendererDelegate) -> AndroidRenderer {
        let renderer = AndroidRenderer(delegate: delegate)
        if AndroidHostUI.renderer != nil {
            HostLog.warning("the app made a second renderer; events go to the newest")
        }
        AndroidHostUI.renderer = renderer
        return renderer
    }

    public func apply(_ tree: [UInt8]) {
        guard let surface = AndroidHostUI.surface else {
            HostLog.error("the app sent a tree with nowhere to show it")
            return
        }
        surface.apply(tree)
    }

    public func replaceSubtree(_ id: [UInt8], tree: [UInt8]) {
        let node: RenderNode.ID
        do {
            node = try RenderCodec.decode(id: id)
        } catch {
            HostLog.error("the app sent a node ID this host can't read: \(error)")
            return
        }
        AndroidHostUI.surface?.replaceSubtree(node, tree: tree)
    }

    // MARK: Host side

    /// The user acted on `node`. `kind` is a `RenderEventKind`; `payload` an
    /// encoded value, or empty. The guest's update arrives before it returns.
    public func event(_ node: UInt64, kind: Int32, payload: [UInt8]) {
        delegate.event(RenderCodec.encode(id: node), kind: kind, payload: payload)
    }

    /// Rows in the lazy container `list`.
    public func rowCount(_ list: UInt64) -> Int32 {
        delegate.rowCount(RenderCodec.encode(id: list))
    }

    /// Row `index` of `list`, as an encoded tree.
    public func row(_ list: UInt64, index: Int32) -> [UInt8] {
        delegate.row(RenderCodec.encode(id: list), index: index)
    }
}

/// The SwiftUI player's contracts.
public enum AndroidHostUI: HostModule {

    /// Where trees go. The shell sets it before the guest starts.
    nonisolated(unsafe) public static var surface: (any RenderSurface)?

    /// The renderer the guest made, while it keeps it.
    nonisolated(unsafe) public internal(set) static weak var renderer: AndroidRenderer?

    public static var contracts: [ContractDescriptor] {
        [RendererProxy.descriptor, RendererDelegateProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        RendererProxy.register(AndroidRenderer.self, in: registrar)
        RendererDelegateProxy.registerInterface(in: registrar)
    }
}
