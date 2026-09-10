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
- menu 的 `<handler>` 内容存到 `config.pageHandlerSh`，执行时由 `ScriptEnvironment` 注入 `START_DIR`（指向 app 私有目录根），所以 handler 里可写 `sh "$START_DIR/kr-script/slot/swab.sh" ...`。

### 子页面挂载

- 主页 `home.xml` 通过 `<page config="slot/slot.xml" title="...">` 挂子页面；`<page>` 内部可放 `<resource>` 声明该页需要的脚本。
- 脚本资源相对路径在解压后保持原相对结构，即 `file:///android_asset/kr-script/slot/swab.sh` 解压到 `$START_DIR/kr-script/slot/swab.sh`。

## kr-script 配置常见错误 → 规范对照表

以下错误均为组件库（PageConfigReader / ActionListFragment / Params*）的确定性约定违反，曾在 `ota.xml` 等文件实际出现，已修复。**新增或修改 XML 配置时对照本表自检。**

| # | 错误写法 | 后果 | 正确规范 |
|---|----------|------|----------|
| 1 | `<param type="select" values="a\|b" />`（用 `values`/`labels` 属性） | 属性被 `parseActionParamAttrs` 忽略，`optionsFromShell` 为空，下拉框退化为 EditText 手填框，取值无约束 | 静态选项一律用 `<option>` 子标签（见上「下拉选择」节） |
| 2 | `<param name="x" type="bool" />` | `type="bool"` 不是组件库识别的开关类型，`ParamsSwitchRender` 不渲染，退化为 EditText，用户需手填 `true/false` | 开关用 `type="switch"`（与 `slot.xml` 一致） |
| 3 | `<set>sh $START_DIR/kr-script/xxx.sh</set>`（路径无引号） | `$START_DIR` 若含空格会断词，脚本找不到 | `<set>sh "$START_DIR/kr-script/xxx.sh"</set>`（路径加双引号） |
| 4 | 在 `<menu>` 内部放 `<resource>` | 被忽略，脚本不会被解压 | `<resource>` 放 `<nav>` 顶层或 `<page>` 内声明即可 |
| 5 | 暗码 `tel:` 手写 URL 编码漏字符（如 `*#06#` 写成 `tel:%2A06%23` 漏开头 `#`；`*#*#2288#*#*` 写成 `tel:%2A%232288%23%2A%23%2A` 漏开头第二对 `*#`） | 拨号器收到错误暗码无法触发，实测 `*#*#2288#*#*` 变成 `*#2288#*#*` | `*`→`%2A`、`#`→`%23` 必须逐字符对应；模板见下「电话暗码 tel: 编码」节；**改完必须用脚本解码全量核对** |

**参数类型速查**（组件库识别的 `type` 值）：
- 文本：`text`；下拉：`select`（配 `<option>`）；开关：`switch`；文件：`file`（可配 `suffix`/`mime`）；文件夹：`folder`；包名：`package`。

**自检清单**（改完 XML 后）：
- [ ] `type="select"` 的 `<param>` 是否都带 `<option>` 子标签（而非 `values` 属性）？
- [ ] 所有开关是否用 `type="switch"`（无 `bool`）？
- [ ] 所有 `sh $START_DIR/...` 路径是否已加双引号？
- [ ] 脚本 `<resource>` 是否在 `<nav>` 顶层或对应 `<page>` 内声明？
- [ ] 所有 `tel:` 暗码是否用 `urllib.parse.unquote` 解码核对过（解码结果必须等于原暗码，逐字符）？
- [ ] 长耗时脚本的执行前提示是否写在 `desc`（`warning` 在有 `<param>` 的 action 上不生效）？是否区分了『退出』（杀脚本）与『隐藏』（不杀）？
- [ ] 新增日志行是否避开"成功/完成"等词（否则警告行会被 `paint_line` 染成绿色）？

### 电话暗码 tel: 编码（反复踩坑，务必照模板）

用 `am start -a android.intent.action.DIAL -d "tel:..."` 触发工程暗码时，`*` 和 `#` 必须 URL 编码：`*`→`%2A`，`#`→`%23`。**手写替换极不可靠，已连续两次漏字符**，必须改完用脚本复核。

正确模板（已修复）：
- `*#XXXX#`        → `tel:%2A%23XXXX%23`
- `*#*#XXXX#*#*`   → `tel:%2A%23%2A%23XXXX%23%2A%23%2A`
- 也可用半明文（vivo 拨号器能处理，不必编码 `*`）：`tel:*%232288%23*%23*`

复核方法（改完跑一次，确认解码 == 原暗码再提交/构建）：
```python
import re, urllib.parse
t = open("app/src/main/assets/kr-script/secret_codes/secret_codes.xml", encoding="utf-8").read()
for title, d in re.findall(r'<action title="([^"]+)">.*?tel:([^"]+)"', t, re.S):
    print(title.split("(")[0].strip(), "=>", urllib.parse.unquote(d))
```

### 执行界面：『退出』会杀脚本，『隐藏』不会（DialogLogFragment）

长耗时脚本（OTA 安装等）必须知道用户在日志界面上能做什么：

- `DialogLogFragment` 的 `isCancelable = false`（`ActionListFragment.kt` 里设置），**返回键关不掉**界面。
- **『退出』按钮 = 真杀脚本**：`btnExit` 先跑 `forceStopRunnable` 再关界面，`ShellExecutor.killProcess` 执行 `kill -s 1 \`pgrep -f kr_<uuid>\``（`core/.../executor/ShellExecutor.kt:21-52`）。脚本一死，它后面的步骤（切槽 / 刷 LK / 打印小结）**全部不会执行** —— 对 OTA 而言就是"包写进去了但没人切槽，重启被回滚清空"。
- **『隐藏』按钮 = 只关界面**：`btnHide` 只 `closeView()`，进程继续跑，可用『查看安装进度』之类入口回看。
- `interruptable="false"`（或 `interruptible="false"`）可同时隐藏这两个按钮，但**用户也失去了唯一的中止手段**，长耗时任务慎用。
- 结论：提示文案必须把『退出』和『隐藏』**分开写**，不能笼统说"请勿退出界面"。

### `warning` 属性在有参数的 action 上不生效，执行前提示要写在 `desc`

- `ActionListFragment.onActionClick` 只在 `item.confirm` 为真、或 **`warning` 非空且 `params` 为空** 时才弹确认框（`ActionListFragment.kt:351-363`）。带 `<param>` 的 action（如『开始强制安装』）写 `warning` **永远不会被弹出来**。
- 正确做法：`confirm="true"` + `desc="..."`。`desc` 一箭双雕 —— 既是确认弹窗的 message，也是日志界面顶部常驻文本（`DialogLogFragment` 的 `binding.desc`）。
- 别用 `desc-sh` 做动态提示：它在**页面加载时**就被 `executeResultRootCached` 求值（`PageConfigReader.kt:613-621`），拿不到用户之后才选的参数（如 OTA 包路径）。动态内容只能用脚本内 `log`/`echo`。

### 日志着色：paint_line 关键词有优先级，"成功"压过"警告"

`vivo_ota.sh` 的 `paint_line` 按 error → success → warn → 默认 的顺序判定，**先命中即返回**：

- 含 `error/fail/失败/错误/fatal/denied` → 红
- 含 `success/done/成功/完成/okay/applied` → **绿**
- 含 `warn/warning/⚠/警告` → 黄

坑：一条**警告**行里只要出现"成功/完成"（如"⚠ LK 写入成功不代表刷机包刷入成功"），就会被染成绿色。写警告文案时要避开这些词（改用"刷入失败"走红、用 ⚠ 且不含"成功"走黄），或者直接改 `paint_line` 的判定顺序（会影响既有日志配色，谨慎）。

## OTA 强刷脚本（kr-script/ota/）

### Boot Control HAL 事务码（PD2419 真机实测，2026-09-06）

`service call android.hardware.boot.IBootControl/default <txn>`（服务名用 `service list | grep -i IBootControl` 探测，勿写死）：

| txn | 方法 | 说明 |
|-----|------|------|
| 1 | getActiveBootSlot | 待生效槽（0=A, 1=B） |
| 2 | getCurrentSlot | 当前运行槽 |
| 4 | getSnapshotMergeStatus | 0=none 干净；非 0=有 pending 快照 |
| 7 | isSlotMarkedSuccessful | 查询当前槽是否已标记成功 |
| 8 | markBootSuccessful | **幂等**，解锁 CleanupPreviousUpdateAction 卡死的唯一开关 |
| 9 | setActiveBootSlot | 切槽（`i32 <0|1>`）；swab.sh 同款，实测可用 |

**不要用 txn 3**（getNumberSlots，只读）做切槽 —— vivo_ota.sh/vivo_ota_ctrl.sh 曾因此切槽从未真正下发。

### 返回码 248 的双重语义（曾致假成功）

`update_engine_client` 的**退出码** 248 = binder `Status(-8)` 失败（错误 54 "CleanupPreviousUpdateAction is running"、错误 65 "Already processing" 等），**不是** UPDATED_NEED_REBOOT。引擎真正接受安装时 launch 退出 0；"已应用待重启"只能由 `wait_engine_done` 从引擎日志终态判定（UPDATED_NEED_REBOOT / SendPayloadApplicationComplete [0]）。客户端任何非 0 退出码一律按失败处理（归一为 66，已列入 FAIL_CODES）。

### CleanupPreviousUpdateAction 卡死（VAB 收尾死锁）

引擎带未完成收尾启动时会卡在 `Boot completed, waiting on markBootSuccessful()`：当前槽未被标记 boot successful（正常由 update_verifier/framework 开机后调用）。此时 `--cancel`（错误 54）、`--reset_status`、强清 prefs、ctl.restart 全都解不开（重启后重进同一状态）。唯一解法：`service call $SVC 8`（markBootSuccessful，幂等）+ `update_engine_client --merge` 让收尾跑完，回 merge=none 的干净 IDLE 后才能提交新安装。推不动时补一次 `ctl.restart update_engine` 让它重排 cleanup（此时槽已 successful，会立即通过）。

**因此**：安装脚本在 `sys.boot_completed!=1` 时不得停 com.bbk.updater / 杀引擎（它参与 markBootSuccessful 链路）；launch 前必须过 IDLE 闸（`ue_wait_idle`）；成功切槽/刷 LK 只能发生在引擎日志确认写入成功之后 —— 顺序反了（包被 741 拒收却去切槽+刷 lk）是变砖前提。

## A/B 槽位切换（slot/swab.sh）

- 脚本依赖 busybox 的 `crc32` / `xxd`，且需 root（KernelSU / Magisk），脚本内部有自检。
- 用法：`swab.sh [a|b|o] [-r] [-d] [-a a|b] [-p a|b] [-s] [-h]`
  - 无参 / `-s`：只读查看当前运行槽、待生效槽、misc 后缀、可启动性、boot_ctrl CRC-32 校验。
  - `a` / `b`：切到 A / B 槽。
  - `o`：切到对位槽（以当前运行槽为基准自动判断）。
  - `-r`：切换后重启。如 `-o -r` = 重启到另一卡槽。
  - `-d`：完整 dump boot_ctrl 元数据（移植自 abslot-tool）。
  - `-a a|b`：设置指定槽位 active（priority=15, tries=7，其他高优先级槽降级）。
  - `-p a|b`：保护模式（successful_boot=0, tries=6，防变砖兜底）。
  - `-h`：帮助。
- 旧的 `slot/switch_ab.sh` 已替换为功能更全的 `swab.sh`（额外支持 dump/active/protect 模式）。

## Agent skills

### Issue tracker

Issues and specs live as GitHub Issues for this repo (`github.com/long36708/vivo-helper-shell`). See `docs-dev/agents/issue-tracker.md`.

### Domain docs

Single-context layout: one `CONTEXT.md` at the repo root plus `docs/adr/`. See `docs-dev/agents/domain.md`.
