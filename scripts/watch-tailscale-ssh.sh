#!/bin/zsh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
script_path="${script_dir}/$(basename "$0")"
command_name="${1:-start}"
peer_ip="${2:-100.82.42.75}"
peer_port="${3:-22}"
base_interval="${4:-180}"

label="com.lwq.tailscale-ssh-heal"
plist_path="${HOME}/Library/LaunchAgents/${label}.plist"
log_file="${HOME}/Library/Logs/tailscale-ssh-heal.log"
heal_script="${script_dir}/check-and-heal-tailscale-ssh.sh"
state_dir="${HOME}/Library/Application Support/tailscale-ssh-heal"
state_file="${state_dir}/state.env"
lock_dir="${state_dir}/run.lock"
lock_pid_file="${lock_dir}/pid"
uid="$(id -u)"

mkdir -p "${HOME}/Library/LaunchAgents" "${HOME}/Library/Logs" "$state_dir"

log_block() {
  {
    printf '[%s]\n' "$(date '+%F %T')"
    printf '%s\n' "$@"
    printf '\n'
  } >> "$log_file"
}

write_state() {
  cat > "$state_file" <<EOF
CURRENT_INTERVAL=$1
CONSECUTIVE_FAILURES=$2
LAST_RESULT=$3
NEXT_CHECK_AT=$4
LAST_CHECK_AT=$5
EOF
}

load_state() {
  if [[ -f "$state_file" ]]; then
    # shellcheck disable=SC1090
    source "$state_file"
  fi

  CURRENT_INTERVAL="${CURRENT_INTERVAL:-$base_interval}"
  CONSECUTIVE_FAILURES="${CONSECUTIVE_FAILURES:-0}"
  LAST_RESULT="${LAST_RESULT:-unknown}"
  NEXT_CHECK_AT="${NEXT_CHECK_AT:-0}"
  LAST_CHECK_AT="${LAST_CHECK_AT:-0}"
}

format_epoch() {
  if [[ -n "${1:-}" && "$1" -gt 0 ]]; then
    date -r "$1" '+%F %T'
  else
    echo "未计划"
  fi
}

write_plist() {
  cat > "$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "https://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${label}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>${script_path}</string>
    <string>run</string>
    <string>${peer_ip}</string>
    <string>${peer_port}</string>
    <string>${base_interval}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>${base_interval}</integer>
  <key>StandardOutPath</key>
  <string>${log_file}</string>
  <key>StandardErrorPath</key>
  <string>${log_file}</string>
</dict>
</plist>
EOF
}

agent_exists() {
  [[ -f "$plist_path" ]]
}

agent_loaded() {
  launchctl print "gui/${uid}/${label}" >/dev/null 2>&1
}

acquire_lock() {
  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" > "$lock_pid_file"
    trap 'rm -rf "$lock_dir" >/dev/null 2>&1 || true' EXIT
    return 0
  fi

  if [[ -f "$lock_pid_file" ]]; then
    existing_pid="$(cat "$lock_pid_file" 2>/dev/null || true)"
    if [[ -n "$existing_pid" ]] && ! kill -0 "$existing_pid" >/dev/null 2>&1; then
      rm -rf "$lock_dir"
      if mkdir "$lock_dir" 2>/dev/null; then
        printf '%s\n' "$$" > "$lock_pid_file"
        trap 'rm -rf "$lock_dir" >/dev/null 2>&1 || true' EXIT
        return 0
      fi
    fi
  fi

  return 1
}

log_recovery_if_needed() {
  if [[ "$LAST_RESULT" == "healed_local_issue" || "$LAST_RESULT" == "remote_ssh_issue" || "$LAST_RESULT" == "peer_or_path_issue" || "$LAST_RESULT" == "error" || "$CONSECUTIVE_FAILURES" -gt 0 || "$CURRENT_INTERVAL" -ne "$base_interval" ]]; then
    log_block \
      "检查结果：正常" \
      "检测目标：${peer_ip}:${peer_port}" \
      "说明：连接已恢复，连续异常次数清零" \
      "当前间隔：恢复为 ${base_interval} 秒"
  fi
}

run_once() {
  if [[ ! -x "$heal_script" ]]; then
    log_block \
      "检查脚本缺失或不可执行" \
      "脚本路径：${heal_script}"
    exit 1
  fi

  if ! acquire_lock; then
    exit 0
  fi

  load_state

  now="$(date +%s)"
  if [[ "$NEXT_CHECK_AT" -gt "$now" ]]; then
    exit 0
  fi

  LAST_CHECK_AT="$now"
  output=""

  if output="$("$heal_script" --quiet-ok "$peer_ip" "$peer_port" 2>&1)"; then
    log_recovery_if_needed
    CONSECUTIVE_FAILURES=0
    CURRENT_INTERVAL="$base_interval"
    LAST_RESULT="healthy"
  else
    exit_code=$?

    case "$exit_code" in
      10)
        CONSECUTIVE_FAILURES=$((CONSECUTIVE_FAILURES + 1))
        LAST_RESULT="healed_local_issue"
        log_block \
          "检查结果：异常，已触发 Tailscale 重启" \
          "检测目标：${peer_ip}:${peer_port}" \
          "连续异常次数：${CONSECUTIVE_FAILURES}" \
          "当前间隔：${CURRENT_INTERVAL} 秒" \
          "详细信息：${output//$'\n'/ | }"

        if (( CONSECUTIVE_FAILURES % 2 == 0 )); then
          CURRENT_INTERVAL=$((CURRENT_INTERVAL * 2))
          log_block \
            "退避策略已触发" \
            "检测目标：${peer_ip}:${peer_port}" \
            "原因：连续两次检查都异常并触发了重启" \
            "新的检查间隔：${CURRENT_INTERVAL} 秒"
        fi
        ;;
      20)
        if [[ "$LAST_RESULT" != "remote_ssh_issue" || "$CONSECUTIVE_FAILURES" -ne 0 || "$CURRENT_INTERVAL" -ne "$base_interval" ]]; then
          log_block \
            "检查结果：异常，但未触发 Tailscale 重启" \
            "检测目标：${peer_ip}:${peer_port}" \
            "说明：Tailscale 链路正常，更像是远端 SSH 服务自身有问题" \
            "当前间隔：恢复为 ${base_interval} 秒" \
            "详细信息：${output//$'\n'/ | }"
        fi
        CONSECUTIVE_FAILURES=0
        CURRENT_INTERVAL="$base_interval"
        LAST_RESULT="remote_ssh_issue"
        ;;
      21)
        if [[ "$LAST_RESULT" != "peer_or_path_issue" || "$CONSECUTIVE_FAILURES" -ne 0 || "$CURRENT_INTERVAL" -ne "$base_interval" ]]; then
          log_block \
            "检查结果：异常，但未触发 Tailscale 重启" \
            "检测目标：${peer_ip}:${peer_port}" \
            "说明：路由仍然正常，但 Tailscale 对端暂时不可达，更像是远端离线或更深层网络波动" \
            "当前间隔：恢复为 ${base_interval} 秒" \
            "详细信息：${output//$'\n'/ | }"
        fi
        CONSECUTIVE_FAILURES=0
        CURRENT_INTERVAL="$base_interval"
        LAST_RESULT="peer_or_path_issue"
        ;;
      *)
        if [[ "$LAST_RESULT" != "error" || "$CONSECUTIVE_FAILURES" -ne 0 || "$CURRENT_INTERVAL" -ne "$base_interval" ]]; then
          log_block \
            "检查脚本执行出错" \
            "检测目标：${peer_ip}:${peer_port}" \
            "退出码：${exit_code}" \
            "当前间隔：恢复为 ${base_interval} 秒" \
            "详细信息：${output//$'\n'/ | }"
        fi
        CONSECUTIVE_FAILURES=0
        CURRENT_INTERVAL="$base_interval"
        LAST_RESULT="error"
        ;;
    esac
  fi

  NEXT_CHECK_AT=$((LAST_CHECK_AT + CURRENT_INTERVAL))
  write_state "$CURRENT_INTERVAL" "$CONSECUTIVE_FAILURES" "$LAST_RESULT" "$NEXT_CHECK_AT" "$LAST_CHECK_AT"
}

start_agent() {
  write_state "$base_interval" 0 "starting" 0 0
  write_plist
  log_block \
    "后台巡检已启动" \
    "检测目标：${peer_ip}:${peer_port}" \
    "基础间隔：${base_interval} 秒" \
    "调度方式：launchd StartInterval 单次执行；若睡眠期间错过检查点，唤醒后由 launchd 尽快补跑一次"
  launchctl bootout "gui/${uid}" "$plist_path" >/dev/null 2>&1 || true
  launchctl bootstrap "gui/${uid}" "$plist_path"
  launchctl kickstart -k "gui/${uid}/${label}" >/dev/null 2>&1 || true

  echo "Watcher installed and started."
  echo "Base interval: ${base_interval}s"
  echo "Log file: $log_file"
}

stop_agent() {
  if agent_exists; then
    launchctl bootout "gui/${uid}" "$plist_path" >/dev/null 2>&1 || true
    rm -f "$plist_path"
  fi

  rm -rf "$lock_dir" >/dev/null 2>&1 || true
  echo "Watcher stopped."
}

status_agent() {
  load_state

  if agent_loaded; then
    echo "Watcher is installed in launchd."
  else
    echo "Watcher is not installed in launchd."
  fi

  if agent_exists; then
    echo "Plist: $plist_path"
  fi

  echo "Scheduler mode: launchd StartInterval one-shot"
  echo "Current interval: ${CURRENT_INTERVAL}s"
  echo "Consecutive failures: ${CONSECUTIVE_FAILURES}"
  echo "Last result: ${LAST_RESULT}"
  echo "Last check at: $(format_epoch "$LAST_CHECK_AT")"
  echo "Next eligible check: $(format_epoch "$NEXT_CHECK_AT")"
  echo "Log file: $log_file"
}

case "$command_name" in
  start)
    start_agent
    ;;
  stop)
    stop_agent
    ;;
  restart)
    stop_agent
    start_agent
    ;;
  status)
    status_agent
    ;;
  run)
    run_once
    ;;
  *)
    echo "Usage: $0 {start|stop|restart|status} [peer_ip] [peer_port] [base_interval_seconds]" >&2
    exit 1
    ;;
esac
