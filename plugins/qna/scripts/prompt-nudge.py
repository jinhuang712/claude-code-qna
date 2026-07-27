#!/usr/bin/env python3
"""UserPromptSubmit hook: the two things a session stops doing on its own.

Both are measured, both on real sessions, and they are opposite failures of the
same silence — the protocol is injected at SessionStart and then never mentioned
again.

**Nothing recorded.** 54 minutes, 84 conversation turns, 49 questions asked,
zero entries, and no part of the system said a word about it.

**Recorded and then abandoned.** Seven items parked in one project, four of them
put to the user, four answers given — and qna-resolve run zero times, with the
scan watermark moved past the very turns the answers were given in. The answers
survive only in a transcript nothing will read again, and not one of the seven
changed a line of code. This hook used to switch itself off permanently the
moment a session recorded anything, which is exactly the state that session was
in for its whole second half.

So every NUDGE_EVERY replies, for as long as the session runs, whichever of the
two applies gets said again.

**Why this is not a Stop hook.** It used to be, and a Stop hook's
additionalContext is rendered to the user as "Stop hook feedback" — so a
paragraph addressed to the model, naming a script and the shape of its
--where argument, was landing on the user's screen after their replies.
suppressOutput does not stop it. UserPromptSubmit output is recorded as an
attachment instead and never displayed, which is the right channel for text the
user has no reason to read. It also lands earlier: at the top of the turn rather
than one reply behind.

**A fixed stride, not a series that thins out.** 15, then 45, then 90 was
rejected: a decision made at reply 200 is no less worth recording than one made
at reply 15, and a reminder that fades leaves the long tail of a long session
uncovered.

The nudge does not move the judgement out of the model — that self-interruption
is the design, not a workaround for it. It only puts the protocol back within
reach and says plainly that finding nothing is a valid outcome.
"""

import os
import re
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qna_lib  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))

NUDGE_EVERY = 15

# Nudges are counted out of the transcript rather than a state file. A hook that
# writes has nowhere to put it that would not leave a .qna/ in every project a
# session was ever opened in, which is the bug that made the old version silent.
# additionalContext lands in the transcript as a hook_additional_context entry,
# so the record of having nudged is already on disk — no second copy needed.
#
# The reply count at the time of each nudge is carried in the text and read back
# out of it. Counting nudges and multiplying by the stride is not equivalent: a
# session that installs the plugin mid-way arrives with the count already past
# several strides, and "have I sent as many as the count implies" then fires a
# burst of catch-up nudges in consecutive turns. What matters is how long it has
# been since the last one.
CONTEXT_LINE = "hook_additional_context"

# Two states, two marks, counted independently. A session crosses from the first
# to the second the moment it records anything, and the stride restarts there
# rather than inheriting a count from a nudge about something else.
NUDGE_MARKS = {
    "unrecorded": re.compile(r"qna: (\d+) replies, nothing recorded"),
    "unsettled": re.compile(r"qna: (\d+) replies, \d+ still open"),
}

# A transcript this large means something pathological; skip rather than read it
# at the top of every turn.
MAX_TRANSCRIPT_BYTES = 64 * 1024 * 1024

# The protocol, if it was ever injected. Its absence means a mid-session install:
# the model has never seen the recording command, so the nudge has to carry it.
PROTOCOL_MARK = "Open-decision log"


def transcript_state(path, kind):
    """Assistant replies so far, replies at the last nudge of this kind,
    protocol seen.

    The reply count goes through qna_lib.iter_turns because that is the one place
    allowed to know the transcript's shape. An earlier version matched
    '"type":"assistant"' as a substring and silently counted zero the moment the
    separator had a space in it — the exact brittleness that rule exists for.

    The other two cannot use iter_turns: hook output arrives as an attachment
    entry, which iter_turns drops. Substring matching is safe there because both
    marks are our own literals, and both are plain ASCII — a transcript escapes
    non-ASCII into backslash-u sequences, which would break the match silently.
    """
    if os.path.getsize(path) > MAX_TRANSCRIPT_BYTES:
        return 0, 0, True  # too big to read: turns stay 0, so nothing fires

    mark = NUDGE_MARKS[kind]
    last_nudge = 0
    protocol = False
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if CONTEXT_LINE not in line:
                continue
            if PROTOCOL_MARK in line:
                protocol = True
            m = mark.search(line)
            if m:
                last_nudge = max(last_nudge, int(m.group(1)))

    turns = sum(1 for t in qna_lib.iter_turns(path) if t["role"] == "assistant")
    return turns, last_nudge, protocol


def main():
    data = qna_lib.hook_input()
    session = data.get("session_id")
    if not session:
        return 0

    project = qna_lib.find_session_dir(data.get("cwd"), session)
    transcript = data.get("transcript_path")
    if not transcript or not os.path.exists(transcript):
        return 0

    # Which of the two nudges applies, if either. Checked without touching disk:
    # creating the directory here would litter one into every project.
    #
    # Recording something used to switch this hook off for the rest of the
    # session, on the reasoning that a session already using the tool does not
    # need reminding of it. A real session disproved that in the worst way: it
    # parked seven items, asked the user about four of them, got four answers,
    # ran qna-resolve zero times, and moved the scan watermark past the very
    # turns the answers were given in. Having recorded something is not the same
    # as having finished with it.
    entries, open_count = [], 0
    if qna_lib.qna_dir_exists(project):
        path = qna_lib.pending_path(session, project, create=False)
        if os.path.exists(path):
            entries = qna_lib.read_entries(path)
        open_count = len([e for e in entries if not e["done"]]) + sum(
            len(v) for _, v in qna_lib.other_session_entries(session, project)
        )

    if open_count:
        kind = "unsettled"
    elif not entries:
        kind = "unrecorded"
    else:
        return 0  # recorded, and every one of them settled

    try:
        turns, last, protocol = transcript_state(transcript, kind)
    except OSError:
        return 0
    if turns - last < NUDGE_EVERY:
        return 0

    if kind == "unsettled":
        # Aimed at one failure and no other: an answer that was given out loud
        # and never written down. The watermark is the part that makes it
        # unrecoverable rather than merely untidy.
        text = (
            f"qna: {turns} replies, {open_count} still open here. If the user "
            f"has taken a position on one since, run QNA_RESOLVE for it now — "
            f"/qna:ask moves the watermark past the turn they said it in, and "
            f"an answer never written back is gone. A settled decision that "
            f"changed nothing in the code was filed, not settled."
        )
        qna_lib.emit("UserPromptSubmit", text)
        return 0

    # One sentence. The three bars collapse into the one that does the work —
    # reversal cost is what separates a decision from an implementation detail —
    # and the --where hint rides along because the first nudge that did produce a
    # recording attempt lost it to a paraphrased citation.
    text = (
        f"qna: {turns} replies, nothing recorded. If you made a call on the "
        f"user's behalf that would cost real work to reverse, record it with "
        f"QNA_ADD (--where wants the file:line you changed, or their words "
        f"verbatim — not a paraphrase). Finding none is a valid answer."
    )
    if not protocol:
        add = "{} --session {} --project {}".format(
            shlex.quote(os.path.join(HERE, "qna-add")),
            shlex.quote(session),
            shlex.quote(project),
        )
        add += " --transcript {}".format(shlex.quote(transcript))
        text += (
            f"\n\nThis session never received the qna block, so the command is:\n"
            f"  {add} --title <one line> --chose <what you did> "
            f"--alt <one> --alt <another> --why <the tradeoff> "
            f"--where <file:line or words actually said>"
        )
    qna_lib.emit("UserPromptSubmit", text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
