#!/usr/bin/env bash
# Plain bash test runner for parse-verdict.sh.
# Exit status: 0 if all pass, 1 if any fail.

set -u
SCRIPT="$(cd "$(dirname "$0")"/.. && pwd)/skills/fusion/lib/parse-verdict.sh"
FAIL=0
PASS=0

# Args: <description> <expected_stdout> <expected_exit> <input_text>
assert_case() {
    local desc="$1" expected_out="$2" expected_exit="$3" input="$4"
    local actual_out actual_exit
    actual_out="$(printf '%s' "$input" | bash "$SCRIPT" 2>/dev/null)"
    actual_exit=$?
    if [[ "$actual_out" == "$expected_out" && "$actual_exit" == "$expected_exit" ]]; then
        PASS=$((PASS+1))
        printf '  PASS: %s\n' "$desc"
    else
        FAIL=$((FAIL+1))
        printf '  FAIL: %s\n    expected: out=%q exit=%s\n    got:      out=%q exit=%s\n' \
            "$desc" "$expected_out" "$expected_exit" "$actual_out" "$actual_exit"
    fi
}

assert_case "approved on last line" \
    "APPROVED" "0" \
    "Some review text
More text
VERDICT: APPROVED"

assert_case "revise on last line" \
    "REVISE" "0" \
    "Issues found:
- BLOCKER: foo
VERDICT: REVISE"

assert_case "approved with trailing blank lines" \
    "APPROVED" "0" \
    "review
VERDICT: APPROVED


"

assert_case "marker not on last non-blank line is unknown" \
    "UNKNOWN" "1" \
    "VERDICT: APPROVED
some trailing chatter"

assert_case "no marker at all is unknown" \
    "UNKNOWN" "1" \
    "Just a normal review without verdict."

assert_case "lowercase verdict is unknown (we require exact)" \
    "UNKNOWN" "1" \
    "verdict: approved"

assert_case "extra spaces after colon is unknown (strict match)" \
    "UNKNOWN" "1" \
    "VERDICT:  APPROVED"

assert_case "leading whitespace on marker line is trimmed" \
    "APPROVED" "0" \
    "review text
   VERDICT: APPROVED"

assert_case "single-line approved input" \
    "APPROVED" "0" \
    "VERDICT: APPROVED"

assert_case "trailing whitespace on APPROVED marker is unknown (strict)" \
    "UNKNOWN" "1" \
    "review text
VERDICT: APPROVED   "

assert_case "trailing whitespace on REVISE marker is unknown (strict)" \
    "UNKNOWN" "1" \
    "issues:
VERDICT: REVISE   "

assert_case "leading whitespace on REVISE marker is trimmed" \
    "REVISE" "0" \
    "review text
   VERDICT: REVISE"

assert_case "empty input is unknown" \
    "UNKNOWN" "1" \
    ""

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
