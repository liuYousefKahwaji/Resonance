plugins {
    id("com.android.application")
    id("com.chaquo.python")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.example.resonance"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        // Chaquopy 17.0.0 requires Java 17
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        applicationId = "com.example.resonance"
        // Chaquopy 17.0.0 requires minSdk >= 24
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // arm64-v8a covers all modern Android devices.
            // armeabi-v7a dropped for Python 3.12+ — omit to keep APK smaller.
            abiFilters += listOf("arm64-v8a")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName("debug")
        }
    }
}

// ── Chaquopy ──────────────────────────────────────────────────────────────────
// IMPORTANT: In KTS this MUST be a top-level block — not inside android {} or
// defaultConfig {}. The old Groovy DSL had python {} inside defaultConfig but
// KTS requires the top-level chaquopy {} block (new DSL since Chaquopy 13.0).
//
// buildPython: Chaquopy needs the same Python version on your build machine
// as the one it embeds in the APK (default 3.10 for Chaquopy 17.0.0).
// We try common Windows install paths. If none work, install Python 3.10 from
// python.org and ensure it's on PATH as "python3.10" or "python".
chaquopy {
    defaultConfig {
        // Try to find Python automatically. If build fails with
        // "Couldn't find Python 3.10", install Python 3.10 from python.org
        // and either add it to PATH or set buildPython explicitly like:
        // buildPython = "C:\\Users\\kawa\\AppData\\Local\\Programs\\Python\\Python310\\python.exe"
        pip {
            install("yt-dlp")
        }
    }
}

flutter {
    source = "../.."
}