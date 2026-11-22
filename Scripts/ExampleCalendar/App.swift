// ExampleCalendar's manifest for Scripts/example-calendar.sh: AppRuntime's
// example, with `calendars` for reading and changing the user's events.
import AppManifest

let app = App(
    id: "org.pureswift.ExampleCalendar",
    name: "ExampleCalendar",
    version: "1.0", build: 1,
    product: "ExampleCalendar",
    capabilities: [.calendars(.full, usage: "Shows your events and lets you change them.")],
    platforms: [.android(minSDK: 28, targetSDK: 35)]
)
