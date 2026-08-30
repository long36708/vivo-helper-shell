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
