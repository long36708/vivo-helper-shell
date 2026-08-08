#!/system/bin/sh
# 原理说明 (仿 gt 的 describe 类)
cat <<'EOF'
================ vivo 强制安装 OTA 原理 =================

本工具基于 vivo 自研的 A/B OTA 通道 update_engine_client 实现，
而非像通用 KrScript 那样 patch update_engine 二进制证书。

关键要点 (来自逆向分析):
1. 错误89 (找不到 payload.bin):
   - 必须用绝对路径 /system/bin/update_engine_client
   - 工作目录必须 cwd=/ (否则相对路径解析失败)
   - 优先解析 _streaming 条目, 残损包也能刷

2. 错误92 (版本守护 / 降级拦截):
   - 设置 persist.vivo.engmode=1 让 update_engine 跳过版本守护
   - 允许降级 / 跨大版本刷入

3. 附加载荷:
   - vivo OTA 含 modem/mcf/oem 等 zip, 需作为 --update-props
     传给 update_engine_client, 否则刷完变砖/无信号

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
