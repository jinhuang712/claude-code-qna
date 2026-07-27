#!/usr/bin/env python3
"""Stop hook: report the backlog, or re-surface the protocol if there is none.

Two jobs, and a session is only ever in one of them.

**Something has been recorded** — report when the count changes, and only then.
Repeating "2 parked" at the end of every reply for as long as the backlog sits
there is noise, and noise is what makes a reminder stop registering. A change
means something actually happened: one was parked, or one was settled.

**Nothing has been recorded** — re-surface the protocol every 15 replies, at a
fixed cadence for as long as the session runs. Milestones that thin out (15,
then 45, then 90) were rejected: a decision made at reply 200 is no less worth
recording than one made at reply 15, and a reminder that fades leaves the long
tail of a long session uncovered. The earlier design nudged every single turn
and was cut for costing a per-turn reminder to buy very little. What that traded
away is now measured: a real 54-minute session with 84 conversation turns and 49
questions asked recorded zero entries, and this hook never said a word, because
the count never changed from zero. The protocol was injected at turn zero and
never mentioned again. "Very little" was being compared against nothing at all.

The nudge does not move the judgement out of the model — that self-interruption
is the design, not a workaround for it. It only puts the protocol back within
reach, with the command spelled out, and says plainly that finding nothing is a
valid outcome.

Note the one-turn lag: a Stop hook's additionalContext reaches the model on its
*next* call, so the line surfaces at the end of the following reply.
"""

import os
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qna_lib  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))

# How often to re-surface the recording protocol in a session that has recorded
# nothing. A fixed stride, not a series that thins out: a choice made at reply
# 200 is no less worth recording than one made at reply 15.
NUDGE_EVERY = 15

# Nudges are counted out of the transcript rather than a state file. A Stop hook
# has nowhere to write that would not put a .qna/ into every project a session
# was ever opened in, which is the bug that made this hook silent to begin with.
# additionalContext lands in the transcript as a hook_additional_context entry,
# so the record of having nudged is already on disk — no second copy needed.
NUDGE_TAG = "qna-unrecorded-nudge"
CONTEXT_LINE = "hook_additional_context"


# A transcript this large means something pathological; skip rather than read it
# at the end of every turn.
MAX_TRANSCRIPT_BYTES = 64 * 1024 * 1024


def turns_and_nudges(path):
    """Assistant replies so far, and nudges already sent.

    The reply count goes through qna_lib.iter_turns because that is the one
    place allowed to know the transcript's shape. An earlier version matched
    '"type":"assistant"' as a substring and silently counted zero the moment the
    separator had a space in it — the exact brittleness that rule exists for.

    The nudge count cannot use iter_turns: additionalContext arrives as an
    attachment entry, which iter_turns drops. Substring matching is safe there
    because the tag is our own literal, not a field name.
    """
    if os.path.getsize(path) > MAX_TRANSCRIPT_BYTES:
        return 0, 0  # too big to read: turns stay 0, so nothing fires

    nudges = 0
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if CONTEXT_LINE in line and NUDGE_TAG in line:
                nudges += 1

    turns = sum(1 for t in qna_lib.iter_turns(path) if t["role"] == "assistant")
    return turns, nudges


def nudge(session, project, transcript):
    """Re-surface the protocol every NUDGE_EVERY replies, silently."""
    if not transcript or not os.path.exists(transcript):
        return 0
    try:
        turns, sent = turns_and_nudges(transcript)
    except OSError:
        return 0
    if turns < (sent + 1) * NUDGE_EVERY:
        return 0

    add = "{} --session {} --project {}".format(
        shlex.quote(os.path.join(HERE, "qna-add")),
        shlex.quote(session),
        shlex.quote(project),
    )
    if transcript:
        add += " --transcript {}".format(shlex.quote(transcript))

    qna_lib.emit(
        "Stop",
        f"[{NUDGE_TAG}] {turns} replies into this session and nothing has been "
        f"parked. Look back over the last few turns for a choice you made on the "
        f"user's behalf without checking: a default you picked, a library or "
        f"shape you settled on, an approach you took where another was defensible."
        f"\n\nIf one clears all three bars — two alternatives a competent engineer "
        f"might prefer, costs more than a line or two to change later, and the "
        f"user would frown at learning you decided it alone — record it:"
        f"\n\n  {add} \\\n      --title <one line> --chose <what you did> \\\n"
        f"      --alt <alternative> --alt <another> \\\n"
        f"      --why <the tradeoff> --where <file:line or words actually said>"
        f"\n\nIf nothing clears them, that is a real answer: say nothing and move "
        f"on. Do not mention this check to the user either way, and do not repeat "
        f"this text back.",
    )
    return 0


def main():
    data = qna_lib.hook_input()
    session = data.get("session_id")
    if not session:
        return 0

    project = qna_lib.find_session_dir(data.get("cwd"), session)
    transcript = data.get("transcript_path")

    # Two different jobs, and which one applies is decided by whether this
    # session has ever recorded anything. Neither writes to disk in the
    # nothing-recorded case: a hook that leaves a trace in every project a
    # session was opened in is the bug that made this one silent.
    if not qna_lib.qna_dir_exists(project):
        return nudge(session, project, transcript)

    path = qna_lib.pending_path(session, project, create=False)
    if not os.path.exists(path):
        return nudge(session, project, transcript)

    count = len(qna_lib.open_entries(path))
    if count == 0 and not qna_lib.read_entries(path):
        return nudge(session, project, transcript)

    meta = qna_lib.load_meta(session, project)
    if count == meta.get("reported_count"):
        return 0
    meta["reported_count"] = count
    try:
        qna_lib.save_meta(session, meta, project)
    except OSError:
        pass  # Worst case the same line repeats once. Not worth failing over.

    if count == 0:
        return 0

    qna_lib.emit(
        "Stop",
        f"qna: {count} decision(s) parked. Surface this as a single short line "
        f"at the end of your next reply, e.g. \"qna: {count} parked — "
        f"/qna:ask to settle\". Do not expand on it.",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
