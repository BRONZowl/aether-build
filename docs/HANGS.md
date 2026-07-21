# Aether freezes / force-quit triage

## Why force-quit happens

The TUI main thread runs **entire agent turns** synchronously. Mid-turn keys only work when code polls (`on_poll` / libcurl progress). Long shell/wait/slash paths that never poll feel dead.

## What we fixed (hang hardening)

- FG **shell** checks **Ctrl+C cancel** and kills the process
- **wait_tasks** checks cancel between polls
- **Clipboard** waits are timed (~2s)
- **Queue** auto-drains **at most one** follow-up per turn

## Env

| Env | Effect |
|-----|--------|
| `AETHER_DEBUG_HANG=1` | Append enter/exit of blocking regions to `~/.grok/aether/hang.log` |

## When it freezes, note

1. Status bar text?
2. Mid-turn or idle?
3. Shell / wait / transcript / btw / copy?
4. Does Ctrl+C show `cancelling…`?

| Observation | Likely class |
|-------------|--------------|
| Mid-turn, Ctrl+C → cancelling, still stuck | Tool not killing (report tool name) |
| Mid-turn, Ctrl+C does nothing | Not polling (HTTP/tool) |
| After /transcript | Pager child |
| After /copy | Clipboard backend |
| After many queued messages | Queue drain (now max 1 auto) |

## Still expected to block (not bugs)

- Permission ask modal until y/n/Esc
- `$PAGER` until you quit less (`q`)
- Device `/login` until complete or fail
