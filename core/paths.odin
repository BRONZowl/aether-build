package core

import "core:os"
import "core:path/filepath"
import "core:strings"

// grok_home returns $GROK_HOME or ~/.grok (allocated).
grok_home :: proc(allocator := context.allocator) -> string {
	if v := os.get_env("GROK_HOME", context.temp_allocator); v != "" {
		return strings.clone(v, allocator)
	}
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil || home == "" {
		return strings.clone(".grok", allocator)
	}
	joined, _ := filepath.join({home, ".grok"}, allocator)
	return joined
}

// auth_json_path returns $GROK_AUTH_PATH or $GROK_HOME/auth.json (allocated).
auth_json_path :: proc(allocator := context.allocator) -> string {
	if v := os.get_env("GROK_AUTH_PATH", context.temp_allocator); v != "" {
		return strings.clone(v, allocator)
	}
	home := grok_home(context.temp_allocator)
	joined, _ := filepath.join({home, "auth.json"}, allocator)
	return joined
}

// aether_sessions_dir returns session store directory (allocated).
// Order: AETHER_SESSIONS_DIR, else $GROK_HOME/aether/sessions.
aether_sessions_dir :: proc(override := "", allocator := context.allocator) -> string {
	if override != "" {
		return strings.clone(override, allocator)
	}
	if v := os.get_env("AETHER_SESSIONS_DIR", context.temp_allocator); v != "" {
		return strings.clone(v, allocator)
	}
	home := grok_home(context.temp_allocator)
	joined, _ := filepath.join({home, "aether", "sessions"}, allocator)
	return joined
}

// abs_cwd returns an absolute path for cwd or "." (allocated).
abs_cwd :: proc(cwd: string, allocator := context.allocator) -> string {
	path := cwd
	if path == "" {
		path = "."
	}
	abs, err := filepath.abs(path, allocator)
	if err != nil {
		return strings.clone(path, allocator)
	}
	return abs
}

// ensure_dir creates directory and parents if needed.
ensure_dir :: proc(path: string) -> bool {
	if path == "" {
		return false
	}
	if os.exists(path) {
		return os.is_directory(path)
	}
	return os.make_directory_all(path) == nil
}
