#!/system/bin/sh
# ============================================================================
#  vivo DSU 工具箱 (v1.0)
#  --------------------------------------------------------------------------
#  功能：打开/管理 vivo 上被隐藏的官方 DSU Loader、DSU Sideloader Plus，
#        查看 GSI/DSU 状态、检查环境前提。
#
#  适用：vivo / iQOO (OriginOS/Funtouch, Android 10+)，推荐已 ROOT + 已解BL
#  用法：
#     sh "$START_DIR/kr-script/dsu/dsu.sh"            # 交互菜单（仅命令行手动跑）
#     sh "$START_DIR/kr-script/dsu/dsu.sh" open       # 直接打开官方 DSU Loader（GSI 选择界面）
#     sh "$START_DIR/kr-script/dsu/dsu.sh" sideload   # 直接打开 DSU Sideloader Plus
#     sh "$START_DIR/kr-script/dsu/dsu.sh" status     # 查看 DSU / GSI 运行状态
#     sh "$START_DIR/kr-script/dsu/dsu.sh" check      # 环境前提检查（动态分区/服务/网络/root）
#     sh "$START_DIR/kr-script/dsu/dsu.sh" info       # 打印使用说明
#
#  原理：vivo 删掉了开发者选项里 DSU Loader 的 UI 入口，但 Activity 仍在
#        清单中且 exported=true，保留官方 intent，可直接拉起。
# ============================================================================

# ---- 可调常量 ---------------------------------------------------------------
OFFICIAL_INTENT="android.settings.development.START_DSU_LOADER"
OFFICIAL_COMPONENT="com.android.settings/.development.DSULoader"
SIDELOAD_COMPONENT="yangfentuozi.dsusideloaderplus/.MainActivity"
GSI_LIST_URL="https://dl.google.com/developers/android/gsi/gsi-src.json"

# ---- 基础工具 ---------------------------------------------------------------
say()  { echo "$*"; }
err()  { echo "[错误] $*"; }
ok()   { echo "[OK]   $*"; }
warn() { echo "[注意] $*"; }

# ---- 打开官方 DSU Loader -----------------------------------------------------
open_official() {
    say ""
    say ">>> 尝试拉起官方 DSU Loader（GSI 选择界面）..."
    if am start -a "$OFFICIAL_INTENT" 2>&1; then
        ok "已发送 Intent: $OFFICIAL_INTENT"
        say "    若上面未显示 Starting，改用显式组件方式："
        am start -n "$OFFICIAL_COMPONENT" 2>&1
    else
        say ">>> 改用显式组件方式..."
        am start -n "$OFFICIAL_COMPONENT" 2>&1
    fi
    say ""
    say "    界面操作：选择官方 GSI → 下载 → 安装 → 在通知栏点“重启进入 GSI”。"
}

# ---- 打开 DSU Sideloader Plus ------------------------------------------------
open_sideload() {
    say ""
    say ">>> 打开 DSU Sideloader Plus（第三方 GSI 旁加载工具）..."
    if am start -n "$SIDELOAD_COMPONENT" 2>&1; then
        ok "已启动: $SIDELOAD_COMPONENT"
    else
        err "启动失败。请确认已安装 DSU Sideloader Plus，或改用官方 Loader。"
    fi
}

# ---- 查看 DSU / GSI 状态 -----------------------------------------------------
status() {
    say ""
    say "========== DSU / GSI 状态 =========="
    local running
    running=$(getprop ro.gsid.image_running 2>/dev/null)
    say "GSI 运行中  (ro.gsid.image_running): ${running:-未知}   ($([ "$running" = "1" ] && echo 正在运行GSI || echo 未运行/原系统))"
    say "GSI 列表覆盖 (persist.sys.fflag.override.settings_dynamic_system.list):"
    getprop persist.sys.fflag.override.settings_dynamic_system.list 2>/dev/null | sed 's/^/    /'
    if ls /data/gsi/*.gz >/dev/null 2>&1; then
        warn "检测到已放置的 GSI 镜像包（/data/gsi）："
        ls -la /data/gsi/ 2>/dev/null | sed 's/^/    /'
    else
        say "未在 /data/gsi 发现已放置的镜像包（正常，若用 Loader 下载则由系统管理）。"
    fi
    say "-----------------------------------"
    say "重启相关说明："
    say "  进入 GSI：在 DSU 常驻通知中选择“重启进入 GSI/重启到动态系统”。"
    say "  切回原系统：再次在通知中选择“重启到原始系统”，或进入 Loader 清除 GSI。"
    say "==================================="
}

# ---- 环境前提检查 -------------------------------------------------------------
check_env() {
    say ""
    say "========== 环境前提检查 =========="
    # 1) 动态分区（DSU 硬性前提）
    local dp
    dp=$(getprop ro.boot.dynamic_partitions 2>/dev/null)
    if [ "$dp" = "true" ]; then ok "动态分区: $dp (满足 DSU 前提)"; else warn "动态分区: ${dp:-空} (可能不支持 DSU)"; fi

    # 2) 框架 system_update 服务
    if service check system_update >/dev/null 2>&1 || service list 2>/dev/null | grep -q 'system_update'; then
        ok "框架服务 system_update: 存在"
    else
        warn "框架服务 system_update: 未检测到"
    fi

    # 3) 网络到 Google GSI 源
    say "GSI 列表源连通性:"
    if ping -c 2 -W 3 dl.google.com >/dev/null 2>&1; then
        ok "dl.google.com 可达 (ping 通)"
    else
        warn "dl.google.com 不可达（官方 Loader 拉列表可能失败，可用 Sideloader 或本地镜像）"
    fi

    # 4) Root 检测
    if [ "$(id -u)" = "0" ] || su -c id 2>/dev/null | grep -q 'uid=0'; then
        ok "Root: 可用"
    else
        warn "Root: 未检测到（DSU Loader 打开不需要 root，Sideloader 装镜像时最好有 root）"
    fi

    # 5) 基本系统信息
    say "Android 版本: $(getprop ro.system.build.version.release 2>/dev/null)"
    say "ABI:          $(getprop ro.product.cpu.abi 2>/dev/null)"
    say "安全补丁:     $(getprop ro.build.version.security_patch 2>/dev/null)"
    say "==================================="
}

# ---- 使用说明 -----------------------------------------------------------------
info() {
    cat <<'EOF'

========== vivo DSU 使用说明 ==========
背景：vivo 在开发者选项里隐藏了 DSU Loader 入口，但功能完整保留。
     本脚本通过官方 Intent 直接拉起隐藏的 DSU Loader。

【方案 A：官方 DSU Loader（推荐先试，免 root）】
  1) 打开 Loader（本脚本菜单选 1，或命令 sh dsu.sh open）
  2) 在界面勾选 Google 官方 GSI（如 arm64-v8a / Android 15）
  3) 点击安装，等待下载完成
  4) 下拉通知栏，点“重启进入 GSI”
  5) 进入 GSI 后，想回原系统：通知栏点“重启到原始系统”

【方案 B：DSU Sideloader Plus（第三方 GSI，需 root）】
  1) 菜单选 2 打开
  2) 选择本地 GSI 镜像（.img / .img.gz）旁加载
  3) 同样通过通知栏重启进入

【注意事项】
  * 官方 Loader 只认 Google/OEM 签名 GSI
  * DSU 是副系统：不清数据、不刷 BL、随时可回原系统，风险远低于直接刷分区
  * 装完可用本脚本“查看状态”确认 ro.gsid.image_running=1
=====================================
EOF
}

# ---- 交互菜单 -----------------------------------------------------------------
menu() {
    while :; do
        say ""
        say "========== vivo DSU 工具箱 =========="
        say " 1) 打开官方 DSU Loader（GSI 选择界面）"
        say " 2) 打开 DSU Sideloader Plus（第三方 GSI）"
        say " 3) 查看 DSU / GSI 状态"
        say " 4) 环境前提检查"
        say " 5) 使用说明"
        say " 0) 退出"
        say "====================================="
        printf "请选择 [0-5]: "
        read -r choice
        case "$choice" in
            1) open_official ;;
            2) open_sideload ;;
            3) status ;;
            4) check_env ;;
            5) info ;;
            0) say "再见。"; exit 0 ;;
            *) err "无效选项: $choice" ;;
        esac
    done
}

# ---- 入口 --------------------------------------------------------------------
case "$1" in
    open)     open_official ;;
    sideload) open_sideload ;;
    status)   status ;;
    check)    check_env ;;
    info)     info ;;
    "")       menu ;;
    *)        err "未知参数: $1 (可用: open | sideload | status | check | info)"; exit 1 ;;
esac
exit 0
