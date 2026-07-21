// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

// video_gen — Grok-shaped Imagine video tools (thin vertical slice).
// image_to_video + reference_to_video share start → poll → download → save.
// Reference: crates/codegen/xai-grok-tools/.../video_gen/mod.rs

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"
import "aether:core"
import "aether:tools"

VIDEO_I2V_MODEL :: "grok-imagine-video-1.5-preview"
VIDEO_R2V_MODEL :: "grok-imagine-video"
VIDEO_START_TIMEOUT_S :: 60
VIDEO_POLL_DEADLINE_S :: 300
VIDEO_POLL_INTERVAL_S :: 5
VIDEO_POLL_REQUEST_TIMEOUT_S :: 30
VIDEO_DOWNLOAD_TIMEOUT_S :: 120
DEFAULT_VIDEO_DURATION :: 6
DEFAULT_VIDEO_RESOLUTION :: "480p"

g_video_mu:  sync.Mutex
g_video_ctr: int

// video_gen_enabled: opt-out AETHER_NO_VIDEO_GEN=1
video_gen_enabled :: proc() -> bool {
	if core.feature_killed("AETHER_NO_VIDEO_GEN") {
		return false
	}
	return true
}

// normalize_video_resolution: 480p|720p (default 480p).
normalize_video_resolution :: proc(s: string) -> (string, string /* err */) {
	t := strings.trim_space(s)
	if t == "" {
		return DEFAULT_VIDEO_RESOLUTION, ""
	}
	low := strings.to_lower(t, context.temp_allocator)
	switch low {
	case "480p", "480":
		return "480p", ""
	case "720p", "720":
		return "720p", ""
	}
	return "", fmt.tprintf("resolution_name must be 480p or 720p (got %s)", t)
}

// normalize_video_aspect: r2v only; allowed set from Grok.
normalize_video_aspect :: proc(s: string) -> (string, string /* err */) {
	t := strings.trim_space(s)
	if t == "" {
		return "16:9", ""
	}
	switch t {
	case "1:1", "16:9", "9:16", "3:2", "2:3":
		return t, ""
	}
	return "", fmt.tprintf(
		"aspect_ratio must be one of: 1:1, 16:9, 9:16, 3:2, 2:3 (got %s)",
		t,
	)
}

// parse_video_duration: missing → 6; only 6 or 10 allowed when present.
parse_video_duration :: proc(obj: json.Object) -> (int, string /* err */) {
	v, ok := obj["duration"]
	if !ok {
		return DEFAULT_VIDEO_DURATION, ""
	}
	d := 0
	#partial switch n in v {
	case json.Integer:
		d = int(n)
	case json.Float:
		d = int(n)
	case json.String:
		parsed, pok := tools.parse_positive_int(string(n))
		if !pok {
			return 0, fmt.tprintf("duration must be 6 or 10 (got %s)", string(n))
		}
		d = parsed
	case json.Null:
		return DEFAULT_VIDEO_DURATION, ""
	case:
		return 0, "duration must be 6 or 10"
	}
	if d == 6 || d == 10 {
		return d, ""
	}
	return 0, fmt.tprintf("duration must be 6 or 10 (got %d)", d)
}

// resolve_video_image_ref: https pass-through or image_edit resolve (path/data URL).
resolve_video_image_ref :: proc(ref: string, allocator := context.allocator) -> (string, string /* err */) {
	v := strings.trim_space(ref)
	if v == "" {
		return "", "empty image reference"
	}
	if strings.has_prefix(v, "https://") || strings.has_prefix(v, "http://") {
		// Grok allows https; keep http for completeness (download is separate).
		return strings.clone(v, allocator), ""
	}
	return resolve_image_ref(v, allocator)
}

// video_output_dir: AETHER_VIDEO_DIR or {sessions}/videos
video_output_dir :: proc(allocator := context.allocator) -> string {
	if v := os.get_env("AETHER_VIDEO_DIR", context.temp_allocator); v != "" {
		return strings.clone(v, allocator)
	}
	base := core.aether_sessions_dir("", context.temp_allocator)
	joined, _ := filepath.join({base, "videos"}, allocator)
	return joined
}

next_video_path :: proc(allocator := context.allocator) -> (abs_path: string, rel: string, err: string) {
	dir := video_output_dir(context.temp_allocator)
	if !core.ensure_dir(dir) {
		return "", "", fmt.tprintf("cannot create video dir %s", dir)
	}
	sync.mutex_lock(&g_video_mu)
	g_video_ctr += 1
	n := g_video_ctr
	sync.mutex_unlock(&g_video_mu)
	name := fmt.tprintf("%d.mp4", n)
	path, jerr := filepath.join({dir, name}, allocator)
	if jerr != nil {
		return "", "", "path join failed"
	}
	return path, fmt.tprintf("videos/%d.mp4", n), ""
}

save_video_bytes :: proc(data: []byte, allocator := context.allocator) -> (path: string, rel: string, err: string) {
	p, r, e := next_video_path(allocator)
	if e != "" {
		return "", "", e
	}
	if werr := os.write_entire_file(p, data); werr != nil {
		delete(p)
		return "", "", fmt.tprintf("write failed: %v", werr)
	}
	return p, r, ""
}

// parse_video_start_response extracts request_id from start JSON.
parse_video_start_response :: proc(body: string) -> (request_id: string, err: string) {
	val, perr := json.parse(transmute([]byte)body, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil {
		return "", "invalid JSON from video generation start"
	}
	obj, ok := val.(json.Object)
	if !ok {
		return "", "video start response is not an object"
	}
	if ev, has := obj["error"]; has {
		return "", fmt.tprintf("video API error: %s", tools_json_snippet(ev, 200))
	}
	id := tools.jstr(obj, "request_id")
	if id == "" {
		id = tools.jstr(obj, "id")
	}
	if strings.trim_space(id) == "" {
		return "", "no request_id in video generation start response"
	}
	return strings.clone(id, context.temp_allocator), ""
}

// parse_video_poll_response → status + optional download URL.
parse_video_poll_response :: proc(body: string) -> (status: string, video_url: string, err: string) {
	val, perr := json.parse(transmute([]byte)body, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil {
		return "", "", "invalid JSON from video poll"
	}
	obj, ok := val.(json.Object)
	if !ok {
		return "", "", "video poll response is not an object"
	}
	if ev, has := obj["error"]; has {
		return "", "", fmt.tprintf("video poll API error: %s", tools_json_snippet(ev, 200))
	}
	status = tools.jstr(obj, "status")
	if status == "" {
		status = "unknown"
	}
	// video.url or video_url top-level
	if vv, has := obj["video"]; has {
		if vo, is_o := vv.(json.Object); is_o {
			video_url = tools.jstr(vo, "url")
		}
	}
	if video_url == "" {
		video_url = tools.jstr(obj, "video_url")
	}
	return status, video_url, ""
}

// tools_json_snippet is defined in image_gen; reuse if present else local.
// (image_gen may export via package agent — same package, so call extract path.)

// video_gen_run: shared start/poll/download/save.
// image_url set for i2v; ref_urls for r2v (mutually exclusive).
video_gen_run :: proc(
	creds: Credentials,
	model: string,
	prompt: string,
	duration: int,
	resolution: string,
	aspect_ratio: string, // empty = omit
	image_url: string, // empty if r2v
	ref_urls: []string, // empty if i2v
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

	// Build start body
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b,
		`{"model":%q,"prompt":%q,"duration":%d,"resolution":%q`,
		model,
		prompt,
		duration,
		resolution,
	)
	if aspect_ratio != "" {
		fmt.sbprintf(&b, `,"aspect_ratio":%q`, aspect_ratio)
	}
	if image_url != "" {
		fmt.sbprintf(&b, `,"image":{"url":%q}`, image_url)
	}
	if len(ref_urls) > 0 {
		strings.write_string(&b, `,"reference_images":[`)
		for u, i in ref_urls {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			fmt.sbprintf(&b, `{"url":%q}`, u)
		}
		strings.write_byte(&b, ']')
	}
	strings.write_byte(&b, '}')
	body := strings.to_string(b)

	start_url := fmt.tprintf("%s/videos/generations", base)
	headers := []string{
		fmt.tprintf("Authorization: Bearer %s", bearer),
		"Content-Type: application/json",
	}
	start_opts := Http_Opts {
		connect_timeout_s = 30,
		timeout_s         = VIDEO_START_TIMEOUT_S,
	}
	resp, herr := http_post_json(start_url, headers, body, context.allocator, start_opts)
	if herr != .None {
		return fmt.aprintf("error: video generation start failed (%v)", herr, allocator = allocator)
	}
	defer delete(resp.body)
	if resp.status < 200 || resp.status >= 300 {
		snippet := resp.body
		if len(snippet) > 240 {
			snippet = snippet[:240]
		}
		return fmt.aprintf(
			"error: video generation start HTTP %d: %s",
			resp.status,
			snippet,
			allocator = allocator,
		)
	}
	request_id, serr := parse_video_start_response(resp.body)
	if serr != "" {
		return fmt.aprintf("error: %s", serr, allocator = allocator)
	}

	// Poll until done / failed / deadline
	poll_url := fmt.tprintf("%s/videos/%s", base, request_id)
	poll_opts := Http_Opts {
		connect_timeout_s = 15,
		timeout_s         = VIDEO_POLL_REQUEST_TIMEOUT_S,
	}
	poll_start := time.now()
	poll_deadline := time.Duration(VIDEO_POLL_DEADLINE_S) * time.Second

	video_url := ""
	for {
		time.sleep(time.Duration(VIDEO_POLL_INTERVAL_S) * time.Second)
		if time.since(poll_start) > poll_deadline {
			return fmt.aprintf(
				"error: video generation did not complete within %ds (request_id=%s)",
				VIDEO_POLL_DEADLINE_S,
				request_id,
				allocator = allocator,
			)
		}
		presp, perr := http_get(poll_url, headers, context.allocator, poll_opts)
		if perr != .None {
			// transient — continue polling until deadline
			continue
		}
		// accept 200 and 202
		if presp.status != 200 && presp.status != 202 {
			snippet := presp.body
			if len(snippet) > 200 {
				snippet = snippet[:200]
			}
			status_code := presp.status
			delete(presp.body)
			// non-retryable-ish: still allow a few failures via deadline
			if status_code >= 400 && status_code < 500 && status_code != 429 {
				return fmt.aprintf(
					"error: video poll HTTP %d: %s",
					status_code,
					snippet,
					allocator = allocator,
				)
			}
			continue
		}
		st, vurl, parse_err := parse_video_poll_response(presp.body)
		delete(presp.body)
		if parse_err != "" {
			continue
		}
		switch st {
		case "done", "completed", "succeeded":
			if vurl == "" {
				return fmt.aprintf(
					"error: video generation completed but no download URL (request_id=%s)",
					request_id,
					allocator = allocator,
				)
			}
			video_url = strings.clone(vurl, context.temp_allocator)
		case "failed":
			return fmt.aprintf(
				"error: video generation failed on server (request_id=%s)",
				request_id,
				allocator = allocator,
			)
		case "expired":
			return fmt.aprintf(
				"error: video generation request expired (request_id=%s)",
				request_id,
				allocator = allocator,
			)
		case:
			// pending / processing / queued
			continue
		}
		break
	}

	// Download video bytes (no auth — presigned/CDN URL)
	dl_opts := Http_Opts {
		connect_timeout_s = 30,
		timeout_s         = VIDEO_DOWNLOAD_TIMEOUT_S,
	}
	dresp, derr := http_get(video_url, nil, context.allocator, dl_opts)
	if derr != .None {
		return fmt.aprintf("error: video download failed (%v)", derr, allocator = allocator)
	}
	defer delete(dresp.body)
	if dresp.status < 200 || dresp.status >= 300 {
		return fmt.aprintf(
			"error: video download HTTP %d",
			dresp.status,
			allocator = allocator,
		)
	}
	if len(dresp.body) == 0 {
		return strings.clone("error: video download returned empty body", allocator)
	}
	// body is string; convert to bytes without re-alloc if possible
	raw := transmute([]byte)dresp.body
	path, rel, werr := save_video_bytes(raw, allocator)
	if werr != "" {
		return fmt.aprintf("error: %s", werr, allocator = allocator)
	}
	return fmt.aprintf(
		"Video generated and saved to %s.\npath: %s\nrelative: %s\nrequest_id: %s\n\nRefer to the short path (%s) when talking to the user. Do not re-display or describe the video content.",
		path,
		path,
		rel,
		request_id,
		rel,
		allocator = allocator,
	)
}

// handle_image_to_video — model tool entrypoint.
handle_image_to_video :: proc(
	creds: Credentials,
	arguments_json: string,
	allocator := context.allocator,
) -> string {
	if !video_gen_enabled() {
		return strings.clone("error: video tools disabled (AETHER_NO_VIDEO_GEN=1)", allocator)
	}
	obj, ok := tools.json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	image := strings.trim_space(tools.jstr(obj, "image"))
	if image == "" {
		return strings.clone("error: image is required for image_to_video", allocator)
	}
	prompt := tools.jstr(obj, "prompt") // optional
	duration, derr := parse_video_duration(obj)
	if derr != "" {
		return fmt.aprintf("error: %s", derr, allocator = allocator)
	}
	res_raw := tools.jstr(obj, "resolution_name")
	if res_raw == "" {
		res_raw = tools.jstr(obj, "resolution")
	}
	res, rerr := normalize_video_resolution(res_raw)
	if rerr != "" {
		return fmt.aprintf("error: %s", rerr, allocator = allocator)
	}
	url, uerr := resolve_video_image_ref(image, context.temp_allocator)
	if uerr != "" {
		return fmt.aprintf("error: %s", uerr, allocator = allocator)
	}
	return video_gen_run(
		creds,
		VIDEO_I2V_MODEL,
		prompt,
		duration,
		res,
		"", // no aspect for i2v
		url,
		nil,
		allocator,
	)
}

// handle_imagine_video_slash: host /imagine-video <image-ref> [prompt…]
// image-ref: path, data URL, or [Image #N]. Optional prompt after first token.
// For [Image #N] with spaces, first token is the whole bracket form.
handle_imagine_video_slash :: proc(arg: string, allocator := context.allocator) -> string {
	if !video_gen_enabled() {
		return strings.clone("aether: video tools disabled (AETHER_NO_VIDEO_GEN=1)", allocator)
	}
	a := strings.trim_space(arg)
	if a == "" {
		return strings.clone(
			"Usage: /imagine-video <image-ref> [prompt…]\n" +
			"  image-ref: path, https URL, data URL, or [Image #N]\n" +
			"Requires XAI_API_KEY (or session with API access). Opt-out: AETHER_NO_VIDEO_GEN=1",
			allocator,
		)
	}
	image := ""
	prompt := ""
	// Bracket token: [Image #N] may contain spaces
	if strings.has_prefix(a, "[") {
		if end := strings.index_byte(a, ']'); end >= 0 {
			image = strings.trim_space(a[:end + 1])
			prompt = strings.trim_space(a[end + 1:])
		} else {
			return strings.clone("aether: unclosed [Image #N] reference", allocator)
		}
	} else {
		// first field = image, rest = prompt
		sp := strings.index_byte(a, ' ')
		if sp < 0 {
			image = a
		} else {
			image = strings.trim_space(a[:sp])
			prompt = strings.trim_space(a[sp + 1:])
		}
	}
	if image == "" {
		return strings.clone("aether: image reference required", allocator)
	}

	creds, cerr := resolve_credentials(context.temp_allocator)
	if cerr != "" {
		return fmt.aprintf("aether: %s", cerr, allocator = allocator)
	}

	// Build tool JSON (escape via json_escape from chat.odin)
	img_e := json_escape(image, context.temp_allocator)
	if prompt != "" {
		pr_e := json_escape(prompt, context.temp_allocator)
		args := fmt.tprintf(`{"image":"%s","prompt":"%s"}`, img_e, pr_e)
		return handle_image_to_video(creds, args, allocator)
	}
	args := fmt.tprintf(`{"image":"%s"}`, img_e)
	return handle_image_to_video(creds, args, allocator)
}

// handle_reference_to_video — model tool entrypoint.
handle_reference_to_video :: proc(
	creds: Credentials,
	arguments_json: string,
	allocator := context.allocator,
) -> string {
	if !video_gen_enabled() {
		return strings.clone("error: video tools disabled (AETHER_NO_VIDEO_GEN=1)", allocator)
	}
	obj, ok := tools.json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	prompt := strings.trim_space(tools.jstr(obj, "prompt"))
	if prompt == "" {
		return strings.clone("error: prompt is required for reference_to_video", allocator)
	}
	imgs, ierr := parse_image_array(arguments_json, context.allocator)
	defer free_image_strings(&imgs)
	if ierr != "" {
		return fmt.aprintf("error: %s", ierr, allocator = allocator)
	}
	if len(imgs) < 2 {
		return strings.clone(
			"error: reference_to_video requires at least 2 images (use image_to_video for a single source)",
			allocator,
		)
	}
	if len(imgs) > MAX_IMAGE_REFS {
		return fmt.aprintf(
			"error: at most %d reference images allowed",
			MAX_IMAGE_REFS,
			allocator = allocator,
		)
	}
	duration, derr := parse_video_duration(obj)
	if derr != "" {
		return fmt.aprintf("error: %s", derr, allocator = allocator)
	}
	res_raw := tools.jstr(obj, "resolution_name")
	if res_raw == "" {
		res_raw = tools.jstr(obj, "resolution")
	}
	res, rerr := normalize_video_resolution(res_raw)
	if rerr != "" {
		return fmt.aprintf("error: %s", rerr, allocator = allocator)
	}
	aspect, aerr := normalize_video_aspect(tools.jstr(obj, "aspect_ratio"))
	if aerr != "" {
		return fmt.aprintf("error: %s", aerr, allocator = allocator)
	}
	urls := make([dynamic]string, 0, len(imgs), context.temp_allocator)
	for r in imgs {
		u, e := resolve_video_image_ref(r, context.temp_allocator)
		if e != "" {
			return fmt.aprintf("error: %s", e, allocator = allocator)
		}
		append(&urls, u)
	}
	return video_gen_run(
		creds,
		VIDEO_R2V_MODEL,
		prompt,
		duration,
		res,
		aspect,
		"",
		urls[:],
		allocator,
	)
}
