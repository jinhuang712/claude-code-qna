#!/usr/bin/env bash
# Smoke test for the qna scripts and hooks.
#
# Everything this plugin claims to enforce in code is asserted here: the
# refusals, the exit codes, the validator's three rules, and the marker's
# scope. The prompt-side rules (R3, R5, R6, R7, scan recall) cannot be tested
# this way — they need a real session.
#
#     tests/smoke.sh          quiet unless something fails
#     tests/smoke.sh -v       show every case
#
# No dependencies beyond bash, python3 and coreutils. Runs in a temp directory
# and removes it on exit.

set -u

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

SCRIPTS="$(cd "$(dirname "$0")/../plugins/qna/scripts" && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PROJ="$WORK/proj"
FRESH="$WORK/fresh"
SID="smoke-session-1"
TRANSCRIPT="$WORK/transcript.jsonl"
SAID="park that for now, we will come back to it"

mkdir -p "$PROJ/src/deep/nested" "$FRESH"
printf 'x = 1\n' >"$PROJ/src/cache.py"
printf '%s\n' \
  "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":[{\"type\":\"text\",\"text\":\"$SAID\"}]}}" \
  >"$TRANSCRIPT"

# The whole point of --project: the shell the model runs commands in has no
# CLAUDE_PROJECT_DIR, so nothing may depend on it being set.
unset CLAUDE_PROJECT_DIR

PASS=0
FAIL=0

pass() {
  PASS=$((PASS + 1))
  [ "$VERBOSE" = 1 ] && printf '  ok   %s\n' "$1"
  return 0
}

fail() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1"
  printf '       %s\n' "$2"
}

# check <name> <expected-rc> <expected-substring-or-empty> <cmd...>
check() {
  local name=$1 want_rc=$2 want_out=$3
  shift 3
  local out rc
  out=$("$@" 2>&1)
  rc=$?
  if [ "$rc" != "$want_rc" ]; then
    fail "$name" "exit $rc, wanted $want_rc — $out"
    return
  fi
  if [ -n "$want_out" ] && ! printf '%s' "$out" | grep -qF -- "$want_out"; then
    fail "$name" "output missing '$want_out' — $out"
    return
  fi
  pass "$name"
}

# hook <name> <expected-substring-or-empty> <script> <payload-json>
# An empty expectation asserts the hook stayed silent, which for PreToolUse is
# how "allowed" is expressed.
hook() {
  local name=$1 want=$2 script=$3 payload=$4
  local out
  out=$(printf '%s' "$payload" | "$SCRIPTS/$script" 2>&1)
  if [ -z "$want" ]; then
    if [ -n "$out" ]; then
      fail "$name" "expected silence, got — $out"
    else
      pass "$name"
    fi
    return
  fi
  if printf '%s' "$out" | grep -qF -- "$want"; then
    pass "$name"
  else
    fail "$name" "output missing '$want' — $out"
  fi
}

q_ok='{"header":"backend","question":"q","options":[{"label":"a","preview":"x"},{"label":"b","preview":"y"},{"label":"c","preview":"z"}]}'
q_two='{"header":"backend","question":"q","options":[{"label":"a","preview":"x"},{"label":"b","preview":"y"}]}'
q_five='{"header":"backend","question":"q","options":[{"label":"a","preview":"1"},{"label":"b","preview":"2"},{"label":"c","preview":"3"},{"label":"d","preview":"4"},{"label":"e","preview":"5"}]}'
q_nopreview='{"header":"backend","question":"q","options":[{"label":"a","preview":"x"},{"label":"b"},{"label":"c","preview":"  "}]}'
q_multi='{"header":"which","question":"q","multiSelect":true,"options":[{"label":"a"},{"label":"b"},{"label":"c"}]}'
# Two check-boxes answer neither/A/B/both, so the yes/no floor does not apply.
# Taken from a real refusal-that-should-not-have-been: "which of these two new
# contract fields do you want", with exactly two candidate fields.
q_multi_two='{"header":"fields","question":"which of these two","multiSelect":true,"options":[{"label":"tag_ids"},{"label":"reviews[].language"}]}'
q_multi_one='{"header":"fields","question":"which","multiSelect":true,"options":[{"label":"only one"}]}'

ask_payload() { # <cwd> <question-json>
  printf '{"session_id":"%s","cwd":"%s","tool_name":"AskUserQuestion","tool_input":{"questions":[%s]}}' \
    "$SID" "$1" "$2"
}

echo "qna smoke test"

# --------------------------------------------------------------- leaves no trace
# Hooks run in every project. A project that has never recorded anything must
# come out of a session with nothing added to it: the directory appearing
# everywhere you happened to open a session was the bug this guards.
printf '=== leaves no trace in an unused project\n'
UNUSED="$WORK/unused"
mkdir -p "$UNUSED"
for h in session-start.py stop-count.py; do
  printf '{"session_id":"trace-check","cwd":"%s","transcript_path":"%s"}' "$UNUSED" "$TRANSCRIPT" |
    "$SCRIPTS/$h" >/dev/null 2>&1
done
printf '{"session_id":"trace-check","cwd":"%s","tool_name":"AskUserQuestion","tool_input":{"questions":[%s]}}' \
  "$UNUSED" "$q_two" | "$SCRIPTS/pre-tool-use.py" >/dev/null 2>&1
if [ -e "$UNUSED/.qna" ]; then
  fail "hooks create no .qna/ in an unused project" "$(ls -a "$UNUSED/.qna")"
else
  pass "hooks create no .qna/ in an unused project"
fi

# ------------------------------------------------------------ document hygiene
printf '=== documents\n'
DOCS="$(cd "$(dirname "$0")/.." && pwd)"
banned=$(grep -l '§' "$DOCS/plugins/qna/commands/ask.md" "$DOCS/specs/design.md" 2>/dev/null || true)
if [ -n "$banned" ]; then
  fail "no section-sign character in the docs" "still in: $banned"
else
  pass "no section-sign character in the docs"
fi

# The queue gets its own table. A row of questions under the same header as the
# reconciled items means the two were merged back into one grid.
lumped=$(grep -l -e '^| Bucket | Item ' -e '^| 归属 | 条目 ' \
  "$DOCS/plugins/qna/commands/ask.md" "$DOCS/specs/design.md" "$DOCS/README.md" 2>/dev/null || true)
if [ -n "$lumped" ]; then
  fail "queue is not merged into the reconciled table" "combined header still in: $lumped"
else
  pass "queue is not merged into the reconciled table"
fi

# ---------------------------------------------------------------- SessionStart
printf '=== SessionStart\n'
START_PAYLOAD=$(printf '{"session_id":"%s","cwd":"%s","transcript_path":"%s","source":"startup"}' \
  "$SID" "$PROJ" "$TRANSCRIPT")
INJECTED=$(printf '%s' "$START_PAYLOAD" | "$SCRIPTS/session-start.py" 2>&1)

for want in \
  '"hookEventName": "SessionStart"' \
  "qna-add --session $SID --project $PROJ" \
  "qna-resolve --session $SID --project $PROJ" \
  "qna-mark --session $SID --project $PROJ" \
  "qna-scan --session $SID --project $PROJ --transcript $TRANSCRIPT" \
  "$PROJ/.qna/$SID.md"; do
  if printf '%s' "$INJECTED" | grep -qF -- "$want"; then
    pass "injects: $want"
  else
    fail "injects: $want" "not in injected text"
  fi
done

# An injected command line is pasted straight into a shell, so a pipe in it
# would be a pipe, not documentation of alternatives.
if printf '%s' "$INJECTED" | grep -qE 'QNA_[A-Z]+ *= [^\\]*\|'; then
  fail "injected commands contain no pipe" "one of the QNA_* lines has a |"
else
  pass "injected commands contain no pipe"
fi

# No example may invoke $QNA_ANYTHING. A hook cannot export into the shell the
# model runs commands in, so that sigil expands to nothing and the command dies
# with "command not found" — which is not a refusal and invites the workaround
# the whole injection exists to prevent. Every example must be fully spelled.
# Matched at the start of a line only: the text is allowed to name the sigil
# while telling you not to use it, but no line may open with a command that
# does. Lines arrive escaped as \n inside the JSON payload.
if printf '%s' "$INJECTED" | grep -qE '\\n *\$QNA_'; then
  fail "no command line starts with \$QNA_" "an example relies on a shell variable"
else
  pass "no command line starts with \$QNA_"
fi
printf '%s' "$INJECTED" |
  grep -qF -- "$SCRIPTS/qna-add --session $SID --project $PROJ --transcript $TRANSCRIPT \\\\" &&
  pass "protocol example spells out the full qna-add line" ||
  fail "protocol example spells out the full qna-add line" "example not inlined"

printf '%s' "$INJECTED" | grep -qF -- "--transcript $TRANSCRIPT" &&
  pass "injects the transcript path" ||
  fail "injects the transcript path" "not in injected text"

# Nothing on disk yet: the transcript path travels in the command line, so the
# first entry can still be verified without a .meta to look it up in.
[ ! -e "$PROJ/.qna" ] && pass "creates nothing before the first entry" ||
  fail "creates nothing before the first entry" "$(ls -a "$PROJ/.qna")"

# ---------------------------------------------------------------------- qna-add
printf '=== qna-add\n'
ADD="$SCRIPTS/qna-add --session $SID --project $PROJ --transcript $TRANSCRIPT"
check "refuses one alternative" 1 "need at least 2 alternatives" \
  $ADD --title "log level" --chose debug --alt info --why w --where "src/cache.py:1"
check "records a real file:line" 0 "Recorded #1." \
  $ADD --title "cache backend" --chose SQLite --alt "flat files" --alt Redis \
  --why "cross-process without a new dependency" --where "src/cache.py:1"
check "refuses a made-up path" 1 "must be either a real file:line" \
  $ADD --title invented --chose A --alt B --alt C --why w --where "src/nope.py:9"
check "refuses words never said" 1 "do not appear in this conversation" \
  $ADD --title invented --chose A --alt B --alt C --why w --where "a sentence nobody uttered"
check "records something actually said" 0 "Recorded #2." \
  $ADD --title "custom cache dir" --chose "hardcode XDG" --alt "env var" --alt "--cache-dir flag" \
  --why "user parked it" --where "$SAID" --deferred-by-user
grep -qF "Source: user-deferred" "$PROJ/.qna/$SID.md" &&
  pass "marks --deferred-by-user" || fail "marks --deferred-by-user" "no Source line"

[ "$(cat "$PROJ/.qna/.gitignore" 2>/dev/null)" = "*" ] &&
  pass "the first entry brings a self-ignoring directory with it" ||
  fail "the first entry brings a self-ignoring directory with it" "wrong content"

# Unreadable transcript must not block recording, only flag it.
check "records unverified when transcript unreadable" 0 "(unverified" \
  "$SCRIPTS/qna-add" --session "$SID" --project "$PROJ" \
  --transcript /nonexistent/x.jsonl \
  --title "third one" --chose A --alt B --alt C --why w --where "any phrase at all"

# Once the directory exists, SessionStart does record the transcript path — and
# from a cwd below the anchor it must land in the anchor, not fork a new one.
printf '{"session_id":"%s","cwd":"%s","transcript_path":"%s","source":"resume"}' \
  "$SID" "$PROJ/src/deep/nested" "$TRANSCRIPT" | "$SCRIPTS/session-start.py" >/dev/null 2>&1
grep -qF "$TRANSCRIPT" "$PROJ/.qna/$SID.meta" 2>/dev/null &&
  pass "records transcript_path once the directory exists" ||
  fail "records transcript_path once the directory exists" "absent"
[ ! -e "$PROJ/src/deep/nested/.qna" ] &&
  pass "nested cwd does not fork a second directory" ||
  fail "nested cwd does not fork a second directory" "created one"

# ------------------------------------------------------------------ qna-resolve
printf '=== qna-resolve\n'
RESOLVE="$SCRIPTS/qna-resolve --session $SID --project $PROJ"
check "refuses an unknown id" 1 "no entry #99" $RESOLVE 99 --result x --quote y
check "refuses an empty quote" 1 "no quote" $RESOLVE 1 --result "300s" --quote ""
check "resolves" 0 "Resolved #1." $RESOLVE 1 --result "SQLite it is" --quote "use SQLite"
check "refuses a second resolve" 1 "already resolved" $RESOLVE 1 --result x --quote y
grep -qF -- "- [x] #1 " "$PROJ/.qna/$SID.md" &&
  pass "ticks the checkbox" || fail "ticks the checkbox" "still open"
grep -qF "  - Result: SQLite it is" "$PROJ/.qna/$SID.md" &&
  pass "appends Result" || fail "appends Result" "absent"

# --------------------------------------------------------------------- qna-mark
printf '=== qna-mark\n'
MARK="$SCRIPTS/qna-mark --session $SID --project $PROJ"
check "--off is idempotent when absent" 0 "Validator off." $MARK --off
check "--status reports off" 0 "Validator off." $MARK --status
check "--on" 0 "Validator on" $MARK --on
check "--status reports on" 0 "Validator on." $MARK --status
# The bare-touch bug: a project with no .qna/ yet must not fail.
check "--on creates .qna/ in a fresh project" 0 "Validator on" \
  "$SCRIPTS/qna-mark" --session other-session --project "$FRESH" --on
[ -f "$FRESH/.qna/other-session.active" ] &&
  pass "fresh project marker exists" || fail "fresh project marker exists" "absent"
check "rejects two modes at once" 2 "" $MARK --on --off

# ---------------------------------------------------------------- PreToolUse
printf '=== PreToolUse validator (marker live)\n'
hook "denies two options" "yes/no question in disguise" pre-tool-use.py "$(ask_payload "$PROJ" "$q_two")"
hook "denies five options" "exceeds the tool cap" pre-tool-use.py "$(ask_payload "$PROJ" "$q_five")"
hook "denies missing preview" "have no preview: b, c" pre-tool-use.py "$(ask_payload "$PROJ" "$q_nopreview")"
hook "allows three with previews" "" pre-tool-use.py "$(ask_payload "$PROJ" "$q_ok")"
hook "allows multiSelect without preview" "" pre-tool-use.py "$(ask_payload "$PROJ" "$q_multi")"
hook "allows a two-item multiSelect" "" pre-tool-use.py "$(ask_payload "$PROJ" "$q_multi_two")"
hook "denies a one-item multiSelect" "not something to choose between" pre-tool-use.py \
  "$(ask_payload "$PROJ" "$q_multi_one")"
# ...and single-select keeps the higher floor, with the yes/no diagnosis.
hook "single-select still needs three" "yes/no question in disguise" pre-tool-use.py \
  "$(ask_payload "$PROJ" "$q_two")"

# A payload the harness could not parse carries no questions, so every rule
# above passes on an empty list and the malformed call proceeds unremarked.
UNPARSED=$(python3 -c '
import json, sys
print(json.dumps({"session_id": sys.argv[1], "cwd": sys.argv[2],
                  "tool_name": "AskUserQuestion",
                  "tool_input": {"__unparsedToolInput": {"raw": "{\"questions\": [{\"quest"}}}))
' "$SID" "$PROJ")
hook "denies an unparsed payload" "did not parse" pre-tool-use.py "$UNPARSED"
hook "ignores other tools" "" pre-tool-use.py \
  "$(printf '{"session_id":"%s","cwd":"%s","tool_name":"Bash","tool_input":{"command":"ls"}}' "$SID" "$PROJ")"
# The bug this fix exists for: a cwd below the anchor must still validate.
hook "validates from a nested cwd" "yes/no question in disguise" pre-tool-use.py \
  "$(ask_payload "$PROJ/src/deep/nested" "$q_two")"

printf '=== PreToolUse validator (marker off or stale)\n'
$MARK --off >/dev/null
hook "allows everything when marker absent" "" pre-tool-use.py "$(ask_payload "$PROJ" "$q_two")"
$MARK --on >/dev/null
touch -t 200001010000 "$PROJ/.qna/$SID.active"
hook "allows everything when marker stale" "" pre-tool-use.py "$(ask_payload "$PROJ" "$q_two")"
[ ! -f "$PROJ/.qna/$SID.active" ] &&
  pass "stale marker is swept" || fail "stale marker is swept" "still there"

# ------------------------------------------------------------------- Stop hook
printf '=== Stop hook\n'
STOP_PAYLOAD=$(printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$PROJ")
python3 - "$PROJ/.qna/$SID.meta" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d.pop("reported_count", None)
json.dump(d, open(p, "w"))
PY
hook "reports the first time" "qna: 2 decision(s) parked" stop-count.py "$STOP_PAYLOAD"
hook "stays silent when unchanged" "" stop-count.py "$STOP_PAYLOAD"
$RESOLVE 2 --result "no custom dir" --quote "use SQLite" >/dev/null
hook "reports again when the count changes" "qna: 1 decision(s) parked" stop-count.py "$STOP_PAYLOAD"
hook "stays silent at zero" "" stop-count.py \
  "$(printf '{"session_id":"%s","cwd":"%s"}' "empty-session" "$PROJ")"
hook "counts from a nested cwd" "" stop-count.py \
  "$(printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$PROJ/src/deep/nested")"

# ------------------------------------------------------- unrecorded-work nudge
printf '=== unrecorded-work nudge\n'
# The protocol is injected once and never mentioned again. Measured on a real
# session: 84 conversation turns, 49 questions asked, qna-add run zero times,
# and this hook silent throughout because the count never left zero.
NUDGE_PROJ="$WORK/nudgeproj"
NUDGE_T="$WORK/nudge.jsonl"
mkdir -p "$NUDGE_PROJ"
mk_replies() { # <count> — plus a tool-call entry each, which must not be counted
  python3 - "$NUDGE_T" "$1" <<'PY'
import json, sys
with open(sys.argv[1], "w") as f:
    for i in range(int(sys.argv[2])):
        f.write(json.dumps({"type": "assistant", "uuid": f"a{i}",
                            "timestamp": "2026-07-27T01:00:00Z",
                            "message": {"role": "assistant",
                                        "content": [{"type": "text", "text": "reply"}]}}) + "\n")
        f.write(json.dumps({"type": "assistant", "uuid": f"t{i}",
                            "timestamp": "2026-07-27T01:00:00Z",
                            "message": {"role": "assistant",
                                        "content": [{"type": "tool_use", "name": "Bash",
                                                     "input": {}}]}}) + "\n")
PY
}
NUDGE_PAYLOAD=$(printf '{"session_id":"nudged","cwd":"%s","transcript_path":"%s"}' \
  "$NUDGE_PROJ" "$NUDGE_T")

mk_replies 14
hook "stays quiet before the first milestone" "" stop-count.py "$NUDGE_PAYLOAD"
mk_replies 15
hook "nudges at the first milestone" "nothing has been parked" stop-count.py "$NUDGE_PAYLOAD"
hook "spells out the qna-add line" "qna-add --session nudged --project $NUDGE_PROJ" \
  stop-count.py "$NUDGE_PAYLOAD"
hook "says finding nothing is an answer" "that is a real answer" stop-count.py "$NUDGE_PAYLOAD"

# Nudges are counted out of the transcript, so having sent one is remembered
# without writing anywhere — a Stop hook with nowhere safe to write is why this
# hook was silent in the first place.
python3 - "$NUDGE_T" <<'PY'
import json, sys
with open(sys.argv[1], "a") as f:
    f.write(json.dumps({"type": "attachment", "attachment": {
        "type": "hook_additional_context",
        "content": ["[qna-unrecorded-nudge] 15 replies into this session"]}}) + "\n")
PY
hook "does not nudge twice at the same milestone" "" stop-count.py "$NUDGE_PAYLOAD"
if [ -e "$NUDGE_PROJ/.qna" ]; then
  fail "nudging leaves no .qna/ behind" "$(ls -a "$NUDGE_PROJ/.qna" | tr '\n' ' ')"
else
  pass "nudging leaves no .qna/ behind"
fi

# A session that has recorded something takes the counting path, however long it
# runs — the nudge is for the case where the protocol was never acted on at all.
RECORDED="$WORK/recorded"
mkdir -p "$RECORDED"
"$SCRIPTS/qna-add" --session busy --project "$RECORDED" --transcript "$TRANSCRIPT" \
  --title "already parked" --chose "a" --alt "b" --alt "c" --why "w" --where "$SAID" >/dev/null
BUSY_PAYLOAD=$(printf '{"session_id":"busy","cwd":"%s","transcript_path":"%s"}' \
  "$RECORDED" "$NUDGE_T")
hook "a session with entries gets the count" "1 decision(s) parked" stop-count.py "$BUSY_PAYLOAD"
if printf '%s' "$BUSY_PAYLOAD" | "$SCRIPTS/stop-count.py" 2>&1 | grep -qF "$(printf 'unrecorded-nudge')"; then
  fail "a session with entries is never nudged" "got the nudge as well as the count"
else
  pass "a session with entries is never nudged"
fi

# ------------------------------------------------------------- orphan sweeping
printf '=== orphan sweep\n'
# A swept-clean directory that stays behind is litter outliving its reason. Seen
# for real: /Users/.../dev/.qna holding nothing but .gitignore and two stale
# bookkeeping files, in a directory that is not a project at all.
STALE="$WORK/stale"
mkdir -p "$STALE/.qna"
printf '*\n' >"$STALE/.qna/.gitignore"
printf '{"reported_count": 0}' >"$STALE/.qna/old-session.meta"
touch -t 202001010000 "$STALE/.qna/old-session.meta"
printf '{"session_id":"sweeper","cwd":"%s","transcript_path":"%s"}' "$STALE" "$TRANSCRIPT" |
  "$SCRIPTS/session-start.py" >/dev/null 2>&1
if [ -e "$STALE/.qna" ]; then
  fail "sweep removes the emptied directory" "still there: $(ls -a "$STALE/.qna" | tr '\n' ' ')"
else
  pass "sweep removes the emptied directory"
fi

# It must not take a directory that is still in use with it.
LIVE="$WORK/live"
mkdir -p "$LIVE"
"$SCRIPTS/qna-add" --session live-session --project "$LIVE" --transcript "$TRANSCRIPT" \
  --title "keep me" --chose "a" --alt "b" --alt "c" --why "w" --where "$SAID" >/dev/null 2>&1
printf '{"session_id":"live-session","cwd":"%s","transcript_path":"%s"}' "$LIVE" "$TRANSCRIPT" |
  "$SCRIPTS/session-start.py" >/dev/null 2>&1
if [ -f "$LIVE/.qna/live-session.md" ]; then
  pass "sweep spares a directory with live entries"
else
  fail "sweep spares a directory with live entries" "the pending file went away"
fi

# --------------------------------------------------------------------- qna-scan
printf '=== qna-scan\n'
# A transcript shaped like a real one: conversation mixed with the tool traffic,
# thinking and metadata that make up the overwhelming majority of the bytes.
SCAN_PROJ="$WORK/scanproj"
SCAN_SID="scan-session"
SCAN_T="$WORK/scan.jsonl"
mkdir -p "$SCAN_PROJ/.qna"
NOISE=$(python3 -c 'print("TOOLNOISE" * 400)')
{
  printf '{"type":"user","uuid":"u1","timestamp":"2026-07-27T01:00:00Z","message":{"role":"user","content":[{"type":"text","text":"FIRST_HUMAN_LINE"}]}}\n'
  printf '{"type":"assistant","uuid":"a1","timestamp":"2026-07-27T01:00:10Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"HIDDEN_THOUGHT"},{"type":"text","text":"FIRST_REPLY"}]}}\n'
  printf '{"type":"user","uuid":"t1","timestamp":"2026-07-27T01:00:20Z","message":{"role":"user","content":[{"type":"tool_result","content":"%s"}]}}\n' "$NOISE"
  printf '{"type":"assistant","uuid":"s1","timestamp":"2026-07-27T01:00:30Z","isSidechain":true,"message":{"role":"assistant","content":[{"type":"text","text":"SUBAGENT_CHATTER"}]}}\n'
  printf '{"type":"user","uuid":"m1","timestamp":"2026-07-27T01:00:40Z","isMeta":true,"message":{"role":"user","content":[{"type":"text","text":"META_LINE"}]}}\n'
  printf '{"type":"system","uuid":"y1","timestamp":"2026-07-27T01:00:50Z","content":"SYSTEM_LINE"}\n'
  printf '{"type":"user","uuid":"c1","timestamp":"2026-07-27T01:01:00Z","isCompactSummary":true,"message":{"role":"user","content":"SUMMARY_BODY"}}\n'
  printf '{"type":"user","uuid":"u2","timestamp":"2026-07-27T01:02:00Z","message":{"role":"user","content":[{"type":"text","text":"SECOND_HUMAN_LINE"}]}}\n'
} >"$SCAN_T"

SCAN="$SCRIPTS/qna-scan --session $SCAN_SID --project $SCAN_PROJ --transcript $SCAN_T"
OUT=$($SCAN 2>&1)

# The filter is the whole reason this is affordable. Conversation in, everything
# else out — and "everything else" is most of the file.
for want in FIRST_HUMAN_LINE FIRST_REPLY SECOND_HUMAN_LINE SUMMARY_BODY; do
  printf '%s' "$OUT" | grep -qF -- "$want" &&
    pass "keeps conversation: $want" ||
    fail "keeps conversation: $want" "missing from the window"
done
for gone in TOOLNOISE HIDDEN_THOUGHT SUBAGENT_CHATTER META_LINE SYSTEM_LINE; do
  printf '%s' "$OUT" | grep -qF -- "$gone" &&
    fail "filters out: $gone" "leaked into the window" ||
    pass "filters out: $gone"
done
printf '%s' "$OUT" | grep -qF "no watermark yet" &&
  pass "first run reads the whole conversation" ||
  fail "first run reads the whole conversation" "$OUT"
printf '%s' "$OUT" | grep -qF "crosses a context compaction" &&
  pass "flags a compaction inside the window" ||
  fail "flags a compaction inside the window" "$OUT"

# The watermark: written by the script, never computed by the model.
check "marks the watermark" 0 "watermark at 2026-07-27T01:02:00Z" $SCAN --mark
if python3 - "$SCAN_PROJ/.qna/$SCAN_SID.meta" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get("scan_uuid") == "u2" and d.get("scan_ts") else 1)
PY
then
  pass "watermark lands in .meta"
else
  fail "watermark lands in .meta" "scan_uuid/scan_ts not stored"
fi
check "second run finds nothing new" 0 "nothing new since" $SCAN

# Only the new turn comes back, and it resumed by uuid rather than by clock.
printf '{"type":"user","uuid":"u3","timestamp":"2026-07-27T01:03:00Z","message":{"role":"user","content":[{"type":"text","text":"THIRD_HUMAN_LINE"}]}}\n' >>"$SCAN_T"
OUT=$($SCAN 2>&1)
printf '%s' "$OUT" | grep -qF "THIRD_HUMAN_LINE" &&
  pass "window carries the new turn" ||
  fail "window carries the new turn" "$OUT"
printf '%s' "$OUT" | grep -qF "FIRST_HUMAN_LINE" &&
  fail "window excludes already-scanned turns" "old turn came back" ||
  pass "window excludes already-scanned turns"
printf '%s' "$OUT" | grep -qF "resumed by uuid" &&
  pass "resumes by uuid" ||
  fail "resumes by uuid" "$OUT"

# A uuid that no longer exists must not silently yield an empty window: fall
# back to the clock, and if that fails too, re-read everything. Under-reading is
# invisible; over-reading is merely slower.
python3 - "$SCAN_PROJ/.qna/$SCAN_SID.meta" <<'PY'
import json, sys
p = sys.argv[1]
d = json.load(open(p))
d["scan_uuid"] = "vanished-uuid"
json.dump(d, open(p, "w"))
PY
check "falls back to the timestamp when the uuid is gone" 0 "resumed by timestamp" $SCAN
python3 - "$SCAN_PROJ/.qna/$SCAN_SID.meta" <<'PY'
import json, sys
json.dump({"scan_uuid": "vanished-uuid", "scan_ts": "1999-01-01T00:00:00Z"}, open(sys.argv[1], "w"))
PY
check "re-reads everything when neither anchor resolves" 0 "FIRST_HUMAN_LINE" $SCAN

# Unreadable transcript is not the same as an empty conversation: it has to say
# so, because the fallback is for the model to scan its own context instead.
check "reports an unreadable transcript" 2 "transcript unreadable" \
  "$SCRIPTS/qna-scan" --session "$SCAN_SID" --project "$SCAN_PROJ" \
  --transcript "$WORK/no-such-transcript.jsonl"

# Reading is read-only: the watermark moves on --mark and nowhere else.
check "plain scan leaves the watermark alone" 0 "" $SCAN
if python3 - "$SCAN_PROJ/.qna/$SCAN_SID.meta" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
sys.exit(0 if d.get("scan_uuid") == "vanished-uuid" else 1)
PY
then
  pass "plain scan wrote nothing"
else
  fail "plain scan wrote nothing" "meta changed without --mark"
fi

# A cap that stays quiet reads as "you have seen everything".
BIG_T="$WORK/big.jsonl"
python3 - "$BIG_T" <<'PY'
import json
with open(__import__("sys").argv[1], "w") as f:
    for i in range(60):
        f.write(json.dumps({
            "type": "user", "uuid": f"b{i}",
            "timestamp": "2026-07-27T02:%02d:00Z" % i,
            "message": {"role": "user", "content": [{"type": "text", "text": "X" * 5000}]},
        }) + "\n")
PY
check "reports turns dropped to the size cap" 0 "were NOT scanned" \
  "$SCRIPTS/qna-scan" --session "cap-session" --project "$SCAN_PROJ" --transcript "$BIG_T"

# Same lazy-directory rule as everything else: reading must not conjure state.
VIRGIN="$WORK/virgin"
mkdir -p "$VIRGIN"
check "reading creates no .qna/ in a fresh project" 0 "" \
  "$SCRIPTS/qna-scan" --session "fresh-scan" --project "$VIRGIN" --transcript "$SCAN_T"
if [ -e "$VIRGIN/.qna" ]; then
  fail "reading creates no .qna/ in a fresh project" "$(ls -a "$VIRGIN/.qna")"
else
  pass "reading creates no .qna/ in a fresh project"
fi

# ---------------------------------------------------------------------- summary
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
