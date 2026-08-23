#!/system/bin/sh
# 原理说明 (仿 gt 的 describe 类)
cat <<'EOF'
================ vivo 强制安装 OTA 原理 =================

本工具基于 vivo 自研的 A/B OTA 通道 update_engine_client 实现，
而非像通用 KrScript 那样 patch update_engine 二进制证书。

关键要点 (来自逆向分析 + 真机实测, 以 vivo_ota.sh 实际实现为准):
1. 错误89 (附加载荷 / 相对路径):
   - 实测根因: 脚本为规避 FUSE 大包读取不全, cd / 后用**相对路径**引用附带 payloads,
     若这些附加 zip 缺失会报 89 (表象类似 "找不到 payload.bin", 但本质是引用文件缺失)。
   - 绕过: 包整体经 zip 内 payload.bin 的 offset 直读, 附带 zip 缺失通常可忽略;
     全程用绝对路径 /system/bin/update_engine_client 调用; 优先解析流式/Strored 条目。

2. 错误92 (版本守护 / 降级拦截):
   - 正确做法: setprop ro.ota.allow_downgrade 1 (降级开关), 重启 update_engine 生效后再刷。
   - 注意: persist.vivo.engmode=1 是**错误**的旧说法, vivo 该通道实际用 ro.ota.allow_downgrade。
   - 允许降级 / 跨大版本刷入

3. 附加载荷 (extras):
   - vivo 定制版 update_engine_client **不支持 --update-props** 参数 (会报未知 flag)。
   - 故 modem/mcf/oem 等附加 zip 不在本通道下发, 脚本对 extras 直接跳过 (log 提示)。
   - 这些固件由官方整包内的 payload 一并覆盖, 无需手动传 props。

4. 通道:
   - 使用系统 update_engine_client (非 recovery), 写入空闲 slot(_a/_b 另一侧)
   - 支持断点续传 (断网不影响已写入分区)

与通用 KrScript (gt) 的区别:
   gt 用 magiskboot hexpatch update_engine 的证书路径跳过签名校验;
   vivo 通道无法简单 patch (证书体系不同), 故走官方 update_engine_client +
   版本守护属性绕过, 更安全且不易触发安全启动失败。
=======================================================
EOF
exit 0
