// ExampleMedia's manifest for Scripts/example-media.sh: AppRuntime's
// example, with `audio` for its players and `network` for its video.
// The script makes its songs, short tones, into the bundle's resources.
import AppManifest

let app = App(
    id: "org.pureswift.ExampleMedia",
    name: "ExampleMedia",
    version: "1.0", build: 1,
    product: "ExampleMedia",
    capabilities: [.audio, .network],
    platforms: [.android(minSDK: 28, targetSDK: 35)]
)
