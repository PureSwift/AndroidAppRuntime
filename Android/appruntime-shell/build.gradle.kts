// The shell (Documentation/Plan.md §4): the Application that loads
// libapp.so, the Activity that starts the guest and shows the player, and
// the host's natives. It brings the player and the contracts' Android side.
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
}

android {
    namespace = "org.pureswift.appruntime"
    compileSdk = 36
    defaultConfig {
        minSdk = 28
        consumerProguardFiles("consumer-rules.pro")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    api(project(":appruntime-ui"))
    api(project(":appruntime-contracts"))
    api("androidx.activity:activity-compose:1.10.1")
}
