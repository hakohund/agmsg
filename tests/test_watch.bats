#!/usr/bin/env bats

# Regression tests for the watch.sh per-session watermark (#107): a Monitor
# restart must deliver messages that arrived during the restart gap, without
# re-delivering anything already streamed, while a fresh session still starts
# from "now" rather than replaying history.

load test_helper

setup() {
  setup_test_env
  export PROJ="/tmp/agmsg-watch-proj"
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
}

teardown() {
  teardown_test_env
}

# Run watch.sh in the background for <secs> seconds, capturing stdout to <out>.
# Returns once the watcher has been stopped.
run_watcher_for() {
  local sid="$1" out="$2" secs="$3"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code >"$out" 2>/dev/null &
  local pid=$!
  sleep "$secs"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

@test "watch: restart delivers messages that arrived while the watcher was down" {
  local sid="sess-restart"

  # First watcher: fresh session, takes its mark at MAX(id)=0, then streams M1.
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "$sid" "$PROJ" claude-code \
    >"$TEST_SKILL_DIR/out1.log" 2>/dev/null &
  local w1=$!
  sleep 1.5
  bash "$SCRIPTS/send.sh" team bob alice "M1-before-stop" >/dev/null
  sleep 2
  kill "$w1" 2>/dev/null || true
  wait "$w1" 2>/dev/null || true
  grep -q "M1-before-stop" "$TEST_SKILL_DIR/out1.log"

  # A message arrives while NO watcher is running for this session.
  bash "$SCRIPTS/send.sh" team bob alice "M2-in-gap" >/dev/null

  # Restart the SAME session_id — should resume from the persisted watermark.
  run_watcher_for "$sid" "$TEST_SKILL_DIR/out2.log" 2

  # In-gap message is delivered on restart...
  grep -q "M2-in-gap" "$TEST_SKILL_DIR/out2.log"
  # ...and the already-streamed message is NOT re-delivered.
  ! grep -q "M1-before-stop" "$TEST_SKILL_DIR/out2.log"
}

@test "watch: a fresh session starts from now and does not replay history" {
  # Pre-existing message before any watcher for this session ever runs.
  bash "$SCRIPTS/send.sh" team bob alice "M0-history" >/dev/null

  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "sess-fresh" "$PROJ" claude-code \
    >"$TEST_SKILL_DIR/fresh.log" 2>/dev/null &
  local w=$!
  sleep 1.5
  bash "$SCRIPTS/send.sh" team bob alice "M-live" >/dev/null
  sleep 2
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true

  # Live message after attach is delivered; pre-existing history is not replayed.
  grep -q "M-live" "$TEST_SKILL_DIR/fresh.log"
  ! grep -q "M0-history" "$TEST_SKILL_DIR/fresh.log"
}

@test "watch: persists a watermark file for the session" {
  run_watcher_for "sess-wm" "$TEST_SKILL_DIR/wm.log" 1.5
  [ -f "$TEST_SKILL_DIR/run/watch.sess-wm.watermark" ]
}

@test "session-end: removes the session watermark file" {
  local wm="$TEST_SKILL_DIR/run/watch.sess-end.watermark"
  mkdir -p "$TEST_SKILL_DIR/run"
  echo 5 > "$wm"
  printf '{"session_id":"sess-end"}' | bash "$SCRIPTS/session-end.sh" claude-code "$PROJ" >/dev/null 2>&1 || true
  [ ! -f "$wm" ]
}

@test "watch: actas-mode watcher creates a ready sentinel and removes it on exit" {
  local ready="$TEST_SKILL_DIR/run/ready.team__alice"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "sess-ready" "$PROJ" claude-code alice \
    >/dev/null 2>&1 &
  local w=$!
  # Wait for the watcher to attach and signal readiness.
  local i
  for i in 1 2 3 4 5 6 7 8 9 10; do
    [ -e "$ready" ] && break
    sleep 0.5
  done
  [ -e "$ready" ]
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true
  # Removed on exit (sentinel tracks a live watcher).
  [ ! -e "$ready" ]
}

@test "watch: a broad (non-actas) watcher does not create a ready sentinel" {
  bash "$SCRIPTS/join.sh" team bob claude-code "$PROJ" >/dev/null
  run_watcher_for "sess-broad" "$TEST_SKILL_DIR/broad.log" 1.5
  [ ! -e "$TEST_SKILL_DIR/run/ready.team__alice" ]
  [ ! -e "$TEST_SKILL_DIR/run/ready.team__bob" ]
}

@test "watch: ready sentinel records the owner session_id" {
  local ready="$TEST_SKILL_DIR/run/ready.team__alice"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "sess-own" "$PROJ" claude-code alice \
    >/dev/null 2>&1 &
  local w=$! i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$ready" ] && break; sleep 0.5; done
  [ "$(cat "$ready")" = "sess-own" ]
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true
}

@test "watch: cleanup leaves a sentinel that a successor session re-owned" {
  local ready="$TEST_SKILL_DIR/run/ready.team__alice"
  AGMSG_WATCH_INTERVAL=1 bash "$SCRIPTS/watch.sh" "sess-old" "$PROJ" claude-code alice \
    >/dev/null 2>&1 &
  local w=$! i
  for i in 1 2 3 4 5 6 7 8 9 10; do [ -e "$ready" ] && break; sleep 0.5; done
  # A successor watcher overwrites the sentinel with its own id.
  printf 'sess-new\n' > "$ready"
  kill "$w" 2>/dev/null || true
  wait "$w" 2>/dev/null || true
  # The old watcher must NOT delete the successor's live sentinel.
  [ -f "$ready" ]
  [ "$(cat "$ready")" = "sess-new" ]
}

@test "session-start: GCs stale watermark/ready but keeps live ones" {
  bash "$SCRIPTS/join.sh" team alice claude-code "$PROJ" >/dev/null
  mkdir -p "$TEST_SKILL_DIR/run"
  # Stale (owner has no live cc-instance).
  echo 5 > "$TEST_SKILL_DIR/run/watch.deadsid.watermark"
  echo deadsid > "$TEST_SKILL_DIR/run/ready.team__ghost"
  # Live owner.
  setup_live_owner "$TEST_SKILL_DIR/run" LIVESID
  echo 7 > "$TEST_SKILL_DIR/run/watch.LIVESID.watermark"
  echo LIVESID > "$TEST_SKILL_DIR/run/ready.team__live"

  printf '{"session_id":"somesess"}' \
    | bash "$SCRIPTS/session-start.sh" claude-code "$PROJ" >/dev/null 2>&1 || true

  [ ! -f "$TEST_SKILL_DIR/run/watch.deadsid.watermark" ]
  [ ! -f "$TEST_SKILL_DIR/run/ready.team__ghost" ]
  [ -f "$TEST_SKILL_DIR/run/watch.LIVESID.watermark" ]
  [ -f "$TEST_SKILL_DIR/run/ready.team__live" ]
}
