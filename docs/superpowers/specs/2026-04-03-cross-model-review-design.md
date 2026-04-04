# Cross-Model External Review Design

## Problem

The current `subagent-driven-development` SKILL.md describes a three-stage review with cross-model external review (Stage 3), but the implementation relies on `/codex:review` from a non-existent `codex-plugin-cc` plugin. The feature is aspirational — it doesn't actually work.

## Goal

Make Stage 3 external review work with real cross-model diversity using external CLI tools, with graceful fallback to same-family models when no external CLI is available.

## Design

### Reviewer B Detection (four-level fallback)

At plan start, detect the best available Reviewer B mechanism once and cache the result:

```
1. Check: Is /codex:review skill available? (codex plugin installed)
   → Yes: REVIEWER_B="codex-skill" ← VERIFIED WORKING (codex plugin v1.0.2)
2. Check: command -v codex (Codex CLI installed?)
   → Yes: REVIEWER_B="codex-cli"
3. Check: command -v gemini (Gemini CLI installed?)
   → Yes: REVIEWER_B="gemini-cli"
4. Fallback: REVIEWER_B="opus-agent"
```

**Why four levels:** `/codex:review` as a skill provides the tightest integration — it uses a shared Codex runtime, supports foreground/background execution, and has structured status/result retrieval via `/codex:status` and `/codex:result`. `codex exec review` is the next best — same GPT model, just invoked as standalone CLI. Gemini gives cross-family diversity. Opus is same-family fallback.

### Reviewer Dispatch

**Reviewer A (always Claude Sonnet):** Dispatched via Agent tool with `model: "sonnet"`. Uses `external-reviewer-prompt.md` template. Provides cross-model diversity within the Claude family (different from the implementer model).

**Reviewer B (best available external model):**

Priority chain:
1. **`/codex:review` skill** (codex plugin installed, VERIFIED): Invoke via Skill tool with `--wait --base {BASE_SHA}`. Async alternative: invoke without `--wait`, poll `/codex:status`, retrieve via `/codex:result`. Uses shared Codex runtime with GPT model — true cross-family diversity.
2. **Codex CLI** (codex installed, plugin not): `codex exec review --base {BASE_SHA} --commit {HEAD_SHA} --ephemeral -o {OUTPUT_FILE}` — same GPT model via CLI
3. **Gemini CLI** (gemini installed, codex not): `gemini -m gemini-2.5-pro < "$PROMPT_FILE"` — Gemini family, true cross-family diversity  
4. **Claude Opus Agent** (no external CLI): Agent tool with `model: "opus"` — same family fallback, still provides model diversity via different capability tier

### Codex Integration Details

Use `codex exec review` (built-in review subcommand), not raw `codex exec` with a custom prompt:

```bash
# Review a specific commit range
codex exec review --base {BASE_SHA} --commit {HEAD_SHA} --ephemeral -o /tmp/reviewer-b-output.txt

# With custom review instructions (via stdin)
echo "{REVIEW_INSTRUCTIONS}" | codex exec review --base {BASE_SHA} --commit {HEAD_SHA} --ephemeral -o /tmp/reviewer-b-output.txt -
```

Key flags:
- `--ephemeral` — no session persistence (clean each time)
- `-o {file}` — capture output to file for parsing
- `--base` / `--commit` — specify diff range
- Default sandbox is read-only for review

### Stage Progress Display

```
─── Stage 3/3: External Review ───
  Detecting external reviewers...
  ├─ codex CLI: found (v0.116.0)
  ├─ Reviewer A (Sonnet):  dispatching via Agent tool...
  ├─ Reviewer B (Codex/GPT): dispatching via codex exec review...
  ├─ Reviewer A (Sonnet):  ✅ Approved
  └─ Reviewer B (Codex/GPT): ✅ Approved (1 Minor: line-order test flakiness)
```

When no external CLI:
```
─── Stage 3/3: External Review ───
  Detecting external reviewers...
  ├─ codex CLI: not found
  ├─ gemini CLI: not found
  ⚠ No external CLI available — falling back to Claude Opus
  ├─ Reviewer A (Sonnet):  dispatching via Agent tool...
  ├─ Reviewer B (Opus):    dispatching via Agent tool...
  ...
```

### Feedback Triage

External reviewer feedback is **not automatically trusted**. The controller must evaluate each issue before acting:

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

### Parallel Execution

Reviewer A (Agent tool) and Reviewer B (Bash/codex exec) run in parallel:
- Agent tool call for Sonnet reviewer
- Bash tool call for `codex exec review`
- Both in the same message for concurrent execution

### Files to Change

1. **`skills/subagent-driven-development/SKILL.md`** — Replace "Codex Availability Detection" and "External Review Loop" sections with CLI-based detection and dispatch
2. **`skills/subagent-driven-development/external-reviewer-prompt.md`** — Update to document both Agent tool dispatch (Reviewer A) and CLI dispatch (Reviewer B) patterns
3. **`tests/claude-code/test-external-review-loop.sh`** — Update tests to verify CLI detection, fallback chain, and `codex exec review` pattern

### Why Triage Matters

External models have different training data and conventions. A GPT model might flag something as "bad practice" that is intentional in this project. A Gemini model might not understand a Claude-specific pattern. The controller (Claude Opus, with full project context) is best positioned to judge whether external feedback applies.

Without triage, the loop can degenerate into:
- Implementer "fixes" a non-issue
- Fix introduces a real problem
- Internal review catches the new problem
- Cycle repeats with wasted iterations

### What We Verified

- **`/codex:review` skill** (codex plugin v1.0.2): installed and authenticated, shared runtime available
  - `/codex:review [--wait|--background] [--base <ref>]` — starts review
  - `/codex:status [job-id]` — polls progress
  - `/codex:result [job-id]` — retrieves structured output
- **`codex exec review --commit HEAD --ephemeral`**: works as standalone CLI, returns structured output
- Codex found a real issue in test code (line-order assertion flakiness) — confirms review quality
- Codex CLI v0.116.0 at `/opt/homebrew/bin/codex`, authenticated

### Out of Scope

- Gemini CLI integration (not installed, design supports it but untested)
- Custom model selection for codex (uses default model)
- Structured JSON verdict format (santa-loop pattern) — keep natural language output for now
