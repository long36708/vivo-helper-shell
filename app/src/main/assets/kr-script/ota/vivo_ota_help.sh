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
   - 正确做法: resetprop ro.ota.allow_downgrade true (ro 属性, setprop 无效, 必须 resetprop),
     再由 update_engine 重启/重读后生效 (vivo_ota.sh 勾"降级"会自动处理)。
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
   vivo 通道同样支持: 勾"证书绕过"时优先 magiskboot hexpatch update_engine 硬编码的
   /system/etc/security/otacerts.zip 路径指向自签 testcerts, 无 magiskboot 时降级
   mount --bind 覆盖系统证书; 校验失败(错误码10)自动回退系统证书重试一次。
   官方/编译包通常无需绕过 (zip 注释含 "signed by SignApk" 判为编译包, 仅提示)。
=======================================================
EOF
exit 0
