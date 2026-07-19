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
	emit :: proc(out: Slash_Writer, line: string) {
		if out != nil {
			out(line)
		} else {
			fmt.eprintln(line)
		}
	}

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

	switch cmd {
	case "/exit", "/quit", "/q":
		// SessionEnd hooks before dream/leave (latch; host defer is no-op after)
		maybe_stop_hooks("exit")
		// Best-effort auto-dream before leave (gates apply).
		if note := maybe_auto_dream(sess, model^); note != "" {
			nstart := 0
			for i := 0; i <= len(note); i += 1 {
				if i == len(note) || note[i] == '\n' {
					line := note[nstart:i]
					if line != "" {
						emit(out, line)
					}
					nstart = i + 1
				}
			}
		}
		return .Exit
	case "/help", "/?":
		// B65: sectioned help (+ optional filter)
		help_out := handle_help_slash(arg, context.temp_allocator)
		hstart := 0
		for i := 0; i <= len(help_out); i += 1 {
			if i == len(help_out) || help_out[i] == '\n' {
				line := help_out[hstart:i]
				if line != "" {
					emit(out, line)
				}
				hstart = i + 1
			}
		}
		return .Continue
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
			emit(out, "aether: permission mode = always-approve")
		case "off", "false", "0", "no", "disable", "ask":
			if perm != nil {
				perm^ = .Ask
				changed = true
			}
			emit(out, "aether: permission mode = ask")
		case "read-only", "readonly", "ro":
			if perm != nil {
				perm^ = .Read_Only
				changed = true
			}
			emit(out, "aether: permission mode = read-only")
		case "auto", "accept-edits", "accept_edits":
			if perm != nil {
				perm^ = .Auto
				changed = true
			}
			emit(out, "aether: permission mode = auto (accept file edits; ask for shell)")
		case "toggle":
			if perm != nil {
				if perm^ == .Always_Approve {
					perm^ = .Ask
				} else {
					perm^ = .Always_Approve
				}
				changed = true
				emit(out, fmt.tprintf("aether: permission mode = %s", core.permission_mode_string(perm^)))
			} else {
				emit(out, "aether: permission mode pointer unavailable")
			}
		case "status", "?":
			emit(out, fmt.tprintf("aether: permission mode = %s", core.permission_mode_string(cur)))
		case:
			emit(out, "aether: usage: /always-approve [on|off|auto|read-only|toggle|status]")
		}
		if changed && perm != nil {
			if pe := core.persist_permission_mode(perm^); pe != "" {
				emit(out, fmt.tprintf("aether: permission_mode persist: %s", pe))
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
					emit(out, "aether: permission mode = ask (left auto)")
				} else {
					perm^ = .Auto
					emit(out, "aether: permission mode = auto (accept file edits; ask for shell)")
				}
				changed = true
			} else {
				emit(out, "aether: permission mode pointer unavailable")
			}
		case "on", "true", "1", "yes", "enable":
			if perm != nil {
				perm^ = .Auto
				changed = true
			}
			emit(out, "aether: permission mode = auto (accept file edits; ask for shell)")
		case "off", "false", "0", "no", "disable", "ask":
			if perm != nil {
				perm^ = .Ask
				changed = true
			}
			emit(out, "aether: permission mode = ask")
		case "status", "?":
			emit(out, fmt.tprintf("aether: permission mode = %s", core.permission_mode_string(cur)))
		case:
			emit(out, "aether: usage: /auto [on|off|toggle|status]")
		}
		if changed && perm != nil {
			if pe := core.persist_permission_mode(perm^); pe != "" {
				emit(out, fmt.tprintf("aether: permission_mode persist: %s", pe))
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
			emit(out, fmt.tprintf("aether: model = %s", cur if cur != "" else "(unset)"))
			emit(out, "aether: usage: /model <id>   examples: grok-4.5, grok-build")
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
					emit(out, fmt.tprintf("aether: model set to %s (save failed: %s)", a, e))
					return .Continue
				}
			}
		}
		if pe := core.persist_default_model(a); pe != "" {
			emit(out, fmt.tprintf("aether: model set to %s (persist: %s)", a, pe))
		} else {
			emit(out, fmt.tprintf("aether: model set to %s", a))
		}
		return .Continue
	case "/effort":
		a := strings.trim_space(arg)
		if a == "" || a == "status" || a == "?" {
			cur := reasoning_effort_current()
			emit(
				out,
				fmt.tprintf(
					"aether: reasoning_effort = %s",
					cur if cur != "" else "(default/off)",
				),
			)
			emit(out, "aether: usage: /effort low|medium|high|xhigh|off")
			return .Continue
		}
		if !set_reasoning_effort(a) {
			emit(out, "aether: usage: /effort low|medium|high|xhigh|off")
			return .Continue
		}
		cur := reasoning_effort_current()
		_ = core.persist_reasoning_effort(cur if cur != "" else "off")
		emit(
			out,
			fmt.tprintf(
				"aether: reasoning_effort = %s",
				cur if cur != "" else "(default/off)",
			),
		)
		return .Continue
	case "/copy":
		// /copy [N] — Nth latest non-empty assistant message (1 = most recent)
		n := 1
		if strings.trim_space(arg) != "" {
			v, ok := parse_rewind_count(arg)
			if !ok {
				emit(out, "aether: usage: /copy [N]  (Nth latest assistant reply)")
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
			emit(out, fmt.tprintf("aether: no assistant reply #%d to copy", n))
			return .Continue
		}
		st := copy_text_to_clipboard(body)
		emit(out, fmt.tprintf("aether: %s (%d chars)", st, len(body)))
		return .Continue
	case "/history":
		// List / filter / show session user prompts (newest first)
		all := collect_user_prompts(sess.msgs[:], context.temp_allocator)
		// temp_allocator owns; no destroy needed for short-lived
		a := strings.trim_space(arg)
		if a == "" || a == "list" || a == "?" {
			filtered := filter_prompts(all, "", context.temp_allocator)
			emit(out, format_history_list(filtered, 20, 100, context.temp_allocator))
			return .Continue
		}
		if idx, ok := parse_history_index(a); ok {
			if idx > len(all) {
				emit(out, fmt.tprintf("aether: history #%d not found (%d prompts)", idx, len(all)))
				return .Continue
			}
			// full text of that prompt
			emit(out, fmt.tprintf("aether: history #%d:\n%s", idx, all[idx - 1]))
			return .Continue
		}
		// substring filter
		filtered := filter_prompts(all, a, context.temp_allocator)
		if len(filtered) == 0 {
			emit(out, fmt.tprintf("aether: no prompts matching %q", a))
			return .Continue
		}
		emit(out, format_history_list(filtered, 20, 100, context.temp_allocator))
		return .Continue
	case "/btw":
		if strings.trim_space(arg) == "" {
			emit(out, "aether: usage: /btw <note>  (local only; not sent to the model)")
			return .Continue
		}
		emit(out, fmt.tprintf("btw: %s", strings.trim_space(arg)))
		return .Continue
	case "/feedback":
		fb := handle_feedback_slash(sess, arg, context.temp_allocator)
		fstart := 0
		for i := 0; i <= len(fb); i += 1 {
			if i == len(fb) || fb[i] == '\n' {
				line := fb[fstart:i]
				if line != "" {
					emit(out, line)
				}
				fstart = i + 1
			}
		}
		return .Continue
	case "/context", "/usage", "/cost":
		// /usage and /cost alias /context (B25)
		ctx_out := handle_context_slash(sess, arg, context.temp_allocator)
		cstart := 0
		for i := 0; i <= len(ctx_out); i += 1 {
			if i == len(ctx_out) || ctx_out[i] == '\n' {
				line := ctx_out[cstart:i]
				if line != "" {
					emit(out, line)
				}
				cstart = i + 1
			}
		}
		return .Continue
	case "/diff":
		dcwd := sess.cwd if sess != nil && sess.cwd != "" else (cwd^ if cwd != nil else ".")
		diff_out := handle_diff_slash(dcwd, arg, context.temp_allocator)
		dstart := 0
		for i := 0; i <= len(diff_out); i += 1 {
			if i == len(diff_out) || diff_out[i] == '\n' {
				line := diff_out[dstart:i]
				if line != "" {
					emit(out, line)
				}
				dstart = i + 1
			}
		}
		if len(diff_out) == 0 {
			emit(out, "aether: /diff produced no output")
		}
		return .Continue
	case "/compact":
		cmp_out := handle_compact_slash(sess, model^, arg, perm_mode(perm), context.temp_allocator)
		kstart := 0
		for i := 0; i <= len(cmp_out); i += 1 {
			if i == len(cmp_out) || cmp_out[i] == '\n' {
				line := cmp_out[kstart:i]
				if line != "" {
					emit(out, line)
				}
				kstart = i + 1
			}
		}
		if len(cmp_out) == 0 {
			emit(out, "aether: compact produced no output")
		}
		// History replaced — UI should rebuild
		return .Session_Changed
	case "/flush":
		flush_out := handle_flush_slash(sess, model^, arg, context.temp_allocator)
		fstart := 0
		for i := 0; i <= len(flush_out); i += 1 {
			if i == len(flush_out) || flush_out[i] == '\n' {
				line := flush_out[fstart:i]
				if line != "" {
					emit(out, line)
				}
				fstart = i + 1
			}
		}
		if len(flush_out) == 0 {
			emit(out, "aether: flush produced no output")
		}
		return .Continue
	case "/memory":
		mem_out := handle_memory_slash(
			arg,
			sess.cwd if sess.cwd != "" else cwd^,
			context.temp_allocator,
			sess,
		)
		mstart := 0
		for i := 0; i <= len(mem_out); i += 1 {
			if i == len(mem_out) || mem_out[i] == '\n' {
				line := mem_out[mstart:i]
				if line != "" {
					emit(out, line)
				}
				mstart = i + 1
			}
		}
		return .Continue
	case "/dream":
		dream_out := handle_dream_slash(sess, model^, arg, context.temp_allocator)
		dstart := 0
		for i := 0; i <= len(dream_out); i += 1 {
			if i == len(dream_out) || dream_out[i] == '\n' {
				line := dream_out[dstart:i]
				if line != "" {
					emit(out, line)
				}
				dstart = i + 1
			}
		}
		if len(dream_out) == 0 {
			emit(out, "aether: dream produced no output")
		}
		return .Continue
	case "/remember":
		// B32: save a user note to today's memory session log
		rcwd := sess.cwd if sess.cwd != "" else cwd^
		rem_out := handle_remember_slash(rcwd, arg, context.temp_allocator)
		rstart := 0
		for i := 0; i <= len(rem_out); i += 1 {
			if i == len(rem_out) || rem_out[i] == '\n' {
				line := rem_out[rstart:i]
				if line != "" {
					emit(out, line)
				}
				rstart = i + 1
			}
		}
		return .Continue
	case "/goal":
		emit(out, handle_goal_slash(arg, context.temp_allocator))
		return .Continue
	case "/imagine":
		img_out := handle_imagine_slash(arg, context.temp_allocator)
		// emit line-by-line
		istart := 0
		for i := 0; i <= len(img_out); i += 1 {
			if i == len(img_out) || img_out[i] == '\n' {
				line := img_out[istart:i]
				if line != "" {
					emit(out, line)
				}
				istart = i + 1
			}
		}
		return .Continue
	case "/imagine-video":
		vid_out := handle_imagine_video_slash(arg, context.temp_allocator)
		vstart := 0
		for i := 0; i <= len(vid_out); i += 1 {
			if i == len(vid_out) || vid_out[i] == '\n' {
				line := vid_out[vstart:i]
				if line != "" {
					emit(out, line)
				}
				vstart = i + 1
			}
		}
		return .Continue
	case "/theme", "/t":
		// C2.1 — name stored in core; TUI re-reads each paint; B9 persists [ui] theme
		a := strings.trim_space(arg)
		al := strings.to_lower(a, context.temp_allocator)
		if a == "" {
			next := core.cycle_ui_theme_name()
			if pe := core.persist_ui_string("theme", next); pe != "" {
				emit(out, fmt.tprintf("aether: theme → %s (persist: %s)", next, pe))
			} else {
				emit(out, fmt.tprintf("aether: theme → %s", next))
			}
			return .Continue
		}
		if al == "list" || al == "ls" || al == "help" || al == "?" {
			txt := core.list_ui_theme_names(context.temp_allocator)
			// emit lines
			hstart := 0
			for i := 0; i <= len(txt); i += 1 {
				if i == len(txt) || txt[i] == '\n' {
					line := txt[hstart:i]
					if line != "" {
						emit(out, line)
					}
					hstart = i + 1
				}
			}
			return .Continue
		}
		if al == "status" || al == "show" {
			emit(out, fmt.tprintf("aether: theme = %s", core.get_ui_theme_name()))
			return .Continue
		}
		if core.set_ui_theme_name(a) {
			name := core.get_ui_theme_name()
			if pe := core.persist_ui_string("theme", name); pe != "" {
				emit(out, fmt.tprintf("aether: theme → %s (persist: %s)", name, pe))
			} else {
				emit(out, fmt.tprintf("aether: theme → %s", name))
			}
		} else {
			emit(out, fmt.tprintf("aether: unknown theme %q — try /theme list", a))
		}
		return .Continue
	case "/vim-mode", "/vim":
		// C2.2 — opt-in scrollback j/k navigation; B9 persists [ui] vim_mode
		a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
		switch a {
		case "", "toggle", "t":
			on := core.toggle_vim_mode()
			_ = core.persist_ui_bool("vim_mode", on)
			emit(out, fmt.tprintf("aether: vim-mode %s", "on" if on else "off"))
		case "on", "true", "1", "yes":
			core.set_vim_mode(true)
			_ = core.persist_ui_bool("vim_mode", true)
			emit(out, "aether: vim-mode on")
		case "off", "false", "0", "no":
			core.set_vim_mode(false)
			_ = core.persist_ui_bool("vim_mode", false)
			emit(out, "aether: vim-mode off")
		case "status", "show", "?":
			emit(
				out,
				fmt.tprintf(
					"aether: vim-mode %s (scrollback: j/k g/G H/L J/K i; Shift+←/→ user turns; config [ui] vim_mode)",
					"on" if core.vim_mode_enabled() else "off",
				),
			)
		case:
			emit(out, "aether: usage: /vim-mode [on|off|status|toggle]")
		}
		return .Continue
	case "/timestamps", "/timestamp":
		// B37 — HH:MM prefixes on TUI transcript; persists [ui] timestamps
		a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
		switch a {
		case "", "toggle", "t":
			on := core.toggle_timestamps()
			_ = core.persist_ui_bool("timestamps", on)
			emit(out, fmt.tprintf("aether: timestamps %s", "on" if on else "off"))
		case "on", "true", "1", "yes":
			core.set_timestamps(true)
			_ = core.persist_ui_bool("timestamps", true)
			emit(out, "aether: timestamps on")
		case "off", "false", "0", "no":
			core.set_timestamps(false)
			_ = core.persist_ui_bool("timestamps", false)
			emit(out, "aether: timestamps off")
		case "status", "show", "?":
			emit(
				out,
				fmt.tprintf(
					"aether: timestamps %s (HH:MM on transcript blocks; config [ui] timestamps)",
					"on" if core.timestamps_enabled() else "off",
				),
			)
		case:
			emit(out, "aether: usage: /timestamps [on|off|status|toggle]")
		}
		return .Continue
	case "/compact-mode", "/cm":
		// B8 — denser TUI chrome; B9 persists [ui] compact_mode
		a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
		switch a {
		case "", "toggle", "t":
			on := core.toggle_compact_mode()
			_ = core.persist_ui_bool("compact_mode", on)
			emit(out, fmt.tprintf("aether: compact-mode %s", "on" if on else "off"))
		case "on", "true", "1", "yes":
			core.set_compact_mode(true)
			_ = core.persist_ui_bool("compact_mode", true)
			emit(out, "aether: compact-mode on")
		case "off", "false", "0", "no":
			core.set_compact_mode(false)
			_ = core.persist_ui_bool("compact_mode", false)
			emit(out, "aether: compact-mode off")
		case "status", "show", "?":
			emit(
				out,
				fmt.tprintf(
					"aether: compact-mode %s (denser header/status/tool chrome; config [ui] compact_mode)",
					"on" if core.compact_mode_enabled() else "off",
				),
			)
		case:
			emit(out, "aether: usage: /compact-mode [on|off|status|toggle]")
		}
		return .Continue
	case "/loop":
		// Multi-line result: emit line-by-line for TUI notices
		loop_out := handle_loop_slash(arg, context.temp_allocator)
		start := 0
		for i := 0; i <= len(loop_out); i += 1 {
			if i == len(loop_out) || loop_out[i] == '\n' {
				line := loop_out[start:i]
				if line != "" {
					emit(out, line)
				}
				start = i + 1
			}
		}
		if len(loop_out) == 0 {
			emit(out, loop_usage_message())
		}
		return .Continue
	case "/todos", "/todo":
		arg_l := strings.to_lower(arg, context.temp_allocator)
		if arg_l == "clear" || arg_l == "reset" || arg_l == "empty" {
			tools.todo_clear()
			emit(out, "aether: todos cleared")
			return .Continue
		}
		if arg_l != "" && arg_l != "list" && arg_l != "show" && arg_l != "status" {
			emit(out, "aether: usage: /todos [clear]")
			return .Continue
		}
		sum := tools.summarize_todo_state(context.temp_allocator)
		// Emit one line at a time for TUI notice sink
		if sum == "" || !strings.contains(sum, "\n") {
			emit(out, sum if sum != "" else "No tasks currently tracked.")
			return .Continue
		}
		// split on newlines; skip trailing empty
		start := 0
		for i := 0; i <= len(sum); i += 1 {
			if i == len(sum) || sum[i] == '\n' {
				line := sum[start:i]
				if line != "" {
					emit(out, line)
				}
				start = i + 1
			}
		}
		return .Continue
	case "/find":
		// TUI handles /find; REPL documents it
		emit(out, "aether: /find is TUI-only (Ctrl+F in aether tui)")
		return .Continue
	case "/plan":
		arg_l := strings.to_lower(arg, context.temp_allocator)
		if arg_l == "off" || arg_l == "exit" || arg_l == "leave" || arg_l == "end" {
			emit(out, user_exit_plan_mode(sess.cwd, false, context.temp_allocator))
			sess.plan_mode =
				plan_mode_is_active() || plan_mode_is_pending() || plan_mode_is_exit_pending()
			return .Continue
		}
		if arg_l == "status" || arg_l == "?" {
			st := plan_mode_state()
			path := plan_file_path_for_cwd(sess.cwd, context.temp_allocator)
			switch st {
			case .Active:
				emit(out, fmt.tprintf("plan mode: ACTIVE — %s", path))
			case .Pending:
				emit(out, fmt.tprintf("plan mode: PENDING (activates next turn) — %s", path))
			case .Exit_Pending:
				emit(out, fmt.tprintf("plan mode: EXIT PENDING — %s", path))
			case .Inactive:
				emit(out, "plan mode: OFF")
			}
			return .Continue
		}
		if arg_l == "view" || arg_l == "show" || arg_l == "cat" {
			// /plan view → same as /view-plan
			pcwd := sess.cwd if sess.cwd != "" else cwd^
			vp := handle_view_plan_slash(pcwd, context.temp_allocator)
			vstart := 0
			for i := 0; i <= len(vp); i += 1 {
				if i == len(vp) || vp[i] == '\n' {
					line := vp[vstart:i]
					if line != "" {
						emit(out, line)
					}
					vstart = i + 1
				}
			}
			return .Continue
		}
		// bare /plan, /plan on, or /plan <description>
		desc := arg
		if arg_l == "on" {
			desc = ""
		}
		emit(out, user_enter_plan_mode(sess.cwd, desc, context.temp_allocator))
		sess.plan_mode =
			plan_mode_is_active() || plan_mode_is_pending() || plan_mode_is_exit_pending()
		return .Continue
	case "/view-plan", "/show-plan", "/plan-view":
		// B32: dump .grok/plan.md
		pcwd := sess.cwd if sess.cwd != "" else cwd^
		vp := handle_view_plan_slash(pcwd, context.temp_allocator)
		vstart := 0
		for i := 0; i <= len(vp); i += 1 {
			if i == len(vp) || vp[i] == '\n' {
				line := vp[vstart:i]
				if line != "" {
					emit(out, line)
				}
				vstart = i + 1
			}
		}
		return .Continue
	case "/multiline", "/ml":
		// TUI handles mode toggle; REPL just documents it (B36: /ml alias)
		emit(out, "use Ctrl+M in the TUI to toggle multiline (or /multiline|/ml there)")
		return .Continue
	case "/whoami":
		// whoami prints its own stderr path; also summarize for sink
		code := run_whoami(opts.verbose)
		if code != 0 {
			emit(out, "whoami failed (not signed in?)")
		} else if out != nil {
			emit(out, "whoami: see identity above / auth ok")
		}
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
			emit(out, fmt.tprintf("login failed (exit %d) — see stderr; or set XAI_API_KEY", code))
		} else {
			emit(out, "login ok — try /whoami")
		}
		return .Continue
	case "/mcp":
		mcp_out := handle_mcp_slash(arg, opts.no_mcp, opts.quiet, context.temp_allocator)
		mstart := 0
		for i := 0; i <= len(mcp_out); i += 1 {
			if i == len(mcp_out) || mcp_out[i] == '\n' {
				line := mcp_out[mstart:i]
				if line != "" {
					emit(out, line)
				}
				mstart = i + 1
			}
		}
		return .Continue
	case "/hooks":
		hcwd := sess.cwd if sess.cwd != "" else (cwd^ if cwd != nil else ".")
		hooks_out := handle_hooks_slash(arg, hcwd, context.temp_allocator)
		hstart := 0
		for i := 0; i <= len(hooks_out); i += 1 {
			if i == len(hooks_out) || hooks_out[i] == '\n' {
				line := hooks_out[hstart:i]
				if line != "" {
					emit(out, line)
				}
				hstart = i + 1
			}
		}
		return .Continue
	case "/skills":
		arg_l := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
		if arg_l == "reload" || arg_l == "refresh" {
			ws := cwd^ if cwd != nil else (sess.cwd if sess != nil else ".")
			msg := reload_skills_for_cwd(ws, true)
			// emit line-by-line
			hstart := 0
			for i := 0; i <= len(msg); i += 1 {
				if i == len(msg) || msg[i] == '\n' {
					line := msg[hstart:i]
					if line != "" {
						emit(out, line)
					}
					hstart = i + 1
				}
			}
			delete(msg)
			return .Continue
		}
		if arg != "" {
			// /skills <name> same as /skill
			body := skills_invoke_text(arg, "", context.temp_allocator)
			// show first lines only for slash output
			if len(body) > 2000 {
				emit(out, body[:2000])
				emit(out, "…[truncated; full body available via skill tool]")
			} else {
				emit(out, body)
			}
			return .Continue
		}
		emit(out, skills_list_text(context.temp_allocator))
		return .Continue
	case "/skill":
		if arg == "" {
			emit(out, "aether: usage: /skill <name> [args]")
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
			emit(out, body[:2000])
			emit(out, "…[truncated; model can use skill tool for full text]")
		} else {
			emit(out, body)
		}
		return .Continue
	case "/version":
		ver := handle_version_slash(context.temp_allocator)
		vstart := 0
		for i := 0; i <= len(ver); i += 1 {
			if i == len(ver) || ver[i] == '\n' {
				line := ver[vstart:i]
				if line != "" {
					emit(out, line)
				}
				vstart = i + 1
			}
		}
		return .Continue
	case "/about":
		// B50: product blurb
		ab_out := handle_about_slash(context.temp_allocator)
		astart := 0
		for i := 0; i <= len(ab_out); i += 1 {
			if i == len(ab_out) || ab_out[i] == '\n' {
				line := ab_out[astart:i]
				if line != "" {
					emit(out, line)
				}
				astart = i + 1
			}
		}
		return .Continue
	case "/aliases", "/alias":
		// B53: slash alias table
		al_out := handle_aliases_slash(arg, context.temp_allocator)
		lstart := 0
		for i := 0; i <= len(al_out); i += 1 {
			if i == len(al_out) || al_out[i] == '\n' {
				line := al_out[lstart:i]
				if line != "" {
					emit(out, line)
				}
				lstart = i + 1
			}
		}
		return .Continue
	case "/keys", "/bindings", "/shortcuts":
		// B41: keyboard cheat sheet
		keys_out := handle_keys_slash(context.temp_allocator)
		kstart := 0
		for i := 0; i <= len(keys_out); i += 1 {
			if i == len(keys_out) || keys_out[i] == '\n' {
				line := keys_out[kstart:i]
				if line != "" {
					emit(out, line)
				}
				kstart = i + 1
			}
		}
		return .Continue
	case "/tools", "/tool":
		// B45: model tool catalog
		tools_out := handle_tools_slash(arg, context.temp_allocator)
		tstart := 0
		for i := 0; i <= len(tools_out); i += 1 {
			if i == len(tools_out) || tools_out[i] == '\n' {
				line := tools_out[tstart:i]
				if line != "" {
					emit(out, line)
				}
				tstart = i + 1
			}
		}
		return .Continue
	case "/soft-bash", "/bash-soft", "/softbash":
		// B47: soft bash safety status
		sb_out := handle_soft_bash_slash(arg, context.temp_allocator)
		sstart := 0
		for i := 0; i <= len(sb_out); i += 1 {
			if i == len(sb_out) || sb_out[i] == '\n' {
				line := sb_out[sstart:i]
				if line != "" {
					emit(out, line)
				}
				sstart = i + 1
			}
		}
		return .Continue
	case "/permissions", "/permission", "/perm", "/perms":
		// B61: permission mode dashboard
		pm_out := handle_permissions_slash(arg, perm_mode(perm), context.temp_allocator)
		pstart := 0
		for i := 0; i <= len(pm_out); i += 1 {
			if i == len(pm_out) || pm_out[i] == '\n' {
				line := pm_out[pstart:i]
				if line != "" {
					emit(out, line)
				}
				pstart = i + 1
			}
		}
		return .Continue
	case "/env", "/environ", "/environment":
		// B62: product env catalog
		env_out := handle_env_slash(arg, context.temp_allocator)
		estart := 0
		for i := 0; i <= len(env_out); i += 1 {
			if i == len(env_out) || env_out[i] == '\n' {
				line := env_out[estart:i]
				if line != "" {
					emit(out, line)
				}
				estart = i + 1
			}
		}
		return .Continue
	case "/paths", "/path", "/where":
		// B63: product filesystem paths
		paths_out := handle_paths_slash(arg, sess, context.temp_allocator)
		pstart2 := 0
		for i := 0; i <= len(paths_out); i += 1 {
			if i == len(paths_out) || paths_out[i] == '\n' {
				line := paths_out[pstart2:i]
				if line != "" {
					emit(out, line)
				}
				pstart2 = i + 1
			}
		}
		return .Continue
	case "/features", "/feature", "/flags":
		// B68: process feature flags
		feat_out := handle_features_slash(arg, context.temp_allocator)
		fstart := 0
		for i := 0; i <= len(feat_out); i += 1 {
			if i == len(feat_out) || feat_out[i] == '\n' {
				line := feat_out[fstart:i]
				if line != "" {
					emit(out, line)
				}
				fstart = i + 1
			}
		}
		return .Continue
	case "/status":
		m := model^ if model != nil else ""
		st_out := handle_status_slash(sess, m, perm_mode(perm), context.temp_allocator)
		sstart := 0
		for i := 0; i <= len(st_out); i += 1 {
			if i == len(st_out) || st_out[i] == '\n' {
				line := st_out[sstart:i]
				if line != "" {
					emit(out, line)
				}
				sstart = i + 1
			}
		}
		return .Continue
	case "/config", "/settings", "/preferences", "/prefs":
		// B34: effective product settings (no modal; no secrets)
		m := model^ if model != nil else ""
		cfg_out := handle_config_slash(sess, m, perm_mode(perm), context.temp_allocator)
		cstart := 0
		for i := 0; i <= len(cfg_out); i += 1 {
			if i == len(cfg_out) || cfg_out[i] == '\n' {
				line := cfg_out[cstart:i]
				if line != "" {
					emit(out, line)
				}
				cstart = i + 1
			}
		}
		return .Continue
	case "/doctor":
		dcwd := sess.cwd if sess != nil && sess.cwd != "" else (cwd^ if cwd != nil else ".")
		doc_out := handle_doctor_slash(sess, dcwd, context.temp_allocator)
		dstart := 0
		for i := 0; i <= len(doc_out); i += 1 {
			if i == len(doc_out) || doc_out[i] == '\n' {
				line := doc_out[dstart:i]
				if line != "" {
					emit(out, line)
				}
				dstart = i + 1
			}
		}
		return .Continue
	case "/session", "/session-info":
		emit(out, fmt.tprintf("id:        %s", sess.id))
		emit(out, fmt.tprintf("title:     %s", sess.title if sess.title != "" else "(none)"))
		emit(out, fmt.tprintf("path:      %s", sess.path))
		emit(out, fmt.tprintf("model:     %s", sess.model))
		emit(out, fmt.tprintf("cwd:       %s", sess.cwd))
		emit(out, fmt.tprintf("messages:  %d", len(sess.msgs)))
		emit(out, fmt.tprintf("autosave:  %v", sess.auto_save))
		if cmd == "/session-info" {
			chars := estimate_message_chars(sess.msgs[:])
			toks := estimate_tokens(chars)
			window := default_context_window()
			pct := context_usage_pct(toks, window)
			emit(
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
			emit(out, fmt.tprintf("permission: %s", core.permission_mode_string(perm_mode(perm))))
		}
		return .Continue
	case "/sessions", "/resume":
		// /sessions delete|rm|search|N
		arg_trim := strings.trim_space(arg)
		arg_l := strings.to_lower(arg_trim, context.temp_allocator)
		if strings.has_prefix(arg_l, "delete ") || strings.has_prefix(arg_l, "rm ") {
			sp := strings.index_byte(arg_trim, ' ')
			ref := strings.trim_space(arg_trim[sp + 1:]) if sp >= 0 else ""
			if ref == "" {
				emit(out, "aether: usage: /sessions delete <id|title|path>")
				return .Continue
			}
			if derr := session_delete_by_ref(ref, sess.sessions_dir, sess.path); derr != "" {
				emit(out, fmt.tprintf("aether: %s", derr))
			} else {
				emit(out, fmt.tprintf("aether: deleted session %s", ref))
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
			emit(out, fmt.tprintf("aether: %s", err))
			return .Continue
		}
		if len(entries) == 0 {
			emit(out, "(no saved sessions)")
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
			emit(out, fmt.tprintf("aether: no sessions matching %q", filter))
			return .Continue
		}
		emit(out, "aether: sessions (newest first; * = current; /load <id|title>)")
		emit(out, " #  id                      when         msg  model             title")
		n := min(limit, len(show))
		for i in 0 ..< n {
			e := show[i]
			cur := e.path == sess.path || e.id == sess.id
			line := format_session_list_line(e, cur, i + 1, context.temp_allocator)
			emit(out, line)
		}
		if len(show) > n {
			emit(out, fmt.tprintf("… %d more (raise limit: /sessions %d)", len(show) - n, len(show)))
		}
		return .Continue
	case "/rename", "/title":
		if strings.trim_space(arg) == "" {
			emit(out, "aether: usage: /rename <title>")
			return .Continue
		}
		if e := session_set_title(sess, arg); e != "" {
			emit(out, fmt.tprintf("aether: rename failed: %s", e))
		} else {
			emit(out, fmt.tprintf("aether: title set to %q", sess.title))
		}
		return .Continue
	case "/fork":
		// Save current first if autosave so parent is durable
		if sess.auto_save {
			if e := session_save(sess); e != "" {
				emit(out, fmt.tprintf("aether: autosave before fork failed: %s", e))
			}
		}
		forked, ferr := session_fork(sess^, strings.trim_space(arg), context.allocator)
		if ferr != "" {
			emit(out, fmt.tprintf("aether: fork failed: %s", ferr))
			return .Continue
		}
		// Switch to fork
		old_auto := sess.auto_save
		destroy_session(sess)
		sess^ = forked
		sess.auto_save = old_auto
		if sess.model != "" {
			model^ = sess.model
		}
		if sess.cwd != "" {
			cwd^ = sess.cwd
		}
		emit(
			out,
			fmt.tprintf(
				"aether: forked → session %s %q (%d messages)",
				sess.id,
				sess.title,
				len(sess.msgs),
			),
		)
		return .Session_Changed
	case "/export":
		a := strings.trim_space(arg)
		if a == "help" || a == "?" {
			emit(out, "aether: usage: /export [json|md] [path]")
			emit(out, "  default     markdown → <sessions>/<id>-export.md")
			emit(out, "  json [path] full session JSON dump")
			emit(out, "  path.json   infers JSON from extension")
			return .Continue
		}
		path, eerr := session_export(sess^, a, context.allocator)
		if eerr != "" {
			emit(out, fmt.tprintf("aether: export failed: %s", eerr))
		} else {
			kind := "transcript"
			pl := strings.to_lower(path, context.temp_allocator)
			if strings.has_suffix(pl, ".json") || strings.has_suffix(pl, ".jsonl") {
				kind = "JSON session"
			}
			emit(out, fmt.tprintf("aether: exported %s → %s", kind, path))
			delete(path)
		}
		return .Continue
	case "/import":
		a := strings.trim_space(arg)
		if a == "" || a == "help" || a == "?" {
			emit(out, "aether: usage: /import <path.json>")
			emit(out, "  Load a session or /export json dump as a **new** session (new id).")
			return .Continue
		}
		if sess.auto_save {
			if e := session_save(sess); e != "" {
				emit(out, fmt.tprintf("aether: autosave failed before import: %s", e))
			}
		}
		dir := sess.sessions_dir
		if dir == "" {
			dir = core.aether_sessions_dir("", context.temp_allocator)
		}
		loaded, lerr := session_import_file(a, dir, sess.auto_save)
		if lerr != "" {
			emit(out, fmt.tprintf("aether: import failed: %s", lerr))
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
		emit(
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
			emit(out, tools.file_rewind_status(context.temp_allocator))
		case "clear", "reset":
			tools.file_rewind_clear()
			emit(out, "aether: file rewind stack cleared")
		case "", "once", "1", "undo":
			emit(out, tools.file_rewind_undo(context.temp_allocator))
		case:
			emit(out, "aether: usage: /undo-file [status|clear]  (undo last write/edit/delete)")
		}
		return .Continue
	case "/rewind":
		// Grok-shaped conversation rewind: drop last N user turns
		a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
		switch a {
		case "status", "show", "?", "list":
			emit(out, format_conversation_rewind_status(sess, context.temp_allocator))
			emit(out, tools.file_rewind_status(context.temp_allocator))
		case "file", "files":
			// convenience → file stack undo once
			emit(out, tools.file_rewind_undo(context.temp_allocator))
		case:
			n, ok := parse_rewind_count(arg)
			if !ok {
				emit(out, "aether: usage: /rewind [N|status]  (conversation turns; file undo: /undo-file)")
				return .Continue
			}
			before := len(sess.msgs)
			removed, rerr := conversation_rewind_turns(sess, n)
			if rerr != "" {
				emit(out, fmt.tprintf("aether: %s", rerr))
				return .Continue
			}
			if sess.auto_save {
				if e := session_save(sess); e != "" {
					emit(
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
			emit(
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
			emit(out, fmt.tprintf("aether: save failed: %s", e))
		} else {
			emit(out, fmt.tprintf("aether: saved %s", sess.path))
		}
		return .Continue
	case "/load":
		if arg == "" {
			emit(out, "aether: usage: /load <id|title|path>")
			return .Continue
		}
		if sess.auto_save {
			if e := session_save(sess); e != "" {
				emit(out, fmt.tprintf("aether: autosave failed before load: %s", e))
			}
		}
		path, rerr := resolve_session_ref(arg, sess.sessions_dir, context.temp_allocator)
		if rerr != "" {
			emit(out, fmt.tprintf("aether: %s", rerr))
			return .Continue
		}
		loaded, lerr := session_load_file(path, sess.auto_save)
		if lerr != "" {
			emit(out, fmt.tprintf("aether: load failed: %s", lerr))
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
		emit(
			out,
			fmt.tprintf(
				"aether: loaded session %s%s (%d messages)",
				sess.id,
				title_note,
				len(sess.msgs),
			),
		)
		return .Session_Changed
	case "/new":
		if sess.auto_save {
			if e := session_save(sess); e != "" {
				emit(out, fmt.tprintf("aether: autosave failed before new: %s", e))
			}
		}
		// Auto-dream previous session before destroy (gates apply).
		if note := maybe_auto_dream(sess, model^); note != "" {
			nstart := 0
			for i := 0; i <= len(note); i += 1 {
				if i == len(note) || note[i] == '\n' {
					line := note[nstart:i]
					if line != "" {
						emit(out, line)
					}
					nstart = i + 1
				}
			}
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
		emit(out, fmt.tprintf("aether: new session %s", sess.id))
		return .Session_Changed
	case "/clear":
		for len(sess.msgs) > 1 {
			last, _ := pop_safe(&sess.msgs)
			destroy_message(&last)
		}
		emit(out, "aether: history cleared (same session id)")
		if sess.auto_save {
			if e := session_save(sess); e != "" {
				emit(out, fmt.tprintf("aether: autosave failed: %s", e))
			}
		}
		return .Session_Changed
	case:
		// /skillname as bare skill invoke when not a builtin
		if strings.has_prefix(cmd, "/") && len(cmd) > 1 {
			sname := cmd[1:]
			if skills_is_named(sname) {
				body := skills_invoke_text(sname, arg, context.temp_allocator)
				if len(body) > 2000 {
					emit(out, body[:2000])
					emit(out, "…[truncated; model can use skill tool for full text]")
				} else {
					emit(out, body)
				}
				return .Continue
			}
		}
		emit(out, fmt.tprintf("aether: unknown command %s (try /help)", cmd))
		return .Continue
	}
}


