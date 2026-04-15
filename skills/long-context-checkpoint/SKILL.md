---
name: long-context-checkpoint
description: Use during subagent-driven-development to persist plan execution state to disk, and to hand off to a fresh session when the controller's context budget approaches 50%. Subagents are fresh per task, so the only state that needs to survive a session swap lives in the controller — this skill externalizes it.
---

# Long-Context Checkpoint

## Why This Exists

`superpowers:subagent-driven-development` runs fresh subagents per task, but
the **controller** (main session) accumulates:
- Reviewer B detection result
- Provider availability map (from `scripts/detect-model-providers.sh`)
- TodoWrite state
- Per-task results, triage decisions, open questions
- Worktree path

When the controller's context window fills up, all of this can be lost on
session swap or `/compact`. This skill persists it to a checkpoint file so
that:
1. A new session can resume the plan without re-deriving state.
2. Decisions made by the controller (autonomous triage, provider fallbacks)
   are auditable after the fact.

**Subagents themselves are stateless** — they don't need to be "re-associated"
with the new session. As long as the new controller has the checkpoint, the
worktree, and the plan, it dispatches fresh subagents exactly like before.
There is no lost link.

## Checkpoint File

**Location:** `docs/superpowers/checkpoints/<plan-basename>-checkpoint.json`
(relative to the repo root of the worktree).

**Schema:**

```jsonc
{
  "schema_version": 1,
  "plan_path": "docs/superpowers/plans/2026-04-13-feature-x.md",
  "worktree": "/Users/bmax/.worktrees/feature-x",
  "base_branch": "main",
  "reviewer_b_detected": "codex",         // or "codex-skill" | "gemini-cli" | "opus-agent"
  "provider_availability": {              // verbatim JSON from scripts/detect-model-providers.sh
    "anthropic":  { "type": "agent_tool",  "available": true },
    "glm-cli":    { "type": "cli_wrapper", "available": false, "reason": "binary glm not on PATH" },
    "codex":      { "type": "cli_wrapper", "available": true,  "binary": "/opt/homebrew/bin/codex" }
  },
  "tasks": [
    {
      "n": 1,
      "name": "Hook installation script",
      "tier": "mechanical",
      "status": "done",                   // pending | in_progress | done | blocked
      "stage": null,                      // spec | quality | external | null
      "provider_used": "anthropic/haiku",
      "commit": "abc123",
      "triage_decisions": []              // see Task 9 / decisions_log
    },
    {
      "n": 2,
      "name": "Recovery modes",
      "tier": "integration",
      "status": "in_progress",
      "stage": "external",
      "provider_used": "anthropic/sonnet",
      "commit": null,
      "triage_decisions": []
    }
  ],
  "todos": [],                            // snapshot of TodoWrite state
  "decisions_log": [                      // append-only audit trail
    {
      "ts": "2026-04-13T14:22:10Z",
      "task": 1,
      "stage": "external_review_triage",
      "reviewer": "sonnet",
      "issue": "Minor: extract progress utility",
      "decision": "rejected",
      "rationale": "YAGNI — only used once in this module"
    },
    {
      "ts": "2026-04-13T14:30:05Z",
      "task": 2,
      "stage": "provider_fallback",
      "event": "glm-cli unavailable (binary not on PATH), fell back to anthropic/sonnet"
    }
  ],
  "open_questions": [                     // surfaces for user review; does not block
    { "task": 4, "question": "Codex flagged possible race in cache; function is internal-only — worth hardening?" }
  ],
  "last_context_estimate_pct": 42,
  "next_task_relatedness": "medium",        // "high" | "medium" | "low"
  "handoff_threshold_pct": 50,              // 30 if low, 50 if medium, 70 if high
  "relatedness_rationale": "Task 3 is a new module unrelated to Task 2's cache work",
  "last_updated": "2026-04-13T14:30:05Z"
}
```

## When to Write the Checkpoint

Write (overwrite atomically) at these moments:

1. **Before writing the very first checkpoint of a plan**: use the `Write`
   tool to create both of these files once (idempotent — skip if they
   already exist):
   - `docs/superpowers/checkpoints/.gitignore` with contents:
     ```
     # superpowers: runtime state, not source
     *
     !.gitignore
     !README.md
     ```
   - `docs/superpowers/checkpoints/README.md` with one paragraph explaining
     this directory holds runtime execution state and is not checked in.

   This is the controller's responsibility — the `Write` tool call happens
   inline, not via a subagent or shell script. It is NOT in any hook or
   external tool.
2. **Right after `scripts/detect-model-providers.sh` runs** — seed the
   checkpoint with availability map, plan path, worktree, empty task list,
   and `execution_mode` (from the Plan Start Initialization answer, or
   from env `SUPERPOWERS_AUTONOMOUS_LOOP=1` → `"autonomous"`).
3. **After every task's final status transitions to `done` or `blocked`** — mandatory.
4. **After every auto-triage decision** — append to `decisions_log`, rewrite file.
5. **After every provider fallback event** — append to `decisions_log`.
6. **Any time `last_context_estimate_pct` crosses 40%** — early-warning persist.

**Atomic write pattern** (prevents partial files if interrupted):
use the `Write` tool on a temp path, then `Bash` to `mv` it over the real
checkpoint path. Any JSON-emitting tool (`python3 -c`, `jq`, a Node
one-liner) works for producing the content; the controller typically
produces the JSON inline and writes it directly. The only hard requirement
is that the file on disk never be a half-written JSON.

## Context Estimation (Conservative Self-Report)

Claude Code does not expose a token counter API. Use this conservative
formula. It is intentionally biased HIGH so handoff fires earlier rather
than too late — a slightly-early handoff costs nothing, a late one loses
state.

```
chars_budget  = 4_000_000           # Opus 1M tokens ≈ 4M chars (4 chars/token)
chars_used    = len(plan_text)
              + sum(len(review_output) for each review in this session)
              + sum(len(triage_log)    for each triage in this session)
              + len(implementer_reports)          # accumulated
              + session_overhead = 50_000         # instructions, tool defs, hooks
pct           = chars_used / (chars_budget * 0.8) * 100
```

Round UP. If in doubt, over-report. Store the result in
`last_context_estimate_pct` on every checkpoint write.

**Recompute** after:
- Every external review returns (biggest contributor)
- Every triage completes
- Every task completes

## Handoff Threshold (relatedness-aware)

Hard-coded "handoff at 50%" is wrong. The real cost of handoff is losing the
contextual state the controller has accumulated in this session (review
findings, half-formed judgments about the codebase, patterns it learned from
earlier tasks). If the NEXT task needs that state, paying a little more
context to finish in the current session is cheaper than re-reading it in a
fresh one. If the next task is independent, handing off earlier is free
money — a fresh session is cheaper than dragging stale context forward.

So the controller evaluates BOTH `estimated_pct` AND `next_task_relatedness`
at each checkpoint, and picks the threshold from this table:

| Next task relatedness to current session | Handoff at pct ≥ |
|---|---|
| **High** (same module, extends current task's code, needs architectural discussion from this session, reviews already built up) | **70%** |
| **Medium** (default; shares some context but could be re-derived) | **50%** |
| **Low** (independent task, different module, clean boundary, fresh reader could start from the commits alone) | **30%** |

### How to score relatedness (one pass per checkpoint)

Read the NEXT pending task's card. Classify as:

**High** — any of:
- Modifies a file just modified by a completed task in this session
- Depends on a design decision made during review/triage in this session (not written down in the plan)
- References "see previous task" / "continuing from" / "building on" in its description
- Part of a multi-task refactor with shared invariants discussed mid-session

**Low** — any of:
- Touches a disjoint module/package from every completed task in this session
- Plan explicitly tags the task `independent` or it's in `superpowers:dispatching-parallel-agents` territory
- Next task is "write docs" / "add CI config" / "update CHANGELOG" — surface work that doesn't need prior state
- The accumulated `decisions_log` has zero entries referencing the next task's area

**Medium** — everything else. This is the default; don't bend toward High
just to avoid handoff.

### What to do at each level

- **pct ≥ 40** (regardless of relatedness): silently bump checkpoint write frequency to every event.
- **pct ≥ threshold(relatedness)**: emit Resume Prompt and stop. Do NOT ask the user "should I hand off?" — the threshold encodes the decision. The user can ignore the prompt and keep going manually if they want; emitting the prompt just makes the boundary visible.
- **Approaching threshold (within 10 pp)**: print a one-line warning with the computed relatedness and threshold, e.g.:
  ```
  [context] pct=62% relatedness=high threshold=70% — continuing
  ```
  This makes the controller's reasoning visible without interrupting flow.

Record the relatedness decision in the checkpoint:

```json
{
  "last_context_estimate_pct": 62,
  "next_task_relatedness": "high",
  "handoff_threshold_pct": 70,
  "relatedness_rationale": "Task 4 extends the cache module modified in Task 3 and depends on the locking invariant agreed during Task 3 triage"
}
```

The rationale is one sentence; future-you reviewing this log should be able
to tell whether the call was right.

## Handoff vs. `/compact`: use both, not one

`/compact` (Claude Code builtin) and the `ecc:strategic-compact` skill
operate at a different layer than handoff. They are **complementary**, not
alternatives:

| Layer | Tool | What it does | Loss profile |
|---|---|---|---|
| **Tactical** (inside a task) | `/compact` | LLM-summarizes conversation history, keeps TodoWrite / CLAUDE.md / memory | **Lossy** — summary is LLM-chosen; silent degradation possible |
| **Strategic** (plan-level boundary) | handoff (this skill) | Writes `checkpoint.json`, terminates session, new session rebuilds state | **Lossless** — structured data, no LLM compression |

### Decision matrix

```
pct < 40%                               → do nothing
pct 40-50%  AND  relatedness = high    → /compact, keep running in this session
pct reaches handoff_threshold_pct       → handoff (emit Resume Prompt, stop)
relatedness = low at a task boundary    → handoff regardless of pct
                                          (fresh session starts clean)
```

### Why both

- `/compact` is a **tactical** tool: it lets the controller shed intermediate
  reasoning from a long discussion inside a single task. Cheap, fast, keeps
  the thread alive. But it's lossy: the summary is produced by the model
  and loses nuance; failure mode is "model keeps going but quality quietly
  drops."
- handoff is a **strategic** tool: it acknowledges that at a plan-level
  boundary, dragging accumulated context forward is the wrong default —
  decisions_log + checkpoint carry forward the **structured** state that
  actually matters, and a fresh session gets all its context back.

### Sequence in a long plan

A typical plan with context pressure looks like this:
1. Work through tasks 1-3, pct climbs to 45%.
2. Task 4 is tightly related (modifies Task 3's code) — controller invokes
   `/compact` (not handoff), pct drops to ~25%, keeps going.
3. Tasks 4-6 complete, pct back to 50%.
4. Task 7 is a new independent module — relatedness is low, so handoff
   threshold is 30%. Since pct=50% ≥ 30%, controller **handoffs**.
5. New session starts from checkpoint. Task 7 begins with a clean
   200K-token budget.

### What the controller actually does at each checkpoint

After writing the checkpoint and computing `pct`:

```
if pct >= handoff_threshold_pct:
    emit Resume Prompt; stop.
elif pct >= 40 and next_task_relatedness == "high":
    suggest (but do NOT auto-run) /compact in the progress line:
      "[context] pct=45% — /compact recommended before continuing"
    # The user or controller invokes /compact manually. This is one of the
    # few things where a suggestion to the user is fine because /compact
    # is itself a user-gesture tool in Claude Code.
else:
    continue silently.
```

The controller does NOT auto-invoke `/compact` — that's a Claude Code CLI
gesture, not an Agent tool call. Printing the suggestion is enough; the
user types `/compact` if they agree.

## Resume Prompt (emitted at handoff)

Print this block verbatim (with substitutions filled in) and then stop
taking new actions:

```
══════════════════════════════════════════════════════════
 Context budget reached: {pct}% — handing off
══════════════════════════════════════════════════════════

 Plan:         {plan_path}
 Worktree:     {worktree}
 Checkpoint:   {checkpoint_path}
 Completed:    tasks 1-{last_done_n} of {total}
 Remaining:    tasks {last_done_n+1}-{total}

 Open questions:  {count}
 Decisions log:   {count} entries

To resume in a fresh session, run:

  cd {worktree}
  claude

Then at the prompt type:

  /resume-plan {checkpoint_path}

(Or simply `/resume-plan` to auto-discover the most recent unfinished
checkpoint in the worktree.)

The new session will rebuild TodoWrite from the checkpoint and continue
from the first task with status != "done". Subagents are fresh per task
so there is nothing to "reconnect" — the worktree + checkpoint are the
only state needed.
```

After emitting, the controller does nothing else in this session.

## Autonomous Loop Mode

When the environment variable `SUPERPOWERS_AUTONOMOUS_LOOP=1` is set, the
controller's handoff behavior changes. This mode is activated by
`scripts/run-plan-autonomous.sh`, which the user explicitly opts into at
plan start (see `subagent-driven-development` → Plan Start Initialization).

### Behavior differences

| Situation | Interactive mode (default) | Autonomous mode |
|---|---|---|
| `pct >= handoff_threshold_pct` | Emit full Resume Prompt, stop taking action, wait for user | Write checkpoint with `handoff_requested: true`; print one-line status; let the turn end naturally so the `claude -p` process exits |
| Hard gate (main branch, BLOCKED with exhausted providers, open_questions stalemate) | Ask user, wait | Write `NEEDS_HUMAN.txt` next to the checkpoint with a short reason; exit |
| Normal task completion | Continue to next task | Continue to next task (same) |

In autonomous mode the controller **must not** call `AskUserQuestion` — the
outer script is not wired to a human. If a hard gate fires, the controller
writes `NEEDS_HUMAN.txt` (with rationale + the question it would have
asked) and exits. The outer script sees the file and stops the loop.

### The exit protocol (autonomous handoff)

Concretely, when the controller decides to hand off in autonomous mode:

1. Write the checkpoint with updated state + `handoff_requested: true`.
2. Print a single line to stdout: `[autonomous] handoff at pct=X% relatedness=Y threshold=Z — exiting turn`.
3. **Do NOT** call any further tools in this turn.
4. The `claude -p` session will end, the process will exit 0.
5. The outer script detects the exit, inspects the checkpoint, and spawns
   the next session.

### `NEEDS_HUMAN.txt` format

When a hard gate fires in autonomous mode, write this file next to the
checkpoint (same directory):

```
# NEEDS_HUMAN — autonomous loop stopped

Plan: docs/superpowers/plans/X.md
Checkpoint: docs/superpowers/checkpoints/X-checkpoint.json
Reason: BLOCKED implementer (task 3, all providers exhausted)
Detail:
  Task 3 "Recovery modes" returned Status: BLOCKED from every provider in
  the integration tier chain (anthropic/sonnet, codex/gpt-5.4,
  gemini-cli/gemini-2.5-pro, glm-cli/glm-4.6, anthropic/opus). Implementer
  reports the task needs a design decision about retry policy that isn't
  in the plan.

Suggested action:
  Open a new session, run /resume-plan <checkpoint>, answer the question,
  and either finish interactively or re-launch the autonomous loop.
```

The outer script recognizes this file and terminates without spawning more
sessions.

### Safety invariants (autonomous mode)

- Controller must not modify `.gitignore` or touch files outside the worktree.
- Controller must not auto-approve operations on `main`/`master` — those remain hard gates and produce `NEEDS_HUMAN.txt`.
- Controller must not `AskUserQuestion` — no human is listening; asking would hang the loop. If it would have asked, write `NEEDS_HUMAN.txt` instead.
- Every session records in its checkpoint's `decisions_log` under `stage: autonomous_session`, including the UUID of the `claude -p` session so the full chain is auditable.

## Resuming in a New Session

As of 6.1.0, the resume entry point is **plan.md frontmatter first,
checkpoint.json second**. This lets `executing-plans` (and any other
skill that starts from a plan) recover state without requiring a
separate checkpoint file.

### Resume algorithm

```
given INPUT (plan.md path OR checkpoint.json path):

  # Step 1 — resolve plan.md
  if INPUT ends in .md:
    plan = INPUT
  elif INPUT ends in .json:
    plan = checkpoint.json.plan_path        # back-pointer
  else:
    error and exit

  # Step 2 — read frontmatter (authoritative for resume state)
  if plan.md has `plan_version` in frontmatter:
    state = parse frontmatter
    if state.checkpoint_pointer and file exists:
      # merge bulk state (decisions_log, provider_availability, todos)
      state += read_checkpoint(state.checkpoint_pointer)
    else:
      warn: "no checkpoint; decisions_log will start empty for this run"
    rebuild TodoWrite from plan.md tasks
    jump to subagent-driven-development at frontmatter.current_task
    (resume at the recorded `stage` inside that task, if any)

  # Step 3 — legacy fallback (6.0.0 checkpoints without plan frontmatter)
  elif checkpoint.json exists:
    state = read checkpoint
    rebuild TodoWrite from state.tasks
    jump to subagent-driven-development at state.next_pending_task

  # Step 4 — neither present
  else:
    print resume banner "no resumable state"; invoke Plan Start Init.
```

### `checkpoint_pointer` — the back-link

Every checkpoint.json that corresponds to a plan carries
`plan_path: "docs/superpowers/plans/<name>.md"`, and the plan's
frontmatter carries `checkpoint_pointer` with the reverse. Both sides
keep the link current so the resume algorithm can cross-reference from
either direction.

### What resume does NOT re-do

- **Does not re-run** `scripts/detect-model-providers.sh` (cached in
  checkpoint's `provider_availability`). If the user wants fresh probing
  they delete that field.
- **Does not re-run** Reviewer B detection.
- **Does not re-ask** Plan Start Initialization — the frontmatter
  already encodes the user's choices.

### Resume banner

Print at the top of the new session before dispatching the first task:

```
── Resumed from plan ──
  Plan:         {plan_path}
  Next task:    {n}/{total} — {name}
  Resuming at:  Stage {s}/3  (or "start" if no in-flight stage)
  Convergence:  round {r} of {max_convergence_rounds}
```

## Hard Gates (Never Autonomous)

This skill does NOT override these: they remain user-gated in
subagent-driven-development:
- Operations on `main`/`master` branches
- `BLOCKED` from implementer with all providers exhausted
- brainstorming's spec approval

The handoff emit itself is NOT a "request for confirmation" — it's a
deterministic state transition. The user can resume or discard as they
please; no dialogue is needed at the threshold.

## Anti-Patterns

- ❌ Writing the checkpoint only at plan completion (defeats the purpose)
- ❌ Asking the user "should I checkpoint?" at every boundary
- ❌ Using the checkpoint to skip review stages (it's state, not short-circuit)
- ❌ Storing API keys or any secret in the checkpoint (audit: this file goes in the repo)
- ❌ Deleting `decisions_log` entries — it's append-only; add a correction entry instead
- ❌ Letting estimated_pct reset to 0 on every task (it's cumulative across the whole plan's controller session)
