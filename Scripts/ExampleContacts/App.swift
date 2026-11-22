// ExampleContacts' manifest for Scripts/example-contacts.sh: AppRuntime's
// example, with `contacts` for reading and writing the user's address book.
import AppManifest

let app = App(
    id: "org.pureswift.ExampleContacts",
    name: "ExampleContacts",
    version: "1.0", build: 1,
    product: "ExampleContacts",
    capabilities: [.contacts(usage: "Shows your contacts and lets you change them.")],
    platforms: [.android(minSDK: 28, targetSDK: 35)]
)
