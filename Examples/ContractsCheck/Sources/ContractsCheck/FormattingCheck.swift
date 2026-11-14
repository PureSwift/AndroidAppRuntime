import DynamicFormatting
import DynamicRuntime

/// `NumberFormat`, `DateFormat` and `LocaleInfo`, in fixed locales and
/// zones so the results don't depend on the device's settings.
enum FormattingCheck {

    static func run(_ report: Report) {
        let decimal = NumberFormatProxy.make(locale: "en-US", style: NumberStyle.decimal.rawValue)
        report.check(decimal.format(1234.5) == "1,234.5", "number.decimal \(decimal.format(1234.5))")
        report.check(decimal.parse("1,234.5") == 1234.5, "number.parse")
        report.check(decimal.parse("1,234.5 apples").isNaN, "number.parse rejects trailing text")
        let percent = NumberFormatProxy.make(locale: "en-US", style: NumberStyle.percent.rawValue)
        report.check(percent.format(0.25) == "25%", "number.percent \(percent.format(0.25))")
        let currency = NumberFormatProxy.make(locale: "en-US", style: NumberStyle.currency.rawValue)
        report.check(currency.format(1.5) == "$1.50", "number.currency \(currency.format(1.5))")
        currency.setCurrencyCode("EUR")
        report.check(currency.format(1.5) == "€1.50", "number.currency EUR \(currency.format(1.5))")
        let spelled = NumberFormatProxy.make(locale: "en-US", style: NumberStyle.spellOut.rawValue)
        report.check(spelled.formatInteger(42) == "forty-two", "number.spellOut \(spelled.formatInteger(42))")
        let ordinal = NumberFormatProxy.make(locale: "en-US", style: NumberStyle.ordinal.rawValue)
        report.check(ordinal.formatInteger(2) == "2nd", "number.ordinal \(ordinal.formatInteger(2))")
        let grouped = NumberFormatProxy.make(locale: "en-US", style: NumberStyle.decimal.rawValue)
        grouped.setUsesGrouping(false)
        grouped.setMinimumFractionDigits(2)
        report.check(grouped.format(1234) == "1234.00", "number.settings \(grouped.format(1234))")
        let french = NumberFormatProxy.make(locale: "fr-FR", style: NumberStyle.decimal.rawValue)
        report.check(french.format(1.5) == "1,5", "number.fr-FR \(french.format(1.5))")

        let date = DateFormatProxy.make(locale: "en-US", timeZone: "UTC")
        date.setPattern("yyyy-MM-dd HH:mm")
        report.check(date.format(86_400_000) == "1970-01-02 00:00", "date.pattern \(date.format(86_400_000))")
        report.check(date.parse("1970-01-02 00:00") == 86_400_000, "date.parse")
        report.check(date.parse("January") == Int64.min, "date.parse rejects")
        date.setTemplate("yMMMd")
        report.check(date.format(0) == "Jan 1, 1970", "date.template \(date.format(0))")
        date.setPattern(nil)
        date.setDateStyle(DateStyle.short.rawValue)
        date.setTimeStyle(DateStyle.none.rawValue)
        report.check(date.format(0) == "1/1/70", "date.styles \(date.format(0))")
        let ago = date.formatRelative(0, reference: 3 * 3_600_000)
        report.check(ago == "3 hours ago", "date.relative \(ago)")
        let paris = DateFormatProxy.make(locale: "fr-FR", timeZone: "Europe/Paris")
        paris.setPattern("HH:mm")
        report.check(paris.format(0) == "01:00", "date.timeZone \(paris.format(0))")

        let locale = LocaleInfoProxy.current()
        report.check(!locale.identifier().isEmpty, "locale.current \(locale.identifier())")
        report.check(!locale.timeZoneIdentifier().isEmpty, "locale.timeZone \(locale.timeZoneIdentifier())")
        report.check(!LocaleInfoProxy.preferredLanguages().isEmpty, "locale.preferredLanguages \(LocaleInfoProxy.preferredLanguages().joined(separator: " "))")
        if let fr = LocaleInfoProxy.make(identifier: "fr-FR") {
            report.check(fr.decimalSeparator() == "," && fr.currencyCode() == "EUR" && fr.uses24HourClock(),
                         "locale.fr-FR \(fr.decimalSeparator()) \(fr.currencyCode() ?? "-")")
            report.check(fr.regionCode() == "FR" && fr.languageCode() == "fr", "locale.codes")
        } else {
            report.check(false, "locale.fr-FR")
        }
        report.check(LocaleInfoProxy.make(identifier: "zz-ZZ") == nil, "locale.unknown")
    }
}
