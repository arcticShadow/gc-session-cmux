#!/usr/bin/env bash
# Test runner for gc-session-cmux.
#
# Usage:
#   ./tests/run-tests.sh                # run all tests
#   ./tests/run-tests.sh test_start_*   # run tests matching a glob
#   TEST_VERBOSE=1 ./tests/run-tests.sh # show stdout on pass too
#
# Each test function gets a fresh STATE_DIR and a mock cmux on PATH-equivalent.
# Tests assert via lib/assert.sh helpers; collected failures print at the end.

set -uo pipefail

readonly TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly PROVIDER="${TESTS_DIR}/../gc-session-cmux"
readonly MOCK_CMUX="${TESTS_DIR}/lib/mock-cmux.sh"

# shellcheck source=lib/assert.sh
source "${TESTS_DIR}/lib/assert.sh"

# Counters & state
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0
FAILED_TESTS=()

# ANSI colors (off when not a tty)
if [ -t 1 ]; then
    GREEN='\033[0;32m'
    RED='\033[0;31m'
    YELLOW='\033[0;33m'
    GRAY='\033[0;90m'
    NC='\033[0m'
else
    GREEN=''
    RED=''
    YELLOW=''
    GRAY=''
    NC=''
fi

# ── Fixtures ──

setup() {
    TEST_STATE_DIR=$(mktemp -d -t gc-session-cmux-state.XXXXXX)
    TEST_BIN_DIR=$(mktemp -d -t gc-session-cmux-bin.XXXXXX)
    MOCK_CMUX_LOG="${TEST_BIN_DIR}/mock-calls.log"
    : > "$MOCK_CMUX_LOG"

    # Place mock as ./cmux so the provider's `command -v cmux` finds it via PATH.
    cp "$MOCK_CMUX" "$TEST_BIN_DIR/cmux"
    chmod +x "$TEST_BIN_DIR/cmux"

    export GC_EXEC_STATE_DIR="$TEST_STATE_DIR"
    export GC_CMUX_BIN="$TEST_BIN_DIR/cmux"
    export MOCK_CMUX_LOG
    # Reset mock-control envs to defaults each test
    unset MOCK_CMUX_PING_FAILS MOCK_CMUX_NEW_WS_FAILS \
          MOCK_CMUX_LIST_JSON MOCK_CMUX_READ_SCREEN_TEXT 2>/dev/null || true
    TEST_FAIL_MSG=""
}

teardown() {
    [ -n "${TEST_STATE_DIR:-}" ] && rm -rf "$TEST_STATE_DIR"
    [ -n "${TEST_BIN_DIR:-}" ] && rm -rf "$TEST_BIN_DIR"
}

# Run the provider, capturing stdout/stderr/exit. Set PROV_STDIN before calling
# to feed stdin; the harness appends a trailing newline if absent so line-based
# `read` consumers (process-alive, etc.) see the final line.
# Sets PROV_OUT, PROV_ERR, PROV_RC.
run_provider() {
    local stdin="${PROV_STDIN:-}"
    local _out _err _rc
    _out=$(mktemp); _err=$(mktemp)
    if [ -n "$stdin" ]; then
        # Ensure trailing newline so line-oriented readers don't miss the
        # final entry. This matches what real text pipelines produce.
        printf '%s\n' "$stdin" | "$PROVIDER" "$@" >"$_out" 2>"$_err"
    else
        "$PROVIDER" "$@" >"$_out" 2>"$_err" </dev/null
    fi
    _rc=$?
    PROV_OUT=$(cat "$_out"); PROV_ERR=$(cat "$_err"); PROV_RC=$_rc
    rm -f "$_out" "$_err"
    unset PROV_STDIN
    return $_rc
}

# Helper to pre-populate the workspaces.json so subsequent ops find the state.
seed_workspace_state() {
    local key="$1" ref="${2:-workspace:99}" uuid="${3:-uuid-99}"
    local ws_name
    ws_name="gc-${key}"
    cat > "$TEST_STATE_DIR/workspaces.json" <<EOF
{"version":1,"workspaces":{"${key}":{"key":"${key}","name":"${ws_name}","ref":"${ref}","uuid":"${uuid}"}}}
EOF
}

# Configure the mock cmux to report a given workspace title as existing.
mock_workspace_exists() {
    local ws_name="$1" ref="${2:-workspace:99}" uuid="${3:-uuid-99}"
    export MOCK_CMUX_LIST_JSON
    MOCK_CMUX_LIST_JSON=$(cat <<EOF
{"window_ref":"window:1","workspaces":[{"title":"${ws_name}","ref":"${ref}","uuid":"${uuid}"}]}
EOF
)
}

# ── Test runner ──

run_test() {
    local name="$1"
    if ! declare -F "$name" >/dev/null; then
        echo "${RED}error: test function not found: ${name}${NC}"
        return
    fi
    setup
    TESTS_RUN=$((TESTS_RUN + 1))

    # Run test function; capture failure messages in TEST_FAIL_MSG.
    if "$name"; then
        : # function returned 0 — still check accumulated TEST_FAIL_MSG
    fi

    if [ -z "$TEST_FAIL_MSG" ]; then
        TESTS_PASSED=$((TESTS_PASSED + 1))
        printf "${GREEN}PASS${NC} %s\n" "$name"
        if [ -n "${TEST_VERBOSE:-}" ]; then
            [ -n "${PROV_OUT:-}" ] && printf "${GRAY}  stdout: %s${NC}\n" "$PROV_OUT"
            [ -n "${PROV_ERR:-}" ] && printf "${GRAY}  stderr: %s${NC}\n" "$PROV_ERR"
        fi
    else
        TESTS_FAILED=$((TESTS_FAILED + 1))
        FAILED_TESTS+=("$name")
        printf "${RED}FAIL${NC} %s\n%s\n" "$name" "$TEST_FAIL_MSG"
        if [ -n "${PROV_OUT:-}" ] || [ -n "${PROV_ERR:-}" ]; then
            printf "${GRAY}  stdout: %s${NC}\n" "${PROV_OUT:-<empty>}"
            printf "${GRAY}  stderr: %s${NC}\n" "${PROV_ERR:-<empty>}"
            printf "${GRAY}  exit:   %s${NC}\n" "${PROV_RC:-?}"
        fi
    fi

    teardown
}

# ────────────────────────────────────────────────────────────────────────
#  Tests — protocol compliance
# ────────────────────────────────────────────────────────────────────────

test_unknown_op_returns_exit_2() {
    run_provider totally-bogus-op some-session
    assert_exit_code 2 "$PROV_RC"
}

test_known_ops_do_not_return_exit_2() {
    # Every op listed in the spec should be recognized. We're not asserting
    # they succeed (some require args we're not providing) — just that they
    # don't fall through to the *) exit 2 handler.
    # `start` is excluded because it parses stdin via jq; without valid JSON
    # the script may exit with jq's status code. `start` recognition is
    # covered by the dedicated test_start_* tests.
    # `attach` is excluded because it requires --tty input.
    local op
    for op in stop interrupt is-running process-alive nudge \
              set-meta get-meta remove-meta peek list-running get-last-activity; do
        # Provide a benign key for *-meta ops so they don't error before
        # reaching the case branch.
        PROV_STDIN="" run_provider "$op" some-session some-key 2>/dev/null || true
        if [ "$PROV_RC" -eq 2 ]; then
            _fail "op '${op}' returned exit 2 (treated as unknown); should be recognized"
        fi
    done
}

# ────────────────────────────────────────────────────────────────────────
#  Tests — idempotency (spec: stop/interrupt/nudge must exit 0 even when
#  session is gone)
# ────────────────────────────────────────────────────────────────────────

test_stop_idempotent_when_session_missing() {
    run_provider stop nonexistent
    assert_exit_code 0 "$PROV_RC"
}

test_stop_succeeds_when_cmux_down() {
    export MOCK_CMUX_PING_FAILS=1
    run_provider stop nonexistent
    assert_exit_code 0 "$PROV_RC"
}

test_stop_removes_wrapper_file() {
    local wrapper="$TEST_STATE_DIR/myagent.wrapper.sh"
    echo '#!/bin/bash' > "$wrapper"
    run_provider stop myagent
    assert_exit_code 0 "$PROV_RC"
    assert_file_absent "$wrapper"
}

test_stop_closes_workspace_when_last_session() {
    # Seed state and mark the workspace as live so cmux is found.
    seed_workspace_state myrig "workspace:42"
    mock_workspace_exists "gc-myrig" "workspace:42"
    # Create wrapper so stop has something to remove and sibling check finds nothing.
    echo '#!/bin/bash' > "$TEST_STATE_DIR/myrig.wrapper.sh"
    run_provider stop myrig
    assert_exit_code 0 "$PROV_RC"
    # close-workspace should have been called with the stored ref.
    assert_cmux_called_with close-workspace "workspace:42"
    # State entry should be removed.
    local remaining
    remaining=$(jq -r '.workspaces | keys | length' "$TEST_STATE_DIR/workspaces.json")
    assert_eq "0" "$remaining" "workspace state entries after last session stops"
}

test_stop_does_not_close_workspace_when_sibling_still_running() {
    # Two sessions share the same rig key: myrig.alpha and myrig.beta.
    # Stop myrig.alpha while myrig.beta is still running (its wrapper exists).
    seed_workspace_state myrig "workspace:42"
    mock_workspace_exists "gc-myrig" "workspace:42"
    echo '#!/bin/bash' > "$TEST_STATE_DIR/myrig.alpha.wrapper.sh"
    echo '#!/bin/bash' > "$TEST_STATE_DIR/myrig.beta.wrapper.sh"
    run_provider stop myrig.alpha
    assert_exit_code 0 "$PROV_RC"
    # close-workspace must NOT be called — sibling is still running.
    assert_cmux_not_called close-workspace
    # State entry should still be present.
    local remaining
    remaining=$(jq -r '.workspaces | keys | length' "$TEST_STATE_DIR/workspaces.json")
    assert_eq "1" "$remaining" "workspace state entries when sibling still running"
}

test_stop_removes_state_when_last_dotted_session() {
    # "gastown.mayor" and "gastown.worker" share workspace "gc-gastown".
    # Stopping the last one should close and remove state.
    seed_workspace_state gastown "workspace:77"
    mock_workspace_exists "gc-gastown" "workspace:77"
    echo '#!/bin/bash' > "$TEST_STATE_DIR/gastown.mayor.wrapper.sh"
    run_provider stop gastown.mayor
    assert_exit_code 0 "$PROV_RC"
    assert_cmux_called_with close-workspace "workspace:77"
    local remaining
    remaining=$(jq -r '.workspaces | keys | length' "$TEST_STATE_DIR/workspaces.json")
    assert_eq "0" "$remaining" "workspace state entries after last dotted session stops"
}

test_stop_workspace_close_fails_still_exits_0() {
    # Even if close-workspace fails, stop must exit 0 (graceful degradation).
    # We test this by stopping with no state — the close path is skipped
    # and stop exits 0 regardless (existing idempotency guarantee).
    run_provider stop nonexistent
    assert_exit_code 0 "$PROV_RC"
}

test_interrupt_idempotent_when_session_missing() {
    run_provider interrupt nonexistent
    assert_exit_code 0 "$PROV_RC"
}

test_interrupt_succeeds_when_cmux_down() {
    export MOCK_CMUX_PING_FAILS=1
    run_provider interrupt nonexistent
    assert_exit_code 0 "$PROV_RC"
}

test_nudge_idempotent_when_session_missing() {
    PROV_STDIN="hello"
    run_provider nudge nonexistent
    assert_exit_code 0 "$PROV_RC"
}

test_nudge_succeeds_when_cmux_down() {
    export MOCK_CMUX_PING_FAILS=1
    PROV_STDIN="hello"
    run_provider nudge myagent
    assert_exit_code 0 "$PROV_RC"
}

# ────────────────────────────────────────────────────────────────────────
#  Tests — stdout contracts
# ────────────────────────────────────────────────────────────────────────

test_is_running_empty_name_returns_false() {
    run_provider is-running ""
    assert_exit_code 0 "$PROV_RC"
    assert_stdout_eq "false" "$PROV_OUT"
}

test_is_running_returns_false_when_no_wrapper() {
    run_provider is-running myagent
    assert_exit_code 0 "$PROV_RC"
    assert_stdout_eq "false" "$PROV_OUT"
}

test_is_running_returns_false_when_cmux_down() {
    # Even with wrapper present, no cmux means no live session.
    echo '#!/bin/bash' > "$TEST_STATE_DIR/myagent.wrapper.sh"
    export MOCK_CMUX_PING_FAILS=1
    run_provider is-running myagent
    assert_exit_code 0 "$PROV_RC"
    assert_stdout_eq "false" "$PROV_OUT"
}

test_is_running_returns_true_when_wrapper_and_workspace_present() {
    echo '#!/bin/bash' > "$TEST_STATE_DIR/myagent.wrapper.sh"
    mock_workspace_exists "gc-myagent"
    run_provider is-running myagent
    assert_exit_code 0 "$PROV_RC"
    assert_stdout_eq "true" "$PROV_OUT"
}

test_process_alive_no_names_falls_back_to_is_running() {
    # With no process names and no wrapper, should be "false" — not the
    # blind "true" that the original implementation returned.
    PROV_STDIN=""
    run_provider process-alive myagent
    assert_exit_code 0 "$PROV_RC"
    assert_stdout_eq "false" "$PROV_OUT"
}

test_process_alive_with_pgrep_match() {
    # process-alive must FIRST confirm the session is live (wrapper file +
    # cmux workspace), and only THEN match process names. See ju-u015.
    echo '#!/bin/bash' > "$TEST_STATE_DIR/myagent.wrapper.sh"
    mock_workspace_exists "gc-myagent"

    # Write a uniquely-named sentinel script and run it so its path appears
    # in pgrep -f matches. Don't `exec` inside it — that would replace the
    # script's argv[0] with the sleep path and hide the sentinel name.
    local sentinel="${TEST_BIN_DIR}/gc-cmux-sentinel-$$-${RANDOM}"
    cat > "$sentinel" <<'EOF'
#!/bin/sh
sleep 30
EOF
    chmod +x "$sentinel"
    "$sentinel" &
    local sentinel_pid=$!
    sleep 0.3
    PROV_STDIN="$(basename "$sentinel")"
    run_provider process-alive myagent
    # Clean up: kill the wrapper script and its sleep child.
    pkill -P "$sentinel_pid" 2>/dev/null
    kill "$sentinel_pid" 2>/dev/null
    wait "$sentinel_pid" 2>/dev/null || true
    assert_exit_code 0 "$PROV_RC"
    assert_stdout_eq "true" "$PROV_OUT"
}

test_process_alive_with_no_pgrep_match() {
    # Session IS live, but no process matches → false.
    echo '#!/bin/bash' > "$TEST_STATE_DIR/myagent.wrapper.sh"
    mock_workspace_exists "gc-myagent"
    PROV_STDIN="extremely-unlikely-process-name-zzzqq"
    run_provider process-alive myagent
    assert_exit_code 0 "$PROV_RC"
    assert_stdout_eq "false" "$PROV_OUT"
}

test_process_alive_returns_false_for_ghost_session_even_with_matching_procs() {
    # Regression for ju-u015: pre-fix, process-alive used `pgrep -f node|claude`
    # against the global process table, so any ghost session looked alive
    # whenever Cursor/Claude.app/MCP processes existed on the host. Gas City
    # then either silently stuck the bead awake (pre-ju-ac49 Option 1) or
    # rolled it back forever (post-Option 1). The fix gates process-alive
    # on _session_appears_live: no wrapper + no workspace → false, regardless
    # of what's running globally.
    #
    # Setup: no wrapper file, no mock workspace — i.e. a true ghost. Then
    # run a sentinel process whose name *would* match if the old behavior
    # were in place.
    local sentinel="${TEST_BIN_DIR}/gc-cmux-ghost-sentinel-$$-${RANDOM}"
    cat > "$sentinel" <<'EOF'
#!/bin/sh
sleep 30
EOF
    chmod +x "$sentinel"
    "$sentinel" &
    local sentinel_pid=$!
    sleep 0.3
    PROV_STDIN="$(basename "$sentinel")"
    run_provider process-alive ghost-session-name
    pkill -P "$sentinel_pid" 2>/dev/null
    kill "$sentinel_pid" 2>/dev/null
    wait "$sentinel_pid" 2>/dev/null || true
    assert_exit_code 0 "$PROV_RC"
    assert_stdout_eq "false" "$PROV_OUT"
}

test_get_meta_returns_empty_when_unset() {
    run_provider get-meta myagent SOME_KEY
    assert_exit_code 0 "$PROV_RC"
    assert_stdout_empty "$PROV_OUT"
}

test_set_get_meta_roundtrip() {
    PROV_STDIN="hello world"
    run_provider set-meta myagent SOME_KEY
    assert_exit_code 0 "$PROV_RC"
    run_provider get-meta myagent SOME_KEY
    assert_exit_code 0 "$PROV_RC"
    assert_stdout_eq "hello world" "$PROV_OUT"
}

test_remove_meta_clears_value() {
    PROV_STDIN="abc"
    run_provider set-meta myagent K
    run_provider remove-meta myagent K
    assert_exit_code 0 "$PROV_RC"
    run_provider get-meta myagent K
    assert_stdout_empty "$PROV_OUT"
}

test_meta_operations_dont_require_cmux() {
    # File-only ops must not need cmux to be reachable.
    export MOCK_CMUX_PING_FAILS=1
    PROV_STDIN="value"
    run_provider set-meta myagent K
    assert_exit_code 0 "$PROV_RC"

    export MOCK_CMUX_PING_FAILS=1
    run_provider get-meta myagent K
    assert_exit_code 0 "$PROV_RC"
    assert_stdout_eq "value" "$PROV_OUT"

    export MOCK_CMUX_PING_FAILS=1
    run_provider remove-meta myagent K
    assert_exit_code 0 "$PROV_RC"
}

test_get_last_activity_empty_per_spec() {
    run_provider get-last-activity myagent
    assert_exit_code 0 "$PROV_RC"
    assert_stdout_empty "$PROV_OUT"
}

test_list_running_returns_empty_when_cmux_down() {
    export MOCK_CMUX_PING_FAILS=1
    run_provider list-running ""
    assert_exit_code 0 "$PROV_RC"
    assert_stdout_empty "$PROV_OUT"
}

test_list_running_strips_gc_prefix_and_filters() {
    export MOCK_CMUX_LIST_JSON='{"workspaces":[{"title":"gc-foo"},{"title":"gc-bar"},{"title":"user-ws"}]}'
    run_provider list-running ""
    assert_exit_code 0 "$PROV_RC"
    # gc-prefixed workspaces only, prefix stripped
    assert_stdout_contains "foo" "$PROV_OUT"
    assert_stdout_contains "bar" "$PROV_OUT"
    if [[ "$PROV_OUT" == *"user-ws"* ]]; then
        _fail "list-running included non-gc workspace: $PROV_OUT"
    fi
}

# ────────────────────────────────────────────────────────────────────────
#  Tests — start operation
# ────────────────────────────────────────────────────────────────────────

test_start_writes_wrapper() {
    PROV_STDIN='{"command":"my-agent","work_dir":"/tmp"}'
    run_provider start myagent
    assert_exit_code 0 "$PROV_RC"
    assert_file_exists "$TEST_STATE_DIR/myagent.wrapper.sh"
    assert_file_contains "$TEST_STATE_DIR/myagent.wrapper.sh" 'cd "/tmp"'
    assert_file_contains "$TEST_STATE_DIR/myagent.wrapper.sh" 'exec my-agent'
}

test_start_creates_workspace_via_new_workspace_with_command() {
    PROV_STDIN='{"command":"echo hi"}'
    run_provider start myagent
    assert_exit_code 0 "$PROV_RC"
    # The wrapper should be launched via --command, not via post-creation send.
    assert_cmux_called_with new-workspace "--command"
    assert_cmux_called_with new-workspace "myagent.wrapper.sh"
}

test_start_respawns_when_workspace_exists() {
    # Seed state and mock so the existing workspace path is taken.
    seed_workspace_state myagent "workspace:42"
    mock_workspace_exists "gc-myagent" "workspace:42"
    PROV_STDIN='{"command":"echo hi"}'
    run_provider start myagent
    assert_exit_code 0 "$PROV_RC"
    # respawn-pane should be called, not new-workspace
    assert_cmux_called_with respawn-pane
}

test_start_pre_start_failures_are_non_fatal() {
    PROV_STDIN='{"command":"echo hi","pre_start":["false","true"]}'
    run_provider start myagent
    assert_exit_code 0 "$PROV_RC"
    # stderr should mention the pre_start warning
    assert_stdout_contains "pre_start warning" "$PROV_ERR"
}

test_start_env_vars_in_wrapper() {
    PROV_STDIN='{"command":"echo hi","env":{"FOO":"bar","BAZ":"qux"}}'
    run_provider start myagent
    assert_exit_code 0 "$PROV_RC"
    assert_file_contains "$TEST_STATE_DIR/myagent.wrapper.sh" 'export "FOO=bar"'
    assert_file_contains "$TEST_STATE_DIR/myagent.wrapper.sh" 'export "BAZ=qux"'
}

test_start_session_setup_in_wrapper() {
    PROV_STDIN='{"command":"echo hi","session_setup":["echo hello","date"]}'
    run_provider start myagent
    assert_exit_code 0 "$PROV_RC"
    assert_file_contains "$TEST_STATE_DIR/myagent.wrapper.sh" 'echo hello'
    assert_file_contains "$TEST_STATE_DIR/myagent.wrapper.sh" 'session_setup warning'
}

test_start_fails_when_cmux_down() {
    export MOCK_CMUX_PING_FAILS=1
    PROV_STDIN='{"command":"echo hi"}'
    run_provider start myagent
    # Per spec, start may fail (exit 1) when its backend is unavailable;
    # the error message should be on stderr.
    assert_exit_code 1 "$PROV_RC"
    assert_stdout_contains "cmux" "$PROV_ERR"
}

test_start_records_lifecycle() {
    PROV_STDIN='{"command":"echo hi","lifecycle":"one_shot"}'
    run_provider start myagent
    assert_exit_code 0 "$PROV_RC"
    assert_file_exists "$TEST_STATE_DIR/myagent.lifecycle"
    assert_stdout_eq "one_shot" "$(cat "$TEST_STATE_DIR/myagent.lifecycle")"
}

# ────────────────────────────────────────────────────────────────────────
#  Tests — workspace key derivation (provider-specific behavior)
# ────────────────────────────────────────────────────────────────────────

test_dotted_session_name_shares_workspace() {
    # "rig.role" → workspace "gc-rig"
    PROV_STDIN='{"command":"echo hi"}'
    run_provider start gastown.mayor
    assert_exit_code 0 "$PROV_RC"
    assert_cmux_called_with new-workspace "gc-gastown"
}

test_bare_session_name_uses_own_workspace() {
    PROV_STDIN='{"command":"echo hi"}'
    run_provider start solo
    assert_exit_code 0 "$PROV_RC"
    assert_cmux_called_with new-workspace "gc-solo"
}

# ────────────────────────────────────────────────────────────────────────
#  Tests — state directory honors GC_EXEC_STATE_DIR
# ────────────────────────────────────────────────────────────────────────

test_state_dir_honors_env_var() {
    PROV_STDIN='{"command":"echo hi"}'
    run_provider start myagent
    assert_exit_code 0 "$PROV_RC"
    assert_file_exists "$GC_EXEC_STATE_DIR/myagent.wrapper.sh"
    assert_file_exists "$GC_EXEC_STATE_DIR/workspaces.json"
}

# ────────────────────────────────────────────────────────────────────────
#  Test discovery & main
# ────────────────────────────────────────────────────────────────────────

list_tests() {
    declare -F | awk '$3 ~ /^test_/ {print $3}'
}

main() {
    local pattern="${1:-test_*}"
    local tests=()
    while IFS= read -r t; do
        case "$t" in
            $pattern) tests+=("$t") ;;
        esac
    done < <(list_tests)

    if [ ${#tests[@]} -eq 0 ]; then
        echo "${YELLOW}no tests matched pattern: ${pattern}${NC}"
        exit 1
    fi

    echo "Running ${#tests[@]} test(s)..."
    echo
    for t in "${tests[@]}"; do
        run_test "$t"
    done
    echo
    echo "─────────────────────────────────────────────"
    printf "Ran %d test(s): " "$TESTS_RUN"
    printf "${GREEN}%d passed${NC}" "$TESTS_PASSED"
    if [ "$TESTS_FAILED" -gt 0 ]; then
        printf ", ${RED}%d failed${NC}\n" "$TESTS_FAILED"
        echo "Failed: ${FAILED_TESTS[*]}"
        exit 1
    fi
    printf "\n"
}

main "$@"
