import java.util.Properties

plugins {
    id("com.android.application")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing comes from android/key.properties (not in git). Without it, release builds fall back to the
// debug key so contributors can still build.
val keyProperties = Properties().apply {
    val file = rootProject.file("key.properties")
    if (file.exists()) file.inputStream().use { load(it) }
}

android {
    namespace = "com.imtaqin.andropi"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // Only the ABIs tool/bundle_runtime.py ships a runtime for. `--split-per-abi` sets its own ABI splits,
        // which can't be combined with abiFilters.
        if (!project.hasProperty("split-per-abi")) {
            ndk {
                abiFilters += listOf("armeabi-v7a", "arm64-v8a", "x86_64")
            }
        }
        applicationId = "com.imtaqin.andropi"
        minSdk = 26
        targetSdk = flutter.targetSdkVersion
        // Uses the version code from pubspec.yaml. When using split APKs, 1000 * ABI_VERSION
        // is added automatically by Flutter. (https://developer.android.com/studio/build/configure-apk-splits#configure-APK-versions)
        // You can force using the value of versionCode by specifying the `-P force-version-code-ignoring-abi=true`
        // flag during build.
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Binaries in jniLibs are exec'd from nativeLibraryDir, so they must be
    // extracted on install rather than mapped from the APK.
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }

    // "full" is the GitHub build with "All files access" for opening any folder on the phone. "play" is the Google
    // Play build: Play only allows that permission for file managers, so it works inside the app's workspace.
    flavorDimensions += "store"
    productFlavors {
        create("full") { dimension = "store" }
        create("play") { dimension = "store" }
    }

    signingConfigs {
        if (keyProperties.isNotEmpty()) {
            create("release") {
                storeFile = file(keyProperties.getProperty("storeFile"))
                storePassword = keyProperties.getProperty("storePassword")
                keyAlias = keyProperties.getProperty("keyAlias")
                keyPassword = keyProperties.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("release") ?: signingConfigs.getByName("debug")
        }
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}

dependencies {
    // AppCompat themes are required by the biometric prompt (local_auth).
    implementation("androidx.appcompat:appcompat:1.7.1")
}
