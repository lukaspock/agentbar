#!/bin/bash
# setup-agent-user.sh - set up the hidden role account "agentbar", the IPC group/directory, the host binary,
# the CLI, the LaunchDaemon and (optionally) the Claude OAuth token. NON-INTERACTIVE: no TTY, no prompts.
#
# Normally started by the app through ONE admin prompt (App/Sources/Setup/AdminInstaller.swift), from a
# root-owned, hash-verified staging copy. Can also be run by hand:
#   sudo Scripts/setup-agent-user.sh --owner NAME [--host-binary PATH] [--cli-binary PATH]
#                                    [--token-file PATH] [--steps LIST] [--dry-run]
# --dry-run prints what would happen, changes nothing and needs no root.
#
# Progress: JSON lines are appended to /Library/Application Support/AgentBar/setup-status.jsonl (root-owned,
# world-readable) so the app can show progress while the admin prompt is open. Fixed path, not an argument.
#
# A NEW account is a ROLE account (like _www): dscl record, UID in 200..399 (hidden), shell /usr/bin/false,
# no password, no login. An EXISTING account (e.g. an old sysadminctl user, uid 502) is ADOPTED: its UniqueID
# is never changed (macOS refuses that with eDSPermissionError -14120). It is hardened best effort (hidden,
# shell /usr/bin/false, password '*', no AuthenticationAuthority); a failed hardening step only warns.
# --migrate is accepted for older callers and ignored.
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
TOKEN_DIR_REL=".config/agentbar"
TOKEN_NAME="claude-oauth-token"
STATUS_DIR="/Library/Application Support/AgentBar"
STATUS_FILE="${STATUS_DIR}/setup-status.jsonl"
UID_MIN=200
UID_MAX=399

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="${SCRIPT_DIR}/${LABEL}.plist.template"
cd /   # avoid cwd problems when running commands as another user
umask 022

DRY_RUN=0
WARN_MIGRATE=0
OWNER=""
HOST_SRC=""
CLI_SRC=""
TOKEN_SRC=""
RUN_ID="manual"
STEPS="agentUser,hostBinary,cli,claudeToken"
CURRENT_STEP="setup"
WARNINGS=0
SEQ=0
HOST_CHANGED=0

usage() {
  cat <<USAGE
Usage: sudo $0 --owner NAME [options]
  --owner NAME        human user who owns the IPC directory (required; SUDO_USER is not used)
  --host-binary PATH  agentbar-host binary to install to ${HOST_DST}
  --cli-binary PATH   agentbar CLI to install to ${CLI_DST}
  --token-file PATH   short-lived 0600 file holding the Claude token; moved into the agent home, source deleted
  --steps LIST        comma list of agentUser,hostBinary,cli,claudeToken (default: all)
  --run-id ID         tag for status lines (set by the app)
  --migrate           deprecated, ignored (an existing account is adopted without changing its UID)
  --dry-run           only print actions, change nothing (works without root)
  -h, --help          show this help
USAGE
}

# ---------------------------------------------------------------- output / status
json_escape() { printf '%s' "$1" | LC_ALL=C tr -d '\000-\037\177' | LC_ALL=C sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'; }

# emit STEP STATE MESSAGE  (state: running|info|done|warn|failed)
emit() {
  local step="$1" state="$2" msg="$3"
  SEQ=$((SEQ + 1))
  printf '[%s] %s: %s\n' "$step" "$state" "$msg"
  [[ $DRY_RUN -eq 1 ]] && return 0
  printf '{"seq":%d,"run":"%s","step":"%s","state":"%s","msg":"%s"}\n' \
    "$SEQ" "$(json_escape "$RUN_ID")" "$step" "$state" "$(json_escape "$msg")" >> "$STATUS_FILE" || true
}
info() { emit "$CURRENT_STEP" info "$*"; }
warn() { WARNINGS=$((WARNINGS + 1)); emit "$CURRENT_STEP" warn "$*" >&2; }
begin_step() { CURRENT_STEP="$1"; emit "$1" running "$2"; }
end_step() { emit "$CURRENT_STEP" "done" "${1:-ok}"; }
die() { emit "$CURRENT_STEP" failed "$*" >&2; exit 1; }
on_err() { emit "$CURRENT_STEP" failed "unexpected error at line $1" >&2; exit 1; }
trap 'on_err $LINENO' ERR

# Run a mutating command, or only print it in dry-run mode.
run() {
  if [[ $DRY_RUN -eq 1 ]]; then
    printf '    [dry-run]'; printf ' %q' "$@"; printf '\n'
  else
    "$@"
  fi
}

# ---------------------------------------------------------------- arguments
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --migrate) WARN_MIGRATE=1 ;;
    --owner) [[ $# -ge 2 ]] || die "--owner needs a value"; OWNER="$2"; shift ;;
    --owner=*) OWNER="${1#*=}" ;;
    --host-binary) [[ $# -ge 2 ]] || die "--host-binary needs a value"; HOST_SRC="$2"; shift ;;
    --host-binary=*) HOST_SRC="${1#*=}" ;;
    --cli-binary) [[ $# -ge 2 ]] || die "--cli-binary needs a value"; CLI_SRC="$2"; shift ;;
    --cli-binary=*) CLI_SRC="${1#*=}" ;;
    --token-file) [[ $# -ge 2 ]] || die "--token-file needs a value"; TOKEN_SRC="$2"; shift ;;
    --token-file=*) TOKEN_SRC="${1#*=}" ;;
    --steps) [[ $# -ge 2 ]] || die "--steps needs a value"; STEPS="$2"; shift ;;
    --steps=*) STEPS="${1#*=}" ;;
    --run-id) [[ $# -ge 2 ]] || die "--run-id needs a value"; RUN_ID="$2"; shift ;;
    --run-id=*) RUN_ID="${1#*=}" ;;
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
[[ $WARN_MIGRATE -eq 1 ]] && printf 'note: --migrate is deprecated and ignored; an existing account is adopted as is.\n'

# Status file: root-owned dir under /Library (not the sticky /tmp), recreated per run.
if [[ $DRY_RUN -eq 0 ]]; then
  [[ ! -L "$STATUS_DIR" ]] || die "status dir is a symlink"
  install -d -o root -g wheel -m 755 "$STATUS_DIR"
  [[ ! -L "$STATUS_FILE" ]] || rm -f -- "$STATUS_FILE"
  : > "$STATUS_FILE"
  chown root:wheel "$STATUS_FILE"; chmod 644 "$STATUS_FILE"
fi

# Names go through strict allow-lists; nothing user-supplied is ever interpolated into code.
[[ "$RUN_ID" =~ ^[A-Za-z0-9._-]{1,64}$ ]] || die "invalid --run-id"
[[ -n "$OWNER" ]] || die "owner unknown; pass --owner NAME"
[[ "$OWNER" =~ ^[A-Za-z0-9._-]{1,31}$ && "$OWNER" != -* ]] || die "invalid owner name"
[[ "$OWNER" != "root" ]] || die "owner must not be root"
[[ "$OWNER" != "$AGENT_USER" ]] || die "owner must not be the agent user"
id -u "$OWNER" >/dev/null 2>&1 || die "owner '$OWNER' does not exist"
[[ -f "$TEMPLATE" ]] || die "template not found: $TEMPLATE"
for p in "$HOST_DST" "$AGENT_HOME" "$IPC_DIR"; do
  [[ "$p" =~ ^/[A-Za-z0-9._/@+-]+$ ]] || die "unsafe path: $p"
done
want() { [[ ",${STEPS}," == *",$1,"* ]]; }
IFS=',' read -r -a _steps <<<"$STEPS"
for s in "${_steps[@]}"; do
  case "$s" in agentUser|hostBinary|cli|claudeToken) ;; *) die "unknown step: $s" ;; esac
done

user_exists()   { dscl . -read "/Users/${AGENT_USER}" UniqueID >/dev/null 2>&1; }
group_exists()  { dscl . -read "/Groups/${AGENT_GROUP}" PrimaryGroupID >/dev/null 2>&1; }
is_member()     { dseditgroup -o checkmember -m "$1" "$2" >/dev/null 2>&1; }
daemon_loaded() { launchctl print "system/${LABEL}" >/dev/null 2>&1; }
dscl_value()    { dscl . -read "/Users/${AGENT_USER}" "$1" 2>/dev/null | awk -v k="$1:" '$1==k {print $2}' | head -n 1; }

# ---------------------------------------------------------------- helpers: UID
# Next free UID in the role range: highest used UID in the range + 1; if the range top is reached, first gap.
pick_uid() {
  local used u max=$((UID_MIN - 1)) cand
  used="$(dscl . -list /Users UniqueID | awk '{print $2}')"
  for u in $used; do
    if [[ "$u" =~ ^[0-9]+$ ]] && [[ $u -ge $UID_MIN && $u -le $UID_MAX && $u -gt $max ]]; then max=$u; fi
  done
  cand=$((max + 1))
  if [[ $cand -gt $UID_MAX ]]; then
    for ((cand = UID_MIN; cand <= UID_MAX; cand++)); do
      grep -qx "$cand" <<<"$used" || break
    done
  fi
  [[ $cand -le $UID_MAX ]] || die "no free UID in ${UID_MIN}..${UID_MAX}"
  printf '%s\n' "$cand"
}

# ================================================================ step: agentUser
if want agentUser; then
  begin_step agentUser "role account '${AGENT_USER}'"
  if user_exists; then
    cur_uid="$(dscl_value UniqueID)"; cur_shell="$(dscl_value UserShell)"
    info "existing account: uid ${cur_uid:-?}, shell ${cur_shell:-?}"
    if [[ ! "$cur_uid" =~ ^[0-9]+$ ]]; then die "existing account has no numeric UniqueID"; fi
    [[ "$cur_uid" -ge 100 ]] || die "refusing: UID ${cur_uid} is a system account"
    if is_member "$AGENT_USER" admin; then die "'${AGENT_USER}' is an admin; remove it from the admin group first"; fi
  fi

  if ! user_exists; then
    new_uid="$(pick_uid)"
    info "creating role account with uid ${new_uid}"
    run dscl . -create "/Users/${AGENT_USER}"
    run dscl . -create "/Users/${AGENT_USER}" UniqueID "$new_uid"
    run dscl . -create "/Users/${AGENT_USER}" PrimaryGroupID 20
    run dscl . -create "/Users/${AGENT_USER}" UserShell /usr/bin/false
    run dscl . -create "/Users/${AGENT_USER}" RealName "AgentBar Agent"
    run dscl . -create "/Users/${AGENT_USER}" NFSHomeDirectory "$AGENT_HOME"
    run dscl . -create "/Users/${AGENT_USER}" Password '*'
    run dscl . -create "/Users/${AGENT_USER}" IsHidden 1
    if [[ $DRY_RUN -eq 0 ]]; then
      dscl . -create "/Users/${AGENT_USER}" GeneratedUID "$(uuidgen)"
      dscacheutil -flushcache 2>/dev/null || true
    fi
  else
    # Adopt: the UniqueID stays as it is. Every hardening write stands alone; a refusal only warns, and
    # nothing is stopped because of it (the daemon keeps running).
    info "adopting existing account '${AGENT_USER}' (uid ${cur_uid}); UID unchanged"
    [[ "$(dscl_value IsHidden)" == "1" ]] || run dscl . -create "/Users/${AGENT_USER}" IsHidden 1 \
      || warn "could not hide '${AGENT_USER}' (directory service refused)"
    [[ "$cur_shell" == "/usr/bin/false" ]] || run dscl . -create "/Users/${AGENT_USER}" UserShell /usr/bin/false \
      || warn "could not set the shell of '${AGENT_USER}' to /usr/bin/false"
    run dscl . -create "/Users/${AGENT_USER}" Password '*' \
      || warn "could not set the password of '${AGENT_USER}' to '*'"
    if dscl . -read "/Users/${AGENT_USER}" AuthenticationAuthority >/dev/null 2>&1; then
      run dscl . -delete "/Users/${AGENT_USER}" AuthenticationAuthority \
        || warn "could not remove AuthenticationAuthority of '${AGENT_USER}'"
    fi
    if dscl . -read "/Users/${AGENT_USER}" PasswordPolicyOptions >/dev/null 2>&1; then
      run dscl . -delete "/Users/${AGENT_USER}" PasswordPolicyOptions \
        || warn "could not remove PasswordPolicyOptions of '${AGENT_USER}'"
    fi
    [[ $DRY_RUN -eq 1 ]] || dscacheutil -flushcache 2>/dev/null || true
    # Fail closed: the adopted account must end up unable to log in (shell false, OR no
    # AuthenticationAuthority and password '*'/empty). Otherwise stop before token/IPC/daemon steps.
    if [[ $DRY_RUN -eq 0 ]]; then
      a_shell="$(dscl_value UserShell)"
      a_pw="$(dscl_value Password)"
      a_auth=0; dscl . -read "/Users/${AGENT_USER}" AuthenticationAuthority >/dev/null 2>&1 && a_auth=1
      if [[ "$a_shell" != "/usr/bin/false" ]] && { [[ $a_auth -eq 1 ]] || { [[ -n "$a_pw" && "$a_pw" != "*" ]]; }; }; then
        die "adopted account '${AGENT_USER}' can still log in (shell ${a_shell:-?}); hardening was refused by the directory service, nothing further was changed"
      fi
    fi
  fi

  # Home: install -d is idempotent and (re)applies owner and mode.
  [[ ! -L "$AGENT_HOME" ]] || die "${AGENT_HOME} is a symlink"
  run install -d -o "$AGENT_USER" -g staff -m 700 "$AGENT_HOME"
  run install -d -o "$AGENT_USER" -g staff -m 700 "$WORK_DIR"

  owner_home="$(dscl . -read "/Users/${OWNER}" NFSHomeDirectory 2>/dev/null | awk '{print $2}')"
  if [[ -n "$owner_home" && -d "$owner_home" ]]; then
    omode="$(stat -f %Lp "$owner_home")"
    [[ "$omode" == "700" ]] || warn "owner home ${owner_home} is mode ${omode}; the agent could read it (fix: chmod 700)"
  fi

  # IPC group + directory. The directory carries the group, so files the owner creates inside inherit it and
  # no re-login is needed. Owner stays the directory owner (the agent must not replace socket/token).
  if group_exists; then info "group ${AGENT_GROUP} exists"; else run dseditgroup -o create -r "AgentBar IPC" "$AGENT_GROUP"; fi
  for m in "$AGENT_USER" "$OWNER"; do
    if group_exists && is_member "$m" "$AGENT_GROUP"; then :; else run dseditgroup -o edit -a "$m" -t user "$AGENT_GROUP"; fi
  done
  [[ ! -L "$IPC_DIR" ]] || die "${IPC_DIR} is a symlink"
  run install -d -o "$OWNER" -g "$AGENT_GROUP" -m 0750 "$IPC_DIR"
  end_step "role account, home, IPC group and directory ready"
fi

# ================================================================ step: cli
if want cli; then
  begin_step cli "CLI (${CLI_DST})"
  if [[ -n "$CLI_SRC" && -f "$CLI_SRC" && ! -L "$CLI_SRC" ]]; then
    run install -d -o root -g wheel -m 755 "$(dirname "$CLI_DST")"
    if [[ -f "$CLI_DST" ]] && cmp -s "$CLI_SRC" "$CLI_DST"; then
      info "up to date"
    else
      run install -o root -g wheel -m 755 "$CLI_SRC" "$CLI_DST"
    fi
    run xattr -c "$CLI_DST"
  elif [[ -f "$CLI_DST" ]]; then
    info "already installed (no --cli-binary given)"
  else
    die "no CLI binary given and none installed"
  fi
  end_step "CLI installed"
fi

# ================================================================ step: hostBinary
if want hostBinary; then
  begin_step hostBinary "host binary (${HOST_DST})"
  host_dir="$(dirname "$HOST_DST")"
  if [[ -n "$HOST_SRC" && -f "$HOST_SRC" && ! -L "$HOST_SRC" ]]; then
    [[ ! -L "$host_dir" ]] || die "${host_dir} is a symlink"
    run install -d -o root -g wheel -m 755 "$host_dir"
    run chown root:wheel "$host_dir"; run chmod 755 "$host_dir"
    if [[ -f "$HOST_DST" ]] && cmp -s "$HOST_SRC" "$HOST_DST"; then
      info "up to date"
    else
      run install -o root -g wheel -m 755 "$HOST_SRC" "$HOST_DST"
      HOST_CHANGED=1
    fi
    run xattr -c "$HOST_DST"
  elif [[ -f "$HOST_DST" ]]; then
    info "already installed (no --host-binary given)"
  else
    die "no host binary given and none installed"
  fi
  end_step "host binary installed"
fi

# ================================================================ daemon (reported under hostBinary, else agentUser)
if want hostBinary || want agentUser; then
  if want hostBinary; then CURRENT_STEP="hostBinary"; else CURRENT_STEP="agentUser"; fi
  if [[ ! -f "$HOST_DST" && $DRY_RUN -eq 0 ]]; then
    info "no host binary installed; LaunchDaemon skipped"
  else
    emit "$CURRENT_STEP" running "LaunchDaemon (${PLIST_DST})"
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

    plist_changed=1
    if [[ -f "$PLIST_DST" ]] && cmp -s "$rendered" "$PLIST_DST"; then plist_changed=0; fi
    if [[ $plist_changed -eq 1 ]]; then
      if daemon_loaded; then run launchctl bootout "system/${LABEL}"; fi
      run install -o root -g wheel -m 644 "$rendered" "$PLIST_DST"
      run launchctl bootstrap system "$PLIST_DST"
    elif ! daemon_loaded; then
      run launchctl bootstrap system "$PLIST_DST"
    elif [[ $HOST_CHANGED -eq 1 ]]; then
      run launchctl kickstart -k "system/${LABEL}"
    else
      info "plist unchanged and daemon loaded"
    fi

    # Post-check: state = running and no "last exit code = 78" (EX_CONFIG).
    if [[ $DRY_RUN -eq 0 ]]; then
      ok=0
      for _ in $(seq 1 20); do
        out="$(launchctl print "system/${LABEL}" 2>/dev/null || true)"
        if grep -q 'state = running' <<<"$out" && ! grep -q 'last exit code = 78' <<<"$out"; then ok=1; break; fi
        sleep 1
      done
      if [[ $ok -eq 0 ]]; then
        code="$(grep -m1 'last exit code' <<<"${out:-}" | sed 's/^[[:space:]]*//' || true)"
        die "LaunchDaemon ${LABEL} is not running after setup (${code:-no exit code}); see ${AGENT_HOME}/host.log"
      fi
      info "LaunchDaemon running"
    fi
    emit "$CURRENT_STEP" "done" "LaunchDaemon ready"
  fi
fi

# ================================================================ step: claudeToken
if want claudeToken; then
  begin_step claudeToken "Claude token"
  if [[ -z "$TOKEN_SRC" ]]; then
    info "no --token-file given; existing token (if any) is kept"
  else
    # Always remove the short-lived source, even on failure.
    if [[ $DRY_RUN -eq 0 ]]; then trap 'rm -f -- "$TOKEN_SRC"; rm -f "${rendered:-}"' EXIT; fi
    [[ "$TOKEN_SRC" == /* ]] || die "token file path must be absolute"
    [[ -f "$TOKEN_SRC" && ! -L "$TOKEN_SRC" ]] || die "token file missing or not a regular file"
    # Open the file ONCE and validate the open descriptor (not the path), so a
    # swap to a symlink between check and read cannot redirect root's read.
    exec 3< "$TOKEN_SRC" || die "cannot open token file"
    # (the mode of /dev/fd/N reflects the open mode, so the mode is checked on the path;
    # type, owner, link count and size come from the descriptor)
    tsrc_mode="$(stat -f %Lp "$TOKEN_SRC")"
    tsrc_stat="$(stat -f '%HT %u %l %z' /dev/fd/3)" || die "cannot stat token file"
    read -r tsrc_type1 tsrc_type2 tsrc_uid tsrc_links tsrc_size <<< "$tsrc_stat"
    [[ "$tsrc_type1 $tsrc_type2" == "Regular File" ]] || die "token file is not a regular file"
    [[ "$tsrc_mode" == "600" ]] || die "token file must be mode 0600 (is ${tsrc_mode})"
    # Owner only: never accept a root-owned file here (it could be any system file).
    [[ "$tsrc_uid" == "$(id -u "$OWNER")" && "$tsrc_uid" != "0" ]] || die "token file is not owned by the owner"
    [[ "$tsrc_links" == "1" ]] || die "token file has multiple links"
    [[ "$tsrc_size" -le 8192 ]] || die "token file too large"
    token="$(LC_ALL=C tr -d '\r\n\t ' <&3)"
    exec 3<&-
    # (bash's regex repetition limit is 255, so the length is checked separately)
    [[ "$token" =~ ^[A-Za-z0-9._-]+$ && ${#token} -ge 20 && ${#token} -le 4096 ]] || die "token file content does not look like a Claude token"
    if [[ $DRY_RUN -eq 1 ]]; then
      info "would move the token into ${AGENT_HOME}/${TOKEN_DIR_REL}/${TOKEN_NAME} (0600) and delete the source"
    else
      user_exists || die "agent user missing; cannot store token"
      # The agent home is controlled by the less-trusted agent user, so root must
      # not touch paths inside it: perform every file operation AS the agent user.
      printf '%s\n' "$token" | sudo -n -u "$AGENT_USER" -H /bin/sh -c '
        set -e
        umask 077
        d="$HOME/$1"
        for p in "$HOME/.config" "$d"; do
          [ ! -L "$p" ] || { echo "refusing symlink: $p" >&2; exit 1; }
          [ -d "$p" ] || mkdir -m 700 "$p"
        done
        t="$(mktemp "$d/.token.XXXXXX")"
        cat > "$t"
        mv -f "$t" "$d/$2"
      ' sh "$TOKEN_DIR_REL" "$TOKEN_NAME" || die "could not store the token as ${AGENT_USER}"
      rm -f -- "$TOKEN_SRC"
    fi
    unset token
  fi
  end_step "token handled"
fi

CURRENT_STEP="setup"
emit setup "done" "finished with ${WARNINGS} warning(s)"
