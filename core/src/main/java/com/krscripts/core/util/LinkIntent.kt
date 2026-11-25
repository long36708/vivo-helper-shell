package com.krscripts.core.util

import android.content.Intent
import android.net.Uri

/**
 * 由 link 字符串构造启动 Intent，集中处理 kr-script 页面链接。
 *
 * 三个调用点（ActionListFragment.onPageClick、ListItemText 的 ClickableSpan、ActionPage）
 * 曾各自 `Intent(ACTION_VIEW, uri)`，容易漂移。统一走这里。
 *
 * tel: 暗码用 ACTION_DIAL：vivo 拨号器(com.android.contacts/.dialer.TwelveKeyDialer)
 * 只有收到 ACTION_DIAL 才把号码当暗码识别并拉起对应界面；ACTION_VIEW 只把号码
 * 填进拨号盘就停住。两种 action 解析到的是同一组件，差别在拨号器对 action 的处理。
 *
 * 注意：不要在此处解码 URI。暗码里的 %2A/%23 必须由拨号器按 intent data 解码，
 * 提前解码会让 '#' 变成 URI fragment 分隔符而截断暗码。
 */
fun linkIntent(link: String): Intent {
    val uri = Uri.parse(link)
    val action = when (uri.scheme?.lowercase()) {
        "tel" -> Intent.ACTION_DIAL
        else -> Intent.ACTION_VIEW
    }
    return Intent(action, uri)
}
