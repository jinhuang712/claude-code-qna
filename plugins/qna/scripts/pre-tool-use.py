#!/usr/bin/env python3
"""PreToolUse hook: enforce the asking rules mechanically.

The recording side has qna-add refusing bad entries. Without this, the asking
side would have nothing but prose rules — you could not invent an alternative
and get away with it, but you could ship a two-option yes/no question and
nobody would stop you. This closes that gap.

It validates every AskUserQuestion, everywhere.

That is a reversal. The rules used to apply only while /qna:ask was running,
scoped by a marker file, on the reasoning that they are right for settling a
backlog and needlessly rigid for ordinary conversation. Then a real session
supplied the comparison: 49 questions asked outside the command, of which the 3
single-selects had no preview between them — nothing was enforced where the
questions actually get answered. /qna:ask runs a few times a day; ordinary
questions run dozens of times. Applying the strictest rules only in the rarest
place had it backwards.

The cost is real and was accepted knowingly: a question that genuinely has two
courses of action and no third now has to find one.
"""

import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import qna_lib  # noqa: E402

MIN_OPTIONS = 3
# A multi-select is not measured the same way. The floor of 3 exists to stop a
# yes/no wearing a costume, and two check-boxes are not a yes/no: they answer
# neither / A / B / both. Holding multi-select to 3 also breaks G2.6 outright —
# "which of these fields do you want" frequently has exactly two candidates, and
# refusing it forces the question back into the pair of yes/no questions that
# multi-select exists to collapse.
MIN_OPTIONS_MULTI = 2
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
        multi = bool(q.get("multiSelect"))

        if multi and n < MIN_OPTIONS_MULTI:
            return (
                f'Refused ("{label}"): {n} option is not something to choose '
                f"between. A multi-select needs at least {MIN_OPTIONS_MULTI} "
                f"items on the list."
            )
        if not multi and n < MIN_OPTIONS:
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

        if multi:
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

    tool_input = data.get("tool_input") or {}

    # A payload that failed to parse arrives with the raw text under
    # __unparsedToolInput and no questions at all, so every rule below silently
    # passes and the call goes on to fail for reasons that name none of this.
    # Observed once in a real session: the next attempt was a two-option
    # question, which suggests the model read the failure as "ask something
    # smaller" rather than "resend that". Refusing puts the cause in writing.
    if "__unparsedToolInput" in tool_input:
        return deny(
            "Refused: the question payload did not parse, so none of the asking "
            "rules could be checked. This is almost always size — the previews "
            "are the usual culprit. Shorten them and send the same questions "
            "again; do not simplify the questions to get around it."
        )

    reason = check(tool_input.get("questions") or [])
    if reason:
        return deny(reason)
    return 0


if __name__ == "__main__":
    sys.exit(main())
