package com.longmo.vivo.helper.update

import android.app.Activity
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import com.krscripts.core.shell.KeepShellPublic
import java.io.File

/**
 * APK 安装：首选 root `pm install`（本应用为 root 工具，启动时已校验 root），
 * 失败时回退系统安装器（需用户授予"安装未知应用"权限）。
 */
object UpdateInstaller {

    /** root 静默安装。注意：包被替换时本进程可能直接被杀，调用方需先展示提示再调用。 */
    fun installViaRoot(apkFile: File): Boolean {
        val output = try {
            KeepShellPublic.doCmdSync("pm install -r \"${apkFile.absolutePath}\"")
        } catch (_: Exception) {
            return false
        }
        return output.contains("Success", ignoreCase = true)
    }

    /** 调起系统安装器。返回 false 表示无 Activity 可处理（极少见）。 */
    fun launchSystemInstaller(activity: Activity, apkFile: File): Boolean {
        val uri: Uri = FileProvider.getUriForFile(
            activity, "${activity.packageName}.fileprovider", apkFile
        )
        return try {
            val intent = Intent(Intent.ACTION_INSTALL_PACKAGE).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            activity.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }
}
