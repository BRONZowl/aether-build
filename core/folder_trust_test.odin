// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:os"
import "core:path/filepath"
import "core:testing"

@(test)
test_parse_trusted_folders_toml :: proc(t: ^testing.T) {
	src := `
# comment
[folders."/tmp/proj-a"]
trusted = true
decided_at = 100

[folders."/tmp/proj-a/child"]
trusted = false
decided_at = 200
`
	recs := parse_trusted_folders_toml(src, context.allocator)
	defer free_trust_records(recs)
	testing.expect(t, len(recs) == 2)
	testing.expect(t, recs[0].path == "/tmp/proj-a")
	testing.expect(t, recs[0].trusted)
	testing.expect(t, recs[1].path == "/tmp/proj-a/child")
	testing.expect(t, !recs[1].trusted)
}

@(test)
test_path_is_prefix :: proc(t: ^testing.T) {
	testing.expect(t, path_is_prefix("/a/b", "/a/b"))
	testing.expect(t, path_is_prefix("/a/b", "/a/b/c"))
	testing.expect(t, !path_is_prefix("/a/b", "/a/bc"))
	testing.expect(t, !path_is_prefix("/a/b", "/a"))
}

@(test)
test_is_unsafe_trust_root :: proc(t: ^testing.T) {
	testing.expect(t, is_unsafe_trust_root("/"))
	testing.expect(t, is_unsafe_trust_root(""))
	testing.expect(t, is_unsafe_trust_root("relative"))
	testing.expect(t, !is_unsafe_trust_root("/tmp/some-project"))
}

@(test)
test_folder_trust_grant_revoke_round_trip :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("/tmp", "aether-ft-", context.allocator)
	testing.expect(t, err == nil)
	defer {
		os.remove_all(dir)
		delete(dir) // path string owned by tracking allocator
	}

	prev_h := os.get_env("GROK_HOME", context.temp_allocator)
	prev_ft := os.get_env("AETHER_NO_FOLDER_TRUST", context.temp_allocator)
	_ = os.set_env("GROK_HOME", dir)
	_ = os.unset_env("AETHER_NO_FOLDER_TRUST")
	defer {
		if prev_h != "" {
			_ = os.set_env("GROK_HOME", prev_h)
		} else {
			_ = os.unset_env("GROK_HOME")
		}
		if prev_ft != "" {
			_ = os.set_env("AETHER_NO_FOLDER_TRUST", prev_ft)
		} else {
			_ = os.unset_env("AETHER_NO_FOLDER_TRUST")
		}
	}

	ws, _ := filepath.join({dir, "workspace"}, context.temp_allocator)
	_ = os.make_directory_all(ws)

	testing.expect(t, folder_trust_enabled())
	// undecided → not trusted
	testing.expect(t, !is_folder_trusted(ws))

	gerr := grant_folder_trust(ws)
	testing.expectf(t, gerr == "", "grant: %s", gerr)
	testing.expect(t, is_folder_trusted(ws))

	// store file exists
	store := trusted_folders_path(context.temp_allocator)
	testing.expect(t, os.exists(store))

	rerr := revoke_folder_trust(ws)
	testing.expectf(t, rerr == "", "revoke: %s", rerr)
	testing.expect(t, !is_folder_trusted(ws))
}

@(test)
test_folder_trust_feature_off_allows :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_FOLDER_TRUST", context.temp_allocator)
	_ = os.set_env("AETHER_NO_FOLDER_TRUST", "1")
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_NO_FOLDER_TRUST", prev)
		} else {
			_ = os.unset_env("AETHER_NO_FOLDER_TRUST")
		}
	}
	testing.expect(t, !folder_trust_enabled())
	testing.expect(t, is_folder_trusted("/any/path"))
}

@(test)
test_project_hooks_gated_by_trust :: proc(t: ^testing.T) {
	// Integration-style: load_hooks is in hooks package; test trust store only here.
	// hooks package tests project gate separately if needed.
	dir, err := os.make_directory_temp("/tmp", "aether-ft2-", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)

	prev_h := os.get_env("GROK_HOME", context.temp_allocator)
	_ = os.set_env("GROK_HOME", dir)
	_ = os.unset_env("AETHER_NO_FOLDER_TRUST")
	defer {
		if prev_h != "" {
			_ = os.set_env("GROK_HOME", prev_h)
		} else {
			_ = os.unset_env("GROK_HOME")
		}
	}

	ws, _ := filepath.join({dir, "repo"}, context.temp_allocator)
	_ = os.make_directory_all(ws)
	testing.expect(t, !project_scope_allowed(ws))
	_ = grant_folder_trust(ws)
	testing.expect(t, project_scope_allowed(ws))
}
