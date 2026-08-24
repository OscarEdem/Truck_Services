plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}


android {
    namespace = "com.example.cargomate"
    compileSdk = flutter.compileSdkVersion

    // ⬇️ Force the NDK version required by your plugins
    ndkVersion = "27.0.12077973"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.example.cargomate"

        // ⬇️ Ensure minSdk is at least 23 (Firebase Auth 23.x requirement)
        minSdk = maxOf(23, flutter.minSdkVersion)

        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        // ✅ Wire env key to manifest
        manifestPlaceholders["GOOGLE_MAPS_API_KEY"] =
        project.findProperty("GOOGLE_MAPS_API_KEY") ?: ""
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}


flutter {
    source = "../.."
}


dependencies {
    // Firebase BOM (keeps versions aligned)
    implementation(platform("com.google.firebase:firebase-bom:34.2.0"))
    implementation("com.google.firebase:firebase-auth")

    // Optional Firebase Analytics (only if you want it)
    // implementation("com.google.firebase:firebase-analytics")
}