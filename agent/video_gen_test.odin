// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "aether:tools"

@(test)
test_normalize_video_resolution :: proc(t: ^testing.T) {
	r, e := normalize_video_resolution("")
	testing.expect(t, e == "")
	testing.expect(t, r == "480p")
	r2, e2 := normalize_video_resolution("720p")
	testing.expect(t, e2 == "")
	testing.expect(t, r2 == "720p")
	_, e3 := normalize_video_resolution("1080p")
	testing.expect(t, e3 != "")
}

@(test)
test_normalize_video_aspect :: proc(t: ^testing.T) {
	a, e := normalize_video_aspect("")
	testing.expect(t, e == "")
	testing.expect(t, a == "16:9")
	a2, e2 := normalize_video_aspect("1:1")
	testing.expect(t, e2 == "")
	testing.expect(t, a2 == "1:1")
	_, e3 := normalize_video_aspect("4:3")
	testing.expect(t, e3 != "")
}

@(test)
test_parse_video_duration :: proc(t: ^testing.T) {
	obj, ok := tools.json_obj(`{}`)
	testing.expect(t, ok)
	d, e := parse_video_duration(obj)
	testing.expect(t, e == "")
	testing.expect(t, d == 6)

	obj2, ok2 := tools.json_obj(`{"duration":10}`)
	testing.expect(t, ok2)
	d2, e2 := parse_video_duration(obj2)
	testing.expect(t, e2 == "")
	testing.expect(t, d2 == 10)

	obj3, ok3 := tools.json_obj(`{"duration":"6"}`)
	testing.expect(t, ok3)
	d3, e3 := parse_video_duration(obj3)
	testing.expect(t, e3 == "")
	testing.expect(t, d3 == 6)

	obj4, ok4 := tools.json_obj(`{"duration":7}`)
	testing.expect(t, ok4)
	_, e4 := parse_video_duration(obj4)
	testing.expect(t, e4 != "")
}

@(test)
test_parse_video_start_and_poll :: proc(t: ^testing.T) {
	id, err := parse_video_start_response(`{"request_id":"abc-123"}`)
	testing.expect(t, err == "")
	testing.expect(t, id == "abc-123")

	_, err2 := parse_video_start_response(`{"foo":1}`)
	testing.expect(t, err2 != "")

	st, url, e3 := parse_video_poll_response(`{"status":"done","video":{"url":"https://cdn.example/v.mp4"}}`)
	testing.expect(t, e3 == "")
	testing.expect(t, st == "done")
	testing.expect(t, url == "https://cdn.example/v.mp4")

	st2, _, e4 := parse_video_poll_response(`{"status":"pending"}`)
	testing.expect(t, e4 == "")
	testing.expect(t, st2 == "pending")
}

@(test)
test_resolve_video_image_https :: proc(t: ^testing.T) {
	u, e := resolve_video_image_ref("https://example.com/a.jpg", context.allocator)
	defer delete(u)
	testing.expect(t, e == "")
	testing.expect(t, u == "https://example.com/a.jpg")
}

@(test)
test_image_to_video_validation :: proc(t: ^testing.T) {
	out := handle_image_to_video({}, `{"prompt":"x"}`, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "image is required"))

	out2 := handle_image_to_video({}, `{"image":"/nope.jpg","duration":7}`, context.allocator)
	defer delete(out2)
	testing.expect(t, strings.contains(out2, "duration"))
}

@(test)
test_reference_to_video_validation :: proc(t: ^testing.T) {
	out := handle_reference_to_video({}, `{"prompt":"x","images":["/a.jpg"]}`, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "at least 2"))

	out2 := handle_reference_to_video({}, `{"images":["/a.jpg","/b.jpg"]}`, context.allocator)
	defer delete(out2)
	testing.expect(t, strings.contains(out2, "prompt is required"))

	// 8 images
	args := `{"prompt":"x","images":["1","2","3","4","5","6","7","8"]}`
	out3 := handle_reference_to_video({}, args, context.allocator)
	defer delete(out3)
	testing.expect(t, strings.contains(out3, "at most") || strings.contains(out3, "not readable"))
}

@(test)
test_imagine_video_slash_usage_and_disabled :: proc(t: ^testing.T) {
	out := handle_imagine_video_slash("", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "Usage: /imagine-video"))

	prev := os.get_env("AETHER_NO_VIDEO_GEN", context.temp_allocator)
	_ = os.set_env("AETHER_NO_VIDEO_GEN", "1")
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_NO_VIDEO_GEN")
		} else {
			_ = os.set_env("AETHER_NO_VIDEO_GEN", prev)
		}
	}
	out2 := handle_imagine_video_slash("/tmp/x.png hello", context.allocator)
	defer delete(out2)
	testing.expect(t, strings.contains(out2, "disabled"))
}

@(test)
test_video_gen_disabled_env :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_VIDEO_GEN", context.temp_allocator)
	_ = os.set_env("AETHER_NO_VIDEO_GEN", "1")
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_NO_VIDEO_GEN")
		} else {
			_ = os.set_env("AETHER_NO_VIDEO_GEN", prev)
		}
	}
	testing.expect(t, !video_gen_enabled())
	out := handle_image_to_video({}, `{"image":"/a.jpg"}`, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "disabled"))
	out2 := handle_reference_to_video(
		{},
		`{"prompt":"x","images":["/a.jpg","/b.jpg"]}`,
		context.allocator,
	)
	defer delete(out2)
	testing.expect(t, strings.contains(out2, "disabled"))
}

@(test)
test_save_video_bytes :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-video-test-%d", os.get_pid())
	_ = os.make_directory(dir)
	defer os.remove_all(dir)
	prev := os.get_env("AETHER_VIDEO_DIR", context.temp_allocator)
	_ = os.set_env("AETHER_VIDEO_DIR", dir)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_VIDEO_DIR")
		} else {
			_ = os.set_env("AETHER_VIDEO_DIR", prev)
		}
	}
	data := transmute([]byte)string("fake-mp4-bytes")
	path, rel, err := save_video_bytes(data, context.allocator)
	defer delete(path)
	testing.expect(t, err == "")
	testing.expect(t, strings.has_prefix(rel, "videos/"))
	testing.expect(t, strings.has_suffix(path, ".mp4"))
}

// silence
_ :: fmt
