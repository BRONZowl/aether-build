// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

// image_compress — Grok-shaped reference re-encode under Imagine limits.
// Fast path: small JPEG/PNG pass-through. Else ImageMagick quality/size ladder.
// Reference: crates/.../image_edit compress_reference + util/image_compress.rs

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

// Shared with image_edit (same limits as Grok image_edit).
MAX_REF_RAW_BYTES :: 400 * 1024
MAX_REF_DIMENSION :: 768
MIN_REF_DIMENSION :: 256
MAX_REF_DECODE_PIXELS :: u64(12_000_000)

REF_QUALITY_STEPS := [4]int{80, 65, 50, 35}
REF_SIDE_STEPS := [5]int{768, 640, 512, 384, 256}

// find_magick_bin: AETHER_IMAGE_MAGICK → magick → convert.
find_magick_bin :: proc(allocator := context.allocator) -> string {
	if v := os.get_env("AETHER_IMAGE_MAGICK", context.temp_allocator); v != "" {
		return strings.clone(v, allocator)
	}
	// Prefer magick (IM7); fall back to convert (IM6).
	names := [2]string{"magick", "convert"}
	for name in names {
		if p := look_path(name, context.temp_allocator); p != "" {
			return strings.clone(p, allocator)
		}
	}
	return ""
}

look_path :: proc(name: string, allocator := context.allocator) -> string {
	if strings.contains(name, "/") {
		if os.exists(name) {
			return strings.clone(name, allocator)
		}
		return ""
	}
	path_env := os.get_env("PATH", context.temp_allocator)
	if path_env == "" {
		path_env = "/usr/bin:/bin"
	}
	parts := strings.split(path_env, ":", context.temp_allocator)
	for dir in parts {
		if dir == "" {
			continue
		}
		cand, _ := filepath.join({dir, name}, context.temp_allocator)
		if os.exists(cand) {
			return strings.clone(cand, allocator)
		}
	}
	return ""
}

// run_cmd_capture: run argv, capture stdout; return body + ok (exit 0).
// Used for identify; encode writes to a file path instead.
run_cmd_capture :: proc(
	argv: []string,
	allocator := context.allocator,
) -> (
	out: []byte,
	ok: bool,
) {
	if len(argv) == 0 {
		return nil, false
	}
	stdout_r, stdout_w, perr := os.pipe()
	if perr != nil {
		return nil, false
	}
	stderr_r, stderr_w, perr2 := os.pipe()
	if perr2 != nil {
		os.close(stdout_r)
		os.close(stdout_w)
		return nil, false
	}
	child, serr := os.process_start(
		{
			command = argv,
			stdout  = stdout_w,
			stderr  = stderr_w,
		},
	)
	os.close(stdout_w)
	os.close(stderr_w)
	if serr != nil {
		os.close(stdout_r)
		os.close(stderr_r)
		return nil, false
	}
	body := make([dynamic]byte, 0, 256, allocator)
	buf: [4096]u8
	stdout_done := false
	stderr_done := false
	exit_code := -1
	start := time.now()
	for !stdout_done || !stderr_done || exit_code < 0 {
		if time.since(start) > 30 * time.Second {
			_ = os.process_kill(child)
			break
		}
		if !stdout_done {
			has, _ := os.pipe_has_data(stdout_r)
			if has {
				n, rerr := os.read(stdout_r, buf[:])
				if n > 0 {
					append(&body, ..buf[:n])
				}
				if rerr == .EOF || rerr == .Broken_Pipe {
					stdout_done = true
				}
			}
		}
		if !stderr_done {
			has, _ := os.pipe_has_data(stderr_r)
			if has {
				n, rerr := os.read(stderr_r, buf[:])
				_ = n
				if rerr == .EOF || rerr == .Broken_Pipe {
					stderr_done = true
				}
			}
		}
		state, werr := os.process_wait(child, 10 * time.Millisecond)
		if werr == nil && state.exited {
			exit_code = state.exit_code
			// final drain
			for !stdout_done {
				n, rerr := os.read(stdout_r, buf[:])
				if n > 0 {
					append(&body, ..buf[:n])
				}
				if n == 0 || rerr == .EOF || rerr == .Broken_Pipe {
					stdout_done = true
				}
			}
			for !stderr_done {
				n, rerr := os.read(stderr_r, buf[:])
				_ = n
				if n == 0 || rerr == .EOF || rerr == .Broken_Pipe {
					stderr_done = true
				}
			}
		}
	}
	os.close(stdout_r)
	os.close(stderr_r)
	return body[:], exit_code == 0
}

// run_cmd_file: run argv that writes output to a path; ok if exit 0.
run_cmd_file :: proc(argv: []string) -> bool {
	if len(argv) == 0 {
		return false
	}
	// discard stdout/stderr
	devnull, derr := os.open("/dev/null", {.Write})
	if derr != nil {
		return false
	}
	defer os.close(devnull)
	child, serr := os.process_start(
		{
			command = argv,
			stdout  = devnull,
			stderr  = devnull,
		},
	)
	if serr != nil {
		return false
	}
	state, werr := os.process_wait(child, 60 * time.Second)
	if werr != nil {
		_ = os.process_kill(child)
		return false
	}
	return state.exited && state.exit_code == 0
}

// magick_identify_dims: width, height via identify -format %wx%h
magick_identify_dims :: proc(bin, input_path: string) -> (w, h: int, ok: bool) {
	argv: []string
	if strings.has_suffix(bin, "convert") || filepath.base(bin) == "convert" {
		argv = {bin, input_path, "-format", "%wx%h", "info:"}
	} else {
		argv = {bin, "identify", "-format", "%wx%h", input_path}
	}
	out, rok := run_cmd_capture(argv, context.temp_allocator)
	if !rok || len(out) == 0 {
		return 0, 0, false
	}
	s := strings.trim_space(string(out))
	// "123x456"
	x := strings.index_byte(s, 'x')
	if x <= 0 {
		return 0, 0, false
	}
	wi, wok := strconv.parse_int(s[:x])
	hi, hok := strconv.parse_int(s[x + 1:])
	if !wok || !hok || wi <= 0 || hi <= 0 {
		return 0, 0, false
	}
	return wi, hi, true
}

// magick_encode_jpeg: resize max side, quality Q → JPEG bytes
magick_encode_jpeg :: proc(
	bin, input_path: string,
	side, quality: int,
	allocator := context.allocator,
) -> (
	[]byte,
	bool,
) {
	geom := fmt.tprintf("%dx%d>", side, side)
	// Write to temp out file — more reliable than stdout for binary across IM versions
	out_path := fmt.tprintf("/tmp/aether-img-out-%d-%d-%d.jpg", os.get_pid(), side, quality)
	argv: []string
	if filepath.base(bin) == "convert" || strings.has_suffix(bin, "/convert") {
		argv = {
			bin,
			input_path,
			"-resize",
			geom,
			"-quality",
			fmt.tprintf("%d", quality),
			out_path,
		}
	} else {
		argv = {
			bin,
			input_path,
			"-resize",
			geom,
			"-quality",
			fmt.tprintf("%d", quality),
			out_path,
		}
	}
	if !run_cmd_file(argv) || !os.exists(out_path) {
		_ = os.remove(out_path)
		return nil, false
	}
	data, rerr := os.read_entire_file(out_path, allocator)
	_ = os.remove(out_path)
	if rerr != nil || len(data) == 0 {
		return nil, false
	}
	return data, true
}

// compress_reference: Grok-shaped pass-through or re-encode under limits.
// Returns owned out bytes (caller deletes) + mime ("image/jpeg"|"image/png").
compress_reference :: proc(
	raw: []byte,
	allocator := context.allocator,
) -> (
	out: []byte,
	mime: string,
	err: string,
) {
	if len(raw) == 0 {
		return nil, "", "image reference contained no data"
	}
	// Fast path: small JPEG/PNG
	if len(raw) <= MAX_REF_RAW_BYTES {
		m := detect_image_mime(raw)
		if m == "image/jpeg" || m == "image/png" {
			// clone so caller can always free consistently
			cp := make([]byte, len(raw), allocator)
			copy(cp, raw)
			return cp, m, ""
		}
	}

	bin := find_magick_bin(context.temp_allocator)
	if bin == "" {
		if len(raw) > MAX_REF_RAW_BYTES {
			return nil, "", fmt.tprintf(
				"image reference too large (%d bytes; max %d). Install ImageMagick (magick/convert) or resize/compress and retry.",
				len(raw),
				MAX_REF_RAW_BYTES,
			)
		}
		return nil, "", "image reference must be JPEG or PNG under 400KB, or install ImageMagick to re-encode other formats"
	}

	in_path := fmt.tprintf("/tmp/aether-img-in-%d.bin", os.get_pid())
	if werr := os.write_entire_file(in_path, raw); werr != nil {
		return nil, "", "failed to stage image for compression"
	}
	defer os.remove(in_path)

	// Dimension gate
	if w, h, iok := magick_identify_dims(bin, in_path); iok {
		if u64(w) * u64(h) > MAX_REF_DECODE_PIXELS {
			return nil, "", fmt.tprintf(
				"image reference is too large to process (%d×%d pixels)",
				w,
				h,
			)
		}
	}

	// Never upscale: start from MAX_REF_DIMENSION (resize 'SIDE>' only shrinks)
	for side in REF_SIDE_STEPS {
		if side < MIN_REF_DIMENSION {
			continue
		}
		for q in REF_QUALITY_STEPS {
			data, ok := magick_encode_jpeg(bin, in_path, side, q, context.temp_allocator)
			if !ok {
				continue
			}
			if len(data) <= MAX_REF_RAW_BYTES {
				cp := make([]byte, len(data), allocator)
				copy(cp, data)
				return cp, "image/jpeg", ""
			}
		}
	}
	return nil, "", fmt.tprintf(
		"could not compress image reference small enough for Imagine API (max %d bytes)",
		MAX_REF_RAW_BYTES,
	)
}
