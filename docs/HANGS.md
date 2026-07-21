# Aether freezes / force-quit triage

## Why force-quit happens

The TUI main thread runs **entire agent turns** synchronously. Mid-turn keys only work when code polls (`on_poll` / libcurl progress). Long shell/wait/slash paths that never poll feel dead.

## What we fixed (hang hardening)

- FG **shell** checks **Ctrl+C cancel** and kills the process
- **wait_tasks** checks cancel between polls
- **Clipboard** waits are timed (~2s)
- **Queue** auto-drains **at most one** follow-up per turn
- **SSE stall**: libcurl `LOW_SPEED` (~1 B/s for 120s) aborts a dead mid-stream connection instead of waiting the full 300s
- **Mid-output paint**: stream redraw ~80ms (not 16ms); mermaid layout skipped on live/open fences; render reentrancy guard; key peeks throttled during fast tokens
- **Ctrl+C mid-stream**: xferinfo + write_cb poll; cancel stops buffering and paints `cancelling…`

## Env

| Env | Effect |
|-----|--------|
| `AETHER_DEBUG_HANG=1` | Append enter/exit of blocking regions to `~/.grok/aether/hang.log` (includes `http_post_sse` / `run_agent_turn` / tools) |

## When it freezes, note

1. Status bar text?
2. Mid-turn or idle?
3. Shell / wait / transcript / btw / copy?
4. Does Ctrl+C show `cancelling…`?
5. Did tokens stop mid-sentence with no tool status?

| Observation | Likely class |
|-------------|--------------|
| Mid-turn, Ctrl+C → cancelling, still stuck | Tool not killing (report tool name) |
| Mid-turn, Ctrl+C does nothing | Not polling (HTTP/tool) |
| Tokens stop mid-output, UI dead, then ~2min timeout | SSE stall (should surface timed out) |
| Tokens still arrive but UI frozen / laggy | Paint path (report session size / mermaid) |
| After /transcript | Pager child |
| After /copy | Clipboard backend |
| After many queued messages | Queue drain (now max 1 auto) |

## Still expected to block (not bugs)

- Permission ask modal until y/n/Esc
- `$PAGER` until you quit less (`q`)
- Device `/login` until complete or fail
- Long model **thinking** with no streamed tokens (up to stall window, then timeout)
