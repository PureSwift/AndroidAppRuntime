// The SwiftUI player (Documentation/Plan.md §7): AndroidSwiftUI's composeui,
// a Compose interpreter, behind an adapter for AppRuntime's render IR.
//
// composeui's sources are compiled here from an AndroidSwiftUI checkout
// (ANDROIDSWIFTUI_PATH, or -PandroidSwiftUIPath; ../../AndroidSwiftUI by
// default), without the jextract bridge its own Gradle module needs: only its
// SwiftUIHostView uses that bridge, and the host has its own (§9.2).
//
// The desktop JVM target runs the adapter's tests with no emulator.
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("org.jetbrains.kotlin.multiplatform")
    id("com.android.library")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.compose")
    id("org.jetbrains.kotlin.plugin.serialization")
}

val androidSwiftUI: File = file(
    (findProperty("androidSwiftUIPath") as String?)
        ?: System.getenv("ANDROIDSWIFTUI_PATH")
        ?: rootDir.resolve("../../AndroidSwiftUI").path
)
val composeui: File = androidSwiftUI.resolve("composeui/src")
check(composeui.isDirectory) {
    "composeui not found at $composeui: set ANDROIDSWIFTUI_PATH to an AndroidSwiftUI checkout"
}

kotlin {
    androidTarget {
        compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
    }
    jvm("desktop") {
        compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
    }

    sourceSets {
        commonMain {
            kotlin.srcDir(composeui.resolve("commonMain/kotlin"))
            dependencies {
                api(compose.runtime)
                api(compose.foundation)
                api(compose.material3)
                api(compose.ui)
                implementation("org.jetbrains.compose.material:material-icons-core:1.7.3")
                api("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
            }
        }
        androidMain {
            kotlin.srcDir(composeui.resolve("androidMain/kotlin"))
            // The one file that needs AndroidSwiftUI's jextract bridge.
            kotlin.exclude("**/SwiftUIHostView.kt")
            dependencies {
                implementation("androidx.media3:media3-exoplayer:1.4.1")
                implementation("androidx.media3:media3-ui:1.4.1")
            }
        }
        val desktopMain by getting {
            kotlin.srcDir(composeui.resolve("desktopMain/kotlin"))
        }
        val desktopTest by getting {
            dependencies {
                implementation(kotlin("test"))
                implementation(compose.desktop.currentOs)
            }
        }
    }
}

android {
    namespace = "org.pureswift.appruntime.ui"
    compileSdk = 36
    defaultConfig {
        minSdk = 28
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}
