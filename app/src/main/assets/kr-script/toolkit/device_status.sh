#!/system/bin/sh
# ============================================================
#  设备状态检查  (vivo / Android)
# ------------------------------------------------------------
#  查看当前 Root 权限状态，以及 A/B 分区当前激活槽位
# ============================================================

echo "===== Root 权限检查 ====="
if [ "$(id -u)" -eq 0 ] || command -v su >/dev/null 2>&1; then
    if su -c "id -u" >/dev/null 2>&1; then
        echo "Root: 已获取 (uid=$(su -c 'id -u'))"
    else
        echo "Root: su 存在但未授权"
    fi
else
    echo "Root: 未获取"
fi

echo ""
echo "===== A/B 分区激活槽位 ====="
# 优先从多种属性读取当前激活槽后缀 (_a / _b)
suffix=""
for p in ro.boot.slot_suffix ro.vendor.boot.slot_suffix ro.boot.slot; do
    v=$(getprop "$p" 2>/dev/null)
    if [ -n "$v" ]; then
        suffix="$v"
        break
    fi
done

if [ -z "$suffix" ]; then
    # 尝试 bootctl（普通 shell 与 root 两种情况）
    cur=""
    if command -v bootctl >/dev/null 2>&1; then
        cur=$(bootctl get-active-boot-slot 2>/dev/null)
    fi
    if [ -z "$cur" ] && command -v su >/dev/null 2>&1; then
        cur=$(su -c "bootctl get-active-boot-slot" 2>/dev/null)
    fi
    if [ -n "$cur" ]; then
        slot_name=$([ "$cur" = "0" ] && echo "_a" || ([ "$cur" = "1" ] && echo "_b" || echo ""))
        echo "当前激活槽位: slot $cur ${slot_name}"
        case "$cur" in
        0) echo "另一个槽位: slot 1 (_b)" ;;
        1) echo "另一个槽位: slot 0 (_a)" ;;
        esac
    else
        echo "未检测到 A/B 分区信息 (可能为单分区设备)"
    fi
else
    echo "当前激活槽位后缀: $suffix"
    case "$suffix" in
    *_a) echo "对应槽位: slot 0 (_a)，另一个为 slot 1 (_b)" ;;
    *_b) echo "对应槽位: slot 1 (_b)，另一个为 slot 0 (_a)" ;;
    esac
fi
