#!/system/bin/sh
# 彩蛋页趣味脚本：全部为只读/娱乐内容，不修改任何系统状态
# 仅通过「关于」对话框连点应用 Logo 7 次进入的隐藏页调用
# 用法: egg_fun.sh <info|lucky>

case "$1" in
info)
    echo "===== 设备冷知识 ====="
    echo "机型: $(getprop ro.product.model 2>/dev/null || echo '未知')"
    echo "品牌: $(getprop ro.product.brand 2>/dev/null || echo '未知')"
    echo "Android: $(getprop ro.build.version.release 2>/dev/null || echo '未知')"
    echo "SDK: $(getprop ro.build.version.sdk 2>/dev/null || echo '未知')"
    echo "内核: $(uname -r 2>/dev/null || echo '未知')"
    if command -v su >/dev/null 2>&1; then
        echo "ROOT: 已检测到 su ($(su -v 2>/dev/null || echo '未知实现'))"
    else
        echo "ROOT: 未检测到 su"
    fi
    echo ""
    echo "小贴士: 连点 7 次就能回到这里，别告诉别人 ;)"
    ;;
lucky)
    colors="FF5733 33FF57 3357FF FFFF33 FF33FF 33FFFF FF8333 33FFD1 8C33FF D1FF33"
    # 用日期做种子，保证同一天颜色固定
    seed=$(date +%j)
    pick=$(echo "$seed % $(echo $colors | wc -w)" | bc 2>/dev/null || echo 0)
    i=0
    for c in $colors; do
        if [ "$i" = "$pick" ]; then
            echo "今天 ($seed) 的幸运色: #$c"
            echo "HEX: #$c  RGB: $(printf '%d,%d,%d' 0x${c:0:2} 0x${c:2:2} 0x${c:4:2} 2>/dev/null || echo '?,?,?')"
            break
        fi
        i=$((i+1))
    done
    ;;
*)
    echo "未知彩蛋指令: $1"
    echo "可用: info | lucky"
    ;;
esac
