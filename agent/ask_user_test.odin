// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:strings"
import "core:testing"

@(test)
test_format_accepted_answers :: proc(t: ^testing.T) {
	pairs := []string{"Pick color?", "Blue", "Ship?", "Yes"}
	out := format_accepted_answers(pairs, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, `User has answered your questions`))
	testing.expect(t, strings.contains(out, `"Pick color?"="Blue"`))
	testing.expect(t, strings.contains(out, `"Ship?"="Yes"`))
	testing.expect(t, strings.contains(out, "continue with the user's answers"))
}

@(test)
test_parse_ask_questions_adds_other :: proc(t: ^testing.T) {
	args := `{"questions":[{"question":"Pick one?","options":[{"label":"A","description":"first"},{"label":"B","description":"second"}]}]}`
	qs, err := parse_ask_questions(args, context.allocator)
	defer free_ask_questions(&qs)
	testing.expect(t, err == "")
	testing.expect(t, len(qs) == 1)
	testing.expect(t, qs[0].question == "Pick one?")
	// A, B, + auto Other
	testing.expect(t, len(qs[0].options) == 3)
	testing.expect(t, qs[0].options[2].label == "Other")
}

@(test)
test_parse_ask_questions_preview :: proc(t: ^testing.T) {
	args := `{"questions":[{"question":"UI?","options":[{"label":"A","description":"first","preview":"mock A"},{"label":"B","preview":"mock B"}]}]}`
	qs, err := parse_ask_questions(args, context.allocator)
	defer free_ask_questions(&qs)
	testing.expect(t, err == "")
	testing.expect(t, len(qs) == 1)
	testing.expect(t, qs[0].options[0].preview == "mock A")
	testing.expect(t, qs[0].options[1].preview == "mock B")
}

@(test)
test_parse_ask_questions_validation :: proc(t: ^testing.T) {
	qs, err := parse_ask_questions(`{}`, context.allocator)
	defer free_ask_questions(&qs)
	testing.expect(t, err != "")

	qs2, err2 := parse_ask_questions(`{"questions":[]}`, context.allocator)
	defer free_ask_questions(&qs2)
	testing.expect(t, err2 != "")
}

@(test)
test_resolve_choice_line :: proc(t: ^testing.T) {
	opts := []Ask_Option{
		{label = "Alpha", description = ""},
		{label = "Beta", description = ""},
		{label = "Other", description = ""},
	}
	a := resolve_choice_line("1", opts, context.allocator)
	defer delete(a)
	testing.expect(t, a == "Alpha")
	b := resolve_choice_line("2 1", opts, context.allocator)
	defer delete(b)
	testing.expect(t, strings.contains(b, "Beta") && strings.contains(b, "Alpha"))
}

@(test)
test_other_answer_from_draft :: proc(t: ^testing.T) {
	testing.expect(t, is_other_option("Other"))
	testing.expect(t, !is_other_option("other"))
	testing.expect(t, !is_other_option("Something else"))
	testing.expect(t, other_answer_from_draft("") == "Other")
	testing.expect(t, other_answer_from_draft("   ") == "Other")
	testing.expect(t, other_answer_from_draft("DynamoDB") == "DynamoDB")
	testing.expect(t, other_answer_from_draft("  postgres  ") == "postgres")
}

@(test)
test_join_selected_labels :: proc(t: ^testing.T) {
	opts := []Ask_Option{
		{label = "Alpha", description = ""},
		{label = "Beta", description = ""},
		{label = "Other", description = ""},
	}
	none := []bool{false, false, false}
	empty := join_selected_labels(opts, none, context.allocator)
	defer delete(empty)
	testing.expect(t, empty == "")

	one := []bool{true, false, false}
	a := join_selected_labels(opts, one, context.allocator)
	defer delete(a)
	testing.expect(t, a == "Alpha")

	two := []bool{true, true, false}
	ab := join_selected_labels(opts, two, context.allocator)
	defer delete(ab)
	testing.expect(t, ab == "Alpha, Beta")

	other_only := []bool{false, false, true}
	o := join_selected_labels(opts, other_only, context.allocator)
	defer delete(o)
	testing.expect(t, o == "Other")
}

@(test)
test_ask_user_quiet_cancels :: proc(t: ^testing.T) {
	args := `{"questions":[{"question":"Q?","options":[{"label":"A","description":"a"}]}]}`
	opts := Turn_Options {
		quiet = true,
	}
	out := ask_user_from_args(args, opts, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "declined") || strings.contains(out, "best judgment"))
}
