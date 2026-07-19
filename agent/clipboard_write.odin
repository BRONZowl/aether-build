package agent

import "core:fmt"
import "core:os"

// copy_text_to_clipboard best-effort write (wl-copy / xclip / xsel / pbcopy / file).
// Returns a short status string (never empty).
copy_text_to_clipboard :: proc(text: string) -> string {
	data := text
	trunc := false
	if len(data) > 1_000_000 {
		data = data[:1_000_000]
		trunc = true
	}
	when ODIN_OS == .Darwin {
		if pipe_stdin_cmd(data, {"pbcopy"}) {
			return "copied" if !trunc else "copied (truncated)"
		}
	}
	if cmd_on_path("wl-copy") && pipe_stdin_cmd(data, {"wl-copy"}) {
		return "copied" if !trunc else "copied (truncated)"
	}
	if cmd_on_path("xclip") && pipe_stdin_cmd(data, {"xclip", "-selection", "clipboard"}) {
		return "copied" if !trunc else "copied (truncated)"
	}
	if cmd_on_path("xsel") && pipe_stdin_cmd(data, {"xsel", "--clipboard", "--input"}) {
		return "copied" if !trunc else "copied (truncated)"
	}
	path := "/tmp/aether-clipboard.txt"
	if err := os.write_entire_file(path, transmute([]byte)data); err == nil {
		return fmt.tprintf("copied to %s", path)
	}
	return "copy failed: no clipboard backend"
}

@(private)
cmd_on_path :: proc(name: string) -> bool {
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

@(private)
pipe_stdin_cmd :: proc(data: string, cmd: []string) -> bool {
	stdin_r, stdin_w, perr := os.pipe()
	if perr != nil {
		return false
	}
	devnull, derr := os.open("/dev/null", {.Write})
	if derr != nil {
		os.close(stdin_r)
		os.close(stdin_w)
		return false
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
		return false
	}
	remaining := transmute([]byte)data
	for len(remaining) > 0 {
		n, werr := os.write(stdin_w, remaining)
		if werr != nil || n <= 0 {
			os.close(stdin_w)
			_, _ = os.process_wait(child)
			return false
		}
		remaining = remaining[n:]
	}
	os.close(stdin_w)
	state, werr := os.process_wait(child)
	return werr == nil && state.exit_code == 0
}
