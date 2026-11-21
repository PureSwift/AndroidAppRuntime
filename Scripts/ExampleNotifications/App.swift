// ExampleNotifications' manifest for Scripts/example-notifications.sh:
// AppRuntime's example, with the `notifications` capability its timers and
// its push registration need.
import AppManifest

let app = App(
    id: "org.pureswift.ExampleNotifications",
    name: "ExampleNotifications",
    version: "1.0", build: 1,
    product: "ExampleNotifications",
    // It registers for pushes; Android answers unsupported, with no FCM.
    capabilities: [.notifications(remote: true)],
    platforms: [.android(minSDK: 28, targetSDK: 35)]
)
