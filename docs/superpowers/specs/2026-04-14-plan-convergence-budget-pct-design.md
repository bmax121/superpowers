# Design: Plan convergence loop + weekly-budget-percent + plan-as-state

**Date:** 2026-04-14
**Status:** Design approved (2026-04-14)
**Target version:** superpowers 6.1.0
**Authors:** brainstorming-driven

## Context

Superpowers 6.0.0 shipped:
- Declarative model routing via `config/models.yaml`
- Long-context checkpoint + `/resume-plan`
- Autonomous loop driver (`scripts/run-plan-autonomous.sh`) with USD cap
- Autonomous feedback triage with `decisions_log`

Gaps discovered immediately after ship:

1. **USD budget cap is the wrong unit.** Users who pay Anthropic a flat weekly/monthly plan don't think in "$20 per run"; they think in percent of this week's cap. `--max-cost 20` is a pragmatic placeholder, not a user-facing contract.
2. **No goal-convergence guarantee.** A plan's last task can succeed while the overall goal (e.g. "all tests pass end-to-end") is still broken. The current flow stops at "all tasks done" — it does not *verify* the larger intent.
3. **State split across two files confuses resume.** `plan.md` holds the human design, `checkpoint.json` holds runtime state. A new session wanting to resume must understand both. Users editing `plan.md` lose execution context; users reading `plan.md` see no progress.
4. **No self-healing loop.** If verification fails after all tasks, the current flow has no mechanism to append new tasks and retry.

This spec addresses all four.

## Goals

- **Budget in percent-of-weekly.** Users configure a weekly USD cap once; autonomous runs declare a percent allowance of that cap, or `none` for unlimited.
- **First-class `final_goal`.** Every plan declares an objectively-verifiable goal (or one judged by an LLM subagent) selected from 7 templates plus `custom`.
- **Plan-as-state.** `plan.md` itself carries the minimal state needed to resume: YAML frontmatter (plan-level pointers) + inline `**Status:**` on each task.
- **Convergence loop.** After all tasks reach terminal state, the controller runs final_goal verification. On failure, dispatch a gap-analyzer to append new tasks and retry, bounded by `max_convergence_rounds`.

## Non-goals

- Multi-goal plans (AND/OR of goals). Out of scope; one plan = one goal.
- Cross-plan budget accounting (one plan's spend doesn't affect another's cap).
- Replacing the existing three-stage review (spec / quality / external) — convergence is a LAYER ABOVE, run only after all tasks individually pass their three-stage review.
- Real-time UI. Users monitor via `tail -f` on checkpoint logs or plan.md; we do not add a dashboard.

## Design

### 1. Weekly-percent budget system

**Data source:** `~/.claude/metrics/costs.jsonl` (already written by Claude Code; verified fields: `timestamp`, `estimated_cost_usd`, `model`, `input_tokens`, `output_tokens`, `session_id`).

**User configuration** (one-time): `~/.claude/superpowers-budget.yaml`

```yaml
# Weekly cap in USD. Anthropic does not expose your plan's dollar cap via
# API, so you write it here once. Set to null to declare "unlimited" mode.
weekly_cap_usd: 200

# Optional: alternative window. Defaults to 7 rolling days from now.
# window_days: 7
```

**New helper script:** `scripts/compute-weekly-spent.sh`

- Reads `~/.claude/metrics/costs.jsonl`.
- Sums `estimated_cost_usd` for entries whose `timestamp` is within the window (default 7 days).
- Outputs JSON to stdout: `{"weekly_spent_usd": 42.17, "window_days": 7, "entries": 183}`.
- Reads `superpowers-budget.yaml` if present; attaches `{"weekly_cap_usd": 200, "pct": 21.08}` when cap is set.

**Autonomous loop flags** (`scripts/run-plan-autonomous.sh`):

| New flag | Meaning |
|---|---|
| `--budget-pct N` | Allow up to `N%` of `weekly_cap_usd` to be spent in this run (combining all handoffs). Values 1-100. |
| `--budget-pct none` | Unlimited. No budget check; run until handoffs cap or convergence bound. |
| `--budget-cap-usd N` | Escape hatch for users without a configured weekly_cap_usd: use absolute USD instead. Mutually exclusive with `--budget-pct`. |

**Deprecated:** `--max-cost N` still parses but prints a warning and is treated as `--budget-cap-usd N`. Removed in 7.0.0.

**Pre-flight check** (each iteration of the outer loop):
```
weekly_spent = compute-weekly-spent.sh
limit = weekly_cap_usd * (budget_pct / 100)    # if --budget-pct
     OR budget_cap_usd                          # if --budget-cap-usd
     OR +infinity                               # if none or unset
if weekly_spent + per_session_budget > limit:
    stop with status="budget_exhausted", exit 1
```

Per-session budget is allocated `remaining_limit / remaining_handoffs_budget` (floor $1).

### 2. plan.md schema (state-bearing)

Every plan produced by `writing-plans` (or hand-written) carries YAML frontmatter and `**Status:**` markers. The controller edits these in place as execution progresses.

**Frontmatter:**

```yaml
---
plan_version: 1
final_goal:
  template: all_tests_pass              # see §3 for full list
  verify_command: "pytest -q"
  judge_rationale: null                 # only filled when template == custom
  # Template-specific extras (deploy_command, canary_duration_sec, assertion, ...)
  # live under the template's own keys.
status: in_progress                     # not_started | in_progress | goal_met |
                                        # goal_not_met | budget_exhausted |
                                        # stalled | blocked | judge_uncertain |
                                        # review_contradiction | main_branch_gate
execution_mode: interactive             # interactive | autonomous
current_task: 2                         # most recently dispatched task number
convergence_round: 0                    # increments each time the goal-verify
                                        # loop adds new tasks
last_handoff:
  pct: 42
  ts: "2026-04-14T03:00:00Z"
checkpoint_pointer: docs/superpowers/checkpoints/<plan-basename>-checkpoint.json
autonomous_limits:                      # null in interactive mode
  budget_pct: 30                        # or null (unlimited)
  budget_cap_usd: null                  # mutually exclusive with budget_pct
  max_convergence_rounds: 3
  max_handoffs: 10
  no_progress_abort_after: 2
---

# Plan: ...

<human-authored prose, goals, context — unchanged from current format>

## Task 1: ...

**Tier:** mechanical
**Status:** done
**Commit:** abc123
**Provider:** anthropic/sonnet

<Task body — spec, acceptance, etc.>

## Task 2: ...

**Tier:** integration
**Status:** in_progress
<...>
```

**Status values (per task):**

| Value | Meaning |
|---|---|
| `pending` | Not yet dispatched. |
| `in_progress` | Implementer dispatched; not yet all-reviews-approved. |
| `done` | All three review stages approved; commit recorded. |
| `blocked` | Every provider in the tier chain failed; escalated. |
| `deferred` | Convergence-added task we decided to skip (`superseded` is similar). |
| `superseded` | A convergence round produced a new task that replaces this one. |

**Two distinct status namespaces — do not confuse:**

- `frontmatter.status` describes the *whole plan* (its terminal state or in-progress).
  Values listed in the schema above (`goal_met`, `blocked`, `stalled`, ...).
- `**Status:**` on each `## Task N` section describes *that task*. Values are
  `pending | in_progress | done | blocked | deferred | superseded`.

The token `blocked` appears in both but has different meaning: a task is
`blocked` when every provider in its tier chain failed; the plan becomes
`blocked` (terminal) when that happens AND the controller is in autonomous
mode with no path forward.

**Rationale for frontmatter + inline (not all-frontmatter, not all-checkpoint):**
- Users read `plan.md` to know progress; editors read it to help them navigate.
- `git log plan.md` is an audit trail of execution, not just design.
- Bulk data (full `decisions_log`, `provider_availability`, `todos` snapshot) still lives in checkpoint.json — keeps markdown clean.
- `checkpoint_pointer` links the two; resume code needs to read both.

### 3. `final_goal` templates

Plan Start Initialization (first run only) asks the user which template applies. 7 built-in + free-form:

| Template | Required params | Verify mechanism |
|---|---|---|
| `all_tests_pass` | `verify_command` (e.g. `pytest -q`) | Run command; exit 0 ⇒ met. |
| `code_review_clean` | — | After final code-reviewer subagent, frontmatter must record no Critical/Important Issues. |
| `verify_command_zero` | `verify_command` | Generic variant of `all_tests_pass` — use for lint/typecheck/custom gates. |
| `deploy_success` | `deploy_command`, `health_check_command` | Both commands exit 0. |
| `canary_clean` | `canary_command`, `canary_duration_sec` (default 300) | Command runs for duration; exit 0 ⇒ met. |
| `metrics_met` | `metric_query_command`, `assertion` (shell expr) | `metric_query_command | assertion` exits 0. |
| `custom` | `judge_rationale` (one sentence in natural language) | Goal Judge subagent (§5) returns `met`. |

**New subagent prompt:** `skills/subagent-driven-development/goal-judge-prompt.md`

The Goal Judge subagent receives:
- `final_goal.judge_rationale`
- The full plan.md (for context on what was attempted)
- List of commits in this worktree since plan start
- `decisions_log` summary (which triage decisions were deferred/rejected, so the judge sees known compromises)
- Output of any programmatic checks the controller pre-ran (test outputs, lint reports)

Returns structured verdict:
```
Verdict: met | not_met | uncertain
Confidence: high | medium | low
Rationale: <1-3 sentences>
Gaps: (only if not_met) <what appears missing>
```

`uncertain` always triggers NEEDS_HUMAN (hard gate). Only `custom` template can produce `uncertain`; programmatic templates return `met` or `not_met` based purely on exit codes.

### 4. Execution flow changes

Existing subagent-driven-development flow is preserved end-to-end. The only changes are **what gets written** at each transition.

**After each task's final approval** (all three review stages pass):

1. Write checkpoint.json with new `tasks[n].status = "done"`, `commit`, `provider_used`, full `decisions_log`.
2. Edit plan.md:
   - `## Task N` section: `**Status:** in_progress` → `**Status:** done`; append `**Commit:** <sha>` and `**Provider:** <provider>/<model>` if not present.
   - Frontmatter: `current_task = N+1`, `last_handoff.pct = <estimate>`, `last_handoff.ts = now`.
3. Recompute context estimate & relatedness (unchanged from 6.0.0).
4. Handoff check (unchanged from 6.0.0).

**On BLOCKED:**

1. Checkpoint records the blocker detail.
2. plan.md `## Task N` Status → `blocked`, plus `**Blocker:** <short reason>`.
3. In autonomous mode: also write `NEEDS_HUMAN.txt` (hard gate).

**Atomicity:** Checkpoint is written first (structured, authoritative); then plan.md is edited. If the plan.md edit fails or is interrupted, resume uses the checkpoint to rebuild frontmatter + Status markers.

### 5. Convergence loop (plan-level final review)

Triggered when ALL tasks reach terminal state (`done`, `deferred`, or `superseded` — note `blocked` does NOT trigger the loop; `blocked` is a hard gate).

```
CONVERGENCE_LOOP:
  STEP 1: Verify final_goal
    - Programmatic templates: run verify_command(s); capture exit + stdout snippet.
    - custom template: dispatch Goal Judge subagent.
    - Record verdict in decisions_log.
    - Edit plan.md frontmatter.status = goal_met if met; continue if not_met;
      escalate NEEDS_HUMAN if uncertain.

  STEP 2: Check convergence bounds
    - if convergence_round >= max_convergence_rounds:
        status = goal_not_met
        write conclusion to decisions_log
        exit 1
    - if weekly_spent + estimated_remedy_cost > budget_limit:
        status = budget_exhausted
        exit 1

  STEP 3: Dispatch gap analyzer
    New subagent prompt: skills/subagent-driven-development/gap-analyzer-prompt.md
    Input: final_goal, verify output (stdout/stderr), plan.md, decisions_log
    Output: a YAML array of new task entries, each with:
      - name
      - tier (mechanical/integration/architecture)
      - rationale (which gap it closes)
      - spec body
    Safety: gap analyzer MUST NOT rewrite existing tasks, only append.

  STEP 4: Append to plan.md
    - For each new task, append a `## Task N+i: ...` section with Status=pending,
      including the gap analyzer's spec body.
    - Frontmatter.convergence_round += 1.
    - Frontmatter.current_task = N+1 (first new task).

  STEP 5: Reset no_progress counter
    - The newly-added task counts as "progress". no_progress_count = 0.
    - This prevents the loop from tripping the stall guard while doing legitimate
      convergence work.

  STEP 6: Re-enter the main task loop
    - subagent-driven-development picks up from current_task as usual.
    - After new tasks complete, re-enter CONVERGENCE_LOOP at STEP 1.
```

**Defaults:**
- `max_convergence_rounds: 3`
- If user wants "loop until it gives up", set `max_convergence_rounds: null` (unlimited, only budget_pct stops it).

### 6. Resume: prefer plan.md frontmatter

`/resume-plan <arg>` now accepts **either** a plan.md or a checkpoint.json path. Auto-discovery finds `docs/superpowers/plans/*.md` first (plans with `plan_version` frontmatter); falls back to `docs/superpowers/checkpoints/*-checkpoint.json`.

Resume algorithm:

```
if plan.md has `plan_version` in frontmatter:
    state = read frontmatter
    if checkpoint_pointer is set and file exists:
        merge full decisions_log / provider_availability / etc from checkpoint
    else:
        warn: "no checkpoint; reconstructed state from plan only, decisions_log
               will start empty"
    rebuild TodoWrite from tasks in plan.md
    jump to subagent-driven-development at current_task
elif checkpoint.json exists (legacy 6.0.0):
    use checkpoint as sole state source
else:
    first run: invoke Plan Start Initialization
```

`executing-plans` skill documentation is updated to note the new frontmatter-first resume path. The skill's entry point is still "a plan.md" — the change is that the plan.md may now carry machine state.

### 7. Hard-gate termination matrix (autonomous mode)

| Trigger | frontmatter.status | exit code | Produces |
|---|---|---|---|
| final_goal met | `goal_met` | 0 | Final report |
| Convergence rounds exhausted, still not_met | `goal_not_met` | 1 | Gap analysis snippet of last round |
| Weekly budget percent / cap exceeded | `budget_exhausted` | 1 | Spend summary + remaining work |
| No-progress abort (no new `done` for N handoffs, ignoring convergence-added tasks) | `stalled` | 1 | Last progress marker |
| Any task BLOCKED with all providers exhausted | `blocked` | 2 | NEEDS_HUMAN.txt |
| Goal Judge returns `uncertain` | `judge_uncertain` | 2 | NEEDS_HUMAN.txt |
| Reviewer A/B contradict on a Critical finding | `review_contradiction` | 2 | NEEDS_HUMAN.txt |
| main/master branch operation proposed | `main_branch_gate` | 2 | NEEDS_HUMAN.txt |

All termination branches write a final entry to `decisions_log` with
`stage: terminate` and a rationale.

## Impact map

**New files:**
- `scripts/compute-weekly-spent.sh`
- `skills/subagent-driven-development/goal-judge-prompt.md`
- `skills/subagent-driven-development/gap-analyzer-prompt.md`
- Example `superpowers-budget.yaml` (ships as `config/superpowers-budget.example.yaml`)

**Modified files:**
- `skills/subagent-driven-development/SKILL.md`
  - Plan Start Initialization asks for `final_goal.template` + params
  - Per-task flow edits plan.md after checkpoint write
  - New "Convergence loop" section after "Checkpoint Integration"
  - Hard gates table replaces current four-item list
- `skills/long-context-checkpoint/SKILL.md`
  - Document `checkpoint_pointer` (checkpoint's peer to plan.md's pointer back)
  - Resume procedure now states "prefer plan.md frontmatter, fall back to checkpoint"
- `skills/writing-plans/SKILL.md`
  - Require output to include frontmatter and per-task `**Status:** pending`
  - Provide the 7 final_goal template menu
- `skills/executing-plans/SKILL.md`
  - Document the frontmatter-first entry path
- `scripts/run-plan-autonomous.sh`
  - Add `--budget-pct`, `--budget-cap-usd`; deprecate `--max-cost`
  - Wire `scripts/compute-weekly-spent.sh` into per-iteration pre-flight
  - Parse plan.md frontmatter for autonomous_limits; CLI flags override
  - Extend exit codes per hard-gate table
- `commands/resume-plan.md`
  - Accept plan.md or checkpoint.json
- `config/models.yaml` — no change
- `hooks/session-start` — no change (checkpoint-scanning logic stays as-is)

**Deprecated:**
- `scripts/run-plan-autonomous.sh --max-cost N` — still works with deprecation warning; removed in 7.0.0.

## Success criteria

This design is successful if, after implementation:

1. A plan started in autonomous mode with `final_goal.template = all_tests_pass` and broken code:
   - runs through all declared tasks
   - detects test failure at convergence step
   - gap-analyzer adds a fix-tests task
   - after at most `max_convergence_rounds` loops, either tests pass (`goal_met`) or the tool terminates with `goal_not_met` + a written gap
2. Interrupting the run (Ctrl-C outside the claude process) and running `/resume-plan <plan.md>` in a new session rebuilds TodoWrite from frontmatter, loads bulk state from checkpoint, and continues from `current_task`.
3. `scripts/compute-weekly-spent.sh` returns a sensible number matching a manual grep over `costs.jsonl`.
4. Users who previously used `--max-cost 20` see a deprecation warning but their runs still work.

## Open questions

None as of approval. All four clarifying questions answered; design bounds chosen.

## Out of scope for this spec

- Multi-goal plans (AND/OR composition of final_goal).
- Graphical dashboard of convergence progress.
- Automatic weekly_cap_usd discovery (Anthropic does not expose it; user must configure).
- Inter-plan budget aggregation.
- Goal templates beyond the 7 listed — the `custom` escape hatch covers the long tail.
