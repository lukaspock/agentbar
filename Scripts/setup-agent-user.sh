#!/bin/bash
# setup-agent-user.sh - create the hidden, non-admin "agentbar" macOS user,
# the IPC group/directories and (if the host binary exists) the LaunchDaemon.
#
# Idempotent: every step checks the current state first. Run as admin:
#   sudo Scripts/setup-agent-user.sh [--owner NAME] [--host-binary PATH]
#                                    [--cli-binary PATH] [--set-token] [--dry-run]
# --dry-run prints what would happen, changes nothing and needs no root.
set -euo pipefail

AGENT_USER="agentbar"
AGENT_GROUP="agentbar-ipc"
AGENT_HOME="/Users/${AGENT_USER}"
IPC_DIR="/Users/Shared/AgentBar"
WORK_DIR="${AGENT_HOME}/work"
LABEL="com.agentbar.host"
PLIST_DST="/Library/LaunchDaemons/${LABEL}.plist"
HOST_DST="/usr/local/libexec/agentbar/agentbar-host"
CLI_DST="/usr/local/bin/agentbar"
TOKEN_FILE_REL=".config/agentbar/claude-oauth-token"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/${LABEL}.plist.template"
cd /   # avoid cwd problems when running commands as another user

DRY_RUN=0
SET_TOKEN=0
OWNER="${SUDO_USER:-}"
HOST_SRC=""
CLI_SRC=""
STEP=0
WARNINGS=0

usage() {
  cat <<USAGE
Usage: sudo $0 [options]
  --owner NAME        user who gets access to the IPC group (default: \$SUDO_USER)
  --host-binary PATH  agentbar-host binary to install (root-owned, 0755)
  --cli-binary PATH   agentbar CLI to install to ${CLI_DST}
  --set-token         (re)store the Claude OAuth token interactively (hidden input)
  --dry-run           only print actions, change nothing (works without root)
  -h, --help          show this help
USAGE
}

step() { STEP=$((STEP + 1)); printf '\n[%d] %s\n' "$STEP" "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf '    WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Run a mutating command, or only print it in dry-run mode.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '    [dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --set-token) SET_TOKEN=1 ;;
    --owner) [[ $# -ge 2 ]] || die "--owner needs a value"; OWNER="$2"; shift ;;
    --owner=*) OWNER="${1#*=}" ;;
    --host-binary) [[ $# -ge 2 ]] || die "--host-binary needs a value"; HOST_SRC="$2"; shift ;;
    --host-binary=*) HOST_SRC="${1#*=}" ;;
    --cli-binary) [[ $# -ge 2 ]] || die "--cli-binary needs a value"; CLI_SRC="$2"; shift ;;
    --cli-binary=*) CLI_SRC="${1#*=}" ;;
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

# Owner = the human user that talks to the agent user.
[[ -n "$OWNER" ]] || die "owner unknown; pass --owner NAME (SUDO_USER is empty)"
[[ "$OWNER" != "root" ]] || die "owner must not be root; pass --owner NAME"
[[ "$OWNER" != "$AGENT_USER" ]] || die "owner must not be the agent user"
id -u "$OWNER" >/dev/null 2>&1 || die "owner '$OWNER' does not exist"
[[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE"
# Paths end up in a plist; keep them to a harmless character set.
for p in "$HOST_DST" "$AGENT_HOME" "$IPC_DIR"; do
  [[ "$p" =~ ^/[A-Za-z0-9._/@+-]+$ ]] || die "unsafe path: $p"
done

user_exists()  { id -u "${AGENT_USER}" >/dev/null 2>&1; }
group_exists() { dscl . -read "/Groups/${AGENT_GROUP}" PrimaryGroupID >/dev/null 2>&1; }
is_member()    { dseditgroup -o checkmember -m "$1" "$2" >/dev/null 2>&1; }
daemon_loaded() { launchctl print "system/${LABEL}" >/dev/null 2>&1; }

# ---------------------------------------------------------------- 1. user
step "Agent user '${AGENT_USER}' (standard user, no admin, hidden)"
if user_exists; then
  info "user exists, skipping creation"
else
  info "creating user; sysadminctl will ask for a password interactively"
  run sysadminctl -addUser "$AGENT_USER" -fullName "AgentBar Agent" \
      -home "$AGENT_HOME" -password -
fi
if user_exists && [[ "$(dscl . -read "/Users/${AGENT_USER}" IsHidden 2>/dev/null | awk '{print $2}')" == "1" ]]; then
  info "already hidden"
else
  run dscl . -create "/Users/${AGENT_USER}" IsHidden 1
fi
if user_exists && is_member "$AGENT_USER" admin; then
  die "'${AGENT_USER}' is an admin; remove it from the admin group first"
else
  info "not in admin group"
fi
if user_exists; then
  uid="$(id -u "$AGENT_USER")"
  [[ "$uid" -ge 501 ]] || warn "UID is $uid (<501); hiding via IsHidden may not apply"
fi

# ---------------------------------------------------------------- 2. homes
step "Home permissions"
if [[ -d "$AGENT_HOME" ]]; then
  # sysadminctl can leave the home owned by root; the agent must own its home.
  if [[ "$(stat -f %Su "$AGENT_HOME")" != "$AGENT_USER" ]]; then
    run chown "$AGENT_USER":staff "$AGENT_HOME"
  fi
  if [[ "$(stat -f %Lp "$AGENT_HOME")" == "700" ]]; then
    info "${AGENT_HOME} already 700"
  else
    run chmod 700 "$AGENT_HOME"
  fi
else
  info "${AGENT_HOME} does not exist yet (dry-run before creation); would be set to 700"
fi
owner_home="$(dscl . -read "/Users/${OWNER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
if [[ -n "$owner_home" && -d "$owner_home" ]]; then
  omode="$(stat -f %Lp "$owner_home")"
  if [[ "$omode" != "700" ]]; then
    warn "owner home ${owner_home} is mode ${omode}; the agent could read it. Fix: chmod 700 '${owner_home}'"
  else
    info "owner home ${owner_home} is 700"
  fi
  # The default "group:everyone deny delete" ACL is normal; only flag allow entries.
  acl_out="$(ls -lde "$owner_home" 2>/dev/null || true)"
  if grep -q ' allow ' <<<"$acl_out"; then
    warn "owner home has allow-ACL entries; review with: ls -lde '${owner_home}'"
  fi
else
  warn "could not determine home of owner '${OWNER}'"
fi

# ---------------------------------------------------------------- 3. group
step "IPC group '${AGENT_GROUP}'"
if group_exists; then
  info "group exists"
else
  run dseditgroup -o create -r "AgentBar IPC" "$AGENT_GROUP"
fi
for m in "$AGENT_USER" "$OWNER"; do
  if group_exists && is_member "$m" "$AGENT_GROUP"; then
    info "'${m}' already member"
  else
    run dseditgroup -o edit -a "$m" -t user "$AGENT_GROUP"
  fi
done
info "NOTE: '${OWNER}' must log out and back in (or restart AgentBar from a new login) for the group to take effect."

# ---------------------------------------------------------------- 4. dirs
step "Directories"
agent_gid_group="$AGENT_GROUP"
if [[ -d "$IPC_DIR" ]]; then
  info "${IPC_DIR} exists; enforcing owner/mode"
fi
# install -d is idempotent and (re)applies owner and mode.
if user_exists || [[ $DRY_RUN -eq 1 ]]; then
  # Owned by the OWNER (not the agent), group-readable only: the agent must not be able
  # to replace the socket or token.agent. The server enforces owner + 0750 (fail-closed).
  run install -d -o "$OWNER" -g "$agent_gid_group" -m 0750 "$IPC_DIR"
  run chmod 0750 "$IPC_DIR"
  run install -d -o "$AGENT_USER" -g staff -m 700 "$WORK_DIR"
fi

# ---------------------------------------------------------------- 5. binaries
step "CLI binary (${CLI_DST})"
if [[ -n "$CLI_SRC" && -f "$CLI_SRC" ]]; then
  run install -d -o root -g wheel -m 755 "$(dirname "$CLI_DST")"
  if [[ -f "$CLI_DST" ]] && cmp -s "$CLI_SRC" "$CLI_DST"; then
    info "up to date"
  else
    run install -o root -g wheel -m 755 "$CLI_SRC" "$CLI_DST"
  fi
elif [[ -n "$CLI_SRC" ]]; then
  warn "--cli-binary '${CLI_SRC}' not found; skipping CLI install"
elif [[ -f "$CLI_DST" ]]; then
  info "already installed (no --cli-binary given)"
else
  warn "no CLI installed; pass --cli-binary PATH to install it (skipped)"
fi

step "Host binary (${HOST_DST})"
HOST_READY=0
HOST_CHANGED=0
if [[ -n "$HOST_SRC" && -f "$HOST_SRC" ]]; then
  run install -d -o root -g wheel -m 755 "$(dirname "$HOST_DST")"
  if [[ -f "$HOST_DST" ]] && cmp -s "$HOST_SRC" "$HOST_DST"; then
    info "up to date"
  else
    run install -o root -g wheel -m 755 "$HOST_SRC" "$HOST_DST"
    HOST_CHANGED=1
  fi
  HOST_READY=1
elif [[ -n "$HOST_SRC" ]]; then
  warn "--host-binary '${HOST_SRC}' not found; the host is built in stage 2. Skipping daemon."
elif [[ -f "$HOST_DST" ]]; then
  info "already installed (no --host-binary given)"
  HOST_READY=1
else
  warn "host binary not available yet (built in stage 2); skipping LaunchDaemon. Re-run with --host-binary PATH later."
fi

# ---------------------------------------------------------------- 6. daemon
step "LaunchDaemon (${PLIST_DST})"
if [[ $HOST_READY -eq 0 ]]; then
  info "skipped (no host binary)"
else
  rendered="$(mktemp -t agentbar-plist)"
  trap 'rm -f "$rendered"' EXIT
  sed -e "s|@HOST_BINARY@|${HOST_DST}|g" \
      -e "s|@AGENT_USER@|${AGENT_USER}|g" \
      -e "s|@AGENT_GROUP@|${AGENT_GROUP}|g" \
      -e "s|@AGENT_HOME@|${AGENT_HOME}|g" \
      -e "s|@IPC_DIR@|${IPC_DIR}|g" \
      "$TEMPLATE" > "$rendered"
  if grep -q '@[A-Z_]*@' "$rendered"; then die "unreplaced placeholder in rendered plist"; fi
  plutil -lint "$rendered" >/dev/null || die "rendered plist is invalid"
  info "rendered plist is valid"

  plist_changed=1
  if [[ -f "$PLIST_DST" ]] && cmp -s "$rendered" "$PLIST_DST"; then plist_changed=0; fi

  if [[ $plist_changed -eq 1 ]]; then
    if daemon_loaded; then run launchctl bootout "system/${LABEL}"; fi
    run install -o root -g wheel -m 644 "$rendered" "$PLIST_DST"
    run launchctl bootstrap system "$PLIST_DST"
  elif ! daemon_loaded; then
    run launchctl bootstrap system "$PLIST_DST"
  elif [[ $HOST_CHANGED -eq 1 ]]; then
    info "host binary changed, restarting daemon"
    run launchctl kickstart -k "system/${LABEL}"
  else
    info "plist unchanged and daemon loaded"
  fi
fi

# ---------------------------------------------------------------- 7. token
step "Claude OAuth token (stored in ${AGENT_HOME}/${TOKEN_FILE_REL}, mode 0600)"
if [[ $SET_TOKEN -eq 0 ]]; then
  info "skipped; run again with --set-token to store a token (e.g. from 'claude setup-token')"
else
  info "you will be prompted by the shell of '${AGENT_USER}'; input is hidden and never on a command line"
  # The token is read from the terminal inside the agent user's shell, so it
  # never appears in argv, the environment or this script's variables.
  # shellcheck disable=SC2016  # single quotes intended: runs in the inner shell
  run sudo -u "$AGENT_USER" -H /bin/bash -c '
    set -euo pipefail
    cd "$HOME"
    umask 077
    d="$HOME/.config/agentbar"
    mkdir -p "$d"; chmod 700 "$d"
    printf "Paste token (hidden), empty = keep existing: " >&2
    IFS= read -rs tok </dev/tty
    printf "\n" >&2
    if [ -z "$tok" ]; then echo "empty input, nothing changed" >&2; exit 0; fi
    tmp="$(mktemp "$d/.token.XXXXXX")"
    printf "%s\n" "$tok" > "$tmp"
    chmod 600 "$tmp"
    mv -f "$tmp" "$d/claude-oauth-token"
    unset tok
    echo "token stored (0600)" >&2
  '
fi

# ---------------------------------------------------------------- summary
printf '\nDone%s with %d warning(s).\n' "$([[ $DRY_RUN -eq 1 ]] && echo ' (dry run)')" "$WARNINGS"
cat <<NEXT
Next steps:
  - Log out and back in as '${OWNER}' so the '${AGENT_GROUP}' membership applies.
  - Log in once for the agent user, e.g.: sudo -u ${AGENT_USER} -H claude auth login
  - Emergency stop: sudo Scripts/remove-agent-user.sh --panic
NEXT
