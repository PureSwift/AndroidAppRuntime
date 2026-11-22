package org.pureswift.appruntime.contracts

import android.content.ContentResolver
import android.content.ContentUris
import android.content.ContentValues
import android.database.ContentObserver
import android.database.Cursor
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.provider.CalendarContract
import android.provider.CalendarContract.Calendars
import android.provider.CalendarContract.Events
import android.provider.CalendarContract.Instances
import android.provider.CalendarContract.Reminders
import java.util.TimeZone
import java.util.UUID

/**
 * The user's calendars for Swift's `AndroidCalendarStore`
 * (Documentation/Plan.md §6.15), through `CalendarContract`: a calendar is
 * a row of `Calendars`, an event a row of `Events`, and what happens in a
 * range the provider's own expansion, `Instances`.
 *
 * A calendar crosses to Swift as six strings: the identifier, the title,
 * the account (empty for one on the device alone), the colour as a
 * decimal `0xAARRGGBB`, and whether it can be written and is the account's
 * own, as "1" or "0". An event crosses as fifteen: the identifier, the
 * calendar, the title, the location, the notes, the URL, the start and the
 * end in milliseconds, all day, the time zone, the `RRULE`, the
 * occurrence (-1 for none), detached, the alarms as minutes with commas
 * between, and the availability. An occurrence changed by itself is the
 * row of an exception; it crosses as its series' identifier, with the
 * occurrence it replaces.
 *
 * Called on Swift's calendar queue, one call at a time. Each call returns
 * its value, or an empty one, and leaves an `EventStoreError` raw value
 * for [error] on the same thread: 0 when it succeeded, so `unknown`, whose
 * raw value is 0, is sent as -1. Made on the main thread, where [observe]
 * reports changes.
 *
 * Android's provider expands a series and its exceptions together only
 * when the series has a sync identifier; without one, saving an exception
 * loses the series' other occurrences. A calendar on the device alone has
 * no sync adapter to give one, so before a series there gets its first
 * exception, this is its sync adapter and gives it one.
 */
class CalendarSystem {

    private val resolver: ContentResolver get() = HostContext.application.contentResolver

    fun error(): Int = lastError.get() ?: 0

    // MARK: Reading

    /** Every calendar, in the provider's order. */
    fun calendars(): Array<String> = call {
        val found = ArrayList<String>()
        resolver.query(Calendars.CONTENT_URI, CALENDAR, null, null, Calendars._ID)?.use { row ->
            while (row.moveToNext()) {
                val local = row.getString(3) == CalendarContract.ACCOUNT_TYPE_LOCAL
                found += listOf(
                    row.getLong(0).toString(),
                    row.getString(1) ?: "",
                    if (local) "" else row.getString(2) ?: "",
                    (row.getInt(4).toLong() and 0xFFFFFFFFL).toString(),
                    if (row.getInt(5) >= Calendars.CAL_ACCESS_CONTRIBUTOR) "1" else "0",
                    if (row.getInt(6) != 0) "1" else "0",
                )
            }
        }
        found.toTypedArray()
    } ?: emptyArray()

    /**
     * The occurrences the provider has from `begin` to `end`, in the
     * calendars named; none named is all. Cancelled ones are left out.
     */
    fun instances(begin: Long, end: Long, calendars: Array<String>): Array<String> = call {
        val uri = Instances.CONTENT_URI.buildUpon().let {
            ContentUris.appendId(it, begin)
            ContentUris.appendId(it, end)
            it.build()
        }
        var where = "(${Instances.STATUS} IS NULL OR ${Instances.STATUS} != ${Events.STATUS_CANCELED})"
        val ids = calendars.mapNotNull { it.toLongOrNull() }
        if (calendars.isNotEmpty()) {
            if (ids.isEmpty()) return@call emptyArray()
            where += " AND ${Instances.CALENDAR_ID} IN (${ids.joinToString(",")})"
        }
        val rows = ArrayList<Row>()
        resolver.query(uri, INSTANCE, where, null, null)?.use { row ->
            while (row.moveToNext()) {
                val original = if (row.isNull(9)) -1L else row.getLong(9)
                rows += Row(
                    event = row.getLong(0), calendar = row.getLong(11), title = row.getString(3) ?: "",
                    location = row.getString(4) ?: "", notes = row.getString(5) ?: "",
                    start = row.getLong(1), end = row.getLong(2), allDay = row.getInt(6) != 0,
                    timeZone = row.getString(7) ?: "", rule = row.getString(8) ?: "",
                    original = original, originalTime = if (row.isNull(10)) -1L else row.getLong(10),
                    availability = row.getInt(12),
                )
            }
        }
        // An exception's rule is its series'.
        val series = rows.filter { it.original >= 0 }.map { it.original }.distinct()
        val rules = HashMap<Long, String>()
        for (chunk in series.chunked(500)) {
            resolver.query(Events.CONTENT_URI, arrayOf(Events._ID, Events.RRULE), "${Events._ID} IN (${chunk.joinToString(",")})", null, null)
                ?.use { row -> while (row.moveToNext()) rules[row.getLong(0)] = row.getString(1) ?: "" }
        }
        val alarms = alarms(rows.map { it.event }.distinct())
        rows.flatMap { it.fields(rules, alarms) }.toTypedArray()
    } ?: emptyArray()

    /** One event, as its row has it; empty when it's gone. */
    fun event(identifier: String): Array<String> = call {
        val id = identifier.toLongOrNull() ?: return@call emptyArray()
        find(id)?.fields(emptyMap(), alarms(listOf(id)))?.toTypedArray() ?: emptyArray()
    } ?: emptyArray()

    private fun find(id: Long): Row? =
        resolver.query(Events.CONTENT_URI, EVENT, "${Events._ID} = ? AND ${Events.DELETED} = 0", arrayOf(id.toString()), null)?.use { row ->
            if (!row.moveToFirst()) return@use null
            val start = row.getLong(6)
            val end = if (!row.isNull(7)) row.getLong(7) else start + Durations.milliseconds(row.getString(8) ?: "")
            Row(
                event = id, calendar = row.getLong(1), title = row.getString(2) ?: "", location = row.getString(3) ?: "",
                notes = row.getString(4) ?: "", start = start, end = end, allDay = row.getInt(9) != 0,
                timeZone = row.getString(10) ?: "", rule = row.getString(11) ?: "",
                original = if (row.isNull(12)) -1L else row.getLong(12), originalTime = if (row.isNull(13)) -1L else row.getLong(13),
                availability = row.getInt(5),
                syncID = row.getString(14), account = row.getString(15) ?: "", accountType = row.getString(16) ?: "",
            )
        }

    /** Each event's alarms, as minutes before. */
    private fun alarms(events: List<Long>): Map<Long, List<Int>> {
        val found = HashMap<Long, MutableList<Int>>()
        for (chunk in events.chunked(500)) {
            resolver.query(Reminders.CONTENT_URI, arrayOf(Reminders.EVENT_ID, Reminders.MINUTES),
                "${Reminders.EVENT_ID} IN (${chunk.joinToString(",")})", null, "${Reminders.MINUTES}, ${Reminders._ID}")?.use { row ->
                while (row.moveToNext()) {
                    // -1 is the calendar's own default; there's no telling it here.
                    val minutes = row.getInt(1)
                    if (minutes >= 0) found.getOrPut(row.getLong(0)) { ArrayList() } += minutes
                }
            }
        }
        return found
    }

    /** One row of `Events` or `Instances`. */
    private class Row(
        val event: Long, val calendar: Long, val title: String, val location: String, val notes: String,
        val start: Long, val end: Long, val allDay: Boolean, val timeZone: String, val rule: String,
        val original: Long, val originalTime: Long, val availability: Int,
        val syncID: String? = null, val account: String = "", val accountType: String = "",
    ) {
        fun fields(rules: Map<Long, String>, alarms: Map<Long, List<Int>>): List<String> {
            val detached = original >= 0
            val rule = if (detached) rules[original] ?: "" else rule
            val occurrence = if (detached) originalTime else if (rule.isNotEmpty()) start else -1L
            return listOf(
                (if (detached) original else event).toString(), calendar.toString(), title, location, notes, "",
                start.toString(), end.toString(), if (allDay) "1" else "0",
                // An all-day event is on its days in every zone.
                if (allDay) "" else timeZone, rule, occurrence.toString(), if (detached) "1" else "0",
                (alarms[event] ?: emptyList()).joinToString(","), availability.toString(),
            )
        }
    }

    // MARK: Writing

    /** Adds an event; gives its identifier. */
    fun insert(fields: Array<String>): String = call {
        val values = Fields(fields).values(whole = true)
        val uri = resolver.insert(Events.CONTENT_URI, values) ?: throw Failure(UNKNOWN)
        val id = ContentUris.parseId(uri)
        setAlarms(id, Fields(fields).alarms)
        id.toString()
    } ?: ""

    /** Changes an event, a whole series if it repeats. */
    fun update(identifier: String, fields: Array<String>) {
        call {
            val id = existing(identifier).event
            write(Events.CONTENT_URI, id, Fields(fields).values(whole = true))
            setAlarms(id, Fields(fields).alarms)
        }
    }

    /** Changes one occurrence of a series by itself: its exception. */
    fun detach(identifier: String, occurrence: Long, fields: Array<String>) {
        call {
            val series = existing(identifier)
            val values = Fields(fields).values(whole = false)
            val id = exception(series, occurrence, values)
            setAlarms(id, Fields(fields).alarms)
        }
    }

    /** Cancels one occurrence of a series. */
    fun cancel(identifier: String, occurrence: Long) {
        call {
            val series = existing(identifier)
            exception(series, occurrence, ContentValues().apply { put(Events.STATUS, Events.STATUS_CANCELED) })
        }
    }

    /** Deletes an event, and a series' exceptions. */
    fun delete(identifier: String) {
        call {
            val id = existing(identifier).event
            resolver.delete(Events.CONTENT_URI, "${Events.ORIGINAL_ID} = ?", arrayOf(id.toString()))
            resolver.delete(ContentUris.withAppendedId(Events.CONTENT_URI, id), null, null)
        }
    }

    /** Deletes a series' exceptions for its occurrences from `occurrence` on. */
    fun dropExceptions(identifier: String, occurrence: Long) {
        call {
            val id = existing(identifier).event
            resolver.delete(Events.CONTENT_URI, "${Events.ORIGINAL_ID} = ? AND ${Events.ORIGINAL_INSTANCE_TIME} >= ?",
                arrayOf(id.toString(), occurrence.toString()))
        }
    }

    private fun existing(identifier: String): Row =
        identifier.toLongOrNull()?.let { find(it) } ?: throw Failure(NOT_FOUND)

    /** The exception for an occurrence, changed or made; gives its row. */
    private fun exception(series: Row, occurrence: Long, values: ContentValues): Long {
        val existing = resolver.query(Events.CONTENT_URI, arrayOf(Events._ID),
            "${Events.ORIGINAL_ID} = ? AND ${Events.ORIGINAL_INSTANCE_TIME} = ? AND ${Events.DELETED} = 0",
            arrayOf(series.event.toString(), occurrence.toString()), null)?.use { if (it.moveToFirst()) it.getLong(0) else null }
        if (existing != null) {
            // Naming the series and the start has the provider expand the
            // series again, cancelled occurrences and all.
            values.put(Events.ORIGINAL_ID, series.event)
            values.put(Events.ORIGINAL_INSTANCE_TIME, occurrence)
            if (!values.containsKey(Events.DTSTART)) values.put(Events.DTSTART, occurrence)
            if (values.containsKey(Events.DURATION)) {
                values.put(Events.DTEND, values.getAsLong(Events.DTSTART) + Durations.milliseconds(values.getAsString(Events.DURATION)))
                values.remove(Events.DURATION)
            }
            write(Events.CONTENT_URI, existing, values)
            return existing
        }
        if (series.syncID == null && series.accountType == CalendarContract.ACCOUNT_TYPE_LOCAL) {
            // The calendar's sync adapter, as no one else is.
            val uri = ContentUris.withAppendedId(Events.CONTENT_URI, series.event).buildUpon()
                .appendQueryParameter(CalendarContract.CALLER_IS_SYNCADAPTER, "true")
                .appendQueryParameter(Calendars.ACCOUNT_NAME, series.account)
                .appendQueryParameter(Calendars.ACCOUNT_TYPE, series.accountType)
                .build()
            resolver.update(uri, ContentValues().apply { put(Events._SYNC_ID, "appruntime-" + UUID.randomUUID()) }, null, null)
        }
        values.put(Events.ORIGINAL_INSTANCE_TIME, occurrence)
        val uri = resolver.insert(ContentUris.withAppendedId(Events.CONTENT_EXCEPTION_URI, series.event), values)
            ?: throw Failure(UNKNOWN)
        return ContentUris.parseId(uri)
    }

    private fun write(content: Uri, id: Long, values: ContentValues) {
        if (resolver.update(ContentUris.withAppendedId(content, id), values, null, null) == 0) throw Failure(NOT_FOUND)
    }

    /** An event's alarms, as the guest has them now. */
    private fun setAlarms(event: Long, minutes: List<Int>) {
        resolver.delete(Reminders.CONTENT_URI, "${Reminders.EVENT_ID} = ?", arrayOf(event.toString()))
        for (minute in minutes) {
            resolver.insert(Reminders.CONTENT_URI, ContentValues().apply {
                put(Reminders.EVENT_ID, event)
                put(Reminders.MINUTES, minute)
                put(Reminders.METHOD, Reminders.METHOD_ALERT)
            })
        }
    }

    /** An event's fields, as Swift sends them. */
    private class Fields(fields: Array<String>) {
        val calendar = fields[1]
        val title = fields[2]
        val location = fields[3]
        val notes = fields[4]
        val start = fields[6].toLongOrNull() ?: throw Failure(UNKNOWN)
        val end = fields[7].toLongOrNull() ?: throw Failure(UNKNOWN)
        val allDay = fields[8] == "1"
        val timeZone = fields[9]
        val rule = fields[10]
        val alarms = fields[13].split(",").mapNotNull { it.toIntOrNull() }.filter { it >= 0 }
        val availability = fields[14].toIntOrNull() ?: -1

        /**
         * The columns a save writes. A series' (`whole`) has its rule, and
         * its length as a `DURATION`; an exception's has neither, as the
         * provider takes them from its series. The times are always written,
         * since the provider expands a series again only when it's told its
         * start.
         */
        fun values(whole: Boolean): ContentValues = ContentValues().apply {
            if (whole && calendar.isNotEmpty()) {
                put(Events.CALENDAR_ID, calendar.toLongOrNull() ?: throw Failure(NOT_FOUND))
            }
            put(Events.TITLE, title)
            put(Events.EVENT_LOCATION, location)
            put(Events.DESCRIPTION, notes)
            put(Events.DTSTART, start)
            put(Events.ALL_DAY, if (allDay) 1 else 0)
            put(Events.EVENT_TIMEZONE, if (allDay) "UTC" else timeZone.ifEmpty { TimeZone.getDefault().id })
            when {
                whole && rule.isNotEmpty() -> {
                    put(Events.RRULE, rule)
                    put(Events.DURATION, Durations.text(end - start, allDay))
                    putNull(Events.DTEND)
                }
                whole -> {
                    putNull(Events.RRULE)
                    putNull(Events.DURATION)
                    put(Events.DTEND, end)
                }
                else -> put(Events.DURATION, Durations.text(end - start, allDay))
            }
            // Android has no "out of office"; it's busy.
            when (availability) {
                0, 3 -> put(Events.AVAILABILITY, Events.AVAILABILITY_BUSY)
                1 -> put(Events.AVAILABILITY, Events.AVAILABILITY_FREE)
                2 -> put(Events.AVAILABILITY, Events.AVAILABILITY_TENTATIVE)
            }
        }
    }

    // MARK: Changes

    /** Starts reporting changes to the store. Main thread. */
    fun observe() {
        if (observer != null) return
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                CalendarNatives.changed()
            }
        }
        try {
            resolver.registerContentObserver(CalendarContract.CONTENT_URI, true, observer)
            CalendarSystem.observer = observer
        } catch (error: SecurityException) {
        }
    }

    // MARK: Errors

    private class Failure(val code: Int) : Exception()

    /** Runs a call, keeping its error for [error]. */
    private inline fun <T> call(body: () -> T): T? {
        lastError.set(0)
        return try {
            body()
        } catch (failure: Failure) {
            lastError.set(failure.code)
            null
        } catch (error: SecurityException) {
            lastError.set(NOT_AUTHORIZED)
            null
        } catch (error: IllegalArgumentException) {
            // What the provider can't take: most often a rule.
            lastError.set(UNSUPPORTED_RECURRENCE)
            null
        } catch (error: IllegalStateException) {
            lastError.set(UNKNOWN)
            null
        }
    }

    companion object {
        // EventStoreError raw values; `unknown` as -1, since 0 is no error.
        private const val UNKNOWN = -1
        private const val NOT_AUTHORIZED = 2
        private const val NOT_FOUND = 4
        private const val UNSUPPORTED_RECURRENCE = 9

        private val lastError = ThreadLocal<Int>()

        private var observer: ContentObserver? = null

        private val CALENDAR = arrayOf(
            Calendars._ID, Calendars.CALENDAR_DISPLAY_NAME, Calendars.ACCOUNT_NAME, Calendars.ACCOUNT_TYPE,
            Calendars.CALENDAR_COLOR, Calendars.CALENDAR_ACCESS_LEVEL, Calendars.IS_PRIMARY,
        )

        private val INSTANCE = arrayOf(
            Instances.EVENT_ID, Instances.BEGIN, Instances.END, Instances.TITLE, Instances.EVENT_LOCATION,
            Instances.DESCRIPTION, Instances.ALL_DAY, Instances.EVENT_TIMEZONE, Instances.RRULE, Instances.ORIGINAL_ID,
            Instances.ORIGINAL_INSTANCE_TIME, Instances.CALENDAR_ID, Instances.AVAILABILITY,
        )

        private val EVENT = arrayOf(
            Events._ID, Events.CALENDAR_ID, Events.TITLE, Events.EVENT_LOCATION, Events.DESCRIPTION, Events.AVAILABILITY,
            Events.DTSTART, Events.DTEND, Events.DURATION, Events.ALL_DAY, Events.EVENT_TIMEZONE, Events.RRULE,
            Events.ORIGINAL_ID, Events.ORIGINAL_INSTANCE_TIME, Events._SYNC_ID, Events.ACCOUNT_NAME, Events.ACCOUNT_TYPE,
        )
    }
}

/** RFC 5545 durations, as `Events.DURATION` keeps them. */
object Durations {

    /** `P3600S`, or `P1D` for whole days. */
    fun text(milliseconds: Long, allDay: Boolean): String {
        val seconds = maxOf(milliseconds, 0) / 1000
        return if (allDay && seconds % 86_400 == 0L) "P${seconds / 86_400}D" else "P${seconds}S"
    }

    /** A duration's length; 0 for one that can't be read. */
    fun milliseconds(text: String): Long {
        var rest = text.trim().uppercase()
        var sign = 1
        if (rest.startsWith("-")) sign = -1
        rest = rest.trimStart('+', '-')
        if (!rest.startsWith("P")) return 0
        var seconds = 0L
        var number = 0L
        for (character in rest.drop(1)) {
            when (character) {
                in '0'..'9' -> number = number * 10 + (character - '0')
                'W' -> { seconds += number * 604_800; number = 0 }
                'D' -> { seconds += number * 86_400; number = 0 }
                'H' -> { seconds += number * 3_600; number = 0 }
                'M' -> { seconds += number * 60; number = 0 }
                'S' -> { seconds += number; number = 0 }
                'T' -> number = 0
                else -> return 0
            }
        }
        return sign * seconds * 1000
    }
}

/** The store's changes, for Swift. Main thread. */
object CalendarNatives {

    external fun changed()
}
