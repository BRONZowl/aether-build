// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tools

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"

// Serialize memory tests that touch package-level overrides.
@(private)
g_memory_test_mu: sync.Mutex

@(test)
test_format_memory_lines :: proc(t: ^testing.T) {
	out := format_memory_lines("a\nb\n", 1, context.allocator)
	defer delete(out)
	testing.expect(t, out == "1→a\n2→b\n3→")
	empty := format_memory_lines("", 1, context.allocator)
	defer delete(empty)
	testing.expect(t, empty == "")
}

@(test)
test_memory_get_line_range_and_escape :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_memory_test_mu)
	defer sync.mutex_unlock(&g_memory_test_mu)

	root := fmt.aprintf("/tmp/aether-mem-get-%d", os.get_pid())
	defer delete(root)
	_ = os.remove_all(root)
	testing.expect(t, os.make_directory_all(root) == nil)
	defer os.remove_all(root)

	prev_root := g_memory_root_override
	prev_dis := g_memory_force_disabled
	g_memory_root_override = root
	g_memory_force_disabled = false
	defer {
		g_memory_root_override = prev_root
		g_memory_force_disabled = prev_dis
	}

	md, _ := filepath.join({root, "MEMORY.md"}, context.temp_allocator)
	content := "alpha\nbeta\ngamma\n"
	testing.expect(t, os.write_entire_file(md, transmute([]byte)content) == nil)

	out := tool_memory_get(`{"path":"MEMORY.md","from":1,"lines":1}`, context.allocator)
	defer delete(out)
	testing.expectf(t, strings.contains(out, "2→beta"), "got: %s", out)
	testing.expect(t, !strings.contains(out, "1→alpha"))
	testing.expect(t, !strings.contains(out, "3→gamma"))

	// Escape outside root
	denied := tool_memory_get(`{"path":"../auth.json"}`, context.allocator)
	defer delete(denied)
	testing.expect(t, starts_with_error(denied))
	testing.expect(t, strings.contains(denied, "outside") || strings.contains(denied, "error:"))

	// Absolute outside
	denied2 := tool_memory_get(`{"path":"/etc/passwd"}`, context.allocator)
	defer delete(denied2)
	testing.expect(t, starts_with_error(denied2))
}

@(test)
test_memory_search_prefers_workspace :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_memory_test_mu)
	defer sync.mutex_unlock(&g_memory_test_mu)

	root := fmt.aprintf("/tmp/aether-mem-search-%d", os.get_pid())
	defer delete(root)
	_ = os.remove_all(root)
	testing.expect(t, os.make_directory_all(root) == nil)
	defer os.remove_all(root)

	prev_root := g_memory_root_override
	prev_dis := g_memory_force_disabled
	g_memory_root_override = root
	g_memory_force_disabled = false
	defer {
		g_memory_root_override = prev_root
		g_memory_force_disabled = prev_dis
	}

	// Preferred workspace for /tmp/myproject
	ws_dir, _ := filepath.join({root, "myproject-aabbccdd"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(ws_dir) == nil)
	ws_md, _ := filepath.join({ws_dir, "MEMORY.md"}, context.temp_allocator)
	ws_body := "# Project Memory — /tmp/myproject\n\nUniqueTokenAlpha appears here for ranking.\n"
	testing.expect(t, os.write_entire_file(ws_md, transmute([]byte)ws_body) == nil)

	// Other workspace with same token
	other, _ := filepath.join({root, "other-ffffffff"}, context.temp_allocator)
	testing.expect(t, os.make_directory_all(other) == nil)
	other_md, _ := filepath.join({other, "MEMORY.md"}, context.temp_allocator)
	other_body := "UniqueTokenAlpha also here but lower weight.\n"
	testing.expect(t, os.write_entire_file(other_md, transmute([]byte)other_body) == nil)

	// Global
	g_md, _ := filepath.join({root, "MEMORY.md"}, context.temp_allocator)
	g_body := "global only note\n"
	testing.expect(t, os.write_entire_file(g_md, transmute([]byte)g_body) == nil)

	out := tool_memory_search(
		`{"query":"UniqueTokenAlpha"}`,
		"/tmp/myproject",
		context.allocator,
	)
	defer delete(out)
	testing.expectf(t, strings.contains(out, "Found"), "got: %s", out)
	testing.expect(t, strings.contains(out, "UniqueTokenAlpha"))
	// Prefer workspace-labeled hit
	testing.expectf(t, strings.contains(out, "source: workspace"), "got: %s", out)

	empty := tool_memory_search(`{"query":"zzzznonexistenttoken999"}`, "/tmp/myproject", context.allocator)
	defer delete(empty)
	testing.expect(t, strings.contains(empty, "No memory results"))
}

@(test)
test_memory_schema_and_disabled :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_memory_test_mu)
	defer sync.mutex_unlock(&g_memory_test_mu)

	schema := tools_json_schema(false, false, false, false, true, nil)
	defer delete(schema)
	testing.expect(t, strings.contains(schema, "memory_search"))
	testing.expect(t, strings.contains(schema, "memory_get"))

	schema_off := tools_json_schema(false, false, false, false, false, nil)
	defer delete(schema_off)
	testing.expect(t, !strings.contains(schema_off, "memory_search"))

	prev_dis := g_memory_force_disabled
	g_memory_force_disabled = true
	defer {
		g_memory_force_disabled = prev_dis
	}
	testing.expect(t, !memory_enabled())
	out := tool_memory_search(`{"query":"x"}`, "/tmp", context.allocator)
	defer delete(out)
	testing.expect(t, starts_with_error(out))
}

@(test)
test_tokenize_query :: proc(t: ^testing.T) {
	toks := tokenize_query("Plan Mode!! Shift+Tab", context.allocator)
	defer {
		for tok in toks {
			delete(tok)
		}
		delete(toks)
	}
	testing.expect(t, len(toks) >= 3)
	testing.expect(t, token_seen(toks, "plan"))
	testing.expect(t, token_seen(toks, "mode"))
	testing.expect(t, token_seen(toks, "shift"))
	testing.expect(t, token_seen(toks, "tab"))
}

@(test)
test_memory_workspace_slug :: proc(t: ^testing.T) {
	s := memory_workspace_slug("/tmp/my-project", context.allocator)
	defer delete(s)
	testing.expect(t, s == "my-project")
	s2 := memory_workspace_slug("/tmp/weird name!!", context.allocator)
	defer delete(s2)
	testing.expect(t, s2 == "weird-name--")
	s3 := memory_workspace_slug("", context.allocator)
	defer delete(s3)
	testing.expect(t, s3 == "default")
}

@(test)
test_memory_append_session_log :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_memory_test_mu)
	defer sync.mutex_unlock(&g_memory_test_mu)

	root := fmt.aprintf("/tmp/aether-mem-write-%d", os.get_pid())
	defer delete(root)
	_ = os.remove_all(root)
	testing.expect(t, os.make_directory_all(root) == nil)
	defer os.remove_all(root)

	prev_root := g_memory_root_override
	prev_dis := g_memory_force_disabled
	g_memory_root_override = root
	g_memory_force_disabled = false
	defer {
		g_memory_root_override = prev_root
		g_memory_force_disabled = prev_dis
	}

	cwd := "/tmp/myproject"
	body := "## Decisions & rationale\n\n- Chose append API for A2.1\n"
	path, err := memory_append_session_log(cwd, body, context.allocator)
	defer delete(path)
	testing.expectf(t, err == "", "err: %s", err)
	testing.expect(t, path != "")
	testing.expect(t, strings.contains(path, root))
	testing.expect(t, strings.contains(path, "myproject"))
	testing.expect(t, strings.contains(path, "sessions"))
	testing.expect(t, strings.has_suffix(path, ".md"))
	testing.expect(t, os.exists(path))

	data, rerr := os.read_entire_file(path, context.allocator)
	defer delete(data)
	testing.expect(t, rerr == nil)
	text := string(data)
	testing.expect(t, strings.contains(text, "<!-- flush "))
	testing.expect(t, strings.contains(text, "Chose append API"))

	// Second append uses --- separator
	path2, err2 := memory_append_session_log(cwd, "## Technical context\n\n- second note\n", context.allocator)
	defer delete(path2)
	testing.expect(t, err2 == "")
	testing.expect(t, path2 == path)
	data2, _ := os.read_entire_file(path, context.allocator)
	defer delete(data2)
	text2 := string(data2)
	testing.expect(t, strings.contains(text2, "---"))
	testing.expect(t, strings.contains(text2, "second note"))

	// Empty rejected
	_, err3 := memory_append_session_log(cwd, "   ", context.allocator)
	testing.expect(t, err3 != "")

	// Status
	st := memory_status_text(cwd, context.allocator)
	defer delete(st)
	testing.expect(t, strings.contains(st, root))
	testing.expect(t, strings.contains(st, "enabled"))
	testing.expect(t, strings.contains(st, "myproject"))

	// Search finds the new session log
	out := tool_memory_search(`{"query":"append API"}`, cwd, context.allocator)
	defer delete(out)
	testing.expectf(t, strings.contains(out, "Found") || strings.contains(out, "append"), "got: %s", out)
}

@(test)
test_memory_write_workspace_md_and_lock :: proc(t: ^testing.T) {
	sync.mutex_lock(&g_memory_test_mu)
	defer sync.mutex_unlock(&g_memory_test_mu)

	root := fmt.aprintf("/tmp/aether-mem-dream-api-%d", os.get_pid())
	defer delete(root)
	_ = os.remove_all(root)
	testing.expect(t, os.make_directory_all(root) == nil)
	defer os.remove_all(root)

	prev_root := g_memory_root_override
	prev_dis := g_memory_force_disabled
	g_memory_root_override = root
	g_memory_force_disabled = false
	defer {
		g_memory_root_override = prev_root
		g_memory_force_disabled = prev_dis
	}

	cwd := "/tmp/dreamproj"
	body := "## Decisions\n\n- Ship A2.2 dream\n"
	path, err := memory_write_workspace_md(cwd, body, context.allocator)
	defer delete(path)
	testing.expectf(t, err == "", "err: %s", err)
	testing.expect(t, strings.contains(path, "MEMORY.md"))
	testing.expect(t, os.exists(path))

	got := memory_read_workspace_md(cwd, context.allocator)
	defer delete(got)
	testing.expect(t, strings.contains(got, "Ship A2.2"))

	// Session list after append
	_, aerr := memory_append_session_log(cwd, "## Technical context\n\n- note\n", context.allocator)
	testing.expect(t, aerr == "")
	stems := memory_list_session_stems(cwd, context.allocator)
	defer {
		for s in stems {
			delete(s)
		}
		delete(stems)
	}
	testing.expect(t, len(stems) >= 1)

	// Lock acquire
	acq, prior, lerr := dream_try_acquire(cwd)
	testing.expect(t, lerr == "")
	testing.expect(t, acq)
	testing.expect(t, dream_record(cwd))
	// Same process can re-acquire (own pid not blocking others logic)
	acq2, prior2, _ := dream_try_acquire(cwd)
	testing.expect(t, acq2)
	_ = prior
	_ = prior2
}

@(test)
test_is_scaffold_not_in_tools :: proc(t: ^testing.T) {
	// stems path safety
	_, ok := memory_session_file_path("/tmp/x", "../etc", context.allocator)
	testing.expect(t, !ok)
	_, ok2 := memory_session_file_path("/tmp/x", "2026-07-18", context.allocator)
	testing.expect(t, ok2)
}
