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
dependency order, each with real alternatives and a preview of where each one
leads.

**Scanned 11 — 7 left to ask.**

**Not asking · 4**

| Item | Verdict | Evidence / why |
|---|---|---|
| Default TTL → `300`s | decided | "five minutes is fine" |
| `--no-cache` shipped | decided | "add the flag" |
| Cache filename format | moot | backend is SQLite now, there are no filenames |
| Cache-hit logging → debug | by default | trivial, say so if you disagree |

**Yours to settle · 7**

| # | Weight | Question |
|---|---|---|
| 1 | heavy | Cache key: include the auth identity? |
| 2 | heavy | Write failure: degrade silently or warn? |
| 3 | light | When expiry cleanup runs |

Two tables, split on the only line that matters while reading: does this row want
something from you. Every row of the first carries its evidence, because that
column is the only way a wrong "already decided" gets caught.

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
              qna-mark --on            |   validator armed, 30 min
                        |              |
                    read file <--------+
                        |
                    qna-scan  <-- transcript, minus 97% tool traffic
                        |           starting after the last scan
                        v
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
                        |               +--- no preview         -> denied
                        v
                  decision list --> stop
                        |
                        +-> still-open scan finds --> qna-add
                        |
              qna-scan --mark                next scan starts here
              qna-mark --off                 validator stood down

  ============  at the end of a turn  ============
       Stop hook --> count changed?  ->  "qna: 3 parked"
                     unchanged       ->  silence
```

### Enforce in code what code can enforce

The interesting part is not the prompt, it is which parts are *not* prompt.
"Only record real decisions" and "always give three formed options" are the kind
of instruction a model drifts away from, so neither is left as an instruction.

| Enforced by scripts and hooks | Left to the model |
|---|---|
| At least two alternatives per entry | Whether something counts as a decision |
| `--where` resolves to a real file:line **or** words actually said in the conversation | Whether the conversation has settled it |
| Archiving requires quoting the user | |
| Three to four options per question | |
| Every single-select option has a preview | |
| Where files land — every path is injected, never worked out by the model | |
| Which stretch of conversation is unscanned — the watermark is read and written by `qna-scan`, never reasoned about | |

A refusal is phrased to name the thinking gap, not the missing field:

```
Refused: need at least 2 alternatives. If you cannot name two a competent
engineer might genuinely prefer, this is an implementation detail, not a
decision. Do not record it.
```

```
Refused: every single-select option needs a preview showing what actually
happens if it is chosen. If you cannot think of what to show, you have not
worked out where that option leads.
```

The question validator is scoped to `/qna:ask` by a self-expiring marker file,
so ordinary questions elsewhere in your session are untouched.

Nothing works out a path for itself. Every command is injected at session start
carrying this session's id and this project's absolute path, because the shell
Claude runs commands in has no `CLAUDE_PROJECT_DIR` and the working directory
moves — and a marker written to the wrong place is indistinguishable from no
marker at all, which reads as "not inside `/qna:ask`" and lets every question
through unchecked.

`tests/smoke.sh` asserts all of it: 77 cases, no dependencies, temp directory,
quiet unless something fails.

### Reading the conversation without reading the transcript

A working session's transcript is enormous and almost none of it is
conversation. Measured on the session that built this feature: **2916.7 KB
total, of which 97% is tool calls, tool results, thinking and metadata.** The
actual back-and-forth was 97 KB.

So `qna-scan` does two things, both in code rather than judgement:

- **Filters** to user messages and Claude's own prose. That alone is the
  difference between a file too large to open and one that fits in a scan.
- **Windows** from where the last `/qna:ask` stopped, resuming by entry uuid with
  the timestamp as fallback. A second run in a long session reads only what is
  new; if neither anchor resolves it re-reads everything rather than guessing a
  boundary, because over-reading is merely slower and under-reading is silent.

The watermark advances as the last action of `/qna:ask`, not the first. An
interrupted run therefore re-reads that stretch instead of skipping it. And when
the window crosses a context compaction, the scan says so — detail from before
that point survives only as a summary.

## Deliberately not doing

- **Not claiming completeness.** Nothing can force a model to notice it is making
  a decision, so coverage is partial by design. The output never says "that's
  all" — when the queue empties it says nothing else surfaced in this scan.
- **Not acting on the answers.** It prints the decisions and stops.
- **Not a substitute for asking now.** Anything destructive, irreversible, or
  where a wrong guess wastes the work still gets raised immediately.
- **Not crossing sessions.** State is per session; `/clear` starts fresh.
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
<project>/.qna/<session>.meta  transcript path, last count reported, scan watermark
<project>/.qna/<session>.active  qna-mark's marker, live only while /qna:ask runs
```

The directory appears only when something is actually recorded. The hooks run in
every project you open, so they check for it and write nothing if it is absent —
otherwise every project you ever started a session in would collect an empty one.

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
