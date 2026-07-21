// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_upsert_ui_toml_key_create_and_update :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-ui-persist-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)

	// Point GROK_HOME at temp
	prev_h := os.get_env("GROK_HOME", context.temp_allocator)
	prev_p := os.get_env("AETHER_NO_UI_PERSIST", context.temp_allocator)
	_ = os.set_env("GROK_HOME", dir)
	_ = os.unset_env("AETHER_NO_UI_PERSIST")
	defer {
		if prev_h != "" {
			_ = os.set_env("GROK_HOME", prev_h)
		} else {
			_ = os.unset_env("GROK_HOME")
		}
		if prev_p != "" {
			_ = os.set_env("AETHER_NO_UI_PERSIST", prev_p)
		}
	}

	err := persist_ui_bool("compact_mode", true)
	testing.expect(t, err == "", err)
	path, _ := filepath.join({dir, "config.toml"}, context.temp_allocator)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, rerr == nil)
	s := string(data)
	testing.expect(t, strings.contains(s, "[ui]"))
	testing.expect(t, strings.contains(s, "compact_mode = true"))

	err2 := persist_ui_bool("compact_mode", false)
	testing.expect(t, err2 == "")
	data2, _ := os.read_entire_file(path, context.temp_allocator)
	s2 := string(data2)
	testing.expect(t, strings.contains(s2, "compact_mode = false"))
	// still one key, not duplicated section chaos
	testing.expect(t, strings.count(s2, "compact_mode") == 1)

	err3 := persist_ui_string("theme", "tokyonight")
	testing.expect(t, err3 == "")
	data3, _ := os.read_entire_file(path, context.temp_allocator)
	s3 := string(data3)
	testing.expect(t, strings.contains(s3, "theme = \"tokyonight\""))
	testing.expect(t, strings.contains(s3, "compact_mode = false"))

	// opt out
	_ = os.set_env("AETHER_NO_UI_PERSIST", "1")
	err4 := persist_ui_bool("vim_mode", true)
	testing.expect(t, err4 == "")
	data4, _ := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, !strings.contains(string(data4), "vim_mode"))
	_ = os.unset_env("AETHER_NO_UI_PERSIST")

	// B15: permission_mode string persist
	err5 := persist_permission_mode(.Auto)
	testing.expect(t, err5 == "", err5)
	data5, _ := os.read_entire_file(path, context.temp_allocator)
	s5 := string(data5)
	testing.expect(t, strings.contains(s5, "permission_mode = \"auto\""), s5)
	err6 := persist_permission_mode(.Read_Only)
	testing.expect(t, err6 == "")
	data6, _ := os.read_entire_file(path, context.temp_allocator)
	s6 := string(data6)
	testing.expect(t, strings.contains(s6, "permission_mode = \"read-only\""), s6)
	testing.expect(t, strings.count(s6, "permission_mode") == 1)

	// B17: [models] default + default_reasoning_effort
	err7 := persist_default_model("grok-4.5")
	testing.expect(t, err7 == "", err7)
	err8 := persist_reasoning_effort("high")
	testing.expect(t, err8 == "", err8)
	data7, _ := os.read_entire_file(path, context.temp_allocator)
	s7 := string(data7)
	testing.expect(t, strings.contains(s7, "[models]"), s7)
	testing.expect(t, strings.contains(s7, "default = \"grok-4.5\""), s7)
	testing.expect(t, strings.contains(s7, "default_reasoning_effort = \"high\""), s7)
	err9 := persist_reasoning_effort("off")
	testing.expect(t, err9 == "")
	data8, _ := os.read_entire_file(path, context.temp_allocator)
	s8 := string(data8)
	testing.expect(t, strings.contains(s8, "default_reasoning_effort = \"off\""), s8)
	testing.expect(t, strings.count(s8, "default_reasoning_effort") == 1)
}
