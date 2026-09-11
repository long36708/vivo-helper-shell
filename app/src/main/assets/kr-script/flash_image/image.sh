#!/system/bin/sh
###############################################################
#  分区镜像读写 (image-level partition R/W)
# ------------------------------------------------------------
#  以整个分区为最小单位: 分区 -> .img (读/备份), .img -> 分区 (写/刷入)。
#  不解析、不修改文件系统内容, 因此绕过 dm-verity。
#  与「把分区挂载成可写」(挂载级读写) 是两条不同的路径, 本脚本不做后者。
#
#  用法:
#    sh image.sh list                      列出分区   (输出 "<分区名>|<显示名>")
#    sh image.sh backups                   列出备份   (输出 "<镜像路径>|<显示名>")
#    sh image.sh backup <多选值>            备份一个或多个分区 (多选值以换行分隔)
#    sh image.sh flash <分区名> <镜像> [none|system|recovery|fastboot]
#    sh image.sh restore <备份镜像路径> [none|system|recovery|fastboot]
#
#  依赖: Root; busybox / blockdev / od 均为可选, 缺失时自动降级。
###############################################################

BB="$BUSYBOX"
[ -x "$BB" ] || BB="$TOOLKIT/busybox"
[ -x "$BB" ] || BB=busybox
command -v "$BB" >/dev/null 2>&1 || BB=""

TEMP_DIR="${TEMP_DIR:-/data/local/tmp}"
SLOT_SUFFIX=$(getprop ro.boot.slot_suffix 2>/dev/null)

# 备份目录: 公共下载目录优先 (备份的意义就是能取出来), 逐级回退
BACKUP_ROOT=""
for base in "${SDCARD_PATH:-}" /sdcard /storage/emulated/0 /data/media/0; do
    [ -n "$base" ] || continue
    cand="$base/Download/VivoHelper/partitions"
    if mkdir -p "$cand" 2>/dev/null && [ -d "$cand" ]; then
        BACKUP_ROOT="$cand"
        break
    fi
done
[ -n "$BACKUP_ROOT" ] || BACKUP_ROOT="/sdcard/Download/VivoHelper/partitions"

die() { echo "！$*"; exit 1; }

usage() {
    echo "用法:"
    echo "  sh image.sh list"
    echo "  sh image.sh backups"
    echo "  sh image.sh backup <多选值>"
    echo "  sh image.sh flash <分区名> <镜像> [none|system|recovery|fastboot]"
    echo "  sh image.sh restore <备份镜像路径> [none|system|recovery|fastboot]"
}

# ------------------------- 基础工具 -------------------------

file_size() {
    local s
    s=$(stat -c '%s' "$1" 2>/dev/null)
    [ -n "$s" ] || { [ -n "$BB" ] && s=$("$BB" stat -c '%s' "$1" 2>/dev/null); }
    case "$s" in ''|*[!0-9]*) s=0 ;; esac
    echo "$s"
}

human_size() {
    local s=$1
    case "$s" in ''|*[!0-9]*) s=0 ;; esac
    if [ "$s" -ge 1073741824 ]; then
        echo "$(( s / 1073741824 )).$(( (s % 1073741824) * 10 / 1073741824 ))GB"
    elif [ "$s" -ge 1048576 ]; then
        echo "$(( s / 1048576 ))MB"
    elif [ "$s" -ge 1024 ]; then
        echo "$(( s / 1024 ))KB"
    else
        echo "${s}B"
    fi
}

# 分区名 -> 块设备路径
resolve_part() {
    local n="$1" p
    case "$n" in
        /dev/*) [ -e "$n" ] && { echo "$n"; return 0; } ;;
    esac
    [ -e "/dev/block/by-name/$n" ] && { echo "/dev/block/by-name/$n"; return 0; }
    p=$(find /dev/block -name "$n" 2>/dev/null | head -n 1)
    [ -n "$p" ] && [ -e "$p" ] && { echo "$p"; return 0; }
    return 1
}

# 块设备字节数
part_size() {
    local dev="$1" base s
    s=$(blockdev --getsize64 "$dev" 2>/dev/null)
    [ -n "$s" ] || { [ -n "$BB" ] && s=$("$BB" blockdev --getsize64 "$dev" 2>/dev/null); }
    if [ -z "$s" ]; then
        base=${dev##*/}
        [ -r "/sys/class/block/$base/size" ] && read s < "/sys/class/block/$base/size" 2>/dev/null
        [ -n "$s" ] && s=$(( s * 512 ))
    fi
    case "$s" in ''|*[!0-9]*) return 1 ;; esac
    echo "$s"
    return 0
}

enum_partitions() {
    if [ -d /dev/block/by-name ]; then
        ls -1 /dev/block/by-name 2>/dev/null
    else
        find /dev/block -mindepth 1 -type l 2>/dev/null | while IFS= read -r o; do
            echo "${o##*/}"
        done
    fi | sort -u
}

# 分区风险分类: 危险=整块写入会丢数据或不开机; 逻辑=super 逻辑分区
# 仅用于「标记」, 不做禁用 —— 排障场景必须能选到它们
hazard_kind() {
    local n="$1" b
    case "$n" in
        userdata|metadata|misc|frp|persist|persistblk|nvram|nvcfg|protect1|protect2|seccfg|proinfo)
            echo "危险"; return ;;
        super)
            echo "逻辑"; return ;;
    esac
    b=${n%_a}; b=${b%_b}
    case "$b" in
        system|system_ext|vendor|vendor_dlkm|product|odm|odm_dlkm) echo "逻辑" ;;
        *) echo "" ;;
    esac
}

# 取文件前 N 字节的十六进制串 (小写, 无分隔)
head_hex() {
    local f="$1" off="$2" cnt="$3" out=""
    out=$(dd if="$f" bs=1 skip="$off" count="$cnt" 2>/dev/null | od -An -tx1 -v 2>/dev/null | tr -d ' \n')
    if [ -z "$out" ] && [ -n "$BB" ]; then
        out=$("$BB" dd if="$f" bs=1 skip="$off" count="$cnt" 2>/dev/null | "$BB" od -An -tx1 -v 2>/dev/null | tr -d ' \n')
    fi
    if [ -z "$out" ] && [ -n "$BB" ]; then
        out=$("$BB" dd if="$f" bs=1 skip="$off" count="$cnt" 2>/dev/null | "$BB" xxd -p 2>/dev/null | tr -d '\n')
    fi
    echo "$out"
}

expected_magic() {
    case "$1" in
        boot|init_boot|recovery)             echo "414e44524f494421" ;;  # ANDROID!
        vendor_boot)                         echo "564e4452424f4f54" ;;  # VNDRBOOT
        vbmeta|vbmeta_system|vbmeta_vendor)  echo "41564230" ;;          # AVB0
        *) echo "" ;;
    esac
}

magic_name() {
    case "$1" in
        boot|init_boot|recovery)             echo "ANDROID!" ;;
        vendor_boot)                         echo "VNDRBOOT" ;;
        vbmeta|vbmeta_system|vbmeta_vendor)  echo "AVB0" ;;
        *) echo "" ;;
    esac
}

# ------------------- 备份目录所在分区判定 -------------------
# 备份目录在哪个分区上, 就绝不能备份那个分区: dd 会把输出文件自己也读进去,
# 文件一边长大一边被读, 直到存储写满。动态判定, 不写死分区名。

# 备份目录所在文件系统的底层块设备名。
# 递归 df: /sdcard 是 FUSE, 其源是 /data/media(目录), 再 df 一次才拿到块设备;
# /data 又可能挂在 dm-crypt 设备上, 所以还要处理 /dev/block/by-name 符号链接。
backup_dir_dev() {
    local p="$BACKUP_ROOT" src b real i=0
    while [ "$i" -lt 4 ]; do
        src=$(df -k "$p" 2>/dev/null | tail -n 1 | awk '{print $1}')
        [ -n "$src" ] || return 1
        [ "$src" = "$p" ] && return 1
        case "$src" in
            /dev/*)
                b=${src##*/}
                real=$(readlink -f "$src" 2>/dev/null)
                [ -n "$real" ] && b=${real##*/}
                [ -d "/sys/block/$b" ] && { echo "$b"; return 0; }
                return 1 ;;
            *) p="$src" ;;
        esac
        i=$(( i + 1 ))
    done
    return 1
}

is_backup_dir_on_dev() {
    local dev="$1" real tbase name bname slave s
    real=$(readlink -f "$dev" 2>/dev/null)
    tbase=${real##*/}
    name=${dev##*/}
    bname=$(backup_dir_dev) || return 1
    [ -n "$bname" ] || return 1
    if [ "$bname" = "$tbase" ] || [ "$bname" = "$name" ]; then return 0; fi
    # 备份目录挂在 dm 设备上时 (dm-crypt / 逻辑分区), 目标可能是它的底层从设备
    for slave in /sys/block/"$bname"/slaves/*; do
        [ -e "$slave" ] || continue
        s=${slave##*/}
        if [ "$s" = "$tbase" ] || [ "$s" = "$name" ]; then return 0; fi
    done
    return 1
}

# ------------------------- 命令实现 -------------------------

do_list() {
    enum_partitions | while IFS= read -r n; do
        [ -n "$n" ] || continue
        dev=$(resolve_part "$n") || continue
        size=$(part_size "$dev") || size=0
        label="$n"
        [ "$size" -gt 0 ] && label="$label 「$(human_size "$size")」"
        if [ -n "$SLOT_SUFFIX" ] && [ "$n" != "${n%$SLOT_SUFFIX}" ]; then
            label="$label ·当前槽"
        fi
        case $(hazard_kind "$n") in
            危险) label="$label ⚠危险" ;;
            逻辑) label="$label ⚠逻辑分区" ;;
        esac
        echo "$n|$label"
    done
}

do_backups() {
    local f n s found=0
    if [ -d "$BACKUP_ROOT" ]; then
        for f in $(find "$BACKUP_ROOT" -type f -name '*.img' 2>/dev/null | sort -r); do
            n=${f%/*}; n=${n##*/}
            s=$(file_size "$f")
            echo "$f|$n · ${f##*/} 「$(human_size "$s")」"
            found=1
        done
    fi
    [ "$found" = "1" ] || echo "-|（暂无备份，请先执行「备份分区」）"
}

do_backup() {
    local raw="$1" names="" line n dev size total=0 plan avail limit outdir out
    [ -n "$raw" ] || die "未选择任何分区"

    # 多选值以换行分隔, 逐行收拢成空格分隔的分区名列表
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        names="$names $line"
    done <<EOF
$raw
EOF
    set -- $names
    [ "$#" -gt 0 ] || die "未选择任何分区"

    plan="$TEMP_DIR/image_backup_plan.$$"
    : > "$plan" 2>/dev/null || die "无法写入临时目录 $TEMP_DIR"

    echo "备份目录：$BACKUP_ROOT"
    echo ""
    for n in "$@"; do
        if ! dev=$(resolve_part "$n"); then
            echo "！跳过 $n：找不到对应块设备"
            continue
        fi
        size=$(part_size "$dev") || size=0
        echo "$n|$dev|$size" >> "$plan"
        total=$(( total + size ))
    done
    [ -s "$plan" ] || { rm -f "$plan"; die "没有可备份的分区"; }

    echo "选中分区总大小：$(human_size "$total")"
    avail=$(df -k "$BACKUP_ROOT" 2>/dev/null | tail -n 1 | awk '{print $(NF-2)}')
    case "$avail" in ''|*[!0-9]*) avail=0 ;; esac
    if [ "$avail" -gt 0 ]; then
        limit=$(( avail * 1024 * 80 / 100 ))
        echo "备份目录可用空间：$(human_size $(( avail * 1024 )))"
        if [ "$total" -gt "$limit" ]; then
            echo ""
            echo "！拒绝备份：选中总大小超过可用空间的 80%"
            echo "  占比最大的分区："
            sort -t'|' -k3 -n -r "$plan" 2>/dev/null | head -n 3 | while IFS='|' read -r pn pd ps; do
                echo "    $pn  $(human_size "$ps")"
            done
            echo "  请取消勾选其中一部分再试。"
            echo "  （列表里的「全选」会把 userdata 这类上百 GB 的分区一起选上）"
            rm -f "$plan"
            exit 1
        fi
    fi

    echo ""
    while IFS='|' read -r n dev size; do
        [ -n "$n" ] || continue
        if is_backup_dir_on_dev "$dev"; then
            echo "！跳过 $n：备份目录就在这个分区上，备份它会把输出文件自己也读进去，必然写满存储"
            continue
        fi
        case $(hazard_kind "$n") in
            危险) echo "⚠ $n 是危险分区，整块写入会丢数据或不开机；本次为读取备份，继续" ;;
            逻辑) echo "⚠ $n 是 super 逻辑分区，读出的镜像只能整块写回同名分区" ;;
        esac
        outdir="$BACKUP_ROOT/$n"
        if ! mkdir -p "$outdir" 2>/dev/null; then
            echo "！跳过 $n：无法创建目录 $outdir"
            continue
        fi
        out="$outdir/${n}_$(date +%Y%m%d%H%M%S).img"
        echo "- 备份 $n（$(human_size "$size")）-> $out"
        if dd if="$dev" of="$out" bs=1048576 2>&1; then
            echo "  读出 $(human_size "$(file_size "$out")")"
        else
            echo "  ！失败，已删除不完整的文件"
            rm -f "$out"
        fi
    done < "$plan"
    rm -f "$plan"

    echo ""
    echo "备份结束，镜像保存在：$BACKUP_ROOT"
}

do_flash() {
    local n="$1" img="$2" mode="${3:-none}" dev size isize base exp nbytes got kind
    [ -n "$n" ] || die "未指定分区"
    [ -n "$img" ] || die "未指定镜像文件"
    dev=$(resolve_part "$n") || die "分区 $n 不存在"
    [ -f "$img" ] || die "镜像文件不存在：$img"

    size=$(part_size "$dev") || size=0
    isize=$(file_size "$img")

    echo "- 目标分区：$n  ($dev, $(human_size "$size"))"
    echo "- 镜像文件：$img  ($(human_size "$isize"))"

    kind=$(hazard_kind "$n")
    case "$kind" in
        危险) echo "⚠ $n 是危险分区，整块写入可能导致数据丢失或无法开机" ;;
        逻辑) echo "⚠ $n 是 super 逻辑分区，整块写入会破坏正在挂载的文件系统" ;;
    esac

    # 1) 稀疏镜像: 整块写进去必然是废数据, 且大小和魔数看起来都"正常"
    got=$(head_hex "$img" 0 4)
    if [ "$got" = "3aff26ed" ]; then
        die "拒绝写入：这是稀疏镜像 (sparse image)，真实内容要先 simg2img 转换；直接整块写入会让分区内容全错且无法开机"
    fi

    # 2) 大小
    if [ "$size" -gt 0 ] && [ "$isize" -gt "$size" ]; then
        die "拒绝写入：镜像 $(human_size "$isize") 大于分区 $(human_size "$size")"
    fi

    # 3) 已知分区的镜像头魔数
    base=${n%_a}; base=${base%_b}
    exp=$(expected_magic "$base")
    if [ -n "$exp" ]; then
        nbytes=$(( ${#exp} / 2 ))
        got=$(head_hex "$img" 0 "$nbytes")
        if [ -n "$got" ] && [ "$got" != "$exp" ]; then
            die "拒绝写入：$n 期望镜像头为 $(magic_name "$base")，实际读到 0x$got。分区和镜像多半对不上号"
        fi
        if [ -z "$got" ]; then
            echo "⚠ 本机缺少 od/xxd，无法校验 $n 的镜像头，已跳过这道检查"
        else
            echo "- 镜像头校验通过（$(magic_name "$base")）"
        fi
    fi

    echo "- 正在写入，请勿中断…"
    if ! dd if="$img" of="$dev" bs=1048576 2>&1; then
        die "写入失败：分区可能已损坏，请立刻用备份镜像还原"
    fi
    sync
    echo "- 写入完毕（$(human_size "$isize")）"

    do_reboot "$mode"
}

do_restore() {
    local img="$1" mode="${2:-none}" n
    [ -n "$img" ] || die "未指定备份镜像"
    [ "$img" = "-" ] && die "当前没有可用的备份镜像，请先执行「备份分区」"
    [ -f "$img" ] || die "备份镜像不存在：$img"
    case "$img" in
        "$BACKUP_ROOT"/*) ;;
        *) die "拒绝：$img 不在备份目录 $BACKUP_ROOT 内，请从列表里选" ;;
    esac
    n=${img%/*}; n=${n##*/}
    [ -n "$n" ] || die "无法从 $img 反解出分区名"
    echo "- 反解得到目标分区：$n"
    do_flash "$n" "$img" "$mode"
}

do_reboot() {
    local mode="$1" i
    case "$mode" in
        none|"") return 0 ;;
    esac
    echo "- 即将重启（$mode）…"
    i=3
    while [ "$i" -gt 0 ]; do
        echo "  $i…"
        sleep 1
        i=$(( i - 1 ))
    done
    case "$mode" in
        system)   /system/bin/reboot 2>/dev/null || reboot ;;
        recovery) /system/bin/reboot recovery 2>/dev/null || reboot recovery ;;
        fastboot) /system/bin/reboot fastboot 2>/dev/null || reboot fastboot ;;
        *) echo "  ！未知的重启模式：$mode" ;;
    esac
}

# --------------------------- 入口 ---------------------------

if [ "$(id -u 2>/dev/null)" != "0" ]; then
    die "当前不是 Root（uid=$(id -u 2>/dev/null)），读写分区需要 Root 权限"
fi

case "$1" in
    list)    do_list ;;
    backups) do_backups ;;
    backup)  do_backup "$2" ;;
    flash)   do_flash "$2" "$3" "$4" ;;
    restore) do_restore "$2" "$3" ;;
    help|-h|"") usage ;;
    *) echo "！未知命令：$1"; usage; exit 1 ;;
esac
