package tools

// glob — Grok/OpenCode-shaped file pattern match via rg --files.
// Reference: crates/.../opencode/glob/mod.rs

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"

GLOB_RESULT_LIMIT :: 100
GLOB_MAX_STDOUT :: 5_000_000

Glob_Entry :: struct {
	path:     string,
	mtime_ns: i64,
}

tool_glob :: proc(
	arguments_json: string,
	workspace: string,
	allocator := context.allocator,
) -> string {
	obj, ok := json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	pattern := strings.trim_space(jstr(obj, "pattern"))
	if pattern == "" {
		return strings.clone("error: pattern is required", allocator)
	}
	path := jstr(obj, "path", ".")
	if path == "" {
		path = "."
	}
	abs, inside := resolve_in_workspace(workspace, path, context.temp_allocator)
	if !inside && path != "." {
		// still search if resolve failed? resolve always returns something
		_ = inside
	}

	args := make([dynamic]string, 0, 12, context.temp_allocator)
	append(&args, "rg")
	append(&args, "--files")
	append(&args, "--hidden")
	append(&args, "--glob", "!.git/*")
	append(&args, "--glob", pattern)
	append(&args, "--", abs)

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
	if state.exit_code > 1 {
		return fmt.aprintf(
			"error: rg exit %d: %s",
			state.exit_code,
			string(stderr),
			allocator = allocator,
		)
	}

	out_s := string(stdout)
	if len(out_s) > GLOB_MAX_STDOUT {
		out_s = out_s[:GLOB_MAX_STDOUT]
	}

	// workspace display path
	ws_disp := workspace
	if ws_abs, werr := filepath.abs(workspace, context.temp_allocator); werr == nil {
		ws_disp = ws_abs
	}

	entries := make([dynamic]Glob_Entry, 0, 64, context.temp_allocator)
	truncated := false
	lines := strings.split_lines(out_s, context.temp_allocator)
	for raw_line in lines {
		line := strings.trim_space(raw_line)
		if line == "" {
			continue
		}
		if len(entries) >= GLOB_RESULT_LIMIT {
			truncated = true
			continue
		}
		full := line
		// rg may print relative or absolute
		if !strings.has_prefix(line, "/") {
			joined, jerr := filepath.join({abs, line}, context.temp_allocator)
			if jerr == nil {
				full = joined
			}
		}
		mtime_ns: i64 = 0
		if fi, serr := os.stat(full, context.temp_allocator); serr == nil {
			mtime_ns = time.to_unix_nanoseconds(fi.modification_time)
		}
		// Prefer workspace-relative for display when under workspace
		disp := full
		if rel, rerr := filepath.rel(ws_disp, full, context.temp_allocator); rerr == nil {
			if !strings.has_prefix(rel, "..") {
				disp = rel
			}
		}
		append(&entries, Glob_Entry{path = strings.clone(disp, context.temp_allocator), mtime_ns = mtime_ns})
	}

	// Sort by mtime descending
	slice.sort_by(entries[:], proc(a, b: Glob_Entry) -> bool {
		return a.mtime_ns > b.mtime_ns
	})

	if len(entries) == 0 {
		return strings.clone("No files found", allocator)
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, `<workspace_result workspace_path="`)
	strings.write_string(&b, ws_disp)
	strings.write_string(&b, "\">\n")
	for e in entries {
		strings.write_string(&b, e.path)
		strings.write_byte(&b, '\n')
	}
	if truncated {
		strings.write_byte(&b, '\n')
		fmt.sbprintf(
			&b,
			"(Results are truncated: showing first %d results out of more. Use a more specific path or pattern to narrow results.)\n",
			GLOB_RESULT_LIMIT,
		)
	}
	strings.write_string(&b, "</workspace_result>")
	return strings.to_string(b)
}
