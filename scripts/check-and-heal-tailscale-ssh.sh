#!/bin/zsh

set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
quiet_ok=0

if [[ "${1:-}" == "--quiet-ok" ]]; then
  quiet_ok=1
  shift
fi

peer_ip="${1:-100.82.42.75}"
peer_port="${2:-22}"
restart_script="${script_dir}/restart-tailscale.sh"

run_capture_with_timeout() {
  local timeout_seconds="$1"
  shift

  python3 - "$timeout_seconds" "$@" <<'PY'
import subprocess
import sys

timeout = float(sys.argv[1])
cmd = sys.argv[2:]

try:
    proc = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
except subprocess.TimeoutExpired as exc:
    if exc.stdout:
        sys.stdout.write(exc.stdout if isinstance(exc.stdout, str) else exc.stdout.decode())
    if exc.stderr:
        sys.stderr.write(exc.stderr if isinstance(exc.stderr, str) else exc.stderr.decode())
    print(f"timeout after {timeout:g}s", file=sys.stderr)
    sys.exit(124)

sys.stdout.write(proc.stdout)
sys.stderr.write(proc.stderr)
sys.exit(proc.returncode)
PY
}

tailscale_bin=""
for candidate in /opt/homebrew/bin/tailscale /usr/local/bin/tailscale; do
  if [[ -x "$candidate" ]]; then
    tailscale_bin="$candidate"
    break
  fi
done

if [[ -z "$tailscale_bin" ]] && command -v tailscale >/dev/null 2>&1; then
  tailscale_bin="$(command -v tailscale)"
fi

if [[ -z "$tailscale_bin" ]]; then
  echo "错误：找不到 tailscale 命令。"
  exit 1
fi

if [[ ! -x "$restart_script" ]]; then
  echo "错误：找不到可执行的重启脚本：${restart_script}"
  exit 1
fi

status_json="$(run_capture_with_timeout 8 "$tailscale_bin" status --json 2>/dev/null || true)"
if [[ -n "$status_json" ]]; then
  backend_query_ok=1
else
  backend_query_ok=0
fi
backend_state="$(printf '%s' "$status_json" | tr -d '\n' | sed -nE 's/.*"BackendState"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p')"
backend_state="${backend_state:-未知}"

tailscale_ip="$("$tailscale_bin" ip -4 2>/dev/null | head -n1 || true)"

tailscale_iface=""
if [[ -n "$tailscale_ip" ]]; then
  tailscale_route_output="$(route -n get "$tailscale_ip" 2>/dev/null || true)"
  tailscale_iface="$(printf '%s\n' "$tailscale_route_output" | awk '/interface:/{print $2; exit}')"
fi

peer_route_output="$(route -n get "$peer_ip" 2>/dev/null || true)"
peer_iface="$(printf '%s\n' "$peer_route_output" | awk '/interface:/{print $2; exit}')"

if [[ -n "$tailscale_iface" && "$peer_iface" == "$tailscale_iface" ]]; then
  route_ok=1
else
  route_ok=0
fi

if nc -G 3 -zw 3 "$peer_ip" "$peer_port" >/dev/null 2>&1; then
  port_ok=1
else
  port_ok=0
fi

if "$tailscale_bin" ping --until-direct=false -c 1 --timeout 5s "$peer_ip" >/dev/null 2>&1; then
  ping_ok=1
else
  ping_ok=0
fi

print_healthy() {
  if [[ "$quiet_ok" -eq 0 ]]; then
    echo "检查结果：正常"
    echo "检测目标：${peer_ip}:${peer_port}"
    echo "BackendState：${backend_state}"
    echo "BackendState 查询：$([[ "$backend_query_ok" -eq 1 ]] && echo 正常 || echo 超时或失败)"
    echo "本机 Tailscale 地址：${tailscale_ip:-未知}"
    echo "Tailscale 接口：${tailscale_iface:-未知}"
    echo "目标路由接口：${peer_iface:-未知}"
    echo "路由检查：正常"
    echo "TCP 端口检查：正常"
    echo "Tailscale 连通性检查：正常"
  fi
}

print_restart_reason() {
  echo "检查结果：异常，已触发 Tailscale 重启"
  echo "检测目标：${peer_ip}:${peer_port}"
  echo "异常归类：$1"
  echo "BackendState：${backend_state}"
  echo "BackendState 查询：$([[ "$backend_query_ok" -eq 1 ]] && echo 正常 || echo 超时或失败)"
  echo "本机 Tailscale 地址：${tailscale_ip:-未知}"
  echo "Tailscale 接口：${tailscale_iface:-未知}"
  echo "目标路由接口：${peer_iface:-未知}"
  echo "路由检查：$([[ "$route_ok" -eq 1 ]] && echo 正常 || echo 异常)"
  echo "TCP 端口检查：$([[ "$port_ok" -eq 1 ]] && echo 正常 || echo 异常)"
  echo "Tailscale 连通性检查：$([[ "$ping_ok" -eq 1 ]] && echo 正常 || echo 异常)"
  echo "处理动作：准备重启 Tailscale"
  "$restart_script" >/dev/null 2>&1
  echo "处理动作：Tailscale 重启命令已执行完成"
}

print_no_restart_reason() {
  echo "检查结果：异常，但未触发 Tailscale 重启"
  echo "检测目标：${peer_ip}:${peer_port}"
  echo "异常归类：$1"
  echo "BackendState：${backend_state}"
  echo "BackendState 查询：$([[ "$backend_query_ok" -eq 1 ]] && echo 正常 || echo 超时或失败)"
  echo "本机 Tailscale 地址：${tailscale_ip:-未知}"
  echo "Tailscale 接口：${tailscale_iface:-未知}"
  echo "目标路由接口：${peer_iface:-未知}"
  echo "路由检查：$([[ "$route_ok" -eq 1 ]] && echo 正常 || echo 异常)"
  echo "TCP 端口检查：$([[ "$port_ok" -eq 1 ]] && echo 正常 || echo 异常)"
  echo "Tailscale 连通性检查：$([[ "$ping_ok" -eq 1 ]] && echo 正常 || echo 异常)"
  echo "处理动作：保守处理，不重启本机 Tailscale"
}

if [[ ( "$backend_state" == "Running" || "$backend_query_ok" -eq 0 ) && -n "$tailscale_ip" && -n "$tailscale_iface" && "$route_ok" -eq 1 && "$port_ok" -eq 1 ]]; then
  print_healthy
  exit 0
fi

if [[ ( "$backend_query_ok" -eq 1 && "$backend_state" != "Running" ) || -z "$tailscale_ip" || -z "$tailscale_iface" ]]; then
  print_restart_reason "本机 Tailscale 服务或本地隧道状态异常"
  exit 10
fi

if [[ "$route_ok" -eq 0 ]]; then
  print_restart_reason "目标流量没有走到当前 Tailscale 接口"
  exit 10
fi

if [[ "$route_ok" -eq 1 && "$port_ok" -eq 0 && "$ping_ok" -eq 1 ]]; then
  print_no_restart_reason "Tailscale 链路正常，更像是远端 SSH 服务或远端 22 端口本身有问题"
  exit 20
fi

if [[ "$route_ok" -eq 1 && "$port_ok" -eq 0 && "$ping_ok" -eq 0 ]]; then
  print_no_restart_reason "路由仍然正常，但 Tailscale 对端不可达，可能是远端节点离线或更深层网络波动"
  exit 21
fi

echo "检查脚本未能归类当前状态，请人工复查。"
echo "检测目标：${peer_ip}:${peer_port}"
echo "BackendState：${backend_state}"
echo "BackendState 查询：$([[ "$backend_query_ok" -eq 1 ]] && echo 正常 || echo 超时或失败)"
echo "本机 Tailscale 地址：${tailscale_ip:-未知}"
echo "Tailscale 接口：${tailscale_iface:-未知}"
echo "目标路由接口：${peer_iface:-未知}"
echo "路由检查：$([[ "$route_ok" -eq 1 ]] && echo 正常 || echo 异常)"
echo "TCP 端口检查：$([[ "$port_ok" -eq 1 ]] && echo 正常 || echo 异常)"
echo "Tailscale 连通性检查：$([[ "$ping_ok" -eq 1 ]] && echo 正常 || echo 异常)"
exit 1
