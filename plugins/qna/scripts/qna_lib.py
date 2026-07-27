"""Shared helpers for the qna scripts.

Storage layout, per project:

    <project>/.qna/.gitignore          contains a single "*" so the whole
                                       directory (including itself) is invisible
                                       to git without touching the project's
                                       own .gitignore
    <project>/.qna/<session>.md        pending entries, append-only
    <project>/.qna/<session>.meta      json: transcript_path, last reported
                                       count, and the scan watermark
    <project>/.qna/<session>.active    marker written while /qna:ask runs
"""

import json
import os
import re
import time

HEADER = (
    "<!-- qna-pending · written by qna-add / qna-resolve "
    "· cleared by /qna:ask -->\n"
)

# "- [ ] #4 · 2026-07-27T19:02 · Title"
ENTRY_RE = re.compile(r"^- \[( |x)\] #(\d+) · (\S+) · (.*)$")
FIELD_RE = re.compile(r"^  - ([A-Za-z]+): (.*)$")

ACTIVE_TTL_SECONDS = 30 * 60
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
            for ext in (".md", ".meta", ".active")
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
    qna-add, qna-mark --on, or qna-scan --mark.
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


def active_path(session, project=None, create=True):
    return os.path.join(qna_dir(project, create), f"{session}.active")


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


def next_id(path):
    entries = read_entries(path)
    return max((e["id"] for e in entries), default=0) + 1


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


def marker_is_live(session, project=None):
    """The /qna:ask marker self-expires so an interrupted run cannot leave the
    PreToolUse validator switched on forever."""
    p = active_path(session, project, create=False)
    if not os.path.exists(p):
        return False
    if time.time() - os.path.getmtime(p) > ACTIVE_TTL_SECONDS:
        try:
            os.remove(p)
        except OSError:
            pass
        return False
    return True


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
    """Emit additionalContext for a hook that supports it."""
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
