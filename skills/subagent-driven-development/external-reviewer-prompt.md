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
