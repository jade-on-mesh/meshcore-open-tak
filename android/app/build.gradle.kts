import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
if (keystorePropertiesFile.exists()) {
    keystorePropertiesFile.inputStream().use { keystoreProperties.load(it) }
}

android {
    namespace = "com.meshcore.meshcore_open"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "29.0.14206865"

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
        isCoreLibraryDesugaringEnabled = true
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        // VOX uses its own id so it installs alongside upstream MeshCore Open.
        applicationId = "com.jadeonmesh.meshcore_open_vox"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        // Codec2 (LGPL-2.1) built as libcodec2.so for VOX voice messages.
        externalNativeBuild {
            cmake {
                arguments += listOf("-DANDROID_STL=c++_shared")
            }
        }
        // arm64-v8a only, deliberately.
        //
        //  * ONNX Runtime (flutter_onnxruntime, used by the AEIC-SE image codec)
        //    ships a per-ABI .so. arm64-v8a alone costs ~18 MB of APK; a
        //    universal APK carrying armeabi-v7a and x86_64 as well costs ~56 MB.
        //  * llamadart only declares android-arm64 and android-x64 backends in
        //    pubspec.yaml's `hooks.user_defines`, so an armeabi-v7a build already
        //    has no translation backend at all.
        //  * The image codec needs ~2.7 GiB peak resident, which no 32-bit
        //    address space can provide regardless of ABI.
        //
        // Consequence: this APK will not install on 32-bit-only ARM devices or on
        // x86_64 emulators. For emulator work, temporarily add "x86_64" here.
        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    packaging {
        jniLibs {
            // Plugin AARs (ONNX Runtime, ML Kit) bring every ABI along even
            // with abiFilters set; keep only arm64-v8a, as described above.
            excludes += listOf(
                "lib/x86_64/**",
                "lib/x86/**",
                "lib/armeabi-v7a/**",
                "lib/armeabi/**",
            )
            // Compress native libraries: a far smaller APK to download and
            // sideload, at the cost of extracting them once at install.
            useLegacyPackaging = true
        }
    }

    signingConfigs {
        create("release") {
            val storeFilePath = keystoreProperties["storeFile"] as String?
            if (storeFilePath != null) {
                storeFile = file(storeFilePath)
                storePassword = keystoreProperties["storePassword"] as String?
                keyAlias = keystoreProperties["keyAlias"] as String?
                keyPassword = keystoreProperties["keyPassword"] as String?
            }
        }
    }

    buildTypes {
        release {
            signingConfig = if (keystorePropertiesFile.exists()) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
            // ONNX Runtime resolves its Java classes from native code by name.
            // Without these rules R8 renames them and the process SIGABRTs with
            // "java_class == null" the instant the codec runs a model.
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro",
            )
        }
    }

    // Codec2 native build for VOX voice messages (third_party/codec2).
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    coreLibraryDesugaring("com.android.tools:desugar_jdk_libs:2.1.4")
}
