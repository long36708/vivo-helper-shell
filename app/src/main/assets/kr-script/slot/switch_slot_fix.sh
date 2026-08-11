#!/system/bin/sh
# ============================================================
#  重启到另一卡槽 (A/B 槽位切换) - AIDL 修复版 v2
#  关键修正:
#  - getActiveBootSlot 读的是"当前运行槽位"(ro.boot.slot_suffix),
#    重启前永远不会变成新槽位, 因此【不再用它复核】;
#  - setActiveBootSlot 写 misc 分区 0x800 boot_ctrl 结构,
#    LK 下次开机读取它决定启动槽位;
#  - 只校验 set 返回值 + 直接读 misc 确认写入。
# ============================================================
HAL="android.hardware.boot.IBootControl/default"

# --- 1. 读取当前运行槽位 ---
cur_hex=$(su -c "service call $HAL 1 2>/dev/null" | grep -oE '[0-9a-f]{8}' | head -1)
case "$cur_hex" in
    00000000) cur=0 ;;
    00000001) cur=1 ;;
    *) echo "[FAIL] 无法读取当前槽位 (输出: $cur_hex)"; exit 1 ;;
esac
echo "[OK] 当前槽位: slot $cur ($([ $cur = 0 ] && echo _a || echo _b))"

# --- 2. 目标槽位 ---
if [ "$cur" = "0" ]; then target=1; else target=0; fi
echo "[..] 目标槽位: slot $target ($([ $target = 0 ] && echo _a || echo _b))"

# --- 3. 切换 (setActiveBootSlot, confirm=true) ---
r=$(su -c "service call $HAL 2 i32 $target i32 1 s16 longmo-switch-slot 2>/dev/null")
r_hex=$(printf '%s\n' "$r" | grep -oE '[0-9a-f]{8}' | head -1)
if [ "$r_hex" != "00000000" ]; then
    echo "[FAIL] setActiveBootSlot 调用失败 (返回: $r)"
    exit 1
fi
echo "[OK] setActiveBootSlot($target) 调用成功"

# --- 4. 直接读 misc boot_ctrl 确认写入 (root) ---
pend=$(dd if=/dev/block/by-name/misc bs=1 skip=2048 count=2 2>/dev/null)
case "$pend" in
    _a) [ "$target" = "0" ] && echo "[OK] misc 已写入 _a" || echo "[WARN] misc 仍是 $pend" ;;
    _b) [ "$target" = "1" ] && echo "[OK] misc 已写入 _b" || echo "[WARN] misc 仍是 $pend" ;;
    *)  echo "[WARN] 无法识别 misc 槽位标记: $pend" ;;
esac

# --- 5. 重启 (LK 将按 misc 决定槽位) ---
echo "[OK] 准备重启, LK 将引导到 slot $target ..."
sync
sleep 3
reboot
