// Package tui — Agent Dashboard overview (Wave 3).
// Sessions + background tasks + scheduler. Enter loads a session; k kills bg task.
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:strings"
import "aether:agent"
import "aether:core"

Dashboard_Row_Kind :: enum {
	Text,
	Session,
	Bg_Task,
	Sched,
}

Dashboard_Row :: struct {
	kind:    Dashboard_Row_Kind,
	label:   string, // owned
	payload: string, // owned: session path, task id, or sched id
}

Dashboard :: struct {
	active:       bool,
	rows:         [dynamic]Dashboard_Row,
	selected:     int,
	scroll:       int,
	sessions_dir: string, // owned
	current_id:   string, // owned
}

dashboard_init :: proc(d: ^Dashboard) {
	d.rows = make([dynamic]Dashboard_Row, 0, 32)
	d.selected = 0
	d.scroll = 0
	d.active = false
	d.sessions_dir = ""
	d.current_id = ""
}

dashboard_destroy :: proc(d: ^Dashboard) {
	dashboard_clear(d)
	delete(d.rows)
	delete(d.sessions_dir)
	delete(d.current_id)
	d.active = false
}

dashboard_clear :: proc(d: ^Dashboard) {
	for r in d.rows {
		delete(r.label)
		delete(r.payload)
	}
	clear(&d.rows)
	d.selected = 0
	d.scroll = 0
}

dashboard_add_text :: proc(d: ^Dashboard, line: string) {
	append(
		&d.rows,
		Dashboard_Row{kind = .Text, label = strings.clone(line), payload = ""},
	)
}

dashboard_add :: proc(d: ^Dashboard, kind: Dashboard_Row_Kind, label, payload: string) {
	append(
		&d.rows,
		Dashboard_Row {
			kind    = kind,
			label   = strings.clone(label),
			payload = strings.clone(payload) if payload != "" else "",
		},
	)
}

// extract_token_after: first token after prefix like "id=" or leading task id.
extract_after :: proc(line, key: string) -> string {
	idx := strings.index(line, key)
	if idx < 0 {
		return ""
	}
	rest := line[idx + len(key):]
	end := 0
	for end < len(rest) {
		c := rest[end]
		if c == ' ' || c == '\t' || c == '\n' || c == ',' {
			break
		}
		end += 1
	}
	return rest[:end]
}

// dashboard_open rebuilds rows from session list + bg + scheduler.
dashboard_open :: proc(d: ^Dashboard, sess: ^agent.Session) {
	dashboard_clear(d)
	delete(d.sessions_dir)
	delete(d.current_id)
	d.sessions_dir = ""
	d.current_id = ""
	if sess != nil {
		dir := sess.sessions_dir
		if dir == "" {
			dir = core.aether_sessions_dir("", context.temp_allocator)
		}
		d.sessions_dir = strings.clone(dir)
		d.current_id = strings.clone(sess.id)
		dashboard_add_text(
			d,
			fmt.tprintf(
				"Current  %s  %q  msgs=%d  cwd=%s",
				sess.id,
				sess.title if sess.title != "" else "(none)",
				len(sess.msgs),
				sess.cwd,
			),
		)
	} else {
		dashboard_add_text(d, "Current  (none)")
	}
	dashboard_add_text(d, "")
	dashboard_add_text(d, "— Sessions (Enter load) —")
	if d.sessions_dir != "" {
		entries, err := agent.list_sessions(d.sessions_dir, context.temp_allocator)
		if err != "" {
			dashboard_add_text(d, fmt.tprintf("  (list error: %s)", err))
		} else if len(entries) == 0 {
			dashboard_add_text(d, "  (no saved sessions)")
		} else {
			n := min(12, len(entries))
			for i in 0 ..< n {
				e := entries[i]
				cur := e.id == d.current_id
				title := e.title if e.title != "" else "(untitled)"
				label := fmt.tprintf("%s %s  %s", "*" if cur else " ", e.id, title)
				dashboard_add(d, .Session, label, e.path)
			}
			agent.destroy_session_list(entries)
		}
	}
	dashboard_add_text(d, "")
	dashboard_add_text(d, "— Background tasks (k kill) —")
	bg := agent.format_bg_tasks_list(context.temp_allocator)
	// Parse "  - id  [status] kind  desc" lines
	start := 0
	any_bg := false
	for i := 0; i <= len(bg); i += 1 {
		if i == len(bg) || bg[i] == '\n' {
			line := bg[start:i]
			trim := strings.trim_space(line)
			if strings.has_prefix(trim, "- ") {
				// "- id  [status] ..."
				rest := strings.trim_space(trim[2:])
				id_end := 0
				for id_end < len(rest) && rest[id_end] != ' ' && rest[id_end] != '\t' {
					id_end += 1
				}
				id := rest[:id_end]
				if id != "" {
					dashboard_add(d, .Bg_Task, fmt.tprintf("  %s", trim), id)
					any_bg = true
				}
			} else if trim != "" && !strings.has_prefix(trim, "Background") {
				dashboard_add_text(d, fmt.tprintf("  %s", trim))
			}
			start = i + 1
		}
	}
	if !any_bg {
		// format_bg_tasks_list always emits a header; ensure empty note
		if strings.contains(bg, "(none)") || strings.contains(bg, "none") {
			// already may have text
		}
	}
	dashboard_add_text(d, "")
	dashboard_add_text(d, "— Scheduled —")
	sched := agent.handle_scheduler_list("{}", context.temp_allocator)
	start = 0
	for i := 0; i <= len(sched); i += 1 {
		if i == len(sched) || sched[i] == '\n' {
			line := sched[start:i]
			if line != "" {
				payload := extract_after(line, "id=")
				if payload != "" {
					dashboard_add(d, .Sched, fmt.tprintf("  %s", line), payload)
				} else {
					dashboard_add_text(d, fmt.tprintf("  %s", line))
				}
			}
			start = i + 1
		}
	}
	dashboard_add_text(d, "")
	dashboard_add_text(d, "Enter load session · k kill bg · r refresh · Esc")
	d.selected = 0
	d.scroll = 0
	d.active = true
}

dashboard_close :: proc(d: ^Dashboard) {
	d.active = false
}

dashboard_move :: proc(d: ^Dashboard, delta: int) {
	if len(d.rows) == 0 {
		return
	}
	d.selected += delta
	if d.selected < 0 {
		d.selected = 0
	}
	if d.selected >= len(d.rows) {
		d.selected = len(d.rows) - 1
	}
}

handle_dashboard_key :: proc(
	st: ^App_State,
	sess: ^agent.Session,
	term: ^Term_State,
	key: Key,
	model: ^string,
	cwd: ^string,
) -> bool {
	d := &st.dashboard
	#partial switch key.kind {
	case .Esc, .Ctrl_C:
		dashboard_close(d)
		state_set_status(st, "ready")
		return true
	case .Up, .Ctrl_K:
		dashboard_move(d, -1)
		return true
	case .Down, .Ctrl_J:
		dashboard_move(d, 1)
		return true
	case .PgUp:
		dashboard_move(d, -max(1, term.rows / 2))
		return true
	case .PgDn:
		dashboard_move(d, max(1, term.rows / 2))
		return true
	case .Char:
		if key.ch == 'r' || key.ch == 'R' {
			dashboard_open(d, sess)
			state_set_status(st, "dashboard refreshed")
			return true
		}
		if key.ch == 'k' || key.ch == 'K' {
			if d.selected >= 0 && d.selected < len(d.rows) {
				row := d.rows[d.selected]
				if row.kind == .Bg_Task && row.payload != "" {
					msg := agent.handle_kill_task(
						fmt.tprintf(`{"task_id":%q}`, row.payload),
						context.temp_allocator,
					)
					state_add_notice(st, msg)
					dashboard_open(d, sess)
					state_set_status(st, "kill requested")
				} else {
					state_set_status(st, "select a background task to kill")
				}
			}
			return true
		}
	case .Enter:
		if d.selected < 0 || d.selected >= len(d.rows) {
			return true
		}
		row := d.rows[d.selected]
		if row.kind == .Session && row.payload != "" {
			path := strings.clone(row.payload)
			dashboard_close(d)
			if tui_load_session_path(st, sess, path, model, cwd) {
				state_set_status(st, "session loaded")
			}
			delete(path)
			return true
		}
		if row.kind == .Bg_Task {
			state_add_notice(st, fmt.tprintf("task %s — press k to kill", row.payload))
			state_set_status(st, "bg task")
			return true
		}
		if row.label != "" {
			state_add_notice(st, row.label)
		}
		return true
	}
	return false
}

write_dashboard_body :: proc(b: ^strings.Builder, d: ^Dashboard, cols: int, body_h: int) {
	write_row(b, " dashboard — sessions · bg · scheduled", cols, .Bar_Reverse, true)
	list_h := body_h - 2
	if list_h < 1 {
		list_h = 1
	}
	if d.selected < d.scroll {
		d.scroll = d.selected
	}
	if d.selected >= d.scroll + list_h {
		d.scroll = d.selected - list_h + 1
	}
	if d.scroll < 0 {
		d.scroll = 0
	}
	painted := 0
	for i := d.scroll; i < len(d.rows) && painted < list_h; i += 1 {
		sel := i == d.selected
		line := d.rows[i].label
		if len(line) > cols - 2 {
			line = fmt.tprintf("%s…", line[:max(1, cols - 5)])
		}
		disp := fmt.tprintf("%s%s", "›" if sel else " ", line)
		if sel {
			write_row(b, disp, cols, .Bar_Reverse, true)
		} else if d.rows[i].kind == .Text && strings.has_prefix(line, "—") {
			write_row(b, disp, cols, .Bar_Dim, true)
		} else {
			write_row(b, disp, cols, .Normal, true)
		}
		painted += 1
	}
	for painted < list_h {
		write_row(b, "", cols, .Normal, true)
		painted += 1
	}
	write_row(b, " Enter load · k kill · r refresh · Esc", cols, .Bar_Dim, true)
}
