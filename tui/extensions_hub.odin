// Package tui — Grok-shaped extensions hub (hooks / plugins / skills / mcps).
// Bare /hooks, /plugins, /skills, /mcps, /marketplace open this modal on the
// matching tab. Text CLI handlers remain for REPL.
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:strings"
import "aether:agent"

Extensions_Tab :: enum {
	Hooks,
	Plugins,
	Skills,
	Mcps,
	Marketplace,
}

// Extensions_Hub: tabbed list overlay.
Extensions_Hub :: struct {
	active:   bool,
	tab:      Extensions_Tab,
	rows:     [dynamic]string, // owned display lines
	selected: int,
	scroll:   int,
	cwd:      string, // owned workspace for reload/list
	no_mcp:   bool,
}

extensions_hub_init :: proc(h: ^Extensions_Hub) {
	h.rows = make([dynamic]string, 0, 32)
	h.selected = 0
	h.scroll = 0
	h.active = false
	h.tab = .Plugins
	h.cwd = ""
	h.no_mcp = false
}

extensions_hub_destroy :: proc(h: ^Extensions_Hub) {
	extensions_hub_clear(h)
	delete(h.rows)
	delete(h.cwd)
	h.active = false
}

extensions_hub_clear :: proc(h: ^Extensions_Hub) {
	for r in h.rows {
		delete(r)
	}
	clear(&h.rows)
	h.selected = 0
	h.scroll = 0
}

extensions_tab_name :: proc(tab: Extensions_Tab) -> string {
	switch tab {
	case .Hooks:
		return "Hooks"
	case .Plugins:
		return "Plugins"
	case .Skills:
		return "Skills"
	case .Mcps:
		return "MCPs"
	case .Marketplace:
		return "Market"
	}
	return "?"
}

extensions_tab_from_slash :: proc(cmd: string) -> Extensions_Tab {
	c := strings.to_lower(cmd, context.temp_allocator)
	switch c {
	case "/hooks":
		return .Hooks
	case "/plugins", "/plugin":
		return .Plugins
	case "/skills", "/skill":
		return .Skills
	case "/mcps", "/mcp":
		return .Mcps
	case "/marketplace":
		return .Marketplace
	}
	return .Plugins
}

// extensions_hub_open loads list rows for tab.
extensions_hub_open :: proc(
	h: ^Extensions_Hub,
	tab: Extensions_Tab,
	cwd: string,
	no_mcp := false,
) {
	delete(h.cwd)
	h.cwd = strings.clone(cwd if cwd != "" else ".")
	h.tab = tab
	h.no_mcp = no_mcp
	h.active = true
	extensions_hub_reload_rows(h)
}

extensions_hub_close :: proc(h: ^Extensions_Hub) {
	h.active = false
}

extensions_hub_reload_rows :: proc(h: ^Extensions_Hub) {
	extensions_hub_clear(h)
	add :: proc(h: ^Extensions_Hub, line: string) {
		if line == "" {
			return
		}
		append(&h.rows, strings.clone(line))
	}
	add_blob :: proc(h: ^Extensions_Hub, text: string) {
		start := 0
		for i := 0; i <= len(text); i += 1 {
			if i == len(text) || text[i] == '\n' {
				line := text[start:i]
				// trim trailing \r
				if len(line) > 0 && line[len(line) - 1] == '\r' {
					line = line[:len(line) - 1]
				}
				add(h, line)
				start = i + 1
			}
		}
	}

	// Header actions always first
	add(h, fmt.tprintf("[r] reload this tab · [Tab] next · [1-5] jump · Esc close"))
	add(h, "")

	switch h.tab {
	case .Hooks:
		out := agent.handle_hooks_slash("status", h.cwd, context.temp_allocator)
		add_blob(h, out)
		add(h, "")
		add(h, "Tip: /hooks trust · /hooks list · /hooks reload")
	case .Plugins:
		out := agent.handle_plugins_slash("list", h.cwd, context.temp_allocator)
		add_blob(h, out)
		add(h, "")
		add(h, "Tip: /plugins add <path> · /plugins reload · /plugins trust")
	case .Skills:
		out := agent.skills_list_text(context.temp_allocator)
		add_blob(h, out)
		add(h, "")
		add(h, "Tip: /skills reload · /skill <name> · /create-skill")
	case .Mcps:
		out := agent.handle_mcp_slash("status", h.no_mcp, true, context.temp_allocator)
		add_blob(h, out)
		add(h, "")
		add(h, "Tip: /mcps reconnect · /mcps doctor · /mcps help")
	case .Marketplace:
		add(h, "No remote marketplace in Aether.")
		add(h, "Local plugins (same as Plugins tab):")
		add(h, "")
		out := agent.handle_plugins_slash("list", h.cwd, context.temp_allocator)
		add_blob(h, out)
		add(h, "")
		add(h, "Install: /plugins add <directory>  ·  skills: /skills")
	}

	if h.selected >= len(h.rows) {
		h.selected = max(0, len(h.rows) - 1)
	}
	h.scroll = 0
}

extensions_hub_move :: proc(h: ^Extensions_Hub, delta: int) {
	if len(h.rows) == 0 {
		return
	}
	h.selected += delta
	if h.selected < 0 {
		h.selected = 0
	}
	if h.selected >= len(h.rows) {
		h.selected = len(h.rows) - 1
	}
}

extensions_hub_next_tab :: proc(h: ^Extensions_Hub, dir: int) {
	n := int(h.tab) + dir
	if n < 0 {
		n = int(Extensions_Tab.Marketplace)
	}
	if n > int(Extensions_Tab.Marketplace) {
		n = 0
	}
	h.tab = Extensions_Tab(n)
	extensions_hub_reload_rows(h)
}

extensions_hub_set_tab :: proc(h: ^Extensions_Hub, tab: Extensions_Tab) {
	h.tab = tab
	extensions_hub_reload_rows(h)
}

// extensions_hub_do_reload runs tab-specific reload and refreshes rows.
extensions_hub_do_reload :: proc(h: ^Extensions_Hub) -> string {
	msg := ""
	switch h.tab {
	case .Hooks:
		msg = agent.handle_hooks_slash("reload", h.cwd, context.temp_allocator)
	case .Plugins, .Marketplace:
		msg = agent.handle_plugins_slash("reload", h.cwd, context.temp_allocator)
	case .Skills:
		msg = agent.reload_skills_for_cwd(h.cwd, true)
	case .Mcps:
		msg = agent.handle_mcp_slash("reconnect", h.no_mcp, true, context.temp_allocator)
	}
	extensions_hub_reload_rows(h)
	return msg
}

handle_extensions_hub_key :: proc(st: ^App_State, key: Key) -> bool {
	h := &st.extensions_hub
	#partial switch key.kind {
	case .Esc, .Ctrl_C:
		extensions_hub_close(h)
		state_set_status(st, "ready")
		return true
	case .Tab:
		extensions_hub_next_tab(h, 1)
		state_set_status(st, fmt.tprintf("extensions · %s", extensions_tab_name(h.tab)))
		return true
	case .Up, .Ctrl_K:
		extensions_hub_move(h, -1)
		return true
	case .Down, .Ctrl_J:
		extensions_hub_move(h, 1)
		return true
	case .Left:
		extensions_hub_next_tab(h, -1)
		state_set_status(st, fmt.tprintf("extensions · %s", extensions_tab_name(h.tab)))
		return true
	case .Right:
		extensions_hub_next_tab(h, 1)
		state_set_status(st, fmt.tprintf("extensions · %s", extensions_tab_name(h.tab)))
		return true
	case .PgUp:
		extensions_hub_move(h, -10)
		return true
	case .PgDn:
		extensions_hub_move(h, 10)
		return true
	case .Char:
		// 1-5 jump tabs
		if key.ch >= '1' && key.ch <= '5' {
			extensions_hub_set_tab(h, Extensions_Tab(int(key.ch - '1')))
			state_set_status(st, fmt.tprintf("extensions · %s", extensions_tab_name(h.tab)))
			return true
		}
		if key.ch == 'r' || key.ch == 'R' {
			msg := extensions_hub_do_reload(h)
			// first non-empty line of reload result as status
			line := msg
			if sp := strings.index_byte(msg, '\n'); sp >= 0 {
				line = msg[:sp]
			}
			if len(line) > 60 {
				line = fmt.tprintf("%s…", line[:57])
			}
			state_set_status(st, line if line != "" else "reloaded")
			if msg != "" {
				state_add_notice(st, msg)
			}
			return true
		}
		if key.ch == 't' || key.ch == 'T' {
			// trust folder (hooks/plugins)
			if h.tab == .Hooks || h.tab == .Plugins || h.tab == .Marketplace {
				msg := agent.handle_hooks_slash("trust", h.cwd, context.temp_allocator)
				extensions_hub_reload_rows(h)
				state_set_status(st, "trust updated")
				state_add_notice(st, msg)
				return true
			}
		}
	case .Enter:
		// Show selected line as notice (read-only browse)
		if h.selected >= 0 && h.selected < len(h.rows) {
			row := h.rows[h.selected]
			if row != "" {
				state_add_notice(st, row)
				state_set_status(st, "selected")
			}
		}
		return true
	}
	return false
}

// write_extensions_hub_body paints tab strip + list.
write_extensions_hub_body :: proc(b: ^strings.Builder, h: ^Extensions_Hub, cols: int, body_h: int) {
	// Tab strip
	tabs := [?]Extensions_Tab{.Hooks, .Plugins, .Skills, .Mcps, .Marketplace}
	strip := strings.builder_make(context.temp_allocator)
	strings.write_string(&strip, " ")
	for t, i in tabs {
		name := extensions_tab_name(t)
		if t == h.tab {
			fmt.sbprintf(&strip, "[%s]", name)
		} else {
			fmt.sbprintf(&strip, " %s ", name)
		}
		if i + 1 < len(tabs) {
			strings.write_string(&strip, "·")
		}
	}
	write_row(b, strings.to_string(strip), cols, .Bar_Reverse, true)

	list_h := body_h - 2
	if list_h < 1 {
		list_h = 1
	}
	if h.selected < h.scroll {
		h.scroll = h.selected
	}
	if h.selected >= h.scroll + list_h {
		h.scroll = h.selected - list_h + 1
	}
	if h.scroll < 0 {
		h.scroll = 0
	}
	painted := 0
	if len(h.rows) == 0 {
		write_row(b, "  (empty)", cols, .Bar_Dim, true)
		painted = 1
	} else {
		for i := h.scroll; i < len(h.rows) && painted < list_h; i += 1 {
			sel := i == h.selected
			line := h.rows[i]
			if len(line) > cols - 2 {
				line = fmt.tprintf("%s…", line[:max(1, cols - 5)])
			}
			disp := fmt.tprintf("%s%s", "›" if sel else " ", line)
			write_row(b, disp, cols, .Bar_Reverse if sel else .Normal, true)
			painted += 1
		}
	}
	for painted < list_h {
		write_row(b, "", cols, .Normal, true)
		painted += 1
	}
	write_row(
		b,
		fmt.tprintf(" %s · r reload · t trust · ←/→ tab · Esc", extensions_tab_name(h.tab)),
		cols,
		.Bar_Dim,
		true,
	)
}
