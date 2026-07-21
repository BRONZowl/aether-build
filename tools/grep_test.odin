// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tools

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_grep_requires_pattern :: proc(t: ^testing.T) {
	out := tool_grep(`{"path":"."}`, "/tmp", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "pattern is required"))
}

@(test)
test_grep_finds_and_context :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-grep-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)

	body := "line one\nUNIQUE_TOKEN here\nline three\n"
	p, _ := filepath.join({root, "f.txt"}, context.temp_allocator)
	_ = os.write_entire_file(p, body)

	out := tool_grep(
		`{"pattern":"UNIQUE_TOKEN","path":".","-C":1}`,
		root,
		context.allocator,
	)
	defer delete(out)
	if strings.has_prefix(out, "error:") {
		testing.expect(t, strings.contains(out, "rg"))
		return
	}
	testing.expect(t, strings.contains(out, "UNIQUE_TOKEN"))
	// context should pull adjacent lines
	testing.expect(t, strings.contains(out, "line one") || strings.contains(out, "line three"))
}

@(test)
test_grep_head_limit_truncates :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-grep-lim-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)

	// many matching lines
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< 50 {
		fmt.sbprintf(&b, "match line %d\n", i)
	}
	p, _ := filepath.join({root, "many.txt"}, context.temp_allocator)
	_ = os.write_entire_file(p, strings.to_string(b))

	out := tool_grep(
		`{"pattern":"match line","path":".","head_limit":5}`,
		root,
		context.allocator,
	)
	defer delete(out)
	if strings.has_prefix(out, "error:") {
		return
	}
	testing.expect(t, strings.contains(out, "truncated") || strings.contains(out, "head_limit"))
	// should not list all 50 if truncated note present
	count := strings.count(out, "match line")
	testing.expect(t, count <= 10) // 5 lines + maybe note
}

@(test)
test_grep_case_insensitive :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-grep-i-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)
	p, _ := filepath.join({root, "c.txt"}, context.temp_allocator)
	_ = os.write_entire_file(p, "HelloWorld\n")

	out := tool_grep(
		`{"pattern":"helloworld","path":".","-i":true}`,
		root,
		context.allocator,
	)
	defer delete(out)
	if strings.has_prefix(out, "error:") {
		return
	}
	testing.expect(t, strings.contains(out, "HelloWorld") || strings.contains(out, "helloworld"))
}

@(test)
test_grep_no_matches :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-grep-none-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)
	p, _ := filepath.join({root, "z.txt"}, context.temp_allocator)
	_ = os.write_entire_file(p, "nothing\n")

	out := tool_grep(`{"pattern":"ZZZNOPE","path":"."}`, root, context.allocator)
	defer delete(out)
	if strings.has_prefix(out, "error:") {
		return
	}
	testing.expect(t, strings.contains(out, "no matches"))
}
