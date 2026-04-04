#!/usr/bin/env bash
# Test: subagent-driven-development skill
# Verifies that the skill is loaded and follows correct workflow
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

# All prompts include "Answer in 1-2 sentences." to keep responses short
# and avoid hitting the 300s suite timeout across 9 tests.

echo "=== Test: subagent-driven-development skill ==="
echo ""

# Test 1: Verify skill can be loaded
echo "Test 1: Skill loading..."

output=$(run_claude "What is the subagent-driven-development skill? Answer in 1-2 sentences." 30)

if assert_contains "$output" "subagent-driven-development\|Subagent-Driven Development\|Subagent Driven\|subagent" "Skill is recognized"; then
    : # pass
else
    exit 1
fi

if assert_contains "$output" "plan\|tasks\|dispatch\|implement" "Mentions core concept"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 2: Verify skill describes correct workflow order
echo "Test 2: Workflow ordering..."

output=$(run_claude "In subagent-driven-development, which review comes FIRST: spec compliance or code quality? Answer with just the name." 30)

if assert_contains "$output" "spec\|Spec" "Spec compliance comes first"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 3: Verify self-review is mentioned
echo "Test 3: Self-review requirement..."

output=$(run_claude "Does subagent-driven-development require implementers to self-review? Answer yes/no and what they check, in 1-2 sentences." 30)

if assert_contains "$output" "self-review\|self review\|self.review\|review.*own\|review.*themselves\|[Yy]es" "Mentions self-review"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 4: Verify plan is read once
echo "Test 4: Plan reading efficiency..."

output=$(run_claude "In subagent-driven-development, how many times should the controller read the plan file? Answer in 1 sentence." 30)

if assert_contains "$output" "once\|one time\|single\|one\|1" "Read plan once"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 5: Verify spec compliance reviewer is skeptical
echo "Test 5: Spec compliance reviewer mindset..."

output=$(run_claude "In subagent-driven-development, should the spec reviewer trust the implementer's self-report? Answer in 1-2 sentences." 30)

if assert_contains "$output" "not trust\|don't trust\|skeptical\|independently\|suspiciously\|independent\|not.*rely\|[Nn]o\|should not\|shouldn't" "Reviewer is skeptical"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 6: Verify review loops
echo "Test 6: Review loop requirements..."

output=$(run_claude "In subagent-driven-development, if a reviewer finds issues, is it a one-time review or does it loop? Answer in 1-2 sentences." 30)

if assert_contains "$output" "loop\|again\|repeat\|until.*approved\|until.*compliant\|re-review\|iterate\|cycle" "Review loops mentioned"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 7: Verify full task text is provided
echo "Test 7: Task context provision..."

output=$(run_claude "In subagent-driven-development, does the controller make the implementer read the plan file, or provide task text directly? Answer in 1 sentence." 30)

if assert_contains "$output" "provide.*directly\|full.*text\|paste\|include.*prompt\|inline\|embed\|pass.*context\|provide.*text\|directly\|not.*read" "Provides text directly"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 8: Verify worktree requirement
echo "Test 8: Worktree requirement..."

output=$(run_claude "What skills are required before using subagent-driven-development? Answer in 1-2 sentences." 30)

if assert_contains "$output" "using-git-worktrees\|worktree\|git.*worktree\|isolated" "Mentions worktree requirement"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 9: Verify main branch warning
echo "Test 9: Main branch red flag..."

output=$(run_claude "In subagent-driven-development, is it okay to start on the main branch? Answer in 1 sentence." 30)

if assert_contains "$output" "worktree\|feature.*branch\|not.*main\|never.*main\|avoid.*main\|don't.*main\|consent\|permission\|[Nn]o\|should not\|shouldn't" "Warns against main branch"; then
    : # pass
else
    exit 1
fi

echo ""

echo "=== All subagent-driven-development skill tests passed ==="
