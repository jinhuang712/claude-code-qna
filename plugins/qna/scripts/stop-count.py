#!/usr/bin/env python3
"""Stop hook: report when the number of parked decisions changes.

This hook reports, it does not nag. An earlier design had it prompt the model
to reconsider whether the turn contained an unrecorded decision; that was cut,
because retrospective self-checking is weak and it cost a per-turn nudge to buy
very little. Counting entries in a file needs no judgement at all, which is why
it is cheap enough to run every turn.

It fires only on a change. Repeating "2 parked" at the end of every reply for as
long as the backlog sits there is noise, and noise is what makes a reminder
stop registering. A change means something actually happened: a decision was
parked, or one was settled.

Note the one-turn lag: a Stop hook's additionalContext reaches the model on its
*next* call, so the line surfaces at the end of the following reply.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qna_lib  # noqa: E402


def main():
    data = qna_lib.hook_input()
    session = data.get("session_id")
    if not session:
        return 0

    project = qna_lib.find_session_dir(data.get("cwd"), session)
    path = qna_lib.pending_path(session, project, create=False)
    count = len(qna_lib.open_entries(path))

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
