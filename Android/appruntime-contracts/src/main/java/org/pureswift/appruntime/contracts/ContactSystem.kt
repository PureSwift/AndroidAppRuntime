package org.pureswift.appruntime.contracts

import android.content.ContentProviderOperation
import android.content.ContentResolver
import android.content.OperationApplicationException
import android.database.ContentObserver
import android.database.Cursor
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.RemoteException
import android.provider.ContactsContract
import android.provider.ContactsContract.CommonDataKinds.Email
import android.provider.ContactsContract.CommonDataKinds.Event
import android.provider.ContactsContract.CommonDataKinds.Nickname
import android.provider.ContactsContract.CommonDataKinds.Organization
import android.provider.ContactsContract.CommonDataKinds.Phone
import android.provider.ContactsContract.CommonDataKinds.StructuredName
import android.provider.ContactsContract.CommonDataKinds.StructuredPostal
import android.provider.ContactsContract.CommonDataKinds.Website
import android.provider.ContactsContract.Contacts
import android.provider.ContactsContract.Data
import android.provider.ContactsContract.RawContacts
import java.util.Locale

/**
 * The user's contacts for Swift's `AndroidContactDirectory`
 * (Documentation/Plan.md §6.14), through `ContactsContract`: a person is a
 * row of `Contacts`, the unified person, with the `Data` rows of each of
 * its raw contacts.
 *
 * A person crosses to Swift as strings, one after another: the
 * identifier, the display name, nine name parts (prefix, given, middle,
 * family, suffix, nickname, organization, department, job title), the
 * birthday, then each list as its count and its items: phones and emails
 * and URLs as a label and a value, addresses as a label and six fields
 * (street, city, region, postal code, country, ISO country code). Labels
 * are the contract's words (`home`, `mobile`, …) or the user's own text.
 *
 * Called on Swift's contacts queue, one call at a time. Each call returns
 * its value, or an empty one, and leaves a `ContactStoreError` raw value
 * for [error] on the same thread: 0 when it succeeded. Made on the main
 * thread, where [observe] reports changes.
 */
class ContactSystem {

    private val resolver: ContentResolver get() = HostContext.application.contentResolver

    fun error(): Int = lastError.get() ?: 0

    // MARK: Reading

    /** Everyone, in the system's order. */
    fun all(): Array<String> = call {
        people(resolver.query(Contacts.CONTENT_URI, arrayOf(Contacts._ID), null, null, Contacts.SORT_KEY_PRIMARY))
    } ?: emptyArray()

    /** Who the system's search finds for `text`, best first; `limit` 0 is all. */
    fun search(text: String, limit: Int): Array<String> = call {
        var uri = Uri.withAppendedPath(Contacts.CONTENT_FILTER_URI, Uri.encode(text))
        if (limit > 0) {
            uri = uri.buildUpon().appendQueryParameter(ContactsContract.LIMIT_PARAM_KEY, limit.toString()).build()
        }
        people(resolver.query(uri, arrayOf(Contacts._ID), null, null, null))
    } ?: emptyArray()

    /** One person; empty when they're gone. */
    fun find(identifier: String): Array<String> = call {
        val id = identifier.toLongOrNull() ?: return@call emptyArray()
        people(resolver.query(Contacts.CONTENT_URI, arrayOf(Contacts._ID), "${Contacts._ID} = ?", arrayOf(id.toString()), null))
    } ?: emptyArray()

    /** The people a query of `Contacts` names, in its order. */
    private fun people(cursor: Cursor?): Array<String> {
        val ids = ArrayList<Long>()
        cursor?.use { while (it.moveToNext()) ids += it.getLong(0) }
        if (ids.isEmpty()) return emptyArray()
        val people = LinkedHashMap<Long, Person>()
        ids.forEach { people[it] = Person(it) }
        // The display name, and which raw contact the name is from.
        for (chunk in ids.chunked(500)) {
            val where = "${Contacts._ID} IN (${chunk.joinToString(",")})"
            resolver.query(Contacts.CONTENT_URI, arrayOf(Contacts._ID, Contacts.DISPLAY_NAME_PRIMARY, Contacts.NAME_RAW_CONTACT_ID),
                where, null, null)?.use { row ->
                while (row.moveToNext()) {
                    val person = people[row.getLong(0)] ?: continue
                    person.displayName = row.getString(1) ?: ""
                    person.nameRaw = row.getLong(2)
                }
            }
            val data = "${Data.CONTACT_ID} IN (${chunk.joinToString(",")}) AND ${Data.MIMETYPE} IN (${KINDS.joinToString(",") { "'$it'" }})"
            resolver.query(Data.CONTENT_URI, DATA, data, null, "${Data.RAW_CONTACT_ID}, ${Data.IS_PRIMARY} DESC, ${Data._ID}")?.use { row ->
                while (row.moveToNext()) people[row.getLong(1)]?.add(row)
            }
        }
        return people.values.flatMap { it.fields() }.toTypedArray()
    }

    /** One person as their data rows give them. */
    private class Person(val id: Long) {
        var displayName = ""
        var nameRaw = 0L
        var names: Array<String>? = null
        var namesRaw = -1L
        var nickname = ""
        var organization: Array<String>? = null
        var birthday = ""
        val phones = ArrayList<String>()
        val emails = ArrayList<String>()
        val urls = ArrayList<String>()
        val addresses = ArrayList<String>()

        fun add(row: Cursor) {
            val raw = row.getLong(2)
            fun text(column: String) = row.getString(row.getColumnIndexOrThrow(column)) ?: ""
            fun type(column: String) = row.getInt(row.getColumnIndexOrThrow(column))
            when (row.getString(3)) {
                StructuredName.CONTENT_ITEM_TYPE -> {
                    // The name the system shows is the name raw contact's.
                    if (names == null || (raw == nameRaw && namesRaw != nameRaw)) {
                        names = arrayOf(text(StructuredName.PREFIX), text(StructuredName.GIVEN_NAME), text(StructuredName.MIDDLE_NAME),
                            text(StructuredName.FAMILY_NAME), text(StructuredName.SUFFIX))
                        namesRaw = raw
                    }
                }
                Nickname.CONTENT_ITEM_TYPE -> if (nickname.isEmpty()) nickname = text(Nickname.NAME)
                Organization.CONTENT_ITEM_TYPE -> if (organization == null) {
                    organization = arrayOf(text(Organization.COMPANY), text(Organization.DEPARTMENT), text(Organization.TITLE))
                }
                Event.CONTENT_ITEM_TYPE -> if (type(Event.TYPE) == Event.TYPE_BIRTHDAY && birthday.isEmpty()) {
                    birthday = text(Event.START_DATE)
                }
                Phone.CONTENT_ITEM_TYPE -> phones.addAll(listOf(Labels.phone(type(Phone.TYPE), text(Phone.LABEL)), text(Phone.NUMBER)))
                Email.CONTENT_ITEM_TYPE -> emails.addAll(listOf(Labels.email(type(Email.TYPE), text(Email.LABEL)), text(Email.ADDRESS)))
                Website.CONTENT_ITEM_TYPE -> urls.addAll(listOf(Labels.website(type(Website.TYPE), text(Website.LABEL)), text(Website.URL)))
                StructuredPostal.CONTENT_ITEM_TYPE -> {
                    val (country, iso) = Labels.country(text(StructuredPostal.COUNTRY))
                    addresses.addAll(listOf(
                        Labels.postal(type(StructuredPostal.TYPE), text(StructuredPostal.LABEL)),
                        text(StructuredPostal.STREET), text(StructuredPostal.CITY), text(StructuredPostal.REGION),
                        text(StructuredPostal.POSTCODE), country, iso,
                    ))
                }
            }
        }

        fun fields(): List<String> {
            val fields = ArrayList<String>()
            fields += id.toString()
            fields += displayName
            fields += (names ?: Array(5) { "" })
            fields += nickname
            fields += (organization ?: Array(3) { "" })
            fields += birthday
            for (list in listOf(phones, emails, urls)) {
                fields += (list.size / 2).toString()
                fields += list
            }
            fields += (addresses.size / 7).toString()
            fields += addresses
            return fields
        }
    }

    // MARK: Writing

    /**
     * Adds the person `fields` describe, with an empty identifier, to the
     * default account; or changes the one it names. Gives the person's
     * identifier, which a change may move. What the fields don't carry is
     * kept; the lists they have replace the ones there were.
     */
    fun save(fields: Array<String>): String = call {
        val wanted = Wanted(fields)
        if (wanted.id.isEmpty()) add(wanted) else change(wanted)
    } ?: ""

    private fun add(wanted: Wanted): String {
        val operations = ArrayList<ContentProviderOperation>()
        operations += ContentProviderOperation.newInsert(RawContacts.CONTENT_URI)
            .withValue(RawContacts.ACCOUNT_TYPE, null)
            .withValue(RawContacts.ACCOUNT_NAME, null)
            .build()
        for (insert in wanted.rows()) {
            operations += insert.withValueBackReference(Data.RAW_CONTACT_ID, 0).build()
        }
        val results = resolver.applyBatch(ContactsContract.AUTHORITY, operations)
        val raw = results[0].uri?.lastPathSegment?.toLongOrNull() ?: throw Failure(UNKNOWN)
        return contactOf(raw)?.toString() ?: throw Failure(UNKNOWN)
    }

    private fun change(wanted: Wanted): String {
        val id = wanted.id.toLongOrNull() ?: throw Failure(NOT_FOUND)
        // The person's raw contacts, the ones that can be written first.
        val raws = ArrayList<Pair<Long, Boolean>>()
        raws += rawContacts(id)
        if (raws.isEmpty()) throw Failure(NOT_FOUND)
        val writable = raws.filter { !it.second }.map { it.first }
        if (writable.isEmpty()) throw Failure(READ_ONLY)
        val first = writable[0]
        // Each kind's rows there are, by raw contact.
        val existing = ArrayList<Existing>()
        val where = "${Data.RAW_CONTACT_ID} IN (${writable.joinToString(",")}) AND ${Data.MIMETYPE} IN (${KINDS.joinToString(",") { "'$it'" }})"
        resolver.query(Data.CONTENT_URI, DATA, where, null, "${Data.RAW_CONTACT_ID}, ${Data._ID}")?.use { row ->
            while (row.moveToNext()) existing += Existing(row)
        }
        val operations = ArrayList<ContentProviderOperation>()
        for (insert in wanted.rows()) {
            val kind = insert.kind
            // A birthday is the one event that's the guest's.
            val there = existing.filter { it.kind == kind && (kind != Event.CONTENT_ITEM_TYPE || it.isBirthday) }
            if (kind in SINGLE) {
                // One of each: changed where it is, or added to the first.
                val row = there.firstOrNull()
                if (row != null) {
                    operations += ContentProviderOperation.newUpdate(ContactsContract.Data.CONTENT_URI)
                        .withSelection("${Data._ID} = ?", arrayOf(row.id.toString()))
                        .withValues(insert.changes()).build()
                    there.drop(1).forEach { operations += delete(it.id) }
                    existing.removeAll(there.toSet())
                } else {
                    operations += insert.withValue(Data.RAW_CONTACT_ID, first).build()
                }
            } else {
                // A value already there, with its label, stays; another is added.
                val same = there.firstOrNull { it.key == insert.key }
                if (same != null) {
                    existing.remove(same)
                } else {
                    operations += insert.withValue(Data.RAW_CONTACT_ID, first).build()
                }
            }
        }
        // What the guest dropped goes, from whichever raw contact had it. A
        // single kind it emptied goes too.
        for (row in existing) {
            if (row.kind == Event.CONTENT_ITEM_TYPE && !row.isBirthday) continue
            operations += delete(row.id)
        }
        if (operations.isNotEmpty()) resolver.applyBatch(ContactsContract.AUTHORITY, operations)
        // Joining may have moved the person: find them by a raw contact.
        return contactOf(first)?.toString() ?: throw Failure(NOT_FOUND)
    }

    /**
     * A person's raw contacts, and whether each is read-only: one from an
     * account whose contacts sync adapter doesn't upload, as a company
     * directory's. The device's own are never.
     */
    private fun rawContacts(id: Long): List<Pair<Long, Boolean>> {
        val readOnlyTypes = ContentResolver.getSyncAdapterTypes()
            .filter { it.authority == ContactsContract.AUTHORITY && !it.supportsUploading() }
            .map { it.accountType }
            .toSet()
        val raws = ArrayList<Pair<Long, Boolean>>()
        resolver.query(RawContacts.CONTENT_URI, arrayOf(RawContacts._ID, RawContacts.ACCOUNT_TYPE),
            "${RawContacts.CONTACT_ID} = ? AND ${RawContacts.DELETED} = 0", arrayOf(id.toString()), null)?.use {
            while (it.moveToNext()) raws += it.getLong(0) to (it.getString(1)?.let { type -> type in readOnlyTypes } ?: false)
        }
        return raws
    }

    private fun delete(id: Long): ContentProviderOperation =
        ContentProviderOperation.newDelete(Data.CONTENT_URI).withSelection("${Data._ID} = ?", arrayOf(id.toString())).build()

    private fun contactOf(raw: Long): Long? =
        resolver.query(RawContacts.CONTENT_URI, arrayOf(RawContacts.CONTACT_ID), "${RawContacts._ID} = ?", arrayOf(raw.toString()), null)?.use {
            if (it.moveToFirst() && !it.isNull(0)) it.getLong(0) else null
        }

    /** Removes the person, with every raw contact the user can remove. */
    fun remove(identifier: String) {
        call {
            val id = identifier.toLongOrNull() ?: throw Failure(NOT_FOUND)
            val raws = rawContacts(id)
            if (raws.isEmpty()) throw Failure(NOT_FOUND)
            if (raws.any { it.second }) throw Failure(READ_ONLY)
            resolver.delete(Uri.withAppendedPath(Contacts.CONTENT_URI, id.toString()), null, null)
        }
    }

    /** A data row that's there: its kind, and what it says. */
    private class Existing(row: Cursor) {
        val id = row.getLong(0)
        val kind: String = row.getString(3)
        val key: String = key(kind) { row.getString(row.getColumnIndexOrThrow(it)) ?: "" }
        val isBirthday = kind == Event.CONTENT_ITEM_TYPE && row.getInt(row.getColumnIndexOrThrow(Event.TYPE)) == Event.TYPE_BIRTHDAY
    }

    /** A row to insert, with its kind, values and key. */
    private class Insert(val kind: String, val values: android.content.ContentValues) {
        val key: String = key(kind) { values.get(it)?.toString() ?: "" }

        /** The values for changing a row of this kind: not its kind. */
        fun changes(): android.content.ContentValues =
            android.content.ContentValues(values).apply { remove(Data.MIMETYPE) }

        fun withValue(column: String, value: Any): ContentProviderOperation.Builder =
            ContentProviderOperation.newInsert(Data.CONTENT_URI).withValues(values).withValue(column, value)

        fun withValueBackReference(column: String, index: Int): ContentProviderOperation.Builder =
            ContentProviderOperation.newInsert(Data.CONTENT_URI).withValues(values).withValueBackReference(column, index)
    }

    /** The person the guest wants, from Swift's fields. */
    private class Wanted(fields: Array<String>) {
        val id: String
        private val names: List<String>
        private val birthday: String
        private val phones = ArrayList<Pair<String, String>>()
        private val emails = ArrayList<Pair<String, String>>()
        private val urls = ArrayList<Pair<String, String>>()
        private val addresses = ArrayList<List<String>>()

        init {
            var index = 0
            fun next() = fields.getOrElse(index++) { "" }
            id = next()
            next() // the display name is the system's
            names = List(9) { next() }
            birthday = next()
            for (list in listOf(phones, emails, urls)) {
                repeat(next().toIntOrNull() ?: 0) { list += next() to next() }
            }
            repeat(next().toIntOrNull() ?: 0) { addresses += List(7) { next() } }
        }

        /** Every row the person has, a single kind even when it's empty. */
        fun rows(): List<Insert> {
            val rows = ArrayList<Insert>()
            fun row(kind: String, vararg values: Pair<String, Any?>) {
                val content = android.content.ContentValues()
                content.put(Data.MIMETYPE, kind)
                for ((column, value) in values) {
                    when (value) {
                        null -> content.putNull(column)
                        is Int -> content.put(column, value)
                        else -> content.put(column, value.toString())
                    }
                }
                rows += Insert(kind, content)
            }
            fun orNull(text: String) = text.ifEmpty { null }
            if (names.subList(0, 5).any { it.isNotEmpty() }) {
                // No display name: the provider makes it from the parts.
                row(StructuredName.CONTENT_ITEM_TYPE,
                    StructuredName.DISPLAY_NAME to null,
                    StructuredName.PREFIX to orNull(names[0]), StructuredName.GIVEN_NAME to orNull(names[1]),
                    StructuredName.MIDDLE_NAME to orNull(names[2]), StructuredName.FAMILY_NAME to orNull(names[3]),
                    StructuredName.SUFFIX to orNull(names[4]))
            }
            if (names[5].isNotEmpty()) row(Nickname.CONTENT_ITEM_TYPE, Nickname.NAME to names[5])
            if (names.subList(6, 9).any { it.isNotEmpty() }) {
                row(Organization.CONTENT_ITEM_TYPE, Organization.TYPE to Organization.TYPE_WORK,
                    Organization.COMPANY to orNull(names[6]), Organization.DEPARTMENT to orNull(names[7]),
                    Organization.TITLE to orNull(names[8]))
            }
            if (birthday.isNotEmpty()) row(Event.CONTENT_ITEM_TYPE, Event.TYPE to Event.TYPE_BIRTHDAY, Event.START_DATE to birthday)
            for ((label, number) in phones) {
                val (type, text) = Labels.phoneType(label)
                row(Phone.CONTENT_ITEM_TYPE, Phone.NUMBER to number, Phone.TYPE to type, Phone.LABEL to text)
            }
            for ((label, address) in emails) {
                val (type, text) = Labels.emailType(label)
                row(Email.CONTENT_ITEM_TYPE, Email.ADDRESS to address, Email.TYPE to type, Email.LABEL to text)
            }
            for ((label, url) in urls) {
                val (type, text) = Labels.websiteType(label)
                row(Website.CONTENT_ITEM_TYPE, Website.URL to url, Website.TYPE to type, Website.LABEL to text)
            }
            for (address in addresses) {
                val (type, text) = Labels.postalType(address[0])
                row(StructuredPostal.CONTENT_ITEM_TYPE, StructuredPostal.TYPE to type, StructuredPostal.LABEL to text,
                    StructuredPostal.STREET to orNull(address[1]), StructuredPostal.CITY to orNull(address[2]),
                    StructuredPostal.REGION to orNull(address[3]), StructuredPostal.POSTCODE to orNull(address[4]),
                    StructuredPostal.COUNTRY to orNull(Labels.countryText(address[5], address[6])))
            }
            return rows
        }
    }

    // MARK: Changes

    /** Reports any change to the store, from the main thread. */
    fun observe() {
        if (observer != null) return
        val observer = object : ContentObserver(Handler(Looper.getMainLooper())) {
            override fun onChange(selfChange: Boolean) {
                ContactNatives.changed()
            }
        }
        try {
            resolver.registerContentObserver(Contacts.CONTENT_URI, true, observer)
            ContactSystem.observer = observer
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
        } catch (error: OperationApplicationException) {
            lastError.set(READ_ONLY)
            null
        } catch (error: RemoteException) {
            lastError.set(UNAVAILABLE)
            null
        } catch (error: IllegalArgumentException) {
            lastError.set(UNKNOWN)
            null
        } catch (error: UnsupportedOperationException) {
            lastError.set(READ_ONLY)
            null
        }
    }

    companion object {
        // ContactStoreError raw values; `unknown`'s is 0, which [error]
        // gives for none, so it crosses as -1, which Swift reads as unknown.
        private const val UNKNOWN = -1
        private const val NOT_AUTHORIZED = 2
        private const val UNAVAILABLE = 3
        private const val NOT_FOUND = 4
        private const val READ_ONLY = 5

        private val lastError = ThreadLocal<Int>()

        private var observer: ContentObserver? = null

        /** The kinds of data a person here has. */
        private val KINDS = listOf(
            StructuredName.CONTENT_ITEM_TYPE, Nickname.CONTENT_ITEM_TYPE, Organization.CONTENT_ITEM_TYPE, Event.CONTENT_ITEM_TYPE,
            Phone.CONTENT_ITEM_TYPE, Email.CONTENT_ITEM_TYPE, Website.CONTENT_ITEM_TYPE, StructuredPostal.CONTENT_ITEM_TYPE,
        )

        /** Kinds a person has one of. */
        private val SINGLE = setOf(StructuredName.CONTENT_ITEM_TYPE, Nickname.CONTENT_ITEM_TYPE, Organization.CONTENT_ITEM_TYPE,
            Event.CONTENT_ITEM_TYPE)

        /** Asked of each data row: `Data.DATA1` to `DATA10` hold each kind's columns. */
        private val DATA = arrayOf(
            Data._ID, Data.CONTACT_ID, Data.RAW_CONTACT_ID, Data.MIMETYPE, Data.IS_PRIMARY,
            Data.DATA1, Data.DATA2, Data.DATA3, Data.DATA4, Data.DATA5, Data.DATA6, Data.DATA7, Data.DATA8, Data.DATA9, Data.DATA10,
        )

        /** What makes two rows of a kind the same value. */
        private fun key(kind: String, column: (String) -> String): String = when (kind) {
            Phone.CONTENT_ITEM_TYPE -> listOf(Phone.NUMBER, Phone.TYPE, Phone.LABEL)
            Email.CONTENT_ITEM_TYPE -> listOf(Email.ADDRESS, Email.TYPE, Email.LABEL)
            Website.CONTENT_ITEM_TYPE -> listOf(Website.URL, Website.TYPE, Website.LABEL)
            StructuredPostal.CONTENT_ITEM_TYPE -> listOf(StructuredPostal.TYPE, StructuredPostal.LABEL, StructuredPostal.STREET,
                StructuredPostal.CITY, StructuredPostal.REGION, StructuredPostal.POSTCODE, StructuredPostal.COUNTRY)
            else -> emptyList()
        }.joinToString("\u0000") { column(it) }
    }
}

/**
 * The contract's label words and Android's types, both ways: a word the
 * platform has a type for is that type; any other label is a custom one.
 */
internal object Labels {

    fun phone(type: Int, label: String): String = when (type) {
        Phone.TYPE_HOME -> "home"
        Phone.TYPE_WORK -> "work"
        Phone.TYPE_MOBILE -> "mobile"
        Phone.TYPE_MAIN -> "main"
        Phone.TYPE_OTHER -> "other"
        Phone.TYPE_FAX_HOME -> "homeFax"
        Phone.TYPE_FAX_WORK -> "workFax"
        Phone.TYPE_PAGER -> "pager"
        Phone.TYPE_CUSTOM -> label
        else -> Phone.getTypeLabel(HostContext.application.resources, type, label).toString()
    }

    fun phoneType(label: String): Pair<Int, String?> = when (label) {
        "home" -> Phone.TYPE_HOME to null
        "work" -> Phone.TYPE_WORK to null
        "mobile" -> Phone.TYPE_MOBILE to null
        "main" -> Phone.TYPE_MAIN to null
        "other" -> Phone.TYPE_OTHER to null
        "homeFax" -> Phone.TYPE_FAX_HOME to null
        "workFax" -> Phone.TYPE_FAX_WORK to null
        "pager" -> Phone.TYPE_PAGER to null
        else -> Phone.TYPE_CUSTOM to label
    }

    fun email(type: Int, label: String): String = when (type) {
        Email.TYPE_HOME -> "home"
        Email.TYPE_WORK -> "work"
        Email.TYPE_MOBILE -> "mobile"
        Email.TYPE_OTHER -> "other"
        Email.TYPE_CUSTOM -> label
        else -> Email.getTypeLabel(HostContext.application.resources, type, label).toString()
    }

    fun emailType(label: String): Pair<Int, String?> = when (label) {
        "home" -> Email.TYPE_HOME to null
        "work" -> Email.TYPE_WORK to null
        "mobile" -> Email.TYPE_MOBILE to null
        "other" -> Email.TYPE_OTHER to null
        else -> Email.TYPE_CUSTOM to label
    }

    fun website(type: Int, label: String): String = when (type) {
        Website.TYPE_HOME -> "home"
        Website.TYPE_WORK -> "work"
        Website.TYPE_OTHER -> "other"
        Website.TYPE_HOMEPAGE -> "homepage"
        Website.TYPE_BLOG -> "blog"
        Website.TYPE_PROFILE -> "profile"
        Website.TYPE_FTP -> "ftp"
        else -> label
    }

    fun websiteType(label: String): Pair<Int, String?> = when (label) {
        "home" -> Website.TYPE_HOME to null
        "work" -> Website.TYPE_WORK to null
        "other" -> Website.TYPE_OTHER to null
        "homepage" -> Website.TYPE_HOMEPAGE to null
        "blog" -> Website.TYPE_BLOG to null
        "profile" -> Website.TYPE_PROFILE to null
        "ftp" -> Website.TYPE_FTP to null
        else -> Website.TYPE_CUSTOM to label
    }

    fun postal(type: Int, label: String): String = when (type) {
        StructuredPostal.TYPE_HOME -> "home"
        StructuredPostal.TYPE_WORK -> "work"
        StructuredPostal.TYPE_OTHER -> "other"
        else -> label
    }

    fun postalType(label: String): Pair<Int, String?> = when (label) {
        "home" -> StructuredPostal.TYPE_HOME to null
        "work" -> StructuredPostal.TYPE_WORK to null
        "other" -> StructuredPostal.TYPE_OTHER to null
        else -> StructuredPostal.TYPE_CUSTOM to label
    }

    /**
     * An address's country and ISO code from Android's one field: two
     * capital letters are the code; a country's name in the user's
     * language gives its code too.
     */
    fun country(text: String): Pair<String, String> {
        if (text.length == 2 && text.all { it in 'A'..'Z' }) return "" to text
        if (text.isEmpty()) return "" to ""
        val code = Locale.getISOCountries().firstOrNull { Locale("", it).displayCountry.equals(text, ignoreCase = true) } ?: ""
        return text to code
    }

    /** Android's one field: the country's name, or its code without one. */
    fun countryText(country: String, iso: String): String = country.ifEmpty { iso }
}

/** The store's changes, for Swift. Main thread. */
object ContactNatives {

    external fun changed()
}
