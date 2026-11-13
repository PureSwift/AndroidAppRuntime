// The Android side of the host (Documentation/Plan.md §4). Phase 0 has one
// module: a bare Activity that runs AppRuntime's ExampleApp.
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
include(":example-app")
