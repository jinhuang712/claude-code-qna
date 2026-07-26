"""Shared helpers for the qna scripts.

Storage layout, per project:

    <project>/.qna/.gitignore          contains a single "*" so the whole
                                       directory (including itself) is invisible
                                       to git without touching the project's
                                       own .gitignore
    <project>/.qna/<session>.md        pending entries, append-only
    <project>/.qna/<session>.meta      json, holds transcript_path
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
    """Where .qna/ lives. CLAUDE_PROJECT_DIR is stable for a whole session;
    cwd is not, so it is only the fallback."""
    return override or os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd()


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
    d = qna_dir(project)
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
