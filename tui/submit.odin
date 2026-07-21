// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:strings"
import "aether:agent"
import "aether:core"

// Auto-wake + handle_submit agent turns.

tui_can_auto_wake :: proc(st: ^App_State) -> bool {
	if st.streaming || st.ask_active {
		return false
	}
	if overlay_is_open(st) {
		return false
	}
	if len(st.input) > 0 {
		return false
	}
	if prompt_queue_len(st) > 0 {
		return false // drain user queue first
	}
	return true
}

// tui_run_auto_wake runs a synthetic parent turn for undelivered bg completions.
tui_run_auto_wake :: proc(
	st: ^App_State,
	sess: ^agent.Session,
	term: ^Term_State,
	cfg: ^core.Runtime_Config,
	creds: ^agent.Credentials,
	model: ^string,
	cwd: ^string,
	perm: ^core.Permission_Mode,
	perm_before: ^core.Permission_Mode,
	opts: agent.Headless_Options,
) -> bool {
	state_set_status(st, "auto-wake…")
	state_add_notice(st, "background task completed — waking agent")
	strings.builder_reset(&st.live_assist)
	st.streaming = true
	stream_pin_bottom(st)
	ask_turn_allow := false
	stream_bind(st, term, sess, perm, perm_before)
	defer stream_clear()
	render(term, st)

	agent.set_content_delta_handler(stream_delta)
	turn := agent.Turn_Options {
		workspace         = cwd^,
		max_turns         = cfg.max_turns,
		quiet             = true,
		verbose           = opts.verbose,
		permission_mode   = perm^,
		permission_live   = perm,
		permission_allow  = cfg.permission_allow[:],
		permission_deny   = cfg.permission_deny[:],
		ask_turn_allow    = &ask_turn_allow,
		on_status         = stream_status_cb,
		on_history        = stream_tool_done_cb,
		on_ask            = tui_ask_tool,
		on_ask_user       = tui_ask_user_question,
		on_plan_enter     = tui_plan_enter_ask,
		on_plan_exit      = tui_plan_exit_ask,
		cancel            = stream_cancel_ptr(),
		on_poll           = peek_turn_keys,
		mcp_enabled       = agent.mcp_enabled_for_turn(),
		skills_enabled    = agent.skills_enabled_for_turn(),
		subagents_enabled = agent.subagents_enabled(),
	}
	ran, code := agent.try_idle_auto_wake(creds^, model^, &sess.msgs, turn)
	_ = code

	agent.set_content_delta_handler(nil)

	st.streaming = false
	strings.builder_reset(&st.live_assist)
	if sess.auto_save {
		if e := agent.session_save(sess); e != "" {
			state_add_notice(st, fmt.tprintf("autosave failed: %s", e))
		}
	}
	state_set_session_meta(st, sess.id, sess.title)
	rebuild_blocks(st, sess.msgs[:])
	stream_pin_bottom(st)
	clamp_selected_block(st)
	if ran {
		state_set_status(st, "ready")
	}
	return ran
}

// handle_submit: slash or agent turn. model/cwd may change via /load /new.
// While streaming, non-slash text is enqueued (mid-turn path also uses peek_apply_stream_compose).
handle_submit :: proc(
	st: ^App_State,
	sess: ^agent.Session,
	term: ^Term_State,
	cfg: ^core.Runtime_Config,
	creds: ^agent.Credentials,
	model: ^string,
	cwd: ^string,
	perm: ^core.Permission_Mode,
	perm_before: ^core.Permission_Mode,
	opts: agent.Headless_Options,
) -> bool {
	line := strings.trim_space(input_text(st))
	if line == "" {
		// Empty Enter mid-turn force-send is handled in peek; idle empty is no-op
		return false
	}

	if strings.has_prefix(line, "/") {
		return handle_slash(st, sess, term, line, model, cwd, perm, perm_before, opts)
	}

	// Mid-turn: queue instead of nested agent turn
	if st.streaming {
		if prompt_queue_push(st, line) {
			input_clear(st)
			state_set_status(st, fmt.tprintf("queued (%d)", prompt_queue_len(st)))
			state_add_notice(st, fmt.tprintf("aether: queued follow-up (%d in queue)", prompt_queue_len(st)))
		} else {
			state_set_status(st, "queue full")
		}
		return true
	}

	return run_user_prompt_turn(st, sess, term, cfg, creds, model, cwd, perm, perm_before, opts, line, true)
}

// run_user_prompt_turn: shared agent turn for typed prompt or drained queue item.
// line is not owned (cloned inside). drain_queue: if true, after turn run at most one queued follow-up.
run_user_prompt_turn :: proc(
	st: ^App_State,
	sess: ^agent.Session,
	term: ^Term_State,
	cfg: ^core.Runtime_Config,
	creds: ^agent.Credentials,
	model: ^string,
	cwd: ^string,
	perm: ^core.Permission_Mode,
	perm_before: ^core.Permission_Mode,
	opts: agent.Headless_Options,
	line: string,
	drain_queue := true,
) -> bool {
	prompt := strings.clone(line)
	// UserPromptSubmit may block the turn
	if ok, why := agent.allow_user_prompt_notice(cwd^, prompt); !ok {
		delete(prompt)
		input_clear(st)
		state_add_notice(st, fmt.tprintf("prompt blocked by hook: %s", why if why != "" else "UserPromptSubmit"))
		state_set_status(st, "ready")
		return true
	}
	history_push(st, prompt)
	state_add_block(st, .User, prompt)
	append(
		&sess.msgs,
		agent.Chat_Message {
			role    = .User,
			content = prompt,
		},
	)
	input_clear(st)
	st.history_idx = -1
	st.esc_first_ns = 0
	st.quit_first_ns = 0
	state_set_status(st, "sampling…")
	strings.builder_reset(&st.live_assist)
	st.streaming = true
	stream_pin_bottom(st)
	ask_turn_allow := false
	stream_bind(st, term, sess, perm, perm_before)
	defer stream_clear()
	render(term, st)

	agent.set_content_delta_handler(stream_delta)
	turn := agent.Turn_Options {
		workspace         = cwd^,
		max_turns         = cfg.max_turns,
		quiet             = true,
		verbose           = opts.verbose,
		permission_mode   = perm^,
		permission_live   = perm,
		permission_allow  = cfg.permission_allow[:],
		permission_deny   = cfg.permission_deny[:],
		ask_turn_allow    = &ask_turn_allow,
		on_status         = stream_status_cb,
		on_history        = stream_tool_done_cb,
		on_ask            = tui_ask_tool,
		on_ask_user       = tui_ask_user_question,
		on_plan_enter     = tui_plan_enter_ask,
		on_plan_exit      = tui_plan_exit_ask,
		cancel            = stream_cancel_ptr(),
		on_poll           = peek_turn_keys,
		mcp_enabled       = agent.mcp_enabled_for_turn(),
		skills_enabled    = agent.skills_enabled_for_turn(),
		subagents_enabled = agent.subagents_enabled(),
		memory_injected   = &sess.memory_injected,
		session           = sess,
	}
	final_text, code := agent.run_agent_turn(creds^, model^, &sess.msgs, turn)

	agent.set_content_delta_handler(nil)

	st.streaming = false
	if len(strings.to_string(st.live_assist)) > 0 {
		render(term, st)
	}
	strings.builder_reset(&st.live_assist)

	// B19: turn-complete desktop notify (hooks always; desktop gated)
	agent.maybe_notify_agent_turn(code, sess.title, final_text, cwd^)

	// Autosave after any agent turn (user msg already appended) — success, max-turns, cancel, error.
	// session_save also auto-titles from first user prompt when title empty.
	save_err := ""
	if sess.auto_save {
		save_err = agent.session_save(sess)
	}
	state_set_session_meta(st, sess.id, sess.title)

	// Preserve last status if it already carries error detail
	last := st.status
	if code == 0 {
		delete(final_text)
		if save_err != "" {
			state_set_status(st, fmt.tprintf("autosave failed: %s", save_err))
			state_add_notice(st, st.status)
		} else {
			state_set_status(st, "ready")
		}
	} else if code == 2 {
		if !strings.has_prefix(last, "max turns") {
			state_set_status(st, "max turns — history kept")
		}
		state_add_notice(st, st.status)
		if save_err != "" {
			state_add_notice(st, fmt.tprintf("autosave failed: %s", save_err))
		}
	} else if code == 4 {
		if last != "cancelled" {
			state_set_status(st, "cancelled")
		}
		state_add_notice(st, "turn cancelled — history kept")
		if save_err != "" {
			state_add_notice(st, fmt.tprintf("autosave failed: %s", save_err))
		}
	} else {
		// code 3: prefer on_status "error: …" already set
		if !strings.has_prefix(last, "error") {
			state_set_status(st, "error")
		}
		state_add_notice(st, st.status)
		if save_err != "" {
			state_add_notice(st, fmt.tprintf("autosave failed: %s", save_err))
		}
	}
	rebuild_blocks(st, sess.msgs[:])
	stream_pin_bottom(st)
	clamp_selected_block(st)

	// After turn: auto-drain at most ONE queued follow-up (prevent multi-turn freeze chains).
	st.queue_force_send = false
	if drain_queue && prompt_queue_len(st) > 0 {
		next, ok := prompt_queue_pop_front(st)
		if ok {
			left := prompt_queue_len(st)
			if strings.has_prefix(strings.trim_space(next), "/") {
				_ = handle_slash(st, sess, term, strings.trim_space(next), model, cwd, perm, perm_before, opts)
				delete(next)
			} else {
				// Nested turn does not auto-drain further
				_ = run_user_prompt_turn(
					st,
					sess,
					term,
					cfg,
					creds,
					model,
					cwd,
					perm,
					perm_before,
					opts,
					next,
					false,
				)
				delete(next)
			}
			if left > 0 {
				state_add_notice(
					st,
					fmt.tprintf("queue: %d left — send a message or /queue", left),
				)
				state_set_status(st, fmt.tprintf("queue %d left", left))
			}
		}
	}
	return true
}
