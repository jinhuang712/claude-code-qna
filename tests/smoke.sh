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

# ---------------------------------------------------------------------- summary
printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ] || exit 1
