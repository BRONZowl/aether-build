// Package agent — /keys keyboard shortcuts reference (B41 / Grok-shaped cheat sheet).

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:strings"
import "aether:core"

// handle_keys_slash: compact TUI key binding reference (also useful in REPL).
handle_keys_slash :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "## aether keys (TUI)\n")
	strings.write_string(&b, fmt.tprintf("version: %s\n\n", core.version_string()))

	strings.write_string(&b, "### Compose\n")
	strings.write_string(&b, "  Enter              send (newline in multiline)\n")
	strings.write_string(&b, "  Shift/Alt+Enter    newline (send in multiline)\n")
	strings.write_string(&b, "  \\ then Enter       newline (portable)\n")
	strings.write_string(&b, "  Ctrl+M (prompt)    toggle multiline (/ml)\n")
	strings.write_string(&b, "  Esc Esc (800ms)    clear non-empty prompt\n")
	strings.write_string(&b, "  Ctrl+C             clear draft; mid-turn cancel HTTP\n")
	strings.write_string(&b, "  ↑/↓ empty prompt   durable prompt history\n")
	strings.write_string(&b, "  /…                 live slash menu · ↑↓ · Tab/click accept · Esc dismiss\n")
	strings.write_string(&b, "  Tab                accept slash/@path · else focus toggle\n")
	strings.write_string(&b, "  Ctrl+V             paste (text / image → [Image #N])\n\n")

	strings.write_string(&b, "### Session & mode\n")
	strings.write_string(&b, "  Ctrl+S             session picker (/resume)\n")
	strings.write_string(&b, "  Ctrl+N ×2 (1s)     new session\n")
	strings.write_string(&b, "  Ctrl+O             toggle YOLO always-approve\n")
	strings.write_string(&b, "  Shift+Tab          cycle Normal → Plan → Always-approve (Grok)\n")
	strings.write_string(&b, "  Ctrl+M (scrollback) model picker\n")
	strings.write_string(&b, "  Ctrl+Q ×2 (1s)     quit\n\n")

	strings.write_string(&b, "### Scrollback\n")
	strings.write_string(&b, "  Tab                focus prompt ↔ scrollback (if not completing)\n")
	strings.write_string(&b, "  Space (scrollback) focus prompt\n")
	strings.write_string(&b, "  ↑/↓                select block (scrollback) / history (empty prompt)\n")
	strings.write_string(&b, "  ←/→ on tool        collapse / expand\n")
	strings.write_string(&b, "  e                  toggle tool fold\n")
	strings.write_string(&b, "  y / Y              copy block / tool meta\n")
	strings.write_string(&b, "  PgUp/Dn            page scroll (works from prompt too)\n")
	strings.write_string(&b, "  Ctrl+U/D           half-page up/down (Grok)\n")
	strings.write_string(&b, "  Ctrl+J/K           line down/up\n")
	strings.write_string(&b, "  Home/End           top/bottom (scrollback focused)\n")
	strings.write_string(&b, "  Wheel / click      scroll / select block\n")
	strings.write_string(&b, "  Ctrl+F / /find     search transcript\n")
	strings.write_string(&b, "  Shift+←/→          prev/next user turn\n\n")

	strings.write_string(&b, "### Permission prompt (Grok)\n")
	strings.write_string(&b, "  1-9                select option by number\n")
	strings.write_string(&b, "  j/k or ↑/↓         move highlight\n")
	strings.write_string(&b, "  Enter              confirm highlighted option\n")
	strings.write_string(&b, "  Esc / Ctrl+C       reject once (cancel)\n")
	strings.write_string(&b, "  Options: Allow once · Always allow on all sessions · Reject once · Never allow\n\n")

	strings.write_string(&b, "### Plan approval (exit_plan_mode)\n")
	strings.write_string(&b, "  a                  approve plan (or approve w/ comments)\n")
	strings.write_string(&b, "  s / Tab            request changes → type feedback · Enter send\n")
	strings.write_string(&b, "  q                  quit plan (abandon + leave plan mode)\n")
	strings.write_string(&b, "  c / Enter          comment on selected line\n")
	strings.write_string(&b, "  j/k · ↑/↓ · PgUp/Dn scroll / select line\n")
	strings.write_string(&b, "  Esc                prompt → preview (does not abandon)\n\n")

	strings.write_string(&b, "### Vim scrollback ([ui] vim_mode / /vim-mode)\n")
	strings.write_string(&b, "  j/k  line   g/G top/bottom   H/L user turns   J/K assistant   i prompt\n\n")

	strings.write_string(
		&b,
		"tips: /about · /help · /tools · /permissions · /soft-bash · /status · /config · /theme\n",
	)
	return strings.to_string(b)
}
