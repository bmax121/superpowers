# Unified Reviewer Subagent Prompt Template

A single reviewer that covers **all dimensions in one dispatch**:
spec compliance, code quality, test coverage depth, architecture/design,
security, and cross-model blind-spot review. Replaces the prior three-stage
chain (spec reviewer → code-quality reviewer → external Reviewer A + B).

**Why one reviewer instead of four:** four dispatches per task is ~4×
cost and ~4× wall-clock, and the reviewers' findings overlap heavily in
practice. A single well-prompted reviewer with a structured output
schema covers the same ground at a fraction of the cost. Cross-model
diversity is preserved through provider fallback (see "Reviewer
Provider" below) — when codex/gemini are available, the reviewer
naturally runs in a non-Anthropic family for a single task.

```
Task tool (general-purpose, model: <provider-default>):
  description: "Review Task N: [task name]"
  prompt: |
    You are the unified reviewer for Task N: [task name].

    ## Task Description (what was requested)

    [FULL TEXT of task from plan — paste verbatim]

    ## Implementation Reported

    [Implementer's full Output Protocol report — Status/Files/Tests/
    Concerns + ---REPORT--- narrative — paste verbatim]

    ## Diff to Review

    [Output of `git diff <BASE_SHA>..<HEAD_SHA>` for files in the
    implementer's Files: list — paste, do not ask the subagent to
    git diff itself]

    ## Project Context

    [3-5 lines: language, framework, important conventions in this repo
    that a reviewer needs to know — e.g. "Go 1.22; we use table-driven
    tests; never panic in library code; storage layer is in pkg/store/"]

    ## Your Job

    Review the diff against the spec across SIX dimensions. Output a
    single structured report. Do NOT take more than one pass; if a
    dimension is non-applicable say so explicitly with a short reason.

    ### Dimension A — Spec Compliance

    Does the diff implement EXACTLY what the task says?
    - Anything missing from the spec?
    - Anything extra (over-build) the spec did not ask for?
    - Did the implementer interpret an ambiguous requirement
      defensibly? (If yes, note the interpretation.)

    ### Dimension B — Code Quality

    - Names match what things do (not how they work).
    - No dead code, no unused parameters, no commented-out blocks.
    - Errors handled at the right boundary; no try/except that
      swallows errors.
    - Magic numbers extracted to named constants when used > 1×.
    - Consistent with existing patterns in this codebase (see
      Project Context above).

    ### Dimension C — Test Coverage Depth

    Refer to `superpowers:test-driven-development` → "Test Coverage
    Layers" and "Boundary / Stress / Concurrency".

    - Three layers (unit / integration / E2E) appropriate to the
      surface area of this code? Pure unit tests insufficient if the
      code talks to DBs, queues, or HTTP services.
    - Boundary tests (null / empty / max / invalid / date-edge) for
      every public function?
    - Latency-sensitive code: stress test with concrete p99 or
      throughput assertion?
    - Concurrency or shared state: race-detector test? (`go test
      -race`, `loom`, Thread Sanitizer, JCStress, etc.)
    - "Not applicable" without a concrete reason = Important issue.

    ### Dimension D — Architecture & Design

    - Each new file has one clear responsibility.
    - Abstraction levels appropriate; not over- or under-engineered.
    - Dependency direction correct (no cycles, no upward references).
    - Interfaces well-defined; consumers don't need internals.

    ### Dimension E — Performance

    - No N+1 queries, unbounded loops, or accidental quadratic
      complexity in hot paths.
    - Data structure choices match access patterns.
    - No obvious bottlenecks for the workload this code targets.

    ### Dimension F — Security & Blind Spots

    Take this with FRESH EYES. Imagine you didn't write this; you're
    a security reviewer with no investment in the implementation.

    - Input validation at boundaries (network, file, env)?
    - Auth/authz checks where they belong?
    - Secrets handling (no logging of tokens, no hard-coded creds)?
    - Race conditions in shared-state code?
    - Memory safety (for unsafe languages)?
    - Cross-model blind-spot: anything the same model that wrote this
      might have missed because of consistent reasoning bias?

    ## Triage hints

    Classify each finding by severity:
    - **Critical**: security, correctness, data loss, or violates
      spec acceptance criteria. MUST fix before approving.
    - **Important**: clear quality/coverage gap with no rationale.
      SHOULD fix unless rejected with reason.
    - **Minor**: style, naming, micro-perf. May reject as YAGNI.

    Skip dimensions that genuinely don't apply — e.g. Dimension F is
    not applicable to a pure-math utility with no I/O. State
    "(not applicable: <reason>)" instead of leaving blank.

    ## Output Protocol (MACHINE-PARSEABLE HEADER REQUIRED)

    Start your report with EXACTLY these lines, in order, no preamble,
    no markdown fence:

    ```
    Status: APPROVED
    Spec: ✓
    Quality: ✓
    Coverage: ✓
    Architecture: ✓
    Performance: ✓
    Security: ✓
    Findings:
      Critical: (none)
      Important: (none)
      Minor: (none)
    ---REPORT---
    <free-form narrative explaining what you checked, what you found,
    and what you decided>
    ```

    Rules:
    - Status: exactly one of `APPROVED` | `NEEDS_FIX`
    - Each dimension line: `✓` | `✗` | `(not applicable: <reason>)`.
      Use `✗` if any finding in that dimension is Important or Critical.
    - Findings: exactly three named buckets. Each bucket either
      `(none)` OR a comma-separated list with file:line citations
      where possible:
      ```
      Critical: utils.ts:45 — race condition on shared cache write
      Important: server.py:120 — missing input validation on /search?q=
      Minor: (none)
      ```
    - Use NEEDS_FIX when ANY Critical or Important finding exists.
    - Status MUST agree with Findings. APPROVED with Critical = bug.
    - The narrative goes BELOW `---REPORT---`, never above the headers.
```

## Reviewer Provider (model selection)

The unified reviewer uses the same model-routing infrastructure as the
implementer (see `Model Selection` section in `SKILL.md`), with one
deliberate twist: **the reviewer should run in a different family than
the implementer when possible**, to preserve the cross-model
blind-spot-catching value the old "Reviewer A + B" chain provided.

Routing rules (from `config/models.yaml`'s `reviewer` tier, fallback
chain):

```yaml
tiers:
  reviewer:
    # Default — Sonnet for cost/speed; reviewer is judgment-heavy
    # so we don't go to Haiku.
    - provider: anthropic
      model: sonnet
    # Cross-family fallback when Anthropic unavailable / for diversity
    - provider: codex
      model: gpt-5.4
    - provider: gemini-cli
      model: gemini-2.5-pro
    # Last resort same-family
    - provider: anthropic
      model: opus
```

**When the implementer ran on a non-Anthropic provider** (e.g. Codex
GPT), the reviewer prefers Anthropic Sonnet (different family) for
diversity. The controller MAY swap the chain order at dispatch time
based on the implementer's `provider_used` recorded in the checkpoint.

## Triage after the reviewer returns

The controller applies the same autonomous rule matrix as before
(`subagent-driven-development/SKILL.md` → "Autonomous Feedback
Triage"). With unified output:

- All `Critical` findings auto-triage as **Valid** → dispatch
  implementer to fix.
- `Important` findings: apply the matrix (security/correctness =
  Valid; convention conflict = Rejected; design trade-off = Deferred).
- `Minor` findings: default Rejected unless < 30 lines to fix.
- Every decision logged to `checkpoint.decisions_log` with
  `stage: review_triage` and rationale.

Re-dispatch implementer for valid findings. Re-run unified reviewer.
Loop until Status: APPROVED OR all remaining findings are
rejected/deferred (with audit trail).

## Migration from three-stage

The legacy three prompts remain in the directory but are not invoked
by 6.2.0+ controllers:

- `./spec-reviewer-prompt.md` — superseded by Dimension A
- `./code-quality-reviewer-prompt.md` — superseded by Dimensions B/C/D/E
- `./external-reviewer-prompt.md` — superseded by Dimension F + provider
  routing

They are kept for reference and for users running 6.0/6.1 controllers
against new plans. They can be deleted in 7.0.0.
