#!/system/bin/sh
# ============================================================
# vivo 极暗模式 (Extra dim / Reduce bright colors) 快捷工具
# 设备验证: vivo V2419A / OriginOS / Android 15
#
# 用法:
#   sh extra_dim.sh open           跳转到"极暗模式"设置页 (无需root)
#   sh extra_dim.sh on             开启极暗模式 (需root/shell)
#   sh extra_dim.sh off            关闭极暗模式 (需root/shell)
#   sh extra_dim.sh toggle         开关切换 (需root/shell)
#   sh extra_dim.sh status         查看状态与强度
#   sh extra_dim.sh level <0-100>  设置极暗强度 (需root/shell)
#
# 手动直达命令(备忘):
#   am start -a android.settings.REDUCE_BRIGHT_COLORS_SETTINGS
#   am start -n com.android.settings/.Settings\$ReduceBrightColorsSettingsActivity
# ============================================================

REDUCE_KEY="reduce_bright_colors_activated"
LEVEL_KEY="reduce_bright_colors_level"

get_state() { settings get secure "$REDUCE_KEY"; }
get_level() { settings get secure "$LEVEL_KEY"; }
need_root() {
    u=$(id -u 2>/dev/null)
    if [ "$u" != "0" ] && [ "$u" != "2000" ]; then
        echo "错误: on/off/toggle/level 需要 root 或 adb shell 身份"
        exit 2
    fi
}

cmd_set() {
    settings put secure "$REDUCE_KEY" "$1" || { echo "写入失败(无权限?)"; exit 3; }
    if [ "$1" = "1" ]; then
        echo "极暗模式: 已开启 (强度: $(get_level))"
    else
        echo "极暗模式: 已关闭"
    fi
}

case "$1" in
    open)
        # 深链直达设置页, 无需 root, 兼容所有 Android 12+
        if am start -a android.settings.REDUCE_BRIGHT_COLORS_SETTINGS >/dev/null 2>&1; then
            echo "已跳转到 [极暗模式] 设置页"
        else
            echo "跳转失败: 设备可能不支持该 Action"
            exit 4
        fi
        ;;
    on)
        need_root; cmd_set 1
        ;;
    off)
        need_root; cmd_set 0
        ;;
    toggle)
        need_root
        if [ "$(get_state)" = "1" ]; then cmd_set 0; else cmd_set 1; fi
        ;;
    status)
        s=$(get_state)
        if [ "$s" = "1" ]; then st="开启"; else st="关闭"; fi
        echo "极暗模式: $st | 强度: $(get_level)"
        ;;
    level)
        need_root
        if [ -z "$2" ]; then
            echo "用法: sh extra_dim.sh level <0-100>"
            exit 1
        fi
        settings put secure "$LEVEL_KEY" "$2" && echo "强度已设为: $2"
        ;;
    *)
        echo "用法: sh extra_dim.sh [open|on|off|toggle|status|level N]"
        echo "  open          跳转极暗模式设置页(无需root)"
        echo "  on / off      直接开关(需root)"
        echo "  toggle        开关切换(需root)"
        echo "  status        查看状态"
        echo "  level <0-100> 设置强度"
        ;;
esac
