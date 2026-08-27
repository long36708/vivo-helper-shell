import java.util.Properties
import java.io.FileInputStream

plugins {
    alias(libs.plugins.android.application)
}

val appId = "com.longmo.vivo.helper"
val appVersionName = "0.3.3"

fun gitCommitCount(): Int {
    return providers.exec {
        commandLine("git", "rev-list", "--count", "HEAD")
    }.standardOutput.asText.get().trim().toIntOrNull() ?: 1
}

android {
    namespace = appId
    compileSdk {
        version = release(37)
    }

    val localProps = Properties().apply {
        val localFile = rootProject.file("local.properties")
        if (localFile.exists()) {
            FileInputStream(localFile).use { load(it) }
        }
    }
    val cfgKeystorePath: String? = localProps.getProperty("KEYSTORE_PATH")
    val cfgKeystorePass: String? = localProps.getProperty("KEYSTORE_PASS")
    val cfgKeyAlias: String? = localProps.getProperty("KEY_ALIAS")
    val cfgKeyPassword: String? = localProps.getProperty("KEY_PASSWORD")

    if (cfgKeystorePath != null && cfgKeystorePass != null && cfgKeyAlias != null && cfgKeyPassword != null) {
        signingConfigs {
            create("release") {
                storeFile = rootProject.file(cfgKeystorePath)
                storePassword = cfgKeystorePass
                keyAlias = cfgKeyAlias
                keyPassword = cfgKeyPassword
            }
        }
    }

    defaultConfig {
        applicationId = appId
        minSdk = 23
        targetSdk = 37
        versionCode = gitCommitCount()
        versionName = appVersionName
        buildConfigField("String", "FRAMEWORK_VERSION", "\"$appVersionName\"")
        buildConfigField("int", "BUILD_COMMIT", gitCommitCount().toString())

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(
                getDefaultProguardFile("proguard-android-optimize.txt"),
                "proguard-rules.pro"
            )
            signingConfig = signingConfigs.findByName("release")
                ?: signingConfigs.getByName("debug")
        }
    }

    buildFeatures {
        viewBinding = true
        buildConfig = true
    }

    androidComponents {
        onVariants(selector().all()) { variant ->
            val baseName = "${appId}-v${appVersionName}(${gitCommitCount()})"
            variant.outputs.forEach { output ->
                (output as com.android.build.api.variant.impl.VariantOutputImpl).outputFileName =
                    "$baseName-${variant.name}.apk"
            }
        }
    }
}

dependencies {
    implementation(libs.androidx.appcompat)
    implementation(libs.androidx.constraintlayout)
    implementation(libs.material)
    implementation(project(":core"))
}
