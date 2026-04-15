# Cross-Model External Review Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make Stage 3 external review work with real cross-model diversity (GPT via Codex, Gemini, or Claude Opus fallback), four-level detection, feedback triage, and visible stage markers.

**Architecture:** Replace the aspirational `/codex:review` from `codex-plugin-cc` references with a four-level fallback chain: (1) `/codex:review` skill from the codex plugin, (2) `codex exec review` CLI, (3) `gemini -p` CLI, (4) Claude Opus Agent. Add a feedback triage step so external review results are evaluated before acting. All changes are in markdown skill files and bash test scripts — no compiled code.

**Tech Stack:** Markdown (SKILL.md, prompt templates), Bash (test scripts), Claude Code plugin system

---

### Task 1: Rewrite "Codex Availability Detection" → "Reviewer B Detection" in SKILL.md

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md:176-197` (Codex Availability Detection section)

- [ ] **Step 1: Replace the "Codex Availability Detection" section with four-level fallback**

Replace lines 176-197 (the current "Codex Availability Detection" section) with:

```markdown
## Reviewer B Detection

Before entering Stage 3 for the first time, detect the best available Reviewer B and cache the result for all tasks in this plan.

**Detection runs once at plan start. Output the detection results:**

```
─── Reviewer B detection ───
  /codex:review skill: checking...
```

**Four-level fallback chain:**

1. **`/codex:review` skill** (codex plugin installed): Invoke via Skill tool with `--wait --base {BASE_SHA}`. Async alternative: invoke without `--wait`, poll `/codex:status`, retrieve via `/codex:result`. True cross-family diversity (GPT model).
2. **Codex CLI** (codex installed, plugin not): `codex exec review --base {BASE_SHA} --commit {HEAD_SHA} --ephemeral -o /tmp/reviewer-b-output.txt`. Same GPT model via standalone CLI.
3. **Gemini CLI** (gemini installed, codex not): `gemini -p "$(cat $PROMPT_FILE)" -m gemini-2.5-pro`. Cross-family diversity via Gemini.
4. **Claude Opus Agent** (no external CLI): Agent tool with `model: "opus"` using `./external-reviewer-prompt.md`. Same-family fallback — still provides diversity via different capability tier.

**Detection output examples:**

When codex plugin found:
```
─── Reviewer B detection ───
  /codex:review skill: ✅ available (codex plugin)
  Using: /codex:review (GPT, cross-family)
```

When only codex CLI found:
```
─── Reviewer B detection ───
  /codex:review skill: not available
  codex CLI: ✅ found (v0.116.0)
  Using: codex exec review (GPT, cross-family)
```

When nothing external found:
```
─── Reviewer B detection ───
  /codex:review skill: not available
  codex CLI: not found
  gemini CLI: not found
  ⚠ No external reviewer available — falling back to Claude Opus
  Using: Agent tool model: "opus" (same-family fallback)
```
```

- [ ] **Step 2: Verify the edit**

Read `skills/subagent-driven-development/SKILL.md` and confirm:
- The old "Codex Availability Detection" heading is gone
- The new "Reviewer B Detection" heading exists with four levels
- Detection output examples are present

- [ ] **Step 3: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md
git commit -m "feat: replace Codex availability detection with four-level Reviewer B detection"
```

---

### Task 2: Rewrite "External Review Loop" section with triage in SKILL.md

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md:296-341` (External Review Loop section)

- [ ] **Step 1: Replace the "External Review Loop" section**

Replace lines 296-341 (from `## External Review Loop` through the end of `### External Review Example`) with:

```markdown
## External Review Loop

After internal reviews (spec compliance + code quality) pass, the controller dispatches two external reviewers **in parallel**:

**Reviewer A (always Claude Sonnet):** Dispatched via Agent tool with `model: "sonnet"`. Uses `./external-reviewer-prompt.md` template. Focuses on blind spots, cross-task consistency, systemic/evolutionary concerns, and security.

**Reviewer B (best available — see "Reviewer B Detection"):** Dispatched via the detected mechanism (codex skill, codex CLI, gemini CLI, or opus agent). The detection result is cached from plan start.

**Parallel execution:** Reviewer A (Agent tool) and Reviewer B (Skill/Bash/Agent tool) dispatch in the same message for concurrent execution.

### Feedback Triage

External reviewer feedback is **not automatically trusted**. The controller must evaluate each issue before acting.

**Output format:**
```
─── Triaging external review feedback ───
  Reviewer A (Sonnet): 2 issues
    1. [Important] Race condition in cache access → ✅ Valid, dispatching fix
    2. [Minor] Variable naming style → ❌ Rejected: matches project convention
  Reviewer B (Codex/GPT): 1 issue
    1. [Important] Missing null check on line 45 → ⚠ Discuss: function is internal-only, caller guarantees non-null
```

**Triage categories:**
- **Valid** → accept, dispatch implementer to fix
- **Rejected** → explain why (wrong assumption, matches existing convention, etc.), skip
- **Discuss** → present to user with controller's assessment, let user decide

**Triage criteria:**
- Does the issue identify a real bug or security problem? → likely valid
- Does the reviewer misunderstand project conventions or constraints? → likely reject
- Is the reviewer applying generic best practices that don't fit this context? → likely reject
- Is the issue about a design trade-off with no clear right answer? → discuss with user

**After triage:**
1. Controller presents triage results to user with reasoning for each decision
2. User confirms or overrides any triage decisions
3. Controller dispatches implementer subagent to fix only the accepted issues
4. Re-runs internal reviews (Stage 1 + 2) on the fix
5. Re-runs Stage 3 with both external reviewers

**Exit condition:** Both reviewers approve, OR all remaining issues have been triaged as rejected/discussed and user has confirmed.

### External Review Example

```
─── Stage 3/3: External Review ───
  ├─ Reviewer A (Sonnet):  dispatching via Agent tool...
  ├─ Reviewer B (Codex/GPT): dispatching via /codex:review --wait --base abc123...
  ├─ Reviewer A (Sonnet):  ❌ Needs Fix (1 Important)
  │    Important: Race condition in concurrent access to shared cache (utils.ts:45)
  └─ Reviewer B (Codex/GPT): ✅ Approved

─── Triaging external review feedback ───
  Reviewer A (Sonnet): 1 issue
    1. [Important] Race condition in cache access → ✅ Valid
  Reviewer B (Codex/GPT): 0 issues

  Presenting triage to user...
  User confirms: proceed with fix

  Dispatching implementer to fix...

  Re-running internal reviews on fix:
─── Stage 1/3: Spec Compliance (re-review) ───
  Result: ✅ Spec compliant
─── Stage 2/3: Code Quality (re-review) ───
  Result: ✅ Approved

─── Stage 3/3: External Review (round 2) ───
  ├─ Reviewer A (Sonnet):  ✅ Approved — race condition properly addressed
  └─ Reviewer B (Codex/GPT): ✅ Approved

✅ Task 2 complete
```
```

- [ ] **Step 2: Verify the edit**

Read the modified section and confirm:
- Triage section exists with categories (Valid/Rejected/Discuss)
- Triage criteria are present
- After-triage flow includes user confirmation step
- Exit condition includes the "user confirmed rejections" path
- Example shows triage output format

- [ ] **Step 3: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md
git commit -m "feat: add feedback triage to external review loop, replace codex-plugin-cc with four-level dispatch"
```

---

### Task 3: Update "Red Flags" and "If external reviewers disagree" in SKILL.md

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md:378-418` (Red Flags section)

- [ ] **Step 1: Update the external reviewer red flags and disagreement handling**

Find this block in the Red Flags section:

```markdown
- **Proceed when only one external reviewer approves** (both external reviewers must approve)
- **Send unfixed internal review issues to external review** (fix internal issues first)
- **Skip Codex availability check** (run it once at plan start, cache the result)
- **Omit stage markers** (user must see which stage is active at all times)
```

Replace with:

```markdown
- **Proceed when only one external reviewer approves** (both external reviewers must approve, or user confirms triage rejections)
- **Send unfixed internal review issues to external review** (fix internal issues first)
- **Skip Reviewer B detection** (run it once at plan start, cache the result)
- **Omit stage markers** (user must see which stage is active at all times)
- **Blindly accept external review feedback** (triage first — external models may misunderstand project conventions)
- **Skip user confirmation on triage** (user must confirm valid/rejected/discuss decisions)
```

Find this block:

```markdown
**If external reviewers disagree:**
- If one approves and one finds issues, fix the issues and re-submit to both
- If both find different issues, merge and dedup, fix all, re-submit to both
- Never cherry-pick which reviewer's feedback to address — fix everything
```

Replace with:

```markdown
**If external reviewers disagree:**
- If one approves and one finds issues, triage the issues first, then fix valid ones and re-submit to both
- If both find different issues, merge and dedup, triage all, fix valid ones, re-submit to both
- Never cherry-pick which reviewer's feedback to address — triage everything, fix what's valid
- If reviewer flags something that matches project conventions, reject with explanation
- When in doubt, present as "Discuss" and let the user decide
```

- [ ] **Step 2: Verify the edit**

Read the Red Flags section and confirm:
- "Skip Codex availability check" is now "Skip Reviewer B detection"
- Two new red flags about blind acceptance and skipping user confirmation
- Disagreement handling includes triage step

- [ ] **Step 3: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md
git commit -m "feat: update red flags for feedback triage and Reviewer B detection"
```

---

### Task 4: Update Example Workflow to show triage and codex detection

**Files:**
- Modify: `skills/subagent-driven-development/SKILL.md:206-294` (Example Workflow section)

- [ ] **Step 1: Replace the example workflow header and detection block**

Find the current detection block in the example (around lines 215-217):

```
─── Codex availability check ───
  ⚠ /codex:review not available (codex-plugin-cc not installed)
  Falling back to: Sonnet + Opus review
```

Replace with:

```
─── Reviewer B detection ───
  /codex:review skill: ✅ available (codex plugin)
  Using: /codex:review (GPT, cross-family)
```

- [ ] **Step 2: Update Task 1 example to show codex dispatch**

Find the Stage 3 block in Task 1 example (around lines 242-246):

```
─── Stage 3/3: External Review ───
  ├─ Sonnet:  dispatching...
  ├─ Opus:    dispatching...
  ├─ Sonnet:  ✅ Approved — no additional issues found
  └─ Opus:    ✅ Approved — no issues found
```

Replace with:

```
─── Stage 3/3: External Review ───
  ├─ Reviewer A (Sonnet):  dispatching via Agent tool...
  ├─ Reviewer B (Codex/GPT): dispatching via /codex:review --wait...
  ├─ Reviewer A (Sonnet):  ✅ Approved — no additional issues found
  └─ Reviewer B (Codex/GPT): ✅ Approved — no issues found
```

- [ ] **Step 3: Update Task 2 example to show triage**

Find the Stage 3 block in Task 2 example (around lines 279-283):

```
─── Stage 3/3: External Review ───
  ├─ Sonnet:  dispatching...
  ├─ Opus:    dispatching...
  ├─ Sonnet:  ✅ Approved (Minor: consider extracting progress utility)
  └─ Opus:    ✅ Approved — no issues found
```

Replace with:

```
─── Stage 3/3: External Review ───
  ├─ Reviewer A (Sonnet):  dispatching via Agent tool...
  ├─ Reviewer B (Codex/GPT): dispatching via /codex:review --wait...
  ├─ Reviewer A (Sonnet):  ⚠ 1 Minor issue
  │    Minor: Consider extracting progress utility
  └─ Reviewer B (Codex/GPT): ✅ Approved — no issues found

─── Triaging external review feedback ───
  Reviewer A (Sonnet): 1 issue
    1. [Minor] Extract progress utility → ❌ Rejected: YAGNI, only used once
  User confirms: proceed

✅ Task 2 complete
```

- [ ] **Step 4: Verify the edit**

Read the example workflow and confirm:
- Detection block says "Reviewer B detection" not "Codex availability check"
- Stage 3 shows "Reviewer A (Sonnet)" and "Reviewer B (Codex/GPT)" labels
- Task 2 example includes triage block with rejection

- [ ] **Step 5: Commit**

```bash
git add skills/subagent-driven-development/SKILL.md
git commit -m "feat: update example workflow with codex detection and feedback triage"
```

---

### Task 5: Update external-reviewer-prompt.md for both dispatch methods

**Files:**
- Modify: `skills/subagent-driven-development/external-reviewer-prompt.md`

- [ ] **Step 1: Rewrite the prompt template header**

Replace the entire file content with:

```markdown
# External Reviewer Prompt Template

Use this template when dispatching external reviewers for cross-model review in Stage 3.

**Purpose:** Provide an independent cross-model perspective on code that has already passed internal spec compliance and code quality review. Catch blind spots that same-model review misses.

**Only dispatch after both spec compliance and code quality reviews pass.**

## Reviewer A: Sonnet Subagent (always runs)

Dispatch via Agent tool with `model: "sonnet"`:

```
Agent tool:
  model: "sonnet"
  description: "External review for Task N: [task name]"
  prompt: |
    You are an independent external code reviewer. The code you are reviewing has
    already passed two internal review stages:
    1. Spec compliance review (confirmed: implements exactly what was requested)
    2. Code quality review (confirmed: clean, tested, maintainable, performant, consistent, well-designed)

    Your job is to provide a DIFFERENT perspective. Do not repeat what internal
    reviewers already checked. Focus on what they might have missed.

    ## Task Spec

    [FULL TEXT of task requirements]

    ## Changed Files

    [List of files changed by this task]

    ## Git Diff

    Review the diff for this task:

    ```bash
    git diff {BASE_SHA}..{HEAD_SHA}
    ```

    ## Focus Areas

    **Cross-task consistency:**
    - Does this task's implementation style match other tasks in the same plan?
    - Are there naming or pattern inconsistencies across the broader codebase?

    **Blind spots:**
    - Edge cases that both the implementer and internal reviewer might share assumptions about
    - Concurrency, race conditions, or ordering issues
    - Error propagation paths that cross module boundaries
    - Implicit assumptions about input data or environment

    **Systemic/evolutionary concerns:**
    - Will this approach cause problems as the codebase scales (more tasks, more contributors)?
    - Does this change create coupling between components that should remain independent?
    - Are there cross-cutting concerns (logging, error handling, configuration) that this task handles differently from the rest of the system?

    **Security:**
    - Input validation gaps
    - Injection vectors
    - Authentication/authorization bypasses

    ## Output Format

    Issues:
      - Critical: [must fix before proceeding]
      - Important: [should fix before proceeding]
      - Minor: [note for future improvement]
    Assessment: Approved / Needs Fix

    If you find no issues beyond what internal review already covered, report:
    Assessment: Approved — no additional issues found.

    Do NOT manufacture issues. If the code is solid, say so.
```

## Reviewer B: Best Available External Model

Dispatch via the detected Reviewer B mechanism (see "Reviewer B Detection" in SKILL.md).

### Option 1: /codex:review skill (codex plugin installed)

```
Skill tool:
  skill: "codex:review"
  args: "--wait --base {BASE_SHA}"
```

The codex plugin handles the review autonomously — it reads the git diff, runs a GPT-based review, and returns structured output. No custom prompt needed.

### Option 2: codex exec review CLI (codex installed, plugin not)

```bash
codex exec review --base {BASE_SHA} --commit {HEAD_SHA} --ephemeral -o /tmp/reviewer-b-output.txt
```

Returns structured review output to the file. Read the file for results.

### Option 3: gemini CLI (gemini installed)

Write the Reviewer A prompt (above) to a temp file, then:

```bash
PROMPT_FILE=$(mktemp /tmp/external-reviewer-b-XXXXXX.txt)
cat > "$PROMPT_FILE" << 'EOF'
[Same prompt as Reviewer A above, with task spec and diff filled in]
EOF
gemini -p "$(cat "$PROMPT_FILE")" -m gemini-2.5-pro
rm -f "$PROMPT_FILE"
```

### Option 4: Claude Opus Agent (fallback)

```
Agent tool:
  model: "opus"
  description: "External review for Task N: [task name]"
  prompt: |
    [Same prompt as Reviewer A above]
```

**Note:** Log a warning that both reviewers share the same model family — true model diversity was not achieved but context isolation is still enforced.
```

- [ ] **Step 2: Verify the edit**

Read `skills/subagent-driven-development/external-reviewer-prompt.md` and confirm:
- Reviewer A section with Agent tool dispatch and full prompt
- Reviewer B section with all four options
- Option 1 uses `/codex:review` skill
- Option 2 uses `codex exec review` CLI
- Option 3 uses `gemini -p` CLI
- Option 4 uses Agent tool with `model: "opus"` with warning

- [ ] **Step 3: Commit**

```bash
git add skills/subagent-driven-development/external-reviewer-prompt.md
git commit -m "feat: rewrite external reviewer prompt with four-level Reviewer B dispatch options"
```

---

### Task 6: Update tests for four-level detection, triage, and codex integration

**Files:**
- Modify: `tests/claude-code/test-external-review-loop.sh`

- [ ] **Step 1: Replace Tests 11-13 and add new tests**

Find the block starting with `# Test 11: Stage progress display requirement` (near the end of the file, before `echo "=== All external review loop tests passed ==="`) and replace everything from Test 11 through the end-of-tests echo with:

```bash
# Test 11: Stage progress markers are mandatory
echo "Test 11: Stage progress markers..."

output=$(run_claude "In subagent-driven-development, how should the controller display review progress to the user? Are stage markers mandatory or optional?" 60)

if assert_contains_ci "$output" "stage" "Mentions stage markers"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "must\|required\|mandatory" "Stage markers are mandatory"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 12: Four-level Reviewer B detection
echo "Test 12: Reviewer B four-level fallback..."

output=$(run_claude "In subagent-driven-development, what are the four levels of Reviewer B detection for external review? List them in order." 60)

if assert_contains_ci "$output" "codex.*review.*skill\|/codex:review\|codex.*plugin" "Level 1: codex review skill"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "codex.*cli\|codex.*exec\|command.*codex" "Level 2: codex CLI"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "gemini" "Level 3: gemini CLI"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "opus\|fallback" "Level 4: opus fallback"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 13: Feedback triage requirement
echo "Test 13: Feedback triage..."

output=$(run_claude "In subagent-driven-development, what happens with external review feedback before it is acted on? Is it automatically trusted?" 60)

if assert_contains_ci "$output" "triage\|evaluat\|not.*trust\|not.*automatic" "Feedback is not automatically trusted"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "valid\|reject\|discuss" "Triage categories mentioned"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 14: User confirmation in triage
echo "Test 14: User confirmation in triage..."

output=$(run_claude "In subagent-driven-development external review triage, does the user get to confirm or override triage decisions?" 60)

if assert_contains_ci "$output" "user.*confirm\|user.*override\|user.*decide\|present.*user" "User confirms triage"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 15: Detection runs once
echo "Test 15: Reviewer B detection caching..."

output=$(run_claude "In subagent-driven-development, how often does Reviewer B detection run? Once per task or once per plan?" 60)

if assert_contains_ci "$output" "once\|cache\|plan.*start\|single" "Detection runs once per plan"; then
    : # pass
else
    exit 1
fi

echo ""

echo "=== All external review loop tests passed ==="
```

- [ ] **Step 2: Also update Test 3 to include the skill-based codex option**

Find Test 3 (around line 107-128) which checks for "Sonnet + Codex parallel dispatch". Update the assertion to also accept the skill-based path:

Find:
```bash
if assert_contains_ci "$output" "codex" "Mentions Codex"; then
```

This assertion already works for both `/codex:review` skill and `codex exec review` since both contain "codex". No change needed.

- [ ] **Step 3: Run the fast content tests to verify syntax**

```bash
bash -n tests/claude-code/test-external-review-loop.sh
echo "Syntax check: $?"
```

Expected: exit code 0 (no syntax errors)

- [ ] **Step 4: Commit**

```bash
git add tests/claude-code/test-external-review-loop.sh
git commit -m "test: update external review tests for four-level detection and feedback triage"
```

---

### Task 7: Smoke test — run codex review on the changes we just made

**Files:**
- No files created/modified — this is a verification task

- [ ] **Step 1: Run codex exec review on the branch diff**

```bash
codex exec review --commit HEAD --ephemeral -o /tmp/cross-model-review-smoke.txt 2>&1 | tail -20
```

- [ ] **Step 2: Read and evaluate the output**

```bash
cat /tmp/cross-model-review-smoke.txt
```

Evaluate: Does Codex return structured review feedback? Does it find any real issues? This confirms the cross-model review pipeline is functional.

- [ ] **Step 3: Run the test syntax check**

```bash
bash -n tests/claude-code/test-external-review-loop.sh && echo "OK"
```

- [ ] **Step 4: Clean up**

```bash
rm -f /tmp/cross-model-review-smoke.txt /tmp/reviewer-b-output.txt
```
