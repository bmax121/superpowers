# Code Quality Reviewer Prompt Template

Use this template when dispatching a code quality reviewer subagent.

**Purpose:** Verify implementation is well-built (clean, tested, maintainable, performant, consistent, well-designed)

**Only dispatch after spec compliance review passes.**

```
Task tool (superpowers:code-reviewer):
  Use template at requesting-code-review/code-reviewer.md

  WHAT_WAS_IMPLEMENTED: [from implementer's report]
  PLAN_OR_REQUIREMENTS: Task N from [plan-file]
  BASE_SHA: [commit before task]
  HEAD_SHA: [current commit]
  DESCRIPTION: [task summary]
```

**In addition to standard code quality concerns, the reviewer should check:**
- Does each file have one clear responsibility with a well-defined interface?
- Are units decomposed so they can be understood and tested independently?
- Is the implementation following the file structure from the plan?
- Did this implementation create new files that are already large, or significantly grow existing files? (Don't flag pre-existing file sizes — focus on what this change contributed.)

**Note:** These dimensions supplement the base code-reviewer template. Report findings in the dedicated Performance/Consistency/Design slots in the output format below, not under the generic Issues section. If the base template's Architecture checklist already covers an item, skip it here to avoid duplicate findings.

**Performance:**
- Are there unnecessary repeated computations, N+1 queries, or unbounded loops?
- Are data structure choices appropriate for the access patterns?
- Are there obvious performance bottlenecks?

**Consistency:**
- Do naming, error handling, and logging style match the existing codebase?
- Are API design patterns unified with the rest of the project?
- Does this change introduce conflicting new patterns?

**Design:**
- Are abstraction levels appropriate and responsibilities clear?
- Is the dependency direction correct?
- Is the implementation neither over-engineered nor under-designed?

**Code reviewer returns:**

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
