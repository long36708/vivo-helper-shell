#!/system/bin/sh
# ============================================================================
# vivo_ota.sh —— vivo 强制安装 OTA 核心脚本 (真机实测对齐版)
# 由 projectKR KrScript 壳 (kr-scripts-next) 调用, 路径: kr-script/ota/vivo_ota.sh
#
# 参数(来自 payload.xml 的开关, 顺序固定):
#   $1 = rom        : OTA 包(zip) 绝对路径
#   $2 = downgrade  : 1=绕过版本守护(错误92)  ro.ota.allow_downgrade=true
#   $3 = extras     : 1=收集附加载荷(modem/mcf/oem/dyn/vgc)
#   $4 = cert       : 1=证书绕过(非官方包)  magiskboot hexpatch otacerts 路径
#   $5 = root       : 1=刷完保留ROOT(KernelSU/Magisk boot 修补)
#   $6 = reboot     : 1=完成后重启
#   $7 = force      : 1=强制重刷(清空 update_engine 持久化状态后重装, 忽略"已应用等重启"的包)
#
# 原理(依据真机逆向 update_engine 实测):
#  - 错误89(附加载荷): update_engine 用相对路径读 system/etc/oem-all-in-one.txt,
#    故必须 cwd=/ 且用系统 update_engine_client(绝不复制二进制)。
#  - 错误92(降级): vivo 原生开关 ro.ota.allow_downgrade=true (ro 属性, 需 resetprop)。
#  - 证书: update_engine 硬编码 /system/etc/security/otacerts.zip,
#    非官方包用 magiskboot hexpatch 替换为自签 testcerts; 绕过后校验失败
#    (错误码10) 自动回退系统证书重试一次。
#  - 编译包: zip 注释含 "signed by SignApk" 判为编译/官方包 (对齐 GT), 仅作信息提示
#    (官方包无需证书绕过)。payload 策略:
#    * 有 streaming offset/size (metadata 的 ota-streaming-property-files) -> 直读 zip。
#    * 无 streaming offset (vivo 本地 full 包) -> 自行从 zip 本地文件头解析 payload.bin
#      的偏移/大小, 用 --offset/--size 指向【原 zip 内】的 payload.bin。
#    为什么必须带 offset: vivo 的 update_engine 对本地包既要求显式 payload 位置
#    (否则 kDownloadInvalidMetadataSize=32), 又要求输入文件带 APK 签名 footer
#    (否则 Failed to verify package "footer is wrong"=10)。整包直传缺 offset -> 32;
#    单独解压 payload.bin 丢了 footer -> 10。只有"原 zip + offset/size"能同时规避。
#    绝不整包解压裸 payload.bin。
#  - headers: 每个 KEY=VALUE 必须独立一行。update_engine_client 的 --headers 按 '\n'
#    切分列表; 若用 tr '\n' ' ' 合并成单行, client 只解析出 FILE_HASH 一个键,
#    METADATA_SIZE 未解析 -> Omaha response metadata_size=0 -> kDownloadInvalidMetadataSize。
# ============================================================================

# 所有命令强制 cwd=/，避免 update_engine_client 相对路径解析错误(错误89)
cd /

# 显式设置 PATH: kr-script 通过 su -c 拉起本脚本时, 其环境可能不含
# /system/bin 等标准路径, 导致 grep/unzip/stat/awk 找不到, 进而 HEADERS
# 为空 -> update_engine 直接返回 IDLE (刷不进去)。这里兜底导出完整 PATH。
export PATH="/system/bin:/system/xbin:/sbin:/vendor/bin:/odm/bin:/data/adb/ksu/bin:/data/adb/magisk/bin:$PATH"

# 全程日志镜像到 /sdcard/ota.log (追加, 不覆盖), 兼容 GT 查看习惯/便于回看。
# 终端显示用 ANSI 颜色(成功绿/失败红/警告黄); 文件镜像保持纯文本(无转义, 便于 cat/回看)。
# Android 的 /system/bin/sh 多为 mksh/ash, 故用函数级双写, 不依赖 bash 进程替换。
UE_MIRROR=/sdcard/ota.log
UE_LOG_WRITABLE=0
{ [ -w /sdcard ] || mountpoint -q /sdcard 2>/dev/null; } && UE_LOG_WRITABLE=1

# ANSI 颜色码 (ash 兼容: 用 printf 直接输出转义)
C_RED=$(printf '\033[31m'); C_GRN=$(printf '\033[32m'); C_YEL=$(printf '\033[33m')
C_BLU=$(printf '\033[34m'); C_RST=$(printf '\033[0m')

# 单行着色: 根据关键字判断颜色 (大小写不敏感)
#   error/fail/失败/错误 -> 红; success/done/成功/完成 -> 绿; warn/⚠/警告 -> 黄
paint_line() {
  line="$1"
  lc=$(printf '%s' "$line" | tr 'A-Z' 'a-z')
  case "$lc" in
    *error*|*fail*|*失败*|*错误*|*fatal*|*denied*)
      printf '%s%s%s\n' "$C_RED" "$line" "$C_RST" ;;
    *success*|*done*|*成功*|*完成*|*okay*|*applied*)
      printf '%s%s%s\n' "$C_GRN" "$line" "$C_RST" ;;
    *warn*|*warning*|*"⚠"*|*警告*)
      printf '%s%s%s\n' "$C_YEL" "$line" "$C_RST" ;;
    *)
      printf '%s\n' "$line" ;;
  esac
}

# 实时流着色 + 文件无颜色镜像: 从 stdin 读, 终端逐行着色, 同时纯文本追加到镜像文件。
color_stream() {
  while IFS= read -r line; do
    paint_line "$line"
    [ "$UE_LOG_WRITABLE" = "1" ] && printf '%s\n' "$line" >> "$UE_MIRROR"
  done
}

# log: 终端着色输出 + 纯文本写入镜像文件
log() { paint_line "[vivo_ota] $*"; [ "$UE_LOG_WRITABLE" = "1" ] && echo "[vivo_ota] $*" >> "$UE_MIRROR"; }
die() { printf '%s%s%s\n' "$C_RED" "FAILED: $*" "$C_RST"; [ "$UE_LOG_WRITABLE" = "1" ] && echo "FAILED: $*" >> "$UE_MIRROR"; exit 1; }

if [ "$UE_LOG_WRITABLE" = "1" ]; then
  echo "[vivo_ota] $(date '+%F %T') 本次日志开始 (同时写入 $UE_MIRROR)" >> "$UE_MIRROR"
  printf '%s%s%s\n' "$C_BLU" "[vivo_ota] $(date '+%F %T') 本次日志开始 (终端带颜色, 文件纯文本: $UE_MIRROR)" "$C_RST"
fi

# 启动前清理: 仅当确实存在残留时才清理, 避免对正常状态误操作。
# 1) otacerts.zip 仅在其确被 bind 挂载时才卸载 (证书绕过失败时才会留下)
if grep -q ' /system/etc/security/otacerts.zip ' /proc/mounts 2>/dev/null \
   || mountpoint -q /system/etc/security/otacerts.zip 2>/dev/null; then
  umount /system/etc/security/otacerts.zip 2>/dev/null
  log "已卸载上次残留的 otacerts.zip bind 挂载"
fi
# 2) 仅当存在独立 update_engine 前台进程(工具 nohup 启动的 --logtostderr 形态)时才杀
if pgrep -f 'update_engine --logtostderr' >/dev/null 2>&1; then
  pkill -9 -f 'update_engine --logtostderr' 2>/dev/null
  log "已杀掉上次残留的独立 update_engine 前台进程"
fi

TMP=/data/local/tmp/vivo_ota
rm -rf "$TMP"; mkdir -p "$TMP"
UPDATE_ENGINE_CLIENT=/system/bin/update_engine_client

# root 工具链: 优先 KernelSU, 回退 Magisk
KSU_BIN=/data/adb/ksu/bin
MAGISK_BIN=/data/adb/magisk/bin
RESETPROP=""
MAGISKBOOT=""
for d in "$KSU_BIN" "$MAGISK_BIN"; do
  [ -z "$RESETPROP" ] && [ -x "$d/resetprop" ] && RESETPROP="$d/resetprop"
  [ -z "$MAGISKBOOT" ] && [ -x "$d/magiskboot" ] && MAGISKBOOT="$d/magiskboot"
done
[ -x "$RESETPROP" ] || RESETPROP="$(which resetprop 2>/dev/null)"
[ -x "$MAGISKBOOT" ] || MAGISKBOOT="$(which magiskboot 2>/dev/null)"

TESTCERTS=/data/fuck_oddo_ota_testcerts.zip

# ---------- 工具函数 ----------
log() { echo "[vivo_ota] $*"; }
die() { echo "FAILED: $*"; exit 1; }

# 小端读取 zip 本地头中的 2/4 字节整型
le2() { local f="$1" o="$2" b; b=$(dd if="$f" bs=1 skip="$o" count=2 2>/dev/null | od -A n -t u1 | tr -s ' '); set -- $b; echo $(( ${1:-0} + ${2:-0}*256 )); }
le4() { local f="$1" o="$2" b; b=$(dd if="$f" bs=1 skip="$o" count=4 2>/dev/null | od -A n -t u1 | tr -s ' '); set -- $b; echo $(( ${1:-0} + ${2:-0}*256 + ${3:-0}*65536 + ${4:-0}*16777216 )); }

# 从 zip 本地文件头解析 payload.bin 的偏移/大小 (仅支持 Stored 条目)。
# 成功: 设置 PAYLOAD_FILE/PAYLOAD_OFFSET/PAYLOAD_SIZE/USE_OFFSET 并返回 0
# 失败: 返回 1 (调用方回退整包解压)
locate_payload_in_zip() {
  local z="$1" hits spos s blob hdr method csize fnlen exlen off
  hits=$(grep -a -b -o 'payload\.bin' "$z" 2>/dev/null)
  [ -z "$hits" ] && { log "  ⚠ zip 内未找到 payload.bin 文件名, 回退整包解压"; return 1; }
  for spos in $(echo "$hits" | cut -d: -f1); do
    s=$spos; [ "$s" -gt 80 ] && s=$((spos-80)) || s=0
    blob=$(dd if="$z" bs=1 skip="$s" count=$((spos - s)) 2>/dev/null | od -A n -t u1 | tr -s ' ')
    set -- $blob
    local i=1 found=""
    while [ $# -gt 0 ]; do
      if [ "$1" = "80" ] && [ "$2" = "75" ] && [ "$3" = "3" ] && [ "$4" = "4" ]; then
        found=$(( s + i - 1 )); break
      fi
      shift; i=$((i+1))
    done
    [ -z "$found" ] && continue
    hdr=$found
    method=$(le2 "$z" $((hdr+8)))
    csize=$(le4 "$z" $((hdr+18)))
    fnlen=$(le2 "$z" $((hdr+26)))
    exlen=$(le2 "$z" $((hdr+28)))
    off=$(( hdr + 30 + fnlen + exlen ))
    if [ "$method" != "0" ]; then
      log "  ⚠ payload.bin 为压缩条目(method=$method), 无法用 offset 直读, 回退整包解压"
      return 1
    fi
    PAYLOAD_FILE="$z"; PAYLOAD_OFFSET="$off"; PAYLOAD_SIZE="$csize"; USE_OFFSET=1
    log "  从 zip 本地头解析 payload.bin: offset=$off size=$csize"
    return 0
  done
  log "  ⚠ 未在原 zip 定位到 payload.bin 本地头, 回退整包解压"
  return 1
}

# ---------- 0. 校验 ----------
ROM="$1"
[ -z "$ROM" ] && die "未选择 OTA 包 (param rom 为空)"
[ -f "$ROM" ]  || die "OTA 包不存在: $ROM"
[ -x "$UPDATE_ENGINE_CLIENT" ] || die "找不到 $UPDATE_ENGINE_CLIENT (非vivo/无root?)"

# ---------- 1. 解析 metadata ----------
log "解析 META-INF/com/android/metadata ..."
META="$TMP/metadata"
unzip -p "$ROM" "META-INF/com/android/metadata" > "$META" 2>/dev/null \
  || die "无法读取 metadata (不是标准 OTA 包?)"

# 机型匹配
DEVICE=$(grep -m1 '^pre-device=' "$META" | cut -d= -f2)
HW_DEVICE=$(grep -m1 '^hardware-device=' "$META" | cut -d= -f2)
CUR_DEVICE=$(getprop ro.product.device 2>/dev/null)
[ -n "$HW_DEVICE" ] && ! echo "$HW_DEVICE" | grep -qw "$CUR_DEVICE" \
  && log "⚠ hardware-device($HW_DEVICE) 不含当前($CUR_DEVICE), 跨机型风险"
[ -n "$DEVICE" ] && [ -n "$CUR_DEVICE" ] && [ "$DEVICE" != "$CUR_DEVICE" ] \
  && log "⚠ pre-device=$DEVICE 当前=$CUR_DEVICE (vivo 多代号, 谨慎)"

# ---------- 2. 降级绕过 (错误92) ----------
if [ "$2" = "1" ]; then
  log "降级模式: ro.ota.allow_downgrade=true (需 resetprop, ro 不可直接 setprop)"
  if [ -x "$RESETPROP" ]; then
    "$RESETPROP" ro.ota.allow_downgrade true
    log "  resetprop 已设置: $($RESETPROP ro.ota.allow_downgrade 2>/dev/null)"
  else
    # 退路: 直接 setprop (部分 ROM 允许 persist 覆盖)
    setprop ro.ota.allow_downgrade true 2>/dev/null
    setprop persist.ota.allow_downgrade true 2>/dev/null
    log "  ⚠ 未找到 resetprop, 已尝试 setprop (可能无效)"
  fi
fi

# ---------- 3. 附加载荷说明 (vivo 不再用 --update-props) ----------
# 实测: vivo 的 update_engine_client 不支持 --update-props (报 unknown flag),
#       附加载荷(modem/mcf/oem/dyn/vgc)不能在命令行传 offset/size。
#       正确做法: 直接把整个 zip 传给 update_engine, 引擎按
#       payload_properties.txt / system/etc/oem-all-in-one.txt 指示自动从 zip 读取
#       附加载荷 (真机实测全部校验通过, 对齐 GT)。
#       此处仅做信息性提示, 不再收集 EXTRA_PROPS。
if [ "$3" = "1" ]; then
  log "附加载荷: vivo 不支持 --update-props, 将由 update_engine 从 zip 自动读取"
  unzip -l "$ROM" 2>/dev/null | awk '{print $4}' \
    | grep -E '^(common/modem|common/mcf_ota|common/dsp|oem_zip/oem|oem_zip/dyn|oem_zip/vgc)' \
    | while read -r z; do log "  附加载荷(引擎自动读取) $z"; done
fi

# ---------- 4. 定位 payload.bin (对齐 GT 玩机助手 ab_updater.sh) ----------
# GT 用 `7za l | grep "signed by SignApk"` 判断编译/官方包 (SignApk 会把该串写入
# zip 注释)。项目无 7za, 改用 tail 读 zip 末尾 EOCD 注释区域匹配 (toybox unzip 无 -z)。
# 注意: 签名检测仅作信息提示。
log "定位 payload.bin ..."
PAYLOAD_FILE=""; PAYLOAD_OFFSET=""; PAYLOAD_SIZE=""; USE_OFFSET=0
COMPILED=0
# 双保险: strings 提取可打印串 或 grep -a 直接匹配, 任一命中即判编译包。
if tail -c 65536 "$ROM" 2>/dev/null | strings 2>/dev/null | grep -q "signed by SignApk" 2>/dev/null \
   || tail -c 65536 "$ROM" 2>/dev/null | grep -a -q "signed by SignApk" 2>/dev/null; then
  COMPILED=1
  log "  检测: 编译/官方包 (signed by SignApk)"
else
  log "  检测: 非编译包"
fi

# streaming: metadata 的 ota-streaming-property-files 声明 payload.bin:OFFSET:SIZE。
# 有 offset/size 优先用 --offset/--size 直读 zip (免解析)。
STREAM_PROP=$(grep -m1 '^ota-streaming-property-files=' "$META" | cut -d= -f2)
if [ -n "$STREAM_PROP" ] && echo "$STREAM_PROP" | grep -q "payload\.bin:"; then
  PAYLOAD_OFFSET=$(echo "$STREAM_PROP" | sed -n 's/.*payload\.bin:\([0-9]*\):\([0-9]*\).*/\1/p' | head -1)
  PAYLOAD_SIZE=$(echo  "$STREAM_PROP" | sed -n 's/.*payload\.bin:\([0-9]*\):\([0-9]*\).*/\2/p' | head -1)
  if [ -n "$PAYLOAD_OFFSET" ] && [ -n "$PAYLOAD_SIZE" ]; then
    PAYLOAD_FILE="$ROM"; USE_OFFSET=1
    log "  有 streaming offset/size: 从 zip 直读 payload.bin"
  fi
fi
if [ "$USE_OFFSET" -eq 0 ]; then
  # 无 streaming offset: 自行从 zip 本地头解析 payload.bin 偏移/大小, 用 --offset/--size
  # 指向【原 zip 内】的 payload.bin。vivo 实测: 整包直传(无 offset)报
  # kDownloadInvalidMetadataSize=32; 单独解压 payload.bin 因缺 APK footer 报
  # Failed to verify package=10。带 offset 指向原 zip 可同时规避这两个错误。
  if locate_payload_in_zip "$ROM"; then
    :
  else
    # 兜底: 解析失败 (如 payload.bin 被压缩) 时退回整包解压裸 payload.bin。
    # 警告: 此法在 vivo 上通常会触发错误10, 仅作最后手段。
    EXTRACT="$TMP/payload_extract"
    rm -rf "$EXTRACT"; mkdir -p "$EXTRACT"
    log "  解压整个 ROM 到 $EXTRACT (含附加载荷) ..."
    7za x -o"$EXTRACT" "$ROM" 2>/dev/null || unzip -o "$ROM" -d "$EXTRACT" >/dev/null 2>&1
    if [ -f "$EXTRACT/payload.bin" ]; then
      PAYLOAD_FILE="$EXTRACT/payload.bin"
      log "  已解压 payload.bin 到 $PAYLOAD_FILE (独立安装, 不带 offset)"
    else
      PAYLOAD_FILE="$ROM"
      log "  ⚠ 解压失败, 仍尝试整包直传"
    fi
  fi
fi

[ -n "$PAYLOAD_FILE" ] || die "找不到 payload.bin (包结构不支持, 非标准 OTA 包?)"

# payload_properties.txt 的校验头 —— 对齐 GT: 传完整内容(含 POWERWASH 等), 不能只
# 提取 4 个字段。每个 KEY=VALUE 必须独立一行: update_engine_client 的 --headers 按
# '\n' 切分列表 (帮助文档注明 "one element of the list per line")。实测把 headers 用
# tr '\n' ' ' 合并成单行后, client 只解析出 FILE_HASH 一个键 (其余全并进其 value),
# METADATA_SIZE 未解析 -> Omaha response metadata_size=0 -> kDownloadInvalidMetadataSize。
HEADERS=$(unzip -p "$ROM" "payload_properties.txt" 2>/dev/null | sed '/^[[:space:]]*$/d')
log "payload.bin -> $PAYLOAD_FILE (offset模式=$USE_OFFSET)"
log "headers(${#HEADERS}字节): ${HEADERS:-<空>}"

if [ -z "$HEADERS" ]; then
  log "  ⚠ headers 为空 (payload_properties.txt 缺失?)"
fi
[ -n "$HEADERS" ] || die "payload_properties.txt 校验头为空 (无法校验, 包损坏或非标准 OTA?)"

# ---------- 5. 证书绕过 (可选; 对齐 GT: 多数官方多代号包用系统证书即可过) ----------
# 经验: vivo PD2415/PD2419 等多代号同系包是带有效签名的官方包, update_engine 用系统
#       /system/etc/security/otacerts.zip 即可验证通过, 无需 hexpatch。GT 玩机助手在
#       KernelSU 上实测也不走 magiskboot(其二进制不在 ksu/bin), 直接喂系统 update_engine。
# 绕过优先级(仅在 $4=1 时):
#   1) magiskboot 可用 -> hexpatch update_engine 的硬编码 otacerts 路径指向 testcerts
#   2) 否则有 testcerts -> mount --bind 覆盖系统 /system/etc/security/otacerts.zip
#   3) 否则降级为系统证书直装 (官方包通常能过)
# 若绕过后校验失败(错误码10 Failed to verify package, 常见于对有效签名官方包勾了绕过),
# 段 7 会 restore_system_certs 回退系统证书重试一次。这里记录绕过状态供回退恢复。
SCRIPT_DIR=$(cd "$(dirname "$0")" 2>/dev/null; pwd)
RES_TESTCERTS="$SCRIPT_DIR/res/testcerts.zip"
[ -f "$RES_TESTCERTS" ] && TESTCERTS="$RES_TESTCERTS"
UE=/system/bin/update_engine
UE_BAK="$TMP/update_engine.bak"
SYS_OTACERTS_BACKUP="$TMP/otacerts.orig.zip"
CERT_ACTIVE=0; CERT_BIND=0; UE_PATCHED=0

if [ "$4" = "1" ]; then
  if [ -x "$MAGISKBOOT" ] && [ -f "$TESTCERTS" ]; then
    log "证书绕过: 用 magiskboot hexpatch update_engine 的 otacerts 路径"
    # hexpatch 把证书路径硬替换为 /data/fuck_oddo_ota_testcerts.zip,
    # 必须先在该路径放好 testcerts (对齐 GT ab_updater.sh), 否则补丁版找不到证书
    cp -f "$TESTCERTS" /data/fuck_oddo_ota_testcerts.zip 2>/dev/null
    PATCHED_CERT_READY=0
    [ -f /data/fuck_oddo_ota_testcerts.zip ] && PATCHED_CERT_READY=1
    cp -f "$UE" "$UE_BAK"
    "$MAGISKBOOT" hexpatch "$UE_BAK" \
      2F73797374656D2F6574632F73656375726974792F6F746163657274732E7A6970 \
      2F646174612F6675636B5F6F64646F5F6F74615F7465737463657274732E7A6970
    # remount/cp 失败(erofs 只读, Android15 常见)时 hexpatch 不生效, 降级 bind
    if [ "$PATCHED_CERT_READY" -eq 1 ] && mount -o rw,remount /system 2>/dev/null && cp -f "$UE_BAK" "$UE"; then
      log "  update_engine 证书路径已改为 /data/fuck_oddo_ota_testcerts.zip"
      UE_PATCHED=1; CERT_ACTIVE=1
    else
      log "  ⚠ hexpatch 未生效(/data 证书缺失或 /system 只读), 降级 mount --bind 覆盖 otacerts"
      if [ -f /system/etc/security/otacerts.zip ]; then
        cp -f /system/etc/security/otacerts.zip "$SYS_OTACERTS_BACKUP" 2>/dev/null
        mount -o bind "$TESTCERTS" /system/etc/security/otacerts.zip 2>/dev/null \
          && { log "  已 bind $TESTCERTS -> /system/etc/security/otacerts.zip"; CERT_BIND=1; CERT_ACTIVE=1; } \
          || log "  ⚠ bind 失败, 降级系统证书直装"
      else
        log "  ⚠ 系统无 otacerts.zip, 降级系统证书直装"
      fi
    fi
  elif [ -f "$TESTCERTS" ]; then
    log "证书绕过: magiskboot 缺失, 改用 mount --bind 覆盖系统 otacerts.zip"
    if [ -f /system/etc/security/otacerts.zip ]; then
      cp -f /system/etc/security/otacerts.zip "$SYS_OTACERTS_BACKUP" 2>/dev/null
      mount -o bind "$TESTCERTS" /system/etc/security/otacerts.zip 2>/dev/null \
        && { log "  已 bind $TESTCERTS -> /system/etc/security/otacerts.zip"; CERT_BIND=1; CERT_ACTIVE=1; } \
        || log "  ⚠ bind 失败 (erofs 只读?), 降级系统证书直装"
    else
      log "  ⚠ 系统无 otacerts.zip, 降级系统证书直装"
    fi
  else
    log "⚠ 无 testcerts, 降级为系统证书直装 (官方多代号包通常可过)"
  fi
fi

# ---------- 6. 当前 slot ----------
CUR_SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null || echo "_a")
TARGET_SLOT=$( [ "$CUR_SLOT" = "_a" ] && echo "_b" || echo "_a" )
log "当前 slot=$CUR_SLOT 目标 slot=$TARGET_SLOT"

# ---------- 6.5 OTA89 非守护保护 (借鉴 vivo_ota89_fix 思路, 但不用 daemon) ----------
# 根因: 第三方刷机工具 com.wellqrg.gt 检测到"编译ROM"后会
#   cp -f /system/bin/update_engine update_engine   # 复制二进制到工具目录
#   nohup ./update_engine ... &                       # cwd=工具目录启动
# update_engine 在错误 cwd 下用相对路径读 system/etc/oem-all-in-one.txt 失败 ->
# 错误89 "Failed to get additional payloads"。
# vivo_ota89_fix 模块用开机守护每2秒重写包装器来修复。本项目不使用 daemon:
# 改为"安装前一次性预置包装器 + 安装后立即清理"的一次性方案。
# 注: 本项目本就只用系统 update_engine_client 且强制 cd /, 正常情况下不会触发错误89;
#      此保护仅针对"同机并存 GT 工具、且其残留的 update_engine 副本被意外调用"的场景,
#      以及作为防御性兜底, 确保任何拉起 update_engine 的路径都以 cwd=/ 运行。
TOOL_DIR=/data/user/0/com.wellqrg.gt/files
TOOL_UE="$TOOL_DIR/update_engine"
OTA89_WRAPPER_ACTIVE=0

# 预置包装器: 若工具目录存在且其中的 update_engine 副本是被覆盖的二进制(>1MB),
# 则替换为 "强制 cd / 再 exec 系统原版" 的 shell 包装器。
ota89_install_wrapper() {
  [ -d "$TOOL_DIR" ] || return 0
  if [ -f "$TOOL_UE" ]; then
    local sz=0
    sz=$(stat -c %s "$TOOL_UE" 2>/dev/null || echo 0)
    if [ "$sz" -gt 1000000 ] 2>/dev/null; then
      cat > "$TOOL_UE" <<'EOF'
#!/system/bin/sh
# vivo_ota ota89 fix wrapper (非守护版): 强制正确 cwd, 再 exec 系统原版 update_engine
cd / || exit 1
exec /system/bin/update_engine "$@"
EOF
      chmod 755 "$TOOL_UE" 2>/dev/null
      OTA89_WRAPPER_ACTIVE=1
      log "  [ota89] 工具目录 update_engine 副本(>$sz bytes)已被覆盖为二进制, 已改写为 cwd=/ 包装器"
    fi
  fi
}

# 清理包装器: 安装结束后移除, 避免长期驻留影响工具正常使用。
ota89_cleanup_wrapper() {
  [ "$OTA89_WRAPPER_ACTIVE" = "1" ] || return 0
  rm -f "$TOOL_UE" 2>/dev/null
  OTA89_WRAPPER_ACTIVE=0
  log "  [ota89] 已移除临时包装器, 恢复工具目录 update_engine 原始状态"
}

# ---------- 7. 执行安装 (用系统服务, 绝不复制二进制) ----------
# 对齐 GT ab_updater.sh 官方包分支: 先杀掉并重启 update_engine 服务, 确保状态机干净,
# 再带 --update 调 client (vivo 精简版 client 缺 --update 不会发起 ApplyPayload, 直接 IDLE)。
run_client() {
  # 前台阻塞: client 带 --follow, 持续把 update_engine 状态回调(进度百分比/阶段)输出到
  # stdout/stderr, 先落到临时文件再经 color_stream 着色显示并纯文本镜像, 实时可见。
  # 强制 cwd=/ 避免相对路径读附加载荷失败(错误89)。
  # 退出码存入全局 UE_RC (先把输出到临时文件, 才能拿到 client 真实退出码, 不受管道影响)。
  cd /
  UE_RC=0
  UE_OUT="$TMP/ue_follow.out"
  if [ "$USE_OFFSET" -eq 1 ]; then
    "$UPDATE_ENGINE_CLIENT" --update --payload="file://$PAYLOAD_FILE" \
      --offset="$PAYLOAD_OFFSET" --size="$PAYLOAD_SIZE" \
      --headers="$HEADERS" --follow > "$UE_OUT" 2>&1
  else
    # 非 offset: 直接把整个 zip 作为 payload 传入, 不带 offset/size,
    # update_engine 自动定位 zip 内 payload.bin 并读取附加载荷 (对齐 GT 编译包分支)。
    "$UPDATE_ENGINE_CLIENT" --update --payload="file://$PAYLOAD_FILE" \
      --headers="$HEADERS" --follow > "$UE_OUT" 2>&1
  fi
  UE_RC=$?
  # 立即逐行着色显示 + 镜像文件 (实时性略低于管道, 但能拿到准确退出码, 且文件无颜色)
  color_stream < "$UE_OUT"
}

# update_engine 的 UPDATED_NEED_REBOOT 等状态会持久化在 /data/misc/update_engine 下,
# 单纯 pkill + 重启进程, 进程起来后会从磁盘恢复旧状态, 导致新 --update 被 66 拒绝。
#
# 重要: 清状态目录只删元数据(prefs/进度), 不会动已写进目标 slot 分区的镜像数据。
# 但为安全起见, 默认绝不主动清状态 —— 因为处于 UPDATED_NEED_REBOOT 往往意味着"上一次刷的包
# 已应用、正等重启生效", 此时应让用户去重启使其生效, 而不是清掉状态重刷(否则旧包可能白刷)。
# 仅当用户明确传 FORCE=1 (环境变量) 或第7参数(force)=1 时, 才允许清状态强制重刷。
clear_ue_state() {
  pkill -9 update_engine 2>/dev/null
  sleep 1
  # 候选状态目录(不同 ROM 路径略有差异), 只删状态文件不删整个目录避免权限问题
  for d in /data/misc/update_engine /data/misc/update_engine/prefs; do
    [ -d "$d" ] || continue
    log "  清空 update_engine 持久化状态: $d"
    find "$d" -maxdepth 1 -type f \( \
      -name 'update_engine_prefs*' -o \
      -name 'rollback*' -o \
      -name '*.json' -o \
      -name 'last_update*' \) -delete 2>/dev/null
  done
  # 兜底: 直接清空整个状态目录内容(部分 ROM 把状态放单文件)
  rm -f /data/misc/update_engine/update_engine_prefs 2>/dev/null
}

# 是否允许强制清状态重刷: 环境变量 FORCE=1 或第7参数(force)=1
# 与第6参数(reboot)解耦, 二者互不影响。
FORCE_REFRESH=0
[ "${FORCE}" = "1" ] && FORCE_REFRESH=1
[ "$7" = "1" ] && FORCE_REFRESH=1

# vivo 的 update_engine 是后台 daemon, 进度不回显到终端, 只落盘到:
#   /logdata/recovery/update_engine_log/update_engine.*
# 为实时展示进度, 安装期间后台 tail -F 该日志转发到终端(着色)并纯文本镜像; 安装结束后停掉。
UE_LOG_DIR=/logdata/recovery/update_engine_log
UE_TAIL_PID=0
start_ue_log_tail() {
  if [ -d "$UE_LOG_DIR" ] && command -v tail >/dev/null 2>&1; then
    # 最新那份日志文件(按 mtime), 不存在时 tail 会等待后续创建
    local latest target
    latest=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | head -1)
    if [ -n "$latest" ]; then
      target="$latest"
    else
      target="$UE_LOG_DIR/update_engine.*"
    fi
    # 终端实时着色 + 纯文本镜像到 $UE_MIRROR (color_stream 已处理双写)
    tail -F "$target" 2>/dev/null | color_stream &
    log "已开启 update_engine 日志实时转发(着色)并镜像到 $UE_MIRROR (tail -F $target)"
    UE_TAIL_PID=$!
  else
    log "  ⚠ 未找到 $UE_LOG_DIR, 无法实时转发进度(可手动 cat 查看)"
  fi
}
stop_ue_log_tail() {
  [ "$UE_TAIL_PID" -ne 0 ] 2>/dev/null && kill "$UE_TAIL_PID" 2>/dev/null
  UE_TAIL_PID=0
}

attempt_install() {
  # 仅当明确要强制重刷时才清状态; 否则只重启 daemon 以尽量保留"已应用等重启"的包
  if [ "$FORCE_REFRESH" = "1" ]; then
    clear_ue_state
  else
    pkill -9 update_engine 2>/dev/null
    sleep 1
  fi
  setprop ctl.start update_engine 2>/dev/null
  sleep 3
  # 确认 daemon 真的起来了, 没起来再拉一次
  if ! pgrep -x update_engine >/dev/null 2>&1; then
    log "  ⚠ update_engine 未自动拉起, 重试 ctl.start"
    setprop ctl.start update_engine 2>/dev/null
    sleep 3
  fi
  # 安装期间实时转发进度日志(双保险: 与下面 client --follow 的前台输出互补)
  start_ue_log_tail
  log "================ 以下为 update_engine 前台实时输出 ================"
  run_client
  RC=$UE_RC
  stop_ue_log_tail
  log "================ update_engine 前台输出结束 (RC=$RC) ==============="
  return $RC
}

restore_system_certs() {
  # 撤销证书绕过, 恢复系统证书: 卸载 bind + 还原被 hexpatch 的二进制
  if [ "$CERT_BIND" = "1" ]; then
    umount /system/etc/security/otacerts.zip 2>/dev/null
    CERT_BIND=0
    log "  已卸载 otacerts.zip 的 bind 挂载"
  fi
  if [ "$UE_PATCHED" = "1" ]; then
    if cp -f "$UE_BAK" "$UE" 2>/dev/null; then
      UE_PATCHED=0
      log "  已还原 /system/bin/update_engine 原版二进制"
    else
      log "  ⚠ 还原 update_engine 失败(/system 只读?), 重试仍可能用 testcerts"
    fi
  fi
}

# 安装前预置 ota89 包装器(防御性兜底, 非守护), 再真正执行安装
ota89_install_wrapper
attempt_install
RC=$?
# 安装结束(无论成败)清理临时包装器, 避免影响工具目录原有二进制
ota89_cleanup_wrapper

# 失败判定策略: 只有明确列入 FAIL_CODES 的错误码才视为失败, 其余一律当成功。
# 业务错误码语义: 10=签名/证书校验失败, 15=rootfs验证失败, 89/92=状态机/slot冲突。
# 其他(含 1、248=已应用等重启、以及任何未知值)都按正常处理, 不再误杀。
FAIL_CODES="10 15 89 92"
is_fail_code() {
  local c="$1" f
  for f in $FAIL_CODES; do
    [ "$c" = "$f" ] && return 0
  done
  return 1
}

# 248 = UPDATED_NEED_REBOOT: 上一次刷的包已应用、正等重启生效, 视为成功(只是需重启)。
# # 默认提示重启即可, 不重刷(避免覆盖已刷好的包)。FORCE_REFRESH=1 才清状态强制重刷。
# if [ "$RC" -eq 248 ] 2>/dev/null || grep -q "waiting for reboot" /proc/self/fd/2 2>/dev/null; then
#   if [ "$FORCE_REFRESH" = "1" ]; then
#     log "检测到 UPDATED_NEED_REBOOT, 但 FORCE=1 已设定: 清空状态并强制重刷当前包"
#     clear_ue_state
#     setprop ctl.start update_engine 2>/dev/null
#     sleep 3
#     run_client
#     RC=$?
#   else
#     log "update_engine 处于 UPDATED_NEED_REBOOT: 上一次刷的包已应用, 等待重启生效(视为成功)"
#     log "  请重启设备让已刷入的包生效。若确认要放弃旧包强制重刷当前包, 设 FORCE=1 或第7参数(force)传 1 后重试。"
#   fi
# fi

# 回退1: 证书绕过校验失败(错误码10=验证失败) -> 回退系统证书重试一次
# 注意: 仅当证书绕过确实生效过(CERT_ACTIVE=1)才回退, 避免无谓重试。
if [ "$RC" = "10" ] && [ "$CERT_ACTIVE" = "1" ]; then
  log "证书绕过校验失败(RC=10=Failed to verify package), 回退系统证书重试一次"
  restore_system_certs
  attempt_install
  RC=$UE_RC
  log "回退系统证书后重试返回 RC=$RC"
fi

# 失败收尾: 仅 FAIL_CODES 中的错误码才视为失败, 其余一律按正常继续
if is_fail_code "$RC"; then
  case "$RC" in
    15)
      # kNewRootfsVerificationError: payload 已写入目标 slot, 但新 rootfs 验证失败。
      # 最常见原因: 包机型与设备不符(如 PD2415 包刷 PD2419), 附加载荷(oem/vgc/modem)校验对不上;
      # 或证书绕过只覆盖了 otacerts.zip, 没绕过附加载荷的独立校验。
      log "诊断: RC=15 = kNewRootfsVerificationError (新 rootfs 验证失败)"
      log "  可能原因: (1) 机型不匹配(包含 PD2415 附加载荷, 当前 PD2419);"
      log "            (2) 证书绕过仅 bind 覆盖 otacerts.zip, 附加载荷(oem/vgc/modem)的独立校验未绕过;"
      log "            (3) 降级模式下部分分区 version/hash 校验不过。"
      log "  建议: 换对应机型(PD2419)的包; 或补全 magiskboot 做更彻底的二进制 patch; 用 logcat 看具体哪份载荷失败。"
      die "update_engine_client 返回 15 (rootfs 验证失败, 多因机型不匹配或附加载荷校验未绕过)"
      ;;
    10)
      die "update_engine_client 返回 10 (Failed to verify package, 签名/证书校验失败)"
      ;;
    89|92)
      die "update_engine_client 返回 $RC (状态机/ slot 冲突, 通常需重启设备后再试)"
      ;;
  esac
fi

log "update_engine_client 返回 $RC (非失败错误码, 按成功处理)"

# ---------- 8. 保留 ROOT (由用户自选分区 + 指定已修补镜像, 不再内置自动修补) ----------
# 参数:
#   $5  = root 开关 (1=开启)
#   $8  = 分区选择 (boot | init_boot, 默认 init_boot)
#   $9  = 用户已修补好的镜像文件路径(必填, 用于写入目标分区)
#   环境变量 ROOT_PART / ROOT_IMG 可单独覆盖
ROOT_ENABLED=0
[ "$5" = "1" ] && ROOT_ENABLED=1
ROOT_PART="${ROOT_PART:-${8:-init_boot}}"
ROOT_IMG="${ROOT_IMG:-$9}"

if [ "$ROOT_ENABLED" = "1" ]; then
  [ -n "$ROOT_IMG" ] || die "开启'保留 ROOT'后必须指定已修补的镜像文件路径 (第9参数 / ROOT_IMG)"
  [ -f "$ROOT_IMG" ] || die "指定的 ROOT 镜像不存在: $ROOT_IMG"

  case "$ROOT_PART" in
    boot|init_boot) ;;
    *) die "ROOT 分区只能是 boot 或 init_boot, 当前: $ROOT_PART" ;;
  esac

  BOOT_DEV=/dev/block/by-name/${ROOT_PART}${TARGET_SLOT}
  [ -b "$BOOT_DEV" ] || BOOT_DEV=/dev/block/bootdevice/by-name/${ROOT_PART}${TARGET_SLOT}
  [ -b "$BOOT_DEV" ] || die "找不到目标分区设备: $BOOT_DEV"

  log "保留 ROOT: 将用户镜像写入 $ROOT_PART$TARGET_SLOT ($BOOT_DEV)"
  log "  镜像: $ROOT_IMG"
  dd if="$ROOT_IMG" of="$BOOT_DEV" bs=4096 || die "写入 $BOOT_DEV 失败"
  log "  已写入 $ROOT_PART$TARGET_SLOT, 请确认镜像与机型/内核匹配"
fi

# ---------- 8.5 刷入 LK (bootloader) 镜像 ----------
# 参数:
#   $10 = lk 开关 (1=开启)
#   $11 = 用户选定的 lk 镜像文件路径
#   环境变量 LK_IMG / LK_DEV 可单独覆盖(LK_DEV 为精确设备节点, 跳过自动推断)
# 注意: 多数 vivo 机型 lk 为独立(非 A/B)分区, 无 slot 后缀; 若机型为 lk_a/lk_b 可设 LK_DEV 精确指定。
LK_ENABLED=0
[ "$10" = "1" ] && LK_ENABLED=1
LK_IMG="${LK_IMG:-$11}"

if [ "$LK_ENABLED" = "1" ]; then
  [ -n "$LK_IMG" ] || die "开启'刷入 LK'后必须指定 lk 镜像文件路径 (第11参数 / LK_IMG)"
  [ -f "$LK_IMG" ] || die "指定的 LK 镜像不存在: $LK_IMG"

  if [ -n "$LK_DEV" ]; then
    LK_DEV_NODE="$LK_DEV"
  else
    LK_DEV_NODE=/dev/block/by-name/lk
    [ -b "$LK_DEV_NODE" ] || LK_DEV_NODE=/dev/block/bootdevice/by-name/lk
  fi
  [ -b "$LK_DEV_NODE" ] || die "找不到 LK 分区设备: $LK_DEV_NODE (若机型为 lk_a/lk_b, 请设 LK_DEV 精确指定)"

  log "刷入 LK: 将用户镜像写入 $LK_DEV_NODE"
  log "  镜像: $LK_IMG"
  dd if="$LK_IMG" of="$LK_DEV_NODE" bs=4096 || die "写入 $LK_DEV_NODE 失败"
  log "  已写入 LK 分区, 刷写 bootloader 有风险, 请确认镜像与机型严格匹配"
fi

# ---------- 9. 完成 ----------
# 进度已通过 run_client --follow 前台实时输出 + tail -F 日志转发到终端, 无需再提示"正在写入"。
if [ "$6" = "1" ]; then
  sleep 3
  reboot
fi
log "DONE"
