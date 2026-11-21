// ExampleSignIn's manifest for Scripts/example-signin.sh: AppRuntime's
// example, with `secrets` for its token and the scheme its sign-in
// redirects to.
import AppManifest

let app = App(
    id: "org.pureswift.ExampleSignIn",
    name: "ExampleSignIn",
    version: "1.0", build: 1,
    product: "ExampleSignIn",
    capabilities: [.secrets],
    authenticationSchemes: ["org.pureswift.example.signin"],
    platforms: [.android(minSDK: 28, targetSDK: 35)]
)
