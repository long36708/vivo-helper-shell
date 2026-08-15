# krscripts-core 组件清单（详细参考）

> 本文件是 `SKILL.md` 的详细延伸。开发某个具体组件时，再 read 本文件中对应小节。
> 包前缀均为 `com.krscripts.core`。

## A. config（配置解析）

### PageConfigReader（核心入口）
解析 assets 下的 XML 配置，产出 `ConfigNode`。
- `PageConfigReader(context)` 构造后 `parseConfigXml(pageConfigPath: String, canReadAsset: Boolean): ConfigNode?`
- `canReadAsset = true` 时允许读 `file:///android_asset/...`；`false` 时只接受已解压到私有目录的路径（用于防止配置被篡改）。
- 返回 `ConfigNode`，其中 `content: ArrayList<NodeInfoBase>` 为节点列表，`pageMenuOptions / pageMenuOptionsSh / pageHandlerSh` 为页面级菜单与 handler 脚本。
- 内部按节点 tag 映射：`page`→PageNode、`action`→ActionNode、`group`→GroupNode、`text`→TextNode、`config`→ConfigNode（嵌套）、`picker`→PickerNode、`switch`→SwitchNode、`image`→ImageNode、`list`→ListItem。
- 参数解析：`parseActionParamAttrs` 仅识别 `name/label/title/desc/value/type/suffix/required/readonly/editable/mime/optionsFromShell/valueFromShell` 等属性。**`values`/`labels` 属性不被解析**，静态下拉选项必须用 `<option>` 子标签。

### 配置 XML 约定（踩坑）
- `<option>` 子标签的 `val`（或 `value`）是传给脚本的实际值；标签文本是 UI 显示。
- `<param type="select">`：≤5 个 `<option>` 走原生 Spinner，>5 个走弹窗 DialogItemChooser；`options` 来自 `<option>` 经 `getParamOptions` 合并到 `optionsFromShell`。
- `<nav>` 顶层可放 `<resource file="file:///android_asset/...">` 解压脚本到私有目录；`<menu>` 内只识别 `option/menu/handler`，放 `<resource>` 无效（脚本已在 nav 顶层声明即可）。
- handler 执行时由 `ScriptEnvironment` 注入 `START_DIR`（指向 app 私有目录根），handler 里可写 `sh "$START_DIR/kr-script/xxx.sh"`。

## B. model（数据模型）

继承关系：`NodeInfoBase` ← `ClickableNode` ← `PageNode` / `ActionNode`；`RunnableNode` 是脚本型节点基类（`ActionNode` 继承它）。

- **NodeInfoBase**：`key/title/desc/state/stateShell/summary/summaryShell/confirm/confirmShell/action` 等；`key` 用于快捷方式标识。
- **ClickableNode**：`iconPath/logoPath/iconClip/allowShortcut/locked/lockShell/minSdkVersion/maxSdkVersion/targetSdkVersion`。
- **ActionNode**：`shell/page/link/activity/beforeShell/afterShell/interruptable/replaceResult/repeat`；脚本模式常量：`shellModeBgTask` 等（见 `RunnableNode.Companion`）。
- **PageNode**：`pageConfigPath/pageConfigSh/onlineHtmlPage/link/activity/beforeRead/afterRead/pageMenuOptions/pageHandlerSh/loadSuccess/loadFail`。
- **ConfigNode**（Serializable）：`pageMenuOptions/pageMenuOptionsSh/pageHandlerSh/content`（子节点列表）。
- **ActionParamInfo**：参数表单字段。`name/label/title/desc/value/type（text/select/switch/file/folder/package...）/options: ArrayList<SelectItem>/optionsFromShell/required/readonly/editable/mime/suffix/valueFromShell`。
- **SelectItem**：`icon/iconClip/title/value/selected`，`toString()` 返回 title 或 value，供 ArrayAdapter 直接显示。
- **RunnableNode**：`title/desc/state/stateShell/interruptable/replaceResult`；脚本执行回调通过 `ShellHandlerBase` 接收。

## C. ui（UI 渲染）

### ActionListFragment
- 列表型页面主 Fragment，读取 `ConfigNode.content` 渲染各节点。
- 关键方法：`getParamOptions(info)` 合并静态 `<option>` 与 `optionsFromShell`；`ParamsSingleSelect` 只读 `optionsFromShell`，为空会退化为 EditText。
- 点击 action 触发 `ShellExecutor().execute(...)`，传入 `RunnableNode` + `ShellHandlerBase` 子类（如 `ActivityShellHandler`）。

### PageLayoutRender
- `PageLayoutRender(...)` 负责把单个节点渲染为 View（图标、标题、描述、开关、参数表单）。通常配合 `ActionListFragment` 使用，无需直接 new。

### 参数表单组件（Params*）
- `ParamsFileChooserRender(info, context, fileChooser)`：`render()` 返回文件/文件夹选择 View；需实现 `FileChooserInterface`（回调 `openFileChooser(FileSelectedInterface)`），`FileSelectedInterface` 提供 `type()/mimeType()/suffix()/onFileSelected(path)`。
- `ParamsSingleSelect` / `ParamsRender`：下拉/文本参数渲染；下拉选项来自 `info.options`。
- 选择结果写回 `actionParamInfo`，最终以 `HashMap<String,String>` 形式作为脚本参数传入 `ShellExecutor.execute`。

### DialogHelper
- `DialogHelper.animDialog(context, builder)`：Material 对话框带动画包装（替代直接 `builder.show()`）。
- `DialogHelper.openInfoAlert(context, title, msg)`：信息提示框。

### 其他
- `ListItemView`、`ListItemAdapter`、`DialogItemChooser`、`ParamsTextRender`、`ParamsSwitchRender` 等：列表项与各类参数控件，按需复用，构造多接收 `(Context, NodeInfoBase/ActionParamInfo)`。

## D. executor（脚本执行）

### ShellExecutor（统一执行入口）
```kotlin
ShellExecutor().execute(
    context: Context?,
    nodeInfo: RunnableNode,          // 含 title/desc/interruptable 等
    cmd: String?,                    // 脚本内容或脚本路径
    onExit: Runnable?,               // 退出回调
    params: HashMap<String, String>?, // 参数键值对（来自参数表单）
    shellHandlerBase: ShellHandlerBase // 日志/进度回调接收者
): Process?
```
- 内部用 `ScriptEnvironment.runtime`（root 时为 `su`，否则 `sh`）。
- `nodeInfo.interruptable` 或 `shell == shellModeBgTask` 时提供 `forceStop` 可中断。
- 回调：`SimpleShellWatcher` 把进程输出转发给 `ShellHandlerBase` 的 `onStart/onReader/onWrite/onError/onExit/onProgress` 事件。

### ScriptEnvironment
- `ScriptEnvironment.runtime`：当前 shell 进程（`su`/`sh`）。
- `ScriptEnvironment.executeShell(context, out, cmd, params, nodeInfo, sessionTag)`：写入脚本到进程。
- `ScriptEnvironment.executeResultRoot(context, cmd, params) / executeResultSh(...)`：执行并取回结果字符串（不落地 UI）。
- `ScriptEnvironment.putEnv(...)`：注入环境变量（如 `START_DIR`）。

### ExtractAssets
- `ExtractAssets(context).extractResource("file:///android_asset/kr-script/xxx.sh"): String?` → 解压到私有目录并返回路径；`.sh` 用 `writePrivateShellFile`（带可执行权限），其他用 `writePrivateFile`。
- `extractResources(dir)`：批量解压目录；`getExtractPath(file)` 取私有目录绝对路径。有 `extractHistory` 缓存。

### SimpleShellWatcher
- `SimpleShellWatcher().setHandler(context, process, shellHandlerBase, onExit)`：绑定进程与回调，通常不需直接调用（ShellExecutor 内部已用）。

## E. shell（Shell 与 root）

- **KeepShell / KeepShellPublic**：常驻 root shell 包装，`KeepShellPublic` 提供静态便捷方法取 root 权限执行。
- **RootFile**：root 下的文件操作。`RootFile.fileInfo(path): RootFileInfo?`、`RootFile.itemExists(path): Boolean`、`RootFile.list(path): ArrayList<RootFileInfo>`、`RootFile.mkdir/mkfile/writeFile/deleteFile/setOwner` 等。
- **ShellExecutor（shell 包）**：`object ShellExecutor`，`superUserRuntime`（su 进程）/ `runtime`（sh 进程）属性；支持 `extraEnvPath` 追加 PATH。
- **ShellTranslation**：`ShellTranslation(context).resolveRow(row)/resolveRows(rows)` 把脚本输出里的 `@string:xxx` / `@dimen:xxx` 占位符替换为当前 app 的资源值（带缓存）。

## F. shared（文件读写）

- **FileWrite**：`writePrivateFile(assets, from, to, context)`、`writePrivateShellFile(from, to, context)`（脚本带执行权限）、`getPrivateFilePath(context, relative)`、`writePrivateFileText/readPrivateFileText`、`copyWithRoot`、权限/所有者设置。
  - 私有目录根 = `context.filesDir`；脚本默认解压到 `$filesDir/kr-script/...`。
- **RootFileInfo**：`RootFileInfo(path)` 构造时即用 `RootFile.fileInfo` 填充；提供 `exists()/isFile()/isDirectory()/listFiles()/getName()/getParent()/length()/absolutePath/fileName`。
- **ObjectStorage**：`put(context, key, obj, cacheTime)` / `get(context, key): Any?`，基于 `ObjectSerializer` 的轻量对象持久化（带过期时间，`ONE_DAY` 等常量）。
- **AppInfo**：`getCurrentPkgName` / `getAppName` 等应用信息。

## G. downloader（下载）

- **Downloader**：`download(context, url, path, filename, title, desc, notify, onlyWifi)`；基于 `DownloadManager` 或 WorkManager。
- **DownloadWorker / DownloadReceiver / DownloaderActivity**：后台下载任务与完成广播/页面，按需复用，通常经 `Downloader.download` 触发。

## H. shortcut（快捷方式）

- **ActionShortcutManager**：`addShortcut(context, action: ActionNode)` / `clearShortcut()` / `addCallback`；把带 `key` 且 `allowShortcut != false` 的 action 加到桌面。
- **ShortcutIconManager**：快捷方式图标生成（按 `logoPath`/`iconPath`）。
- **CreateShortcut / DeleteShortcutActivity**：创建/删除快捷方式的 Activity 入口。

## I. core 根（后台/隐藏任务 + 工具）

- **BgTaskThread.startTask(context, script, params, nodeInfo, onExit, onDismiss)**：带通知栏进度、可中断（`interruptable`）的后台脚本执行，内部用 `ServiceShellHandler` 更新通知。
- **HiddenTaskThread.startTask(context, script, params, nodeInfo, onExit, onDismiss)**：静默执行（无 UI），仅收集错误并以 Toast 提示。
- 二者均调用 `ShellExecutor().execute(...)`，区别在传入的 `ShellHandlerBase` 实现。
- **FileOwner**：文件所有者/权限工具（配合 RootFile 设置 chown/chmod）。
- **TryOpenActivity**：尝试打开指定 Activity，失败回退的安全封装。
- **WebViewInjector**：向 WebView 注入 JS / 资源（在线页面场景用）。

## J. util（权限）

- **PermissionUtil**：`requestAccessFilesDialog(activity, manageFileRequester?, onSkip?)` 申请文件管理权限；`checkAccessFiles(context): Boolean` 判断（Android 11+ 用 `Environment.isExternalStorageManager()`，否则检查存储权限）。
