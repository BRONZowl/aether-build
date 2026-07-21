// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_parse_toml_bool_and_int :: proc(t: ^testing.T) {
	testing.expect(t, parse_toml_bool("true"))
	testing.expect(t, parse_toml_bool("YES"))
	testing.expect(t, !parse_toml_bool("false"))
	testing.expect(t, !parse_toml_bool("0"))
	n, ok := parse_toml_int("42")
	testing.expect(t, ok && n == 42)
	n2, ok2 := parse_toml_int("\"75\"")
	testing.expect(t, ok2 && n2 == 75)
}

@(test)
test_parse_toml_layer_product_keys :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-cfg-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)

	body := `
[models]
default = "grok-test"
default_reasoning_effort = "high"

[ui]
permission_mode = "ask"
auto_compact = false
auto_compact_pct = 55
theme = "tokyonight"
vim_mode = true

[agent]
max_turns = 7

[memory]
enabled = false
auto_dream = false

[memory.initial_injection]
enabled = false

[subagents]
enabled = false

[permission]
allow = ["Bash(git *)"]
`
	path, _ := filepath.join({dir, "cfg.toml"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)body) == nil)

	L := parse_toml_layer(path, context.allocator)
	defer destroy_config_layer(&L)

	testing.expect(t, L.model == "grok-test", L.model)
	testing.expect(t, L.has_reasoning_effort && L.reasoning_effort == "high", L.reasoning_effort)
	testing.expect(t, L.has_perm_mode && L.permission_mode == .Ask)
	testing.expect(t, L.has_auto_compact && !L.auto_compact)
	testing.expect(t, L.has_auto_compact_pct && L.auto_compact_pct == 55)
	testing.expect(t, L.has_max_turns && L.max_turns == 7)
	testing.expect(t, L.has_memory && !L.memory)
	testing.expect(t, L.has_auto_dream && !L.auto_dream)
	testing.expect(t, L.has_memory_inject && !L.memory_inject)
	testing.expect(t, L.has_subagents && !L.subagents)
	testing.expect(t, L.has_theme && L.theme == "tokyonight", L.theme)
	testing.expect(t, L.has_vim_mode && L.vim_mode)
	testing.expect(t, len(L.allow) == 1)
	testing.expect(t, strings.contains(L.allow[0], "git"))
}

@(test)
test_apply_runtime_flags_and_env_precedence :: proc(t: ^testing.T) {
	reset_runtime_flags()
	defer reset_runtime_flags()

	// Defaults when not loaded
	testing.expect(t, flag_memory())
	testing.expect(t, flag_subagents())
	testing.expect(t, flag_auto_compact_pct() == DEFAULT_AUTO_COMPACT_PCT)

	cfg := Runtime_Config {
		auto_compact_pct = 40,
		auto_compact     = true,
		memory           = false,
		memory_inject    = false,
		auto_dream       = true,
		subagents        = false,
	}
	apply_runtime_flags(cfg)
	testing.expect(t, !flag_memory())
	testing.expect(t, !flag_subagents())
	testing.expect(t, flag_auto_compact_pct() == 40)
	testing.expect(t, !flag_memory_inject())
	testing.expect(t, flag_auto_dream())
}

@(test)
test_load_runtime_config_from_aether_config_env :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-cfg-load-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)

	body := `
[models]
default = "from-file"

[agent]
max_turns = 3

[subagents]
enabled = false

[ui]
auto_compact_pct = 90
`
	path, _ := filepath.join({dir, "aether.toml"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)body) == nil)

	prev := os.get_env("AETHER_CONFIG", context.temp_allocator)
	os.set_env("AETHER_CONFIG", path)
	defer {
		if prev != "" {
			os.set_env("AETHER_CONFIG", prev)
		} else {
			os.unset_env("AETHER_CONFIG")
		}
		reset_runtime_flags()
	}

	reset_runtime_flags()
	cfg := load_runtime_config("", dir, 0, "", context.allocator)
	defer destroy_runtime_config(&cfg)

	testing.expect(t, cfg.model == "from-file", cfg.model)
	testing.expect(t, cfg.max_turns == 3)
	testing.expect(t, !cfg.subagents)
	testing.expect(t, cfg.auto_compact_pct == 90)
	testing.expect(t, !flag_subagents())
	testing.expect(t, flag_auto_compact_pct() == 90)

	// CLI max_turns wins over TOML
	cfg2 := load_runtime_config("", dir, 99, "", context.allocator)
	defer destroy_runtime_config(&cfg2)
	testing.expect(t, cfg2.max_turns == 99)
}
