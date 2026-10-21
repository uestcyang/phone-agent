import java.util.Base64

val phoneAgentDartDefines =
    (project.findProperty("dart-defines") as? String)
        ?.split(',')
        ?.mapNotNull { encoded ->
            runCatching {
                String(Base64.getDecoder().decode(encoded))
                    .split('=', limit = 2)
                    .takeIf { it.size == 2 }
                    ?.let { it[0] to it[1] }
            }.getOrNull()
        }
        ?.toMap()
        .orEmpty()

plugins {
    id("com.android.application")

    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "org.phoneagent.app"


    compileSdk = 36
    ndkVersion = flutter.ndkVersion

    packaging {
        jniLibs.useLegacyPackaging = true
        jniLibs.keepDebugSymbols += "**/libphonechisel.so"
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }


    buildFeatures {
        buildConfig = true
        aidl = true
    }

    defaultConfig {

        applicationId = "org.phoneagent.app"


        for (key in listOf("PA_BRIDGE_REMOTE", "PA_BRIDGE_EGRESS", "PA_BRIDGE_SHA256")) {
            val value = phoneAgentDartDefines[key] ?: ""
            require(!value.contains('"') && !value.contains('\\') && !value.contains('\n')) { "Invalid bridge build setting" }
            buildConfigField("String", key, "\"$value\"")
        }
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
        val publicOrigin =
            phoneAgentDartDefines["PA_PUBLIC_ORIGIN"] ?: ""
        require(publicOrigin.isEmpty() || publicOrigin.matches(Regex("https://[A-Za-z0-9.-]+"))) {
            "PA_PUBLIC_ORIGIN must be a plain HTTPS origin"
        }
        buildConfigField("String", "PA_PUBLIC_ORIGIN", "\"$publicOrigin\"")
        val backupOrigin = if (publicOrigin.isEmpty()) "" else
            phoneAgentDartDefines["PA_BACKUP_ORIGIN"] ?:
                ""
        require(backupOrigin.isEmpty() || backupOrigin.matches(Regex("https://[A-Za-z0-9.-]+(:8443)?"))) {
            "PA_BACKUP_ORIGIN must be a plain HTTPS origin on 443 or 8443"
        }
        buildConfigField("String", "PA_BACKUP_ORIGIN", "\"$backupOrigin\"")
        buildConfigField(
            "String",
            "WIDGET_SUMMARY_URL",
            "\"\"",
        )
        buildConfigField(
            "String",
            "PAI_ACK_URL",
            "\"\"",
        )
    }

    buildTypes {
        release {


            signingConfig = signingConfigs.getByName("debug")
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
    testImplementation("junit:junit:4.13.2")
    implementation("dev.rikka.shizuku:api:13.1.5")
    implementation("dev.rikka.shizuku:provider:13.1.5")


}
