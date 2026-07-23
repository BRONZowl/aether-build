// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:strings"
import "aether:agent"
import "aether:core"

// TUI slash command host (/new, /load, …).

handle_slash :: proc(
	st: ^App_State,
	sess: ^agent.Session,
	term: ^Term_State,
	line: string,
	model: ^string,
	cwd: ^string,
	perm: ^core.Permission_Mode,
	perm_before: ^core.Permission_Mode,
	opts: agent.Headless_Options,
) -> bool {
	// Local TUI-only
	if line == "/yolo" {
		input_clear(st)
		toggle_yolo(st, perm, perm_before)
		return true
	}
	if line == "/find" || strings.has_prefix(line, "/find ") {
		input_clear(st)
		q := ""
		if sp := strings.index_byte(line, ' '); sp >= 0 {
			q = strings.trim_space(line[sp + 1:])
		}
		search_open(st, q)
		return true
	}
	if line == "/multiline" || line == "/ml" {
		// B36: /ml alias (Grok-shaped)
		input_clear(st)
		st.multiline_mode = !st.multiline_mode
		state_set_status(st, "multiline on" if st.multiline_mode else "multiline off")
		return true
	}
	// Wave 1: /queue list pane (also slash text via agent when REPL)
	if line == "/queue" || strings.has_prefix(line, "/queue ") {
		arg := ""
		if sp := strings.index_byte(line, ' '); sp >= 0 {
			arg = strings.trim_space(line[sp + 1:])
		}
		arg_l := strings.to_lower(arg, context.temp_allocator)
		input_clear(st)
		if arg_l == "clear" || arg_l == "reset" {
			prompt_queue_clear(st)
			state_set_status(st, "queue cleared")
			state_add_notice(st, "aether: queue cleared")
			return true
		}
		if strings.has_prefix(arg_l, "drop ") || strings.has_prefix(arg_l, "rm ") {
			sp := strings.index_byte(arg, ' ')
			num := strings.trim_space(arg[sp + 1:]) if sp >= 0 else ""
			n, ok := parse_pos_int(num)
			if ok && n >= 1 && prompt_queue_drop(st, n - 1) {
				state_set_status(st, fmt.tprintf("queue %d left", prompt_queue_len(st)))
				state_add_notice(st, fmt.tprintf("aether: dropped queue item #%d", n))
			} else {
				state_set_status(st, "usage: /queue drop N")
			}
			return true
		}
		// bare /queue → pane
		queue_pane_open(st)
		state_add_notice(st, prompt_queue_format_list(st, context.temp_allocator))
		return true
	}
	// Wave 1: bare /rewind → turn picker
	if line == "/rewind" {
		input_clear(st)
		rewind_picker_open(&st.rewind_picker, sess)
		if len(st.rewind_picker.labels) == 0 {
			rewind_picker_close(&st.rewind_picker)
			state_set_status(st, "no user turns to rewind")
			state_add_notice(st, "aether: no user turns to rewind")
		} else {
			state_set_status(st, "rewind picker")
		}
		return true
	}
	// Wave 1: bare /settings → settings modal (no billing)
	if line == "/settings" || line == "/config" || line == "/preferences" || line == "/prefs" {
		input_clear(st)
		settings_modal_open(&st.settings_modal, st, perm^)
		state_set_status(st, "settings")
		return true
	}
	// bare /fork or /fork <title> without flags → worktree modal
	if line == "/fork" || strings.has_prefix(line, "/fork ") {
		arg := ""
		if sp := strings.index_byte(line, ' '); sp >= 0 {
			arg = strings.trim_space(line[sp + 1:])
		}
		wt, rest, perr := agent.parse_fork_args(arg)
		if perr != "" {
			input_clear(st)
			state_add_notice(st, fmt.tprintf("aether: %s", perr))
			state_set_status(st, "fork error")
			return true
		}
		if wt == .Ask {
			// Grok: always ask when no flags
			input_clear(st)
			fork_modal_open(&st.fork_modal, rest)
			state_set_status(st, "fork: worktree?")
			return true
		}
		// flagged: fall through to agent
	}
	// /help bare → command palette
	if line == "/help" || line == "/?" {
		input_clear(st)
		command_palette_open(&st.command_palette)
		state_set_status(st, "command palette")
		return true
	}
	// /docs bare → docs picker
	if line == "/docs" || line == "/howto" || line == "/guides" {
		input_clear(st)
		ws := cwd^ if cwd != nil else (sess.cwd if sess != nil else ".")
		docs_picker_open(&st.docs_picker, ws)
		state_set_status(st, "docs")
		return true
	}
	// /view-plan · /show-plan · /plan view → scrollable read-only plan preview
	{
		is_view :=
			line == "/view-plan" ||
			line == "/show-plan" ||
			line == "/plan-view" ||
			line == "/plan view" ||
			strings.has_prefix(line, "/plan view ")
		if is_view {
			input_clear(st)
			ws := cwd^ if cwd != nil else (sess.cwd if sess != nil else ".")
			path := agent.plan_file_path_for_cwd(ws, context.temp_allocator)
			tui_run_plan_view(path)
			return true
		}
	}
	// /personas /config-agents → personas modal
	if line == "/personas" ||
	   line == "/persona" ||
	   line == "/config-agents" ||
	   line == "/agents" {
		input_clear(st)
		ws := cwd^ if cwd != nil else (sess.cwd if sess != nil else ".")
		personas_modal_open(&st.personas_modal, ws)
		state_set_status(st, "agents / personas")
		return true
	}
	// Wave 3: /dashboard → overview (sessions + bg + scheduled)
	if line == "/dashboard" || line == "/agents-dashboard" {
		input_clear(st)
		dashboard_open(&st.dashboard, sess)
		state_set_status(st, "dashboard")
		return true
	}
	// bare /tasks → dashboard scrolled to tasks (same surface; refresh list)
	if line == "/tasks" {
		input_clear(st)
		dashboard_open(&st.dashboard, sess)
		// Prefer first Bg_Task row if any
		for i in 0 ..< len(st.dashboard.rows) {
			if st.dashboard.rows[i].kind == .Bg_Task {
				st.dashboard.selected = i
				break
			}
		}
		state_set_status(st, "tasks (dashboard)")
		return true
	}
	// Wave 2: bare extensions cmds → hub (args still go to agent text handlers)
	{
		cmd := line
		arg := ""
		if sp := strings.index_byte(line, ' '); sp >= 0 {
			cmd = line[:sp]
			arg = strings.trim_space(line[sp + 1:])
		}
		cmd_l := strings.to_lower(cmd, context.temp_allocator)
		is_ext :=
			cmd_l == "/hooks" ||
			cmd_l == "/plugins" ||
			cmd_l == "/plugin" ||
			cmd_l == "/skills" ||
			cmd_l == "/mcps" ||
			cmd_l == "/mcp" ||
			cmd_l == "/marketplace"
		if is_ext && arg == "" {
			input_clear(st)
			ws := cwd^ if cwd != nil else (sess.cwd if sess != nil else ".")
			tab := extensions_tab_from_slash(cmd_l)
			// /skill alone is not skills list — leave to agent if needed
			if cmd_l == "/skill" {
				// fall through
			} else {
				extensions_hub_open(&st.extensions_hub, tab, ws, opts.no_mcp)
				state_set_status(st, fmt.tprintf("extensions · %s", extensions_tab_name(tab)))
				return true
			}
		}
	}
	// Grok /expand — expand last tool card (fullscreen TUI equivalent of minimal re-print)
	if line == "/expand" {
		input_clear(st)
		if toggle_last_tool_expand(st) {
			// force expanded (toggle may have collapsed if already open)
			for i := len(st.blocks) - 1; i >= 0; i -= 1 {
				if st.blocks[i].kind == .Tool {
					st.blocks[i].expanded = true
					break
				}
			}
			state_set_status(st, "expanded last tool")
			state_add_notice(st, "aether: expanded last tool card")
		} else {
			state_set_status(st, "no tool card to expand")
			state_add_notice(st, "aether: no tool card to expand")
		}
		return true
	}
	// Grok /toggle-mouse-reporting
	if line == "/toggle-mouse-reporting" {
		input_clear(st)
		on := term_toggle_mouse(term)
		msg := "mouse reporting on" if on else "mouse reporting off"
		state_set_status(st, msg)
		state_add_notice(st, fmt.tprintf("aether: %s", msg))
		return true
	}
	// Grok /transcript|/log — export markdown and open in $PAGER
	if line == "/transcript" || line == "/log" {
		input_clear(st)
		path, eerr := agent.handle_transcript_export(sess^, context.allocator)
		if eerr != "" {
			state_set_status(st, eerr)
			state_add_notice(st, fmt.tprintf("aether: transcript failed: %s", eerr))
			return true
		}
		state_add_notice(st, fmt.tprintf("aether: transcript → %s", path))
		term_suspend_for_pager(term)
		perr := agent.run_transcript_pager(path)
		term_resume_after_pager(term)
		if perr != "" {
			state_add_notice(st, fmt.tprintf("aether: pager: %s", perr))
			state_set_status(st, "transcript saved (pager failed)")
		} else {
			state_set_status(st, "transcript pager closed")
		}
		delete(path)
		return true
	}
	// B40: bare /copy with a scrollback selection → copy that block (else agent Nth assistant)
	if line == "/copy" {
		if st.selected_block >= 0 && st.selected_block < len(st.blocks) {
			input_clear(st)
			msg := copy_selected_block(st, false)
			state_set_status(st, msg)
			state_add_notice(st, fmt.tprintf("aether: /copy selected → %s", msg))
			return true
		}
		// no selection: fall through to agent /copy (latest assistant)
	}
	// Grok /resume → session picker. Bare /sessions is alias of /resume.
	if line == "/resume" || line == "/sessions" || line == "/sessions-ui" {
		input_clear(st)
		err := picker_open(&st.picker, sess.sessions_dir)
		if err != "" {
			state_set_status(st, err)
		} else {
			state_set_status(st, "session picker")
		}
		return true
	}
	if line == "/model" || strings.has_prefix(line, "/model ") {
		input_clear(st)
		arg := ""
		if sp := strings.index_byte(line, ' '); sp >= 0 {
			arg = strings.trim_space(line[sp + 1:])
		}
		if arg != "" {
			// direct set: /model grok-4.5
			delete(model^)
			model^ = strings.clone(arg)
			delete(st.model)
			st.model = strings.clone(arg)
			delete(sess.model)
			sess.model = strings.clone(arg)
			if sess.auto_save {
				_ = agent.session_save(sess)
			}
			_ = core.persist_default_model(arg)
			state_set_status(st, fmt.tprintf("model: %s", arg))
			state_add_notice(st, fmt.tprintf("model set to %s", arg))
			return true
		}
		model_picker_open(&st.model_picker, model^)
		state_set_status(st, "model picker")
		return true
	}
	// /history N → fill composer with that prompt (Grok recall UX)
	if line == "/history" || strings.has_prefix(line, "/history ") {
		arg := ""
		if sp := strings.index_byte(line, ' '); sp >= 0 {
			arg = strings.trim_space(line[sp + 1:])
		}
		if idx, ok := agent.parse_history_index(arg); ok {
			prompts := agent.collect_user_prompts(sess.msgs[:], context.temp_allocator)
			if idx <= len(prompts) {
				input_set_text(st, prompts[idx - 1])
				st.history_idx = -1
				state_set_status(st, fmt.tprintf("recalled history #%d", idx))
				state_add_notice(st, fmt.tprintf("aether: loaded history #%d into prompt", idx))
				return true
			}
			// fall through to slash for error message
		}
		// list / filter via shared slash handler
	}

	// Capture notices via package-level sink target
	stream_bind_slash(st)
	defer stream_clear_slash()
	slash_out :: proc(msg: string) {
		stream_notice_slash(msg)
	}

	// /clear|/new replace the session — cancel mid-turn UI first so we don't
	// leave streaming=true over an empty transcript (breaks welcome + input).
	is_session_reset :=
		line == "/clear" ||
		line == "/new" ||
		strings.has_prefix(line, "/new ") ||
		line == "/home" ||
		line == "/welcome"
	if is_session_reset && st.streaming {
		tui_abort_turn_ui(st)
	}

	action := agent.run_slash(sess, line, opts, model, cwd, perm, slash_out)
	input_clear(st)
	st.history_idx = -1
	// keep header chip in sync when /auto /always-approve change perm
	delete(st.perm)
	st.perm = strings.clone(core.permission_mode_string(perm^))

	switch action {
	case .Exit:
		st.quit = true
		return false
	case .Session_Changed:
		// refresh header + blocks + history
		delete(st.model)
		st.model = strings.clone(model^)
		state_set_cwd(st, cwd^)
		state_set_session_meta(st, sess.id, sess.title)
		set_live_session(st, sess)
		// Always drop turn chrome after session replace (even if not streaming
		// when slash ran — avoids sticky spinner/live draft).
		tui_abort_turn_ui(st)
		rebuild_blocks(st, sess.msgs[:])
		seed_prompt_history(st, sess.msgs[:])
		stream_pin_bottom(st)
		clamp_selected_block(st)
		focus_prompt(st)
		// After /fork with directive, fill composer once
		if strings.has_prefix(line, "/fork") {
			if dir := agent.take_fork_pending_composer(); dir != "" {
				input_set_text(st, dir)
				delete(dir)
				focus_prompt(st)
			}
		}
		// B56: /clear, /new, /home drop ephemeral notice spam
		if is_session_reset {
			state_clear_notices(st)
		}
		state_set_status(st, "ready")
		return true
	case .Continue:
		// keep top-bar cwd in sync after /cd
		if line == "/cd" || strings.has_prefix(line, "/cd ") {
			state_set_cwd(st, cwd^)
		}
		// show last notice in status if any
		if len(st.notices) > 0 {
			state_set_status(st, st.notices[len(st.notices) - 1])
		}
		return true
	}
	return true
}
