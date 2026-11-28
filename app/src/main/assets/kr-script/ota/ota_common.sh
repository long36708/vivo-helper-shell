#!/system/bin/sh
# ============================================================================
# ota_common.sh —— OTA 系列脚本共用工具 (被 source, 不单独执行)
#
# 为什么单独一份: PATH / 颜色 / 日志着色 / 日志过滤 / Boot Control HAL 探测这些
# 函数原先在 vivo_ota.sh、vivo_ota_status.sh、vivo_ota_ctrl.sh、vivo_ota_cancel.sh
# 里各复制了一份, 修一个 bug 要改 4 处。36cd919「服务名取错列」就是因为漏改一处
# 而复发过一次 (AGENTS.md 已记录)。收拢到这里后只需改一处。
#
# 用法(必须放在调用脚本最前部, 且此时 $0 仍指向脚本自身):
#   OTA_SELF_DIR=$(cd "$(dirname "$0")" 2>/dev/null && pwd)
#   . "$OTA_SELF_DIR/ota_common.sh"
#
# 约定:
#   - 本文件不 cd /、不设 trap、不启动后台进程, 只定义变量与函数。
#   - 颜色码在本文件里用 printf 生成; 调用方不要再用 '\033' 字面量。
#   - 终端着色在 app 内由 ShellHandlerBase 解析 ANSI 转 Span 实现;
#     镜像文件 /sdcard/ota.log 始终写纯文本(无转义), 便于 cat 回看。
# ============================================================================

# ---------- 环境 ----------
# kr-script 通过 su -c 拉起脚本时环境可能不含标准路径, 导致 grep/unzip/stat/awk
# 找不到, HEADERS 为空 -> update_engine 直接返回 IDLE (刷不进去)。这里兜底导出。
export PATH="/system/bin:/system/xbin:/sbin:/vendor/bin:/odm/bin:/data/adb/ksu/bin:/data/adb/magisk/bin:$PATH"

# update_engine 的落盘日志 (vivo 的引擎进度不回显终端, 只写这两个目录)
UE_LOG_DIR=/logdata/recovery/update_engine_log
UE_ERR_DIR=/logdata/recovery/update_engine_log_err

# 全程日志镜像 (追加, 纯文本)
UE_MIRROR=/sdcard/ota.log
UE_LOG_WRITABLE=0
{ [ -w /sdcard ] || mountpoint -q /sdcard 2>/dev/null; } && UE_LOG_WRITABLE=1

# 安装单例锁路径 (2026-11-27 P2-10: vivo_ota.sh / vivo_ota_cancel.sh 各定义一份, 收拢至此)。
# 注意: status.sh 的 vivo_ota_status.pid 是"进度监听"单例锁, 与安装锁无关, 保持独立。
INSTALL_LOCK_DIR=/data/local/tmp/vivo_ota_install.lock
INSTALL_LOCK_PID="$INSTALL_LOCK_DIR/pid"

# ---------- 颜色 ----------
C_RED=$(printf '\033[31m'); C_GRN=$(printf '\033[32m'); C_YEL=$(printf '\033[33m')
C_BLU=$(printf '\033[34m'); C_CYN=$(printf '\033[36m'); C_RST=$(printf '\033[0m')

# ---------- 着色 / 日志 ----------
# 单行着色: 进度行优先(青色), 其余按关键字 (大小写不敏感)
#   error/fail/失败/错误 -> 红; success/done/成功/完成 -> 绿; warn/⚠/警告 -> 黄
# ⚠ 顺序即优先级: 先命中即返回。写警告文案时要避开"成功/完成"等词, 否则会被染绿。
paint_line() {
  local line="$1"
  local lc
  lc=$(printf '%s' "$line" | tr 'A-Z' 'a-z')
  case "$lc" in
    *"overall progress"*|*"completed "*"operations"*)
      printf '%s%s%s\n' "$C_CYN" "$line" "$C_RST" ;;
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

# 引擎日志只转发关键行 (一次全量包能刷出上千行底层细节, 全量转发会淹没进度/错误,
# 并把 /sdcard/ota.log 灌爆)。关键行判定 (大小写不敏感):
#   进度: overall progress / Completed x/y operations
#   状态: update status / ActionProcessor / Downloading / Verifying / Applying / Finalizing
#   终态: UPDATED_NEED_REBOOT / successfully applied / SendPayloadApplicationComplete
#   错误: error / fail / 失败 / 错误 / fatal / denied / abort / kErrorCode
#   其它: suspending / resuming / payload.bin / payload_metadata / additional payloads
# 注意: 不要用裸 "payload" / "bytes" / "action" 做关键词 —— update_engine 的日志
#       模块名就叫 payload_consumer / payload_verifier / delta_performer, 几乎每行
#       都含 payload, 用裸词等于不过滤。
is_key_line() {
  local lc
  lc=$(printf '%s' "$1" | tr 'A-Z' 'a-z')
  case "$lc" in
    *"overall progress"*|*"completed "*"operations"*|\
    *"update status"*|*"updatestatus"*|*"actionprocessor"*|\
    *"downloading"*|*"verifying"*|*"applying"*|*"finalizing"*|*"postinstall"*|\
    *"updated_need_reboot"*|*"successfully applied"*|*"sendpayloadapplicationcomplete"*|\
    *"update successfully"*|*"boot completed"*|*"waiting on markbootsuccessful"*|\
    *"error"*|*"fail"*|*"失败"*|*"错误"*|*"fatal"*|*"denied"*|*"abort"*|*"kerrorcode"*|\
    *"suspending"*|*"resuming"*|\
    *"payload.bin"*|*"payload_metadata"*|*"additional payloads"*|*"payloadverificationerror"*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# 关键行流: 仅命中 is_key_line 的行才着色 + 镜像, 其余丢弃。
filter_stream() {
  while IFS= read -r line; do
    if is_key_line "$line"; then
      paint_line "$line"
      [ "$UE_LOG_WRITABLE" = "1" ] && printf '%s\n' "$line" >> "$UE_MIRROR"
    fi
  done
}

# log: 终端着色输出 + 纯文本写入镜像文件
# OTA_LOG_TAG 可被调用方覆盖 (status.sh 等只读命令用不同前缀)
OTA_LOG_TAG="${OTA_LOG_TAG:-[vivo_ota]}"
log() { paint_line "$OTA_LOG_TAG $*"; [ "$UE_LOG_WRITABLE" = "1" ] && echo "$OTA_LOG_TAG $*" >> "$UE_MIRROR"; }
die() { printf '%s%s%s\n' "$C_RED" "FAILED: $*" "$C_RST"; [ "$UE_LOG_WRITABLE" = "1" ] && echo "FAILED: $*" >> "$UE_MIRROR"; exit 1; }

# 普通提示 (不带 OTA_LOG_TAG): 终端着色 + 纯文本镜像。原先 status.sh 与 ctrl.sh
# 各定义一份 (前者 paint+镜像, 后者裸 printf %b), 2026-11-27 P2 收拢到此。
put() { paint_line "$*"; [ "$UE_LOG_WRITABLE" = "1" ] && printf '%s\n' "$*" >> "$UE_MIRROR"; }

# ---------- 日志判定工具 (P2-10/P2-12 从 status.sh / ctrl.sh 收拢) ----------
# 取正则 $1 在文件 $2 中"最后一次命中"的行号 (无命中则输出空)
last_hit_line() { grep -anE "$1" "$2" 2>/dev/null | tail -1 | cut -d: -f1; }
# 文件行数 (取不到返回 0)
log_lines() { [ -n "$1" ] && [ -f "$1" ] || { echo 0; return; }; wc -l < "$1" 2>/dev/null || echo 0; }
# 纯无符号整数判定 (P2-11): 时间戳/补丁级别比较前必须先过这道闸, 避免 [ -lt ] 比较
# 空串或非数字时的不确定行为 (toybox test 对非数字参数并非总是稳定返回假)。
is_uint() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; return 0; }
# 读取文件偏移 $2 起 $3 字节, 输出空格分隔的十进制字节 (P2-11): 优先 od -j/-N 批量读,
# 老 toybox 不支持时回退 dd bs=1。原先 le2/le4 与 80 字节回扫都用 dd bs=1 逐字节。
od_bytes() {
  local f="$1" o="$2" n="$3" out
  out=$(od -A n -t u1 -j "$o" -N "$n" "$f" 2>/dev/null | tr -s ' ')
  [ -z "$out" ] && out=$(dd if="$f" bs=1 skip="$o" count="$n" 2>/dev/null | od -A n -t u1 | tr -s ' ')
  printf '%s\n' "$out"
}

# 引擎状态正则。由"最后出现的标记"判定当前态, 不依赖顺序; 不收裸 processing
# (失败行 "Aborting processing due to failure" 会命中, 把失败空档误报成安装中)。
UE_STATE_PAT='UPDATED_NEED_REBOOT|UPDATE_STATUS_IDLE|suspending|resuming|Downloading|Applying|Verifying|Finalizing|postinstall|ActionProcessor|overall progress|Completed .* operations'
UE_PAT_CLEANUP='Boot completed, waiting on markBootSuccessful'

# 统一的引擎状态判定 (P2-12): 输出到全局 UE_STATE / UE_STATE_RAW。
# 状态取值: IDLE / UPDATING / NEED_REBOOT / SUSPENDED / CLEANUP / STOPPED / UNKNOWN。
# 原先 status.sh 有 detect_engine_state、ctrl.sh 有 ue_is_active 两套判定, 语义重复
# 且阈值各异; 现统一到此, ctrl 的"是否进行中"也改由 UE_STATE 派生。
detect_engine_state() {
  local svc L P_CL P_LAST TL LAST_MARK P_SUSP P_RESU
  UE_STATE=UNKNOWN
  UE_STATE_RAW=""
  svc=$(getprop init.svc.update_engine 2>/dev/null)
  if ! pgrep -x update_engine >/dev/null 2>&1 && [ "$svc" != "running" ]; then
    UE_STATE=STOPPED
    return 0
  fi
  # update_engine_client 无 --status flag (真机实测 unknown command line flag),
  # 状态只能从落盘日志关键字判定。
  L=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | head -1)
  if [ -n "$L" ]; then
    UE_STATE_RAW=$(tail -40 "$L" 2>/dev/null)
    # 看"最后出现的标记"而非"整文件命中即返回", 避免历史会话终态误报空闲/待重启/暂停。
    P_CL=$(last_hit_line "$UE_PAT_CLEANUP" "$L")
    P_LAST=$(last_hit_line "$UE_STATE_PAT" "$L")
    TL=$(log_lines "$L")
    # 卡死态: cleanup 等待行停在尾部 40 行窗口内且其后无更晚标记 -> 恒忙, 新安装会被 741 拒。
    if [ -n "$P_CL" ] && [ "$TL" -gt 0 ] 2>/dev/null \
       && [ "$((TL - P_CL))" -lt 40 ] 2>/dev/null \
       && { [ -z "$P_LAST" ] || [ "$P_CL" -gt "$P_LAST" ] 2>/dev/null; }; then
      UE_STATE=CLEANUP
    else
      LAST_MARK=$(grep -anE "$UE_STATE_PAT" "$L" 2>/dev/null | tail -1)
      if [ -z "$LAST_MARK" ]; then
        UE_STATE=UNKNOWN
      else
        case "$LAST_MARK" in
          *UPDATED_NEED_REBOOT*) UE_STATE=NEED_REBOOT ;;
          *UPDATE_STATUS_IDLE*)  UE_STATE=IDLE ;;
          *)
            # 暂停态单独判: 仅当最后一次 suspending 晚于最后一次 resuming 才算仍在暂停。
            P_SUSP=$(last_hit_line 'suspending' "$L")
            P_RESU=$(last_hit_line 'resuming' "$L")
            if [ -n "$P_SUSP" ] && { [ -z "$P_RESU" ] || [ "$P_SUSP" -gt "$P_RESU" ] 2>/dev/null; }; then
              UE_STATE=SUSPENDED
            else
              UE_STATE=UPDATING
            fi
            ;;
        esac
      fi
    fi
  fi
  # 进程在跑但日志无明确态 -> 仍归为 UPDATING (保守)
  [ "$UE_STATE" = "UNKNOWN" ] && UE_STATE=UPDATING
  return 0
}

# ---------- Boot Control HAL 探测 ----------
# 探测 AIDL 服务名。**必须取「名字」列, 不能取序号列**:
#   service list 的行格式是  "<序号>\t<服务名>: [<接口名>]"
#   曾用 `awk '{print $1}'` 取到 "29" 这种序号 -> service call 报服务不存在 ->
#   ① setActiveBootSlot 静默无效 ② getActiveBootSlot 回读恒空 ③ markBootSuccessful
#   从未下发 ④ merge 状态查询失败被兜底成"干净"。详见 AGENTS.md OTA 节。
#
# 服务行不存在(非 A/B 设备)时输出空, 让调用方走"跳过切槽"分支; 不能无条件兜底成
# 标准服务名 —— 那会把"设备不支持"变成"service call 服务不存在", 同样被误读成
# "HAL 拒绝切槽"。
#
# OTA_HAL_STRICT=1 时"行在但格式没认出"也不兜底 (cancel.sh 需要: 探测不到就如实
# 报未找到, 不拿猜出来的名字去 call)。
boot_hal_svc() {
  local line s
  line=$(service list 2>/dev/null | grep -i 'IBootControl' | head -n1)
  [ -n "$line" ] || return 0
  s=$(printf '%s\n' "$line" | grep -oE '[A-Za-z0-9_.]+/[A-Za-z0-9_.]+' | head -n1)
  case "$s" in
    *[!0-9]*) ;;          # 含非数字字符才算服务名
    *) s="" ;;            # 纯数字 -> 又抓成序号了, 丢弃
  esac
  # 行在但格式没认出: 退回与 swab.sh 写死的真机实测名一致的兜底值
  if [ -z "$s" ] && [ "$OTA_HAL_STRICT" != "1" ]; then
    s=android.hardware.boot.IBootControl/default
  fi
  printf '%s\n' "$s"
}
