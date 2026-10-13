plugins {
    id("com.android.application")
    kotlin("android")
}

android {
    namespace = "com.example.kmpapp"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.example.kmpapp"
        minSdk = 24
        targetSdk = 36
        versionCode = 1
        versionName = "1.0"
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = false
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(project(":shared"))

    // Instrumented tests for the screenshot lane (see docs/mobile-screenshots.md).
    androidTestImplementation("androidx.test:runner:1.7.0")
    androidTestImplementation("androidx.test.ext:junit:1.3.0")
    androidTestImplementation("junit:junit:4.13.2")
    androidTestImplementation("tools.fastlane:screengrab:2.1.1")
}
