# gc-session-cmux tests

A self-contained bash test suite covering the [Exec Session Provider
spec](https://docs.gascityhall.com/reference/exec-session-provider) and
this provider's cmux-specific behavior.

## Running

```bash
# All tests
bash tests/run-tests.sh

# Filter by glob
bash tests/run-tests.sh 'test_start_*'

# Verbose (show stdout on pass too)
TEST_VERBOSE=1 bash tests/run-tests.sh
```

Exit code is non-zero on any failure. Suitable for CI.

## What it covers

| Concern | Tests |
| --- | --- |
| Protocol compliance | unknown-op → exit 2; every spec op recognized |
| Idempotency (spec §Conventions) | stop / interrupt / nudge succeed when session missing or cmux down |
| Stdout contracts | is-running / process-alive `true`/`false`; get-meta empty when unset; get-last-activity empty |
| File-only ops | set-meta / get-meta / remove-meta work without cmux |
| Start operation | wrapper generation; env vars; pre_start; session_setup; lifecycle; respawn vs new-workspace path |
| Workspace key derivation | dotted names share workspace; bare names get their own |
| State directory | honors `GC_EXEC_STATE_DIR` |

## How it works

`tests/lib/mock-cmux.sh` is a fake cmux binary that:

- Logs every invocation to `$MOCK_CMUX_LOG` (one TSV line per call).
- Tracks workspaces created via `new-workspace --name` so subsequent
  `list-workspaces --json` returns them.
- Respects env-var knobs for failure modes:
  - `MOCK_CMUX_PING_FAILS=1` — cmux unreachable
  - `MOCK_CMUX_NEW_WS_FAILS=1` — workspace creation fails
  - `MOCK_CMUX_LIST_JSON=<json>` — override the workspace list
  - `MOCK_CMUX_READ_SCREEN_TEXT=<text>` — canned peek output

Each test gets a fresh temp `STATE_DIR` and a fresh `TEST_BIN_DIR`
containing the mock. The provider's `GC_CMUX_BIN` env var points at
the mock, and `GC_EXEC_STATE_DIR` points at the temp state.

Assertions accumulate in `$TEST_FAIL_MSG`; a test "fails" if that
variable is non-empty at the end (rather than aborting on the first
miss), so a single run surfaces all problems in a given case.

## Writing a new test

```bash
test_my_new_thing() {
    # Optional: set up state
    seed_workspace_state myagent "workspace:42"
    mock_workspace_exists "gc-myagent" "workspace:42"

    # Invoke the provider
    PROV_STDIN='{"command":"echo hi"}'
    run_provider start myagent

    # Assert
    assert_exit_code 0 "$PROV_RC"
    assert_cmux_called_with respawn-pane
    assert_file_exists "$TEST_STATE_DIR/myagent.wrapper.sh"
}
```

The runner auto-discovers any function whose name starts with `test_`.

## Available assertion helpers

See `tests/lib/assert.sh`:

- `assert_exit_code <want> <got>`
- `assert_eq <want> <got> [label]`
- `assert_stdout_eq <want> <got>`
- `assert_stdout_contains <needle> <haystack>`
- `assert_stdout_empty <got>`
- `assert_file_exists <path>` / `assert_file_absent <path>`
- `assert_file_contains <path> <pattern>` (grep -q)
- `assert_cmux_called_with <subcmd> [substring]` — checks mock log
- `assert_cmux_not_called <subcmd>`
