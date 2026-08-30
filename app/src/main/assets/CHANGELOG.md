# 更新日志

## v0.4.0 - 2026-08-30

- 新增 vivo 电话暗码工具箱（secret_codes/secret_codes.xml 子页面）：集成文档确认可用的 13 个工程暗码（*#*#2288#*#*、*#*#113#*#*、*#*#4244#*#*、*#*#4636#*#*、*#*#5588#*#*、*#9966#、*#09#、*#0000#、*#06#、*#225#、*#558#、*#*#7777#*#*、*#*#112#*#*），点击即经拨号盘 intent 触发，主页以子页面入口呈现
- kr-script 主页重构与分组优化：
  - 暗码组拆为独立子页面（secret_codes.xml），主页不再堆砌 13 个 action
  - 「vivo DSU」从快捷工具中拆出独立成组
  - 主页分组按功能域重排：vivo OTA → 系统槽位 → vivo DSU → 快捷工具 → vivo 电话暗码
- 设备状态检查（Root 权限 / A/B 激活槽位）内联脚本抽离为 toolkit/device_status.sh，主页改用 `<set>` 引用，消除最长一段内联脚本
- 新增状态栏时间显秒切换（clock/toggle_clock_seconds.sh）：通过 settings 修改 Secure.CLOCK_SECONDS，支持 on/off/toggle/status，无需重启
- 新增极暗模式 (Extra dim) 工具（toolkit/extra_dim.sh）：控制 Reduce bright colors，`open` 跳设置页无需 root，`on/off/toggle/status/level` 需 root 或 adb shell

## v0.3.3 - 2026-08-27

- 修复 vivo OTA 安装脚本（vivo_ota.sh）位置参数错位（ROOT 三参数移除重排时的残留，仅 lk/lk_img 改对，reboot/force 漏改）：
  - force 开关误读 `$7`（实际是 lk），勾选「刷入 LK」会意外触发清空 update_engine 状态强制重刷；已改为读 `$6`
  - reboot 开关误读 `$6`（实际是 force），勾选「强制重刷」会意外自动重启、勾选「刷完重启」反而不重启；已改为读 `$5`
- 新增参数序快照日志：安装开始即打印 `dg/ex/ce/rb/fc/lk/lk_img` 各位置参数值，便于现场核对参数契约
- 修正脚本注释：参数「前移 2 位」实为「前移 3 位」（root 原占 $5/$8/$9 三位）

## v0.3.2 - 2026-08-25

- 借鉴 vivo_dg_app 的降级安装设计，为 vivo OTA 安装新增两个开关（ota.xml / vivo_ota.sh 配套更新）：
  - 属性伪装（SPF）：开启后在 `--headers` 追加伪造的 `ro.vivo.product.version` / `security_patch` / `anti_ver` / `device.name` 四项属性并 `resetprop` 写入，绕过部分机型对系统版本/防回滚/机型名的校验（此类校验失败可能触发数据清空）
  - 恢复出厂（POWERWASH）：开启后 headers 追加 `POWERWASH=1`，OTA 应用完成自动触发 factory reset 清空用户数据（危险操作，默认关闭）
- 两项能力默认关闭，以环境变量 `SPF` / `POWERWASH` 传入，不占用既有位置参数顺序；安装小结中展示其启用状态

## v0.3.1 - 2026-08-24

- 新增 veritymode 状态检查（kr-script/verity/get_veritymode.sh）：查看当前 veritymode（enforcing/disabled）及 LK 补丁点是否生效，DSU 修复专用
- 新增 vivo DSU 工具箱子页面（kr-script/dsu/dsu.xml）：打开官方 DSU Loader、DSU Sideloader Plus、查看状态、环境前提检查、使用说明，各功能以子命令 action 提供，避免交互菜单在无 TTY 环境死循环
- 两个脚本由 kr-script 根目录归位到独立目录（verity/、dsu/），并接入 home.xml 入口
- veritymode 脚本修正 busybox 定位：由写死其他 app 私有目录改为优先使用引擎注入的 $BUSYBOX，回退本仓库自带 toolkit/busybox，最后回退系统 PATH，摆脱对外部 app 的依赖
- 清理 veritymode 脚本中指向不存在文档（DSU_LK补丁_veritymode_disabled.md）的死引用提示

## v0.3.0 - 2026-08-23

- 重构 vivo OTA 安装流程（vivo_ota.sh 等）：规避引擎卡死与超时问题，安装流程更稳定
- OTA 写入成功后支持手动切换启动槽并回读确认（ota.xml / vivo_ota_ctrl.sh / vivo_ota_help.sh 配套更新），校验刷入结果

## v0.2.1 - 2026-08-16

- A/B 槽位管理脚本由 switch_ab.sh 替换为功能更全的 swab.sh（支持 active / 保护模式 / dump 等模式）
- 修复 swab.sh 写入 misc 分区静默失败导致保护模式误报成功的问题：写回 misc 的 dd 现在检查返回值并在失败时明确报错，不再因校验读回旧数据而误报
- 写回 misc 前尝试 `blockdev --setrw` 解锁只读分区
- 槽位状态显示改为真实从 misc 读回各槽 priority / tries_remaining / successful_boot，操作后状态更可信
- 保护模式 / active 模式界面文案改为大白话，操作后自动展示前后状态对比

## v0.2.0 - 2026-08-08

- 新增设备状态检查（Root 权限 / A/B 激活槽位）
- 新增清除 adb nonblocking_ffs 残留工具
- 新增 A/B 槽位管理（swab.sh）
- 新增 WiFi 密码查看
- 新增「查看更新日志」功能（关于页内可查看版本历史）

## v0.1.0 - 2026-07-30

- 首个发布版本
- 基础重启/关机菜单与 kr-script 框架接入
- 新增 vivo 强制安装 OTA

