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
#   (原 $5 root 已移除: OTA 安装不再支持一并 ROOT, 避免假成功刷入修补 init_boot 触发校验报错
#    及 ROOT 刷入失败阻断 LK 修补导致变砖; 需 ROOT 请单独用 KernelSU/Magisk 操作)
#   $5 = reboot     : 1=完成后重启
#   $6 = force      : 1=强制重刷(清空 update_engine 持久化状态后重装, 忽略"已应用等重启"的包)
#   $7 = lk         : 1=刷入 LK(bootloader) 镜像 (参数随 root 移除前移 3 位: 原 ${10})
#   $8 = lk_img     : LK 镜像文件路径 (原 ${11})
#
# 环境变量(开关类, 不占位置参数, 由 ota.xml 的 <set> 注入):
#   SPF=1           : 属性伪装(Spoof Properties)。在 headers 追加 5 项 vivo 系统属性
#                       (ro.vivo.product.version / ro.build.version.security_patch /
#                       ro.vendor.build.security_patch / ro.boot.anti.avb_anti_ver=0 /
#                       ro.vivo.ota.arb=空), 并 resetprop 写入, 绕过部分机型对"系统版本/
#                       双安全补丁/防回滚版本(ARB)"的校验(此类校验失败会触发数据清空)。
#                       实际值见下文 SPF 段 (:499 附近), 与 dg_install.sh 一致。
#   POWERWASH=1     : 刷完恢复出厂设置。在 headers 追加 POWERWASH=1, update_engine 应用
#                       完成后自动触发 factory reset(清空用户数据分区)。危险操作, 默认关闭。
#   (借鉴 vivo_dg_app-v1.0 的 dg_install.sh 的 $5 SPF / $6 POWERWASH 设计, 改为环境变量形态)

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

# 共用工具 (PATH / 颜色 / paint_line / is_key_line / filter_stream / log / die /
# boot_hal_svc / UE_LOG_DIR 等)。原先这些函数在本脚本与 status/ctrl/cancel 里各复制
# 了一份, 修一个 bug 要改 4 处, 已因此漂移过一次(36cd919 服务名取错列漏改)。
# 现统一收拢到 ota_common.sh, 本脚本只保留 OTA 安装特有的逻辑。
OTA_SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
. "$OTA_SELF_DIR/ota_common.sh"

if [ "$UE_LOG_WRITABLE" = "1" ]; then
  echo "[vivo_ota] $(date '+%F %T') 本次日志开始 (同时写入 $UE_MIRROR)" >> "$UE_MIRROR"
  printf '%s%s%s\n' "$C_BLU" "[vivo_ota] $(date '+%F %T') 本次日志开始 (终端带颜色, 文件纯文本: $UE_MIRROR)" "$C_RST"
fi

# ---------- update_engine 原版二进制: 持久备份 / 真还原 (2026-11-27 P1) ----------
# 旧实现两个坑:
#   1) 原版备份放在 $TMP/update_engine.bak, 而 $TMP 每次运行开头 rm -rf -> 被 kill -9
#      留下 patched 二进制时, 下次启动完全没有原版可还原;
#   2) hexpatch 是直接改 $UE_BAK, 于是 UE_BAK 里其实是【已 patch】的版本,
#      restore_system_certs 用 `cp "$UE_BAK" "$UE"` 等于把 patched 版再写回去, 根本没还原。
# 现在: 原版备份放持久路径, 并用"二进制里是否含 patched 证书路径串"判定真实状态
# (不靠可能过期的标记文件), 启动自愈 / EXIT trap / 证书回退 三处共用同一还原函数。
UE_ORIG_BAK=/data/local/tmp/vivo_ota_update_engine.orig
UE_PATCH_FLAG=/data/local/tmp/vivo_ota_update_engine.patched
UE_PATCH_PATH='/data/fuck_oddo_ota_testcerts.zip'

ue_is_patched() {
  grep -aq "$UE_PATCH_PATH" /system/bin/update_engine 2>/dev/null
}

# 真还原: 只有二进制确实含 patch 串才动; 否则清掉可能过期的标记直接返回。
# 成功后连备份一起删 —— 备份只在 patch 存活期间有意义, 留着会在"刷入新 ROM 后重启"
# 时把旧版 update_engine 当成原版写回(新 ROM 的 UE 版本已变)。失败则保留备份供下次重试。
# 返回 0=已还原或本就干净, 1=处于 patched 但还原失败(需人工介入)。
ue_restore_original() {
  ue_is_patched || { rm -f "$UE_PATCH_FLAG" 2>/dev/null; return 0; }
  if [ -f "$UE_ORIG_BAK" ] && cp -f "$UE_ORIG_BAK" /system/bin/update_engine 2>/dev/null; then
    rm -f "$UE_PATCH_FLAG" "$UE_ORIG_BAK" 2>/dev/null
    log "  [cert] 已从持久备份还原 /system/bin/update_engine 原版"
    return 0
  fi
  log "🚨 [cert] update_engine 处于 patched 状态但持久备份缺失/写入失败, 请手动恢复!"
  return 1
}

# ---------- 安装单例锁 (原子 mkdir 锁, 防并发实例互相 pkill 打断安装) ----------
# 借鉴 vivo_ota_status.sh 的单例锁思路, 但把"pid 文件 + kill -0"升级为 mkdir 原子锁。
# 仅阻塞"真正发起安装"的入口(本脚本), 不影响 status/cancel 等只读/控制命令。
# 2026-09-21 修复: 原实现用 pid 文件 + "引擎是否忙" 判据, 存在 TOCTOU 竞态 ——
#   实例刚启动时 update_engine 尚未拉起, "引擎不忙" 恒成立, 于是每个新实例都会把
#   仍然存活的兄弟实例误判成 "死锁/已空闲" 而清锁放行 -> 多实例并发 -> 后启动的实例
#   在 attempt_install 里 pkill -9 update_engine 打断前一个实例正在进行的写入 ->
#   引擎写出失败归档 -> 被误判成错误码 10 -> 假失败 (见 ota.log 2026-09-21 复盘)。
# 现改为 mkdir 原子锁 (mkdir 对同一路径并发只会有一个成功), 且存活判定只用 kill -0,
# 绝不再用 "引擎是否忙" 作为兄弟实例存活与否的依据。
# 锁路径常量 INSTALL_LOCK_DIR / INSTALL_LOCK_PID 已收拢到 ota_common.sh (P2-10)。
_acquire_install_lock() {
  # 首次尝试原子创建锁目录
  if mkdir "$INSTALL_LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$INSTALL_LOCK_PID" 2>/dev/null
    return 0
  fi
  # 锁已存在: 仅凭 kill -0 判持有者是否存活 (绝不再用 "引擎是否忙" 作判据)
  OLD_PID=$(cat "$INSTALL_LOCK_PID" 2>/dev/null)
  # mkdir 成功与写入 pid 之间有窗口: 读到空 pid 不能立刻判"残留", 先重读几轮。
  # 否则会把刚 mkdir 成功、还没来得及写 pid 的兄弟实例误当残留接管 -> 两实例并存,
  # 且落后那个退出时 trap 会删掉前者仍在使用的锁目录。
  _i=0
  while [ -z "$OLD_PID" ] && [ "$_i" -lt 3 ]; do
    sleep 1
    OLD_PID=$(cat "$INSTALL_LOCK_PID" 2>/dev/null)
    _i=$((_i + 1))
  done
  if [ -n "$OLD_PID" ] && [ "$OLD_PID" != "$$" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    die "已有安装实例在运行 (pid=$OLD_PID), 请勿重复点击安装。如确认该进程为残留, 删除 $INSTALL_LOCK_DIR 后重试。"
  fi
  # 持有者已死 (或 pid 文件损坏/为空): 判为残留死锁, 接管重建
  log "检测到残留安装锁 (pid=${OLD_PID:-未知} 已失效), 视为死锁, 接管重建"
  rm -rf "$INSTALL_LOCK_DIR" 2>/dev/null
  if mkdir "$INSTALL_LOCK_DIR" 2>/dev/null; then
    echo "$$" > "$INSTALL_LOCK_PID" 2>/dev/null
    return 0
  fi
  # 重建时被另一实例抢先拿到锁 -> 让位, 不并发
  die "获取安装锁失败 (另一实例刚抢占锁), 请勿重复点击安装, 稍后重试。"
}
_acquire_install_lock
# 脚本正常退出/被信号终止时释放锁 (kill -9 无法触发 trap, 由 kill -0 存活判定兜底)。
# ⚠ 只删自己持有的锁: 原实现无条件 rm -rf, 若本实例是"接管失败但仍在运行"的后来者,
#   退出时会把另一个存活实例正在用的锁目录删掉, 于是下一次安装与之并发 ->
#   互相 pkill update_engine 打断写入(2026-09-21 复盘的假失败)。
#   先校验 pid 文件内容是否仍是自己, 是才删。
_release_install_lock() {
  [ "$(cat "$INSTALL_LOCK_PID" 2>/dev/null)" = "$$" ] || return 0
  rm -rf "$INSTALL_LOCK_DIR" 2>/dev/null
}
# ota89 包装器的清理也挂在这里: attempt_install 内部会 die(exit 1) 直接退出,
# 原先写在调用之后的那行 cleanup 永远执行不到, 导致 GT 工具目录被永久改成包装器。
_cleanup_on_exit() {
  # OTA89_WRAPPER_ACTIVE 只可能由 ota89_install_wrapper 置 1, 用它判断函数是否已定义
  # (脚本在函数定义之前就 die 时不能调用未定义函数)。
  [ "$OTA89_WRAPPER_ACTIVE" = "1" ] && ota89_cleanup_wrapper
  # 2026-11-27 P1: 被『退出』杀脚本 / die 时, 若 update_engine 还处于 patched 状态,
  # 用持久备份真还原原版(ue_restore_original 定义在文件头部, 此时一定已定义)。
  ue_restore_original
  _release_install_lock
}
trap '_cleanup_on_exit' EXIT

# 记录安装开始时间(用于小结耗时统计)。用 date +%s 取 Unix 秒(原生 sh 无 $SECONDS 保证,
# 且脚本可能被 source 进其他 shell, 自管时间戳更可靠)。
INSTALL_START_TS=$(date +%s 2>/dev/null || echo "")

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
# 3) 2026-11-27 P1 启动自愈: 上次被 kill -9 (EXIT trap 不执行) 留下 patched 的
#    update_engine 时, 用持久备份还原。必须在证书绕过段(会重新 patch)之前、且在本实例
#    已持锁之后执行, 避免与并发实例互相踩踏。
ue_restore_original

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
# 注意: log()/die() 已在文件头部定义(带 ANSI 着色 + /sdcard/ota.log 纯文本镜像)。
# 此处曾重复定义为裸 echo 版本, 会覆盖前面的实现, 导致从这一行往后的所有日志
# 既没有颜色、也不再写入镜像文件。故删除重复定义, 统一复用头部版本。

# 小端读取 zip 本地头中的 2/4 字节整型 (P2-11: 改用共用库 od_bytes 批量读,
# 不再 dd bs=1 逐字节 syscall; od -j/-N 不可用时 od_bytes 内部回退 dd)。
le2() { local f="$1" o="$2" b; b=$(od_bytes "$f" "$o" 2); set -- $b; echo $(( ${1:-0} + ${2:-0}*256 )); }
le4() { local f="$1" o="$2" b; b=$(od_bytes "$f" "$o" 4); set -- $b; echo $(( ${1:-0} + ${2:-0}*256 + ${3:-0}*65536 + ${4:-0}*16777216 )); }

# 从 zip 本地文件头解析 payload.bin 的偏移/大小 (仅支持 Stored 条目)。
# 成功: 设置 PAYLOAD_FILE/PAYLOAD_OFFSET/PAYLOAD_SIZE/USE_OFFSET 并返回 0
# 失败: 返回 1 (调用方回退整包解压)
locate_payload_in_zip() {
  local z="$1" hits spos s blob hdr method csize fnlen exlen off
  hits=$(grep -a -b -o 'payload\.bin' "$z" 2>/dev/null)
  [ -z "$hits" ] && { log "  ⚠ zip 内未找到 payload.bin 文件名, 回退整包解压"; return 1; }
  for spos in $(echo "$hits" | cut -d: -f1); do
    s=$spos; [ "$s" -gt 80 ] && s=$((spos-80)) || s=0
    blob=$(od_bytes "$z" "$s" $((spos - s)))
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

# 写入完成后手动切启动槽 (AIDL boot control HAL)。
# 背景: vivo/Android15 的 update_engine 跨机型强刷后不会自动 setActiveBootSlot,
# 写入完成直接 reboot -> bootloader 仍从原槽启动 -> 引擎发现目标槽 pending 即
# Removing all update state 把刚写入的槽全清(update-result 变 1, 写入白费)。
# 故写入成功后必须手动切槽。
#
# 2026-09-13 需求变更: **不再回读 getActiveBootSlot 判定切槽是否生效**。
#   本函数只负责把切槽指令下发, 然后提示用户自行查看槽位状态确认。
#   原因: HAL 回读长期被服务名取错列的 bug 污染(见 AGENTS.md OTA 节), 结论不可信;
#   且判定权既然交回用户, 重启动作也必须一并交回 —— 带错槽重启会被引擎回滚清空刚写入的槽。
# 入参: $1=目标 slot 名(_a/_b)
# 返回: 0=已下发切槽指令(结果未经校验); 1=参数/环境异常; 2=无 AIDL 接口(非 A/B)
switch_active_slot() {
  local TS="$1"
  [ -z "$TS" ] && { log "✗ 切槽失败: 未指定目标 slot"; return 1; }
  local TNUM
  case "$TS" in
    _a) TNUM=0 ;;
    _b) TNUM=1 ;;
    *)  log "✗ 切槽失败: 非法 slot 名 '$TS' (仅 _a/_b)"; return 1 ;;
  esac
  # 探测 AIDL 接口名(不同 vivo 固件名可能不同, 不能写死)
  local SVC out
  SVC=$(boot_hal_svc)
  [ -z "$SVC" ] && { log "⚠ 切槽跳过: 当前环境无 android.hardware.boot.IBootControl (非 A/B 或版本过旧)"; return 2; }
  log "切启动槽: 调 $SVC setActiveBootSlot($TNUM) -> $TS"
  # 事务码对齐 swab.sh 真机实测映射: 9=setActiveBootSlot。
  # (旧代码误用 3=getNumberSlots 只读接口 -> 从未真正下发; 另有服务名取到序号列
  #  导致 $SVC 变成 "29" -> service not found, 详见 AGENTS.md OTA 节)
  out=$(service call "$SVC" 9 i32 "$TNUM" 2>&1)
  # 只报告"调用层面"的异常, 不据此判定切槽成败(成败交由用户查看槽位确认)
  case "$out" in
    *Error*|*error*|*not\ found*|*does\ not\ exist*)
      log "  ⚠ setActiveBootSlot 调用返回异常: $out" ;;
  esac
  sleep 1
  log "  切槽指令已下发, 下一次启动应进入 $TS"
  log "  ⚠ 本脚本不再回读校验切槽结果, 请前往『A/B 槽位管理 → 查看当前槽位状态』确认:"
  log "     『待生效槽』已变成 $TS        -> 可以重启"
  log "     『待生效槽』仍是当前运行槽    -> 切勿重启! 否则刚写入的 $TS 会被引擎回滚清空"
  return 0
}

# ---------- 0.1 槽位状态校验 [已于 2026-09-13 移除] ----------
# 原 verify_slot_state() / slot_num2name(): 安装后复查 getActiveBootSlot(txn=1) 与
# getCurrentSlot(txn=2), 两者不一致即判定"刷入成功"(INSTALL_OK=1), 一致则判定失败并
# 置 SWITCH_BLOCK_REBOOT 阻止自动重启。
#
# 移除原因(需求变更): 该判定完全依赖 HAL 回读, 而回读长期受服务名取错列的 bug 影响
# (见 AGENTS.md OTA 节), 结论不可信; 与其用一个不可靠的自动判定替用户下结论, 不如
# 把判定权交回用户 —— 切槽后提示用户到『A/B 槽位管理 → 查看当前槽位状态』自行确认。
#
# 连带变更: INSTALL_OK / SLOT_CUR / SLOT_ACT / SLOT_VERIFY_DETAIL / SLOT_VERIFY_RC
# 这几个全局量一并废弃, 不再有任何自动"刷入成功/失败"的结论。
# 需要事后核对时, 以用户查看到的槽位状态为准。

# ---------- 0. 校验 ----------
ROM="$1"
[ -z "$ROM" ] && die "未选择 OTA 包 (param rom 为空)"
[ -f "$ROM" ]  || die "OTA 包不存在: $ROM"
[ -x "$UPDATE_ENGINE_CLIENT" ] || die "找不到 $UPDATE_ENGINE_CLIENT (非vivo/无root?)"

# 参数序快照(排查位置参数错位用): rom=包路径 dg=降级 ex=附加载荷 ce=证书绕过
# rb=完成后重启 fc=强制重刷 lk=刷入LK li=lk镜像路径
# (教训: ROOT 三参数移除后曾发生 reboot/force 读错位, 详见 docs-dev/lessons-ota-size-zip64.md)
log "参数快照: dg=$2 ex=$3 ce=$4 rb=$5 fc=$6 lk=$7 lk_img=$8"

# ---------- 1. 解析 metadata ----------
log "解析 META-INF/com/android/metadata ..."
META="$TMP/metadata"
unzip -p "$ROM" "META-INF/com/android/metadata" > "$META" 2>/dev/null \
  || die "无法读取 metadata (不是标准 OTA 包?)"

# 机型匹配
DEVICE=$(grep -m1 '^pre-device=' "$META" | cut -d= -f2)
HW_DEVICE=$(grep -m1 '^hardware-device=' "$META" | cut -d= -f2)
CUR_DEVICE=$(getprop ro.product.device 2>/dev/null)
# P2-11: 原 `grep -qw "$CUR_DEVICE"` 把设备串当正则(-w 的边界由正则引擎判), 设备名含
# `.`/`+` 等元字符时会误配。改为固定串匹配: 用逗号分隔后 grep -qF 精确匹配整段。
if [ -n "$HW_DEVICE" ] && [ -n "$CUR_DEVICE" ]; then
  case ",$(printf '%s' "$HW_DEVICE" | tr ' ' ',')," in
    *",$CUR_DEVICE,"*) : ;;
    *) log "⚠ hardware-device($HW_DEVICE) 不含当前($CUR_DEVICE), 跨机型风险" ;;
  esac
fi
[ -n "$DEVICE" ] && [ -n "$CUR_DEVICE" ] && [ "$DEVICE" != "$CUR_DEVICE" ] \
  && log "⚠ pre-device=$DEVICE 当前=$CUR_DEVICE (vivo 多代号, 谨慎)"

# 非降级模式下, 软校验安全补丁级别与构建时间戳, 阻断"误刷更旧的系统"
# (借鉴 Custota fetchAndCheckMetadata 的 postSecurityPatchLevel/postTimestamp 比对)。
# 仅为提醒(不强制 die), 因 vivo 多代号跨版本有时确实需要刷旧基线; 降级模式($2=1)整体跳过。
if [ "$2" != "1" ]; then
  POST_PATCH=$(grep -m1 '^post-security-patch-level=' "$META" | cut -d= -f2)
  POST_TS=$(grep -m1 '^post-timestamp=' "$META" | cut -d= -f2)
  CUR_PATCH=$(getprop ro.build.version.security_patch 2>/dev/null)
  CUR_TS=$(getprop ro.build.date.utc 2>/dev/null)
  if [ -n "$POST_PATCH" ] && [ -n "$CUR_PATCH" ]; then
    # 简单字典序/日期串比较(YYYY-MM-DD 格式可直接比), 旧于当前则警告
    if [ "$POST_PATCH" \< "$CUR_PATCH" ]; then
      log "⚠ 安全补丁级别: 包=$POST_PATCH < 设备当前=$CUR_PATCH (非降级模式, 疑似刷更旧系统, 请确认)"
    fi
  fi
  # P2-11: 比较前先确认两边都是纯数字, 避免 -lt 拿到空串/非数字时行为不确定
  if is_uint "$POST_TS" && is_uint "$CUR_TS"; then
    if [ "$POST_TS" -lt "$CUR_TS" ]; then
      log "⚠ 构建时间戳: 包=$POST_TS < 设备当前=$CUR_TS (非降级模式, 疑似刷更旧系统, 请确认)"
    fi
  fi
fi

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
# 双保险: strings 提取可打印串 或 grep -a 直接匹配, 任一命中即判编译包。
# 注: 原 COMPILED 变量 (:344/:348) 设置后从未被读取, 已删; 此处仅作信息提示。
if tail -c 65536 "$ROM" 2>/dev/null | strings 2>/dev/null | grep -q "signed by SignApk" 2>/dev/null \
   || tail -c 65536 "$ROM" 2>/dev/null | grep -a -q "signed by SignApk" 2>/dev/null; then
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

# 文档坑10: OTA 包 >6GB 走 /storage/emulated/0/ (FUSE) 会报 kDownloadTransferError,
# 必须改用 /data/media/0/ 路径 (同一份文件, 绕过 FUSE 大文件读取坑)。
# (注: /data/media/0 是 f2fs 物理路径; 8/23 成功即用此路径)
case "$PAYLOAD_FILE" in
  /storage/emulated/0/*)
    _F="/data/media/0/${PAYLOAD_FILE#/storage/emulated/0/}"
    if [ -f "$_F" ]; then
      PAYLOAD_FILE="$_F"
      log "  payload 路径已从 /storage/emulated/0/ 转换为 /data/media/0/ (大包 FUSE 规避, 文档坑10)"
    else
      log "  ⚠ /data/media/0 下未找到对应文件, 保持原路径继续"
    fi
    ;;
esac

# payload_properties.txt 的校验头 —— 对齐 GT: 传完整内容(含 POWERWASH 等), 不能只
# 提取 4 个字段。每个 KEY=VALUE 必须独立一行: update_engine_client 的 --headers 按
# '\n' 切分列表 (帮助文档注明 "one element of the list per line")。实测把 headers 用
# tr '\n' ' ' 合并成单行后, client 只解析出 FILE_HASH 一个键 (其余全并进其 value),
# METADATA_SIZE 未解析 -> Omaha response metadata_size=0 -> kDownloadInvalidMetadataSize。
HEADERS=$(unzip -p "$ROM" "payload_properties.txt" 2>/dev/null | sed '/^[[:space:]]*$/d')
log "payload.bin -> $PAYLOAD_FILE (offset模式=$USE_OFFSET)"
log "headers(${#HEADERS}字节): ${HEADERS:-<空>}"
# ZIP64 修正: payload.bin 为 ZIP64 条目(>4GB)时, 本地头 csize/usize=0xFFFFFFFF,
# 32 位 shell 算术溢出成 -1, 导致 --size=-1 被引擎按"读到文件尾"处理, 与 zip 内
# payload 之后的其他条目冲突 -> kDownloadTransferError。改用 payload_properties.txt
# 里的权威 FILE_SIZE 覆盖 (与 payload 头 FILE_SIZE 一致, 引擎本就要校验)。
if [ "$USE_OFFSET" = "1" ]; then
  _FSIZE=$(printf '%s\n' "$HEADERS" | grep -m1 '^FILE_SIZE=' | cut -d= -f2)
  case "$_FSIZE" in
    ''|*[!0-9]*)
      log "  ⚠ 未从 payload_properties 取到 FILE_SIZE, 保持原 PAYLOAD_SIZE=${PAYLOAD_SIZE:-?}"
      ;;
    *)
      if [ "${PAYLOAD_SIZE:-x}" != "$_FSIZE" ]; then
        log "  ZIP64 修正: PAYLOAD_SIZE=${PAYLOAD_SIZE:-<无效>} -> $_FSIZE"
        PAYLOAD_SIZE="$_FSIZE"
      fi
      ;;
  esac
fi

if [ -z "$HEADERS" ]; then
  log "  ⚠ headers 为空 (payload_properties.txt 缺失?)"
fi
[ -n "$HEADERS" ] || die "payload_properties.txt 校验头为空 (无法校验, 包损坏或非标准 OTA?)"

# ---------- 4.5 属性伪装 (SPF) + 恢复出厂 (POWERWASH) ----------
# 与 vivo_dg_app 的 dg_install.sh ①.1 对齐: 伪"当前版本相关读数"为目标包值, 绕过
#   ro.vivo.product.version + ro.build.version.security_patch + ro.vendor.build.security_patch
#   的 版本 + 双SPL 门, 并清零 ARB (ro.boot.anti.avb_anti_ver / ro.vivo.ota.arb)。
# 做法(取值对齐 dg_install.sh, 并保留本脚本 headers 注入能力):
#   1) 从 metadata 取目标包 post-version / post-security_patch(+回退 post-security-patch-level)
#      / post-vendor-security_patch 作为伪值 —— 降级方向令"当前版本读数 = 目标包版本"以过门;
#   2) spoof_append_header 把 5 项写进 HEADERS, update_engine 据此写入目标槽 vendor/odm 覆盖;
#   3) resetprop 即时写入当前系统, 使 ApplyPayload 阶段的版本/SPL/ARB 校验读到伪值。
# POWERWASH=1 则令 update_engine 应用完后自动恢复出厂(清空用户数据)。两项默认关闭。
spoof_append_header() { # key value [replace]
  # 只按「行首 KEY=」精确匹配, 绝不用全文子串。
  # 原先写的是 `case "$HEADERS" in *"$1"*)`, POWERWASH 会被包里本来就有的
  # POWERWASH=0 命中而跳过追加 —— 用户勾了『恢复出厂』却静默不生效, 属于数据安全问题。
  # 第三参数 replace: 已存在时覆盖为新值(POWERWASH 需要把包内的 0 改成 1);
  # 缺省 append 语义: 已存在则保留包内原生值(SPF 属性不该覆盖包内声明)。
  local k="$1" v="$2" mode="${3:-append}" cur
  cur=$(printf '%s\n' "$HEADERS" | awk -v p="$k=" 'index($0, p) == 1 { print; exit }')
  if [ -n "$cur" ]; then
    [ "$mode" = "replace" ] || return 0
    [ "$cur" = "$k=$v" ] && return 0
    # 只替换第一处, 其余重复键原样保留 (不丢数据)
    HEADERS=$(printf '%s\n' "$HEADERS" | awk -v p="$k=" -v nv="$k=$v" '
      index($0, p) == 1 && !done { print nv; done = 1; next }
      { print }')
    return 0
  fi
  HEADERS="${HEADERS}
$k=$v"
}

# 目标包伪值: 与 dg_install.sh ①.1 一致, 从 metadata 解析
# (SPL 键回退 post-security-patch-level: 本仓库 vivo_ota.sh 实测 vivo 元数据用此标准键)
SPF_PV=$(grep -m1 '^post-version=' "$META" 2>/dev/null | cut -d= -f2)
SPF_SP=$(grep -m1 '^post-security_patch=' "$META" 2>/dev/null | cut -d= -f2)
[ -z "$SPF_SP" ] && SPF_SP=$(grep -m1 '^post-security-patch-level=' "$META" 2>/dev/null | cut -d= -f2)
SPF_VSP=$(grep -m1 '^post-vendor-security_patch=' "$META" 2>/dev/null | cut -d= -f2)

# 写入一项伪装属性并立即回读校验, 防止"setprop 对 ro.* 无效"造成的静默失败:
# 无 resetprop 的环境(如 NUT 裸 root)会退化到 setprop, 而 ro.* 只读属性写不进去,
# 若只写不验, 日志会显示"已写入"但属性没变 -> 引擎侧报错92 却查不到原因。
# 优先级: $RESETPROP(KSU/Magisk) > $PATH 里的 resetprop > setprop(通常无效)。
# 返回 0=回读一致(生效); 1=回读不一致(未生效, 调用方负责告警)。
spoof_set_prop() { # key value
  local k="$1" v="$2" cur
  if [ -x "$RESETPROP" ]; then
    "$RESETPROP" "$k" "$v" 2>/dev/null
  elif command -v resetprop >/dev/null 2>&1; then
    resetprop "$k" "$v" 2>/dev/null
  else
    setprop "$k" "$v" 2>/dev/null
  fi
  cur=$(getprop "$k" 2>/dev/null)
  [ "$cur" = "$v" ] && return 0
  # 清空型属性(如 ro.vivo.ota.arb 期望空值): getprop 返回空即视为生效
  [ -z "$v" ] && [ -z "$cur" ] && return 0
  return 1
}

if [ "$SPF" = "1" ]; then
  log "属性伪装(SPF): 伪目标包 版本+双SPL+ARB (对齐 dg_install.sh ①.1) 以绕过版本/防回滚校验"
  # 5 项: 属性=伪值; ARB 两项清零(设备默认即 0, 双保险)
  SPF_FAIL=""
  for kv in \
    "ro.vivo.product.version:${SPF_PV}" \
    "ro.build.version.security_patch:${SPF_SP}" \
    "ro.vendor.build.security_patch:${SPF_VSP}" \
    "ro.boot.anti.avb_anti_ver:0" \
    "ro.vivo.ota.arb:" ; do
    k="${kv%%:*}"; v="${kv#*:}"
    spoof_append_header "$k" "$v"
    if spoof_set_prop "$k" "$v"; then
      log "  ✅ 伪值生效 $k=${v:-<空>}"
    else
      cur=$(getprop "$k" 2>/dev/null)
      log "  ⚠ 伪装未生效 $k: 期望=${v:-<空>} 实际=${cur:-<空>} (ro 属性需 resetprop 才能改写)"
      SPF_FAIL="$SPF_FAIL $k"
    fi
  done
  if [ -n "$SPF_FAIL" ]; then
    log "  🚨 以下属性伪装未生效, 版本/SPL/ARB 门可能仍拦截(错误92):$SPF_FAIL"
    log "     请确认已装 KernelSU/Magisk 并提供 resetprop; 无 resetprop 时 ro.* 只读无法改写"
  fi
  log "  已追加 5 项 SPF 属性到 headers 并写入当前系统(重启复原)"
fi

if [ "$POWERWASH" = "1" ]; then
  log "恢复出厂(POWERWASH): 将在 OTA 应用完成后触发 factory reset (⚠ 会清空用户数据!)"
  # replace 语义: 标准 Android 的 payload_properties.txt 通常已带 POWERWASH=0,
  # 必须把它改成 1, 否则用户勾了恢复出厂却静默不生效。
  spoof_append_header "POWERWASH" "1" replace
  # 回读确认, 避免又出现"日志说已启用、实际没生效"的静默失败
  case "$HEADERS" in
    *"POWERWASH=1"*) log "  ✅ headers 已确认 POWERWASH=1" ;;
    *) log "  🚨 headers 中 POWERWASH 未能置为 1, 恢复出厂不会生效! 请勿依赖本次清数据" ;;
  esac
fi

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
# UE_BAK 现仅作 patch 的工作副本(在 $TMP, 每次运行重建); 原版备份是持久的 UE_ORIG_BAK。
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
    # 2026-11-27 P1: 持久备份原版。启动自愈已保证此刻 UE 是原版(未 patch);
    # 只在备份不存在时写入, 绝不用 hexpatch 后的 UE_BAK 覆盖它。
    if [ ! -f "$UE_ORIG_BAK" ]; then
      cp -f "$UE" "$UE_ORIG_BAK" 2>/dev/null \
        && log "  原版 update_engine 已持久备份 -> $UE_ORIG_BAK" \
        || log "  ⚠ 持久备份失败, 后续将无法自动还原二进制"
    fi
    # P2-15 依赖断言: hexpatch 工作副本必须存在且非空, 否则 magiskboot 会静默失败,
    # 随后把未 patch 的 UE_BAK 写回 /system, 误报"证书路径已改"。
    cp -f "$UE_ORIG_BAK" "$UE_BAK" 2>/dev/null || cp -f "$UE" "$UE_BAK"
    HEXPATCH_USABLE=0
    if [ ! -s "$UE_BAK" ]; then
      log "  ⚠ hexpatch 工作副本为空/缺失, 跳过 hexpatch, 降级 bind"
    else
      HEXPATCH_USABLE=1
      # P2-15: 捕获 magiskboot stdout/stderr 并经 log() 写入 ota.log —— 原先裸输出
      # 只进终端, 出问题时事后无从查证是"没找到目标串"还是"ROM 版本不匹配"。
      HP_OUT=$("$MAGISKBOOT" hexpatch "$UE_BAK" \
        2F73797374656D2F6574632F73656375726974792F6F746163657274732E7A6970 \
        2F646174612F6675636B5F6F64646F5F6F74615F7465737463657274732E7A6970 2>&1)
      HP_RC=$?
      [ -n "$HP_OUT" ] && log "  [hexpatch] $(printf '%s' "$HP_OUT" | tr '\n' ' ')"
      [ "$HP_RC" -ne 0 ] && log "  ⚠ magiskboot hexpatch 返回 $HP_RC (可能未找到目标串)"
      # 断言: hexpatch 后工作副本必须仍非空, 否则绝不能写到 /system/bin/update_engine
      # (写成空文件等于硬砖, 且启动自愈会拿这个空文件当"原版"反复写回)。
      [ -s "$UE_BAK" ] || { log "  🚨 hexpatch 后工作副本为空, 拒绝写回 /system"; HEXPATCH_USABLE=0; }
    fi
    # remount/cp 失败(erofs 只读, Android15 常见)时 hexpatch 不生效, 降级 bind
    # HEXPATCH_USABLE=0 时跳过写回, 防止把空/损坏的工作副本写进系统。
    if [ "$HEXPATCH_USABLE" -eq 1 ] && [ "$PATCHED_CERT_READY" -eq 1 ] \
       && mount -o rw,remount /system 2>/dev/null && cp -f "$UE_BAK" "$UE"; then
      log "  update_engine 证书路径已改为 $UE_PATCH_PATH"
      echo "patched at $(date '+%F %T') by vivo_ota.sh" > "$UE_PATCH_FLAG" 2>/dev/null
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

# ---------- 5.5 温控绕过 (update_engine 错误码9 / thermal detection) ----------
# update_engine 安装开始前检测板温(/sys/class/thermal/thermal_zone*), 默认阈值 46000 mC=46C
# (thermal_utils.cpp: Use default config 46000)。安装时 CPU 满载升温极易触发 kOverHeat 中止
# (错误码9: Finish update, exit thermal detection)。
# vivo 官方调试口: 属性 vota.virtual_ab.debug.thermal_threshold 可覆盖阈值(单位 mC),
# 读到该属性则用之, 否则回退默认 46000。有 root 直接拉高到 120C 避免温控中途掐断。
# 属性非 persist, 重启后失效, 故每次安装前自动设置。
setprop vota.virtual_ab.debug.thermal_threshold 120000 2>/dev/null
log "温控绕过: vota.virtual_ab.debug.thermal_threshold=$(getprop vota.virtual_ab.debug.thermal_threshold 2>/dev/null) (默认46C已拉高到120C)"

# ---------- 6. 当前 slot ----------
# ⚠ 不能用 `getprop ... || echo "_a"` 兜底: getprop 对不存在的属性返回**空字符串且
#   rc=0**, `||` 分支永远不触发。于是 CUR_SLOT 为空、TARGET_SLOT 被算成 "_a";
#   若设备实际跑在 _b 而属性读不到, 目标槽就等于当前槽 —— 切槽变成切到当前槽、
#   LK 也刷到当前运行侧, 正是注释里警告的"硬砖"场景。
# 读不到就按"非 A/B"处理: 不切槽、不刷 LK, 只正常写包。
CUR_SLOT=$(getprop ro.boot.slot_suffix 2>/dev/null)
case "$CUR_SLOT" in
  _a|_b) TARGET_SLOT=$( [ "$CUR_SLOT" = "_a" ] && echo "_b" || echo "_a" ) ;;
  *)
    log "⚠ 读不到 ro.boot.slot_suffix (当前值='${CUR_SLOT:-空}'), 按非 A/B 设备处理: 本次不切槽"
    TARGET_SLOT=""
    ;;
esac
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
# 2026-11-27 P0 修复: 原二进制备份到【持久目录】, 不能用 $TMP(每次运行开头 rm -rf)。
# 解决"覆盖第三方二进制后 cleanup 只 rm -f、日志却谎称已恢复"的问题:
#   - 覆盖前先 cp 原文件到 OTA89_BAK;
#   - cleanup / EXIT trap 用备份真还原;
#   - 上次被 kill -9(EXIT trap 不执行)残留的包装器, 下次启动由 recover 自愈。
OTA89_BAK=/data/local/tmp/vivo_ota_ota89_update_engine.bak
OTA89_WRAPPER_ACTIVE=0

# 自愈: 若上次运行被 kill -9 留下包装器和备份, 先还原原二进制。
# 备份存在即说明我们曾覆盖过(备份只在覆盖前那一刻创建), 无条件还原是安全的。
ota89_recover_stale() {
  [ -f "$OTA89_BAK" ] || return 0
  if cp -f "$OTA89_BAK" "$TOOL_UE" 2>/dev/null; then
    chmod 755 "$TOOL_UE" 2>/dev/null
    log "  [ota89] 已用备份还原上次残留的工具目录 update_engine 原二进制"
  else
    log "  [ota89] ⚠ 还原上次残留包装器失败, 请手动从 $OTA89_BAK 恢复"
  fi
  rm -f "$OTA89_BAK" 2>/dev/null
}

# 预置包装器: 若工具目录存在且其中的 update_engine 副本是被覆盖的二进制(>1MB),
# 先备份原文件, 再替换为 "强制 cd / 再 exec 系统原版" 的 shell 包装器。
ota89_install_wrapper() {
  [ -d "$TOOL_DIR" ] || return 0
  ota89_recover_stale
  if [ -f "$TOOL_UE" ]; then
    local sz=0
    sz=$(stat -c %s "$TOOL_UE" 2>/dev/null || echo 0)
    if [ "$sz" -gt 1000000 ] 2>/dev/null; then
      # 备份必须在覆盖前成功; 备份失败则放弃改写, 绝不覆盖后无法还原。
      if ! cp -f "$TOOL_UE" "$OTA89_BAK" 2>/dev/null; then
        log "  [ota89] ⚠ 备份原二进制失败, 放弃改写包装器(避免覆盖后无法还原)"
        return 0
      fi
      cat > "$TOOL_UE" <<'EOF'
#!/system/bin/sh
# vivo_ota ota89 fix wrapper (非守护版): 强制正确 cwd, 再 exec 系统原版 update_engine
cd / || exit 1
exec /system/bin/update_engine "$@"
EOF
      chmod 755 "$TOOL_UE" 2>/dev/null
      OTA89_WRAPPER_ACTIVE=1
      log "  [ota89] 工具目录 update_engine 副本($sz bytes)已备份到 $OTA89_BAK 并改写为 cwd=/ 包装器"
    fi
  fi
}

# 清理包装器: 安装结束后用备份真还原原二进制, 避免长期驻留/丢失第三方工具文件。
ota89_cleanup_wrapper() {
  [ "$OTA89_WRAPPER_ACTIVE" = "1" ] || return 0
  if [ -f "$OTA89_BAK" ] && cp -f "$OTA89_BAK" "$TOOL_UE" 2>/dev/null; then
    chmod 755 "$TOOL_UE" 2>/dev/null
    log "  [ota89] 已从备份还原工具目录 update_engine 原始二进制"
  else
    rm -f "$TOOL_UE" 2>/dev/null
    log "  [ota89] ⚠ 备份缺失或还原失败, 只能移除包装器(原二进制可能已丢失)"
  fi
  rm -f "$OTA89_BAK" 2>/dev/null
  OTA89_WRAPPER_ACTIVE=0
}

# ---------- 7. 执行安装 (用系统服务, 绝不复制二进制) ----------
# 对齐 GT ab_updater.sh 官方包分支: 先杀掉并重启 update_engine 服务, 确保状态机干净,
# 再带 --update 调 client (vivo 精简版 client 缺 --update 不会发起 ApplyPayload, 直接 IDLE)。
run_client() {
  # launch 模式(对齐 vivo 排错手册步骤6): client 不带 --follow, 引擎后台接受并安装,
  # client 立即返回 launch 退出码。避免 --follow 前台阻塞期间终端/MCP 超时把命令打掉
  # 误 cancel 正在下载的安装(文档坑9: 实战犯过两次)。
  # 安装进度由 start_ue_log_tail 后台轮询 /logdata/recovery/update_engine_log 增量转发。
  # 强制 cwd=/ 避免相对路径读附加载荷失败(错误89)。
  # 退出码存入全局 UE_RC (先把输出到临时文件, 才能拿到 client 真实退出码, 不受管道影响)。
  cd /
  UE_RC=0
  UE_OUT="$TMP/ue_launch.out"
  if [ "$USE_OFFSET" -eq 1 ]; then
    "$UPDATE_ENGINE_CLIENT" --update --payload="file://$PAYLOAD_FILE" \
      --offset="$PAYLOAD_OFFSET" --size="$PAYLOAD_SIZE" \
      --headers="$HEADERS" > "$UE_OUT" 2>&1
  else
    # 非 offset: 直接把整个 zip 作为 payload 传入, 不带 offset/size,
    # update_engine 自动定位 zip 内 payload.bin 并读取附加载荷 (对齐 GT 编译包分支)。
    "$UPDATE_ENGINE_CLIENT" --update --payload="file://$PAYLOAD_FILE" \
      --headers="$HEADERS" > "$UE_OUT" 2>&1
  fi
  UE_RC=$?
  # 立即逐行着色显示 + 镜像文件 (实时性略低于管道, 但能拿到准确退出码, 且文件无颜色)
  color_stream < "$UE_OUT"
  if [ "$UE_RC" -ne 0 ]; then
    # 2026-09-06 复盘修复: 客户端退出码 248 = binder Status(-8) 失败(如错误54/65
    # "Already processing"/"CleanupPreviousUpdateAction is running"), 并不是
    # UPDATED_NEED_REBOOT! 旧代码直接 return $UE_RC, 248 曾被当成成功放行 ->
    # 包根本没写入就去刷 LK/切槽(变砖前提)。所有非 0 launch 一律归一为失败码 66。
    # 引擎真正接受安装时 launch 退出 0; 成功终态一律由 wait_engine_done 从引擎日志判定。
    log "  ✗ launch 失败 (RC=$UE_RC), 引擎未接受本次更新 (客户端非0退出码≠UPDATED_NEED_REBOOT)"
    # attempt_install 以 RC=$UE_RC 取结果, 须同步改写 UE_RC (66 属失败码, 不在 SUCCESS_CODES)
    UE_RC=66
    return 66
  fi
  # launch 成功 (EXIT=0): 引擎已在后台接受并开始安装, 轮询日志等待终态
  # (替代 --follow 阻塞; 文档坑9: 勿用 --follow 防超时误 cancel)。
  record_log_anchor
  wait_engine_done
  UE_RC=$?
  return $UE_RC
}

# 等待引擎后台安装完成 (替代 --follow; 轮询日志/失败归档/状态文件判定终态)。
# 判定顺序:
#   1) 失败归档目录(update_engine_log_err)出现新文件 -> 提取错误码判失败
#      (提取不到时: 文本明确指向验证失败才取 10 以保留证书回退, 否则取 99=未知失败);
#   2) 日志出现 UPDATED_NEED_REBOOT -> 成功待重启 (248);
#   3) 日志出现 "Update successfully applied" / "SendPayloadApplicationComplete [0]" -> 成功 (0);
#   4) 引擎回 IDLE 或进程退出但无成功标记 -> 以 prefs/update-result 判定
#      (0=成功, 1=被回滚/失败, 缺省视为失败 89);
#   5) 超时(默认 3600s=60 分钟, 2026-11-28 从 1800s 上调; OTA_WAIT_TIMEOUT 可覆盖)
#      -> 不判失败、不 die、不切槽/刷 LK/重启, 只提示让用户看进度后自行决定。
WAIT_ERR_SEEN=""

# 记录 apply 发起后的日志锚点: 只检查锚点【之后】的新日志, 避免把引擎启动阶段
# CleanupPreviousUpdateAction 写下的 SendPayloadApplicationComplete [0]
# (并非本次安装完成) 误判为成功 -> 假成功导致提前写 ROOT/切槽、漏掉后台传输错误。
UE_ANCHOR_FILE=""
UE_ANCHOR_OFF=0
record_log_anchor() {
  local f
  f=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | head -1)
  UE_ANCHOR_FILE="$f"; UE_ANCHOR_OFF=0
  [ -n "$f" ] && UE_ANCHOR_OFF=$(stat -c %s "$f" 2>/dev/null || echo 0)
  # 2026-11-27 P0-4: 把锚点(日志文件+字节偏移)持久化到安装锁目录, 供并行的
  # 『取消当前安装』(vivo_ota_cancel.sh) 只读本次 launch 之后新增的日志 ——
  # 它原先 `tail -1` 整份日志, 上一次安装的 UPDATED_NEED_REBOOT/IDLE 终态会
  # 被误当成"本次取消"的结果。锁释放时随目录一起清除。
  [ -d "$INSTALL_LOCK_DIR" ] && \
    printf '%s\n%s\n' "$UE_ANCHOR_FILE" "$UE_ANCHOR_OFF" > "$INSTALL_LOCK_DIR/log_anchor" 2>/dev/null
  # 快照已有失败归档, 只把本次新增的当失败依据 (避免旧归档误判)
  WAIT_ERR_SEEN=""
  for _ef in "$UE_ERR_DIR"/*; do
    [ -f "$_ef" ] && WAIT_ERR_SEEN="$WAIT_ERR_SEEN $_ef"
  done
}

# 检查【锚点之后】新增日志是否命中正则 $1; 0=命中, 1=未命中。引擎轮转出新文件时按全新处理。
new_log_grep() {
  local pat="$1" f size
  f=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | head -1)
  [ -z "$f" ] && return 1
  if [ "$f" = "$UE_ANCHOR_FILE" ]; then
    size=$(stat -c %s "$f" 2>/dev/null || echo 0)
    [ -z "$size" ] && return 1
    { [ "$size" -le "$UE_ANCHOR_OFF" ] 2>/dev/null; } && return 1
    tail -c +$((UE_ANCHOR_OFF + 1)) "$f" 2>/dev/null | grep -aqE "$pat" && return 0
    return 1
  fi
  grep -aqE "$pat" "$f" 2>/dev/null && return 0
  return 1
}

wait_engine_done() {
  # 2026-11-28: 上限 1800→3600s。大包(10GB+)实测可能超过 30 分钟, 旧上限会在引擎
  # 仍正常写入时误判超时; 超时只提示、不 die/不刷 LK/不重启(见超时分支与段8.6/段9)。
  local timeout="${OTA_WAIT_TIMEOUT:-3600}" waited=0 L ur code
  while [ "$waited" -lt "$timeout" ] 2>/dev/null; do
    # (1) 失败归档 (仅本次新增)
    if [ -d "$UE_ERR_DIR" ]; then
      for f in "$UE_ERR_DIR"/*; do
        [ -f "$f" ] || continue
        case " $WAIT_ERR_SEEN " in
          *" $f "*) ;;
          *)
            WAIT_ERR_SEEN="$WAIT_ERR_SEEN $f"
            code=$(grep -aoE 'ErrorCode=[0-9]+|error_code[^0-9]*[0-9]+|kErrorCode[^0-9]*[0-9]+' "$f" 2>/dev/null | grep -aoE '[0-9]+' | head -1)
            if [ -z "$code" ]; then
              # 归档里没有可解析的错误码: 若文本明确指出"包验证失败"仍按 10 返回,
              # 以便保留"回退系统证书重试一次"; 其余未知失败用 99, 不再一律兜底成 10
              # (兜底成 10 会触发无谓的证书回退, 并把诊断引向证书方向)。
              if grep -aqiE 'Failed to verify package|PayloadVerificationError|signature verification failed' "$f" 2>/dev/null; then
                code=10
              else
                code=99
              fi
            fi
            log "⚠ 引擎写出失败归档 $f, 判定安装失败 (错误码=${code})"
            return $code
            ;;
        esac
      done
    fi
    L=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | head -1)
    if [ -n "$L" ]; then
      # 锚点之后出现"验证/证书失败" -> 返回 10 (触发证书回退)
      if new_log_grep 'Failed to verify package'; then
        log "⚠ 引擎日志出现验证/证书失败终态 (Failed to verify package)"
        return 10
      fi
      # 锚点之后出现明确失败终态 -> 立即判失败 (修复: 之前会漏掉 kDownloadTransferError)
      if new_log_grep 'ErrorCode::k[A-Za-z]*Error|Didn.t get enough bytes|Aborting processing due to failure|SendPayloadApplicationComplete \[[1-9][0-9]*\]'; then
        log "⚠ 引擎日志出现失败终态 (传输/其他错误), 判定安装失败"
        return 4
      fi
      # 成功终态: UPDATED_NEED_REBOOT
      if new_log_grep 'UPDATED_NEED_REBOOT'; then
        log "✅ 引擎报告 UPDATED_NEED_REBOOT (写入完成, 等待重启生效)"
        return 248
      fi
      # 成功终态: 锚点之后的 SendPayloadApplicationComplete [0]
      if new_log_grep 'Update successfully applied|SendPayloadApplicationComplete \[0\]'; then
        log "✅ 引擎报告写入成功 (SendPayloadApplicationComplete [0])"
        return 0
      fi
      # (4) 引擎回 IDLE 但无成功标记 -> prefs/update-result 判定 (仅看锚点后新内容)
      # 注意: "waiting on markBootSuccessful" 不是 IDLE, 是 CleanupPreviousUpdateAction
      # 的卡死等待行, 不能当成功/空闲信号 (2026-09-06 复盘; IDLE 闸已保证提交前无此状态)
      if new_log_grep 'UPDATE_STATUS_IDLE' \
         && ! new_log_grep 'Downloading|Applying|Verifying|Finalizing|ActionProcessor|processing|postinstall'; then
        ur=$(cat /data/misc/update_engine/prefs/update-result 2>/dev/null)
        [ "$ur" = "0" ] && { log "✅ 引擎回到 IDLE 且 update-result=0 (成功)"; return 0; }
        log "⚠ 引擎回到 IDLE 且无成功标记 (update-result=${ur:-无}), 判定未完成"
        return 89
      fi
    fi
    # (4b) 引擎进程退出 -> 以 prefs 判定
    if ! pgrep -x update_engine >/dev/null 2>&1; then
      ur=$(cat /data/misc/update_engine/prefs/update-result 2>/dev/null)
      [ "$ur" = "0" ] && { log "✅ 引擎进程退出且 update-result=0 (成功)"; return 0; }
      log "⚠ 引擎进程已退出且无成功标记 (update-result=${ur:-无}), 判定未完成"
      return 89
    fi
    sleep 5
    waited=$((waited + 5))
  done
  log "⚠ 等待引擎完成超时 (${timeout}s): 安装状态未知, 本次不按成功处理"
  # 2026-11-28: 超时只提示、不 die/不刷 LK/不重启 —— 引擎很可能仍在后台正常写入,
  # 此时若 die 会让脚本提前结束(LK 不刷、小结不出), 用户误以为完成而手动重启 -> 变砖。
  log "   → 引擎可能仍在后台写入, 本次【不切槽 / 不刷 LK / 不重启】, 脚本以提示结束"
  log "   → 请用『查看安装进度』确认引擎终态; 若稍后出现 UPDATED_NEED_REBOOT,"
  log "     再用『手动切启动槽』下发切槽、确认待生效槽后, 再手动刷 LK 并重启"
  log "   → 未确认写入前切勿重启(新系统 + 旧 LK 会无法开机)"
  return 124
}

# update_engine 的 UPDATED_NEED_REBOOT 等状态会持久化在 /data/misc/update_engine 下,
# 单纯 pkill + 重启进程, 进程起来后会从磁盘恢复旧状态, 导致新 --update 被 66 拒绝。
#
# 重要: 清状态目录只删元数据(prefs/进度), 不会动已写进目标 slot 分区的镜像数据。
# 但为安全起见, 默认绝不主动清状态 —— 因为处于 UPDATED_NEED_REBOOT 往往意味着"上一次刷的包
# 已应用、正等重启生效", 此时应让用户去重启使其生效, 而不是清掉状态重刷(否则旧包可能白刷)。
# 仅当用户明确传 FORCE=1 (环境变量) 或第6参数(force)=1 时, 才允许清状态强制重刷。
clear_ue_state() {
  # 安全闸 (2026-09-06 复盘): 引擎持有待合并快照(merge status≠none)时, 删 prefs 会
  # 破坏 VAB 收尾, 且清完重启引擎只会重进 CleanupPreviousUpdateAction 卡死。
  # 先走 markBootSuccessful+merge 正常收尾, 成功则无需强清; 失败才按 FORCE 语义继续。
  if ! ue_merge_status_none; then
    log "  [reset] ⚠ 检测到待合并快照 (merge status≠none), 先走正常收尾而非直接清状态"
    if ue_wait_idle; then
      log "  [reset] ✅ 收尾已完成, 引擎回干净 IDLE, 跳过强清"
      return 0
    fi
    log "  [reset] ⚠ 正常收尾未完成, 继续强清状态 (有风险, 仅 FORCE 语义下应走到这)"
  fi
  pkill -9 update_engine 2>/dev/null
  sleep 1
  # 官方清状态流程 (真机实测验证): 顺序必须是 cancel -> reset_status -> 删目录兜底。
  # 否则 reset_status 会报 "Already processing an update, cancel it first" (rc=248)。
  # 对应 Custota 的 REVERT / resetStatus 思路, 比手删目录更干净(走引擎自身状态机)。
  if [ -x "$UPDATE_ENGINE_CLIENT" ]; then
    OUT=$("$UPDATE_ENGINE_CLIENT" --cancel 2>&1)
    log "  [reset] cancel: $OUT"
    OUT=$("$UPDATE_ENGINE_CLIENT" --reset_status 2>&1)
    log "  [reset] reset_status: $OUT"
  fi
  # ---- 对齐 vivo 排错手册步骤3/4: 备份 + 按"卡死文件"清单删除 + 清 tmp ----
  PREFS=/data/misc/update_engine/prefs
  if [ -d "$PREFS" ]; then
    # 步骤3: 先备份整份 prefs, 万一清错可回滚
    BAK="${PREFS}.bak.$(date +%s)"
    cp -r "$PREFS" "$BAK" 2>/dev/null && log "  已备份 prefs -> $BAK"
    # 步骤4: 按手册列出的"卡死文件"清单精确删除
    # (update-state-* / payload_url / target-version / persist-update-errorcode /
    #  payload-attempt-number / previous-version / 下载进度 / resumed-update-failures)
    rm -f "$PREFS"/update-state-* \
          "$PREFS"/payload_url \
          "$PREFS"/target-version \
          "$PREFS"/persist-update-errorcode \
          "$PREFS"/payload-attempt-number \
          "$PREFS"/previous-version \
          "$PREFS"/current-bytes-downloaded \
          "$PREFS"/total-bytes-downloaded \
          "$PREFS"/resumed-update-failures 2>/dev/null
    # 更彻底: prefs 下还有 manifest-bytes/update-state-next-*/caller_src/full-payload 等
    # 大量残留, 备份后整体清空最稳妥 (手册步骤4 亦建议直接清空 prefs)。
    rm -rf "$PREFS"/* 2>/dev/null
    mkdir -p "$PREFS" 2>/dev/null
    log "  已清空 $PREFS/* (备份见 $BAK)"
  fi
  # 步骤4: 清空临时目录
  rm -f /data/misc/update_engine/tmp/* 2>/dev/null
  # 兜底: 直接删单文件形态的状态(部分 ROM 把状态放单文件)
  rm -f /data/misc/update_engine/update_engine_prefs 2>/dev/null
}

# 是否允许强制清状态重刷: 环境变量 FORCE=1 或第6参数(force)=1
# 与第5参数(reboot)解耦, 二者互不影响。
# (修订 2026-08-27: 此处原误读 $7(实际是 lk 开关), 会导致勾选 LK 意外触发清状态强制重刷)
FORCE_REFRESH=0
[ "${FORCE}" = "1" ] && FORCE_REFRESH=1
[ "$6" = "1" ] && FORCE_REFRESH=1

# vivo 的 update_engine 是后台 daemon, 进度不回显到终端, 只落盘到:
#   /logdata/recovery/update_engine_log/update_engine.*
# 为实时展示进度, 安装期间后台轮询该日志目录并把增量转发到终端(着色)+纯文本镜像; 安装结束后停掉。
# (UE_LOG_DIR / UE_ERR_DIR 由 ota_common.sh 定义, 勿在此重复赋值)
UE_TAIL_PID=0

# 为什么不用 tail -F:
#   `tail -F "$UE_LOG_DIR"/update_engine.*` 会被 shell 在启动瞬间把通配符展开成
#   "当时已存在的文件列表", tail 只跟随这些文件。而 attempt_install 里会先
#   pkill update_engine 再 ctl.start 重新拉起 daemon, 引擎随即新建
#   update_engine.<新时间戳>.<n> —— 新文件不在列表内, 永远不会被跟随, 进度直接断流。
#   即使只 tail 单个 latest 文件, 安装中途引擎再次轮转日志同样会断。
#   故改为: 后台子进程按固定间隔轮询"当前最新文件 + 已读偏移", 增量输出,
#   文件轮转/截断都能正确跟随。
start_ue_log_tail() {
  if [ ! -d "$UE_LOG_DIR" ]; then
    log "  ⚠ 未找到 $UE_LOG_DIR, 无法实时转发进度(可手动 cat 查看)"
    return 0
  fi
  (
    # dd bs=1 是逐字节 read(), 安装高峰期引擎一次写几十 KB 会跟不上;
    # 优先用 tail -c +N (toybox 支持, N 为 1-based 字节起点) 一次取走增量。
    tail_c_ok=0
    printf 'ab' | tail -c +2 2>/dev/null | grep -q 'b' 2>/dev/null && tail_c_ok=1
    emit() { # emit <file> <from> <count>
      # 引擎底层日志量极大 (逐行下载/校验/写入), 只转发关键行到终端/镜像, 过滤细节噪声
      if [ "$tail_c_ok" = "1" ]; then
        tail -c +$(( $2 + 1 )) "$1" 2>/dev/null | filter_stream
      else
        dd if="$1" bs=1 skip="$2" count="$3" 2>/dev/null | filter_stream
      fi
    }
    cur=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | head -1)
    off=0
    # 已存在的日志从当前末尾开始跟, 避免把历史内容整份回放到安装输出里
    [ -n "$cur" ] && off=$(stat -c %s "$cur" 2>/dev/null || echo 0)
    err_seen=""
    [ -d "$UE_ERR_DIR" ] && err_seen=$(ls "$UE_ERR_DIR" 2>/dev/null | tr '\n' ' ')
    while true; do
      new=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | head -1)
      # 引擎轮转出新日志: 先收干旧文件尾巴, 再切到新文件
      if [ -n "$new" ] && [ "$new" != "$cur" ]; then
        if [ -n "$cur" ] && [ -f "$cur" ]; then
          end=$(stat -c %s "$cur" 2>/dev/null || echo 0)
          cnt=$((end - off))
          [ "$cnt" -gt 0 ] 2>/dev/null && emit "$cur" "$off" "$cnt"
        fi
        cur="$new"; off=0
        printf '%s---- 引擎已轮转日志, 切换跟随: %s ----%s\n' "$C_BLU" "$cur" "$C_RST"
        [ "$UE_LOG_WRITABLE" = "1" ] && echo "---- 引擎已轮转日志, 切换跟随: $cur ----" >> "$UE_MIRROR"
      fi
      # 增量读取当前文件
      if [ -n "$cur" ] && [ -f "$cur" ]; then
        size=$(stat -c %s "$cur" 2>/dev/null || echo 0)
        [ "$size" -lt "$off" ] 2>/dev/null && off=0   # 被截断则从头再读
        cnt=$((size - off))
        [ "$cnt" -gt 0 ] 2>/dev/null && emit "$cur" "$off" "$cnt"
        off="$size"
      fi
      # 失败归档目录出现新文件 -> 立即提示(引擎失败时关键细节写在这里)
      if [ -d "$UE_ERR_DIR" ]; then
        for f in $(ls "$UE_ERR_DIR" 2>/dev/null); do
          case " $err_seen " in
            *" $f "*) ;;
            *)
              printf '%s⚠ 引擎写出新的失败归档: %s/%s%s\n' "$C_RED" "$UE_ERR_DIR" "$f" "$C_RST"
              [ "$UE_LOG_WRITABLE" = "1" ] && echo "⚠ 引擎写出新的失败归档: $UE_ERR_DIR/$f" >> "$UE_MIRROR"
              err_seen="$err_seen $f"
              ;;
          esac
        done
      fi
      sleep 2
    done
  ) &
  UE_TAIL_PID=$!
  log "已开启 update_engine 日志实时转发(着色, 自动跟随轮转)并镜像到 $UE_MIRROR"
}
stop_ue_log_tail() {
  if [ "$UE_TAIL_PID" -ne 0 ] 2>/dev/null; then
    kill "$UE_TAIL_PID" 2>/dev/null
    # 收尾: 等一拍让最后一批增量落地, 再确保子进程退出
    sleep 1
    kill -9 "$UE_TAIL_PID" 2>/dev/null
  fi
  UE_TAIL_PID=0
}

# ---------- 7.5 applypayload 前的"干净 IDLE"闸 (2026-09-06 真机复盘) ----------
# 背景: 引擎若带着上次未完成的 Virtual A/B 收尾, 启动即调度 CleanupPreviousUpdateAction,
# 卡在 "Boot completed, waiting on markBootSuccessful()" —— 当前槽未被标记 boot
# successful(正常由 update_verifier/framework 开机后调用, 被本脚本杀引擎/停 updater 打断),
# cleanup 永不结束 -> 引擎恒忙: --cancel 报错54, 新 applypayload 被错误65/741 拒收。
# 此时 cancel/reset_status/强清 prefs 全都解不开(引擎重启后重进同一状态)。
# 解法(复盘第五/六节): 手动补 markBootSuccessful(IBootControl txn=8, 真机实测幂等)
# 让 cleanup 自然走完 merge 回到干净 IDLE, 再提交新安装。
UE_HAL_SVC=""
ue_hal_service() {
  if [ -z "$UE_HAL_SVC" ]; then
    UE_HAL_SVC=$(boot_hal_svc)
  fi
  [ -n "$UE_HAL_SVC" ]
}

# getSnapshotMergeStatus(txn=4, 实测映射) 的原始值: 0=干净(none), 非0=有待合并快照。
# 取不到(无服务 / 输出里解析不出 Result 数值) 时返回非 0 且不输出 —— 调用方必须能区分
# "干净" 与 "查询失败", 不能把"查不到"当成"干净"(AGENTS 已记录过这次误判的教训)。
ue_hal_merge_status() {
  ue_hal_service || return 1
  local out raw tok ms
  out=$(service call "$UE_HAL_SVC" 4 2>/dev/null)
  raw=$(printf '%s' "$out" | sed -n 's/.*Result: *//p')
  [ -n "$raw" ] || return 1
  # 2026-11-27 P0 修复: 必须先确认 raw 里真有数值 token, 再把前导 0 剥掉。
  # 旧实现直接 `grep ... | sed 's/^0*//'` 后 `[ -n "$ms" ] || ms=0`, 于是
  # "Result: (null)" 这类解析不出数值的输出被兜底成 0=干净 —— 调用方无从区分
  # "查不到"与"真干净"(AGENTS.md 已记录过这次误判)。
  tok=$(printf '%s' "$raw" | grep -oE '0x[0-9a-fA-F]+|[0-9a-fA-F]{8}|[0-9]+' | head -1)
  [ -n "$tok" ] || return 1
  ms=$(printf '%s' "$tok" | sed 's/^0*//')
  [ -n "$ms" ] || ms=0   # tok="0" 剥完为空, 归一回 0
  printf '%s\n' "$ms"
}

# 三态判定 (2026-11-27 P0 修复): 0=确认干净, 1=未就绪/未知(拒绝放行)。
# 无 HAL(非 A/B)仍视为干净 —— 这类设备没有 VAB 快照概念, 保持既有主流程。
# 但 HAL 服务存在、查询失败/解析不出数值时绝不能当干净: 旧实现 `|| return 0`
# 会把"查不到"伪装成"干净", 让 IDLE 闸形同虚设(与 2026-09-13 "HAL 查不到当干净"
# 同类误判), 带状态硬提交只会被 741 拒收。与 cancel.sh 的 OTA_HAL_STRICT 对齐。
ue_merge_status_none() {
  local ms
  ue_hal_service || return 0   # 无 HAL(非 A/B) 视为干净
  ms=$(ue_hal_merge_status) || return 1
  [ "$ms" = "0" ]
}

# snapshotctl 官方判定 (不可用/无输出时回退成功, 由 HAL txn4 兜底)
ue_snapshot_state_none() {
  local out
  out=$(snapshotctl dump 2>/dev/null | grep -i 'Update state' | tail -n1)
  [ -z "$out" ] && return 0
  printf '%s' "$out" | grep -qi 'none'
}

# IDLE 闸主流程: mark 当前槽成功 -> --merge 收尾(有就合并/没有秒回) -> 双通道校验 none。
# 返回 0=干净可安装; 1=仍未就绪(调用方必须中止, 严禁带状态硬提交撞 741)。
# 检测"残留未激活快照": Update state=initiated 且 HAL 无可合并项(merge status=none)。
# 这类快照是上次安装已创建目标槽快照、但从未激活/重启生效遗留的 (见 2026-09-21 复盘):
#   它没有可 merge 的东西, --merge 推不动, idle-gate 只会反复报"收尾未完成"并中止。
#   正确处理是 --cancel + --reset_status 丢弃 (快照指向非当前运行槽, 丢弃不影响在跑系统)。
ue_snapshot_initiated_stale() {
  local st ms
  st=$(snapshotctl dump 2>/dev/null | grep -i 'Update state' | tail -n1)
  # 必须是 initiated (不是 merging/在合并中)
  printf '%s' "$st" | grep -qi 'initiated' || return 1
  # 且 HAL 必须"查询成功并明确返回 none(=0)"。丢弃快照是破坏性动作, 只有在确认无待合并项时
  # 才允许; HAL 查不到(服务缺失/输出解析失败)一律返回 1 —— 宁可中止安装并提示用户重启,
  # 也不把"查不到"当成"干净"而误丢快照。
  ue_hal_service || return 1
  ms=$(ue_hal_merge_status) || return 1
  [ "$ms" = "0" ]
}

ue_wait_idle() {
  log "  [idle-gate] 提交前闸: markBootSuccessful(txn=8, 幂等) + merge 收尾 + merge 状态校验"
  if ! pgrep -x update_engine >/dev/null 2>&1; then
    setprop ctl.start update_engine 2>/dev/null
    sleep 3
  fi
  if ue_hal_service; then
    service call "$UE_HAL_SVC" 8 >/dev/null 2>&1
  else
    log "  [idle-gate] ⚠ 未找到 IBootControl 服务, 仅依赖 --merge 收尾"
  fi
  "$UPDATE_ENGINE_CLIENT" --merge > "$TMP/ue_merge.out" 2>&1
  MERGE_RC=$?
  if [ "$MERGE_RC" -ne 0 ]; then
    log "  [idle-gate] --merge 返回 $MERGE_RC: $(tail -n 2 "$TMP/ue_merge.out" 2>/dev/null | tr '\n' ' ')"
  fi
  if ue_merge_status_none && ue_snapshot_state_none; then
    log "  [idle-gate] ✅ 引擎已回干净 IDLE (merge status=none)"
    return 0
  fi
  # 自愈: 残留未激活快照(initiated 但无可 merge) -> --merge 无效, 直接 reset_status 丢弃
  if ue_snapshot_initiated_stale; then
    log "  [idle-gate] 检测到残留未激活快照 (Update state=initiated 但无可合并项), --merge 推不动"
    log "  [idle-gate] 自动 --cancel + --reset_status 丢弃残留 (指向非当前运行槽, 安全) ..."
    "$UPDATE_ENGINE_CLIENT" --cancel >/dev/null 2>&1
    "$UPDATE_ENGINE_CLIENT" --reset_status > "$TMP/ue_reset.out" 2>&1
    log "  [idle-gate] reset_status: $(tail -n 1 "$TMP/ue_reset.out" 2>/dev/null | tr '\n' ' ')"
    sleep 2
    if ue_merge_status_none && ue_snapshot_state_none; then
      log "  [idle-gate] ✅ 残留快照已丢弃, 引擎回干净 IDLE (Update state=none)"
      return 0
    fi
  fi
  # 收尾未完成: 补一次引擎重启让它重排 cleanup(当前槽已 successful, 会立即通过并收尾)
  log "  [idle-gate] 收尾未完成, 重启引擎重排 cleanup 后再验一次 ..."
  setprop ctl.restart update_engine 2>/dev/null
  sleep 5
  "$UPDATE_ENGINE_CLIENT" --merge > "$TMP/ue_merge.out" 2>&1
  if ue_merge_status_none && ue_snapshot_state_none; then
    log "  [idle-gate] ✅ 引擎已回干净 IDLE (merge status=none)"
    return 0
  fi
  # 重启后再兜底一次残留快照丢弃 (部分固件重排 cleanup 后才暴露 initiated 状态)
  if ue_snapshot_initiated_stale; then
    log "  [idle-gate] 重启后仍为残留未激活快照, 再次 reset_status 丢弃 ..."
    "$UPDATE_ENGINE_CLIENT" --cancel >/dev/null 2>&1
    "$UPDATE_ENGINE_CLIENT" --reset_status > "$TMP/ue_reset.out" 2>&1
    sleep 2
    if ue_merge_status_none && ue_snapshot_state_none; then
      log "  [idle-gate] ✅ 残留快照已丢弃, 引擎回干净 IDLE (Update state=none)"
      return 0
    fi
  fi
  log "  [idle-gate] ✗ 引擎未回到干净 IDLE, 中止安装 (带状态硬提交只会被 741 拒收)"
  log "  [idle-gate]   请正常重启设备, 开机后等待 1-2 分钟再重试; 切勿反复杀引擎/清状态。"
  return 1
}

attempt_install() {
  # 文档坑1 (90% 反复失败原因): 必须先停 com.bbk.updater, 否则它会持续抢占
  # update_engine 并重新写回状态, 清完状态也会被它覆盖。am force-stop 无需恢复
  # (系统更新会自行恢复; 只有 pm disable 才需要手动 enable)。
  # 但 2026-09-06 复盘修正: com.bbk.updater/update_verifier 正是开机后调用
  # markBootSuccessful 的正常链路 —— 开机未完成就杀它, 当前槽会永远停在
  # "未标记成功", 引擎卡死 CleanupPreviousUpdateAction。故仅当系统已完成启动
  # (留足标记窗口)才停; 刚开机则跳过, 宁可晚一点装也不抢 markBootSuccessful。
  if [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; then
    log "⚠ sys.boot_completed!=1 (开机未完成), 跳过停 com.bbk.updater 以免打断 markBootSuccessful 链路"
  else
    am force-stop com.bbk.updater 2>/dev/null
    log "已停 com.bbk.updater (防止抢占 update_engine, 文档坑1)"
  fi
  sleep 1
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
  # 文档步骤5/6: launch 前必须 --cancel 探测, 清掉上一次"已取消但未清理干净"的会话,
  # 避免残留会话干扰新安装。判读: "No ongoing update to cancel." + EXIT=248 或 EXIT=0
  # = 引擎空闲(可); "Already processing an update" = 仍有抢占/残留 -> 提示并强制清一次;
  # "CleanupPreviousUpdateAction is running"(错误54) = VAB 收尾卡死, cancel/clear 都解不开,
  # 只能走下方 IDLE 闸收尾解锁。
  # 2026-11-27 P2-13 (借鉴 V-ABHelper UpdateService.java:127-131 的 busy-as-resumable):
  # "waiting for reboot" 是【上次更新已成功写入、待重启生效】的可恢复态, 不是占用/失败。
  # 旧实现没有这个分支, 一旦 cancel 回显里出现该串就会被当作普通占用走 clear_ue_state,
  # 把上一次成功写入的包清掉。现显式识别: 不强制清状态, 交 IDLE 闸 + 用户 FORCE 决定。
  OUT=$("$UPDATE_ENGINE_CLIENT" --cancel 2>&1); RC_C=$?
  log "  [probe] launch 前 --cancel: $OUT (RC=$RC_C)"
  case "$OUT" in
    *"CleanupPreviousUpdateAction is running"*)
      log "  ⚠ 引擎卡在 CleanupPreviousUpdateAction (等 markBootSuccessful), 强清 prefs 解不开, 交由 IDLE 闸收尾 ..."
      ;;
    *"waiting for reboot"*)
      log "  ℹ 引擎报告 waiting for reboot: 上一次更新已应用待重启(可恢复态), 本次不强制清状态。"
      log "     若确实要覆盖重刷, 请勾『强制重刷(FORCE)』; 否则建议先重启让上一次生效。"
      ;;
    *"Already processing"*)
      log "  ⚠ 探测到引擎仍被占用 (Already processing), 强制清理状态后重拉引擎 ..."
      clear_ue_state
      setprop ctl.start update_engine 2>/dev/null
      sleep 3
      ;;
  esac
  # IDLE 闸 (2026-09-06 复盘第六节): 提交前必须确认引擎回干净 IDLE, 否则 applypayload
  # 被错误 65/741 拒收, 客户端 RC=248 又会被旧逻辑误判成"已应用待重启成功"。
  ue_wait_idle || die "引擎未回到干净 IDLE, 已中止安装 (详见 [idle-gate] 日志)"
  # 安装期间后台轮询日志实时转发进度 (替代 --follow 前台阻塞, 文档坑9)
  start_ue_log_tail
  log "================ 以下为 update_engine launch 输出 ================"
  run_client
  RC=$UE_RC
  stop_ue_log_tail
  log "================ update_engine launch 结束 (RC=$RC) ==============="
  return $RC
}

restore_system_certs() {
  # 撤销证书绕过, 恢复系统证书: 卸载 bind + 还原被 hexpatch 的二进制
  if [ "$CERT_BIND" = "1" ]; then
    umount /system/etc/security/otacerts.zip 2>/dev/null
    CERT_BIND=0
    log "  已卸载 otacerts.zip 的 bind 挂载"
    # 2026-11-27 P0 修复: bind 之前备份过系统原版证书(:573/:584), 但旧实现
    # 只 umount、从不把备份 cp 回去 —— 若 bind 期间有写入穿透到原文件, 系统证书
    # 会残留被改动的内容。这里显式还原; /system 只读(erofs)时 cp 失败不致命,
    # 因为 umount 后原文件本就重新可见, 仅作防御性回写。
    if [ -f "$SYS_OTACERTS_BACKUP" ]; then
      if cp -f "$SYS_OTACERTS_BACKUP" /system/etc/security/otacerts.zip 2>/dev/null; then
        log "  已从备份还原系统 /system/etc/security/otacerts.zip 原版"
      else
        log "  ⚠ 回写 otacerts.zip 备份失败(/system 只读?), bind 已卸载, 原文件应仍可见"
      fi
    fi
  fi
  if [ "$UE_PATCHED" = "1" ]; then
    # 2026-11-27 P1: 必须还原【原版】。旧实现 cp "$UE_BAK" "$UE" 里的 UE_BAK 是
    # hexpatch 过的工作副本, 等于把 patched 版又写回去, 根本没有回退到系统证书。
    ue_restore_original
    UE_PATCHED=0
  fi
}

# ---------- 6.9 安装前提示 (每次强制安装都提示, 与 XML 顶部 desc 内容一致) ----------
# 为什么必须提示"请勿退出":
#   kr-script 日志界面上的『退出』按钮会真杀脚本(forceStop -> kill -s 1 `pgrep -f kr_<uuid>`),
#   脚本一死, 后面的切槽 / 刷 LK / 安装小结全都不会执行; 此时若重启, update_engine 会
#   Removing all update state 把刚写入的目标槽回滚清空(update-result 变 1) —— 等于白刷。
#   『隐藏』按钮只收起界面、不杀进程, 安装继续; 故提示必须把两者区别讲清楚。
log "⚠ 安装进行中, 视包大小可能耗时数分钟到约 30 分钟(等待上限 1800s), 请勿退出安装界面"
log "  点『退出』= 终止本脚本 -> 切槽 / 刷 LK / 小结都不会执行, 重启时引擎会回滚清空刚写入的槽"
log "  点『隐藏』= 仅收起界面, 脚本与安装继续 (之后可用『查看安装进度』回看)"

# 安装前预置 ota89 包装器(防御性兜底, 非守护), 再真正执行安装
ota89_install_wrapper
attempt_install
RC=$?
# 安装结束(无论成败)清理临时包装器, 避免影响工具目录原有二进制
ota89_cleanup_wrapper

# 失败判定策略 (2026-11-27 P0 修复): 改为「已知成功码白名单」。
# 旧实现是失败码黑名单 FAIL_CODES="4 9 10 15 66 89 92 99" —— 21/42 这类
# code_to_text 认得、失败归档解析(view :767)也会返回的码因不在黑名单里, 被当成
# 成功一路走到切槽+刷 LK。新增错误码时黑名单会反复漏, 故反转:
#   成功仅 SUCCESS_CODES="0 1 248" (0/1=写入成功, 248=UPDATED_NEED_REBOOT 待重启);
#   124 = 等待超时、状态未知, 既非成功也非明确失败, 由段7/段9单独拦截(不切槽/不重启);
#   其余一切(含 21/42 及任何未知码)按失败处理, 并在下方 case 的 * 分支 die。
SUCCESS_CODES="0 1 248"
is_success_code() {
  local c="$1" f
  for f in $SUCCESS_CODES; do
    [ "$c" = "$f" ] && return 0
  done
  return 1
}
is_fail_code() {
  [ "$1" = "124" ] && return 1
  ! is_success_code "$1"
}

# 错误码 -> 人类可读含义 (借鉴 Custota 的 UpdateEngineError/UpdateEngineStatus 枚举表思路)
# 覆盖 vivo update_engine 常见返回码; 未知码回退为"未知/需查 logcat"。
# 注意: 0/1 视为成功, 248=UPDATED_NEED_REBOOT 视为成功(待重启), 这些在 SUCCESS_CODES 里;
# 124=等待超时状态未知, 不进成功也不进失败 case, 由段7/段9单独拦截。
code_to_text() {
  case "$1" in
    0)   echo "成功 (SUCCESS)" ;;
    1)   echo "成功 (update_engine 以 1 退出但无其他失败迹象, 视为成功)" ;;
    4)   echo "下载/传输错误 (kDownloadTransferError=4, 多因 payload 读取/大文件路径或 size 参数问题)" ;;
    9)   echo "传输/解压错误或温控中止 (kDownloadPayloadDecompressionError/Thermal=9)" ;;
    10)  echo "签名/证书校验失败 (kErrorCode=10, Failed to verify package)" ;;
    15)  echo "新 rootfs 验证失败 (kNewRootfsVerificationError=15, 多因机型不匹配或附加载荷校验不过)" ;;
    89)  echo "读取附加载荷失败 (kErrorCode=89, Failed to get additional payloads)" ;;
    92)  echo "降级被拒 (kDowngrade=92, 需开启降级模式 ro.ota.allow_downgrade=true)" ;;
    248) echo "已应用, 等待重启生效 (UPDATED_NEED_REBOOT=248, 视为成功)" ;;
    66)  echo "状态机冲突 (kErrorCode=66, 上一次状态未清, 通常需重启后再试或 FORCE=1 强制清状态)" ;;
    21)  echo "payload 元数据大小校验失败 (kDownloadInvalidMetadataSize=21, headers 解析异常)" ;;
    42)  echo "payload 哈希/大小校验失败 (kPayloadHashMismatch/SizeMismatch=42)" ;;
    99)  echo "引擎写出失败归档但错误码不可解析 (未知失败, 按一般失败处理; 归档文本明确指向验证失败时仍取 10 走证书回退, 详见 $UE_ERR_DIR 归档)" ;;
    124) echo "等待引擎完成超时, 安装状态未知 (非失败也非成功: 未切槽, 请用『查看安装进度』确认后再决定)" ;;
    *)   echo "未知返回码 ($1), 需结合 logcat / update_engine_log 进一步诊断" ;;
  esac
}

# 248 = UPDATED_NEED_REBOOT 的强制重刷分支已移除 (2026-10-25): 原实现被整段注释掉,
# 是死代码; 实际语义由 wait_engine_done 返回 248 + 段7 切槽 + 段9 重启引导覆盖。
# 需要强制重刷时用『强制重刷(FORCE)』开关, 它走 clear_ue_state。

# 回退1: 证书绕过校验失败(错误码10=验证失败) -> 回退系统证书重试一次
# 注意: 仅当证书绕过确实生效过(CERT_ACTIVE=1)才回退, 避免无谓重试。
if [ "$RC" = "10" ] && [ "$CERT_ACTIVE" = "1" ]; then
  log "证书绕过校验失败(RC=10=Failed to verify package), 回退系统证书重试一次"
  restore_system_certs
  attempt_install
  RC=$UE_RC
  log "回退系统证书后重试返回 RC=$RC"
fi

# 失败收尾: 除 SUCCESS_CODES(0/1/248) 与 124(状态未知)外一律按失败中止, 绝不带着
# 未确认的 RC 继续切槽/刷 LK。case 末尾必须有 * 兜底, 否则新增错误码仍会穿透。
if is_fail_code "$RC"; then
  case "$RC" in
    21)
      die "update_engine 返回 21 (payload 元数据大小校验失败, headers 解析异常, 详见 update_engine_log)" ;;
    42)
      die "update_engine 返回 42 (payload 哈希/大小校验失败, 包损坏或机型不匹配, 详见 update_engine_log)" ;;
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
    4)
      die "update_engine_client 返回 4 (kDownloadTransferError: payload 读取/传输错误, 多因 offset/size 参数或大文件路径问题, 详见 update_engine_log)"
      ;;
    9)
      die "update_engine_client 返回 9 (传输/解压/温控中止, 详见 update_engine_log)"
      ;;
    10)
      die "update_engine_client 返回 10 (Failed to verify package, 签名/证书校验失败)"
      ;;
    66)
      die "update_engine 返回 66 (launch 被拒/引擎未接受: 状态机被占用或收尾卡死, 见上方 [probe]/[idle-gate]/launch 输出; 可用『取消当前安装』走收尾解锁, 或重启设备后再试)"
      ;;
    99)
      die "update_engine 写出失败归档但错误码不可解析 (未知失败, 已避免一律误判成证书失败; 归档内容见 $UE_ERR_DIR, 并查 logcat 进一步定位)"
      ;;
    89|92)
      die "update_engine_client 返回 $RC (状态机/ slot 冲突, 通常需重启设备后再试)"
      ;;
    *)
      die "update_engine_client 返回未识别的失败码 $RC ($(code_to_text "$RC")), 已中止后续切槽/刷 LK"
      ;;
  esac
fi

log "update_engine_client 返回 $RC ($(code_to_text "$RC"))"

# ---------- 8. 保留 ROOT: 已彻底移除 (2026-08-26) ----------
# 移除原因:
#   1) 之前"假成功"误判会把已修补的 init_boot 刷入, 之后平刷同包触发校验报错。
#   2) init_boot ROOT 刷入失败时, 会阻止后续 LK 修补刷入, 存在变砖风险。
# 故 OTA 安装不再支持一并 ROOT; 需要 ROOT 请单独用 KernelSU/Magisk 操作。
# 代码块已于 2026-10-25 删除 (原为 ROOT_ENABLED=0 硬关闭的死代码)。
# ROOT_ENABLED 常量保留, 供 print_install_env 判断是否打印 ROOT 方案(恒为 0, 即不打印)。
ROOT_ENABLED=0

# ---------- 9. 完成 ----------
# 进度已通过 run_client 后台 launch + start_ue_log_tail 增量转发到终端, 无需再提示"正在写入"。

# 安装小结的运行环境头部 (复用: 重启/非重启两分支共用, 便于事后排查)。
# 含: 包名/机型/型号/当前+目标 slot/返回码/ROOT 方案/证书绕过方式/thermal 阈值。
print_install_env() {
  log "  包: $(basename "$ROM")"
  log "  机型代号: ${DEVICE:-未知} (当前: ${CUR_DEVICE:-未知})"
  CUR_MODEL=$(getprop ro.product.model 2>/dev/null)
  [ -n "$CUR_MODEL" ] && log "  型号: $CUR_MODEL"
  log "  当前 slot=$CUR_SLOT  目标 slot=$TARGET_SLOT"
  log "  返回码: $RC ($(code_to_text "$RC"))"
  # ROOT 方案: 优先 KernelSU, 其次 Magisk, 否则未保留
  if [ "$ROOT_ENABLED" = "1" ]; then
    if [ -x "$KSU_BIN/ksud" ] || pgrep -x "ksud" >/dev/null 2>&1 || [ -d /data/adb/ksu ]; then
      log "  保留 ROOT: $ROOT_PART$TARGET_SLOT (方案 KernelSU)"
    elif [ -x "$MAGISK_BIN/magisk" ] || [ -d /data/adb/magisk ]; then
      log "  保留 ROOT: $ROOT_PART$TARGET_SLOT (方案 Magisk)"
    else
      log "  保留 ROOT: $ROOT_PART$TARGET_SLOT (方案未知)"
    fi
  fi
  # LK 是整条流程里最危险的一步, 小结里给全: 刷到哪个节点、刷的哪个镜像、多大、校验结果。
  # 原先只有一行"已写入 LK: <设备节点>" —— 镜像名和大小都看不到, 事后无法确认刷的是哪个包。
  # 另附一行结构化标记 LK_INFO, 便于 grep / 事后脚本解析(与 status.sh summary 收录习惯一致)。
  if [ "$LK_ENABLED" = "1" ]; then
    case "$LK_VERIFY" in
      1) log "  LK: 已写入 $LK_DEV_NODE (回读校验通过)" ;;
      0) log "  LK: 🚨 已写入 $LK_DEV_NODE 但回读校验失败! 已阻止自动重启, 请重刷 LK" ;;
      *) log "  LK: 已写入 $LK_DEV_NODE (未做回读校验)" ;;
    esac
    log "  LK 镜像: ${LK_IMG##*/}"
    log "  LK 路径: $LK_IMG"
    if [ -n "$LK_SZ" ]; then
      log "  LK 大小: 镜像=${LK_SZ}B  分区=${LK_PSZ:-未知}B"
    fi
    [ -n "$IMG_SUM" ] && log "  LK sha256(镜像): $IMG_SUM"
    [ -n "$RD_SUM" ]  && log "  LK sha256(回读): $RD_SUM"
    log "LK_INFO dev=${LK_DEV_NODE:-?} img=${LK_IMG:-?} sz=${LK_SZ:-?} psz=${LK_PSZ:-?} verify=${LK_VERIFY:-?} sha=${IMG_SUM:-?}"
  fi
  # 属性伪装(SPF): 已在 headers 追加 4 项伪造属性并 resetprop, 绕过机型/版本/防回滚校验
  if [ "$SPF" = "1" ]; then
    log "  属性伪装(SPF): 已启用 (伪造 vivo 系统属性 + resetprop 写入)"
  else
    log "  属性伪装(SPF): 未启用"
  fi
  # 恢复出厂(POWERWASH): 应用完成后自动 factory reset, 清空用户数据
  if [ "$POWERWASH" = "1" ]; then
    log "  ⚠ 恢复出厂(POWERWASH): 已启用 (OTA 应用完成后将清空用户数据)"
  else
    log "  恢复出厂(POWERWASH): 未启用"
  fi
  # 证书绕过方式: hexpatch > bind > 系统证书直装
  if [ "$CERT_ACTIVE" = "1" ]; then
    [ "$UE_PATCHED" = "1" ] && log "  证书绕过: hexpatch update_engine 路径"
    [ "$CERT_BIND" = "1" ]  && log "  证书绕过: bind 覆盖 otacerts.zip"
  else
    log "  证书: 未绕过(系统证书直装, 或官方包免绕过)"
  fi
  # thermal 阈值: 已被本脚本拉高到 120C(默认 46C), 记录实际生效值
  TH=$(getprop vota.virtual_ab.debug.thermal_threshold 2>/dev/null)
  [ -n "$TH" ] && log "  thermal 阈值: ${TH}mC (默认46000, 本脚本拉高防中途过热中止)"
  # 槽位: 2026-09-13 起不再做自动判定, 只如实说明"未校验", 结论交给用户查看槽位状态。
  if [ "$SLOT_PENDING" = "1" ]; then
    log "  槽位: 切槽指令已下发, 但本脚本不回读校验 (INSTALL_OK 等判据已废弃)"
    log "        请到『A/B 槽位管理 → 查看当前槽位状态』确认『待生效槽』是否为 $TARGET_SLOT"
  fi
  # 耗时统计: 从记录的安装开始时间算到小结打印时刻。
  if [ -n "$INSTALL_START_TS" ]; then
    END_TS=$(date +%s 2>/dev/null)
    if [ -n "$END_TS" ]; then
      ELAPSED=$(( END_TS - INSTALL_START_TS ))
      if [ "$ELAPSED" -ge 0 ] 2>/dev/null; then
        M=$(( ELAPSED / 60 )); S=$(( ELAPSED % 60 ))
        if [ "$M" -gt 0 ] 2>/dev/null; then
          log "  耗时: ${M}分${S}秒"
        else
          log "  耗时: ${S}秒"
        fi
      fi
    fi
  fi
}

# ---------- 7. 写入成功后手动切启动槽(核心闭环, 否则重启被回滚清空) ----------
# 仅当写入成功(RC=0/1/248 均为成功语义: 0/1=成功, 248=UPDATED_NEED_REBOOT 待重启)才切;
# 失败时跳过。文档坑11: 状态到 UPDATED_NEED_REBOOT 后必须立刻切槽, 否则 bootloader 仍从
# 原槽启动 -> 引擎回滚清空刚写入的槽 (update-result 变 1)。
#
# 2026-09-13 需求变更(B 方案): 切槽后不再回读校验, 且**不再自动重启** ——
#   既然无法确认切槽是否落地, 就不能替用户按下去; 带错槽重启会白刷(引擎回滚清空)。
#   改为提示用户自行查看槽位状态确认后手动重启。
#   非 A/B 设备(无 IBootControl)没有槽位概念, 不存在这个风险, 勾了重启仍照旧自动重启。
SWITCH_RC=0
SWITCH_BLOCK_REBOOT=0
INSTALL_WRITTEN=0
SLOT_PENDING=0
# RC 语义 (wait_engine_done 的返回值):
#   0   = 引擎日志确认写入成功 (SendPayloadApplicationComplete [0] / update-result=0)
#   1   = 引擎以 1 退出但无失败迹象 (历史兼容, 仍按成功)
#   248 = UPDATED_NEED_REBOOT (写入完成, 待重启生效)
#   124 = **等待超时, 状态未知** —— 绝不能当成功! 引擎可能还在写, 此时切槽/刷 LK
#         会在重启后被引擎回滚清空, 且 LK 已是新版本而系统还是旧的。
# 超时曾经 `return 0`, 于是下游把它当"写入成功"去切槽+刷 LK, 属于假成功(第三次同类
# 教训, 前两次是 248 与 HAL 查不到)。现在超时单独一个码, 下面按"状态未知"处理。
if [ "$RC" = "0" ] || [ "$RC" = "1" ] || [ "$RC" = "248" ]; then
  INSTALL_WRITTEN=1
  if [ -z "$TARGET_SLOT" ]; then
    log "ℹ 无目标槽信息(非 A/B), 跳过切槽。"
    SWITCH_RC=2
  else
    switch_active_slot "$TARGET_SLOT"; SWITCH_RC=$?
  fi
  case "$SWITCH_RC" in
    0) SLOT_PENDING=1 ;;                 # A/B: 指令已下发但未经校验 -> 不自动重启
    2) log "ℹ 非 A/B 设备, 无需切槽。" ;;  # 无 AIDL 接口
    1) log "🚨 切槽调用异常, 切勿直接重启, 否则刚写入的 $TARGET_SLOT 会被回滚清空。"
       log "   请重新执行一次安装(等 update-result=0), 再切槽; 或改用 fastboot 硬切。"
       SLOT_PENDING=1
       SWITCH_BLOCK_REBOOT=1 ;;
  esac
else
  log "ℹ 写入未完成(RC=$RC), 跳过切槽。"
fi

# ---------- 8.6 刷入 LK (bootloader) 镜像 ----------
# 位置: 本段已从"ROOT 之后/切槽之前"移到"手动切启动槽之后"。原因: 刷 bootloader 必须在
#   切槽动作之后进行 —— 切槽是否生效至少要出现在日志里
#   (AGENTS.md: 顺序反了是变砖前提)。
#   2026-11-27 P0 安全修复: 撤销 2026-09-11 的"全拆", 恢复"写入未确认就不刷 LK"硬闸 ——
#   超时(124)/状态未知时仍刷 LK 会留下"LK 是新版、系统还是旧版"的变砖前提。
# 参数 (ROOT 三项移除后前移 3 位):
#   $7  = lk 开关 (1=开启)
#   $8  = 用户选定的 lk 镜像文件路径
#   环境变量 LK_IMG / LK_DEV 可单独覆盖(LK_DEV 为精确设备节点, 跳过自动推断)
# 注意: 多数 vivo 机型 lk 为独立(非 A/B)分区, 无 slot 后缀; 若机型为 lk_a/lk_b 可设 LK_DEV 精确指定。
#
# 三重闸门 (刷 bootloader 是变砖高危操作):
#   ① 硬闸[2026-11-27 恢复]: 必须 INSTALL_WRITTEN=1(写入已确认成功) 才允许刷 LK;
#      超时/状态未知/失败 RC 一律 die, 不进 dd。撤销此前"勾选即刷"的全拆行为。
#   ② 可写: 写前 blockdev --setrw 解除只读/写保护, 否则 dd 直接 Permission denied 失败。
#   ③ size: 镜像 > 分区 -> die(会被截断, 必坏); 镜像 < 分区 -> 告警后继续(LK 头部自带
#      长度, 分区尾部残留旧数据通常不影响启动, 与 fastboot flash 行为一致)。
#   ⚠ ARB 防回滚熔丝无法由脚本豁免: SPF 只能清系统侧 ro.boot.anti.avb_anti_ver, 清不掉
#      bootloader 自身熔丝。刷入 anti_ver 更低的 LK 会触发熔丝 -> 拒启动(硬砖), 且脚本
#      全程不报错。务必确认镜像 anti_ver 不低于设备当前值。
LK_ENABLED=0
[ "${7}" = "1" ] && LK_ENABLED=1
LK_IMG="${LK_IMG:-${8}}"
# 2026-11-28: 重启闸用 —— 仅当"勾选了 LK 且真正写入并回读通过"才置 1。
# 脚本被中途杀掉/超时跳过/回读失败时它保持 0, 段9 据此禁止自动重启,
# 杜绝"新系统 + 旧 LK"变砖。
LK_DONE=0

if [ "$LK_ENABLED" = "1" ]; then
  # ── 闸门①[硬闸, 2026-11-27 恢复 / 2026-11-28 超时分支调整] ──
  # 写入未确认就绝不刷 LK。INSTALL_WRITTEN 仅在 RC=0/1/248 时置 1。
  # 2026-11-28: 超时(RC=124)是"状态未知"而非失败, 按决策只提示、不 die ——
  #   引擎可能仍在后台写入, 此时 die 会让脚本提前结束(LK 不刷、小结不出),
  #   用户误以为完成而手动重启 -> "新系统 + 旧 LK" 变砖。改为跳过 LK、不中止脚本,
  #   重启闸(段9)会继续拦住自动重启。
  LK_SKIP=0
  if [ "$INSTALL_WRITTEN" != "1" ]; then
    if [ "$RC" = "124" ]; then
      log "⏸ 本次等待超时(RC=124), 写入状态未知: 跳过刷 LK, 不中止脚本。"
      log "   请用『查看安装进度』确认引擎终态, 再手动切槽 / 刷 LK / 重启。"
      LK_SKIP=1
    else
      die "本次 OTA 写入未确认成功 (RC=$RC, INSTALL_WRITTEN=$INSTALL_WRITTEN), 已拒绝刷入 LK。请先用『查看安装进度』确认写入成功, 再单独刷 LK。"
    fi
  fi
  if [ "$LK_SKIP" != "1" ]; then
  # 切槽指令已下发但未经回读校验(SLOT_PENDING=1)属 B 方案常态, 不阻断刷 LK ——
  # LK 始终写入 lk$TARGET_SLOT(非当前运行侧), 不会因未回读而刷到运行槽。
  # 刷前 / 回读通过后 / 小结三处仍重申"LK 写入分区 ≠ 刷机包已刷入"。
  log "⚠ 即将刷入 LK: LK 写入分区不等于刷机包已刷入"
  if [ "$SLOT_PENDING" = "1" ]; then
    log "⚠ 本次切槽结果未经校验(需你自行查看槽位状态确认), LK 仍写入目标槽: 请勿把 LK 写入当作刷机包已刷入"
  fi
  [ -n "$LK_IMG" ] || die "开启'刷入 LK'后必须指定 lk 镜像文件路径 (第8参数 / LK_IMG)"
  [ -f "$LK_IMG" ] || die "指定的 LK 镜像不存在: $LK_IMG"

  # ⚠ 目标槽未知时禁止自动探测: 无 $TARGET_SLOT 的候选会退化成无后缀的 lk,
  #   在 A/B 机型上可能正是**当前运行槽**; 刷当前运行侧会在下次重启(哪怕是用户
  #   手动重启)立刻生效, LK 与在跑系统不匹配即硬砖。此时必须由用户显式给 LK_DEV。
  if [ -z "$TARGET_SLOT" ] && [ -z "$LK_DEV" ]; then
    die "读不到目标槽(ro.boot.slot_suffix 为空), 无法安全推断 LK 分区。请设 LK_DEV 精确指定设备节点, 或取消勾选『刷入 LK』。"
  fi

  if [ -n "$LK_DEV" ]; then
    LK_DEV_NODE="$LK_DEV"
  else
    # 自动探测 LK 分区: 优先按目标 slot 的 A/B 命名(lk_a/lk_b), 再回退固定名 lk
    # (实测 vivo PD2419/MTK: LK 是 A/B 分区, by-name 下只有 lk_a/lk_b, 无 lk)
    LK_DEV_NODE=""
    for cand in /dev/block/by-name/lk$TARGET_SLOT /dev/block/by-name/lk \
                /dev/block/bootdevice/by-name/lk$TARGET_SLOT /dev/block/bootdevice/by-name/lk; do
      if [ -b "$cand" ]; then
        LK_DEV_NODE="$cand"
        break
      fi
    done
  fi
  [ -n "$LK_DEV_NODE" ] && [ -b "$LK_DEV_NODE" ] || die "找不到 LK 分区设备: ${LK_DEV_NODE:-无} (已自动探测 lk_a/lk_b/lk, 仍失败请设 LK_DEV 精确指定)"
  # 恒定刷目标槽一侧: 即便切槽结果未知(未经校验)也刷 lk$TARGET_SLOT。
  # 不改刷当前运行槽 —— 那会在下一次重启(哪怕只是用户手动重启)立刻生效,
  # LK 与当前系统不匹配即硬砖; 刷非启动侧最坏只是本次不生效。
  if [ "$SLOT_PENDING" = "1" ]; then
    log "  注: 目标槽 $TARGET_SLOT 是否生效未经校验, LK 仍写入 $LK_DEV_NODE"
  fi

  # 闸门②: 解除只读/写保护 + 回读确认 (P2-14, 借鉴 V-ABHelper manager.sh:249-256)
  # 旧实现 setrw 后不校验, 只读分区上 dd 会静默失败/写不进, 靠末尾 sha256 回读才发现。
  # 现在 setrw 后立刻 --getro: 仍返回 1 说明写保护没解开, 直接 die, 不做无谓的 dd。
  blockdev --setrw "$LK_DEV_NODE" 2>/dev/null
  LK_RO=$(blockdev --getro "$LK_DEV_NODE" 2>/dev/null)
  case "$LK_RO" in
    1) die "LK 分区 $LK_DEV_NODE 仍为只读 (--setrw 未生效), 已中止写入" ;;
    0|'') [ -n "$LK_RO" ] || log "  ⚠ blockdev --getro 不可用, 跳过只读校验(由 dd + sha256 回读兜底)" ;;
    *)    log "  ⚠ blockdev --getro 返回异常值 '$LK_RO', 跳过只读校验" ;;
  esac

  # 闸门③: 大小校验 (stat 取镜像大小, blockdev 取分区字节数)
  LK_SZ=$(stat -c %s "$LK_IMG" 2>/dev/null)
  LK_PSZ=$(blockdev --getsize64 "$LK_DEV_NODE" 2>/dev/null)
  case "$LK_SZ" in ''|*[!0-9]*) LK_SZ="" ;; esac
  case "$LK_PSZ" in ''|*[!0-9]*) LK_PSZ="" ;; esac
  if [ -z "$LK_SZ" ] || [ -z "$LK_PSZ" ]; then
    log "  ⚠ 无法读取镜像/分区大小(镜像=${LK_SZ:-空} 分区=${LK_PSZ:-空}), 跳过大小校验, 自行承担风险"
  else
    if [ "$LK_SZ" -gt "$LK_PSZ" ] 2>/dev/null; then
      die "LK 镜像(${LK_SZ}B) 大于 LK 分区(${LK_PSZ}B): $LK_DEV_NODE —— 会被截断写入导致 bootloader 损坏, 已中止"
    fi
    if [ "$LK_SZ" -lt "$LK_PSZ" ] 2>/dev/null; then
      log "  ⚠ 镜像(${LK_SZ}B) 小于分区(${LK_PSZ}B): 尾部将残留旧 LK(LK 头部自带长度, 通常不影响启动)"
    fi
    log "  大小校验: 镜像=${LK_SZ}B 分区=${LK_PSZ}B"
  fi

  # 可选: 写前用 /dev/zero 清空整块分区 (P2-14, 借鉴 V-ABHelper manager.sh:256)。
  # 默认关闭 —— vivo LK 头部自带长度, 尾部残留旧数据通常不影响启动, 与 fastboot 行为
  # 一致; 清空整块在 dd 中途失败时会把原本可用的 LK 擦掉, 风险更大。仅在明确需要
  # 彻底清除尾部旧数据时设 LK_ZERO_PAD=1 开启。
  if [ "${LK_ZERO_PAD:-0}" = "1" ]; then
    log "  LK_ZERO_PAD=1: 写前用 /dev/zero 清空 $LK_DEV_NODE"
    dd if=/dev/zero of="$LK_DEV_NODE" bs=4096 2>/dev/null \
      || log "  ⚠ /dev/zero 清空失败, 继续写镜像(由 sha256 回读判定)"
  fi

  log "刷入 LK: 将用户镜像写入 $LK_DEV_NODE"
  log "  镜像: $LK_IMG"
  log "🚨🚨🚨 高危确认: ARB 防回滚熔丝不受本脚本控制 🚨🚨🚨"
  log "  刷入 anti_ver 低于设备当前熔丝值的 LK 会触发防回滚 -> 拒启动(硬砖),"
  log "  且本脚本全程检测不到。务必先确认镜像 anti_ver 不低于设备当前值再刷!"
  log "  (SPF 只能清系统侧 ro.boot.anti.avb_anti_ver, 清不掉 bootloader 自身熔丝)"
  # dd 的输出(records in/out、bytes copied)是"到底写了多少字节"的唯一直接证据,
  # 但它是裸 stdout/stderr、不经过 log(), 原先只进终端不进 ota.log —— 这里捕获后经
  # log() 输出并转成单行, 保证刷 LK 这一步在 ota.log 里也能完整还原。
  LK_DD_OUT=$(dd if="$LK_IMG" of="$LK_DEV_NODE" bs=4096 2>&1)
  LK_DD_RC=$?
  if [ "$LK_DD_RC" -ne 0 ]; then
    log "  🚨 dd 失败 (rc=$LK_DD_RC): $(printf '%s' "$LK_DD_OUT" | tr '\n' ' ')"
    die "写入 $LK_DEV_NODE 失败"
  fi
  log "  dd 输出: $(printf '%s' "$LK_DD_OUT" | tr '\n' ' ')"
  log "  已写入 LK 分区, 刷写 bootloader 有风险, 请确认镜像与机型严格匹配"

  # ---------- 回读校验 (dd 退出 0 不代表真写进去了) ----------
  # 比较"镜像 sha256" 与 "分区前 LK_SZ 字节 sha256"。不一致说明写入未落地(被写保护拦下 /
  # 分区不可写 / 静默丢弃), 此时绝不能自动重启 —— 带损坏 LK 重启即变砖, 故置
  # SWITCH_BLOCK_REBOOT=1 阻断, 让用户重刷并确认校验通过后再手动重启。
  LK_VERIFY=0
  IMG_SUM=$(sha256sum "$LK_IMG" 2>/dev/null | cut -d' ' -f1)
  if [ -n "$IMG_SUM" ] && [ -n "$LK_SZ" ]; then
    # 按 4096 整块读(避免 bs=1 的百万次 syscall), 再用 head -c 截到精确的 LK_SZ 字节
    LK_BLKS=$(( (LK_SZ + 4095) / 4096 ))
    RD_SUM=$(dd if="$LK_DEV_NODE" bs=4096 count="$LK_BLKS" 2>/dev/null \
             | head -c "$LK_SZ" 2>/dev/null | sha256sum 2>/dev/null | cut -d' ' -f1)
    if [ -n "$RD_SUM" ] && [ "$RD_SUM" = "$IMG_SUM" ]; then
      LK_VERIFY=1
      LK_DONE=1   # 2026-11-28: 写入且回读通过, 段9 才允许自动重启
      log "  ✅ 回读校验通过: 分区前 ${LK_SZ}B 与镜像 sha256 一致"
      log "  ⚠ 注意: LK 写入分区不等于刷机包已刷入 —— 是否刷入请以槽位状态判定为准"
    else
      log "  🚨 回读校验失败: 镜像 sha256=${IMG_SUM}  分区回读=${RD_SUM:-<空/读取失败>}"
      log "  🚨 LK 写入未落地(可能被写保护拦截或分区不可写), 已阻止自动重启 —— 请勿手动重启!"
      log "     请重新刷入一次 LK, 确认回读校验通过后再重启, 否则可能无法开机"
      SWITCH_BLOCK_REBOOT=1
    fi
  else
    log "  ⚠ 无法计算镜像 sha256 或缺 LK_SZ, 跳过回读校验(需 sha256sum + stat 支持)"
    LK_VERIFY=-1
  fi
  fi   # LK_SKIP != 1 (2026-11-28: 超时跳过刷 LK, 不进 dd)
fi

if [ "$5" = "1" ]; then
  # 重启模式: 先打印小结再重启(重启后终端/日志会中断, 故小结必须在 reboot 前)
  # (修订 2026-08-27: 此处原误读 $6(实际是 force 开关), 会导致勾"强制重刷"意外自动重启)
  log "──────────── 安装小结 ────────────"
  print_install_env
  if [ "$RC" = "124" ]; then
    log "⏸ 安装状态未知(等待超时), 已阻止自动重启。"
    log "   请先用『查看安装进度』确认引擎状态; 确认 UPDATED_NEED_REBOOT 后再手动重启。"
  elif [ "$SWITCH_BLOCK_REBOOT" = "1" ]; then
    log "🚨 切槽调用异常或 LK 回读校验未通过, 已阻止自动重启。请按上面提示处理后再重启。"
  elif [ "$LK_ENABLED" = "1" ] && [ "$LK_DONE" != "1" ]; then
    # 2026-11-28 重启闸: 勾了 LK 但没写入/没回读通过(脚本被打断、超时跳过、回读失败等),
    # 此时自动重启 = 新系统 + 旧 LK = 无法开机。宁可不重启, 也不能赌。
    log "🚨 本次勾选了『刷入 LK』但未确认写入成功(回读未通过或中途跳过), 已阻止自动重启。"
    log "   请确认 LK 已写入目标槽(用『查看安装进度』/日志 LK_INFO 行核对), 再手动重启;"
    log "   否则新系统配旧 bootloader 会无法开机。"
  elif [ "$SLOT_PENDING" = "1" ]; then
    # B 方案: 切槽结果未经校验 -> 不替用户按重启键
    log "⏸ 已跳过自动重启(勾了『完成后重启』也不自动执行)"
    log "   原因: 本脚本不再回读校验切槽结果, 无法确认 $TARGET_SLOT 是否已生效;"
    log "         带错槽重启会被引擎回滚清空刚写入的槽 (本次刷入白费)。"
    log "   请前往『A/B 槽位管理 → 查看当前槽位状态』:"
    log "     · 『待生效槽』已是 $TARGET_SLOT -> 回来后手动重启, 或在槽位页直接点『重启到另一卡槽』"
    log "     · 『待生效槽』仍是当前运行槽 -> 切勿重启! 请重新执行一次安装后再切槽"
  else
    log "✅ 即将重启使更新生效..."
    sleep 3
    reboot
  fi
else
  # 非重启模式: 明确告知"已应用, 重启即生效"(借鉴 Custota reboot 通知),
  # 用户不勾 reboot 时最容易困惑"刷完没反应", 这里补上收尾提示 + 小结。
  log "──────────── 安装小结 ────────────"
  print_install_env
  if [ "$RC" = "124" ]; then
    log "⚠ 安装状态未知(等待超时), 本次未切槽、未按成功处理。"
    log "   请用『查看安装进度』确认; 若日志稍后出现 UPDATED_NEED_REBOOT,"
    log "   再用『辅助 → 手动切启动槽』下发切槽, 确认待生效槽后再重启。"
  elif [ "$INSTALL_WRITTEN" != "1" ]; then
    log "⚠ 本次写入未确认成功(RC=$RC), 请先按上方提示处理, 不要直接重启。"
  elif [ "$LK_ENABLED" = "1" ] && [ "$LK_DONE" != "1" ]; then
    # 2026-11-28: 即便不勾自动重启, 也不能给出"重启即可生效"的误导 ——
    # 勾了 LK 却没确认写入, 手动重启就是"新系统 + 旧 LK"变砖。
    log "🚨 本次勾选了『刷入 LK』但未确认写入成功, 请勿重启!"
    log "   先用『查看安装进度』/日志 LK_INFO 确认 LK 已写入目标槽, 再手动重启。"
  elif [ "$SLOT_PENDING" = "1" ]; then
    log "⚠ 包已写入 $TARGET_SLOT, 但切槽结果未经校验。"
    log "   重启前请先到『A/B 槽位管理 → 查看当前槽位状态』确认『待生效槽』已是 $TARGET_SLOT;"
    log "   否则重启会被引擎回滚清空(本次刷入白费)。"
  else
    log "✅ 包已写入目标槽 $TARGET_SLOT, 重启设备即可生效(非 A/B, 无槽位概念)。"
  fi
  log "  若需放弃本次更新改刷其他包, 重启后状态机仍处待生效态, 可 FORCE=1 强制清状态重刷。"
fi
# 收尾引导: 告知中途控制(取消/暂停/恢复)入口所在, 因 kr-script 架构下这些是与安装
# 并行的独立动作(向 update_engine daemon 发信号), 不在本安装页内嵌按钮, 需到『辅助』组操作。
log "──────────── 中途控制提示 ────────────"
log "  安装进行中如需【取消/暂停/恢复】, 请到本页『辅助』分组点击对应按钮:"
log "    · 取消当前安装  · 暂停当前安装  · 恢复当前安装"
log "    (亦可『查看安装进度』实时跟随, 或『本次安装小结查看』回看本小结)"
log "DONE"
