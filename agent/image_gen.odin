// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

// image_gen — Grok-shaped Imagine API tool (thin vertical slice).
// Reference: crates/codegen/xai-grok-tools/.../image_gen/mod.rs

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "aether:core"
import "aether:tools"

IMAGINE_MODEL :: "grok-imagine-image-quality"
IMAGE_GEN_TIMEOUT_S :: 300

g_image_mu:    sync.Mutex
g_image_ctr:   int

// image_gen_enabled: opt-out AETHER_NO_IMAGE_GEN=1
image_gen_enabled :: proc() -> bool {
	if core.feature_killed("AETHER_NO_IMAGE_GEN") {
		return false
	}
	return true
}

// normalize_aspect_ratio maps user input to API aspect_ratio (default 1:1 for auto).
normalize_aspect_ratio :: proc(s: string) -> string {
	t := strings.trim_space(s)
	if t == "" || strings.equal_fold(t, "auto") {
		return "1:1"
	}
	switch t {
	case "1:1", "16:9", "9:16", "4:3", "3:4", "3:2", "2:3", "2:1", "1:2":
		return t
	}
	// accept common aliases
	low := strings.to_lower(t, context.temp_allocator)
	switch low {
	case "square":
		return "1:1"
	case "landscape", "wide":
		return "16:9"
	case "portrait", "tall":
		return "9:16"
	}
	return "1:1"
}

// image_output_dir: AETHER_IMAGE_DIR or {sessions}/images
image_output_dir :: proc(allocator := context.allocator) -> string {
	return media_output_dir("AETHER_IMAGE_DIR", "images", allocator)
}

next_image_path :: proc(allocator := context.allocator) -> (abs_path: string, rel: string, err: string) {
	dir := image_output_dir(context.temp_allocator)
	return next_media_path(dir, "images", "jpg", &g_image_mu, &g_image_ctr, allocator)
}

// save_image_bytes writes JPEG bytes; registers [Image #N]; returns path + display n.
save_image_bytes :: proc(
	data: []byte,
	allocator := context.allocator,
) -> (
	path: string,
	rel: string,
	image_n: int,
	err: string,
) {
	p, r, e := next_image_path(allocator)
	if e != "" {
		return "", "", 0, e
	}
	if werr := os.write_entire_file(p, data); werr != nil {
		delete(p)
		return "", "", 0, fmt.tprintf("write failed: %v", werr)
	}
	n := image_reg_register(p)
	return p, r, n, ""
}

// extract_b64_json pulls first image b64 from Imagine API JSON body.
extract_b64_json :: proc(body: string) -> (b64: string, err: string) {
	val, perr := json.parse(transmute([]byte)body, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil {
		return "", "invalid JSON response from Imagine API"
	}
	obj, ok := val.(json.Object)
	if !ok {
		return "", "Imagine API response is not an object"
	}
	// error field
	if ev, has := obj["error"]; has {
		return "", fmt.tprintf("Imagine API error: %s", tools_json_snippet(ev, 200))
	}
	data_v, has_d := obj["data"]
	if !has_d {
		return "", "Imagine API response missing data[]"
	}
	arr, is_a := data_v.(json.Array)
	if !is_a || len(arr) == 0 {
		return "", "Imagine API data[] empty"
	}
	first, is_o := arr[0].(json.Object)
	if !is_o {
		return "", "Imagine API data[0] not an object"
	}
	// b64_json or b64Json
	if bv, has := first["b64_json"]; has {
		if s, is_s := bv.(json.String); is_s {
			return string(s), ""
		}
	}
	if bv, has := first["b64Json"]; has {
		if s, is_s := bv.(json.String); is_s {
			return string(s), ""
		}
	}
	return "", "Imagine API data[0] missing b64_json"
}

tools_json_snippet :: proc(v: json.Value, max: int) -> string {
	// crude
	#partial switch t in v {
	case json.String:
		s := string(t)
		if len(s) > max {
			return s[:max]
		}
		return s
	case json.Object:
		if m, has := t["message"]; has {
			if s, is_s := m.(json.String); is_s {
				return string(s)
			}
		}
	}
	return "request failed"
}

// decode_b64_image decodes standard base64 (with optional whitespace).
decode_b64_image :: proc(b64: string, allocator := context.allocator) -> ([]byte, string /* err */) {
	// strip whitespace/newlines
	clean := make([dynamic]u8, 0, len(b64), context.temp_allocator)
	for i in 0 ..< len(b64) {
		ch := b64[i]
		if ch == ' ' || ch == '\n' || ch == '\r' || ch == '\t' {
			continue
		}
		append(&clean, ch)
	}
	out, err := base64.decode(string(clean[:]), allocator = allocator)
	if err != nil {
		return nil, fmt.tprintf("base64 decode failed: %v", err)
	}
	return out, ""
}

// image_gen_api_base prefers API-key public base for Imagine.
image_gen_api_base :: proc(creds: Credentials, allocator := context.allocator) -> (base: string, err: string) {
	// Env override for Imagine host
	if v := os.get_env("AETHER_IMAGINE_BASE_URL", context.temp_allocator); v != "" {
		return strings.clone(strings.trim_right(v, "/"), allocator), ""
	}
	if creds.kind == .Api_Key {
		return strings.clone(strings.trim_right(creds.base_url, "/"), allocator), ""
	}
	// Session auth: try env key if present for Imagine only
	if key := os.get_env("XAI_API_KEY", context.temp_allocator); key != "" {
		return core.api_key_base_url(allocator), ""
	}
	if key := os.get_env("GROK_CODE_XAI_API_KEY", context.temp_allocator); key != "" {
		return core.api_key_base_url(allocator), ""
	}
	return "", "image_gen requires XAI_API_KEY (session-only auth not supported for Imagine in this slice)"
}

image_gen_bearer :: proc(creds: Credentials, allocator := context.allocator) -> (string, string /* err */) {
	if creds.kind == .Api_Key {
		return strings.clone(creds.bearer, allocator), ""
	}
	if key := os.get_env("XAI_API_KEY", context.temp_allocator); key != "" {
		return strings.clone(key, allocator), ""
	}
	if key := os.get_env("GROK_CODE_XAI_API_KEY", context.temp_allocator); key != "" {
		return strings.clone(key, allocator), ""
	}
	return "", "image_gen requires XAI_API_KEY"
}

// handle_image_gen is the model-facing tool entrypoint.
handle_image_gen :: proc(
	creds: Credentials,
	arguments_json: string,
	allocator := context.allocator,
) -> string {
	if !image_gen_enabled() {
		return strings.clone("error: image_gen disabled (AETHER_NO_IMAGE_GEN=1)", allocator)
	}
	obj, ok := tools.json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	prompt := strings.trim_space(tools.jstr(obj, "prompt"))
	if prompt == "" {
		return strings.clone("error: prompt is required", allocator)
	}
	aspect := normalize_aspect_ratio(tools.jstr(obj, "aspect_ratio"))
	return image_gen_run(creds, prompt, aspect, allocator)
}

// image_gen_run performs the API call + save (shared with /imagine).
image_gen_run :: proc(
	creds: Credentials,
	prompt: string,
	aspect_ratio: string,
	allocator := context.allocator,
) -> string {
	base, berr := image_gen_api_base(creds, context.temp_allocator)
	if berr != "" {
		return fmt.aprintf("error: %s", berr, allocator = allocator)
	}
	bearer, kerr := image_gen_bearer(creds, context.temp_allocator)
	if kerr != "" {
		return fmt.aprintf("error: %s", kerr, allocator = allocator)
	}
	// Escape prompt for JSON
	body := fmt.tprintf(
		`{"model":%q,"prompt":%q,"n":1,"aspect_ratio":%q,"resolution":"1k","response_format":"b64_json"}`,
		IMAGINE_MODEL,
		prompt,
		aspect_ratio,
	)
	// Odin %q may be fine for JSON strings
	url := fmt.tprintf("%s/images/generations", base)
	headers := []string{
		fmt.tprintf("Authorization: Bearer %s", bearer),
		"Content-Type: application/json",
	}
	opts := Http_Opts {
		connect_timeout_s = 30,
		timeout_s         = IMAGE_GEN_TIMEOUT_S,
	}
	resp, herr := http_post_json(url, headers, body, context.allocator, opts)
	if herr != .None {
		return fmt.aprintf(
			"error: Imagine API request failed (%v)",
			herr,
			allocator = allocator,
		)
	}
	defer delete(resp.body)
	if resp.status < 200 || resp.status >= 300 {
		snippet := resp.body
		if len(snippet) > 240 {
			snippet = snippet[:240]
		}
		return fmt.aprintf(
			"error: Imagine API HTTP %d: %s",
			resp.status,
			snippet,
			allocator = allocator,
		)
	}
	b64, eerr := extract_b64_json(resp.body)
	if eerr != "" {
		return fmt.aprintf("error: %s", eerr, allocator = allocator)
	}
	raw, derr := decode_b64_image(b64, context.allocator)
	if derr != "" {
		return fmt.aprintf("error: %s", derr, allocator = allocator)
	}
	defer delete(raw)
	path, rel, n, serr := save_image_bytes(raw, allocator)
	if serr != "" {
		return fmt.aprintf("error: %s", serr, allocator = allocator)
	}
	return fmt.aprintf(
		"Image generated.\npath: %s\nrelative: %s\nImage #%d\naspect_ratio: %s\n\nReference as [Image #%d] in image_edit / video tools, or use the absolute path.",
		path,
		rel,
		n,
		aspect_ratio,
		n,
		allocator = allocator,
	)
}

// handle_imagine_slash: host-side /imagine <prompt> (resolves creds internally).
handle_imagine_slash :: proc(arg: string, allocator := context.allocator) -> string {
	if !image_gen_enabled() {
		return strings.clone("aether: image_gen disabled (AETHER_NO_IMAGE_GEN=1)", allocator)
	}
	prompt := strings.trim_space(arg)
	if prompt == "" {
		return strings.clone(
			"Usage: /imagine <description>\nProvide a text description to generate an image.",
			allocator,
		)
	}
	creds, cerr := resolve_credentials(context.temp_allocator)
	if cerr != "" {
		return fmt.aprintf("aether: %s", cerr, allocator = allocator)
	}
	// Note: temp_allocator owns bearer clones for this call only; image_gen_run
	// does not retain creds strings after return.
	return image_gen_run(creds, prompt, "1:1", allocator)
}
