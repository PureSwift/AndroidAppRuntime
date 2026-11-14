// Phase 1 (Documentation/Plan.md §11): AppRuntime's ExampleUI, from its
// universal bundle, in a hand-made app. Scripts/example-ui.sh builds
// libapp.so with the bundle's slice, stages it with the Swift runtime, and
// copies the bundle's Info.plist to assets/rt/.
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Where the script stages the native libraries (one folder per ABI) and the
// app's assets.
val jniLibsDir: String = (findProperty("jniLibsDir") as String?)
    ?: rootProject.file("../.build/example-ui/jniLibs").path
val assetsDir: String = (findProperty("assetsDir") as String?)
    ?: rootProject.file("../.build/example-ui/assets").path

android {
    namespace = "org.pureswift.appruntime.exampleui"
    compileSdk = 36

    defaultConfig {
        applicationId = "org.pureswift.ExampleUI"
        minSdk = 28
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    sourceSets["main"].jniLibs.srcDir(jniLibsDir)
    sourceSets["main"].assets.srcDir(assetsDir)

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        jniLibs.keepDebugSymbols += "**/*.so"
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation(project(":appruntime-shell"))
}
