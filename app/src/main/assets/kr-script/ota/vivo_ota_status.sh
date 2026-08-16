#!/system/bin/sh
# ============================================================================
# vivo_ota_status.sh —— 查看 update_engine 当前安装进度
#
# vivo 的 update_engine 是后台 daemon, 进度写进落盘文件而非 logcat, 故优先读
# /logdata/recovery/update_engine_log/update_engine.*, 拿不到时回退 logcat 快照。
#
# 用法:
#   无参数          -> 实时跟随最新日志 (自动跟随引擎轮转出的新文件, 只显示新增内容)
#   status          -> 一次性状态快照 (不常驻), 打印引擎状态 + 最近进度后立即退出
#   stop            -> 停止本机上所有正在运行的监听实例
#   list            -> 列出所有历史日志文件 (含大小/时间), 方便取消后回看旧进度
#   <编号或文件名>  -> 查看指定的某一份日志 (cat 全部内容)
#
# 相对旧版的修复:
#   P1 断流: 旧版 `tail -F "$DIR"/update_engine.*` 会被 shell 在启动瞬间展开成固定
#            文件列表, tail 只跟这些文件; 引擎在新安装时会重启 daemon 并新建
#            update_engine.<新时间戳>.<n>, 新文件不在列表里 -> 永远不被跟随, 界面
#            打印一句"已切换到最新日志"后就静止。现改为"记录读取偏移 + 轮询增量读",
#            文件轮转 / 被截断都能正确跟随, 先开监听再开始安装也不会断流。
#   P2 多开: 加单例锁, 重复点击"查看安装进度"不再堆积永不退出的常驻进程;
#            并提供 stop 子命令主动结束 (app 环境按不了 Ctrl+C)。
#   P3 回放: 默认只显示最新一份日志的尾部 + 引擎状态, 不再把 11 份历史日志
#            (含上次失败的红字) 全量回放, 避免误判本次安装失败; 引擎空闲时明确提示。
#   P4 进度: 提取 "overall progress" / "Completed x/y operations" 百分比高亮显示,
#            并同时跟随 update_engine_log_err/ 失败详情目录。
# ============================================================================
cd /
export PATH="/system/bin:/system/xbin:/sbin:/vendor/bin:/odm/bin:/data/adb/ksu/bin:/data/adb/magisk/bin:$PATH"

UE_LOG_DIR=/logdata/recovery/update_engine_log
UE_ERR_DIR=/logdata/recovery/update_engine_log_err
CLIENT=/system/bin/update_engine_client
ARG="$1"

# 默认模式启动时回显最新日志的尾部行数 (P3: 不再全量回放历史)
TAIL_LINES="${OTA_TAIL_LINES:-40}"
# 轮询间隔 (秒)
POLL_SEC="${OTA_POLL_SEC:-2}"
# 单例锁 / pid 文件
LOCK_PID_FILE=/data/local/tmp/vivo_ota_status.pid

# 全程日志镜像到 /sdcard/ota.log (追加, 纯文本); 终端显示带 ANSI 颜色。
UE_MIRROR=/sdcard/ota.log
UE_LOG_WRITABLE=0
{ [ -w /sdcard ] || mountpoint -q /sdcard 2>/dev/null; } && UE_LOG_WRITABLE=1

# ANSI 颜色码
C_RED=$(printf '\033[31m'); C_GRN=$(printf '\033[32m'); C_YEL=$(printf '\033[33m')
C_BLU=$(printf '\033[34m'); C_CYN=$(printf '\033[36m'); C_RST=$(printf '\033[0m')

# 单行着色: 进度行优先(青色高亮), 其余按关键字判断 (大小写不敏感)
paint_line() {
  line="$1"
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

# 实时流着色 + 文件无颜色镜像
color_stream() {
  while IFS= read -r line; do
    paint_line "$line"
    [ "$UE_LOG_WRITABLE" = "1" ] && printf '%s\n' "$line" >> "$UE_MIRROR"
  done
}

# 普通提示: 终端着色 + 纯文本写文件
put() { paint_line "$*"; [ "$UE_LOG_WRITABLE" = "1" ] && echo "$*" >> "$UE_MIRROR"; }

# ---------------------------------------------------------------------------
# stop 子命令: 结束所有常驻监听实例 (含本次之前遗留的)
# ---------------------------------------------------------------------------
if [ "$ARG" = "stop" ]; then
  SELF=$$
  KILLED=0
  # 优先按 pid 文件精确杀
  if [ -f "$LOCK_PID_FILE" ]; then
    OLD=$(cat "$LOCK_PID_FILE" 2>/dev/null)
    if [ -n "$OLD" ] && [ "$OLD" != "$SELF" ] && kill -0 "$OLD" 2>/dev/null; then
      kill -9 "$OLD" 2>/dev/null && KILLED=$((KILLED+1))
    fi
    rm -f "$LOCK_PID_FILE" 2>/dev/null
  fi
  # 兜底: 按命令行特征杀掉残留 (排除自身及自身父进程)
  for p in $(pgrep -f 'vivo_ota_status.sh' 2>/dev/null); do
    [ "$p" = "$SELF" ] && continue
    [ "$p" = "$PPID" ] && continue
    kill -9 "$p" 2>/dev/null && KILLED=$((KILLED+1))
  done
  # 杀掉可能残留的 tail 子进程
  pkill -9 -f "tail -F $UE_LOG_DIR" 2>/dev/null
  put "已停止 $KILLED 个监听实例。"
  exit 0
fi

# 注: "本次日志开始"标记仅在实时监听(无参数)模式下写入, 避免 summary/list/status
#     等只读子命令污染 /sdcard/ota.log, 影响小结提取。
if [ -z "$ARG" ] && [ "$UE_LOG_WRITABLE" = "1" ]; then
  echo "[vivo_ota_status] $(date '+%F %T') 本次日志开始 (同时写入 $UE_MIRROR)" >> "$UE_MIRROR"
  printf '%s%s%s\n' "$C_BLU" "[vivo_ota_status] $(date '+%F %T') 本次日志开始 (终端带颜色, 文件纯文本: $UE_MIRROR)" "$C_RST"
fi

# ---------------------------------------------------------------------------
# 引擎状态判定: 综合 init.svc / 进程 / update_engine_client --status
#   输出到全局: UE_STATE (IDLE / UPDATING / NEED_REBOOT / STOPPED / UNKNOWN)
#              UE_STATE_RAW (client 原始输出)
# ---------------------------------------------------------------------------
detect_engine_state() {
  UE_STATE=UNKNOWN
  UE_STATE_RAW=""
  SVC=$(getprop init.svc.update_engine 2>/dev/null)
  if ! pgrep -x update_engine >/dev/null 2>&1 && [ "$SVC" != "running" ]; then
    UE_STATE=STOPPED
    return 0
  fi
  # 注意: update_engine_client 没有 --status flag (真机实测报 unknown command line flag),
  #       状态只能从落盘日志 (/logdata/recovery/update_engine_log) 关键字判定。
  L=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | head -1)
  if [ -n "$L" ]; then
    UE_STATE_RAW=$(tail -40 "$L" 2>/dev/null)
    # 终态优先
    if grep -q 'UPDATED_NEED_REBOOT' "$L" 2>/dev/null; then
      UE_STATE=NEED_REBOOT
    elif grep -qE 'UPDATE_STATUS_IDLE|Boot completed, waiting on markBootSuccessful' "$L" 2>/dev/null; then
      UE_STATE=IDLE
    elif grep -qE 'Downloading|Verifying|Finalizing|suspending|resuming|ActionProcessor|processing' "$L" 2>/dev/null; then
      UE_STATE=UPDATING
    fi
  fi
  # 进程在跑但日志无明确态 -> 仍归为 UPDATING(保守)
  [ "$UE_STATE" = "UNKNOWN" ] && UE_STATE=UPDATING
  return 0
}

# 从最新日志里提取整体进度百分比 (引擎日志常见 "overall progress X%" / "progress Y")
print_client_progress() {
  L=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | head -1)
  [ -n "$L" ] || return 0
  prog=$(grep -aoE 'overall progress[^0-9]*[0-9]+(\.[0-9]+)?%|progress[^0-9]*[0-9]+(\.[0-9]+)?%' "$L" 2>/dev/null | tail -1 | grep -aoE '[0-9]+(\.[0-9]+)?' | head -1)
  [ -n "$prog" ] && put "  当前进度: ${prog}%"
}

show_engine_state() {
  detect_engine_state
  put "==== update_engine 状态 ===="
  case "$UE_STATE" in
    STOPPED)     put "  引擎未运行 (当前无进行中的更新)" ;;
    IDLE)        put "  引擎空闲 IDLE (当前无进行中的更新)" ;;
    UPDATING)    put "  正在安装中 ..." ; print_client_progress ;;
    NEED_REBOOT) put "  已安装完成, 等待重启生效 (UPDATED_NEED_REBOOT)" ;;
    *)           put "  状态未知 (引擎在运行, 但 --status 查询失败)" ;;
  esac
  [ -n "$UE_STATE_RAW" ] && printf '%s\n' "$UE_STATE_RAW" | color_stream
}

# ---------------------------------------------------------------------------
# 日志文件工具
# ---------------------------------------------------------------------------
latest_log() { ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | head -1; }
latest_err()  { ls -t "$UE_ERR_DIR"/* 2>/dev/null | head -1; }

# 文件大小 (字节), 取不到返回 0
fsize() { stat -c %s "$1" 2>/dev/null || echo 0; }

# 列出所有日志文件(按 mtime 新->旧), 编号便于指定查看
# 注意: 用 for 而非 `ls | while`, 避免管道子 shell 导致计数器 i 丢失
list_logs() {
  i=1
  put "历史日志文件 (新->旧, 编号可传给本脚本查看):"
  for f in $(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null); do
    put "  [$i] $f  ($(fsize "$f") 字节)"
    i=$((i+1))
  done
  [ "$i" = "1" ] && put "  (无历史日志)"
}

# ---------------------------------------------------------------------------
# 无日志目录 -> 回退 logcat 快照
# ---------------------------------------------------------------------------
if [ ! -d "$UE_LOG_DIR" ]; then
  show_engine_state
  put ""
  put "==== 未找到 $UE_LOG_DIR, 回退 logcat 快照 ===="
  logcat -d -s update_engine:v 2>/dev/null | tail -n 30 | color_stream \
    || put "(logcat 无 update_engine 日志)"
  exit 0
fi

# ---------------------------------------------------------------------------
# list 子命令: 仅列出, 不监听
# ---------------------------------------------------------------------------
if [ "$ARG" = "list" ]; then
  put "==== 全部历史日志 ===="
  list_logs
  if [ -d "$UE_ERR_DIR" ]; then
    put ""
    put "失败详情归档 ($UE_ERR_DIR):"
    for f in $(ls -t "$UE_ERR_DIR"/* 2>/dev/null); do
      put "  $f  ($(fsize "$f") 字节)"
    done
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
# err 子命令: 查看最近一次安装失败的详情归档 (update_engine_log_err/ 下的文件)
#   vivo 安装失败时会把错误上下文 dump 到此目录, 直接 cat 最新一份省去手动翻目录。
#   (借鉴 Custota 失败细节写 update_engine_log_err + 结构化的错误诊断思路)
# ---------------------------------------------------------------------------
if [ "$ARG" = "err" ]; then
  if [ ! -d "$UE_ERR_DIR" ]; then
    put "未找到失败归档目录 $UE_ERR_DIR (本次可能未失败, 或日志目录结构不同)。"
    show_engine_state
    exit 0
  fi
  ERRF=$(latest_err)
  if [ -z "$ERRF" ]; then
    put "✅ $UE_ERR_DIR 下暂无失败归档 (最近一次安装未写出错误详情)。"
    show_engine_state
    exit 0
  fi
  printf '%s%s%s\n' "$C_BLU" "==== 最近失败归档: $ERRF ====" "$C_RST"
  put "  (大小: $(fsize "$ERRF") 字节)"
  color_stream < "$ERRF"
  put ""
  put "(如需查看全部归档: sh \$0 list  然后 cat 指定文件)"
  exit 0
fi

# ---------------------------------------------------------------------------
# summary 子命令: 查看"本次安装小结" (vivo_ota.sh 段9 写入 /sdcard/ota.log 的区块)
#   从镜像日志里倒序找最近一段 "──── 安装小结 ────" .. "DONE" 之间的内容打印。
#   找不到时回退提示引擎当前状态。 (借鉴 Custota 安装后结构化结果展示思路)
# ---------------------------------------------------------------------------
if [ "$ARG" = "summary" ]; then
  MIRROR=/sdcard/ota.log
  if [ ! -f "$MIRROR" ]; then
    put "未找到 $MIRROR (尚未进行过任何安装)。"
    show_engine_state
    exit 0
  fi
  # 定位最近一份小结: 保留最后一段 "──── 安装小结 ────" .. "DONE" 之间的内容
  # (不依赖 tac/tail -r, toybox 可能无这两者; 用 awk 记录每段, 取最后一段)
  SUMMARY=$(awk '
    /──── 安装小结 ────/ { buf=""; inblk=1 }
    inblk { buf = buf $0 "\n"; if (/^DONE$/) { lastbuf=buf; inblk=0 } }
    END { printf "%s", lastbuf }
  ' "$MIRROR" 2>/dev/null)
  if [ -z "$SUMMARY" ]; then
    put "未在 $MIRROR 找到安装小结 (可能尚未完成一次安装)。"
    put "最近日志尾部:"
    tail -n 15 "$MIRROR" 2>/dev/null | color_stream
    exit 0
  fi
  printf '%s%s%s\n' "$C_BLU" "==== 最近一次安装小结 ====" "$C_RST"
  printf '%s\n' "$SUMMARY" | color_stream
  printf '%s%s%s\n' "$C_BLU" "==========================" "$C_RST"
  put "(完整日志见 $MIRROR)"
  exit 0
fi

# ---------------------------------------------------------------------------
# status 子命令: 一次性快照, 不常驻 (P2/P3 推荐入口)
# ---------------------------------------------------------------------------
if [ "$ARG" = "status" ]; then
  show_engine_state
  put ""
  CUR=$(latest_log)
  if [ -n "$CUR" ]; then
    put "==== 最新日志尾部: $CUR ===="
    tail -n "$TAIL_LINES" "$CUR" 2>/dev/null | color_stream
    put ""
    LASTP=$(grep -a 'overall progress' "$CUR" 2>/dev/null | tail -1)
    [ -n "$LASTP" ] && put "最近一条进度: $LASTP"
  else
    put "(日志目录为空)"
  fi
  ERRF=$(latest_err)
  [ -n "$ERRF" ] && { put ""; put "⚠ 存在失败归档 (最近一份): $ERRF"; }
  exit 0
fi

# ---------------------------------------------------------------------------
# 指定某份日志查看 (编号或完整/部分文件名)
# ---------------------------------------------------------------------------
if [ -n "$ARG" ]; then
  target=""
  case "$ARG" in
    [0-9]*)
      target=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | sed -n "${ARG}p") ;;
    *)
      target=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | grep -m1 "$ARG") ;;
  esac
  if [ -n "$target" ] && [ -f "$target" ]; then
    put "==== 查看指定日志: $target ===="
    color_stream < "$target"
  else
    put "未找到匹配的日志: $ARG"
    put "可运行: $0 list  查看全部历史日志"
  fi
  exit 0
fi

# ===========================================================================
# 默认模式: 实时跟随最新日志
# ===========================================================================

# ---- P2: 单例锁, 避免重复点击堆积常驻进程 ----
if [ -f "$LOCK_PID_FILE" ]; then
  OLD=$(cat "$LOCK_PID_FILE" 2>/dev/null)
  if [ -n "$OLD" ] && [ "$OLD" != "$$" ] && kill -0 "$OLD" 2>/dev/null; then
    put "⚠ 已有监听实例在运行 (pid=$OLD), 本次不再重复启动。"
    put "   如需重开: 先运行  sh \$0 stop  停止旧实例; 或用  sh \$0 status  看一次性快照。"
    exit 0
  fi
  rm -f "$LOCK_PID_FILE" 2>/dev/null
fi
echo "$$" > "$LOCK_PID_FILE" 2>/dev/null

# 退出时清理锁 (脚本被 kill -9 时无法触发, 故上面的 kill -0 存活检测是主要保障)
trap 'rm -f "$LOCK_PID_FILE" 2>/dev/null; exit 0' INT TERM HUP

show_engine_state
put ""
put "==== update_engine 实时进度 (自动跟随日志轮转) ===="
put "   停止监听请运行: sh \$0 stop ; 回看旧进度: sh \$0 list / sh \$0 <编号>"
put ""

# ---- P1 核心修复: 偏移跟随, 而非 tail -F 通配符 ----
# CUR      : 当前正在跟随的日志文件
# OFFSET   : 已读取到的字节偏移 (下次从这里继续读增量)
CUR=$(latest_log)
OFFSET=0

if [ -n "$CUR" ]; then
  put "---- 当前日志: $CUR (先显示最近 $TAIL_LINES 行) ----"
  tail -n "$TAIL_LINES" "$CUR" 2>/dev/null | color_stream
  OFFSET=$(fsize "$CUR")
else
  put "(暂无日志文件, 等待引擎创建 ...)"
fi

# 读取文件从 OFFSET 起的增量内容, 避免重复输出。
# 实现说明: dd bs=1 是逐字节 read(), 安装高峰期引擎一次能写几十 KB, 逐字节读会
# 拖慢显示甚至跟不上写入速度。故优先用 `tail -c +N` (toybox 支持, N 为 1-based
# 字节起点) 一次性取增量; 不可用时再回退 dd bs=1。
TAIL_C_OK=0
if printf 'ab' | tail -c +2 2>/dev/null | grep -q 'b' 2>/dev/null; then
  TAIL_C_OK=1
fi
read_increment() {
  f="$1"; from="$2"; to="$3"
  cnt=$((to - from))
  [ "$cnt" -gt 0 ] 2>/dev/null || return 0
  if [ "$TAIL_C_OK" = "1" ]; then
    tail -c +$((from + 1)) "$f" 2>/dev/null | color_stream
  else
    dd if="$f" bs=1 skip="$from" count="$cnt" 2>/dev/null | color_stream
  fi
}

# 失败归档目录的已知文件集合 (用于发现新归档时提醒)
ERR_SEEN=""
[ -d "$UE_ERR_DIR" ] && ERR_SEEN=$(ls "$UE_ERR_DIR" 2>/dev/null | tr '\n' ' ')

# 上一次打印过的引擎状态, 变化时才提示, 避免刷屏
LAST_STATE=""

while true; do
  NEW=$(latest_log)

  # (a) 引擎轮转出新文件 -> 切换跟随目标, 偏移归零 (旧版这里会断流)
  if [ -n "$NEW" ] && [ "$NEW" != "$CUR" ]; then
    # 先把旧文件的剩余尾巴读完, 不丢日志
    if [ -n "$CUR" ] && [ -f "$CUR" ]; then
      END=$(fsize "$CUR")
      read_increment "$CUR" "$OFFSET" "$END"
    fi
    CUR="$NEW"
    OFFSET=0
    put ""
    put "---- 引擎已轮转日志, 切换跟随: $CUR ----"
  fi

  # (b) 读取当前文件的新增内容
  if [ -n "$CUR" ] && [ -f "$CUR" ]; then
    SIZE=$(fsize "$CUR")
    if [ "$SIZE" -lt "$OFFSET" ] 2>/dev/null; then
      # 文件被截断 (引擎重开同名文件), 从头再读
      put "---- 日志被截断, 重新从头跟随 ----"
      OFFSET=0
    fi
    read_increment "$CUR" "$OFFSET" "$SIZE"
    OFFSET="$SIZE"
  fi

  # (c) 引擎状态变化时提示 (P3: 空闲/完成也有明确反馈, 不再静默)
  detect_engine_state
  if [ "$UE_STATE" != "$LAST_STATE" ]; then
    case "$UE_STATE" in
      UPDATING)    put "[状态] 正在安装中 ..." ; print_client_progress ;;
      NEED_REBOOT) put "[状态] 安装完成, 等待重启生效 (UPDATED_NEED_REBOOT)" ;;
      IDLE)        put "[状态] 引擎空闲 (当前无进行中的更新)" ;;
      STOPPED)     put "[状态] 引擎未运行" ;;
    esac
    LAST_STATE="$UE_STATE"
  fi

  # (d) P4: 跟随失败归档目录, 出现新归档立即提醒
  if [ -d "$UE_ERR_DIR" ]; then
    for f in $(ls "$UE_ERR_DIR" 2>/dev/null); do
      case " $ERR_SEEN " in
        *" $f "*) ;;
        *)
          put ""
          put "⚠ 引擎写出新的失败归档: $UE_ERR_DIR/$f (安装很可能已失败)"
          ERR_SEEN="$ERR_SEEN $f"
          ;;
      esac
    done
  fi

  sleep "$POLL_SEC"
done
