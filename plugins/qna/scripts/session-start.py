#!/usr/bin/env python3
"""SessionStart hook: inject the recording protocol and the current backlog.

Two jobs beyond the injection itself:

  * stash transcript_path in .qna/<session>.meta, because qna-transcript has no
    other reliable way to find it (the path under ~/.claude/projects/ is an
    internal convention and cwd can move mid-session)
  * sweep orphaned files older than 30 days

Runs again after auto-compaction (matcher includes "compact"), which is what
makes the protocol survive a compressed context.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qna_lib  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))

PROTOCOL = """## Open-decision log (qna)

Three protocols for this session, plus current state at the bottom.
The command prefix below already encodes this session — use it verbatim.

  QNA_ADD     = {add}
  QNA_RESOLVE = {resolve}

### 1. You decided something the user has not signed off on

Do not stop to ask. Keep working, then run:

  $QNA_ADD --title <one line> --chose <what you did> \\
           --alt <alternative> --alt <another> \\
           --why <the tradeoff that made you pick it> \\
           --where <file:line, or a phrase actually said in this conversation>

Record it only if all three hold:
  1. You can name two alternatives a competent engineer might genuinely prefer.
  2. Changing it later costs more than editing a line or two — it would mean
     touching a data structure, an interface, several call sites, or migrating
     data already written.
  3. The user would frown on learning you decided it alone, rather than shrug
     and say "obviously".

Never record:
  - Anything the user already stated. If they said it, it is not open. Handing
    their own instruction back to them as a question is the worst failure this
    tool can produce.
  - Naming, log wording, which file code lives in, comments, test fixture
    values, formatting, or anything with one reasonable implementation.

Several decisions in one turn: run it once per decision. Do not pack unrelated
choices into one entry.

If it refuses, do not work around it. The refusal is the answer: that item was
not a decision.

### 2. The user explicitly defers something

When the user says "leave that for now", "note it and move on", or otherwise
parks a question rather than answering it, run the same command with
--deferred-by-user, setting --chose to whatever you will do in the meantime.

This is the one case where something the user said still counts as open. The
test is whether they settled it or shelved it.

### 3. A parked item gets settled

The moment the user states a position on a parked item, or its premise
disappears, run:

  $QNA_RESOLVE <id> --result <what was decided> --quote <the user's own words>

Do it in the turn you notice it. Settling in the moment is far more accurate
than reconstructing later, and it is what keeps /qna:ask from asking the user
something they already answered.

### What this does not cover

This protocol is for choices you can defer. It does not apply to anything
destructive, irreversible, or where guessing wrong makes the work useless.
Those you still raise immediately, exactly as you otherwise would. Parking is
not a substitute for asking when asking is the right call.

### Field language

Field names stay English. Titles and values follow the conversation.
"""


def main():
    data = qna_lib.hook_input()
    session = data.get("session_id")
    if not session:
        return 0

    project = data.get("cwd")
    transcript = data.get("transcript_path")

    meta = qna_lib.load_meta(session, project)
    if transcript:
        meta["transcript_path"] = transcript
    qna_lib.save_meta(session, meta, project)

    try:
        qna_lib.sweep_orphans(project)
    except Exception:
        pass

    prefix = "{} --session {}".format(os.path.join(HERE, "qna-add"), session)
    resolve = "{} --session {}".format(os.path.join(HERE, "qna-resolve"), session)
    text = PROTOCOL.format(add=prefix, resolve=resolve)

    open_items = qna_lib.open_entries(
        qna_lib.pending_path(session, project, create=False)
    )
    if open_items:
        listing = "\n".join(f"  #{e['id']}  {e['title']}" for e in open_items)
        text += (
            f"\n### Currently parked ({len(open_items)})\n\n"
            f"{listing}\n\nRun /qna:ask to settle them.\n"
        )

    qna_lib.emit("SessionStart", text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
