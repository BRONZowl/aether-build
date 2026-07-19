package tools

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_line_hash_fnv_stable :: proc(t: ^testing.T) {
	a := line_hash_fnv("hello world")
	b := line_hash_fnv("hello   world") // whitespace collapse
	c := line_hash_fnv("hello\tworld")
	testing.expect(t, len(a) == HASH_LEN)
	testing.expect(t, a == b)
	testing.expect(t, a == c)
	testing.expect(t, line_hash_fnv("hello world!") != a)
}

@(test)
test_parse_anchor :: proc(t: ^testing.T) {
	line, hash, ok := parse_anchor("12:abc")
	testing.expect(t, ok)
	testing.expect(t, line == 12)
	testing.expect(t, hash == "abc")

	line, hash, ok = parse_anchor("EOF")
	testing.expect(t, ok)
	testing.expect(t, line == -1)

	line, hash, ok = parse_anchor("0:")
	testing.expect(t, ok)
	testing.expect(t, line == 0)

	_, _, ok = parse_anchor("")
	testing.expect(t, !ok)
}

@(test)
test_hashline_read_edit_replace :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-hl-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)

	p, _ := filepath.join({root, "sample.txt"}, context.temp_allocator)
	_ = os.write_entire_file(p, "alpha\nbeta\ngamma\n")

	read_out := tool_hashline_read(`{"file_path":"sample.txt"}`, root, context.allocator)
	defer delete(read_out)
	testing.expect(t, strings.contains(read_out, "scheme=content_only_v1"))
	testing.expect(t, strings.contains(read_out, "1:"))
	testing.expect(t, strings.contains(read_out, "→alpha"))
	testing.expect(t, strings.contains(read_out, "→beta"))

	// Build JSON without fmt (Odin treats { } as format braces)
	h2 := line_hash_fnv("beta")
	args := strings.concatenate(
		{
			`{"file_path":"sample.txt","op":"replace","anchor":"2:`,
			h2,
			`","content":"BETA"}`,
		},
		context.allocator,
	)
	defer delete(args)

	edit_out := tool_hashline_edit(args, root, context.allocator)
	defer delete(edit_out)
	testing.expect(t, strings.contains(edit_out, "ok"), edit_out)

	data, err := os.read_entire_file(p, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, string(data) == "alpha\nBETA\ngamma\n")
}

@(test)
test_hashline_stale_anchor :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-hl-stale-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)

	p, _ := filepath.join({root, "f.txt"}, context.temp_allocator)
	_ = os.write_entire_file(p, "one\ntwo\n")

	out := tool_hashline_edit(
		`{"file_path":"f.txt","op":"replace","anchor":"1:zzz","content":"x"}`,
		root,
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, strings.contains(out, "stale") || strings.contains(out, "error:"))
}

@(test)
test_hashline_insert_after_bof :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-hl-ins-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)

	p, _ := filepath.join({root, "f.txt"}, context.temp_allocator)
	_ = os.write_entire_file(p, "body\n")

	out := tool_hashline_edit(
		`{"file_path":"f.txt","op":"insert_after","anchor":"0:","content":"head"}`,
		root,
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, strings.contains(out, "ok"), out)

	data, _ := os.read_entire_file(p, context.temp_allocator)
	testing.expect(t, string(data) == "head\nbody\n")
}

@(test)
test_tool_pack_deny_mutual_exclusion :: proc(t: ^testing.T) {
	d_hl := deny_for_tool_pack(.Hashline)
	testing.expect(t, len(d_hl) == 5)
	found_read := false
	for n in d_hl {
		if n == "read_file" {
			found_read = true
		}
	}
	testing.expect(t, found_read)

	d_std := deny_for_tool_pack(.Standard)
	testing.expect(t, len(d_std) == 3)
	found_hl := false
	for n in d_std {
		if n == "hashline_read" {
			found_hl = true
		}
	}
	testing.expect(t, found_hl)
}

@(test)
test_tools_schema_hashline_pack_env :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_TOOL_PACK", context.temp_allocator)
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_TOOL_PACK", prev)
		} else {
			_ = os.unset_env("AETHER_TOOL_PACK")
		}
	}

	_ = os.unset_env("AETHER_TOOL_PACK")
	std := tools_json_schema(allocator = context.allocator)
	defer delete(std)
	testing.expect(t, !strings.contains(std, `"name":"hashline_read"`))
	testing.expect(t, strings.contains(std, `"name":"read_file"`))

	_ = os.set_env("AETHER_TOOL_PACK", "hashline")
	hl := tools_json_schema(allocator = context.allocator)
	defer delete(hl)
	testing.expect(t, strings.contains(hl, `"name":"hashline_read"`))
	testing.expect(t, strings.contains(hl, `"name":"hashline_edit"`))
	testing.expect(t, !strings.contains(hl, `"name":"read_file"`))
	testing.expect(t, !strings.contains(hl, `"name":"search_replace"`))
}
