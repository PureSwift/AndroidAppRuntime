// The contract modules' Android side (Documentation/Plan.md §4): a class per
// contract that calls the Android SDK for Swift, and an object whose
// natives carry what the system reports back to Swift. Swift does the
// contracts' logic; these stay thin.
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

android {
    namespace = "org.pureswift.appruntime.contracts"
    compileSdk = 36
    defaultConfig {
        minSdk = 28
        consumerProguardFiles("consumer-rules.pro")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    implementation("androidx.core:core:1.15.0")
    // The media players (Plan.md §6.10); the shell shows them in PlayerView.
    api("androidx.media3:media3-exoplayer:1.5.1")
    api("androidx.media3:media3-ui:1.5.1")
}
