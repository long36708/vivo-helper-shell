package com.longmo.vivo.helper.update

import android.app.Dialog
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.view.LayoutInflater
import android.widget.Toast
import androidx.activity.ComponentActivity
import androidx.core.content.edit
import androidx.lifecycle.lifecycleScope
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.longmo.vivo.helper.BuildConfig
import com.longmo.vivo.helper.R
import com.longmo.vivo.helper.databinding.DialogUpdateProgressBinding
import com.krscripts.core.ui.DialogHelper
import com.krscripts.core.ui.ProgressBarDialog
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.delay
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File
import java.util.Locale

/**
 * 在线更新流程编排（GitHub Release，非强制）：
 * 启动自动检查（24h 节流、失败静默）/ 关于页手动检查 → 更新确认弹窗（可随时取消，可跳过此版本）
 * → 应用内下载（进度可取消）→ root 静默安装，失败回退系统安装器。
 */
object UpdateManager {

    private const val PREFS_NAME = "update_settings"
    private const val KEY_LAST_AUTO_CHECK = "last_auto_check_ts"
    private const val KEY_IGNORED_CODE = "ignored_version_code"
    private const val AUTO_CHECK_INTERVAL_MS = 24 * 60 * 60 * 1000L
    private const val MAX_NOTES_LEN = 1200

    /** 冷启动自动检查：节流 24h；无更新/失败/已跳过的版本一律静默返回。 */
    fun autoCheckOnStartup(activity: ComponentActivity) {
        val prefs = activity.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
        val last = prefs.getLong(KEY_LAST_AUTO_CHECK, 0L)
        if (last > 0 && System.currentTimeMillis() - last < AUTO_CHECK_INTERVAL_MS) return

        activity.lifecycleScope.launch {
            try {
                val release = UpdateChecker.fetchLatestRelease() ?: return@launch
                prefs.edit { putLong(KEY_LAST_AUTO_CHECK, System.currentTimeMillis()) }
                if (!UpdateChecker.isNewer(release)) return@launch
                // 用户点过"跳过此版本"后，同版本号的更新不再自动弹出（手动检查仍可见）
                val ignored = prefs.getInt(KEY_IGNORED_CODE, 0)
                if (release.versionCode in 1..ignored) return@launch
                showUpdateDialog(activity, release)
            } catch (_: Exception) {
                // 自动检查失败不打扰用户
            }
        }
    }

    /** 手动检查：全程有反馈（检查中 / 已最新 / 无版本 / 失败原因）。 */
    fun manualCheck(activity: ComponentActivity) {
        val loading = ProgressBarDialog(activity)
        activity.lifecycleScope.launch {
            try {
                loading.showDialog(activity.getString(R.string.update_checking))
                val release = UpdateChecker.fetchLatestRelease()
                when {
                    release == null ->
                        DialogHelper.openInfoAlert(activity, "", activity.getString(R.string.update_no_release))
                    UpdateChecker.isNewer(release) ->
                        showUpdateDialog(activity, release)
                    else ->
                        DialogHelper.openInfoAlert(
                            activity, "",
                            activity.getString(R.string.update_latest, BuildConfig.FRAMEWORK_VERSION)
                        )
                }
            } catch (e: Exception) {
                if (activity.isFinishing || activity.isDestroyed) return@launch
                DialogHelper.openInfoAlert(
                    activity, "",
                    activity.getString(R.string.update_check_failed, e.message ?: "网络异常")
                )
            } finally {
                loading.hideDialog()
            }
        }
    }

    // 非强制：弹窗可取消（返回键/点外部关闭），不记录跳过则下次自动检查仍会提醒
    private fun showUpdateDialog(activity: ComponentActivity, release: ReleaseInfo) {
        if (activity.isFinishing || activity.isDestroyed) return

        val message = buildString {
            append(
                activity.getString(
                    R.string.update_version_line,
                    BuildConfig.FRAMEWORK_VERSION, BuildConfig.BUILD_COMMIT,
                    release.versionName, release.versionCode
                )
            )
            val notes = release.notes.trim()
            if (notes.isNotEmpty()) {
                append("\n\n")
                append(if (notes.length > MAX_NOTES_LEN) notes.take(MAX_NOTES_LEN) + "…" else notes)
            }
        }

        val builder = MaterialAlertDialogBuilder(activity)
            .setTitle(activity.getString(R.string.update_available_title, release.versionName))
            .setMessage(message)
            .setCancelable(true)

        if (release.apkUrl.isEmpty()) {
            // 无 APK 资产：只给发布页出口
            builder.setPositiveButton(R.string.update_btn_view_page) { _, _ -> openReleasePage(activity, release) }
        } else {
            builder.setPositiveButton(R.string.update_btn_download) { _, _ -> downloadAndInstall(activity, release) }
            builder.setNegativeButton(R.string.update_btn_skip) { _, _ ->
                if (release.versionCode > 0) {
                    activity.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)
                        .edit { putInt(KEY_IGNORED_CODE, release.versionCode) }
                }
            }
            builder.setNeutralButton(R.string.update_btn_view_page) { _, _ -> openReleasePage(activity, release) }
        }

        DialogHelper.animDialog(activity, builder)
    }

    private fun openReleasePage(activity: ComponentActivity, release: ReleaseInfo) {
        if (release.htmlUrl.isEmpty()) return
        try {
            activity.startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(release.htmlUrl)))
        } catch (_: Exception) {
        }
    }

    private fun downloadAndInstall(activity: ComponentActivity, release: ReleaseInfo) {
        val binding = DialogUpdateProgressBinding.inflate(LayoutInflater.from(activity))
        val progressBar = binding.progressUpdate
        progressBar.isIndeterminate = true

        var downloadJob: Job? = null
        val progressDialog = DialogHelper.animDialog(
            activity,
            MaterialAlertDialogBuilder(activity)
                .setTitle(activity.getString(R.string.update_download_title, release.versionName))
                .setView(binding.root)
                .setCancelable(true)
                // 返回键/点外部关闭时同时取消下载
                .setOnCancelListener { downloadJob?.cancel() }
                .setNegativeButton(R.string.btn_cancel) { _, _ -> downloadJob?.cancel() }
        )

        val destFile = prepareUpdateFile(activity, release.versionName)

        downloadJob = activity.lifecycleScope.launch {
            try {
                UpdateChecker.downloadApk(release.apkUrl, destFile) { done, total ->
                    currentCoroutineContext().ensureActive()
                    withContext(Dispatchers.Main) {
                        if (activity.isFinishing || activity.isDestroyed) return@withContext
                        if (total > 0) {
                            progressBar.isIndeterminate = false
                            progressBar.progress = ((done * 100) / total).toInt().coerceIn(0, 100)
                            binding.tvUpdateProgress.text = String.format(
                                Locale.US, "%d%%  (%s / %s)",
                                progressBar.progress, formatBytes(done), formatBytes(total)
                            )
                        } else {
                            progressBar.isIndeterminate = true
                            binding.tvUpdateProgress.text = formatBytes(done)
                        }
                    }
                }
                installApk(activity, progressDialog, destFile)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                withContext(Dispatchers.Main) {
                    try { progressDialog.dismiss() } catch (_: Exception) {}
                    if (!activity.isFinishing && !activity.isDestroyed) {
                        DialogHelper.openInfoAlert(
                            activity, "",
                            activity.getString(R.string.update_download_failed, e.message ?: "网络异常")
                        )
                    }
                }
            }
        }
    }

    private suspend fun installApk(activity: ComponentActivity, progressDialog: Dialog, apkFile: File) {
        withContext(Dispatchers.Main) {
            try { progressDialog.dismiss() } catch (_: Exception) {}
            ProgressBarDialog(activity).showDialog(activity.getString(R.string.update_install_wait), delayMillis = 0L)
        }
        // 先给弹窗渲染留时间：pm install 成功瞬间本进程可能被杀，之后的一切都不保证执行
        delay(400)

        if (withContext(Dispatchers.IO) { UpdateInstaller.installViaRoot(apkFile) }) {
            withContext(Dispatchers.Main) {
                if (!activity.isFinishing && !activity.isDestroyed) {
                    DialogHelper.openInfoAlert(activity, "", activity.getString(R.string.update_install_done))
                }
            }
            return
        }

        // root 安装失败 → 转交系统安装器
        withContext(Dispatchers.Main) {
            val launched = UpdateInstaller.launchSystemInstaller(activity, apkFile)
            if (!activity.isFinishing && !activity.isDestroyed) {
                if (launched) {
                    Toast.makeText(activity, R.string.update_install_fallback, Toast.LENGTH_LONG).show()
                } else {
                    DialogHelper.openInfoAlert(
                        activity, "",
                        activity.getString(R.string.update_install_fallback_failed, "无可用安装器")
                    )
                }
            }
        }
    }

    /** 更新包存放目录（应用外部私有目录），每次下载前清理历史安装包。 */
    private fun prepareUpdateFile(activity: ComponentActivity, versionName: String): File {
        val dir = activity.getExternalFilesDir("update")
            ?: File(activity.filesDir, "update").apply { mkdirs() }
        dir.listFiles()?.forEach { if (it.isFile && it.name.endsWith(".apk")) it.delete() }
        return File(dir, "vivo-helper-$versionName.apk")
    }

    private fun formatBytes(bytes: Long): String = when {
        bytes >= 1L shl 20 -> String.format(Locale.US, "%.1f MB", bytes / 1048576.0)
        bytes >= 1L shl 10 -> String.format(Locale.US, "%.0f KB", bytes / 1024.0)
        else -> "$bytes B"
    }
}
