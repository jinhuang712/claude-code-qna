#!/usr/bin/env python3
"""Stop hook: tell the user what was just decided for them.

This is the one hook whose output reaches a person. Claude Code records a Stop
hook's additionalContext as a "stop_hook_summary" and renders it under the reply
as "Stop hook feedback"; SessionStart and UserPromptSubmit land as attachments
and are never displayed. suppressOutput does not change that — it was set here
for a whole version and the line still appeared on screen. So the split is by
placement, not by flag: everything addressed to the model went to
prompt-nudge.py, and what is left here is written for the reader.

Three things follow from that.

**It fires on a new entry, not on a count.** The old version compared the number
of open items against the last number reported, which meant resolving one
printed a line about a different item that had been sitting there for an hour —
news about nothing. What is worth interrupting for is the moment a choice gets
made on the user's behalf, so the trigger is an id above the highest already
reported. Settling something prints nothing: the user just did it.

**It says what was chosen, not just what is open.** The title alone is a
question with no answer in sight — "要不要用 disable-model-invocation" tells the
reader they have something to think about and nothing to think with. Carrying
--chose alongside it means the common case needs no follow-up at all: they read
what was picked, shrug, and it is settled by silence. /qna:ask is for when they
would rather it had gone the other way.

**Nothing here asks the model for anything.** An earlier version ended in
"Surface this as a single short line at the end of your next reply" — the model
obeyed, the line was printed twice, and the instruction outlived the version that
sent it because it sits in that session's context forever. The standing rule
against repeating this line now lives in the SessionStart protocol, on the
channel the user cannot see.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qna_lib  # noqa: E402

# Terminal output under an already-wrapped reply. Long enough to identify the
# entry, short enough not to become a paragraph.
MAX_TITLE = 70
MAX_CHOSE = 70


def clip(text, limit):
    text = " ".join(text.split())
    return text if len(text) <= limit else text[: limit - 1] + "…"


def first_run_baseline(meta, entries):
    """Highest id to treat as already announced on a meta written before this.

    Three states, and they are not the same:

      reported_max_id present   this version has run here; use it
      only reported_count       an older version reported these already, so
                                start from the top and announce nothing old
      neither                   nothing has ever been reported here, including
                                the first entry, which is the one most worth
                                saying out loud
    """
    if "reported_max_id" in meta:
        return meta["reported_max_id"]
    if "reported_count" in meta:
        return max((e["id"] for e in entries), default=0)
    return 0


def main():
    data = qna_lib.hook_input()
    session = data.get("session_id")
    if not session:
        return 0

    project = qna_lib.find_session_dir(data.get("cwd"), session)

    # Only projects that have recorded something have anything to report, and
    # asking for the path would create the directory in every project a session
    # was ever opened in.
    if not qna_lib.qna_dir_exists(project):
        return 0

    path = qna_lib.pending_path(session, project, create=False)
    if not os.path.exists(path):
        return 0

    entries = qna_lib.read_entries(path)
    if not entries:
        return 0

    meta = qna_lib.load_meta(session, project)
    baseline = first_run_baseline(meta, entries)
    top = max(e["id"] for e in entries)
    if top <= baseline:
        return 0

    # Advance past everything in the file, including anything added and settled
    # inside the same turn — that one never needed announcing and must not be
    # announced late.
    meta["reported_max_id"] = top
    meta.pop("reported_count", None)
    try:
        qna_lib.save_meta(session, meta, project)
    except OSError:
        pass  # Worst case the same line repeats once. Not worth failing over.

    fresh = [e for e in entries if e["id"] > baseline and not e["done"]]
    if not fresh:
        return 0

    lines = []
    for e in fresh:
        lines.append(f"qna parked #{e['id']} — {clip(e['title'], MAX_TITLE)}")
        chose = e["fields"].get("Chose", "").strip()
        if chose:
            lines.append(f"    going with: {clip(chose, MAX_CHOSE)}")
    still_open = len([e for e in entries if not e["done"]])
    lines.append(f"    /qna:ask to settle · {still_open} open")

    qna_lib.emit("Stop", "\n".join(lines))
    return 0


if __name__ == "__main__":
    sys.exit(main())
