"""Shared helpers for the qna scripts.

Storage layout, per project:

    <project>/.qna/.gitignore          contains a single "*" so the whole
                                       directory (including itself) is invisible
                                       to git without touching the project's
                                       own .gitignore
    <project>/.qna/<session>.md        pending entries, append-only until
                                       qna-prune removes the closed ones
    <project>/.qna/<session>.meta      json: transcript_path, last reported
                                       count, the scan watermark, and the
                                       highest id ever handed out here

Nothing outside these scripts touches those files. Reading goes through
qna-list, closing through qna-resolve or qna-drop, removal through qna-prune,
and a PreToolUse hook refuses the model's own Read/Edit/Write/Bash on them. The
file is a data structure with rules attached — an id sequence, a checkbox state
machine, fields other scripts parse — and a free-hand edit breaks those quietly,
which is the failure mode this layout is arranged to prevent.

One piece of state deliberately lives nowhere near a project:

    <tmp>/qna-ask/<session>.json       when this session last asked a question,
                                       and how many it carried

The validator runs on every AskUserQuestion in every project, including ones
that have never recorded a thing, and those must come out of a session with
nothing added to them — there is a test asserting exactly that. So this cannot
go in .qna/. A temp file is also the right lifetime: the question is always
"how long since the last one in this session", never "what happened last week".
"""

import json
import os
import re
import tempfile
import time

HEADER = (
    "<!-- qna-pending · written by qna-add · closed by qna-resolve / qna-drop "
    "· cleared by qna-prune · read with qna-list -->\n"
)

# "- [ ] #4 · 2026-07-27T19:02 · Title"
ENTRY_RE = re.compile(r"^- \[( |x)\] #(\d+) · (\S+) · (.*)$")
FIELD_RE = re.compile(r"^  - ([A-Za-z]+): (.*)$")

ORPHAN_AGE_SECONDS = 30 * 24 * 60 * 60


def project_dir(override=None):
    """Where .qna/ lives.

    Callers must pass the anchor explicitly. SessionStart resolves it once and
    injects it into every command it hands the model, because nothing else in
    this system is stable: CLAUDE_PROJECT_DIR does not exist in the shell the
    model runs commands in, so a path built there collapses to the working
    directory, which moves. The env var and cwd remain as fallbacks only for a
    hand-run script.
    """
    return override or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()


def find_session_dir(start, session, limit=8):
    """Read-side anchor resolution for hooks.

    The writing side is pinned by the injected --project. Hooks only get their
    own cwd, which may sit below that anchor, so walk up for the directory that
    actually holds this session's files. Filenames carry the session id, so a
    hit is proof of the right directory and a stranger's .qna/ cannot match.
    """
    if not start:
        return start
    cur = os.path.abspath(start)
    for _ in range(limit):
        d = os.path.join(cur, ".qna")
        if any(
            os.path.exists(os.path.join(d, f"{session}{ext}"))
            for ext in (".md", ".meta")
        ):
            return cur
        parent = os.path.dirname(cur)
        if parent == cur:
            break
        cur = parent
    return os.path.abspath(start)


def qna_dir_exists(project=None):
    """Whether this project has ever recorded anything.

    Hooks run in every project and must not leave a trace in the ones that
    never used the tool. Anything that only reads or updates bookkeeping checks
    this first; the directory comes into being only on a deliberate act —
    qna-add or qna-scan --mark.
    """
    return os.path.isdir(os.path.join(project_dir(project), ".qna"))


def qna_dir(project=None, create=True):
    d = os.path.join(project_dir(project), ".qna")
    if create:
        os.makedirs(d, exist_ok=True)
        # Self-ignoring directory: git never sees any of it, and the project's
        # own .gitignore stays untouched.
        gi = os.path.join(d, ".gitignore")
        if not os.path.exists(gi):
            with open(gi, "w") as f:
                f.write("*\n")
    return d


def pending_path(session, project=None, create=True):
    return os.path.join(qna_dir(project, create), f"{session}.md")


def meta_path(session, project=None, create=True):
    return os.path.join(qna_dir(project, create), f"{session}.meta")


def read_entries(path):
    """Parse the pending file into a list of dicts. Unknown lines are ignored,
    so a hand-edited file degrades rather than explodes."""
    if not os.path.exists(path):
        return []
    entries = []
    current = None
    for line in open(path, encoding="utf-8"):
        line = line.rstrip("\n")
        m = ENTRY_RE.match(line)
        if m:
            current = {
                "done": m.group(1) == "x",
                "id": int(m.group(2)),
                "ts": m.group(3),
                "title": m.group(4),
                "fields": {},
                "alts": [],
            }
            entries.append(current)
            continue
        if current is None:
            continue
        f = FIELD_RE.match(line)
        if f:
            key, val = f.group(1), f.group(2)
            if key == "Alternatives":
                current["alts"] = [a.strip() for a in val.split(" / ") if a.strip()]
            current["fields"][key] = val
    return entries


def open_entries(path):
    return [e for e in read_entries(path) if not e["done"]]


def other_session_entries(session, project=None):
    """Open entries parked in this project by other sessions, oldest file first.

    Entries are stored per session because a session is the unit of context, not
    because a decision stops mattering when the session ends. Those two came
    apart in practice: seven items were parked in a project, the session ended
    with all seven open, and the next session in the same directory could not see
    one of them — no hook read them, no command listed them, and the orphan sweep
    was the only thing that would ever touch them again.

    So the read side is per project and the write side stays per session. Ids are
    only unique within a file, which is why callers surface these separately
    rather than merging them into one numbered list: settling one means running
    qna-resolve with that file's own session id.
    """
    d = os.path.join(project_dir(project), ".qna")
    if not os.path.isdir(d):
        return []
    out = []
    for name in sorted(os.listdir(d)):
        if not name.endswith(".md") or name[:-3] == session:
            continue
        entries = open_entries(os.path.join(d, name))
        if entries:
            out.append((name[:-3], entries))
    return out


def read_blocks(path):
    """Split the pending file into (preamble, blocks), text preserved.

    read_entries answers "what is parked here". This answers "which lines is it
    made of", which is what the reading side needs to print one entry verbatim
    and qna-prune needs to remove one without reflowing its neighbours.

    Each block is {"done", "id", "title", "lines"}; trailing blank lines are
    stripped from every block and from the preamble, and write_blocks puts the
    single separating blank line back. Round-tripping a file no script has
    touched leaves it byte-identical.
    """
    if not os.path.exists(path):
        return [], []
    lines = open(path, encoding="utf-8").read().split("\n")
    preamble, blocks = [], []
    for line in lines:
        m = ENTRY_RE.match(line)
        if m:
            blocks.append(
                {
                    "done": m.group(1) == "x",
                    "id": int(m.group(2)),
                    "title": m.group(4),
                    "lines": [line],
                }
            )
        elif blocks:
            blocks[-1]["lines"].append(line)
        else:
            preamble.append(line)

    def trim(seq):
        while seq and not seq[-1].strip():
            seq.pop()

    trim(preamble)
    for b in blocks:
        trim(b["lines"])
    return preamble, blocks


def write_blocks(path, preamble, blocks):
    out = list(preamble) or [HEADER.rstrip("\n")]
    for b in blocks:
        out.append("")
        out.extend(b["lines"])
    with open(path, "w", encoding="utf-8") as f:
        f.write("\n".join(out) + "\n")


def close_entry(path, entry_id, fields):
    """Tick one entry's checkbox and attach fields to it.

    Both ways an entry can close come through here — qna-resolve with the user's
    words, qna-drop with a reason — so the checkbox and the field layout have one
    implementation rather than two that drift.
    """
    preamble, blocks = read_blocks(path)
    for b in blocks:
        if b["id"] != entry_id:
            continue
        b["lines"][0] = b["lines"][0].replace("- [ ] ", "- [x] ", 1)
        b["lines"].extend(f"  - {k}: {v}" for k, v in fields)
        write_blocks(path, preamble, blocks)
        return True
    return False


def next_id(path, session=None, project=None):
    """One past the highest id ever handed out in this file.

    The file alone stopped being enough when qna-prune arrived: pruning the
    highest-numbered entry would otherwise hand its number to the next one, and
    the old number is still sitting in the conversation, in an earlier Stop line,
    and in whatever qna-resolve command the model was about to run. So the
    watermark outlives the entries, in .meta. It goes away with the file itself —
    a session with nothing parked is genuinely starting over at #1.
    """
    entries = read_entries(path)
    floor = 0
    if session:
        try:
            floor = int(load_meta(session, project).get("max_id") or 0)
        except (TypeError, ValueError):
            floor = 0
    return max(max((e["id"] for e in entries), default=0), floor) + 1


def render_entry(entry_id, title, chose, alts, why, where, source, verified):
    ts = time.strftime("%Y-%m-%dT%H:%M")
    lines = [
        f"- [ ] #{entry_id} · {ts} · {title}",
        f"  - Chose: {chose}",
        f"  - Alternatives: {' / '.join(alts)}",
        f"  - Why: {why}",
        f"  - Where: {where}",
        f"  - Source: {source}",
        f"  - Verified: {verified}",
    ]
    return "\n".join(lines) + "\n"


def append_entry(path, text):
    exists = os.path.exists(path)
    with open(path, "a", encoding="utf-8") as f:
        if not exists:
            f.write(HEADER)
        f.write("\n" + text)


def load_meta(session, project=None):
    p = meta_path(session, project, create=False)
    if not os.path.exists(p):
        return {}
    try:
        return json.load(open(p, encoding="utf-8"))
    except Exception:
        return {}


def save_meta(session, data, project=None):
    with open(meta_path(session, project), "w", encoding="utf-8") as f:
        json.dump(data, f)


def ask_state_path(session):
    """Where this session's last-question timestamp lives — outside any project.

    See the note at the top of this file: the validator fires in projects that
    have never used the tool, and leaving a file behind in one of those is the
    bug the no-trace test guards.
    """
    safe = re.sub(r"[^A-Za-z0-9._-]", "_", session or "unknown")
    return os.path.join(tempfile.gettempdir(), "qna-ask", f"{safe}.json")


def load_ask_state(session):
    try:
        with open(ask_state_path(session), encoding="utf-8") as f:
            return json.load(f)
    except Exception:
        # Missing, unreadable or cleaned up by the OS all mean the same thing —
        # there is no previous question to compare against. Degrading to "first
        # question of the session" is correct and has no side effect.
        return {}


def save_ask_state(session, data):
    p = ask_state_path(session)
    try:
        os.makedirs(os.path.dirname(p), exist_ok=True)
        with open(p, "w", encoding="utf-8") as f:
            json.dump(data, f)
    except Exception:
        # Bookkeeping for a hint. Never let it break the question.
        pass


def iter_turns(path):
    """Yield the conversation out of a Claude Code transcript, oldest first.

    Everything that knows the transcript's internal JSONL shape lives here, so a
    format change has exactly one place to be fixed. Each turn is a dict:

        {"uuid": str, "ts": str, "role": "user"|"assistant",
         "text": str, "compacted": bool}

    Only text survives. Tool calls, tool results and thinking blocks are 97% of
    the file by volume in a working session and none of it is conversation; a
    scan that carried them would be unaffordable long before it was useful.
    Sidechain entries are a subagent talking to itself, not this conversation.
    """
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                d = json.loads(line)
            except Exception:
                continue
            if d.get("type") not in ("user", "assistant"):
                continue
            if d.get("isMeta") or d.get("isSidechain"):
                continue
            content = (d.get("message") or {}).get("content")
            if isinstance(content, str):
                text = content
            elif isinstance(content, list):
                text = "\n".join(
                    b.get("text", "")
                    for b in content
                    if isinstance(b, dict) and b.get("type") == "text"
                )
            else:
                continue
            if not text.strip():
                continue
            yield {
                "uuid": d.get("uuid") or "",
                "ts": d.get("timestamp") or "",
                "role": d["type"],
                "text": text,
                "compacted": bool(d.get("isCompactSummary")),
            }


def sweep_orphans(project=None):
    if not qna_dir_exists(project):
        return  # Nothing to sweep, and asking for the path would create it.
    d = qna_dir(project, create=False)
    cutoff = time.time() - ORPHAN_AGE_SECONDS
    for name in os.listdir(d):
        if name == ".gitignore":
            continue
        p = os.path.join(d, name)
        try:
            if os.path.isfile(p) and os.path.getmtime(p) < cutoff:
                os.remove(p)
        except OSError:
            pass

    # Nothing left but the file that hides the directory: take the directory
    # too. Sweeping the contents and leaving the container behind means every
    # project that ever held a single entry keeps an empty .qna/ forever — the
    # litter outlives the reason for it. It comes back on the next qna-add.
    try:
        if os.listdir(d) == [".gitignore"]:
            os.remove(os.path.join(d, ".gitignore"))
            os.rmdir(d)
    except OSError:
        pass


def hook_input():
    """Hook payload on stdin. Never raise: a broken hook must not break the
    session."""
    import sys

    try:
        return json.loads(sys.stdin.read() or "{}")
    except Exception:
        return {}


def emit(event, context):
    """Emit additionalContext for a hook that supports it.

    Whether the text also reaches the user's screen depends entirely on which
    event it is emitted for, and the difference is visible in the transcript:

        SessionStart, UserPromptSubmit   an attachment, type
                                         "hook_additional_context" — model only
        Stop                             a "stop_hook_summary" entry, which
                                         Claude Code renders as "Stop hook
                                         feedback" under the reply

    suppressOutput does not change that. It was set on the Stop path for exactly
    this purpose and the line still appeared on screen, quoted back verbatim by
    the user, so the flag is gone rather than left in place looking like it does
    something. The rule that replaces it is a placement rule: anything written
    for the model goes out on UserPromptSubmit, and the Stop path carries only
    text worth a person's attention.
    """
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": event,
                    "additionalContext": context,
                }
            }
        )
    )
