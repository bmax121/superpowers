# Plan Convergence + Weekly Budget % + Plan-as-State Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Superpowers 6.1.0 — replace USD budget cap with weekly-percent, move execution state into `plan.md` frontmatter + inline Status, add a convergence loop that verifies `final_goal` after all tasks and self-heals by appending tasks, bounded by `max_convergence_rounds`.

**Architecture:** `plan.md` becomes the execution-state spine: YAML frontmatter holds pointers (current_task, convergence_round, final_goal, autonomous_limits) and each `## Task N` section carries an inline `**Status:**`. Bulk state (decisions_log, provider_availability) stays in `checkpoint.json` and is linked via `checkpoint_pointer`. The autonomous driver (`run-plan-autonomous.sh`) reads frontmatter first, CLI flags second; budget is computed as a percent of a user-configured `weekly_cap_usd` using sums from `~/.claude/metrics/costs.jsonl`. After all tasks reach terminal state, a convergence loop runs `final_goal` verification (command or Goal Judge subagent), and on failure dispatches a gap-analyzer subagent to append fresh tasks, up to `max_convergence_rounds`.

**Tech Stack:** bash + awk + python3 (for JSON/YAML parsing); YAML in plan frontmatter; Skill markdown edits; existing Agent tool + CLI-wrapper providers from 6.0.0.

---

## File Structure

### New

| Path | Responsibility |
|---|---|
| `scripts/compute-weekly-spent.sh` | Read `~/.claude/metrics/costs.jsonl`, sum `estimated_cost_usd` over a rolling window, emit a single JSON line with `weekly_spent_usd`, `window_days`, `entries`, and (if `~/.claude/superpowers-budget.yaml` exists) `weekly_cap_usd` + `pct`. |
| `skills/subagent-driven-development/goal-judge-prompt.md` | Dispatchable prompt for the Goal Judge subagent (only for `template == custom`). Returns `Verdict / Confidence / Rationale / Gaps`. |
| `skills/subagent-driven-development/gap-analyzer-prompt.md` | Dispatchable prompt for the gap-analyzer subagent. Reads plan + verify output + decisions_log, outputs a YAML array of new task entries. |
| `config/superpowers-budget.example.yaml` | Documented example of `~/.claude/superpowers-budget.yaml` (comments explain semantics). |
| `tests/claude-code/test-compute-weekly-spent.sh` | Unit test for `compute-weekly-spent.sh` (mock costs.jsonl, assert sum). |
| `tests/claude-code/test-run-plan-autonomous-budget.sh` | Unit test for budget-pct + frontmatter parsing path of `run-plan-autonomous.sh` (dry-run only). |
| `tests/claude-code/test-plan-md-roundtrip.sh` | Integration test: parse plan.md with frontmatter via python3, run detect + autonomous dry-run, assert all paths agree. |

### Modified

| Path | Sections touched |
|---|---|
| `scripts/run-plan-autonomous.sh` | New flags `--budget-pct`, `--budget-cap-usd`; deprecate `--max-cost`; per-iteration pre-flight calls `compute-weekly-spent.sh`; parses plan.md frontmatter for `autonomous_limits`; writes `frontmatter.status` + `decisions_log` termination entry on every exit branch. |
| `skills/subagent-driven-development/SKILL.md` | Plan Start Initialization extended with 7-template final_goal picker; per-task flow adds plan.md Edit after checkpoint write; new "Convergence Loop" section; hard-gate matrix replaces prior four-item list. |
| `skills/long-context-checkpoint/SKILL.md` | Document `checkpoint_pointer`; rewrite "Resuming in a New Session" to prefer plan.md frontmatter over checkpoint.json. |
| `skills/writing-plans/SKILL.md` | Require frontmatter (plan_version, final_goal, status, autonomous_limits) and per-task `**Status:** pending` in generated plans; present 7-template menu. |
| `skills/executing-plans/SKILL.md` | Document frontmatter-first entry path. |
| `commands/resume-plan.md` | Accept plan.md or checkpoint.json; auto-discover prefers plan.md. |
| `CHANGELOG.md` | New `[6.1.0]` entry. |
| `.claude-plugin/plugin.json`, `package.json`, `.cursor-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `gemini-extension.json` | Bump version 6.0.0 → 6.1.0 via `scripts/bump-version.sh`. |

---

## Tasks

### Task 1: `compute-weekly-spent.sh` helper + test

**Tier:** mechanical

**Files:**
- Create: `scripts/compute-weekly-spent.sh`
- Create: `tests/claude-code/test-compute-weekly-spent.sh`

- [ ] **Step 1: Write the failing test** (`tests/claude-code/test-compute-weekly-spent.sh`)

```bash
#!/usr/bin/env bash
# Unit test for compute-weekly-spent.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/compute-weekly-spent.sh"

# shellcheck source=./test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

PASS=0
FAIL=0

# Create a fake costs.jsonl in a temp HOME
setup_mock_home() {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/.claude/metrics"
  echo "$tmp"
}

# Test 1: no costs.jsonl → weekly_spent_usd = 0, entries = 0
t1_dir=$(setup_mock_home)
out=$(HOME="$t1_dir" bash "$SCRIPT" 2>&1 | tail -1)
if echo "$out" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["weekly_spent_usd"] == 0; assert d["entries"] == 0; print("ok")' >/dev/null 2>&1; then
  echo "  [PASS] empty-state returns zeros"; PASS=$((PASS+1))
else
  echo "  [FAIL] empty-state returns zeros — got: $out"; FAIL=$((FAIL+1))
fi
rm -rf "$t1_dir"

# Test 2: two entries within window + one outside window (10 days ago) → only two count
t2_dir=$(setup_mock_home)
now_iso=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z"))')
past_iso=$(python3 -c 'import datetime,time; t=datetime.datetime.now(datetime.timezone.utc)-datetime.timedelta(days=10); print(t.isoformat().replace("+00:00","Z"))')
cat > "$t2_dir/.claude/metrics/costs.jsonl" <<EOF
{"timestamp":"$now_iso","estimated_cost_usd":1.50,"session_id":"a","model":"sonnet","input_tokens":0,"output_tokens":0}
{"timestamp":"$now_iso","estimated_cost_usd":2.25,"session_id":"b","model":"opus","input_tokens":0,"output_tokens":0}
{"timestamp":"$past_iso","estimated_cost_usd":99.00,"session_id":"c","model":"opus","input_tokens":0,"output_tokens":0}
EOF
out=$(HOME="$t2_dir" bash "$SCRIPT" 2>&1 | tail -1)
if echo "$out" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert abs(d["weekly_spent_usd"]-3.75)<0.01, d; assert d["entries"] == 2; print("ok")' >/dev/null 2>&1; then
  echo "  [PASS] window correctly excludes entries older than 7 days"; PASS=$((PASS+1))
else
  echo "  [FAIL] window inclusion — got: $out"; FAIL=$((FAIL+1))
fi
rm -rf "$t2_dir"

# Test 3: superpowers-budget.yaml with weekly_cap_usd attaches pct
t3_dir=$(setup_mock_home)
cat > "$t3_dir/.claude/metrics/costs.jsonl" <<EOF
{"timestamp":"$now_iso","estimated_cost_usd":50.00,"session_id":"a","model":"sonnet","input_tokens":0,"output_tokens":0}
EOF
cat > "$t3_dir/.claude/superpowers-budget.yaml" <<EOF
weekly_cap_usd: 200
EOF
out=$(HOME="$t3_dir" bash "$SCRIPT" 2>&1 | tail -1)
if echo "$out" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["weekly_cap_usd"] == 200; assert abs(d["pct"]-25.0)<0.01, d; print("ok")' >/dev/null 2>&1; then
  echo "  [PASS] pct computed against weekly_cap_usd"; PASS=$((PASS+1))
else
  echo "  [FAIL] pct computation — got: $out"; FAIL=$((FAIL+1))
fi
rm -rf "$t3_dir"

echo ""
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

```bash
chmod +x tests/claude-code/test-compute-weekly-spent.sh
bash tests/claude-code/test-compute-weekly-spent.sh
```

Expected: FAIL with "No such file or directory: scripts/compute-weekly-spent.sh" (or all three assertions fail).

- [ ] **Step 3: Write minimal implementation** (`scripts/compute-weekly-spent.sh`)

```bash
#!/usr/bin/env bash
# Compute weekly Claude Code spend from ~/.claude/metrics/costs.jsonl.
#
# Output: a single JSON line on stdout:
#   {"weekly_spent_usd": N, "window_days": D, "entries": E}
#   (+ "weekly_cap_usd" and "pct" when ~/.claude/superpowers-budget.yaml sets a cap)
#
# Usage:
#   scripts/compute-weekly-spent.sh [--window-days N]
#
# Exit codes:
#   0   succeeded (even if no data — emits zeros)
#   2   malformed superpowers-budget.yaml (missing or invalid weekly_cap_usd)

set -u

WINDOW_DAYS=7
while [[ $# -gt 0 ]]; do
  case "$1" in
    --window-days) WINDOW_DAYS="$2"; shift 2 ;;
    --help|-h)
      sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) echo "ERROR: unknown arg $1" >&2; exit 2 ;;
  esac
done

COSTS_FILE="${HOME}/.claude/metrics/costs.jsonl"
BUDGET_FILE="${HOME}/.claude/superpowers-budget.yaml"

python3 - "$COSTS_FILE" "$BUDGET_FILE" "$WINDOW_DAYS" <<'PY'
import json, os, sys, datetime, pathlib

costs_path = sys.argv[1]
budget_path = sys.argv[2]
window_days = int(sys.argv[3])

now = datetime.datetime.now(datetime.timezone.utc)
cutoff = now - datetime.timedelta(days=window_days)

total = 0.0
entries = 0
if os.path.isfile(costs_path):
    with open(costs_path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                rec = json.loads(line)
            except json.JSONDecodeError:
                continue
            ts_raw = rec.get("timestamp")
            cost = rec.get("estimated_cost_usd")
            if ts_raw is None or cost is None:
                continue
            try:
                ts = datetime.datetime.fromisoformat(ts_raw.replace("Z", "+00:00"))
            except ValueError:
                continue
            if ts >= cutoff:
                total += float(cost)
                entries += 1

out = {
    "weekly_spent_usd": round(total, 4),
    "window_days": window_days,
    "entries": entries,
}

if os.path.isfile(budget_path):
    # Minimal YAML parse: we only need `weekly_cap_usd: <number>` or `: null`.
    cap = None
    with open(budget_path) as f:
        for line in f:
            s = line.strip()
            if s.startswith("weekly_cap_usd:"):
                raw = s.split(":", 1)[1].strip()
                # strip inline comment
                if "#" in raw:
                    raw = raw.split("#", 1)[0].strip()
                if raw.lower() in ("null", "~", ""):
                    cap = None
                else:
                    try:
                        cap = float(raw)
                    except ValueError:
                        print(f"ERROR: malformed weekly_cap_usd in {budget_path}", file=sys.stderr)
                        sys.exit(2)
                break
    if cap is not None:
        out["weekly_cap_usd"] = cap
        out["pct"] = round((total / cap) * 100.0, 4) if cap > 0 else 0.0

print(json.dumps(out))
PY
```

- [ ] **Step 4: Run test to verify it passes**

```bash
chmod +x scripts/compute-weekly-spent.sh
bash tests/claude-code/test-compute-weekly-spent.sh
```

Expected: `passed: 3, failed: 0`.

- [ ] **Step 5: Commit**

```bash
git add scripts/compute-weekly-spent.sh tests/claude-code/test-compute-weekly-spent.sh
git commit -m "feat(scripts): add compute-weekly-spent.sh for weekly-pct budget"
```

---

### Task 2: `superpowers-budget.example.yaml`

**Tier:** mechanical

**Files:**
- Create: `config/superpowers-budget.example.yaml`

- [ ] **Step 1: Write the file**

```yaml
# Example ~/.claude/superpowers-budget.yaml
#
# Copy this file to ~/.claude/superpowers-budget.yaml and edit.
# Superpowers reads it to compute the percent-of-weekly budget used by
# scripts/run-plan-autonomous.sh (--budget-pct). Anthropic does not expose
# your plan's dollar cap via any API, so you write it here.

# Dollar cap for the rolling 7-day window. Set to null for unlimited mode
# (run-plan-autonomous.sh will refuse --budget-pct and require either
# --budget-cap-usd or unlimited mode explicitly).
weekly_cap_usd: 200

# Optional: change the rolling window. Default 7 days.
# window_days: 7
```

- [ ] **Step 2: Verify it parses as YAML**

```bash
python3 -c "import yaml; d=yaml.safe_load(open('config/superpowers-budget.example.yaml')); assert d['weekly_cap_usd']==200; print('ok')"
```

Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add config/superpowers-budget.example.yaml
git commit -m "feat(config): ship example superpowers-budget.yaml"
```

---

### Task 3: `goal-judge-prompt.md`

**Tier:** mechanical

**Files:**
- Create: `skills/subagent-driven-development/goal-judge-prompt.md`

- [ ] **Step 1: Write the prompt template**

```markdown
# Goal Judge Subagent Prompt Template

Use this template when dispatching a Goal Judge subagent. This is ONLY
dispatched when the plan's `final_goal.template == "custom"`. For every
other template, verification is programmatic (run a command, check exit
code) and no Goal Judge is needed.

The Goal Judge does NOT do a code review — that's the final code-reviewer
subagent's job. The Goal Judge only judges whether the natural-language
rationale has been satisfied by the implementation as it currently stands.

```
Task tool (general-purpose, model: sonnet):
  description: "Goal Judge: verify final_goal against current implementation"
  prompt: |
    You are the Goal Judge for an autonomous plan execution.

    ## Goal to verify (natural language)

    [final_goal.judge_rationale from plan frontmatter — paste verbatim]

    ## Plan (for context)

    [Full contents of docs/superpowers/plans/<plan>.md — paste, don't
    ask subagent to read a file]

    ## Completed commits in this plan's worktree

    [git log --oneline <base_sha>..HEAD — paste]

    ## Programmatic check outputs (if controller pre-ran any)

    [stdout/stderr of any verify_command / test runs / lint runs — paste.
    Say "(none run)" if nothing was pre-run.]

    ## Known deferred issues from decisions_log

    [Paste the decisions_log entries where decision=="deferred" or
    decision=="rejected" so you know what was consciously skipped]

    ## Your job

    Judge whether the goal is met. Rely on the evidence above; do not
    invent capabilities or assume things not shown. If the evidence is
    insufficient to decide, say so.

    ## Output Protocol (MACHINE-PARSEABLE HEADER REQUIRED)

    Emit EXACTLY these lines, in order, no preamble, no code fence:

    ```
    Verdict: met
    Confidence: high
    Rationale: <1-3 sentences justifying the verdict against the evidence>
    Gaps: (none)
    ---REPORT---
    <longer-form reasoning, observed evidence, what you checked>
    ```

    Rules:
    - Verdict: exactly one of `met` | `not_met` | `uncertain`
    - Confidence: exactly one of `high` | `medium` | `low`
    - Rationale: one paragraph, 1-3 sentences. Must cite specific evidence.
    - Gaps: comma-separated short phrases when Verdict is `not_met`, or
      `(none)` when met. Each gap should be addressable by a future task.
    - Use `uncertain` only when evidence is genuinely insufficient — NOT
      as a cop-out. `uncertain` triggers a NEEDS_HUMAN hard gate, so
      prefer `not_met` with specific Gaps when in doubt.
```
```

- [ ] **Step 2: Verify file is present and well-formed**

```bash
test -f skills/subagent-driven-development/goal-judge-prompt.md
grep -q "Verdict: met" skills/subagent-driven-development/goal-judge-prompt.md
grep -q "^# Goal Judge" skills/subagent-driven-development/goal-judge-prompt.md
echo "ok"
```

Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add skills/subagent-driven-development/goal-judge-prompt.md
git commit -m "feat(skills): add goal-judge-prompt for custom final_goal template"
```

---

### Task 4: `gap-analyzer-prompt.md`

**Tier:** mechanical

**Files:**
- Create: `skills/subagent-driven-development/gap-analyzer-prompt.md`

- [ ] **Step 1: Write the prompt template**

```markdown
# Gap Analyzer Subagent Prompt Template

Dispatched during the convergence loop when final_goal verification fails.
Input: everything that was attempted. Output: a YAML array of new tasks
that should close the gap, formatted so the controller can append them
to plan.md directly.

The gap analyzer MUST NOT rewrite existing tasks — only append new ones.
If it believes an existing task's spec was wrong, it adds a NEW task that
corrects the behavior; it never edits a completed task's body.

```
Task tool (general-purpose, model: sonnet):
  description: "Gap Analyzer: propose tasks to close final_goal gap"
  prompt: |
    You are the Gap Analyzer for an autonomous plan execution. All declared
    tasks reached terminal state but final_goal verification failed. Your
    job is to propose the MINIMUM set of new tasks that would close the gap.

    ## final_goal

    [final_goal yaml block from plan frontmatter — paste]

    ## Verify output (failing)

    [Exit code + stdout + stderr of the verify_command, OR the Goal Judge
    subagent's output. Paste verbatim.]

    ## Current plan

    [Full contents of docs/superpowers/plans/<plan>.md including all
    completed tasks and their Status markers]

    ## decisions_log (recent entries)

    [Last 20 entries from checkpoint.json decisions_log, so you see
    triage rejections, provider fallbacks, etc.]

    ## Rules

    1. Append-only. Never rewrite an existing task.
    2. Minimum set. One focused task is better than three speculative ones.
    3. Each new task must be independently implementable (clear spec,
       tier-appropriate, includes tests).
    4. If the gap is fundamentally un-fixable within the plan's scope
       (e.g. requires a dependency not available, requires user decision),
       output a single task with `tier: blocked_escalation` and an
       explanation — the controller will treat this as NEEDS_HUMAN.

    ## Output Protocol (MACHINE-PARSEABLE HEADER REQUIRED)

    Emit EXACTLY these lines, in order, no preamble, no code fence:

    ```
    Verdict: actionable
    Rationale: <1-3 sentences on the root cause of the gap>
    TaskCount: 2
    ---TASKS---
    - name: "Fix X import path"
      tier: mechanical
      rationale: "verify output shows ModuleNotFoundError for xyz"
      spec: |
        File: src/foo.py
        Change the import on line 12 from `from xyz import bar` to
        `from xyz.bar import bar`. Add a unit test importing the module
        cleanly to tests/test_foo.py.
    - name: "Add retry for transient DB error"
      tier: integration
      rationale: "verify output shows intermittent OperationalError from db"
      spec: |
        File: src/db.py
        Wrap the bare db.execute() calls in _retry_on_operational(3, ...)
        ... (full actionable spec)
    ---END---
    ```

    Rules:
    - Verdict: `actionable` when you can propose tasks; `unreachable`
      when the gap is outside plan scope.
    - TaskCount must match the number of entries under `---TASKS---`.
    - Each task's `tier` is `mechanical` | `integration` | `architecture`
      | `blocked_escalation`.
    - If `unreachable`, output `TaskCount: 0` and empty TASKS block.
```
```

- [ ] **Step 2: Verify file is present**

```bash
test -f skills/subagent-driven-development/gap-analyzer-prompt.md
grep -q "Verdict: actionable" skills/subagent-driven-development/gap-analyzer-prompt.md
echo "ok"
```

Expected: `ok`.

- [ ] **Step 3: Commit**

```bash
git add skills/subagent-driven-development/gap-analyzer-prompt.md
git commit -m "feat(skills): add gap-analyzer-prompt for convergence loop"
```

---

### Task 5: `run-plan-autonomous.sh` — budget flags + compute-weekly-spent integration

**Tier:** integration

**Files:**
- Modify: `scripts/run-plan-autonomous.sh`
- Create: `tests/claude-code/test-run-plan-autonomous-budget.sh`

- [ ] **Step 1: Write the failing test** (`tests/claude-code/test-run-plan-autonomous-budget.sh`)

```bash
#!/usr/bin/env bash
# Budget flag parsing + weekly-spend wiring test for run-plan-autonomous.sh
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/run-plan-autonomous.sh"

PASS=0; FAIL=0

# Fixture: tmp worktree with a minimal plan & fake costs
setup() {
  local tmp
  tmp=$(mktemp -d)
  mkdir -p "$tmp/docs/superpowers/plans" "$tmp/docs/superpowers/checkpoints"
  mkdir -p "$tmp/home/.claude/metrics"
  now_iso=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z"))')
  cat > "$tmp/home/.claude/metrics/costs.jsonl" <<EOF
{"timestamp":"$now_iso","estimated_cost_usd":50.00,"session_id":"a","model":"sonnet","input_tokens":0,"output_tokens":0}
EOF
  cat > "$tmp/home/.claude/superpowers-budget.yaml" <<EOF
weekly_cap_usd: 200
EOF
  cat > "$tmp/docs/superpowers/plans/dummy.md" <<'EOF'
---
plan_version: 1
final_goal: {template: all_tests_pass, verify_command: "true"}
status: in_progress
execution_mode: autonomous
current_task: 1
convergence_round: 0
checkpoint_pointer: docs/superpowers/checkpoints/dummy-checkpoint.json
autonomous_limits: {budget_pct: 30, max_convergence_rounds: 3, max_handoffs: 2, no_progress_abort_after: 2}
---
# Plan

## Task 1: dummy
**Tier:** mechanical
**Status:** done
EOF
  cat > "$tmp/docs/superpowers/checkpoints/dummy-checkpoint.json" <<'EOF'
{"tasks":[{"n":1,"status":"done"}]}
EOF
  echo "$tmp"
}

# Test 1: --budget-pct with plan under budget → allows run (dry-run continues)
t1=$(setup)
out=$(HOME="$t1/home" bash "$SCRIPT" "$t1/docs/superpowers/plans/dummy.md" --dry-run --budget-pct 30 --max-handoffs 1 2>&1)
if echo "$out" | grep -q "budget_pct=30"; then
  echo "  [PASS] --budget-pct flag is acknowledged in output"; PASS=$((PASS+1))
else
  echo "  [FAIL] --budget-pct not reflected — got:"; echo "$out" | head -5 | sed 's/^/    /'; FAIL=$((FAIL+1))
fi
rm -rf "$t1"

# Test 2: weekly spent exceeds cap → refuses with status=budget_exhausted
t2=$(setup)
# Bump cost to $100 (50% of $200) and cap budget-pct at 20% — should refuse
now_iso=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z"))')
cat > "$t2/home/.claude/metrics/costs.jsonl" <<EOF
{"timestamp":"$now_iso","estimated_cost_usd":100.00,"session_id":"a","model":"sonnet","input_tokens":0,"output_tokens":0}
EOF
out=$(HOME="$t2/home" bash "$SCRIPT" "$t2/docs/superpowers/plans/dummy.md" --dry-run --budget-pct 20 --max-handoffs 1 2>&1 || true)
if echo "$out" | grep -qE "budget.*(exceeded|exhausted)"; then
  echo "  [PASS] exceeds-cap refuses with budget-exhausted message"; PASS=$((PASS+1))
else
  echo "  [FAIL] exceeds-cap not detected — got:"; echo "$out" | head -5 | sed 's/^/    /'; FAIL=$((FAIL+1))
fi
rm -rf "$t2"

# Test 3: --budget-pct none → unlimited, no check
t3=$(setup)
out=$(HOME="$t3/home" bash "$SCRIPT" "$t3/docs/superpowers/plans/dummy.md" --dry-run --budget-pct none --max-handoffs 1 2>&1)
if echo "$out" | grep -q "budget_pct=unlimited"; then
  echo "  [PASS] --budget-pct none reads as unlimited"; PASS=$((PASS+1))
else
  echo "  [FAIL] --budget-pct none not recognized — got:"; echo "$out" | head -5 | sed 's/^/    /'; FAIL=$((FAIL+1))
fi
rm -rf "$t3"

# Test 4: --max-cost still works but warns deprecation
t4=$(setup)
out=$(HOME="$t4/home" bash "$SCRIPT" "$t4/docs/superpowers/plans/dummy.md" --dry-run --max-cost 50 --max-handoffs 1 2>&1)
if echo "$out" | grep -qi "deprecated"; then
  echo "  [PASS] --max-cost emits deprecation warning"; PASS=$((PASS+1))
else
  echo "  [FAIL] --max-cost deprecation warning missing — got:"; echo "$out" | head -5 | sed 's/^/    /'; FAIL=$((FAIL+1))
fi
rm -rf "$t4"

echo ""
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

```bash
chmod +x tests/claude-code/test-run-plan-autonomous-budget.sh
bash tests/claude-code/test-run-plan-autonomous-budget.sh
```

Expected: all 4 FAIL (script doesn't understand new flags yet).

- [ ] **Step 3: Modify `scripts/run-plan-autonomous.sh` — replace arg parsing + add pre-flight**

Find the existing `# ---- defaults ----` block and the arg-parsing `while [[ $# -gt 0 ]]` block. Replace them with:

```bash
# ---- defaults ----
BUDGET_PCT=""                  # empty = unset, "none" = unlimited, or number 1-100
BUDGET_CAP_USD=""              # empty = unset; overrides percent when set
MAX_COST_USD=""                # deprecated; still parsed but treated as budget-cap-usd + warning
MAX_HANDOFFS=10
NO_PROGRESS_ABORT=2
LOG_DIR=""
DRY_RUN=0
INPUT=""

# ---- arg parsing ----
while [[ $# -gt 0 ]]; do
  case "$1" in
    --budget-pct)          BUDGET_PCT="$2"; shift 2 ;;
    --budget-cap-usd)      BUDGET_CAP_USD="$2"; shift 2 ;;
    --max-cost)            MAX_COST_USD="$2"; shift 2 ;;
    --max-handoffs)        MAX_HANDOFFS="$2"; shift 2 ;;
    --no-progress-abort)   NO_PROGRESS_ABORT="$2"; shift 2 ;;
    --log-dir)             LOG_DIR="$2"; shift 2 ;;
    --dry-run)             DRY_RUN=1; shift ;;
    -h|--help)             usage 0 ;;
    -*)                    echo "ERROR: unknown option $1" >&2; usage 3 ;;
    *)
      if [[ -z "$INPUT" ]]; then INPUT="$1"; shift
      else echo "ERROR: multiple positional args" >&2; usage 3
      fi ;;
  esac
done

# Handle deprecated --max-cost: treat as --budget-cap-usd, warn.
if [[ -n "$MAX_COST_USD" ]]; then
  echo "[deprecated] --max-cost is deprecated; treating as --budget-cap-usd $MAX_COST_USD. Prefer --budget-pct against ~/.claude/superpowers-budget.yaml. --max-cost will be removed in 7.0.0." >&2
  if [[ -z "$BUDGET_CAP_USD" ]]; then
    BUDGET_CAP_USD="$MAX_COST_USD"
  fi
fi

# Reject conflicting budget inputs
if [[ -n "$BUDGET_PCT" && -n "$BUDGET_CAP_USD" ]]; then
  echo "ERROR: --budget-pct and --budget-cap-usd are mutually exclusive" >&2
  exit 3
fi
```

- [ ] **Step 4: Add a budget-check helper near the other helpers**

Insert just after the `_count_with_status` helper block:

```bash
# ---- budget helpers ----
# Emit one line: "budget_pct=<n>|none|unset; cap=<usd>|unset; spent=<usd>; limit=<usd>|inf"
# Returns 0 if run should proceed, 1 if over budget.
check_budget() {
  local pct="$1" cap="$2"
  local spent limit_usd
  local weekly_json
  weekly_json=$(bash "$(dirname "${BASH_SOURCE[0]}")/compute-weekly-spent.sh" 2>/dev/null || echo '{"weekly_spent_usd":0}')
  spent=$(echo "$weekly_json" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("weekly_spent_usd",0))')

  if [[ "$pct" == "none" ]]; then
    echo "[budget] budget_pct=unlimited cap=unset spent=\$$spent limit=inf"
    return 0
  elif [[ -n "$pct" ]]; then
    local cap_usd
    cap_usd=$(echo "$weekly_json" | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); print(d.get("weekly_cap_usd",""))')
    if [[ -z "$cap_usd" ]]; then
      echo "ERROR: --budget-pct requires weekly_cap_usd in ~/.claude/superpowers-budget.yaml" >&2
      return 1
    fi
    limit_usd=$(python3 -c "print($cap_usd * $pct / 100.0)")
    echo "[budget] budget_pct=$pct cap=\$$cap_usd spent=\$$spent limit=\$$limit_usd"
    if (( $(python3 -c "print(1 if $spent >= $limit_usd else 0)") )); then
      echo "[budget] ❌ weekly spend \$$spent exceeded limit \$$limit_usd (budget_pct=$pct of cap \$$cap_usd) — plan status = budget_exhausted" >&2
      return 1
    fi
    return 0
  elif [[ -n "$cap" ]]; then
    echo "[budget] budget_pct=unset cap=\$$cap spent=\$$spent limit=\$$cap"
    if (( $(python3 -c "print(1 if $spent >= $cap else 0)") )); then
      echo "[budget] ❌ weekly spend \$$spent exceeded cap \$$cap — plan status = budget_exhausted" >&2
      return 1
    fi
    return 0
  else
    # No budget constraint set → behave like unlimited (legacy default 20 USD is gone)
    echo "[budget] budget_pct=unset cap=unset spent=\$$spent limit=inf"
    return 0
  fi
}
```

- [ ] **Step 5: Wire `check_budget` into the loop (before each spawn)**

Find the `while [[ $SESSION_N -lt $MAX_HANDOFFS ]]; do` loop. Right after `SESSION_N=$((SESSION_N + 1))` and BEFORE the "Completion check" block, insert:

```bash
  # Budget gate — runs every iteration
  if ! check_budget "$BUDGET_PCT" "$BUDGET_CAP_USD" >&2; then
    exit 1
  fi
```

Also, find the old `REMAINING_BUDGET` + `per_session_budget` + `--max-budget-usd` logic in the spawn block and **remove it** — the new budget check at top of loop supersedes it. (Per-session budget to `claude -p --max-budget-usd` becomes optional; only pass it when `--budget-cap-usd` was explicit, to keep the hard cap in the child session too.)

Replace the `SUPERPOWERS_AUTONOMOUS_LOOP=1 claude -p ...` block with:

```bash
  per_session_budget=""
  if [[ -n "$BUDGET_CAP_USD" ]]; then
    # Divide remaining cap across remaining handoffs (floor $1).
    remaining=$((MAX_HANDOFFS - SESSION_N + 1))
    per_session_budget=$(python3 -c "print(max(1.0, ($BUDGET_CAP_USD - ${SPENT_SO_FAR:-0}) / $remaining))")
  fi

  echo "[autonomous-loop] session $SESSION_N/$MAX_HANDOFFS: uuid=$SESSION_UUID log=$LOG_FILE${per_session_budget:+ budget=\$$per_session_budget}" >&2

  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[dry-run] would spawn: claude -p --session-id $SESSION_UUID ${per_session_budget:+--max-budget-usd $per_session_budget} --dangerously-skip-permissions --output-format stream-json -- '$INITIAL_PROMPT'" >&2
  else
    local claude_args=(-p --session-id "$SESSION_UUID" --dangerously-skip-permissions --output-format stream-json --include-partial-messages)
    if [[ -n "$per_session_budget" ]]; then
      claude_args+=(--max-budget-usd "$per_session_budget")
    fi
    SUPERPOWERS_AUTONOMOUS_LOOP=1 \
      claude "${claude_args[@]}" -- "$INITIAL_PROMPT" \
      > "$LOG_FILE" 2>&1 || {
        rc=$?
        echo "[autonomous-loop] session $SESSION_N exited rc=$rc (may be budget-limit; continuing to inspect checkpoint)" >&2
      }
  fi
```

Also remove the trailing `REMAINING_BUDGET` bookkeeping lines after the inspect block — the budget gate now runs at the top of each iteration, making the trailing subtract redundant.

- [ ] **Step 6: Run test to verify it passes**

```bash
bash tests/claude-code/test-run-plan-autonomous-budget.sh
```

Expected: `passed: 4, failed: 0`.

- [ ] **Step 7: Re-run the existing autonomous-loop dry-run to ensure no regression**

```bash
tmp=$(mktemp -d) && mkdir -p "$tmp/docs/superpowers/checkpoints"
echo '{"tasks":[{"n":1,"status":"done"},{"n":2,"status":"done"}]}' > "$tmp/docs/superpowers/checkpoints/done-checkpoint.json"
bash scripts/run-plan-autonomous.sh "$tmp/docs/superpowers/checkpoints/done-checkpoint.json" --dry-run
rm -rf "$tmp"
```

Expected: `[autonomous-loop] ✅ plan complete (2/2 tasks). total sessions: 0` and exit 0.

- [ ] **Step 8: Commit**

```bash
git add scripts/run-plan-autonomous.sh tests/claude-code/test-run-plan-autonomous-budget.sh
git commit -m "feat(autonomous): weekly-pct budget, deprecate --max-cost, wire compute-weekly-spent"
```

---

### Task 6: `run-plan-autonomous.sh` — plan.md frontmatter parsing

**Tier:** integration

**Files:**
- Modify: `scripts/run-plan-autonomous.sh`
- Modify: `tests/claude-code/test-run-plan-autonomous-budget.sh` (add one test)

- [ ] **Step 1: Extend the test** (append before the final `echo "passed: ..."` line)

```bash
# Test 5: plan frontmatter provides autonomous_limits; CLI --max-handoffs overrides
t5=$(setup)
# frontmatter already says max_handoffs: 2 (from setup's fixture); CLI should win when provided
out=$(HOME="$t5/home" bash "$SCRIPT" "$t5/docs/superpowers/plans/dummy.md" --dry-run --budget-pct none --max-handoffs 7 2>&1 || true)
if echo "$out" | grep -q "max_handoffs=7"; then
  echo "  [PASS] CLI --max-handoffs overrides frontmatter"; PASS=$((PASS+1))
else
  echo "  [FAIL] frontmatter/cli precedence — got:"; echo "$out" | head -5 | sed 's/^/    /'; FAIL=$((FAIL+1))
fi
rm -rf "$t5"

# Test 6: without CLI override, frontmatter's autonomous_limits.max_handoffs wins
t6=$(setup)
out=$(HOME="$t6/home" bash "$SCRIPT" "$t6/docs/superpowers/plans/dummy.md" --dry-run --budget-pct none 2>&1 || true)
if echo "$out" | grep -q "max_handoffs=2"; then
  echo "  [PASS] frontmatter max_handoffs=2 used when CLI omits"; PASS=$((PASS+1))
else
  echo "  [FAIL] frontmatter default not honored — got:"; echo "$out" | head -5 | sed 's/^/    /'; FAIL=$((FAIL+1))
fi
rm -rf "$t6"
```

Update the final failure check's expected count: `passed: 6, failed: 0`.

- [ ] **Step 2: Run test to verify new assertions fail**

```bash
bash tests/claude-code/test-run-plan-autonomous-budget.sh
```

Expected: 4 PASS, 2 FAIL (the new 5 & 6 fail because no frontmatter parsing yet).

- [ ] **Step 3: Add a frontmatter parser helper and integrate**

Near the other helpers, add:

```bash
# ---- plan.md frontmatter helpers ----
# Read a single scalar key from plan.md YAML frontmatter (top-level or
# nested one level deep via "parent.key"). Empty string if absent.
read_plan_frontmatter() {
  local plan="$1" key="$2"
  python3 - "$plan" "$key" <<'PY' 2>/dev/null
import sys, re, os
plan_path, key = sys.argv[1], sys.argv[2]
if not os.path.isfile(plan_path):
    sys.exit(0)
with open(plan_path) as f:
    text = f.read()
m = re.match(r"^---\n(.*?)\n---\n", text, re.DOTALL)
if not m:
    sys.exit(0)
fm = m.group(1)
try:
    import yaml
    data = yaml.safe_load(fm) or {}
except Exception:
    # Fallback: super-simple line grep for top-level scalar or nested "a.b: v"
    data = {}
    for line in fm.splitlines():
        s = line.strip()
        if s and not s.startswith("#") and ":" in s and not line.startswith(" "):
            k, _, v = s.partition(":")
            data[k.strip()] = v.strip()
# Walk dotted key
cur = data
for part in key.split("."):
    if isinstance(cur, dict) and part in cur:
        cur = cur[part]
    else:
        sys.exit(0)
if cur is None:
    sys.exit(0)
print(cur)
PY
}
```

- [ ] **Step 4: Use frontmatter when available**

Right after the `INPUT` has been validated and resolved to `CHECKPOINT` path, but BEFORE the main loop, add:

```bash
# Plan-frontmatter override of autonomous_limits (CLI flags still win)
PLAN_FILE=""
case "$INPUT" in
  *.md) PLAN_FILE="$INPUT" ;;
  *)
    # Try to derive plan from checkpoint's plan_path field
    if [[ -f "$CHECKPOINT" ]] && command -v python3 >/dev/null 2>&1; then
      PLAN_FILE=$(python3 -c "import json,sys; d=json.load(open(sys.argv[1])); print(d.get('plan_path',''))" "$CHECKPOINT" 2>/dev/null || echo "")
    fi
    ;;
esac

if [[ -n "$PLAN_FILE" && -f "$PLAN_FILE" ]]; then
  # Only apply when the user did NOT pass the corresponding CLI flag.
  if [[ "$MAX_HANDOFFS" == "10" ]]; then
    fm_val=$(read_plan_frontmatter "$PLAN_FILE" "autonomous_limits.max_handoffs")
    [[ -n "$fm_val" ]] && MAX_HANDOFFS="$fm_val"
  fi
  if [[ "$NO_PROGRESS_ABORT" == "2" ]]; then
    fm_val=$(read_plan_frontmatter "$PLAN_FILE" "autonomous_limits.no_progress_abort_after")
    [[ -n "$fm_val" ]] && NO_PROGRESS_ABORT="$fm_val"
  fi
  if [[ -z "$BUDGET_PCT" && -z "$BUDGET_CAP_USD" ]]; then
    fm_val=$(read_plan_frontmatter "$PLAN_FILE" "autonomous_limits.budget_pct")
    [[ -n "$fm_val" ]] && BUDGET_PCT="$fm_val"
    fm_val=$(read_plan_frontmatter "$PLAN_FILE" "autonomous_limits.budget_cap_usd")
    [[ -n "$fm_val" ]] && BUDGET_CAP_USD="$fm_val"
  fi
fi

echo "[autonomous-loop] effective limits: max_handoffs=$MAX_HANDOFFS no_progress_abort=$NO_PROGRESS_ABORT budget_pct=${BUDGET_PCT:-unset} budget_cap_usd=${BUDGET_CAP_USD:-unset}" >&2
```

- [ ] **Step 5: Run test**

```bash
bash tests/claude-code/test-run-plan-autonomous-budget.sh
```

Expected: `passed: 6, failed: 0`.

- [ ] **Step 6: Commit**

```bash
git add scripts/run-plan-autonomous.sh tests/claude-code/test-run-plan-autonomous-budget.sh
git commit -m "feat(autonomous): read autonomous_limits from plan.md frontmatter; CLI overrides"
```

---

### Task 7: `run-plan-autonomous.sh` — extended exit codes + state writeback

**Tier:** integration

**Files:**
- Modify: `scripts/run-plan-autonomous.sh`
- Modify: `tests/claude-code/test-run-plan-autonomous-budget.sh` (add one test)

- [ ] **Step 1: Extend the test**

Add at the end (before the final `echo passed:`):

```bash
# Test 7: on budget-exhausted exit, frontmatter.status becomes "budget_exhausted"
t7=$(setup)
now_iso=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z"))')
cat > "$t7/home/.claude/metrics/costs.jsonl" <<EOF
{"timestamp":"$now_iso","estimated_cost_usd":150.00,"session_id":"x","model":"sonnet","input_tokens":0,"output_tokens":0}
EOF
HOME="$t7/home" bash "$SCRIPT" "$t7/docs/superpowers/plans/dummy.md" --dry-run --budget-pct 20 --max-handoffs 1 2>&1 >/dev/null || true
got=$(python3 -c "
import re
t = open('$t7/docs/superpowers/plans/dummy.md').read()
m = re.search(r'^status:\s*(\S+)', t, re.MULTILINE)
print(m.group(1) if m else 'unset')
")
if [[ "$got" == "budget_exhausted" ]]; then
  echo "  [PASS] frontmatter.status written as budget_exhausted on exit"; PASS=$((PASS+1))
else
  echo "  [FAIL] frontmatter.status = $got (want budget_exhausted)"; FAIL=$((FAIL+1))
fi
rm -rf "$t7"
```

Update expected count to `passed: 7, failed: 0`.

- [ ] **Step 2: Run test (expect new assertion to fail)**

```bash
bash tests/claude-code/test-run-plan-autonomous-budget.sh
```

Expected: 6 PASS, 1 FAIL.

- [ ] **Step 3: Add a frontmatter-status writer + wire into every exit branch**

Add helper next to `read_plan_frontmatter`:

```bash
# Update frontmatter.status in plan.md (top-level key). Silently no-op if
# plan doesn't have a frontmatter block.
write_plan_status() {
  local plan="$1" new_status="$2"
  [[ -z "$plan" || ! -f "$plan" ]] && return 0
  python3 - "$plan" "$new_status" <<'PY'
import sys, re
plan_path, new_status = sys.argv[1], sys.argv[2]
with open(plan_path) as f:
    text = f.read()
m = re.match(r"^(---\n)(.*?)(\n---\n)(.*)$", text, re.DOTALL)
if not m:
    sys.exit(0)
head_open, fm, head_close, body = m.groups()
# Replace an existing top-level `status:` line or append one.
if re.search(r"^status:\s*\S", fm, re.MULTILINE):
    fm = re.sub(r"^status:\s*\S+.*$", f"status: {new_status}", fm, count=1, flags=re.MULTILINE)
else:
    fm = fm.rstrip() + f"\nstatus: {new_status}\n"
with open(plan_path, "w") as f:
    f.write(head_open + fm + head_close + body)
PY
}

# Helper: terminate the loop with a named plan status + exit code + log
terminate_loop() {
  local status="$1" exit_code="$2" reason="$3"
  echo "[autonomous-loop] terminating: status=$status — $reason" >&2
  write_plan_status "$PLAN_FILE" "$status"
  exit "$exit_code"
}
```

- [ ] **Step 4: Replace completion check with frontmatter-status reader**

The outer script must NOT mark a plan `goal_met` just because all tasks are
done — `goal_met` is the controller's call after it runs convergence
verification. The outer script only **propagates** terminal states the
controller has already written.

Find the existing "Completion check (before spawning — if already done, exit
clean)" block and REPLACE it with:

```bash
  # Terminal-state propagation: read controller-written frontmatter.status.
  # Any terminal value → map to exit code and stop.
  if [[ -n "$PLAN_FILE" && -f "$PLAN_FILE" ]]; then
    fm_status=$(read_plan_frontmatter "$PLAN_FILE" "status" 2>/dev/null)
    case "$fm_status" in
      goal_met)             terminate_loop "goal_met" 0 "controller marked final_goal met" ;;
      goal_not_met)         terminate_loop "goal_not_met" 1 "controller marked final_goal unreachable within bound" ;;
      budget_exhausted)     terminate_loop "budget_exhausted" 1 "controller marked budget exhausted" ;;
      stalled)              terminate_loop "stalled" 1 "controller marked stalled" ;;
      blocked|judge_uncertain|review_contradiction|main_branch_gate)
                            terminate_loop "$fm_status" 2 "controller hard gate: $fm_status" ;;
      ""|not_started|in_progress) : ;;  # continue
      *)                    echo "[autonomous-loop] unknown frontmatter.status='$fm_status', continuing" >&2 ;;
    esac
  fi

  # Legacy fallback: no plan frontmatter (6.0.0 checkpoint-only plans).
  # All tasks done AND no frontmatter to consult → terminate as goal_met
  # (best-effort legacy behavior; 6.1.0 plans don't hit this branch).
  if [[ -z "$PLAN_FILE" || ! -f "$PLAN_FILE" ]]; then
    if [[ -f "$CHECKPOINT" ]]; then
      done_n=$(count_done_tasks)
      total_n=$(count_total_tasks)
      if [[ $total_n -gt 0 && $done_n -ge $total_n ]]; then
        terminate_loop "goal_met" 0 "legacy: all tasks done (no frontmatter to verify)"
      fi
    fi
  fi
```

Other `exit` statements get swapped per this table:

| Before | After |
|---|---|
| `exit 1` after budget check fails | `terminate_loop "budget_exhausted" 1 "weekly budget exceeded"` |
| `exit 2` after NEEDS_HUMAN detected | `terminate_loop "blocked" 2 "NEEDS_HUMAN.txt detected"` |
| `exit 1` after "no checkpoint written" | `terminate_loop "stalled" 1 "first session produced no checkpoint"` |
| `exit 1` after no-progress abort | `terminate_loop "stalled" 1 "no new tasks completed in $NO_PROGRESS_ABORT handoffs"` |
| `exit 1` after "reached max_handoffs" | `terminate_loop "stalled" 1 "reached max_handoffs=$MAX_HANDOFFS without finishing"` |
| `exit 130` in cleanup trap | keep as-is (user interrupt; don't claim "stalled") |

Also update the `check_budget` return-1 path in the outer loop:

```bash
  if ! check_budget "$BUDGET_PCT" "$BUDGET_CAP_USD" >&2; then
    terminate_loop "budget_exhausted" 1 "check_budget failed pre-flight"
  fi
```

- [ ] **Step 5: Run tests**

```bash
bash tests/claude-code/test-run-plan-autonomous-budget.sh
bash tests/claude-code/test-compute-weekly-spent.sh
```

Expected: both report `failed: 0`.

- [ ] **Step 6: Regression check on the completion path**

```bash
tmp=$(mktemp -d) && mkdir -p "$tmp/docs/superpowers/plans" "$tmp/docs/superpowers/checkpoints"
cat > "$tmp/docs/superpowers/plans/x.md" <<'EOF'
---
plan_version: 1
status: in_progress
---
# x
EOF
echo '{"tasks":[{"n":1,"status":"done"}],"plan_path":"'"$tmp"'/docs/superpowers/plans/x.md"}' > "$tmp/docs/superpowers/checkpoints/x-checkpoint.json"
bash scripts/run-plan-autonomous.sh "$tmp/docs/superpowers/checkpoints/x-checkpoint.json" --dry-run --budget-pct none
grep "^status:" "$tmp/docs/superpowers/plans/x.md"
rm -rf "$tmp"
```

Expected: `status: goal_met`.

- [ ] **Step 7: Commit**

```bash
git add scripts/run-plan-autonomous.sh tests/claude-code/test-run-plan-autonomous-budget.sh
git commit -m "feat(autonomous): extended termination statuses written back to plan.md"
```

---

### Task 8: `subagent-driven-development/SKILL.md` — Plan Start Init with 7 templates

**Tier:** integration

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md`

- [ ] **Step 1: Locate the current `## Plan Start Initialization` section**

```bash
grep -n "^## Plan Start Initialization" skills/subagent-driven-development/SKILL.md
```

Expected: one line match (currently around line 118).

- [ ] **Step 2: Replace the section body with the 7-template version**

Replace the entire `## Plan Start Initialization (one-time ask, first run only)` section up through (but not including) the next `##` heading, with:

````markdown
## Plan Start Initialization (one-time ask, first run only)

Before Reviewer B / provider detection, **on the very first run for a
plan** (no existing frontmatter with `plan_version` AND no existing
checkpoint), the controller asks the user ONE (possibly multi-part)
AskUserQuestion. Skip entirely when:

- Plan.md already has `plan_version` in frontmatter — reuse it.
- `SUPERPOWERS_AUTONOMOUS_LOOP=1` is set — the outer script already chose.
- A valid checkpoint exists — resume path.

### Question 1 — execution mode

> "Execution mode for this plan?"
> - **Interactive** (default): emit Resume Prompt at handoff; you resume manually.
> - **Autonomous**: `scripts/run-plan-autonomous.sh` drives iterations to completion.

### Question 2 — final_goal template (required)

> "What is the final goal for this plan, and how should it be verified?"

Seven templates plus `custom`:

| Template | User supplies | Verification |
|---|---|---|
| `all_tests_pass` | `verify_command` (e.g. `pytest -q`) | Run; exit 0 ⇒ met. |
| `code_review_clean` | — | Final code-reviewer must return no Critical/Important. |
| `verify_command_zero` | `verify_command` | Generic: run; exit 0 ⇒ met. |
| `deploy_success` | `deploy_command`, `health_check_command` | Both must exit 0. |
| `canary_clean` | `canary_command`, `canary_duration_sec` (default 300) | Command runs for duration; exit 0. |
| `metrics_met` | `metric_query_command`, `assertion` (shell expr) | `metric_query_command | assertion` exits 0. |
| `custom` | `judge_rationale` (one sentence) | Goal Judge subagent (see `./goal-judge-prompt.md`). |

Record the chosen template and its params in plan frontmatter under
`final_goal:`. For programmatic templates (everything but `custom`) the
verification is a shell command; for `custom` it is a subagent dispatch.

### Question 3 — autonomous-only limits

Only when the user chose autonomous mode, ask:

> "Autonomous run limits (defaults in parens):"
> - `budget_pct` (30) — % of weekly cap from `~/.claude/superpowers-budget.yaml`. `none` for unlimited.
> - `max_convergence_rounds` (3) — times the convergence loop can append fresh tasks.
> - `max_handoffs` (10) — hard cap on session spawns.
> - `no_progress_abort_after` (2) — stop if N handoffs produce zero new `done` tasks.

Write all answers into plan frontmatter:

```yaml
---
plan_version: 1
final_goal:
  template: all_tests_pass
  verify_command: "pytest -q"
status: in_progress
execution_mode: autonomous
current_task: 1
convergence_round: 0
last_handoff: {pct: 0, ts: null}
checkpoint_pointer: docs/superpowers/checkpoints/<basename>-checkpoint.json
autonomous_limits:
  budget_pct: 30
  max_convergence_rounds: 3
  max_handoffs: 10
  no_progress_abort_after: 2
---
```

If the user chose Interactive, omit `autonomous_limits`.

````

- [ ] **Step 3: Verify the edit**

```bash
grep -n "### Question 1" skills/subagent-driven-development/SKILL.md
grep -c "all_tests_pass\|code_review_clean\|verify_command_zero\|deploy_success\|canary_clean\|metrics_met\|custom" skills/subagent-driven-development/SKILL.md
```

Expected: question-1 grep hits; template token count ≥ 7.

- [ ] **Step 4: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md
git commit -m "feat(sdd): Plan Start Init prompts for final_goal template + autonomous limits"
```

---

### Task 9: `subagent-driven-development/SKILL.md` — per-task plan.md dual-write

**Tier:** integration

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md`

- [ ] **Step 1: Find the existing "Checkpoint Integration" section**

```bash
grep -n "^## Checkpoint Integration" skills/subagent-driven-development/SKILL.md
```

- [ ] **Step 2: Append a new sub-section at the end of Checkpoint Integration**

Right before the next `^## ` heading, append:

````markdown

### Dual-write protocol (plan.md + checkpoint.json)

Execution state lives in two files now; every state transition touches BOTH.

**On each task's final approval** (all 3 review stages ✅):

1. **Write checkpoint.json** (authoritative, structured). Update
   `tasks[n]` with `status: done`, `commit`, `provider_used`,
   `triage_decisions`; append to `decisions_log`; update `todos`.
2. **Edit plan.md** (human-readable view):
   - Under `## Task N`, change `**Status:** in_progress` →
     `**Status:** done` (or add the line if missing).
   - Append `**Commit:** <sha>` and `**Provider:** <provider>/<model>`
     underneath the Status line if not already present.
   - In frontmatter, set `current_task: N+1` and
     `last_handoff: {pct: <estimate>, ts: <ISO>}`.

**On BLOCKED** (all providers in tier chain exhausted):

1. checkpoint.json records the blocker detail.
2. plan.md `## Task N`: `**Status:** blocked` + `**Blocker:** <short reason>`.
3. Autonomous mode additionally writes `NEEDS_HUMAN.txt` and exits.

**Atomicity:** checkpoint first, then plan.md. If the plan.md edit fails
(permissions, unexpected content), the checkpoint still has authoritative
state; on next resume, rebuild plan.md frontmatter from the checkpoint's
`tasks` array.

**Never** edit plan.md's human-authored body (the task spec, the prose
intro, the success criteria) — only the frontmatter scalar fields and the
per-task `**Status:**` / `**Commit:**` / `**Provider:**` / `**Blocker:**`
metadata lines.
````

- [ ] **Step 3: Verify content landed**

```bash
grep -c "Dual-write protocol" skills/subagent-driven-development/SKILL.md
grep -c "Never.*edit plan.md's human-authored" skills/subagent-driven-development/SKILL.md
```

Expected: each ≥ 1.

- [ ] **Step 4: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md
git commit -m "feat(sdd): document dual-write plan.md + checkpoint.json per task"
```

---

### Task 10: `subagent-driven-development/SKILL.md` — convergence loop + hard-gate matrix update

**Tier:** integration

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md`

- [ ] **Step 1: Insert a new `## Convergence Loop` section after Checkpoint Integration**

```bash
grep -n "^## When to Escalate" skills/subagent-driven-development/SKILL.md
```

Insert just BEFORE that `## When to Escalate` heading:

````markdown
## Convergence Loop

Triggered when **all** tasks reach a terminal state (`done`, `deferred`,
or `superseded`) — `blocked` is NOT terminal; a blocked task is its own
hard gate (see below).

```
CONVERGENCE_LOOP:
  # Step 1 — verify final_goal
  case plan.final_goal.template:
    programmatic ({all_tests_pass, verify_command_zero, deploy_success,
                  canary_clean, metrics_met}):
      run the appropriate command(s); capture exit + stdout+stderr tail.
    code_review_clean:
      reuse the final code-reviewer's output already recorded in
      decisions_log; verdict = no Critical/Important ⇒ met.
    custom:
      dispatch Goal Judge subagent (./goal-judge-prompt.md).

  append decisions_log entry: stage=final_goal_verification,
    outcome={met|not_met|uncertain}, evidence=<tail>

  # Step 2 — act on verdict
  if met:
    frontmatter.status = goal_met; terminate 0.
  if uncertain:   # only custom template can produce this
    write NEEDS_HUMAN.txt; frontmatter.status = judge_uncertain;
    terminate 2.
  # else: not_met

  # Step 3 — convergence bounds
  convergence_round += 1
  if convergence_round > max_convergence_rounds:
    frontmatter.status = goal_not_met; write conclusion to decisions_log
    (include last verify output + suggested next step); terminate 1.
  if budget check would fail for even one more task:
    frontmatter.status = budget_exhausted; terminate 1.

  # Step 4 — gap analysis
  dispatch Gap Analyzer subagent (./gap-analyzer-prompt.md)
    inputs: final_goal, last verify output, full plan.md,
            last 20 decisions_log entries
  parse output:
    Verdict: actionable | unreachable
    TaskCount: N
    tasks: [{name, tier, rationale, spec}, ...]
  if Verdict == unreachable:
    write NEEDS_HUMAN.txt; frontmatter.status = goal_not_met;
    include analyzer rationale; terminate 2.

  # Step 5 — append tasks
  for each new task:
    append `## Task X: <name>` to plan.md with
      **Tier:** <tier>
      **Status:** pending
      **Rationale:** <analyzer rationale>
      <spec body>
  frontmatter.current_task = first new task number
  no_progress_count = 0    # convergence counts as progress

  # Step 6 — re-enter main subagent-driven-development loop
  dispatch implementer for the new current_task; three-stage review;
  eventually re-enter CONVERGENCE_LOOP.
```

**Why gap analyzer is a subagent, not the controller itself:** the
controller's context is full of review history from the prior tasks; a
fresh subagent sees the situation cleanly and is less likely to propose
tasks that rehash already-rejected triage decisions.

**Why `no_progress_count` resets on convergence:** the stall guard is to
catch "dispatched tasks but none completed" — convergence-added tasks
are legitimate new progress, not a stall.

````

- [ ] **Step 2: Replace the hard-gate table in `## When to Escalate`**

Find the existing "The controller asks the user ONLY in these cases" block
inside `## When to Escalate` and replace the bullet list with:

```markdown
### Hard-gate termination matrix

| Trigger | `frontmatter.status` | exit | Outputs |
|---|---|---|---|
| final_goal met | `goal_met` | 0 | Summary line + final verify output |
| Convergence rounds exhausted, not_met | `goal_not_met` | 1 | Last-round gap analyzer rationale |
| Weekly budget (pct or cap) exceeded | `budget_exhausted` | 1 | Spend summary |
| No-progress abort | `stalled` | 1 | Last `done` timestamp, counters |
| Task BLOCKED with providers exhausted | `blocked` | 2 | NEEDS_HUMAN.txt with blocker |
| Goal Judge returns `uncertain` | `judge_uncertain` | 2 | NEEDS_HUMAN.txt with judge output |
| Reviewer A/B contradict on Critical | `review_contradiction` | 2 | NEEDS_HUMAN.txt with both reviewer outputs |
| main/master operation proposed | `main_branch_gate` | 2 | NEEDS_HUMAN.txt with proposed action |

Interactive mode: all `exit 2` (NEEDS_HUMAN) cases ask the user via
AskUserQuestion instead of writing the file. All `exit 1` cases still emit
a summary to stdout. `exit 0` is the success path.

Autonomous mode: all `exit 2` cases write `NEEDS_HUMAN.txt` and the outer
`run-plan-autonomous.sh` stops the loop. The user inspects the file and
decides whether to resume.
```

- [ ] **Step 3: Verify both edits**

```bash
grep -c "^## Convergence Loop" skills/subagent-driven-development/SKILL.md
grep -c "### Hard-gate termination matrix" skills/subagent-driven-development/SKILL.md
grep -c "goal_not_met\|judge_uncertain\|review_contradiction\|main_branch_gate" skills/subagent-driven-development/SKILL.md
```

Expected: convergence section = 1, hard-gate table = 1, status tokens ≥ 4.

- [ ] **Step 4: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md
git commit -m "feat(sdd): convergence loop protocol + hard-gate termination matrix"
```

---

### Task 11: `long-context-checkpoint/SKILL.md` — resume preference

**Tier:** mechanical

**Files:**
- Modify: `skills/long-context-checkpoint/SKILL.md`

- [ ] **Step 1: Find the current "Resuming in a New Session" section**

```bash
grep -n "^## Resuming in a New Session" skills/long-context-checkpoint/SKILL.md
```

- [ ] **Step 2: Replace the section body**

Replace the existing section body with:

```markdown
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
```

- [ ] **Step 3: Verify**

```bash
grep -c "plan.md frontmatter first" skills/long-context-checkpoint/SKILL.md
grep -c "checkpoint_pointer" skills/long-context-checkpoint/SKILL.md
```

Expected: each ≥ 1.

- [ ] **Step 4: Commit**

```bash
git add skills/long-context-checkpoint/SKILL.md
git commit -m "feat(checkpoint): prefer plan.md frontmatter for resume; document back-link"
```

---

### Task 12: `writing-plans/SKILL.md` — require frontmatter + Status markers

**Tier:** mechanical

**Files:**
- Modify: `skills/writing-plans/SKILL.md`

- [ ] **Step 1: Find the "Plan Document Header" section**

```bash
grep -n "^## Plan Document Header" skills/writing-plans/SKILL.md
```

- [ ] **Step 2: Replace the header template**

Replace the code block under `## Plan Document Header` with:

````markdown
```markdown
---
plan_version: 1
final_goal:
  template: <one of: all_tests_pass, code_review_clean, verify_command_zero, deploy_success, canary_clean, metrics_met, custom>
  # Template-specific params go below as needed, e.g.:
  # verify_command: "pytest -q"
  # judge_rationale: "all lints green, tests green, no broken imports"
status: not_started
execution_mode: <interactive | autonomous>
current_task: 1
convergence_round: 0
last_handoff: {pct: 0, ts: null}
checkpoint_pointer: docs/superpowers/checkpoints/<basename>-checkpoint.json
autonomous_limits:       # omit entirely if execution_mode: interactive
  budget_pct: 30
  max_convergence_rounds: 3
  max_handoffs: 10
  no_progress_abort_after: 2
---

# [Feature Name] Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** [One sentence describing what this builds]

**Architecture:** [2-3 sentences about approach]

**Tech Stack:** [Key technologies/libraries]

---
```

The plan-writing agent MUST:
- Fill in the `final_goal` block with a template choice and its required
  params (ask the user if unclear; `custom` requires a `judge_rationale`).
- Set `status: not_started` and `current_task: 1` at creation.
- Emit `autonomous_limits` only when the user has asked for autonomous
  execution; otherwise leave it out entirely — downstream tooling treats
  absence as "interactive-only plan".
````

- [ ] **Step 3: Add a `## Task Status Marker` section**

Locate `## Task Structure` and insert BEFORE it:

````markdown
## Task Status Marker

Every `## Task N` section in the plan MUST include a `**Status:**` line
just below the task title, with initial value `pending`. The controller
edits this in place as execution progresses. Example:

```markdown
### Task 1: LRUCache class

**Tier:** mechanical
**Status:** pending

<spec body>
```

Valid values: `pending | in_progress | done | blocked | deferred | superseded`.
After a task enters `done`, the controller appends `**Commit:** <sha>`
and `**Provider:** <provider>/<model>` lines. After `blocked`, it appends
`**Blocker:** <short reason>`. DO NOT write those lines at plan creation
time — leave them for the controller.
````

- [ ] **Step 4: Verify**

```bash
grep -c "plan_version: 1" skills/writing-plans/SKILL.md
grep -c "## Task Status Marker" skills/writing-plans/SKILL.md
```

Expected: each ≥ 1.

- [ ] **Step 5: Commit**

```bash
git add skills/writing-plans/SKILL.md
git commit -m "feat(writing-plans): require plan_version frontmatter + Status markers"
```

---

### Task 13: `executing-plans/SKILL.md` — frontmatter-first entry

**Tier:** mechanical

**Files:**
- Modify: `skills/executing-plans/SKILL.md`

- [ ] **Step 1: Find Step 1 ("Load and Review Plan")**

```bash
grep -n "^### Step 1: Load and Review Plan" skills/executing-plans/SKILL.md
```

- [ ] **Step 2: Replace with frontmatter-aware version**

```markdown
### Step 1: Load and Review Plan
1. Read the plan file.
2. If the plan has YAML frontmatter with `plan_version`:
   - Parse it. The `current_task`, `convergence_round`, and per-task
     `**Status:**` markers tell you what has already run.
   - Skip any tasks whose Status is `done`, `deferred`, or `superseded`.
   - Resume from the first task whose Status is `pending` or `in_progress`.
   - If `checkpoint_pointer` is set and the file exists, load it for the
     bulk state (decisions_log, provider_availability); do NOT re-run
     provider detection.
3. Review the remaining plan critically - identify any questions or
   concerns about the plan.
4. If concerns: Raise them with your human partner before starting.
5. If no concerns: Create TodoWrite and proceed.
```

- [ ] **Step 3: Verify**

```bash
grep -c "YAML frontmatter with \`plan_version\`" skills/executing-plans/SKILL.md
grep -c "checkpoint_pointer" skills/executing-plans/SKILL.md
```

Expected: each ≥ 1.

- [ ] **Step 4: Commit**

```bash
git add skills/executing-plans/SKILL.md
git commit -m "feat(executing-plans): load state from plan.md frontmatter first"
```

---

### Task 14: `commands/resume-plan.md` — accept plan.md or checkpoint.json

**Tier:** mechanical

**Files:**
- Modify: `commands/resume-plan.md`

- [ ] **Step 1: Read current content**

```bash
cat commands/resume-plan.md
```

- [ ] **Step 2: Rewrite**

```markdown
---
description: "Resume an in-progress plan from frontmatter (plan.md) or checkpoint. Usage: /resume-plan <path-to-plan.md-or-checkpoint.json>. Omit the path to auto-discover."
---

You were asked to resume a superpowers plan. Do this, in order, before any other action:

1. Invoke the **`superpowers:long-context-checkpoint`** skill via the Skill tool for the full resume procedure.

2. Parse the argument passed after `/resume-plan`:
   - If a path to `*.md` was given, treat it as a plan.md (preferred path).
   - If a path to `*-checkpoint.json` was given, read its `plan_path` field to find the plan.md.
   - If no path given, auto-discover:
     1. Scan `docs/superpowers/plans/*.md`. For each, parse frontmatter; pick those whose `status` is in `{not_started, in_progress, goal_not_met, stalled, blocked, budget_exhausted, judge_uncertain, review_contradiction, main_branch_gate}` (i.e. anything not `goal_met`).
     2. If exactly one candidate: use it.
     3. If multiple: list them and ask the user which to resume (this is one of the four hard gates where asking is required).
     4. If none: fall back to scanning `docs/superpowers/checkpoints/*-checkpoint.json` for any checkpoint whose tasks array has entries not `done`. Same disambiguation rules.
     5. If still none: tell the user "no resumable plan or checkpoint found" and stop.

3. Follow the algorithm in `long-context-checkpoint` skill's "Resuming in a New Session" section:
   - Read the plan's frontmatter.
   - Load bulk state from `checkpoint_pointer` if available.
   - Rebuild TodoWrite.
   - Do NOT re-run provider detection or Plan Start Initialization.
   - Print a `── Resumed from plan ──` banner with next task number and stage.
   - Continue `subagent-driven-development` from `frontmatter.current_task`.

4. Hand off to `superpowers:subagent-driven-development` for the remaining tasks.

If the frontmatter is missing `plan_version`, the plan is a 6.0.0-or-earlier plan — fall back to the legacy checkpoint-only resume described in `long-context-checkpoint`.

If the plan file is missing, malformed, `plan_version` is unknown, or the worktree no longer exists, STOP and report the specific failure — do not attempt partial recovery.
```

- [ ] **Step 3: Verify**

```bash
grep -c "plan_version" commands/resume-plan.md
grep -c "plan_path" commands/resume-plan.md
```

Expected: each ≥ 1.

- [ ] **Step 4: Commit**

```bash
git add commands/resume-plan.md
git commit -m "feat(commands): /resume-plan accepts plan.md; prefers frontmatter"
```

---

### Task 15: Integration roundtrip test

**Tier:** integration

**Files:**
- Create: `tests/claude-code/test-plan-md-roundtrip.sh`

- [ ] **Step 1: Write the test**

```bash
#!/usr/bin/env bash
# Integration test: a plan.md with frontmatter flows cleanly through
# detect-model-providers.sh, compute-weekly-spent.sh, and run-plan-autonomous.sh
# in --dry-run mode, and the plan's frontmatter.status is written on exit.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PASS=0; FAIL=0

# Fixture
tmp=$(mktemp -d)
mkdir -p "$tmp/docs/superpowers/plans" "$tmp/docs/superpowers/checkpoints" "$tmp/home/.claude/metrics"
now_iso=$(python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat().replace("+00:00","Z"))')
cat > "$tmp/home/.claude/metrics/costs.jsonl" <<EOF
{"timestamp":"$now_iso","estimated_cost_usd":5.00,"session_id":"a","model":"sonnet","input_tokens":0,"output_tokens":0}
EOF
cat > "$tmp/home/.claude/superpowers-budget.yaml" <<EOF
weekly_cap_usd: 200
EOF
cat > "$tmp/docs/superpowers/plans/foo.md" <<'EOF'
---
plan_version: 1
final_goal:
  template: all_tests_pass
  verify_command: "true"
status: in_progress
execution_mode: autonomous
current_task: 1
convergence_round: 0
last_handoff: {pct: 0, ts: null}
checkpoint_pointer: docs/superpowers/checkpoints/foo-checkpoint.json
autonomous_limits: {budget_pct: 40, max_convergence_rounds: 3, max_handoffs: 1, no_progress_abort_after: 1}
---
# foo plan
## Task 1: noop
**Tier:** mechanical
**Status:** done
EOF
cat > "$tmp/docs/superpowers/checkpoints/foo-checkpoint.json" <<EOF
{"tasks":[{"n":1,"status":"done"}],"plan_path":"$tmp/docs/superpowers/plans/foo.md"}
EOF

# Test A: detect-model-providers still works
out=$(HOME="$tmp/home" bash "$REPO_ROOT/scripts/detect-model-providers.sh" 2>&1)
if echo "$out" | tail -1 | python3 -c "import json,sys; json.loads(sys.stdin.read())" >/dev/null 2>&1; then
  echo "  [PASS] detect-model-providers emits valid JSON tail"; PASS=$((PASS+1))
else
  echo "  [FAIL] detect-model-providers broken"; FAIL=$((FAIL+1))
fi

# Test B: compute-weekly-spent reads mock costs
out=$(HOME="$tmp/home" bash "$REPO_ROOT/scripts/compute-weekly-spent.sh" 2>&1)
if echo "$out" | tail -1 | python3 -c 'import json,sys; d=json.loads(sys.stdin.read()); assert d["weekly_spent_usd"]==5.0; assert d["pct"]==2.5; print("ok")' >/dev/null 2>&1; then
  echo "  [PASS] compute-weekly-spent reads $HOME mock"; PASS=$((PASS+1))
else
  echo "  [FAIL] compute-weekly-spent returned: $out"; FAIL=$((FAIL+1))
fi

# Test C: outer script PROPAGATES a terminal frontmatter.status written by controller.
# We simulate: plan already marked `goal_met` — outer script must exit 0 without spawning.
python3 -c "
import re
p = '$tmp/docs/superpowers/plans/foo.md'
t = open(p).read()
t = re.sub(r'^status:\s*\S+', 'status: goal_met', t, count=1, flags=re.MULTILINE)
open(p,'w').write(t)
"
HOME="$tmp/home" bash "$REPO_ROOT/scripts/run-plan-autonomous.sh" "$tmp/docs/superpowers/plans/foo.md" --dry-run --budget-pct 40 >/dev/null 2>&1
rc=$?
got=$(python3 -c "
import re
t = open('$tmp/docs/superpowers/plans/foo.md').read()
m = re.search(r'^status:\s*(\S+)', t, re.MULTILINE)
print(m.group(1) if m else 'unset')
")
if [[ "$rc" -eq 0 && "$got" == "goal_met" ]]; then
  echo "  [PASS] outer script propagates terminal frontmatter.status=goal_met (rc=0)"; PASS=$((PASS+1))
else
  echo "  [FAIL] propagation: rc=$rc, status=$got (want rc=0, status=goal_met)"; FAIL=$((FAIL+1))
fi

# Test D: in_progress plan with all tasks done but NO controller convergence → outer loops, eventually stalls
python3 -c "
import re
p = '$tmp/docs/superpowers/plans/foo.md'
t = open(p).read()
t = re.sub(r'^status:\s*\S+', 'status: in_progress', t, count=1, flags=re.MULTILINE)
open(p,'w').write(t)
"
HOME="$tmp/home" bash "$REPO_ROOT/scripts/run-plan-autonomous.sh" "$tmp/docs/superpowers/plans/foo.md" --dry-run --budget-pct 40 --no-progress-abort 1 --max-handoffs 2 >/dev/null 2>&1
rc=$?
got=$(python3 -c "
import re
t = open('$tmp/docs/superpowers/plans/foo.md').read()
m = re.search(r'^status:\s*(\S+)', t, re.MULTILINE)
print(m.group(1) if m else 'unset')
")
if [[ "$rc" -eq 1 && "$got" == "stalled" ]]; then
  echo "  [PASS] in_progress without controller progress → stalled rc=1"; PASS=$((PASS+1))
else
  echo "  [FAIL] stall detection: rc=$rc, status=$got (want rc=1, status=stalled)"; FAIL=$((FAIL+1))
fi

rm -rf "$tmp"
echo ""
echo "passed: $PASS, failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
```

- [ ] **Step 2: Run test**

```bash
chmod +x tests/claude-code/test-plan-md-roundtrip.sh
bash tests/claude-code/test-plan-md-roundtrip.sh
```

Expected: `passed: 4, failed: 0`.

- [ ] **Step 3: Run the full new test suite**

```bash
for t in \
  tests/claude-code/test-compute-weekly-spent.sh \
  tests/claude-code/test-run-plan-autonomous-budget.sh \
  tests/claude-code/test-plan-md-roundtrip.sh; do
  echo "=== $t ===" ; bash "$t" || exit 1
done
```

Expected: all three suites end with `failed: 0`.

- [ ] **Step 4: Commit**

```bash
git add tests/claude-code/test-plan-md-roundtrip.sh
git commit -m "test(integration): plan.md frontmatter roundtrip through scripts"
```

---

### Task 16: CHANGELOG entry + version bump to 6.1.0

**Tier:** mechanical

**Files:**
- Modify: `CHANGELOG.md`
- Modify: via `scripts/bump-version.sh`: `package.json`, `.claude-plugin/plugin.json`, `.cursor-plugin/plugin.json`, `.claude-plugin/marketplace.json`, `gemini-extension.json`

- [ ] **Step 1: Prepend CHANGELOG entry**

Insert at the top of `CHANGELOG.md`, right after the first `# Changelog` line:

```markdown

## [6.1.0] - 2026-04-14

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
```

- [ ] **Step 2: Bump version**

```bash
./scripts/bump-version.sh 6.1.0
```

Expected: all 5 declared files go `6.0.0 -> 6.1.0`; audit reports no drift.

- [ ] **Step 3: Verify**

```bash
./scripts/bump-version.sh --check
head -5 CHANGELOG.md
```

Expected: `All declared files are in sync at 6.1.0`; CHANGELOG starts with `## [6.1.0]`.

- [ ] **Step 4: Commit**

```bash
git add CHANGELOG.md package.json .claude-plugin/plugin.json .cursor-plugin/plugin.json .claude-plugin/marketplace.json gemini-extension.json
git commit -m "chore: release 6.1.0 (convergence + budget-pct + plan-as-state)"
```

---

## Self-review checklist (for the implementer / controller to run at end)

- [ ] All 16 tasks committed.
- [ ] `./scripts/bump-version.sh --check` → no drift.
- [ ] Three test scripts pass: `test-compute-weekly-spent.sh`,
  `test-run-plan-autonomous-budget.sh`, `test-plan-md-roundtrip.sh`.
- [ ] `scripts/detect-model-providers.sh` still runs cleanly.
- [ ] Existing 6.0.0 smoke scripts still pass (no regression).
- [ ] No TBD/TODO in any of the new SKILL.md text.
- [ ] All seven `final_goal` templates are referenced in both
  `subagent-driven-development/SKILL.md` and `writing-plans/SKILL.md`.
- [ ] Hard-gate table in `subagent-driven-development/SKILL.md` lists
  eight status values; no orphans.
