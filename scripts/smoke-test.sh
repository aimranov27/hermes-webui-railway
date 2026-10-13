#!/usr/bin/env bash
# Builds the image and checks what a template user depends on:
#   - the container starts and the WebUI answers on the Railway port
#   - the WebUI refuses to start without a password, and with one, nothing
#     but the login page is reachable without signing in
#   - the WebUI can reach the agent: the agent code imports in-process and
#     the gateway API answers on loopback with the shared key
#   - with no model key, chat fails with a clear error and the server stays up
#   - sessions and the login survive a restart (state lives on the volume)
# Used locally and by CI. Needs docker, curl, jq and openssl.
set -euo pipefail

cd "$(dirname "$0")/.."

PROJECT="hermes-smoke-$$"
export IMAGE="${IMAGE:-hermes-smoke-image:test}"
export HOST_PORT="${SMOKE_PORT:-39480}"
export HERMES_WEBUI_PASSWORD="smoke-$(openssl rand -hex 12)"
BASE="http://127.0.0.1:$HOST_PORT"
COOKIES="$(mktemp)"
compose() { docker compose -p "$PROJECT" "$@"; }

cleanup() {
  compose down -v --remove-orphans >/dev/null 2>&1 || true
  docker rm -f "$PROJECT-nopass" >/dev/null 2>&1 || true
  rm -f "$COOKIES"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  compose logs --no-color --tail 80 >&2 2>/dev/null || true
  exit 1
}

wait_healthy() {
  for _ in $(seq 1 180); do
    curl -fsS "$BASE/health" >/dev/null 2>&1 && return 0
    sleep 1
  done
  fail "the WebUI did not become healthy"
}

code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }

login() {
  rm -f "$COOKIES"
  jq -n --arg p "$1" '{password: $p}' \
    | curl -s -o /dev/null -w '%{http_code}' -c "$COOKIES" -X POST \
        -H 'Content-Type: application/json' --data @- "$BASE/api/auth/login"
}

api() { curl -fsS -b "$COOKIES" "$@"; }

if [ -z "${SKIP_BUILD:-}" ]; then
  compose build
fi

echo "== versions"
docker run --rm --entrypoint sh "$IMAGE" -c \
  'echo "Hermes Agent $HERMES_AGENT_VERSION, Hermes WebUI $HERMES_WEBUI_VERSION"; hermes --version 2>/dev/null | head -n 1'

echo "== refuses to start without a password"
docker run -d --name "$PROJECT-nopass" -e HERMES_WEBUI_PASSWORD= "$IMAGE" >/dev/null
for _ in $(seq 1 120); do
  [ "$(docker inspect -f '{{.State.Running}}' "$PROJECT-nopass")" = false ] && break
  sleep 1
done
[ "$(docker inspect -f '{{.State.Running}}' "$PROJECT-nopass")" = false ] \
  || fail "the container kept running without HERMES_WEBUI_PASSWORD"
[ "$(docker inspect -f '{{.State.ExitCode}}' "$PROJECT-nopass")" != 0 ] \
  || fail "the container exited successfully without HERMES_WEBUI_PASSWORD"
grep -q "HERMES_WEBUI_PASSWORD is not set" <<<"$(docker logs "$PROJECT-nopass" 2>&1)" \
  || fail "the missing-password error was not logged"
docker rm -f "$PROJECT-nopass" >/dev/null

echo "== first boot"
# Railway mounts an empty, root-owned volume with a lost+found directory.
# Start from the same instead of a volume Docker seeds from the image.
docker volume create --label com.docker.compose.project="$PROJECT" \
  --label com.docker.compose.volume=data "${PROJECT}_data" >/dev/null
docker run --rm --entrypoint sh -v "${PROJECT}_data:/v" "$IMAGE" \
  -c 'mkdir -p /v/lost+found && chown root:root /v && chmod 755 /v'
compose up -d
wait_healthy

echo "== the WebUI is protected"
[ "$(code "$BASE/")" = 302 ] || fail "/ did not redirect to the login page"
[ "$(code "$BASE/api/sessions")" = 401 ] || fail "/api/sessions was reachable without signing in"
[ "$(code "$BASE/api/health/agent")" = 401 ] || fail "/api/health/agent was reachable without signing in"
[ "$(code -X POST -H 'Content-Type: application/json' -d '{}' "$BASE/api/session/new")" = 401 ] \
  || fail "a session could be created without signing in"
grep -qi '<html' <<<"$(curl -fsS "$BASE/login")" || fail "the login page did not load"
[ "$(curl -fsS "$BASE/api/auth/status" | jq -r .password_auth_enabled)" = true ] \
  || fail "password auth is not enabled"
[ "$(login wrong-password-123)" = 401 ] || fail "a wrong password was not rejected"
[ "$(login "$HERMES_WEBUI_PASSWORD")" = 200 ] || fail "signing in with the configured password failed"
grep -qi '<html' <<<"$(api "$BASE/")" || fail "the WebUI did not load after signing in"
owners="$(compose exec -T hermes ps -eo user=,args= | awk '/server\.py|gateway run/ && !/awk/ {print $1}' | sort -u | tr -d ' \n')"
[ "$owners" = hermes ] || fail "the WebUI or gateway is not running as the unprivileged hermes user ($owners)"

echo "== the WebUI can reach the agent"
onboarding="$(api "$BASE/api/onboarding/status")"
[ "$(jq -r .system.hermes_found <<<"$onboarding")" = true ] || fail "the WebUI did not find Hermes Agent"
[ "$(jq -r .system.imports_ok <<<"$onboarding")" = true ] \
  || fail "the WebUI could not import Hermes Agent: $(jq -c .system.import_errors <<<"$onboarding")"
agent=""
for _ in $(seq 1 60); do
  agent="$(api "$BASE/api/health/agent" || true)"
  [ "$(jq -r '.details.gateway_state // empty' <<<"$agent" 2>/dev/null)" = running ] && break
  sleep 2
done
[ "$(jq -r .alive <<<"$agent")" = true ] || fail "the gateway is not alive: $agent"
[ "$(jq -r .details.gateway_state <<<"$agent")" = running ] \
  || fail "the WebUI could not read the gateway's detailed health with the API key: $agent"
# The gateway API must only listen on loopback (port 8642 = 0x21C2).
listeners="$(compose exec -T hermes sh -c "awk 'NR>1 && \$4==\"0A\" {print \$2}' /proc/net/tcp /proc/net/tcp6")"
gateway_listeners="$(grep -i ':21C2$' <<<"$listeners" || true)"
[ -n "$gateway_listeners" ] || fail "the gateway API is not listening"
if grep -qiv '^0100007F:\|^00000000000000000000000001000000:' <<<"$gateway_listeners"; then
  fail "the gateway API listens on a non-loopback address: $gateway_listeners"
fi

echo "== the WebUI can restart the gateway"
gateway_pid() { compose exec -T hermes sh -c 'cat /opt/data/gateway_state.json' | jq -r .pid; }
old_pid="$(gateway_pid)"
[ "$(api -X POST -H 'Content-Type: application/json' -d '{}' "$BASE/api/gateway/restart" | jq -r .ok)" = true ] \
  || fail "the gateway restart request failed"
new_pid="$old_pid"
for _ in $(seq 1 60); do
  new_pid="$(gateway_pid 2>/dev/null || true)"
  agent="$(api "$BASE/api/health/agent" || true)"
  if [ "$new_pid" != "$old_pid" ] && [ "$(jq -r '.details.gateway_state // empty' <<<"$agent" 2>/dev/null)" = running ]; then
    break
  fi
  sleep 2
done
[ "$new_pid" != "$old_pid" ] || fail "the gateway was not restarted (pid $old_pid)"
[ "$(jq -r .details.gateway_state <<<"$agent")" = running ] || fail "the gateway did not come back after a restart from the WebUI"

echo "== chat without a model key fails cleanly"
sid="$(api -X POST -H 'Content-Type: application/json' -d '{}' "$BASE/api/session/new" | jq -r .session.session_id)"
[ -n "$sid" ] && [ "$sid" != null ] || fail "could not create a session"
stream="$(jq -n --arg s "$sid" '{session_id: $s, message: "Say hello"}' \
  | api -X POST -H 'Content-Type: application/json' --data @- "$BASE/api/chat/start" | jq -r .stream_id)"
[ -n "$stream" ] && [ "$stream" != null ] || fail "could not start a chat"
events="$(curl -s -N -m 60 -b "$COOKIES" "$BASE/api/chat/stream?stream_id=$stream" || true)"
grep -q '^event: apperror' <<<"$events" || fail "chat without a model key did not return an error event: $events"
grep -qi 'provider' <<<"$events" || fail "the error does not explain that no provider is configured: $events"
[ "$(code "$BASE/health")" = 200 ] || fail "the WebUI is unhealthy after the failed chat"

echo "== restart keeps sessions and the login"
compose down
compose up -d
wait_healthy
[ "$(login "$HERMES_WEBUI_PASSWORD")" = 200 ] || fail "signing in failed after a restart"
grep -q "$sid" <<<"$(api "$BASE/api/sessions")" || fail "the session was lost after a restart"
for _ in $(seq 1 60); do
  agent="$(api "$BASE/api/health/agent" || true)"
  [ "$(jq -r '.details.gateway_state // empty' <<<"$agent" 2>/dev/null)" = running ] && break
  sleep 2
done
[ "$(jq -r .details.gateway_state <<<"$agent")" = running ] || fail "the gateway did not come back after a restart: $agent"

echo "PASS"
