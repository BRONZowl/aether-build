package agent

// image_edit — Grok-shaped Imagine /images/edits (thin vertical slice).
// Reference: crates/codegen/xai-grok-tools/.../image_edit/mod.rs
// Reuses image_gen auth, decode, and save helpers.

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "aether:tools"

MAX_IMAGE_REFS :: 7
// MAX_REF_RAW_BYTES defined in image_compress.odin (shared Grok limit).

// detect_image_mime: jpeg/png magic only.
detect_image_mime :: proc(data: []byte) -> string {
	if len(data) >= 3 && data[0] == 0xff && data[1] == 0xd8 && data[2] == 0xff {
		return "image/jpeg"
	}
	if len(data) >= 8 &&
	   data[0] == 0x89 &&
	   data[1] == 0x50 &&
	   data[2] == 0x4e &&
	   data[3] == 0x47 {
		return "image/png"
	}
	return ""
}

// resolve_image_ref → compressed data URL for Imagine edits.
// Accepts [Image #N] registry tokens, data:image/...;base64,..., or filesystem path.
// Large / non-JPEG-PNG refs re-encoded via ImageMagick when available.
resolve_image_ref :: proc(ref: string, allocator := context.allocator) -> (data_url: string, err: string) {
	v := strings.trim_space(ref)
	if v == "" {
		return "", "empty image reference"
	}
	// Attachment tokens first (Grok AttachedImages)
	resolved, is_tok, terr := image_reg_resolve_token(v, context.temp_allocator)
	if is_tok {
		if terr != "" {
			return "", terr
		}
		v = resolved
	}
	if strings.has_prefix(v, "file://") {
		v = v[len("file://"):]
	}
	raw: []byte
	if strings.has_prefix(v, "data:image/") {
		if !strings.contains(v, ";base64,") {
			return "", "image references only support base64 data URLs"
		}
		// decode payload after comma
		comma := strings.index_byte(v, ',')
		if comma < 0 || comma + 1 >= len(v) {
			return "", "malformed data URL in image reference"
		}
		b64 := v[comma + 1:]
		decoded, derr := decode_b64_image(b64, context.temp_allocator)
		if derr != "" {
			return "", derr
		}
		raw = decoded
	} else {
		// filesystem path
		data, rerr := os.read_entire_file(v, context.temp_allocator)
		if rerr != nil {
			return "", fmt.tprintf("image reference not readable: %s", v)
		}
		raw = data
	}
	compressed, mime, cerr := compress_reference(raw, context.temp_allocator)
	if cerr != "" {
		return "", cerr
	}
	enc, eerr := base64.encode(compressed, allocator = context.temp_allocator)
	if eerr != nil {
		return "", fmt.tprintf("base64 encode failed: %v", eerr)
	}
	return fmt.aprintf("data:%s;base64,%s", mime, enc, allocator = allocator), ""
}

// parse_image_array extracts image[] strings from tool JSON args.
parse_image_array :: proc(
	arguments_json: string,
	allocator := context.allocator,
) -> (
	images: [dynamic]string,
	err: string,
) {
	images = make([dynamic]string, 0, 4, allocator)
	obj, ok := tools.json_obj(arguments_json)
	if !ok {
		return images, "invalid JSON arguments"
	}
	iv, has := obj["image"]
	if !has {
		// also accept "images"
		iv, has = obj["images"]
	}
	if !has {
		return images, "image array is required"
	}
	// single string
	if s, is_s := iv.(json.String); is_s {
		append(&images, strings.clone(string(s), allocator))
		return images, ""
	}
	arr, is_a := iv.(json.Array)
	if !is_a {
		return images, "image must be a string or array of strings"
	}
	for item in arr {
		if s, is_s := item.(json.String); is_s {
			append(&images, strings.clone(string(s), allocator))
		}
	}
	return images, ""
}

free_image_strings :: proc(images: ^[dynamic]string) {
	for s in images {
		delete(s)
	}
	delete(images^)
	images^ = {}
}

// handle_image_edit — model tool entrypoint.
handle_image_edit :: proc(
	creds: Credentials,
	arguments_json: string,
	allocator := context.allocator,
) -> string {
	if !image_gen_enabled() {
		return strings.clone("error: image_edit disabled (AETHER_NO_IMAGE_GEN=1)", allocator)
	}
	obj, ok := tools.json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	prompt := strings.trim_space(tools.jstr(obj, "prompt"))
	if prompt == "" {
		return strings.clone("error: prompt is required", allocator)
	}
	imgs, ierr := parse_image_array(arguments_json, context.allocator)
	defer free_image_strings(&imgs)
	if ierr != "" {
		return fmt.aprintf("error: %s", ierr, allocator = allocator)
	}
	if len(imgs) == 0 {
		return strings.clone(
			"error: image_edit requires at least one reference image. Use image_gen for text-only generation.",
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
	aspect := normalize_aspect_ratio(tools.jstr(obj, "aspect_ratio"))
	return image_edit_run(creds, prompt, imgs[:], aspect, allocator)
}

image_edit_run :: proc(
	creds: Credentials,
	prompt: string,
	image_refs: []string,
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

	// Resolve refs to data URLs
	urls := make([dynamic]string, 0, len(image_refs), context.temp_allocator)
	for r in image_refs {
		u, e := resolve_image_ref(r, context.temp_allocator)
		if e != "" {
			return fmt.aprintf("error: %s", e, allocator = allocator)
		}
		append(&urls, u)
	}

	// Build JSON body (Grok: single → "image":{url}, multi → "images":[{url},…])
	b := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(
		&b,
		`{"model":%q,"prompt":%q,"n":1,"resolution":"1k","response_format":"b64_json"`,
		IMAGINE_MODEL,
		prompt,
	)
	if len(urls) == 1 {
		fmt.sbprintf(&b, `,"image":{"url":%q}`, urls[0])
	} else {
		strings.write_string(&b, `,"images":[`)
		for u, i in urls {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			fmt.sbprintf(&b, `{"url":%q}`, u)
		}
		fmt.sbprintf(&b, `],"aspect_ratio":%q`, aspect_ratio)
	}
	strings.write_byte(&b, '}')
	body := strings.to_string(b)

	url := fmt.tprintf("%s/images/edits", base)
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
		return fmt.aprintf("error: Imagine edit API request failed (%v)", herr, allocator = allocator)
	}
	defer delete(resp.body)
	if resp.status < 200 || resp.status >= 300 {
		snippet := resp.body
		if len(snippet) > 240 {
			snippet = snippet[:240]
		}
		return fmt.aprintf(
			"error: Imagine edit API HTTP %d: %s",
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
		"Image edited.\npath: %s\nrelative: %s\nImage #%d\nrefs: %d\n\nReference as [Image #%d] in later image_edit / video tools, or use the absolute path.",
		path,
		rel,
		n,
		len(image_refs),
		n,
		allocator = allocator,
	)
}
