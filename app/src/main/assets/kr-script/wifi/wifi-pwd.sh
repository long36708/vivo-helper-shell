#!/system/bin/sh
# ============================================================
#  wifi-pwd.sh — 一键查看本机已保存的所有 WiFi 密码
#
#  用法:
#    sh wifi-pwd.sh          显示全部 WiFi 密码表格
#    sh wifi-pwd.sh -q       仅输出 "SSID<TAB>密码"（方便复制/二次处理）
#    sh wifi-pwd.sh -j       输出 JSON 数组
#    sh wifi-pwd.sh -h       显示帮助
#
#  依赖: root 权限 (通过 su 或 root shell 执行)
#  来源: /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml
# ============================================================

# ---------- 检查 root ----------
if [ "$(id -u)" != "0" ]; then
    echo "[!] 需要 root 权限，请使用 su 或 root shell 执行" >&2
    exit 1
fi

# ---------- 定位配置文件 ----------
XML=""
for f in \
    /data/misc/apexdata/com.android.wifi/WifiConfigStore.xml \
    /data/misc/wifi/WifiConfigStore.xml; do
    [ -r "$f" ] && { XML="$f"; break; }
done

if [ -z "$XML" ]; then
    echo "[!] 未找到 WiFi 配置文件 (WifiConfigStore.xml)" >&2
    exit 1
fi

# ---------- 参数解析 ----------
MODE="table"
case "$1" in
    -q) MODE="quiet" ;;
    -j) MODE="json" ;;
    -h|--help)
        echo "用法: sh wifi-pwd.sh [-q|-j|-h]"
        echo "  (无参数)  表格输出"
        echo "  -q        仅输出 SSID<TAB>密码"
        echo "  -j        输出 JSON 数组"
        echo "  -h        帮助"
        exit 0
        ;;
esac

# ---------- 解析并输出 ----------
awk -v mode="$MODE" '
function unescape(s,    t) {
    # 还原 XML 实体
    t = s
    gsub(/&quot;/, "\"", t)
    gsub(/&amp;/, "&", t)
    gsub(/&lt;/, "<", t)
    gsub(/&gt;/, ">", t)
    gsub(/&apos;/, "\x27", t)
    return t
}

/name="ConfigKey"/ {
    # 记录当前条目的 SSID 与安全类型
    ssid = "?"
    if (match($0, /&quot;[^&]*&quot;/)) {
        s = substr($0, RSTART + 6, RLENGTH - 12)
        if (s != "") ssid = unescape(s)
    }
    secur = "WPA2/WPA3"
    if (index($0, "NONE") > 0) secur = "开放(无密码)"
    if (index($0, "WPA3_SAE") > 0) secur = "WPA3"
    if (index($0, "WEP") > 0) secur = "WEP"
    seen[ssid] = 0
    next
}

/name="PreSharedKey"/ {
    if (ssid == "" || seen[ssid]++) next   # 同一网络去重(跳过第二条WPA3记录)
    if (match($0, /&quot;[^&]*&quot;/)) {
        pwd = unescape(substr($0, RSTART + 6, RLENGTH - 12))
    } else {
        pwd = ""   # 开放网络没有密码
    }
    n++

    if (mode == "json") {
        # JSON 转义
        e1 = ssid; e2 = pwd
        gsub(/\\/, "\\\\", e1); gsub(/"/, "\\\"", e1)
        gsub(/\\/, "\\\\", e2); gsub(/"/, "\\\"", e2)
        line = sprintf("{\"id\":%d,\"ssid\":\"%s\",\"password\":\"%s\",\"security\":\"%s\"}", n, e1, e2, secur)
        if (prev != "") print prev ","
        prev = line
    } else if (mode == "quiet") {
        printf "%s\t%s\n", ssid, pwd
    } else {
        printf "%-3d  %-24s %-22s %s\n", n, ssid, (pwd == "" ? "(无密码)" : pwd), secur
    }
}

END {
    if (mode == "json") {
        if (prev != "") print prev
        print "]"
    } else if (mode == "table") {
        printf "\n共 %d 个已保存 WiFi 网络\n", n
    }
}
' "$XML"
