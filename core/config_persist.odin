// Persist selected keys into ~/.grok/config.toml (B9 / B15 / B17).
// Best-effort; never required for runtime. Opt out: AETHER_NO_UI_PERSIST=1.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

ui_persist_enabled :: proc() -> bool {
	return !feature_killed("AETHER_NO_UI_PERSIST")
}

// user_config_toml_path: $GROK_HOME/config.toml (allocated).
user_config_toml_path :: proc(allocator := context.allocator) -> string {
	home := grok_home(context.temp_allocator)
	p, _ := filepath.join({home, "config.toml"}, allocator)
	return p
}

// persist_ui_bool upserts key = true|false under [ui] in user config.toml.
// Returns "" on success or a short error string (temp/static).
persist_ui_bool :: proc(key: string, value: bool) -> string {
	if !ui_persist_enabled() || key == "" {
		return ""
	}
	val := "true" if value else "false"
	return upsert_section_toml_key("[ui]", key, val)
}

// persist_ui_string upserts key = "quoted" under [ui].
persist_ui_string :: proc(key: string, value: string) -> string {
	if !ui_persist_enabled() || key == "" {
		return ""
	}
	return upsert_section_toml_key("[ui]", key, quote_toml_string(value))
}

// persist_permission_mode writes [ui] permission_mode = "ask|auto|…" (B15).
persist_permission_mode :: proc(m: Permission_Mode) -> string {
	return persist_ui_string("permission_mode", permission_mode_string(m))
}

// persist_default_model writes [models] default = "…" (B17 / Grok-shaped).
persist_default_model :: proc(model: string) -> string {
	if !ui_persist_enabled() {
		return ""
	}
	m := strings.trim_space(model)
	if m == "" {
		return ""
	}
	return upsert_section_toml_key("[models]", "default", quote_toml_string(m))
}

// persist_reasoning_effort writes [models] default_reasoning_effort (B17).
// Empty / off → "off" so restarts clear process default.
persist_reasoning_effort :: proc(level: string) -> string {
	if !ui_persist_enabled() {
		return ""
	}
	v := strings.trim_space(level)
	if v == "" {
		v = "off"
	}
	return upsert_section_toml_key(
		"[models]",
		"default_reasoning_effort",
		quote_toml_string(v),
	)
}

quote_toml_string :: proc(value: string) -> string {
	esc := value
	if strings.contains(value, "\"") {
		esc, _ = strings.replace_all(value, "\"", "\\\"", context.temp_allocator)
	}
	return fmt.tprintf("\"%s\"", esc)
}

// upsert_ui_toml_key kept as [ui] shorthand (tests / callers).
upsert_ui_toml_key :: proc(key: string, value_literal: string) -> string {
	return upsert_section_toml_key("[ui]", key, value_literal)
}

// upsert_section_toml_key rewrites or appends key = value under section header
// (e.g. "[ui]", "[models]"). Creates the section if missing.
upsert_section_toml_key :: proc(section_hdr, key, value_literal: string) -> string {
	if section_hdr == "" || key == "" {
		return "invalid section/key"
	}
	path := user_config_toml_path(context.temp_allocator)
	home := grok_home(context.temp_allocator)
	_ = os.make_directory_all(home)

	raw := ""
	if os.exists(path) {
		data, err := os.read_entire_file(path, context.temp_allocator)
		if err != nil {
			return "read config.toml failed"
		}
		raw = string(data)
	}

	lines := strings.split_lines(raw, context.temp_allocator)
	out := make([dynamic]string, 0, len(lines) + 4, context.temp_allocator)

	in_sec := false
	sec_seen := false
	key_written := false
	new_line := fmt.tprintf("%s = %s", key, value_literal)

	for line in lines {
		trim := strings.trim_space(line)
		if strings.has_prefix(trim, "[") && strings.has_suffix(trim, "]") {
			if in_sec && !key_written {
				append(&out, new_line)
				key_written = true
			}
			in_sec = (trim == section_hdr)
			if in_sec {
				sec_seen = true
			}
			append(&out, line)
			continue
		}
		if in_sec {
			k, _, ok := split_toml_kv(trim)
			if ok && k == key {
				append(&out, new_line)
				key_written = true
				continue
			}
		}
		append(&out, line)
	}
	if in_sec && !key_written {
		append(&out, new_line)
		key_written = true
	}
	if !sec_seen {
		if len(out) > 0 {
			last := out[len(out) - 1]
			if last != "" {
				append(&out, "")
			}
		}
		append(&out, section_hdr)
		append(&out, new_line)
	}

	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(out) {
		strings.write_string(&b, out[i])
		strings.write_byte(&b, '\n')
	}
	body := strings.to_string(b)
	if werr := os.write_entire_file(path, transmute([]byte)body); werr != nil {
		return fmt.tprintf("write config.toml failed: %v", werr)
	}
	return ""
}
