---
name: ask
description: So what do I actually need to decide?
disable-model-invocation: true
argument-hint: [optional: limit to one topic, e.g. "architecture"]
---

The user just typed the equivalent of:

> So what do I actually need to decide? What is still outstanding? Put it to me
> as questions.

That is the whole job. Treat it as that request, not as a file-cleanup chore.

If `$ARGUMENTS` is present, limit the scan to that topic, and say in the
overview how many out-of-topic items you left untouched.

## 0. What you have to work with

`QNA_ADD`, `QNA_SCAN` and `QNA_FILE` are full command lines SessionStart
injected into your context for this session — **labels in that text, not shell
variables**. Nothing exports them, so `$QNA_SCAN` expands to nothing. Paste the
whole line and append flags where a step says to.

Never assemble these paths yourself. The shell has no `CLAUDE_PROJECT_DIR` and
the working directory can move, so a hand-built path may not be the one the
hooks read, and writing to the wrong place fails silently — which is worse than
failing loudly.

R2 and R4 are enforced by a `PreToolUse` hook on every `AskUserQuestion` in
every session, so they hold here whether or not the injection arrived. Nothing
needs switching on.

If those names are not in your context, SessionStart did not run — the plugin
arrived mid-session. **Open with one flat line and go straight on:**

```
没有找到历史上下文，本轮只扫对话。
```

That is the whole notice. No explanation of why, no advice about restarting, and
no mention of hooks, injection or transcripts — those are plumbing, and the
person reading came here to be asked questions. Skip the steps that need those
commands and scan your own context instead.

## 1. Scan

Three sources, merged and de-duplicated. The file is a supplement, not a
replacement: nothing forces a model to notice it is making a decision, so
recorded coverage is partial by nature.

**The conversation on disk** — run `QNA_SCAN` (the whole line, no flags) and
read what it prints. It filters the transcript down to user messages and your
own prose, and starts from where the last `/qna:ask` stopped, so a second run in
a long session is cheap. Two things it tells you that your context cannot:

- **Turns that are no longer in your context.** If it reports crossing a context
  compaction, everything before that point reaches you only as a condensed
  summary — treat detail from there as approximate and say so in the overview.
- **What was already scanned.** Turns before the watermark are absent by design.
  Anything still open from back there is in the pending file, because the file is
  the memory; settled and dismissed items are deliberately not kept.

If it reports the transcript is unreadable, or names turns it dropped to stay
under its size cap, scan your own context for that stretch instead. Never
reconstruct the boundary yourself and never pass it a timestamp — it holds the
watermark, you do not.

**Your own context**, for the turn in flight and anything the script's window
missed, looking for five kinds of thing:

1. Questions you asked that the user never actually answered
2. Anything either of you called "later" or "for now"
3. Choices you made on the user's behalf without checking
4. Statements of theirs open to two readings that lead to different work
5. **Questions, doubts and "but"s you raised in prose in the last few turns and
   never turned into something decidable**

The fifth is usually the richest source when this command is run, and none of
it is in the file — the recording scripts capture decisions you *made*, not
questions you *raised*. It looks like "I lean towards A, but B has a case",
"worth thinking about", "one thing to watch out for", or a closing list of
things to note.

**The pending file** — `Read` the absolute path SessionStart injected as
`QNA_FILE`. If it does not exist yet, nothing has been parked; the conversation
is your only source. This is where anything still open from before the watermark
lives, so read it even when the window comes back empty.

## 2. Filter, and record what survives

Apply the same three tests the recording side uses, and then **put every
survivor through `QNA_ADD` with `--found-by-scan` appended** — one call each, for
anything not already in the file.

That is not bookkeeping, it is the filter. Judging alternatives, cost and
surprise in your head is exactly the check that drifts. Without this, the
conversational half of the scan is the one path with no script behind it, and
filtering only the half that already has a hard gate is worse than not filtering.

**The two refusals mean different things.** Refused over `--alt` is the answer:
the item was an implementation detail, so drop it and do not work around it.
Refused over `--where` is not — the citation failed, the item did not. Point at
the `file:line` the decision shows up in, or quote the user verbatim, and run it
again. Treating the second as the first throws away real decisions silently.

`--found-by-scan` marks the provenance and is not optional. An entry recorded as
the choice was made carries alternatives that were genuinely weighed; one
reconstructed here carries alternatives you thought up just now. Both clear the
same bar. The file has to say which is which.

For a scan find, `--chose` is what happens if nobody decides — the current
leaning, or the status quo it drifts into.

1. **Alternatives** — can you name two options a competent engineer might
   genuinely prefer?
2. **Cost** — would changing it later mean more than editing a line or two?
3. **Surprise** — would the user frown at learning you decided it alone, rather
   than shrug and say "obviously"?

Never a question: naming, log wording, file placement, comments, fixture
values, formatting, anything with one reasonable implementation, and **anything
re-chosen per invocation rather than settled once** — which mode, which env,
which flag this run. If the answer is remade every time the thing runs, there is
nothing to settle.

Three further gates specific to scanning, which works directly on the user's
own words:

- **Anything the user already stated is not a question.** This is the highest
  risk in the whole command: handing someone their own instruction back as a
  question.
- **Anything you asked and they answered is not a question.** That belongs to
  reconciliation, below.
- **A pure heads-up is not a question.** "Watch out for X" with no fork in it is
  a note, not a decision. The test is whether the prose contains a real fork.
  Fork, ask. No fork, list it under "handled by default".

## 3. Reconcile

The file is append-only, so entries may have been settled by the conversation
since they were written. Asking about something already answered is worse than
not asking: it proves the tool was not listening.

| Verdict | Test | Action |
|---|---|---|
| Settled | The user took a position, and you can quote it | Do not ask; list under "already decided" |
| Moot | Its premise is gone | Do not ask; list under "no longer applies", with why |
| Still open | Neither | Goes in the queue |

**Never do this silently.** Every reconciled item is listed in the overview with
the evidence — the user's actual words for settled items, the reason for moot
ones. That listing is the only backstop against a wrong call, so it is not
optional.

When in doubt, ask. A wrong "settled" is invisible and costs the user a
decision; a redundant question is visible and costs them a second.

If the same decision was recorded twice, take the latest and point out in the
question that the leaning changed.

## 4. Rank and aggregate

**Heavy** if any of: the options need background to understand; it determines
later questions; getting it wrong is expensive to undo (architecture, data
model, public interface); you have a recommendation that needs reasoning.
Everything else is **light**.

**Aggregate before queueing.** Neither filter catches everything, so collapse
what is left:

- Merge same-topic trivia into one question rather than one each
- Give genuinely inconsequential items a non-question exit: list them under
  "handled by default" in the overview, one line each
- Items recorded with `Source: user-deferred` are **never** demoted this way.
  The user asked for those explicitly.
- `Source: agent` outranks `Source: scan` when the two describe the same thing.
  One was written while the choice was being made; the other was reconstructed
  minutes ago. Keep the earlier entry and its alternatives.

**Order by dependency first, recency second.** Whatever changes later questions
goes first; among peers, the most recent wins, because the user is reading the
last few turns right now.

## 5. Overview

A count, then **two tables — the queue first** — then straight into the first
question, no confirmation step. One combined table is what this replaces: with
the queue mixed in, nothing tells the reader at a glance which rows are still
waiting on them. Never a fenced block of aligned monospace text either: it reads
as a ledger dump and it wraps badly.

The queue leads because it is the only part that wants something from the person
reading. Making them scroll past a reconciliation ledger to reach their own
to-do list has the priority backwards.

**Scanned 11 — 7 left to ask.**

**Yours to settle · 7**

| # | Weight | Question |
|---|---|---|
| 1 | heavy | Cache key: include the auth identity? |
| 2 | heavy | Write failure: degrade silently or warn? |
| 3 | light | When expiry cleanup runs |

**Not asking · 4**

| Item | Verdict | Evidence / why |
|---|---|---|
| Default TTL → `300`s | decided | "five minutes is fine" |
| `--no-cache` shipped | decided | "add the flag" |
| Cache filename format | moot | backend is SQLite now, there are no filenames |
| 2 more handled by default | by default | cache-hit logging, temp-file naming — say so if you disagree |

Close with one line inviting corrections.

**The second table has to stay short, or it stops being read.** Two rules keep it
bounded, and neither drops anything that matters:

- **It carries only rows where a wrong call costs the user something** — settled
  items, whose quote they may dispute, and moot ones, whose premise they may not
  agree has gone. Those keep a row each with their evidence, always: that column
  is the only way a wrong call gets caught. Items handled by default are trivial
  by definition and are the rows that multiply, so more than two of them collapse
  into one row with a count and the titles inline. The closing invitation to
  object already covers them.
- **Never re-list what an earlier run already reconciled.** Those are gone from
  the file on purpose. This table is what changed since the last scan, not a
  running total — a table that only ever grows is one nobody reads by the third
  run.

If the session has been compacted, say so above the tables.

## 6. Scope gate

**Only when the queue spans both sources** — some items from this turn, some
carried over. If everything is from this turn there is no scope to choose, so
skip it and start asking.

Ask it as a real question (three or more options, previews, single-select),
giving counts and batch counts:

```
7 to settle — 4 from this turn, 3 carried over.

  Just this turn (4, one round)
  All of it (7, two rounds)
  Heavy ones only (3, one round)
  The three that matter most
```

Whatever falls outside the chosen scope is listed in the wrap-up under "not
touched this time". It does not vanish.

## 7. Ask

**R1 — More than four questions means more calls, never prose.** The tool caps
a call at four. Send the next batch as soon as the first is answered. Never,
for any reason, fall back to a numbered list in a message because a batch would
not fit. That failure is the entire reason this command exists.

**R2 — Three to four options, no yes/no.** Every option is a formed, workable
course of action, not a direction. Give four when four genuinely exist; never
pad to three, and never trim to three for tidiness. If you can only see one
option and its negation, you have not thought it through.

**Every heavy question ends with "I don't follow the question".** Three
substantive options plus that one — exactly what the cap of four allows. It is
the single option exempt from being a course of action, because what it answers
is not the subject.

Its preview says what happens if picked: nothing is recorded, and the question
comes back rewritten. **Picking it is not a non-answer, it is a bug report** —
R3 failed. So the reply is a rewrite: plainer words, jargon spelled out, a
concrete scenario in place of the abstraction. Never the same question again
with the same framing.

A free-text box is always available and always has been — in the side-by-side
preview layout it renders as `Notes:` rather than a fourth row. But using it
costs typing, and typing is exactly what this command exists to remove. Someone
who cannot follow the question should not have to write an essay explaining
that. Light questions skip this option: they need no background, so failing to
follow one means it was badly worded, and the box covers that case fine.

**R3 — Options explain themselves.** Any term from earlier in the conversation
gets one line saying what it is and why it is now in question. The test: could
someone walking in cold pick from this screen alone?

**R4 — Every single-select option carries a preview** showing what actually
happens if it is chosen: the real artifact, the consequence, the knock-on, a
worked example. Restating the label is filler and worse than nothing. There is
no such thing as an option with nothing to show — if you cannot think of
anything, you have not worked out where that option leads.

**R5 — A heavy question is explained before it is asked.** Prose, in the same
turn, immediately above the tool call: what is in question, why it is in question
now, and what turns on it. Around 150 words, one screen. Everything else goes
into the option descriptions and previews — compressing the explanation is only
legitimate because the detail moves somewhere; if it has nowhere to go, you are
deleting it.

**What is banned between batches is narration about the process** — recap of
what was just answered, a re-evaluation essay, "next up", "good, moving on". A
heavy question's own explanation is none of those. It is part of the question.
Dropping it does not make the command terser, it makes the question
unanswerable: the user is left reconstructing the stakes from three previews,
each written for a different option, none of them stating the shared premise.

A question that arrives with no framing is the failure this rule exists to
prevent, and it is worse than a wordy one.

**R6 — Re-evaluate after every heavy answer.** Strike what is now moot and say
why, rewrite what changed shape, add what the answer surfaced. Update the
overview.

**R7 — Every question goes through `AskUserQuestion`.** Never ask in prose. A
sentence ending in a question mark is not a question the user can click.

Heavy questions: explanation first, then one question alone — two at most, and
only when they share the same background. Light questions: batched, four at a
time.

Default to single-select, which is what makes previews available. Use
`multiSelect` only when the answer genuinely can be several things at once, and
when you do, move what would have been in the preview into the descriptions.

## 8. Wrap up

Print the decision list and **stop**. No "shall I start?", no edits.

Same two-table shape as the overview, no monospace ledger — what is now closed,
and what is not.

**Settled · 5**

| Item | Result | Verdict / follow-on |
|---|---|---|
| Cache backend | `SQLite` | follow-on: concurrent writes, enable WAL |
| Cache key | token fingerprint | follow-on: cache dir splits per token |
| Write failure | warn, then degrade | — |
| Cache-hit logging | debug level | by default |
| Cache filename format | dropped | moot: backend changed to SQLite |

**Still open · 1**

| Item | Why it is open |
|---|---|
| `#9` metrics for cache hit rate | outside the scope you picked, kept in the file |

Then one closing line for what is still open.

Two wording rules, both aimed at the same risk — that the user reads this list
as everything outstanding, when recall is partial by design:

- When nothing is left open, **never write "none"**. Write that nothing else
  surfaced in this scan.
- Never write "all", "everything", "that's all", or "nothing else".

Then clean up the file:

- Settled and moot items: remove
- Demoted as trivia: remove — they failed the importance bar, and leaving them
  means they resurface every single time
- Skipped because of the scope gate: **keep** — the user never ruled on them
- Left deliberately open (the user chose Other and said "let me think"): keep

Scan finds from step 2 are already in the file. **What is not yet in it is
anything R6 turned up while you were asking** — an answer that opened a new
question, a follow-on nobody has ruled on. Those arrived after step 2, so put
each one still open through `QNA_ADD --found-by-scan` now.

This is the last chance. The watermark moves next, and the turns you and the
user just spent asking and answering fall behind it — an open item from those
turns that is not in the file is not merely missed, it is unreachable.

Finally, `QNA_SCAN` with `--mark` appended: it records this scan's endpoint so
the next run starts here. Last of everything, because an interrupted run must
re-read this stretch rather than skip it.
