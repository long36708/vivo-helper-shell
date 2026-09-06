package com.longmo.vivo.helper

import android.annotation.SuppressLint
import android.app.Activity
import android.app.Dialog
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.net.Uri
import android.widget.TextView
import androidx.activity.ComponentActivity
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.edit
import androidx.lifecycle.lifecycleScope
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.longmo.vivo.helper.ad.AdManager
import com.longmo.vivo.helper.databinding.ActivitySplashBinding
import com.krscripts.core.executor.ScriptEnvironment
import com.krscripts.core.shell.KeepShellPublic
import com.krscripts.core.shell.ShellExecutor
import com.krscripts.core.ui.DialogHelper
import com.krscripts.core.util.PermissionUtil.checkAccessFiles
import com.krscripts.core.util.PermissionUtil.requestAccessFilesDialog
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.DataOutputStream
import java.io.IOException
import kotlin.coroutines.resume

@SuppressLint("CustomSplashScreen")
class SplashActivity : ComponentActivity() {

    lateinit var binding: ActivitySplashBinding
    private var logs = ArrayList<String>()
    private var isRoot: Boolean? = null
    private val manageFileRequester = registerForActivityResult(ActivityResultContracts.StartActivityForResult()) {
        checkFileManage { startToFinish() }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        if (ScriptEnvironment.isInitialed) {
            if (isTaskRoot) {
                gotoHome()
            }
            return
        }

        binding = ActivitySplashBinding.inflate(layoutInflater)
        setContentView(binding.root)
        enableEdgeToEdge()

        // 合规硬要求：隐私政策同意弹窗必须先于一切广告 SDK 初始化；
        // 未同意前照常走启动流程，只是完全不初始化广告。
        if (!AdManager.isPrivacyAgreed(this)) {
            showPrivacyConsentDialog()
        } else {
            proceedStartup()
        }
    }

    private fun proceedStartup() {
        AdManager.ensureInitialized(this)
        checkPermissions()
    }

    private fun showPrivacyConsentDialog() {
        val builder = MaterialAlertDialogBuilder(this)
            .setTitle(getString(R.string.privacy_consent_title))
            .setMessage(getString(R.string.privacy_consent_message))
            .setCancelable(false)
            .setPositiveButton(getString(R.string.privacy_agree)) { dialog, _ ->
                dialog.dismiss()
                AdManager.setPrivacyAgreed(this, true)
                proceedStartup()
            }
            .setNegativeButton(getString(R.string.privacy_disagree)) { dialog, _ ->
                dialog.dismiss()
                // 不同意则不初始化广告 SDK，应用功能不受影响；下次冷启动会再次询问
                AdManager.setPrivacyAgreed(this, false)
                proceedStartup()
            }
            .setNeutralButton(getString(R.string.privacy_view_policy)) { _, _ ->
                startActivity(Intent(Intent.ACTION_VIEW, Uri.parse(getString(R.string.privacy_policy_url))))
                // 返回后重新弹出，等待用户做出选择
                binding.root.post { showPrivacyConsentDialog() }
            }
        DialogHelper.animDialog(this, builder)
    }

    private fun checkPermissions() {
        binding.startStateText.text = getString(R.string.pio_permission_checking)
        lifecycleScope.launch {
            checkRoot {
                withContext(Dispatchers.Main) {
                    checkFileManage {
                        startToFinish()
                    }
                }
            }
        }
    }

    private fun checkFileManage(next: () -> Unit) {
        if (!checkAccessFiles(this)) {
            requestAccessFilesDialog(this@SplashActivity, manageFileRequester) {
                next()
            }
        } else {
            next()
        }
    }

    private suspend fun checkRoot(next: suspend () -> Unit) {
        withContext(Dispatchers.IO) {
            while (true) {
                isRoot = KeepShellPublic.checkRoot()
                if (isRoot == true) {
                    next()
                    return@withContext
                } else {
                    val shouldRetry = suspendCancellableCoroutine { continuation ->
                        lifecycleScope.launch {
                            val dialog = requestRoot(
                                this@SplashActivity,
                                onRetry = {
                                    continuation.resume(true)
                                },
                                onSkip = {
                                    continuation.resume(false)
                                }
                            )
                            continuation.invokeOnCancellation {
                                dialog?.dismiss()
                            }
                        }
                    }

                    if (!shouldRetry) {
                        next()
                        return@withContext
                    }
                }
            }
        }
    }

    private fun startToFinish() {
        val config = KrScriptConfig().init(this)
        lifecycleScope.launch {
            if (config.beforeStartSh.isNotEmpty()) {
                runBeforeStart(this@SplashActivity, config) { log ->
                    onLogOutput(binding.startStateText, log)
                }
            } else {
                binding.startStateText.text = getString(R.string.pop_started)
            }
            if (intent.getBooleanExtra("JumpActionPage", false)) {
                // 快捷方式直达脚本页：不插广告，避免打断脚本执行
                gotoHome()
            } else {
                // 正常启动：开屏广告有频控与超时兜底，未展示/失败时直接放行
                AdManager.showAppOpenIfEligible(this@SplashActivity) { gotoHome() }
            }
        }

    }

    private fun gotoHome() {
        if (intent.getBooleanExtra("JumpActionPage", false)) {
            val actionPage = Intent(applicationContext, ActionPage::class.java)
            actionPage.putExtras(intent)
            startActivity(actionPage)
        } else {
            val home = Intent(applicationContext, MainActivity::class.java)
            startActivity(home)
        }
        finish()
    }

    suspend fun onLogOutput(
        logView: TextView,
        log: String
    ) {
        withContext(Dispatchers.Main) {
            synchronized(logs) {
                val ignore = logs.size > 6
                if (ignore) {
                    logs.removeFirstOrNull()
                }
                logs.add(log)
                logView.text = logs.joinToString("\n", if (ignore) "……\n" else "").trim()
            }
        }
    }

    private suspend fun runBeforeStart(
        context: Context,
        config: KrScriptConfig,
        onLog: suspend (String) -> Unit
    ) {
        withContext(Dispatchers.IO) {
            var process: Process? = null
            try {
                process = if (isRoot == true) ShellExecutor.superUserRuntime else ShellExecutor.runtime

                DataOutputStream(process.outputStream).use { outputStream ->
                    ScriptEnvironment.executeShell(
                        context,
                        outputStream,
                        config.beforeStartSh,
                        config.variables,
                        null,
                        "splash"
                    )
                }

                coroutineScope {
                    launch(Dispatchers.IO) {
                        process.inputStream.bufferedReader().useLines { lines ->
                            lines.forEach { onLog(it) }
                        }
                    }
                    launch(Dispatchers.IO) {
                        process.errorStream.bufferedReader().useLines { lines ->
                            lines.forEach { onLog(it) }
                        }
                    }
                    withContext(Dispatchers.IO) {
                        process.waitFor()
                    }
                }
            } catch (e: IOException) {
                onLog(e.localizedMessage ?: "beforeStart failed")
            } finally {
                process?.destroy()
            }
        }
    }

    private fun requestRoot(
        context: Context,
        onRetry: () -> Unit,
        onSkip: () -> Unit
    ): Dialog? {
        val prefs = context.getSharedPreferences("app_settings", MODE_PRIVATE)
        val hasSkipped = prefs.getBoolean("skip_root", false)
        if (hasSkipped) {
            onSkip()
            return null
        }

        val builder = MaterialAlertDialogBuilder(context)
            .setTitle(context.getString(R.string.error_root_title))
            .setCancelable(false)
            .setMessage(R.string.error_root_message)
            .setPositiveButton(R.string.btn_retry) { dialog, _ ->
                dialog.dismiss()
                onRetry()
            }
            .setNegativeButton(R.string.btn_exit) { dialog, _ ->
                dialog.dismiss()
                (context as? Activity)?.finishAffinity()
            }
        if (!context.resources.getBoolean(R.bool.force_root)) {
            builder.setNeutralButton(com.krscripts.core.R.string.btn_skip) { dialog, _ ->
                dialog.dismiss()
                prefs.edit { putBoolean("skip_root", true) }
                onSkip()
            }
        }
        return DialogHelper.animDialog(context, builder)
    }
}