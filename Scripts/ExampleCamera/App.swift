// ExampleCamera's manifest for Scripts/example-camera.sh: AppRuntime's
// example, with the camera, the microphone for a video's sound, and adding
// what it takes to the user's photos.
import AppManifest

let app = App(
    id: "org.pureswift.ExampleCamera",
    name: "ExampleCamera",
    version: "1.0", build: 1,
    product: "ExampleCamera",
    capabilities: [
        .camera(usage: "Takes photos and videos."),
        .microphone(usage: "Records sound with your videos."),
        .photoLibrary(.addOnly, usage: "Saves what you take to your photos."),
    ],
    platforms: [.android(minSDK: 28, targetSDK: 35)]
)
