# qna

A Claude Code plugin that turns everything still undecided in a conversation
into questions you can click.

```
/qna:ask
```

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

```
Scanned 11, 7 left to ask.

Already decided · 2
  V  Default TTL          -> 300s  (you said "five minutes is fine")
  V  --no-cache flag      -> yes   (you asked for it directly)

No longer applies · 1
  X  Cache filename format — backend is SQLite now, there are no filenames

Handled by default · 1     trivial, say so if you disagree
  ·  Cache-hit logging at debug level

Still to ask · 7
  1  [heavy] Should the cache key include the auth identity
  ...
```

Meanwhile, as Claude works, choices it makes on your behalf get parked in
`.qna/<session>.md` so they are still there after a context compaction — and so
that when you are finally asked, the options offered are the ones that were
actually weighed at the time, not three invented on the spot.

## Install

```
/plugin marketplace add jinhuang712/claude-code-qna
/plugin install qna@qna-marketplace
/reload-plugins
```

Then just work. Run `/qna:ask` whenever you would otherwise have typed *"so what
do I need to decide?"*

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
                    read file <--------+
                        |
        scan conversation
                        |
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
  conversation.

## Storage

```
<project>/.qna/.gitignore      a single "*" — the directory hides itself
<project>/.qna/<session>.md    parked decisions
<project>/.qna/<session>.meta  transcript path, for quote verification
<project>/.qna/<session>.active  marker, live only while /qna:ask runs
```

Files untouched for 30 days are swept at session start.

## Uninstall

```
/plugin uninstall qna@qna-marketplace
```

Nothing global is left behind — no `settings.json` edits, no `CLAUDE.md` edits,
nothing added to `PATH`. Per-project `.qna/` directories do remain; clear them
with:

```
find ~ -type d -name .qna -prune -exec rm -rf {} +
```

## Design notes

The full design, including the reasoning behind each rule and the alternatives
that were rejected, is in
[`docs/design.md`](docs/design.md) (written in Chinese).

## License

MIT
