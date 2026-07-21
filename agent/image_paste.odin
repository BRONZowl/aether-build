// Package agent — multimodal paste: path / data URL / clipboard → [Image #N] (M1).
// Path paste and binary clipboard attach for TUI/REPL; chat vision expand separate.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "aether:core"

// is_image_extension: common still-image suffixes.
is_image_extension :: proc(path: string) -> bool {
	ext := strings.to_lower(filepath.ext(path), context.temp_allocator)
	switch ext {
	case ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tif", ".tiff":
		return true
	}
	return false
}

// looks_like_image_file: extension and/or magic; path must exist for magic check.
looks_like_image_file :: proc(path: string) -> bool {
	p := strings.trim_space(path)
	if p == "" {
		return false
	}
	if strings.has_prefix(p, "file://") {
		p = p[len("file://"):]
	}
	// tilde expand light
	if strings.has_prefix(p, "~/") {
		home := os.get_env("HOME", context.temp_allocator)
		if home != "" {
			p = fmt.tprintf("%s/%s", home, p[2:])
		}
	}
	if is_image_extension(p) {
		if os.exists(p) && !os.is_directory(p) {
			return true
		}
		// extension alone is not enough without file for attach — require exists
		return false
	}
	// no extension: sniff magic if readable and small-ish header
	if !os.exists(p) || os.is_directory(p) {
		return false
	}
	f, err := os.open(p)
	if err != nil {
		return false
	}
	defer os.close(f)
	buf: [16]byte
	n, _ := os.read(f, buf[:])
	if n < 3 {
		return false
	}
	return detect_image_mime(buf[:n]) != ""
}

// is_data_image_url: data:image/...;base64,...
is_data_image_url :: proc(s: string) -> bool {
	t := strings.trim_space(s)
	return strings.has_prefix(t, "data:image/") && strings.contains(t, ";base64,")
}

// normalize_image_paste_ref: strip file:// quotes; return path or data URL.
normalize_image_paste_ref :: proc(s: string, allocator := context.allocator) -> string {
	t := strings.trim_space(s)
	// strip matching quotes
	if len(t) >= 2 {
		if (t[0] == '"' && t[len(t) - 1] == '"') || (t[0] == '\'' && t[len(t) - 1] == '\'') {
			t = t[1:len(t) - 1]
		}
	}
	if strings.has_prefix(t, "file://") {
		t = t[len("file://"):]
	}
	if strings.has_prefix(t, "~/") {
		home := os.get_env("HOME", context.temp_allocator)
		if home != "" {
			return fmt.aprintf("%s/%s", home, t[2:], allocator = allocator)
		}
	}
	return strings.clone(t, allocator)
}

// try_attach_single_image_ref: if ref is image path/data URL, register and return label.
// ok=false → not an image attach candidate.
try_attach_single_image_ref :: proc(ref: string, allocator := context.allocator) -> (label: string, ok: bool) {
	r := normalize_image_paste_ref(ref, context.temp_allocator)
	if r == "" {
		return "", false
	}
	if is_data_image_url(r) {
		n := image_reg_register(r)
		if n < 1 {
			return "", false
		}
		return image_reg_label(n, allocator), true
	}
	if looks_like_image_file(r) {
		// store absolute-ish path
		n := image_reg_register(r)
		if n < 1 {
			return "", false
		}
		return image_reg_label(n, allocator), true
	}
	return "", false
}

// process_paste_for_images: rewrite paste text so image paths/lines become [Image #N].
// Whole paste = one image ref → single token (+ trailing space for chip UX).
// Multi-line: convert each image-only line; leave other lines as text.
// Returns owned string; attached = count registered.
process_paste_for_images :: proc(
	text: string,
	allocator := context.allocator,
) -> (
	out: string,
	attached: int,
) {
	if text == "" {
		return strings.clone("", allocator), 0
	}
	// single-line / whole-buffer path or data URL
	if !strings.contains(text, "\n") {
		if label, ok := try_attach_single_image_ref(text, context.temp_allocator); ok {
			return fmt.aprintf("%s ", label, allocator = allocator), 1
		}
		return strings.clone(text, allocator), 0
	}
	// multi-line: convert pure image lines
	lines := strings.split_lines(text, context.temp_allocator)
	b := strings.builder_make(allocator)
	n_att := 0
	for line, i in lines {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		if label, ok := try_attach_single_image_ref(line, context.temp_allocator); ok {
			strings.write_string(&b, label)
			n_att += 1
		} else {
			strings.write_string(&b, line)
		}
	}
	return strings.to_string(b), n_att
}

// save_clipboard_image_bytes writes PNG/JPEG bytes to session tmp and registers.
// Returns [Image #N] label or "" on failure.
save_clipboard_image_bytes :: proc(
	data: []byte,
	allocator := context.allocator,
) -> (
	label: string,
	ok: bool,
) {
	if len(data) < 8 {
		return "", false
	}
	mime := detect_image_mime(data)
	if mime == "" {
		// webp RIFF....WEBP
		if len(data) >= 12 &&
		   data[0] == 'R' &&
		   data[1] == 'I' &&
		   data[2] == 'F' &&
		   data[3] == 'F' &&
		   data[8] == 'W' &&
		   data[9] == 'E' &&
		   data[10] == 'B' &&
		   data[11] == 'P' {
			mime = "image/webp"
		}
	}
	if mime == "" {
		return "", false
	}
	ext := ".png"
	switch mime {
	case "image/jpeg":
		ext = ".jpg"
	case "image/webp":
		ext = ".webp"
	case "image/png":
		ext = ".png"
	}
	dir := aether_media_tmp_dir(context.temp_allocator)
	_ = os.make_directory_all(dir)
	name := fmt.tprintf("paste-%d%s", time.time_to_unix_nano(time.now()) % 1_000_000_000_000, ext)
	path, _ := filepath.join({dir, name}, context.temp_allocator)
	if werr := os.write_entire_file(path, data); werr != nil {
		return "", false
	}
	n := image_reg_register(path)
	if n < 1 {
		return "", false
	}
	return image_reg_label(n, allocator), true
}

// aether_media_tmp_dir: ~/.grok/aether/media-paste (or AETHER_MEDIA_DIR).
aether_media_tmp_dir :: proc(allocator := context.allocator) -> string {
	if v := os.get_env("AETHER_MEDIA_DIR", context.temp_allocator); v != "" {
		return strings.clone(v, allocator)
	}
	home := os.get_env("HOME", context.temp_allocator)
	if home == "" {
		home = "/tmp"
	}
	joined, _ := filepath.join({home, ".grok", "aether", "media-paste"}, allocator)
	return joined
}

// --- chat multimodal expand (M1 vision) ---

// content_image_token_indices finds 1-based N from [Image #N] in text (deduped order of first seen).
content_image_token_indices :: proc(text: string, allocator := context.allocator) -> [dynamic]int {
	out := make([dynamic]int, 0, 4, allocator)
	seen := make(map[int]bool, context.temp_allocator)
	i := 0
	for i < len(text) {
		// look for [Image #
		rest := text[i:]
		idx := strings.index(rest, "[Image #")
		if idx < 0 {
			break
		}
		start := i + idx
		j := start + len("[Image #")
		if j >= len(text) {
			break
		}
		// digits
		d0 := j
		for j < len(text) && text[j] >= '0' && text[j] <= '9' {
			j += 1
		}
		if j > d0 && j < len(text) && text[j] == ']' {
			n, pok := parse_image_token(text[start:j + 1])
			if pok && !seen[n] {
				seen[n] = true
				append(&out, n)
			}
			i = j + 1
		} else {
			i = start + 1
		}
	}
	return out
}

// write_user_content_json writes "content":... for a user message (string or multimodal array).
// Multimodal when [Image #N] present and resolve succeeds; opt-out AETHER_NO_MULTIMODAL=1.
write_user_content_json :: proc(b: ^strings.Builder, content: string) {
	if multimodal_disabled() || content == "" {
		strings.write_string(b, `,"content":"`)
		strings.write_string(b, json_escape(content, context.temp_allocator))
		strings.write_string(b, `"`)
		return
	}
	idxs := content_image_token_indices(content, context.temp_allocator)
	if len(idxs) == 0 {
		strings.write_string(b, `,"content":"`)
		strings.write_string(b, json_escape(content, context.temp_allocator))
		strings.write_string(b, `"`)
		return
	}
	// Collect resolved data URLs (OpenAI image_url parts)
	urls := make([dynamic]string, 0, len(idxs), context.temp_allocator)
	for n in idxs {
		label := image_reg_label(n, context.temp_allocator)
		url, err := resolve_image_ref(label, context.temp_allocator)
		if err != "" || url == "" {
			continue
		}
		append(&urls, url)
	}
	if len(urls) == 0 {
		// fallback string
		strings.write_string(b, `,"content":"`)
		strings.write_string(b, json_escape(content, context.temp_allocator))
		strings.write_string(b, `"`)
		return
	}
	// OpenAI-shaped multimodal content
	strings.write_string(b, `,"content":[`)
	strings.write_string(b, `{"type":"text","text":"`)
	strings.write_string(b, json_escape(content, context.temp_allocator))
	strings.write_string(b, `"}`)
	for url in urls {
		strings.write_string(b, `,{"type":"image_url","image_url":{"url":"`)
		strings.write_string(b, json_escape(url, context.temp_allocator))
		strings.write_string(b, `"}}`)
	}
	strings.write_byte(b, ']')
}

multimodal_disabled :: proc() -> bool {
	return core.feature_killed("AETHER_NO_MULTIMODAL")
}
