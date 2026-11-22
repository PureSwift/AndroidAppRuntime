import AndroidHost
import DynamicContacts
import DynamicRuntime
import RuntimeHost
import RuntimeContacts

/// What `AndroidContactDirectory` asks Android, through the Kotlin
/// `org.pureswift.appruntime.contracts.ContactSystem` (`AndroidHostApp`
/// binds it). Called on the contacts queue, one call at a time. Each call
/// leaves a `ContactStoreError` raw value for `error()`: 0 when it
/// succeeded.
///
/// A person crosses as strings (`ContactFields`).
public protocol ContactSystem: AnyObject {

    func error() -> Int32

    /// Everyone, in the system's order.
    func all() -> [String]

    /// Who the system's search finds, best first; `limit` 0 is all.
    func search(_ text: String, limit: Int32) -> [String]

    /// One person; nothing when they're gone.
    func find(_ identifier: String) -> [String]

    /// Adds the person, with an empty identifier, or changes the one
    /// named; gives the person's identifier.
    func save(_ fields: [String]) -> String

    func remove(_ identifier: String)
}

/// A person as the Kotlin side writes them: the identifier, the display
/// name, nine name parts, the birthday, then each list as its count and its
/// items. Phones, emails and URLs are a label and a value; addresses a
/// label and six fields.
enum ContactFields {

    static func encode(_ contact: Contact) -> [String] {
        var fields = [contact.id ?? "", contact.displayName]
        fields += contact.nameParts
        fields.append(contact.birthday?.text ?? "")
        for list in [contact.phoneNumbers, contact.emailAddresses, contact.urls] {
            fields.append(String(list.count))
            for item in list {
                fields += [item.label.rawValue, item.value]
            }
        }
        fields.append(String(contact.postalAddresses.count))
        fields += Contact.fields(contact.postalAddresses)
        return fields
    }

    /// The people in `fields`; nil when they don't parse.
    static func decode(_ fields: [String]) -> [Contact]? {
        var index = 0
        func next() -> String? {
            guard index < fields.count else { return nil }
            defer { index += 1 }
            return fields[index]
        }
        func labeled() -> [LabeledValue<String>]? {
            guard let count = next().flatMap({ Int($0) }), count >= 0 else { return nil }
            var labels: [String] = []
            var values: [String] = []
            for _ in 0..<count {
                guard let label = next(), let value = next() else { return nil }
                labels.append(label)
                values.append(value)
            }
            return Contact.labeled(labels, values)
        }
        var people: [Contact] = []
        while index < fields.count {
            guard let id = next(), let displayName = next() else { return nil }
            var parts: [String] = []
            for _ in 0..<9 {
                guard let part = next() else { return nil }
                parts.append(part)
            }
            guard let birthday = next(),
                  let phones = labeled(), let emails = labeled(), let urls = labeled(),
                  let addressCount = next().flatMap({ Int($0) }), addressCount >= 0 else {
                return nil
            }
            var addressFields: [String] = []
            for _ in 0..<(addressCount * 7) {
                guard let field = next() else { return nil }
                addressFields.append(field)
            }
            var contact = Contact()
            contact.id = id
            contact.namePrefix = parts[0]
            contact.givenName = parts[1]
            contact.middleName = parts[2]
            contact.familyName = parts[3]
            contact.nameSuffix = parts[4]
            contact.nickname = parts[5]
            contact.organizationName = parts[6]
            contact.departmentName = parts[7]
            contact.jobTitle = parts[8]
            contact.birthday = ContactDate(text: birthday)
            contact.phoneNumbers = phones
            contact.emailAddresses = emails
            contact.urls = urls
            contact.postalAddresses = Contact.addresses(addressFields)
            people.append(contact.named(displayName))
        }
        return people
    }
}

/// The user's contacts on Android (`Plan.md` §6.14): `ContactsContract`,
/// through the Kotlin `ContactSystem`. A person is the unified contact, in
/// `SORT_KEY_PRIMARY` order with `DISPLAY_NAME_PRIMARY` as their name;
/// a search is `Contacts.CONTENT_FILTER_URI`, the system's own.
public final class AndroidContactDirectory: ContactDirectory, @unchecked Sendable {

    let system: any ContactSystem

    public init(system: any ContactSystem) {
        self.system = system
    }

    private func check() throws(ContactStoreError) {
        let code = system.error()
        guard code == 0 else {
            throw ContactStoreError(rawValue: code) ?? .unknown
        }
    }

    private func people(_ fields: [String]) throws(ContactStoreError) -> [Contact] {
        try check()
        guard let people = ContactFields.decode(fields) else {
            throw .unknown
        }
        return people
    }

    public func contacts() throws(ContactStoreError) -> [Contact] {
        try people(system.all())
    }

    public func contacts(matching text: String, limit: Int?) throws(ContactStoreError) -> [Contact] {
        try people(system.search(text, limit: Int32(clamping: limit ?? 0)))
    }

    public func contact(withID identifier: String) throws(ContactStoreError) -> Contact? {
        try people(system.find(identifier)).first
    }

    public func save(_ contact: Contact) throws(ContactStoreError) -> Contact {
        let identifier = system.save(ContactFields.encode(contact))
        try check()
        guard let saved = try self.contact(withID: identifier) else {
            throw .notFound
        }
        return saved
    }

    public func remove(_ contact: Contact) throws(ContactStoreError) {
        guard let identifier = contact.id else {
            throw .notFound
        }
        system.remove(identifier)
        try check()
    }
}

/// The contacts module (`Plan.md` §6.14): AppRuntime's `HostContacts` over
/// `AndroidContactDirectory`, with access from Android's runtime
/// permissions.
public enum AndroidHostContacts: HostModule {

    /// `READ_CONTACTS`, and `WRITE_CONTACTS` for an app that writes.
    nonisolated(unsafe) public private(set) static var permissions: [String] = []

    /// Starts the system reporting changes, once access allows it.
    nonisolated(unsafe) static var observe: () -> Void = { }

    nonisolated(unsafe) private static var observing = false

    public static let readContacts = "android.permission.READ_CONTACTS"
    public static let writeContacts = "android.permission.WRITE_CONTACTS"

    /// Points `HostContacts` at Android's contacts. `allowsWriting` is the
    /// manifest's `RTCapabilityOptions.contacts.access`: anything but
    /// `readOnly`. `observe` starts `ContentObserver` reports. Main thread.
    public static func configure(_ directory: AndroidContactDirectory, allowsWriting: Bool, observe: @escaping () -> Void) {
        HostContacts.directory = directory
        HostContacts.allowsWriting = allowsWriting
        HostContacts.deliver = { job in MainLooper.shared.post(job) }
        permissions = allowsWriting ? [readContacts, writeContacts] : [readContacts]
        Self.observe = observe
        observing = false
        HostContacts.requester = { completion in
            AndroidPermissions.request(permissions) { _ in
                refresh()
                completion(HostContacts.access)
            }
        }
        refresh()
    }

    /// What the user granted, as Android says now: when the app starts,
    /// after a request, and when it comes back to the front, since the
    /// user may have changed it in Settings. Main thread.
    public static func refresh() {
        guard let system = AndroidPermissions.system, !permissions.isEmpty else { return }
        let status = AndroidPermissions.status(AndroidPermissions.Requirement(permissions: permissions), system: system)
        HostContacts.access = access(status)
        if HostContacts.access.allowsReading, !observing {
            observing = true
            observe()
        }
    }

    static func access(_ status: PermissionStatus) -> ContactStoreAccess {
        switch status {
        case .granted, .limited: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .unavailable: .unavailable
        default: .notDetermined
        }
    }

    /// The store changed: from the `ContentObserver`. Main thread.
    public static func changed() {
        HostContacts.storeChanged()
    }

    public static var contracts: [ContractDescriptor] {
        HostContactsModule.contracts
    }

    public static func register(in registrar: some ContractRegistrar) {
        HostContactsModule.register(in: registrar)
    }

    public static func permissionProviders() -> [Capability: any PermissionProvider] {
        HostContactsModule.permissionProviders()
    }
}
