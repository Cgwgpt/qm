#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
log_dir="$root/local"

proc_matches() {
  local pid="$1" marker="$2"
  ps -p "$pid" -o command= 2>/dev/null | grep -qF "$marker"
}

stop_pidfile() {
  local name="$1" marker="$2"
  local pidfile="$log_dir/$name.pid"
  if [ ! -f "$pidfile" ]; then
    echo "[dev-down] $name not running via dev-up"
    return 0
  fi
  local pid
  pid=$(cat "$pidfile")
  if kill -0 "$pid" 2>/dev/null && proc_matches "$pid" "$marker"; then
    kill "$pid" 2>/dev/null || true
    for _ in $(seq 1 10); do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.2
    done
    if kill -0 "$pid" 2>/dev/null; then
      kill -9 "$pid" 2>/dev/null && echo "[dev-down] killed $name (pid $pid, SIGKILL)" || echo "[dev-down] $name (pid $pid) still lingering"
    else
      echo "[dev-down] stopped $name (pid $pid)"
    fi
  else
    echo "[dev-down] $name (pid $pid) not ours or already gone"
  fi
  rm -f "$pidfile"
}

stop_pidfile mock-smtp "local/mock-smtp.mjs"
stop_pidfile admin "plugins/admin/src/index.ts"
stop_pidfile web-ui "plugins/web-ui/server/index.ts"
stop_pidfile portal "plugins/portal/src/index.ts"
stop_pidfile auth "plugins/auth/src/index.ts"
stop_pidfile core "src/index.ts"

echo "[dev-down] postgres left running — stop it with: docker stop qm-auth-postgres"
