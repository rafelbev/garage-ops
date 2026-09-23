# Skill: Collaborate with Hermes Agent (Linus)

Use this skill when working alongside the Hermes agent (profile `linus`) in the same Orca workspace.

## Finding the Hermes Terminal

List all terminals and find the one running hermes:

```bash
orca terminal list --json
```

Look for a terminal with `agentIdentity: "hermes"`. Note its `handle`.

## Sending Messages

```bash
orca terminal send --terminal <handle> --text "Your message" --enter
```

**Important:** Avoid backticks in messages — they get interpreted as shell commands by the terminal. Use plain text descriptions instead.

## Waiting for Response

Use `terminal wait` with the `tui-idle` condition. Do NOT use sleep commands.

```bash
orca terminal wait --terminal <handle> --for tui-idle --timeout-ms 300000 --json
```

- Returns immediately when the agent finishes its turn and the TUI is idle
- Timeout of 300000ms (5 minutes) is usually sufficient
- If it times out, read the terminal to check progress

## Reading Output

```bash
# Read rendered screen (preferred for TUI apps)
orca terminal read --terminal <handle> --screen --limit 50

# Read accumulated output from a cursor position
orca terminal read --terminal <handle> --cursor <n> --limit 100
```

- Use `--screen` for the rendered view (what the user sees)
- Use `--cursor` with the `cursor` value from a previous read to get only new output
- The response includes `cursor` and `latest cursor` values for pagination

## Collaboration Workflow

1. **Send a task** via `terminal send`
2. **Wait** using `terminal wait --for tui-idle` (not sleep)
3. **Read** the response via `terminal read --screen`
4. **Review the work** — check files created, git commits, etc. directly
5. **Provide feedback** or approve via another `terminal send`
6. Repeat until the task is complete

## Best Practices

- **Always use `terminal wait`** instead of sleep — it's event-driven and more efficient
- **Use `--screen` flag** when reading output — gives the rendered TUI view
- **Track cursor positions** when reading long output to avoid re-reading
- **Review files directly** after the agent completes work — don't just trust its summary
- **Use git** to track changes between collaboration turns
- **Be specific** in task descriptions — include file paths, expected outcomes, and constraints

## Example

```bash
# Find hermes terminal
TERM=$(orca terminal list --json | jq -r '.result.terminals[] | select(.agentIdentity == "hermes") | .handle')

# Send a task
orca terminal send --terminal "$TERM" --text "Please review the Sonarr deployment manifests in kubernetes/apps/sonarr/" --enter

# Wait for response (5 min timeout)
orca terminal wait --terminal "$TERM" --for tui-idle --timeout-ms 300000 --json

# Read response
orca terminal read --terminal "$TERM" --screen --limit 50
```
