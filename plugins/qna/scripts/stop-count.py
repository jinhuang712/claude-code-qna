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
reach and says plainly that finding nothing is a valid outcome.

**A Stop hook's additionalContext is shown to the user.** Claude Code renders it
as "Stop hook feedback" in the transcript, so everything here is read by a person
as well as by the model. This was got wrong once: the first version was a 150-word
instruction block ending in "do not mention this check to the user", written on
the assumption that nobody would see it. The user saw all of it, including a raw
absolute path, and said so. Two consequences hold now:

  * Every line is written to read sensibly to a person. Short, plain, no
    templates, no instruction voice where a statement will do.
  * Nothing asks the model to repeat a line back. The hook's own output *is* the
    surfacing. Telling the model to echo it produced the message twice, which is
    what made it read as abrupt.

Note the one-turn lag: additionalContext reaches the model on its *next* call, so
anything the model does in response lands a reply later.
"""

import os
import re
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
#
# The reply count at the time of each nudge is carried in the visible text and
# read back out of it. Counting nudges and multiplying by the stride is not
# equivalent: a session that installs the plugin mid-way arrives with the count
# already past several strides, and "have I sent as many as the count implies"
# then fires a burst of catch-up nudges in consecutive turns. What matters is how
# long it has been since the last one.
CONTEXT_LINE = "hook_additional_context"
NUDGE_MARK = re.compile(r"qna: (\d+) replies, nothing recorded")

# A transcript this large means something pathological; skip rather than read it
# at the end of every turn.
MAX_TRANSCRIPT_BYTES = 64 * 1024 * 1024

# The protocol, if it was ever injected. Its absence means a mid-session install:
# the model has never seen the recording command, so the nudge has to carry it.
PROTOCOL_MARK = "Open-decision log"


def transcript_state(path):
    """Assistant replies so far, replies at the last nudge, protocol seen.

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

    last_nudge = 0
    protocol = False
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            if CONTEXT_LINE not in line:
                continue
            if PROTOCOL_MARK in line:
                protocol = True
            m = NUDGE_MARK.search(line)
            if m:
                last_nudge = max(last_nudge, int(m.group(1)))

    turns = sum(1 for t in qna_lib.iter_turns(path) if t["role"] == "assistant")
    return turns, last_nudge, protocol


def nudge(session, project, transcript):
    """Re-surface the recording protocol, NUDGE_EVERY replies since the last."""
    if not transcript or not os.path.exists(transcript):
        return 0
    try:
        turns, last, protocol = transcript_state(transcript)
    except OSError:
        return 0
    if turns - last < NUDGE_EVERY:
        return 0

    # Short and plain: the user reads this too. The three bars collapse into the
    # one that does the work — reversal cost is what separates a decision from an
    # implementation detail, and it is the one a model misjudges least often.
    text = (
        f"qna: {turns} replies, nothing recorded in this session. Look back for a "
        f"choice you made on the user's behalf that would cost real work to "
        f"reverse. Record it with QNA_ADD if you find one; if you do not, that is "
        f"a real answer — say nothing and carry on.\n\n"
        f"--where takes the file:line you changed, or words the user said "
        f"verbatim. Recalling a paraphrase will be refused; the file is the "
        f"easier of the two this long after the fact."
    )
    if not protocol:
        add = "{} --session {} --project {}".format(
            shlex.quote(os.path.join(HERE, "qna-add")),
            shlex.quote(session),
            shlex.quote(project),
        )
        if transcript:
            add += " --transcript {}".format(shlex.quote(transcript))
        text += (
            f"\n\nThis session never received the qna block, so the command is:\n"
            f"  {add} --title <one line> --chose <what you did> "
            f"--alt <one> --alt <another> --why <the tradeoff> "
            f"--where <file:line or words actually said>"
        )
    qna_lib.emit("Stop", text)
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

    entries = qna_lib.open_entries(path)
    count = len(entries)
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

    # Named, not counted. "qna: 1 parked" was reported as meaningless — "no idea
    # what this means" — because nothing in it says what was parked or what to do.
    # And no instruction to echo it: this text is on the user's screen already, so
    # asking the model to repeat it printed the same message twice.
    newest = max(entries, key=lambda e: e["id"])["title"]
    if len(newest) > 60:
        newest = newest[:57] + "..."
    if count == 1:
        body = f'1 decision recorded here and still open — "{newest}". ' \
               "/qna:ask turns it into a clickable question."
    else:
        body = f'{count} decisions recorded here and still open, newest ' \
               f'"{newest}". /qna:ask turns them into clickable questions.'
    qna_lib.emit("Stop", f"qna: {body} No need to relay this line.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
