package com.longmo.vivo.helper.update

import com.longmo.vivo.helper.BuildConfig
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.concurrent.TimeUnit

data class ReleaseInfo(
    val tagName: String,
    val versionName: String,
    val versionCode: Int,
    val notes: String,
    val htmlUrl: String,
    val apkUrl: String,
    val apkName: String,
    val apkSize: Long
)

/**
 * GitHub Release 在线更新检测。
 *
 * 版本比较策略：以资产文件名解析出的 versionCode（= git 提交数，单调递增）为主比较键，
 * versionName 是 build.gradle.kts 里的手工变量，忘 bump 时 semver 相等会漏报；
 * 资产名解析失败时才回退 semver 比较（tag vs FRAMEWORK_VERSION）。
 */
object UpdateChecker {

    private const val RELEASE_API = "https://api.github.com/repos/long36708/vivo-helper-shell/releases/latest"

    // com.longmo.vivo.helper-v0.4.6(84)-release.apk -> ("0.4.6", 84)
    private val ASSET_VERSION_REGEX = Regex("""v(\d+(?:\.\d+)+)\((\d+)\)""")

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(10, TimeUnit.SECONDS)
            .readTimeout(15, TimeUnit.SECONDS)
            .build()
    }

    /**
     * 拉取最新正式 Release（GitHub 自动排除 draft / prerelease）。
     * 网络失败抛 [IOException]；仓库尚无任何 Release（404）返回 null。
     */
    suspend fun fetchLatestRelease(): ReleaseInfo? = withContext(Dispatchers.IO) {
        val request = Request.Builder()
            .url(RELEASE_API)
            .header("Accept", "application/vnd.github+json")
            .build()

        client.newCall(request).execute().use { response ->
            when {
                response.isSuccessful -> parseRelease(response.body!!.string())
                response.code == 404 -> null
                else -> throw IOException("HTTP ${response.code}")
            }
        }
    }

    /**
     * 流式下载 APK 到指定文件，[onProgress] 回调 (已下载字节, 总字节-未知为 -1)。
     * 失败/协程取消时删除半成品文件；由调用方在 onProgress 中 ensureActive() 实现取消响应。
     */
    suspend fun downloadApk(url: String, destFile: File, onProgress: suspend (Long, Long) -> Unit) =
        withContext(Dispatchers.IO) {
            try {
                val request = Request.Builder().url(url).build()
                client.newCall(request).execute().use { response ->
                    if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
                    val source = response.body!!.byteStream()
                    val total = response.body!!.contentLength()

                    destFile.parentFile?.mkdirs()
                    if (destFile.exists()) destFile.delete()

                    source.use { input ->
                        destFile.outputStream().use { output ->
                            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                            var downloaded = 0L
                            var lastNotify = 0L
                            while (true) {
                                val read = input.read(buffer)
                                if (read == -1) break
                                output.write(buffer, 0, read)
                                downloaded += read
                                if (downloaded > MAX_APK_BYTES) throw IOException("exceeds size limit")
                                // 进度回调限频，避免刷爆主线程消息队列
                                if (downloaded - lastNotify >= PROGRESS_STEP) {
                                    lastNotify = downloaded
                                    onProgress(downloaded, total)
                                }
                            }
                            onProgress(downloaded, total)
                        }
                    }
                    if (destFile.length() <= 0L) throw IOException("empty file")
                }
            } catch (e: Exception) {
                destFile.delete()
                throw e
            }
        }

    private fun parseRelease(body: String): ReleaseInfo? {
        val json = JSONObject(body)
        val (assetUrl, assetName, assetSize) = pickApkAsset(json.optJSONArray("assets") ?: JSONArray())
            ?: return ReleaseInfo(
                tagName = json.optString("tag_name"),
                versionName = parseTagVersion(json.optString("tag_name")),
                versionCode = 0,
                notes = json.optString("body"),
                htmlUrl = json.optString("html_url"),
                apkUrl = "",
                apkName = "",
                apkSize = 0L
            )

        val assetVersion = parseAssetVersion(assetName)
        return ReleaseInfo(
            tagName = json.optString("tag_name"),
            versionName = assetVersion?.first ?: parseTagVersion(json.optString("tag_name")),
            versionCode = assetVersion?.second ?: 0,
            notes = json.optString("body"),
            htmlUrl = json.optString("html_url"),
            apkUrl = assetUrl,
            apkName = assetName,
            apkSize = assetSize
        )
    }

    /** 优先取 `-release.apk` 结尾的资产（CI 命名约定），否则兜底任意 .apk。 */
    fun pickApkAsset(assets: JSONArray): Triple<String, String, Long>? {
        var fallback: Triple<String, String, Long>? = null
        for (i in 0 until assets.length()) {
            val asset = assets.getJSONObject(i)
            val name = asset.optString("name")
            if (!name.endsWith(".apk", ignoreCase = true)) continue
            val triple = Triple(
                asset.optString("browser_download_url"),
                name,
                asset.optLong("size", 0L)
            )
            if (name.endsWith("-release.apk", ignoreCase = true)) return triple
            if (fallback == null) fallback = triple
        }
        return fallback
    }

    /** 资产名 -> (versionName, versionCode)，不符合命名约定返回 null。 */
    fun parseAssetVersion(assetName: String): Pair<String, Int>? {
        val m = ASSET_VERSION_REGEX.find(assetName) ?: return null
        val versionCode = m.groupValues[2].toIntOrNull() ?: return null
        return m.groupValues[1] to versionCode
    }

    private fun parseTagVersion(tag: String): String = tag.removePrefix("v").removePrefix("V")

    /** 有新版本判定：versionCode 严格大于当前值为主；无法取得时回退 semver。 */
    fun isNewer(release: ReleaseInfo): Boolean {
        if (release.versionCode > 0) {
            return release.versionCode > BuildConfig.BUILD_COMMIT
        }
        return compareSemver(release.versionName, BuildConfig.FRAMEWORK_VERSION) > 0
    }

    /** >0 表示 a 更新，<0 表示 b 更新，0 相等；缺失段按 0 处理。 */
    fun compareSemver(a: String, b: String): Int {
        val pa = parseSemver(a)
        val pb = parseSemver(b)
        for (i in 0 until maxOf(pa.size, pb.size)) {
            val va = pa.getOrElse(i) { 0 }
            val vb = pb.getOrElse(i) { 0 }
            if (va != vb) return va.compareTo(vb)
        }
        return 0
    }

    private fun parseSemver(version: String): List<Int> =
        version.removePrefix("v").removePrefix("V")
            .substringBefore('-').substringBefore('+')
            .split('.').map { it.toIntOrNull() ?: 0 }

    // 体积保护：异常大的响应（CDN 异常/配错地址）直接中止，避免刷爆存储
    private const val MAX_APK_BYTES = 300L * 1024 * 1024
    private const val PROGRESS_STEP = 256L * 1024
}
