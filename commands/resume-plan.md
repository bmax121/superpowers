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
