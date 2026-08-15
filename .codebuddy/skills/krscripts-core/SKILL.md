---
name: krscripts-core
description: 使用 krscripts core 组件库（com.krscripts.core）开发 kr-script 配置页面、执行 shell 脚本、渲染参数表单、管理桌面快捷方式与后台任务时参考。当用户需要新增一个 kr-script 页面（home.xml/page.xml）、新增 action 节点、调用 ShellExecutor 执行脚本、使用 ActionListFragment/PageLayoutRender 渲染 UI、处理参数表单（ActionParamInfo/Params*）、读取/解析页面配置（PageConfigReader）、读写私有文件（FileWrite/ExtractAssets）或 root 文件（RootFile/RootFileInfo）时使用。本 skill 是组件速查手册，避免每次翻阅 core 源码；组件完整签名/字段见同目录 reference.md（渐进式披露，按需 read）。
---

# krscripts-core 组件速查

本 skill 覆盖 `core/src/main/java/com/krscripts/core` 下的可复用组件。包前缀均为 `com.krscripts.core`。

> **渐进式披露**：本文件只保留总览、高频流程与踩坑。各组件的**完整签名/字段/用法**在 `reference.md`，开发某个具体组件时再 read 它（见下表「详情」列）。不要一次性把整个组件库细节都读进上下文。

## 0. 包结构一览

| 子包 | 职责 | 详情 |
|------|------|------|
| `config` | 解析 kr-script XML 配置（PageConfigReader）、节点类型 | [reference.md §A](reference.md) |
| `model` | 配置节点数据类（ActionNode / PageNode / RunnableNode / ClickableNode / ConfigNode / ActionParamInfo / SelectItem 等） | [reference.md §B](reference.md) |
| `ui` | UI 渲染（ActionListFragment、PageLayoutRender、Params*、DialogHelper、ListItemView 等） | [reference.md §C](reference.md) |
| `executor` | 脚本执行（ShellExecutor、ScriptEnvironment、ExtractAssets、SimpleShellWatcher） | [reference.md §D](reference.md) |
| `shell` | root/sh 运行（KeepShell、KeepShellPublic、RootFile、ShellExecutor、ShellTranslation） | [reference.md §E](reference.md) |
| `shared` | 私有/root 文件读写、对象存储、应用信息（FileWrite、RootFileInfo、ObjectStorage、AppInfo） | [reference.md §F](reference.md) |
| `downloader` | 资源下载（Downloader、DownloaderActivity、DownloadWorker、DownloadReceiver） | [reference.md §G](reference.md) |
| `shortcut` | 桌面快捷方式（ActionShortcutManager、ShortcutIconManager、CreateShortcut 等） | [reference.md §H](reference.md) |
| `util` | 权限工具（PermissionUtil） | [reference.md §J](reference.md) |
| 根（`core`） | BgTaskThread、HiddenTaskThread、FileOwner、TryOpenActivity、WebViewInjector | [reference.md §I](reference.md) |

## 1. 高频速查（最常用的三个入口）

**解析页面**：`PageConfigReader(context).parseConfigXml("file:///android_asset/...", true): ConfigNode?`
> `canReadAsset=true` 允许读 assets；`false` 只接受已解压私有目录路径（防篡改）。返回 `ConfigNode`，`content: ArrayList<NodeInfoBase>` 为节点列表。

**执行脚本**：`ShellExecutor().execute(context, nodeInfo: RunnableNode, cmd: String?, onExit: Runnable?, params: HashMap<String,String>?, shellHandlerBase: ShellHandlerBase): Process?`
> 内部用 `ScriptEnvironment.runtime`（root=`su`，否则 `sh`）；`interruptable` 时可 `forceStop`；同一实例 `started` 后再调用返回 `null`，不可复用串行执行。

**解压资源**：`ExtractAssets(context).extractResource("file:///android_asset/kr-script/xxx.sh"): String?`
> 解压到私有目录返回路径；`.sh` 带可执行权限；menu handler 由 `ScriptEnvironment` 注入 `START_DIR`，handler 里用 `$START_DIR/kr-script/xxx.sh`。

## 2. 典型开发流程

1. 在 `app/src/main/assets/kr-script/` 放脚本；在 `assets` 下写 `home.xml` / 子页面 `xxx.xml`。
2. 页面入口用 `PageConfigReader(context).parseConfigXml("file:///android_asset/...", true)` 解析为 `ConfigNode`。
3. 用 `ActionListFragment`（或 `PageLayoutRender`）渲染 `ConfigNode.content`。
4. action 点击 → `ExtractAssets(context).extractResource(scriptPath)` 取得私有脚本路径 → `ShellExecutor().execute(context, actionNode, script, onExit, params, handler)`。
5. 参数表单：在 XML `<param>` 中声明，UI 自动渲染为 `Params*`，结果进 `params: HashMap`。
6. 需要 root 文件/常驻 shell：用 `RootFile` / `KeepShellPublic`；需要桌面快捷方式：用 `ActionShortcutManager`。

## 3. 常见踩坑（务必注意）

- `<param>` 的 `values`/`labels` 属性无效，下拉选项必须写 `<option>` 子标签，否则渲染退化为手填 EditText。
- `ExtractAssets` 解压脚本到私有目录后才可执行；menu handler 依赖 `START_DIR`，脚本路径要用 `$START_DIR/...`。
- `ShellExecutor.execute` 同一实例 `started` 后再次调用返回 `null`，不可复用同一实例串行执行多个脚本。
- `ActionParamInfo.options` 需经 `getParamOptions` 合并 `optionsFromShell`，只设静态 `<option>` 时用 `info.options` 即可。
- Android 11+ 文件访问用 `Environment.isExternalStorageManager()`，旧 API 用 `READ/WRITE_EXTERNAL_STORAGE`。
- `RootFileInfo` 在构造时即读取元数据；需最新状态时重新构造或用 `RootFile.*` 重新查询。
