package tools

// grep — Grok-shaped ripgrep wrapper (full parameter surface).
// Reference: crates/.../grok_build/grep/mod.rs

import "core:fmt"
import "core:os"
import "core:strings"

DEFAULT_GREP_HEAD_LIMIT :: 200

tool_grep :: proc(
	arguments_json: string,
	workspace: string,
	allocator := context.allocator,
) -> string {
	obj, ok := json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	pattern := jstr(obj, "pattern")
	if pattern == "" {
		return strings.clone("error: pattern is required", allocator)
	}
	path := jstr(obj, "path", ".")
	if path == "" {
		path = "."
	}
	glob := jstr(obj, "glob")
	type_filter := jstr(obj, "type")
	// head_limit: total output lines (not rg --max-count per file)
	head_limit := jint(obj, "head_limit", DEFAULT_GREP_HEAD_LIMIT)
	if head_limit <= 0 {
		head_limit = DEFAULT_GREP_HEAD_LIMIT
	}
	case_insensitive := jbool(obj, "-i", false)
	multiline := jbool(obj, "multiline", false)

	// Context: -C wins over -A/-B when set
	ctx_c := jint(obj, "-C", -1)
	ctx_a := jint(obj, "-A", -1)
	ctx_b := jint(obj, "-B", -1)

	abs, inside := resolve_in_workspace(workspace, path, context.temp_allocator)
	if !inside {
		return strings.clone("error: grep outside workspace is denied", allocator)
	}

	args := make([dynamic]string, 0, 20, context.temp_allocator)
	append(&args, "rg")
	append(&args, "--line-number")
	append(&args, "--no-heading")
	append(&args, "--color", "never")
	if case_insensitive {
		append(&args, "-i")
	}
	if multiline {
		append(&args, "-U")
		append(&args, "--multiline-dotall")
	}
	if ctx_c >= 0 {
		append(&args, "-C", fmt.tprintf("%d", ctx_c))
	} else {
		if ctx_b >= 0 {
			append(&args, "-B", fmt.tprintf("%d", ctx_b))
		}
		if ctx_a >= 0 {
			append(&args, "-A", fmt.tprintf("%d", ctx_a))
		}
	}
	if type_filter != "" {
		append(&args, "--type", type_filter)
	}
	if glob != "" {
		append(&args, "--glob", glob)
	}
	append(&args, "--", pattern, abs)

	state, stdout, stderr, err := os.process_exec(
		{
			command = args[:],
			working_dir = workspace,
		},
		context.temp_allocator,
	)
	if err != nil {
		return fmt.aprintf(
			"error: failed to run rg (is ripgrep installed?): %v",
			err,
			allocator = allocator,
		)
	}
	// rg exit 1 = no matches
	if state.exit_code == 1 && len(stdout) == 0 {
		return strings.clone("(no matches)", allocator)
	}
	if state.exit_code > 1 {
		return fmt.aprintf(
			"error: rg exit %d: %s",
			state.exit_code,
			string(stderr),
			allocator = allocator,
		)
	}

	text := string(stdout)
	lines := strings.split_lines(text, context.temp_allocator)
	// drop trailing empty from final newline
	n := len(lines)
	if n > 0 && lines[n - 1] == "" {
		n -= 1
	}
	truncated := false
	if n > head_limit {
		n = head_limit
		truncated = true
	}
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< n {
		strings.write_string(&b, lines[i])
		strings.write_byte(&b, '\n')
	}
	if truncated {
		fmt.sbprintf(
			&b,
			"\n(Results truncated to head_limit=%d; refine pattern/path/glob.)\n",
			head_limit,
		)
	}
	return cap_output(strings.to_string(b), DEFAULT_OUTPUT_CAP, allocator)
}
