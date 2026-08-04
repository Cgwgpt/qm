#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"
log_dir="$root/local"
mkdir -p "$log_dir"

unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL ANTHROPIC_MODEL
unset PI_MODEL OPENCODE_MODEL CLAUDE_MODEL OPENAI_API_KEY OPENROUTER_API_KEY

port_up() { (exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null; }

proc_matches() {
  local pid="$1" marker="$2"
  ps -p "$pid" -o command= 2>/dev/null | grep -qF "$marker"
}

docker info >/dev/null 2>&1 || { echo "[dev-up] docker daemon not reachable" >&2; exit 1; }

require_env() {
  if [ ! -f "$1" ]; then
    echo "[dev-up] missing $1 — see README.zh-CN 本地快速启动 (config .env 与各插件 .env)" >&2
    exit 1
  fi
}

require_env .env
require_env plugins/auth/.env
require_env plugins/portal/.env
require_env plugins/web-ui/.env
require_env plugins/admin/.env

if [ ! -d plugins/web-ui/dist-web ]; then
  echo "[dev-up] building web-ui..."
  (cd plugins/web-ui && npm run build)
fi

if ! docker ps -a --format '{{.Names}}' | grep -qx qm-auth-postgres; then
  echo "[dev-up] creating postgres container..."
  docker run -d --name qm-auth-postgres \
    -e POSTGRES_DB=qm -e POSTGRES_HOST_AUTH_METHOD=trust \
    -p 5432:5432 --restart unless-stopped \
    -v qm-auth-postgres-data:/var/lib/postgresql/data postgres:16-alpine >/dev/null
elif ! docker ps --format '{{.Names}}' | grep -qx qm-auth-postgres; then
  echo "[dev-up] starting postgres container..."
  docker start qm-auth-postgres >/dev/null
fi

echo "[dev-up] waiting for postgres..."
pg_ok=0
for _ in $(seq 1 30); do
  if docker exec qm-auth-postgres pg_isready -U postgres >/dev/null 2>&1; then
    pg_ok=1
    break
  fi
  sleep 1
done
if [ "$pg_ok" -ne 1 ]; then
  echo "[dev-up] postgres not ready — check: docker logs qm-auth-postgres" >&2
  exit 1
fi

if ! docker image inspect qm-sandbox-local:latest >/dev/null 2>&1; then
  echo "[dev-up] warning: sandbox image missing — run: bash scripts/local-sandbox-build.sh" >&2
fi

start_service() {
  local name="$1" port="$2" marker="$3"
  shift 3
  local pidfile="$log_dir/$name.pid"
  if port_up "$port"; then
    echo "[dev-up] $name already up on :$port"
    return 0
  fi
  if [ -f "$pidfile" ]; then
    local old_pid
    old_pid=$(cat "$pidfile")
    if kill -0 "$old_pid" 2>/dev/null && proc_matches "$old_pid" "$marker"; then
      echo "[dev-up] $name already running (pid $old_pid)"
      return 0
    fi
    rm -f "$pidfile"
  fi
  nohup "$@" > "$log_dir/$name.log" 2>&1 &
  echo $! > "$pidfile"
  echo "[dev-up] started $name on :$port (pid $!)"
}

if [ -f "$log_dir/mock-smtp.pid" ] && kill -0 "$(cat "$log_dir/mock-smtp.pid")" 2>/dev/null && proc_matches "$(cat "$log_dir/mock-smtp.pid")" "local/mock-smtp.mjs"; then
  echo "[dev-up] mock-smtp already running (pid $(cat "$log_dir/mock-smtp.pid"))"
elif port_up 2525; then
  echo "[dev-up] mock-smtp already up on :2525"
else
  rm -f "$log_dir/mock-smtp.pid"
  nohup node local/mock-smtp.mjs > "$log_dir/mock-smtp-run.log" 2>&1 &
  echo $! > "$log_dir/mock-smtp.pid"
  echo "[dev-up] started mock-smtp on :2525 (pid $!)"
fi

start_service core 8080 "src/index.ts" node --env-file-if-exists=.env src/index.ts
start_service auth 8099 "plugins/auth/src/index.ts" node --env-file-if-exists=plugins/auth/.env plugins/auth/src/index.ts
start_service portal 8097 "plugins/portal/src/index.ts" node --env-file-if-exists=plugins/portal/.env plugins/portal/src/index.ts
start_service web-ui 8096 "plugins/web-ui/server/index.ts" node --env-file-if-exists=plugins/web-ui/.env plugins/web-ui/server/index.ts
start_service admin 8090 "plugins/admin/src/index.ts" node --env-file-if-exists=plugins/admin/.env plugins/admin/src/index.ts

echo "[dev-up] waiting for services..."
for _ in $(seq 1 90); do
  ok=1
  for p in 8080 8099 8097 8096 8090; do
    if ! port_up "$p"; then ok=0; break; fi
  done
  if [ "$ok" -eq 1 ]; then break; fi
  sleep 1
done

all_up=1
for p in 8080 8099 8097 8096 8090; do
  if ! port_up "$p"; then all_up=0; fi
done
if [ "$all_up" -ne 1 ]; then
  echo "[dev-up] some services did not come up — see local/*.log" >&2
  exit 1
fi
if curl -sf http://localhost:8080/healthz >/dev/null 2>&1; then
  echo "[dev-up] core healthy"
else
  echo "[dev-up] core healthz failed — see local/core.log" >&2
  exit 1
fi

echo
echo "QM 本地环境就绪"
echo "  Web UI / 登录: http://localhost:8097"
echo "  管理面板:      http://localhost:8097/admin"
echo "  魔法链接:      grep -o 'verify#token=[^ ]*' local/mock-smtp.log | tail -1"
echo "  日志:          local/{core,auth,portal,web-ui,admin,mock-smtp-run}.log"
echo "  停止:          bash scripts/dev-down.sh"
