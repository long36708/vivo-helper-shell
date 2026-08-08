# GT `ab_updater.sh` 与项目 `vivo_ota.sh` 对照

对照对象：
- **GT**：`com.wellqrg.gt` 的 `assets/kr-script/payload/ab_updater.sh`（逆向所得）
- **vivo**：本项目 `app/src/main/assets/kr-script/ota/vivo_ota.sh`（项目自研 vivo 专版）

项目 `vivo_ota.sh` 保留了 GT 的 payload 直刷框架，针对 vivo 的实测问题做了修正。
下表逐段对齐。

---

## 0. 参数接口

| GT（变量注入） | vivo（位置参数） | 说明 |
|---|---|---|
| `rom` | `$1` | OTA zip 路径 |
| `fota` | `$4 cert` | 非官方包证书绕过 |
| `root` | `$5 root` | 刷完保留 ROOT |
| `Format` | —（未复刻） | GT 的格式化手机，vivo 版未做 |
| `ChongQi` | `$6 reboot` | 完成后自动重启 |
| — | `$2 downgrade` | vivo 降级绕过（错误 92） |
| — | `$3 extras` | vivo 附加载荷（错误 89） |

> GT 靠引擎把 `<param>` export 成环境变量；vivo 版改成了顺序位置参数，由
> `ota.xml` 的 `<set>` 里先 `case` 把 bool 转成 `1/0` 再传入。

---

## 1. 逐段对照

| 环节 | GT `ab_updater.sh` | vivo `vivo_ota.sh` | 差异 / 结论 |
|---|---|---|---|
| **7za 部署** | 拷贝 `7za` 到 `/data/7za` | 不复制任何二进制，直接用系统 `update_engine_client` | vivo 注释明确：**绝不复制 update_engine 二进制**（GT 在 KernelSU 上实测也不复制）。原因：GT 复制 update_engine 到工具目录、错误 cwd 触发错误 89，需配 `vivo_ota89_fix` 模块才可刷入；vivo 版从根上绕开 |
| **降级** | `resetprop ro.build.date.utc 1600000000`（通用时间戳绕过） | `resetprop ro.ota.allow_downgrade true`（vivo 原生开关，错误 92） | vivo 用厂商原生属性，比改全局时间戳更精确 |
| **cwd / PATH** | 依赖引擎已设好环境 | `cd /` + 显式 `export PATH=...`（含 ksu/bin） | **vivo 特有踩坑**：错误 89 由相对路径解析引起，cwd 必须为 `/`；PATH 缺失会致 headers 为空 → update_engine 直接 IDLE |
| **签名检测** | `7za l` 查 `signed by SignApk` | `tail` 读 zip 末尾 EOCD 注释区，`strings`/`grep -a` 匹配 `signed by SignApk`（无 7za），**仅作信息提示**不切换策略 | 检测手段对齐 GT；签名检测不影响 payload 路线，路线由 streaming offset 决定 |
| **payload 定位** | 编译包：metadata 的 `ota-streaming-property-files` 取 offset/size；非编译包：解压整个 zip | 有 streaming offset/size 直读 zip；**无 offset 则直接把整个 zip 传给引擎**，由引擎自带 zip 解析自动定位 payload.bin + 附加载荷 | 引擎能自动定位（本包偏移 61）；**绝不整包解压**——解压出的裸 payload.bin 无整包签名 footer，会卡在 vivo 预检 `footer is wrong`（错误码10） |
| **解压目录** | `out_dir=${rom%.*}`（ROM 同目录去扩展名），存在则跳过 | 无（不再整包解压，直接传 zip） | vivo 整包解压会触发预检 footer 校验失败，故删除解压路径 |
| **headers** | `cat payload_properties.txt` 完整传给 client | `unzip -p` 读取后**保留换行**（每 KEY=VALUE 一行），空则 die | client 的 `--headers` 按 `\n` 切分列表（"one element per line"）；合并成单行会让 METADATA_SIZE 未解析 → Omaha `metadata_size=0` → 错误32（实测根因） |
| **证书绕过** | hexpatch 后 **手动 nohup 前台起补丁版 update_engine**，`>/sdcard/ota.log` | hexpatch 系统 update_engine；**不手动起进程**，走系统服务重启；无 magiskboot 时回退 `mount --bind` 覆盖 otacerts | GT 必须手动起补丁引擎（否则改的二进制不生效）；vivo 优先用**系统服务**，且多一层 bind 回退 |
| **官方包** | `pkill -9 update_engine; setprop ctl.start update_engine` | 同样先杀后启清状态机 + `sleep 2` | 一致 |
| **安装调用** | `update_engine_client --update --payload=file://... [--offset --size] --headers --follow` | 完全相同 | 一致 |
| **保留 ROOT** | `cd /data/adb/magisk; install_magisk` 修补对侧 boot | `magiskboot unpack` 对侧 boot，**仅占位**未完成修补 | vivo 版 root 保留尚未实现（注释注明需走 KernelSU/Magisk boot 修补流程） |
| **自动重启** | 5 秒倒计时后 `reboot` | `sleep 3; reboot` | 一致（vivo 更短） |
| **进度查看** | `logcat -s update_engine:v`（`cat.sh`） | `vivo_ota_status.sh` | 另见下方辅助对照 |

---

## 2. 辅助脚本对照

| 功能 | GT | vivo |
|---|---|---|
| 查看进度 | `payload/cat.sh` = `logcat -s update_engine:v` | `vivo_ota_status.sh` |
| 取消进行中 | `payload/quit.sh` = `update_engine_client --cancel` | `vivo_ota_cancel.sh` |
| 撤销已完成 | `payload/exit.sh` = `update_engine_client --reset_status` | —（未复刻） |
| 原理说明 | — | `vivo_ota_help.sh` |
| 遗留死代码 | `payload/fota.sh`（装 Fuck_OTA 模块，zip 未附带） | — |

---

## 3. vivo 版独有（GT 没有）的实测修正

1. **错误 89（附加载荷）**：`update_engine` 用**相对路径**读 `system/etc/oem-all-in-one.txt`，
   所以必须 `cwd=/` 且用系统 client，附加载荷（`common/modem`、`mcf_ota`、`oem_zip/oem|dyn|vgc`）
   只能随整包解压后由引擎自动读取，**vivo 的 client 不支持 `--update-props`**。
2. **错误 92（降级）**：vivo 原生 `ro.ota.allow_downgrade=true`（ro 属性，需 resetprop）。
3. **headers 单行 + 完整性**：空 headers 是刷不进去的典型原因（IDLE）。
4. **PATH 兜底**：`su -c` 拉起时环境可能缺 `/system/bin`，需显式导出。
5. **多代号机型**：`pre-device` / `hardware-device` 与当前 `ro.product.device` 比对告警
   （vivo PD2415/PD2419 等多代号同系包）。
6. **错误 32（`metadata_size` 缺失，非 zip 定位问题）**：传 zip 时引擎能正确自动定位
   `payload.bin`（本包偏移 61 = 本地头 30 + 名字 11 + ZIP64 extra 20 字节），也能读取并
   校验全部附加载荷（`oem_*`/`modem`/`mcf_ota`/`dyn`/`vgc`，真机全部通过）；真正的失败点是
   headers 被 `tr '\n' ' '` 合并成单行 → client 按 `\n` 切分只得到 1 个元素 →
   `METADATA_SIZE` 未解析 → Omaha response `metadata_size=0` → `kDownloadInvalidMetadataSize`。
   修复：headers 每个 KEY=VALUE 独立一行（对齐 GT 的 `cat payload_properties.txt`）。
7. **错误 10（裸 payload.bin 无整包 footer）**：整包解压出的 `payload.bin` 没有 zip 的
   整包签名 footer（`signed by SignApk` 在 EOCD 注释区），vivo 预检 verifier
   `footer is wrong` → `Failed to verify package`。因此 vivo 路线**绝不整包解压**，
   直接把 zip 喂给引擎（引擎对 zip 的校验通过）。

---

## 4. 遗留差异 / 待办

- vivo 版未复刻 GT 的「格式化手机」（POWERWASH）开关。
- vivo 版「保留 ROOT」目前只有 `magiskboot unpack` 占位，未完成真正的 boot 修补写回。
- vivo 版未复刻「撤销已完成更新」（`--reset_status`）。
