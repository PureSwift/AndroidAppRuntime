@testable import AndroidHost
import DynamicRuntime
import RuntimeABI
import Testing

/// A device's permissions, as the tests set them.
final class FakePermissionSystem: PermissionSystem {

    var apiLevel: Int32 = 34

    var granted: Set<String> = []

    var requested: Set<String> = []

    var declared: Set<String>?

    var features: Set<String> = ["android.hardware.bluetooth_le", "android.hardware.location"]

    var hasActivity = true

    var requests: [(permissions: [String], id: Int32)] = []

    func isGranted(_ permission: String) -> Bool { granted.contains(permission) }

    func wasRequested(_ permission: String) -> Bool { requested.contains(permission) }

    func isDeclared(_ permission: String) -> Bool { declared?.contains(permission) ?? true }

    func hasFeature(_ feature: String) -> Bool { features.contains(feature) }

    func request(_ permissions: [String], id: Int32) -> Bool {
        guard hasActivity else { return false }
        requested.formUnion(permissions)
        requests.append((permissions, id))
        return true
    }
}

/// Serialized: `AndroidPermissions` is global.
@Suite(.serialized) struct AndroidPermissionsTests {

    let system = FakePermissionSystem()

    init() {
        AndroidPermissions.reset()
        AndroidPermissions.system = system
    }

    @Test func choosesPermissionsByAPILevel() {
        let bluetooth = "android.hardware.bluetooth_le"
        #expect(AndroidPermissions.requirement(.bluetooth, api: 31)
                == .init(permissions: ["android.permission.BLUETOOTH_SCAN", "android.permission.BLUETOOTH_CONNECT"], feature: bluetooth))
        #expect(AndroidPermissions.requirement(.bluetooth, api: 30)?.permissions == [AndroidPermissions.fineLocation])
        #expect(AndroidPermissions.requirement(.motion, api: 29)?.permissions == ["android.permission.ACTIVITY_RECOGNITION"])
        #expect(AndroidPermissions.requirement(.motion, api: 28)?.permissions == [])
        #expect(AndroidPermissions.requirement(.notifications, api: 33)?.permissions == ["android.permission.POST_NOTIFICATIONS"])
        #expect(AndroidPermissions.requirement(.notifications, api: 32)?.permissions == [])
        #expect(AndroidPermissions.requirement(.nfc, api: 34) == .init(permissions: [], feature: "android.hardware.nfc"))
        #expect(AndroidPermissions.requirement(.network, api: 34) == nil)
    }

    @Test func reportsStatus() {
        let location = RuntimePermission(AndroidPermissions.requirement(.location, api: 34)!)
        #expect(location.status() == .notDetermined)
        system.requested = [AndroidPermissions.fineLocation, AndroidPermissions.coarseLocation]
        #expect(location.status() == .denied)
        system.granted = [AndroidPermissions.coarseLocation]
        #expect(location.status() == .limited, "approximate location only")
        system.granted = [AndroidPermissions.coarseLocation, AndroidPermissions.fineLocation]
        #expect(location.status() == .granted)
        system.declared = [AndroidPermissions.coarseLocation]
        #expect(location.status() == .denied, "a permission the manifest lacks")
        system.features = []
        #expect(location.status() == .unavailable)
        // Install-time and pre-runtime permissions are granted with the feature.
        system.features = ["android.hardware.nfc"]
        #expect(RuntimePermission(AndroidPermissions.requirement(.nfc, api: 34)!).status() == .granted)
        #expect(RuntimePermission(AndroidPermissions.requirement(.notifications, api: 32)!).status() == .granted)
    }

    @Test func requestsAndAnswers() {
        let location = RuntimePermission(AndroidPermissions.requirement(.location, api: 34)!)
        var answers: [PermissionStatus] = []
        location.request { answers.append($0) }
        #expect(system.requests.count == 1)
        #expect(answers.isEmpty, "the answer comes from the Activity")
        let request = system.requests[0]
        system.granted = [AndroidPermissions.coarseLocation]
        AndroidPermissions.didRequest(id: request.id, permissions: request.permissions, granted: [false, true])
        #expect(answers == [.limited])
        // A second answer for the same request is ignored.
        AndroidPermissions.didRequest(id: request.id, permissions: request.permissions, granted: [true, true])
        #expect(answers == [.limited])
    }

    @Test func answersAtOnceWhenThereIsNothingToAsk() {
        system.granted = [AndroidPermissions.fineLocation, AndroidPermissions.coarseLocation]
        var answers: [PermissionStatus] = []
        RuntimePermission(AndroidPermissions.requirement(.location, api: 34)!).request { answers.append($0) }
        #expect(answers == [.granted])
        #expect(system.requests.isEmpty)
        // Without an Activity the request fails, and the status stays.
        system.granted = []
        system.hasActivity = false
        RuntimePermission(AndroidPermissions.requirement(.location, api: 34)!).request { answers.append($0) }
        #expect(answers == [.granted, .notDetermined])
    }

    @Test func backsTheBuiltin() {
        HostPermissions.providers = AndroidPermissions.providers(api: 34)
        HostPermissions.declared = [.location, .network]
        #expect(HostPermissions.status(.location) == PermissionStatus.notDetermined.rawValue)
        #expect(HostPermissions.status(.network) == PermissionStatus.granted.rawValue)
        #expect(HostPermissions.status(.bluetooth) == PermissionStatus.denied.rawValue, "not declared")
        HostPermissions.providers = [:]
        HostPermissions.declared = []
    }
}
