plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "io.github.lixuedenon.localroll_mobile"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_11
        targetCompatibility = JavaVersion.VERSION_11
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_11.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "io.github.lixuedenon.localroll_mobile"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // CI signs with one fixed key (GitHub secrets), so a new APK installs
    // over the old one and keeps its data. Local builds fall back to the
    // debug key.
    val lrKeystore = System.getenv("LR_KEYSTORE_PATH")
    signingConfigs {
        if (lrKeystore != null && file(lrKeystore).exists()) {
            create("lr") {
                storeFile = file(lrKeystore)
                storePassword = System.getenv("LR_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("LR_KEY_ALIAS")
                keyPassword = System.getenv("LR_KEY_PASSWORD")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.findByName("lr") ?: signingConfigs.getByName("debug")
        }
    }
}

flutter {
    source = "../.."
}
