# vivo 玩机助手

基于 [kr-scripts-next](https://buylan01.github.io/kr-scripts-next/Intro.html) 框架打造的 vivo 玩机工具箱，通过 `xml + shell` 实现，ROOT 权限驱动，专治各种 vivo 刷机 / 玩机疑难杂症。

> 当前版本：v0.2.0（2026-08-08）

## 简介

- 利用 kr-script 框架，通过 `xml + shell` 快速创建具有 ROOT 权限的玩机工具
- 如果你对 `linux shell` 脚本语法有一定了解，上手将会非常迅速
- 大多数情况下，只需要修改应用 `assets` 中的静态文件，即可完成功能定义和修改
- 而不需要修改和编译 `Java、Kotlin` 代码

## 主要功能

### vivo 强制安装 OTA
- 强制降级 / 跨版本安装（绕过版本守护，解决 vivo 错误 92）
- 附带 OEM / 基带载荷（解决错误 89）
- 证书绕过（非官方包）
- 刷完保留 KernelSU / Magisk ROOT（写入已修补的 boot / init_boot 镜像）
- 可选刷入 LK（bootloader）
- 状态快照、实时进度监听、历史日志、取消安装、原理说明等辅助能力

### A/B 槽位管理
- 查看当前运行槽、待生效槽、misc 后缀、可启动性与 boot_ctrl CRC-32 校验
- 切换槽位（对位 / A / B），支持切换后自动重启
- 一键重启到另一卡槽

### 快捷工具
- 打开版本测试 `*#225#`
- 设备状态检查（Root 权限 / A/B 激活槽位）
- 查看已保存的 WiFi 密码（需 ROOT）
- 清除 adb nonblocking_ffs 残留（规避刷机属性残留检测，如小骨检测）
- 关机 / 重启 / 软重启 / 进 Recovery、Bootloader、Download、EDL、Fastbootd

### 隐藏彩蛋（连点关于页 Logo 7 次进入）
- 设备冷知识 / 今日幸运色
- Scene Magisk 模块仓库在线浏览
- GT 强制安装 OTA 包（fastbootd 模式）

## 更新日志

### v0.2.0 - 2026-08-08
- 新增设备状态检查（Root 权限 / A/B 激活槽位）
- 新增清除 adb nonblocking_ffs 残留工具
- 新增 A/B 槽位管理（switch_ab.sh）
- 新增 WiFi 密码查看
- 新增「查看更新日志」功能（关于页内可查看版本历史）

### v0.1.0 - 2026-07-30
- 首个发布版本
- 基础重启 / 关机菜单与 kr-script 框架接入
- 新增 vivo 强制安装 OTA

## 目录结构

```
app/src/main/assets/kr-script/
├── home.xml          # 主页：重启菜单 + OTA + 槽位 + 快捷工具
├── more.xml          # 更多：文档 / 工具 / 活动 / 致谢
├── ota/              # vivo 强制安装 OTA 脚本与配置
├── slot/             # A/B 槽位管理（swab.sh）
├── wifi/             # WiFi 密码查看
├── hidden/           # 残留清理等隐藏工具
├── toolkit/          # busybox / zip 等内置二进制
├── payload/          # GT 强制 OTA（payload.bin）
└── egg/              # 隐藏彩蛋页
```

## 注意事项

- 需要 ROOT（KernelSU / Magisk），部分功能需要解锁 bootloader
- 刷机有风险，操作前请备份数据，并确认镜像与机型严格匹配
- 项目基于 kr-scripts-next 开源模板搭建，感谢原作者

## 界面展示

![截图](/docs/screenshots/screenshot.jpg)
