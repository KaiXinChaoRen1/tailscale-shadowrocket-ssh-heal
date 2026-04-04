#!/bin/zsh

set -euo pipefail

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
  echo "Error: tailscale command not found in PATH." >&2
  exit 1
fi

echo "Bringing Tailscale down..."
"$tailscale_bin" down

sleep 1

echo "Bringing Tailscale up..."
"$tailscale_bin" up

sleep 5

echo
echo "Current status:"
"$tailscale_bin" status
