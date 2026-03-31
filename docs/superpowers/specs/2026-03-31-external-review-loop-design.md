# External Review Loop Design

Add a cross-model external review stage to `subagent-driven-development`, where Sonnet and Codex review code in parallel after the existing internal review stages pass.

## Problem

The current two-stage review (spec compliance + code quality) uses the same model family. A single model has blind spots — it may consistently miss certain classes of issues. Cross-model review provides independent perspectives and catches problems that same-model review cannot.

## Design

### Extended Per-Task Flow

```
Implementer completes task
    ↓
Stage 1: Spec Compliance Review (unchanged)
    ↓ pass
Stage 2: Code Quality Review (expanded: +performance, +consistency, +design)
    ↓ pass, implementer fixes any issues
Stage 3: External Review Loop
    ├── Sonnet subagent (Agent tool, model: "sonnet")
    └── Codex (/codex:review via codex-plugin-cc)
    ↓ collect both results
    ├── Both approve → mark task complete
    └── Issues found → merge/dedup feedback → implementer fixes → repeat Stage 3
```

### Stage 2 Expansion: Code Quality Review

The existing code quality reviewer prompt adds three dimensions:

**Performance:**
- Unnecessary repeated computation, N+1 queries, unbounded loops
- Data structure choice appropriateness
- Obvious performance bottlenecks

**Consistency:**
- Naming, error handling, logging style matches existing codebase
- API design patterns unified with rest of project
- No conflicting new patterns introduced

**Design:**
- Abstraction levels appropriate, responsibilities clear
- Dependency direction correct
- Neither over-engineered nor under-designed

Output format expands to:

```
Strengths:
Issues:
  - Critical: ...
  - Important: ...
  - Minor: ...
Performance:
  - ...
Consistency:
  - ...
Design:
  - ...
Assessment: Approved / Needs Fix
```

### Stage 3: External Review Loop

#### Sonnet Review

Dispatched via Agent tool with `model: "sonnet"`. Uses new `external-reviewer-prompt.md` template.

The prompt provides:
- Full task spec
- Changed files list and git diff
- Note that code has already passed internal spec compliance + code quality review
- Focus areas: blind spots internal review may miss, cross-task consistency, broader design perspective

Output: `Issues (Critical/Important/Minor) / Assessment (Approved / Needs Fix)`

#### Codex Review

Invoked via `/codex:review` from `codex-plugin-cc`. Reviews the committed diff (BASE_SHA..HEAD_SHA) since implementer commits before review. Async flow:
1. Invoke `/codex:review` with the branch diff from task start to current HEAD
2. Poll `/codex:status` until complete
3. Retrieve results via `/codex:result`

#### Feedback Merge and Fix Loop

```
Collect Sonnet feedback + Codex feedback
    ↓
Merge and deduplicate (same issue from both → single item)
    ↓
Dispatch implementer subagent with merged issue list
    ↓
Implementer fixes and commits
    ↓
Re-run internal reviews (spec compliance + code quality) on fixes
    ↓
Re-dispatch Sonnet + Codex in parallel
    ↓
Both approved → next task
Issues remain → loop continues
```

#### Exit Condition

Both Sonnet and Codex must approve. No maximum loop count — loop until both pass.

### Parallel Execution

Sonnet subagent and Codex review are dispatched simultaneously. The controller waits for both to return before proceeding. Since Codex `/codex:review` is async (poll with `/codex:status`), the controller handles this transparently.

## Files Changed

| File | Change |
|------|--------|
| `skills/subagent-driven-development/SKILL.md` | Update flow diagram, add Stage 3 external review loop, update Red Flags |
| `skills/subagent-driven-development/code-quality-reviewer-prompt.md` | Expand review dimensions: +performance, +consistency, +design |
| `skills/subagent-driven-development/external-reviewer-prompt.md` | **New** — Sonnet external reviewer prompt template |
| `skills/requesting-code-review/SKILL.md` | Sync review dimension descriptions for consistency |

**Not changed:**
- `implementer-prompt.md` — implementer workflow unchanged
- `spec-reviewer-prompt.md` — spec compliance logic unchanged
- `executing-plans/SKILL.md` — no subagent review mechanism
- `codex-plugin-cc` — used as-is via `/codex:review`
