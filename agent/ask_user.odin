// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

// ask_user_question — Grok Build AskUserQuestionTool port (product Full).
// Reference: crates/codegen/xai-grok-tools/.../ask_user_question/
// stdin / TUI callback; option preview lines shown in TUI modal (B7).

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:terminal"
import "aether:core"

// Grok CANCEL_TEXT (format.rs Path D)
ASK_USER_CANCEL_TEXT :: "User declined to answer the questions. Continue with the task using your best judgment, or ask different questions."

Ask_Option :: struct {
	label:       string,
	description: string,
	preview:     string, // optional; shown under option when non-empty
}

Ask_Question :: struct {
	question:     string,
	options:      [dynamic]Ask_Option,
	multi_select: bool,
}

// Ask_User_Handler: optional TUI/REPL. Return answer tool-result text, or empty to cancel.
// questions_json is the raw tool arguments (or a normalized payload).
Ask_User_Handler :: #type proc(arguments_json: string) -> string

ask_user_enabled :: proc() -> bool {
	return !core.feature_killed("AETHER_NO_ASK_USER")
}

// is_other_option: exact match for the auto-appended Other choice.
is_other_option :: proc(label: string) -> bool {
	return label == "Other"
}

// other_answer_from_draft: empty/whitespace freeform → "Other"; else trimmed text.
// Does not allocate; return value aliases draft or a static string.
other_answer_from_draft :: proc(draft: string) -> string {
	t := strings.trim_space(draft)
	if t == "" {
		return "Other"
	}
	return t
}

// format_accepted_answers — Grok format_accepted_tool_result (label-keyed Path A).
format_accepted_answers :: proc(
	pairs: []string, // alternating question, answer_label
	allocator := context.allocator,
) -> string {
	if len(pairs) < 2 {
		return strings.clone(ASK_USER_CANCEL_TEXT, allocator)
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, "User has answered your questions: ")
	for i := 0; i + 1 < len(pairs); i += 2 {
		if i > 0 {
			strings.write_string(&b, ", ")
		}
		fmt.sbprintf(&b, "\"%s\"=\"%s\"", pairs[i], pairs[i + 1])
	}
	strings.write_string(&b, ". You can now continue with the user's answers in mind.")
	return strings.to_string(b)
}

parse_ask_questions :: proc(
	arguments_json: string,
	allocator := context.allocator,
) -> (
	qs: [dynamic]Ask_Question,
	err: string,
) {
	qs = make([dynamic]Ask_Question, 0, 4, allocator)
	obj, ok := tools_json_object(arguments_json)
	if !ok {
		return qs, "invalid JSON arguments"
	}
	arr_v, has := obj["questions"]
	if !has {
		return qs, "questions array is required"
	}
	arr, is_arr := arr_v.(json.Array)
	if !is_arr || len(arr) == 0 {
		return qs, "questions must be a non-empty array"
	}
	for item in arr {
		qo, is_obj := item.(json.Object)
		if !is_obj {
			return qs, "each question must be an object"
		}
		qtext := strings.trim_space(jstr_obj(qo, "question"))
		if qtext == "" {
			return qs, "each question requires a non-empty question field"
		}
		opts_v, has_o := qo["options"]
		if !has_o {
			return qs, "each question requires options"
		}
		oarr, is_oa := opts_v.(json.Array)
		if !is_oa || len(oarr) == 0 {
			return qs, "options must be a non-empty array"
		}
		opts := make([dynamic]Ask_Option, 0, len(oarr) + 1, allocator)
		for ov in oarr {
			oo, is_oo := ov.(json.Object)
			if !is_oo {
				return qs, "each option must be an object"
			}
			label := strings.trim_space(jstr_obj(oo, "label"))
			if label == "" {
				return qs, "each option requires a label"
			}
			desc := jstr_obj(oo, "description")
			prev := jstr_obj(oo, "preview")
			append(
				&opts,
				Ask_Option {
					label       = strings.clone(label, allocator),
					description = strings.clone(desc, allocator),
					preview     = strings.clone(prev, allocator),
				},
			)
		}
		// Grok: every question automatically gets an "Other" choice
		append(
			&opts,
			Ask_Option {
				label       = strings.clone("Other", allocator),
				description = strings.clone("Type your own answer", allocator),
				preview     = "",
			},
		)
		multi := false
		if mv, has_m := qo["multi_select"]; has_m {
			#partial switch t in mv {
			case json.Boolean:
				multi = bool(t)
			case json.String:
				s := strings.to_lower(string(t), context.temp_allocator)
				multi = s == "true" || s == "1" || s == "yes"
			}
		} else if mv2, has_m2 := qo["multiSelect"]; has_m2 {
			if b, is_b := mv2.(json.Boolean); is_b {
				multi = bool(b)
			}
		}
		append(
			&qs,
			Ask_Question {
				question     = strings.clone(qtext, allocator),
				options      = opts,
				multi_select = multi,
			},
		)
	}
	return qs, ""
}

// tools package helpers without import cycle — local JSON helpers
tools_json_object :: proc(arguments_json: string) -> (json.Object, bool) {
	val, err := json.parse(
		transmute([]byte)arguments_json,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if err != nil {
		return nil, false
	}
	obj, ok := val.(json.Object)
	return obj, ok
}

jstr_obj :: proc(obj: json.Object, key: string) -> string {
	v, ok := obj[key]
	if !ok {
		return ""
	}
	if s, is_s := v.(json.String); is_s {
		return string(s)
	}
	return ""
}

free_ask_questions :: proc(qs: ^[dynamic]Ask_Question) {
	for &q in qs {
		delete(q.question)
		for &o in q.options {
			delete(o.label)
			delete(o.description)
			delete(o.preview)
		}
		delete(q.options)
	}
	delete(qs^)
	qs^ = {}
}

// interactive_ask_user_stdin: number selection + freeform for Other (Grok Path A).
interactive_ask_user_stdin :: proc(
	qs: []Ask_Question,
	quiet: bool,
	allocator := context.allocator,
) -> string {
	if quiet || !terminal.is_terminal(os.stdin) {
		return strings.clone(ASK_USER_CANCEL_TEXT, allocator)
	}
	pairs := make([dynamic]string, 0, len(qs) * 2, context.temp_allocator)
	for q in qs {
		fmt.eprintf("\naether: %s\n", q.question)
		for o, i in q.options {
			desc := o.description
			if desc != "" {
				fmt.eprintf("  %d) %s — %s\n", i + 1, o.label, desc)
			} else {
				fmt.eprintf("  %d) %s\n", i + 1, o.label)
			}
			if o.preview != "" {
				// Product preview line (full pager modal N/A)
				fmt.eprintf("      preview: %s\n", o.preview)
			}
		}
		if q.multi_select {
			fmt.eprintf("  (multi-select: enter numbers separated by spaces, or empty to skip)\n")
		}
		fmt.eprintf("  choice [1-%d, or empty=cancel]: ", len(q.options))
		line, ok := read_stdin_line(context.temp_allocator)
		if !ok || strings.trim_space(line) == "" {
			return strings.clone(ASK_USER_CANCEL_TEXT, allocator)
		}
		answer := resolve_choice_line(line, q.options[:], context.temp_allocator)
		if answer == "" {
			return strings.clone(ASK_USER_CANCEL_TEXT, allocator)
		}
		// If Other, prompt free text (Grok Path A freeform)
		if is_other_option(answer) || strings.has_prefix(answer, "Other") {
			fmt.eprintf("  other (type answer): ")
			note, nok := read_stdin_line(context.temp_allocator)
			draft := ""
			if nok {
				draft = note
			}
			answer = other_answer_from_draft(draft)
		}
		append(&pairs, q.question)
		append(&pairs, answer)
	}
	return format_accepted_answers(pairs[:], allocator)
}

// resolve_choice_line maps "1" or "1 3" to option label(s).
resolve_choice_line :: proc(line: string, options: []Ask_Option, allocator := context.allocator) -> string {
	parts, _ := strings.fields(strings.trim_space(line), context.temp_allocator)
	if len(parts) == 0 {
		return ""
	}
	labels := make([dynamic]string, 0, len(parts), context.temp_allocator)
	for p in parts {
		n, ok := strconv.parse_int(p)
		if !ok || n < 1 || n > len(options) {
			// free text answer
			return strings.clone(strings.trim_space(line), allocator)
		}
		append(&labels, options[n - 1].label)
	}
	if len(labels) == 1 {
		return strings.clone(labels[0], allocator)
	}
	return strings.join(labels[:], ", ", allocator)
}

// join_selected_labels: TUI multi-select → "A, B" (empty if none selected).
join_selected_labels :: proc(
	options: []Ask_Option,
	selected: []bool,
	allocator := context.allocator,
) -> string {
	n := min(len(options), len(selected))
	labels := make([dynamic]string, 0, n, context.temp_allocator)
	for i in 0 ..< n {
		if selected[i] {
			append(&labels, options[i].label)
		}
	}
	if len(labels) == 0 {
		return strings.clone("", allocator)
	}
	if len(labels) == 1 {
		return strings.clone(labels[0], allocator)
	}
	return strings.join(labels[:], ", ", allocator)
}

// ask_user_from_args is the tool entrypoint.
ask_user_from_args :: proc(
	arguments_json: string,
	opts: Turn_Options,
	allocator := context.allocator,
) -> string {
	if !ask_user_enabled() {
		return strings.clone("error: ask_user_question disabled (AETHER_NO_ASK_USER=1)", allocator)
	}
	qs, err := parse_ask_questions(arguments_json, context.allocator)
	defer free_ask_questions(&qs)
	if err != "" {
		return fmt.aprintf("error: %s", err, allocator = allocator)
	}
	if opts.on_ask_user != nil {
		// Handler receives original JSON; may re-parse or use its own UI
		out := opts.on_ask_user(arguments_json)
		if out == "" {
			return strings.clone(ASK_USER_CANCEL_TEXT, allocator)
		}
		return strings.clone(out, allocator)
	}
	return interactive_ask_user_stdin(qs[:], opts.quiet, allocator)
}
