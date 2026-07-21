// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"
import "aether:agent"
import "aether:core"

// tui_modal_yn shows ask modal with name/summary; returns true on y/Enter.
// (Still used by plan-exit and callers that only need binary choice.)
tui_modal_yn :: proc(title, name, summary: string) -> bool {
	dec := tui_modal_ask(title, name, summary, allow_always = false)
	return dec == .Once || dec == .Always
}

// tui_modal_ask: Deny / Once / Always / Never session. Keys a/d when grants enabled.
tui_modal_ask :: proc(
	title, name, summary: string,
	allow_always := true,
) -> core.Ask_Decision {
	st := stream_st()
	term := stream_term()
	if st == nil || term == nil {
		return .Deny
	}
	delete(st.ask_name)
	delete(st.ask_summary)
	st.ask_name = strings.clone(name)
	st.ask_summary = strings.clone(summary)
	st.ask_active = true
	state_set_status(st, title)
	render(term, st)

	dec: core.Ask_Decision = .Deny
	grants := allow_always && core.session_allow_enabled()
	for {
		key := read_key()
		#partial switch key.kind {
		case .Char:
			if key.ch == 'y' || key.ch == 'Y' {
				dec = .Once
				break
			}
			if key.ch == 'n' || key.ch == 'N' {
				dec = .Deny
				break
			}
			if grants && (key.ch == 'a' || key.ch == 'A') {
				dec = .Always
				break
			}
			if grants && (key.ch == 'd' || key.ch == 'D') {
				dec = .Never
				break
			}
			continue
		case .Enter:
			dec = .Once
			break
		case .Esc, .Ctrl_C:
			dec = .Deny
			break
		case:
			continue
		}
		break
	}

	st.ask_active = false
	delete(st.ask_name)
	delete(st.ask_summary)
	st.ask_name = ""
	st.ask_summary = ""
	return dec
}

// tui_ask_user_clear_modal tears down the mid-turn ask overlay.
tui_ask_user_clear_modal :: proc(st: ^App_State) {
	st.ask_active = false
	delete(st.ask_name)
	delete(st.ask_summary)
	st.ask_name = ""
	st.ask_summary = ""
}

// tui_ask_user_set_choice_summary paints option list for digit selection.
// Shows description and optional preview (Grok option.preview).
tui_ask_user_set_choice_summary :: proc(st: ^App_State, q: agent.Ask_Question) {
	b := strings.builder_make(context.temp_allocator)
	for o, i in q.options {
		fmt.sbprintf(&b, "%d) %s\n", i + 1, o.label)
		if o.description != "" {
			fmt.sbprintf(&b, "   %s\n", o.description)
		}
		if o.preview != "" {
			// indent multi-line previews
			prev := o.preview
			for len(prev) > 0 {
				nl := strings.index_byte(prev, '\n')
				line: string
				if nl >= 0 {
					line = prev[:nl]
					prev = prev[nl + 1:]
				} else {
					line = prev
					prev = ""
				}
				if line != "" {
					fmt.sbprintf(&b, "   │ %s\n", line)
				}
			}
		}
	}
	strings.write_string(&b, "1-9 select · Esc cancel")
	delete(st.ask_summary)
	st.ask_summary = strings.clone(strings.to_string(b))
}

// tui_ask_user_set_multi_summary paints multi-select with [x]/[ ] markers.
tui_ask_user_set_multi_summary :: proc(st: ^App_State, q: agent.Ask_Question, selected: []bool) {
	b := strings.builder_make(context.temp_allocator)
	for o, i in q.options {
		mark := "[ ]"
		if i < len(selected) && selected[i] {
			mark = "[x]"
		}
		fmt.sbprintf(&b, "%s %d) %s\n", mark, i + 1, o.label)
		if o.description != "" {
			fmt.sbprintf(&b, "   %s\n", o.description)
		}
		if o.preview != "" {
			prev := o.preview
			for len(prev) > 0 {
				nl := strings.index_byte(prev, '\n')
				line: string
				if nl >= 0 {
					line = prev[:nl]
					prev = prev[nl + 1:]
				} else {
					line = prev
					prev = ""
				}
				if line != "" {
					fmt.sbprintf(&b, "   │ %s\n", line)
				}
			}
		}
	}
	strings.write_string(&b, "digit toggle · Enter submit · Esc cancel")
	delete(st.ask_summary)
	st.ask_summary = strings.clone(strings.to_string(b))
}

// tui_ask_user_set_freeform_summary paints live Other freeform draft.
tui_ask_user_set_freeform_summary :: proc(st: ^App_State, draft: string) {
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&b, "Other> %s_\n", draft)
	strings.write_string(&b, "Enter submit · Esc = Other · Ctrl+C cancel")
	delete(st.ask_summary)
	st.ask_summary = strings.clone(strings.to_string(b))
}

// tui_ask_user_freeform: after Other pick — type free text (Grok Path A).
// Returns (answer, cancelled). Esc/empty → "Other"; Ctrl+C → cancel all.
tui_ask_user_freeform :: proc(st: ^App_State, term: ^Term_State) -> (answer: string, cancelled: bool) {
	draft := make([dynamic]u8, 0, 64, context.temp_allocator)
	tui_ask_user_set_freeform_summary(st, "")
	state_set_status(st, "type freeform · Enter submit · Esc = Other")
	render(term, st)
	for {
		key := read_key()
		#partial switch key.kind {
		case .Enter:
			return agent.other_answer_from_draft(string(draft[:])), false
		case .Esc:
			return "Other", false
		case .Ctrl_C:
			return "", true
		case .Backspace:
			if len(draft) > 0 {
				_, size := utf8.decode_last_rune(draft[:])
				if size <= 0 {
					size = 1
				}
				resize(&draft, len(draft) - size)
			}
		case .Char:
			if key.ch >= 32 {
				buf, n := utf8.encode_rune(key.ch)
				for i in 0 ..< n {
					append(&draft, buf[i])
				}
			}
		case:
			continue
		}
		tui_ask_user_set_freeform_summary(st, string(draft[:]))
		state_set_status(st, "type freeform · Enter submit · Esc = Other")
		render(term, st)
	}
}

// tui_ask_user_multi: multi_select loop — digit toggles, Enter submits.
// Returns (answer, cancelled). Empty selection + Enter → cancel.
tui_ask_user_multi :: proc(
	st: ^App_State,
	term: ^Term_State,
	q: agent.Ask_Question,
) -> (
	answer: string,
	cancelled: bool,
) {
	selected := make([]bool, len(q.options), context.temp_allocator)
	tui_ask_user_set_multi_summary(st, q, selected)
	state_set_status(st, "multi-select · digit toggle · Enter submit")
	render(term, st)
	for {
		key := read_key()
		#partial switch key.kind {
		case .Enter:
			ans := agent.join_selected_labels(q.options[:], selected, context.temp_allocator)
			if ans == "" {
				return "", true
			}
			return ans, false
		case .Esc, .Ctrl_C:
			return "", true
		case .Char:
			if key.ch >= '1' && key.ch <= '9' {
				idx := int(key.ch - '1')
				if idx < len(selected) {
					selected[idx] = !selected[idx]
					tui_ask_user_set_multi_summary(st, q, selected)
					state_set_status(st, "multi-select · digit toggle · Enter submit")
					render(term, st)
				}
			}
		case:
			continue
		}
	}
}

// tui_ask_user_question: number-key multi-choice for ask_user_question tool.
// Esc cancels (Grok Path D). Digits 1-9 select (or toggle if multi_select); Other opens freeform.
tui_ask_user_question :: proc(arguments_json: string) -> string {
	qs, err := agent.parse_ask_questions(arguments_json, context.allocator)
	defer agent.free_ask_questions(&qs)
	if err != "" {
		return fmt.tprintf("error: %s", err)
	}
	st := stream_st()
	term := stream_term()
	if st == nil || term == nil {
		return agent.ASK_USER_CANCEL_TEXT
	}
	pairs := make([dynamic]string, 0, len(qs) * 2, context.temp_allocator)
	for q in qs {
		delete(st.ask_name)
		st.ask_name = strings.clone(q.question)
		st.ask_active = true

		chosen := ""
		if q.multi_select {
			ans, cancelled := tui_ask_user_multi(st, term, q)
			if cancelled {
				tui_ask_user_clear_modal(st)
				return agent.ASK_USER_CANCEL_TEXT
			}
			chosen = ans
		} else {
			tui_ask_user_set_choice_summary(st, q)
			state_set_status(st, "answer question · digit select · Esc cancel")
			render(term, st)
			for {
				key := read_key()
				#partial switch key.kind {
				case .Char:
					if key.ch >= '1' && key.ch <= '9' {
						idx := int(key.ch - '1')
						if idx < len(q.options) {
							chosen = q.options[idx].label
							break
						}
					}
					continue
				case .Esc, .Ctrl_C:
					tui_ask_user_clear_modal(st)
					return agent.ASK_USER_CANCEL_TEXT
				case:
					continue
				}
			}
			if chosen == "" {
				tui_ask_user_clear_modal(st)
				return agent.ASK_USER_CANCEL_TEXT
			}
		}
		// Other alone → freeform sub-mode (stdin parity; multi "A, Other" stays literal)
		if agent.is_other_option(chosen) {
			ans, cancelled := tui_ask_user_freeform(st, term)
			if cancelled {
				tui_ask_user_clear_modal(st)
				return agent.ASK_USER_CANCEL_TEXT
			}
			chosen = ans
		}
		tui_ask_user_clear_modal(st)
		append(&pairs, q.question)
		append(&pairs, chosen)
	}
	state_set_status(st, "questions answered")
	return agent.format_accepted_answers(pairs[:], context.allocator)
}

// tui_ask_tool is the Turn_Options.on_ask handler (nested key loop on alt-screen).
// y/Enter = once, n/Esc = deny, a = always, d = never (Grok AllowAlways / RejectAlways).
tui_ask_tool :: proc(name, summary: string) -> core.Ask_Decision {
	title := fmt.tprintf("approve %s? y/n/a/d", name)
	if !core.session_allow_enabled() {
		title = fmt.tprintf("approve %s? y/n", name)
	}
	dec := tui_modal_ask(title, name, summary, allow_always = true)
	st := stream_st()
	term := stream_term()
	if st != nil {
		switch dec {
		case .Once:
			state_set_status(st, fmt.tprintf("allowed %s", name))
		case .Always:
			state_set_status(st, fmt.tprintf("always allow (session) %s", name))
		case .Never:
			state_set_status(st, fmt.tprintf("never allow (session) %s", name))
		case .Deny:
			state_set_status(st, fmt.tprintf("denied %s", name))
		}
		if term != nil {
			render(term, st)
		}
	}
	return dec
}

// tui_plan_enter_ask: approve model enter_plan_mode tool.
tui_plan_enter_ask :: proc() -> bool {
	ok := tui_modal_yn("enter plan mode? y/n", "enter_plan_mode", "explore first; only .grok/plan.md writable")
	st := stream_st()
	term := stream_term()
	if st != nil {
		if ok {
			state_set_status(st, "plan mode enter approved")
		} else {
			state_set_status(st, "plan mode enter declined")
		}
		if term != nil {
			render(term, st)
		}
	}
	return ok
}

// tui_plan_exit_ask: y approve / n revise / a abandon (Grok plan approval outcomes).
tui_plan_exit_ask :: proc(plan_path, plan_preview: string) -> agent.Plan_Exit_Result {
	sum := plan_preview
	if sum == "" {
		sum = "(empty plan file)"
	}
	st := stream_st()
	term := stream_term()
	res := agent.Plan_Exit_Result {
		outcome = .Cancelled,
	}
	if st == nil || term == nil {
		// headless fallback inside TUI package — should not happen mid-stream
		return agent.default_plan_exit_ask(plan_path, plan_preview)
	}
	delete(st.ask_name)
	delete(st.ask_summary)
	st.ask_name = strings.clone("exit_plan_mode")
	st.ask_summary = strings.clone(sum)
	st.ask_active = true
	state_set_status(st, "exit plan? y=approve n=revise a=abandon")
	render(term, st)

	for {
		key := read_key()
		#partial switch key.kind {
		case .Char:
			if key.ch == 'y' || key.ch == 'Y' {
				res.outcome = .Approved
				break
			}
			if key.ch == 'a' || key.ch == 'A' {
				res.outcome = .Abandoned
				break
			}
			if key.ch == 'n' || key.ch == 'N' {
				// optional freeform feedback
				res.outcome = .Cancelled
				fb, cancelled := tui_ask_user_freeform(st, term)
				if !cancelled && strings.trim_space(fb) != "" {
					// Plan_Exit_Result.feedback is not owned long-term; clone into temp
					// for exit_plan_mode_impl which only reads during the call.
					res.feedback = fb
				} else {
					delete(fb)
				}
				break
			}
			continue
		case .Enter:
			res.outcome = .Approved
			break
		case .Esc, .Ctrl_C:
			res.outcome = .Cancelled
			break
		case:
			continue
		}
		break
	}

	st.ask_active = false
	delete(st.ask_name)
	delete(st.ask_summary)
	st.ask_name = ""
	st.ask_summary = ""

	switch res.outcome {
	case .Approved:
		state_set_status(st, "plan exit approved")
		if stream_sess() != nil {
			stream_sess().plan_mode = false
		}
	case .Abandoned:
		state_set_status(st, "plan abandoned")
		if stream_sess() != nil {
			stream_sess().plan_mode = false
		}
	case .Cancelled:
		state_set_status(st, "plan revise — still planning")
	}
	if term != nil {
		render(term, st)
	}
	return res
}
