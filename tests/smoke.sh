#!/usr/bin/env bash
# Smoke test for the qna scripts and hooks.
#
# Everything this plugin claims to enforce in code is asserted here: the
# refusals, the exit codes, the validator's rules — option floor and ceiling, and
# the panel behind an option being neither empty nor half-filled, all of which now
# apply to every session rather than just /qna:ask — the scan window and
# watermark, the unrecorded-work nudge, and the orphan sweep. The prompt-side
# rules (R3, R5, R6, R7, scan recall) cannot be tested this way — they need a
# real session.
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

# The batching hint keeps "when did this session last ask" in the system temp
# directory, keyed by session id. Pointing TMPDIR into the throwaway workspace
# makes each run hermetic — otherwise the previous run's state is still sitting
# there and a fresh session looks like it just asked something.
export TMPDIR="$WORK/tmp"
mkdir -p "$TMPDIR"

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
# The panel is one slot with two ways to fill it. Half-filled breaks the compare;
# empty leaves the reader with the label alone; filled either way is fine.
q_partial='{"header":"backend","question":"q","options":[{"label":"a","preview":"x"},{"label":"b"},{"label":"c","preview":"  "}]}'
q_thin='{"header":"cleanup","question":"q","options":[{"label":"on boot","description":"on boot"},{"label":"daily","description":"a cron job at 3am, invisible during the day"},{"label":"manual","description":"manual"}]}'
q_desc='{"header":"cleanup","question":"q","options":[{"label":"on boot","description":"sweeps once as the process comes up, slower to start"},{"label":"daily","description":"a cron job at 3am, invisible during the day"},{"label":"manual","description":"a command you run when you want it cleared"}]}'
q_multi='{"header":"which","question":"q","multiSelect":true,"options":[{"label":"a"},{"label":"b"},{"label":"c"}]}'
# Two check-boxes answer neither/A/B/both, so the yes/no floor does not apply.
# Taken from a real refusal-that-should-not-have-been: "which of these two new
# contract fields do you want", with exactly two candidate fields.
q_multi_two='{"header":"fields","question":"which of these two","multiSelect":true,"options":[{"label":"tag_ids"},{"label":"reviews[].language"}]}'
q_multi_one='{"header":"fields","question":"which","multiSelect":true,"options":[{"label":"only one"}]}'

# hook_not <name> <substring-that-must-not-appear> <script> <payload-json>
# The soft lane must never touch the permission flow: this hook's matcher also
# covers Bash and Write, and a stray "allow" there waves through something the
# user was meant to be asked about.
hook_not() {
  local name=$1 forbidden=$2 script=$3 payload=$4
  local out
  out=$(printf '%s' "$payload" | "$SCRIPTS/$script" 2>&1)
  if printf '%s' "$out" | grep -qF -- "$forbidden"; then
    fail "$name" "output must not contain '$forbidden' — $out"
  else
    pass "$name"
  fi
}

# Questions carrying an over-long or an over-total preview. Both are allowed
# through with a note; neither is worth a round trip.
q_longprev="$(python3 -c '
import json
o=[{"label":"opt%d"%i,"description":"a description longer than the label",
    "preview":"y"*420} for i in range(3)]
print(json.dumps({"header":"long","question":"q","options":o}))')"
q_bigtotal="$(python3 -c '
import json
o=[{"label":"opt%d"%i,"description":"a description longer than the label",
    "preview":"y"*390} for i in range(3)]
print(json.dumps({"header":"total","question":"q","options":o}))')"
# The recommendation sits third; the hook reorders it without touching anything
# else and says so.
q_recthird='{"header":"rec","question":"q","options":[{"label":"a","description":"the first way of doing it"},{"label":"b","description":"the second way of doing it"},{"label":"c (recommended)","description":"the way I would pick"}]}'
# A preview on a multi-select is never rendered, so it is dropped in place.
q_multiprev='{"header":"fields","question":"q","multiSelect":true,"options":[{"label":"tag_ids","description":"the tag id list"},{"label":"lang","description":"the language field","preview":"never rendered"}]}'

# Each assertion that expects a *silent* pass needs its own session id. The
# batching hint fires when two small questions go out inside five minutes, and
# every case in this file runs within the same second — sharing one session
# would make the second silent-pass assertion fail for a correct reason.
ask_payload() { # <cwd> <question-json> [session]
  printf '{"session_id":"%s","cwd":"%s","tool_name":"AskUserQuestion","tool_input":{"questions":[%s]}}' \
    "${3:-$SID}" "$1" "$2"
}

echo "qna smoke test"

# --------------------------------------------------------------- leaves no trace
# Hooks run in every project. A project that has never recorded anything must
# come out of a session with nothing added to it: the directory appearing
# everywhere you happened to open a session was the bug this guards.
printf '=== leaves no trace in an unused project\n'
UNUSED="$WORK/unused"
mkdir -p "$UNUSED"
for h in session-start.py prompt-nudge.py stop-count.py; do
  printf '{"session_id":"trace-check","cwd":"%s","transcript_path":"%s"}' "$UNUSED" "$TRANSCRIPT" |
    "$SCRIPTS/$h" >/dev/null 2>&1
done
printf '{"session_id":"trace-check","cwd":"%s","tool_name":"AskUserQuestion","tool_input":{"questions":[%s]}}' \
  "$UNUSED" "$q_two" | "$SCRIPTS/pre-tool-use.py" >/dev/null 2>&1
# A refused question stops before the bookkeeping, so ask one that passes too:
# the batching hint records when this session last asked, and recording it into
# the project would be exactly the trace this test exists to catch.
for s in trace-ok-1 trace-ok-2; do
  printf '{"session_id":"%s","cwd":"%s","tool_name":"AskUserQuestion","tool_input":{"questions":[%s]}}' \
    "$s" "$UNUSED" "$q_desc" | "$SCRIPTS/pre-tool-use.py" >/dev/null 2>&1
done
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
  "qna-scan --session $SID --project $PROJ --transcript $TRANSCRIPT" \
  "qna-list --session $SID --project $PROJ" \
  "qna-drop --session $SID --project $PROJ" \
  "qna-prune --session $SID --project $PROJ"; do
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

# The pending file's path is deliberately not among them any more. Handing the
# model a path is handing it a Read, and the hook now refuses that — the way in
# is qna-list.
if printf '%s' "$INJECTED" | grep -qF -- "$PROJ/.qna/$SID.md"; then
  fail "injects no raw path to the pending file" "the .md path is still in there"
else
  pass "injects no raw path to the pending file"
fi

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

# ----------------------------------------------------- qna-list / drop / prune
# Its own project: these three change what is in the file, and the Stop-hook
# assertions further down count on the ids $PROJ has.
printf '=== qna-list, qna-drop, qna-prune\n'
CLOSE="$WORK/close"
mkdir -p "$CLOSE"
CSID="close-session"
close_add() { # <title>
  "$SCRIPTS/qna-add" --session "$CSID" --project "$CLOSE" --transcript "$TRANSCRIPT" \
    --title "$1" --chose "nothing yet" --alt b --alt c --why w --where "$SAID" >/dev/null
}
LIST="$SCRIPTS/qna-list --session $CSID --project $CLOSE"
DROP="$SCRIPTS/qna-drop --session $CSID --project $CLOSE"
PRUNE="$SCRIPTS/qna-prune --session $CSID --project $CLOSE"

check "list on a session with nothing parked" 0 "Nothing parked" $LIST
close_add "keep this one open"
close_add "premise about to vanish"
close_add "should never have been recorded"
close_add "settled by the user"

check "lists the open entries in full" 0 "premise about to vanish" $LIST
check "list counts them" 0 "4 open in session $CSID" $LIST

# The two reasons a caller reaches for by mistake, both refused by name: one
# belongs to qna-resolve, the other is not the model's call to make at all.
check "refuses --reason settled" 1 "belongs to qna-resolve" \
  $DROP 2 --reason settled --why "the user said so"
check "refuses --reason out-of-scope" 1 "has not ruled on" \
  $DROP 2 --reason out-of-scope --why "left it out"
check "refuses an invented reason" 1 "is not one of" $DROP 2 --reason boring --why w
check "refuses an empty why" 1 "no --why" $DROP 2 --reason moot --why ""
check "refuses an unknown id" 1 "no entry #99" $DROP 99 --reason moot --why w
check "drops a moot item" 0 "Dropped #2 (moot)" \
  $DROP 2 --reason moot --why "the feature it was about is gone"
check "refuses to drop it twice" 1 "already closed" $DROP 2 --reason trivia --why w
grep -qF "  - Dropped: moot — the feature it was about is gone" "$CLOSE/.qna/$CSID.md" &&
  pass "writes the reason into the entry" || fail "writes the reason into the entry" "absent"
grep -qF -- "- [x] #2 " "$CLOSE/.qna/$CSID.md" &&
  pass "ticks the box rather than deleting the line" ||
  fail "ticks the box rather than deleting the line" "entry vanished on drop"

check "drops trivia" 0 "Dropped #3" \
  $DROP 3 --reason trivia --why "naming, one line to change back"
"$SCRIPTS/qna-resolve" --session "$CSID" --project "$CLOSE" 4 \
  --result "settled" --quote "park that for now" >/dev/null

# Closed entries are the reader's problem until they are pruned, which is exactly
# why reading goes through a script that filters them.
check "list hides closed entries" 0 "3 closed and hidden" $LIST
printf '%s' "$($LIST)" | grep -qF "premise about to vanish" &&
  fail "list omits a dropped entry" "still listed" ||
  pass "list omits a dropped entry"
check "--all shows them again" 0 "premise about to vanish" $LIST --all
check "--raw dumps the file" 0 "qna-pending" $LIST --raw

check "dry run changes nothing" 0 "Would prune #2, #3, #4" $PRUNE --dry-run
grep -qF -- "- [x] #2 " "$CLOSE/.qna/$CSID.md" &&
  pass "and leaves the entries in place" || fail "and leaves the entries in place" "removed anyway"

check "prunes every closed entry at once" 0 "Pruned #2, #3, #4. 1 still open." $PRUNE
printf '%s' "$(cat "$CLOSE/.qna/$CSID.md")" | grep -qF -- "- [x] " &&
  fail "no closed entry survives the prune" "one is still in the file" ||
  pass "no closed entry survives the prune"
grep -qF "keep this one open" "$CLOSE/.qna/$CSID.md" &&
  pass "the open one is untouched" || fail "the open one is untouched" "pruned by mistake"
check "prunes nothing twice" 0 "Nothing closed to prune. 1 still open." $PRUNE

# #4 was announced in a Stop line and named in a resolve command. Handing its
# number to the next entry would make both of those point at something else.
close_add "the next one after a prune"
grep -qF -- "- [ ] #5 " "$CLOSE/.qna/$CSID.md" &&
  pass "ids are not reused after a prune" ||
  fail "ids are not reused after a prune" "$(grep -c -- '- \[ \] #' "$CLOSE/.qna/$CSID.md") entries, wanted #5"

# An empty queue is no file. The bookkeeping stays: qna-prune runs at the end of
# /qna:ask, moments after the scan watermark was advanced, and taking .meta with
# it would hand the next scan the whole conversation to read again.
"$SCRIPTS/qna-drop" --session "$CSID" --project "$CLOSE" 1 \
  --reason moot --why "cleaning up" >/dev/null
"$SCRIPTS/qna-drop" --session "$CSID" --project "$CLOSE" 5 \
  --reason moot --why "cleaning up" >/dev/null
check "removes the file when nothing is left open" 0 "removed the file" $PRUNE
[ ! -e "$CLOSE/.qna/$CSID.md" ] && pass "the pending file is gone" ||
  fail "the pending file is gone" "still there"
[ -f "$CLOSE/.qna/$CSID.meta" ] && pass "the scan watermark survives it" ||
  fail "the scan watermark survives it" ".meta went with the file"
check "list says so afterwards" 0 "Nothing parked" $LIST

# ---------------------------------------------------------------- PreToolUse
printf '=== PreToolUse validator (every session, no marker)\n'
hook "denies two options" "yes/no question in disguise" pre-tool-use.py "$(ask_payload "$PROJ" "$q_two")"
hook "denies five options" "exceeds the tool cap" pre-tool-use.py "$(ask_payload "$PROJ" "$q_five")"
hook "denies a half-filled panel" "empty for others: b, c" pre-tool-use.py "$(ask_payload "$PROJ" "$q_partial")"
hook "denies label-only options" "beyond their own label: on boot, manual" pre-tool-use.py "$(ask_payload "$PROJ" "$q_thin")"
hook "allows no preview when the descriptions carry it" "" pre-tool-use.py "$(ask_payload "$PROJ" "$q_desc" "pass-a")"
hook "allows three with previews" "" pre-tool-use.py "$(ask_payload "$PROJ" "$q_ok" "pass-b")"
hook "allows multiSelect without preview" "" pre-tool-use.py "$(ask_payload "$PROJ" "$q_multi" "pass-c")"
hook "allows a two-item multiSelect" "" pre-tool-use.py "$(ask_payload "$PROJ" "$q_multi_two" "pass-d")"
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
hook "the unparsed refusal reports the size" "characters, and this" pre-tool-use.py "$UNPARSED"
hook "ignores other tools" "" pre-tool-use.py \
  "$(printf '{"session_id":"%s","cwd":"%s","tool_name":"Bash","tool_input":{"command":"ls"}}' "$SID" "$PROJ")"

# --------------------------------------------------- PreToolUse soft lane
# Everything below rides along with the tool result instead of costing a round
# trip. The hard gate above is for questions the user cannot answer; this lane
# is for questions they can answer but that could have been put better.
printf '=== PreToolUse soft lane (allowed, with a note)\n'

hook "reorders a recommendation to the top" '"updatedInput"' pre-tool-use.py \
  "$(ask_payload "$PROJ" "$q_recthird" "soft-a")"
hook "says which option it moved" "Moved the recommended option to the top: c (recommended)" pre-tool-use.py \
  "$(ask_payload "$PROJ" "$q_recthird" "soft-b")"
hook "the reorder actually puts it first" '"options": [{"label": "c (recommended)"' pre-tool-use.py \
  "$(ask_payload "$PROJ" "$q_recthird" "soft-c")"
hook "drops a preview a multiSelect would never render" "Dropped a preview from a multi-select" pre-tool-use.py \
  "$(ask_payload "$PROJ" "$q_multiprev" "soft-d")"
hook_not "and leaves no preview behind in the payload" '"preview"' pre-tool-use.py \
  "$(ask_payload "$PROJ" "$q_multiprev" "soft-e")"

hook "notes an over-long preview" "is 420 characters" pre-tool-use.py \
  "$(ask_payload "$PROJ" "$q_longprev" "soft-f")"
hook "notes previews that add up too far" "add up to 1170 characters" pre-tool-use.py \
  "$(ask_payload "$PROJ" "$q_bigtotal" "soft-g")"

# The whole point of the soft lane: it must not touch the permission flow.
hook_not "a note carries no permission decision" '"permissionDecision"' pre-tool-use.py \
  "$(ask_payload "$PROJ" "$q_longprev" "soft-h")"
hook_not "a repair carries no permission decision either" '"permissionDecision"' pre-tool-use.py \
  "$(ask_payload "$PROJ" "$q_recthird" "soft-i")"

# Batching. Two small questions inside the window were one question split.
printf '%s' "$(ask_payload "$PROJ" "$q_desc" "batch-1")" | "$SCRIPTS/pre-tool-use.py" >/dev/null
hook "flags a second small question moments later" "the tool takes four at a time" pre-tool-use.py \
  "$(ask_payload "$PROJ" "$q_ok" "batch-1")"
# ...but a batch that was already close to full is not the problem it describes.
FOUR="$q_desc,$q_ok,$q_desc,$q_ok"
printf '{"session_id":"batch-2","cwd":"%s","tool_name":"AskUserQuestion","tool_input":{"questions":[%s]}}' \
  "$PROJ" "$FOUR" | "$SCRIPTS/pre-tool-use.py" >/dev/null
hook "says nothing after a full batch" "" pre-tool-use.py \
  "$(ask_payload "$PROJ" "$q_ok" "batch-2")"
# A first question has nothing to compare against.
hook "says nothing on the first question of a session" "" pre-tool-use.py \
  "$(ask_payload "$PROJ" "$q_ok" "batch-3-fresh")"

# ------------------------------------------------------- PreToolUse .qna guard
printf '=== PreToolUse .qna guard\n'
# Every gate in this plugin lives in a script. A free-hand Edit walks around all
# of them, and a hand-deleted entry takes the record of why it closed with it.
tool_payload() { # <tool> <tool_input-json>
  printf '{"session_id":"%s","cwd":"%s","tool_name":"%s","tool_input":%s}' \
    "$SID" "$PROJ" "$1" "$2"
}
file_payload() { # <tool> <path>
  tool_payload "$1" "$(printf '{"file_path":"%s"}' "$2")"
}
bash_payload() { # <command>
  tool_payload Bash "$(printf '{"command":"%s"}' "$1")"
}
for tool in Read Edit Write; do
  hook "denies $tool on the pending file" "script-owned" pre-tool-use.py \
    "$(file_payload "$tool" "$PROJ/.qna/$SID.md")"
done
hook "denies a relative path into it" "script-owned" pre-tool-use.py \
  "$(file_payload Read ".qna/$SID.md")"
hook "denies the directory itself" "script-owned" pre-tool-use.py \
  "$(file_payload Read "$PROJ/.qna")"
hook "denies rm on the directory" "script-owned" pre-tool-use.py \
  "$(bash_payload "rm -rf $PROJ/.qna")"
hook "denies cat on an entry" "script-owned" pre-tool-use.py \
  "$(bash_payload "cat $PROJ/.qna/$SID.md")"
hook "denies a sed in place" "script-owned" pre-tool-use.py \
  "$(bash_payload "sed -i '' '/#2/d' $PROJ/.qna/$SID.md")"

# The refusal has to be actionable in a shell with no CLAUDE_PROJECT_DIR, so it
# spells out this session's own commands rather than naming the scripts.
GUARD_OUT=$(printf '%s' "$(file_payload Edit "$PROJ/.qna/$SID.md")" |
  "$SCRIPTS/pre-tool-use.py" 2>&1)
for name in qna-list qna-drop qna-prune; do
  if printf '%s' "$GUARD_OUT" | grep -qF -- "$SCRIPTS/$name --session $SID --project $PROJ"; then
    pass "the refusal spells out the whole $name line"
  else
    fail "the refusal spells out the whole $name line" "$GUARD_OUT"
  fi
done

# Mentioning ".qna" is not touching it. This plugin's own source says the word on
# nearly every page, and a guard that blocked reading it would block its own
# development.
hook "allows a grep whose pattern says .qna" "" pre-tool-use.py \
  "$(bash_payload "grep -rn '\\\\.qna' plugins/")"
hook "allows the scripts themselves" "" pre-tool-use.py \
  "$(bash_payload "$SCRIPTS/qna-list --session $SID --project $PROJ")"
hook "allows an unrelated file" "" pre-tool-use.py \
  "$(file_payload Edit "$PROJ/src/cache.py")"
hook "allows a path that merely starts the same way" "" pre-tool-use.py \
  "$(file_payload Read "$PROJ/.qnargs/notes.md")"
# The bug this fix exists for: a cwd below the anchor must still validate.
hook "validates from a nested cwd" "yes/no question in disguise" pre-tool-use.py \
  "$(ask_payload "$PROJ/src/deep/nested" "$q_two")"

# Scope is no longer conditional: the same payload that validates inside
# /qna:ask must validate in a project that has never used the tool at all.
hook "validates in a project with no .qna/" "yes/no question in disguise" pre-tool-use.py \
  "$(ask_payload "$FRESH" "$q_two")"
hook "validates with no session id at all" "yes/no question in disguise" pre-tool-use.py \
  "$(printf '{"cwd":"%s","tool_name":"AskUserQuestion","tool_input":{"questions":[%s]}}' "$PROJ" "$q_two")"

# ------------------------------------------------------------------- Stop hook
printf '=== Stop hook (the only output a person sees)\n'
STOP_PAYLOAD=$(printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$PROJ")
STOP_NESTED=$(printf '{"session_id":"%s","cwd":"%s"}' "$SID" "$PROJ/src/deep/nested")

# additionalContext travels as JSON with non-ASCII escaped, so every assertion
# below runs against the decoded text rather than the wire form.
stop_ctx() { # <payload>
  printf '%s' "$1" | "$SCRIPTS/stop-count.py" 2>&1 | python3 -c 'import json, sys
raw = sys.stdin.read().strip()
print(json.loads(raw)["hookSpecificOutput"]["additionalContext"] if raw else "", end="")'
}
in_out() { # <name> <substring> <text>
  if printf '%s' "$3" | grep -qF -- "$2"; then
    pass "$1"
  else
    fail "$1" "missing '$2' — got: $3"
  fi
}
not_in_out() { # <name> <substring> <text>
  if printf '%s' "$3" | grep -qF -- "$2"; then
    fail "$1" "still there: '$2'"
  else
    pass "$1"
  fi
}
forget_reports() {
  python3 - "$PROJ/.qna/$SID.meta" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d.pop("reported_count", None)
d.pop("reported_max_id", None)
json.dump(d, open(sys.argv[1], "w"))
PY
}

forget_reports
FIRST=$(stop_ctx "$STOP_PAYLOAD")
in_out "names the entry rather than counting it" "qna parked #2 — custom cache dir" "$FIRST"
# The title is a question. Without what was picked, the reader has something to
# think about and nothing to think with — and no way to settle it by shrugging.
in_out "carries what was chosen meanwhile" "going with: hardcode XDG" "$FIRST"
in_out "announces every new entry, not only the newest" "qna parked #3 — third one" "$FIRST"
in_out "ends with how many are open" "/qna:ask to settle · 2 open" "$FIRST"
# Both instructions that have been sent down this channel: one told the model to
# repeat the line, which printed it twice; the other told it not to, which is
# still the user reading a note addressed to someone else.
not_in_out "does not ask the model to relay it" "Surface this" "$FIRST"
not_in_out "does not address the model at all" "No need to relay" "$FIRST"

hook "silent when nothing new was parked" "" stop-count.py "$STOP_PAYLOAD"

# Settling is news to nobody: the user just did it. The old version reported a
# level rather than a change, so resolving one item printed a line about a
# different item that had been sitting there for an hour.
$RESOLVE 2 --result "no custom dir" --quote "use SQLite" >/dev/null
hook "silent when an entry is settled" "" stop-count.py "$STOP_PAYLOAD"

# A new entry seen from a cwd below the anchor still finds the same file.
$ADD --title "fourth one" --chose "keep the default" --alt B --alt C \
  --why w --where "src/cache.py:1" >/dev/null
NESTED_OUT=$(stop_ctx "$STOP_NESTED")
in_out "reports from a nested cwd" "qna parked #4 — fourth one" "$NESTED_OUT"
in_out "counts only what is still open" "/qna:ask to settle · 2 open" "$NESTED_OUT"

# Parked and settled inside one turn: never worth announcing, and announcing it
# on the next turn instead would be worse than saying nothing.
$ADD --title "fifth one" --chose A --alt B --alt C --why w --where "src/cache.py:1" >/dev/null
$RESOLVE 5 --result "settled at once" --quote "use SQLite" >/dev/null
hook "silent for an entry settled in the same turn" "" stop-count.py "$STOP_PAYLOAD"
$ADD --title "sixth one" --chose A --alt B --alt C --why w --where "src/cache.py:1" >/dev/null
SIXTH=$(stop_ctx "$STOP_PAYLOAD")
in_out "the next entry is still announced" "qna parked #6 — sixth one" "$SIXTH"
not_in_out "the settled one is not announced late" "fifth one" "$SIXTH"

# Bookkeeping written by an older version: those entries were already reported
# under it, so the first run of this one says nothing instead of replaying them.
python3 - "$PROJ/.qna/$SID.meta" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
d.pop("reported_max_id", None)
d["reported_count"] = 2
json.dump(d, open(sys.argv[1], "w"))
PY
hook "an upgraded session does not replay its backlog" "" stop-count.py "$STOP_PAYLOAD"

hook "silent in a session with no entries" "" stop-count.py \
  "$(printf '{"session_id":"%s","cwd":"%s"}' "empty-session" "$PROJ")"

# ------------------------------------------------------- unrecorded-work nudge
printf '=== unrecorded-work nudge\n'
# The protocol is injected once and never mentioned again. Measured on a real
# session: 84 conversation turns, 49 questions asked, qna-add run zero times, and
# the hooks silent throughout because the count never left zero.
NUDGE_PROJ="$WORK/nudgeproj"
NUDGE_T="$WORK/nudge.jsonl"
NUDGE_GEN="$WORK/mk_transcript.py"
mkdir -p "$NUDGE_PROJ"

cat >"$NUDGE_GEN" <<'GENEOF'
import json, sys
path, replies = sys.argv[1], int(sys.argv[2])
marks = [int(x) for x in sys.argv[3:]]
with open(path, "w") as f:
    for i in range(replies):
        # A reply and a tool call. Only the reply counts; counting every
        # assistant entry inflates the number several times over.
        f.write(json.dumps({"type": "assistant", "uuid": "a%d" % i,
                            "timestamp": "2026-07-27T01:00:00Z",
                            "message": {"role": "assistant",
                                        "content": [{"type": "text", "text": "reply"}]}}) + "\n")
        f.write(json.dumps({"type": "assistant", "uuid": "t%d" % i,
                            "timestamp": "2026-07-27T01:00:00Z",
                            "message": {"role": "assistant",
                                        "content": [{"type": "tool_use", "name": "Bash",
                                                     "input": {}}]}}) + "\n")
    for n in marks:
        f.write(json.dumps({"type": "attachment", "attachment": {
            "type": "hook_additional_context",
            "content": ["qna: %d replies, nothing recorded in this session." % n]}}) + "\n")
GENEOF

mk_transcript() { python3 "$NUDGE_GEN" "$NUDGE_T" "$@"; }
# The unsettled nudge carries a differently shaped mark, so its stride is
# counted from its own text and never from the other one's.
mark_unsettled() { python3 -c 'import json, sys
open(sys.argv[1], "a").write(json.dumps({"type": "attachment", "attachment": {
    "type": "hook_additional_context",
    "content": ["qna: %s replies, 1 still open here." % sys.argv[2]]}}) + "\n")' "$NUDGE_T" "$1"; }
NUDGE_PAYLOAD=$(printf '{"session_id":"nudged","cwd":"%s","transcript_path":"%s"}' \
  "$NUDGE_PROJ" "$NUDGE_T")
nudge_out() { printf '%s' "$NUDGE_PAYLOAD" | "$SCRIPTS/prompt-nudge.py" 2>&1; }

mk_transcript 14
hook "stays quiet before the first stride" "" prompt-nudge.py "$NUDGE_PAYLOAD"
mk_transcript 15
hook "nudges at the first stride" "qna: 15 replies, nothing recorded" prompt-nudge.py "$NUDGE_PAYLOAD"
hook "says finding nothing is an answer" "Finding none is a valid answer" prompt-nudge.py "$NUDGE_PAYLOAD"

# A nudge-driven recording attempt was refused over --where the first time this
# ran for real, so the nudge names what --where accepts.
hook "nudge explains what --where takes" "wants the file:line you changed" prompt-nudge.py "$NUDGE_PAYLOAD"

# This text is addressed to the model, and the whole reason it moved off the Stop
# hook is that a Stop hook's output is displayed to the user. UserPromptSubmit
# output is recorded as an attachment and never rendered.
mk_transcript 15
if nudge_out | grep -qF '"hookEventName": "UserPromptSubmit"'; then
  pass "the nudge goes out on the channel the user cannot see"
else
  fail "the nudge goes out on the channel the user cannot see" "$(nudge_out)"
fi
# suppressOutput was set on the Stop path for a version and the line still
# appeared on screen, quoted back verbatim. A flag that does nothing is worse
# than no flag: it makes the problem look handled.
if nudge_out | grep -qF 'suppressOutput'; then
  fail "no suppressOutput theatre" "the flag is back, and it never worked"
else
  pass "no suppressOutput theatre"
fi
if printf '%s' "$FIRST" | grep -qF 'suppressOutput'; then
  fail "the Stop line does not claim to be hidden either" "flag present"
else
  pass "the Stop line does not claim to be hidden either"
fi

# Still budgeted, for a different reason than before: nobody reads it now, but
# every session pays for it in context every stride. Measured on the common form
# — protocol in context, so no command block. The variant that spells the command
# out is longer by however long the paths are, which no length budget can govern.
mk_transcript 15
python3 -c 'import json,sys
open(sys.argv[1], "a").write(json.dumps({"type": "attachment", "attachment": {
    "type": "hook_additional_context",
    "content": ["## Open-decision log (qna)"]}}) + "\n")' "$NUDGE_T"
NUDGE_LEN=$(nudge_out | python3 -c \
  'import json,sys; print(len(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"]))')
if [ "$NUDGE_LEN" -lt 320 ]; then
  pass "nudge text stays cheap ($NUDGE_LEN chars)"
else
  fail "nudge text stays cheap" "$NUDGE_LEN chars, wanted under 320"
fi
mk_transcript 15
if nudge_out | grep -qF "do not mention this check"; then
  fail "nudge does not order the model to hide it" "still telling the model to conceal it"
else
  pass "nudge does not order the model to hide it"
fi

# Already nudged at 15: silent until 30, then due again. Reading the last count
# out of the recorded text is what makes this work — counting nudges and
# multiplying by the stride fires a burst the moment a session starts past
# several strides.
mk_transcript 29 15
hook "quiet one reply short of the next stride" "" prompt-nudge.py "$NUDGE_PAYLOAD"
mk_transcript 30 15
hook "nudges again at the next stride" "qna: 30 replies" prompt-nudge.py "$NUDGE_PAYLOAD"

# Mid-session install: the count arrives already past several strides. One nudge,
# not one per stride skipped.
mk_transcript 97
hook "one nudge, not a catch-up burst" "qna: 97 replies" prompt-nudge.py "$NUDGE_PAYLOAD"
mk_transcript 97 97
hook "quiet right after that nudge" "" prompt-nudge.py "$NUDGE_PAYLOAD"

# The command only rides along when the session never got the protocol.
mk_transcript 15
hook "carries the command when the protocol is absent" "qna-add --session nudged" \
  prompt-nudge.py "$NUDGE_PAYLOAD"
python3 -c 'import json,sys
open(sys.argv[1], "a").write(json.dumps({"type": "attachment", "attachment": {
    "type": "hook_additional_context",
    "content": ["## Open-decision log (qna)"]}}) + "\n")' "$NUDGE_T"
if nudge_out | grep -qF "so the command is"; then
  fail "omits the command when the protocol is in context" "spelled it out anyway"
else
  pass "omits the command when the protocol is in context"
fi

if [ -e "$NUDGE_PROJ/.qna" ]; then
  fail "nudging leaves no .qna/ behind" "$(ls -a "$NUDGE_PROJ/.qna" | tr '\n' ' ')"
else
  pass "nudging leaves no .qna/ behind"
fi

# Recording something used to switch the nudge off for the rest of the session.
# A real session then parked seven items, asked about four, got four answers,
# ran qna-resolve zero times and moved the watermark past the turns the answers
# were given in — the whole second half of it was in the state this hook had
# decided needed no reminding.
RECORDED="$WORK/recorded"
mkdir -p "$RECORDED"
"$SCRIPTS/qna-add" --session busy --project "$RECORDED" --transcript "$TRANSCRIPT" \
  --title "already parked" --chose "the default" --alt "b" --alt "c" --why "w" --where "$SAID" >/dev/null
BUSY_PAYLOAD=$(printf '{"session_id":"busy","cwd":"%s","transcript_path":"%s"}' \
  "$RECORDED" "$NUDGE_T")

mk_transcript 15
hook "an open entry is nudged about, not left alone" "qna: 15 replies, 1 still open here" \
  prompt-nudge.py "$BUSY_PAYLOAD"
hook "the unsettled nudge names the cost" "an answer never written back is gone" \
  prompt-nudge.py "$BUSY_PAYLOAD"
hook "and that filing is not settling" "changed nothing in the code was filed" \
  prompt-nudge.py "$BUSY_PAYLOAD"
# Two strides counted separately: crossing from one state to the other must not
# inherit the other's count, in either direction.
hook "the unsettled nudge is never the unrecorded one" "" prompt-nudge.py \
  "$(printf '{"session_id":"busy","cwd":"%s","transcript_path":"%s"}' "$RECORDED" "$WORK/none.jsonl")"
mk_transcript 29
mark_unsettled 15
hook "quiet one reply short of its own stride" "" prompt-nudge.py "$BUSY_PAYLOAD"
mk_transcript 30
mark_unsettled 15
hook "due again at its own stride" "qna: 30 replies, 1 still open" prompt-nudge.py "$BUSY_PAYLOAD"

# Settle it and the hook goes quiet: nothing recorded is a different state from
# recorded-and-finished, and only the first wants the protocol read back.
mk_transcript 15
"$SCRIPTS/qna-resolve" --session busy --project "$RECORDED" 1 \
  --result "the default stands" --quote "park that for now" >/dev/null
hook "silent once everything is settled" "" prompt-nudge.py "$BUSY_PAYLOAD"
not_in_out "and never claims nothing was recorded" "nothing recorded" \
  "$(printf '%s' "$BUSY_PAYLOAD" | "$SCRIPTS/prompt-nudge.py" 2>&1)"

# An earlier session's open items count too: they are open in this project, and
# the session that wrote them having ended does not settle anything.
"$SCRIPTS/qna-add" --session ghost --project "$RECORDED" --transcript "$TRANSCRIPT" \
  --title "left behind by a dead session" --chose "nothing" --alt "b" --alt "c" \
  --why "w" --where "$SAID" >/dev/null
hook "an earlier session's open items still nudge" "1 still open here" \
  prompt-nudge.py "$BUSY_PAYLOAD"

# Its own project, so the ids the Stop line prints are not whatever the nudge
# tests above happened to leave behind.
SEEN="$WORK/seen"
mkdir -p "$SEEN"
"$SCRIPTS/qna-add" --session seen --project "$SEEN" --transcript "$TRANSCRIPT" \
  --title "already parked" --chose "the default" --alt "b" --alt "c" --why "w" --where "$SAID" >/dev/null
BUSY_OUT=$(stop_ctx "$(printf '{"session_id":"seen","cwd":"%s"}' "$SEEN")")
# Self-contained: naming the item is what makes the line mean anything. "qna: 1
# parked" told the user nothing — in their words, "no idea what this means".
in_out "the Stop line names the item" "qna parked #1 — already parked" "$BUSY_OUT"
in_out "and what was done about it" "going with: the default" "$BUSY_OUT"
not_in_out "the Stop line is never a nudge" "nothing recorded" "$BUSY_OUT"

# ------------------------------------------- carried over from other sessions
printf '=== carried over from an earlier session\n'
# Entries are filed per session because a session is the unit of context, not
# because a decision expires with it. Measured: a project ended a session with
# seven items open and the next session in that directory could see none of
# them — no hook read them, no command listed them, and the 30-day orphan sweep
# was the only thing that would ever touch them again.
CARRY="$WORK/carry"
mkdir -p "$CARRY"
carry_add() { # <session> <title>
  "$SCRIPTS/qna-add" --session "$1" --project "$CARRY" --transcript "$TRANSCRIPT" \
    --title "$2" --chose "nothing yet" --alt "b" --alt "c" --why "w" --where "$SAID" >/dev/null
}
carry_add gone-session "left behind when that session ended"
carry_add gone-session "settled before it ended"
"$SCRIPTS/qna-resolve" --session gone-session --project "$CARRY" 2 \
  --result "done" --quote "park that for now" >/dev/null
carry_add live-session "parked in this session"

CARRY_OUT=$(printf '{"session_id":"live-session","cwd":"%s","transcript_path":"%s","source":"startup"}' \
  "$CARRY" "$TRANSCRIPT" | "$SCRIPTS/session-start.py" 2>&1 | python3 -c 'import json, sys
print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"], end="")')

in_out "surfaces an earlier session's open item" "left behind when that session ended" "$CARRY_OUT"
in_out "counts them separately from this session's" "Still open here from an earlier session (1)" "$CARRY_OUT"
in_out "still lists this session's own" "Currently parked (1)" "$CARRY_OUT"
not_in_out "does not resurrect what that session settled" "settled before it ended" "$CARRY_OUT"
# Ids belong to the file they were written in, so the way to close one is that
# session's own command line — not this session's with a foreign number.
in_out "gives that session's own resolve line" \
  "qna-resolve --session gone-session --project $CARRY" "$CARRY_OUT"
in_out "and that session's own line to print them in full" \
  "qna-list --session gone-session --project $CARRY" "$CARRY_OUT"
in_out "warns against re-parking them here" "open in two files" "$CARRY_OUT"

# A dead session with a long backlog must not push the protocol out of the way.
for i in 1 2 3 4 5 6 7 8 9 10; do carry_add gone-session "backlog item $i"; done
CARRY_MANY=$(printf '{"session_id":"live-session","cwd":"%s","transcript_path":"%s","source":"startup"}' \
  "$CARRY" "$TRANSCRIPT" | "$SCRIPTS/session-start.py" 2>&1 | python3 -c 'import json, sys
print(json.load(sys.stdin)["hookSpecificOutput"]["additionalContext"], end="")')
in_out "caps the listing and says how many it held back" "and 3 more" "$CARRY_MANY"

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
for want in FIRST_HUMAN_LINE FIRST_REPLY; do
  printf '%s' "$OUT" | grep -qF -- "$want" &&
    pass "keeps conversation: $want" ||
    fail "keeps conversation: $want" "missing from the window"
done
for gone in TOOLNOISE HIDDEN_THOUGHT SUBAGENT_CHATTER META_LINE SYSTEM_LINE; do
  printf '%s' "$OUT" | grep -qF -- "$gone" &&
    fail "filters out: $gone" "leaked into the window" ||
    pass "filters out: $gone"
done

# The second filter, and the one that sets the price: everything from the newest
# compact summary onward is verbatim in the model's context already, so printing
# it off disk buys a second copy at full cost. The summary entry is in context
# too, which is why it is cut at rather than after.
for gone in SUMMARY_BODY SECOND_HUMAN_LINE; do
  printf '%s' "$OUT" | grep -qF -- "$gone" &&
    fail "leaves what the context still holds: $gone" "printed a second copy" ||
    pass "leaves what the context still holds: $gone"
done
printf '%s' "$OUT" | grep -qF "2 newer turns not printed" &&
  pass "counts what it handed to the context scan" ||
  fail "counts what it handed to the context scan" "$OUT"
printf '%s' "$OUT" | grep -qF "no watermark yet" &&
  pass "first run reads back to the first turn" ||
  fail "first run reads back to the first turn" "$OUT"
printf '%s' "$OUT" | grep -qF "behind a context compaction" &&
  pass "says the printed turns are behind a compaction" ||
  fail "says the printed turns are behind a compaction" "$OUT"

# The ordinary outcome, and the one that has to not look like a failure: a
# session that never compacted has nothing on disk the model cannot already see.
# It must say so and hand the stretch over by count, not print an empty window.
FRESH_PROJ="$WORK/freshproj"
FRESH_T="$WORK/fresh.jsonl"
mkdir -p "$FRESH_PROJ/.qna"
{
  printf '{"type":"user","uuid":"f1","timestamp":"2026-07-27T03:00:00Z","message":{"role":"user","content":[{"type":"text","text":"UNCOMPACTED_LINE"}]}}\n'
  printf '{"type":"assistant","uuid":"f2","timestamp":"2026-07-27T03:00:10Z","message":{"role":"assistant","content":[{"type":"text","text":"UNCOMPACTED_REPLY"}]}}\n'
} >"$FRESH_T"
FRESH_OUT=$("$SCRIPTS/qna-scan" --session fresh-session --project "$FRESH_PROJ" \
  --transcript "$FRESH_T" 2>&1)
printf '%s' "$FRESH_OUT" | grep -qF "none of them behind a compaction" &&
  pass "no compaction: says so instead of printing" ||
  fail "no compaction: says so instead of printing" "$FRESH_OUT"
printf '%s' "$FRESH_OUT" | grep -qF "UNCOMPACTED_LINE" &&
  fail "no compaction: prints nothing" "printed a turn the context holds" ||
  pass "no compaction: prints nothing"
printf '%s' "$FRESH_OUT" | grep -qF "2 turns in the window" &&
  pass "no compaction: hands over the count" ||
  fail "no compaction: hands over the count" "$FRESH_OUT"

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

# Only the new turn comes back, and it resumed by uuid rather than by clock. The
# second summary is what makes the new turn printable at all: without a
# compaction behind it, u3 is still in context and the right answer is to print
# nothing. Resume and the compaction cut are separate boundaries and both apply.
{
  printf '{"type":"user","uuid":"u3","timestamp":"2026-07-27T01:03:00Z","message":{"role":"user","content":[{"type":"text","text":"THIRD_HUMAN_LINE"}]}}\n'
  printf '{"type":"user","uuid":"c2","timestamp":"2026-07-27T01:04:00Z","isCompactSummary":true,"message":{"role":"user","content":"SECOND_SUMMARY_BODY"}}\n'
} >>"$SCAN_T"
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

# A cap that stays quiet reads as "you have seen everything". The trailing
# summary puts all 60 turns behind a compaction, which is the only state in which
# the cap can be reached at all — turns still in context are never printed, so
# they can never overflow.
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
    f.write(json.dumps({
        "type": "user", "uuid": "bsum", "timestamp": "2026-07-27T02:59:00Z",
        "isCompactSummary": True,
        "message": {"role": "user", "content": "BIG_SUMMARY_BODY"},
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
