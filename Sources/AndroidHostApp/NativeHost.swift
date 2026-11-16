import AndroidHost
import AndroidHostBluetooth
import AndroidHostDevice
import AndroidHostFiles
import AndroidHostFormatting
import AndroidHostGraphics
import AndroidHostLocation
import AndroidHostMotion
import AndroidHostNFC
import AndroidHostNetworking
import AndroidHostModules
import AndroidHostUI
import AndroidHostWebKit
import CRuntime
import DynamicRuntime
import RuntimeABI
import SwiftJava
#if canImport(FoundationEssentials)
import FoundationEssentials
#else
import Foundation
#endif

/// The app's host (`Plan.md` §5): every module this host has, and the app
/// linked into this library.
public enum AndroidHostApp {

    /// Every module this host has.
    public static let modules: [any HostModule.Type] = AndroidHostModules.all

    /// Points each module at its Kotlin side, made when the app first uses it.
    static func connectModules() {
        AndroidPermissions.system = AndroidPermissionSystem()
        HostBackground.system = JavaBackgroundSystem()
        DeviceHub.shared.makeSystem = { AndroidDeviceSystem() }
        AndroidHostFormatting.makeSystem = { AndroidFormattingSystem() }
        LocationHub.shared.makeSystem = { AndroidLocationSystem() }
        NetworkHub.shared.makeSystem = { AndroidNetworkSystem() }
        BluetoothHub.shared.makeSystem = { AndroidBluetoothSystem() }
        NFCHub.shared.makeSystem = { AndroidNFCSystem() }
        MotionHub.shared.makeSystem = { MotionSensors.make() }
        SurfaceHub.shared.makeSystem = { GraphicsBridge.makeSystem() }
        SurfaceHub.shared.views = JavaGraphicsSystem()
        WebHub.shared.makeSystem = { JavaWebSystem() }
    }

    /// The app's exports, from the sealed slice linked into this library.
    static let entry = AppEntryPoints(main: rt_main, dispatch: rt_dispatch, finalize: rt_finalize)

    /// The running host, once `start` succeeded.
    nonisolated(unsafe) static var host: AppHost?

    /// Starts the app: an empty string, or why it couldn't.
    static func start(info data: [UInt8], languages: [String], surface: (any RenderSurface)?) -> String {
        if host != nil {
            // A recreated Activity: the guest keeps running (§5).
            AndroidHostUI.surface = surface ?? AndroidHostUI.surface
            return ""
        }
        guard MainLooper.shared.install() else {
            return "the main looper couldn't be installed"
        }
        let info: AppInfo
        do {
            info = try AppInfo(propertyList: Data(data))
        } catch {
            return error.description
        }
        AndroidBundle.languages = languages
        AndroidHostUI.surface = surface
        connectModules()
        FilesBridge.configure()
        let host = AppHost(info: info, modules: modules)
        do {
            try host.prepare()
        } catch {
            return error.description
        }
        self.host = host
        let status = host.start(entry)
        guard status == .ok else {
            return "the app didn't start: rt_main returned \(status)"
        }
        HostLog.info("\(info.identifier) \(info.version) (\(info.build)) started")
        return ""
    }
}

/// The Kotlin player's `RenderSurface`, which decodes trees into composeui's
/// store.
@JavaClass("org.pureswift.appruntime.ui.RenderSurface")
open class JavaRenderSurface: JavaObject {

    @JavaMethod
    open func apply(_ tree: [UInt8])

    @JavaMethod
    open func replaceSubtree(_ id: Int64, _ tree: [UInt8])
}

/// Adapts the Kotlin surface to `AndroidHostUI`'s.
final class SurfaceAdapter: RenderSurface {

    let surface: JavaRenderSurface

    init(_ surface: JavaRenderSurface) {
        self.surface = surface
    }

    func apply(_ tree: [UInt8]) {
        surface.apply(tree)
    }

    func replaceSubtree(_ id: UInt64, tree: [UInt8]) {
        surface.replaceSubtree(Int64(bitPattern: id), tree)
    }
}

/// The shell's `NativeHost` object, whose `external` methods are
/// implemented here. Every call arrives on the main thread.
@JavaClass("org.pureswift.appruntime.NativeHost")
open class NativeHost: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.NativeHost")
extension NativeHost {

    /// Starts the app from its `Info.plist` bytes; an empty string, or why it
    /// couldn't. Called again by a recreated Activity, with its surface.
    @JavaMethod
    public func start(_ info: [UInt8], _ languages: [String], _ surface: JavaRenderSurface?) -> String {
        AndroidHostApp.start(info: info, languages: languages, surface: surface.map(SurfaceAdapter.init))
    }

    /// A UI event on `node` (`RenderEventKind`).
    @JavaMethod
    public func event(_ node: Int64, _ kind: Int32, _ payload: [UInt8]) {
        AndroidHostUI.renderer?.event(UInt64(bitPattern: node), kind: kind, payload: payload)
    }

    /// Rows in the lazy container `list`.
    @JavaMethod
    public func rowCount(_ list: Int64) -> Int32 {
        AndroidHostUI.renderer?.rowCount(UInt64(bitPattern: list)) ?? 0
    }

    /// Row `index` of `list`, as an encoded tree; empty if there's none.
    @JavaMethod
    public func row(_ list: Int64, _ index: Int32) -> [UInt8] {
        AndroidHostUI.renderer?.row(UInt64(bitPattern: list), index: index) ?? []
    }

    /// The Activity's lifecycle, as an `ApplicationState` raw value.
    @JavaMethod
    public func setState(_ state: Int32) {
        guard let state = ApplicationState(rawValue: state) else { return }
        HostApplication.setState(state)
        // Surfaces draw only while the app is active (§8.2).
        SurfaceHub.shared.setActive(state == .active)
        if state == .active {
            // The user may have changed a permission in Settings.
            LocationHub.shared.authorizationMayHaveChanged()
            BluetoothHub.shared.updateAll()
        } else {
            // Reader mode needs the resumed Activity.
            NFCHub.shared.appWentInactive()
        }
    }

    /// An `ACTION_VIEW` intent's URL; whether the app handled it.
    @JavaMethod
    public func open(_ url: String) -> Bool {
        HostApplication.open(url)
    }

    /// `onTrimMemory` at `TRIM_MEMORY_RUNNING_LOW` or above.
    @JavaMethod
    public func memoryWarning() {
        HostApplication.didReceiveMemoryWarning()
    }

    /// The user's languages changed.
    @JavaMethod
    public func setLanguages(_ languages: [String]) {
        AndroidBundle.languages = languages
    }
}
