# vivo-ota-docs —— 强制安装 OTA 机制文档

GT 玩机助手（`com.wellqrg.gt`）「强制安装 OTA」逆向分析，以及与项目
`kr-scripts-next` 中 `vivo_ota.sh` 的对照说明。

## 文档索引

| 文件 | 内容 |
|---|---|
| `01-GT玩机助手强制安装OTA逆向分析.md` | 完整逆向分析：入口、参数注入、`ab_updater.sh` 每一步、辅助脚本、关键机制（签名绕过 / 降级 / 双槽位 / 保留ROOT） |
| `02-与vivo_ota.sh对照.md` | GT `ab_updater.sh` 与项目 `app/src/main/assets/kr-script/ota/vivo_ota.sh` 逐段对照，标注相同点、差异点与踩坑记录 |

## 一句话结论

GT 玩机助手的核心思路：

> **root 下把 `update_engine` 的 OTA 证书路径 hexpatch 成自定义证书
> （`/data/fuck_oddo_ota_testcerts.zip`）实现签名绕过，配合 `resetprop`
> 时间戳绕过 + 对侧槽位直刷 `payload.bin`，从而强装官方 / 降级 / 第三方
> A-B（含 VAB）分区 OTA 包。**

项目 `vivo_ota.sh` 是在此基础上的 vivo 专版：保留同样的 payload 直刷框架，
针对 vivo 的 `ro.ota.allow_downgrade`（错误 92）、附加载荷相对路径（错误 89）
做了实测修正。

## 实际刷入前提（GT 单独不够）

真机实测：**单用 GT 玩机助手刷不进去**，必须配套面具模块才能过错误 89/92。

- `vivo_ota89_fix`（**必须**）：GT 的 fota 分支会 `cp /system/bin/update_engine` 到
  工具目录并在错误 cwd 下前台运行 → 相对路径读附加载荷失败（错误 89）。该模块守护进程
  每 2 秒把副本替换成「`cd /` + `exec /system/bin/update_engine`」的包装器，让拷贝
  实际 exec 系统原版（cwd 正确）→ 89 消除。
- `vivo_ota_downgrade_bypass`（降级时需要）：`ro.ota.allow_downgrade=true`（错误 92）。

> 注意：模块换掉副本后，GT 对副本做的证书 hexpatch 也会被一并替换 → 证书绕过失效，
> 所以只对**有效签名官方包**可行（多代号包实测可过）。这正是项目 `vivo_ota.sh`
> 「绝不复制 update_engine 二进制、直接用系统服务」设计原则的来源——从根上绕开
> 这套外挂与 89 问题。

