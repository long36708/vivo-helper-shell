package com.longmo.vivo.helper

import android.content.ComponentName
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.view.LayoutInflater
import android.view.View
import android.view.Menu
import android.view.MenuItem
import android.text.SpannableString
import android.text.Spanned
import android.text.style.UnderlineSpan
import android.widget.TextView
import androidx.activity.enableEdgeToEdge
import androidx.core.content.ContextCompat
import androidx.core.view.ViewCompat
import androidx.core.view.WindowInsetsCompat
import androidx.core.view.get
import androidx.fragment.app.Fragment
import androidx.fragment.app.FragmentActivity
import androidx.appcompat.app.AlertDialog
import androidx.lifecycle.lifecycleScope
import androidx.viewpager2.adapter.FragmentStateAdapter
import androidx.viewpager2.widget.ViewPager2
import com.google.android.material.dialog.MaterialAlertDialogBuilder
import com.longmo.vivo.helper.databinding.ActivityMainBinding
import com.longmo.vivo.helper.util.chooseFilePath
import com.krscripts.core.config.PageConfigReader
import com.krscripts.core.config.PageConfigSh
import com.krscripts.core.model.ClickableNode
import com.krscripts.core.model.ConfigNode
import com.krscripts.core.model.KrScriptActionHandler
import com.krscripts.core.model.NavNode
import com.krscripts.core.model.PageNode
import com.krscripts.core.model.RunnableNode
import com.krscripts.core.ui.ActionListFragment
import com.krscripts.core.ui.DialogHelper
import com.krscripts.core.ui.ParamsFileChooserRender
import com.google.android.material.button.MaterialButton
import com.google.android.material.imageview.ShapeableImageView
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

class MainActivity : KrActivity() {

    private var krScriptConfig = KrScriptConfig()
    lateinit var binding: ActivityMainBinding

    // 彩蛋：连点关于页 Logo 触发
    private var eggClickCount = 0
    private var eggLastClickTime = 0L
    private val eggPrefsName = "egg_settings"
    private val eggUnlockedKey = "egg_unlocked"
    // 仅在彩蛋解锁后才作为底部导航 tab 展示的彩蛋页
    private val eggGatedPagePath = "file:///android_asset/kr-script/egg/egg.xml"
    // 本次会话内解锁/重置后，待回到主页时刷新一次菜单（避免在对话框中 recreate 产生游离遮罩）
    private var pendingEggMenuRefresh = false
    private var aboutDialog: AlertDialog? = null

    private fun isEggUnlocked(): Boolean =
        getSharedPreferences(eggPrefsName, MODE_PRIVATE).getBoolean(eggUnlockedKey, false)

    // 当前应展示的页面列表：基础页 + (彩蛋解锁时附加彩蛋页 tab)
    private fun currentPageConfigs(): List<PageNode> {
        val list = krScriptConfig.pageListConfig.toMutableList()
        if (isEggUnlocked()) {
            list.add(PageNode("").apply { pageConfigPath = eggGatedPagePath })
        }
        return list
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()

        binding = ActivityMainBinding.inflate(layoutInflater)
        setContentView(binding.root)

        ViewCompat.setOnApplyWindowInsetsListener(binding.main) { v, insets ->
            val systemBars = insets.getInsets(WindowInsetsCompat.Type.systemBars())
            v.setPadding(systemBars.left, systemBars.top, systemBars.right, 0)
            insets
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
        }

        setSupportActionBar(binding.toolbar)

        lifecycleScope.launch {
            progressBarDialog.showDialog(getString(R.string.please_wait))

            krScriptConfig = KrScriptConfig()
            buildNavgationMenu(currentPageConfigs())

            progressBarDialog.hideDialog()
        }
    }

    override fun onResume() {
        super.onResume()
        // 彩蛋解锁/重置后，从彩蛋页或关于对话框返回时刷新一次菜单（无需 recreate，避免遮罩残留）
        if (pendingEggMenuRefresh) {
            pendingEggMenuRefresh = false
            lifecycleScope.launch {
                progressBarDialog.showDialog(getString(R.string.please_wait))
                buildNavgationMenu(currentPageConfigs())
                progressBarDialog.hideDialog()
            }
        }
    }

    private suspend fun buildNavgationMenu(pageConfigs: List<PageNode>) = withContext(Dispatchers.Main) {

        binding.viewPager.apply {
            adapter = PageFragmentAdapter(this@MainActivity, pageConfigs)
            offscreenPageLimit = 1
        }

        val menu = binding.bottomNavView.menu
        menu.clear()
        menuOptions.clear()

        pageConfigs.forEachIndexed { index, page ->

            getConfig(page)?.let { config ->

                menuHandler = config.pageHandlerSh.takeIf { it.isNotEmpty() }

                config.pageMenuOptions.let {
                    menuOptions.addAll(it)
                    invalidateOptionsMenu()
                }

                val menuName =
                    config.content.lastOrNull()?.title?.takeIf { it.isNotEmpty() && config.content.last() is NavNode }
                        ?: page.pageConfigPath.substringAfterLast('/')

                menu.add(menuName).apply {
                    icon = ContextCompat.getDrawable(
                        this@MainActivity,
                        R.drawable.baseline_bookmark_24
                    )!!
                    setOnMenuItemClickListener {
                        binding.viewPager.setCurrentItem(index, false)
                        false
                    }
                }
            }
        }

        binding.viewPager.registerOnPageChangeCallback(object : ViewPager2.OnPageChangeCallback() {
            override fun onPageSelected(position: Int) {
                binding.bottomNavView.menu[position].isChecked = true
            }
        })
    }

    private fun getConfig(pageNode: PageNode): ConfigNode? {
        var config: ConfigNode? = null

        if (pageNode.pageConfigSh.isNotEmpty()) {
            config = PageConfigSh(this, pageNode.pageConfigSh, null).execute()
        }
        if (config == null && pageNode.pageConfigPath.isNotEmpty()) {
            config = PageConfigReader(this.applicationContext, pageNode.pageConfigPath, null).readConfigXml()
        }

        return config
    }

    private fun reloadTab(pageNode: PageNode, index: Int) {
        lifecycleScope.launch(Dispatchers.IO) {
            val items = getConfig(pageNode)
            withContext(Dispatchers.Main) {
                items?.let { newItems ->
                    val itemId = (binding.viewPager.adapter as? PageFragmentAdapter)?.getItemId(index) ?: return@withContext
                    val tag = "f$itemId"
                    val fragment = supportFragmentManager.findFragmentByTag(tag) as? ActionListFragment
                    fragment?.update(newItems.content, getKrScriptActionHandler(pageNode, index))
                }
            }
        }
    }

    private fun getKrScriptActionHandler(pageNode: PageNode, index: Int): KrScriptActionHandler {
        return object : KrScriptActionHandler {
            override fun onActionCompleted(runnableNode: RunnableNode) {
                if (runnableNode.autoFinish ) {
                    finishAndRemoveTask()
                } else if (runnableNode.reloadPage) {
                    reloadTab(pageNode, index)
                }
            }

            override fun createShortcut(clickableNode: ClickableNode, createShortcutHandler: KrScriptActionHandler.CreateShortcutHandler) {
                val page = clickableNode as? PageNode
                    ?: if (clickableNode is RunnableNode) {
                        pageNode
                    } else {
                        return
                    }

                val intent = Intent()

                intent.component = ComponentName(this@MainActivity.applicationContext, ActionPage::class.java)
                intent.addFlags(Intent.FLAG_ACTIVITY_EXCLUDE_FROM_RECENTS)
                intent.addFlags(Intent.FLAG_ACTIVITY_NO_HISTORY)

                if (clickableNode is RunnableNode) {
                    intent.putExtra("autoRunItemId", clickableNode.key)
                }
                intent.putExtra("page", page)

                createShortcutHandler.onCreateShortcut(clickableNode, intent)
            }

            override fun onSubPageClick(pageNode: PageNode) {
                openPage(pageNode)
            }

            override fun openFileChooser(fileSelectedInterface: ParamsFileChooserRender.FileSelectedInterface): Boolean {
                fileSelectorInterface = fileSelectedInterface
                return chooseFilePath(fileSelectedInterface)
            }
        }
    }

    fun openPage(pageNode: PageNode) {
        OpenPageHelper(this).openPage(pageNode)
    }

    // 更新日志：读取 assets/CHANGELOG.md，弹窗展示（可在 IO 读取，UI 填充）
    private fun showChangelogDialog() {
        val context = this
        lifecycleScope.launch(Dispatchers.IO) {
            val content = try {
                assets.open("CHANGELOG.md").bufferedReader().use { it.readText() }
            } catch (_: Exception) {
                getString(R.string.changelog_empty)
            }
            withContext(Dispatchers.Main) {
                val layout = LayoutInflater.from(context)
                    .inflate(R.layout.dialog_changelog, null)
                layout.findViewById<TextView>(R.id.tv_changelog_content).text = content
                DialogHelper.animDialog(
                    context,
                    MaterialAlertDialogBuilder(context)
                        .setView(layout)
                )
            }
        }
    }

    // 彩蛋入口：解锁隐藏状态并加载隐藏的 egg.xml 子页面（不在主页菜单中暴露）
    private fun maybeOpenEggPage() {
        // 持久化解锁状态，使受控分组（GT 玩机助手 OTA）在返回主页后可见
        getSharedPreferences(eggPrefsName, MODE_PRIVATE)
            .edit().putBoolean(eggUnlockedKey, true).apply()

        // 标记待刷新：返回主页(onResume)时重建菜单，避免在此处 recreate 造成进度遮罩残留
        pendingEggMenuRefresh = true

        val eggPage = PageNode("").apply {
            title = getString(R.string.egg_page_title)
            pageConfigPath = "file:///android_asset/kr-script/egg/egg.xml"
        }
        openPage(eggPage)
    }

    private fun getThemeColor(attrRes: Int): Int {
        val typedValue = TypedValue()
        this.theme.resolveAttribute(attrRes, typedValue, true)
        return typedValue.data
    }

    override fun onCreateOptionsMenu(menu: Menu): Boolean {

        menu.clear()
        menuInflater.inflate(R.menu.main, menu)

        for (i in menuOptions.indices) {
            val menuOption = menuOptions[i]
            if (menuOption.isFab) {
                addFab(menuOption, binding.fab)
            } else {
                menu.add(-1, i, i, menuOption.title)
            }
        }

        menu.findItem(R.id.option_menu_info)?.icon?.setTint(
            getThemeColor(com.google.android.material.R.attr.colorOnSurface)
        )

        return true
    }

    override fun onOptionsItemSelected(item: MenuItem): Boolean {
        when (item.itemId) {
            R.id.option_menu_info -> {
                val layoutInflater = LayoutInflater.from(this)
                val layout = layoutInflater.inflate(R.layout.dialog_about, null)

                val appVersion = try {
                    packageManager.getPackageInfo(packageName, 0).versionName
                } catch (_: Exception) {
                    ".null"
                }

                val tvAppVersion = layout.findViewById<TextView>(R.id.tv_app_version)
                tvAppVersion.text = getString(R.string.app_version, appVersion, BuildConfig.BUILD_COMMIT)

                val tvAppAuthor = layout.findViewById<TextView>(R.id.tv_app_author)
                tvAppAuthor.text = SpannableString(getString(R.string.app_author)).apply {
                    setSpan(UnderlineSpan(), 0, length, Spanned.SPAN_INCLUSIVE_INCLUSIVE)
                }
                tvAppAuthor.setOnClickListener {
                    startActivity(Intent(Intent.ACTION_VIEW, Uri.parse("https://www.coolapk.com/u/922815")))
                }

                val frameworkVersion = BuildConfig.FRAMEWORK_VERSION
                val tvFrameworkInfo = layout.findViewById<TextView>(R.id.tv_framework_info)
                tvFrameworkInfo.text = getString(R.string.framework_info, frameworkVersion)

                // 彩蛋：连点应用 Logo 7 次跳转到隐藏功能页
                layout.findViewById<ShapeableImageView>(R.id.app_logo)?.setOnClickListener {
                    val now = System.currentTimeMillis()
                    eggClickCount = if (now - eggLastClickTime < 600) eggClickCount + 1 else 1
                    eggLastClickTime = now
                    if (eggClickCount >= 7) {
                        eggClickCount = 0
                        maybeOpenEggPage()
                    }
                }

                // 已解锁彩蛋时显示「重置」入口，点击后清除解锁状态并刷新主页
                layout.findViewById<MaterialButton>(R.id.btn_reset_egg)?.let { resetBtn ->
                    if (isEggUnlocked()) {
                        resetBtn.visibility = View.VISIBLE
                        resetBtn.setOnClickListener {
                            getSharedPreferences(eggPrefsName, MODE_PRIVATE)
                                .edit().putBoolean(eggUnlockedKey, false).apply()
                            // 关闭对话框后直接刷新菜单（dismiss 不会触发 onResume）
                            aboutDialog?.dismiss()
                            lifecycleScope.launch {
                                progressBarDialog.showDialog(getString(R.string.please_wait))
                                buildNavgationMenu(currentPageConfigs())
                                progressBarDialog.hideDialog()
                            }
                        }
                    }
                }

                // 更新日志：点击后读取内置 CHANGELOG.md 并弹窗展示
                layout.findViewById<MaterialButton>(R.id.btn_changelog)?.setOnClickListener {
                    showChangelogDialog()
                }

                aboutDialog = DialogHelper.animDialog(
                    this,
                    MaterialAlertDialogBuilder(this)
                        .setView(layout)
                        .setTitle(getString(R.string.title_about))
                ) as AlertDialog
            }
            else -> {
                onMenuItemClick(menuOptions[item.itemId])
            }
        }
        return true
    }

    inner class PageFragmentAdapter(
        activity: FragmentActivity,
        private val pages: List<PageNode>
    ) : FragmentStateAdapter(activity) {

        private val sessionId: Long = System.nanoTime()

        override fun getItemCount() = pages.size

        override fun getItemId(position: Int): Long {
            return sessionId + position
        }

        override fun containsItem(itemId: Long): Boolean {
            return itemId in sessionId until (sessionId + pages.size)
        }

        override fun createFragment(position: Int): Fragment {
            val page = pages[position]
            val items = getConfig(page) ?: ConfigNode()
            return ActionListFragment.create(items.content, getKrScriptActionHandler(page, position), null, false)
        }
    }
}
