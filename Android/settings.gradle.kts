// The Android side of the host (Documentation/Plan.md §4):
// - :appruntime-ui, the player: composeui and the render IR adapter;
// - :appruntime-contracts, the contract modules' calls to the Android SDK;
// - :appruntime-shell, the Application, Activity and the host's natives;
// - :example-ui, a hand-made app for AppRuntime's ExampleUI (phase 1);
// - :example-app, phase 0's bare Activity for ExampleApp.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "AndroidAppRuntime"
include(":appruntime-ui")
include(":appruntime-contracts")
include(":appruntime-shell")
include(":example-ui")
include(":example-app")
