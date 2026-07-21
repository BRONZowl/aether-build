// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_normalize_aspect_ratio :: proc(t: ^testing.T) {
	testing.expect(t, normalize_aspect_ratio("") == "1:1")
	testing.expect(t, normalize_aspect_ratio("auto") == "1:1")
	testing.expect(t, normalize_aspect_ratio("16:9") == "16:9")
	testing.expect(t, normalize_aspect_ratio("portrait") == "9:16")
	testing.expect(t, normalize_aspect_ratio("landscape") == "16:9")
}

@(test)
test_extract_b64_json :: proc(t: ^testing.T) {
	body := `{"data":[{"b64_json":"aGVsbG8="}]}`
	b64, err := extract_b64_json(body)
	testing.expect(t, err == "")
	testing.expect(t, b64 == "aGVsbG8=")
	_, e2 := extract_b64_json(`{"data":[]}`)
	testing.expect(t, e2 != "")
}

@(test)
test_decode_b64_image :: proc(t: ^testing.T) {
	// "hi" in base64
	raw, err := decode_b64_image("aGk=", context.allocator)
	defer delete(raw)
	testing.expect(t, err == "")
	testing.expect(t, len(raw) == 2)
	testing.expect(t, raw[0] == 'h' && raw[1] == 'i')
}

@(test)
test_save_image_bytes_counter :: proc(t: ^testing.T) {
	// write tiny payload under temp image dir
	prev := os.get_env("AETHER_IMAGE_DIR", context.temp_allocator)
	dir := fmt.tprintf("/tmp/aether-img-test-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.set_env("AETHER_IMAGE_DIR", dir)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_IMAGE_DIR")
		} else {
			_ = os.set_env("AETHER_IMAGE_DIR", prev)
		}
	}
	data := transmute([]byte)string("not-a-real-jpeg")
	p1, r1, n1, e1 := save_image_bytes(data, context.allocator)
	defer delete(p1)
	testing.expect(t, e1 == "")
	testing.expect(t, strings.has_suffix(p1, ".jpg"))
	testing.expect(t, strings.contains(r1, "images/"))
	testing.expect(t, n1 >= 1)
	p2, _, n2, e2 := save_image_bytes(data, context.allocator)
	defer delete(p2)
	testing.expect(t, e2 == "")
	testing.expect(t, p1 != p2)
	testing.expect(t, n2 == n1 + 1)
}

@(test)
test_image_gen_disabled_env :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_IMAGE_GEN", context.temp_allocator)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_NO_IMAGE_GEN")
		} else {
			_ = os.set_env("AETHER_NO_IMAGE_GEN", prev)
		}
	}
	_ = os.set_env("AETHER_NO_IMAGE_GEN", "1")
	testing.expect(t, !image_gen_enabled())
	out := handle_image_gen({}, `{"prompt":"x"}`, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "disabled"))
}

@(test)
test_image_gen_requires_key_session_only :: proc(t: ^testing.T) {
	// Ensure no env key for this check
	prev := os.get_env("XAI_API_KEY", context.temp_allocator)
	prev2 := os.get_env("GROK_CODE_XAI_API_KEY", context.temp_allocator)
	_ = os.unset_env("XAI_API_KEY")
	_ = os.unset_env("GROK_CODE_XAI_API_KEY")
	defer {
		if prev != "" {
			_ = os.set_env("XAI_API_KEY", prev)
		}
		if prev2 != "" {
			_ = os.set_env("GROK_CODE_XAI_API_KEY", prev2)
		}
	}
	creds := Credentials {
		kind   = .Session,
		bearer = "sess-token",
	}
	out := image_gen_run(creds, "a cat", "1:1", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "XAI_API_KEY"))
}
