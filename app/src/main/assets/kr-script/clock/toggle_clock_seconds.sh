#!/system/bin/sh
# ============================================================
#  状态栏时间显秒 快速切换脚本  (vivo / Android 11+)
# ------------------------------------------------------------
#  用法:
#    sh 本脚本.sh             # 无参数 = 切换开关
#    sh 本脚本.sh on          # 开启状态栏时间显秒
#    sh 本脚本.sh off         # 关闭状态栏时间显秒
#    sh 本脚本.sh toggle      # 切换开关
#    sh 本脚本.sh status      # 查看当前状态
#    sh 本脚本.sh help        # 帮助
# ------------------------------------------------------------
#  原理: 通过 settings 修改 Secure.CLOCK_SECONDS
#        SystemUI 的 Clock 组件实时监听, 无需重启
# ============================================================

SETTINGS="settings"
KEY="clock_seconds"

usage() {
    echo "用法: sh $0 [on|off|toggle|status|help]"
    echo "  无参数   = 切换开关"
    echo "  on       = 开启状态栏时间显秒"
    echo "  off      = 关闭状态栏时间显秒"
    echo "  toggle   = 切换开关"
    echo "  status   = 查看当前状态"
}

# 读取当前值
get_status() {
    $SETTINGS get secure "$KEY" 2>/dev/null
}

# 判断是否开启
is_on() {
    case "$(get_status)" in
        1|true) return 0 ;;
        *)      return 1 ;;
    esac
}

# 写入设置 (参数: 0 或 1)
set_seconds() {
    if $SETTINGS put secure "$KEY" "$1" 2>/dev/null; then
        return 0
    else
        echo "[-] 写入失败: 当前环境无权限"
        echo "    请通过 adb shell 执行, 或以 root 身份运行"
        return 1
    fi
}

case "$1" in
    on)
        set_seconds 1 && echo "[OK] 已开启状态栏时间显秒 (clock_seconds=1)"
        ;;
    off)
        set_seconds 0 && echo "[OK] 已关闭状态栏时间显秒 (clock_seconds=0)"
        ;;
    toggle|"")
        if is_on; then
            set_seconds 0 && echo "[OK] 状态: 开启 -> 已切换为 关闭"
        else
            set_seconds 1 && echo "[OK] 状态: 关闭 -> 已切换为 开启"
        fi
        ;;
    status)
        if is_on; then
            echo "[状态] 时间显秒: 开启 (clock_seconds=1)"
        else
            echo "[状态] 时间显秒: 关闭 (clock_seconds=0)"
        fi
        ;;
    help|-h|--help)
        usage
        ;;
    *)
        echo "[-] 未知参数: $1"
        usage
        ;;
esac

echo "-------------------------------------------"
echo "提示: 设置实时生效, 无需重启"
echo "若个别 ROM 未立即生效, 可尝试:"
echo "  adb shell am force-stop com.android.systemui   (需 adb/root)"
