import AndroidHost
import AndroidHostAuthentication
import AndroidHostBackgroundTasks
import AndroidHostBluetooth
import AndroidHostClipboard
import AndroidHostDefaults
import AndroidHostDevice
import AndroidHostFiles
import AndroidHostFormatting
import AndroidHostGraphics
import AndroidHostLocation
import AndroidHostMedia
import AndroidHostMotion
import AndroidHostNFC
import AndroidHostNotifications
import AndroidHostPhotos
import AndroidHostNetworking
import AndroidHostSecrets
import AndroidHostContacts
import AndroidHostCalendars
import AndroidHostCamera
import AndroidHostText
import AndroidHostModules
import AndroidHostUI
import AndroidHostWebKit
import CRuntime
import DynamicRuntime
import RuntimeABI
import RuntimeHost
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
        HostDefaults.storage = AndroidDefaultsStorage { JavaDefaultsSystem() }
        AndroidHostText.configure { JavaTextSystem() }
    }

    /// The app's exports, from the sealed slice linked into this library.
    static let entry = AppEntryPoints(main: rt_main, dispatch: rt_dispatch, finalize: rt_finalize)

    /// The running host, once `start` succeeded.
    nonisolated(unsafe) static var host: AppHost?

    /// Starts the app: an empty string, or why it couldn't. `background`:
    /// the system started it to run a task, with no window, and it's in the
    /// background until an Activity shows it (§6.17).
    static func start(info data: [UInt8], languages: [String], surface: (any RenderSurface)?, background: Bool = false) -> String {
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
        ModelStoreBridge.configure()
        DocumentsBridge.configure()
        AndroidHostClipboard.configure(AndroidClipboardPlatform(system: JavaClipboardSystem()))
        AndroidHostSecrets.configure(KeystoreSecretStore(system: JavaSecretSystem()))
        if info.capabilities.contains(.contacts) {
            ContactsBridge.configure(allowsWriting: CapabilityOptions(Data(data)).value("contacts", "access") != "readOnly")
        }
        if info.capabilities.contains(.calendars) {
            CalendarsBridge.configure(writeOnly: CapabilityOptions(Data(data)).value("calendars", "access") == "writeOnly")
        }
        if info.capabilities.contains(.photoLibrary) {
            AndroidHostPhotos.configure(JavaPhotoSystem(),
                                        allowsReading: CapabilityOptions(Data(data)).value("photoLibrary", "access") != "addOnly")
        }
        if info.capabilities.contains(.backgroundTasks) {
            let entries = (try? PropertyListDecoder().decode(BackgroundTaskEntries.self, from: Data(data)))?.entries ?? []
            AndroidHostBackgroundTasks.configure(JavaBackgroundTaskSystem(), declared: AndroidHostBackgroundTasks.declared(entries))
        }
        AndroidHostAuthentication.configure(AndroidWebAuthenticationPresenter(system: JavaAuthenticationSystem()),
                                            schemes: CapabilityOptions.authenticationSchemes(Data(data)))
        NotificationsBridge.configure(declaresRemote: CapabilityOptions(Data(data)).value("notifications", "remote") == "true")
        let host = AppHost(info: info, modules: modules)
        // Players report times on the guest's clock, and play on in the
        // background where the manifest says `.audio(background: true)`.
        AndroidMedia.configure(AndroidMediaPlatform(system: JavaMediaSystem(), nowPlaying: JavaNowPlayingSystem()),
                               clock: host.native.runtime.clock, allowsNetwork: info.capabilities.contains(.network),
                               allowsBackground: CapabilityOptions(Data(data)).value("audio", "background") == "true")
        if info.capabilities.contains(.camera) {
            AndroidHostCamera.configure({ JavaCameraSystem() }, allowsMicrophone: info.capabilities.contains(.microphone),
                                        clock: host.native.runtime.clock)
        }
        do {
            try host.prepare()
        } catch {
            return error.description
        }
        self.host = host
        if background {
            // What the app's init reads, before any Activity reports.
            HostApplication.setState(.background)
        }
        let status = host.start(entry)
        guard status == .ok else {
            return "the app didn't start: rt_main returned \(status)"
        }
        HostLog.info("\(info.identifier) \(info.version) (\(info.build)) started")
        return ""
    }
}

/// `RTCapabilityOptions` from the bundle's `Info.plist`: options such as
/// notifications' `remote`, which `AppInfo` doesn't carry.
struct CapabilityOptions: Decodable {

    var options: [String: [String: String]]

    enum CodingKeys: String, CodingKey {
        case options = "RTCapabilityOptions"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        options = try container.decodeIfPresent([String: [String: String]].self, forKey: .options) ?? [:]
    }

    /// None when the property list doesn't read.
    init(_ data: Data) {
        self = (try? PropertyListDecoder().decode(CapabilityOptions.self, from: data)) ?? CapabilityOptions(options: [:])
    }

    init(options: [String: [String: String]]) {
        self.options = options
    }

    func value(_ capability: String, _ option: String) -> String? {
        options[capability]?[option]
    }

    /// `RTAuthenticationSchemes`: the schemes a sign-in may redirect to.
    static func authenticationSchemes(_ data: Data) -> [String] {
        struct Schemes: Decodable {
            var RTAuthenticationSchemes: [String]?
        }
        return (try? PropertyListDecoder().decode(Schemes.self, from: data))?.RTAuthenticationSchemes ?? []
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
    public func start(_ info: [UInt8], _ languages: [String], _ surface: JavaRenderSurface?, _ background: Bool) -> String {
        AndroidHostApp.start(info: info, languages: languages, surface: surface.map(SurfaceAdapter.init), background: background)
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
        if state == .background {
            // What doesn't play in the background pauses, and says why.
            AndroidMedia.applicationDidEnterBackground()
            // The camera is off while the app isn't in front (§6.19).
            AndroidHostCamera.applicationDidEnterBackground()
        }
        if state == .active {
            AndroidHostCamera.applicationWillEnterForeground()
            AndroidHostNotifications.center?.didBecomeActive()
            // The user may have changed the contacts and calendar permissions
            // in Settings.
            AndroidHostContacts.refresh()
            AndroidHostCalendars.refresh()
            AndroidHostPhotos.refresh()
            // Back from a sign-in page, with or without its redirect.
            AndroidHostAuthentication.presenter?.didBecomeActive()
            // The user may have changed a permission in Settings.
            LocationHub.shared.authorizationMayHaveChanged()
            BluetoothHub.shared.updateAll()
        } else {
            AndroidHostNotifications.center?.didResignActive()
            AndroidHostAuthentication.presenter?.didResignActive()
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
