import AndroidHost
import DynamicFormatting
import DynamicRuntime

/// The `DynamicFormatting` contracts over `android.icu.text` (`Plan.md`
/// §6.2). ICU ships in Android, so the APK carries no ICU data. The
/// contracts need no capability, so this module has no permission
/// providers.
public enum AndroidHostFormatting: HostModule {

    /// Makes the system on first use; `AndroidHostApp` sets it.
    nonisolated(unsafe) public static var makeSystem: (() -> any FormattingSystem)?

    nonisolated(unsafe) private static var _system: (any FormattingSystem)?

    static var system: any FormattingSystem {
        if let _system {
            return _system
        }
        guard let makeSystem else {
            fatalError("AndroidHostFormatting.makeSystem isn't set")
        }
        let system = makeSystem()
        _system = system
        return system
    }

    /// Replaces the system and empties the caches, for tests.
    public static func use(_ system: (any FormattingSystem)?) {
        _system = system
        FormatterCache.numbers.removeAll()
        FormatterCache.dates.removeAll()
    }

    public static var contracts: [ContractDescriptor] {
        [LocaleInfoProxy.descriptor, NumberFormatProxy.descriptor, DateFormatProxy.descriptor]
    }

    public static func register(in registrar: some ContractRegistrar) {
        LocaleInfoProxy.register(AndroidLocale.self, in: registrar)
        NumberFormatProxy.register(AndroidNumberFormat.self, in: registrar)
        DateFormatProxy.register(AndroidDateFormat.self, in: registrar)
    }
}

/// The ICU formatters made so far, by settings: making one is slow, and
/// guests often make the same one again. Bounded: a full cache starts
/// over.
enum FormatterCache {

    static let limit = 32

    nonisolated(unsafe) static var numbers: [NumberSettings: any NumberFormatting] = [:]

    nonisolated(unsafe) static var dates: [DateSettings: any DateFormatting] = [:]

    static func number(_ settings: NumberSettings) -> any NumberFormatting {
        if let formatter = numbers[settings] {
            return formatter
        }
        if numbers.count >= limit {
            numbers.removeAll()
        }
        let formatter = AndroidHostFormatting.system.numberFormatter(settings)
        numbers[settings] = formatter
        return formatter
    }

    static func date(_ settings: DateSettings) -> any DateFormatting {
        if let formatter = dates[settings] {
            return formatter
        }
        if dates.count >= limit {
            dates.removeAll()
        }
        let formatter = AndroidHostFormatting.system.dateFormatter(settings)
        dates[settings] = formatter
        return formatter
    }
}

/// The `NumberFormat` contract. Each object holds its settings; the ICU
/// formatter for them comes from `FormatterCache`.
public final class AndroidNumberFormat: NumberFormat {

    private(set) var settings: NumberSettings

    init(_ settings: NumberSettings) {
        self.settings = settings
    }

    /// An unknown style is logged and formats as decimal.
    public static func make(locale: String?, style: Int32) -> AndroidNumberFormat {
        var numberStyle = NumberStyle.decimal
        if let known = NumberStyle(rawValue: style) {
            numberStyle = known
        } else {
            HostLog.error("NumberFormat.make: unknown style \(style); using decimal")
        }
        return AndroidNumberFormat(NumberSettings(locale: locale, style: numberStyle))
    }

    public func setMinimumFractionDigits(_ digits: Int32) {
        settings.minimumFractionDigits = max(0, digits)
    }

    public func setMaximumFractionDigits(_ digits: Int32) {
        settings.maximumFractionDigits = max(0, digits)
    }

    public func setUsesGrouping(_ grouping: Bool) {
        settings.usesGrouping = grouping
    }

    public func setCurrencyCode(_ code: String?) {
        settings.currencyCode = code
    }

    var formatter: any NumberFormatting {
        FormatterCache.number(settings)
    }

    public func format(_ value: Double) -> String {
        formatter.format(value)
    }

    public func formatInteger(_ value: Int64) -> String {
        formatter.formatInteger(value)
    }

    public func parse(_ string: String) -> Double {
        formatter.parse(string)
    }
}

/// The `DateFormat` contract. A new object uses the medium date and time
/// styles, like `DateFormat.getDateTimeInstance()`.
public final class AndroidDateFormat: DateFormat {

    private(set) var settings: DateSettings

    init(_ settings: DateSettings) {
        self.settings = settings
    }

    /// An unknown `timeZone` is logged and replaced by the user's.
    public static func make(locale: String?, timeZone: String?) -> AndroidDateFormat {
        var zone = timeZone
        if let timeZone, !AndroidHostFormatting.system.isTimeZone(timeZone) {
            HostLog.error("DateFormat.make: unknown time zone \(timeZone); using the user's")
            zone = nil
        }
        return AndroidDateFormat(DateSettings(locale: locale, timeZone: zone))
    }

    public func setDateStyle(_ style: Int32) {
        guard let style = Self.style(style, method: "setDateStyle") else { return }
        settings.dateStyle = style
    }

    public func setTimeStyle(_ style: Int32) {
        guard let style = Self.style(style, method: "setTimeStyle") else { return }
        settings.timeStyle = style
    }

    public func setPattern(_ pattern: String?) {
        settings.pattern = pattern.map(DateSettings.Pattern.fixed)
    }

    public func setTemplate(_ template: String) {
        settings.pattern = .template(template)
    }

    static func style(_ raw: Int32, method: String) -> DateStyle? {
        guard let style = DateStyle(rawValue: raw) else {
            HostLog.error("DateFormat.\(method): unknown style \(raw)")
            return nil
        }
        return style
    }

    var formatter: any DateFormatting {
        FormatterCache.date(settings)
    }

    public func format(_ milliseconds: Int64) -> String {
        formatter.format(milliseconds)
    }

    public func parse(_ string: String) -> Int64 {
        formatter.parse(string)
    }

    public func formatRelative(_ milliseconds: Int64, reference: Int64) -> String {
        AndroidHostFormatting.system.relative(Self.relative(milliseconds, reference: reference), locale: settings.locale)
    }

    /// The largest unit the interval has one of, as iOS's
    /// `RelativeDateTimeFormatter` chooses: under a second is now, and
    /// quantities are rounded down.
    static func relative(_ milliseconds: Int64, reference: Int64) -> RelativeTime {
        let (difference, overflow) = milliseconds.subtractingReportingOverflow(reference)
        let delta = overflow ? (milliseconds > reference ? Int64.max : Int64.min) : difference
        let seconds = delta.magnitude / 1000
        guard seconds > 0 else {
            return .now
        }
        let units: [(RelativeTime.Unit, UInt64)] = [
            (.years, 365 * 86_400), (.months, 30 * 86_400), (.weeks, 7 * 86_400),
            (.days, 86_400), (.hours, 3_600), (.minutes, 60), (.seconds, 1),
        ]
        let (unit, length) = units.first { seconds >= $0.1 } ?? (.seconds, 1)
        return RelativeTime(unit: unit, quantity: Int64(clamping: seconds / length), isFuture: delta > 0)
    }
}

/// The `LocaleInfo` contract over ICU's locale data.
public final class AndroidLocale: LocaleInfo {

    /// Nil for the user's locale, read each time so it follows the
    /// settings.
    let localeIdentifier: String?

    init(_ identifier: String?) {
        self.localeIdentifier = identifier
    }

    public static func current() -> AndroidLocale {
        AndroidLocale(nil)
    }

    public static func make(identifier: String) -> AndroidLocale? {
        guard AndroidHostFormatting.system.locale(identifier) != nil else {
            return nil
        }
        return AndroidLocale(identifier)
    }

    /// The user's languages, as the `Bundle` built-in has them.
    public static func preferredLanguages() -> [String] {
        AndroidBundle.languages
    }

    var facts: LocaleFacts {
        AndroidHostFormatting.system.locale(localeIdentifier)
            ?? LocaleFacts(identifier: "und", languageCode: nil, regionCode: nil, decimalSeparator: ".",
                           groupingSeparator: ",", currencyCode: nil, uses24HourClock: true)
    }

    public func identifier() -> String {
        facts.identifier
    }

    public func languageCode() -> String? {
        facts.languageCode
    }

    public func regionCode() -> String? {
        facts.regionCode
    }

    public func decimalSeparator() -> String {
        facts.decimalSeparator
    }

    public func groupingSeparator() -> String {
        facts.groupingSeparator
    }

    public func currencyCode() -> String? {
        facts.currencyCode
    }

    public func uses24HourClock() -> Bool {
        facts.uses24HourClock
    }

    public func timeZoneIdentifier() -> String {
        AndroidHostFormatting.system.currentTimeZone()
    }

    public func timeZoneOffset(_ milliseconds: Int64) -> Int32 {
        AndroidHostFormatting.system.timeZoneOffset(nil, at: milliseconds)
    }
}
