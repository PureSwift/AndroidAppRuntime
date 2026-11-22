import Testing
import AndroidHost
import DynamicCalendar
import DynamicRuntime
import RuntimeCalendar
import RuntimeHost
@testable import AndroidHostCalendars

/// The Kotlin side's calendars, in memory: events as `CalendarFields` has
/// them, by identifier, with the calls the store made. `instances` is
/// what the provider's expansion gives, set by each test.
final class ScriptedCalendars: CalendarSystem {

    var calendarFields: [String] = [
        "1", "Holidays", "holidays@example.com", "4278190335", "0", "0",
        "2", "Personal", "", "4278222848", "1", "1",
    ]

    var events: [String: [String]] = [:]

    var instances: [String] = []

    var calls: [String] = []

    /// The error every call leaves; 0 for none.
    var failing: Int32 = 0

    var nextID = 10

    func error() -> Int32 { failing }

    func calendars() -> [String] { failing == 0 ? calendarFields : [] }

    func instances(_ begin: Int64, end: Int64, calendars: [String]) -> [String] {
        calls.append("instances \(begin) \(end) \(calendars)")
        return instances
    }

    func event(_ identifier: String) -> [String] { events[identifier] ?? [] }

    func insert(_ fields: [String]) -> String {
        calls.append("insert \(fields[2]) \(fields[10])")
        guard failing == 0 else { return "" }
        let identifier = String(nextID)
        nextID += 1
        var stored = fields
        stored[0] = identifier
        // A series' row is its first occurrence.
        stored[11] = fields[10].isEmpty ? "-1" : fields[6]
        events[identifier] = stored
        return identifier
    }

    func update(_ identifier: String, fields: [String]) {
        calls.append("update \(identifier) \(fields[10])")
        var stored = fields
        stored[0] = identifier
        stored[11] = fields[10].isEmpty ? "-1" : fields[6]
        events[identifier] = stored
    }

    func detach(_ identifier: String, occurrence: Int64, fields: [String]) {
        calls.append("detach \(identifier) \(occurrence) \(fields[6])")
    }

    func cancel(_ identifier: String, occurrence: Int64) {
        calls.append("cancel \(identifier) \(occurrence)")
    }

    func delete(_ identifier: String) {
        calls.append("delete \(identifier)")
        events[identifier] = nil
    }

    func dropExceptions(_ identifier: String, occurrence: Int64) {
        calls.append("drop \(identifier) \(occurrence == .min ? "all" : String(occurrence))")
    }
}

final class Permissions: PermissionSystem {

    var apiLevel: Int32 = 34
    var granted: Set<String> = []
    var requested: Set<String> = []
    var declared: Set<String> = Set(AndroidHostCalendars.permissions)
    var requests: [(permissions: [String], id: Int32)] = []

    func isGranted(_ permission: String) -> Bool { granted.contains(permission) }
    func wasRequested(_ permission: String) -> Bool { requested.contains(permission) }
    func isDeclared(_ permission: String) -> Bool { declared.contains(permission) }
    func hasFeature(_ feature: String) -> Bool { true }

    func request(_ permissions: [String], id: Int32) -> Bool {
        requests.append((permissions, id))
        requested.formUnion(permissions)
        return true
    }
}

final class Answer: CalendarCallback {

    var events: [String] = []
    var found: [Event] = []

    func didComplete() { events.append("complete") }
    func didChangeAccess(_ access: Int32) { events.append("access \(access)") }
    func didListCalendars(_ calendars: [any CalendarRecord]) { events.append("calendars \(calendars.count)") }
    func didFindCalendar(_ calendar: (any CalendarRecord)?) { events.append("calendar \(calendar?.title() ?? "none")") }

    func didListEvents(_ events: [any CalendarEventRecord]) {
        found = events.map(Event.init)
        self.events.append("events \(found.count)")
    }

    func didFindEvent(_ event: (any CalendarEventRecord)?) {
        found = event.map { [Event($0)] } ?? []
        events.append("event \(found.first?.id ?? "none")")
    }

    func didFail(_ error: Int32) { events.append("fail \(error)") }
}

/// `AndroidCalendarStore` over a scripted provider, alone and under
/// `HostCalendars`, with access from scripted permissions, answering at
/// once.
///
/// Serialized: `HostCalendars` and `AndroidPermissions` are shared.
@Suite(.serialized) final class AndroidCalendarsTests {

    let system = ScriptedCalendars()

    let permissions = Permissions()

    var observed = 0

    var store: AndroidCalendarStore { AndroidCalendarStore(system: system) }

    /// 2026-11-03 09:00 UTC, a Tuesday.
    static let tuesday: Int64 = 1_793_696_400_000

    static let week: Int64 = 7 * 86_400_000

    init() {
        HostCalendars.reset()
        AndroidHostCalendars.reset()
        AndroidPermissions.reset()
        AndroidPermissions.system = permissions
        permissions.granted = Set(AndroidHostCalendars.permissions)
        configure(.full)
    }

    deinit {
        HostCalendars.reset()
        AndroidHostCalendars.reset()
        AndroidPermissions.reset()
        AndroidPermissions.system = nil
    }

    func configure(_ declared: EventStoreAccess) {
        AndroidHostCalendars.configure(store, declaredAccess: declared) { [unowned self] in
            observed += 1
        }
        HostCalendars.work = { $0() }
        HostCalendars.deliver = { $0() }
    }

    static var standup: Event {
        var event = Event(title: "Standup", start: tuesday, end: tuesday + 1_800_000)
        event.location = "Room 4"
        event.alarms = [.before(minutes: 10)]
        event.recurrence = RecurrenceRule(.weekly, daysOfWeek: [.tuesday], end: .count(4))
        event.availability = .busy
        return event
    }

    /// A weekly series in the store, and its identifier.
    func series() throws -> Event {
        try store.save(Self.standup, span: .thisEvent)
    }

    @Test func anEventCrossesAsStrings() throws {
        var event = Self.standup
        event.id = "7"
        event.calendar = "2"
        event.notes = "Bring news"
        event.timeZone = "Europe/Dublin"
        event.occurrence = Self.tuesday
        let fields = CalendarFields.encode(event)
        #expect(fields == ["7", "2", "Standup", "Room 4", "Bring news", "", String(Self.tuesday), String(Self.tuesday + 1_800_000),
                           "0", "Europe/Dublin", "FREQ=WEEKLY;BYDAY=TU;COUNT=4", String(Self.tuesday), "0", "10", "0"])
        let decoded = try #require(CalendarFields.events(fields + fields))
        #expect(decoded == [event, event])
        #expect(CalendarFields.events(Array(fields.dropLast())) == nil, "an event cut short")
        let calendars = try #require(CalendarFields.calendars(system.calendarFields))
        #expect(calendars.map(\.calendar.title) == ["Holidays", "Personal"])
        #expect(calendars[0].calendar.account == "holidays@example.com" && !calendars[0].calendar.isWritable)
        #expect(calendars[1].calendar.color == 0xFF00_8000 && calendars[1].isPrimary)
    }

    @Test func theDefaultIsTheAccountsOwnThatCanBeWritten() throws {
        #expect(try store.defaultCalendar()?.title == "Personal")
        // None its account's own: the first that can be written.
        system.calendarFields[11] = "0"
        system.calendarFields += ["3", "Work", "ada@example.com", "0", "1", "0"]
        #expect(try store.defaultCalendar()?.title == "Personal")
        system.calendarFields = Array(system.calendarFields.prefix(6))
        #expect(try store.defaultCalendar() == nil)
    }

    @Test func aRangeIsTheProvidersOccurrencesThatOverlapIt() throws {
        var first = Self.standup
        first.id = "10"
        first.calendar = "2"
        first.occurrence = Self.tuesday
        var moved = first
        moved.start += Self.week + 3_600_000
        moved.end += Self.week + 3_600_000
        moved.occurrence = Self.tuesday + Self.week
        moved.isDetached = true
        // The provider gives what touches the range; this ends as it starts.
        var before = Event(title: "Before", start: Self.tuesday - 3_600_000, end: Self.tuesday)
        before.id = "11"
        system.instances = [first, moved, before].flatMap(CalendarFields.encode)
        let found = try store.events(from: Self.tuesday, to: Self.tuesday + 2 * Self.week, in: ["2"])
        #expect(found == [first, moved])
        #expect(system.calls == ["instances \(Self.tuesday) \(Self.tuesday + 2 * Self.week) [\"2\"]"])
    }

    @Test func savingAddsAnEventAndChangesOne() throws {
        let saved = try series()
        #expect(saved.id == "10" && saved.occurrence == Self.tuesday && saved.recurrence == Self.standup.recurrence)
        #expect(saved.alarms == [.before(minutes: 10)])
        var lunch = Event(title: "Lunch", start: Self.tuesday, end: Self.tuesday + 3_600_000)
        lunch = try store.save(lunch, span: .thisEvent)
        lunch.title = "Long lunch"
        #expect(try store.save(lunch, span: .thisEvent).title == "Long lunch")
        #expect(system.calls == ["insert Standup FREQ=WEEKLY;BYDAY=TU;COUNT=4", "insert Lunch ", "update 11 "])
    }

    @Test func oneOccurrenceIsAnException() throws {
        let series = try series()
        var second = series
        second.occurrence = Self.tuesday + Self.week
        second.start = Self.tuesday + Self.week + 3_600_000
        second.end = second.start + 1_800_000
        let saved = try store.save(second, span: .thisEvent)
        #expect(saved.isDetached && saved.occurrence == Self.tuesday + Self.week && saved.recurrence == series.recurrence)
        #expect(system.calls.last == "detach 10 \(Self.tuesday + Self.week) \(second.start)")
        try store.remove(second, span: .thisEvent)
        #expect(system.calls.last == "cancel 10 \(Self.tuesday + Self.week)")
    }

    @Test func thisAndWhatFollowsEndsTheSeriesAndStartsAnother() throws {
        let series = try series()
        var third = series
        third.occurrence = Self.tuesday + 2 * Self.week
        third.start = Self.tuesday + 2 * Self.week
        third.end = third.start + 1_800_000
        third.title = "Retro"
        let started = try store.save(third, span: .futureEvents)
        #expect(started.id == "11" && started.title == "Retro" && started.start == third.start)
        let until = Self.tuesday + 2 * Self.week - 1000
        let ended = try #require(try store.event(withID: "10")?.recurrence)
        #expect(ended.end == .until(until))
        #expect(system.calls.suffix(3) == ["insert Retro FREQ=WEEKLY;BYDAY=TU;COUNT=4", "update 10 \(ended.rrule)",
                                           "drop 10 \(Self.tuesday + 2 * Self.week)"])
        // From the first occurrence: the whole series, without its exceptions.
        var whole = series
        whole.title = "Daily"
        whole.recurrence = RecurrenceRule(.daily)
        #expect(try store.save(whole, span: .futureEvents).recurrence == RecurrenceRule(.daily))
        #expect(system.calls.suffix(2) == ["drop 10 all", "update 10 FREQ=DAILY"])
    }

    @Test func removingEndsWhatWasAskedFor() throws {
        var series = try series()
        series.occurrence = Self.tuesday + Self.week
        try store.remove(series, span: .futureEvents)
        #expect(try store.event(withID: "10")?.recurrence?.end == .until(Self.tuesday + Self.week - 1000))
        #expect(system.calls.last == "drop 10 \(Self.tuesday + Self.week)")
        series.occurrence = Self.tuesday
        try store.remove(series, span: .futureEvents)
        #expect(system.calls.last == "delete 10")
        var lunch = try store.save(Event(title: "Lunch", start: Self.tuesday, end: Self.tuesday + 3_600_000), span: .thisEvent)
        try store.remove(lunch, span: .thisEvent)
        #expect(system.calls.last == "delete 11")
        lunch.id = "99"
        #expect(throws: EventStoreError.notFound) { try self.store.remove(lunch, span: .thisEvent) }
    }

    @Test func androidsErrorsAreTheStores() {
        system.failing = EventStoreError.unsupportedRecurrence.rawValue
        #expect(throws: EventStoreError.unsupportedRecurrence) { try self.series() }
        // The Kotlin side sends `unknown` as -1, since 0 is no error.
        system.failing = -1
        #expect(throws: EventStoreError.unknown) { try self.store.calendars() }
        system.failing = EventStoreError.notAuthorized.rawValue
        let answer = Answer()
        HostCalendars.shared().events(0, end: Self.week, calendars: [], callback: answer)
        #expect(answer.events == ["fail \(EventStoreError.notAuthorized.rawValue)"])
    }

    @Test func throughTheHostAWriteOnlyAppAddsAndReadsNothing() throws {
        configure(.writeOnly)
        #expect(HostCalendars.effectiveAccess == .writeOnly)
        let shared = HostCalendars.shared()
        let read = Answer()
        shared.calendars(read)
        #expect(read.events == ["fail \(EventStoreError.notAuthorized.rawValue)"])
        // A new event goes to the default calendar; its identifier stays
        // the store's.
        let added = Answer()
        let record = shared.makeEvent()
        Self.standup.fill(record)
        record.save(0, callback: added)
        #expect(added.events == ["event none"])
        #expect(system.events["10"]?[1] == "2")
    }

    @Test func accessIsAndroidsPermissions() throws {
        #expect(HostCalendars.access == .full)
        #expect(observed == 1)
        AndroidHostCalendars.refresh()
        #expect(observed == 1, "changes are reported once")
        // Not asked yet: asking is Android's dialog, for both.
        permissions.granted = []
        AndroidHostCalendars.refresh()
        #expect(HostCalendars.access == .notDetermined)
        let answer = Answer()
        HostCalendars.shared().requestAccess(answer)
        let request = try #require(permissions.requests.last)
        #expect(request.permissions == [AndroidHostCalendars.readCalendar, AndroidHostCalendars.writeCalendar])
        permissions.granted = Set(request.permissions)
        AndroidPermissions.didRequest(id: request.id, permissions: request.permissions, granted: [true, true])
        #expect(answer.events == ["access \(EventStoreAccess.full.rawValue)"])
        // Turned off in Settings.
        permissions.granted = []
        AndroidHostCalendars.refresh()
        #expect(HostCalendars.access == .denied)
    }
}
