#!/usr/bin/env bats

load test_helper

setup() {
  setup_test_env
  export TEST_PROJECT="$(mktemp -d)"
  bash "$SCRIPTS/join.sh" team alice codex "$TEST_PROJECT" >/dev/null
  bash "$SCRIPTS/join.sh" team bob codex "$TEST_PROJECT" >/dev/null
}

teardown() {
  teardown_test_env
  rm -rf "$TEST_PROJECT"
}

db_path() {
  printf '%s/db/messages.db\n' "$TEST_SKILL_DIR"
}

unread_count_for() {
  local agent="$1"
  sqlite3 "$(db_path)" "SELECT count(*) FROM messages WHERE team='team' AND to_agent='$agent' AND read_at IS NULL;"
}

marker_mtime() {
  local marker="$1"
  if [ "$(uname)" = "Darwin" ]; then
    stat -f %m "$marker"
  else
    stat -c %Y "$marker"
  fi
}

@test "codex-longpoll: delivers existing unread message and marks it read" {
  bash "$SCRIPTS/send.sh" team bob alice "hello longpoll" >/dev/null

  run env AGMSG_CODEX_LONGPOLL_WAIT_SECONDS=3 AGMSG_CODEX_LONGPOLL_INTERVAL=1 \
    bash "$SCRIPTS/codex-longpoll.sh" codex "$TEST_PROJECT"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "\"decision\": \"block\"" ]]
  [[ "$output" =~ "hello longpoll" ]]
  [ "$(unread_count_for alice)" = "0" ]
}

@test "codex-longpoll: delivers special characters as valid block JSON only" {
  local message=$'quote " backslash \\ newline\n日本語'
  bash "$SCRIPTS/send.sh" team bob alice "$message" >/dev/null

  env AGMSG_CODEX_LONGPOLL_WAIT_SECONDS=3 AGMSG_CODEX_LONGPOLL_INTERVAL=1 \
    bash "$SCRIPTS/codex-longpoll.sh" codex "$TEST_PROJECT" \
    >"$TEST_SKILL_DIR/special.out" 2>"$TEST_SKILL_DIR/special.err"
  local rc=$?

  [ "$rc" -eq 0 ]
  [ ! -s "$TEST_SKILL_DIR/special.err" ]
  [ "$(sqlite3 :memory: "SELECT json_valid(readfile('$TEST_SKILL_DIR/special.out'));")" = "1" ]
  [ "$(sqlite3 :memory: "SELECT json_extract(readfile('$TEST_SKILL_DIR/special.out'), '\$.decision');")" = "block" ]
  sqlite3 :memory: "SELECT json_extract(readfile('$TEST_SKILL_DIR/special.out'), '\$.reason');" \
    | grep -Fq 'quote " backslash \ newline\n日本語'
}

@test "codex-longpoll: delivers message that arrives while waiting" {
  AGMSG_CODEX_LONGPOLL_WAIT_SECONDS=10 AGMSG_CODEX_LONGPOLL_INTERVAL=1 \
    bash "$SCRIPTS/codex-longpoll.sh" codex "$TEST_PROJECT" \
    >"$TEST_SKILL_DIR/longpoll.out" 2>"$TEST_SKILL_DIR/longpoll.err" &
  local pid=$!

  sleep 1
  bash "$SCRIPTS/send.sh" team bob alice "arrived during wait" >/dev/null

  local i
  for i in {1..30}; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.2
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    false
  fi
  wait "$pid"
  local rc=$?

  [ "$rc" -eq 0 ]
  grep -q "\"decision\": \"block\"" "$TEST_SKILL_DIR/longpoll.out"
  grep -q "arrived during wait" "$TEST_SKILL_DIR/longpoll.out"
}

@test "codex-longpoll: timeout exits zero with empty stdout" {
  run env AGMSG_CODEX_LONGPOLL_WAIT_SECONDS=1 AGMSG_CODEX_LONGPOLL_INTERVAL=1 \
    bash "$SCRIPTS/codex-longpoll.sh" codex "$TEST_PROJECT"

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
}

@test "codex-longpoll: stop_hook_active input still delivers via forced check-inbox" {
  bash "$SCRIPTS/send.sh" team bob alice "stop hook active delivery" >/dev/null

  run bash -c "printf '%s' '{\"stop_hook_active\":true,\"session_id\":\"test-session\"}' | AGMSG_CODEX_LONGPOLL_WAIT_SECONDS=3 AGMSG_CODEX_LONGPOLL_INTERVAL=1 bash '$SCRIPTS/codex-longpoll.sh' codex '$TEST_PROJECT'"

  [ "$status" -eq 0 ]
  [[ "$output" =~ "\"decision\": \"block\"" ]]
  [[ "$output" =~ "stop hook active delivery" ]]
}

@test "check-inbox: stop_hook_active remains silent without force" {
  bash "$SCRIPTS/send.sh" team bob alice "not delivered without force" >/dev/null

  run bash -c "printf '%s' '{\"stop_hook_active\":true,\"session_id\":\"test-session\"}' | bash '$SCRIPTS/check-inbox.sh' codex '$TEST_PROJECT'"

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(unread_count_for alice)" = "1" ]
}

@test "check-inbox: force bypasses cooldown and strict force value is required" {
  mkdir -p "$TEST_SKILL_DIR/run"
  touch "$TEST_SKILL_DIR/run/.lastcheck-alice"
  bash "$SCRIPTS/send.sh" team bob alice "cooldown bypass" >/dev/null

  run bash -c "printf '{}' | bash '$SCRIPTS/check-inbox.sh' codex '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agmsg: check skipped (cooldown)" ]]
  [ "$(unread_count_for alice)" = "1" ]

  run bash -c "printf '{}' | AGMSG_CHECK_INBOX_FORCE=true bash '$SCRIPTS/check-inbox.sh' codex '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "agmsg: check skipped (cooldown)" ]]
  [ "$(unread_count_for alice)" = "1" ]

  run bash -c "printf '{}' | AGMSG_CHECK_INBOX_FORCE=1 bash '$SCRIPTS/check-inbox.sh' codex '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "\"decision\": \"block\"" ]]
  [[ "$output" =~ "cooldown bypass" ]]
  [ "$(unread_count_for alice)" = "0" ]
}

@test "check-inbox: force does not create or update cooldown marker" {
  local marker="$TEST_SKILL_DIR/run/.lastcheck-alice"
  bash "$SCRIPTS/send.sh" team bob alice "force without marker" >/dev/null

  run bash -c "printf '{}' | AGMSG_CHECK_INBOX_FORCE=1 bash '$SCRIPTS/check-inbox.sh' codex '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "\"decision\": \"block\"" ]]
  [ ! -f "$marker" ]

  mkdir -p "$TEST_SKILL_DIR/run"
  touch -t 200001010000 "$marker"
  local before
  before=$(marker_mtime "$marker")
  bash "$SCRIPTS/send.sh" team bob alice "force with marker" >/dev/null

  run bash -c "printf '{}' | AGMSG_CHECK_INBOX_FORCE=1 bash '$SCRIPTS/check-inbox.sh' codex '$TEST_PROJECT'"
  [ "$status" -eq 0 ]
  [[ "$output" =~ "\"decision\": \"block\"" ]]
  [ "$(marker_mtime "$marker")" = "$before" ]
}

@test "codex-longpoll: race after pending does not emit non-block JSON" {
  cat >"$SCRIPTS/watch-once.sh" <<'EOF'
#!/usr/bin/env bash
count=$(cat "$AGMSG_RACE_COUNT" 2>/dev/null || echo 0)
count=$((count + 1))
echo "$count" > "$AGMSG_RACE_COUNT"
if [ "$count" -eq 1 ]; then
  exit 0
fi
exit 2
EOF
  chmod +x "$SCRIPTS/watch-once.sh"
  cat >"$SCRIPTS/check-inbox.sh" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null || true
printf '{"continue":true}\n'
EOF
  chmod +x "$SCRIPTS/check-inbox.sh"

  run env AGMSG_RACE_COUNT="$TEST_SKILL_DIR/race-count" \
    AGMSG_CODEX_LONGPOLL_WAIT_SECONDS=3 AGMSG_CODEX_LONGPOLL_INTERVAL=1 \
    bash "$SCRIPTS/codex-longpoll.sh" codex "$TEST_PROJECT"

  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  [ "$(cat "$TEST_SKILL_DIR/race-count")" = "2" ]
}

@test "codex-longpoll: watch-once error exits zero with empty stdout" {
  cat >"$SCRIPTS/watch-once.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
  chmod +x "$SCRIPTS/watch-once.sh"

  AGMSG_CODEX_LONGPOLL_WAIT_SECONDS=3 AGMSG_CODEX_LONGPOLL_INTERVAL=1 \
    bash "$SCRIPTS/codex-longpoll.sh" codex "$TEST_PROJECT" \
    >"$TEST_SKILL_DIR/watch-error.out" 2>"$TEST_SKILL_DIR/watch-error.err"
  local rc=$?

  [ "$rc" -eq 0 ]
  [ ! -s "$TEST_SKILL_DIR/watch-error.out" ]
  grep -q "watch-once failed: rc=1" "$TEST_SKILL_DIR/watch-error.err"
}

@test "codex-longpoll: cleans watch-once and descendant sleep on SIGTERM" {
  cat >"$SCRIPTS/watch-once.sh" <<'EOF'
#!/usr/bin/env bash
echo "$$" > "$AGMSG_WATCH_STUB_PID"
sleep 30 &
echo "$!" > "$AGMSG_SLEEP_STUB_PID"
wait "$!"
EOF
  chmod +x "$SCRIPTS/watch-once.sh"

  AGMSG_WATCH_STUB_PID="$TEST_SKILL_DIR/watch-stub.pid" \
  AGMSG_SLEEP_STUB_PID="$TEST_SKILL_DIR/sleep-stub.pid" \
  AGMSG_CODEX_LONGPOLL_WAIT_SECONDS=30 AGMSG_CODEX_LONGPOLL_INTERVAL=10 \
    bash "$SCRIPTS/codex-longpoll.sh" codex "$TEST_PROJECT" \
    >"$TEST_SKILL_DIR/sigterm.out" 2>"$TEST_SKILL_DIR/sigterm.err" &
  local pid=$!

  local i
  for i in {1..20}; do
    [ -f "$TEST_SKILL_DIR/watch-stub.pid" ] && [ -f "$TEST_SKILL_DIR/sleep-stub.pid" ] && break
    sleep 0.1
  done
  [ -f "$TEST_SKILL_DIR/watch-stub.pid" ]
  [ -f "$TEST_SKILL_DIR/sleep-stub.pid" ]

  local watch_pid sleep_pid
  watch_pid=$(cat "$TEST_SKILL_DIR/watch-stub.pid")
  sleep_pid=$(cat "$TEST_SKILL_DIR/sleep-stub.pid")

  kill -TERM "$pid"
  wait "$pid" 2>/dev/null || true
  sleep 0.5

  ! kill -0 "$pid" 2>/dev/null
  ! kill -0 "$watch_pid" 2>/dev/null
  ! kill -0 "$sleep_pid" 2>/dev/null
}

@test "codex-longpoll: guarded child exits when wrapper is killed without traps" {
  cat >"$SCRIPTS/watch-once.sh" <<'EOF'
#!/usr/bin/env bash
echo "$$" > "$AGMSG_WATCH_STUB_PID"
sleep 30 &
echo "$!" > "$AGMSG_SLEEP_STUB_PID"
wait "$!"
EOF
  chmod +x "$SCRIPTS/watch-once.sh"

  AGMSG_WATCH_STUB_PID="$TEST_SKILL_DIR/watch-kill-stub.pid" \
  AGMSG_SLEEP_STUB_PID="$TEST_SKILL_DIR/sleep-kill-stub.pid" \
  AGMSG_CODEX_LONGPOLL_WAIT_SECONDS=30 AGMSG_CODEX_LONGPOLL_INTERVAL=10 \
    bash "$SCRIPTS/codex-longpoll.sh" codex "$TEST_PROJECT" \
    >"$TEST_SKILL_DIR/sigkill.out" 2>"$TEST_SKILL_DIR/sigkill.err" &
  local pid=$!

  local i
  for i in {1..20}; do
    [ -f "$TEST_SKILL_DIR/watch-kill-stub.pid" ] && [ -f "$TEST_SKILL_DIR/sleep-kill-stub.pid" ] && break
    sleep 0.1
  done
  [ -f "$TEST_SKILL_DIR/watch-kill-stub.pid" ]
  [ -f "$TEST_SKILL_DIR/sleep-kill-stub.pid" ]

  local watch_pid sleep_pid
  watch_pid=$(cat "$TEST_SKILL_DIR/watch-kill-stub.pid")
  sleep_pid=$(cat "$TEST_SKILL_DIR/sleep-kill-stub.pid")

  kill -KILL "$pid"
  wait "$pid" 2>/dev/null || true
  sleep 2

  ! kill -0 "$pid" 2>/dev/null
  ! kill -0 "$watch_pid" 2>/dev/null
  ! kill -0 "$sleep_pid" 2>/dev/null
}

@test "codex-longpoll: chooses same first identity and clamps wait settings" {
  cat >"$SCRIPTS/watch-once.sh" <<'EOF'
#!/usr/bin/env bash
timeout=""
interval=""
name=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --timeout) timeout="$2"; shift 2 ;;
    --interval) interval="$2"; shift 2 ;;
    --name) name="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf 'name=%s timeout=%s interval=%s\n' "$name" "$timeout" "$interval" >> "$AGMSG_ARGS_LOG"
exit 2
EOF
  chmod +x "$SCRIPTS/watch-once.sh"

  run env AGMSG_ARGS_LOG="$TEST_SKILL_DIR/args.log" \
    AGMSG_CODEX_LONGPOLL_WAIT_SECONDS=999999 AGMSG_CODEX_LONGPOLL_INTERVAL=99 \
    bash "$SCRIPTS/codex-longpoll.sh" codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  [ "$output" = "" ]
  grep -q "name=alice timeout=86400 interval=60" "$TEST_SKILL_DIR/args.log"

  : > "$TEST_SKILL_DIR/args.log"
  run env AGMSG_ARGS_LOG="$TEST_SKILL_DIR/args.log" \
    AGMSG_CODEX_LONGPOLL_WAIT_SECONDS=0 AGMSG_CODEX_LONGPOLL_INTERVAL=0 \
    bash "$SCRIPTS/codex-longpoll.sh" codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  grep -q "name=alice timeout=1 interval=1" "$TEST_SKILL_DIR/args.log"

  : > "$TEST_SKILL_DIR/args.log"
  run env AGMSG_ARGS_LOG="$TEST_SKILL_DIR/args.log" \
    AGMSG_CODEX_LONGPOLL_WAIT_SECONDS=abc AGMSG_CODEX_LONGPOLL_INTERVAL=abc \
    bash "$SCRIPTS/codex-longpoll.sh" codex "$TEST_PROJECT"
  [ "$status" -eq 0 ]
  grep -q "name=alice timeout=28800 interval=5" "$TEST_SKILL_DIR/args.log"
}
