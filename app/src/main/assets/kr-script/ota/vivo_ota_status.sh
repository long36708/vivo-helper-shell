#!/system/bin/sh
# 查看 update_engine 当前安装进度
# vivo 的 update_engine 是后台 daemon, 进度写进落盘文件而非 logcat, 故优先 tail -F 该文件,
# 拿不到时再回退到 logcat 快照 (对齐 GT 玩机助手 cat.sh: logcat -s update_engine:v)。
# 用法:
#   无参数          -> 实时监听最新的日志文件 (Ctrl+C 退出)
#   list            -> 列出所有历史日志文件 (含大小/时间), 方便取消后回看旧进度
#   <编号或文件名>  -> 查看指定的某一份日志 (cat 全部内容)
cd /
export PATH="/system/bin:/system/xbin:/sbin:/vendor/bin:/odm/bin:/data/adb/ksu/bin:/data/adb/magisk/bin:$PATH"

UE_LOG_DIR=/logdata/recovery/update_engine_log
ARG="$1"

# 全程日志镜像到 /sdcard/ota.log (追加, 纯文本); 终端显示带 ANSI 颜色(成功绿/失败红/警告黄)。
# Android 的 /system/bin/sh 多为 mksh/ash, 用函数级双写, 不依赖 bash 进程替换。
UE_MIRROR=/sdcard/ota.log
UE_LOG_WRITABLE=0
{ [ -w /sdcard ] || mountpoint -q /sdcard 2>/dev/null; } && UE_LOG_WRITABLE=1

# ANSI 颜色码
C_RED=$(printf '\033[31m'); C_GRN=$(printf '\033[32m'); C_YEL=$(printf '\033[33m')
C_BLU=$(printf '\033[34m'); C_RST=$(printf '\033[0m')

# 单行着色: 根据关键字判断颜色 (大小写不敏感)
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

# 实时流着色 + 文件无颜色镜像
color_stream() {
  while IFS= read -r line; do
    paint_line "$line"
    [ "$UE_LOG_WRITABLE" = "1" ] && printf '%s\n' "$line" >> "$UE_MIRROR"
  done
}

# 普通提示: 终端着色 + 纯文本写文件
put() { paint_line "$*"; [ "$UE_LOG_WRITABLE" = "1" ] && echo "$*" >> "$UE_MIRROR"; }

if [ "$UE_LOG_WRITABLE" = "1" ]; then
  echo "[vivo_ota_status] $(date '+%F %T') 本次日志开始 (同时写入 $UE_MIRROR)" >> "$UE_MIRROR"
  printf '%s%s%s\n' "$C_BLU" "[vivo_ota_status] $(date '+%F %T') 本次日志开始 (终端带颜色, 文件纯文本: $UE_MIRROR)" "$C_RST"
fi

put "==== update_engine 进程 ===="
ps -A 2>/dev/null | grep -E 'update_engine|update_engine_client' | grep -v grep \
  || put "(无 update_engine 进程, 当前无进行中的更新)"

put ""
put "==== 系统属性里的 OTA 状态 ===="
getprop | grep -iE 'update_engine|ota|vivo.*ota' | head -20

put ""

if [ ! -d "$UE_LOG_DIR" ]; then
  put "==== 未找到 $UE_LOG_DIR, 回退 logcat 快照 ===="
  logcat -d -s update_engine:v 2>/dev/null | tail -n 30 | color_stream \
    || put "(logcat 无 update_engine 日志)"
  exit 0
fi

# 列出所有日志文件(按 mtime 新->旧), 编号便于指定查看
list_logs() {
  local i=1 f
  put "历史日志文件 (新->旧, 编号可传给本脚本查看):"
  ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | while read -r f; do
    printf "  [%d] %s  (%s)\n" "$i" "$f" "$(ls -la "$f" 2>/dev/null | awk '{print $5"字节 "$6" "$7}')"
    i=$((i+1))
  done
}

# list 子命令: 仅列出, 不监听
if [ "$ARG" = "list" ]; then
  put "==== 全部历史日志 ===="
  list_logs
  exit 0
fi

# 指定某份日志查看 (编号或完整/部分文件名)
if [ -n "$ARG" ]; then
  target=""
  case "$ARG" in
    [0-9]*)
      # 按编号取第 N 新的一份
      target=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | sed -n "${ARG}p")
      ;;
    *)
      # 按文件名匹配(支持部分匹配)
      target=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | grep -m1 "$ARG")
      ;;
  esac
  if [ -n "$target" ] && [ -f "$target" ]; then
    put "==== 查看指定日志: $target ===="
    cat "$target" | color_stream
  else
    put "未找到匹配的日志: $ARG"
    put "可运行: $0 list  查看全部历史日志"
  fi
  exit 0
fi

# 默认: 实时监听最新的日志(始终跟到最新文件)
# 用 tail -F 跟 glob 通配: 引擎滚动新建 update_engine.* 时, tail 会自动跟随新文件,
# 不会出现"启动那一刻定死旧文件、之后看不到最新进度"的问题。
# 同时每 5 秒检测一次最新文件, 若与当前正在跟踪的不同则打印分隔提示, 方便肉眼区分轮转。
if [ -d "$UE_LOG_DIR" ]; then
  put "==== update_engine 实时进度 (tail -F $UE_LOG_DIR/update_engine.*) ===="
  put "   (Ctrl+C 退出监听; 取消后想看旧进度请用: $0 list / $0 <编号>)"
  # 记录当前最新文件, 用于轮转提示
  CUR=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | head -1)
  (
    tail -F "$UE_LOG_DIR"/update_engine.* 2>/dev/null | color_stream &
    TAILPID=$!
    while true; do
      sleep 5
      NEW=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | head -1)
      if [ -n "$NEW" ] && [ "$NEW" != "$CUR" ]; then
        CUR="$NEW"
        put ""
        put "---- 进度已切换到最新日志文件: $CUR ----"
      fi
    done
    kill "$TAILPID" 2>/dev/null
  )
else
  put "==== 未找到 $UE_LOG_DIR, 回退 logcat 快照 ===="
  logcat -d -s update_engine:v 2>/dev/null | tail -n 30 | color_stream \
    || put "(logcat 无 update_engine 日志)"
fi
exit 0
