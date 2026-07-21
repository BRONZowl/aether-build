// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tools

// read_file — Grok-shaped text / binary / image read.
// Reference: crates/.../grok_build/read_file + util/binary.rs
// Tool results are text-only (no multimodal parts); images → metadata + optional small data URL.

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

DEFAULT_READ_LIMIT :: 1000
// Max base64 chars to inline for images in tool text (~9KB raw).
MAX_INLINE_IMAGE_B64 :: 12_000
BINARY_SAMPLE :: 8192

// Common non-image binary extensions (png/jpeg handled as image first).
// Static array — Odin disables dynamic map compound literals by default.
BINARY_EXTS :: []string{
	"7z", "a", "avi", "bin", "class", "dat", "dll", "doc", "docx", "dylib",
	"exe", "gz", "ico", "jar", "lib", "mov", "mp3", "mp4", "o", "obj",
	"pyc", "pyd", "rar", "so", "tar", "wasm", "xls", "xlsx", "zip",
}

is_binary_ext :: proc(ext: string) -> bool {
	for e in BINARY_EXTS {
		if e == ext {
			return true
		}
	}
	return false
}

detect_image_kind :: proc(data: []byte) -> string {
	if len(data) >= 3 && data[0] == 0xff && data[1] == 0xd8 && data[2] == 0xff {
		return "image/jpeg"
	}
	if len(data) >= 8 &&
	   data[0] == 0x89 && data[1] == 0x50 && data[2] == 0x4e && data[3] == 0x47 {
		return "image/png"
	}
	if len(data) >= 6 &&
	   data[0] == 'G' && data[1] == 'I' && data[2] == 'F' {
		return "image/gif"
	}
	if len(data) >= 12 &&
	   data[0] == 'R' && data[1] == 'I' && data[2] == 'F' && data[3] == 'F' &&
	   data[8] == 'W' && data[9] == 'E' && data[10] == 'B' && data[11] == 'P' {
		return "image/webp"
	}
	return ""
}

file_ext_lower :: proc(path: string) -> string {
	ext := filepath.ext(path)
	if len(ext) > 0 && ext[0] == '.' {
		ext = ext[1:]
	}
	return strings.to_lower(ext, context.temp_allocator)
}

is_binary_bytes :: proc(ext: string, data: []byte) -> bool {
	if is_binary_ext(ext) {
		return true
	}
	if len(data) == 0 {
		return false
	}
	n := min(len(data), BINARY_SAMPLE)
	sample := data[:n]
	for b in sample {
		if b == 0 {
			return true
		}
	}
	// high control-char ratio
	non_print := 0
	for b in sample {
		if b < 9 || (b >= 14 && b <= 31) {
			non_print += 1
		}
	}
	return f64(non_print) / f64(n) > 0.3
}

tool_read_file :: proc(
	arguments_json: string,
	workspace: string,
	allocator := context.allocator,
) -> string {
	obj, ok := json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	target := jstr(obj, "target_file")
	if target == "" {
		target = jstr(obj, "path")
	}
	if target == "" {
		return strings.clone("error: target_file is required", allocator)
	}
	offset_raw := jint(obj, "offset", 1)
	limit := jint(obj, "limit", DEFAULT_READ_LIMIT)
	if limit <= 0 {
		limit = DEFAULT_READ_LIMIT
	}

	abs, inside := resolve_in_workspace(workspace, target, context.temp_allocator)
	if !inside {
		return strings.clone("error: reads outside workspace are denied", allocator)
	}

	data, err := os.read_entire_file(abs, context.temp_allocator)
	if err != nil {
		return fmt.aprintf("error: cannot read %s: %v", target, err, allocator = allocator)
	}

	// Image by magic bytes first; corrupt image-ext files fall through to binary/text.
	mime := detect_image_kind(data)
	if mime != "" {
		return format_image_read(target, abs, mime, data, allocator)
	}

	ext := file_ext_lower(target)
	// PDF text extract via pdftotext (A1 residual) before binary reject
	if is_pdf_file(ext, data) {
		pages := jstr(obj, "pages")
		return format_pdf_read(target, abs, pages, offset_raw, limit, allocator)
	}
	// PPTX text extract via unzip + a:t scrape (A1 residual)
	if is_pptx_file(ext, data) {
		pages := jstr(obj, "pages")
		return format_pptx_read(target, abs, pages, offset_raw, limit, allocator)
	}

	if is_binary_bytes(ext, data) {
		return fmt.aprintf(
			"error: cannot read binary file: %s (use shell tools or convert to text)",
			target,
			allocator = allocator,
		)
	}

	if len(data) == 0 {
		return strings.clone("(empty file)", allocator)
	}

	return format_line_numbered_text(string(data), offset_raw, limit, allocator)
}

// is_pdf_file: .pdf extension or %PDF magic.
is_pdf_file :: proc(ext: string, data: []byte) -> bool {
	if ext == "pdf" {
		return true
	}
	return len(data) >= 4 && data[0] == '%' && data[1] == 'P' && data[2] == 'D' && data[3] == 'F'
}

// is_pptx_file: .pptx extension (OLE .ppt not supported).
is_pptx_file :: proc(ext: string, data: []byte) -> bool {
	_ = data
	return ext == "pptx"
}

Pptx_Slide_Path :: struct {
	n:    int,
	path: string,
}

// extract_pptx_text: unzip slide XML parts and collect a:t / text runs.
// pages: same shape as PDF (1-based slide numbers); default 1-20.
extract_pptx_text :: proc(
	abs: string,
	first, last: int,
	allocator := context.allocator,
) -> (
	text: string,
	err: string,
) {
	// list members (-Z1 = one path per line when available)
	state, stdout, stderr, perr := os.process_exec(
		{command = {"unzip", "-Z1", abs}},
		context.temp_allocator,
	)
	if perr != nil || (state.exited && state.exit_code != 0 && len(stdout) == 0) {
		// fallback list
		state, stdout, stderr, perr = os.process_exec(
			{command = {"unzip", "-l", abs}},
			context.temp_allocator,
		)
		if perr != nil {
			return "", fmt.tprintf("unzip unavailable (%v)", perr)
		}
	}
	_ = stderr
	if state.exited && state.exit_code != 0 && len(stdout) == 0 {
		return "", fmt.tprintf("unzip failed (exit %d)", state.exit_code)
	}
	listing := string(stdout)
	slides := make([dynamic]Pptx_Slide_Path, 0, 16, context.temp_allocator)
	// lines from -Z1 are one path per line; -l has extra columns
	for raw_line in strings.split_lines(listing, context.temp_allocator) {
		line := strings.trim_space(raw_line)
		if line == "" {
			continue
		}
		// find ppt/slides/slideN.xml
		idx := strings.index(line, "ppt/slides/slide")
		if idx < 0 {
			continue
		}
		path := line[idx:]
		// trim trailing junk from unzip -l
		if sp := strings.index_byte(path, ' '); sp >= 0 {
			path = path[:sp]
		}
		if !strings.has_suffix(path, ".xml") {
			continue
		}
		// parse N
		rest := path[len("ppt/slides/slide"):]
		end := 0
		for end < len(rest) && rest[end] >= '0' && rest[end] <= '9' {
			end += 1
		}
		if end == 0 {
			continue
		}
		n, ok := parse_digits_pos(rest[:end])
		if !ok {
			continue
		}
		append(&slides, Pptx_Slide_Path{n = n, path = strings.clone(path, context.temp_allocator)})
	}
	if len(slides) == 0 {
		return "", "no slides found (not a pptx?)"
	}
	// sort by slide number (insertion sort — small N)
	for i in 1 ..< len(slides) {
		j := i
		for j > 0 && slides[j - 1].n > slides[j].n {
			slides[j - 1], slides[j] = slides[j], slides[j - 1]
			j -= 1
		}
	}

	b := strings.builder_make(allocator)
	shown := 0
	for s in slides {
		if first > 0 && s.n < first {
			continue
		}
		if last > 0 && s.n > last {
			continue
		}
		// extract part
		st2, body, _, perr2 := os.process_exec(
			{command = {"unzip", "-p", abs, s.path}},
			context.temp_allocator,
		)
		if perr2 != nil || (st2.exited && st2.exit_code != 0) {
			continue
		}
		plain := scrape_ooxml_text(string(body), context.temp_allocator)
		plain = strings.trim_space(plain)
		if plain == "" {
			continue
		}
		if shown > 0 {
			strings.write_string(&b, "\n\n")
		}
		fmt.sbprintf(&b, "--- slide %d ---\n%s", s.n, plain)
		shown += 1
	}
	if shown == 0 {
		return "", "no extractable text in slides"
	}
	return strings.to_string(b), ""
}

// scrape_ooxml_text: collect text from a:t… and strip tags crudely.
scrape_ooxml_text :: proc(xml: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	// prefer a:t runs (DrawingML text)
	search := xml
	for {
		// <a:t ...>TEXT</a:t> or <a:t>TEXT</a:t>
		open := strings.index(search, "<a:t")
		if open < 0 {
			break
		}
		gt := strings.index_byte(search[open:], '>')
		if gt < 0 {
			break
		}
		start := open + gt + 1
		close := strings.index(search[start:], "</a:t>")
		if close < 0 {
			break
		}
		chunk := search[start:start + close]
		chunk = xml_decode_entities(chunk, context.temp_allocator)
		if strings.builder_len(b) > 0 {
			// separate runs with space if needed
			prev := strings.to_string(b)
			if len(prev) > 0 && prev[len(prev) - 1] != '\n' && prev[len(prev) - 1] != ' ' {
				strings.write_byte(&b, ' ')
			}
		}
		strings.write_string(&b, chunk)
		search = search[start + close + len("</a:t>"):]
	}
	out := strings.to_string(b)
	if strings.trim_space(out) != "" {
		return out
	}
	// fallback: strip all tags
	return strip_xml_tags(xml, allocator)
}

xml_decode_entities :: proc(s: string, allocator := context.allocator) -> string {
	r, _ := strings.replace_all(s, "&lt;", "<", context.temp_allocator)
	r, _ = strings.replace_all(r, "&gt;", ">", context.temp_allocator)
	r, _ = strings.replace_all(r, "&amp;", "&", context.temp_allocator)
	r, _ = strings.replace_all(r, "&quot;", "\"", context.temp_allocator)
	r, _ = strings.replace_all(r, "&apos;", "'", context.temp_allocator)
	return strings.clone(r, allocator)
}

strip_xml_tags :: proc(xml: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	i := 0
	for i < len(xml) {
		if xml[i] == '<' {
			// skip tag
			for i < len(xml) && xml[i] != '>' {
				i += 1
			}
			if i < len(xml) {
				i += 1
			}
			// newline after block-ish tags
			continue
		}
		strings.write_byte(&b, xml[i])
		i += 1
	}
	return strings.to_string(b)
}

// format_pptx_read: extract slides → line window.
format_pptx_read :: proc(
	target, abs, pages: string,
	offset_raw, limit: int,
	allocator := context.allocator,
) -> string {
	first, last, has_pages := parse_pdf_pages(pages) // same 1-5 / 3 / 10- syntax
	if !has_pages {
		first, last = 1, 20
	} else if last == 0 {
		last = first + 19
	} else if last - first + 1 > 20 {
		last = first + 19
	}

	text, err := extract_pptx_text(abs, first, last, context.temp_allocator)
	if err != "" {
		return fmt.aprintf(
			"error: cannot extract PPTX text from %s: %s",
			target,
			err,
			allocator = allocator,
		)
	}
	body := format_line_numbered_text(text, offset_raw, limit, context.temp_allocator)
	return fmt.aprintf(
		"[pptx file]\npath: %s\nslides: %d-%d (unzip a:t)\n\n%s",
		target,
		first,
		last,
		body,
		allocator = allocator,
	)
}

// parse_digits_pos: positive int from decimal digits only.
parse_digits_pos :: proc(s: string) -> (int, bool) {
	if s == "" {
		return 0, false
	}
	n := 0
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch < '0' || ch > '9' {
			return 0, false
		}
		n = n * 10 + int(ch - '0')
	}
	return n, true
}

// parse_pdf_pages: Grok-shaped "1-5", "3", "10-" → first/last page (1-based; 0 = open end).
parse_pdf_pages :: proc(pages: string) -> (first, last: int, ok: bool) {
	s := strings.trim_space(pages)
	if s == "" {
		return 0, 0, false
	}
	// "N-" open end
	if strings.has_suffix(s, "-") && len(s) > 1 {
		n, pok := parse_digits_pos(s[:len(s) - 1])
		if !pok || n < 1 {
			return 0, 0, false
		}
		return n, 0, true
	}
	// "N-M"
	if dash := strings.index_byte(s, '-'); dash > 0 {
		a, ok1 := parse_digits_pos(s[:dash])
		b, ok2 := parse_digits_pos(s[dash + 1:])
		if !ok1 || !ok2 || a < 1 || b < a {
			return 0, 0, false
		}
		return a, b, true
	}
	// single page
	n, pok := parse_digits_pos(s)
	if !pok || n < 1 {
		return 0, 0, false
	}
	return n, n, true
}

// extract_pdf_text runs pdftotext -layout [-f N] [-l M] path -.
// Returns text or err message (not empty if ok=false).
extract_pdf_text :: proc(
	abs: string,
	first, last: int,
	allocator := context.allocator,
) -> (
	text: string,
	err: string,
) {
	// require pdftotext on PATH
	args := make([dynamic]string, 0, 10, context.temp_allocator)
	append(&args, "pdftotext")
	append(&args, "-layout")
	append(&args, "-enc", "UTF-8")
	if first > 0 {
		append(&args, "-f", fmt.tprintf("%d", first))
	}
	if last > 0 {
		append(&args, "-l", fmt.tprintf("%d", last))
	}
	append(&args, abs, "-")

	state, stdout, stderr, perr := os.process_exec(
		{command = args[:]},
		context.temp_allocator,
	)
	if perr != nil {
		return "", fmt.tprintf(
			"pdftotext unavailable or failed to start (%v). Install poppler-utils.",
			perr,
		)
	}
	if !state.exited || state.exit_code != 0 {
		msg := strings.trim_space(string(stderr))
		if msg == "" {
			msg = fmt.tprintf("pdftotext exit %d", state.exit_code)
		}
		return "", msg
	}
	return strings.clone(string(stdout), allocator), ""
}

// format_pdf_read: extract → line-number window; header notes PDF.
format_pdf_read :: proc(
	target, abs, pages: string,
	offset_raw, limit: int,
	allocator := context.allocator,
) -> string {
	first, last, has_pages := parse_pdf_pages(pages)
	if !has_pages {
		// default: first 20 pages max (Grok-ish cap per call)
		first, last = 1, 20
	} else if last == 0 {
		// open end: cap at first+19
		last = first + 19
	} else if last - first + 1 > 20 {
		last = first + 19
	}

	text, err := extract_pdf_text(abs, first, last, context.temp_allocator)
	if err != "" {
		return fmt.aprintf(
			"error: cannot extract PDF text from %s: %s",
			target,
			err,
			allocator = allocator,
		)
	}
	if strings.trim_space(text) == "" {
		return fmt.aprintf(
			"[pdf file]\npath: %s\npages: %d-%d\n\n(empty extract — scanned image PDF?)\n",
			target,
			first,
			last,
			allocator = allocator,
		)
	}
	body := format_line_numbered_text(text, offset_raw, limit, context.temp_allocator)
	return fmt.aprintf(
		"[pdf file]\npath: %s\npages: %d-%d (pdftotext)\n\n%s",
		target,
		first,
		last,
		body,
		allocator = allocator,
	)
}

// format_line_numbered_text: offset/limit window with "N→line" (shared by text + PDF).
format_line_numbered_text :: proc(
	text: string,
	offset_raw, limit: int,
	allocator := context.allocator,
) -> string {
	lines := strings.split_lines(text, context.temp_allocator)
	total := len(lines)
	if total > 0 && lines[total - 1] == "" {
		total -= 1
	}
	if total == 0 {
		return strings.clone("(empty file)", allocator)
	}

	start_line := 1
	if offset_raw == 0 {
		start_line = 1
	} else if offset_raw > 0 {
		start_line = offset_raw
	} else {
		computed := total + offset_raw + 1
		if computed < 1 {
			computed = 1
		}
		start_line = computed
	}

	start := start_line - 1
	if start < 0 {
		start = 0
	}
	if start >= total {
		return strings.clone("(file has fewer lines than offset)", allocator)
	}
	end := start + limit
	if end > total {
		end = total
	}

	b := strings.builder_make(context.temp_allocator)
	for i in start ..< end {
		strings.write_string(&b, fmt.tprintf("%d→%s\n", i + 1, lines[i]))
	}
	return cap_output(strings.to_string(b), DEFAULT_OUTPUT_CAP, allocator)
}

format_image_read :: proc(
	target, abs, mime: string,
	data: []byte,
	allocator := context.allocator,
) -> string {
	// Prefer passthrough small jpeg/png for inline
	out_data := data
	out_mime := mime
	// If large, try to note size only; compress via magick if agent compress available
	// tools package: attempt base64 if small enough
	raw_n := len(data)
	enc, eerr := base64.encode(out_data, allocator = context.temp_allocator)
	b64_ok := eerr == nil
	b64_len := 0
	if b64_ok {
		b64_len = len(enc)
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, "[image file]\n")
	fmt.sbprintf(&b, "path: %s\n", target)
	fmt.sbprintf(&b, "absolute: %s\n", abs)
	fmt.sbprintf(&b, "mime: %s\n", out_mime)
	fmt.sbprintf(&b, "bytes: %d\n", raw_n)
	if b64_ok && b64_len <= MAX_INLINE_IMAGE_B64 {
		fmt.sbprintf(&b, "data_url: data:%s;base64,%s\n", out_mime, enc)
		strings.write_string(
			&b,
			"\n(Image inlined as data URL for multimodal-capable clients. Prefer absolute path with image_edit/image_to_video for transforms.)\n",
		)
	} else {
		strings.write_string(
			&b,
			"\n(not inlined — too large for tool text. Use absolute path with image_edit / image_to_video, or compress first.)\n",
		)
	}
	return strings.to_string(b)
}
