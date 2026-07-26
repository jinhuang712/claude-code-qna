#!/usr/bin/env python3
"""PreToolUse hook: enforce the asking rules mechanically.

The recording side has qna-add refusing bad entries. Without this, the asking
side would have nothing but prose rules — you could not invent an alternative
and get away with it, but you could ship a two-option yes/no question and
nobody would stop you. This closes that gap.

Scope is deliberately narrow: it only validates while /qna:ask is running,
detected via the .active marker. Every other question in the session passes
straight through, because these rules are right for settling a backlog and
needlessly rigid for ordinary conversation.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qna_lib  # noqa: E402

MIN_OPTIONS = 3
MAX_OPTIONS = 4


def deny(reason):
    print(
        json.dumps(
            {
                "hookSpecificOutput": {
                    "hookEventName": "PreToolUse",
                    "permissionDecision": "deny",
                    "permissionDecisionReason": reason,
                }
            }
        )
    )
    return 0


def check(questions):
    for i, q in enumerate(questions, 1):
        label = q.get("header") or q.get("question", "")[:40] or f"question {i}"
        options = q.get("options") or []
        n = len(options)

        if n < MIN_OPTIONS:
            return (
                f'Refused ("{label}"): {n} options is a yes/no question in '
                f"disguise. Every question needs at least {MIN_OPTIONS} formed, "
                f"genuinely different courses of action. If you can only think "
                f"of one plus its negation, you have not thought it through — "
                f"produce a conservative, an aggressive, and a middle option."
            )
        if n > MAX_OPTIONS:
            return (
                f'Refused ("{label}"): {n} options exceeds the tool cap of '
                f"{MAX_OPTIONS}."
            )

        if q.get("multiSelect"):
            # preview does not render for multiSelect, so detail has to live in
            # the descriptions instead. Nothing to enforce here.
            continue

        missing = [
            o.get("label", "?") for o in options if not (o.get("preview") or "").strip()
        ]
        if missing:
            return (
                f'Refused ("{label}"): these options have no preview: '
                f"{', '.join(missing)}. Every single-select option needs one, "
                f"showing what actually happens if it is chosen. If you cannot "
                f"think of what to show, you have not worked out where that "
                f"option leads. Restating the option label does not count."
            )
    return None


def main():
    data = qna_lib.hook_input()
    if data.get("tool_name") != "AskUserQuestion":
        return 0

    session = data.get("session_id")
    if not session or not qna_lib.marker_is_live(session, data.get("cwd")):
        return 0

    questions = (data.get("tool_input") or {}).get("questions") or []
    reason = check(questions)
    if reason:
        return deny(reason)
    return 0


if __name__ == "__main__":
    sys.exit(main())
