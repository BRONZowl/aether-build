package tools

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_list_dir_tree_and_nested :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-listdir-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)

	src, _ := filepath.join({root, "src"}, context.temp_allocator)
	_ = os.make_directory_all(src)
	main_p, _ := filepath.join({src, "main.rs"}, context.temp_allocator)
	lib_p, _ := filepath.join({src, "lib.rs"}, context.temp_allocator)
	readme, _ := filepath.join({root, "README.md"}, context.temp_allocator)
	_ = os.write_entire_file(main_p, "fn main() {}\n")
	_ = os.write_entire_file(lib_p, "pub fn x() {}\n")
	_ = os.write_entire_file(readme, "# hi\n")
	// hidden should be omitted
	hidden, _ := filepath.join({root, ".secret"}, context.temp_allocator)
	_ = os.write_entire_file(hidden, "nope\n")

	out := tool_list_dir(`{"target_directory":"."}`, root, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "src/"))
	testing.expect(t, strings.contains(out, "main.rs"))
	testing.expect(t, strings.contains(out, "lib.rs"))
	testing.expect(t, strings.contains(out, "README.md"))
	testing.expect(t, !strings.contains(out, ".secret"))
	testing.expect(t, strings.has_prefix(strings.trim_space(out), "- "))
}

@(test)
test_list_dir_not_found_and_file :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-listdir-err-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)
	f, _ := filepath.join({root, "a.txt"}, context.temp_allocator)
	_ = os.write_entire_file(f, "x\n")

	miss := tool_list_dir(`{"target_directory":"nope"}`, root, context.allocator)
	defer delete(miss)
	testing.expect(t, strings.contains(miss, "not found") || strings.contains(miss, "error"))

	as_file := tool_list_dir(`{"target_directory":"a.txt"}`, root, context.allocator)
	defer delete(as_file)
	testing.expect(t, strings.contains(as_file, "file") || strings.contains(as_file, "error"))
}

@(test)
test_list_dir_outside_workspace :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-listdir-out-%d", os.get_pid())
	_ = os.make_directory_all(root)
	defer os.remove_all(root)
	out := tool_list_dir(`{"target_directory":"/etc"}`, root, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "outside") || strings.contains(out, "denied"))
}

@(test)
test_list_dir_fat_summary :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-listdir-fat-%d", os.get_pid())
	_ = os.remove_all(root)
	imgs, _ := filepath.join({root, "images"}, context.temp_allocator)
	_ = os.make_directory_all(imgs)
	defer os.remove_all(root)

	// > FAT threshold files
	for i in 0 ..< 70 {
		p, _ := filepath.join({imgs, fmt.tprintf("img_%03d.jpg", i)}, context.temp_allocator)
		_ = os.write_entire_file(p, "x")
	}
	// small sibling so root expands images/
	_ = os.write_entire_file(
		fmt.tprintf("%s/note.txt", root),
		"n\n",
	)

	out := tool_list_dir(`{"target_directory":"."}`, root, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "images/"))
	// should summarize rather than dump 70 lines
	testing.expect(
		t,
		strings.contains(out, "in subtree") || strings.contains(out, "*.jpg"),
	)
	// not every img_ file enumerated
	count := strings.count(out, "img_")
	testing.expect(t, count < 20)
}

@(test)
test_list_dir_gitignore :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-listdir-gi-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)

	// minimal git repo so rg respects .gitignore
	git, _ := filepath.join({root, ".git"}, context.temp_allocator)
	_ = os.make_directory_all(fmt.tprintf("%s/objects", git))
	_ = os.make_directory_all(fmt.tprintf("%s/refs/heads", git))
	_ = os.write_entire_file(fmt.tprintf("%s/HEAD", git), "ref: refs/heads/master\n")
	_ = os.write_entire_file(
		fmt.tprintf("%s/config", git),
		"[core]\n\trepositoryformatversion = 0\n\tfilemode = true\n\tbare = false\n",
	)
	_ = os.write_entire_file(fmt.tprintf("%s/.gitignore", root), "*.log\nbuild/\n")
	_ = os.write_entire_file(fmt.tprintf("%s/keep.rs", root), "fn main(){}\n")
	_ = os.write_entire_file(fmt.tprintf("%s/noise.log", root), "log\n")
	_ = os.make_directory_all(fmt.tprintf("%s/build", root))
	_ = os.write_entire_file(fmt.tprintf("%s/build/out.o", root), "o")

	out := tool_list_dir(`{"target_directory":"."}`, root, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "keep.rs"))
	// gitignored should be absent when rg allowlist works
	if strings.contains(out, "keep.rs") {
		// only assert hide if listing otherwise succeeded
		testing.expect(t, !strings.contains(out, "noise.log"))
		testing.expect(t, !strings.contains(out, "build/") || !strings.contains(out, "out.o"))
	}
}
