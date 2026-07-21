// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_detect_image_mime :: proc(t: ^testing.T) {
	jpeg := []byte{0xff, 0xd8, 0xff, 0xe0}
	png := []byte{0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a}
	testing.expect(t, detect_image_mime(jpeg) == "image/jpeg")
	testing.expect(t, detect_image_mime(png) == "image/png")
	testing.expect(t, detect_image_mime([]byte{1, 2, 3}) == "")
}

@(test)
test_resolve_image_ref_data_url_and_path :: proc(t: ^testing.T) {
	// Minimal valid-ish JPEG for compress passthrough (magic + size under cap)
	// Use path with tiny JPEG magic — compress_reference pass-through
	path := fmt.tprintf("/tmp/aether-img-edit-%d.jpg", os.get_pid())
	payload := make([]byte, 64)
	payload[0] = 0xff
	payload[1] = 0xd8
	payload[2] = 0xff
	_ = os.write_entire_file(path, payload)
	defer os.remove(path)

	url, e2 := resolve_image_ref(path, context.allocator)
	defer delete(url)
	testing.expect(t, e2 == "")
	testing.expect(t, strings.has_prefix(url, "data:image/jpeg;base64,"))

	// Small data URL: compress path re-wraps
	// Craft data URL from same jpeg bytes
	du_in := "data:image/jpeg;base64,/9j/4AAQ" // may fail decode - use real encode
	// Build proper data URL from payload
	raw_url, re := resolve_image_ref(path, context.allocator)
	defer delete(raw_url)
	testing.expect(t, re == "")
	// re-resolve data URL form
	url2, e3 := resolve_image_ref(raw_url, context.allocator)
	defer delete(url2)
	testing.expect(t, e3 == "")
	testing.expect(t, strings.has_prefix(url2, "data:image/jpeg;base64,"))
	_ = du_in
}

@(test)
test_compress_passthrough_small_jpeg :: proc(t: ^testing.T) {
	payload := make([]byte, 128)
	payload[0] = 0xff
	payload[1] = 0xd8
	payload[2] = 0xff
	out, mime, err := compress_reference(payload, context.allocator)
	defer delete(out)
	testing.expect(t, err == "")
	testing.expect(t, mime == "image/jpeg")
	testing.expect(t, len(out) == len(payload))
}

@(test)
test_resolve_image_ref_oversized :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/aether-img-big-%d.jpg", os.get_pid())
	// 401 KiB with jpeg magic — not a valid JPEG for magick; may error or compress
	n := MAX_REF_RAW_BYTES + 1024
	payload := make([]byte, n)
	payload[0] = 0xff
	payload[1] = 0xd8
	payload[2] = 0xff
	_ = os.write_entire_file(path, payload)
	defer os.remove(path)

	url, err := resolve_image_ref(path, context.allocator)
	if err == "" {
		// Magick may still produce something from garbage or fail softly
		defer delete(url)
		testing.expect(t, strings.has_prefix(url, "data:image/"))
	} else {
		// Without magick or unreadable garbage: structured error
		testing.expect(
			t,
			strings.contains(err, "too large") ||
			strings.contains(err, "compress") ||
			strings.contains(err, "ImageMagick") ||
			strings.contains(err, "failed") ||
			strings.contains(err, "decode") ||
			strings.contains(err, "process"),
		)
	}
}

@(test)
test_compress_large_with_magick_if_present :: proc(t: ^testing.T) {
	bin := find_magick_bin(context.temp_allocator)
	if bin == "" {
		return // skip: no ImageMagick
	}
	// Generate a large PNG via magick
	src := fmt.tprintf("/tmp/aether-img-gen-%d.png", os.get_pid())
	// 1200x1200 solid — should exceed 400KB as uncompressed-ish PNG or large
	argv := []string{bin, "-size", "2000x2000", "xc:red", src}
	if filepath_base_is_convert(bin) {
		argv = []string{bin, "-size", "2000x2000", "xc:red", src}
	}
	if !run_cmd_file(argv) {
		return // skip generate failure
	}
	defer os.remove(src)
	raw, rerr := os.read_entire_file(src, context.allocator)
	if rerr != nil {
		return
	}
	defer delete(raw)
	// if already small, still fine — compress should succeed
	out, mime, err := compress_reference(raw, context.allocator)
	defer delete(out)
	testing.expect(t, err == "")
	testing.expect(t, mime == "image/jpeg" || mime == "image/png")
	testing.expect(t, len(out) <= MAX_REF_RAW_BYTES)
	testing.expect(t, len(out) > 0)
}

filepath_base_is_convert :: proc(bin: string) -> bool {
	return strings.has_suffix(bin, "convert")
}

@(test)
test_parse_image_array :: proc(t: ^testing.T) {
	imgs, err := parse_image_array(`{"prompt":"x","image":["/a.jpg","/b.png"]}`, context.allocator)
	defer free_image_strings(&imgs)
	testing.expect(t, err == "")
	testing.expect(t, len(imgs) == 2)
	imgs2, err2 := parse_image_array(`{"prompt":"x","image":"/solo.jpg"}`, context.allocator)
	defer free_image_strings(&imgs2)
	testing.expect(t, err2 == "")
	testing.expect(t, len(imgs2) == 1)
}

@(test)
test_image_edit_empty_and_disabled :: proc(t: ^testing.T) {
	out := handle_image_edit({}, `{"prompt":"x","image":[]}`, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "at least one"))

	prev := os.get_env("AETHER_NO_IMAGE_GEN", context.temp_allocator)
	_ = os.set_env("AETHER_NO_IMAGE_GEN", "1")
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_NO_IMAGE_GEN")
		} else {
			_ = os.set_env("AETHER_NO_IMAGE_GEN", prev)
		}
	}
	out2 := handle_image_edit({}, `{"prompt":"x","image":["/a.jpg"]}`, context.allocator)
	defer delete(out2)
	testing.expect(t, strings.contains(out2, "disabled"))
}
