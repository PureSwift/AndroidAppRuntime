import AndroidHostFormatting
import SwiftJava

/// The Kotlin `FormattingSystem` (`:appruntime-contracts`). Empty strings
/// stand for nil, and -1 for an unset number.
@JavaClass("org.pureswift.appruntime.contracts.FormattingSystem")
open class JavaFormattingSystem: JavaObject {

    @JavaMethod
    @_nonoverride public convenience init(environment: JNIEnvironment? = nil)

    @JavaMethod
    open func numberFormatter(_ locale: String, _ style: Int32, _ minimumFraction: Int32, _ maximumFraction: Int32,
                              _ grouping: Int32, _ currency: String) -> JavaNumberFormat!

    @JavaMethod
    open func dateFormatter(_ locale: String, _ timeZone: String, _ dateStyle: Int32, _ timeStyle: Int32,
                            _ pattern: String, _ template: String) -> JavaDateFormat!

    @JavaMethod open func relative(_ locale: String, _ unit: Int32, _ quantity: Int64, _ future: Bool) -> String
    @JavaMethod open func locale(_ identifier: String) -> [String]
    @JavaMethod open func isTimeZone(_ identifier: String) -> Bool
    @JavaMethod open func currentTimeZone() -> String
    @JavaMethod open func timeZoneOffset(_ zone: String, _ milliseconds: Int64) -> Int32
}

@JavaClass("org.pureswift.appruntime.contracts.IcuNumberFormat")
open class JavaNumberFormat: JavaObject {
    @JavaMethod open func format(_ value: Double) -> String
    @JavaMethod open func formatInteger(_ value: Int64) -> String
    @JavaMethod open func parse(_ string: String) -> Double
}

@JavaClass("org.pureswift.appruntime.contracts.IcuDateFormat")
open class JavaDateFormat: JavaObject {
    @JavaMethod open func format(_ milliseconds: Int64) -> String
    @JavaMethod open func parse(_ string: String) -> Int64
}

extension JavaNumberFormat: NumberFormatting {}

extension JavaDateFormat: DateFormatting {}

/// `AndroidHostFormatting`'s system over the Kotlin class.
final class AndroidFormattingSystem: FormattingSystem {

    let java = JavaFormattingSystem()

    func numberFormatter(_ settings: NumberSettings) -> any NumberFormatting {
        let grouping: Int32 = settings.usesGrouping.map { $0 ? 1 : 0 } ?? -1
        return java.numberFormatter(settings.locale ?? "", settings.style.rawValue,
                                    settings.minimumFractionDigits ?? -1, settings.maximumFractionDigits ?? -1,
                                    grouping, settings.currencyCode ?? "")
    }

    func dateFormatter(_ settings: DateSettings) -> any DateFormatting {
        var pattern = "", template = ""
        switch settings.pattern {
        case .fixed(let fixed): pattern = fixed
        case .template(let fields): template = fields
        case nil: break
        }
        return java.dateFormatter(settings.locale ?? "", settings.timeZone ?? "",
                                  DateSettings.icuStyle(settings.dateStyle), DateSettings.icuStyle(settings.timeStyle),
                                  pattern, template)
    }

    func relative(_ relative: RelativeTime, locale: String?) -> String {
        java.relative(locale ?? "", relative.unit?.rawValue ?? -1, relative.quantity, relative.isFuture)
    }

    func locale(_ identifier: String?) -> LocaleFacts? {
        let values = java.locale(identifier ?? "")
        guard values.count == 7 else { return nil }
        func optional(_ value: String) -> String? { value.isEmpty ? nil : value }
        return LocaleFacts(identifier: values[0], languageCode: optional(values[1]), regionCode: optional(values[2]),
                           decimalSeparator: values[3], groupingSeparator: values[4],
                           currencyCode: optional(values[5]), uses24HourClock: values[6] == "1")
    }

    func isTimeZone(_ identifier: String) -> Bool {
        java.isTimeZone(identifier)
    }

    func currentTimeZone() -> String {
        java.currentTimeZone()
    }

    func timeZoneOffset(_ zone: String?, at milliseconds: Int64) -> Int32 {
        java.timeZoneOffset(zone ?? "", milliseconds)
    }
}
