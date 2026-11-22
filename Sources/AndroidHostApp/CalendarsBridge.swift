import AndroidHost
import AndroidHostCalendars
import DynamicCalendar
import SwiftJava

/// The Kotlin `CalendarSystem` (`:appruntime-contracts`). Made on the main
/// thread, where its class can be found; called on the calendar queue,
/// and `observe` on the main thread.
@JavaClass("org.pureswift.appruntime.contracts.CalendarSystem")
open class JavaCalendarSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod open func error() -> Int32
    @JavaMethod open func calendars() -> [String]
    @JavaMethod open func instances(_ begin: Int64, _ end: Int64, _ calendars: [String]) -> [String]
    @JavaMethod open func event(_ identifier: String) -> [String]
    @JavaMethod open func insert(_ fields: [String]) -> String
    @JavaMethod open func update(_ identifier: String, _ fields: [String])
    @JavaMethod open func detach(_ identifier: String, _ occurrence: Int64, _ fields: [String])
    @JavaMethod open func cancel(_ identifier: String, _ occurrence: Int64)
    @JavaMethod open func delete(_ identifier: String)
    @JavaMethod open func dropExceptions(_ identifier: String, _ occurrence: Int64)
    @JavaMethod open func observe()
}

extension JavaCalendarSystem: CalendarSystem {

    public func instances(_ begin: Int64, end: Int64, calendars: [String]) -> [String] {
        instances(begin, end, calendars)
    }

    public func update(_ identifier: String, fields: [String]) {
        update(identifier, fields)
    }

    public func detach(_ identifier: String, occurrence: Int64, fields: [String]) {
        detach(identifier, occurrence, fields)
    }

    public func cancel(_ identifier: String, occurrence: Int64) {
        cancel(identifier, occurrence)
    }

    public func dropExceptions(_ identifier: String, occurrence: Int64) {
        dropExceptions(identifier, occurrence)
    }
}

/// The Kotlin `CalendarNatives` object: the store's changes.
@JavaClass("org.pureswift.appruntime.contracts.CalendarNatives")
open class CalendarNatives: JavaObject {}

@JavaImplementation("org.pureswift.appruntime.contracts.CalendarNatives")
extension CalendarNatives {

    @JavaMethod
    public func changed() {
        AndroidHostCalendars.changed()
    }
}

/// The calendar module's Kotlin side.
enum CalendarsBridge {

    /// `writeOnly`: the manifest's calendars access is `writeOnly`.
    static func configure(writeOnly: Bool) {
        let java = JavaCalendarSystem()
        AndroidHostCalendars.configure(AndroidCalendarStore(system: java), declaredAccess: writeOnly ? .writeOnly : .full) {
            java.observe()
        }
    }
}
