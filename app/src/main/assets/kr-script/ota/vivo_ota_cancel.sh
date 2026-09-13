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

# CleanupPreviousUpdateAction 收尾不可取消(VAB merge, 引擎设计禁止打断):
# 2026-09-06 复盘: 该状态下 --cancel 报错54, ctl.restart 只会让引擎重排 cleanup
# 再次卡死(它一直等 markBootSuccessful)。真正的"取消"= 补 markBootSuccessful
# (txn=8, 本机实测幂等)让收尾跑完 merge 回到干净 IDLE。
SKIP_RESTART=0
if echo "$OUT" | grep -q 'CleanupPreviousUpdateAction'; then
  # 取"名字"列, 不能取第 1 列(那是序号列如 "29", 会导致 service call 服务不存在,
  # markBootSuccessful 静默不下发)。与 vivo_ota.sh 的 boot_hal_svc() 保持一致。
  SVC=$(service list 2>/dev/null | grep -i 'IBootControl' | head -n1 \
        | grep -oE '[A-Za-z0-9_.]+/[A-Za-z0-9_.]+' | head -n1)
  case "$SVC" in *[!0-9]*) ;; *) SVC="" ;; esac
  echo "检测到引擎卡在 CleanupPreviousUpdateAction (等 markBootSuccessful), cancel 动不了, 走收尾解锁 ..."
  if [ -n "$SVC" ]; then
    echo "调 $SVC markBootSuccessful (txn=8, 幂等) 标记当前槽启动成功 ..."
    service call "$SVC" 8 >/dev/null 2>&1
  else
    echo "⚠ 未找到 IBootControl 服务, 仅靠 --merge 收尾"
  fi
  if ! pgrep -x update_engine >/dev/null 2>&1; then
    setprop ctl.start update_engine 2>/dev/null
    sleep 3
  fi
  echo "执行 update_engine_client --merge 等待快照收尾 (有就合并/没有秒回; 合并期间勿重启断电) ..."
  "$CLIENT" --merge 2>&1 | tail -n 5
  OUT=$("$CLIENT" --cancel 2>&1); RC=$?
  echo "$OUT"
  case "$OUT" in
    *"CleanupPreviousUpdateAction"*)
      echo "⚠ 收尾仍未完成: 请正常重启设备, 开机后等 1-2 分钟让系统自动 markBootSuccessful, 切勿反复杀引擎/清状态。"
      ;;
    *)
      echo "✅ 引擎已解除收尾卡死, 回到干净 IDLE, 可正常安装新包。"
      ;;
  esac
  # 已走收尾解锁, 跳过下方兜底重启(重启引擎只会重排 cleanup, 无意义)
  SKIP_RESTART=1
fi

if [ "$SKIP_RESTART" != "1" ]; then
  # 兜底: 证书绕过时脚本可能起过独立 update_engine 前台进程, --cancel 取消不到, 直接重启/杀掉
  echo "兜底重启 update_engine 服务 ..."
  setprop ctl.restart update_engine 2>/dev/null
  # 仅当存在独立 update_engine 前台进程(工具 nohup 启动的 --logtostderr 形态)时才杀, 避免误杀系统服务
  if pgrep -f 'update_engine --logtostderr' >/dev/null 2>&1; then
    pkill -9 -f 'update_engine --logtostderr' 2>/dev/null
    echo "已杀掉残留的独立 update_engine 前台进程"
  fi
fi

echo "已尝试取消并重启 update_engine。可用『查看安装进度』确认状态。"

# 取消后的二选一引导 (借鉴 Custota 的 REVERT / resetStatus 思路):
# 取消可能发生在不同阶段, 给出对应处置建议, 避免用户误判"是否已刷入"。
# 注意: update_engine_client 无 --status flag (真机实测报 unknown command line flag),
#       状态只能从落盘日志 (/logdata/recovery/update_engine_log) 关键字判定。
UE_LOG_DIR=/logdata/recovery/update_engine_log
LAST_LOG=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | head -1)
STATE_HINT=""
[ -n "$LAST_LOG" ] && STATE_HINT=$(grep -aoE 'UPDATED_NEED_REBOOT|UPDATE_STATUS_IDLE|ActionProcessor: (suspending|resuming|finished)|Downloading|Verifying|Finalizing' "$LAST_LOG" 2>/dev/null | tail -1)
if echo "$STATE_HINT" | grep -q 'UPDATED_NEED_REBOOT'; then
  echo ""
  echo "⚠ 引擎日志显示 UPDATED_NEED_REBOOT: 本次取消前, 包可能已部分/全部写入目标槽。"
  echo "   情况A (想保留本次更新): 直接『重启设备』即可让已刷入的包生效。"
  echo "   情况B (想放弃、改刷其他包): 用『强制重刷(FORCE)』清状态后重刷, 否则可能卡在待生效态。"
elif echo "$STATE_HINT" | grep -qi 'IDLE\|finished\|cancel'; then
  echo ""
  echo "ℹ 引擎已回到可更新状态: 本次取消大概率未写入/只写了少量数据, 可安全重刷其他包。"
  echo "   如需彻底清状态重刷: 用『强制重刷(FORCE)』入口。"
fi
exit 0
