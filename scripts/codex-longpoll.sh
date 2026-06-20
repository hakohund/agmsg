#!/usr/bin/env bash
set -euo pipefail

# Lightweight Codex Stop-hook waiter.
#
# Usage:
#   codex-longpoll.sh codex <project_path>
#
# It waits for unread agmsg messages via watch-once.sh and delegates message
# formatting/read-marking to check-inbox.sh. stdout is reserved for Codex hook
# control JSON; diagnostics must go to stderr.

TYPE="${1:-}"
PROJECT="${2:-}"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

if [ "$TYPE" != "codex" ] || [ -z "$PROJECT" ]; then
  echo "codex-longpoll: usage: codex-longpoll.sh codex <project_path>" >&2
  exit 0
fi

INPUT=""
if [ ! -t 0 ]; then
  INPUT="$(cat 2>/dev/null || true)"
fi

WAIT_SECONDS="${AGMSG_CODEX_LONGPOLL_WAIT_SECONDS:-28800}"
POLL_INTERVAL="${AGMSG_CODEX_LONGPOLL_INTERVAL:-5}"

case "$WAIT_SECONDS" in
  ''|*[!0-9]*) WAIT_SECONDS=28800 ;;
esac
case "$POLL_INTERVAL" in
  ''|*[!0-9]*) POLL_INTERVAL=5 ;;
esac

[ "$WAIT_SECONDS" -lt 1 ] && WAIT_SECONDS=1
[ "$WAIT_SECONDS" -gt 86400 ] && WAIT_SECONDS=86400
[ "$POLL_INTERVAL" -lt 1 ] && POLL_INTERVAL=1
[ "$POLL_INTERVAL" -gt 60 ] && POLL_INTERVAL=60

child_pid=""

children_of() {
  local pid="$1"
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -P "$pid" 2>/dev/null || true
  else
    ps -o pid= --ppid "$pid" 2>/dev/null || true
  fi
}

kill_tree() {
  local pid="$1"
  local child
  for child in $(children_of "$pid"); do
    kill_tree "$child"
  done
  kill "$pid" 2>/dev/null || true
}

cleanup() {
  if [ -n "$child_pid" ]; then
    if kill -0 "$child_pid" 2>/dev/null; then
      kill_tree "$child_pid"
    fi
    wait "$child_pid" 2>/dev/null || true
    child_pid=""
  fi
}

trap cleanup EXIT
trap 'cleanup; exit 0' HUP INT TERM

run_guarded_child() {
  local parent_pid="$$"
  (
    "$@" &
    local guarded_pid=$!
    (
      while kill -0 "$parent_pid" 2>/dev/null && kill -0 "$guarded_pid" 2>/dev/null; do
        sleep 1
      done
      if ! kill -0 "$parent_pid" 2>/dev/null && kill -0 "$guarded_pid" 2>/dev/null; then
        kill_tree "$guarded_pid"
      fi
    ) &
    local guard_pid=$!

    set +e
    wait "$guarded_pid"
    local guarded_rc=$?
    set -e

    kill "$guard_pid" 2>/dev/null || true
    wait "$guard_pid" 2>/dev/null || true
    exit "$guarded_rc"
  ) &
  child_pid=$!
}

WHOAMI="$("$SCRIPT_DIR/whoami.sh" "$PROJECT" "$TYPE" 2>/dev/null || true)"
if echo "$WHOAMI" | grep -q "not_joined=true"; then
  echo "codex-longpoll: no matching identity" >&2
  exit 0
fi

if echo "$WHOAMI" | grep -q "multiple=true"; then
  AGENT=$(echo "$WHOAMI" | sed -n 's/.*agents=\([^,]*\).*/\1/p')
else
  AGENT=$(echo "$WHOAMI" | sed -n 's/.*agent=\([^ ]*\).*/\1/p')
fi
TEAMS=$(echo "$WHOAMI" | sed -n 's/.*teams=\([^ ]*\).*/\1/p')

if [ -z "${AGENT:-}" ] || [ -z "${TEAMS:-}" ]; then
  echo "codex-longpoll: no matching identity" >&2
  exit 0
fi

started_at=$SECONDS

while (( SECONDS - started_at < WAIT_SECONDS )); do
  elapsed=$(( SECONDS - started_at ))
  remaining=$(( WAIT_SECONDS - elapsed ))
  [ "$remaining" -lt 1 ] && break

  run_guarded_child "$SCRIPT_DIR/watch-once.sh" \
    "$PROJECT" \
    "$TYPE" \
    --name "$AGENT" \
    --timeout "$remaining" \
    --interval "$POLL_INTERVAL" \
    >/dev/null

  set +e
  wait "$child_pid"
  watch_rc=$?
  set -e
  child_pid=""

  case "$watch_rc" in
    0)
      result="$(
        printf '%s' "$INPUT" |
          AGMSG_CHECK_INBOX_FORCE=1 \
          "$SCRIPT_DIR/check-inbox.sh" "$TYPE" "$PROJECT" \
          2>/dev/null || true
      )"

      if printf '%s' "$result" | grep -q '"decision"[[:space:]]*:[[:space:]]*"block"'; then
        printf '%s\n' "$result"
        exit 0
      fi

      elapsed=$(( SECONDS - started_at ))
      remaining=$(( WAIT_SECONDS - elapsed ))
      [ "$remaining" -lt 1 ] && break
      sleep_for="$POLL_INTERVAL"
      [ "$remaining" -lt "$sleep_for" ] && sleep_for="$remaining"
      [ "$sleep_for" -gt 0 ] || sleep_for=1
      run_guarded_child sleep "$sleep_for"
      set +e
      wait "$child_pid"
      set -e
      child_pid=""
      ;;
    2)
      exit 0
      ;;
    *)
      echo "codex-longpoll: watch-once failed: rc=$watch_rc" >&2
      exit 0
      ;;
  esac
done

exit 0
