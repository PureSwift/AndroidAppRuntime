// ExampleMedia's manifest for Scripts/example-nowplaying.sh: AppRuntime's
// example, which plays on in the background with
// `.audio(background: true)`, under an id of its own so that it doesn't
// replace Scripts/example-media.sh's. The script makes its songs.
import AppManifest

let app = App(
    id: "org.pureswift.ExampleNowPlaying",
    name: "ExampleNowPlaying",
    version: "1.0", build: 1,
    product: "ExampleMedia",
    capabilities: [.audio(background: true), .network],
    platforms: [.android(minSDK: 28, targetSDK: 35)]
)
