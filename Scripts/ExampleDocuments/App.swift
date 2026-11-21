// ExampleDocuments' manifest for Scripts/example-documents.sh: AppRuntime's
// example, with the `userFiles` capability its pickers need, and text files
// to open from the file manager.
import AppManifest

let app = App(
    id: "org.pureswift.ExampleDocuments",
    name: "ExampleDocuments",
    version: "1.0", build: 1,
    product: "ExampleDocuments",
    capabilities: [.userFiles],
    documentTypes: [
        .init(name: "Text", types: ["text/plain"], role: .editor),
    ],
    platforms: [.android(minSDK: 28, targetSDK: 35)]
)
