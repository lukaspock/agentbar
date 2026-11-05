#!/bin/bash
# remove-agent-user.sh - undo setup-agent-user.sh, or emergency-stop the agent.
#
#   sudo Scripts/remove-agent-user.sh --panic       stop daemon + kill all agent processes
#   sudo Scripts/remove-agent-user.sh [--yes]       full removal (asks for confirmation)
# Options: --keep-home (keep /Users/agentbar), --dry-run (print only, no root needed)
# The user is only deleted after --yes or after typing the user name.
set -euo pipefail

AGENT_USER="agentbar"
AGENT_GROUP="agentbar-ipc"
AGENT_HOME="/Users/${AGENT_USER}"
IPC_DIR="/Users/Shared/AgentBar"
LABEL="com.agentbar.host"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"
HOST_DIR="/usr/local/libexec/agentbar"
CLI_DST="/usr/local/bin/agentbar"
LOG_FILE="/Users/agentbar/host.log"

cd /
DRY_RUN=0
PANIC=0
YES=0
KEEP_HOME=0
STEP=0

usage() {
  cat <<USAGE
Usage: sudo $0 [--panic] [--yes] [--keep-home] [--dry-run]
  --panic      emergency stop only: bootout daemon, kill all processes of '${AGENT_USER}'
  --yes        skip the typed confirmation before deleting the user
  --keep-home  keep ${AGENT_HOME} when deleting the user
  --dry-run    only print actions, change nothing (works without root)
USAGE
}

step() { STEP=$((STEP + 1)); printf '\n[%d] %s\n' "$STEP" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '    WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '    [dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}
# Like run, but a failure is only reported (e.g. nothing to kill).
run_soft() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '    [dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@" || info "(exit $? ignored: $1)"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --panic) PANIC=1 ;;
    --yes) YES=1 ;;
    --keep-home) KEEP_HOME=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $1" ;;
  esac
  shift
done

[[ "$(uname -s)" == "Darwin" ]] || die "macOS only"
if [[ $DRY_RUN -eq 0 && $EUID -ne 0 ]]; then
  die "must run as root (use sudo), or pass --dry-run"
fi
[[ $DRY_RUN -eq 1 ]] && printf 'DRY RUN: nothing will be changed.\n'

user_exists()  { dscl . -read "/Users/${AGENT_USER}" UniqueID >/dev/null 2>&1; }
group_exists() { dscl . -read "/Groups/${AGENT_GROUP}" PrimaryGroupID >/dev/null 2>&1; }
daemon_loaded() { launchctl print "system/${LABEL}" >/dev/null 2>&1; }

stop_daemon() {
  if daemon_loaded; then
    run_soft launchctl bootout "system/${LABEL}"
  else
    info "daemon not loaded"
  fi
}

kill_agent_processes() {
  if ! user_exists; then info "user does not exist, no processes to kill"; return; fi
  if pgrep -u "$AGENT_USER" >/dev/null 2>&1; then
    info "processes of ${AGENT_USER}: $(pgrep -u "$AGENT_USER" | wc -l | tr -d ' ')"
    run_soft pkill -TERM -u "$AGENT_USER"
    if [[ $DRY_RUN -eq 0 ]]; then
      sleep 2
      if pgrep -u "$AGENT_USER" >/dev/null 2>&1; then
        info "still running, sending SIGKILL"
        run_soft pkill -KILL -u "$AGENT_USER"
      fi
    else
      run_soft pkill -KILL -u "$AGENT_USER"
    fi
  else
    info "no running processes"
  fi
}

# ---------------------------------------------------------------- panic
if [[ $PANIC -eq 1 ]]; then
  step "PANIC: stop LaunchDaemon ${LABEL}"
  stop_daemon
  step "PANIC: kill all processes of '${AGENT_USER}'"
  kill_agent_processes
  printf '\nAgent stopped. User and files are untouched. Restart: sudo launchctl bootstrap system %s\n' "$PLIST_DST"
  exit 0
fi

# ---------------------------------------------------------------- safety
# Fixed names only; refuse anything that could hit a real account.
[[ "$AGENT_USER" == "agentbar" ]] || die "internal: unexpected user name"
if user_exists; then
  uid="$(id -u "$AGENT_USER")"
  # Role account (UID 200..399, shell /usr/bin/false) or a legacy login account; never a system account.
  [[ "$uid" -ge 200 ]] || die "refusing: UID $uid is a system account"
  shell="$(dscl . -read "/Users/${AGENT_USER}" UserShell 2>/dev/null | awk '{print $2}')"
  if [[ "$uid" -lt 500 && "$shell" != "/usr/bin/false" ]]; then die "refusing: UID $uid with shell '${shell}' does not look like the agent role account"; fi
  [[ "${SUDO_USER:-}" != "$AGENT_USER" ]] || die "refusing: run as the owner, not the agent user"
  [[ "$(id -un 2>/dev/null)" != "$AGENT_USER" ]] || die "refusing: running as the agent user"
fi

# ---------------------------------------------------------------- confirm
if [[ $DRY_RUN -eq 1 ]]; then
  info "would require --yes or typing the user name '${AGENT_USER}' before deleting"
elif [[ $YES -eq 0 ]]; then
  [[ -t 0 ]] || die "not a terminal; pass --yes to confirm non-interactively"
  printf 'This deletes user "%s"%s and the IPC data. Type the user name to confirm: ' \
    "$AGENT_USER" "$([[ $KEEP_HOME -eq 1 ]] && echo ' (home kept)' || echo ' including its home')"
  read -r answer
  [[ "$answer" == "$AGENT_USER" ]] || die "confirmation did not match; aborted"
fi

# ---------------------------------------------------------------- removal
step "Stop LaunchDaemon"
stop_daemon

step "Kill remaining processes of '${AGENT_USER}'"
kill_agent_processes

step "Remove LaunchDaemon files, host, CLI and log"
for f in "$PLIST_DST" "$CLI_DST" "$LOG_FILE"; do
  if [[ -e "$f" ]]; then run rm -f -- "$f"; else info "absent: $f"; fi
done
if [[ -d "$HOST_DIR" ]]; then run rm -rf -- "$HOST_DIR"; else info "absent: $HOST_DIR"; fi

step "Remove setup status/staging data"
if [[ -d "/Library/Application Support/AgentBar" ]]; then run rm -rf -- "/Library/Application Support/AgentBar"; else info "absent"; fi

step "Remove IPC directory ${IPC_DIR}"
if [[ -d "$IPC_DIR" ]]; then run rm -rf -- "$IPC_DIR"; else info "absent"; fi

step "Delete user '${AGENT_USER}'"
if user_exists; then
  # Role accounts are plain dscl records, so delete the record directly (sysadminctl may not know them).
  run dscl . -delete "/Users/${AGENT_USER}"
  if [[ $KEEP_HOME -eq 1 ]]; then
    info "home kept: ${AGENT_HOME}"
  elif [[ -d "$AGENT_HOME" && ! -L "$AGENT_HOME" ]]; then
    run rm -rf -- "$AGENT_HOME"
  fi
else
  info "user does not exist"
fi

step "Delete group '${AGENT_GROUP}'"
if group_exists; then run dseditgroup -o delete "$AGENT_GROUP"; else info "group does not exist"; fi

printf '\nDone%s. The owner may need to log out/in to drop the stale group membership.\n' \
  "$([[ $DRY_RUN -eq 1 ]] && echo ' (dry run)')"
