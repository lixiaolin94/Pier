#!/bin/zsh
# aft-mtp — 用 Android File Transfer 稳定连接 Switch DBI（MTP）
#
# 根因：DBI 的 MTP 接口在 macOS 看来是"相机"（PTP 类），系统的 ptpcamerad
# 会独占它，AFT 就连不上。ptpcamerad 受 SIP 保护，launchctl disable 无效；
# icdd、Google Drive（设备备份）等一请求，launchd 就立刻把它拉起来。
#
# 关键：USB 接口是"先占先得"，AFT 一旦拿到独占权，ptpcamerad 就抢不走。
# 所以：清场 → 打开 AFT → 确认 AFT 拿到独占权（没拿到就重试）；
# AFT 运行期间只在 ptpcamerad 真的抢走接口时（如 DBI 重连）才杀掉它。
#
# 用法：
#   aft-mtp            # 打开 AFT 并确保它拿到 DBI，AFT 退出后脚本自动结束
#   aft-mtp status     # 查看 DBI / 接口占用情况

set -u

AFT="Android File Transfer"
AFT_APP="/Applications/$AFT.app"
AGENTS=(
  "$HOME/Library/Application Support/Google/$AFT/$AFT Agent.app"
  "$AFT_APP/Contents/Helpers/$AFT Agent.app"
)

dbi_present() { ioreg -p IOUSB -w0 2>/dev/null | grep -q 'DBI@'; }
owner()       { ioreg -r -n DBI -l -w0 2>/dev/null | grep -m1 UsbExclusiveOwner; }
aft_owns()    { owner | grep -q 'Android File'; }
aft_running() { pgrep -xq "$AFT"; }
kill_ptp()    { killall -9 ptpcamerad 2>/dev/null; }
notify()      { osascript -e "display notification \"$1\" with title \"Switch MTP\"" 2>/dev/null; }

# AFT Agent 会在插 USB 时自动弹出 AFT 抢设备，改名让它失效（AFT 更新后可能复原）
disable_agents() {
  killall "$AFT Agent" 2>/dev/null
  local p
  for p in "${AGENTS[@]}"; do
    [[ -d "$p" && ! -e "$p.disabled" ]] && mv "$p" "$p.disabled"
  done
}

# 清场后打开 AFT，等它拿到独占权；最多重开 3 次
connect() {
  local attempt i
  for attempt in 1 2 3; do
    kill_ptp
    open -a "$AFT"
    for i in {1..20}; do
      aft_owns && return 0
      kill_ptp
      sleep 0.25
    done
    killall "$AFT" 2>/dev/null
    sleep 0.5
  done
  return 1
}

status() {
  if dbi_present; then
    echo "DBI: 已连接"
    owner || echo "接口占用: 无"
  else
    echo "DBI: 未连接"
  fi
  aft_running && echo "AFT: 运行中" || echo "AFT: 未运行"
  pgrep -lx ptpcamerad || echo "ptpcamerad: 未运行"
}

run() {
  [[ -d "$AFT_APP" ]] || { notify "未安装 Android File Transfer"; exit 1; }
  disable_agents
  if dbi_present; then
    connect || notify "AFT 没能拿到 DBI，请重新插拔数据线后再试"
  else
    kill_ptp
    open -a "$AFT"
  fi
  # AFT 运行期间：只在 ptpcamerad 抢走接口时清场（DBI 重连、晚插线的情况）
  sleep 2
  while aft_running; do
    owner | grep -q ptpcamera && kill_ptp
    sleep 1
  done
  disable_agents   # AFT 运行时可能把 Agent 装回来
}

case "${1:-}" in
  "")     run ;;
  status) status ;;
  *)      sed -n '2,15p' "$0"; exit 2 ;;
esac
