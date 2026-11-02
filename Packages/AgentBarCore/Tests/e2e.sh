#!/bin/bash
# End-to-end test: real `agentbar` CLI against `agentbar-testhost` (store + UDS server, no GUI).
set -u
cd "$(dirname "$0")/.."
swift build 2>&1 | grep -E "error|warning" && { echo "build problems"; exit 1; }
BIN="$(swift build --show-bin-path)"
CLI="$BIN/agentbar"; HOST="$BIN/agentbar-testhost"
D="/tmp/abe-$$"; BAD="/tmp/abe-$$-bad"; GONE="/tmp/abe-$$-gone"
PASS=0; FAIL=0; BGPIDS=""
cleanup() { for p in $BGPIDS; do kill "$p" 2>/dev/null; done; [ -n "${HOSTPID:-}" ] && kill "$HOSTPID" 2>/dev/null; wait 2>/dev/null; rm -rf "$D" "$BAD" "$GONE"; }
trap cleanup EXIT

check() { # name expected actual
  if [ "$2" == "$3" ]; then PASS=$((PASS+1)); echo "ok   - $1"; else FAIL=$((FAIL+1)); echo "FAIL - $1 (expected '$2', got '$3')"; fi
}
state() { sed -n "s/.*$1=\([a-zA-Z0-9]*\).*/\1/p" "$D/state.txt" 2>/dev/null; }
wait_state() { # key value [tries]
  for _ in $(seq 1 ${3:-100}); do [ "$(state "$1")" == "$2" ] && return 0; sleep 0.05; done; return 1
}

mkdir -p "$D"
"$HOST" --dir "$D" > "$D/host.out" 2>&1 &
HOSTPID=$!
for _ in $(seq 1 100); do grep -q READY "$D/host.out" && break; sleep 0.05; done
grep -q READY "$D/host.out" || { echo "host did not start"; cat "$D/host.out"; exit 1; }
export AGENTBAR_DIR="$D"
perm() { stat -f '%Lp' "$1"; }
check "dir perms 700" 700 "$(perm "$D")"
check "socket perms 600" 600 "$(perm "$D/agentbar.sock")"
check "token perms 600" 600 "$(perm "$D/token")"

# update
"$CLI" update --session u1 --name "Unit" --kind claudeCode --state working --action "typing"; check "update exit" 0 $?
wait_state sessions 1; check "update visible in store" 1 "$(state sessions)"
check "aggregate working" working "$(state aggregate)"
"$CLI" update --session u1 --state bogus 2>/dev/null; check "update invalid state exit" 4 $?
"$CLI" log --session u1 --kind status --text "hello"; check "log exit" 0 $?
"$CLI" end --session u1; check "end exit" 0 $?

# ask answered (host answers auto-* sessions; also sends a second, conflicting response which must be ignored)
OUT=$("$CLI" ask --session auto-1 --type approval --text "Run ls?" --option allow:Allow:primary --option deny:Deny:destructive --timeout 10 --default deny); RC=$?
check "ask answered exit" 0 $RC
check "ask answered option (double response ignored)" allow "$(echo "$OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["option"])')"
check "no pending after answer" 0 "$(state pending)"

# ask timeout with default
OUT=$("$CLI" ask --session hold-1 --type approval --text "t" --option allow:Allow --option deny:Deny --timeout 1 --default deny); RC=$?
check "ask timeout exit" 2 $RC
check "ask timeout default applied" deny "$(echo "$OUT" | python3 -c 'import sys,json;d=json.load(sys.stdin);print(d["option"],d["reason"])' | cut -d' ' -f1)"

# ask + client disconnect = cancel
"$CLI" ask --session hold-2 --type info --text "wait" >/dev/null 2>&1 &
P=$!; BGPIDS="$BGPIDS $P"
wait_state pending 1; check "pending while waiting" 1 "$(state pending)"
check "aggregate needsInput" needsInput "$(state aggregate)"
kill $P; wait $P 2>/dev/null
wait_state pending 0; check "cancelled on disconnect" 0 "$(state pending)"

# remove: pending ask is answered "cancelled" (exit 1) and the session disappears
BEFORE=$(state sessions)
"$CLI" update --session rm-1 --state working; wait_state sessions $((BEFORE+1))
"$CLI" ask --session rm-1 --type info --text "wait" > "$D/rm.out" 2>/dev/null &
P=$!; BGPIDS="$BGPIDS $P"
wait_state pending 1; check "remove: ask pending" 1 "$(state pending)"
"$CLI" remove --session rm-1; check "remove exit" 0 $?
wait $P; check "remove: ask exit cancelled" 1 $?
check "remove: ask reason" cancelled "$(python3 -c 'import sys,json;print(json.load(open(sys.argv[1]))["reason"])' "$D/rm.out")"
wait_state pending 0; check "remove: no pending" 0 "$(state pending)"
wait_state sessions $BEFORE; check "remove: session gone" $BEFORE "$(state sessions)"
"$CLI" remove --session rm-1; check "remove idempotent exit" 0 $?
"$CLI" remove --session rm-1 --bogus 2>/dev/null; check "remove bad args exit" 4 $?

# wrong token
mkdir -p "$BAD"; echo "deadbeef" > "$BAD/token"; ln -s "$D/agentbar.sock" "$BAD/agentbar.sock"
before=$(state sessions)
AGENTBAR_DIR="$BAD" "$CLI" update --session evil --state working 2>/dev/null; check "wrong token exit" 4 $?
sleep 0.2; check "wrong token no state change" "$before" "$(state sessions)"

# raw protocol cases via python
raw() { python3 -I - "$D" "$1" "$2" <<'PY'
import socket, sys
d, mode, arg = sys.argv[1], sys.argv[2], sys.argv[3]
tok = open(d + "/token").read().strip()
s = socket.socket(socket.AF_UNIX); s.settimeout(5); s.connect(d + "/agentbar.sock")
if mode == "malformed": s.sendall(b"{not json\n")
elif mode == "noline": s.sendall(b"a" * 200000)
elif mode == "bigline": s.sendall(b'{"token":"%s","op":"log","session":"x","kind":"status","text":"%s"}\n' % (tok.encode(), b"a" * 70000))
try: s.shutdown(socket.SHUT_WR)
except OSError: pass
buf = b""
try:
    while b"\n" not in buf:
        c = s.recv(4096)
        if not c: break
        buf += c
except OSError: pass
print(buf.decode().strip())
PY
}
check "malformed json" '{"error":"malformed json","ok":false}' "$(raw malformed x)"
check "oversized line (with newline)" '{"error":"line too long","ok":false}' "$(raw bigline x)"
check "oversized line (flood, no newline)" '{"error":"line too long","ok":false}' "$(raw noline x)"
"$CLI" log --session x --kind status --text "$(head -c 100000 /dev/zero | tr '\0' a)" 2>/dev/null; check "oversized via CLI exit" 4 $?

# pending cap: 100 held requests, the 101st is rejected
for i in $(seq 1 100); do "$CLI" ask --session "hold-cap-$((i % 9))" --type info --text "n$i" >/dev/null 2>&1 & BGPIDS="$BGPIDS $!"; done
wait_state pending 100 200; check "100 pending accepted" 100 "$(state pending)"
OUT=$("$CLI" ask --session hold-extra --type info --text over 2>/dev/null); RC=$?
check "101st rejected exit" 4 $RC
check "101st error message" "too many pending requests" "$(echo "$OUT" | python3 -c 'import sys,json;print(json.load(sys.stdin)["error"])')"
for p in $BGPIDS; do kill "$p" 2>/dev/null; done; wait $BGPIDS 2>/dev/null; BGPIDS=""
wait_state pending 0 200; check "all cancelled after clients die" 0 "$(state pending)"

# hook mode with host running (fake adapter approves auto-* sessions)
OUT=$(echo '{"session_id":"auto-hook","tool_name":"Bash"}' | "$CLI" hook --adapter claudeCode); RC=$?
check "hook exit" 0 $RC
check "hook output" '{"decision":"allow"}' "$OUT"
OUT=$(echo '{"garbage":true}' | "$CLI" hook --adapter claudeCode); RC=$?
check "hook invalid payload silent" "0:" "$RC:$OUT"
OUT=$(echo 'not json at all' | "$CLI" hook --adapter claudeCode); RC=$?
check "hook non-json stdin silent" "0:" "$RC:$OUT"

# hook client killed (SIGKILL) while a PermissionRequest waits => request cancelled, no orphan
echo '{"session_id":"hold-kill","tool_name":"Bash"}' | "$CLI" hook --adapter claudeCode >/dev/null 2>&1 &
P=$!
wait_state pending 1; check "hook pending while waiting" 1 "$(state pending)"
kill -9 $P; wait $P 2>/dev/null
wait_state pending 0; check "hook killed => request cancelled" 0 "$(state pending)"

# burst: 150 parallel updates must all reach the server (backlog + client connect retry)
BEFORE=$(state sessions)
for i in $(seq 1 150); do ( "$CLI" update --session "burst-$((i % 50))" --state working >/dev/null 2>&1; echo $? >> "$D/burst.rc" ) & done; wait $(jobs -p | grep -v "^$HOSTPID$") 2>/dev/null
check "burst: all 150 exit 0" 150 "$(grep -c '^0$' "$D/burst.rc")"

# run wrapper
RUNOUT=$("$CLI" run --session run-ok --name RunOk --log -- sh -c 'echo one; echo two'); RC=$?
check "run: exit 0 passthrough" 0 $RC
check "run: stdout passed through" "one two" "$(echo $RUNOUT)"
"$CLI" run --session run-fail -- sh -c 'exit 7'; check "run: exit code passthrough" 7 $?
"$CLI" run --session run-nf -- definitely-not-a-command-xyz 2>/dev/null; check "run: command not found exit 127" 127 $?
"$CLI" run --session 2>/dev/null; check "run: missing command exit 4" 4 $?
"$CLI" run --session x -- 2>/dev/null; check "run: empty command exit 4" 4 $?
"$CLI" run --session run-term -- sleep 30 & P=$!; BGPIDS="$BGPIDS $P"
sleep 0.7; kill -TERM $P; wait $P 2>/dev/null; check "run: SIGTERM forwarded (exit 143)" 143 $?
"$CLI" run --session run-int -- sh -c 'trap "exit 9" INT; sleep 5 & wait' & P=$!; BGPIDS="$BGPIDS $P"
sleep 0.7; kill -INT $P; wait $P 2>/dev/null; check "run: SIGINT forwarded to child handler (exit 9)" 9 $?
wait_state aggregate error; check "run: failed child => session error" error "$(state aggregate)"
OUT=$(AGENTBAR_DIR="$GONE" "$CLI" run --session run-gone --log -- sh -c 'echo alive; exit 5'); RC=$?
check "run: app absent, command still runs, exit passthrough" "5:alive" "$RC:$OUT"
T0=$(date +%s); AGENTBAR_DIR="$GONE" "$CLI" run --session run-gone -- true; RC=$?; T1=$(date +%s)
check "run: app absent not slow" yes "$([ $RC -eq 0 ] && [ $((T1-T0)) -le 3 ] && echo yes || echo no)"

# stop channel: app -> CLI (no confirmation, immediate SIGTERM to the child)
ctl() { echo "$1 $2" > "$D/cmd.txt.tmp"; mv "$D/cmd.txt.tmp" "$D/cmd.txt"; }
stoppable() { cat "$D/stoppable.txt" 2>/dev/null; }
is_stoppable() { stoppable | tr ',' '\n' | grep -qx "$1" && echo yes || echo no; }
wait_stoppable() { for _ in $(seq 1 100); do [ "$(is_stoppable "$1")" == "$2" ] && return 0; sleep 0.05; done; }
"$CLI" run --session run-stop --name StopMe -- sleep 30 & P=$!; BGPIDS="$BGPIDS $P"
wait_stoppable run-stop yes
check "run: supportsStop set" yes "$(is_stoppable run-stop)"
T0=$(date +%s); ctl stop run-stop; wait $P 2>/dev/null; RC=$?; T1=$(date +%s)
check "run: app stop => SIGTERM to child (exit 143), fast" "143:yes" "$RC:$([ $((T1-T0)) -le 3 ] && echo yes || echo no)"
wait_stoppable run-stop no
check "run: stopped session no longer stoppable" no "$(is_stoppable run-stop)"
"$CLI" run --session run-pause -- sh -c 'sleep 1; echo x > "$AGENTBAR_DIR/pause.out"' & P=$!; BGPIDS="$BGPIDS $P"
wait_stoppable run-pause yes; sleep 0.3
ctl pause run-pause; sleep 1.8
check "run: paused child makes no progress" no "$([ -e "$D/pause.out" ] && echo yes || echo no)"
ctl resume run-pause; wait $P 2>/dev/null; check "run: resumed child finishes (exit 0)" "0:yes" "$?:$([ -e "$D/pause.out" ] && echo yes || echo no)"
# watch command
"$CLI" update --session w1 --state working
"$CLI" watch --session w1 > "$D/watch.out" & P=$!; BGPIDS="$BGPIDS $P"
sleep 0.5; ctl pause w1; sleep 0.3; ctl resume w1; sleep 0.3; ctl stop w1; wait $P 2>/dev/null
check "watch: events then exit 0 on stop" "0:pause resume stop" "$?:$(echo $(cat "$D/watch.out"))"
AGENTBAR_DIR="$GONE" "$CLI" watch --session w2 2>/dev/null; check "watch: app absent exit 3" 3 $?
# forged history kinds are rejected (exit 4)
"$CLI" log --session forge --kind answer --text "You: hi" 2>/dev/null; check "log kind answer rejected (exit 4)" 4 $?
"$CLI" log --session forge --kind request --text "x" 2>/dev/null; check "log kind request rejected (exit 4)" 4 $?
echo '{"session":"forge","log":{"kind":"answer","text":"You: x"}}' | "$CLI" hook --adapter genericCLI; check "hook forged answer log silent exit 0" 0 $?
# computerUse adapter via hook
echo '{"session":"cu1","name":"Mac\u001b[31m Agent","action":"clicking \u001b[2Jthe button","supportsStop":true}' | "$CLI" hook --adapter computerUse; check "computerUse hook exit" 0 $?
wait_stoppable cu1 yes; check "computerUse session stoppable" yes "$(is_stoppable cu1)"

OUT=$("$CLI" hook --adapter claudeCode --argv '{"garbage":true}'); check "hook --argv invalid payload silent" "0:" "$?:$OUT"

# app absent
OUT=$(echo '{"session_id":"a","tool_name":"Bash"}' | AGENTBAR_DIR="$GONE" "$CLI" hook --adapter claudeCode 2>&1); RC=$?
check "hook app absent: silent, exit 0" "0:" "$RC:$OUT"
AGENTBAR_DIR="$GONE" "$CLI" ask --session s --type info --text t 2>/dev/null; check "ask app absent exit" 3 $?
AGENTBAR_DIR="$GONE" "$CLI" update --session s 2>/dev/null; check "update app absent exit" 3 $?

# hung server (accepts, never replies): CLI must give up instead of hanging
HUNG="/tmp/abe-$$-hung"; mkdir -p "$HUNG"; echo tok > "$HUNG/token"
python3 -I - "$HUNG" <<'PY' &
import socket, sys, time
s = socket.socket(socket.AF_UNIX); s.bind(sys.argv[1] + "/agentbar.sock"); s.listen(8)
conns = []
end = time.time() + 40
s.settimeout(1)
while time.time() < end:
    try: conns.append(s.accept()[0])
    except OSError: pass
PY
HUNGPID=$!; disown $HUNGPID; sleep 0.5
T0=$(date +%s); AGENTBAR_DIR="$HUNG" "$CLI" update --session s --state working 2>/dev/null; RC=$?; T1=$(date +%s)
check "hung server: update exit 3" 3 $RC
check "hung server: update bounded (<=7s)" yes "$([ $((T1-T0)) -le 7 ] && echo yes || echo no)"
T0=$(date +%s); AGENTBAR_DIR="$HUNG" "$CLI" ask --session s --type info --text t --timeout 1 2>/dev/null; RC=$?; T1=$(date +%s)
check "hung server: ask --timeout 1 exit 3" 3 $RC
check "hung server: ask bounded (timeout+grace)" yes "$([ $((T1-T0)) -ge 5 ] && [ $((T1-T0)) -le 9 ] && echo yes || echo no)"
T0=$(date +%s); OUT=$(echo '{"hook_event_name":"PreToolUse","session_id":"a"}' | AGENTBAR_DIR="$HUNG" "$CLI" hook --adapter claudeCode 2>&1); RC=$?; T1=$(date +%s)
check "hung server: non-blocking hook silent exit 0" "0:" "$RC:$OUT"
check "hung server: non-blocking hook bounded" yes "$([ $((T1-T0)) -le 7 ] && echo yes || echo no)"
kill $HUNGPID 2>/dev/null; rm -rf "$HUNG"

# graceful stop removes socket + token; hook afterwards is silent
kill "$HOSTPID"; wait "$HOSTPID" 2>/dev/null; HOSTPID=""
check "socket removed on stop" "no" "$([ -e "$D/agentbar.sock" ] && echo yes || echo no)"
check "token removed on stop" "no" "$([ -e "$D/token" ] && echo yes || echo no)"
OUT=$(echo '{"session_id":"a","tool_name":"Bash"}' | "$CLI" hook --adapter claudeCode 2>&1); RC=$?
check "hook after stop silent" "0:" "$RC:$OUT"

echo; echo "passed=$PASS failed=$FAIL"
[ "$FAIL" -eq 0 ]
