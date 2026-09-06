import java.util.Properties
import java.io.FileInputStream

plugins {
    alias(libs.plugins.android.application)
}

val appId = "com.longmo.vivo.helper"
val appVersionName = "0.4.0"

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

        // 广告变现：gradle.properties 可覆盖（ADMOB_APP_ID / ADMOB_APP_OPEN_ID / ADMOB_BANNER_ID）
        // 默认全部为 AdMob 官方测试 ID，发布时换成后台申请的正式 ID
        buildConfigField("boolean", "ADS_ENABLED", localProps.getProperty("ADS_ENABLED", "true"))
        buildConfigField("String", "ADMOB_APP_OPEN_ID", "\"${localProps.getProperty("ADMOB_APP_OPEN_ID", "ca-app-pub-3940256099942544/9257395921")}\"")
        buildConfigField("String", "ADMOB_BANNER_ID", "\"${localProps.getProperty("ADMOB_BANNER_ID", "ca-app-pub-3940256099942544/6300978111")}\"")
        manifestPlaceholders["admobAppId"] = localProps.getProperty("ADMOB_APP_ID", "ca-app-pub-3940256099942544~3347511713")

        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }

    buildTypes {
        release {
            // 暂时关闭混淆/资源收缩：kr-script 框架大量依赖 XML 反射解析，混淆后闪退；
            // 后续如需开启，需补齐 core 模块的 proguard keep 规则再验证
            isMinifyEnabled = false
            isShrinkResources = false
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
    implementation(libs.play.services.ads)
    implementation(project(":core"))
}
