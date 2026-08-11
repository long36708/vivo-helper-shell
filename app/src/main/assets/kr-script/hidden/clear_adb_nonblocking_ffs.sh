#!/system/bin/sh
# =============================================================================
# clear_adb_nonblocking_ffs.sh
# 用途：清除 persist.adb.nonblocking_ffs 系统属性的值
# -----------------------------------------------------------------------------
# 背景说明：
#   persist.adb.nonblocking_ffs 是 adbd（Android 设备端 ADB 守护进程）读取的
#   系统属性，用于控制 USB FunctionFS 端点是否采用非阻塞 I/O，默认开启(true)。
#   正常出厂 ROM 一般不会设置该属性；若它存在且值非空，会被"刷机属性残留"
#   检测类工具（如小骨检测 com.envdetector 的 FlashPropResidueDetector）判定
#   为刷机/模块残留痕迹，并以 FAIL/高风险项报告。
#
# 执行效果：
#   setprop 将该属性值置空后，检测工具的两条读取通道（getprop 命令、
#   native __system_property_get）均读到空值，从而不再报告该残留项。
#
# 注意事项：
#   1. setprop 只能把"值"清空，属性条目本身仍保留在
#      /data/property/persistent_properties 中，重启后依然存在且值为空。
#   2. 如需彻底删除该属性条目，可改用 Magisk 的 resetprop -d 命令，
#      或直接编辑 /data/property/persistent_properties（需 root 并重启）。
#   3. 修改 persist.* 属性需要相应权限（root 或 shell 环境）。
# =============================================================================

# 将 persist.adb.nonblocking_ffs 的值清空（保留属性名，值变为空字符串）
setprop persist.adb.nonblocking_ffs ""
