#!/usr/bin/env bash
# Read text from stdin, locate the LAST non-blank line, and check whether
# (after stripping leading whitespace) it equals exactly one of:
#   "VERDICT: APPROVED"  -> stdout "APPROVED", exit 0
#   "VERDICT: REVISE"    -> stdout "REVISE",   exit 0
# Otherwise: stdout "UNKNOWN", exit 1.
#
# Strict matching: exact case, exactly one space after the colon, no trailing
# garbage on that line. The reviewer prompt asks for this exact format, so any
# deviation indicates a prompt failure that the caller must surface.

set -u

last_nonblank=""
while IFS= read -r line || [[ -n "$line" ]]; do
    # Trim CR (in case of CRLF input from some terminals)
    line="${line%$'\r'}"
    # Update only if the line has at least one non-whitespace char
    if [[ -n "${line//[[:space:]]/}" ]]; then
        last_nonblank="$line"
    fi
done

# Strip leading whitespace from candidate
trimmed="${last_nonblank#"${last_nonblank%%[![:space:]]*}"}"

case "$trimmed" in
    "VERDICT: APPROVED")
        printf 'APPROVED\n'
        exit 0
        ;;
    "VERDICT: REVISE")
        printf 'REVISE\n'
        exit 0
        ;;
    *)
        printf 'UNKNOWN\n'
        exit 1
        ;;
esac
