import java.net.URI

import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val localProperties = Properties()
val localPropertiesFile = rootProject.file("local.properties")
if (localPropertiesFile.exists()) {
    localPropertiesFile.inputStream().use { localProperties.load(it) }
}

val flutterVersionCode = localProperties.getProperty("flutter.versionCode") ?: "1"
val flutterVersionName = localProperties.getProperty("flutter.versionName") ?: "1.0"

android {
    namespace = "dev.flutterberlin.flutter_gemma_example"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = "27.0.12077973"

    aaptOptions {
        noCompress("tflite", "safetensors", "bin", "model", "task")
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "dev.flutterberlin.flutter_gemma_example"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = 34
        versionCode = flutterVersionCode.toInt()
        versionName = flutterVersionName
    }

    buildTypes {
        release {
            // TODO: Add your own signing config for the release build.
            // Signing with the debug keys for now, so `flutter run --release` works.
            signingConfig = signingConfigs.getByName("debug")
            // Enable minification but with basic rules only
            isMinifyEnabled = true
            isShrinkResources = false  // Disable resource shrinking to avoid MediaPipe issues
            proguardFiles(getDefaultProguardFile("proguard-android.txt"), "proguard-rules.pro")
        }
    }
}

flutter {
    source = "../.."
}

// ---------------------------------------------------------------------------
// Download x86_64 native libraries that are missing from localagents-rag AAR.
// Google publishes them separately at:
//   https://storage.googleapis.com/mediapipe-assets/rag_pipeline/x86_64/
// This task runs automatically before mergeDebugNativeLibs / mergeReleaseNativeLibs.
// ---------------------------------------------------------------------------
val ragX86Libs = listOf(
    "libgemma_embedding_model_jni.so",
    "libgecko_embedding_model_jni.so",
    "libsqlite_vector_store_jni.so",
    "libtext_chunker_jni.so",
)

val downloadRagX86NativeLibs by tasks.registering {
    val outDir = file("src/main/jniLibs/x86_64")
    outputs.dir(outDir)

    doLast {
        outDir.mkdirs()
        ragX86Libs.forEach { lib ->
            val target = File(outDir, lib)
            if (!target.exists()) {
                val url = "https://storage.googleapis.com/mediapipe-assets/rag_pipeline/x86_64/$lib"
                logger.lifecycle("Downloading $lib ...")
                URI(url).toURL().openStream().use { input ->
                    target.outputStream().use { output -> input.copyTo(output) }
                }
                logger.lifecycle("  → ${target.length() / 1024}KB")
            } else {
                logger.lifecycle("$lib already present, skipping.")
            }
        }
    }
}

// Hook into the build: run before native libs are merged into the APK
afterEvaluate {
    tasks.matching { it.name.matches(Regex("merge(Debug|Release|Profile)(NativeLibs|JniLibFolders)")) }.configureEach {
        dependsOn(downloadRagX86NativeLibs)
    }
}

dependencies {}
