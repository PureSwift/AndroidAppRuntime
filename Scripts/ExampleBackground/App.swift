// ExampleBackground's manifest for Scripts/example-background.sh: AppRuntime's
// example, with `backgroundTasks` and the refresh task it asks for.
import AppManifest

let app = App(
    id: "org.pureswift.ExampleBackground",
    name: "ExampleBackground",
    version: "1.0", build: 1,
    product: "ExampleBackground",
    capabilities: [.backgroundTasks],
    backgroundTasks: [.refresh("org.pureswift.example.background.refresh")],
    platforms: [.android(minSDK: 28, targetSDK: 35)]
)
