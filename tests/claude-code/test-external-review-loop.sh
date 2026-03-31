#!/usr/bin/env bash
# Test: external review loop feature in subagent-driven-development
# Verifies three-stage review, external reviewer prompt, and Codex integration
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/test-helpers.sh"

# Case-insensitive assert_contains wrapper
assert_contains_ci() {
    local output="$1"
    local pattern="$2"
    local test_name="${3:-test}"

    if echo "$output" | grep -iq "$pattern"; then
        echo "  [PASS] $test_name"
        return 0
    else
        echo "  [FAIL] $test_name"
        echo "  Expected to find (case-insensitive): $pattern"
        echo "  In output:"
        echo "$output" | sed 's/^/    /' | head -20
        return 1
    fi
}

echo "=== Test: External Review Loop ==="
echo ""

# Test 1: Three-stage review is recognized
echo "Test 1: Three-stage review recognition..."

output=$(run_claude "In the subagent-driven-development skill, how many review stages are there per task? List each stage in order." 60)

if assert_contains_ci "$output" "three\|3" "Mentions three stages"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "spec.*compliance" "Mentions spec compliance stage"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "code.*quality" "Mentions code quality stage"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "external.*review\|cross-model\|sonnet.*codex" "Mentions external review stage"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 2: Review stage ordering
echo "Test 2: Review stage ordering (spec → quality → external)..."

output=$(run_claude "In subagent-driven-development, list the three review stages in order, numbered 1 2 3." 60)

if assert_contains_ci "$output" "spec.*compliance" "Spec compliance present"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "code.*quality" "Code quality present"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "external\|cross-model" "External review present"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 3: External review uses Sonnet + Codex in parallel
echo "Test 3: Sonnet + Codex parallel dispatch..."

output=$(run_claude "In the external review loop of subagent-driven-development, which reviewers are used and how are they dispatched? Are they sequential or parallel?" 60)

if assert_contains_ci "$output" "sonnet" "Mentions Sonnet"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "codex" "Mentions Codex"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "parallel\|simultaneously\|same time\|concurrent" "Dispatched in parallel"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 4: External review exit condition
echo "Test 4: External review exit condition..."

output=$(run_claude "In subagent-driven-development, what is the exit condition for the external review loop? What happens if only one reviewer approves?" 60)

if assert_contains_ci "$output" "both" "Both must approve"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 5: External reviewer prompt exists and focuses on blind spots
echo "Test 5: External reviewer prompt focus areas..."

output=$(run_claude "What does the external reviewer in subagent-driven-development focus on? What are its specific review areas?" 60)

if assert_contains_ci "$output" "blind spot\|blind spots\|missed\|miss" "Focuses on blind spots"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "security" "Includes security review"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 6: Code quality review expanded dimensions
echo "Test 6: Code quality review expanded dimensions..."

output=$(run_claude "What dimensions does the code quality reviewer check in subagent-driven-development? List all review areas." 60)

if assert_contains_ci "$output" "performance" "Includes performance"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "consistency" "Includes consistency"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "design" "Includes design"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 7: Feedback merge and fix loop
echo "Test 7: Feedback merge and fix loop..."

output=$(run_claude "In subagent-driven-development, when external reviewers find issues, what happens? How is feedback from multiple reviewers handled?" 60)

if assert_contains_ci "$output" "merge\|combined\|consolidat\|dedup" "Feedback is merged"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "implementer\|fix" "Implementer fixes issues"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 8: Red flags about external review
echo "Test 8: External review red flags..."

output=$(run_claude "What are the red flags or 'never do' rules about external review in subagent-driven-development? List the rules about skipping external review or proceeding with partial approval." 60)

if assert_contains_ci "$output" "skip\|never\|mandatory\|must not" "Cannot skip external review"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "both.*approve\|both.*must\|both.*sonnet\|both.*pass" "Both reviewers must approve"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 9: Codex integration via /codex:review
echo "Test 9: Codex integration mechanism..."

output=$(run_claude "How does the subagent-driven-development skill integrate with Codex for external review? What commands are used?" 60)

if assert_contains_ci "$output" "codex:review\|codex-plugin\|/codex" "Uses /codex:review"; then
    : # pass
else
    exit 1
fi

echo ""

# Test 10: Prompt templates list includes external reviewer
echo "Test 10: Prompt template listing..."

output=$(run_claude "List all prompt templates used by the subagent-driven-development skill." 60)

if assert_contains_ci "$output" "external-reviewer-prompt\|external.*reviewer.*prompt" "External reviewer prompt listed"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "implementer-prompt\|implementer.*prompt" "Implementer prompt listed"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "spec-reviewer-prompt\|spec.*reviewer.*prompt" "Spec reviewer prompt listed"; then
    : # pass
else
    exit 1
fi

if assert_contains_ci "$output" "code-quality-reviewer-prompt\|code.*quality.*reviewer" "Code quality reviewer prompt listed"; then
    : # pass
else
    exit 1
fi

echo ""

echo "=== All external review loop tests passed ==="
