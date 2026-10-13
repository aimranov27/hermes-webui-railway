#!/bin/bash
# Starts the Hermes gateway and Hermes WebUI side by side.
#
# The upstream entrypoint has already prepared the volume, seeded config.yaml
# and .env, and dropped to the unprivileged hermes user before this runs.
#
# - The gateway runs cron jobs, connects messaging apps and serves the Hermes
#   API on 127.0.0.1:8642 only. Upstream's s6 supervisor keeps it running.
# - The WebUI is the public process on $PORT. If it exits, the container
#   exits and Railway restarts it.
set -euo pipefail

log() { echo "[railway] $*"; }

export HERMES_HOME="${HERMES_HOME:-/opt/data}"
export HOME="$HERMES_HOME"
cd "$HERMES_HOME"

# The WebUI has no login unless a password is set. A public URL without one
# would let anyone run commands on the server, so refuse to start.
if [ -z "${HERMES_WEBUI_PASSWORD:-}" ]; then
  log "ERROR: HERMES_WEBUI_PASSWORD is not set."
  log "ERROR: Without it anyone who finds this URL controls the agent, so the WebUI will not start."
  log "ERROR: Add HERMES_WEBUI_PASSWORD in the service's Variables tab and redeploy."
  exit 1
fi
if [ "${#HERMES_WEBUI_PASSWORD}" -lt 12 ]; then
  log "ERROR: HERMES_WEBUI_PASSWORD must be at least 12 characters."
  exit 1
fi

# The gateway API key. Upstream generates one into $HERMES_HOME/.env on first
# boot, and that file wins over the environment, so read it from there.
env_key="$(sed -n 's/^API_SERVER_KEY=//p' "$HERMES_HOME/.env" 2>/dev/null | tail -n 1 | tr -d "\"'")"
api_key="${env_key:-${API_SERVER_KEY:-}}"
export HERMES_API_URL="http://127.0.0.1:8642"
if [ -n "$api_key" ]; then
  export HERMES_WEBUI_GATEWAY_API_KEY="$api_key"
fi

# Railway serves the public URL over HTTPS, so mark the login cookie Secure.
if [ -n "${RAILWAY_ENVIRONMENT_ID:-}" ] && [ -z "${HERMES_WEBUI_SECURE:-}" ]; then
  export HERMES_WEBUI_SECURE=1
fi

export HERMES_WEBUI_HOST="${HERMES_WEBUI_HOST:-0.0.0.0}"
export HERMES_WEBUI_PORT="${PORT:-8080}"
mkdir -p "$HERMES_WEBUI_STATE_DIR" "$HERMES_WEBUI_DEFAULT_WORKSPACE"

# This install is updated by redeploying the template, not from inside the
# app. Turn off the WebUI's own update check on first boot.
settings="$HERMES_WEBUI_STATE_DIR/settings.json"
if [ ! -e "$settings" ]; then
  (umask 077 && printf '{"check_for_updates": false}\n' > "$settings")
fi

bg_pids=()
webui_pid=""
stopping=""

# Fallback for runtimes where the image does not own PID 1 and s6 is not
# running: keep a foreground gateway alive with a small restart loop.
run_gateway_loop() {
  local delay=2
  while true; do
    local started=$SECONDS
    hermes gateway run --no-supervise --external-supervisor || true
    if [ $((SECONDS - started)) -gt 60 ]; then delay=2; else delay=$((delay < 60 ? delay * 2 : 60)); fi
    log "Gateway exited. Restarting in ${delay}s."
    sleep "$delay"
  done
}

shutdown() {
  [ -n "$stopping" ] && return 0
  stopping=1
  log "Stopping"
  if [ -n "$webui_pid" ]; then kill -TERM "$webui_pid" 2>/dev/null || true; fi
  local pid children
  for pid in "${bg_pids[@]}"; do
    children="$(pgrep -P "$pid" || true)"
    kill -TERM "$pid" 2>/dev/null || true
    if [ -n "$children" ]; then kill -TERM $children 2>/dev/null || true; fi
  done
}
trap shutdown TERM INT

if [ "${HERMES_GATEWAY:-on}" = "off" ]; then
  log "HERMES_GATEWAY=off: scheduled jobs and messaging apps are disabled"
elif [ "$(cat /proc/1/comm 2>/dev/null)" = "s6-svscan" ]; then
  # s6 restarts the gateway if it crashes, the WebUI's "restart gateway"
  # button works through it, and its output goes to the Railway logs and to
  # $HERMES_HOME/logs/gateways/default.
  log "Starting Hermes gateway ${HERMES_AGENT_VERSION:-} under s6 supervision"
  if ! hermes gateway start; then
    # Keep the WebUI available even if the supervisor can't start the gateway.
    log "WARNING: s6 could not start the gateway. Running it in the foreground instead."
    run_gateway_loop &
    bg_pids+=($!)
  fi
else
  log "Starting Hermes gateway ${HERMES_AGENT_VERSION:-} in the foreground (s6 is not PID 1)"
  run_gateway_loop &
  bg_pids+=($!)
fi

log "Starting Hermes WebUI ${HERMES_WEBUI_VERSION:-} on port $HERMES_WEBUI_PORT"
cd /opt/hermes-webui
"$HERMES_WEBUI_PYTHON" server.py &
webui_pid=$!

status=0
wait "$webui_pid" || status=$?
shutdown
exit "$status"
