package com.longmo.vivo.helper.ad

import android.app.Activity
import android.content.Context
import android.os.Handler
import android.os.Looper
import android.view.View
import android.view.ViewGroup
import com.google.android.gms.ads.AdError
import com.google.android.gms.ads.AdListener
import com.google.android.gms.ads.AdRequest
import com.google.android.gms.ads.AdSize
import com.google.android.gms.ads.AdView
import com.google.android.gms.ads.FullScreenContentCallback
import com.google.android.gms.ads.LoadAdError
import com.google.android.gms.ads.MobileAds
import com.google.android.gms.ads.appopen.AppOpenAd
import com.longmo.vivo.helper.BuildConfig
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * 广告源抽象：当前实现为 AdMob（个人开发者唯一可直签的主流平台）。
 * 未来注册企业主体切穿山甲/GroMore 时，新增实现并替换 AdManager.provider 即可，UI 层不动。
 */
interface AdProvider {
    fun initialize(context: Context)
    fun preloadAppOpen(context: Context)

    /**
     * 展示开屏广告。超时/加载失败/展示失败时也必须回调（shown=false），
     * 保证调用方的启动流程绝不被广告阻塞。
     */
    fun showAppOpen(activity: Activity, timeoutMs: Long, onFinished: (shown: Boolean) -> Unit)

    /** 向 container 挂载 Banner；仅在加载成功后把 container 置为可见，避免填充率低时留白 */
    fun attachBanner(activity: Activity, container: ViewGroup)
    fun detachBanner()
}

/**
 * 广告统一入口。
 * 硬约束：
 * - 必须在用户同意隐私政策后才会初始化任何广告 SDK（enabled() 的前提）。
 * - 开屏有频控（每日上限 + 最小间隔）和超时兜底，任何分支都保证回调 onDone 放行启动。
 * - BuildConfig.ADS_ENABLED=false 时全部方法均为空操作。
 */
object AdManager {

    private const val PREFS_NAME = "ad_settings"
    private const val KEY_PRIVACY_AGREED = "privacy_agreed"
    private const val KEY_APP_OPEN_SHOWN_DATE = "app_open_shown_date"
    private const val KEY_APP_OPEN_SHOWN_COUNT = "app_open_shown_count"
    private const val KEY_APP_OPEN_LAST_SHOWN_AT = "app_open_last_shown_at"

    // 频控策略：对 ROOT 玩家群体保持最保守的展示强度
    const val APP_OPEN_MAX_PER_DAY = 2
    private const val APP_OPEN_MIN_INTERVAL_MS = 6 * 60 * 60 * 1000L
    private const val APP_OPEN_TIMEOUT_MS = 3_000L

    private val provider: AdProvider = AdMobProvider()
    private var initialized = false

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun isPrivacyAgreed(context: Context): Boolean =
        prefs(context).getBoolean(KEY_PRIVACY_AGREED, false)

    fun setPrivacyAgreed(context: Context, agreed: Boolean) {
        prefs(context).edit().putBoolean(KEY_PRIVACY_AGREED, agreed).apply()
    }

    private fun enabled(context: Context): Boolean =
        BuildConfig.ADS_ENABLED && isPrivacyAgreed(context)

    fun ensureInitialized(context: Context) {
        val appContext = context.applicationContext
        if (!enabled(appContext)) return
        if (!initialized) {
            initialized = true
            provider.initialize(appContext)
        } else {
            provider.preloadAppOpen(appContext)
        }
    }

    /**
     * 展示开屏广告（含频控与超时兜底），无论展示与否都回调 onDone。
     * 调用时机：Splash 正常启动路径的最后一步、gotoHome 之前。
     * 快捷方式直达脚本页（JumpActionPage）的路径不要调用此方法。
     */
    fun showAppOpenIfEligible(activity: Activity, onDone: () -> Unit) {
        if (!enabled(activity)) {
            onDone()
            return
        }
        val prefs = prefs(activity)
        val today = SimpleDateFormat("yyyy-MM-dd", Locale.US).format(Date())
        val shownToday =
            if (prefs.getString(KEY_APP_OPEN_SHOWN_DATE, "") == today) prefs.getInt(KEY_APP_OPEN_SHOWN_COUNT, 0)
            else 0
        if (shownToday >= APP_OPEN_MAX_PER_DAY ||
            System.currentTimeMillis() - prefs.getLong(KEY_APP_OPEN_LAST_SHOWN_AT, 0L) < APP_OPEN_MIN_INTERVAL_MS
        ) {
            onDone()
            return
        }
        provider.showAppOpen(activity, APP_OPEN_TIMEOUT_MS) { shown ->
            if (shown) {
                prefs.edit()
                    .putString(KEY_APP_OPEN_SHOWN_DATE, today)
                    .putInt(KEY_APP_OPEN_SHOWN_COUNT, shownToday + 1)
                    .putLong(KEY_APP_OPEN_LAST_SHOWN_AT, System.currentTimeMillis())
                    .apply()
            }
            onDone()
        }
    }

    fun attachBanner(activity: Activity, container: ViewGroup) {
        if (!enabled(activity)) return
        provider.attachBanner(activity, container)
    }

    fun detachBanner() {
        provider.detachBanner()
    }
}

class AdMobProvider : AdProvider {

    private var appOpenAd: AppOpenAd? = null
    private var isLoadingAppOpen = false
    private var banner: AdView? = null
    private var bannerLoaded = false

    override fun initialize(context: Context) {
        // MobileAds.initialize 内部自己切线程，这里按官方示例放到 IO 协程避免阻塞主线程
        CoroutineScope(Dispatchers.IO).launch {
            MobileAds.initialize(context)
        }
        preloadAppOpen(context)
    }

    override fun preloadAppOpen(context: Context) {
        if (appOpenAd != null || isLoadingAppOpen) return
        isLoadingAppOpen = true
        AppOpenAd.load(
            context.applicationContext,
            BuildConfig.ADMOB_APP_OPEN_ID,
            AdRequest.Builder().build(),
            object : AppOpenAd.AppOpenAdLoadCallback() {
                override fun onAdLoaded(ad: AppOpenAd) {
                    appOpenAd = ad
                    isLoadingAppOpen = false
                }

                override fun onAdFailedToLoad(error: LoadAdError) {
                    appOpenAd = null
                    isLoadingAppOpen = false
                }
            }
        )
    }

    override fun showAppOpen(activity: Activity, timeoutMs: Long, onFinished: (shown: Boolean) -> Unit) {
        val ad = appOpenAd
        if (ad == null) {
            onFinished(false)
            return
        }
        appOpenAd = null // 只消费一次，无论结果如何都触发下一次预加载
        val handler = Handler(Looper.getMainLooper())
        var handled = false
        val timeoutRunnable = Runnable {
            if (!handled) {
                handled = true
                onFinished(false)
            }
        }
        handler.postDelayed(timeoutRunnable, timeoutMs)

        fun finish(shown: Boolean) {
            if (handled) return
            handled = true
            handler.removeCallbacks(timeoutRunnable)
            onFinished(shown)
            preloadAppOpen(activity)
        }

        ad.fullScreenContentCallback = object : FullScreenContentCallback() {
            override fun onAdDismissedFullScreenContent() {
                finish(true)
            }

            override fun onAdFailedToShowFullScreenContent(adError: AdError) {
                finish(false)
            }
        }
        ad.show(activity)
    }

    override fun attachBanner(activity: Activity, container: ViewGroup) {
        if (banner != null) {
            // 切页返回时恢复可见性：加载成功的重新显示，失败过的保持隐藏
            container.visibility = if (bannerLoaded) View.VISIBLE else View.GONE
            return
        }
        val adView = AdView(activity).apply {
            adUnitId = BuildConfig.ADMOB_BANNER_ID
            setAdSize(AdSize.BANNER)
            adListener = object : AdListener() {
                override fun onAdLoaded() {
                    bannerLoaded = true
                    container.visibility = View.VISIBLE
                }

                override fun onAdFailedToLoad(error: LoadAdError) {
                    bannerLoaded = false
                    container.visibility = View.GONE
                }
            }
        }
        container.addView(adView)
        banner = adView
        adView.loadAd(AdRequest.Builder().build())
    }

    override fun detachBanner() {
        banner?.let { adView ->
            (adView.parent as? ViewGroup)?.removeView(adView)
            adView.destroy()
        }
        banner = null
        bannerLoaded = false
    }
}
