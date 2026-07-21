// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tools

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

join2 :: proc(a, b: string) -> string {
	p, _ := filepath.join({a, b}, context.temp_allocator)
	return p
}

join3 :: proc(a, b, c: string) -> string {
	p, _ := filepath.join({a, b, c}, context.temp_allocator)
	return p
}

@(test)
test_glob_requires_pattern :: proc(t: ^testing.T) {
	out := tool_glob(`{"path":"."}`, "/tmp", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "pattern is required"))
}

@(test)
test_glob_finds_files :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-glob-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)

	_ = os.write_entire_file(join2(root, "a.go"), "package a\n")
	_ = os.make_directory_all(join2(root, "b"))
	_ = os.write_entire_file(join3(root, "b", "c.ts"), "x\n")
	_ = os.write_entire_file(join2(root, "skip.o"), "obj\n")

	out := tool_glob(`{"pattern":"**/*.ts"}`, root, context.allocator)
	defer delete(out)
	if strings.has_prefix(out, "error:") {
		testing.expect(t, strings.contains(out, "rg"))
		return
	}
	testing.expect(t, strings.contains(out, "c.ts"))
	testing.expect(t, !strings.contains(out, "skip.o"))
	testing.expect(t, strings.contains(out, "workspace_result"))
}

@(test)
test_glob_no_matches :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-glob-empty-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)
	_ = os.write_entire_file(join2(root, "a.txt"), "x\n")

	out := tool_glob(`{"pattern":"**/*.rs"}`, root, context.allocator)
	defer delete(out)
	if strings.has_prefix(out, "error:") {
		return
	}
	testing.expect(t, strings.contains(out, "No files found"))
}
