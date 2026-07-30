# qna

A Claude Code plugin that turns everything still undecided in a conversation
into questions you can click.

```
/qna:ask
```

Run it whenever you would otherwise have typed *"so what do I need to decide?"*

## The problem

Ask Claude Code what is still outstanding and you tend to get a wall of text:
ten numbered questions in a single message. Answering means scrolling back to
re-read Q7, typing `Q1: … Q2: …` by hand, and watching the questions scroll out
of view the moment you start typing.

Here is what that actually produces, from a real session:

| What the user was forced to reply | What it says about the question |
|---|---|
| `Q9: no idea what this even is` | The question used a term the user had never internalised |
| `Q6: why have I never seen this in the actual project?` | It was built on a premise they did not accept |
| `Q1: too thin, needs more structure` | It asked "here's my proposal, look right?" — so the only answer was "no", and they still had to invent the alternative themselves |

Six of those ten questions were "I propose X, does that work?" — a yes/no
dressed up as a question.

The tool for asking properly already exists: `AskUserQuestion` renders clickable
options with a side panel, and it had been used four times earlier in that same
session. It still collapsed into prose at question ten, because the tool caps a
call at four questions and ten does not fit.

**That is the actual failure. Not "didn't know the tool existed" — "gave up when
it didn't fit".**

## What it does

`/qna:ask` reads the conversation and a small per-session log, works out what is
genuinely still open, and puts it to you as clickable questions — batched, in
dependency order, each with real alternatives and, wherever the difference is
something you can look at, a preview of where each one leads.

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
| 2 more handled by default | by default | cache-hit logging, temp-file naming |

Two tables, split on the only line that matters while reading: does this row want
something from you — and the queue leads, because making you scroll past a
reconciliation ledger to reach your own to-do list has it backwards. Settled and
moot rows always carry their evidence, because that column is the only way a
wrong "already decided" gets caught; by-default rows collapse into a count, since
they are the ones that multiply.

Meanwhile, as Claude works, choices it makes on your behalf get parked in
`.qna/<session>.md` so they are still there after a context compaction — and so
that when you are finally asked, the options offered are the ones that were
actually weighed at the time, not three invented on the spot.

## Install

```
curl -fsSL https://raw.githubusercontent.com/jinhuang712/claude-code-qna/main/reinstall.sh | bash
```

Then **open a new session** — the protocol arrives through a `SessionStart` hook,
so whatever session you were in does not have it.

**That same line is also how you update or repair it.** Run it again: it
uninstalls, drops the marketplace, deletes the cached clone, and installs `main`
fresh. Nothing else reliably does that — `claude plugin update` only compares the
`version` string in `plugin.json` and never re-pulls the cache, so an edit
without a version bump reports "already at the latest" and changes nothing.

### Working on the plugin itself

From a clone, the same script installs **the working tree**, uncommitted changes
included, and refuses to install at all if `tests/smoke.sh` fails:

```
bash reinstall.sh              # working tree if in a clone, else main
bash reinstall.sh --remote     # force main
bash reinstall.sh --local      # force working tree
```

## How it works

```
  SessionStart hook
       |
       +--> inject the recording protocol + what is currently parked
       |
       v
  ============  while Claude works  ============
       |
       |  made a call you didn't sign off on
       |  or you said "park that for now"
       +---------------------------> qna-add
       |                               |
       |                               +-> fewer than 2 alternatives  -> refused
       |                               +-> --where doesn't check out  -> refused
       |                               |
       |  something parked gets settled v
       +---------------------------> qna-resolve  (--quote required)
                                       |
                                       v
                       <project>/.qna/<session>.md
                                       |
  ==========  you run /qna:ask  ========|=================
                                       |
                    qna-list <---------+   open entries only
                        |
                    qna-scan  <-- transcript, minus 97% tool traffic
                        |           after the last scan, and only the
                        |           turns behind a context compaction
                        |           (nothing to print is the usual case:
                        |            the rest is still in Claude's context)
                        v
                     filter --> qna-add --found-by-scan
                        |          |   same refusals as above:
                        |          |   a refusal means it was
                        |          |   never a decision -> dropped
                        v          v
                    reconcile --> settled / moot --> shown, not asked
                        |
                        v
                     rank, aggregate
                        |
                        v
                    overview, scope gate
                        |
                        v
                     ask --------> AskUserQuestion
                        |               ^
                        |               |  PreToolUse validator
                        |               +--- under 3 options    -> denied
                        |               |    (multi-select: 2)
                        |               +--- panel half-filled  -> denied
                        |               +--- panel empty        -> denied
                        |               +--- payload unparsed   -> denied
                        v
                  decision list --> write the answers back
                        |            then do what they decided
                        |
                        +-> new opens from R6 --> qna-add
                        |
                     clean up   the only step that removes anything
                        |
                        +-> you decided it      --> qna-resolve  (--quote)
                        +-> nobody ever will    --> qna-drop     (why required)
                        +-> outside the scope gate  --> left alone
                        |
                     qna-prune   takes every closed entry out at once

  ============  around each turn  ============
       your prompt --> nothing ever recorded?  -> re-surface the protocol,
                       (UserPromptSubmit)         every 15 replies
                                                  never displayed to you

       end of turn --> something new parked?   -> names it, and what
                       (Stop hook)                Claude went with
                       nothing new             -> silence, including
                                                  when you settle one

       Only the Stop hook reaches your screen — Claude Code renders it
       under the reply and suppressOutput does not stop it. So that is
       the one place anything is written for you to read, and everything
       addressed to Claude goes out on the channel you never see.
```

### Enforce in code what code can enforce

The interesting part is not the prompt, it is which parts are *not* prompt.
"Only record real decisions" and "always give three formed options" are the kind
of instruction a model drifts away from, so neither is left as an instruction.

| Enforced by scripts and hooks | Left to the model |
|---|---|
| At least two alternatives per entry — including the ones the scan finds, which go through the same `qna-add` | Whether something counts as a decision |
| `--where` resolves to a real file:line **or** words actually said in the conversation | Whether the conversation has settled it |
| Archiving requires quoting the user | |
| Discarding an item nobody will rule on requires one of two reasons and a written why | |
| The pending file itself — reading, closing and removing all go through scripts, and the file tools are refused on `.qna/` | |
| Three to four options per question — two is enough for a multi-select, where two boxes answer neither/A/B/both | |
| The panel behind an option is never empty and never half-filled — a preview to look at or a description to read, the same way for every option | Which of the two a given question wants |
| A payload that failed to parse is refused rather than waved through unchecked, with its size named | |
| A recommendation is moved to the top of the list, and a preview a multi-select would never render is dropped — both in place, before the question is shown | Whether there is a recommendation to make at all |
| An over-long preview, previews that add up past what the payload survives, and a second small question minutes after the last one all come back as a note beside the result — allowed, never blocked | What to do about the note |
| Where files land — every path is injected, never worked out by the model | |
| Which stretch of conversation is unscanned — the watermark is read and written by `qna-scan`, never reasoned about | |

A refusal is phrased to name the thinking gap, not the missing field:

```
Refused: need at least 2 alternatives. If you cannot name two a competent
engineer might genuinely prefer, this is an implementation detail, not a
decision. Do not record it.
```

```
Refused: these options say nothing beyond their own label. With no preview and
a description no longer than the label, the reader is choosing from a handful
of characters. Do not invent a preview for an option its label already settles
— write the description instead.
```

**The validator runs on every question, in every session** — not just inside
`/qna:ask`. It used to be scoped to the command by a marker file, on the
reasoning that these rules suit settling a backlog and are needlessly rigid for
ordinary conversation. Then the transcripts supplied the comparison: over three
weeks, 7 questions were refused for having fewer than three options and 6 of
them were asked outside the command. `/qna:ask` runs a few times a day; ordinary
questions run dozens of times. Enforcing only in the rarest place had it
backwards.

The cost is real: a question that genuinely has two courses of action and no
third now has to find one.

What it asks about previews moved once, and the numbers are why. The first
version wanted one on every single-select option. It worked — coverage over
those three weeks went from 11% of questions before the hook was installed to
89% after — but it refused 59% of everything asked, and a refusal is a full
round trip on a tool that is already slow. It also pushed the model into
inventing artifacts: one refusal produced three `git branch` outputs differing
only in where the asterisk sat, for a question whose options were three branch
names. So the demand moved to the harm: a preview and a description are the same
panel, and what is refused now is leaving that panel empty, or filling it for
some options and not others. Replaying all 1034 questions from those three weeks
through the validator, the panel rule refuses 2.7% where the old one refused
31.6%.

### When the question is the problem

Every heavy question ends with **"I don't follow the question"** as its fourth
option. Picking it records nothing and sends the question back rewritten —
plainer words, jargon spelled out, a concrete scenario instead of the
abstraction. It is treated as a bug report against the question, not as a
non-answer, because a question you cannot parse is a failure of the asking.

A free-text box is always there too, and always has been. But using it costs
typing, and typing is what this command exists to remove: someone who cannot
follow a question should not have to write an essay saying so.

Nothing works out a path for itself. Every command is injected at session start
carrying this session's id and this project's absolute path, because the shell
Claude runs commands in has no `CLAUDE_PROJECT_DIR` and the working directory
moves — and a file written to the wrong place fails without failing: the pending
list silently reads as empty, and the scan silently re-reads the whole session.

`tests/smoke.sh` asserts all of it: 170 cases, no dependencies, temp directory,
quiet unless something fails.

### Reading the conversation without reading the transcript

A working session's transcript is enormous and almost none of it is
conversation. Measured on the session that built this feature: **2916.7 KB
total, of which 97% is tool calls, tool results, thinking and metadata.** The
actual back-and-forth was 97 KB.

So `qna-scan` does three things, all in code rather than judgement:

- **Filters** to user messages and Claude's own prose. That alone is the
  difference between a file too large to open and one that fits in a scan.
- **Windows** from where the last `/qna:ask` stopped, resuming by entry uuid with
  the timestamp as fallback. A second run in a long session reads only what is
  new; if neither anchor resolves it re-reads everything rather than guessing a
  boundary, because over-reading is merely slower and under-reading is silent.
- **Cuts at the newest context compaction** and prints only what is behind it.
  Everything after that point is still verbatim in Claude's context, so reading
  it off disk would buy a second copy of what Claude is already looking at — paid
  for on that turn and then on every request for the rest of the session.

That third one means **an empty scan is the ordinary result**, not a failure: a
session that has not compacted has nothing on disk Claude cannot already reach,
and the scan says so and hands the stretch back by count. The output caps at
30 KB, and names how many turns it dropped when it gets there.

The watermark advances as soon as the survivors are recorded, before Claude asks
you anything. Marking last read as the safer order — an interrupted run would
re-read rather than skip — but it put the watermark past the very turns your
answers were given in, and a run that never reached the end left it unset
entirely. This project managed eight `/qna:ask` invocations in one session
without ever marking; all eight re-read from the first turn, and the eighth
printed 139 KB. Recording is what makes a stretch durable, so marking follows it
directly.

## Deliberately not doing

- **Not claiming completeness.** Nothing can force a model to notice it is making
  a decision, so coverage is partial by design. The output never says "that's
  all" — when the queue empties it says nothing else surfaced in this scan.
- **Not asking twice.** The answers are written back with `qna-resolve` and then
  carried out in the same turn. It used to print the decisions and stop, which
  turned an hour of answering into a table: one real run parked seven items,
  asked about four, wrote back none, and advanced the watermark past the turns
  the answers were given in.
- **Not a substitute for asking now.** Anything destructive, irreversible, or
  where a wrong guess wastes the work still gets raised immediately.
- **Not carrying context across sessions** — but open decisions do carry. Files
  are per session, because a session is the unit of context. A question nobody
  has ruled on is not context, so a new session in the same directory is shown
  what earlier ones left open, with the command to settle each. Without that,
  seven items in one project were reachable by nothing but the 30-day sweep.
- **Not a team artifact.** `.qna/` carries its own `.gitignore` containing `*`,
  so it never reaches version control and your project's `.gitignore` is left
  alone.
- **Not an archive.** Settled items are deleted; the decisions live in the
  conversation. The file is the memory for what is *still open* — which is why
  anything the scan finds and leaves open gets written into it before the
  watermark moves past that turn.

## Storage

```
<project>/.qna/.gitignore      a single "*" — the directory hides itself
<project>/.qna/<session>.md    parked decisions
<project>/.qna/<session>.meta  transcript path, last entry announced, scan watermark
```

The directory appears only when something is actually recorded. The hooks run in
every project you open, so they check for it and write nothing if it is absent —
otherwise every project you ever started a session in would collect an empty one.

It also leaves the same way. When the 30-day sweep clears the last file, the
directory goes with it: sweeping the contents and keeping the container means
the litter outlives its reason.

Files untouched for 30 days are swept at session start.

## Uninstall

```
claude plugin uninstall qna@qna-marketplace
claude plugin marketplace remove qna-marketplace
```

The only global footprint is the pair of entries any plugin install writes to
`~/.claude/settings.json` — `enabledPlugins` and `extraKnownMarketplaces` — and
the two commands above remove them. No `CLAUDE.md` edits, nothing added to
`PATH`, no shell config touched. Per-project `.qna/` directories do remain; clear
them with:

```
find ~ -type d -name .qna -prune -exec rm -rf {} +
```

## Design notes

The full design, including the reasoning behind each rule and the alternatives
that were rejected, is in
[`specs/design.md`](specs/design.md) (written in Chinese).

## License

MIT
