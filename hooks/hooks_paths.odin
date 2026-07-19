// Extra hook search paths: ~/.grok/hooks-paths (B18 / Grok-shaped).
// One absolute path per line under $GROK_HOME; loaded after default dirs.
package hooks

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "aether:core"

// hooks_paths_file: $GROK_HOME/hooks-paths (allocated).
hooks_paths_file :: proc(allocator := context.allocator) -> string {
	home := core.grok_home(context.temp_allocator)
	p, _ := filepath.join({home, "hooks-paths"}, allocator)
	return p
}

// read_hooks_paths returns absolute path lines from hooks-paths (allocated strings).
// Skips blanks and # comments. Caller frees each string + the slice.
read_hooks_paths :: proc(allocator := context.allocator) -> []string {
	path := hooks_paths_file(context.temp_allocator)
	if !os.exists(path) {
		return nil
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return nil
	}
	out := make([dynamic]string, 0, 4, allocator)
	for line in strings.split_lines(string(data), context.temp_allocator) {
		t := strings.trim_space(line)
		if t == "" || strings.has_prefix(t, "#") {
			continue
		}
		append(&out, strings.clone(t, allocator))
	}
	return out[:]
}

// free_hooks_paths frees read_hooks_paths result.
free_hooks_paths :: proc(paths: []string) {
	for p in paths {
		delete(p)
	}
	delete(paths)
}

// expand_hooks_path_input: trim, strip quotes, expand ~/ .
expand_hooks_path_input :: proc(raw: string, allocator := context.allocator) -> string {
	t := strings.trim_space(raw)
	if len(t) >= 2 {
		if (t[0] == '"' && t[len(t) - 1] == '"') || (t[0] == '\'' && t[len(t) - 1] == '\'') {
			t = t[1:len(t) - 1]
		}
	}
	if strings.has_prefix(t, "~/") {
		home := os.get_env("HOME", context.temp_allocator)
		if home != "" {
			return fmt.aprintf("%s/%s", home, t[2:], allocator = allocator)
		}
	}
	return strings.clone(t, allocator)
}

// validate_hooks_path: absolute path under $GROK_HOME (CWE-427 / Grok parity).
// Returns "" if ok, else short error (temp-safe static/tprintf).
validate_hooks_path :: proc(path: string) -> string {
	p := strings.trim_space(path)
	if p == "" {
		return "hook path is empty"
	}
	if !os.is_absolute_path(p) {
		return "hook path must be absolute (or ~/… under home)"
	}
	// Reject traversal that leaves home via ".." after normalize
	clean, _ := filepath.clean(p, context.temp_allocator)
	gh := core.grok_home(context.temp_allocator)
	gh_clean, _ := filepath.clean(gh, context.temp_allocator)
	if clean == gh_clean {
		return ""
	}
	prefix := fmt.tprintf("%s/", gh_clean)
	if strings.has_prefix(clean, prefix) {
		return ""
	}
	return fmt.tprintf("hook path must be under %s (got %s)", gh_clean, clean)
}

// add_hooks_path appends path to hooks-paths if valid and not already present.
// Returns "" on success, else error message.
add_hooks_path :: proc(path: string) -> string {
	exp := expand_hooks_path_input(path, context.temp_allocator)
	if err := validate_hooks_path(exp); err != "" {
		return err
	}
	file := hooks_paths_file(context.temp_allocator)
	home := core.grok_home(context.temp_allocator)
	_ = os.make_directory_all(home)

	existing := ""
	if os.exists(file) {
		data, rerr := os.read_entire_file(file, context.temp_allocator)
		if rerr != nil {
			return "read hooks-paths failed"
		}
		existing = string(data)
		for line in strings.split_lines(existing, context.temp_allocator) {
			if strings.trim_space(line) == exp {
				return "" // idempotent
			}
		}
	}
	// append
	body: string
	if existing == "" {
		body = fmt.tprintf("%s\n", exp)
	} else if strings.has_suffix(existing, "\n") {
		body = fmt.tprintf("%s%s\n", existing, exp)
	} else {
		body = fmt.tprintf("%s\n%s\n", existing, exp)
	}
	if werr := os.write_entire_file(file, transmute([]byte)body); werr != nil {
		return fmt.tprintf("write hooks-paths failed: %v", werr)
	}
	return ""
}

// remove_hooks_path removes exact line match from hooks-paths (noop if missing).
remove_hooks_path :: proc(path: string) -> string {
	exp := expand_hooks_path_input(path, context.temp_allocator)
	file := hooks_paths_file(context.temp_allocator)
	if !os.exists(file) {
		return ""
	}
	data, rerr := os.read_entire_file(file, context.temp_allocator)
	if rerr != nil {
		return "read hooks-paths failed"
	}
	b := strings.builder_make(context.temp_allocator)
	found := false
	for line in strings.split_lines(string(data), context.temp_allocator) {
		if strings.trim_space(line) == exp {
			found = true
			continue
		}
		// preserve original line content
		strings.write_string(&b, line)
		strings.write_byte(&b, '\n')
	}
	if !found {
		return ""
	}
	body := strings.to_string(b)
	if werr := os.write_entire_file(file, transmute([]byte)body); werr != nil {
		return fmt.tprintf("write hooks-paths failed: %v", werr)
	}
	return ""
}

// load_hooks_from_extra_path: file → one JSON; directory → *.json.
load_hooks_from_extra_path :: proc(
	path: string,
	out: ^[dynamic]Hook_Spec,
	allocator := context.allocator,
) {
	p := strings.trim_space(path)
	if p == "" || !os.exists(p) {
		return
	}
	if os.is_directory(p) {
		load_hooks_from_dir(p, out, allocator)
		return
	}
	// treat as single JSON file; source_dir = parent
	parent := filepath.dir(p)
	load_hooks_from_file(p, parent, out, allocator)
}

// format_hooks_paths_status lists configured extra paths (for /hooks paths).
format_hooks_paths_status :: proc(allocator := context.allocator) -> string {
	file := hooks_paths_file(context.temp_allocator)
	paths := read_hooks_paths(context.temp_allocator)
	// do not free temp paths — temp allocator
	if len(paths) == 0 {
		return fmt.aprintf(
			"hooks-paths: none (%s)\n  /hooks add <abs path under ~/.grok>\n  /hooks remove <path>",
			file,
			allocator = allocator,
		)
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, fmt.tprintf("hooks-paths (%d) from %s:\n", len(paths), file))
	for p in paths {
		mark := ""
		if !os.exists(p) {
			mark = "  [missing]"
		} else if os.is_directory(p) {
			mark = "  [dir]"
		} else {
			mark = "  [file]"
		}
		strings.write_string(&b, fmt.tprintf("  %s%s\n", p, mark))
	}
	return strings.to_string(b)
}
