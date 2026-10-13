#!/bin/bash
# Small assertion helpers shared by the test scripts.

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); echo "  ok   - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL - $1"; [ -n "$2" ] && echo "$2" | sed 's/^/         /'; }

# assert_contains <description> <haystack> <fixed string>
assert_contains() {
    if printf '%s' "$2" | grep -qF -- "$3"; then pass "$1"; else fail "$1" "expected to find: $3"; fi
}

# assert_not_contains <description> <haystack> <fixed string>
assert_not_contains() {
    if printf '%s' "$2" | grep -qF -- "$3"; then fail "$1" "did not expect: $3"; else pass "$1"; fi
}

# assert_equals <description> <actual> <expected>
assert_equals() {
    if [ "$2" == "$3" ]; then pass "$1"; else fail "$1" "expected: $3
actual:   $2"; fi
}

# assert_golden <description> <actual> <expected file>; set UPDATE_GOLDEN=1 to rewrite the file
assert_golden() {
    if [ "${UPDATE_GOLDEN:-0}" == "1" ]; then
        mkdir -p "$(dirname "$3")"
        printf '%s\n' "$2" > "$3"
        pass "$1 (expected output updated)"
    elif [ "$2" == "$(cat "$3" 2>/dev/null)" ]; then
        pass "$1"
    else
        fail "$1" "$(diff <(cat "$3" 2>/dev/null) <(printf '%s\n' "$2") | head -20)"
    fi
}

summary() {
    echo ""
    echo "$PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
}
