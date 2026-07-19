#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
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
	if line == "/resume" || line == "/sessions-ui" {
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
		state_set_session_meta(st, sess.id, sess.title)
		rebuild_blocks(st, sess.msgs[:])
		seed_prompt_history(st, sess.msgs[:])
		stream_pin_bottom(st)
		// B56: /clear and /new drop ephemeral notice spam
		if line == "/clear" || line == "/new" || strings.has_prefix(line, "/new ") {
			state_clear_notices(st)
		}
		state_set_status(st, "ready")
		return true
	case .Continue:
		// show last notice in status if any
		if len(st.notices) > 0 {
			state_set_status(st, st.notices[len(st.notices) - 1])
		}
		return true
	}
	return true
}
