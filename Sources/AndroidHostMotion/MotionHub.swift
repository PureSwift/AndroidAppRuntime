import AndroidHost

/// Something that wants samples of some sensor types.
protocol SensorClient: AnyObject {
    func received(_ sample: SensorSample)
}

/// The NDK sensors every Motion object shares: a sensor is on while any
/// object wants it, at the shortest period any asks for, and its samples go
/// to each. Main thread only.
public final class MotionHub {

    nonisolated(unsafe) public static let shared = MotionHub()

    /// Makes the system on first use; `AndroidHostApp` sets it.
    public var makeSystem: (() -> any SensorSystem)?

    private var _system: (any SensorSystem)?

    public var system: any SensorSystem {
        if let _system {
            return _system
        }
        guard let makeSystem else {
            fatalError("MotionHub.makeSystem isn't set")
        }
        let system = makeSystem()
        _system = system
        return system
    }

    private struct Subscription {
        weak var client: (any SensorClient)?
        var period: Int32
    }

    private var subscriptions: [Int32: [ObjectIdentifier: Subscription]] = [:]

    /// The period each sensor runs at.
    private(set) var periods: [Int32: Int32] = [:]

    public init() { }

    /// Replaces the system, for tests.
    public func use(_ system: (any SensorSystem)?) {
        _system = system
        subscriptions = [:]
        periods = [:]
    }

    /// Adds `client` to `type`'s samples; false if the sensor wouldn't
    /// start.
    func subscribe(_ client: any SensorClient, to type: Int32, period: Int32) -> Bool {
        var clients = subscriptions[type, default: [:]]
        clients[ObjectIdentifier(client)] = Subscription(client: client, period: period)
        clients = clients.filter { $0.value.client != nil }
        subscriptions[type] = clients
        return update(type)
    }

    func unsubscribe(_ client: any SensorClient, from type: Int32) {
        subscriptions[type]?[ObjectIdentifier(client)] = nil
        _ = update(type)
    }

    /// Runs `type` at the shortest period wanted, or stops it.
    private func update(_ type: Int32) -> Bool {
        let wanted = subscriptions[type, default: [:]].values.filter { $0.client != nil }.map(\.period).min()
        guard wanted != periods[type] else { return true }
        if periods[type] != nil {
            system.disable(type)
            periods[type] = nil
        }
        guard let wanted else { return true }
        guard system.enable(type, period: wanted) else {
            return false
        }
        periods[type] = wanted
        return true
    }

    /// A sample from the system.
    public func received(_ sample: SensorSample) {
        for subscription in subscriptions[sample.type, default: [:]].values {
            subscription.client?.received(sample)
        }
    }
}
