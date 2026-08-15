# Add project specific ProGuard rules here.
# By default, the flags in this file are appended to flags specified
# in F:\Android\sdk/tools/proguard/proguard-android.txt
# You can edit the include path and order by changing the proguardFiles
# directive in build.gradle.
#
# For more details, see
#   http://developer.android.com/guide/developing/tools/proguard.html

# Add any project specific keep options here:

# If your project uses WebView with JS, uncomment the following
# and specify the fully qualified class name to the JavaScript interface
# class:
#-keepclassmembers class fqcn.of.javascript.interface.for.webview {
#   public *;
#}

-keepclassmembers class * implements java.io.Serializable{*;}

# 保留 kr-script 核心模型与执行链路，避免 release 混淆破坏 app(core) 跨模块字段访问
# 例如 ConfigNode.pageHandlerSh 在 core 中赋值、在 app(MainActivity) 中读取，
# 被 R8 混淆/优化后 menuHandler 恒为空，导致所有菜单项点击不生效（debug 正常）。
-keep class com.krscripts.core.model.** { *; }
-keep class com.krscripts.core.config.PageConfigReader { *; }
-keep class com.krscripts.core.executor.ShellExecutor { *; }
-keep class com.krscripts.core.executor.ScriptEnvironment { *; }
-keep class com.krscripts.core.HiddenTaskThread { *; }
-keep class com.krscripts.core.ui.DialogLogFragment { *; }
