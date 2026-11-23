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
    // The system photo picker, and its fallbacks (Plan.md §6.8).
    implementation("androidx.activity:activity:1.10.1")
    // Sign-in pages in the system's browser (Plan.md §6.12).
    implementation("androidx.browser:browser:1.9.0")
    // The media players (Plan.md §6.10); the shell shows them in PlayerView.
    api("androidx.media3:media3-exoplayer:1.5.1")
    api("androidx.media3:media3-ui:1.5.1")
    // What's playing, its buttons, and playing in the background (Plan.md §6.13).
    implementation("androidx.media3:media3-session:1.5.1")
    // Background tasks the system runs, while the app is closed too (Plan.md §6.17).
    implementation("androidx.work:work-runtime:2.10.1")
    implementation("androidx.concurrent:concurrent-futures:1.2.0")
    // The camera's preview, photos and video (Plan.md §6.19).
    implementation("androidx.camera:camera-camera2:1.4.2")
    implementation("androidx.camera:camera-lifecycle:1.4.2")
    implementation("androidx.camera:camera-video:1.4.2")
    implementation("androidx.camera:camera-view:1.4.2")
}
