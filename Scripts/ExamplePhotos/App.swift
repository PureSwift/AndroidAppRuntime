// ExamplePhotos's manifest for Scripts/example-photos.sh: AppRuntime's
// example, with `photoLibrary` for browsing the user's photos.
import AppManifest

let app = App(
    id: "org.pureswift.ExamplePhotos",
    name: "ExamplePhotos",
    version: "1.0", build: 1,
    product: "ExamplePhotos",
    capabilities: [.photoLibrary(.readWrite, usage: "Shows your photos and videos.")],
    platforms: [.android(minSDK: 28, targetSDK: 35)]
)
