// Package agent — /keys keyboard shortcuts reference (B41 / Grok-shaped cheat sheet).
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
	strings.write_string(&b, "  /…                 live slash menu · ↑↓ · Tab accept\n")
	strings.write_string(&b, "  Tab                accept slash/@path · else focus toggle\n")
	strings.write_string(&b, "  Ctrl+V             paste (text / image → [Image #N])\n\n")

	strings.write_string(&b, "### Session & mode\n")
	strings.write_string(&b, "  Ctrl+S             session picker (/resume)\n")
	strings.write_string(&b, "  Ctrl+N ×2 (1s)     new session\n")
	strings.write_string(&b, "  Ctrl+O             toggle YOLO always-approve\n")
	strings.write_string(&b, "  Shift+Tab          cycle ask→plan→auto→yolo→read-only\n")
	strings.write_string(&b, "  Ctrl+M (scrollback) model picker\n")
	strings.write_string(&b, "  Ctrl+Q/D ×2 (1s)   quit\n\n")

	strings.write_string(&b, "### Scrollback\n")
	strings.write_string(&b, "  Tab                focus prompt ↔ scrollback (if not completing)\n")
	strings.write_string(&b, "  Space (scrollback) focus prompt\n")
	strings.write_string(&b, "  ↑/↓                select block\n")
	strings.write_string(&b, "  ←/→ on tool        collapse / expand\n")
	strings.write_string(&b, "  e                  toggle tool fold\n")
	strings.write_string(&b, "  y / Y              copy block / tool meta\n")
	strings.write_string(&b, "  PgUp/Dn Ctrl+J/K/U scroll (mid-stream follows when at tail)\n")
	strings.write_string(&b, "  Ctrl+F / /find     search transcript\n")
	strings.write_string(&b, "  Shift+←/→          prev/next user turn\n")
	strings.write_string(&b, "  Wheel / click      scroll / select block\n\n")

	strings.write_string(&b, "### Ask modal\n")
	strings.write_string(&b, "  y/Enter  allow once   n/Esc deny   a always   d never\n\n")

	strings.write_string(&b, "### Vim scrollback ([ui] vim_mode / /vim-mode)\n")
	strings.write_string(&b, "  j/k  line   g/G top/bottom   H/L user turns   J/K assistant   i prompt\n\n")

	strings.write_string(
		&b,
		"tips: /about · /help · /tools · /permissions · /soft-bash · /status · /config · /theme\n",
	)
	return strings.to_string(b)
}
