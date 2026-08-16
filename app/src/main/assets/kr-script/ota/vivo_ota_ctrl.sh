#!/system/bin/sh
# ============================================================================
# vivo_ota_ctrl.sh —— update_engine 运行期控制 (暂停/恢复/预检)
#
# 用法:
#   suspend   -> 暂停当前进行中的安装 (update_engine_client --suspend)
#   resume    -> 恢复被暂停的安装   (update_engine_client --resume)
#   preflight -> 安装前预检: 不动 update_engine 状态, 只预判包能否刷、会刷到哪
#
# 真机实测 (V2419A / PD2419):
#   --suspend / --resume 均被引擎正确处理 (日志见 ActionProcessor: suspending/resuming)。
#   --suspend 无进行中更新时 rc=0 但无效果 (INFO "Command took X ms"), 故用日志回读确认。
#   --reset_status / --cancel 见 vivo_ota.sh clear_ue_state。
#   --status 是**无效 flag** (unknown command line flag), 状态只能从落盘日志判定。
# ============================================================================
cd /
export PATH="/system/bin:/system/xbin:/sbin:/vendor/bin:/odm/bin:/data/adb/ksu/bin:/data/adb/magisk/bin:$PATH"

CLIENT=/system/bin/update_engine_client
UE_LOG_DIR=/logdata/recovery/update_engine_log
ARG="$1"; shift
[ -x "$CLIENT" ] || { echo "FAILED: 找不到 $CLIENT"; exit 1; }

C_BLU='\033[34m'; C_GRN='\033[32m'; C_YEL='\033[33m'; C_RST='\033[0m'
put() { printf '%b\n' "$*"; }
color_stream() { sed -E \
  -e "s/(ERROR|error|Failed|failed|FAIL)/$(printf '\033[31m')&$(printf '\033[0m')/g" \
  -e "s/(suspending|resuming|UPDATED_NEED_REBOOT|overall progress|progress)/$(printf '\033[36m')&$(printf '\033[0m')/g" ; }

# 引擎当前是否在"进行中"(正在下载/校验/写入/清理)。
# 判定依据(无 --status, 真机实测):
#   1) update_engine 进程在跑
#   2) 最新日志不含终态标记(IDLE / UPDATED_NEED_REBOOT / CLEANUP completed / "Boot completed, waiting")
ue_is_active() {
  pgrep -x update_engine >/dev/null 2>&1 || return 1
  L=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | head -1)
  [ -n "$L" ] || return 0   # 有进程但无日志, 视为进行中
  # 终态关键字出现 -> 不在进行中
  grep -qE 'UPDATE_STATUS_IDLE|UPDATED_NEED_REBOOT|Boot completed, waiting on markBootSuccessful' "$L" 2>/dev/null \
    && return 1
  return 0
}

case "$ARG" in
  suspend)
    if ! ue_is_active; then
      put "${C_YEL}⚠ 当前没有进行中的安装, 无需暂停。${C_RST}"
      put "  (若刚点完安装, 请等几秒让引擎进入下载/写入态后再暂停)"
      exit 0
    fi
    OUT=$("$CLIENT" --suspend 2>&1); RC=$?
    put "suspend 返回: $OUT (rc=$RC)"
    # 回读最新日志确认确实进入 suspending
    L=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | head -1)
    if [ -n "$L" ] && grep -q 'suspending' "$L" 2>/dev/null; then
      put "${C_GRN}✅ 已发送暂停请求, 引擎正在挂起。${C_RST}"
      put "   需要继续时运行『恢复当前安装』。"
    else
      put "${C_YEL}⚠ 已发送暂停, 但未在日志中确认到 suspending (可能已接近完成)。${C_RST}"
    fi
    # 写 ota.log 可见反馈 (与主安装日志同一入口, 方便一眼看到暂停事件)
    OTA_LOG=/data/local/tmp/vivo_ota_install.log
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [CTRL] suspend 指令 (rc=$RC), 引擎日志: ${L:-<无>}" >> "$OTA_LOG" 2>/dev/null
    ;;
  resume)
    OUT=$("$CLIENT" --resume 2>&1); RC=$?
    put "resume 返回: $OUT (rc=$RC)"
    L=$(ls -t "$UE_LOG_DIR"/update_engine.* 2>/dev/null | head -1)
    if [ -n "$L" ] && grep -q 'resuming' "$L" 2>/dev/null; then
      put "${C_GRN}✅ 已发送恢复请求, 引擎正在继续安装。${C_RST}"
    else
      put "${C_YEL}⚠ 已发送恢复, 但日志未确认 resuming (可能本就没有被暂停的任务)。${C_RST}"
      ue_is_active && put "   当前引擎看似在进行中, 可直接『查看安装进度』确认。"
    fi
    ;;
  preflight)
    # 预检: 解析包结构 + 环境, 不触碰 update_engine 状态机。
    # 因 --verify 需引擎生成的 /data/ota_package/metadata (非 zip 内 metadata),
    # 故 preflight 用脚本内部已解析的信息做"软预检", 零风险、可离线运行。
    ROM="$1"
    [ -n "$ROM" ] || { put "${C_YEL}用法: sh \$0 preflight <ota_zip路径>${C_RST}"; exit 1; }
    [ -f "$ROM" ] || { put "FAILED: 包不存在: $ROM"; exit 1; }
    put "${C_BLU}==== 预检: $(basename "$ROM") ====${C_RST}"
    # 基础结构
    unzip -l "$ROM" >/dev/null 2>&1 || { put "  ✗ 不是合法 zip/OTA 包"; exit 1; }
    META=$(unzip -p "$ROM" "META-INF/com/android/metadata" 2>/dev/null)
    [ -n "$META" ] || { put "  ✗ 缺 META-INF/com/android/metadata (非标准 OTA 包)"; exit 1; }
    put "  ✓ 包结构完整"
    # 机型匹配 (软警告, 不阻断)
    DEV=$(printf '%s\n' "$META" | grep -m1 '^pre-device=' | cut -d= -f2)
    HDEV=$(printf '%s\n' "$META" | grep -m1 '^hardware-device=' | cut -d= -f2)
    CUR_DEV=$(getprop ro.product.device 2>/dev/null)
    if [ -n "$DEV" ] && [ -n "$CUR_DEV" ] && [ "$DEV" != "$CUR_DEV" ]; then
      put "  ${C_YEL}⚠ pre-device=$DEV 当前=$CUR_DEV (vivo 多代号, 谨慎)${C_RST}"
    else
      put "  ✓ 机型匹配 (pre-device=$DEV 当前=$CUR_DEV)"
    fi
    # payload + headers 完整性
    PAYLOAD=$(unzip -l "$ROM" 2>/dev/null | grep -m1 'payload.bin' | awk '{print $4}')
    HDRS=$(unzip -p "$ROM" "payload_properties.txt" 2>/dev/null | sed '/^[[:space:]]*$/d')
    [ -n "$PAYLOAD" ] && put "  ✓ 含 $PAYLOAD"
    [ -n "$HDRS" ] && put "  ✓ payload_properties.txt 校验头完整 ($(printf '%s\n' "$HDRS" | wc -l) 行)" \
                  || put "  ${C_YEL}⚠ payload_properties.txt 为空 (无法校验, 包可能损坏)${C_RST}"
    # 目标分区可写性 (boot / init_boot / lk)
    for p in boot init_boot; do
      for s in _a _b; do
        node=/dev/block/by-name/$p$s
        [ -b "$node" ] && { [ -w "$node" ] && put "  ✓ $node 可写" || put "  ${C_YEL}⚠ $node 不可写(需 root)${C_RST}"; }
      done
    done
    # 降级维度提醒
    POST_TS=$(printf '%s\n' "$META" | grep -m1 '^post-timestamp=' | cut -d= -f2)
    CUR_TS=$(getprop ro.build.date.utc 2>/dev/null)
    if [ -n "$POST_TS" ] && [ -n "$CUR_TS" ] && [ "$POST_TS" -lt "$CUR_TS" ] 2>/dev/null; then
      put "  ${C_YEL}⚠ post-timestamp 早于当前, 属降级刷机, 需开启降级模式(第2参数=1)${C_RST}"
    fi
    put "${C_BLU}==== 预检结束: 以上仅结构/环境预判, 最终以 update_engine 实际校验为准 ====${C_RST}"
    put "  确认无误后用主安装入口刷入; 仍不确定可先试刷(失败不会变砖, 状态可 FORCE 清)。"
    ;;
  *)
    put "用法: sh \$0 {suspend|resume|preflight <zip>}"
    exit 1
    ;;
esac
exit 0
