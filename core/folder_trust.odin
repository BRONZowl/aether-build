// Package core — folder trust store (M1).
// Interop with Grok: ~/.grok/trusted_folders.toml
// Shape:
//   [folders."/abs/workspace"]
//   trusted = true
//   decided_at = 1710000000
//
// Project-local hooks/MCP/plugins consult is_folder_trusted / project_scope_allowed.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:time"

// folder_trust_enabled: opt-out AETHER_NO_FOLDER_TRUST=1 (feature off = always allow project scope).
folder_trust_enabled :: proc() -> bool {
	if v := os.get_env("AETHER_NO_FOLDER_TRUST", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") ||
	   strings.equal_fold(v, "yes") ||
	   strings.equal_fold(v, "on") {
		return false
	}
	return true
}

// trusted_folders_path: $GROK_HOME/trusted_folders.toml (allocated).
trusted_folders_path :: proc(allocator := context.allocator) -> string {
	home := grok_home(context.temp_allocator)
	joined, _ := filepath.join({home, "trusted_folders.toml"}, allocator)
	return joined
}

Folder_Trust_Record :: struct {
	path:       string, // owned key
	trusted:    bool,
	decided_at: i64,
}

// workspace_trust_key: git toplevel when available, else absolute cwd (allocated).
workspace_trust_key :: proc(cwd: string, allocator := context.allocator) -> string {
	abs := abs_cwd(cwd, context.temp_allocator)
	// Prefer git repository root for Grok interop.
	if git_root := git_toplevel(abs, context.temp_allocator); git_root != "" {
		return strings.clone(git_root, allocator)
	}
	return strings.clone(abs, allocator)
}

git_toplevel :: proc(abs_cwd: string, allocator := context.allocator) -> string {
	// Best-effort: git rev-parse --show-toplevel in abs_cwd.
	state, stdout, stderr, err := os.process_exec(
		{
			command = {"git", "-C", abs_cwd, "rev-parse", "--show-toplevel"},
		},
		context.temp_allocator,
	)
	_ = stderr
	if err != nil || state.exit_code != 0 {
		return ""
	}
	s := strings.trim_space(string(stdout))
	if s == "" {
		return ""
	}
	a, aerr := filepath.abs(s, allocator)
	if aerr != nil {
		return strings.clone(s, allocator)
	}
	return a
}

// is_unsafe_trust_root: refuse / and $HOME and non-absolute keys.
is_unsafe_trust_root :: proc(key: string) -> bool {
	if key == "" || key[0] != '/' {
		return true
	}
	if key == "/" {
		return true
	}
	home, err := os.user_home_dir(context.temp_allocator)
	if err == nil && home != "" {
		habs, _ := filepath.abs(home, context.temp_allocator)
		if key == habs || key == home {
			return true
		}
	}
	return false
}

// is_folder_trusted: most-specific prefix match in trusted_folders.toml.
// When folder trust feature is off, returns true (project scope allowed).
is_folder_trusted :: proc(cwd: string) -> bool {
	if !folder_trust_enabled() {
		return true
	}
	key := workspace_trust_key(cwd, context.temp_allocator)
	return trust_store_is_trusted(key)
}

// project_scope_allowed: whether project-local hooks (and later plugins/MCP) may load.
// Fail-closed for gated paths: not trusted unless feature off.
// When no project hooks dir exists, still returns trust status for status display;
// loaders skip project dirs only when false.
project_scope_allowed :: proc(cwd: string) -> bool {
	return is_folder_trusted(cwd)
}

// grant_folder_trust records trusted=true for workspace key. Returns error string or "".
grant_folder_trust :: proc(cwd: string) -> string {
	if !folder_trust_enabled() {
		return "folder trust disabled (AETHER_NO_FOLDER_TRUST=1)"
	}
	key := workspace_trust_key(cwd, context.temp_allocator)
	if is_unsafe_trust_root(key) {
		return fmt.tprintf("refusing to trust over-broad root: %s", key)
	}
	return trust_store_set(key, true)
}

// revoke_folder_trust records trusted=false. Returns error or "".
revoke_folder_trust :: proc(cwd: string) -> string {
	if !folder_trust_enabled() {
		return "folder trust disabled (AETHER_NO_FOLDER_TRUST=1)"
	}
	key := workspace_trust_key(cwd, context.temp_allocator)
	if is_unsafe_trust_root(key) {
		return fmt.tprintf("refusing to untrust over-broad root: %s", key)
	}
	return trust_store_set(key, false)
}

// folder_trust_status_line for /hooks status (allocated).
folder_trust_status_line :: proc(cwd: string, allocator := context.allocator) -> string {
	if !folder_trust_enabled() {
		return strings.clone("folder-trust: off (AETHER_NO_FOLDER_TRUST=1 — project hooks always load)", allocator)
	}
	key := workspace_trust_key(cwd, context.temp_allocator)
	trusted := trust_store_is_trusted(key)
	decided := trust_store_has_decision(key)
	state := "untrusted"
	if trusted {
		state = "trusted"
	} else if !decided {
		state = "undecided (project hooks gated until /hooks trust)"
	}
	return fmt.aprintf("folder-trust: %s\n  key: %s\n  store: %s", state, key, trusted_folders_path(context.temp_allocator), allocator = allocator)
}

// --- store I/O ---

trust_store_is_trusted :: proc(workspace_key: string) -> bool {
	recs := trust_store_load(context.allocator)
	defer free_trust_records(recs)
	if is_unsafe_trust_root(workspace_key) {
		return false
	}
	best_depth := -1
	trusted := false
	for r in recs {
		if is_unsafe_trust_root(r.path) {
			continue
		}
		if !path_is_prefix(r.path, workspace_key) {
			continue
		}
		depth := path_depth(r.path)
		if depth > best_depth {
			best_depth = depth
			trusted = r.trusted
		} else if depth == best_depth {
			// tie: require all trusted (fail closed)
			trusted = trusted && r.trusted
		}
	}
	return trusted
}

trust_store_has_decision :: proc(workspace_key: string) -> bool {
	recs := trust_store_load(context.allocator)
	defer free_trust_records(recs)
	for r in recs {
		if r.path == workspace_key {
			return true
		}
	}
	return false
}

path_depth :: proc(p: string) -> int {
	n := 0
	for i in 0 ..< len(p) {
		if p[i] == '/' {
			n += 1
		}
	}
	return n
}

// path_is_prefix: folder is ancestor of or equal to key (slash-boundary safe).
path_is_prefix :: proc(folder, key: string) -> bool {
	if folder == key {
		return true
	}
	if len(folder) == 0 || len(key) < len(folder) {
		return false
	}
	if !strings.has_prefix(key, folder) {
		return false
	}
	// next char must be '/' unless folder is exactly key
	if len(key) > len(folder) && key[len(folder)] != '/' {
		// allow folder without trailing slash matching /foo vs /foobar
		return false
	}
	return true
}

free_trust_records :: proc(recs: []Folder_Trust_Record) {
	if len(recs) == 0 {
		return
	}
	for r in recs {
		if r.path != "" {
			delete(r.path)
		}
	}
	delete(recs)
}

trust_store_load :: proc(allocator := context.allocator) -> []Folder_Trust_Record {
	path := trusted_folders_path(context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {}
	}
	return parse_trusted_folders_toml(string(data), allocator)
}

// parse_trusted_folders_toml: minimal parser for Grok-compatible shape.
parse_trusted_folders_toml :: proc(src: string, allocator := context.allocator) -> []Folder_Trust_Record {
	out := make([dynamic]Folder_Trust_Record, 0, 8, allocator)
	cur_path := ""
	cur_trusted := false
	cur_at: i64 = 0
	have := false

	lines := strings.split_lines(src, context.temp_allocator)
	for line in lines {
		trim := strings.trim_space(line)
		if trim == "" || strings.has_prefix(trim, "#") {
			continue
		}
		// [folders."/path"] or [folders.'/path']
		if strings.has_prefix(trim, "[folders.") && strings.has_suffix(trim, "]") {
			if have && cur_path != "" {
				append(&out, Folder_Trust_Record {
					path       = strings.clone(cur_path, allocator),
					trusted    = cur_trusted,
					decided_at = cur_at,
				})
			}
			inner := trim[len("[folders.") : len(trim) - 1]
			// strip quotes
			inner = strings.trim_space(inner)
			if len(inner) >= 2 && (inner[0] == '"' || inner[0] == '\'') {
				q := inner[0]
				if inner[len(inner) - 1] == q {
					inner = inner[1 : len(inner) - 1]
				}
			}
			cur_path = inner
			cur_trusted = false
			cur_at = 0
			have = true
			continue
		}
		if !have {
			continue
		}
		if strings.has_prefix(trim, "trusted") {
			// trusted = true/false
			if eq := strings.index_byte(trim, '='); eq >= 0 {
				val := strings.trim_space(trim[eq + 1 :])
				val = strings.trim(val, "\"'")
				cur_trusted = strings.equal_fold(val, "true") || val == "1"
			}
		} else if strings.has_prefix(trim, "decided_at") {
			if eq := strings.index_byte(trim, '='); eq >= 0 {
				val := strings.trim_space(trim[eq + 1 :])
				if n, ok := strconv.parse_i64(val); ok {
					cur_at = n
				}
			}
		}
	}
	if have && cur_path != "" {
		append(&out, Folder_Trust_Record {
			path       = strings.clone(cur_path, allocator),
			trusted    = cur_trusted,
			decided_at = cur_at,
		})
	}
	return out[:]
}

trust_store_set :: proc(key: string, trusted: bool) -> string {
	if is_unsafe_trust_root(key) {
		return "unsafe trust root"
	}
	path := trusted_folders_path(context.temp_allocator)
	// ensure parent
	parent := filepath.dir(path)
	_ = ensure_dir(parent)

	recs := trust_store_load(context.allocator)
	defer free_trust_records(recs)

	// upsert
	found := false
	updated := make([dynamic]Folder_Trust_Record, 0, len(recs) + 1, context.allocator)
	defer {
		for r in updated {
			delete(r.path)
		}
		delete(updated)
	}
	now := time.now()
	unix := time.to_unix_seconds(now)
	for r in recs {
		if r.path == key {
			append(&updated, Folder_Trust_Record {
				path       = strings.clone(key, context.allocator),
				trusted    = trusted,
				decided_at = unix,
			})
			found = true
		} else {
			append(&updated, Folder_Trust_Record {
				path       = strings.clone(r.path, context.allocator),
				trusted    = r.trusted,
				decided_at = r.decided_at,
			})
		}
	}
	if !found {
		append(&updated, Folder_Trust_Record {
			path       = strings.clone(key, context.allocator),
			trusted    = trusted,
			decided_at = unix,
		})
	}

	body := format_trusted_folders_toml(updated[:], context.temp_allocator)
	if os.write_entire_file(path, transmute([]byte)body) != nil {
		return "failed to write trusted_folders.toml"
	}
	return ""
}

format_trusted_folders_toml :: proc(recs: []Folder_Trust_Record, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "# Aether/Grok folder trust store\n")
	for r in recs {
		// quote path for TOML
		// Grok-compatible: [folders."/abs/path"]
		strings.write_string(&b, "\n[folders.\"")
		strings.write_string(&b, r.path)
		strings.write_string(&b, "\"]\n")
		if r.trusted {
			strings.write_string(&b, "trusted = true\n")
		} else {
			strings.write_string(&b, "trusted = false\n")
		}
		if r.decided_at > 0 {
			strings.write_string(&b, fmt.tprintf("decided_at = %d\n", r.decided_at))
		}
	}
	return strings.to_string(b)
}
