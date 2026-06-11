#!/usr/bin/env bash
# Assertion helpers for the test runner.
#
# Each assertion writes its result to $TEST_FAIL_MSG on failure and returns 1.
# Tests collect failures rather than aborting on first miss so a single run
# surfaces all problems for a given case.

TEST_FAIL_MSG=""

_fail() {
    TEST_FAIL_MSG+="${TEST_FAIL_MSG:+
}  $1"
    return 1
}

assert_eq() {
    local want="$1" got="$2" label="${3:-equality}"
    if [ "$want" != "$got" ]; then
        _fail "$label: want=<${want}> got=<${got}>"
    fi
}

assert_exit_code() {
    local want="$1" got="$2"
    if [ "$want" != "$got" ]; then
        _fail "exit code: want=${want} got=${got}"
    fi
}

assert_stdout_eq() {
    local want="$1" got="$2"
    if [ "$want" != "$got" ]; then
        _fail "stdout: want=<${want}> got=<${got}>"
    fi
}

assert_stdout_contains() {
    local needle="$1" haystack="$2"
    if [[ "$haystack" != *"$needle"* ]]; then
        _fail "stdout missing <${needle}>: got=<${haystack}>"
    fi
}

assert_stdout_empty() {
    local got="$1"
    if [ -n "$got" ]; then
        _fail "stdout: want=<empty> got=<${got}>"
    fi
}

assert_file_exists() {
    local path="$1"
    if [ ! -f "$path" ]; then
        _fail "file missing: $path"
    fi
}

assert_file_absent() {
    local path="$1"
    if [ -f "$path" ]; then
        _fail "file should be absent: $path"
    fi
}

assert_file_contains() {
    local path="$1" needle="$2"
    if [ ! -f "$path" ]; then
        _fail "file missing: $path"
        return 1
    fi
    if ! grep -q -- "$needle" "$path"; then
        _fail "file <${path}> missing pattern <${needle}>: $(head -c 200 "$path")"
    fi
}

# Assert the mock cmux saw a call whose first arg is the given subcommand and
# whose joined args contain the given substring.
assert_cmux_called_with() {
    local subcmd="$1" substr="${2:-}"
    if [ ! -f "$MOCK_CMUX_LOG" ]; then
        _fail "mock cmux log missing"
        return 1
    fi
    while IFS=$'\t' read -r got_subcmd rest_of_line; do
        if [ "$got_subcmd" = "$subcmd" ]; then
            if [ -z "$substr" ] || [[ "$rest_of_line" == *"$substr"* ]]; then
                return 0
            fi
        fi
    done < "$MOCK_CMUX_LOG"
    _fail "expected cmux call: ${subcmd} containing <${substr}>; log:
$(sed 's/^/    /' "$MOCK_CMUX_LOG")"
}

assert_cmux_not_called() {
    local subcmd="$1"
    if [ ! -f "$MOCK_CMUX_LOG" ]; then
        return 0
    fi
    if cut -f1 < "$MOCK_CMUX_LOG" | grep -qx "$subcmd"; then
        _fail "cmux ${subcmd} should not have been called; log:
$(sed 's/^/    /' "$MOCK_CMUX_LOG")"
    fi
}
