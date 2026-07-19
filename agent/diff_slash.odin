// Package agent — /diff slash: git status + short diff stats (B19).
package agent

import "core:fmt"
import "core:os"
import "core:strings"

DIFF_MAX_OUT_BYTES :: 24 * 1024
DIFF_MAX_LINES :: 80

// run_git_capture runs `git -C cwd …` and returns combined stdout+stderr (allocated).
// On failure returns ("", false) or ("error text", false).
run_git_capture :: proc(
	cwd: string,
	args: []string,
	allocator := context.allocator,
) -> (
	out: string,
	ok: bool,
) {
	ws := cwd if cwd != "" else "."
	cmd := make([dynamic]string, 0, 2 + len(args), context.temp_allocator)
	append(&cmd, "git")
	append(&cmd, "-C")
	append(&cmd, ws)
	for a in args {
		append(&cmd, a)
	}
	state, stdout, stderr, err := os.process_exec(
		{command = cmd[:]},
		context.temp_allocator,
	)
	if err != nil {
		return fmt.aprintf("git failed to start: %v", err, allocator = allocator), false
	}
	combined := strings.concatenate({string(stdout), string(stderr)}, context.temp_allocator)
	if state.exit_code != 0 && strings.trim_space(combined) == "" {
		return fmt.aprintf("git exit %d", state.exit_code, allocator = allocator), false
	}
	// still return output on non-zero (e.g. dirty status is 0 usually)
	text := combined
	if len(text) > DIFF_MAX_OUT_BYTES {
		text = text[:DIFF_MAX_OUT_BYTES]
	}
	return strings.clone(text, allocator), true
}

// truncate_diff_lines keeps first max_lines of text (allocated if truncated).
truncate_diff_lines :: proc(
	text: string,
	max_lines: int,
	allocator := context.allocator,
) -> string {
	if max_lines <= 0 || text == "" {
		return strings.clone(text, allocator)
	}
	n := 0
	for i in 0 ..< len(text) {
		if text[i] == '\n' {
			n += 1
			if n >= max_lines {
				rest := text[i + 1:]
				if rest == "" {
					return strings.clone(text[:i + 1], allocator)
				}
				return fmt.aprintf(
					"%s… (%d more bytes truncated)",
					text[:i + 1],
					len(rest),
					allocator = allocator,
				)
			}
		}
	}
	return strings.clone(text, allocator)
}

// handle_diff_slash implements /diff [stat|full|help].
// Default: status -sb + diff --stat. full: also first N lines of git diff.
handle_diff_slash :: proc(
	cwd: string,
	arg: string,
	allocator := context.allocator,
) -> string {
	a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
	if a == "help" || a == "?" {
		return strings.clone(
			"Usage: /diff [stat|full|help]\n" +
			"  (default|stat)  git status -sb + git diff --stat\n" +
			"  full            also include truncated git diff patch\n" +
			"Runs git -C <session cwd>. Read-only; no staging.",
			allocator,
		)
	}
	mode := "stat"
	if a == "full" || a == "patch" || a == "all" {
		mode = "full"
	} else if a != "" && a != "stat" && a != "status" && a != "short" {
		return fmt.aprintf(
			"aether: unknown /diff arg %q (try /diff help)",
			arg,
			allocator = allocator,
		)
	}

	status, st_ok := run_git_capture(cwd, []string{"status", "-sb"}, context.temp_allocator)
	stat, df_ok := run_git_capture(
		cwd,
		[]string{"diff", "--stat", "HEAD"},
		context.temp_allocator,
	)
	// if not a git repo, status fails
	st_low := strings.to_lower(status, context.temp_allocator)
	if !st_ok &&
	   (strings.contains(st_low, "not a git") ||
		   strings.contains(st_low, "not a git repository")) {
		return fmt.aprintf(
			"aether: not a git repository (%s)\n%s",
			cwd,
			status,
			allocator = allocator,
		)
	}
	if !st_ok && status != "" && !df_ok {
		// try without HEAD for unborn
		stat2, ok2 := run_git_capture(cwd, []string{"diff", "--stat"}, context.temp_allocator)
		if ok2 {
			stat = stat2
			df_ok = true
		}
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, fmt.tprintf("## git status (%s)\n", cwd if cwd != "" else "."))
	if strings.trim_space(status) == "" {
		strings.write_string(&b, "(clean / empty status)\n")
	} else {
		strings.write_string(&b, status)
		if !strings.has_suffix(status, "\n") {
			strings.write_byte(&b, '\n')
		}
	}
	strings.write_string(&b, "\n## git diff --stat\n")
	if strings.trim_space(stat) == "" {
		strings.write_string(&b, "(no unstaged/staged diff vs HEAD)\n")
	} else {
		strings.write_string(&b, stat)
		if !strings.has_suffix(stat, "\n") {
			strings.write_byte(&b, '\n')
		}
	}

	if mode == "full" {
		patch, _ := run_git_capture(
			cwd,
			[]string{"diff", "HEAD", "--", "."},
			context.temp_allocator,
		)
		if strings.trim_space(patch) == "" {
			patch2, _ := run_git_capture(cwd, []string{"diff"}, context.temp_allocator)
			patch = patch2
		}
		strings.write_string(&b, "\n## git diff (truncated)\n")
		if strings.trim_space(patch) == "" {
			strings.write_string(&b, "(empty)\n")
		} else {
			trunc := truncate_diff_lines(patch, DIFF_MAX_LINES, context.temp_allocator)
			strings.write_string(&b, trunc)
			if !strings.has_suffix(trunc, "\n") {
				strings.write_byte(&b, '\n')
			}
		}
	}
	return strings.to_string(b)
}
