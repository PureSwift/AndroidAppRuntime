import AndroidHost
import DynamicCalendar
import DynamicRuntime
import RuntimeCalendar
import RuntimeHost

/// What `AndroidCalendarStore` asks Android, through the Kotlin
/// `org.pureswift.appruntime.contracts.CalendarSystem` (`AndroidHostApp`
/// binds it). Called on the calendar queue, one call at a time. Each call
/// leaves an `EventStoreError` raw value for `error()`: 0 when it
/// succeeded, and -1 for `unknown`.
///
/// A calendar crosses as six strings, an event as fifteen
/// (`CalendarFields`).
public protocol CalendarSystem: AnyObject {

    func error() -> Int32

    /// Every calendar, in the provider's order.
    func calendars() -> [String]

    /// The provider's occurrences from `begin` to `end`, in the calendars
    /// named; none named is all.
    func instances(_ begin: Int64, end: Int64, calendars: [String]) -> [String]

    /// One event as its row has it: a series' first occurrence.
    func event(_ identifier: String) -> [String]

    /// Adds an event; gives its identifier.
    func insert(_ fields: [String]) -> String

    /// Changes an event, a whole series if it repeats.
    func update(_ identifier: String, fields: [String])

    /// Changes one occurrence of a series by itself.
    func detach(_ identifier: String, occurrence: Int64, fields: [String])

    /// Cancels one occurrence of a series.
    func cancel(_ identifier: String, occurrence: Int64)

    /// Deletes an event, with a series' exceptions.
    func delete(_ identifier: String)

    /// Deletes a series' exceptions for its occurrences from `occurrence`
    /// on.
    func dropExceptions(_ identifier: String, occurrence: Int64)
}

/// Calendars and events as the Kotlin side writes them. A calendar: the
/// identifier, title, account, colour, writable and primary. An event: the
/// identifier, calendar, title, location, notes, URL, start, end, all day,
/// time zone, `RRULE`, occurrence (-1 for none), detached, alarms and
/// availability.
enum CalendarFields {

    static let calendarCount = 6

    static let eventCount = 15

    /// The calendars, with whether each is its account's own; nil when
    /// they don't parse.
    static func calendars(_ fields: [String]) -> [(calendar: EventCalendar, isPrimary: Bool)]? {
        guard fields.count % calendarCount == 0 else { return nil }
        var found: [(EventCalendar, Bool)] = []
        var index = 0
        while index < fields.count {
            let color = UInt32(fields[index + 3]) ?? 0xFF00_7AFF
            let calendar = EventCalendar(id: fields[index], title: fields[index + 1], account: fields[index + 2],
                                         color: color, isWritable: fields[index + 4] == "1")
            found.append((calendar, fields[index + 5] == "1"))
            index += calendarCount
        }
        return found
    }

    static func encode(_ event: Event) -> [String] {
        [
            event.id ?? "", event.calendar ?? "", event.title, event.location, event.notes, event.url,
            String(event.start), String(event.end), event.isAllDay ? "1" : "0", event.timeZone ?? "",
            event.recurrence?.rrule ?? "", String(event.occurrence ?? -1), event.isDetached ? "1" : "0",
            EventAlarm.text(event.alarms), String(event.availability.rawValue),
        ]
    }

    /// The events in `fields`; nil when they don't parse.
    static func events(_ fields: [String]) -> [Event]? {
        guard fields.count % eventCount == 0 else { return nil }
        var found: [Event] = []
        var index = 0
        while index < fields.count {
            let field = fields[index..<(index + eventCount)].map { $0 }
            guard let start = Int64(field[6]), let end = Int64(field[7]), let occurrence = Int64(field[11]) else {
                return nil
            }
            var event = Event(title: field[2], start: start, end: end, isAllDay: field[8] == "1")
            event.id = field[0].isEmpty ? nil : field[0]
            event.calendar = field[1].isEmpty ? nil : field[1]
            event.location = field[3]
            event.notes = field[4]
            event.url = field[5]
            event.timeZone = field[9].isEmpty ? nil : field[9]
            event.recurrence = field[10].isEmpty ? nil : RecurrenceRule(rrule: field[10])
            event.occurrence = occurrence < 0 ? nil : occurrence
            event.isDetached = field[12] == "1"
            event.alarms = EventAlarm.alarms(field[13])
            event.availability = Int32(field[14]).flatMap(EventAvailability.init(rawValue:)) ?? .notSupported
            found.append(event)
            index += eventCount
        }
        return found
    }
}

/// The user's calendars on Android (`Plan.md` §6.15): `CalendarContract`,
/// through the Kotlin `CalendarSystem`. A range is the provider's own
/// expansion, `Instances`; one occurrence changed by itself is an
/// exception, `Events.CONTENT_EXCEPTION_URI`; this and the ones after is
/// an `UNTIL` on the series and a new event from there.
public final class AndroidCalendarStore: CalendarStore, @unchecked Sendable {

    let system: any CalendarSystem

    public init(system: any CalendarSystem) {
        self.system = system
    }

    private func check() throws(EventStoreError) {
        let code = system.error()
        guard code == 0 else {
            throw EventStoreError(rawValue: code) ?? .unknown
        }
    }

    private func list() throws(EventStoreError) -> [(calendar: EventCalendar, isPrimary: Bool)] {
        let fields = system.calendars()
        try check()
        guard let calendars = CalendarFields.calendars(fields) else {
            throw .unknown
        }
        return calendars
    }

    private func events(_ fields: [String]) throws(EventStoreError) -> [Event] {
        try check()
        guard let events = CalendarFields.events(fields) else {
            throw .unknown
        }
        return events
    }

    public func calendars() throws(EventStoreError) -> [EventCalendar] {
        try list().map(\.calendar)
    }

    /// The first account's own calendar that can be written, as Android
    /// has no default of its own; else the first that can.
    public func defaultCalendar() throws(EventStoreError) -> EventCalendar? {
        let calendars = try list().filter(\.calendar.isWritable)
        return (calendars.first(where: \.isPrimary) ?? calendars.first)?.calendar
    }

    public func events(from start: Int64, to end: Int64, in calendars: [String]) throws(EventStoreError) -> [Event] {
        // The provider's range takes in what touches it.
        try events(system.instances(start, end: end, calendars: calendars)).filter { $0.overlaps(start, end) }
    }

    public func event(withID identifier: String) throws(EventStoreError) -> Event? {
        try events(system.event(identifier)).first
    }

    private func found(_ identifier: String) throws(EventStoreError) -> Event {
        guard let event = try event(withID: identifier) else {
            throw .notFound
        }
        return event
    }

    private func insert(_ event: Event) throws(EventStoreError) -> Event {
        var new = event
        new.id = nil
        let identifier = system.insert(CalendarFields.encode(new))
        try check()
        return try found(identifier)
    }

    /// The series ends before `occurrence`, and forgets what was changed
    /// from there.
    private func truncate(_ series: Event, before occurrence: Int64) throws(EventStoreError) {
        guard let identifier = series.id else { throw .notFound }
        var series = series
        series.recurrence?.end = .until(occurrence - 1000)
        system.update(identifier, fields: CalendarFields.encode(series))
        try check()
        system.dropExceptions(identifier, occurrence: occurrence)
        try check()
    }

    public func save(_ event: Event, span: EventSpan) throws(EventStoreError) -> Event {
        guard let identifier = event.id else {
            return try insert(event)
        }
        let existing = try found(identifier)
        guard existing.recurrence != nil else {
            system.update(identifier, fields: CalendarFields.encode(event))
            try check()
            return try found(identifier)
        }
        let occurrence = event.occurrence ?? existing.start
        switch span {
        case .thisEvent:
            system.detach(identifier, occurrence: occurrence, fields: CalendarFields.encode(event))
            try check()
            var detached = event
            detached.calendar = existing.calendar
            detached.recurrence = existing.recurrence
            detached.occurrence = occurrence
            detached.isDetached = true
            return detached
        case .futureEvents:
            if occurrence <= existing.start {
                // From the first occurrence on: the whole series, as
                // saved, without what was changed of it.
                system.dropExceptions(identifier, occurrence: .min)
                try check()
                system.update(identifier, fields: CalendarFields.encode(event))
                try check()
                return try found(identifier)
            }
            // A new event from this occurrence, then the old one ends
            // before it: a rule Android refuses changes nothing.
            var started = event
            started.calendar = event.calendar ?? existing.calendar
            started.occurrence = nil
            started.isDetached = false
            let new = try insert(started)
            try truncate(existing, before: occurrence)
            return new
        }
    }

    public func remove(_ event: Event, span: EventSpan) throws(EventStoreError) {
        guard let identifier = event.id else {
            throw .notFound
        }
        let existing = try found(identifier)
        guard existing.recurrence != nil else {
            system.delete(identifier)
            try check()
            return
        }
        let occurrence = event.occurrence ?? existing.start
        switch span {
        case .thisEvent:
            system.cancel(identifier, occurrence: occurrence)
            try check()
        case .futureEvents:
            if occurrence <= existing.start {
                system.delete(identifier)
                try check()
            } else {
                try truncate(existing, before: occurrence)
            }
        }
    }
}

/// The calendar module (`Plan.md` §6.15): AppRuntime's `HostCalendars`
/// over `AndroidCalendarStore`, with access from Android's runtime
/// permissions.
public enum AndroidHostCalendars: HostModule {

    /// `READ_CALENDAR` and `WRITE_CALENDAR`, for either level: Android's
    /// provider reads nothing, not even the calendars to add to, without
    /// `READ_CALENDAR`. `HostCalendars` keeps a write-only app from
    /// reading.
    public static let permissions = [readCalendar, writeCalendar]

    public static let readCalendar = "android.permission.READ_CALENDAR"
    public static let writeCalendar = "android.permission.WRITE_CALENDAR"

    /// Starts the system reporting changes, once access allows it.
    nonisolated(unsafe) static var observe: () -> Void = { }

    nonisolated(unsafe) private static var observing = false

    nonisolated(unsafe) private static var configured = false

    /// Points `HostCalendars` at Android's calendars. `declaredAccess` is
    /// the manifest's `RTCapabilityOptions.calendars.access`. `observe`
    /// starts `ContentObserver` reports. Main thread.
    public static func configure(_ store: AndroidCalendarStore, declaredAccess: EventStoreAccess, observe: @escaping () -> Void) {
        HostCalendars.store = store
        HostCalendars.declaredAccess = declaredAccess
        HostCalendars.deliver = { job in MainLooper.shared.post(job) }
        Self.observe = observe
        observing = false
        configured = true
        HostCalendars.requester = { completion in
            AndroidPermissions.request(permissions) { _ in
                refresh()
                completion(HostCalendars.access)
            }
        }
        refresh()
    }

    /// What the user granted, as Android says now: when the app starts,
    /// after a request, and when it comes back to the front, since the
    /// user may have changed it in Settings. Main thread.
    public static func refresh() {
        guard configured, let system = AndroidPermissions.system else { return }
        let status = AndroidPermissions.status(AndroidPermissions.Requirement(permissions: permissions), system: system)
        HostCalendars.access = access(status)
        if HostCalendars.access == .full, !observing {
            observing = true
            observe()
        }
    }

    /// Both permissions are the store's `full`, which `HostCalendars`
    /// holds to the manifest's level.
    static func access(_ status: PermissionStatus) -> EventStoreAccess {
        switch status {
        case .granted: .full
        case .denied: .denied
        case .restricted: .restricted
        case .unavailable: .unavailable
        default: .notDetermined
        }
    }

    /// The store changed: from the `ContentObserver`. Main thread.
    public static func changed() {
        HostCalendars.storeChanged()
    }

    /// Forgets the configuration, for tests.
    static func reset() {
        configured = false
        observing = false
        observe = { }
    }

    public static var contracts: [ContractDescriptor] {
        HostCalendarsModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostCalendarsModule.register(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        HostCalendarsModule.permissionProviders()
    }
}
