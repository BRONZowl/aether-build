# Changelog

All notable product milestones for **Aether** (Odin). Version remains `0.1.0-dev` until an explicit tag.

## Unreleased

### Ship readiness (final polish)

- Docs truth-up: README auth/login (device-code M7), slash list, non-goals, standalone-first paths
- `scripts/parity-inventory.py`: hashline pack labeled **OPTIN Full** (not bare N/A)
- `/doctor` reports brand ASCII art on/off
- Empty TUI: avoid duplicate tip notice when brand welcome tips already show
- Install script auth hint matches M7

### Visual parity (V1)

- Aether brand ASCII/Unicode wordmark (chip / small / full size tiers)
- Empty TUI welcome, REPL startup banner, `/about` art
- `AETHER_NO_ASCII_ART` / `AETHER_ASCII_ART`; `/features` row `ascii-art`

### Ship-hardening max (Phase M)

| Epic | Summary |
|------|---------|
| **M1** | Folder trust + `/hooks trust\|untrust` |
| **M2** | `/goal --budget` + token pause |
| **M3** | MCP enroll / set-token polish (DCR still host-assisted) |
| **M4** | Local `/plugins` list/add/remove/reload |
| **M5** | Opt-in `AETHER_TOOL_PACK=hashline` |
| **M6** | `AETHER_OS_SANDBOX=soft\|bwrap` shell isolation |
| **M7** | In-process device-code login |
| **M8** | Mermaid Unicode flowchart/sequence layout |
| **M9** | Subagent `persona=` from `~/.grok/personas` |
| **M10** | `/create-skill` scaffold |

### Prior ship path (summary)

Phases **A** (tools), **B** (shell/slash/TUI chrome), **C1–C2** (pager), **S0–S4** (dual-product separation / standalone export), **R0–R4** (Odin-only charter) — see [PORTING.md](./PORTING.md).

## Intentional residuals (not bugs)

ACP multi-client, remote marketplace, Mixpanel/voice/self-update, mermaid PNG/SVG, in-process Landlock, full MCP browser OAuth DCR, SQLite memory, remote Auto classifier — documented N/A in PORTING.
