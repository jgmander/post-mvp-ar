import java.util.Properties
import java.io.FileInputStream
import java.util.Base64

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
    id("com.google.gms.google-services")
}

android {
    namespace = "com.post.spatial"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    val localProperties = Properties()
    val localPropertiesFile = rootProject.file("local.properties")
    if (localPropertiesFile.exists()) {
        localPropertiesFile.inputStream().use { stream ->
            localProperties.load(stream)
        }
    }

    // Extract variables passed via --dart-define
    val dartEnvironmentVariables = mutableMapOf<String, String>()
    if (project.hasProperty("dart-defines")) {
        val dartDefines = project.property("dart-defines") as String
        dartDefines.split(",").forEach {
            val decoded = String(Base64.getDecoder().decode(it))
            val parts = decoded.split("=")
            if (parts.size == 2) {
                dartEnvironmentVariables[parts[0]] = parts[1]
            }
        }
    }

    // CI/CD Keystore environment variables
    val ciKeystoreFile = rootProject.file("app/key.jks")
    val ciKeystorePassword = System.getenv("KEYSTORE_PASSWORD")
    val ciKeyAlias = System.getenv("KEY_ALIAS")
    val ciKeyPassword = System.getenv("KEY_PASSWORD")

    val mapsApiKey = dartEnvironmentVariables["MAPS_API_KEY"] ?: localProperties.getProperty("MAPS_API_KEY") ?: ""
    val mapId = dartEnvironmentVariables["MAP_ID"] ?: localProperties.getProperty("MAP_ID") ?: ""

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.post.spatial"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = 24
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        manifestPlaceholders["MAPS_API_KEY"] = mapsApiKey
        manifestPlaceholders["MAP_ID"] = mapId
    }

    signingConfigs {
        create("release") {
            if (ciKeystorePassword != null) {
                storeFile = ciKeystoreFile
                storePassword = ciKeystorePassword
                keyAlias = ciKeyAlias
                keyPassword = ciKeyPassword
            } else {
                // Fallback to debug keystore if building release locally without CI
                storeFile = signingConfigs.getByName("debug").storeFile
                storePassword = signingConfigs.getByName("debug").storePassword
                keyAlias = signingConfigs.getByName("debug").keyAlias
                keyPassword = signingConfigs.getByName("debug").keyPassword
            }
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig = signingConfigs.getByName("release")
        }
    }
}

flutter {
    source = "../.."
}

dependencies {
    implementation("com.google.android.gms:play-services-location:21.0.1")
    implementation("com.google.ar:core:1.41.0")
}
