import Testing
import AndroidHost
import DynamicContacts
import DynamicRuntime
import RuntimeContacts
import RuntimeHost
@testable import AndroidHostContacts

/// The Kotlin side's contacts, in memory: people as `ContactFields` has
/// them, found by the start of a word of their name.
final class ScriptedContacts: ContactSystem {

    var people: [[String]] = []

    var calls: [String] = []

    /// The error every call leaves; 0 for none.
    var failing: Int32 = 0

    var nextID = 1

    func error() -> Int32 { failing }

    func all() -> [String] {
        failing == 0 ? people.flatMap { $0 } : []
    }

    func search(_ text: String, limit: Int32) -> [String] {
        calls.append("search \(text) \(limit)")
        let found = people.filter { person in
            person[1].split(separator: " ").contains { $0.lowercased().hasPrefix(text.lowercased()) }
        }
        return (limit > 0 ? Array(found.prefix(Int(limit))) : found).flatMap { $0 }
    }

    func find(_ identifier: String) -> [String] {
        people.first { $0[0] == identifier } ?? []
    }

    func save(_ fields: [String]) -> String {
        calls.append("save \(fields[0].isEmpty ? "new" : fields[0])")
        guard failing == 0 else { return "" }
        var person = fields
        if person[0].isEmpty {
            person[0] = String(nextID)
            nextID += 1
        }
        // The system names them: given and family name.
        person[1] = [person[3], person[5]].filter { !$0.isEmpty }.joined(separator: " ")
        people.removeAll { $0[0] == person[0] }
        people.append(person)
        return person[0]
    }

    func remove(_ identifier: String) {
        calls.append("remove \(identifier)")
        if failing == 0 { people.removeAll { $0[0] == identifier } }
    }
}

final class Permissions: PermissionSystem {

    var apiLevel: Int32 = 34
    var granted: Set<String> = []
    var requested: Set<String> = []
    var declared: Set<String> = [AndroidHostContacts.readContacts, AndroidHostContacts.writeContacts]
    var requests: [(permissions: [String], id: Int32)] = []

    func isGranted(_ permission: String) -> Bool { granted.contains(permission) }
    func wasRequested(_ permission: String) -> Bool { requested.contains(permission) }
    func isDeclared(_ permission: String) -> Bool { declared.contains(permission) }
    func hasFeature(_ feature: String) -> Bool { true }

    func request(_ permissions: [String], id: Int32) -> Bool {
        requests.append((permissions, id))
        requested.formUnion(permissions)
        return true
    }
}

final class Answer: ContactCallback {

    var events: [String] = []
    var people: [Contact] = []

    func didComplete() { events.append("complete") }
    func didChangeAccess(_ access: Int32) { events.append("access \(access)") }

    func didListContacts(_ contacts: [any ContactRecord]) {
        people = contacts.map(Contact.init)
        events.append("listed \(people.map(\.displayName))")
    }

    func didFindContact(_ contact: (any ContactRecord)?) {
        people = contact.map { [Contact($0)] } ?? []
        events.append("found \(people.first?.displayName ?? "none")")
    }

    func didFail(_ error: Int32) { events.append("fail \(error)") }
}

final class Listener: ContactsDelegate {
    var changes = 0
    func didChange() { changes += 1 }
}

/// `HostContacts` over `AndroidContactDirectory`, with access from scripted
/// permissions, answering at once.
///
/// Serialized: `HostContacts` and `AndroidPermissions` are shared.
@Suite(.serialized) final class AndroidContactsTests {

    let contacts = ScriptedContacts()

    let permissions = Permissions()

    var observed = 0

    init() {
        HostContacts.reset()
        AndroidPermissions.reset()
        AndroidPermissions.system = permissions
        permissions.granted = [AndroidHostContacts.readContacts, AndroidHostContacts.writeContacts]
        configure(allowsWriting: true)
    }

    deinit {
        HostContacts.reset()
        AndroidPermissions.reset()
        AndroidPermissions.system = nil
    }

    func configure(allowsWriting: Bool) {
        AndroidHostContacts.configure(AndroidContactDirectory(system: contacts), allowsWriting: allowsWriting) { [unowned self] in
            observed += 1
        }
        HostContacts.work = { $0() }
        HostContacts.deliver = { $0() }
    }

    var store: HostContacts { HostContacts.shared() }

    static var ada: Contact {
        var ada = Contact()
        ada.givenName = "Ada"
        ada.familyName = "Lovelace"
        ada.nickname = "Enchantress"
        ada.jobTitle = "Programmer"
        ada.phoneNumbers = [LabeledValue(.mobile, "+353 1 555 0100"), LabeledValue("Lab", "555 0199")]
        ada.emailAddresses = [LabeledValue(.work, "ada@example.com")]
        ada.urls = [LabeledValue(.home, "https://ada.example")]
        ada.postalAddresses = [LabeledValue(.home, PostalAddress(street: "12 St James's Square", city: "London", isoCountryCode: "GB"))]
        ada.birthday = ContactDate(month: 12, day: 10)
        return ada
    }

    func save(_ contact: Contact) -> Answer {
        let answer = Answer()
        let record = store.makeContact()
        contact.fill(record)
        record.save(answer)
        return answer
    }

    @Test func aPersonCrossesAsStrings() throws {
        var ada = Self.ada
        ada.id = "7"
        let fields = ContactFields.encode(ada.named("Ada Lovelace"))
        #expect(fields.prefix(12) == ["7", "Ada Lovelace", "", "Ada", "", "Lovelace", "", "Enchantress", "", "", "Programmer", "--12-10"])
        let decoded = try #require(ContactFields.decode(fields + fields))
        #expect(decoded.count == 2)
        #expect(decoded[0] == ada.named("Ada Lovelace"))
        #expect(decoded[0].phoneNumbers[1].label == "Lab")
        #expect(ContactFields.decode(Array(fields.dropLast())) == nil, "a person cut short")
        #expect(ContactFields.decode([]) == [])
    }

    @Test func peopleAreSavedFoundAndRemoved() throws {
        let listener = Listener()
        store.setDelegate(listener)
        let saved = save(Self.ada)
        #expect(saved.events == ["found Ada Lovelace"])
        let id = try #require(saved.people.first?.id)
        #expect(saved.people.first?.postalAddresses.first?.value.isoCountryCode == "GB")
        var promoted = saved.people[0]
        promoted.organizationName = "Analytical Engines"
        #expect(save(promoted).people.first?.organizationName == "Analytical Engines")
        #expect(contacts.calls == ["save new", "save \(id)"])
        // A search is the system's; an empty one finds no one.
        let found = Answer()
        store.contacts("love", all: false, limit: 5, callback: found)
        store.contacts("", all: false, limit: 5, callback: found)
        #expect(found.events == [#"listed ["Ada Lovelace"]"#, "listed []"])
        #expect(contacts.calls.last == "search love 5")
        let removed = Answer()
        let record = store.makeContact()
        promoted.fill(record)
        record.remove(removed)
        store.contacts("", all: true, limit: 0, callback: removed)
        #expect(removed.events == ["complete", "listed []"])
        // This app's own changes are said: here each, as answers come at
        // once and none waits to be joined to another.
        #expect(listener.changes == 3)
    }

    @Test func androidsErrorsAreTheStores() {
        contacts.failing = ContactStoreError.readOnly.rawValue
        #expect(save(Self.ada).events == ["fail \(ContactStoreError.readOnly.rawValue)"])
        let listed = Answer()
        contacts.failing = ContactStoreError.notAuthorized.rawValue
        store.contacts("", all: true, limit: 0, callback: listed)
        #expect(listed.events == ["fail \(ContactStoreError.notAuthorized.rawValue)"])
    }

    @Test func accessIsAndroidsPermissions() throws {
        #expect(HostContacts.access == .authorized)
        #expect(observed == 1)
        AndroidHostContacts.refresh()
        #expect(observed == 1, "changes are reported once")
        // Not asked yet: asking is Android's dialog.
        permissions.granted = []
        AndroidHostContacts.refresh()
        #expect(HostContacts.access == .notDetermined)
        let answer = Answer()
        store.requestAccess(answer)
        let request = try #require(permissions.requests.last)
        #expect(request.permissions == [AndroidHostContacts.readContacts, AndroidHostContacts.writeContacts])
        permissions.granted = Set(request.permissions)
        AndroidPermissions.didRequest(id: request.id, permissions: request.permissions, granted: [true, true])
        #expect(answer.events == ["access \(ContactStoreAccess.authorized.rawValue)"])
        // Turned off in Settings.
        permissions.granted = []
        AndroidHostContacts.refresh()
        #expect(HostContacts.access == .denied)
    }

    @Test func anAppThatOnlyReadsNeverWrites() {
        configure(allowsWriting: false)
        #expect(AndroidHostContacts.permissions == [AndroidHostContacts.readContacts])
        #expect(save(Self.ada).events == ["fail \(ContactStoreError.notAuthorized.rawValue)"])
        #expect(contacts.calls.isEmpty)
    }
}
