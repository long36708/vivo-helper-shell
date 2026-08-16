# 更新日志

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

