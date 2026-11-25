package com.longmo.vivo.helper.update

import com.longmo.vivo.helper.BuildConfig
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.async
import kotlinx.coroutines.cancelChildren
import kotlinx.coroutines.selects.select
import kotlinx.coroutines.withContext
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.withTimeoutOrNull
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
    val sha256: String,
    /** 下载代理前缀，来自清单的 mirrors 字段；空则回退 [DEFAULT_DOWNLOAD_MIRRORS]。 */
    val mirrors: List<String> = emptyList()
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

    // 清单源：并发竞速，任一成功即用。这些是「种子源」，必须内置 ——
    // 因为 mirrors 配置本身就在清单里，没有种子源就拉不到远端配置。
    // 国内至少 jsDelivr / gh-proxy / ghfast 可达，实测 200。
    private val MANIFEST_URLS = listOf(
        "https://raw.githubusercontent.com/$REPO/main/update/latest.json",
        "https://cdn.jsdelivr.net/gh/$REPO@main/update/latest.json",
        "https://gh-proxy.com/https://raw.githubusercontent.com/$REPO/main/update/latest.json",
        "https://ghfast.top/https://raw.githubusercontent.com/$REPO/main/update/latest.json"
    )

    // 下载镜像兜底：仅当清单里 mirrors 字段缺失/为空时使用（兼容旧清单）。
    // 正常情况下以清单里远端配置的 mirrors 为准，节点失效改 JSON 即可，无需发版。
    private val DEFAULT_DOWNLOAD_MIRRORS = listOf(
        "https://gh-proxy.com/",
        "https://ghfast.top/"
    )

    // 下载探测：并发 HEAD 选最快可达节点，避免国内直连必等 8s 超时；
    // HEAD 全失败时回退到串行下载（兜底，兼容不支持 HEAD 的节点）。
    private const val PROBE_TIMEOUT_MS = 6_000L

    // 清单收齐窗口：并发拉各源后等这么久，取 versionCode 最大的清单。
    // 清单本身仅几百字节，多等 2~4s 换来的是「不被任何源的陈旧缓存骗成已是最新」。
    private const val MANIFEST_SETTLE_MS = 6_000L

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
        var best: ReleaseInfo? = null
        var sawNotFound = false
        var lastError: Throwable? = null
        val deadline = System.currentTimeMillis() + MANIFEST_SETTLE_MS
        try {
            // 不能「最先返回者胜」：jsDelivr 的 @main 缓存最长 12 小时，发版后它可能仍返回
            // 上一版清单，先到反而会把新版判成「已是最新」。改为在 settle 窗口内收齐各源，
            // 取 versionCode 最大者 —— 对任何源的陈旧缓存都免疫。
            while (pending.isNotEmpty()) {
                val remain = deadline - System.currentTimeMillis()
                if (remain <= 0) break
                val winner = withTimeoutOrNull(remain) {
                    select<ManifestAttempt> {
                        pending.forEach { (_, deferred) -> deferred.onAwait { it } }
                    }
                } ?: break
                pending.removeAll { it.first == winner.url }
                val info = winner.info
                if (info != null) {
                    if (info.versionCode > (best?.versionCode ?: -1)) best = info
                } else if (winner.error == null) {
                    sawNotFound = true
                } else {
                    lastError = winner.error
                }
            }
        } finally {
            coroutineContext.cancelChildren()
        }
        when {
            best != null -> best
            sawNotFound -> null
            else -> throw (lastError ?: IOException("all manifest sources failed"))
        }
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
        // mirrors 来自清单（远端可配）；缺失/类型不对时留空，下载时回退内置默认
        val mirrors = json.optJSONArray("mirrors")?.let { arr ->
            (0 until arr.length()).mapNotNull { arr.optString(it).takeIf { s -> s.isNotBlank() } }
        }.orEmpty()
        return ReleaseInfo(
            tagName = tag,
            versionName = versionName,
            versionCode = json.optInt("versionCode", 0),
            notes = json.optString("notes"),
            htmlUrl = json.optString("htmlUrl").ifEmpty { "https://github.com/$REPO/releases/tag/$tag" },
            apkName = apk,
            apkSize = json.optLong("apkSize", 0L),
            sha256 = json.optString("sha256"),
            mirrors = mirrors
        )
    }

    /**
     * 多源下载 APK 到指定文件：先用 HEAD 并发探测选最快可达源，再逐源回退；
     * 每源下载完做 SHA-256 校验（清单提供），不匹配视为该源失败换下一源。
     * [onProgress] 回调 (已下载字节, 总字节-未知为 -1)；失败/取消时清理半成品。
     */
    suspend fun downloadApk(release: ReleaseInfo, destFile: File, onProgress: suspend (Long, Long) -> Unit) =
        withContext(Dispatchers.IO) {
            // 清单里的 apk 是本地构建名（带括号），GitHub 实际资产名会把括号清洗成点
            // （v0.4.8(92) → v0.4.8.92.）；拼 URL 前做同样清洗，兼容旧清单
            val apkForUrl = release.apkName.replace("(", ".").replace(")", ".")
            val directUrl = "https://github.com/$REPO/releases/download/${release.tagName}/$apkForUrl"
            // 优先用清单里远端配置的 mirrors；旧清单无该字段时回退内置默认
            val mirrorPrefixes = release.mirrors.ifEmpty { DEFAULT_DOWNLOAD_MIRRORS }
            val sources = listOf(directUrl) + mirrorPrefixes.map { it + directUrl }

            // 并发 HEAD 探测，把最快可达的源排到最前；探测全失败则保持原顺序串行回退
            val fastest = probeFastestSource(sources)
            val ordered = if (fastest != null) listOf(fastest) + sources.filter { it != fastest } else sources

            var lastError: Exception? = null
            for (url in ordered) {
                try {
                    downloadFrom(url, release, destFile, onProgress)
                    return@withContext
                } catch (e: CancellationException) {
                    destFile.delete()
                    throw e
                } catch (e: Exception) {
                    destFile.delete()
                    lastError = IOException("${sourceLabel(url, directUrl)}: ${e.message}", e)
                }
            }
            throw lastError ?: IOException("all download sources failed")
        }

    /**
     * 并发对候选源发 HEAD，返回**最先成功**（2xx）的那个 URL。
     *
     * 目的：国内直连 github.com 几乎必失败，串行等它 8s 超时纯属浪费；
     * 先把所有源一起探活，谁快用谁。全部失败/超时返回 null，调用方走串行兜底。
     * 用独立的短超时 client，避免探测拖到读超时 30s。
     */
    private suspend fun probeFastestSource(sources: List<String>): String? =
        withContext(Dispatchers.IO) {
            val probeClient = client.newBuilder()
                .connectTimeout(PROBE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                .readTimeout(PROBE_TIMEOUT_MS, TimeUnit.MILLISECONDS)
                .build()
            val probes = sources.map { url ->
                url to async {
                    try {
                        val request = Request.Builder().url(url).head().build()
                        probeClient.newCall(request).execute().use { response ->
                            if (response.isSuccessful) url else null
                        }
                    } catch (_: Exception) {
                        null
                    }
                }
            }
            val pending = probes.toMutableList()
            try {
                while (pending.isNotEmpty()) {
                    val winner = select<Pair<String, String?>> {
                        pending.forEach { (url, deferred) -> deferred.onAwait { url to it } }
                    }
                    pending.removeAll { it.first == winner.first }
                    if (winner.second != null) return@withContext winner.second
                }
            } finally {
                coroutineContext.cancelChildren()
            }
            null
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

    /** 失败提示带具体域名，用户看到 "HTTP 502" 时知道是哪个节点挂了。 */
    private fun sourceLabel(url: String, directUrl: String): String {
        if (url == directUrl) return "直连"
        val host = try {
            java.net.URI.create(url).host ?: url
        } catch (_: Exception) {
            url
        }
        return "代理 $host"
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
