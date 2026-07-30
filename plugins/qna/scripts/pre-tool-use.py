#!/usr/bin/env python3
"""PreToolUse hook: enforce the asking rules mechanically, and keep .qna/ closed.

Two jobs, both the same idea — a rule written only in prose is a rule the next
session may or may not follow.

**The asking rules.** The recording side has qna-add refusing bad entries.
Without this, the asking side would have nothing but prose rules — you could not
invent an alternative and get away with it, but you could ship a two-option
yes/no question and nobody would stop you. This closes that gap.

It validates every AskUserQuestion, everywhere.

That is a reversal. The rules used to apply only while /qna:ask was running,
scoped by a marker file, on the reasoning that they are right for settling a
backlog and needlessly rigid for ordinary conversation. Then the transcripts
supplied the comparison: over three weeks, 7 questions were refused for having
fewer than three options and 6 of those were asked outside the command.
/qna:ask runs a few times a day; ordinary questions run dozens of times.
Applying the strictest rules only in the rarest place had it backwards.

The cost is real and was accepted knowingly: a question that genuinely has two
courses of action and no third now has to find one.

**What it asks of previews moved once, and the measurement is the reason.** The
first version demanded a preview on every single-select option. It worked: over
the same three weeks, coverage went from 68 of 613 questions before this hook
was installed to 342 of 384 after — 11% to 89%. It also refused 59% of
everything asked, and a refusal is a full round trip on a tool that is already
slow. Worse, "there is no such thing as an option with nothing to show" pushed
the model into inventing artifacts: one refusal produced three `git branch`
outputs, 633 characters, differing only in where the asterisk sat, for a
question whose options were three branch names.

So the demand moved to where the harm actually is. `preview` and `description`
are the same slot — the panel that renders for whichever option has focus, one
to look at and one to read. A question is refused when that slot is empty, not
when `preview` in particular is missing, and refused when the slot is filled for
some options and not others, because a panel that blinks in and out destroys the
one thing a preview is for: seeing what changes between the options. Against the
same three weeks the rule below refuses 3.9% where the old one refused 58.9%,
and every question it lets through still says something the label does not.

**.qna/ is script-owned.** Everything that writes into that directory goes
through a script with gates on it: qna-add wants two alternatives and a citation,
qna-resolve wants the user's own words, qna-drop wants one of two reasons and a
why. A free-hand Edit walks around all of it, and deleting an entry by hand loses
the record of why it closed — the one operation nobody can review afterwards.
Reading has the same problem in a quieter form: the file carries closed entries
whose Result lines are nobody's business any more, and a reader who forgets to
skip a ticked box asks the user something they already answered.

So the file tools are refused on those paths and pointed at the scripts. The
Bash rule is narrower on purpose: a command that names a path into .qna/ is
refused, and so is rm/mv/cp/truncate aimed at the directory itself, but merely
mentioning ".qna" — grepping this plugin's own source, for instance — is not.
"""

import json
import os
import re
import shlex
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qna_lib  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))

MIN_OPTIONS = 3
# A multi-select is not measured the same way. The floor of 3 exists to stop a
# yes/no wearing a costume, and two check-boxes are not a yes/no: they answer
# neither / A / B / both. Holding multi-select to 3 also breaks G2.6 outright —
# "which of these fields do you want" frequently has exactly two candidates, and
# refusing it forces the question back into the pair of yes/no questions that
# multi-select exists to collapse.
MIN_OPTIONS_MULTI = 2
MAX_OPTIONS = 4

# A preview past this is an outlier: the real p90 across three weeks is 319.
MAX_PREVIEW = 400
# And past this in total, the payload starts failing to parse — every one of the
# 22 observed __unparsedToolInput events was a question carrying large previews.
MAX_PREVIEW_TOTAL = 1000
# Two questions this close together, both small, were one question split in two.
# 40% of consecutive asks land inside this window.
BATCH_WINDOW = 300
BATCH_SMALL = 2

REC = re.compile(r"推荐|recommend", re.I)


def deny(reason):
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }
        )
    )
    return 0


def note(text, updated=None):
    """Let the call through and hand the model a sentence beside the result.

    Deliberately no `permissionDecision`. Emitting an explicit "allow" would
    take over the permission flow for this call, and this hook's matcher also
    covers Bash, Write and Edit — a stray allow there would wave through
    something the user was meant to be asked about. Saying nothing about
    permission leaves that flow exactly as it was.
    """
    out = {"hookEventName": "PreToolUse", "additionalContext": text}
    if updated is not None:
        out["updatedInput"] = updated
    print(json.dumps({"hookSpecificOutput": out}))
    return 0


def check(questions):
    for i, q in enumerate(questions, 1):
        label = q.get("header") or q.get("question", "")[:40] or f"question {i}"
        options = q.get("options") or []
        n = len(options)
        multi = bool(q.get("multiSelect"))

        if multi and n < MIN_OPTIONS_MULTI:
            return (
                f'Refused ("{label}"): {n} option is not something to choose '
                f"between. A multi-select needs at least {MIN_OPTIONS_MULTI} "
                f"items on the list."
            )
        if not multi and n < MIN_OPTIONS:
            return (
                f'Refused ("{label}"): {n} options is a yes/no question in '
                f"disguise. Every question needs at least {MIN_OPTIONS} formed, "
                f"genuinely different courses of action. If you can only think "
                f"of one plus its negation, you have not thought it through — "
                f"produce a conservative, an aggressive, and a middle option."
            )
        if n > MAX_OPTIONS:
            return (
                f'Refused ("{label}"): {n} options exceeds the tool cap of '
                f"{MAX_OPTIONS}."
            )

        if multi:
            # The panel does not render for multiSelect at all, so there is no
            # asymmetry to catch and nowhere for detail to go but description.
            continue

        labels = [(o.get("label") or "?").strip() for o in options]
        previews = [(o.get("preview") or "").strip() for o in options]
        descs = [(o.get("description") or "").strip() for o in options]

        shown = [bool(p) for p in previews]
        if any(shown) and not all(shown):
            blank = [lb for lb, s in zip(labels, shown) if not s]
            return (
                f'Refused ("{label}"): the panel is filled for some options and '
                f"empty for others: {', '.join(blank)}. It renders for whichever "
                f"option has focus, so a half-filled set makes it blink in and "
                f"out, and what a preview is for — seeing what changes as you "
                f"move between the options — is exactly what that destroys. "
                f"Give every option one, or give none and put the detail in the "
                f"descriptions."
            )

        if not any(shown):
            thin = [lb for lb, dc in zip(labels, descs) if len(dc) <= len(lb)]
            if thin:
                return (
                    f'Refused ("{label}"): these options say nothing beyond '
                    f"their own label: {', '.join(thin)}. With no preview and a "
                    f"description no longer than the label, the reader is "
                    f"choosing from a handful of characters. Fill one of the "
                    f"two: a preview when the difference is something to look "
                    f"at, a description when the label needs a sentence. Do not "
                    f"invent a preview for an option its label already settles "
                    f"— write the description instead."
                )
    return None


def normalize(questions):
    """Lossless repairs, applied in place. Returns a note, or None.

    Only two things qualify: reordering options, and dropping a field the tool
    never renders. Both leave every character the model wrote intact. Truncating
    an over-long preview would also save a round trip and is deliberately not
    done here — it would silently delete something the user was meant to read,
    which trades the wrong thing away.
    """
    moved, stripped = [], []
    for q in questions:
        if not isinstance(q, dict):
            continue
        options = q.get("options") or []
        if bool(q.get("multiSelect")):
            for o in options:
                if isinstance(o, dict) and o.pop("preview", None):
                    stripped.append((o.get("label") or "?").strip())
            continue
        hit = next(
            (
                i
                for i, o in enumerate(options)
                if isinstance(o, dict) and REC.search(o.get("label") or "")
            ),
            None,
        )
        if hit:  # index 0 is already where it belongs
            options.insert(0, options.pop(hit))
            moved.append((options[0].get("label") or "?").strip())

    if moved:
        return (
            f"Moved the recommended option to the top: {', '.join(moved)}. A "
            f"recommendation is read first or it is not doing its job — it "
            f"turns the question from \"work this out\" into \"do you agree\", "
            f"and that only works if it is the first thing on the list. Send it "
            f"first next time; nothing else about the question was touched."
        )
    if stripped:
        return (
            f"Dropped a preview from a multi-select: {', '.join(stripped)}. The "
            f"panel does not render for multi-select at all, so those "
            f"characters would never have reached the screen. Detail for a "
            f"multi-select goes in the descriptions."
        )
    return None


def soft(questions):
    """Quality notes that do not justify a round trip. Returns a note, or None."""
    for i, q in enumerate(questions, 1):
        if not isinstance(q, dict) or q.get("multiSelect"):
            continue
        label = q.get("header") or q.get("question", "")[:40] or f"question {i}"
        previews = [
            ((o.get("label") or "?").strip(), len((o.get("preview") or "").strip()))
            for o in (q.get("options") or [])
            if isinstance(o, dict)
        ]
        long = [(lb, n) for lb, n in previews if n > MAX_PREVIEW]
        if long:
            worst = max(long, key=lambda x: x[1])
            return (
                f'("{label}") The preview on "{worst[0]}" is {worst[1]} '
                f"characters, where the usual one is under 200. A preview is "
                f"read by looking, not by reading — whatever in there needs "
                f"reading in order belongs in the description, and whatever "
                f"does not change between the options is an anchor the eye only "
                f"needs a line or two of."
            )
        total = sum(n for _, n in previews)
        if total > MAX_PREVIEW_TOTAL:
            return (
                f'("{label}") The previews add up to {total} characters. Past '
                f"about {MAX_PREVIEW_TOTAL} the payload starts failing to parse, "
                f"and a question that fails to parse asks nothing at all. Shorten "
                f"the parts that are identical across the options first — those "
                f"cost three readings and carry no information."
            )
    return None


def batching(session, n_q, now):
    """A question that arrived minutes after the last one was part of it."""
    state = qna_lib.load_ask_state(session)
    last_t, last_n = state.get("t"), state.get("n_q")
    qna_lib.save_ask_state(session, {"t": now, "n_q": n_q})

    if not isinstance(last_t, (int, float)) or not isinstance(last_n, int):
        return None
    gap = now - last_t
    if not (0 <= gap < BATCH_WINDOW):
        return None
    if n_q > BATCH_SMALL or last_n > BATCH_SMALL:
        return None
    return (
        f"The last question went out {int(gap // 60)}m{int(gap % 60):02d}s ago "
        f"carrying {last_n}, and this one carries {n_q}; the tool takes four at "
        f"a time. Did this one only become askable after that answer, or could "
        f"the two have gone together? Every extra call is another interruption "
        f"— across three weeks 40% of questions followed the previous answer "
        f"within five minutes."
    )


PATH_TOOLS = {"Read", "Edit", "MultiEdit", "Write", "NotebookEdit", "Grep", "Glob"}
PATH_KEYS = ("file_path", "notebook_path", "path")

# A path into .qna/, or the directory itself.
QNA_PATH = re.compile(r"(^|/)\.qna(/|$)")
# In a command line: a path into the directory...
QNA_IN_COMMAND = re.compile(r"\.qna/")
# ...or the directory itself on the wrong end of something destructive.
QNA_DESTRUCTIVE = re.compile(
    r"\b(rm|rmdir|mv|cp|truncate|shred)\b[^|;&]*[\s'\"=/]\.qna(?![\w.-])"
)

SCRIPT_OWNED = (
    "Refused: .qna/ is script-owned. That file is an id sequence, a checkbox "
    "state machine and a set of fields the other scripts parse — a hand edit "
    "breaks them silently, and removing an entry by hand loses the record of why "
    "it closed. Reading it raw is how a closed entry gets asked about twice. Use "
    "these instead, exactly as spelled:"
)


def routes(data):
    """The commands that replace whatever was just refused, fully spelled out.

    The refusal has to carry them. "Use qna-list" is not actionable in the shell
    the model runs commands in: nothing exports CLAUDE_PROJECT_DIR there and the
    working directory moves, so a hand-assembled path is the exact failure this
    plugin is arranged to prevent. The hook knows the session and can resolve the
    anchor, so it does that here rather than asking the caller to.
    """
    session = data.get("session_id")
    if not session:
        return (
            "\n  read:   qna-list --session <id> --project <dir>"
            "\n  settle: qna-resolve <id> --result <what> --quote <their words>"
            "\n  drop:   qna-drop <id> --reason moot|trivia --why <one line>"
            "\n  clear:  qna-prune"
        )
    project = qna_lib.find_session_dir(data.get("cwd"), session)

    def line(name):
        return "{} --session {} --project {}".format(
            shlex.quote(os.path.join(HERE, name)),
            shlex.quote(session),
            shlex.quote(project),
        )

    return (
        f"\n  read:   {line('qna-list')}"
        f"\n  settle: {line('qna-resolve')} <id> --result <what was decided> "
        f"--quote <their words>"
        f"\n  drop:   {line('qna-drop')} <id> --reason moot|trivia "
        f"--why <one line>"
        f"\n  clear:  {line('qna-prune')}"
    )


def guard(tool_name, tool_input):
    """Whether this call reaches into .qna/. Returns True to refuse."""
    if tool_name == "Bash":
        cmd = tool_input.get("command") or ""
        return bool(QNA_IN_COMMAND.search(cmd) or QNA_DESTRUCTIVE.search(cmd))
    if tool_name in PATH_TOOLS:
        candidates = [tool_input.get(k) or "" for k in PATH_KEYS]
        for e in tool_input.get("edits") or []:
            if isinstance(e, dict):
                candidates.append(e.get("file_path") or "")
        return any(QNA_PATH.search(str(c)) for c in candidates)
    return False


def main():
    data = qna_lib.hook_input()
    tool_name = data.get("tool_name")
    tool_input = data.get("tool_input") or {}

    if tool_name != "AskUserQuestion":
        if guard(tool_name, tool_input):
            return deny(SCRIPT_OWNED + routes(data))
        return 0

    # A payload that failed to parse arrives with the raw text under
    # __unparsedToolInput and no questions at all, so every rule below silently
    # passes and the call goes on to fail for reasons that name none of this.
    # Observed once in a real session: the next attempt was a two-option
    # question, which suggests the model read the failure as "ask something
    # smaller" rather than "resend that". Refusing puts the cause in writing.
    if "__unparsedToolInput" in tool_input:
        size = len(str(tool_input.get("__unparsedToolInput") or ""))
        return deny(
            f"Refused: the question payload did not parse, so none of the "
            f"asking rules could be checked. It was {size} characters, and this "
            f"is almost always size — the previews are the usual culprit, and "
            f"about {MAX_PREVIEW_TOTAL} per question is where it starts to bite. "
            f"Shorten them and send the same questions again; do not simplify "
            f"the questions to get around it."
        )

    questions = tool_input.get("questions") or []

    reason = check(questions)
    if reason:
        return deny(reason)

    # Past the hard gate. Everything below rides along with the tool result and
    # costs no round trip, so it is capped at one line — a hint nobody reads is
    # worse than no hint. Order is by how much the model needs to know it.
    fixed = normalize(questions)
    # Runs unconditionally: it records when this question went out, and a
    # short-circuit here would lose the timestamp the next call compares against.
    later = batching(data.get("session_id") or "", len(questions), time.time())
    hint = fixed or soft(questions) or later
    if fixed:
        return note(hint, updated=tool_input)
    if hint:
        return note(hint)
    return 0


if __name__ == "__main__":
    sys.exit(main())
