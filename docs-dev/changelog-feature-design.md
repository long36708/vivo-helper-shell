# 查看更新日志功能 - 方案设计

> 状态：设计阶段（未开发）
> 日期：2026-08-15

## 一、需求定位

让用户在 App 内直接查看应用的版本更新历史（changelog），而非跳转外部链接。

数据来源两种思路：
- **本地内置**：随 APK 打包一份 `CHANGELOG` 文件（记录已发布版本，发布时手动维护）。
- **远程拉取**：从 GitHub raw 拉取最新 `CHANGELOG.md`（动态展示线上内容，类似 `more.xml` 中直接 `link` 文档的做法）。

推荐：**本地内置为主 + 可选远程兜底**，二者可共存。

## 二、方案选型

| 方案 | 入口形态 | 改动范围 | 复杂度 |
|---|---|---|---|
| A. kr-script `<action>` + `<script>` 输出 | 主页新增 action，点击弹终端式输出框显示 changelog | 仅 `home.xml` + 资源文件 | 最低 |
| B. 关于对话框新增"更新日志"按钮 | 复用 `dialog_about.xml` 与 `MainActivity`，点按钮弹新 Dialog | `dialog_about.xml` + `MainActivity.kt` + 资源 + 字符串 | 中 |
| C. 独立子页面 `changelog/changelog.xml` | 像 `slot.xml`/`ota.xml` 挂 `<page>` 子页面，支持折叠/富文本 | 新增 xml + 资源 + `home.xml` 挂载 | 中高 |

**结论：首选方案 B**——更新日志属"关于"语境，与现有关于弹窗同处，用户心智一致，且不污染主页菜单，展示空间充足（可滚动列表）。

## 三、推荐方案 B 详细设计

### 1. 数据来源
在 `app/src/main/assets/` 新增 `CHANGELOG.md`，按版本倒序书写：

```markdown
# 更新日志

## v1.4.0 (build 23) - 2026-08-10
- 新增 A/B 槽位一键切换（对位槽自动判断）
- 设备状态检查支持 bootctl 读取

## v1.3.0 (build 20) - 2026-07-22
- 新增 GT 玩机助手 OTA 入口（彩蛋解锁后可见）
- 修复 WiFi 密码查看在 Android 15 上的兼容
```

格式约定：`##` 分隔版本块，`()` 内写 build 号，便于后续解析"当前版本"高亮。

可选远程兜底：在 `more.xml` 的"文档"组保留 `<page link=".../CHANGELOG.md">` 作为线上版入口（与现有风格一致）；本地对话框负责"已安装版本"明细。

### 2. UI 改造
`dialog_about.xml` 底部 `btn_reset_egg` 之前新增按钮：

```xml
<com.google.android.material.button.MaterialButton
    android:id="@+id/btn_changelog"
    android:layout_width="wrap_content"
    android:layout_height="wrap_content"
    android:layout_gravity="center"
    android:layout_marginTop="12dp"
    android:text="@string/btn_changelog"
    style="?attr/materialButtonOutlinedStyle" />
```

新增展示用布局 `dialog_changelog.xml`：`ScrollView` + `TextView`（`android:textIsSelectable="true"` 便于复制），顶部显示当前版本标题。

### 3. 逻辑改造（MainActivity.kt）
在 `onOptionsItemSelected` 的 `R.id.option_menu_info` 分支内、`aboutDialog` 构建前，给 `btn_changelog` 绑定点击：
- `assets.open("CHANGELOG.md").bufferedReader().readText()` 读取；
- IO 协程读取、主线程填充到 `dialog_changelog` 的 TextView；
- 与 `aboutDialog` 一致用 `DialogHelper.animDialog` 弹出，保持动画风格统一。

### 4. 字符串新增（strings.xml）
- `btn_changelog` = "更新日志"
- `title_changelog` = "更新日志"
- 可选：`changelog_empty` = "暂无更新记录"

### 5. 涉及文件清单
- 新增：`app/src/main/assets/CHANGELOG.md`
- 新增：`app/src/main/res/layout/dialog_changelog.xml`
- 修改：`app/src/main/res/layout/dialog_about.xml`（加按钮）
- 修改：`app/src/main/res/values/strings.xml`（加字符串）
- 修改：`app/src/main/java/com/longmo/vivo/helper/MainActivity.kt`（按钮绑定 + 弹窗逻辑）

## 四、方案 A 要点（最低改动，备选）
在 `home.xml` 的"快捷工具"组加 `<action title="查看更新日志">`，内部 `<script>` 用 `cat` 打包的 changelog 文本，输出到 kr-script 终端式结果框。
- 优点：完全不碰 Kotlin/布局。
- 缺点：等宽终端样式，无版本高亮、复制/滚动体验差、占用主页菜单位。

## 五、方案 C 要点（独立子页面）
新增 `app/src/main/assets/kr-script/changelog/changelog.xml`，用 `<group>`+`<action>` 把每个版本块做成可展开项；在 `home.xml` 用 `<page config="changelog/changelog.xml" title="更新日志">` 挂载。
- 优点：体验最完整、可折叠分组。
- 缺点：改动最大，且更新日志非高频功能，单独占 Tab/菜单项略重。

## 六、结论与后续
- 首选方案 B：契合"关于"语境、复用弹窗体系、改动可控、体验优于 A。
- 数据以本地 `CHANGELOG.md` 为主，发布时随版本手动维护；线上版仅作 `more.xml` 链接补充。
- 后续可扩展：解析 build 号对比 `BuildConfig.VERSION_CODE` 实现"当前版本高亮 / 检测更新"，本期不做。
