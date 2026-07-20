// Package tui — /docs in-TUI guide picker + open web docs.
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "aether:agent"
import "aether:core"

Docs_Picker :: struct {
	active:   bool,
	titles:   [dynamic]string, // owned
	paths:    [dynamic]string, // owned; empty = web or special
	kinds:    [dynamic]int, // 0=local file, 1=web, 2=help
	selected: int,
	scroll:   int,
}

docs_picker_init :: proc(p: ^Docs_Picker) {
	p.titles = make([dynamic]string, 0, 16)
	p.paths = make([dynamic]string, 0, 16)
	p.kinds = make([dynamic]int, 0, 16)
	p.selected = 0
	p.scroll = 0
	p.active = false
}

docs_picker_destroy :: proc(p: ^Docs_Picker) {
	docs_picker_clear(p)
	delete(p.titles)
	delete(p.paths)
	delete(p.kinds)
	p.active = false
}

docs_picker_clear :: proc(p: ^Docs_Picker) {
	for t in p.titles {
		delete(t)
	}
	for path in p.paths {
		delete(path)
	}
	clear(&p.titles)
	clear(&p.paths)
	clear(&p.kinds)
	p.selected = 0
	p.scroll = 0
}

docs_picker_add :: proc(p: ^Docs_Picker, title, path: string, kind: int) {
	append(&p.titles, strings.clone(title))
	append(&p.paths, strings.clone(path) if path != "" else "")
	append(&p.kinds, kind)
}

// find_docs_dir: walk for docs/ or bundled user-guide near cwd/binary.
find_docs_roots :: proc(cwd: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 4, allocator)
	try :: proc(out: ^[dynamic]string, path: string) {
		if path != "" && os.exists(path) && os.is_directory(path) {
			append(out, strings.clone(path))
		}
	}
	base := cwd if cwd != "" else "."
	// project docs
	d1, _ := filepath.join({base, "docs"}, context.temp_allocator)
	try(&out, d1)
	// walk parents for docs/
	cur := base
	for _ in 0 ..< 6 {
		cand, _ := filepath.join({cur, "docs"}, context.temp_allocator)
		try(&out, cand)
		// grok user-guide in monorepo
		ug, _ := filepath.join(
			{cur, "crates/codegen/xai-grok-pager/docs/user-guide"},
			context.temp_allocator,
		)
		try(&out, ug)
		parent := filepath.dir(cur)
		if parent == cur || parent == "" {
			break
		}
		cur = parent
	}
	// ~/.grok/docs
	home := core.grok_home(context.temp_allocator)
	hg, _ := filepath.join({home, "docs"}, context.temp_allocator)
	try(&out, hg)
	return out[:]
}

docs_picker_open :: proc(p: ^Docs_Picker, cwd: string) {
	docs_picker_clear(p)
	docs_picker_add(p, "Open Build docs on the web", agent.BUILD_DOCS_URL, 1)
	docs_picker_add(p, "Slash command help (/help)", "", 2)
	docs_picker_add(p, "Product about (/about)", "", 2)
	docs_picker_add(p, "Release notes (/release-notes)", "", 2)
	docs_picker_add(p, "Keyboard shortcuts (/keys)", "", 2)

	roots := find_docs_roots(cwd, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for root in roots {
		if root in seen {
			continue
		}
		seen[root] = true
		fis, err := os.read_all_directory_by_path(root, context.temp_allocator)
		if err != nil {
			continue
		}
		for fi in fis {
			if fi.type == .Directory {
				continue
			}
			if !strings.has_suffix(fi.name, ".md") {
				continue
			}
			path, _ := filepath.join({root, fi.name}, context.temp_allocator)
			title := fi.name
			// strip leading NN-
			if len(title) > 3 && title[0] >= '0' && title[0] <= '9' {
				// keep as-is
			}
			docs_picker_add(p, title, path, 0)
		}
	}
	p.selected = 0
	p.scroll = 0
	p.active = true
}

docs_picker_close :: proc(p: ^Docs_Picker) {
	p.active = false
}

docs_picker_move :: proc(p: ^Docs_Picker, delta: int) {
	if len(p.titles) == 0 {
		return
	}
	p.selected += delta
	if p.selected < 0 {
		p.selected = 0
	}
	if p.selected >= len(p.titles) {
		p.selected = len(p.titles) - 1
	}
}

handle_docs_picker_key_term :: proc(st: ^App_State, term: ^Term_State, key: Key) -> bool {
	p := &st.docs_picker
	#partial switch key.kind {
	case .Esc, .Ctrl_C:
		docs_picker_close(p)
		state_set_status(st, "ready")
		return true
	case .Up, .Ctrl_K:
		docs_picker_move(p, -1)
		return true
	case .Down, .Ctrl_J:
		docs_picker_move(p, 1)
		return true
	case .Enter:
		if p.selected < 0 || p.selected >= len(p.titles) {
			return true
		}
		kind := p.kinds[p.selected]
		path := p.paths[p.selected]
		title := p.titles[p.selected]
		docs_picker_close(p)
		if kind == 1 {
			if agent.open_browser_url(path) {
				state_set_status(st, "opened browser")
				state_add_notice(st, fmt.tprintf("aether: opened %s", path))
			} else {
				state_add_notice(st, fmt.tprintf("aether: open in browser: %s", path))
			}
			return true
		}
		if kind == 2 {
			if strings.contains(title, "/help") {
				input_set_text(st, "/help ")
			} else if strings.contains(title, "/about") {
				input_set_text(st, "/about")
			} else if strings.contains(title, "/release") {
				input_set_text(st, "/release-notes")
			} else if strings.contains(title, "/keys") {
				input_set_text(st, "/keys")
			}
			focus_prompt(st)
			state_set_status(st, "docs → slash")
			return true
		}
		if path != "" && os.exists(path) && term != nil {
			term_suspend_for_pager(term)
			perr := agent.run_transcript_pager(path)
			term_resume_after_pager(term)
			if perr != "" {
				state_add_notice(st, perr)
			}
			state_set_status(st, "docs closed")
			state_add_notice(st, fmt.tprintf("aether: %s", path))
		}
		return true
	}
	return false
}

write_docs_picker_body :: proc(b: ^strings.Builder, p: ^Docs_Picker, cols: int, body_h: int) {
	write_row(b, " docs — guides & discover", cols, .Bar_Reverse, true)
	list_h := body_h - 2
	if list_h < 1 {
		list_h = 1
	}
	if p.selected < p.scroll {
		p.scroll = p.selected
	}
	if p.selected >= p.scroll + list_h {
		p.scroll = p.selected - list_h + 1
	}
	painted := 0
	for i := p.scroll; i < len(p.titles) && painted < list_h; i += 1 {
		sel := i == p.selected
		mark := " "
		if p.kinds[i] == 1 {
			mark = "↗"
		} else if p.kinds[i] == 0 {
			mark = "·"
		}
		line := fmt.tprintf("%s%s %s", "›" if sel else " ", mark, p.titles[i])
		if len(line) > cols - 1 {
			line = fmt.tprintf("%s…", line[:max(1, cols - 4)])
		}
		write_row(b, line, cols, .Bar_Reverse if sel else .Normal, true)
		painted += 1
	}
	for painted < list_h {
		write_row(b, "", cols, .Normal, true)
		painted += 1
	}
	write_row(b, " Enter open · Esc close", cols, .Bar_Dim, true)
}
