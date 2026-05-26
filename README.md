# gc-session-cmux

CMUX session provider for [Gas City](https://github.com/gastownhall/gascity).

> **Status:** Early / experimental. Surface-per-session support is planned but not yet implemented. Currently, one workspace per rig with a shared surface.

## What it does

This script implements the [Exec Session Provider](https://github.com/gastownhall/gascity/blob/main/docs/reference/exec-session-provider.md) protocol, letting Gas City use [cmux](https://cmux.com) as its session backend on macOS.

### Workspace-per-rig model

Sessions are grouped by **rig**. A session named `gastown.mayor` shares a workspace with `gastown.witness` — they both open in the same CMUX workspace (`gc-gastown`). Sessions without dots (e.g. `my-agent`) get their own workspace.

This design matches the Gas Town mental model: one terminal workspace per project, with each agent as a surface (or in the future, a split) within it.

## Dependencies

- [cmux](https://cmux.com) CLI installed and the cmux app running
- `jq`
- `bash`

## Installation

Put the script on your `PATH`:

```bash
cp gc-session-cmux /usr/local/bin/
```

Or reference it directly:

```bash
export GC_SESSION=exec:/path/to/gc-session-cmux
```

## Usage

```bash
# Set the session provider
export GC_SESSION=exec:gc-session-cmux

# Start your city
gc start my-city
```

Or inline:

```bash
GC_SESSION=exec:gc-session-cmux gc start my-city
```

## How it works

1. **Derive workspace key** from session name: `rig.role` → `rig`
2. **Create or reuse** a CMUX workspace named `gc-<key>`
3. **Store state** in `$GC_EXEC_STATE_DIR/gc-session-cmux/workspaces.json`
4. **Send commands** into the workspace via `cmux send`
5. **Sync to bead metadata** (best-effort): writes `gc.rig_workspace_uuid` and `gc.rig_workspace_name` to any `gc:session` bead matching the rig

## State file

```json
{
  "version": 1,
  "workspaces": {
    "gastown": {
      "key": "gastown",
      "name": "gc-gastown",
      "ref": "workspace:3",
      "uuid": "..."
    }
  }
}
```

## Bead integration

After creating a workspace, the script runs (if `gc` is on PATH):

```bash
gc bd update <bead-id> --set-metadata gc.rig_workspace_uuid=<uuid>
gc bd update <bead-id> --set-metadata gc.rig_workspace_name=<rig>
```

This lets other tools discover the CMUX workspace associated with a session or rig.

## Implementation status

| Operation | Status | Notes |
|-----------|--------|-------|
| `start` | ✅ Implemented | Creates workspace, sends via `cmux send` |
| `stop` | ✅ Implemented | Soft-stop (Ctrl+C), does NOT close shared workspace |
| `interrupt` | ✅ Implemented | Sends Ctrl+C via `cmux send` |
| `is-running` | ✅ Implemented | Checks state + CMUX list |
| `attach` | ✅ Implemented | Focuses workspace via `select-workspace` |
| `process-alive` | ✅ Implemented | Global `pgrep` (heuristic) |
| `nudge` | ✅ Implemented | `cmux send` with trailing newline |
| `set-meta` | ✅ Implemented | File-based |
| `get-meta` | ✅ Implemented | File-based |
| `remove-meta` | ✅ Implemented | File-based |
| `peek` | ✅ Implemented | `cmux read-screen --scrollback` |
| `list-running` | ✅ Implemented | Filters workspaces with `gc-` prefix |
| `get-last-activity` | ⬜ Unsupported | Returns empty (per protocol) |

## Future work

- **Surface-per-session**: Each session gets its own CMUX surface within the shared workspace, rather than sharing one surface. This requires:
  - Tracking `session_name → surface_ref` in state
  - Using `cmux new-split` to create dedicated surfaces
  - Routing `send`, `peek`, `interrupt` to the correct surface
  
- **Cleanup**: Close workspace when all sessions in the rig have stopped
- **Theming**: Map Gas Town role colors to CMUX workspace/config (if cmux exposes it)

## License

MIT
