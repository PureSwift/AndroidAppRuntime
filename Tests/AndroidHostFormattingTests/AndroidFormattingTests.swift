@testable import AndroidHostFormatting
import DynamicFormatting
import DynamicRuntime
import Testing

/// Formatters that say what they were made with.
final class FakeFormattingSystem: FormattingSystem {

    final class Number: NumberFormatting {
        let settings: NumberSettings
        init(_ settings: NumberSettings) { self.settings = settings }
        func format(_ value: Double) -> String { "\(value) \(settings.style)" }
        func formatInteger(_ value: Int64) -> String { "\(value)" }
        func parse(_ string: String) -> Double { Double(string) ?? .nan }
    }

    final class Date: DateFormatting {
        let settings: DateSettings
        init(_ settings: DateSettings) { self.settings = settings }
        func format(_ milliseconds: Int64) -> String { "\(milliseconds) in \(settings.timeZone ?? "the user's zone")" }
        func parse(_ string: String) -> Int64 { Int64(string) ?? .min }
    }

    var numbersMade = 0

    var datesMade = 0

    var relatives: [(RelativeTime, String?)] = []

    func numberFormatter(_ settings: NumberSettings) -> any NumberFormatting {
        numbersMade += 1
        return Number(settings)
    }

    func dateFormatter(_ settings: DateSettings) -> any DateFormatting {
        datesMade += 1
        return Date(settings)
    }

    func relative(_ relative: RelativeTime, locale: String?) -> String {
        relatives.append((relative, locale))
        return "relative"
    }

    func locale(_ identifier: String?) -> LocaleFacts? {
        switch identifier {
        case nil, "fr-FR":
            LocaleFacts(identifier: identifier ?? "en-US", languageCode: identifier == nil ? "en" : "fr",
                        regionCode: identifier == nil ? "US" : "FR", decimalSeparator: identifier == nil ? "." : ",",
                        groupingSeparator: identifier == nil ? "," : "\u{202F}", currencyCode: identifier == nil ? "USD" : "EUR",
                        uses24HourClock: identifier != nil)
        default:
            nil
        }
    }

    func isTimeZone(_ identifier: String) -> Bool {
        identifier == "Europe/Paris"
    }

    func currentTimeZone() -> String {
        "America/New_York"
    }

    func timeZoneOffset(_ zone: String?, at milliseconds: Int64) -> Int32 {
        -18_000
    }
}

/// Serialized: the system and the caches are shared.
@Suite(.serialized) struct AndroidFormattingTests {

    let system = FakeFormattingSystem()

    init() {
        AndroidHostFormatting.use(system)
    }

    @Test func formatsNumbersWithTheirSettings() {
        let format = AndroidNumberFormat.make(locale: "fr-FR", style: NumberStyle.currency.rawValue)
        format.setMaximumFractionDigits(2)
        format.setMinimumFractionDigits(-3)
        format.setUsesGrouping(false)
        format.setCurrencyCode("EUR")
        var expected = NumberSettings(locale: "fr-FR", style: .currency)
        expected.maximumFractionDigits = 2
        expected.minimumFractionDigits = 0
        expected.usesGrouping = false
        expected.currencyCode = "EUR"
        #expect(format.settings == expected)
        #expect(format.format(1.5) == "1.5 currency")
        #expect(format.parse("x").isNaN)
        #expect(AndroidNumberFormat.make(locale: nil, style: 99).settings.style == .decimal)
    }

    @Test func cachesFormattersBySettings() {
        let first = AndroidNumberFormat.make(locale: nil, style: 0)
        let second = AndroidNumberFormat.make(locale: nil, style: 0)
        _ = first.format(1)
        _ = second.format(2)
        _ = first.formatInteger(3)
        #expect(system.numbersMade == 1)
        second.setUsesGrouping(false)
        _ = second.format(2)
        #expect(system.numbersMade == 2)
        for style in 0..<Int32(FormatterCache.limit + 1) {
            let format = AndroidNumberFormat.make(locale: "\(style)", style: 0)
            _ = format.format(0)
        }
        #expect(FormatterCache.numbers.count <= FormatterCache.limit)
    }

    @Test func formatsDates() {
        let format = AndroidDateFormat.make(locale: "fr-FR", timeZone: "Europe/Paris")
        #expect(format.format(1000) == "1000 in Europe/Paris")
        #expect(format.parse("nope") == .min)
        format.setDateStyle(DateStyle.long.rawValue)
        format.setTimeStyle(DateStyle.none.rawValue)
        format.setTimeStyle(42)
        #expect(format.settings.dateStyle == .long)
        #expect(format.settings.timeStyle == DateStyle.none)
        format.setTemplate("yMMMd")
        #expect(format.settings.pattern == .template("yMMMd"))
        format.setPattern("yyyy")
        #expect(format.settings.pattern == .fixed("yyyy"))
        format.setPattern(nil)
        #expect(format.settings.pattern == nil)
        // An unknown zone becomes the user's.
        #expect(AndroidDateFormat.make(locale: nil, timeZone: "Mars/Olympus").settings.timeZone == nil)
        #expect([DateStyle.none, .short, .medium, .long, .full].map(DateSettings.icuStyle) == [-1, 3, 2, 1, 0])
    }

    @Test func choosesRelativeUnits() {
        func relative(_ seconds: Int64) -> RelativeTime {
            AndroidDateFormat.relative(seconds * 1000, reference: 0)
        }
        #expect(AndroidDateFormat.relative(400, reference: 0) == .now)
        #expect(relative(-45) == RelativeTime(unit: .seconds, quantity: 45, isFuture: false))
        #expect(relative(3 * 3_600 + 59) == RelativeTime(unit: .hours, quantity: 3, isFuture: true))
        #expect(relative(-2 * 86_400) == RelativeTime(unit: .days, quantity: 2, isFuture: false))
        #expect(relative(15 * 86_400) == RelativeTime(unit: .weeks, quantity: 2, isFuture: true))
        #expect(relative(65 * 86_400) == RelativeTime(unit: .months, quantity: 2, isFuture: true))
        #expect(relative(-800 * 86_400) == RelativeTime(unit: .years, quantity: 2, isFuture: false))
        #expect(AndroidDateFormat.relative(.max, reference: .min).unit == .years, "no overflow")
        let format = AndroidDateFormat.make(locale: "fr-FR", timeZone: nil)
        #expect(format.formatRelative(0, reference: 60_000) == "relative")
        #expect(system.relatives.last?.0 == RelativeTime(unit: .minutes, quantity: 1, isFuture: false))
        #expect(system.relatives.last?.1 == "fr-FR")
    }

    @Test func readsLocales() {
        let current = AndroidLocale.current()
        #expect(current.identifier() == "en-US")
        #expect(current.languageCode() == "en")
        #expect(current.regionCode() == "US")
        #expect(current.currencyCode() == "USD")
        #expect(!current.uses24HourClock())
        #expect(current.timeZoneIdentifier() == "America/New_York")
        #expect(current.timeZoneOffset(0) == -18_000)
        let french = AndroidLocale.make(identifier: "fr-FR")
        #expect(french?.decimalSeparator() == ",")
        #expect(french?.uses24HourClock() == true)
        #expect(AndroidLocale.make(identifier: "zz-ZZ") == nil)
    }

    @Test func registersEveryContract() {
        #expect(AndroidHostFormatting.contracts == [LocaleInfoProxy.descriptor, NumberFormatProxy.descriptor, DateFormatProxy.descriptor])
        #expect(AndroidHostFormatting.permissionProviders().isEmpty)
    }
}
