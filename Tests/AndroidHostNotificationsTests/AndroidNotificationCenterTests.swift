import Foundation
import Testing
import DynamicNotifications
import DynamicRuntime
import RuntimeHost
import RuntimeNotifications
@testable import AndroidHostNotifications

/// Android's notifications as the Kotlin side would make them: what was
/// posted, the alarms set, and what's showing.
final class ScriptedPlatform: NotificationPlatform {

    var apiLevel: Int32 = 32

    var enabled = true

    var exact = true

    /// Whether the setting for exact alarms opens.
    var opensExactSetting = false

    var zone = "America/New_York"

    var channels: [[String: Any]] = []

    var posted: [[String: Any]] = []

    var showing: [String] = []

    var alarms: [String: Int64] = [:]

    var calls: [String] = []

    func areEnabled() -> Bool { enabled }

    func canScheduleExact() -> Bool { exact }

    func requestExactTiming() -> Bool {
        calls.append("requestExactTiming")
        return opensExactSetting
    }

    func timeZone() -> String { zone }

    func setChannels(_ json: String) {
        channels = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [[String: Any]] ?? []
    }

    func post(_ json: String) -> Bool {
        let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        posted.append(object)
        if let identifier = object["identifier"] as? String, !showing.contains(identifier) {
            showing.append(identifier)
        }
        return enabled
    }

    func delivered() -> [String] { showing }

    func removeDelivered(_ identifiers: [String], all: Bool) {
        showing = all ? [] : showing.filter { !identifiers.contains($0) }
    }

    func setAlarm(_ identifier: String, at milliseconds: Int64) {
        alarms[identifier] = milliseconds
    }

    func cancelAlarm(_ identifier: String) {
        alarms[identifier] = nil
        calls.append("cancelAlarm \(identifier)")
    }
}

final class Listener: NotificationsDelegate {

    var received: [String] = []

    var responses: [(identifier: String, action: String, text: String?, userInfo: [String: String])] = []

    func didReceive(_ notification: any NotificationRecord) {
        received.append(notification.identifier())
    }

    func didRespond(_ notification: any NotificationRecord, action: String, text: String?) {
        responses.append((notification.identifier(), action, text, notification.keys().reduce(into: [:]) { $0[$1] = notification.value($1) }))
    }
}

/// `AndroidNotificationCenter` over a scripted platform and a temporary
/// directory. The clock is fixed: Tuesday 14 November 2023, 22:13:20 UTC,
/// 17:13:20 in New York.
///
/// Serialized: `HostNotifications` is shared.
@Suite(.serialized) final class AndroidNotificationCenterTests {

    let directory: URL

    let platform = ScriptedPlatform()

    let center: AndroidNotificationCenter

    static let now: Int64 = 1_700_000_000_000

    init() throws {
        directory = Foundation.FileManager.default.temporaryDirectory.appendingPathComponent("NotificationsTests-\(UUID().uuidString)")
        try Foundation.FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        center = AndroidNotificationCenter(platform: platform, directory: directory.path, appName: "Timers")
        center.now = { Date(timeIntervalSince1970: Double(Self.now) / 1000) }
        HostNotifications.reset()
        HostNotifications.deliver = { $0() }
    }

    deinit {
        HostNotifications.reset()
        try? Foundation.FileManager.default.removeItem(at: directory)
    }

    func add(_ notification: HostNotification) -> NotificationError? {
        var result: NotificationError?? = .none
        center.add(notification) { result = .some($0) }
        return result ?? .unknown
    }

    static let timer = NotificationCategory(
        identifier: "timer", name: "Timers",
        actions: [
            NotificationAction(identifier: "repeat", title: "Repeat"),
            .textInput(identifier: "reply", title: "Reply", buttonTitle: "Send", placeholder: "Message"),
        ],
        interruption: .timeSensitive)

    // MARK: Permission

    @Test func beforeAndroid13TheAppsSwitchIsThePermission() throws {
        var settings: NotificationSettings?
        center.settings { settings = $0 }
        #expect(settings?.authorizationStatus == .granted)
        #expect(settings?.deliversWhenClosed == true)
        #expect(settings?.exactTiming == true)
        platform.enabled = false
        platform.exact = false
        center.settings { settings = $0 }
        #expect(settings?.authorizationStatus == .denied)
        #expect(settings?.exactTiming == false)
        // Nothing to prompt for: the answer is where things stand.
        var asked: Result<NotificationSettings, NotificationError>?
        center.requestAuthorization([.alert]) { asked = $0 }
        #expect(try asked?.get().authorizationStatus == .denied)
    }

    @Test func exactTimingIsAnsweredWhenTheUserComesBack() throws {
        platform.exact = false
        platform.opensExactSetting = true
        var answer: Result<NotificationSettings, NotificationError>?
        center.requestExactTiming { answer = $0 }
        #expect(answer == nil)
        platform.exact = true
        center.didBecomeActive()
        #expect(try answer?.get().exactTiming == true)
        // Where there's no setting to open, at once.
        platform.opensExactSetting = false
        answer = nil
        center.requestExactTiming { answer = $0 }
        #expect(answer != nil)
    }

    // MARK: Categories

    @Test func categoriesAreChannels() {
        center.setCategories([
            Self.timer,
            NotificationCategory(identifier: "quiet", name: "Quiet", interruption: .passive),
            NotificationCategory(identifier: "mute", name: "Mute", sound: .none),
        ])
        let channels = platform.channels.map { [$0["id"] as? String, $0["name"] as? String, "\($0["importance"] ?? "")", "\($0["silent"] ?? "")"] }
        #expect(channels == [
            ["rt.default", "Timers", "3", "0"],
            ["rt.c.timer", "Timers", "4", "0"],
            ["rt.c.quiet", "Quiet", "2", "1"],
            ["rt.c.mute", "Mute", "3", "1"],
        ])
        // Kept for posting with the app closed, and made again after a restart.
        platform.channels = []
        AndroidNotificationCenter(platform: platform, directory: directory.path, appName: "Timers").reschedule()
        #expect(platform.channels.count == 4)
    }

    // MARK: Showing

    @Test func aNotificationWithNoTriggerIsPostedNow() throws {
        center.setCategories([Self.timer])
        let listener = Listener()
        HostNotifications.current().setDelegate(listener)
        #expect(add(HostNotification(identifier: "now", title: "Tea", body: "Ready.", category: "timer", badge: 3,
                                     userInfo: ["timer": "42"])) == nil)
        let posted = try #require(platform.posted.first)
        #expect(posted["channel"] as? String == "rt.c.timer")
        #expect(posted["title"] as? String == "Tea")
        #expect(posted["number"] as? Int == 3)
        let actions = posted["actions"] as? [[String: Any]] ?? []
        #expect(actions.map { $0["id"] as? String } == ["repeat", "reply"])
        #expect(actions[1]["button"] as? String == "Send")
        // The guest hears of it while it runs.
        #expect(listener.received == ["now"])
        #expect(platform.alarms.isEmpty)
    }

    @Test func anUnknownCategoryIsTheDefaultOne() throws {
        #expect(add(HostNotification(identifier: "a", title: "A", category: "none")) == nil)
        #expect(platform.posted.first?["channel"] as? String == "rt.default")
        #expect((platform.posted.first?["actions"] as? [Any])?.isEmpty == true)
    }

    @Test func inFrontTheGuestDecidesWhatShows() {
        center.didBecomeActive()
        center.setForegroundPresentation([])
        #expect(add(HostNotification(identifier: "quiet", title: "Q")) == nil)
        #expect(platform.posted.isEmpty)
        center.setForegroundPresentation([.list])
        #expect(add(HostNotification(identifier: "listed", title: "L")) == nil)
        #expect(platform.posted.count == 1)
        // Without .sound it's posted silently.
        #expect(platform.posted[0]["silent"] as? Bool == true)
        // In the background, as usual.
        center.didResignActive()
        #expect(add(HostNotification(identifier: "away", title: "A")) == nil)
        #expect(platform.posted[1]["silent"] as? Bool == false)
    }

    // MARK: Scheduling

    @Test func aScheduledOneIsAnAlarmAndKept() {
        #expect(add(HostNotification(identifier: "timer-1", title: "Timer", trigger: .interval(seconds: 300, repeats: false))) == nil)
        #expect(platform.alarms == ["timer-1": Self.now + 300_000])
        #expect(platform.posted.isEmpty)
        var pending: [String] = []
        center.pending { pending = $0 }
        #expect(pending == ["timer-1"])
        // Another process, after a restart, finds it.
        let later = AndroidNotificationCenter(platform: platform, directory: directory.path, appName: "Timers")
        later.pending { pending = $0 }
        #expect(pending == ["timer-1"])

        center.removePending(["timer-1"])
        center.pending { pending = $0 }
        #expect(pending.isEmpty)
        #expect(platform.alarms.isEmpty)
    }

    @Test func anIdentifierInUseIsReplaced() {
        #expect(add(HostNotification(identifier: "x", title: "Now")) == nil)
        #expect(platform.showing == ["x"])
        #expect(add(HostNotification(identifier: "x", title: "Later", trigger: .interval(seconds: 60, repeats: false))) == nil)
        #expect(platform.showing.isEmpty)
        #expect(add(HostNotification(identifier: "x", title: "Later still", trigger: .interval(seconds: 120, repeats: false))) == nil)
        #expect(platform.calls.contains("cancelAlarm x"))
        #expect(platform.alarms == ["x": Self.now + 120_000])
    }

    @Test func whatCantBeScheduled() {
        #expect(add(HostNotification(identifier: "past", trigger: .date(milliseconds: Self.now - 1))) == .invalid)
        for index in 0..<AndroidNotificationCenter.pendingLimit {
            _ = add(HostNotification(identifier: "n\(index)", trigger: .interval(seconds: 60, repeats: false)))
        }
        #expect(add(HostNotification(identifier: "one more", trigger: .interval(seconds: 60, repeats: false))) == .limitReached)
    }

    @Test func anAlarmPostsItAndARepeatIsSetAgain() {
        center.setCategories([Self.timer])
        #expect(add(HostNotification(identifier: "once", title: "Once", trigger: .interval(seconds: 60, repeats: false))) == nil)
        #expect(add(HostNotification(identifier: "every", title: "Every", category: "timer", trigger: .interval(seconds: 60, repeats: true))) == nil)
        center.alarm("once")
        #expect(platform.posted.map { $0["identifier"] as? String } == ["once"])
        var pending: [String] = []
        center.pending { pending = $0 }
        #expect(pending == ["every"])
        // It came three minutes late: the times it missed are skipped.
        center.now = { Date(timeIntervalSince1970: Double(Self.now + 180_000) / 1000) }
        center.alarm("every")
        #expect(platform.posted.last?["channel"] as? String == "rt.c.timer")
        #expect(platform.alarms["every"] == Self.now + 240_000)
        // An alarm for something no longer pending does nothing.
        center.alarm("once")
        #expect(platform.posted.count == 2)
    }

    @Test func calendarPartsAreTheDevicesLocalTime() {
        // Mondays at 7:00 in New York: 12:00 UTC, since daylight time has ended.
        #expect(add(HostNotification(identifier: "alarm", trigger: .calendar(HostNotificationDateParts(hour: 7, minute: 0, weekday: 2), repeats: true))) == nil)
        let monday: Int64 = 1_700_481_600_000   // 2023-11-20 12:00 UTC
        #expect(platform.alarms["alarm"] == monday)
        center.now = { Date(timeIntervalSince1970: Double(monday) / 1000) }
        center.alarm("alarm")
        #expect(platform.alarms["alarm"] == monday + 7 * 86_400_000)
        // The device moves to London: set again at 7:00 there.
        platform.zone = "Europe/London"
        center.reschedule()
        #expect(platform.alarms["alarm"] == monday + 7 * 86_400_000 - 5 * 3_600_000)
    }

    @Test func aRestartShowsWhatCameDueAndSetsTheRest() {
        #expect(add(HostNotification(identifier: "soon", title: "Soon", trigger: .interval(seconds: 60, repeats: false))) == nil)
        #expect(add(HostNotification(identifier: "later", title: "Later", trigger: .interval(seconds: 3600, repeats: false))) == nil)
        platform.alarms = [:]
        center.now = { Date(timeIntervalSince1970: Double(Self.now + 120_000) / 1000) }
        center.reschedule()
        #expect(platform.posted.map { $0["identifier"] as? String } == ["soon"])
        #expect(platform.alarms == ["later": Self.now + 3_600_000])
    }

    // MARK: Responses

    @Test func aResponseWaitsForTheGuest() throws {
        #expect(add(HostNotification(identifier: "timer-2", title: "Timer", userInfo: ["minutes": "5"])) == nil)
        let record = try #require(platform.posted.first?["record"] as? String)
        // As a tap's intent brings it back, with the app just started.
        center.responded(record, action: "reply", text: "On my way")
        let listener = Listener()
        HostNotifications.current().setDelegate(listener)
        #expect(listener.responses.count == 1)
        #expect(listener.responses.first?.identifier == "timer-2")
        #expect(listener.responses.first?.action == "reply")
        #expect(listener.responses.first?.text == "On my way")
        #expect(listener.responses.first?.userInfo == ["minutes": "5"])
    }

    @Test func aRecordKeepsEveryKindOfTrigger() {
        let triggers: [HostNotificationTrigger?] = [
            nil,
            .interval(seconds: 90, repeats: true),
            .date(milliseconds: Self.now),
            .calendar(HostNotificationDateParts(month: 2, day: 29, hour: 9), repeats: false),
        ]
        for trigger in triggers {
            let notification = HostNotification(identifier: "x", title: "T", subtitle: "S", body: "B", category: "c", thread: "t",
                                                badge: 2, isSilent: true, userInfo: ["k": "v"], trigger: trigger, delivered: 5)
            #expect(AndroidNotificationCenter.decode(AndroidNotificationCenter.encode(StoredNotification(notification)))?.host == notification)
        }
    }

    // MARK: Badges

    @Test func androidHasNoBadgeToSet() {
        center.setBadgeCount(4)
        #expect(platform.calls.isEmpty)
    }
}
