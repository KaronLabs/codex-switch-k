#!/usr/bin/env bats

setup() {
  export CODEX_SWITCH=${CODEX_SWITCH:-"$BATS_TEST_DIRNAME/../codex-switch"}
  export TEST_ROOT
  TEST_ROOT=$(mktemp -d)
  export CODEX_ACCOUNT_ROOT="$TEST_ROOT/accounts"
  export CODEX_SHARED_HOME="$TEST_ROOT/shared"
  export CODEX_BIN="$TEST_ROOT/fake-codex"
  export BWRAP_BIN=/usr/bin/bwrap
  export SUDO_BIN="$TEST_ROOT/fake-sudo"
  export ADMIN_RUNNER_BIN="$TEST_ROOT/fake-admin-runner"
  export SUDO_TRACE="$TEST_ROOT/sudo-trace"
  export ADMIN_TRACE="$TEST_ROOT/admin-trace"
  export TRACE_FILE="$TEST_ROOT/trace"
  export FAKE_RPC_TRACE="$TEST_ROOT/rpc-trace"
  export CODEX_SWITCH_PROCESS_CHECK="$TEST_ROOT/no-processes"
  export CODEX_SWITCH_PROC_ROOT="$TEST_ROOT/proc"
  export FAKE_MODEL_CATALOG='{"models":[{"slug":"synthetic","supported_reasoning_levels":[{"effort":"xhigh"},{"effort":"ultra"}]}]}'
  mkdir -m 700 "$CODEX_ACCOUNT_ROOT" "$CODEX_SHARED_HOME"
  mkdir -m 700 "$CODEX_SWITCH_PROC_ROOT"
  printf '%s\n' 'model = "synthetic"' >"$CODEX_SHARED_HOME/config.toml"
  chmod 600 "$CODEX_SHARED_HOME/config.toml"
  write_auth alpha "$CODEX_SHARED_HOME/auth.json"
  printf '%s\n' 'shared-state' >"$CODEX_SHARED_HOME/shared-marker"
  for name in plugins skills rules agents brain compound-engineering; do
    mkdir -m 700 "$CODEX_SHARED_HOME/$name"
  done
  printf '#!/usr/bin/env bash\nexit 1\n' >"$CODEX_SWITCH_PROCESS_CHECK"
  chmod 700 "$CODEX_SWITCH_PROCESS_CHECK"
cat >"$CODEX_BIN" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = debug ] && [ "${2:-}" = models ]; then
  printf '%s\n' debug-models >>"$TRACE_FILE"
  printf '%s\n' "$FAKE_MODEL_CATALOG"
  exit 0
fi
printf 'raw_args=' >>"$TRACE_FILE"
printf '<%s>' "$@" >>"$TRACE_FILE"
printf '\n' >>"$TRACE_FILE"
[ "${1:-}" = --no-daemon ] && shift
if [ "${1:-}" = -c ]; then
  [ "${2:-}" = cli_auth_credentials_store=file ] || exit 86
  [ "${FAKE_REJECT_FILE_AUTH:-0}" != 1 ] || exit 86
  shift 2
fi
{
  printf 'home=%s\n' "${CODEX_HOME:-}"
  printf 'account_home=%s\n' "${CODEX_SWITCH_ACCOUNT_HOME:-}"
  printf 'session_path=%s\n' "${CODEX_HOME:-}/sessions"
  printf 'cwd=%s\n' "$PWD"
  printf 'args='
  printf '<%s>' "$@"
  printf '\n'
} >>"$TRACE_FILE"
if [ "${1:-}" = login ] && [ "${FAKE_SKIP_FILE_AUTH:-0}" != 1 ]; then
  printf '%s\n' '{"auth_mode":"chatgpt","tokens":{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","id_token":"synthetic-id","account_id":"acct-login"}}' >"$CODEX_HOME/auth.json"
fi
if [ "${1:-}" = probe-overlay ]; then
  printf 'marker=%s\n' "$(cat "$CODEX_HOME/shared-marker")" >>"$TRACE_FILE"
  printf 'account=%s\n' "$(jq -r '.tokens.account_id' "$CODEX_HOME/auth.json")" >>"$TRACE_FILE"
  printf '%s\n' 'created-through-overlay' >"$CODEX_HOME/new-top-level"
  printf '%s\n' '{"probe":"slot-auth-updated"}' >"$CODEX_HOME/auth.json"
fi
SH
  chmod 700 "$CODEX_BIN"
cat >"$SUDO_BIN" <<'SH'
#!/usr/bin/env bash
printf '<%s>' "$@" >"$SUDO_TRACE"
[ "${FAKE_SUDO_FAIL:-0}" -eq 0 ] || exit "$FAKE_SUDO_FAIL"
[ "${1:-}" = -n ] || exit 64
shift
exec "$@"
SH
  chmod 700 "$SUDO_BIN"
cat >"$ADMIN_RUNNER_BIN" <<'SH'
#!/usr/bin/env bash
auth=$1
target=$2
account_home=$3
shift 3
[ "${1:-}" = -- ] || exit 64
shift
printf 'auth=%s\ntarget=%s\naccount_home=%s\nargs=' "$auth" "$target" "$account_home" >"$ADMIN_TRACE"
printf '<%s>' "$@" >>"$ADMIN_TRACE"
printf '\n' >>"$ADMIN_TRACE"
backup=$(mktemp)
cp "$target" "$backup"
cp "$auth" "$target"
CODEX_HOME=$(dirname "$target") CODEX_SWITCH_ACCOUNT_HOME="$account_home" "$@"
rc=$?
cp "$target" "$auth"
cp "$backup" "$target"
rm -f "$backup"
exit "$rc"
SH
  chmod 700 "$ADMIN_RUNNER_BIN"
  BLOCKER_PID=
  MANAGED_PIDS=()
  SERVER_PID=
  WATCHER_PID=
}

@test "launch preserves a valid config without a final newline" {
  init_home 1 alpha
  printf 'model = "synthetic"' >"$CODEX_SHARED_HOME/config.toml"
  cp "$CODEX_SHARED_HOME/config.toml" "$TEST_ROOT/config-before"

  run "$CODEX_SWITCH" launch 1 -- --version

  [ "$status" -eq 0 ]
  cmp -s "$TEST_ROOT/config-before" "$CODEX_SHARED_HOME/config.toml"
  ! grep -F debug-models "$TRACE_FILE"
}

@test "launch preserves a config ending in an MCP table" {
  init_home 1 alpha
  printf '%s\n' '[mcp_servers.example]' 'command = "example"' >>"$CODEX_SHARED_HOME/config.toml"
  cp "$CODEX_SHARED_HOME/config.toml" "$TEST_ROOT/config-before"

  run "$CODEX_SWITCH" launch 1 -- --version

  [ "$status" -eq 0 ]
  cmp -s "$TEST_ROOT/config-before" "$CODEX_SHARED_HOME/config.toml"
  ! grep -F debug-models "$TRACE_FILE"
}

teardown() {
  if [ -n "${WATCHER_PID:-}" ]; then
    kill "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
  fi
  if [ -n "${SERVER_PID:-}" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  for pid in "${MANAGED_PIDS[@]}"; do
    kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  if [ -n "${BLOCKER_PID:-}" ]; then
    kill -- "-$BLOCKER_PID" 2>/dev/null || kill "$BLOCKER_PID" 2>/dev/null || true
    wait "$BLOCKER_PID" 2>/dev/null || true
  fi
  rm -rf -- "$TEST_ROOT"
}

write_auth() {
  local label=$1 destination=$2 email account_id payload
  case "$label" in
    alpha) email=alpha@example.test; account_id=acct-alpha-0001 ;;
    beta) email=beta@example.test; account_id=acct-beta-0002 ;;
    gamma) email=gamma@example.test; account_id=acct-gamma-0003 ;;
    delta) email=delta@example.test; account_id=acct-delta-0004 ;;
    epsilon) email=epsilon@example.test; account_id=acct-epsilon-0005 ;;
    theta) email=theta@example.test; account_id=acct-theta-0008 ;;
    iota) email=iota@example.test; account_id=acct-iota-0009 ;;
  esac
  payload=$(printf '{"email":"%s"}' "$email" | base64 | tr '+/' '-_' | tr -d '=\n')
  printf '%s\n' "{\"auth_mode\":\"chatgpt\",\"tokens\":{\"access_token\":\"synthetic-access-$label\",\"refresh_token\":\"synthetic-refresh-$label\",\"id_token\":\"header.$payload.signature\",\"account_id\":\"$account_id\"},\"last_refresh\":\"2026-01-01T00:00:00Z\"}" >"$destination"
  chmod 600 "$destination"
}

init_home() {
  local slot=$1 label=${2:-}
  local home="$CODEX_ACCOUNT_ROOT/$slot/home"
  mkdir -p -m 700 "$CODEX_ACCOUNT_ROOT/$slot" "$home"
  if [ -n "$label" ]; then
    write_auth "$label" "$CODEX_ACCOUNT_ROOT/$slot/auth.json"
  fi
}

spawn_blocker() {
  local blocker_home=${1:-<unset>}
  setsid bash -c 'sleep 30 & wait' &
  BLOCKER_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    BLOCKER_CHILD=$(pgrep -P "$BLOCKER_PID" | head -n1 || true)
    [ -n "$BLOCKER_CHILD" ] && break
    sleep 0.05
  done
  cat >"$TEST_ROOT/detect-processes" <<SH
#!/usr/bin/env bash
if kill -0 '$BLOCKER_PID' 2>/dev/null; then
  printf '%s\tcli\t?\t%s\t%s,%s\\n' '$BLOCKER_PID' '$blocker_home' '$BLOCKER_PID' '$BLOCKER_CHILD'
  exit 0
fi
exit 1
SH
  chmod 700 "$TEST_ROOT/detect-processes"
  export CODEX_SWITCH_PROCESS_CHECK="$TEST_ROOT/detect-processes"
}

write_proc_process() {
  local pid=$1 ppid=$2 pgid=$3 sid=$4 uid=$5 comm=$6 home=$7
  shift 7
  local dir="$CODEX_SWITCH_PROC_ROOT/$pid"
  mkdir -p "$dir/fd"
  printf '%s\n' "$comm" >"$dir/comm"
  printf 'Name:\t%s\nUid:\t%s\t%s\t%s\t%s\nPPid:\t%s\n' "$comm" "$uid" "$uid" "$uid" "$uid" "$ppid" >"$dir/status"
  printf '%s (%s) S %s %s %s' "$pid" "$comm" "$ppid" "$pgid" "$sid" >"$dir/stat"
  for _ in {1..15}; do printf ' 0' >>"$dir/stat"; done
  printf ' %s 0 0 0 0\n' "${PROC_START_TICKS:-12345}" >>"$dir/stat"
  printf '%s\0' "$@" >"$dir/cmdline"
  if [ "$home" != '<unset>' ]; then
    printf 'CODEX_HOME=%s\0' "$home" >"$dir/environ"
  else
    : >"$dir/environ"
  fi
  printf '%s\n' '?' >"$dir/tty"
}

managed_process() {
  local name=$1 pid=$2 uid=${3:-$(id -u)}
  local executable="$CODEX_SHARED_HOME/packages/app-server-daemon/releases/v1/bin/codex"
  mkdir -p "$(dirname "$executable")" "$CODEX_SHARED_HOME/app-server-daemon" "$CODEX_SWITCH_PROC_ROOT/sys/kernel/random"
  : >"$executable"
  printf '%s\n' 'test-boot-id' >"$CODEX_SWITCH_PROC_ROOT/sys/kernel/random/boot_id"
  write_proc_process "$pid" 1 "$pid" "$pid" "$uid" codex "$CODEX_SHARED_HOME" "$executable" app-server
  ln -s "$executable" "$CODEX_SWITCH_PROC_ROOT/$pid/exe"
  printf '{"pid":%s,"processIdentity":{"bootId":"test-boot-id","startTicks":12345}}\n' "$pid" >"$CODEX_SHARED_HOME/app-server-daemon/$name.pid"
}

start_app_server() {
  local scenario=$1 socket="$CODEX_SHARED_HOME/app-server-control/app-server-control.sock"
  mkdir -p "$(dirname "$socket")"
  : >"$FAKE_RPC_TRACE"
  python3 "$BATS_TEST_DIRNAME/fake_app_server.py" "$socket" "$scenario" &
  SERVER_PID=$!
  # The scanner reads a synthetic /proc; supply matching kernel peer credentials.
  cat >"$TEST_ROOT/sitecustomize.py" <<'PY'
import os
import socket
import struct

BaseSocket = socket.socket

class PeerSocket(BaseSocket):
    def getsockopt(self, level, option, buflen=0):
        if level == socket.SOL_SOCKET and option == socket.SO_PEERCRED:
            return struct.pack("3i", int(os.environ["FAKE_PEER_PID"]),
                               int(os.environ.get("FAKE_PEER_UID", os.getuid())),
                               os.getgid())
        return super().getsockopt(level, option, buflen)

socket.socket = PeerSocket
PY
  export PYTHONPATH="$TEST_ROOT"
  FAKE_PEER_PID=$(jq -r '.pid' "$CODEX_SHARED_HOME/app-server-daemon/daemon.pid")
  export FAKE_PEER_PID
  for _ in {1..40}; do
    [ -S "$socket" ] && return 0
    sleep 0.05
  done
  return 1
}

assert_launch_blocked() {
  [ "$status" -eq 75 ]
  [ ! -e "$TRACE_FILE" ]
  [[ "$output" == *"use --kill or close them first"* ]]
}

assert_bad_initialize_blocks() {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  managed_process daemon 900
  start_app_server "$1"
  run "$CODEX_SWITCH" launch 3 -- --version
  [ "$status" -eq 75 ]
  [ ! -e "$TRACE_FILE" ]
  grep -Fx initialize "$FAKE_RPC_TRACE"
}

@test "unreadable proc exe keeps an ordinary CLI visible as a blocker" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  write_proc_process 730 1 730 730 "$(id -u)" codex '<unset>' /vendor/bin/codex --yolo
  ln -s /vendor/bin/codex "$CODEX_SWITCH_PROC_ROOT/730/exe"
  cat >"$TEST_ROOT/sitecustomize.py" <<'PY'
import os

original = os.readlink

def denied(path, *args, **kwargs):
    if str(path) == os.environ["CODEX_SWITCH_PROC_ROOT"] + "/730/exe":
        raise PermissionError("test exe denial")
    return original(path, *args, **kwargs)

os.readlink = denied
PY
  export PYTHONPATH="$TEST_ROOT"

  run "$CODEX_SWITCH" launch 3 -- --version

  assert_launch_blocked
  [[ "$output" == *"kind=cli"* ]]
}

@test "deep malformed managed record never hides a CLI blocker" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  write_proc_process 730 1 730 730 "$(id -u)" codex '<unset>' /vendor/bin/codex --yolo
  mkdir -p "$CODEX_SHARED_HOME/app-server-daemon"
  python3 - "$CODEX_SHARED_HOME/app-server-daemon/daemon.pid" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_text("[" * 20000 + "0" + "]" * 20000)
PY

  run "$CODEX_SWITCH" launch 3 -- --version

  assert_launch_blocked
  [[ "$output" == *"kind=cli"* ]]
  [[ "$output" != *"Traceback"* ]]
}

@test "FIFO managed record cannot hang or hide a CLI blocker" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  write_proc_process 730 1 730 730 "$(id -u)" codex '<unset>' /vendor/bin/codex --yolo
  mkdir -p "$CODEX_SHARED_HOME/app-server-daemon"
  mkfifo "$CODEX_SHARED_HOME/app-server-daemon/daemon.pid"

  run timeout 3 "$CODEX_SWITCH" launch 3 -- --version

  assert_launch_blocked
  [[ "$output" == *"kind=cli"* ]]
}

@test "unhandled scanner errors fail closed without exposing diagnostics" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  cat >"$TEST_ROOT/sitecustomize.py" <<'PY'
import os
from pathlib import Path

original = Path.iterdir

def failing_scan(path):
    if str(path) == os.environ["CODEX_SWITCH_PROC_ROOT"]:
        raise RuntimeError("PRIVATE_TEST_SENTINEL")
    return original(path)

Path.iterdir = failing_scan
PY
  export PYTHONPATH="$TEST_ROOT"

  run "$CODEX_SWITCH" launch 3 -- --version

  [ "$status" -eq 75 ]
  [ ! -e "$TRACE_FILE" ]
  [[ "$output" == *"unable to inspect running Codex processes"* ]]
  [[ "$output" != *"PRIVATE_TEST_SENTINEL"* ]]
}

@test "null initialize result blocks managed daemon exemption" {
  assert_bad_initialize_blocks null-initialize
}

@test "boolean response id blocks managed daemon exemption" {
  assert_bad_initialize_blocks bool-id
}

@test "unnegotiated RSV1 frame blocks managed daemon exemption" {
  assert_bad_initialize_blocks rsv1
}

@test "idle managed daemon and updater allow slot three without prompt" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  managed_process daemon 900
  managed_process daemon-updater 901
  start_app_server idle

  run "$CODEX_SWITCH" launch 3 -- --version

  [ "$status" -eq 0 ]
  [[ "$output" != *"Kill running Codex process(es)?"* ]]
  grep -Fx 'raw_args=<--no-daemon><-c><cli_auth_credentials_store=file><--version>' "$TRACE_FILE"
  grep -Fx 'args=<--version>' "$TRACE_FILE"
}

@test "slot nine avoids the shared account-one daemon" {
  init_home 9 iota

  run "$CODEX_SWITCH" launch 9 -- --version

  [ "$status" -eq 0 ]
  grep -Fx "auth=$CODEX_ACCOUNT_ROOT/9/auth.json" "$ADMIN_TRACE"
  grep -Fx 'raw_args=<--no-daemon><-c><cli_auth_credentials_store=file><--version>' "$TRACE_FILE"
}

@test "slot three interactive launch avoids the shared daemon" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  managed_process daemon 900
  managed_process daemon-updater 901
  start_app_server idle

  run "$CODEX_SWITCH" launch 3

  [ "$status" -eq 0 ]
  grep -Fx "auth=$CODEX_ACCOUNT_ROOT/3/auth.json" "$ADMIN_TRACE"
  grep -Fx 'raw_args=<--no-daemon><-c><cli_auth_credentials_store=file>' "$TRACE_FILE"
}

@test "updater alone allows launch even without a status socket" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  managed_process daemon-updater 901

  run "$CODEX_SWITCH" launch 3 -- --version

  [ "$status" -eq 0 ]
  grep -Fx 'args=<--version>' "$TRACE_FILE"
}

@test "managed daemon with zero loaded threads allows launch" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  managed_process daemon 900
  start_app_server empty

  run "$CODEX_SWITCH" launch 3 -- --version

  [ "$status" -eq 0 ]
  grep -Fx 'args=<--version>' "$TRACE_FILE"
}

@test "socket peer PID mismatch cannot hide a managed daemon" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  managed_process daemon 900
  start_app_server idle
  export FAKE_PEER_PID=901

  run "$CODEX_SWITCH" launch 3 -- --version

  assert_launch_blocked
  [[ "$output" == *"kind=app-server"* ]]
}

@test "socket peer UID mismatch cannot hide a managed daemon" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  managed_process daemon 900
  start_app_server idle
  export FAKE_PEER_UID=99999

  run "$CODEX_SWITCH" launch 3 -- --version

  assert_launch_blocked
  [[ "$output" == *"kind=app-server"* ]]
}

@test "same-slot active managed app-server remains a blocker" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  managed_process daemon 900
  printf 'CODEX_SWITCH_ACCOUNT_HOME=%s\0' "$CODEX_ACCOUNT_ROOT/3/home" >"$CODEX_SWITCH_PROC_ROOT/900/environ"
  start_app_server active

  run "$CODEX_SWITCH" launch 3 -- --version

  assert_launch_blocked
  [[ "$output" == *"kind=app-server"* ]]
  [[ "$output" == *"account=3"* ]]
}

@test "same-slot mismatched daemon socket peer remains a blocker" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  managed_process daemon 900
  printf 'CODEX_SWITCH_ACCOUNT_HOME=%s\0' "$CODEX_ACCOUNT_ROOT/3/home" >"$CODEX_SWITCH_PROC_ROOT/900/environ"
  start_app_server idle
  export FAKE_PEER_PID=901

  run "$CODEX_SWITCH" launch 3 -- --version

  assert_launch_blocked
  [[ "$output" == *"kind=app-server"* ]]
  [[ "$output" == *"account=3"* ]]
}

@test "active and unknown managed daemon thread status blocks launch" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  managed_process daemon 900
  for scenario in active unknown mixed paged; do
    start_app_server "$scenario"
    run "$CODEX_SWITCH" launch 3 -- --version
    assert_launch_blocked
    grep -Fx 'thread/read' "$FAKE_RPC_TRACE"
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=
    rm -f "$CODEX_SHARED_HOME/app-server-control/app-server-control.sock"
  done
}

@test "socket error and timeout block managed daemon launch" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  managed_process daemon 900
  run "$CODEX_SWITCH" launch 3 -- --version
  assert_launch_blocked
  for scenario in error timeout; do
    start_app_server "$scenario"
    run "$CODEX_SWITCH" launch 3 -- --version
    assert_launch_blocked
    grep -Fx 'thread/read' "$FAKE_RPC_TRACE"
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=
    rm -f "$CODEX_SHARED_HOME/app-server-control/app-server-control.sock"
  done
}

@test "daemon PID identity changing during the status query blocks launch" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  managed_process daemon 900
  export FAKE_PID_RECORD="$CODEX_SHARED_HOME/app-server-daemon/daemon.pid"
  start_app_server identity-change

  run "$CODEX_SWITCH" launch 3 -- --version

  [ "$status" -eq 75 ]
  [ ! -e "$TRACE_FILE" ]
  grep -Fx 'thread/read' "$FAKE_RPC_TRACE"
}

@test "daemon and updater records naming the same PID cannot bypass an active daemon" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  managed_process daemon 900
  cp "$CODEX_SHARED_HOME/app-server-daemon/daemon.pid" "$CODEX_SHARED_HOME/app-server-daemon/daemon-updater.pid"
  start_app_server active

  run "$CODEX_SWITCH" launch 3 -- --version

  [ "$status" -eq 75 ]
  [ ! -e "$TRACE_FILE" ]
}

@test "unmanaged app-server and ordinary CLI still block beside idle daemon" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  managed_process daemon 900
  write_proc_process 902 1 902 902 "$(id -u)" codex '<unset>' /vendor/bin/codex app-server
  start_app_server idle
  run "$CODEX_SWITCH" launch 3 -- --version
  assert_launch_blocked
  [[ "$output" == *"kind=app-server"* ]]
  [[ "$output" != *"session=900 "* ]]
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  SERVER_PID=
  rm -f "$CODEX_SHARED_HOME/app-server-control/app-server-control.sock"
  rm -rf "$CODEX_SWITCH_PROC_ROOT/902"
  write_proc_process 903 1 903 903 "$(id -u)" codex '<unset>' /vendor/bin/codex --yolo
  start_app_server idle
  run "$CODEX_SWITCH" launch 3 -- --version
  assert_launch_blocked
  [[ "$output" == *"kind=cli"* ]]
  [[ "$output" != *"session=900 "* ]]
}

@test "stale or mismatched managed identity never exempts an app-server" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  local record="$CODEX_SHARED_HOME/app-server-daemon/daemon-updater.pid"
  for mismatch in stale boot start exe uid; do
    managed_process daemon-updater 901
    case "$mismatch" in
      stale) sed -i 's/"pid":901/"pid":999/' "$record" ;;
      boot) sed -i 's/test-boot-id/other-boot/' "$record" ;;
      start) sed -i 's/12345/99999/' "$record" ;;
      exe) rm "$CODEX_SWITCH_PROC_ROOT/901/exe"; ln -s /vendor/bin/codex "$CODEX_SWITCH_PROC_ROOT/901/exe" ;;
      uid) sed -i "s/$(id -u)/99999/g" "$CODEX_SWITCH_PROC_ROOT/901/status" ;;
    esac
    run "$CODEX_SWITCH" launch 3 -- --version
    if [ "$mismatch" = uid ]; then
      [ "$status" -eq 75 ]
      [ ! -e "$TRACE_FILE" ]
      [[ "$output" == *"unable to inspect running Codex processes"* ]]
    else
      assert_launch_blocked
    fi
    rm -rf "$CODEX_SWITCH_PROC_ROOT/901"
  done
}

@test "--kill cannot signal excluded managed processes" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  setsid sleep 30 &
  MANAGED_PIDS+=("$!")
  managed_process daemon "${MANAGED_PIDS[0]}"
  setsid sleep 30 &
  MANAGED_PIDS+=("$!")
  managed_process daemon-updater "${MANAGED_PIDS[1]}"
  start_app_server idle

  run "$CODEX_SWITCH" launch 3 --kill -- --version

  [ "$status" -eq 0 ]
  kill -0 "${MANAGED_PIDS[0]}"
  kill -0 "${MANAGED_PIDS[1]}"
  grep -Fx 'args=<--version>' "$TRACE_FILE"
}

@test "--kill leaves an idle managed ancestor alive when a CLI shares its PGID" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  setsid bash -c 'sleep 30 & printf "%s\n" "$!" >"$1"; while :; do sleep 1; done' _ "$TEST_ROOT/cli-pid" &
  local managed_pid=$!
  MANAGED_PIDS+=("$managed_pid")
  for _ in {1..40}; do
    [ -s "$TEST_ROOT/cli-pid" ] && break
    sleep 0.05
  done
  local cli_pid
  cli_pid=$(cat "$TEST_ROOT/cli-pid")
  managed_process daemon "$managed_pid"
  write_proc_process "$cli_pid" "$managed_pid" "$managed_pid" "$managed_pid" "$(id -u)" codex '<unset>' /vendor/bin/codex --yolo
  (
    while kill -0 "$cli_pid" 2>/dev/null; do
      case "$(ps -o stat= -p "$cli_pid" 2>/dev/null)" in Z*) break ;; esac
      sleep 0.05
    done
    rm -rf "$CODEX_SWITCH_PROC_ROOT/$cli_pid"
  ) &
  WATCHER_PID=$!
  start_app_server idle

  run "$CODEX_SWITCH" launch 3 --kill -- --version

  [ "$status" -eq 0 ]
  kill -0 "$managed_pid"
  ! kill -0 "$cli_pid" 2>/dev/null
  grep -Fx 'args=<--version>' "$TRACE_FILE"
}

@test "--kill uses fresh idle exemption when a shared-PGID daemon changes from active" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  setsid bash -c 'sleep 30 & printf "%s\n" "$!" >"$1"; while :; do sleep 1; done' _ "$TEST_ROOT/cli-pid" &
  local managed_pid=$!
  MANAGED_PIDS+=("$managed_pid")
  for _ in {1..40}; do
    [ -s "$TEST_ROOT/cli-pid" ] && break
    sleep 0.05
  done
  local cli_pid
  cli_pid=$(cat "$TEST_ROOT/cli-pid")
  managed_process daemon "$managed_pid"
  write_proc_process "$cli_pid" "$managed_pid" "$managed_pid" "$managed_pid" "$(id -u)" codex '<unset>' /vendor/bin/codex --yolo
  (
    while kill -0 "$cli_pid" 2>/dev/null; do
      case "$(ps -o stat= -p "$cli_pid" 2>/dev/null)" in Z*) break ;; esac
      sleep 0.05
    done
    rm -rf "$CODEX_SWITCH_PROC_ROOT/$cli_pid"
  ) &
  WATCHER_PID=$!
  start_app_server active-then-idle

  run "$CODEX_SWITCH" launch 3 --kill -- --version

  [ "$(grep -c '^thread/read$' "$FAKE_RPC_TRACE")" -ge 2 ]
  [ "$status" -eq 0 ]
  kill -0 "$managed_pid"
  ! kill -0 "$cli_pid" 2>/dev/null
  grep -Fx 'args=<--version>' "$TRACE_FILE"
}

@test "--kill signals the fresh CLI PID when shared-PGID membership changes" {
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  setsid bash -c 'sleep 30 & printf "%s\n" "$!" >"$1"; sleep 30 & printf "%s\n" "$!" >"$2"; while :; do sleep 1; done' _ "$TEST_ROOT/old-pid" "$TEST_ROOT/new-pid" &
  local managed_pid=$!
  MANAGED_PIDS+=("$managed_pid")
  for _ in {1..40}; do
    [ -s "$TEST_ROOT/old-pid" ] && [ -s "$TEST_ROOT/new-pid" ] && break
    sleep 0.05
  done
  local old_pid new_pid
  old_pid=$(cat "$TEST_ROOT/old-pid")
  new_pid=$(cat "$TEST_ROOT/new-pid")
  managed_process daemon "$managed_pid"
  write_proc_process "$old_pid" "$managed_pid" "$managed_pid" "$managed_pid" "$(id -u)" codex '<unset>' /vendor/bin/codex --yolo
  export FAKE_STALE_OLD_DIR="$CODEX_SWITCH_PROC_ROOT/$old_pid"
  export FAKE_STALE_NEW_DIR="$CODEX_SWITCH_PROC_ROOT/$new_pid"
  (
    while kill -0 "$new_pid" 2>/dev/null; do
      case "$(ps -o stat= -p "$new_pid" 2>/dev/null)" in Z*) break ;; esac
      sleep 0.05
    done
    rm -rf "$FAKE_STALE_NEW_DIR"
  ) &
  WATCHER_PID=$!
  start_app_server stale-pid

  run "$CODEX_SWITCH" launch 3 --kill -- --version

  [ "$(grep -c '^thread/read$' "$FAKE_RPC_TRACE")" -ge 2 ]
  [ "$status" -eq 0 ]
  kill -0 "$managed_pid"
  kill -0 "$old_pid"
  ! kill -0 "$new_pid" 2>/dev/null
  grep -Fx 'args=<--version>' "$TRACE_FILE"
}

@test "list shows supported auth-only account labels including slot eight without token material" {
  init_home 1 alpha
  init_home 2 beta
  init_home 3 gamma
  init_home 4 delta
  init_home 5 epsilon
  init_home 8 theta

  run "$CODEX_SWITCH" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"account 1: alpha@example.test (acct-alp...) [ready]"* ]]
  [[ "$output" == *"account 2: beta@example.test (acct-bet...) [ready]"* ]]
  [[ "$output" == *"account 3: gamma@example.test (acct-gam...) [ready]"* ]]
  [[ "$output" == *"account 4: delta@example.test (acct-del...) [ready]"* ]]
  [[ "$output" == *"account 5: epsilon@example.test (acct-eps...) [ready]"* ]]
  [[ "$output" == *"account 8: theta@example.test (acct-the...) [ready]"* ]]
  [[ "$output" != *"synthetic-access"* ]]
  [[ "$output" != *"synthetic-refresh"* ]]
}

@test "list marks an unauthenticated home as login required" {
  init_home 1
  init_home 2 beta
  init_home 3 gamma

  run "$CODEX_SWITCH" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"account 1: (login required)"* ]]
}

@test "dynamic slot discovery sorts numbers and maps a running session" {
  init_home 12 gamma
  init_home 3 beta
  export CODEX_SWITCH_PROCESS_CHECK=
  uid=$(id -u)
  write_proc_process 480 1 480 480 "$uid" codex "$CODEX_ACCOUNT_ROOT/12/home" "$CODEX_BIN" --version

  run "$CODEX_SWITCH" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"account 12: gamma@example.test (acct-gam...) [ready] (running)"* ]]
  [[ "$output" == *"account 3: beta@example.test (acct-bet...) [ready]"* ]]
  [[ "$output" != *"account 1:"* ]]
  [[ "$output" == *"account 3:"*"account 12:"* ]]
}

@test "add creates only requested empty slots with private permissions" {
  run "$CODEX_SWITCH" add 1
  [ "$status" -eq 0 ]
  run "$CODEX_SWITCH" add 2
  [ "$status" -eq 0 ]
  run "$CODEX_SWITCH" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"account 1: (login required)"* ]]
  [[ "$output" == *"account 2: (login required)"* ]]
  [[ "$output" != *"account 3:"* ]]
  for slot in 1 2; do
    [ "$(stat -c '%a' "$CODEX_ACCOUNT_ROOT/$slot")" = 700 ]
    [ "$(stat -c '%a' "$CODEX_ACCOUNT_ROOT/$slot/home")" = 700 ]
    [ "$(stat -c '%a' "$CODEX_ACCOUNT_ROOT/$slot/auth.json")" = 600 ]
    [ ! -s "$CODEX_ACCOUNT_ROOT/$slot/auth.json" ]
  done
}

@test "add three is discovered by list and rejects an existing slot without changing it" {
  run "$CODEX_SWITCH" add 3
  [ "$status" -eq 0 ]
  write_auth gamma "$CODEX_ACCOUNT_ROOT/3/auth.json"
  before=$(sha256sum "$CODEX_ACCOUNT_ROOT/3/auth.json")
  run "$CODEX_SWITCH" add 3
  [ "$status" -ne 0 ]
  [ "$(sha256sum "$CODEX_ACCOUNT_ROOT/3/auth.json")" = "$before" ]
  run "$CODEX_SWITCH" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"account 3: gamma@example.test (acct-gam...) [ready]"* ]]
}

@test "add rejects invalid numbers and preexisting symlink paths" {
  for invalid in 0 01 -1 foo 1/2; do
    run "$CODEX_SWITCH" add "$invalid"
    [ "$status" -eq 64 ]
  done
  ln -s "$TEST_ROOT" "$CODEX_ACCOUNT_ROOT/3"
  run "$CODEX_SWITCH" add 3
  [ "$status" -ne 0 ]
  [ -L "$CODEX_ACCOUNT_ROOT/3" ]
}

@test "add creates a missing shared mount target without modifying shared config" {
  rm "$CODEX_SHARED_HOME/auth.json"
  before=$(sha256sum "$CODEX_SHARED_HOME/config.toml")
  run "$CODEX_SWITCH" add 1
  [ "$status" -eq 0 ]
  [ "$(stat -c '%a' "$CODEX_SHARED_HOME/auth.json")" = 600 ]
  [ ! -s "$CODEX_SHARED_HOME/auth.json" ]
  [ "$(sha256sum "$CODEX_SHARED_HOME/config.toml")" = "$before" ]
}

@test "add refuses unsafe account root or shared auth target" {
  chmod 755 "$CODEX_ACCOUNT_ROOT"
  run "$CODEX_SWITCH" add 1
  [ "$status" -ne 0 ]
  [ ! -e "$CODEX_ACCOUNT_ROOT/1" ]
  chmod 700 "$CODEX_ACCOUNT_ROOT"
  rm "$CODEX_SHARED_HOME/auth.json"
  ln -s "$TEST_ROOT/shared-marker" "$CODEX_SHARED_HOME/auth.json"
  run "$CODEX_SWITCH" add 1
  [ "$status" -ne 0 ]
  [ ! -e "$CODEX_ACCOUNT_ROOT/1" ]
}

@test "login and launch require a previously added slot" {
  run "$CODEX_SWITCH" login 3
  [ "$status" -ne 0 ]
  [[ "$output" == *"add 3"* ]]
  run "$CODEX_SWITCH" launch 3 -- --version
  [ "$status" -ne 0 ]
  [[ "$output" == *"add 3"* ]]
  [ ! -d "$CODEX_ACCOUNT_ROOT/3" ]
}

@test "duplicate account ids are labeled and refused" {
  init_home 1 alpha
  init_home 2 alpha
  init_home 3 gamma
  init_home 4 alpha
  init_home 5 alpha
  init_home 8 alpha

  run "$CODEX_SWITCH" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"account 1: alpha@example.test (acct-alp...) [duplicate account]"* ]]
  [[ "$output" == *"account 2: alpha@example.test (acct-alp...) [duplicate account]"* ]]
  [[ "$output" == *"account 4: alpha@example.test (acct-alp...) [duplicate account]"* ]]
  [[ "$output" == *"account 5: alpha@example.test (acct-alp...) [duplicate account]"* ]]
  [[ "$output" == *"account 8: alpha@example.test (acct-alp...) [duplicate account]"* ]]

  run "$CODEX_SWITCH" launch 1
  [ "$status" -eq 75 ]
  [[ "$output" == *"account login duplicates another slot"* ]]
  [ ! -e "$TRACE_FILE" ]

  run "$CODEX_SWITCH" launch 4
  [ "$status" -eq 75 ]
  [[ "$output" == *"account login duplicates another slot"* ]]
  [ ! -e "$TRACE_FILE" ]

  run "$CODEX_SWITCH" launch 5
  [ "$status" -eq 75 ]
  [[ "$output" == *"account login duplicates another slot"* ]]
  [ ! -e "$TRACE_FILE" ]

  run "$CODEX_SWITCH" launch 8
  [ "$status" -eq 75 ]
  [[ "$output" == *"account login duplicates another slot"* ]]
  [ ! -e "$TRACE_FILE" ]
}

@test "account duplicate detection includes newly added slot numbers" {
  init_home 1 alpha
  run "$CODEX_SWITCH" add 12
  [ "$status" -eq 0 ]
  write_auth alpha "$CODEX_ACCOUNT_ROOT/12/auth.json"
  run "$CODEX_SWITCH" launch 12
  [ "$status" -eq 75 ]
  [[ "$output" == *"account login duplicates another slot"* ]]
  [ ! -e "$TRACE_FILE" ]
}

@test "default proc detector maps a running process to account eight" {
  init_home 1 alpha
  init_home 2 beta
  init_home 3 gamma
  init_home 4 delta
  init_home 5 epsilon
  init_home 8 theta
  export CODEX_SWITCH_PROCESS_CHECK=
  uid=$(id -u)
  home="$CODEX_ACCOUNT_ROOT/8/home"
  write_proc_process 470 1 470 470 "$uid" MainThread "$home" node "$CODEX_BIN" --yolo
  write_proc_process 471 470 470 470 "$uid" codex "$home" /vendor/bin/codex --yolo

  run "$CODEX_SWITCH" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"account 8: theta@example.test (acct-the...) [ready] (running)"* ]]
  ! printf '%s\n' "$output" | grep -E '^account (1|2|3|4|5):.*\(running\)$'
}

@test "default proc detector ignores its own awk-like command and unrelated processes" {
  init_home 1 alpha
  init_home 2 beta
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  uid=$(id -u)
  write_proc_process 200 1 200 200 "$uid" awk '<unset>' awk 'codex app-server proxy|codex --yolo'
  write_proc_process 201 1 201 201 "$uid" sshd '<unset>' sshd 'sshd: ubuntu@notty'
  write_proc_process 202 1 202 202 99999 codex '<unset>' codex --yolo

  run "$CODEX_SWITCH" list
  [ "$status" -eq 0 ]
  [[ "$output" != *"(running)"* ]]
  [[ "$output" != *"legacy/default Codex"* ]]
}

@test "default proc detector groups desktop proxy wrapper and native child once" {
  init_home 1 alpha
  init_home 2 beta
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  uid=$(id -u)
  home="$CODEX_ACCOUNT_ROOT/3/home"
  write_proc_process 300 1 300 300 "$uid" sh "$home" /bin/sh -c 'codex app-server proxy'
  write_proc_process 301 300 300 300 "$uid" MainThread "$home" node "$CODEX_BIN" app-server proxy
  write_proc_process 302 301 300 300 "$uid" codex "$home" /vendor/bin/codex app-server proxy

  run "$CODEX_SWITCH" launch 1
  [ "$status" -eq 75 ]
  [[ "$output" == *"session=300 kind=desktop-proxy tty=? account=3 pids=300,301,302"* ]]
  [ "$(printf '%s\n' "$output" | grep -c 'session=300 ')" -eq 1 ]
}

@test "list marks only the account home that has a live proc session as running" {
  init_home 1 alpha
  init_home 2 beta
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  uid=$(id -u)
  home="$CODEX_ACCOUNT_ROOT/2/home"
  write_proc_process 400 1 400 400 "$uid" MainThread "$home" node "$CODEX_BIN" --yolo
  write_proc_process 401 400 400 400 "$uid" codex "$home" /vendor/bin/codex --yolo

  run "$CODEX_SWITCH" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"account 2: beta@example.test (acct-bet...) [ready] (running)"* ]]
  ! printf '%s\n' "$output" | grep -E '^account (1|3):.*\(running\)$'
  [[ "$output" != *"legacy/default Codex"* ]]
}

@test "running marker is bright green on a TTY and plain when piped" {
  init_home 1 alpha
  init_home 2 beta
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  uid=$(id -u)
  home="$CODEX_ACCOUNT_ROOT/2/home"
  write_proc_process 425 1 425 425 "$uid" codex "$home" /vendor/bin/codex --yolo

  run "$CODEX_SWITCH" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"[ready] (running)"* ]]
  [[ "$output" != *$'\033['* ]]

  run env TERM=xterm script -qec "$CODEX_SWITCH list" /dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *$'\033[1;92m(running)\033[0m'* ]]
}

@test "process detector uses the account marker while CODEX_HOME stays shared" {
  init_home 1 alpha
  init_home 2 beta
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  uid=$(id -u)
  home="$CODEX_ACCOUNT_ROOT/2/home"
  write_proc_process 450 1 450 450 "$uid" codex "$CODEX_SHARED_HOME" /vendor/bin/codex --yolo
  printf 'CODEX_HOME=%s\0CODEX_SWITCH_ACCOUNT_HOME=%s\0' "$CODEX_SHARED_HOME" "$home" >"$CODEX_SWITCH_PROC_ROOT/450/environ"

  run "$CODEX_SWITCH" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"account 2: beta@example.test (acct-bet...) [ready] (running)"* ]]
  [[ "$output" != *"legacy/default Codex: running"* ]]
}

@test "list reports unset or shared CODEX_HOME as legacy default" {
  init_home 1 alpha
  init_home 2 beta
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  uid=$(id -u)
  write_proc_process 500 1 500 500 "$uid" MainThread '<unset>' node "$CODEX_BIN" --yolo
  write_proc_process 501 500 500 500 "$uid" codex '<unset>' /vendor/bin/codex --yolo

  run "$CODEX_SWITCH" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"legacy/default Codex: running"* ]]
  [[ "$output" != *"[ready] (running)"* ]]
}

@test "default proc detector reports a codex process sharing the launcher pgid" {
  init_home 1 alpha
  init_home 2 beta
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  uid=$(id -u)
  shared_pgid=$(ps -o pgid= -p $$ | tr -d ' ')
  write_proc_process 550 1 "$shared_pgid" "$shared_pgid" "$uid" codex '<unset>' /vendor/bin/codex --yolo

  run "$CODEX_SWITCH" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"legacy/default Codex: running"* ]]
}

@test "launch keeps shared CODEX_HOME and passes account marker cwd and arguments" {
  init_home 1 alpha
  cd "$TEST_ROOT"

  run "$CODEX_SWITCH" launch 1 -- --yolo "hello world"
  [ "$status" -eq 0 ]
  grep -Fx "home=$CODEX_SHARED_HOME" "$TRACE_FILE"
  grep -Fx "account_home=$CODEX_ACCOUNT_ROOT/1/home" "$TRACE_FILE"
  grep -Fx "session_path=$CODEX_SHARED_HOME/sessions" "$TRACE_FILE"
  grep -Fx "cwd=$TEST_ROOT" "$TRACE_FILE"
  grep -Fx 'args=<--yolo><hello world>' "$TRACE_FILE"
}

@test "launch automatically uses the sudo namespace runner instead of bubblewrap" {
  init_home 2 beta
  export BWRAP_TRACE="$TEST_ROOT/bwrap-trace"
  cat >"$TEST_ROOT/forbidden-bwrap" <<'SH'
#!/usr/bin/env bash
printf '<%s>' "$@" >"$BWRAP_TRACE"
exit 88
SH
  chmod 700 "$TEST_ROOT/forbidden-bwrap"
  export BWRAP_BIN="$TEST_ROOT/forbidden-bwrap"

  run "$CODEX_SWITCH" launch 2 -- --version

  [ "$status" -eq 0 ]
  [ ! -e "$BWRAP_TRACE" ]
  grep -F -- '<-n>' "$SUDO_TRACE"
  ! grep -F -- '<-E>' "$SUDO_TRACE"
  grep -F -- "<$ADMIN_RUNNER_BIN>" "$SUDO_TRACE"
  grep -Fx "auth=$CODEX_ACCOUNT_ROOT/2/auth.json" "$ADMIN_TRACE"
  grep -Fx "target=$CODEX_SHARED_HOME/auth.json" "$ADMIN_TRACE"
  grep -Fx "account_home=$CODEX_ACCOUNT_ROOT/2/home" "$ADMIN_TRACE"
  grep -Fx 'args=<--version>' "$TRACE_FILE"
}

@test "sudo namespace runner failure never falls back or executes Codex" {
  init_home 1 alpha
  export FAKE_SUDO_FAIL=77

  run "$CODEX_SWITCH" launch 1

  [ "$status" -eq 77 ]
  [ ! -e "$TRACE_FILE" ]
}

@test "admin runner refuses direct non-root execution" {
  run "$BATS_TEST_DIRNAME/../codex-switch-admin-run"

  [ "$status" -eq 77 ]
  [[ "$output" == *"must be invoked through sudo"* ]]
}

@test "private account view shares state while overlaying only the selected auth" {
  init_home 2 beta
  cp "$CODEX_SHARED_HOME/auth.json" "$TEST_ROOT/legacy-auth-before.json"

  run "$CODEX_SWITCH" launch 2 -- probe-overlay
  [ "$status" -eq 0 ]
  grep -Fx 'marker=shared-state' "$TRACE_FILE"
  grep -Fx 'account=acct-beta-0002' "$TRACE_FILE"
  grep -Fx 'created-through-overlay' "$CODEX_SHARED_HOME/new-top-level"
  grep -Fx '{"probe":"slot-auth-updated"}' "$CODEX_ACCOUNT_ROOT/2/auth.json"
  cmp -s "$TEST_ROOT/legacy-auth-before.json" "$CODEX_SHARED_HOME/auth.json"
  [ -z "$(find "$CODEX_ACCOUNT_ROOT/2/home" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

@test "private account view exposes shared sessions skills plugins and sqlite" {
  init_home 3 gamma
  mkdir -p "$CODEX_SHARED_HOME/sessions/2026/07/13"
  printf '%s\n' rollout >"$CODEX_SHARED_HOME/sessions/2026/07/13/rollout.jsonl"
  printf '%s\n' sqlite >"$CODEX_SHARED_HOME/state_5.sqlite"

  cat >"$CODEX_BIN" <<'SH'
#!/usr/bin/env bash
for path in sessions/2026/07/13/rollout.jsonl skills plugins state_5.sqlite; do
  [ -e "$CODEX_HOME/$path" ] || exit 91
done
printf '%s\n' future >"$CODEX_HOME/future-root-file"
SH
  chmod 700 "$CODEX_BIN"

  run "$CODEX_SWITCH" launch 3
  [ "$status" -eq 0 ]
  grep -Fx future "$CODEX_SHARED_HOME/future-root-file"
  [ -z "$(find "$CODEX_ACCOUNT_ROOT/3/home" -mindepth 1 -maxdepth 1 -print -quit)" ]
}

@test "login retains the bubblewrap account view" {
  run "$CODEX_SWITCH" add 1
  [ "$status" -eq 0 ]
  export BWRAP_TRACE="$TEST_ROOT/bwrap-trace"
  cat >"$TEST_ROOT/recording-bwrap" <<'SH'
#!/usr/bin/env bash
printf '<%s>' "$@" >"$BWRAP_TRACE"
SH
  chmod 700 "$TEST_ROOT/recording-bwrap"
  export BWRAP_BIN="$TEST_ROOT/recording-bwrap"

  run "$CODEX_SWITCH" login 1
  [ "$status" -ne 0 ]
  grep -F -- '<--dev-bind></dev></dev>' "$BWRAP_TRACE"
}

@test "missing bubblewrap and mount failure prevent login" {
  run "$CODEX_SWITCH" add 1
  [ "$status" -eq 0 ]
  export BWRAP_BIN="$TEST_ROOT/missing-bwrap"
  run "$CODEX_SWITCH" login 1
  [ "$status" -eq 66 ]
  [ ! -e "$TRACE_FILE" ]

  cat >"$TEST_ROOT/failing-bwrap" <<'SH'
#!/usr/bin/env bash
exit 73
SH
  chmod 700 "$TEST_ROOT/failing-bwrap"
  export BWRAP_BIN="$TEST_ROOT/failing-bwrap"
  run "$CODEX_SWITCH" login 1
  [ "$status" -eq 73 ]
  [ ! -e "$TRACE_FILE" ]
}

@test "default proc detector allows a non-TTY launch beside the same account" {
  init_home 1 alpha
  init_home 2 beta
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  uid=$(id -u)
  home="$CODEX_ACCOUNT_ROOT/2/home"
  write_proc_process 600 1 600 600 "$uid" MainThread "$home" node "$CODEX_BIN" --yolo
  write_proc_process 601 600 600 600 "$uid" codex "$home" /vendor/bin/codex --yolo

  run "$CODEX_SWITCH" launch 2 -- --version
  [ "$status" -eq 0 ]
  [[ "$output" != *"Codex process(es) are running:"* ]]
  grep -Fx "home=$CODEX_SHARED_HOME" "$TRACE_FILE"
  grep -Fx "account_home=$home" "$TRACE_FILE"
  grep -Fx 'args=<--version>' "$TRACE_FILE"
}

@test "TTY menu launches beside the same account without prompting or killing" {
  init_home 1 alpha
  init_home 2 beta
  init_home 3 gamma
  home="$CODEX_ACCOUNT_ROOT/1/home"
  spawn_blocker "$home"

  run bash -c "printf '1\\n' | script -qec '$CODEX_SWITCH' /dev/null"
  [ "$status" -eq 0 ]
  kill -0 "$BLOCKER_PID"
  [[ "$output" != *"Kill running Codex process(es)?"* ]]
  grep -Fx "home=$CODEX_SHARED_HOME" "$TRACE_FILE"
  grep -Fx "account_home=$home" "$TRACE_FILE"
}

@test "same-account bypass is rejected when a conflicting home is also present" {
  init_home 1 alpha
  init_home 2 beta
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  uid=$(id -u)
  home="$CODEX_ACCOUNT_ROOT/1/home"
  write_proc_process 610 1 610 610 "$uid" codex "$home" /vendor/bin/codex --yolo
  write_proc_process 620 1 620 620 "$uid" codex '<unset>' /vendor/bin/codex app-server

  run "$CODEX_SWITCH" launch 1
  [ "$status" -eq 75 ]
  [ ! -e "$TRACE_FILE" ]
  [[ "$output" == *"account=1"* ]]
  [[ "$output" == *"account=legacy/default"* ]]
  [[ "$output" == *"use --kill or close them first"* ]]
}

@test "default detector preserves a selected plus unset home in one PGID as mixed" {
  init_home 1 alpha
  init_home 2 beta
  init_home 3 gamma
  export CODEX_SWITCH_PROCESS_CHECK=
  uid=$(id -u)
  home="$CODEX_ACCOUNT_ROOT/1/home"
  write_proc_process 625 1 625 625 "$uid" MainThread "$home" node "$CODEX_BIN" --yolo
  write_proc_process 626 625 625 625 "$uid" codex '<unset>' /vendor/bin/codex --yolo

  run "$CODEX_SWITCH" launch 1
  [ "$status" -eq 75 ]
  [ ! -e "$TRACE_FILE" ]
  [[ "$output" == *"account=external"* ]]
  [[ "$output" == *"use --kill or close them first"* ]]
}

@test "external mixed and other-account homes do not use the same-account bypass" {
  init_home 1 alpha
  init_home 2 beta
  init_home 3 gamma
  for blocker_home in "$CODEX_ACCOUNT_ROOT/2/home" /srv/external-codex '<mixed>'; do
    cat >"$TEST_ROOT/conflicting-detector" <<SH
#!/usr/bin/env bash
printf '630\tcli\t?\t%s\t630\\n' '$blocker_home'
SH
    chmod 700 "$TEST_ROOT/conflicting-detector"
    export CODEX_SWITCH_PROCESS_CHECK="$TEST_ROOT/conflicting-detector"

    run "$CODEX_SWITCH" launch 1
    [ "$status" -eq 75 ]
    [ ! -e "$TRACE_FILE" ]
    [[ "$output" == *"use --kill or close them first"* ]]
  done
}

@test "launch supports arbitrary positive slot numbers after creation" {
  init_home 4 delta
  init_home 5 epsilon
  init_home 8 theta
  init_home 9 iota

  run "$CODEX_SWITCH" launch 4
  [ "$status" -eq 0 ]
  grep -Fx "account_home=$CODEX_ACCOUNT_ROOT/4/home" "$TRACE_FILE"
  rm -f "$TRACE_FILE"

  run "$CODEX_SWITCH" launch 5
  [ "$status" -eq 0 ]
  grep -Fx "account_home=$CODEX_ACCOUNT_ROOT/5/home" "$TRACE_FILE"
  rm -f "$TRACE_FILE"

  run "$CODEX_SWITCH" launch 8
  [ "$status" -eq 0 ]
  grep -Fx "account_home=$CODEX_ACCOUNT_ROOT/8/home" "$TRACE_FILE"
  rm -f "$TRACE_FILE"

  run "$CODEX_SWITCH" launch 9 -- probe-overlay
  [ "$status" -eq 0 ]
  grep -Fx "account_home=$CODEX_ACCOUNT_ROOT/9/home" "$TRACE_FILE"
  grep -Fx 'account=acct-iota-0009' "$TRACE_FILE"

  for unsupported in 6 7 0 01; do
    run "$CODEX_SWITCH" launch "$unsupported"
    [ "$status" -ne 0 ]
  done

  run "$CODEX_SWITCH" add 12
  [ "$status" -eq 0 ]
  write_auth beta "$CODEX_ACCOUNT_ROOT/12/auth.json"
  run "$CODEX_SWITCH" launch 12 -- --version
  [ "$status" -eq 0 ]
  grep -Fx "account_home=$CODEX_ACCOUNT_ROOT/12/home" "$TRACE_FILE"
}

@test "launch rejects a missing or symlinked auth file" {
  init_home 8
  run "$CODEX_SWITCH" launch 8
  [ "$status" -eq 66 ]
  [ ! -e "$TRACE_FILE" ]

  write_auth alpha "$TEST_ROOT/external-auth.json"
  ln -s "$TEST_ROOT/external-auth.json" "$CODEX_ACCOUNT_ROOT/8/auth.json"
  run "$CODEX_SWITCH" launch 8
  [ "$status" -eq 66 ]
  [ ! -e "$TRACE_FILE" ]
}

@test "launch rejects permissive auth files and account directories" {
  init_home 1 alpha

  chmod 644 "$CODEX_ACCOUNT_ROOT/1/auth.json"
  run "$CODEX_SWITCH" launch 1
  [ "$status" -eq 66 ]
  rm -f "$TRACE_FILE"

  chmod 600 "$CODEX_ACCOUNT_ROOT/1/auth.json"
  chmod 755 "$CODEX_ACCOUNT_ROOT/1"
  run "$CODEX_SWITCH" launch 1
  [ "$status" -eq 75 ]
  rm -f "$TRACE_FILE"

  chmod 700 "$CODEX_ACCOUNT_ROOT/1"
  chmod 644 "$CODEX_SHARED_HOME/auth.json"
  run "$CODEX_SWITCH" launch 1
  [ "$status" -eq 75 ]
  [ ! -e "$TRACE_FILE" ]
}

@test "login uses the selected home and device authentication" {
  run "$CODEX_SWITCH" add 8
  [ "$status" -eq 0 ]
  run "$CODEX_SWITCH" login 8
  [ "$status" -eq 0 ]
  grep -Fx "home=$CODEX_SHARED_HOME" "$TRACE_FILE"
  grep -Fx "account_home=$CODEX_ACCOUNT_ROOT/8/home" "$TRACE_FILE"
  grep -Fx 'args=<login><--device-auth>' "$TRACE_FILE"
  grep -F 'raw_args=<-c><cli_auth_credentials_store=file><login><--device-auth>' "$TRACE_FILE"
  grep -F '"account_id":"acct-login"' "$CODEX_ACCOUNT_ROOT/8/auth.json"
}

@test "browser login and launch request file credential storage" {
  run "$CODEX_SWITCH" add 2
  [ "$status" -eq 0 ]
  run "$CODEX_SWITCH" login 2 --browser
  [ "$status" -eq 0 ]
  grep -Fx 'args=<login>' "$TRACE_FILE"
  grep -F 'raw_args=<-c><cli_auth_credentials_store=file><login>' "$TRACE_FILE"
  run "$CODEX_SWITCH" launch 2 -- --version
  [ "$status" -eq 0 ]
  grep -F 'raw_args=<--no-daemon><-c><cli_auth_credentials_store=file><--version>' "$TRACE_FILE"
}

@test "successful CLI login without a slot auth file is rejected" {
  run "$CODEX_SWITCH" add 1
  [ "$status" -eq 0 ]
  export FAKE_SKIP_FILE_AUTH=1
  run "$CODEX_SWITCH" login 1
  [ "$status" -eq 75 ]
  [[ "$output" == *"file-based slot login was not created"* ]]
  [ ! -s "$CODEX_ACCOUNT_ROOT/1/auth.json" ]
}

@test "file credential storage rejection stops login without fallback" {
  run "$CODEX_SWITCH" add 1
  [ "$status" -eq 0 ]
  export FAKE_REJECT_FILE_AUTH=1
  run "$CODEX_SWITCH" login 1
  [ "$status" -eq 86 ]
  [ ! -s "$CODEX_ACCOUNT_ROOT/1/auth.json" ]
}

@test "legacy mutation commands are rejected" {
  for command in switch capture import status; do
    run "$CODEX_SWITCH" "$command" 1 "$TEST_ROOT/source"
    [ "$status" -eq 64 ]
    [[ "$output" == *"legacy auth-file switching is disabled"* ]]
  done
}

@test "bare invocation requires a TTY" {
  run "$CODEX_SWITCH"
  [ "$status" -eq 64 ]
  [[ "$output" == *"interactive menu requires a TTY"* ]]
}

@test "TTY menu launches the selected account home" {
  init_home 1 alpha
  init_home 2 beta
  init_home 3 gamma
  init_home 4 delta
  init_home 5 epsilon
  init_home 8 theta

  run bash -c "printf '8\\n' | script -qec '$CODEX_SWITCH' /dev/null"
  [ "$status" -eq 0 ]
  grep -Fx "home=$CODEX_SHARED_HOME" "$TRACE_FILE"
  grep -Fx "account_home=$CODEX_ACCOUNT_ROOT/8/home" "$TRACE_FILE"
}

@test "TTY Enter defaults to killing blockers before launch" {
  init_home 1 alpha
  spawn_blocker

  run bash -c "printf '\\n' | script -qec '$CODEX_SWITCH launch 1' /dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Kill running Codex process(es)? [Y/n]:"* ]]
  ! kill -0 "$BLOCKER_PID" 2>/dev/null
  grep -Fx "home=$CODEX_SHARED_HOME" "$TRACE_FILE"
  grep -Fx "account_home=$CODEX_ACCOUNT_ROOT/1/home" "$TRACE_FILE"
}

@test "TTY Y kills blockers before launch" {
  init_home 1 alpha
  spawn_blocker

  run bash -c "printf 'Y\\n' | script -qec '$CODEX_SWITCH launch 1' /dev/null"
  [ "$status" -eq 0 ]
  ! kill -0 "$BLOCKER_PID" 2>/dev/null
  grep -Fx "home=$CODEX_SHARED_HOME" "$TRACE_FILE"
  grep -Fx "account_home=$CODEX_ACCOUNT_ROOT/1/home" "$TRACE_FILE"
}

@test "TTY N keeps blockers and cancels launch" {
  init_home 1 alpha
  spawn_blocker

  run bash -c "printf 'N\\n' | script -qec '$CODEX_SWITCH launch 1' /dev/null"
  [ "$status" -eq 0 ]
  kill -0 "$BLOCKER_PID"
  [ ! -e "$TRACE_FILE" ]
  [[ "$output" == *"Launch canceled; running Codex process(es) were not killed"* ]]
}

@test "TTY unexpected input keeps blockers and cancels launch" {
  init_home 1 alpha
  spawn_blocker

  run bash -c "printf 'maybe\\n' | script -qec '$CODEX_SWITCH launch 1' /dev/null"
  [ "$status" -eq 0 ]
  kill -0 "$BLOCKER_PID"
  [ ! -e "$TRACE_FILE" ]
}

@test "non-TTY launch refuses blockers without explicit kill" {
  init_home 1 alpha
  spawn_blocker

  run "$CODEX_SWITCH" launch 1
  [ "$status" -eq 75 ]
  kill -0 "$BLOCKER_PID"
  [ ! -e "$TRACE_FILE" ]
  [[ "$output" == *"use --kill or close them first"* ]]
}

@test "non-TTY launch with --kill terminates blockers and launches" {
  init_home 1 alpha
  spawn_blocker "$CODEX_ACCOUNT_ROOT/1/home"

  run "$CODEX_SWITCH" launch 1 --kill
  [ "$status" -eq 0 ]
  ! kill -0 "$BLOCKER_PID" 2>/dev/null
  grep -Fx "home=$CODEX_SHARED_HOME" "$TRACE_FILE"
  grep -Fx "account_home=$CODEX_ACCOUNT_ROOT/1/home" "$TRACE_FILE"
}

@test "--kill preserves an unrelated sibling in the Codex process group" {
  init_home 1 alpha
  setsid bash -c 'sleep 30 & echo $! >"$1"; sleep 30 & echo $! >"$2"; wait' \
    bash "$TEST_ROOT/codex-pid" "$TEST_ROOT/other-pid" &
  BLOCKER_PID=$!
  for _ in {1..20}; do
    [ -s "$TEST_ROOT/codex-pid" ] && [ -s "$TEST_ROOT/other-pid" ] && break
    sleep 0.05
  done
  codex_pid=$(<"$TEST_ROOT/codex-pid")
  other_pid=$(<"$TEST_ROOT/other-pid")
  cat >"$TEST_ROOT/detect-processes" <<SH
#!/usr/bin/env bash
if kill -0 '$codex_pid' 2>/dev/null && ! ps -o stat= -p '$codex_pid' | grep -q Z; then
  printf '%s\tcli\t?\t<unset>\t%s,%s\n' '$BLOCKER_PID' '$BLOCKER_PID' '$codex_pid'
  exit 0
fi
exit 1
SH
  chmod 700 "$TEST_ROOT/detect-processes"
  export CODEX_SWITCH_PROCESS_CHECK="$TEST_ROOT/detect-processes"

  run "$CODEX_SWITCH" launch 1 --kill -- --version
  [ "$status" -eq 0 ]
  kill -0 "$other_pid"
  ! ps -o stat= -p "$other_pid" | grep -q Z
}

@test "launch refuses when a detector still reports blockers after termination" {
  init_home 1 alpha
  cat >"$TEST_ROOT/stubborn-detector" <<'SH'
#!/usr/bin/env bash
printf '999999\tdesktop-proxy\t?\t<unset>\t999999\n'
exit 0
SH
  chmod 700 "$TEST_ROOT/stubborn-detector"
  export CODEX_SWITCH_PROCESS_CHECK="$TEST_ROOT/stubborn-detector"

  run "$CODEX_SWITCH" launch 1 --kill
  [ "$status" -eq 75 ]
  [ ! -e "$TRACE_FILE" ]
  [[ "$output" == *"Codex process group could not be terminated; launch aborted"* ]]
}

@test "launch refuses when a new detector session appears after termination" {
  init_home 1 alpha
  printf '0\n' >"$TEST_ROOT/detector-count"
  export DETECTOR_COUNT="$TEST_ROOT/detector-count"
  cat >"$TEST_ROOT/respawn-detector" <<'SH'
#!/usr/bin/env bash
count=$(cat "$DETECTOR_COUNT")
count=$((count + 1))
printf '%s\n' "$count" >"$DETECTOR_COUNT"
if [ "$count" -le 2 ]; then
  printf '999998\tdesktop-proxy\t?\t<unset>\t999998\n'
else
  printf '999999\tdesktop-proxy\t?\t<unset>\t999999\n'
fi
exit 0
SH
  chmod 700 "$TEST_ROOT/respawn-detector"
  export CODEX_SWITCH_PROCESS_CHECK="$TEST_ROOT/respawn-detector"

  run "$CODEX_SWITCH" launch 1 --kill
  [ "$status" -eq 75 ]
  [ ! -e "$TRACE_FILE" ]
  [[ "$output" == *"Codex process(es) respawned; launch aborted"* ]]
}

@test "account home root symlinks and nonempty mountpoints are rejected" {
  mkdir -m 700 "$TEST_ROOT/real-home"
  mkdir -p "$CODEX_ACCOUNT_ROOT/1"
  ln -s "$TEST_ROOT/real-home" "$CODEX_ACCOUNT_ROOT/1/home"
  run "$CODEX_SWITCH" login 1
  [ "$status" -eq 75 ]

  rm "$CODEX_ACCOUNT_ROOT/1/home"
  init_home 1 alpha
  printf '%s\n' unsafe >"$CODEX_ACCOUNT_ROOT/1/home/unexpected"
  run "$CODEX_SWITCH" launch 1
  [ "$status" -eq 75 ]
}
