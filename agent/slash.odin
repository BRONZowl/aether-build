// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:strings"
import "aether:core"
import "aether:tools"

Slash_Action :: enum {
	Continue,
	Exit,
	// Session was replaced/cleared — caller should rebuild UI from sess.
	Session_Changed,
}

// Slash_Writer receives user-visible slash output (one logical line at a time).
Slash_Writer :: #type proc(line: string)

// After /fork with a directive, TUI may pull this into the composer once.
// Owned heap string; take_fork_pending_composer transfers ownership.
g_fork_pending_composer: string

// take_fork_pending_composer: returns and clears pending directive (caller frees).
take_fork_pending_composer :: proc() -> string {
	s := g_fork_pending_composer
	g_fork_pending_composer = ""
	return s
}


// emit_line writes one slash output line (stderr when out is nil).
emit_line :: proc(out: Slash_Writer, line: string) {
	if out != nil {
		out(line)
	} else {
		fmt.eprintln(line)
	}
}

// emit_lines splits text on newlines and emits each non-empty line.
emit_lines :: proc(out: Slash_Writer, text: string) {
	start := 0
	for i := 0; i <= len(text); i += 1 {
		if i == len(text) || text[i] == '\n' {
			line := text[start:i]
			if line != "" {
				emit_line(out, line)
			}
			start = i + 1
		}
	}
}

// run_slash handles REPL/TUI slash commands. out defaults to stderr when nil.
// perm is optional live permission mode (updated by /always-approve).
run_slash :: proc(
	sess: ^Session,
	text: string,
	opts: Headless_Options,
	model: ^string,
	cwd: ^string,
	perm: ^core.Permission_Mode,
	out: Slash_Writer = nil,
) -> Slash_Action {
	perm_mode :: proc(perm: ^core.Permission_Mode) -> core.Permission_Mode {
		if perm != nil {
			return perm^
		}
		return .Always_Approve
	}

	cmd := text
	arg := ""
	if sp := strings.index_byte(text, ' '); sp >= 0 {
		cmd = text[:sp]
		arg = strings.trim_space(text[sp + 1:])
	}

	// Table-driven emit-only commands (P3); session lifecycle stays in the switch.
	if act, ok := slash_table_dispatch(
		cmd,
		Slash_Ctx {
			sess  = sess,
			arg   = arg,
			opts  = opts,
			model = model,
			cwd   = cwd,
			perm  = perm,
			out   = out,
		},
	); ok {
		return act
	}

	switch cmd {
	case "/quit", "/exit", "/q":
		// SessionEnd hooks before dream/leave (latch; host defer is no-op after)
		maybe_stop_hooks("exit")
		// Best-effort auto-dream before leave (gates apply).
		if note := maybe_auto_dream(sess, model^); note != "" {
			emit_lines(out, note)
		}
		return .Exit
	case "/always-approve", "/yolo":
		// /yolo always turns on
		a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
		if cmd == "/yolo" {
			a = "on"
		}
		cur := perm_mode(perm)
		changed := false
		switch a {
		case "", "on", "true", "1", "yes", "enable":
			if perm != nil {
				perm^ = .Always_Approve
				changed = true
			}
			emit_line(out, "aether: permission mode = always-approve")
		case "off", "false", "0", "no", "disable", "ask":
			if perm != nil {
				perm^ = .Ask
				changed = true
			}
			emit_line(out, "aether: permission mode = ask")
		case "read-only", "readonly", "ro":
			if perm != nil {
				perm^ = .Read_Only
				changed = true
			}
			emit_line(out, "aether: permission mode = read-only")
		case "auto", "accept-edits", "accept_edits":
			if perm != nil {
				perm^ = .Auto
				changed = true
			}
			emit_line(out, "aether: permission mode = auto (accept file edits; ask for shell)")
		case "toggle":
			if perm != nil {
				if perm^ == .Always_Approve {
					perm^ = .Ask
				} else {
					perm^ = .Always_Approve
				}
				changed = true
				emit_line(out, fmt.tprintf("aether: permission mode = %s", core.permission_mode_string(perm^)))
			} else {
				emit_line(out, "aether: permission mode pointer unavailable")
			}
		case "status", "?":
			emit_line(out, fmt.tprintf("aether: permission mode = %s", core.permission_mode_string(cur)))
		case:
			emit_line(out, "aether: usage: /always-approve [on|off|auto|read-only|toggle|status]")
		}
		if changed && perm != nil {
			if pe := core.persist_permission_mode(perm^); pe != "" {
				emit_line(out, fmt.tprintf("aether: permission_mode persist: %s", pe))
			}
		}
		return .Continue
	case "/auto":
		// Grok-shaped /auto toggle for accept-edits mode
		a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
		cur := perm_mode(perm)
		changed := false
		switch a {
		case "", "toggle":
			if perm != nil {
				if cur == .Auto {
					perm^ = .Ask
					emit_line(out, "aether: permission mode = ask (left auto)")
				} else {
					perm^ = .Auto
					emit_line(out, "aether: permission mode = auto (accept file edits; ask for shell)")
				}
				changed = true
			} else {
				emit_line(out, "aether: permission mode pointer unavailable")
			}
		case "on", "true", "1", "yes", "enable":
			if perm != nil {
				perm^ = .Auto
				changed = true
			}
			emit_line(out, "aether: permission mode = auto (accept file edits; ask for shell)")
		case "off", "false", "0", "no", "disable", "ask":
			if perm != nil {
				perm^ = .Ask
				changed = true
			}
			emit_line(out, "aether: permission mode = ask")
		case "status", "?":
			emit_line(out, fmt.tprintf("aether: permission mode = %s", core.permission_mode_string(cur)))
		case:
			emit_line(out, "aether: usage: /auto [on|off|toggle|status]")
		}
		if changed && perm != nil {
			if pe := core.persist_permission_mode(perm^); pe != "" {
				emit_line(out, fmt.tprintf("aether: permission_mode persist: %s", pe))
			}
		}
		return .Continue
	case "/model", "/m":
		a := strings.trim_space(arg)
		if a == "" || a == "status" || a == "?" {
			cur := model^ if model != nil else ""
			if sess != nil && sess.model != "" {
				cur = sess.model
			}
			emit_line(out, fmt.tprintf("aether: model = %s", cur if cur != "" else "(unset)"))
			emit_line(out, "aether: usage: /model <id>   examples: grok-4.5, grok-build")
			return .Continue
		}
		if model != nil {
			delete(model^)
			model^ = strings.clone(a)
		}
		if sess != nil {
			delete(sess.model)
			sess.model = strings.clone(a)
			if sess.auto_save {
				if e := session_save(sess); e != "" {
					emit_line(out, fmt.tprintf("aether: model set to %s (save failed: %s)", a, e))
					return .Continue
				}
			}
		}
		if pe := core.persist_default_model(a); pe != "" {
			emit_line(out, fmt.tprintf("aether: model set to %s (persist: %s)", a, pe))
		} else {
			emit_line(out, fmt.tprintf("aether: model set to %s", a))
		}
		return .Continue
	case "/copy":
		// /copy [N] — Nth latest non-empty assistant message (1 = most recent)
		n := 1
		if strings.trim_space(arg) != "" {
			v, ok := parse_rewind_count(arg)
			if !ok {
				emit_line(out, "aether: usage: /copy [N]  (Nth latest assistant reply)")
				return .Continue
			}
			n = v
		}
		// walk assistants from end
		found := 0
		body := ""
		if sess != nil {
			for i := len(sess.msgs) - 1; i >= 0; i -= 1 {
				if sess.msgs[i].role == .Assistant &&
				   strings.trim_space(sess.msgs[i].content) != "" {
					found += 1
					if found == n {
						body = sess.msgs[i].content
						break
					}
				}
			}
		}
		if body == "" {
			emit_line(out, fmt.tprintf("aether: no assistant reply #%d to copy", n))
			return .Continue
		}
		st := copy_text_to_clipboard(body)
		emit_line(out, fmt.tprintf("aether: %s (%d chars)", st, len(body)))
		return .Continue
	case "/history":
		// List / filter / show session user prompts (newest first)
		all := collect_user_prompts(sess.msgs[:], context.temp_allocator)
		// temp_allocator owns; no destroy needed for short-lived
		a := strings.trim_space(arg)
		if a == "" || a == "list" || a == "?" {
			filtered := filter_prompts(all, "", context.temp_allocator)
			emit_line(out, format_history_list(filtered, 20, 100, context.temp_allocator))
			return .Continue
		}
		if idx, ok := parse_history_index(a); ok {
			if idx > len(all) {
				emit_line(out, fmt.tprintf("aether: history #%d not found (%d prompts)", idx, len(all)))
				return .Continue
			}
			// full text of that prompt
			emit_line(out, fmt.tprintf("aether: history #%d:\n%s", idx, all[idx - 1]))
			return .Continue
		}
		// substring filter
		filtered := filter_prompts(all, a, context.temp_allocator)
		if len(filtered) == 0 {
			emit_line(out, fmt.tprintf("aether: no prompts matching %q", a))
			return .Continue
		}
		emit_line(out, format_history_list(filtered, 20, 100, context.temp_allocator))
		return .Continue
	case "/theme", "/t":
		// C2.1 — name stored in core; TUI re-reads each paint; B9 persists [ui] theme
		a := strings.trim_space(arg)
		al := strings.to_lower(a, context.temp_allocator)
		if a == "" {
			next := core.cycle_ui_theme_name()
			if pe := core.persist_ui_string("theme", next); pe != "" {
				emit_line(out, fmt.tprintf("aether: theme → %s (persist: %s)", next, pe))
			} else {
				emit_line(out, fmt.tprintf("aether: theme → %s", next))
			}
			return .Continue
		}
		if al == "list" || al == "ls" || al == "help" || al == "?" {
			txt := core.list_ui_theme_names(context.temp_allocator)
			// emit lines
			emit_lines(out, txt)
			return .Continue
		}
		if al == "status" || al == "show" {
			emit_line(out, fmt.tprintf("aether: theme = %s", core.get_ui_theme_name()))
			return .Continue
		}
		if core.set_ui_theme_name(a) {
			name := core.get_ui_theme_name()
			if pe := core.persist_ui_string("theme", name); pe != "" {
				emit_line(out, fmt.tprintf("aether: theme → %s (persist: %s)", name, pe))
			} else {
				emit_line(out, fmt.tprintf("aether: theme → %s", name))
			}
		} else {
			emit_line(out, fmt.tprintf("aether: unknown theme %q — try /theme list", a))
		}
		return .Continue
	case "/plan":
		arg_l := strings.to_lower(arg, context.temp_allocator)
		if arg_l == "off" || arg_l == "exit" || arg_l == "leave" || arg_l == "end" {
			emit_line(out, user_exit_plan_mode(sess.cwd, false, context.temp_allocator))
			sess.plan_mode =
				plan_mode_is_active() || plan_mode_is_pending() || plan_mode_is_exit_pending()
			return .Continue
		}
		if arg_l == "status" || arg_l == "?" {
			st := plan_mode_state()
			path := plan_file_path_for_cwd(sess.cwd, context.temp_allocator)
			switch st {
			case .Active:
				emit_line(out, fmt.tprintf("plan mode: ACTIVE — %s", path))
			case .Pending:
				emit_line(out, fmt.tprintf("plan mode: PENDING (activates next turn) — %s", path))
			case .Exit_Pending:
				emit_line(out, fmt.tprintf("plan mode: EXIT PENDING — %s", path))
			case .Inactive:
				emit_line(out, "plan mode: OFF")
			}
			return .Continue
		}
		if arg_l == "view" || arg_l == "show" || arg_l == "cat" {
			// /plan view → same as /view-plan
			pcwd := sess.cwd if sess.cwd != "" else cwd^
			vp := handle_view_plan_slash(pcwd, context.temp_allocator)
			emit_lines(out, vp)
			return .Continue
		}
		// bare /plan, /plan on, or /plan <description>
		desc := arg
		if arg_l == "on" {
			desc = ""
		}
		emit_line(out, user_enter_plan_mode(sess.cwd, desc, context.temp_allocator))
		sess.plan_mode =
			plan_mode_is_active() || plan_mode_is_pending() || plan_mode_is_exit_pending()
		return .Continue
	case "/login":
		// Host bridge — blocks until grok login returns (TTY/browser).
		extra: []string
		if strings.trim_space(arg) != "" {
			// single optional passthrough blob split on spaces (simple)
			parts := strings.fields(arg, context.temp_allocator)
			extra = parts
		}
		code := run_host_login(extra, opts.quiet)
		if code != 0 {
			emit_line(out, fmt.tprintf("login failed (exit %d) — see stderr; or set XAI_API_KEY", code))
		} else {
			emit_line(out, "login ok — try /whoami")
		}
		return .Continue
	case "/cd":
		cur := cwd^ if cwd != nil else (sess.cwd if sess != nil else ".")
		// msg is temp; new_path is heap-owned when non-empty
		msg, new_path := handle_cd_slash(arg, cur, context.allocator)
		emit_lines(out, msg)
		delete(msg)
		if new_path != "" {
			if cwd != nil {
				delete(cwd^)
				cwd^ = strings.clone(new_path)
			}
			if sess != nil {
				delete(sess.cwd)
				sess.cwd = strings.clone(new_path)
				if sess.auto_save {
					if e := session_save(sess); e != "" {
						emit_line(out, fmt.tprintf("aether: cwd set but save failed: %s", e))
					}
				}
			}
			delete(new_path)
		}
		return .Continue
	case "/skills":
		arg_l := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
		if arg_l == "reload" || arg_l == "refresh" {
			ws := cwd^ if cwd != nil else (sess.cwd if sess != nil else ".")
			msg := reload_skills_for_cwd(ws, true)
			// emit line-by-line
			emit_lines(out, msg)
			delete(msg)
			return .Continue
		}
		if arg != "" {
			// /skills <name> same as /skill
			body := skills_invoke_text(arg, "", context.temp_allocator)
			// show first lines only for slash output
			if len(body) > 2000 {
				emit_line(out, body[:2000])
				emit_line(out, "…[truncated; full body available via skill tool]")
			} else {
				emit_line(out, body)
			}
			return .Continue
		}
		emit_line(out, skills_list_text(context.temp_allocator))
		return .Continue
	case "/skill":
		if arg == "" {
			emit_line(out, "aether: usage: /skill <name> [args]")
			return .Continue
		}
		name := arg
		rest := ""
		if sp := strings.index_byte(arg, ' '); sp >= 0 {
			name = arg[:sp]
			rest = strings.trim_space(arg[sp + 1:])
		}
		body := skills_invoke_text(name, rest, context.temp_allocator)
		if len(body) > 2000 {
			emit_line(out, body[:2000])
			emit_line(out, "…[truncated; model can use skill tool for full text]")
		} else {
			emit_line(out, body)
		}
		return .Continue
	case "/session-info", "/session":
		// Grok primary: /session-info; /session is alias (always show full info)
		emit_line(out, fmt.tprintf("id:        %s", sess.id))
		emit_line(out, fmt.tprintf("title:     %s", sess.title if sess.title != "" else "(none)"))
		emit_line(out, fmt.tprintf("path:      %s", sess.path))
		emit_line(out, fmt.tprintf("model:     %s", sess.model))
		emit_line(out, fmt.tprintf("cwd:       %s", sess.cwd))
		emit_line(out, fmt.tprintf("messages:  %d", len(sess.msgs)))
		emit_line(out, fmt.tprintf("autosave:  %v", sess.auto_save))
		chars := estimate_message_chars(sess.msgs[:])
		toks := estimate_tokens(chars)
		window := default_context_window()
		pct := context_usage_pct(toks, window)
		emit_line(
			out,
			fmt.tprintf(
				"context:   ~%d/%d tokens (%d%%)  auto-compact %s@%d%%",
				toks,
				window,
				pct,
				"on" if auto_compact_enabled() else "off",
				auto_compact_threshold_pct(),
			),
		)
		emit_line(out, fmt.tprintf("permission: %s", core.permission_mode_string(perm_mode(perm))))
		return .Continue
	case "/resume", "/sessions":
		// Grok primary: /resume; /sessions is alias (list/filter/delete)
		// /sessions delete|rm|search|N
		arg_trim := strings.trim_space(arg)
		arg_l := strings.to_lower(arg_trim, context.temp_allocator)
		if strings.has_prefix(arg_l, "delete ") || strings.has_prefix(arg_l, "rm ") {
			sp := strings.index_byte(arg_trim, ' ')
			ref := strings.trim_space(arg_trim[sp + 1:]) if sp >= 0 else ""
			if ref == "" {
				emit_line(out, "aether: usage: /sessions delete <id|title|path>")
				return .Continue
			}
			if derr := session_delete_by_ref(ref, sess.sessions_dir, sess.path); derr != "" {
				emit_line(out, fmt.tprintf("aether: %s", derr))
			} else {
				emit_line(out, fmt.tprintf("aether: deleted session %s", ref))
			}
			return .Continue
		}
		// filter query
		filter := ""
		limit := 20
		if strings.has_prefix(arg_l, "search ") || strings.has_prefix(arg_l, "find ") {
			sp := strings.index_byte(arg_trim, ' ')
			filter = strings.trim_space(arg_trim[sp + 1:]) if sp >= 0 else ""
		} else if arg_trim != "" {
			// pure number → limit; else treat as search
			if n, ok := parse_history_index(arg_trim); ok {
				limit = n
				if limit > 100 {
					limit = 100
				}
			} else {
				filter = arg_trim
			}
		}
		entries, err := list_sessions(sess.sessions_dir, context.temp_allocator)
		if err != "" {
			emit_line(out, fmt.tprintf("aether: %s", err))
			return .Continue
		}
		if len(entries) == 0 {
			emit_line(out, "(no saved sessions)")
			return .Continue
		}
		// filter by id/title substring
		show := make([dynamic]Session_List_Entry, 0, min(limit, len(entries)), context.temp_allocator)
		if filter != "" {
			fl := strings.to_lower(filter, context.temp_allocator)
			for e in entries {
				id_l := strings.to_lower(e.id, context.temp_allocator)
				title_l := strings.to_lower(e.title, context.temp_allocator)
				if strings.contains(id_l, fl) || strings.contains(title_l, fl) {
					append(&show, e)
				}
			}
		} else {
			for e in entries {
				append(&show, e)
			}
		}
		if len(show) == 0 {
			emit_line(out, fmt.tprintf("aether: no sessions matching %q", filter))
			return .Continue
		}
		emit_line(out, "aether: sessions (newest first; * = current; /load <id|title>)")
		emit_line(out, " #  id                      when         msg  model             title")
		n := min(limit, len(show))
		for i in 0 ..< n {
			e := show[i]
			cur := e.path == sess.path || e.id == sess.id
			line := format_session_list_line(e, cur, i + 1, context.temp_allocator)
			emit_line(out, line)
		}
		if len(show) > n {
			emit_line(out, fmt.tprintf("… %d more (raise limit: /sessions %d)", len(show) - n, len(show)))
		}
		return .Continue
	case "/rename", "/title":
		if strings.trim_space(arg) == "" {
			emit_line(out, "aether: usage: /rename <title>")
			return .Continue
		}
		if e := session_set_title(sess, arg); e != "" {
			emit_line(out, fmt.tprintf("aether: rename failed: %s", e))
		} else {
			emit_line(out, fmt.tprintf("aether: title set to %q", sess.title))
		}
		return .Continue
	case "/fork":
		// Grok-shaped: /fork [--worktree|--no-worktree] [title/directive]
		wt, rest, perr := parse_fork_args(arg)
		if perr != "" {
			emit_line(out, fmt.tprintf("aether: %s", perr))
			emit_line(out, "aether: usage: /fork [--worktree|--no-worktree] [title]")
			return .Continue
		}
		// REPL/headless: Ask → No (TUI modal resolves Ask before calling with Yes/No)
		if wt == .Ask {
			wt = .No
			if strings.trim_space(arg) == "" || strings.trim_space(rest) == strings.trim_space(arg) {
				// bare or title-only: tip about worktree
				emit_line(out, "aether: forking in same workspace (use /fork --worktree for isolated git worktree)")
			}
		}
		if wt == .Yes && !worktree_enabled() {
			emit_line(out, "aether: worktree isolation disabled (AETHER_NO_WORKTREE=1); using same workspace")
			wt = .No
		}

		parent_cwd := sess.cwd
		if parent_cwd == "" && cwd != nil {
			parent_cwd = cwd^
		}
		if parent_cwd == "" {
			parent_cwd = "."
		}

		// Create worktree before switching session (need parent cwd + new id)
		// We need an id first for path naming — generate via dry fork path:
		// 1) autosave parent 2) fork session 3) worktree with forked.id 4) set cwd
		if sess.auto_save {
			if e := session_save(sess); e != "" {
				emit_line(out, fmt.tprintf("aether: autosave before fork failed: %s", e))
			}
		}

		title := fork_title_from_rest(rest)
		if len(title) > 77 && len(strings.trim_space(rest)) > 77 {
			title = fmt.tprintf("%s…", title)
		}

		forked, ferr := session_fork(sess^, title, context.allocator)
		if ferr != "" {
			emit_line(out, fmt.tprintf("aether: fork failed: %s", ferr))
			return .Continue
		}

		wt_note := "worktree=no"
		if wt == .Yes {
			wt_path, wterr := create_subagent_worktree(parent_cwd, forked.id, context.allocator)
			if wterr != "" {
				// Roll back forked session file
				_ = session_delete_by_ref(forked.path, forked.sessions_dir, "")
				destroy_session(&forked)
				emit_line(out, fmt.tprintf("aether: worktree failed: %s", wterr))
				emit_line(out, "aether: parent session unchanged; try /fork --no-worktree or fix git")
				return .Continue
			}
			delete(forked.cwd)
			forked.cwd = wt_path // takes ownership of allocated path
			if e := session_save(&forked); e != "" {
				emit_line(out, fmt.tprintf("aether: forked but save cwd failed: %s", e))
			}
			wt_note = fmt.tprintf("worktree=yes cwd=%s", forked.cwd)
		}

		// Switch to fork
		old_auto := sess.auto_save
		destroy_session(sess)
		sess^ = forked
		sess.auto_save = old_auto
		if sess.model != "" && model != nil {
			delete(model^)
			model^ = strings.clone(sess.model)
		}
		if sess.cwd != "" && cwd != nil {
			delete(cwd^)
			cwd^ = strings.clone(sess.cwd)
		}
		// Stash directive for TUI composer (process-local; optional)
		delete(g_fork_pending_composer)
		g_fork_pending_composer = ""
		if strings.trim_space(rest) != "" {
			g_fork_pending_composer = strings.clone(strings.trim_space(rest))
		}
		emit_line(
			out,
			fmt.tprintf(
				"aether: forked → session %s %q (%d messages) %s",
				sess.id,
				sess.title,
				len(sess.msgs),
				wt_note,
			),
		)
		return .Session_Changed
	case "/export":
		a := strings.trim_space(arg)
		if a == "help" || a == "?" {
			emit_line(out, "aether: usage: /export [json|md] [path]")
			emit_line(out, "  default     markdown → <sessions>/<id>-export.md")
			emit_line(out, "  json [path] full session JSON dump")
			emit_line(out, "  path.json   infers JSON from extension")
			return .Continue
		}
		path, eerr := session_export(sess^, a, context.allocator)
		if eerr != "" {
			emit_line(out, fmt.tprintf("aether: export failed: %s", eerr))
		} else {
			kind := "transcript"
			pl := strings.to_lower(path, context.temp_allocator)
			if strings.has_suffix(pl, ".json") || strings.has_suffix(pl, ".jsonl") {
				kind = "JSON session"
			}
			emit_line(out, fmt.tprintf("aether: exported %s → %s", kind, path))
			delete(path)
		}
		return .Continue
	case "/import":
		a := strings.trim_space(arg)
		if a == "" || a == "help" || a == "?" {
			emit_line(out, "aether: usage: /import <path.json>")
			emit_line(out, "  Load a session or /export json dump as a **new** session (new id).")
			return .Continue
		}
		if sess.auto_save {
			if e := session_save(sess); e != "" {
				emit_line(out, fmt.tprintf("aether: autosave failed before import: %s", e))
			}
		}
		dir := sess.sessions_dir
		if dir == "" {
			dir = core.aether_sessions_dir("", context.temp_allocator)
		}
		loaded, lerr := session_import_file(a, dir, sess.auto_save)
		if lerr != "" {
			emit_line(out, fmt.tprintf("aether: import failed: %s", lerr))
			return .Continue
		}
		old_auto := sess.auto_save
		destroy_session(sess)
		sess^ = loaded
		sess.auto_save = old_auto
		if sess.model != "" && model != nil {
			delete(model^)
			model^ = strings.clone(sess.model)
		}
		if sess.cwd != "" && cwd != nil {
			delete(cwd^)
			cwd^ = strings.clone(sess.cwd)
		}
		title_note := ""
		if sess.title != "" {
			title_note = fmt.tprintf(" %q", sess.title)
		}
		emit_line(
			out,
			fmt.tprintf(
				"aether: imported → session %s%s (%d messages)",
				sess.id,
				title_note,
				len(sess.msgs),
			),
		)
		return .Session_Changed
	case "/undo-file", "/rewind-file":
		// Soft file-edit stack (B2.2); conversation rewind is /rewind
		a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
		switch a {
		case "status", "show", "?", "list":
			emit_line(out, tools.file_rewind_status(context.temp_allocator))
		case "clear", "reset":
			tools.file_rewind_clear()
			emit_line(out, "aether: file rewind stack cleared")
		case "", "once", "1", "undo":
			emit_line(out, tools.file_rewind_undo(context.temp_allocator))
		case:
			emit_line(out, "aether: usage: /undo-file [status|clear]  (undo last write/edit/delete)")
		}
		return .Continue
	case "/rewind":
		// Grok-shaped conversation rewind: drop last N user turns
		a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
		switch a {
		case "status", "show", "?", "list":
			emit_line(out, format_conversation_rewind_status(sess, context.temp_allocator))
			emit_line(out, tools.file_rewind_status(context.temp_allocator))
		case "file", "files":
			// convenience → file stack undo once
			emit_line(out, tools.file_rewind_undo(context.temp_allocator))
		case:
			n, ok := parse_rewind_count(arg)
			if !ok {
				emit_line(out, "aether: usage: /rewind [N|status]  (conversation turns; file undo: /undo-file)")
				return .Continue
			}
			before := len(sess.msgs)
			removed, rerr := conversation_rewind_turns(sess, n)
			if rerr != "" {
				emit_line(out, fmt.tprintf("aether: %s", rerr))
				return .Continue
			}
			if sess.auto_save {
				if e := session_save(sess); e != "" {
					emit_line(
						out,
						fmt.tprintf(
							"aether: rewound %d turn(s) (%d→%d msgs; save failed: %s)",
							removed,
							before,
							len(sess.msgs),
							e,
						),
					)
					return .Session_Changed
				}
			}
			emit_line(
				out,
				fmt.tprintf(
					"aether: rewound %d user turn(s) (%d→%d messages)",
					removed,
					before,
					len(sess.msgs),
				),
			)
			return .Session_Changed
		}
		return .Continue
	case "/save":
		if arg != "" {
			delete(sess.title)
			sess.title = strings.clone(arg)
		}
		if e := session_save(sess); e != "" {
			emit_line(out, fmt.tprintf("aether: save failed: %s", e))
		} else {
			emit_line(out, fmt.tprintf("aether: saved %s", sess.path))
		}
		return .Continue
	case "/load":
		if arg == "" {
			emit_line(out, "aether: usage: /load <id|title|path>")
			return .Continue
		}
		if sess.auto_save {
			if e := session_save(sess); e != "" {
				emit_line(out, fmt.tprintf("aether: autosave failed before load: %s", e))
			}
		}
		path, rerr := resolve_session_ref(arg, sess.sessions_dir, context.temp_allocator)
		if rerr != "" {
			emit_line(out, fmt.tprintf("aether: %s", rerr))
			return .Continue
		}
		loaded, lerr := session_load_file(path, sess.auto_save)
		if lerr != "" {
			emit_line(out, fmt.tprintf("aether: load failed: %s", lerr))
			return .Continue
		}
		old_auto := sess.auto_save
		destroy_session(sess)
		sess^ = loaded
		sess.auto_save = old_auto
		if sess.model != "" {
			model^ = sess.model
		}
		if sess.cwd != "" {
			cwd^ = sess.cwd
		}
		title_note := ""
		if sess.title != "" {
			title_note = fmt.tprintf(" %q", sess.title)
		}
		emit_line(
			out,
			fmt.tprintf(
				"aether: loaded session %s%s (%d messages)",
				sess.id,
				title_note,
				len(sess.msgs),
			),
		)
		return .Session_Changed
	case "/new", "/clear", "/home", "/welcome":
		// Grok: /clear = /new; /home|/welcome return to empty welcome session
		is_home := cmd == "/home" || cmd == "/welcome"
		if sess.auto_save {
			if e := session_save(sess); e != "" {
				emit_line(out, fmt.tprintf("aether: autosave failed before new: %s", e))
			}
		}
		// Auto-dream previous session before destroy (gates apply).
		if note := maybe_auto_dream(sess, model^); note != "" {
			emit_lines(out, note)
		}
		dir := strings.clone(sess.sessions_dir)
		auto := sess.auto_save
		m := strings.clone(model^)
		c := strings.clone(cwd^)
		destroy_session(sess)
		clear_plan_mode_for_new_session()
		core.session_allow_clear()
		core.session_deny_clear()
		tools.todo_clear()
		tools.file_rewind_clear()
		scheduler_clear_session() // keep durable=true tasks
		goal_clear()
		image_reg_clear()
		catalog := skills_catalog_text(context.temp_allocator)
		sess^ = new_session(m, c, dir, auto, perm_mode(perm), context.allocator, catalog)
		delete(m)
		delete(c)
		delete(dir)
		if is_home {
			emit_line(out, fmt.tprintf("aether: welcome (session %s)", sess.id))
		} else {
			emit_line(out, fmt.tprintf("aether: new session %s", sess.id))
		}
		return .Session_Changed
	case:
		// /skillname as bare skill invoke when not a builtin
		if strings.has_prefix(cmd, "/") && len(cmd) > 1 {
			sname := cmd[1:]
			if skills_is_named(sname) {
				body := skills_invoke_text(sname, arg, context.temp_allocator)
				if len(body) > 2000 {
					emit_line(out, body[:2000])
					emit_line(out, "…[truncated; model can use skill tool for full text]")
				} else {
					emit_line(out, body)
				}
				return .Continue
			}
		}
		emit_line(out, fmt.tprintf("aether: unknown command %s (try /help)", cmd))
		return .Continue
	}
}


