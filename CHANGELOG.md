# Changelog

## [6.2.0] - 2026-04-15

Single unified reviewer replaces three-stage review chain. Per-task
subagent dispatches: **5 → 2** (60% reduction).

### Breaking changes

- **Three-stage review removed from the active flow.** `spec-reviewer`,
  `code-quality-reviewer`, and `external-reviewer` (Reviewer A + B)
  are no longer dispatched by 6.2.0+ controllers. They're replaced by
  a single `unified-reviewer-prompt.md` dispatch that covers six
  dimensions: spec compliance, code quality, test coverage depth,
  architecture, performance, security.
- **`Reviewer B Detection` removed.** No more 4-level fallback chain
  scanning for `/codex:review` skill / codex CLI / gemini CLI / Opus
  agent. Reviewer routing now goes through the standard
  `config/models.yaml` provider tier (`reviewer:` tier).
- **Stage Progress Display markers changed.** Old: `─── Stage 1/3:
  Spec Compliance ───` (× 3). New: `─── Implementer (provider/model)
  ───` and `─── Unified Reviewer (provider/model) ───`.

### New features

- **`unified-reviewer-prompt.md`** — single-dispatch reviewer with a
  rigid 6-dimension output schema (`Spec`, `Quality`, `Coverage`,
  `Architecture`, `Performance`, `Security`) plus
  `Findings: Critical / Important / Minor`. Cross-model diversity is
  preserved via reviewer-tier provider routing — when implementer ran
  on family X, reviewer prefers family ≠ X.
- **New `reviewer` tier in `config/models.yaml`** with default
  fallback chain: anthropic/sonnet → codex/gpt-5.4 →
  gemini-cli/gemini-2.5-pro → anthropic/opus.

### Migration

- 6.1.0 plans run unchanged on 6.2.0 controllers. Plan format is
  unchanged.
- Legacy prompts (`spec-reviewer-prompt.md`,
  `code-quality-reviewer-prompt.md`, `external-reviewer-prompt.md`)
  are prefixed with a `DEPRECATED in 6.2.0` banner and remain in
  the directory. They will be removed in 7.0.0.
- 6.1.0 controllers still work — they just dispatch the old chain
  if explicitly told to. Upgrade path: nothing required, the new
  controller picks up `unified-reviewer-prompt.md` automatically.

### Cost impact

- Per-task subagent dispatches: **5 → 2** (60% reduction)
- Sonnet review × 3 (one in each stage) → Sonnet review × 1
- Reviewer A + Reviewer B parallel external review eliminated
- Wall-clock per task: ~50% faster (fewer round-trips)
- Quality signal preserved: dimensions are now structured and
  comparable, with severity-tagged findings driving auto-triage.

## [6.1.0] - 2026-04-15

Convergence loop + weekly-percent budget + plan-as-state. Minor breaking
changes to autonomous CLI flags and plan format.

### Breaking changes

- **`plan.md` now carries YAML frontmatter and per-task `**Status:**`
  markers.** Plans written by 6.0.0's `writing-plans` will still execute,
  but new plans require the frontmatter (automatically produced by
  `writing-plans` 6.1.0). `/resume-plan` prefers frontmatter; the old
  checkpoint-only path remains as a fallback for 6.0.0 plans.
- **`scripts/run-plan-autonomous.sh --max-cost N` is deprecated.** Still
  works with a warning; treated as `--budget-cap-usd N`. Will be removed
  in 7.0.0. Prefer `--budget-pct N` against
  `~/.claude/superpowers-budget.yaml`.

### New features

- **Weekly-percent budget.** `scripts/compute-weekly-spent.sh` reads
  `~/.claude/metrics/costs.jsonl` and outputs this week's spend. The
  autonomous driver's `--budget-pct N` uses this against
  `weekly_cap_usd` in `~/.claude/superpowers-budget.yaml`.
  `--budget-pct none` for unlimited; `--budget-cap-usd N` as escape hatch
  for users without a weekly cap configured.
- **`final_goal` per plan.** Plan Start Initialization asks for one of
  seven templates (`all_tests_pass`, `code_review_clean`,
  `verify_command_zero`, `deploy_success`, `canary_clean`, `metrics_met`,
  `custom`). Programmatic templates verify via shell command; `custom`
  dispatches the new Goal Judge subagent.
- **Convergence loop.** After all tasks reach terminal state, the
  controller verifies `final_goal`. On failure, the Gap Analyzer
  subagent proposes fresh tasks; the controller appends them and
  re-enters the main loop. Bounded by `max_convergence_rounds` (default
  3).
- **Plan-as-state.** YAML frontmatter holds `current_task`,
  `convergence_round`, `status`, and `autonomous_limits`. The controller
  edits frontmatter + per-task `**Status:**` alongside each checkpoint
  write. `git log plan.md` becomes an execution audit trail.
- **Extended termination statuses.** `frontmatter.status` ends in one of
  `goal_met` | `goal_not_met` | `budget_exhausted` | `stalled` |
  `blocked` | `judge_uncertain` | `review_contradiction` |
  `main_branch_gate`. Each maps to a specific exit code.
- **`executing-plans` frontmatter-first entry.** `/resume-plan` accepts
  either a plan.md or a checkpoint.json; the plan path is preferred.

### Upgrade notes

1. **6.0.0 plans** keep working — they have no frontmatter, so
   `/resume-plan` falls back to checkpoint-only resume.
2. **Users on `--max-cost N`** see a deprecation warning; no action
   needed until 7.0.0.
3. **To use `--budget-pct`**: create `~/.claude/superpowers-budget.yaml`
   with a `weekly_cap_usd: <your-plan-cap>`. Example at
   `config/superpowers-budget.example.yaml`.

## [6.0.0] - 2026-04-13

This is a major release. The core change is that `subagent-driven-development`
now runs **autonomously by default** — the controller no longer stops to
ask users to confirm every external-review triage decision — plus a new
declarative model-routing layer and a checkpoint system that lets long
plans survive session boundaries.

### Breaking changes

- **Autonomous external-review triage.** The Stage 3 review loop no longer
  asks the user to confirm each issue as Valid / Rejected / Discuss.
  Instead the controller applies a rule matrix (see
  `subagent-driven-development` → "Autonomous Feedback Triage") and
  appends every decision to `checkpoint.decisions_log` for post-hoc audit.
  The user is now only interrupted on four hard gates:
  main/master branch operations, BLOCKED implementer with every provider
  in the tier exhausted, deferred-only triage stalemate, and Reviewer A/B
  contradicting on a Critical finding. Previous behavior ("User confirms
  triage") is removed.
- **Model selection is declarative.** The controller no longer hardcodes
  `model: "sonnet" | "opus"` per task. Routing is now driven by
  `config/models.yaml`, which maps a task tier (mechanical / integration
  / architecture) to an ordered (provider, model) fallback chain. Custom
  providers (GLM, Qwen, DeepSeek, …) are added by declaring them in the
  yaml with a `cli_wrapper` command template.
- **Default mechanical tier is Sonnet, not Haiku.** When the controller
  session is Opus, "mechanical" work steps down to Sonnet (and optionally
  further to cross-family CLIs or Haiku as configured fallbacks). Prior
  releases implied Haiku as the cheap default; Sonnet is now the
  production-code floor we trust.

### New features

- **`config/models.yaml`** — declarative tier → provider chain. Ships with
  defaults for Anthropic (`agent_tool`), codex, gemini-cli, and glm-cli
  (`cli_wrapper`). Users edit the yaml to add new models; no skill edits
  required.
- **`scripts/detect-model-providers.sh`** — probes which providers from
  the yaml are actually invocable on the current machine; outputs a
  human-readable summary plus a machine-parseable JSON availability map
  for the controller to cache in the checkpoint.
- **CLI-wrapper providers.** Implementers can now be dispatched to any CLI
  that accepts a prompt file and writes the final assistant message to an
  output file (codex, gemini, glm, etc.), not just to Claude Code's
  built-in `Agent` tool. The implementer `Output Protocol` header
  (`Status:/Files:/Tests:/Concerns:/---REPORT---`) makes reports
  parseable across model families. Fallback automatically steps to the
  next entry in the tier chain on non-zero exit, empty output, or
  missing Status header; the reason (including captured stderr) is
  logged to `decisions_log`.
- **`skills/long-context-checkpoint`** — persists plan execution state
  (provider availability, Reviewer B detection, tasks, decisions_log,
  open_questions) to `docs/superpowers/checkpoints/<plan>-checkpoint.json`.
  Subagents remain fresh per task, so the only state that must survive a
  session swap lives in the controller — the checkpoint externalizes it.
- **Relatedness-aware handoff threshold.** Instead of a fixed 50%
  context-budget handoff, the controller scores the NEXT task's
  relatedness to the current session (high / medium / low) and picks a
  threshold of 70% / 50% / 30% respectively. Rationale is recorded in
  the checkpoint for audit.
- **`/resume-plan <checkpoint>`** — slash command that rebuilds TodoWrite
  from a checkpoint and continues the plan in a fresh session. Omit the
  argument to auto-discover the most recent unfinished checkpoint in
  `docs/superpowers/checkpoints/`.
- **Autonomous loop mode.** Users can opt into fully-automated execution
  by launching `scripts/run-plan-autonomous.sh <plan-or-checkpoint>`. The
  outer shell script spawns `claude -p` iterations with
  `SUPERPOWERS_AUTONOMOUS_LOOP=1`, honoring per-run caps: `--max-cost
  USD` (default 20), `--max-handoffs N` (default 10),
  `--no-progress-abort N` (default 2). On hard gates, the controller
  writes `NEEDS_HUMAN.txt` next to the checkpoint and exits; the outer
  loop detects this and stops.
- **`/compact` coexistence.** The `long-context-checkpoint` skill
  documents a two-tool strategy: `/compact` for tactical mid-task
  compression (lossy LLM summarization, same session), handoff for
  strategic plan-boundary state externalization (lossless, new session).
  The controller hints at `/compact` near the threshold but never
  auto-invokes it (slash commands are user gestures, not tool calls).
- **Session-start hook** now scans `docs/superpowers/checkpoints/*.json`
  in the current directory and injects one hint line per unfinished
  checkpoint into the new session's context.
- **Test-driven-development skill** is expanded with explicit coverage
  layers (unit / integration / E2E), boundary testing rubrics (null /
  empty / max / invalid / date-edge), concrete stress-test expectations
  with p99/throughput assertions, and a mandatory concurrency-test rule
  for any code touching shared state (with a multi-language race-detector
  matrix: `go test -race`, `loom`, Thread Sanitizer, JCStress, etc.).
  `code-quality-reviewer-prompt.md` checks for this coverage; missing
  layers without a documented "not applicable" rationale flag as
  Important.

### Checkpoints are runtime state, not source

First checkpoint write creates `docs/superpowers/checkpoints/.gitignore`
(content: `*` with `.gitignore` and `README.md` whitelisted) so
checkpoints sit alongside `specs/` and `plans/` on disk but are never
committed. Existing users with a pre-6.0 repo should add this directory
to their `.gitignore` manually if they have locally modified checkpoints
from development testing.

### Upgrade notes

1. **Interactive users**: no action required. First run on an existing
   plan will ask one extra question ("Execution mode: interactive /
   autonomous"); default answer preserves previous behavior (minus the
   per-triage confirmations, which are now automatic).
2. **Users who relied on per-triage confirmations** to catch bad
   external-review findings: review `decisions_log` periodically during
   the run, or interrupt and re-run interactively. The rules matrix
   errs on the side of "reject minor findings that conflict with
   conventions" and "accept Critical/Important findings that touch
   security/correctness" — if your repo has unusual conventions, watch
   the log.
3. **Users who want cross-family implementers** (GPT / Gemini / GLM):
   install the corresponding CLI, ensure it's on PATH, and
   `scripts/detect-model-providers.sh` will pick it up automatically.
   Edit `config/models.yaml` to change its position in the tier chain.

## [5.0.5] - 2026-03-17

### Fixed

- **Brainstorm server ESM fix**: Renamed `server.js` → `server.cjs` so the brainstorming server starts correctly on Node.js 22+ where the root `package.json` `"type": "module"` caused `require()` to fail. ([PR #784](https://github.com/obra/superpowers/pull/784) by @sarbojitrana, fixes [#774](https://github.com/obra/superpowers/issues/774), [#780](https://github.com/obra/superpowers/issues/780), [#783](https://github.com/obra/superpowers/issues/783))
- **Brainstorm owner-PID on Windows**: Skip `BRAINSTORM_OWNER_PID` lifecycle monitoring on Windows/MSYS2 where the PID namespace is invisible to Node.js. Prevents the server from self-terminating after 60 seconds. The 30-minute idle timeout remains as the safety net. ([#770](https://github.com/obra/superpowers/issues/770), docs from [PR #768](https://github.com/obra/superpowers/pull/768) by @lucasyhzhu-debug)
- **stop-server.sh reliability**: Verify the server process actually died before reporting success. Waits up to 2 seconds for graceful shutdown, escalates to `SIGKILL`, and reports failure if the process survives. ([#723](https://github.com/obra/superpowers/issues/723))

### Changed

- **Execution handoff**: Restore user choice between subagent-driven-development and executing-plans after plan writing. Subagent-driven is recommended but no longer mandatory. (Reverts `5e51c3e`)
