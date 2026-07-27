---
name: ask
description: So what do I actually need to decide? Turn every open point into a clickable question.
disable-model-invocation: true
argument-hint: [optional: limit to one topic, e.g. "architecture"]
---

The user just typed the equivalent of:

> So what do I actually need to decide? What is still outstanding? Put it to me
> as questions.

That is the whole job. Treat it as that request, not as a file-cleanup chore.

If `$ARGUMENTS` is present, limit the scan to that topic, and say in the
overview how many out-of-topic items you left untouched.

## 0. Switch the validator on

First action, before anything else. `QNA_MARK` is a full command line
SessionStart injected into your context for this session — a **label in that
text, not a shell variable**. Nothing exports it, so `$QNA_MARK` expands to
nothing. Paste the whole line and append `--on`:

```
<the QNA_MARK line from the qna block> --on
```

That turns on the `PreToolUse` validator for the rest of this command, which is
what makes R2 and R4 below real rather than advisory. **Switch it off as the
last action, always** (same line, `--off`) — including when you stop early or
the user interrupts. It self-expires after 30 minutes, but do not rely on that.

Never assemble these paths yourself. The shell has no `CLAUDE_PROJECT_DIR` and
the working directory can move, so a hand-built path may not be the one the
hooks read — and a marker written somewhere else is indistinguishable from no
marker at all: every question would pass unchecked, silently.

If `QNA_MARK` is not in your context, SessionStart did not run — the plugin
arrived mid-session. **Open with one flat line and go straight on:**

```
没有找到历史上下文，本轮只扫对话。
```

That is the whole notice. No explanation of why, no advice about restarting, and
no mention of hooks, markers, injection or validators — those are plumbing, and
the person reading came here to be asked questions. The rules below still apply;
they are simply unenforced this run.

## 1. Scan

Two sources, merged and de-duplicated. The file is a supplement, not a
replacement: nothing forces a model to notice it is making a decision, so
recorded coverage is partial by nature.

**The conversation**, looking for five kinds of thing:

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
is your only source.

## 2. Filter

Apply the same three tests the recording side uses — the scan has no script
backing it, so this is the only place the filtering happens for conversational
material. Filtering only the low-recall path is worse than not filtering.

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

**Order by dependency first, recency second.** Whatever changes later questions
goes first; among peers, the most recent wins, because the user is reading the
last few turns right now.

## 5. Overview

A count, then **one table per bucket** — and only the buckets that have rows —
then straight into the first question, no confirmation step. What is settled and
what is still open are different kinds of thing and never share a grid; split
apart, each table carries the columns it actually needs instead of a generic
"why". Never a fenced block of aligned monospace text either: it reads as a
ledger dump and it wraps badly.

**Scanned 11 — 7 left to ask.**

**Already decided**

| Item | Where it landed | Your words |
|---|---|---|
| Default TTL | `300`s | "five minutes is fine" |
| `--no-cache` | shipped | "add the flag" |

**No longer applies**

| Item | Why |
|---|---|
| Cache filename format | backend is SQLite now, there are no filenames |

**Handled by default** — say so if you disagree

| Item | What I did |
|---|---|
| Cache-hit logging | debug level |

**To ask · 7**

| # | Weight | Question |
|---|---|---|
| 1 | heavy | Cache key: include the auth identity? |
| 2 | heavy | Write failure: degrade silently or warn? |
| 3 | light | When expiry cleanup runs |

Close with one line inviting corrections. The two reconciled tables always carry
their evidence column — the user's own words for decided, the reason for moot.
That column is the only way a wrong call gets caught, so it is never left blank.

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

**R3 — Options explain themselves.** Any term from earlier in the conversation
gets one line saying what it is and why it is now in question. The test: could
someone walking in cold pick from this screen alone?

**R4 — Every single-select option carries a preview** showing what actually
happens if it is chosen: the real artifact, the consequence, the knock-on, a
worked example. Restating the label is filler and worse than nothing. There is
no such thing as an option with nothing to show — if you cannot think of
anything, you have not worked out where that option leads.

**R5 — A heavy question's explanation fits on one screen.** Around 150 words.
Everything else goes into the option descriptions and previews. Compressing the
explanation is only legitimate because the detail moves somewhere; if it has
nowhere to go, you are deleting it. **Between batches, write nothing** — no
recap, no re-evaluation essay, no "next up". The overview is the only narration
in the whole command; everything else the user needs is inside the options.

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

Same shape as the overview: one table per bucket, only the buckets that have
rows, no monospace ledger.

**Decided**

| Item | Result | Follow-on |
|---|---|---|
| Cache backend | `SQLite` | concurrent writes — enable WAL |
| Cache key | token fingerprint | cache dir splits per token |
| Write failure | warn, then degrade | — |

**Handled by default**

| Item | What I did |
|---|---|
| Cache-hit logging | debug level |

**No longer applies**

| Item | Why |
|---|---|
| Cache filename format | backend changed to SQLite |

**Not touched this time**

| Item | Why |
|---|---|
| `#9` metrics for cache hit rate | outside the scope you picked |

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

Finally, switch the validator off — the same `QNA_MARK` line, with `--off`.
