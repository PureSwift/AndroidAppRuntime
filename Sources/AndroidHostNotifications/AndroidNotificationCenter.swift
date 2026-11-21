import AndroidHost
import DynamicNotifications
import DynamicRuntime
import Foundation
import RuntimeHost
import RuntimeNotifications

/// What `AndroidNotificationCenter` asks Android, through the Kotlin
/// `org.pureswift.appruntime.contracts.NotificationSystem` (`AndroidHostApp`
/// binds it). Main thread only.
public protocol NotificationPlatform: AnyObject {

    /// `Build.VERSION.SDK_INT`.
    var apiLevel: Int32 { get }

    /// The app's switch in Settings.
    func areEnabled() -> Bool

    /// Whether alarms arrive on time.
    func canScheduleExact() -> Bool

    /// Opens the setting for exact alarms; false when there's none to
    /// change.
    func requestExactTiming() -> Bool

    /// The device's time zone identifier.
    func timeZone() -> String

    /// `[{id, name, importance, silent}]`.
    func setChannels(_ json: String)

    /// Shows a notification described by `json`; false without permission.
    func post(_ json: String) -> Bool

    /// The identifiers of the app's notifications showing now.
    func delivered() -> [String]

    func removeDelivered(_ identifiers: [String], all: Bool)

    /// Wakes the app for `identifier` at a time in milliseconds since 1970.
    func setAlarm(_ identifier: String, at milliseconds: Int64)

    func cancelAlarm(_ identifier: String)
}

/// The notification presenter on Android (`Plan.md` §6.9), under
/// AppRuntime's `HostNotifications`:
///
/// - each category is a channel, `rt.c.<identifier>`, and a notification
///   with none is in `rt.default`;
/// - a notification shown now is posted at once; a scheduled one is kept on
///   disk and posted when an `AlarmManager` alarm wakes the app, which may
///   have been closed. A repeating one is set again each time it fires, and
///   all of them after a restart or a change of the clock;
/// - permission is `POST_NOTIFICATIONS` from Android 13, and the app's
///   switch in Settings always;
/// - the response to a tap or a button reaches the guest through
///   `HostNotifications.responded(to:action:text:)`.
///
/// Main thread only.
public final class AndroidNotificationCenter: NotificationPresenter {

    let platform: any NotificationPlatform

    /// What's kept across launches: categories and scheduled requests.
    let store: NotificationStore

    /// What a notification that arrives while the app is in front does.
    var presentation: NotificationPresentationOptions = .all

    /// Whether the app is in front: set by the host from the Activity's
    /// lifecycle.
    public var isActive = false

    /// The time, for scheduling. Tests set it.
    var now: () -> Date = { Date() }

    /// A request for exact timing, answered when the user comes back from
    /// Settings.
    private var waitingForExactTiming: [(Result<NotificationSettings, NotificationError>) -> Void] = []

    /// The most scheduled requests kept: Android allows an app 500 alarms.
    static let pendingLimit = 500

    static let defaultChannel = "rt.default"

    /// `POST_NOTIFICATIONS`, from Android 13.
    static let permission = "android.permission.POST_NOTIFICATIONS"

    /// The name of the default channel: the app's.
    let appName: String

    public init(platform: any NotificationPlatform, directory: String, appName: String) {
        self.platform = platform
        self.store = NotificationStore(path: directory + "/org.pureswift.appruntime.notifications.json")
        self.appName = appName
    }

    var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: platform.timeZone()) ?? .current
        return calendar
    }

    // MARK: Permission

    var status: PermissionStatus {
        let enabled = platform.areEnabled()
        guard platform.apiLevel >= 33 else {
            return enabled ? .granted : .denied
        }
        guard let system = AndroidPermissions.system else {
            return .unavailable
        }
        let status = AndroidPermissions.status(AndroidPermissions.Requirement(permissions: [Self.permission]), system: system)
        // Allowed, and then turned off in Settings.
        return status == .granted && !enabled ? .denied : status
    }

    var currentSettings: NotificationSettings {
        let status = status
        let allowed = status == .granted
        return NotificationSettings(authorizationStatus: status, alerts: allowed, sounds: allowed, badges: false,
                                    exactTiming: platform.canScheduleExact(), deliversWhenClosed: true)
    }

    public func settings(_ completion: @escaping (NotificationSettings) -> Void) {
        completion(currentSettings)
    }

    /// Prompts only while the user hasn't answered; Android grants all of
    /// the options or none.
    public func requestAuthorization(_ options: AuthorizationOptions, completion: @escaping (Result<NotificationSettings, NotificationError>) -> Void) {
        guard platform.apiLevel >= 33, status == .notDetermined else {
            completion(.success(currentSettings))
            return
        }
        AndroidPermissions.request([Self.permission]) { [self] _ in
            completion(.success(currentSettings))
        }
    }

    public func requestExactTiming(_ completion: @escaping (Result<NotificationSettings, NotificationError>) -> Void) {
        guard platform.requestExactTiming() else {
            completion(.success(currentSettings))
            return
        }
        waitingForExactTiming.append(completion)
    }

    /// The app came forward: the user may be back from Settings.
    public func didBecomeActive() {
        isActive = true
        let waiting = waitingForExactTiming
        waitingForExactTiming = []
        for completion in waiting {
            completion(.success(currentSettings))
        }
    }

    public func didResignActive() {
        isActive = false
    }

    // MARK: Categories

    public func setCategories(_ categories: [NotificationCategory]) {
        var stored = store.load()
        stored.categories = categories.map(StoredCategory.init)
        store.save(stored)
        makeChannels(stored.categories)
    }

    static func channel(_ category: String?) -> String {
        category.map { "rt.c." + $0 } ?? defaultChannel
    }

    /// `NotificationManager`'s importance for each interruption level.
    static func importance(_ interruption: Int32) -> Int {
        switch NotificationInterruption(rawValue: interruption) ?? .active {
        case .passive: 2         // IMPORTANCE_LOW: no sound, no banner
        case .timeSensitive: 4   // IMPORTANCE_HIGH: a banner
        default: 3               // IMPORTANCE_DEFAULT
        }
    }

    func makeChannels(_ categories: [StoredCategory]) {
        var channels: [[String: Any]] = [["id": Self.defaultChannel, "name": appName, "importance": 3, "silent": false]]
        for category in categories {
            channels.append([
                "id": Self.channel(category.identifier), "name": category.name,
                "importance": Self.importance(category.interruption),
                // A named sound plays the default one: Android's channels
                // take a URI, and the bundle's files have none yet.
                "silent": category.sound == 1 || category.interruption == NotificationInterruption.passive.rawValue,
            ])
        }
        platform.setChannels(Self.json(channels))
    }

    // MARK: Adding

    public func add(_ notification: HostNotification, completion: @escaping (NotificationError?) -> Void) {
        // An identifier in use is replaced, pending or delivered.
        var stored = store.load()
        if stored.pending.removeValue(forKey: notification.identifier) != nil {
            platform.cancelAlarm(notification.identifier)
        }
        platform.removeDelivered([notification.identifier], all: false)
        guard let trigger = notification.trigger else {
            store.save(stored)
            deliver(notification, stored)
            completion(nil)
            return
        }
        guard stored.pending.count < Self.pendingLimit else {
            store.save(stored)
            completion(.limitReached)
            return
        }
        guard let date = trigger.nextDate(after: now(), calendar: calendar) else {
            store.save(stored)
            completion(.invalid)
            return
        }
        let fireAt = Self.milliseconds(date)
        stored.pending[notification.identifier] = StoredRequest(notification: StoredNotification(notification), fireAt: fireAt)
        store.save(stored)
        platform.setAlarm(notification.identifier, at: fireAt)
        completion(nil)
    }

    /// Shows a notification now, as the app's state and the guest's
    /// foreground presentation say, and tells the guest if it's running.
    func deliver(_ notification: HostNotification, _ stored: StoredState) {
        var notification = notification
        notification.delivered = Self.milliseconds(now())
        let shows = !isActive || !presentation.isDisjoint(with: [.banner, .list])
        if shows {
            _ = platform.post(postJSON(notification, stored))
        }
        // Dropped unless the guest runs and listens.
        HostNotifications.received(notification)
    }

    /// What `NotificationSystem.post` takes.
    func postJSON(_ notification: HostNotification, _ stored: StoredState) -> String {
        let category = notification.category.flatMap { identifier in stored.categories.first { $0.identifier == identifier } }
        var object: [String: Any] = [
            "identifier": notification.identifier,
            // An unknown category is the default one.
            "channel": category.map { Self.channel($0.identifier) } ?? Self.defaultChannel,
            "title": notification.title,
            "subtitle": notification.subtitle,
            "body": notification.body,
            "thread": notification.thread ?? "",
            "silent": notification.isSilent || (isActive && !presentation.contains(.sound)),
            "record": Self.encode(StoredNotification(notification)),
        ]
        if let badge = notification.badge {
            object["number"] = badge
        }
        object["actions"] = (category?.actions ?? []).map { action -> [String: Any] in
            var button: [String: Any] = ["id": action.identifier, "title": action.title]
            if let input = action.textInput {
                button["button"] = input.buttonTitle
                button["placeholder"] = input.placeholder
            }
            return button
        }
        return Self.json(object)
    }

    // MARK: From Android

    /// A scheduled notification is due: shown, and set again if it
    /// repeats.
    public func alarm(_ identifier: String) {
        var stored = store.load()
        guard let request = stored.pending[identifier] else { return }
        let notification = request.notification.host
        if let trigger = notification.trigger, trigger.repeats, let next = nextFire(trigger, after: request.fireAt) {
            stored.pending[identifier]?.fireAt = next
            platform.setAlarm(identifier, at: next)
        } else {
            stored.pending[identifier] = nil
        }
        store.save(stored)
        deliver(notification, stored)
    }

    /// After a restart, an update, or a change of the clock: every alarm
    /// set again, a calendar trigger's at its time in the new zone, and
    /// what came due meanwhile shown now.
    public func reschedule() {
        let stored = store.load()
        makeChannels(stored.categories)
        let now = Self.milliseconds(now())
        for (identifier, request) in stored.pending.sorted(by: { $0.key < $1.key }) {
            if request.fireAt <= now {
                alarm(identifier)
                continue
            }
            var fireAt = request.fireAt
            if case .calendar = request.notification.host.trigger,
               let date = request.notification.host.trigger?.nextDate(after: Self.date(now), calendar: calendar) {
                fireAt = Self.milliseconds(date)
                var updated = store.load()
                updated.pending[identifier]?.fireAt = fireAt
                store.save(updated)
            }
            platform.setAlarm(identifier, at: fireAt)
        }
    }

    /// When a repeating trigger next fires after it fired at `fired`, and
    /// after now: an alarm that came late skips the times it missed.
    func nextFire(_ trigger: HostNotificationTrigger, after fired: Int64) -> Int64? {
        let now = now()
        var after = Self.date(fired)
        if case .calendar = trigger {
            after = max(after, now)
        }
        var next = trigger.nextDate(after: after, calendar: calendar)
        while let date = next, date <= now {
            next = trigger.nextDate(after: date, calendar: calendar)
        }
        return next.map(Self.milliseconds)
    }

    /// The user tapped a notification or one of its buttons.
    public func responded(_ record: String, action: String, text: String?) {
        guard let notification = Self.decode(record) else {
            HostLog.error("Notifications: a response with a notification that doesn't read")
            return
        }
        HostNotifications.responded(to: notification.host, action: action, text: text)
    }

    // MARK: Listing and removing

    public func pending(_ completion: @escaping ([String]) -> Void) {
        completion(store.load().pending.keys.sorted())
    }

    public func delivered(_ completion: @escaping ([String]) -> Void) {
        completion(platform.delivered().sorted())
    }

    public func removePending(_ identifiers: [String]?) {
        var stored = store.load()
        let removed = identifiers ?? Array(stored.pending.keys)
        for identifier in removed where stored.pending.removeValue(forKey: identifier) != nil {
            platform.cancelAlarm(identifier)
        }
        store.save(stored)
    }

    public func removeDelivered(_ identifiers: [String]?) {
        platform.removeDelivered(identifiers ?? [], all: identifiers == nil)
    }

    /// Android has no number on the app's icon to set: launchers count the
    /// notifications, and show a notification's own number.
    public func setBadgeCount(_ count: Int) { }

    public func setForegroundPresentation(_ options: NotificationPresentationOptions) {
        presentation = options
    }

    // MARK: Helpers

    static func milliseconds(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    static func date(_ milliseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(milliseconds) / 1000)
    }

    static func json(_ object: Any) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func encode(_ notification: StoredNotification) -> String {
        guard let data = try? JSONEncoder().encode(notification) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }

    static func decode(_ record: String) -> StoredNotification? {
        try? JSONDecoder().decode(StoredNotification.self, from: Data(record.utf8))
    }
}
