// Phase 0 (Documentation/Plan.md §11): AppRuntime's ExampleApp, from its
// sealed Android slice, run from a bare Activity. Scripts/example-app.sh
// builds libExampleAppHost.so and the Swift runtime into jniLibs first.
plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
}

// Where Scripts/example-app.sh stages the native libraries, one folder per ABI.
val jniLibsDir: String = (findProperty("jniLibsDir") as String?)
    ?: rootProject.file("../.build/jniLibs").path

android {
    namespace = "org.pureswift.appruntime.example"
    compileSdk = 36

    defaultConfig {
        applicationId = "org.pureswift.appruntime.example"
        minSdk = 28
        targetSdk = 35
        versionCode = 1
        versionName = "1.0"
    }

    sourceSets["main"].jniLibs.srcDir(jniLibsDir)

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    packaging {
        // The libraries are already stripped or wanted with symbols.
        jniLibs.keepDebugSymbols += "**/*.so"
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
    }
}
