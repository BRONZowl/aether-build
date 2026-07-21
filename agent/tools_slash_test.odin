// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:strings"
import "core:testing"

@(test)
test_handle_tools_slash_lists_core :: proc(t: ^testing.T) {
	out := handle_tools_slash("", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "aether tools"), out)
	testing.expect(t, strings.contains(out, "run_terminal_cmd"), out)
	testing.expect(t, strings.contains(out, "read_file"), out)
	testing.expect(t, strings.contains(out, "search_replace"), out)
	testing.expect(t, strings.contains(out, "tool(s)"), out)
}

@(test)
test_handle_tools_slash_filter :: proc(t: ^testing.T) {
	out := handle_tools_slash("web", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "web_search") || strings.contains(out, "web_fetch"), out)
	testing.expect(t, !strings.contains(out, "run_terminal_cmd") || strings.contains(out, "web"), out)
}

@(test)
test_handle_tools_slash_help :: proc(t: ^testing.T) {
	out := handle_tools_slash("help", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "Usage: /tools"), out)
}

@(test)
test_tools_schema_next_parses_name :: proc(t: ^testing.T) {
	sample := `[{"type":"function","function":{"name":"foo","description":"Foo does bar."}},` +
		`{"type":"function","function":{"name":"baz","description":"Baz."}}]`
	n1, d1, p1, ok1 := tools_schema_next(sample, 0)
	testing.expect(t, ok1)
	testing.expect(t, n1 == "foo", n1)
	testing.expect(t, strings.contains(d1, "Foo"), d1)
	n2, d2, p2, ok2 := tools_schema_next(sample, p1)
	testing.expect(t, ok2)
	testing.expect(t, n2 == "baz", n2)
	testing.expect(t, strings.contains(d2, "Baz"), d2)
	_, _, _, ok3 := tools_schema_next(sample, p2)
	testing.expect(t, !ok3)
}
