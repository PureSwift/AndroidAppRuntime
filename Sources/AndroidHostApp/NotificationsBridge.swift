import AndroidHost
import AndroidHostNotifications
import SwiftJava

/// The Kotlin `NotificationSystem` (`:appruntime-contracts`).
@JavaClass("org.pureswift.appruntime.contracts.NotificationSystem")
open class JavaNotificationSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func apiLevel() -> Int32
    @JavaMethod open func areEnabled() -> Bool
    @JavaMethod open func canScheduleExact() -> Bool
    @JavaMethod open func requestExactTiming() -> Bool
    @JavaMethod open func timeZone() -> String
    @JavaMethod open func appName() -> String
    @JavaMethod open func storageDirectory() -> String
    @JavaMethod open func setChannels(_ json: String)
    @JavaMethod open func post(_ json: String) -> Bool
    @JavaMethod open func delivered() -> [String]
    @JavaMethod open func removeDelivered(_ identifiers: [String], _ all: Bool)
    @JavaMethod open func setAlarm(_ identifier: String, _ milliseconds: Int64)
    @JavaMethod open func cancelAlarm(_ identifier: String)
}

/// `AndroidNotificationCenter`'s platform over the Kotlin class.
final class AndroidNotificationPlatform: NotificationPlatform {

    let java = JavaNotificationSystem()

    lazy var apiLevel: Int32 = java.apiLevel()

    func areEnabled() -> Bool { java.areEnabled() }
    func canScheduleExact() -> Bool { java.canScheduleExact() }
    func requestExactTiming() -> Bool { java.requestExactTiming() }
    func timeZone() -> String { java.timeZone() }
    func setChannels(_ json: String) { java.setChannels(json) }
    func post(_ json: String) -> Bool { java.post(json) }
    func delivered() -> [String] { java.delivered() }
    func removeDelivered(_ identifiers: [String], all: Bool) { java.removeDelivered(identifiers, all) }
    func setAlarm(_ identifier: String, at milliseconds: Int64) { java.setAlarm(identifier, milliseconds) }
    func cancelAlarm(_ identifier: String) { java.cancelAlarm(identifier) }
}

/// The Kotlin `NotificationNatives` object: responses from the Activity,
/// and alarms from `NotificationReceiver`, which may have started the
/// process with no guest.
@JavaClass("org.pureswift.appruntime.contracts.NotificationNatives")
open class NotificationNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.NotificationNatives")
extension NotificationNatives {

    @JavaMethod
    public func responded(_ record: String, _ action: String, _ text: String, _ hasText: Bool) {
        NotificationsBridge.center().responded(record, action: action, text: hasText ? text : nil)
    }

    @JavaMethod
    public func alarm(_ identifier: String) {
        NotificationsBridge.center().alarm(identifier)
    }

    @JavaMethod
    public func reschedule() {
        NotificationsBridge.center().reschedule()
    }
}

enum NotificationsBridge {

    /// The centre: the one the app configured, or one made for an alarm
    /// in a process that started without the app.
    static func center() -> AndroidNotificationCenter {
        if let center = AndroidHostNotifications.center {
            return center
        }
        let platform = AndroidNotificationPlatform()
        let center = AndroidNotificationCenter(platform: platform, directory: platform.java.storageDirectory(),
                                               appName: platform.java.appName())
        AndroidHostNotifications.configure(center, declaresRemote: false)
        return center
    }

    /// Before the app starts: `declaresRemote` is the manifest's
    /// `RTCapabilityOptions.notifications.remote`.
    static func configure(declaresRemote: Bool) {
        AndroidHostNotifications.configure(center(), declaresRemote: declaresRemote)
    }
}
