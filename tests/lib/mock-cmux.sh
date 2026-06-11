#!/usr/bin/env bash
# Mock cmux binary for tests. Records every invocation to $MOCK_CMUX_LOG and
# returns canned responses driven by environment variables:
#
#   MOCK_CMUX_PING_FAILS=1            # ping returns non-zero
#   MOCK_CMUX_LIST_JSON='<json>'      # canned list-workspaces output (overrides
#                                       the auto-tracked list)
#   MOCK_CMUX_NEW_WS_FAILS=1          # new-workspace returns non-zero
#   MOCK_CMUX_READ_SCREEN_TEXT='...'  # canned read-screen output
#
# Behavior:
#   - new-workspace --name <title> appends the workspace to a tracked list
#     so subsequent list-workspaces returns it. Use MOCK_CMUX_LIST_JSON to
#     override (e.g. when seeding pre-existing workspaces in tests).
#   - Each invocation appends one line to $MOCK_CMUX_LOG:
#       <subcommand>\t<arg1>\t<arg2>...

set -u

_log() {
    if [ -n "${MOCK_CMUX_LOG:-}" ]; then
        printf '%s' "$1" >> "$MOCK_CMUX_LOG"
        shift
        for a in "$@"; do
            printf '\t%s' "$a" >> "$MOCK_CMUX_LOG"
        done
        printf '\n' >> "$MOCK_CMUX_LOG"
    fi
}

# Tracked-workspaces state file lives alongside the call log so tests sharing
# a MOCK_CMUX_LOG also share workspace state across invocations.
_state_file() {
    if [ -n "${MOCK_CMUX_LOG:-}" ]; then
        echo "${MOCK_CMUX_LOG}.workspaces"
    else
        echo ""
    fi
}

_read_state() {
    local f
    f=$(_state_file)
    if [ -n "$f" ] && [ -f "$f" ]; then
        cat "$f"
    fi
}

_write_state() {
    local f
    f=$(_state_file)
    [ -n "$f" ] && printf '%s\n' "$1" > "$f"
}

# Add a workspace to the tracked list. Args: name [ref]
_track_workspace() {
    local name="$1" ref="${2:-}"
    [ -z "$ref" ] && ref="workspace:$((RANDOM % 1000 + 10))"
    local existing
    existing=$(_read_state)
    if [ -n "$existing" ]; then
        existing="${existing}"$'\n'"${name}|${ref}"
    else
        existing="${name}|${ref}"
    fi
    _write_state "$existing"
}

# Emit list-workspaces JSON, either from MOCK_CMUX_LIST_JSON override or by
# converting tracked state.
_emit_list_json() {
    if [ -n "${MOCK_CMUX_LIST_JSON:-}" ]; then
        printf '%s\n' "$MOCK_CMUX_LIST_JSON"
        return
    fi
    local entries=""
    local first=1
    while IFS='|' read -r name ref; do
        [ -z "$name" ] && continue
        if [ $first -eq 1 ]; then
            first=0
        else
            entries+=","
        fi
        entries+="{\"title\":\"${name}\",\"ref\":\"${ref}\",\"uuid\":\"${ref}-uuid\"}"
    done <<< "$(_read_state)"
    printf '{"window_ref":"window:1","workspaces":[%s]}\n' "$entries"
}

# Parse --name <val> out of an argv list.
_arg_value() {
    local target="$1"; shift
    while [ $# -gt 0 ]; do
        if [ "$1" = "$target" ]; then
            shift
            echo "$1"
            return
        fi
        shift
    done
}

subcmd="${1:-}"
shift || true

case "$subcmd" in
    ping)
        _log ping "$@"
        if [ "${MOCK_CMUX_PING_FAILS:-}" = "1" ]; then
            echo "ping failed" >&2
            exit 1
        fi
        echo "PONG"
        ;;
    list-workspaces)
        _log list-workspaces "$@"
        _emit_list_json
        ;;
    new-workspace)
        _log new-workspace "$@"
        if [ "${MOCK_CMUX_NEW_WS_FAILS:-}" = "1" ]; then
            echo "new-workspace failed" >&2
            exit 1
        fi
        name=$(_arg_value --name "$@")
        if [ -n "$name" ]; then
            _track_workspace "$name"
        fi
        echo "OK workspace:99"
        ;;
    new-surface)
        _log new-surface "$@"
        echo "OK surface:99"
        ;;
    respawn-pane)
        _log respawn-pane "$@"
        echo "OK"
        ;;
    send)
        _log send "$@"
        ;;
    read-screen)
        _log read-screen "$@"
        if [ -n "${MOCK_CMUX_READ_SCREEN_TEXT:-}" ]; then
            printf '%s' "$MOCK_CMUX_READ_SCREEN_TEXT"
        fi
        ;;
    select-workspace)
        _log select-workspace "$@"
        ;;
    close-workspace)
        _log close-workspace "$@"
        ;;
    *)
        _log "$subcmd" "$@"
        ;;
esac
