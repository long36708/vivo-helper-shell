#!/system/bin/sh
# ============================================================
#  vivo OTA 排查 · 设备信息快照 (只读)
# ------------------------------------------------------------
#  依据《Updater 报错信息与排查手册》第九章排查工具箱:
#  输出关键属性、降级保护判定与 recovery 日志摘要,
#  用于排查"一直显示已是最新"(retcode 210)、检测失败等问题。
#  零风险只读: 只用 getprop / cat / ls / dumpsys, 不写任何状态。
# ============================================================

RED=$(printf '\033[31m'); YEL=$(printf '\033[33m'); GRN=$(printf '\033[32m'); RST=$(printf '\033[0m')

# root 探测: 可用 su 时通过 root_read/cat_file 读受限文件
ROOT_OK=0
if [ "$(id -u)" -eq 0 ]; then
    ROOT_OK=1
elif command -v su >/dev/null 2>&1 && su -c "id -u" >/dev/null 2>&1; then
    ROOT_OK=1
fi

cat_file() {
    # $1 = 文件路径; 输出内容, 失败返回非 0
    if [ -r "$1" ]; then
        cat "$1" 2>/dev/null
    elif [ "$ROOT_OK" = "1" ] && su -c "cat '$1'" 2>/dev/null; then
        :
    else
        return 1
    fi
}

soft_ver=$(getprop ro.vivo.product.version.incremental)

echo "=============================================="
echo "  vivo OTA 排查 · 设备信息快照"
echo "=============================================="

# ---------- 一、设备身份属性 ----------
echo ""
echo "===== 一、设备身份属性 ====="
prop() {
    v=$(getprop "$1" 2>/dev/null)
    if [ -n "$v" ]; then
        printf '%-40s %s\n' "$1" "$v"
    else
        printf '%-40s %s\n' "$1" "(空)"
    fi
}
prop ro.vivo.product.model          # 机型
prop ro.vivo.product.device         # 设备名
prop ro.vivo.hardware.version       # hwVer (签名被签数据字段)
prop ro.vivo.product.version.incremental   # softVersion (降级保护对比基准)
prop ro.build.version.group         # 版本线 (版本线不匹配 → 本地安装错误码 6)
prop ro.vivo.system.region.version  # 地区版本 (region_verison 比对)
prop ro.virtual_ab.enabled          # 虚拟 A/B (--sign 是否上传)
prop ro.vivo.ota.status
prop persist.vivo.systemunlock.version
v=$(getprop persist.sys.u.server.addr 2>/dev/null)
if [ -n "$v" ]; then
    printf '%-40s %s\n' "persist.sys.u.server.addr" "$v (⚠ 调试服务器覆盖中)"
else
    printf '%-40s %s\n' "persist.sys.u.server.addr" "(未覆盖, 使用默认服务器)"
fi
prop ro.build.version.incremental   # 参照
prop ro.build.display.id            # 参照
printf '%-40s %s\n' "Root" $([ "$ROOT_OK" = "1" ] && echo "已获取" || echo "未获取 (受限文件可能读不到)")

# ---------- 二、降级保护判定 ----------
echo ""
echo "===== 二、降级保护判定 ====="
dota=$(cat_file /cache/recovery/last_dota_info 2>/dev/null | tr -d ' \r\n')
if [ -z "$dota" ] && [ ! -e /cache/recovery/last_dota_info ]; then
    echo "last_dota_info: 不存在 (无降级保护记录, 正常)"
elif [ -z "$dota" ]; then
    echo "last_dota_info: 存在但无法读取内容 (需 root)"
else
    echo "last_dota_info 内容 : $dota"
    echo "当前 softVersion    : $soft_ver"
    if [ "$dota" = "$soft_ver" ]; then
        printf '%s\n' "${RED}⚠ 降级保护已触发: last_dota_info == softVersion${RST}"
        printf '%s\n' "${RED}  Updater 会强制 retcode 210 (一直显示\"已是最新\")。${RST}"
        printf '%s\n' "${YEL}  清除该文件需 root, 可解决回退后\"突然没更新了\"。${RST}"
    else
        printf '%s\n' "${GRN}正常: last_dota_info 与当前 softVersion 不一致, 降级保护未触发${RST}"
    fi
fi

# ---------- 三、关键文件存在性 ----------
echo ""
echo "===== 三、关键文件存在性 ====="
check_file() {
    if [ -e "$1" ]; then
        sz=$(cat_file "$1" 2>/dev/null | wc -c | tr -d ' ')
        if [ -n "$sz" ] && [ "$sz" -gt 0 ] 2>/dev/null; then
            echo "存在, 可读, ${sz} 字节: $1"
            return 0
        fi
        echo "存在但无读取权限 (需 root): $1"
    else
        echo "不存在: $1"
    fi
    return 1
}
check_file /cache/recovery/last_dota_info   # 降级检测
check_file /cache/recovery/last_ota_info    # recovery 与 Updater 交换 (含 imei)

# recovery 安装日志摘要: 哪个存在输出哪个的最后 20 行
rec_log=""
if [ -e /cache/recovery/last_log ]; then
    rec_log=/cache/recovery/last_log
elif [ -e /logdata/recovery/last_log ]; then
    rec_log=/logdata/recovery/last_log
fi
if [ -n "$rec_log" ]; then
    echo ""
    echo "----- recovery 日志摘要 (最后 20 行): $rec_log -----"
    cat_file "$rec_log" 2>/dev/null | tail -n 20 || echo "(存在但无读取权限, 需 root)"
else
    echo "recovery 日志不存在 (未找到 /cache/recovery/last_log 与 /logdata/recovery/last_log)"
fi

# ---------- 四、Updater 相关状态简查 ----------
echo ""
echo "===== 四、Updater 应用状态 ====="
upd_ver=$(dumpsys package com.bbk.updater 2>/dev/null | grep -m1 versionName | sed 's/.*versionName=//;s/[^0-9A-Za-z._-].*$//')
if [ -n "$upd_ver" ]; then
    echo "com.bbk.updater versionName: $upd_ver"
else
    echo "无法读取 com.bbk.updater 版本 (dumpsys 受限或未安装)"
fi
echo ""
echo "提示: 完整取证 (logcat tag 清单 / hook 点 / 错误码全表)"
echo "      请查看《Updater 报错信息与排查手册》第九章。"
echo "      常见码: 210=无更新或被拦截  1210=auth 取签失败"
echo "              1000=完整性校验失败 1002=签名校验失败 2001=AB 空间不足"
