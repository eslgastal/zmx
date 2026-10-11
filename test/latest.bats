#!/usr/bin/env bats
load test_helper

# A long-running task copies arbitrary bytes from a FIFO to its PTY. Unlike
# zmx send, the bytes are not echoed as shell input before the task prints them.
start_latest() {
  local name="$1" script="$BATS_TEST_TMPDIR/producer-$1" fifo="$BATS_TEST_TMPDIR/fifo-$1"
  mkfifo "$fifo"
  printf '#!/bin/sh\nwhile :; do cat "%s"; done\n' "$fifo" > "$script"
  chmod +x "$script"
  "$ZMX" run "$name" -d "$script" >/dev/null
  wait_for_session "$name"
  # Let the shell start the FIFO reader; script paths may wrap in history.
  sleep 0.3
  FIFO="$fifo"
}

@test 'latest: bootstraps once, and subsequent calls consume completed lines' {
  start_latest latest-basic
  run "$ZMX" history --latest --wait-lines 5 --timeout 1 latest-basic
  [ "$status" -eq 0 ]
  [[ "$output" == '[Latest history initialized: showing up to the last 20 existing lines. Future --latest calls return only new lines.]'* ]]

  exec 9>"$FIFO"
  printf 'first\r\nsecond\r\npartial' >&9
  wait_for_output latest-basic second
  run "$ZMX" history --latest latest-basic
  [ "$status" -eq 0 ]
  [[ "$output" == *'[Latest history: 2 new lines.]'* ]]
  [[ "$output" == *$'first\nsecond'* ]]
  [[ "$output" != *partial* ]]
  run "$ZMX" history --latest latest-basic
  [ "$output" = '[Latest history: no new lines.]' ]
  printf ' end\r\n' >&9
  run "$ZMX" history --latest --wait-lines --timeout 2 latest-basic
  [ "$output" == $'[Latest history: 1 new lines.]\n\npartial end' ]
  exec 9>&-
}

@test 'latest: wait is asynchronous and timeout consumes partial progress' {
  start_latest latest-wait
  "$ZMX" history --latest latest-wait >/dev/null
  exec 9>"$FIFO"
  "$ZMX" history --latest --wait-lines 3 --timeout 2 latest-wait >"$BATS_TEST_TMPDIR/reply" &
  local waiter=$!
  sleep 0.2
  # A different client can still get history while this one is waiting.
  run "$ZMX" history latest-wait
  [ "$status" -eq 0 ]
  printf 'one\r\ntwo\r\n' >&9
  wait "$waiter"
  local reply
  reply=$(<"$BATS_TEST_TMPDIR/reply")
  [[ "$reply" == *'[Latest history: 2 new lines; timed out waiting for 3.]'* ]]
  [[ "$reply" == *$'one\ntwo'* ]]
  run "$ZMX" history --latest latest-wait
  [ "$output" = '[Latest history: no new lines.]' ]
  exec 9>&-
}

@test 'latest: escape sequences and alternate screen are excluded' {
  start_latest latest-vt
  "$ZMX" history --latest latest-vt >/dev/null
  exec 9>"$FIFO"
  printf '\033[?1049hhidden\r\n\033[?1049l\033[31mvisible\033[0m\r\n' >&9
  run "$ZMX" history --latest --wait-lines --timeout 2 latest-vt
  [ "$status" -eq 0 ]
  [[ "$output" == *visible* ]]
  [[ "$output" != *hidden* ]]
  [[ "$output" != *$'\033'* ]]
  exec 9>&-
}

@test 'latest: alternate screen defers first-call bootstrap and ignores wait' {
  start_latest latest-alt-first
  exec 9>"$FIFO"
  printf '\033[?1049hhidden\r\n' >&9
  wait_for_output latest-alt-first hidden
  local start=$SECONDS
  run "$ZMX" history --latest --wait-lines 5 --timeout 3 latest-alt-first
  [ "$status" -eq 0 ]
  [ "$output" = '[Latest history: alternate screen active; output not tracked. Use zmx history latest-alt-first for a non-incremental snapshot.]' ]
  [ "$((SECONDS - start))" -le 1 ]
  printf '\033[?1049l' >&9
  # Wait for the daemon to process the screen switch.
  local i
  for i in {1..30}; do
    if ! "$ZMX" history latest-alt-first | grep -q hidden; then break; fi
    sleep 0.1
  done
  run "$ZMX" history --latest latest-alt-first
  [ "$status" -eq 0 ]
  [[ "$output" == '[Latest history initialized: showing up to the last 20 existing lines. Future --latest calls return only new lines.]'* ]]
  [[ "$output" != *hidden* ]]
  exec 9>&-
}

@test 'latest: alternate screen returns queued primary lines before wait target' {
  start_latest latest-alt-queued
  "$ZMX" history --latest latest-alt-queued >/dev/null
  exec 9>"$FIFO"
  printf 'queued\r\n\033[?1049hhidden\r\n' >&9
  wait_for_output latest-alt-queued hidden
  run "$ZMX" history --latest --wait-lines 5 --timeout 2 latest-alt-queued
  [ "$status" -eq 0 ]
  [ "$output" == $'[Latest history: 1 new lines; alternate screen active; output not tracked. Use zmx history latest-alt-queued for a non-incremental snapshot.]\n\nqueued' ]
  run "$ZMX" history --latest latest-alt-queued
  [ "$output" = '[Latest history: alternate screen active; output not tracked. Use zmx history latest-alt-queued for a non-incremental snapshot.]' ]
  printf '\033[?1049l' >&9
  exec 9>&-
}

@test 'latest: alternate screen interrupts a pending wait and returns partial progress' {
  start_latest latest-alt-pending
  "$ZMX" history --latest latest-alt-pending >/dev/null
  exec 9>"$FIFO"
  "$ZMX" history --latest --wait-lines 3 --timeout 4 latest-alt-pending >"$BATS_TEST_TMPDIR/alt-reply" &
  local waiter=$!
  sleep 0.2
  printf 'first\r\nsecond\r\n\033[?1049hhidden\r\n' >&9
  wait_for_output latest-alt-pending hidden
  wait "$waiter"
  local reply
  reply=$(<"$BATS_TEST_TMPDIR/alt-reply")
  [ "$reply" == $'[Latest history: 2 new lines; alternate screen active; output not tracked. Use zmx history latest-alt-pending for a non-incremental snapshot.]\n\nfirst\nsecond' ]
  printf '\033[?1049l' >&9
  exec 9>&-
}

@test 'latest: soft wraps and split ANSI sequences still yield one plain logical line' {
  start_latest latest-wrap
  "$ZMX" history --latest latest-wrap >/dev/null
  exec 9>"$FIFO"
  local long
  long=$(printf '%0140d' 0)
  printf '\033[3' >&9
  sleep 0.1
  printf '1m%s\033[0m\r\n' "$long" >&9
  run "$ZMX" history --latest --wait-lines --timeout 2 latest-wrap
  [ "$status" -eq 0 ]
  [[ "$output" == *'[Latest history: 1 new lines.]'* ]]
  [[ "$output" == *"$long"* ]]
  [[ "$output" != *$'\033'* ]]
  exec 9>&-
}

@test 'latest: bootstrap shows exactly the final 20 plain history lines' {
  start_latest latest-boot20
  exec 9>"$FIFO"
  for i in $(seq 1 25); do printf 'boot-%02d\r\n' "$i" >&9; done
  wait_for_output latest-boot20 boot-25
  local expected full bootstrap
  full=$("$ZMX" history latest-boot20)
  expected=$(printf '%s\n' "$full" | tail -20)
  bootstrap=$("$ZMX" history --latest latest-boot20)
  [ "${bootstrap#*$'\n\n'}" = "$expected" ]
  run "$ZMX" history --latest latest-boot20
  [ "$output" = '[Latest history: no new lines.]' ]
  exec 9>&-
}

@test 'latest: successful wait returns all available lines and does not block the daemon' {
  start_latest latest-success
  "$ZMX" history --latest latest-success >/dev/null
  exec 9>"$FIFO"
  "$ZMX" history --latest --wait-lines 2 --timeout 3 latest-success >"$BATS_TEST_TMPDIR/success" &
  local waiter=$!
  sleep 0.2
  printf 'alpha\r\nbeta\r\ngamma\r\n' >&9
  wait "$waiter"
  local reply
  reply=$(<"$BATS_TEST_TMPDIR/success")
  [[ "$reply" == *'[Latest history: 3 new lines.]'* ]]
  [[ "$reply" != *'wait condition satisfied'* ]]
  exec 9>&-
}

@test 'latest: zero-line timeout has the requested count in its notice' {
  start_latest latest-empty
  "$ZMX" history --latest latest-empty >/dev/null
  run "$ZMX" history --latest --wait-lines 2 --timeout 1 latest-empty
  [ "$status" -eq 0 ]
  [ "$output" = '[Latest history: no new lines; timed out waiting for 2.]' ]
}

@test 'latest: default wait timeout is five seconds; available lines return immediately' {
  start_latest latest-default
  "$ZMX" history --latest latest-default >/dev/null
  local start=$SECONDS
  run "$ZMX" history --latest --wait-lines latest-default
  [ "$output" = '[Latest history: no new lines; timed out waiting for 1.]' ]
  [ "$((SECONDS - start))" -ge 4 ]
  [ "$((SECONDS - start))" -le 7 ]
  printf 'ready\r\n' >"$FIFO"
  wait_for_output latest-default ready
  start=$SECONDS
  run "$ZMX" history --latest --wait-lines 1 latest-default
  [ "$output" == $'[Latest history: 1 new lines.]\n\nready' ]
  [ "$((SECONDS - start))" -le 1 ]
}

@test 'latest: validates options' {
  for option in '--latest --vt' '--latest --html' '--latest --screen' '--latest --scrollback 4' '--latest --timeout 1' '--latest --wait-lines 0' '--latest --wait-lines -1' '--latest --wait-lines 4294967296' '--latest --wait-lines --timeout 0' '--latest --wait-lines --timeout NaN' '--latest --wait-lines --timeout -2' '--latest --wait example'; do
    # Intentional word splitting of the fixed option strings above.
    run "$ZMX" history $option example
    [ "$status" -ne 0 ]
    [[ "$output" == *error:* ]]
  done
  run "$ZMX" history --latest --wait-lines --timeout
  [ "$status" -ne 0 ]
  [[ "$output" == *'--timeout requires seconds'* ]]
  run "$ZMX" history --latest --wait example
  [ "$status" -ne 0 ]
  [[ "$output" == *'unknown history option: --wait'* ]]
}
