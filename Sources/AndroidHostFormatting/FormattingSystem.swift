import DynamicFormatting

/// What the Formatting contracts ask Android, through the Kotlin
/// `org.pureswift.appruntime.contracts.FormattingSystem` (`AndroidHostApp`
/// binds it): formatters from `android.icu.text`, made for a set of
/// settings and kept by `FormatterCache`. Main thread only.
public protocol FormattingSystem: AnyObject {

    func numberFormatter(_ settings: NumberSettings) -> any NumberFormatting

    func dateFormatter(_ settings: DateSettings) -> any DateFormatting

    /// `RelativeDateTimeFormatter` for `locale` (nil for the user's).
    func relative(_ relative: RelativeTime, locale: String?) -> String

    /// A locale's settings; nil for the user's locale, and nil back if
    /// ICU doesn't know `identifier`.
    func locale(_ identifier: String?) -> LocaleFacts?

    /// Whether ICU knows the IANA time zone.
    func isTimeZone(_ identifier: String) -> Bool

    /// The user's time zone.
    func currentTimeZone() -> String

    /// `zone`'s offset from UTC at `milliseconds`, in seconds; nil for the
    /// user's zone.
    func timeZoneOffset(_ zone: String?, at milliseconds: Int64) -> Int32
}

/// An ICU number formatter.
public protocol NumberFormatting: AnyObject {

    func format(_ value: Double) -> String

    func formatInteger(_ value: Int64) -> String

    /// `nan` unless all of `string` is a number.
    func parse(_ string: String) -> Double
}

/// An ICU date formatter.
public protocol DateFormatting: AnyObject {

    func format(_ milliseconds: Int64) -> String

    /// `Int64.min` unless all of `string` is a date.
    func parse(_ string: String) -> Int64
}

/// Everything that shapes a number formatter.
public struct NumberSettings: Hashable, Sendable {

    /// A BCP 47 identifier; nil for the user's.
    public var locale: String?

    public var style: NumberStyle

    public var minimumFractionDigits: Int32?

    public var maximumFractionDigits: Int32?

    public var usesGrouping: Bool?

    /// ISO 4217; nil for the locale's.
    public var currencyCode: String?

    public init(locale: String?, style: NumberStyle) {
        self.locale = locale
        self.style = style
    }
}

/// Everything that shapes a date formatter.
public struct DateSettings: Hashable, Sendable {

    /// What overrides the styles.
    public enum Pattern: Hashable, Sendable {
        /// A TR35 pattern, used as is.
        case fixed(String)
        /// Skeleton fields, localized by `DateTimePatternGenerator`.
        case template(String)
    }

    public var locale: String?

    /// An IANA identifier ICU knows; nil for the user's.
    public var timeZone: String?

    public var dateStyle: DateStyle = .medium

    public var timeStyle: DateStyle = .medium

    public var pattern: Pattern?

    public init(locale: String?, timeZone: String?) {
        self.locale = locale
        self.timeZone = timeZone
    }
}

/// A time relative to now, as `RelativeDateTimeFormatter` says it.
public struct RelativeTime: Equatable, Sendable {

    /// ICU's `RelativeUnit`, in its order.
    public enum Unit: Int32, Sendable {
        case seconds = 0
        case minutes = 1
        case hours = 2
        case days = 3
        case weeks = 4
        case months = 5
        case years = 6
    }

    /// Nil for "now".
    public var unit: Unit?

    public var quantity: Int64

    public var isFuture: Bool

    public init(unit: Unit?, quantity: Int64, isFuture: Bool) {
        self.unit = unit
        self.quantity = quantity
        self.isFuture = isFuture
    }

    public static let now = RelativeTime(unit: nil, quantity: 0, isFuture: false)
}

/// A locale's settings, from ICU.
public struct LocaleFacts: Equatable, Sendable {

    public var identifier: String

    public var languageCode: String?

    public var regionCode: String?

    public var decimalSeparator: String

    public var groupingSeparator: String

    public var currencyCode: String?

    public var uses24HourClock: Bool

    public init(identifier: String, languageCode: String?, regionCode: String?, decimalSeparator: String,
                groupingSeparator: String, currencyCode: String?, uses24HourClock: Bool) {
        self.identifier = identifier
        self.languageCode = languageCode
        self.regionCode = regionCode
        self.decimalSeparator = decimalSeparator
        self.groupingSeparator = groupingSeparator
        self.currencyCode = currencyCode
        self.uses24HourClock = uses24HourClock
    }
}

extension DateSettings {

    /// ICU's `DateFormat` style for the contract's: `NONE` is -1, then
    /// `FULL` 0 to `SHORT` 3.
    public static func icuStyle(_ style: DateStyle) -> Int32 {
        switch style {
        case .none: -1
        case .short: 3
        case .medium: 2
        case .long: 1
        case .full: 0
        }
    }
}
