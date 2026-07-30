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

`QNA_ADD`, `QNA_SCAN`, `QNA_LIST`, `QNA_RESOLVE`, `QNA_DROP` and `QNA_PRUNE` are
full command lines SessionStart injected into your context for this session —
**labels in that text, not shell variables**. Nothing exports them, so
`$QNA_SCAN` expands to nothing. Paste the whole line and append flags where a
step says to.

Never assemble these paths yourself. The shell has no `CLAUDE_PROJECT_DIR` and
the working directory can move, so a hand-built path may not be the one the
hooks read, and writing to the wrong place fails silently — which is worse than
failing loudly.

The `.qna/` files are reached only through those commands. `Read`, `Edit`,
`Write` and any Bash command naming a path inside them are refused by a
`PreToolUse` hook, and that refusal prints the lines to use instead. Nothing in
this command needs the raw file: `QNA_LIST` prints the queue, `QNA_RESOLVE` and
`QNA_DROP` close an entry, `QNA_PRUNE` clears the closed ones out at the end.

The parts of R2 and R4 a script can check — the option floor and ceiling, and
the panel behind an option being neither empty nor half-filled — are enforced by
a `PreToolUse` hook on every `AskUserQuestion` in every session, so they hold
here whether or not the injection arrived. Nothing needs switching on.

That hook also has a quiet lane. A question can come back **allowed** with a
note attached to the result — a recommendation it moved to the top for you, a
preview it thinks is too long, two small questions it noticed went out minutes
apart. None of that blocks anything and none of it needs answering in the
moment; it is for the next question, not this one. Do not re-send a question
because a note came back with it.

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
read what it prints. It prints exactly one thing: the turns **behind a context
compaction**, after the watermark. Nothing else, because nothing else is worth
paying for — every turn on this side of the newest compaction is already sitting
verbatim in your context, and printing a second copy costs a full re-read of the
conversation to tell you what you can already see.

**So an empty scan is the ordinary outcome, not a failure.** A session that has
not compacted has nothing on disk you cannot reach; it will say so and name how
many turns it left to you. Read that as "your context is complete for this
stretch" and move straight to the next source. Do not re-run it, do not go
looking for a flag that prints more, and do not treat the empty result as a
reason to skip the context scan below — that scan is now the only thing covering
the turns it declined to print.

When it does print, everything in it reaches you elsewhere only as a condensed
summary, so what it shows is the record: prefer it over your recollection of the
same stretch, and say in the overview that the session was compacted.

Two boundaries it keeps and you do not: the watermark, and the compaction point.
Never reconstruct either yourself and never pass it a timestamp. If it reports
the transcript unreadable, or names turns it dropped to stay under its size cap,
scan your own context for that stretch instead.

Turns before the watermark are absent by design. Anything still open from back
there is in the pending file, because the file is the memory; settled and
dismissed items are deliberately not kept.

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

**The queue** — run `QNA_LIST` (the whole line, no flags). It prints the open
entries in full and nothing else; closed ones are filtered out, so what comes
back is exactly what is still waiting. If it reports nothing parked, the
conversation is your only source. This is where anything still open from before
the watermark lives, so run it even when the scan window comes back empty.

**Earlier sessions in this same project.** If SessionStart listed a section
headed "Still open here from an earlier session", those items are in scope and it
printed a `qna-list` line for each — run them. They were parked in this
directory about this code and nobody has ruled on them; the only thing that
makes them different is that the session which wrote them ended. Seven of them
sat unreachable in one project because nothing read them, which is why they are
surfaced at all.

Two things they need that this session's own items do not: their ids belong to
their own file, so keep them labelled by session in the tables, and settling one
means running `QNA_RESOLVE` with **that** session's id, exactly as SessionStart
spelled it out. Never re-park one under this session — that leaves the same
question open in two files, and closing one does not close the other.

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

**Now mark the scan — here, before you ask anything.** Append `--mark` to
`QNA_SCAN` and run it once.

Marking is safe at this point and nowhere earlier, because the survivors are in
the file as of the step above. The window has done its whole job: what it found
is recorded durably, so re-reading it would turn up the same entries and pay
again for them. The file is the memory, not the transcript.

Marking here also keeps the turns you and the user are **about** to spend asking
and answering in front of the watermark, where the next scan can still reach
them. Marking at the end of the run put them behind it — which is exactly how
one session lost four answers it had already been given.

The cost of not marking is not abstract. This project ran `--mark` zero times
across eight `/qna:ask` invocations in one session, so all eight re-read from the
first turn; the eighth alone printed 139 KB. An unmarked run does not fail
loudly, it just makes the next one expensive.

## 3. Reconcile

Entries are written the moment a decision is made and nothing revisits them, so
some have been settled by the conversation since. Asking about something already
answered is worse than not asking: it proves the tool was not listening.

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

Ask it as a real question (three or more options, single-select), giving counts
and batch counts. Which items each scope covers is exactly the kind of thing the
panel is for:

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

**Labels take their values along one axis.** The reader scans them to rule
options *out*, not to understand them, so `on boot / daily / manually` can be
scanned and `on boot / faster / manually` cannot — the second mixes a trigger
with a benefit and there is nothing to run the eye down. That is what "the
options must be mutually exclusive" actually asks for. Real labels run about
eleven characters; past twenty they stop being scannable at all.

**If you have a leaning, mark it and put it first.** A marked recommendation
turns the question from "work this out" into "do you agree", which is a far
lighter thing to ask of someone; the other options are what keep it a choice
rather than a rubber stamp, and the reason for the recommendation goes in that
option's own description, not in the label.

The rule is two-way. **No leaning, no mark.** Holding an answer in your head
while presenting three options as equals costs the user a round of thinking they
did not need to do, and it is the worst of the three states.

**Never mark a recommendation on a question whose answer is the user's to
have** — what to call something, what to do first, which of two acceptable
styles. You have no standing to recommend there, and marking one anyway is
deciding it for them while appearing to ask.

**Two questions need a last option, and they are not the same failure.**

- **"I don't follow the question"** — for a heavy question. What failed is R3:
  the words. Picking it is a bug report, so the reply is a rewrite in plainer
  words, jargon spelled out, a concrete scenario in place of the abstraction.
  Never the same question again with the same framing.
- **"None of these — let me say what I want"** — for any question where you are
  not certain the options are exhaustive. What failed is R2: the options. The
  reply is not a rewording, it is a different set of options built from what
  they say next.

Either way, three substantive options plus that one is exactly what the cap of
four allows, and the last option is the only one exempt from being a course of
action, because what it answers is not the subject. Say in its panel what
happens if picked: nothing is recorded, and the question comes back.

**The second one is the under-used half.** Across three weeks the user answered
by typing instead of clicking 123 times, and a last option of either kind
appeared in only 63 questions — barely half the demand. Typing is exactly what
this command exists to remove: someone the options do not fit should not have to
write an essay to say so.

A free-text box is always there and always has been — in the side-by-side
preview layout it renders as `Notes:` rather than a fourth row. It is the
fallback for when both of the above were unnecessary, not a reason to skip
them. A light question that is genuinely one of three known things needs
neither.

**R3 — Options explain themselves.** Any term from earlier in the conversation
gets one line saying what it is and why it is now in question. The test: could
someone walking in cold pick from this screen alone?

**R4 — The panel behind an option is never empty.** `preview` and `description`
are the same slot: the panel that renders for whichever option currently has
focus, one of them to look at and one to read. Which of the two you fill is a
judgement. Leaving both empty is not — it puts the reader in front of eleven
characters and asks them to decide.

**A preview is a differ.** It draws in one place and swaps as the focus moves,
and the eye is very good at catching what changed in a fixed position. So its
worth is not the artifact, it is the information in *what changes* between the
options:

```
分支名 · restart / v2 / blank-slate
  three `git branch` outputs, 633 characters, and the only thing that
  moved between them was the asterisk. The label had already said it all.
  This one was invented to satisfy a rule.

HTML 产物 · 收进 html/ / 删掉 / 继续平铺
  the same directory three ways, with real sizes and one irreversible
  warning. Reading it settles the question.
```

Four things follow from that, and none of them is taste:

- **Every preview in a question has the same shape.** Different shapes cannot be
  compared, and the panel degrades into three unrelated descriptions taking up
  more room than descriptions would.
- **What differs sits in the same place** in each one — same opening line,
  divergence below it.
- **What does not differ stays short.** It is the anchor the eye aligns on. It
  carries no information, and every line of it is read three times.
- **No long sentences.** Anything that has to be read in order belongs in the
  description.

Around 300 characters each. When one question's previews add up past a thousand,
the payload starts failing to parse, and this is nearly always the cause.

**When the label already settles it, write the description instead.** This rule
used to say there was no such thing as an option with nothing to show; that
sentence is what produced the three `git branch` outputs above. An option whose
difference is a name, a flag or a path needs a sentence explaining what picking
it commits you to — not an artifact built to fill a panel.

**Fill the panel the same way for every option in a question.** Some with
previews and some without makes it blink in and out as focus moves, which
destroys the one thing the panel is for. All of them or none of them.

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

**The explanation and the previews spend the same budget.** A reader gives a
question about one screen. The explanation buys context that is shared and
always visible; the panel buys detail that is per-option and appears only on
focus. They compete for the same attention, they do not add up. So when the
premise needs a long explanation *and* the options need large previews, the
question is telling you it is two questions: settle the direction first, then
the specifics. Writing both of them long is the failure, not the fix.

**A batch of light questions with a shared premise gets one paragraph above the
batch**, not the same sentence copied into four descriptions. Anything that
would repeat in every option belongs above the question, where it is read once —
a premise pasted into three descriptions is read three times and understood
none.

**R6 — Re-evaluate after every heavy answer.** Strike what is now moot and say
why, rewrite what changed shape, add what the answer surfaced. Update the
overview.

**R7 — Every question goes through `AskUserQuestion`.** Never ask in prose. A
sentence ending in a question mark is not a question the user can click.

Heavy questions: explanation first, then one question alone — two at most, and
only when they share the same background. Light questions: batched, four at a
time.

Default to single-select, which is what makes the panel available. Use
`multiSelect` only when the answer genuinely can be several things at once, and
when you do, move what would have been in the preview into the descriptions: the
panel does not render for a multi-select at all, so a preview written there is
thrown away, and three of them have been written already.

**If the difference between the options is something to look at, the question is
not a multi-select.** Giving up the panel to save a question is how a comparison
gets flattened into a checklist. The two needs rarely collide — a question whose
options are rival plans is single-select by nature, and a question that is
genuinely "tick the ones that apply" has options that differ by name, which is
exactly the case that never wanted a panel.

## 8. Write the answers back

**Before anything else, run `QNA_RESOLVE` for every question the user just
answered**, one call each, with their own words in `--quote`.

This step has been skipped in full, and it is the most expensive failure this
command has: a real run parked seven items, asked about four, got four answers,
resolved none, and then advanced the watermark past the turns those answers were
given in. The answers still exist in the transcript, but no scan will ever reach
them again and no file records them. The user spent an hour deciding and nothing
kept the decisions.

So the order is fixed and nothing may come between the links: **resolve, then
report, then act, then mark.** An answer you are holding in your head is not
recorded, and this is the only turn in which you know it.

## 9. Report, then do the work

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

**Then carry out what the answers decided, in the same turn.** A decision that
changes nothing is not settled, it is filed — and filing is what the user came
here to stop doing.

Three rules, all of them from the same observed run:

- **Never end on a request for permission.** "你点头，我就开始写" is how that
  session finished, and the nod never came. The user answered four questions
  precisely so that no further approval would be needed; asking for one anyway
  spends their answers and gives nothing back. If a follow-on is genuinely
  yours to call, call it and park it with `QNA_ADD` — that is the whole premise
  of this plugin.
- **Do the work, not a plan of the work.** The follow-on column in the table
  above is the to-do list. Work it.
- **When an answer decides nothing that needs doing, say so in one line.**
  Some answers only confirm the status quo. That is a real outcome, and stating
  it is not the same as stopping.

Two things do stop you, and only these two: work the user put outside the scope
gate, and work that is destructive or irreversible in the way `N3` describes.
Both get named in the closing line rather than silently skipped.

Then clean up the file — with the scripts, never by editing it. `Read`, `Edit`,
`Write` and Bash on `.qna/` are refused by a hook, and rightly: an entry removed
by hand takes the record of why it closed with it.

Four buckets, and the command each one goes through:

| Bucket | Command |
|---|---|
| Settled by the user | `QNA_RESOLVE <id> --result … --quote …` — already done in step 7 |
| Moot, premise gone | `QNA_DROP <id> --reason moot --why …` |
| Demoted as trivia | `QNA_DROP <id> --reason trivia --why …` |
| Skipped by the scope gate, or left deliberately open | nothing — the user has not ruled on it |

Trivia earns its own reason because leaving it means it resurfaces every single
time. `QNA_DROP` refuses `--reason settled`, which belongs to `QNA_RESOLVE` and
wants the user's words, and it refuses out-of-scope items outright: those stay.

Then run `QNA_PRUNE` once. It takes every closed entry out of the file in one
pass, needs no arguments, and removes the file itself when nothing open is left.
Resolving and dropping only tick the box; this is what clears them.

Scan finds from step 2 are already in the file. **What is not yet in it is
anything R6 turned up while you were asking** — an answer that opened a new
question, a follow-on nobody has ruled on. Those arrived after step 2, so put
each one still open through `QNA_ADD --found-by-scan` now.

Record them now rather than trusting the next run to find them again. The
watermark was set back in step 2, so these turns are still in front of it and a
later scan can reach them — but only if the session survives to have one, and
only as raw conversation nobody has filtered. An entry in the file is the durable
form; a turn in the transcript is a hope.

**Nothing to mark here.** The watermark moved in step 2 and does not move again.
If you are reaching for `--mark` at this point, you are running the old order,
which swallowed exactly these turns.
