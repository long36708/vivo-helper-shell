#!/system/bin/sh
# 取消当前 OTA 安装 (对齐 GT 玩机助手 quit.sh: update_engine_client --cancel)
cd /
export PATH="/system/bin:/system/xbin:/sbin:/vendor/bin:/odm/bin:/data/adb/ksu/bin:/data/adb/magisk/bin:$PATH"
CLIENT=/system/bin/update_engine_client
[ -x "$CLIENT" ] || { echo "FAILED: 找不到 $CLIENT"; exit 1; }

# 全程日志镜像到 /sdcard/ota.log (追加), ash 兼容: mkfifo + 后台 tee
if { [ -w /sdcard ] || mountpoint -q /sdcard 2>/dev/null; } && command -v mkfifo >/dev/null 2>&1; then
  LOGPIPE="/data/local/tmp/vivo_ota_cancel.ota.log.pipe"
  rm -f "$LOGPIPE"
  if mkfifo "$LOGPIPE" 2>/dev/null; then
    tee -a /sdcard/ota.log < "$LOGPIPE" &
    exec > "$LOGPIPE" 2>&1
    echo "[vivo_ota_cancel] $(date '+%F %T') 本次日志开始 (同时写入 /sdcard/ota.log)"
  fi
fi

echo "正在取消 update_engine 任务 ..."
OUT=$("$CLIENT" --cancel 2>&1); RC=$?
echo "$OUT"

# No ongoing update to cancel 属于正常(本来就没在更新), 非致命
if echo "$OUT" | grep -qi 'No ongoing update'; then
  echo "当前没有进行中的更新, 无需取消。"
else
  [ $RC -ne 0 ] && echo "注意: --cancel 返回 $RC"
fi

# 兜底: 证书绕过时脚本可能起过独立 update_engine 前台进程, --cancel 取消不到, 直接重启/杀掉
echo "兜底重启 update_engine 服务 ..."
setprop ctl.restart update_engine 2>/dev/null
# 仅当存在独立 update_engine 前台进程(工具 nohup 启动的 --logtostderr 形态)时才杀, 避免误杀系统服务
if pgrep -f 'update_engine --logtostderr' >/dev/null 2>&1; then
  pkill -9 -f 'update_engine --logtostderr' 2>/dev/null
  echo "已杀掉残留的独立 update_engine 前台进程"
fi

echo "已尝试取消并重启 update_engine。可用『查看安装进度』确认状态。"
exit 0
