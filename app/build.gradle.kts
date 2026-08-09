plugins {
    alias(libs.plugins.android.application)
}

val appId = "com.longmo.vivo.helper.shell.app"
val appVersionName = "0.1.0"

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

    defaultConfig {
        applicationId = appId
        minSdk = 23
        targetSdk = 37
        versionCode = gitCommitCount()
        versionName = appVersionName
        buildConfigField("String", "FRAMEWORK_VERSION", "\"$appVersionName\"")

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
            signingConfig = signingConfigs.getByName("debug")
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
