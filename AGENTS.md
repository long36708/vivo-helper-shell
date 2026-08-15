# AGENT.md

项目相关的约定与踩坑记录，给 AI 编码助手参考。

## kr-script 配置（app/src/main/assets/kr-script/*.xml）

### 下拉选择（select）参数必须用 `<option>` 子标签，不能用 `values`/`labels` 属性

**踩坑**：`<param>` 的 `values` 和 `labels` 属性**不被解析**，写了也会被忽略。
- `PageConfigReader.parseActionParamAttrs` 只解析 `name/label/title/desc/value/type/suffix/required/readonly/...`，没有 `values`/`labels`。
- 静态选项只能用 `<option>` 子标签，`PageConfigReader.tagStartInAction` / `tagStartInPicker` 才会把 `<option>` 填进 `info.options`。
- `info.options` 经 `ActionListFragment.getParamOptions` 合并后赋给 `optionsFromShell`，`ParamsSingleSelect` 只读 `optionsFromShell`。若为空，渲染会退化成 EditText 输入框（手填），不是下拉框。

**正确写法**（下拉框，≤5 项走原生 Spinner，>5 项走弹窗 DialogItemChooser）：

```xml
<param name="target" type="select" title="切换目标" value="opp" required="true"
       desc="选择要切换到的槽位">
    <option val="opp">对位槽 (自动判断另一槽)</option>
    <option val="slot_a">A 槽 (_a)</option>
    <option val="slot_b">B 槽 (_b)</option>
</param>
```

- `<option>` 的 `val` 属性（或 `value`）是传给脚本的实际值；标签文本是 UI 显示内容。
- `val` 缺省时回退为标签文本本身作为值。

### `<nav>` / `<resource>` / `<menu>` 用法

- `<nav>` 顶层可直接放 `<resource file="file:///android_asset/...">`，会把脚本解压到私有目录（`ExtractAssets.extractResource`）。menu handler 执行前需确保脚本已解压，否则找不到文件。
- `<menu>` 内部**只识别** `option` / `menu` / `handler` 三种子标签，放 `<resource>` 会被忽略（无害，脚本在 nav 顶层已声明即可）。
- menu 的 `<handler>` 内容存到 `config.pageHandlerSh`，执行时由 `ScriptEnvironment` 注入 `START_DIR`（指向 app 私有目录根），所以 handler 里可写 `sh "$START_DIR/kr-script/slot/switch_ab.sh" ...`。

### 子页面挂载

- 主页 `home.xml` 通过 `<page config="slot/slot.xml" title="...">` 挂子页面；`<page>` 内部可放 `<resource>` 声明该页需要的脚本。
- 脚本资源相对路径在解压后保持原相对结构，即 `file:///android_asset/kr-script/slot/switch_ab.sh` 解压到 `$START_DIR/kr-script/slot/switch_ab.sh`。

## A/B 槽位切换（slot/switch_ab.sh）

- 脚本依赖 busybox 的 `crc32` / `xxd`，且需 root（KernelSU / Magisk），脚本内部有自检。
- 用法：`switch_ab.sh [a|b|o] [-r]`
  - 无参：只读查看当前运行槽、待生效槽、misc 后缀、可启动性、boot_ctrl CRC-32 校验。
  - `a` / `b`：切到 A / B 槽。
  - `o`：切到对位槽（以当前运行槽为基准自动判断）。
  - `-r`：切换后重启。如 `-o -r` = 重启到另一卡槽。
- 旧的 `slot/switch_slot_fix.sh` 功能不生效，已删除，改用 `switch_ab.sh`。
