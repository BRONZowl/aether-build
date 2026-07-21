// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:strings"
import "core:testing"

@(test)
test_json_string_field_basic :: proc(t: ^testing.T) {
	j := `{"target_file":"src/main.odin","offset":1}`
	got := json_string_field(j, "target_file")
	testing.expect(t, got == "src/main.odin", got)
	got2 := json_string_field(j, "missing")
	testing.expect(t, got2 == "")
}

@(test)
test_tool_display_title_read_file :: proc(t: ^testing.T) {
	body := `args: {"target_file":"/home/u/proj/foo.odin"}
---
1→package main`
	title := tool_display_title("read_file", body)
	testing.expect(t, strings.has_prefix(title, "Read "), title)
	testing.expect(t, strings.contains(title, "foo.odin"), title)
	testing.expect(t, !strings.contains(title, "[tool]"), title)
}

@(test)
test_tool_display_title_bash :: proc(t: ^testing.T) {
	body := `args: {"command":"git status -sb"}
---
## master`
	title := tool_display_title("run_terminal_cmd", body)
	testing.expect(t, title == "$ git status -sb", title)
}

@(test)
test_tool_display_title_edit :: proc(t: ^testing.T) {
	body := `args: {"file_path":"tui/render.odin","old_string":"a","new_string":"b"}
---
ok`
	title := tool_display_title("search_replace", body)
	testing.expect(t, strings.has_prefix(title, "Edited "), title)
	testing.expect(t, strings.contains(title, "render.odin"), title)
}

@(test)
test_tool_args_json_split :: proc(t: ^testing.T) {
	body := "args: {\"command\":\"ls\"}\n---\nout"
	a := tool_args_json(body)
	testing.expect(t, strings.contains(a, "ls"), a)
	r := tool_result_section(body)
	testing.expect(t, strings.trim_space(r) == "out", r)
}
