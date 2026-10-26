package com.krscripts.core.model

import android.graphics.Color
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.text.SpannableStringBuilder
import android.text.Spanned
import android.text.style.ForegroundColorSpan
import androidx.core.text.buildSpannedString
import androidx.core.text.color

/**
 * Created by Hello on 2018/04/01.
 * Refactored by buylan on 2026/07/26
 */

abstract class ShellHandlerBase : Handler(Looper.getMainLooper()) {
    protected abstract fun onProgress(current: Int, total: Int)

    protected abstract fun onStart(msg: Any?)

    abstract fun onStart(forceStop: Runnable?)

    protected abstract fun onExit(msg: Any?)

    /**
     * 输出格式化内容
     *
     * @param msg
     */
    protected abstract fun updateLog(msg: Spanned?)

    override fun handleMessage(msg: Message) {
        super.handleMessage(msg)
        when (msg.what) {
            EVENT_EXIT -> onExit(msg.obj)
            EVENT_START -> onStart(msg.obj)
            EVENT_READ -> onReaderMsg(msg.obj)
            EVENT_READ_ERROR -> onError(msg.obj)
            EVENT_WRITE -> onWrite(msg.obj)
        }
    }

    protected fun onReaderMsg(msg: Any?) {
        if (msg != null) {
            val log = msg.toString().trim()
            val match = PROGRESS_PATTERN.matchEntire(log)
            if (match != null) {
                val current = match.groupValues[1].toInt()
                val total = match.groupValues[2].toInt()
                onProgress(current, total)
            } else {
                onReader(msg)
            }
        }
    }

    protected open fun onReader(msg: Any?) {
        updateLog(msg, "#00cc55")
    }

    protected open fun onWrite(msg: Any?) {
        updateLog(msg, "#808080")
    }

    protected open fun onError(msg: Any?) {
        updateLog(msg, "#ff0000")
    }

    /**
     * 输出指定颜色的内容
     *
     * @param msg
     * @param color
     */
    protected fun updateLog(msg: Any?, color: String?) {
        if (msg != null) {
            updateLog(msg, Color.parseColor(color))
        }
    }

    protected open fun updateLog(msg: Any?, color: Int) {
        if (msg != null) {
            val msgStr = msg.toString()
            val spannedString = buildSpannedString {
                color(color) { append(msgStr) }
            }
            updateLog(spannedString)
        }
    }

    companion object {
        const val EVENT_START: Int = 0
        const val EVENT_READ: Int = 2
        const val EVENT_READ_ERROR: Int = 4
        const val EVENT_WRITE: Int = 6
        const val EVENT_EXIT: Int = -2
        private val PROGRESS_PATTERN = """^progress:\[(-?\d+)/(-?\d+)]$""".toRegex()

        // ANSI SGR 转义序列: ESC [ <数字;数字> m
        private val ANSI_SGR = Regex("""\u001B\[([0-9;]*)m""")

        // SGR 前景色码 -> Android 颜色。30-37 为标准色, 90-97 为亮色。
        private val ANSI_FG_COLORS = mapOf(
            30 to 0xFF000000.toInt(), 31 to 0xFFCC0000.toInt(), 32 to 0xFF00AA00.toInt(),
            33 to 0xFFAA8800.toInt(), 34 to 0xFF0066CC.toInt(), 35 to 0xFFAA00AA.toInt(),
            36 to 0xFF00AAAA.toInt(), 37 to 0xFF666666.toInt(),
            90 to 0xFF555555.toInt(), 91 to 0xFFFF5555.toInt(), 92 to 0xFF55FF55.toInt(),
            93 to 0xFFFFFF55.toInt(), 94 to 0xFF5599FF.toInt(), 95 to 0xFFFF55FF.toInt(),
            96 to 0xFF55FFFF.toInt(), 97 to 0xFFDDDDDD.toInt()
        )

        /**
         * 把带 ANSI 转义的一行文本转成 Spanned。
         *
         * 背景: OTA 等 shell 脚本用 `printf '\033[31m...'` 着色输出错误/警告, 但日志界面
         * 原先只按 stdout/stderr 整行染色, 不解析转义序列 —— 结果是控制字符原样进入
         * TextView(显示成乱码方块), 而红色告警并不会变红。这里补上解析。
         *
         * 规则:
         *  - 解析 ESC[<code>m, 30-37 / 90-97 设前景色, 39 / 0 复位。
         *  - 未识别的 SGR 码(如粗体 1、背景色 4x)直接丢弃, 不留控制字符。
         *  - 整行没有任何 SGR 时返回 null, 调用方沿用原有的整行着色, 行为不变。
         *
         * @param line 原始输出行 (含可能的 ANSI 转义)
         * @param defaultColor 没有任何颜色指令时的默认颜色
         * @return Spanned, 或 null 表示"无 ANSI, 用原逻辑"
         */
        fun ansiToSpanned(line: String, defaultColor: Int): Spanned? {
            if (!line.contains('\u001B')) return null

            val builder = SpannableStringBuilder()
            var last = 0
            var current = defaultColor
            var sawSgr = false

            for (match in ANSI_SGR.findAll(line)) {
                sawSgr = true
                if (match.range.first > last) {
                    appendColored(builder, line.substring(last, match.range.first), current)
                }
                val codes = match.groupValues[1]
                    .split(';')
                    .filter { it.isNotEmpty() }
                    .mapNotNull { it.toIntOrNull() }
                if (codes.isEmpty()) {
                    current = defaultColor
                } else {
                    for (code in codes) {
                        when {
                            code == 0 || code == 39 -> current = defaultColor
                            ANSI_FG_COLORS.containsKey(code) -> current = ANSI_FG_COLORS.getValue(code)
                            else -> Unit // 其它 SGR(粗体/背景色等)忽略
                        }
                    }
                }
                last = match.range.last + 1
            }

            if (!sawSgr) return null
            if (last < line.length) {
                appendColored(builder, line.substring(last), current)
            }
            return builder
        }

        private fun appendColored(builder: SpannableStringBuilder, text: String, color: Int) {
            if (text.isEmpty()) return
            val start = builder.length
            builder.append(text)
            builder.setSpan(
                ForegroundColorSpan(color), start, builder.length,
                Spanned.SPAN_EXCLUSIVE_EXCLUSIVE
            )
        }
    }
}
