#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:encoding/base64"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:terminal"
import "core:time"

MAX_CLIPBOARD_BYTES :: 1_000_000
// Terminal OSC 52 payloads are often limited; keep well under common caps.
OSC52_MAX_BYTES :: 100_000

// copy_to_clipboard copies text using the first available backend.
// Returns a short status string for the UI (always non-empty).
copy_to_clipboard :: proc(text: string) -> string {
	data := text
	truncated := false
	if len(data) > MAX_CLIPBOARD_BYTES {
		data = data[:MAX_CLIPBOARD_BYTES]
		truncated = true
	}

	// 1) native tools
	when ODIN_OS == .Darwin {
		if err := pipe_to_cmd(data, {"pbcopy"}); err == "" {
			return "copied" if !truncated else "copied (truncated)"
		}
	}
	if path_has_cmd("wl-copy") {
		if err := pipe_to_cmd(data, {"wl-copy"}); err == "" {
			return "copied" if !truncated else "copied (truncated)"
		}
	}
	if path_has_cmd("xclip") {
		if err := pipe_to_cmd(data, {"xclip", "-selection", "clipboard"}); err == "" {
			return "copied" if !truncated else "copied (truncated)"
		}
	}
	if path_has_cmd("xsel") {
		if err := pipe_to_cmd(data, {"xsel", "--clipboard", "--input"}); err == "" {
			return "copied" if !truncated else "copied (truncated)"
		}
	}

	// 2) OSC 52 (SSH / terminals without clipboard utilities)
	if terminal.is_terminal(os.stdout) {
		osc_data := data
		osc_trunc := truncated
		if len(osc_data) > OSC52_MAX_BYTES {
			osc_data = osc_data[:OSC52_MAX_BYTES]
			osc_trunc = true
		}
		if write_osc52(osc_data) {
			if osc_trunc {
				return "copied (osc52, truncated)"
			}
			return "copied (osc52)"
		}
	}

	// 3) file fallback
	path := "/tmp/aether-clipboard.txt"
	if err := os.write_entire_file(path, data); err != nil {
		return "copy failed: no clipboard backend"
	}
	return fmt.tprintf("copied to %s", path)
}

// write_osc52 emits OSC 52 clipboard set for the primary CLIPBOARD selection.
// Sequence: ESC ] 52 ; c ; <base64> BEL
write_osc52 :: proc(data: string) -> bool {
	enc, err := base64.encode(transmute([]byte)data, allocator = context.temp_allocator)
	if err != nil {
		return false
	}
	// Use BEL terminator (widely supported); ST (ESC \) also works on some.
	seq := fmt.tprintf("\x1b]52;c;%s\x07", enc)
	n, werr := os.write(os.stdout, transmute([]byte)seq)
	if werr != nil || n < len(seq) {
		return false
	}
	return true
}

path_has_cmd :: proc(name: string) -> bool {
	child, err := os.process_start(
		{
			command = {"sh", "-c", fmt.tprintf("command -v %s >/dev/null 2>&1", name)},
		},
	)
	if err != nil {
		return false
	}
	state, werr := os.process_wait(child)
	if werr != nil {
		return false
	}
	return state.exit_code == 0
}

// paste_clipboard_image_bytes tries CLIPBOARD image/* (png preferred).
// Returns raw image bytes (caller owns via allocator) or ok=false.
paste_clipboard_image_bytes :: proc(allocator := context.allocator) -> ([]byte, bool) {
	when ODIN_OS == .Darwin {
		// pngpaste if available; else skip (pbpaste is text-only)
		if path_has_cmd("pngpaste") {
			if data, ok := read_cmd_stdout_bytes({"pngpaste", "-"}, allocator); ok {
				return data, true
			}
		}
		return nil, false
	}
	if path_has_cmd("wl-paste") {
		if data, ok := read_cmd_stdout_bytes({"wl-paste", "--type", "image/png"}, allocator); ok {
			return data, true
		}
		if data, ok := read_cmd_stdout_bytes({"wl-paste", "--type", "image/jpeg"}, allocator); ok {
			return data, true
		}
	}
	if path_has_cmd("xclip") {
		if data, ok := read_cmd_stdout_bytes(
			{"xclip", "-selection", "clipboard", "-t", "image/png", "-o"},
			allocator,
		); ok {
			return data, true
		}
		if data, ok := read_cmd_stdout_bytes(
			{"xclip", "-selection", "clipboard", "-t", "image/jpeg", "-o"},
			allocator,
		); ok {
			return data, true
		}
	}
	return nil, false
}

// read_cmd_stdout_bytes like read_cmd_stdout but returns raw bytes.
read_cmd_stdout_bytes :: proc(cmd: []string, allocator := context.allocator) -> ([]byte, bool) {
	s, ok := read_cmd_stdout(cmd, context.temp_allocator)
	if !ok || len(s) == 0 {
		return nil, false
	}
	// sanity: must look like image
	if len(s) < 8 {
		return nil, false
	}
	out := make([]byte, len(s), allocator)
	copy(out, transmute([]byte)s)
	return out, true
}

// paste_from_primary reads X11/Wayland PRIMARY selection, then CLIPBOARD fallback.
// Darwin: pbpaste. Returns (text, ok). Text is cloned with allocator (default context).
paste_from_primary :: proc(allocator := context.allocator) -> (string, bool) {
	// Prefer PRIMARY (middle-click convention), then CLIPBOARD.
	when ODIN_OS == .Darwin {
		if s, ok := read_cmd_stdout({"pbpaste"}, allocator); ok {
			return s, true
		}
		return "", false
	}
	if path_has_cmd("wl-paste") {
		// PRIMARY first (--primary), then default clipboard
		if s, ok := read_cmd_stdout({"wl-paste", "--primary", "--no-newline"}, allocator); ok && s != "" {
			return s, true
		}
		if s, ok := read_cmd_stdout({"wl-paste", "--no-newline"}, allocator); ok {
			return s, true
		}
	}
	if path_has_cmd("xclip") {
		if s, ok := read_cmd_stdout({"xclip", "-selection", "primary", "-o"}, allocator); ok && s != "" {
			return s, true
		}
		if s, ok := read_cmd_stdout({"xclip", "-selection", "clipboard", "-o"}, allocator); ok {
			return s, true
		}
	}
	if path_has_cmd("xsel") {
		if s, ok := read_cmd_stdout({"xsel", "--primary", "--output"}, allocator); ok && s != "" {
			return s, true
		}
		if s, ok := read_cmd_stdout({"xsel", "--clipboard", "--output"}, allocator); ok {
			return s, true
		}
	}
	return "", false
}

// read_cmd_stdout runs cmd and returns stdout (capped). ok=false on failure/empty.
read_cmd_stdout :: proc(cmd: []string, allocator := context.allocator) -> (string, bool) {
	stdout_r, stdout_w, perr := os.pipe()
	if perr != nil {
		return "", false
	}
	devnull, derr := os.open("/dev/null", {.Write})
	if derr != nil {
		os.close(stdout_r)
		os.close(stdout_w)
		return "", false
	}
	child, serr := os.process_start(
		{
			command = cmd,
			stdout  = stdout_w,
			stderr  = devnull,
		},
	)
	os.close(stdout_w)
	os.close(devnull)
	if serr != nil {
		os.close(stdout_r)
		return "", false
	}
	// read up to cap
	buf := make([dynamic]u8, 0, 4096, context.temp_allocator)
	tmp: [4096]u8
	for len(buf) < MAX_CLIPBOARD_BYTES {
		n, rerr := os.read(stdout_r, tmp[:])
		if n > 0 {
			remain := MAX_CLIPBOARD_BYTES - len(buf)
			take := min(n, remain)
			append(&buf, ..tmp[:take])
			if take < n {
				break
			}
		}
		if rerr != nil || n <= 0 {
			break
		}
	}
	os.close(stdout_r)
	state, werr := os.process_wait(child, 2 * time.Second)
	if werr != nil {
		_ = os.process_kill(child)
		_, _ = os.process_wait(child, 1 * time.Second)
		return "", false
	}
	if state.exit_code != 0 {
		return "", false
	}
	if len(buf) == 0 {
		return "", false
	}
	return strings.clone(string(buf[:]), allocator), true
}

pipe_to_cmd :: proc(data: string, cmd: []string) -> string /* err */ {
	stdin_r, stdin_w, perr := os.pipe()
	if perr != nil {
		return fmt.tprintf("pipe: %v", perr)
	}
	devnull, derr := os.open("/dev/null", {.Write})
	if derr != nil {
		os.close(stdin_r)
		os.close(stdin_w)
		return "open /dev/null failed"
	}

	child, serr := os.process_start(
		{
			command = cmd,
			stdin   = stdin_r,
			stdout  = devnull,
			stderr  = devnull,
		},
	)
	os.close(stdin_r)
	os.close(devnull)
	if serr != nil {
		os.close(stdin_w)
		return fmt.tprintf("start: %v", serr)
	}

	remaining := transmute([]byte)data
	for len(remaining) > 0 {
		n, werr := os.write(stdin_w, remaining)
		if werr != nil {
			os.close(stdin_w)
			_ = os.process_kill(child)
			_, _ = os.process_wait(child, 1 * time.Second)
			return fmt.tprintf("write: %v", werr)
		}
		if n <= 0 {
			break
		}
		remaining = remaining[n:]
	}
	os.close(stdin_w)

	state, werr := os.process_wait(child, 2 * time.Second)
	if werr != nil {
		_ = os.process_kill(child)
		_, _ = os.process_wait(child, 1 * time.Second)
		return "clipboard timed out"
	}
	if state.exit_code != 0 {
		return fmt.tprintf("exit %d", state.exit_code)
	}
	return ""
}
