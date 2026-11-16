import AndroidHost
import DynamicGraphics
import DynamicRuntime

/// The `Surface` contract (§8.2): somewhere the guest draws with GLES 2.0,
/// shown by a `GLSurface` node whose `surface` prop is its `identifier()`.
/// The player puts a `GraphicsView`, a `TextureView`, there; `SurfaceHub`
/// does the rest.
public final class AndroidSurface: Surface {

    let delegate: any SurfaceDelegate

    let hub: SurfaceHub

    /// `identifier()`: never reused, so a stale view shows nothing.
    public private(set) var id: Int32 = 0

    /// What the guest last heard from `resize`.
    var reported: DrawableSize?

    init(delegate: any SurfaceDelegate, hub: SurfaceHub = .shared) {
        self.delegate = delegate
        self.hub = hub
        id = hub.register(self)
    }

    deinit {
        hub.unregister(id)
    }

    public static func make(_ delegate: any SurfaceDelegate) -> AndroidSurface {
        AndroidSurface(delegate: delegate)
    }

    public func identifier() -> Int32 {
        id
    }

    /// Asks the view to capture the mouse (Android 8+, with a mouse). The
    /// answer comes later, as `pointerCapture(_:captured:)`; this returns
    /// whether it was asked for, or, to stop, false.
    public func setPointerCaptured(_ captured: Bool) -> Bool {
        hub.setPointerCaptured(id, captured: captured)
    }
}

/// The Graphics contracts (`Plan.md` §6.3). The `graphics` capability has
/// no permission; the packager declares GLES 2.0 in the manifest.
public enum AndroidHostGraphics: HostModule {

    public static var contracts: [ContractDescriptor] {
        [SurfaceProxy.descriptor, SurfaceDelegateProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        SurfaceProxy.register(AndroidSurface.self, in: registrar)
        SurfaceDelegateProxy.registerInterface(in: registrar)
    }
}
