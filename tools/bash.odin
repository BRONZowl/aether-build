package tools

// run_terminal_cmd — product Full FG shell (bg handled in agent).
// Timeout clamp 300s; sandbox / persistent shell N/A.

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

// Grok-shaped FG ceiling (ms). Background uses 0 = unlimited separately.
BASH_FG_DEFAULT_TIMEOUT_MS :: 120_000
BASH_FG_MAX_TIMEOUT_MS :: 300_000

// clamp_bash_fg_timeout_ms: default 120s; max 5m.
clamp_bash_fg_timeout_ms :: proc(timeout_ms: int) -> int {
	t := timeout_ms
	if t <= 0 {
		t = BASH_FG_DEFAULT_TIMEOUT_MS
	}
	if t > BASH_FG_MAX_TIMEOUT_MS {
		t = BASH_FG_MAX_TIMEOUT_MS
	}
	return t
}

tool_run_terminal_cmd :: proc(
	arguments_json: string,
	workspace: string,
	allocator := context.allocator,
) -> string {
	obj, ok := json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	command := jstr(obj, "command")
	if command == "" {
		return strings.clone("error: command is required", allocator)
	}
	if jbool(obj, "is_background", false) {
		// Background path is handled in agent.run_one_tool → handle_bash_background.
		return strings.clone(
			"error: is_background must be handled by the agent loop (internal)",
			allocator,
		)
	}
	timeout_ms := clamp_bash_fg_timeout_ms(jint(obj, "timeout", BASH_FG_DEFAULT_TIMEOUT_MS))

	stdout_r, stdout_w, perr := os.pipe()
	if perr != nil {
		return fmt.aprintf("error: pipe stdout: %v", perr, allocator = allocator)
	}
	stderr_r, stderr_w, perr2 := os.pipe()
	if perr2 != nil {
		os.close(stdout_r)
		os.close(stdout_w)
		return fmt.aprintf("error: pipe stderr: %v", perr2, allocator = allocator)
	}

	child, serr := os.process_start(
		{
			command = {"sh", "-c", command},
			working_dir = workspace,
			stdout = stdout_w,
			stderr = stderr_w,
		},
	)
	os.close(stdout_w)
	os.close(stderr_w)
	if serr != nil {
		os.close(stdout_r)
		os.close(stderr_r)
		return fmt.aprintf("error: failed to start command: %v", serr, allocator = allocator)
	}

	stdout_b := make([dynamic]byte, 0, 4096, context.temp_allocator)
	stderr_b := make([dynamic]byte, 0, 1024, context.temp_allocator)
	buf: [4096]u8
	start_t := time.now()
	timeout_dur := time.Duration(timeout_ms) * time.Millisecond

	stdout_done := false
	stderr_done := false
	timed_out := false
	exit_code := 0

	for !stdout_done || !stderr_done {
		if !stdout_done {
			has, _ := os.pipe_has_data(stdout_r)
			if has {
				n, rerr := os.read(stdout_r, buf[:])
				if n > 0 {
					append(&stdout_b, ..buf[:n])
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
				if n > 0 {
					append(&stderr_b, ..buf[:n])
				}
				if rerr == .EOF || rerr == .Broken_Pipe {
					stderr_done = true
				}
			}
		}

		state, werr := os.process_wait(child, 0)
		if werr == nil && state.exited {
			exit_code = state.exit_code
			for !stdout_done {
				n, rerr := os.read(stdout_r, buf[:])
				if n > 0 {
					append(&stdout_b, ..buf[:n])
				}
				if rerr != nil || n == 0 {
					stdout_done = true
				}
			}
			for !stderr_done {
				n, rerr := os.read(stderr_r, buf[:])
				if n > 0 {
					append(&stderr_b, ..buf[:n])
				}
				if rerr != nil || n == 0 {
					stderr_done = true
				}
			}
			break
		}

		if time.diff(start_t, time.now()) >= timeout_dur {
			timed_out = true
			_ = os.process_kill(child)
			_, _ = os.process_wait(child, 2 * time.Second)
			break
		}
		time.sleep(10 * time.Millisecond)
	}

	os.close(stdout_r)
	os.close(stderr_r)
	out := format_cmd_output(stdout_b[:], stderr_b[:], exit_code, timed_out, context.temp_allocator)
	return cap_output(out, DEFAULT_BASH_CAP, allocator)
}

format_cmd_output :: proc(
	stdout: []byte,
	stderr: []byte,
	exit_code: int,
	timed_out: bool,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, string(stdout))
	if len(stderr) > 0 {
		strings.write_string(&b, "\n--- stderr ---\n")
		strings.write_string(&b, string(stderr))
	}
	if timed_out {
		strings.write_string(
			&b,
			"\n[timed out — use is_background=true for long jobs, or raise timeout up to 300000 ms]",
		)
	} else {
		strings.write_string(&b, fmt.tprintf("\n[exit_code=%d]", exit_code))
	}
	return strings.to_string(b)
}
