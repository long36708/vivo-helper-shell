# OTA 包 size 解析 -1 与假成功误判排查经验

> 日期：2026-08-26
> 涉及文件：`app/src/main/assets/kr-script/ota/vivo_ota.sh`
> 现象：vivo 全量 OTA 包刷入时 size 获取到 `-1`，表现为「签名证书校验失败 / kDownloadTransferError」

## 一、现象

- 日志里 `PAYLOAD_SIZE=-1`，`update_engine` 报 `kDownloadTransferError`（错误码 4）或表面上的「签名/证书校验失败」（错误码 10）。
- 脚本偶发「假成功」：日志显示写入完成、自动写 ROOT/切槽，但实际后台刷机失败。

## 二、根因

### 1. ZIP64 占位符被 32 位 shell 算术溢出成 -1（核心原因）

- vivo 全量 OTA 的 `payload.bin` 通常 **>4GB**，在 zip 里是 **ZIP64 条目**。
- 脚本从 zip 本地头用 `le4` 读 `csize`（压缩后大小），ZIP64 条目此处写 `0xFFFFFFFF` 占位符。
- `le4` 用 `$(( ... ))` 做 32 位有符号算术：`4294967295` 在 `/system/bin/sh`（32 位 `ash`/`mksh`）溢出成 **`-1`**。
- `--size=-1` 喂给 `update_engine` → 引擎读偏/读到文件尾，与 zip 内 payload 之后的其他条目冲突 → `kDownloadTransferError=4`。「证书校验失败」只是下游误报，并非真证书问题。

### 2. /data 压缩路径导致路径转换失效

- 原逻辑把 `/storage/emulated/0/...` 转成 `/data/media/0/...` 以绕过 FUSE 大文件坑。
- 但部分设备 `/data` 是**压缩路径**，转换后反而找不到文件，须先 `[ -f "$_F" ]` 校验，找不到则保持原路径。

### 3. "假成功"误判（历史日志锚点缺失）

- `wait_engine_done` 用全量 `grep` 扫描引擎日志。引擎**启动阶段**会写 `CleanupPreviousUpdateAction` 留下历史 `SendPayloadApplicationComplete [0]`，并非本次完成。
- 不设锚点 → 把历史成功标记误判为本次成功 → 提前写 ROOT/切槽、漏掉真实后台错误。

## 三、修复方案（已在提交中实现）

| # | 改动 | 解决问题 |
|---|------|---------|
| 1 | 路径转换前 `[ -f "$_F" ]` 校验，找不到则保持原路径 | /data 压缩路径下转换失效找不到文件 |
| 2 | **ZIP64 修正**：`USE_OFFSET=1` 时从 `payload_properties.txt` 的 `FILE_SIZE=` 取权威值覆盖 `PAYLOAD_SIZE` | 根治 `le4` 溢出成 `-1`、导致 `kDownloadTransferError=4` |
| 3 | **日志锚点** `record_log_anchor` + `new_log_grep`：只检查「本次 apply 之后」的新日志和新增失败归档 | 避免历史 `SendPayloadApplicationComplete [0]` 误判为真成功 |
| 4 | 错误码 4/9 进 `FAIL_CODES` 与 `code_to_text`/`die`，补充 `Failed to verify package`、`Didn't get enough bytes` 等日志正则 | 不再漏判传输/解压/温控错误 |

## 四、经验沉淀（踩坑要点）

1. **大包 size 永远不要从 zip 本地头 `csize` 取**：ZIP64 条目 `csize=0xFFFFFFFF` 占位，32 位 shell 算术必溢出。权威来源是 zip 内 `payload_properties.txt` 的 `FILE_SIZE=`。
2. **`le4`/`le2` 此类 32 位解析函数在 shell 里天生溢出**：如需通用，应改用 `od -t u4`（无符号读），或结果 `<0` 时 `+4294967296`。当前用 `FILE_SIZE` 覆盖主路径已够用。
3. **「签名校验失败」不一定是证书问题**：OTA 错误码 10 常是 size/offset 错导致的下游误报，先查 `PAYLOAD_SIZE` 是否 `-1`，再查证书绕过链路。
4. **引擎日志必须设锚点再 grep**：历史 `SendPayloadApplicationComplete [0]` 会制造假成功，务必只比对「本次 apply 之后」的新增内容。
5. **路径转换不能无脑做**：FUSE 规避转换（`/storage/emulated/0/`→`/data/media/0/`）依赖设备 `/data` 是否为真实路径；压缩路径设备须跳过转换。

## 五、后续可优化（非必须）

- 把 `le4`/`le2` 统一改为无符号读法，避免其他偏移解析处再溢出。
- `/data` 压缩路径检测可做成显式判断，而非仅靠 `[ -f ]` 兜底。

## 六、OTA 安装移除 ROOT 选项经验（2026-08-26）

> 涉及文件：`app/src/main/assets/kr-script/ota/ota.xml`、`vivo_ota.sh`
> 决策：OTA 安装流程**不再支持一并 ROOT**（保留 ROOT 滑块与 init_boot/boot 镜像写入移除）

### 1. 移除的两个直接诱因

- **假成功导致校验报错**：之前的「假成功」误判（见第三节第 3 点）会把已修补的 `init_boot` 写入目标槽。之后平刷同一 OTA 包时，系统检测到 `init_boot` 已被改动 → 触发 payload 校验报错，**包刷不进去**。
- **ROOT 失败会阻断 LK 刷入、存在变砖风险**：脚本里 `init_boot`(ROOT) 写入在前、`LK` 刷入在后。若 ROOT 镜像写入失败（`dd` 失败 `die`），后续 LK 修补根本不会执行 → bootloader 与系统不匹配，**变砖**。

### 2. 移除方式（不是简单删 XML，要同步参数序）

ROOT 原先占参数序第 5/8/9 位（`rt` / `rp` / `ri`），LK 占第 10/11 位（因靠后才需 `${10}`/`${11}` 带大括号）。

**仅注释 XML 参数会错位**：去掉 root 三项后，位置整体前移 2 位，若脚本不跟着改，LK 会取到错误的值（复用 `rb`/`fc` 的值），导致「勾选 LK 却没日志/不刷入」的同类问题复发。

正确做法（均已落实）：
1. **XML**：注释 root 三个 `<param>`；`<set>` 去掉 `rt/rp/ri` 解析；调用改为 `rom dg ex ce rb fc lk li`（8 个位置参数）。
2. **脚本**：root 块改为 `ROOT_ENABLED=0` **硬关闭**（即便误传环境变量也不执行写入，杜绝残留逻辑触发）；LK 参数从 `${10}`/`${11}` 改为 `${7}`/`${8}`；die 提示「第11参数」→「第8参数」；顶部参数总览注释同步更新。
3. 自检一致性：`XML 8 个位置参数` = `脚本 $1~$8`，LK 用 `${7}`/`${8}` 完全对齐。

### 3. 经验沉淀

- **删一个 shell 位置参数，必须全局重排并校验**：shell 位置参数 `$1..$N` 是隐式契约，XML 调用与脚本读取必须同时改、同时数位数。建议改动后做一次「参数序号对照表」自检（本次即如此）。
- **高风险写入放最后、且不要互相阻塞**：bootloader(LK) 这类「刷错就变砖」的操作，不应排在可能失败的 ROOT 写入之后。移除 ROOT 后 LK 反而更安全，因为它不再是「前序失败就跳过」的受害者。
- **「假成功」的连锁危害远超表面**：校验误判不仅骗过用户，还会留下被改动的 `init_boot`，污染后续平刷。修复假成功（日志锚点）与移除 ROOT 应配套，否则前者修好反而暴露后者的隐患。
- **功能下线要在 UI 与脚本两侧都留痕**：XML 注释写清原因，脚本保留硬关闭的死代码（带说明），比彻底删除更利于后人追溯「为什么没有 ROOT 选项」。

## 七、参数重排不彻底：reboot/force 读错位残留（2026-08-27 发现并修复）

> 涉及文件：`app/src/main/assets/kr-script/ota/vivo_ota.sh`
> 背景：第六节的 ROOT 移除重排只改对了 lk（`${10}/${11}` → `${7}/${8}`），**漏改了 reboot 和 force 两处**。

### 1. 错位详情

XML 实际传参 8 个：`$1=rom $2=dg $3=ex $4=ce $5=rb(reboot) $6=fc(force) $7=lk $8=li(lk_img)`，但脚本读的是：

| 开关 | 脚本误读位置 | 实际读到 | 后果 |
|------|------------|---------|------|
| reboot | `$6` | fc | 勾「强制重刷」意外触发自动重启；勾「刷完重启」反而不重启 |
| force | `$7` | lk | 勾「刷入 LK」意外触发 `FORCE_REFRESH=1` 清空 update_engine 状态强制重刷 |

特征：**脚本内两处注释自相矛盾**——force 段注释写「第7参数(force)」，LK 段注释写 `$7=lk`，同一个 `$7` 被两处各自认领，即重排混乱的直接证据。

### 2. 修复内容

1. force 判断 `$7` → `$6`；reboot 判断 `$6` → `$5`（各留一行修订注释说明原错误）。
2. 第 0 节校验后新增**参数序快照日志**：`log "参数快照: dg=$2 ex=$3 ce=$4 rb=$5 fc=$6 lk=$7 lk_img=$8"`，跑一次即可目视核对参数契约。
3. 注释修正：「前移 2 位」→「前移 3 位」（root 原占 $5/$8/$9 三位，lk 从 ${10} 前移 3 位到 $7）。

### 3. 经验沉淀

- **重排位置参数必须 grep 全量引用点，不能靠逐段人眼过**：`grep -n '\$\{?[0-9]\}?\?'` 列出所有 `$N` 引用，逐一对照新参数表。第六节的「参数序号对照表自检」实际只对照了新增/显眼的三处（lk/lk_img/die 文案），漏掉了语义不同的 reboot/force。
- **同一位置参数被两处注释各自认领 = 必有错位**：注释矛盾是重排事故的最强信号，看到即查。
- **改 assets 下的脚本必须重新构建 APK**：设备上生效的是 `build/intermediates/.../mergeDebugAssets` 合并产物，只改源文件不重打包等于没改（也会造成「源码已修但真机复现」的假象）。
