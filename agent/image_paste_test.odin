// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_is_image_extension :: proc(t: ^testing.T) {
	testing.expect(t, is_image_extension("/a/b.png"))
	testing.expect(t, is_image_extension("x.JPEG"))
	testing.expect(t, is_image_extension("q.webp"))
	testing.expect(t, !is_image_extension("x.txt"))
	testing.expect(t, !is_image_extension("noext"))
}

@(test)
test_process_paste_path_to_image_token :: proc(t: ^testing.T) {
	image_reg_clear()
	defer image_reg_clear()

	dir := fmt.aprintf("/tmp/aether-img-paste-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)

	// minimal PNG header
	png := []byte {
		0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
		0, 0, 0, 0, 0, 0, 0, 0,
	}
	path, _ := filepath.join({dir, "shot.png"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, png) == nil)

	out, n := process_paste_for_images(path, context.temp_allocator)
	testing.expect(t, n == 1)
	testing.expect(t, strings.contains(out, "[Image #1]"))
	ref, ok := image_reg_lookup(1, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, ref == path)
}

@(test)
test_process_paste_non_image_passthrough :: proc(t: ^testing.T) {
	image_reg_clear()
	defer image_reg_clear()
	out, n := process_paste_for_images("hello world", context.temp_allocator)
	testing.expect(t, n == 0)
	testing.expect(t, out == "hello world")
}

@(test)
test_content_image_token_indices :: proc(t: ^testing.T) {
	idxs := content_image_token_indices("see [Image #2] and [Image #1] and [Image #2]", context.temp_allocator)
	testing.expect(t, len(idxs) == 2)
	testing.expect(t, idxs[0] == 2 && idxs[1] == 1)
}

@(test)
test_write_user_content_json_multimodal :: proc(t: ^testing.T) {
	image_reg_clear()
	defer image_reg_clear()
	os.unset_env("AETHER_NO_MULTIMODAL")

	dir := fmt.aprintf("/tmp/aether-img-mm-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)
	// tiny valid-enough JPEG for compress pass-through? use PNG and magick may re-encode
	png := []byte {
		0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a,
		0, 0, 0, 0xd, 'I', 'H', 'D', 'R',
		0, 0, 0, 1, 0, 0, 0, 1, 8, 2, 0, 0, 0,
	}
	path, _ := filepath.join({dir, "a.png"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, png) == nil)
	n := image_reg_register(path)
	testing.expect(t, n == 1)

	b := strings.builder_make(context.temp_allocator)
	write_user_content_json(&b, "look [Image #1]")
	s := strings.to_string(b)
	// either multimodal array or string fallback if compress fails on tiny png
	if strings.contains(s, `"image_url"`) {
		testing.expect(t, strings.contains(s, `"type":"text"`))
		testing.expect(t, strings.contains(s, "look [Image #1]"))
	} else {
		// compress failed → string content still ok
		testing.expect(t, strings.contains(s, `"content":"`))
		testing.expect(t, strings.contains(s, "[Image #1]"))
	}
}

@(test)
test_build_chat_body_user_multimodal_optout :: proc(t: ^testing.T) {
	image_reg_clear()
	defer image_reg_clear()
	os.set_env("AETHER_NO_MULTIMODAL", "1")
	defer os.unset_env("AETHER_NO_MULTIMODAL")
	msgs := []Chat_Message{{role = .User, content = "x [Image #1]"}}
	body := build_chat_completions_body("grok", msgs, "", false, context.temp_allocator)
	testing.expect(t, strings.contains(body, `"content":"x [Image #1]"`))
	testing.expect(t, !strings.contains(body, "image_url"))
}

@(test)
test_save_clipboard_image_bytes :: proc(t: ^testing.T) {
	image_reg_clear()
	defer image_reg_clear()
	dir := fmt.aprintf("/tmp/aether-media-test-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	os.set_env("AETHER_MEDIA_DIR", dir)
	defer os.unset_env("AETHER_MEDIA_DIR")

	png := []byte{0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 1, 2, 3, 4}
	label, ok := save_clipboard_image_bytes(png, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(label, "[Image #"))
	ref, rok := image_reg_lookup(1, context.temp_allocator)
	testing.expect(t, rok)
	testing.expect(t, strings.has_prefix(ref, dir))
}
