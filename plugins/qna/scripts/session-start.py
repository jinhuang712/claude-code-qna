#!/usr/bin/env python3
"""SessionStart hook: inject the recording protocol and the current backlog.

Two jobs beyond the injection itself:

  * stash transcript_path in .qna/<session>.meta, because qna-transcript and
    qna-scan have no other reliable way to find it (the path under
    ~/.claude/projects/ is an internal convention and cwd can move mid-session)
  * sweep orphaned files older than 30 days

Runs again after auto-compaction (matcher includes "compact"), which is what
makes the protocol survive a compressed context.
"""

import os
import shlex
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qna_lib  # noqa: E402

HERE = os.path.dirname(os.path.abspath(__file__))

# Titles listed per earlier session before the rest collapse into a count. The
# full file is one Read away and its path is printed alongside.
MAX_CARRIED = 8

PROTOCOL = """## Open-decision log (qna)

Three protocols for this session, plus current state at the bottom.

Every command below already carries this session and this project's absolute
path — paste them as they stand and never rebuild a path by hand. The shell has
no CLAUDE_PROJECT_DIR and the working directory can move, so a path assembled at
call time may not be the one the hooks read.

  QNA_ADD     = {add}
  QNA_RESOLVE = {resolve}
  QNA_SCAN    = {scan}
  QNA_FILE    = {pending}

**Those four names are labels in this text, not shell variables.** Nothing
exports them: a hook cannot set the environment of the shell you run commands
in, and that shell keeps no state between calls. `$QNA_ADD --title x` therefore
expands to `--title x` and fails with "command not found" — which is not a
refusal and must not be worked around. Paste the full line instead. Every
example below already has it filled in.

QNA_ADD and QNA_RESOLVE are the two you use while working. QNA_SCAN prints the
conversation not yet scanned and QNA_FILE is a path to Read; both belong to
/qna:ask alone — ignore them otherwise.

### 1. You decided something the user has not signed off on

Do not stop to ask. Keep working, then run:

  {add} \\
      --title <one line> --chose <what you did> \\
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

If it refuses over `--alt`, do not work around it. That refusal is the answer:
the item was an implementation detail, not a decision.

A refusal over `--where` means something else — the citation did not check out,
not that the item was unworthy. Fix the citation and run it again. `--where`
takes the `file:line` you actually changed, or words the user said **verbatim**;
a paraphrase from memory will not resolve, and for a decision about code the
file is the easier of the two.

### 2. The user explicitly defers something

When the user says "leave that for now", "note it and move on", or otherwise
parks a question rather than answering it, run the same command with
--deferred-by-user, setting --chose to whatever you will do in the meantime.

This is the one case where something the user said still counts as open. The
test is whether they settled it or shelved it.

### 3. A parked item gets settled

The moment the user states a position on a parked item, or its premise
disappears, run:

  {resolve} <id> \\
      --result <what was decided> --quote <the user's own words>

Do it in the turn you notice it. Settling in the moment is far more accurate
than reconstructing later, and it is what keeps /qna:ask from asking the user
something they already answered.

### The line the user already saw

Parking something prints one line to their screen naming it and what you went
with. They have read it. Never repeat it, summarise it, or mention that it
appeared — doing so prints the same thing twice.

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

    # The anchor every injected command carries. On resume and after compaction
    # this finds the directory the earlier files went to, so a session whose cwd
    # has moved keeps writing to one place instead of forking a second .qna/.
    project = qna_lib.find_session_dir(data.get("cwd"), session)
    transcript = data.get("transcript_path")

    # Sweep before writing anything. The other order means the file just written
    # is always fresh, so a directory whose every entry has expired never reaches
    # the empty state that lets it be removed — refilled a moment before being
    # inspected, every single session.
    try:
        qna_lib.sweep_orphans(project)
    except Exception:
        pass

    # Only projects that have actually recorded something get a .qna/. This hook
    # runs everywhere, and creating the directory here littered one into every
    # project a session was ever opened in. The transcript path reaches qna-add
    # through the injected command line instead, so nothing needs to be on disk
    # before the first entry.
    if transcript and qna_lib.qna_dir_exists(project):
        meta = qna_lib.load_meta(session, project)
        meta["transcript_path"] = transcript
        qna_lib.save_meta(session, meta, project)

    def cmd_for(name, sid, transcript_too=False):
        # Quoted: a plugin cache path or project path containing a space would
        # otherwise inject a command that splits into the wrong arguments.
        line = "{} --session {} --project {}".format(
            shlex.quote(os.path.join(HERE, name)),
            shlex.quote(sid),
            shlex.quote(project),
        )
        if transcript_too and transcript:
            line += " --transcript {}".format(shlex.quote(transcript))
        return line

    def cmd(name, transcript_too=False):
        return cmd_for(name, session, transcript_too)

    text = PROTOCOL.format(
        add=cmd("qna-add", transcript_too=True),
        resolve=cmd("qna-resolve"),
        scan=cmd("qna-scan", transcript_too=True),
        pending=qna_lib.pending_path(session, project, create=False),
    )

    open_items = qna_lib.open_entries(
        qna_lib.pending_path(session, project, create=False)
    )
    if open_items:
        listing = "\n".join(f"  #{e['id']}  {e['title']}" for e in open_items)
        text += (
            f"\n### Currently parked ({len(open_items)})\n\n"
            f"{listing}\n\nRun /qna:ask to settle them.\n"
        )

    # Earlier sessions in this same directory. Measured cost of leaving these
    # out: a project ended a session with seven items open, and the next session
    # in it could not see a single one of them.
    for sid, entries in qna_lib.other_session_entries(session, project):
        shown = entries[:MAX_CARRIED]
        listing = "\n".join(f"  #{e['id']}  {e['title']}" for e in shown)
        if len(entries) > len(shown):
            listing += f"\n  ... and {len(entries) - len(shown)} more"
        text += (
            f"\n### Still open here from an earlier session ({len(entries)})\n\n"
            f"{listing}\n\n"
            f"These belong to session {sid}, so their numbers are that file's, "
            f"not this one's. Read them in full at:\n"
            f"  {qna_lib.pending_path(sid, project, create=False)}\n\n"
            f"Settle one with that session's own line — same command, its id:\n"
            f"  {cmd_for('qna-resolve', sid)} <id> "
            f"--result <what was decided> --quote <the user's own words>\n\n"
            f"/qna:ask covers them too. Do not re-park them under this session: "
            f"that leaves the same question open in two files.\n"
        )

    qna_lib.emit("SessionStart", text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
