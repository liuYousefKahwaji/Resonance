import java.util.Base64

plugins {
    id("com.android.application")
    id("com.chaquo.python")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val updateTest = (project.findProperty("dart-defines") as? String).orEmpty().split(",").any {
    runCatching { String(Base64.getDecoder().decode(it)) == "RESONANCE_UPDATE_TEST=true" }.getOrDefault(false)
}
val updateTestX64 = updateTest && System.getenv("RESONANCE_TEST_ABI") == "x86_64"
val ciSigning = System.getenv("RESONANCE_KEYSTORE_PATH")
if (System.getenv("RESONANCE_CI_SIGNING_REQUIRED") == "true" && ciSigning.isNullOrEmpty()) {
    error("CI must restore the exact existing Resonance signing keystore")
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
        if (updateTest) applicationIdSuffix = ".updatertest"
        buildConfigField("boolean", "RESONANCE_UPDATE_TEST", updateTest.toString())
        manifestPlaceholders["appLabel"] = if (updateTest) "Resonance Update Test" else "Resonance"
        // Chaquopy 17.0.0 requires minSdk >= 24
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            // Resonance's release helper targets arm64, which covers modern
            // Android devices and keeps Flutter, FFmpeg and Python single-ABI.
            abiFilters += listOf(if (updateTestX64) "x86_64" else "arm64-v8a")
        }

    }

    buildFeatures { buildConfig = true }
    externalNativeBuild { cmake { path = file("../../native/update_patch/CMakeLists.txt"); version = "3.22.1" } }
    if (!ciSigning.isNullOrEmpty()) {
        signingConfigs.create("releaseExisting") {
            storeFile = file(ciSigning)
            storePassword = System.getenv("RESONANCE_KEYSTORE_PASSWORD") ?: error("Missing signing password")
            keyAlias = System.getenv("RESONANCE_KEY_ALIAS") ?: error("Missing signing alias")
            keyPassword = System.getenv("RESONANCE_KEY_PASSWORD") ?: error("Missing key password")
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (ciSigning.isNullOrEmpty()) "debug" else "releaseExisting")
        }
    }

    packaging {
        jniLibs {
            // yt-dlp launches QuickJS as a subprocess. Android's default
            // direct-from-APK native loading leaves no executable filesystem
            // path, so extract native libraries into nativeLibraryDir.
            useLegacyPackaging = true
            // Some prebuilt plugins publish every ABI and bypass abiFilters.
            // Resonance's release target is arm64, so discard unreachable
            // FFmpeg/Python binaries from the final package explicitly.
            excludes += setOf("**/armeabi-v7a/*.so", if (updateTestX64) "**/arm64-v8a/*.so" else "**/x86_64/*.so")
        }
    }
}

dependencies {
    implementation("androidx.media:media:1.7.0")
    testImplementation("junit:junit:4.13.2")
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
            // Keep Android on the same tested nightly snapshot bundled for
            // Windows. Plain "yt-dlp" resolves PyPI's latest stable build,
            // which can lag behind the YouTube extractor fixes we need.
            install("yt-dlp==2026.8.20.234504.dev0")
            // The exact EJS version required by the pinned nightly. Cookies
            // authenticate the request; EJS + QuickJS solve YouTube's player
            // signature and n challenges for the resulting media formats.
            install("yt-dlp-ejs==0.8.0")
            install("ytmusicapi==1.12.2")
        }
    }
}

flutter {
    source = "../.."
}
