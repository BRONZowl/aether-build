// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tools

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_lsp_op_from_string :: proc(t: ^testing.T) {
	testing.expect(t, lsp_op_from_string("goToDefinition") == .Go_To_Definition)
	testing.expect(t, lsp_op_from_string("hover") == .Hover)
	testing.expect(t, lsp_op_from_string("workspaceSymbol") == .Workspace_Symbol)
	testing.expect(t, lsp_op_from_string("diagnostics") == .Diagnostics)
	testing.expect(t, lsp_op_from_string("nope") == .Unknown)
}

@(test)
test_format_lsp_diagnostics :: proc(t: ^testing.T) {
	raw := `[{"range":{"start":{"line":2,"character":4},"end":{"line":2,"character":8}},"severity":1,"message":"undefined: foo","source":"ols","code":"E001"}]`
	out := format_lsp_diagnostics("/ws/main.odin", raw, context.allocator, "/ws")
	defer delete(out)
	testing.expect(t, strings.contains(out, "Diagnostics for main.odin (1)"))
	testing.expect(t, strings.contains(out, "main.odin:3:5 [error]"))
	testing.expect(t, strings.contains(out, "undefined: foo"))
	testing.expect(t, strings.contains(out, "ols"))

	empty := format_lsp_diagnostics("/ws/x.odin", "[]", context.allocator, "/ws")
	defer delete(empty)
	testing.expect(t, strings.contains(empty, "none"))

	// cache round-trip
	lsp_diag_clear_all()
	lsp_diag_store_json("file:///ws/a.odin", raw)
	got := lsp_diag_get_json("file:///ws/a.odin", context.allocator)
	defer delete(got)
	testing.expect(t, strings.contains(got, "undefined: foo"))
	lsp_diag_clear_all()
}

@(test)
test_diag_severity_filter :: proc(t: ^testing.T) {
	raw := `[
		{"range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}},"severity":1,"message":"err1"},
		{"range":{"start":{"line":1,"character":0},"end":{"line":1,"character":1}},"severity":2,"message":"warn1"},
		{"range":{"start":{"line":2,"character":0},"end":{"line":2,"character":1}},"severity":4,"message":"hint1"}
	]`
	all := format_lsp_diagnostics("/ws/x.odin", raw, context.allocator, "/ws")
	defer delete(all)
	testing.expect(t, strings.contains(all, "(3)"))
	testing.expect(t, strings.contains(all, "err1"))
	testing.expect(t, strings.contains(all, "warn1"))
	testing.expect(t, strings.contains(all, "hint1"))

	errs := format_lsp_diagnostics(
		"/ws/x.odin",
		raw,
		context.allocator,
		"/ws",
		Diag_Filter{errors_only = true, min_severity = 1},
	)
	defer delete(errs)
	testing.expect(t, strings.contains(errs, "(1)"))
	testing.expect(t, strings.contains(errs, "err1"))
	testing.expect(t, !strings.contains(errs, "warn1"))
	testing.expect(t, !strings.contains(errs, "hint1"))

	warns := format_lsp_diagnostics(
		"/ws/x.odin",
		raw,
		context.allocator,
		"/ws",
		Diag_Filter{min_severity = 2},
	)
	defer delete(warns)
	testing.expect(t, strings.contains(warns, "(2)"))
	testing.expect(t, strings.contains(warns, "err1"))
	testing.expect(t, strings.contains(warns, "warn1"))
	testing.expect(t, !strings.contains(warns, "hint1"))

	obj, ok := json_obj(`{"errors_only":true}`)
	testing.expect(t, ok)
	f := parse_diag_filter(obj)
	testing.expect(t, f.errors_only && f.min_severity == 1)
	testing.expect(t, severity_from_string("warn") == 2)
	testing.expect(t, diag_severity_kept(1, f))
	testing.expect(t, !diag_severity_kept(2, f))
}

@(test)
test_collect_diag_paths_and_wait :: proc(t: ^testing.T) {
	// single file_path
	obj1, ok1 := json_obj(`{"file_path":"a.odin"}`)
	testing.expect(t, ok1)
	p1 := collect_diag_paths(obj1, "a.odin", context.allocator)
	defer {
		for s in p1 {
			delete(s)
		}
		delete(p1)
	}
	testing.expect(t, len(p1) == 1)
	testing.expect(t, p1[0] == "a.odin")

	// paths array + dedupe
	obj2, ok2 := json_obj(`{"paths":["a.odin","b.odin","a.odin"],"file_path":"c.odin"}`)
	testing.expect(t, ok2)
	p2 := collect_diag_paths(obj2, "c.odin", context.allocator)
	defer {
		for s in p2 {
			delete(s)
		}
		delete(p2)
	}
	testing.expect(t, len(p2) == 3) // c, a, b order

	// wait clamp
	testing.expect(t, diag_wait_duration(-1) == LSP_DIAG_WAIT)
	testing.expect(t, diag_wait_duration(0) == 0)
	testing.expect(t, diag_wait_duration(500) == 500 * time.Millisecond)
	testing.expect(t, diag_wait_duration(999999) == LSP_DIAG_WAIT_MAX)
}

@(test)
test_apply_default_extensions_ols :: proc(t: ^testing.T) {
	ext := make(map[string]string)
	defer {
		for k, v in ext {
			delete(k)
			delete(v)
		}
		delete(ext)
	}
	apply_default_extensions("ols", &ext)
	testing.expect(t, ext[".odin"] == "odin")
}

@(test)
test_parse_and_resolve_lsp_config :: proc(t: ^testing.T) {
	raw := `{"ols":{"command":"/bin/ols"},"rust-analyzer":{"command":"rust-analyzer","extensions":{".rs":"rust"}}}`
	servers := make([dynamic]Lsp_Server_Cfg, 0, 4)
	defer free_lsp_servers(&servers)
	err := parse_lsp_servers_json(raw, &servers)
	testing.expect(t, err == "")
	testing.expect(t, len(servers) == 2)
	// ols gets default .odin
	name, lang, ok := resolve_lsp_server(servers[:], "/tmp/main.odin")
	testing.expect(t, ok)
	testing.expect(t, name == "ols")
	testing.expect(t, lang == "odin")
	name2, lang2, ok2 := resolve_lsp_server(servers[:], "/tmp/lib.rs")
	testing.expect(t, ok2)
	testing.expect(t, name2 == "rust-analyzer")
	testing.expect(t, lang2 == "rust")
}

@(test)
test_format_lsp_locations_and_hover :: proc(t: ^testing.T) {
	loc_json := `[{"uri":"file:///home/x/a.odin","range":{"start":{"line":3,"character":5},"end":{"line":3,"character":8}}}]`
	out := format_lsp_locations("Definition", loc_json, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "Definition (1 location)"))
	testing.expect(t, strings.contains(out, "/home/x/a.odin:4:6"))

	empty := format_lsp_locations("Definition", "null", context.allocator)
	defer delete(empty)
	testing.expect(t, strings.contains(empty, "No results"))

	hover := format_lsp_hover(`{"contents":{"kind":"markdown","value":"proc foo()"}}`, context.allocator)
	defer delete(hover)
	testing.expect(t, strings.contains(hover, "proc foo()"))
}

@(test)
test_lsp_disabled_env :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_LSP", context.temp_allocator)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_NO_LSP")
		} else {
			_ = os.set_env("AETHER_NO_LSP", prev)
		}
	}
	_ = os.set_env("AETHER_NO_LSP", "1")
	testing.expect(t, !lsp_enabled())
	out := tool_lsp(`{"operation":"hover","file_path":"x.odin","line":0,"character":0}`, "/tmp", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "disabled"))
}

@(test)
test_path_to_file_uri :: proc(t: ^testing.T) {
	u := path_to_file_uri("/home/a/b.odin", context.allocator)
	defer delete(u)
	testing.expect(t, u == "file:///home/a/b.odin")
	testing.expect(t, file_uri_to_path(u) == "/home/a/b.odin")
}

@(test)
test_hover_marked_string_language_fence :: proc(t: ^testing.T) {
	raw := `{"contents":{"language":"odin","value":"proc foo() -> int"}}`
	out := format_lsp_hover(raw, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "```odin"))
	testing.expect(t, strings.contains(out, "proc foo()"))
}

@(test)
test_format_locations_cap_and_relative :: proc(t: ^testing.T) {
	// relative path display (single loc)
	one := `[{"uri":"file:///ws/src/main.odin","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}]`
	rel := format_lsp_locations("Definition", one, context.allocator, "/ws")
	defer delete(rel)
	testing.expectf(t, strings.contains(rel, "src/main.odin:1:1"), "rel got: %s", rel)
	testing.expect(t, !strings.contains(rel, "/ws/src/main.odin"))

	// Cap: 55 synthetic locations by repeating a valid entry (avoids builder/fmt edge cases)
	entry := `{"uri":"file:///ws/f.odin","range":{"start":{"line":0,"character":0},"end":{"line":0,"character":1}}}`
	parts := make([dynamic]string, 0, 55, context.allocator)
	defer delete(parts)
	for _ in 0 ..< 55 {
		append(&parts, entry)
	}
	joined, _ := strings.join(parts[:], ",", context.allocator)
	defer delete(joined)
	json_s := fmt.tprintf("[%s]", joined)
	out := format_lsp_locations("References", json_s, context.allocator, "/ws")
	defer delete(out)
	testing.expectf(
		t,
		strings.contains(out, "55 location"),
		"cap header got (first 300): %.300s json_len=%d",
		out,
		len(json_s),
	)
	testing.expectf(
		t,
		strings.contains(out, "and 5 more"),
		"cap footer got (first 400): %.400s",
		out,
	)
}

@(test)
test_display_path_ws :: proc(t: ^testing.T) {
	testing.expect(t, display_path_ws("/ws/a/b.odin", "/ws") == "a/b.odin")
	testing.expect(t, display_path_ws("/other/x", "/ws") == "/other/x")
	testing.expect(t, display_path_ws("/ws", "/ws") == ".")
}
