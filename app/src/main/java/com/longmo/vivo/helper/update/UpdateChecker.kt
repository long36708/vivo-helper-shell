package com.longmo.vivo.helper.update

import com.longmo.vivo.helper.BuildConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import okhttp3.OkHttpClient
import okhttp3.Request
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.security.MessageDigest
import java.util.concurrent.TimeUnit

data class ReleaseInfo(
    val tagName: String,
    val versionName: String,
    val versionCode: Int,
    val notes: String,
    val htmlUrl: String,
    val apkName: String,
    val apkSize: Long,
    val sha256: String
)

/**
 * GitHub Release 在线更新检测与下载。
 *
 * 国内直连 GitHub 常不可达，且 gh-proxy 类加速**不代理 api.github.com**，
 * 因此检测不走 Release API，改为读仓库内清单 `update/latest.json`
 * （发版时由 CI 生成，仓库文件可被 raw / jsDelivr / gh-proxy 全部代理）。
 *
 * 版本比较策略：以清单里的 versionCode（= git 提交数，单调递增）为主比较键，
 * versionName 是 build.gradle.kts 里的手工变量，忘 bump 时 semver 相等会漏报；
 * 清单异常时才回退 semver 比较（tag vs FRAMEWORK_VERSION）。
 */
object UpdateChecker {

    // ===== 加速源配置（节点失效时只改这里）=====
    private const val REPO = "long36708/vivo-helper-shell"

    // 清单源：并发竞速，任一成功即用。raw 直连对海外最快，jsDelivr / gh-proxy 供国内回退
    private val MANIFEST_URLS = listOf(
        "https://raw.githubusercontent.com/$REPO/main/update/latest.json",
        "https://cdn.jsdelivr.net/gh/$REPO@main/update/latest.json",
        "https://gh-proxy.com/https://raw.githubusercontent.com/$REPO/main/update/latest.json",
        "https://ghfast.top/https://raw.githubusercontent.com/$REPO/main/update/latest.json"
    )

    // 下载镜像：在原始资产 URL 前加前缀（gh-proxy 系支持 releases/download）
    private val DOWNLOAD_MIRRORS = listOf(
        "https://gh-proxy.com/",
        "https://ghfast.top/"
    )

    private val client: OkHttpClient by lazy {
        OkHttpClient.Builder()
            .connectTimeout(8, TimeUnit.SECONDS)
            .readTimeout(30, TimeUnit.SECONDS)
            .build()
    }

    /**
     * 拉取最新版本清单：4 个源并发竞速取最先成功者，避免串行等待多次超时。
     * 所有源都报「404」返回 null（清单尚未生成）；网络错误抛 [IOException]。
     */
    suspend fun fetchLatestRelease(): ReleaseInfo? = withContext(Dispatchers.IO) {
        val attempts = MANIFEST_URLS.map { url ->
            url to async {
                try {
                    ManifestAttempt(url, fetchManifest(url), null)
                } catch (e: Exception) {
                    ManifestAttempt(url, null, e)
                }
            }
        }
        val pending = attempts.toMutableList()
        var sawNotFound = false
        var lastError: Throwable? = null
        try {
            while (pending.isNotEmpty()) {
                val winner = select<ManifestAttempt> {
                    pending.forEach { (_, deferred) -> deferred.onAwait { it } }
                }
                pending.removeAll { it.first == winner.url }
                winner.info?.let {
                    return@withContext it
                }
                if (winner.error == null) sawNotFound = true else lastError = winner.error
            }
        } finally {
            coroutineContext.cancelChildren()
        }
        if (sawNotFound) null else throw (lastError ?: IOException("all manifest sources failed"))
    }

    private class ManifestAttempt(val url: String, val info: ReleaseInfo?, val error: Throwable?)

    private suspend fun fetchManifest(url: String): ReleaseInfo? = withContext(Dispatchers.IO) {
        withTimeout(12_000) {
            val request = Request.Builder().url(url).build()
            client.newCall(request).execute().use { response ->
                if (response.code == 404) return@withTimeout null
                if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
                parseManifest(response.body!!.string())
            }
        }
    }

    /** 严格解析：字段缺失/类型不对都当该源失败，防止镜像返回错误页被当清单用。 */
    private fun parseManifest(body: String): ReleaseInfo {
        val json = JSONObject(body)
        val tag = json.optString("tag")
        val versionName = json.optString("versionName")
        val apk = json.optString("apk")
        if (tag.isEmpty() || versionName.isEmpty() || apk.isEmpty()) {
            throw IOException("manifest fields missing")
        }
        return ReleaseInfo(
            tagName = tag,
            versionName = versionName,
            versionCode = json.optInt("versionCode", 0),
            notes = json.optString("notes"),
            htmlUrl = json.optString("htmlUrl").ifEmpty { "https://github.com/$REPO/releases/tag/$tag" },
            apkName = apk,
            apkSize = json.optLong("apkSize", 0L),
            sha256 = json.optString("sha256")
        )
    }

    /**
     * 多源下载 APK 到指定文件：直连 → 各镜像前缀，逐源尝试；
     * 每源下载完做 SHA-256 校验（清单提供），不匹配视为该源失败换下一源。
     * [onProgress] 回调 (已下载字节, 总字节-未知为 -1)；失败/取消时清理半成品。
     */
    suspend fun downloadApk(release: ReleaseInfo, destFile: File, onProgress: suspend (Long, Long) -> Unit) =
        withContext(Dispatchers.IO) {
            val directUrl = "https://github.com/$REPO/releases/download/${release.tagName}/${release.apkName}"
            val sources = listOf(directUrl) + DOWNLOAD_MIRRORS.map { it + directUrl }

            var lastError: Exception? = null
            for ((index, url) in sources.withIndex()) {
                try {
                    downloadFrom(url, release, destFile, onProgress)
                    return@withContext
                } catch (e: CancellationException) {
                    destFile.delete()
                    throw e
                } catch (e: Exception) {
                    destFile.delete()
                    lastError = IOException("${sourceLabel(index)}: ${e.message}", e)
                }
            }
            throw lastError ?: IOException("all download sources failed")
        }

    private suspend fun downloadFrom(
        url: String,
        release: ReleaseInfo,
        destFile: File,
        onProgress: suspend (Long, Long) -> Unit
    ) = withContext(Dispatchers.IO) {
        val request = Request.Builder().url(url).build()
        client.newCall(request).execute().use { response ->
            if (!response.isSuccessful) throw IOException("HTTP ${response.code}")
            val source = response.body!!.byteStream()
            val total = response.body!!.contentLength().takeIf { it > 0 } ?: release.apkSize

            destFile.parentFile?.mkdirs()
            if (destFile.exists()) destFile.delete()

            val digest = MessageDigest.getInstance("SHA-256")
            source.use { input ->
                destFile.outputStream().use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    var downloaded = 0L
                    var lastNotify = 0L
                    while (true) {
                        val read = input.read(buffer)
                        if (read == -1) break
                        output.write(buffer, 0, read)
                        digest.update(buffer, 0, read)
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

            val actual = digest.digest().joinToString("") { "%02x".format(it) }
            if (release.sha256.isNotEmpty() && !actual.equals(release.sha256, ignoreCase = true)) {
                throw IOException("sha256 mismatch")
            }
        }
    }

    private fun sourceLabel(index: Int): String = when (index) {
        0 -> "直连"
        else -> "加速源$index"
    }

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
