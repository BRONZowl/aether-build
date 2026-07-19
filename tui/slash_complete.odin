// Package tui — slash command Tab autocomplete (B20 / Grok-shaped).
package tui

import "core:fmt"
import "core:strings"

// Product slash commands (names only; aliases included for matching).
// Keep roughly in /help order; Tab cycles matches for the typed prefix.
SLASH_COMMANDS := []string {
	"/help",
	"/?",
	"/about",
	"/aliases",
	"/alias",
	"/keys",
	"/bindings",
	"/shortcuts",
	"/tools",
	"/tool",
	"/soft-bash",
	"/bash-soft",
	"/softbash",
	"/permissions",
	"/permission",
	"/perm",
	"/perms",
	"/env",
	"/environ",
	"/environment",
	"/paths",
	"/path",
	"/where",
	"/features",
	"/feature",
	"/flags",
	"/status",
	"/config",
	"/settings",
	"/preferences",
	"/prefs",
	"/doctor",
	"/version",
	"/session",
	"/session-info",
	"/sessions",
	"/resume",
	"/save",
	"/load",
	"/rename",
	"/title",
	"/fork",
	"/export",
	"/import",
	"/rewind",
	"/undo-file",
	"/copy",
	"/history",
	"/model",
	"/m",
	"/effort",
	"/new",
	"/clear",
	"/whoami",
	"/login",
	"/always-approve",
	"/yolo",
	"/auto",
	"/mcp",
	"/hooks",
	"/skills",
	"/skill",
	"/plan",
	"/view-plan",
	"/show-plan",
	"/plan-view",
	"/todos",
	"/todo",
	"/goal",
	"/loop",
	"/imagine",
	"/imagine-video",
	"/theme",
	"/t",
	"/vim-mode",
	"/vim",
	"/compact-mode",
	"/cm",
	"/timestamps",
	"/timestamp",
	"/flush",
	"/remember",
	"/dream",
	"/memory",
	"/context",
	"/usage",
	"/cost",
	"/diff",
	"/compact",
	"/btw",
	"/feedback",
	"/find",
	"/multiline",
	"/ml",
	"/exit",
	"/quit",
	"/q",
}

// slash_token_prefix: text from last newline (or start) to cursor if it is a
// partial slash command (starts with `/`, no space). Returns ("", false) otherwise.
slash_token_prefix :: proc(text: string, cursor: int) -> (prefix: string, ok: bool) {
	cur := cursor
	if cur < 0 {
		cur = 0
	}
	if cur > len(text) {
		cur = len(text)
	}
	start := 0
	for i in 0 ..< cur {
		if text[i] == '\n' {
			start = i + 1
		}
	}
	frag := text[start:cur]
	if frag == "" || frag[0] != '/' {
		return "", false
	}
	// already past command word → do not hijack Tab
	for i in 1 ..< len(frag) {
		if frag[i] == ' ' || frag[i] == '\t' {
			return "", false
		}
	}
	return frag, true
}

// collect_slash_matches appends commands that have_prefix(prefix) (case-sensitive).
// Empty prefix "/" matches all.
collect_slash_matches :: proc(prefix: string, out: ^[dynamic]string) {
	clear(out)
	for cmd in SLASH_COMMANDS {
		if strings.has_prefix(cmd, prefix) {
			append(out, cmd)
		}
	}
}

// common_slash_prefix of a non-empty match list (longest shared prefix).
common_slash_prefix :: proc(matches: []string) -> string {
	if len(matches) == 0 {
		return ""
	}
	if len(matches) == 1 {
		return matches[0]
	}
	base := matches[0]
	n := len(base)
	for m in matches[1:] {
		i := 0
		for i < n && i < len(m) && base[i] == m[i] {
			i += 1
		}
		n = i
		if n == 0 {
			return ""
		}
	}
	return base[:n]
}

// apply_slash_completion replaces the slash token before cursor with `completed`
// (optionally appends a trailing space when unique full match).
// Returns true if input changed.
apply_slash_completion :: proc(s: ^App_State, completed: string, add_space: bool) -> bool {
	text := input_text(s)
	cur := s.cursor
	prefix, ok := slash_token_prefix(text, cur)
	if !ok || completed == "" {
		return false
	}
	start := cur - len(prefix)
	if start < 0 {
		return false
	}
	// rebuild: before + completed + space? + after cursor
	after := text[cur:]
	ins := completed
	if add_space && !strings.has_suffix(ins, " ") {
		ins = fmt.tprintf("%s ", completed)
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, text[:start])
	strings.write_string(&b, ins)
	strings.write_string(&b, after)
	new_text := strings.to_string(b)
	input_set_text(s, new_text)
	s.cursor = start + len(ins)
	return true
}

// try_slash_tab_complete: Tab handler when prompt has a slash token.
// Cycles matches; first Tab expands to LCP then cycles full names.
// Returns true if Tab was consumed (caller should not toggle focus).
try_slash_tab_complete :: proc(s: ^App_State) -> bool {
	if s == nil || s.focus != .Prompt {
		return false
	}
	text := input_text(s)
	prefix, ok := slash_token_prefix(text, s.cursor)
	if !ok {
		// reset cycle state
		s.slash_comp_idx = 0
		if s.slash_comp_prefix != "" {
			delete(s.slash_comp_prefix)
			s.slash_comp_prefix = ""
		}
		return false
	}

	matches := make([dynamic]string, 0, 16, context.temp_allocator)
	collect_slash_matches(prefix, &matches)
	if len(matches) == 0 {
		state_set_status(s, fmt.tprintf("no slash match for %s", prefix))
		return true
	}

	// New prefix → reset cycle index
	if s.slash_comp_prefix != prefix {
		if s.slash_comp_prefix != "" {
			delete(s.slash_comp_prefix)
		}
		s.slash_comp_prefix = strings.clone(prefix)
		s.slash_comp_idx = 0
		// first hit: expand to longest common prefix if longer than typed
		lcp := common_slash_prefix(matches[:])
		if len(lcp) > len(prefix) {
			_ = apply_slash_completion(s, lcp, false)
			// update stored prefix to LCP for subsequent cycles
			delete(s.slash_comp_prefix)
			s.slash_comp_prefix = strings.clone(lcp)
			if len(matches) == 1 {
				// unique: add trailing space
				_ = apply_slash_completion(s, matches[0], true)
				state_set_status(s, fmt.tprintf("%s", matches[0]))
			} else {
				state_set_status(
					s,
					fmt.tprintf("%d matches · Tab cycle · %s…", len(matches), lcp),
				)
			}
			return true
		}
	}

	// Cycle full command names
	if len(matches) == 1 {
		_ = apply_slash_completion(s, matches[0], true)
		state_set_status(s, matches[0])
		return true
	}
	idx := s.slash_comp_idx % len(matches)
	chosen := matches[idx]
	s.slash_comp_idx = (idx + 1) % len(matches)
	_ = apply_slash_completion(s, chosen, true)
	// After adding space, token no longer active until user edits — keep cycle
	// for next Tab if they backspace into command again.
	state_set_status(
		s,
		fmt.tprintf("%s  (%d/%d)", chosen, idx + 1, len(matches)),
	)
	return true
}

// slash_complete_reset clears Tab-cycle state (call on input edit if desired).
slash_complete_reset :: proc(s: ^App_State) {
	if s == nil {
		return
	}
	s.slash_comp_idx = 0
	if s.slash_comp_prefix != "" {
		delete(s.slash_comp_prefix)
		s.slash_comp_prefix = ""
	}
}
