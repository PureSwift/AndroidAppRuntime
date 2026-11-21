import DynamicNotifications
import Foundation
import RuntimeNotifications

/// What the notifications keep across launches, as JSON in the app's
/// `noBackupFilesDir`: the categories, for posting with the app closed, and
/// the scheduled requests, for setting their alarms again.
struct StoredState: Codable, Equatable {

    var categories: [StoredCategory] = []

    /// By identifier.
    var pending: [String: StoredRequest] = [:]
}

struct StoredRequest: Codable, Equatable {

    var notification: StoredNotification

    /// When its alarm is set for: milliseconds since 1970 UTC.
    var fireAt: Int64
}

struct StoredCategory: Codable, Equatable {

    struct Action: Codable, Equatable {
        var identifier: String
        var title: String
        var options: Int32
        var textInput: TextInput?

        struct TextInput: Codable, Equatable {
            var buttonTitle: String
            var placeholder: String
        }
    }

    var identifier: String
    var name: String
    var actions: [Action]
    var interruption: Int32
    /// 0 default, 1 none, 2 named.
    var sound: Int32

    init(_ category: NotificationCategory) {
        identifier = category.identifier
        name = category.name
        actions = category.actions.map { action in
            Action(identifier: action.identifier, title: action.title, options: action.options.rawValue,
                   textInput: action.textInput.map { Action.TextInput(buttonTitle: $0.buttonTitle, placeholder: $0.placeholder) })
        }
        interruption = category.interruption.rawValue
        switch category.sound {
        case .none: sound = 1
        case .named: sound = 2
        default: sound = 0
        }
    }
}

/// A `HostNotification`, as JSON: kept on disk, and carried in the intent a
/// tap or a button opens the app with.
struct StoredNotification: Codable, Equatable {

    var identifier: String
    var title: String
    var subtitle: String
    var body: String
    var category: String?
    var thread: String?
    var badge: Int?
    var isSilent: Bool
    var userInfo: [String: String]
    var trigger: Trigger?
    var isRemote: Bool
    var delivered: Int64

    struct Trigger: Codable, Equatable {
        /// 1 an interval, 2 a date, 3 calendar parts.
        var kind: Int
        var repeats: Bool
        var seconds: Double?
        var milliseconds: Int64?
        /// Year, month, day, hour, minute, second, weekday; nil where not
        /// given.
        var parts: [Int?]?
    }

    init(_ notification: HostNotification) {
        identifier = notification.identifier
        title = notification.title
        subtitle = notification.subtitle
        body = notification.body
        category = notification.category
        thread = notification.thread
        badge = notification.badge
        isSilent = notification.isSilent
        userInfo = notification.userInfo
        isRemote = notification.isRemote
        delivered = notification.delivered
        switch notification.trigger {
        case nil:
            trigger = nil
        case .interval(let seconds, let repeats):
            trigger = Trigger(kind: 1, repeats: repeats, seconds: seconds)
        case .date(let milliseconds):
            trigger = Trigger(kind: 2, repeats: false, milliseconds: milliseconds)
        case .calendar(let parts, let repeats):
            trigger = Trigger(kind: 3, repeats: repeats,
                              parts: [parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second, parts.weekday])
        }
    }

    var host: HostNotification {
        var hostTrigger: HostNotificationTrigger?
        if let trigger {
            switch trigger.kind {
            case 1:
                hostTrigger = .interval(seconds: trigger.seconds ?? 0, repeats: trigger.repeats)
            case 2:
                hostTrigger = .date(milliseconds: trigger.milliseconds ?? 0)
            case 3:
                let parts = (trigger.parts ?? []) + Array(repeating: nil, count: 7)
                hostTrigger = .calendar(HostNotificationDateParts(
                    year: parts[0], month: parts[1], day: parts[2], hour: parts[3], minute: parts[4], second: parts[5], weekday: parts[6]
                ), repeats: trigger.repeats)
            default:
                hostTrigger = nil
            }
        }
        return HostNotification(identifier: identifier, title: title, subtitle: subtitle, body: body, category: category,
                                thread: thread, badge: badge, isSilent: isSilent, userInfo: userInfo, trigger: hostTrigger,
                                isRemote: isRemote, delivered: delivered)
    }
}

/// The state file, read and written whole. A file that doesn't read is an
/// empty state.
struct NotificationStore {

    let path: String

    func load() -> StoredState {
        guard let data = FileManager.default.contents(atPath: path),
              let state = try? JSONDecoder().decode(StoredState.self, from: data) else {
            return StoredState()
        }
        return state
    }

    func save(_ state: StoredState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
    }
}
