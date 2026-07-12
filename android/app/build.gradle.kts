plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.elitzur.auto_maps"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.elitzur.auto_maps"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // כללי-ProGuard ל-ML Kit (מזהי-כתב שלא צורפו) — בלעדיהם R8 נכשל.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // תשתית ECW נייטיבית — קומפול של libauto_maps_ecw.so דרך ה-wrapper ב-C.
    // ה-CMake מוגן ל-arm64-v8a בלבד (שם קיימים ה-prebuilt libgdal/libproj).
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
        }
    }

    // ה-prebuilt libc++_shared.so עלול להתנגש עם עותק שמגיע מ-NDK/פלאגין אחר.
    packaging {
        jniLibs {
            pickFirsts += "**/libc++_shared.so"
        }
    }
}

flutter {
    source = "../.."
}
