package org.pureswift.appruntime.contracts

import android.icu.text.CompactDecimalFormat
import android.icu.text.DateFormat
import android.icu.text.DateTimePatternGenerator
import android.icu.text.DecimalFormatSymbols
import android.icu.text.NumberFormat
import android.icu.text.RelativeDateTimeFormatter
import android.icu.text.MessageFormat
import android.icu.text.SimpleDateFormat
import android.icu.util.Currency
import android.icu.util.TimeZone
import android.icu.util.ULocale
import java.text.ParsePosition
import java.util.Date

/**
 * The Formatting contracts' Android side (Swift's `AndroidHostFormatting`):
 * `android.icu.text` formatters made for the settings Swift holds. Swift
 * caches them. An empty string stands for nil: swift-java passes no
 * optional strings.
 */
class FormattingSystem {

    /** `style` is a `NumberStyle` raw value; -1 leaves a setting as the style has it. */
    fun numberFormatter(locale: String, style: Int, minimumFraction: Int, maximumFraction: Int,
                        grouping: Int, currency: String): IcuNumberFormat {
        val ulocale = ulocale(locale)
        // Android's ICU has no RuleBasedNumberFormat; MessageFormat's
        // spellout and ordinal arguments use it.
        when (style) {
            4 -> return IcuNumberFormat(null, MessageFormat("{0,spellout}", ulocale))
            5 -> return IcuNumberFormat(null, MessageFormat("{0,ordinal}", ulocale))
        }
        val format: NumberFormat = when (style) {
            1 -> NumberFormat.getInstance(ulocale, NumberFormat.PERCENTSTYLE)
            2 -> NumberFormat.getInstance(ulocale, NumberFormat.CURRENCYSTYLE)
            3 -> NumberFormat.getInstance(ulocale, NumberFormat.SCIENTIFICSTYLE)
            6 -> CompactDecimalFormat.getInstance(ulocale, CompactDecimalFormat.CompactStyle.SHORT)
            else -> NumberFormat.getInstance(ulocale, NumberFormat.NUMBERSTYLE)
        }
        if (currency.isNotEmpty()) {
            runCatching { format.currency = Currency.getInstance(currency) }
        }
        if (minimumFraction >= 0) format.minimumFractionDigits = minimumFraction
        if (maximumFraction >= 0) format.maximumFractionDigits = maximumFraction
        if (grouping >= 0) format.isGroupingUsed = grouping == 1
        return IcuNumberFormat(format, null)
    }

    /**
     * Styles are ICU's (`DateFormat.NONE` is -1); `pattern` is used as is,
     * and `template` is localized first; both empty use the styles.
     */
    fun dateFormatter(locale: String, timeZone: String, dateStyle: Int, timeStyle: Int,
                      pattern: String, template: String): IcuDateFormat {
        val ulocale = ulocale(locale)
        val format: DateFormat? = when {
            pattern.isNotEmpty() -> SimpleDateFormat(pattern, ulocale)
            template.isNotEmpty() -> SimpleDateFormat(DateTimePatternGenerator.getInstance(ulocale).getBestPattern(template), ulocale)
            dateStyle == DateFormat.NONE && timeStyle == DateFormat.NONE -> null
            else -> DateFormat.getDateTimeInstance(dateStyle, timeStyle, ulocale)
        }
        format?.timeZone = if (timeZone.isEmpty()) TimeZone.getDefault() else TimeZone.getTimeZone(timeZone)
        return IcuDateFormat(format)
    }

    /** `unit` is ICU's `RelativeUnit` ordinal, or -1 for now. */
    fun relative(locale: String, unit: Int, quantity: Long, future: Boolean): String {
        val formatter = RelativeDateTimeFormatter.getInstance(ulocale(locale))
        if (unit < 0) {
            return formatter.format(RelativeDateTimeFormatter.Direction.PLAIN, RelativeDateTimeFormatter.AbsoluteUnit.NOW)
        }
        val direction = if (future) RelativeDateTimeFormatter.Direction.NEXT else RelativeDateTimeFormatter.Direction.LAST
        return formatter.format(quantity.toDouble(), direction, RelativeDateTimeFormatter.RelativeUnit.values()[unit])
    }

    /**
     * Identifier, language, region, decimal and grouping separators,
     * currency, and "1" for a 24-hour clock; empty if ICU doesn't know the
     * locale. An empty `identifier` is the user's.
     */
    fun locale(identifier: String): Array<String> {
        val locale = if (identifier.isEmpty()) ULocale.getDefault() else ULocale.forLanguageTag(identifier)
        if (identifier.isNotEmpty() && (locale.language.isEmpty() || !isKnown(locale))) {
            return emptyArray()
        }
        val symbols = DecimalFormatSymbols.getInstance(locale)
        val currency = if (locale.country.isEmpty()) "" else runCatching { Currency.getInstance(locale).currencyCode }.getOrNull() ?: ""
        val time = DateFormat.getTimeInstance(DateFormat.SHORT, locale) as? SimpleDateFormat
        val hours24 = time?.toPattern()?.let { 'H' in it || 'k' in it } ?: false
        return arrayOf(
            locale.toLanguageTag(), locale.language, locale.country,
            symbols.decimalSeparator.toString(), symbols.groupingSeparator.toString(),
            currency, if (hours24) "1" else "0",
        )
    }

    private fun isKnown(locale: ULocale): Boolean =
        ULocale.getAvailableLocales().any { it.language == locale.language }

    fun isTimeZone(identifier: String): Boolean = TimeZone.getCanonicalID(identifier) != null

    fun currentTimeZone(): String = TimeZone.getDefault().id

    /** Seconds from UTC; an empty zone is the user's. */
    fun timeZoneOffset(zone: String, milliseconds: Long): Int {
        val timeZone = if (zone.isEmpty()) TimeZone.getDefault() else TimeZone.getTimeZone(zone)
        return timeZone.getOffset(milliseconds) / 1000
    }

    private fun ulocale(identifier: String): ULocale =
        if (identifier.isEmpty()) ULocale.getDefault() else ULocale.forLanguageTag(identifier)
}

/** One number formatter: a `NumberFormat`, or a `MessageFormat` that spells numbers out. */
class IcuNumberFormat(private val format: NumberFormat?, private val message: MessageFormat?) {

    fun format(value: Double): String = format?.format(value) ?: message?.format(arrayOf<Any>(value)) ?: ""

    fun formatInteger(value: Long): String = format?.format(value) ?: message?.format(arrayOf<Any>(value)) ?: ""

    /** NaN unless all of `string` is a number. */
    fun parse(string: String): Double {
        val position = ParsePosition(0)
        val number = when {
            format != null -> format.parse(string, position)
            message != null -> message.parse(string, position)?.firstOrNull() as? Number
            else -> null
        } ?: return Double.NaN
        return if (position.index == string.length) number.toDouble() else Double.NaN
    }
}

/** One date formatter; without one (both styles none), dates format as "". */
class IcuDateFormat(private val format: DateFormat?) {

    fun format(milliseconds: Long): String = format?.format(Date(milliseconds)) ?: ""

    /** `Long.MIN_VALUE` unless all of `string` is a date. */
    fun parse(string: String): Long {
        val format = format ?: return Long.MIN_VALUE
        val position = ParsePosition(0)
        val date = format.parse(string, position) ?: return Long.MIN_VALUE
        return if (position.index == string.length) date.time else Long.MIN_VALUE
    }
}
