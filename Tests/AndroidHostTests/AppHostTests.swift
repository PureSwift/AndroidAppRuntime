@testable import AndroidHost
import DynamicRuntime
import RuntimeABI
import RuntimeCore
import RuntimeNative
import Testing

/// Preparing an app: the checks, the built-ins and the modules it uses. The
/// built-ins keep their state in statics, so the tests run one at a time.
@Suite(.serialized) struct AppHostTests {

    enum Things: HostModule {

        nonisolated(unsafe) static var registered = 0

        static let thing = ContractDescriptor(name: "org.example.Thing", kind: .contract, methods: [])

        static var contracts: [ContractDescriptor] {
            [thing]
        }

        static func register(in registrar: some ContractRegistrar) {
            registered += 1
            registrar.register(thing, statics: nil)
        }

        static func permissionProviders() -> [Capability: any PermissionProvider] {
            [.location: GrantedPermission()]
        }
    }

    func app(_ contracts: [AppInfo.Contract], capabilities: Set<Capability> = []) -> AppInfo {
        AppInfo(identifier: "org.example.App", version: "1.0", build: "3", abiVersion: runtimeABIVersion,
                capabilities: capabilities, contracts: contracts)
    }

    @Test func registersTheBuiltinsAndTheModulesTheAppUses() throws {
        Things.registered = 0
        let info = app([.init(name: "org.example.Thing", version: 1, kind: .contract)], capabilities: [.location])
        let host = AppHost(info: info, modules: [Things.self], native: NativeRuntime(), clock: ManualClock())
        try host.prepare()
        #expect(Things.registered == 1)
        #expect(host.warnings.isEmpty)
        #expect(AndroidBundle.identifier() == "org.example.App")
        #expect(AndroidBundle.version() == "1.0")
        #expect(AndroidBundle.build() == "3")
        #expect(HostPermissions.status(.location) == PermissionStatus.granted.rawValue)
        #expect(HostPermissions.status(.bluetooth) == PermissionStatus.denied.rawValue)
        #expect(host.native.capabilities == [.location])
    }

    @Test func skipsModulesTheAppDoesntUse() throws {
        Things.registered = 0
        let host = AppHost(info: app([]), modules: [Things.self], native: NativeRuntime(), clock: ManualClock())
        try host.prepare()
        #expect(Things.registered == 0)
    }

    @Test func refusesAppsThatNeedMore() {
        let info = app([.init(name: "org.example.Missing", version: 1, kind: .contract)])
        let host = AppHost(info: info, modules: [Things.self], native: NativeRuntime(), clock: ManualClock())
        #expect(throws: AppHostError.incompatible("org.example.Missing isn't implemented by this host")) {
            try host.prepare()
        }
    }

    @Test func logsWarnings() throws {
        HostLog.recorded = []
        defer { HostLog.recorded = nil }
        let info = app([.init(name: "org.example.Thing", version: 2, kind: .contract)])
        let host = AppHost(info: info, modules: [Things.self], native: NativeRuntime(), clock: ManualClock())
        try host.prepare()
        #expect(HostLog.recorded == ["warning: org.example.Thing is version 1 on this host; the app was built against 2"])
    }

    @Test func reportsLanguages() {
        AndroidBundle.languages = ["pt-BR", "en-US"]
        #expect(AndroidBundle.preferredLanguages() == ["pt-BR", "en-US"])
        AndroidBundle.languages = []
        #expect(AndroidBundle.preferredLanguages() == ["en"])
        #expect(AndroidBundle.localizedString("Hello", table: nil) == nil)
    }
}
