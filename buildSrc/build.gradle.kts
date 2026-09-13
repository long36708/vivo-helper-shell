plugins {
    `kotlin-dsl`
}

// buildSrc 是独立的（included）构建，根 settings.gradle.kts 里的
// dependencyResolutionManagement 对它不生效，必须在这里单独声明仓库。
// 本机之所以"看起来不用声明"，是因为 ~/.gradle/init.gradle.kts 用 settingsEvaluated
// 给所有构建（含 buildSrc）注入了镜像；CI 无此文件，缺了这段会直接失败：
//   Could not resolve ... kotlin-stdlib:2.x because no repositories are defined.
repositories {
    maven("https://maven.aliyun.com/repository/public")
    mavenCentral()
    // 兜底：buildSrc 里若要引用 AGP / androidx 类型，只有 google() 有
    google()
}
