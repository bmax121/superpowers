---
description: "Resume an in-progress plan from a long-context checkpoint. Usage: /resume-plan <path-to-checkpoint.json>. Omit the path to auto-discover the most recent unfinished checkpoint in docs/superpowers/checkpoints/."
---

You were asked to resume a superpowers plan from a checkpoint. Do this now, in this order, before any other action:

1. Invoke the **`superpowers:long-context-checkpoint`** skill via the Skill tool. Its SKILL.md has the full resume procedure.

2. Parse the argument passed after `/resume-plan`:
   - If a path was given, use it as the checkpoint file.
   - If no path was given, auto-discover:
     - `ls docs/superpowers/checkpoints/*-checkpoint.json 2>/dev/null`
     - If exactly one file exists and it has at least one task with `status != "done"`, use it.
     - If multiple candidates, list them and ask the user which to resume — this is one of the four hard gates where asking is required (you cannot pick the wrong plan silently).
     - If none exist, tell the user "no unfinished checkpoints found" and stop.

3. Follow the "Resuming in a New Session" section of the `long-context-checkpoint` skill:
   - Read the checkpoint JSON.
   - Verify the worktree path exists; cd into it (or prompt the user to).
   - Rebuild TodoWrite from the checkpoint's `todos` + remaining `tasks`.
   - **Do not re-run** provider detection or Reviewer B detection — reuse the cached values.
   - Print the "Resumed from checkpoint" banner.
   - Continue `superpowers:subagent-driven-development` from the first task whose `status != "done"`, resuming at the recorded `stage` if any.

4. After banner, hand off to `superpowers:subagent-driven-development` for the remaining tasks.

If the checkpoint file is missing, malformed, schema_version unknown, or the worktree no longer exists, STOP and report the specific failure — do not attempt partial recovery.
