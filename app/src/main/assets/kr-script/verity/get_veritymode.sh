#!/system/bin/sh
# ==========================================================
# get_veritymode.sh
# 获取当前 veritymode 状态，并动态检查 LK 补丁点
# 设备: vivo MT6991 / DSU 修复专用
# 用法: sh "$START_DIR/kr-script/verity/get_veritymode.sh"
# 说明: LK 里 enforcing 的位置可能随 LK 版本/重刷变化，
#       本脚本动态定位，不依赖写死的偏移。
# ==========================================================

# busybox 定位优先级：引擎注入的绝对路径 > 本仓库自带 toolkit > 系统 PATH
BB="$BUSYBOX"
[ -x "$BB" ] || BB="$TOOLKIT/busybox"
[ -x "$BB" ] || BB=busybox

echo "=========================================================="
echo " veritymode 状态检查  (vivo MT6991 / DSU 修复)"
echo " 时间: $($BB date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date)"
echo "=========================================================="

# ---------- 1. /proc/bootconfig（内核 bootconfig，最权威） ----------
echo ""
echo "[1] /proc/bootconfig"
VM=""
if [ -r /proc/bootconfig ]; then
    VM=$($BB grep '^androidboot.veritymode' /proc/bootconfig 2>/dev/null | $BB sed 's/.*= *"\(.*\)".*/\1/')
    echo "    androidboot.veritymode  = ${VM:-<未找到>}"
    $BB grep -E 'androidboot\.(verifiedbootstate|vbmeta\.device_state|slot_suffix|force_normal_boot)' /proc/bootconfig 2>/dev/null | $BB sed 's/^/    /'
else
    echo "    (无法读取 /proc/bootconfig)"
fi

# ---------- 2. 运行时属性 ----------
echo ""
echo "[2] ro.boot.* 属性"
found=0
for p in ro.boot.veritymode ro.boot.verifiedbootstate ro.boot.vbmeta.device_state ro.boot.slot ro.boot.slot_suffix; do
    v=$(getprop "$p" 2>/dev/null)
    if [ -n "$v" ]; then
        echo "    $p = $v"
        found=1
    fi
done
[ "$found" = "0" ] && echo "    (无相关属性)"

# ---------- 3. 结论 ----------
echo ""
case "$VM" in
    disabled)
        echo ">>> 结论: veritymode = DISABLED  -> 补丁已生效，verity 将被跳过"
        ;;
    enforcing)
        echo ">>> 结论: veritymode = ENFORCING -> verity 仍强制开启，补丁未生效"
        ;;
    *)
        echo ">>> 结论: veritymode = ${VM:-未知}  -> 既非 enforcing 也非 disabled，需进一步检查"
        ;;
esac

# ---------- 4. LK 补丁点检查（需 root，动态定位 enforcing） ----------
echo ""
echo "[3] LK 补丁点检查 (动态定位 enforcing 字符串)"
if [ "$(id -u)" = "0" ] && [ -r /dev/block/by-name/lk_a ]; then
    ENF_OFFS=$(grep -abo "enforcing" /dev/block/by-name/lk_a 2>/dev/null | cut -d: -f1)
    if [ -z "$ENF_OFFS" ]; then
        echo "    未发现 enforcing 字符串"
        echo ">>> LK 补丁点: 无 enforcing（可能已全部改为 disabled）"
    else
        all_disabled=1
        for off in $ENF_OFFS; do
            s=$($BB dd if=/dev/block/by-name/lk_a bs=1 skip=$off count=9 2>/dev/null | $BB tr -d '\000')
            printf "    offset %-9d : %s\n" "$off" "${s:-<读失败>}"
            [ "$s" = "disabled" ] || all_disabled=0
        done
        echo ""
        if [ "$all_disabled" = "1" ]; then
            echo ">>> LK 补丁点: 全部为 disabled -> LK 补丁已刷入"
        else
            echo ">>> LK 补丁点: 仍存在 enforcing -> LK 未打补丁 / 未刷入"
        fi
    fi
    echo "    lk_a sha256 : $($BB sha256sum /dev/block/by-name/lk_a 2>/dev/null | $BB cut -d' ' -f1)"
else
    echo "    (需要 root 才能读取 LK 分区，已跳过)"
fi

echo ""
echo "=========================================================="
