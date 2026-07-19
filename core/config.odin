package core

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"

DEFAULT_MODEL :: "grok-4.5"
DEFAULT_MAX_TURNS :: 20
DEFAULT_AUTO_COMPACT_PCT :: 80
CLI_CHAT_PROXY_BASE_URL :: "https://cli-chat-proxy.grok.com/v1"
XAI_API_BASE_URL :: "https://api.x.ai/v1"

// Runtime_Config is the merged product config for one process entry.
// Feature toggles also feed process-global Runtime_Flags (env still wins at gates).
Runtime_Config :: struct {
	model:               string,
	max_turns:           int,
	cwd:                 string,
	config_path:         string, // highest project config path if any
	permission_mode:     Permission_Mode,
	permission_allow:    [dynamic]string,
	permission_deny:     [dynamic]string,
	// Product flags (A5.1) — defaults true / 80
	auto_compact_pct:    int,
	auto_compact:        bool,
	memory:              bool,
	memory_inject:       bool,
	auto_dream:          bool,
	subagents:           bool,
	theme:               string, // [ui] theme canonical or raw (C2.1)
	vim_mode:            bool, // [ui] vim_mode (C2.2)
	compact_mode:        bool, // [ui] compact_mode (B8)
	timestamps:          bool, // [ui] timestamps (B37)
	// [models] default_reasoning_effort — empty = omit / off (B17)
	reasoning_effort:    string,
}

// Config_Layer is a partial overlay applied during merge (only has_* fields apply).
Config_Layer :: struct {
	model:                 string,
	reasoning_effort:      string,
	has_reasoning_effort:  bool,
	permission_mode:       Permission_Mode,
	has_perm_mode:         bool,
	allow:                 [dynamic]string,
	deny:                  [dynamic]string,
	source:                string,
	max_turns:             int,
	has_max_turns:         bool,
	auto_compact_pct:      int,
	has_auto_compact_pct:  bool,
	auto_compact:          bool,
	has_auto_compact:      bool,
	memory:                bool,
	has_memory:            bool,
	memory_inject:         bool,
	has_memory_inject:     bool,
	auto_dream:            bool,
	has_auto_dream:        bool,
	subagents:             bool,
	has_subagents:         bool,
	theme:                 string,
	has_theme:             bool,
	vim_mode:              bool,
	has_vim_mode:          bool,
	compact_mode:          bool,
	has_compact_mode:      bool,
	timestamps:            bool,
	has_timestamps:        bool,
}

// Runtime_Flags process snapshot from last load_runtime_config (Option A).
// Env kill-switches always win over these in gate helpers.
Runtime_Flags :: struct {
	auto_compact_pct: int,
	auto_compact:     bool,
	memory:           bool,
	memory_inject:    bool,
	auto_dream:       bool,
	subagents:        bool,
	vim_mode:         bool,
	compact_mode:     bool,
	timestamps:       bool,
	loaded:           bool, // false until first apply_runtime_flags
}

g_runtime_flags: Runtime_Flags

default_runtime_flags :: proc() -> Runtime_Flags {
	return Runtime_Flags {
		auto_compact_pct = DEFAULT_AUTO_COMPACT_PCT,
		auto_compact     = true,
		memory           = true,
		memory_inject    = true,
		auto_dream       = true,
		subagents        = true,
		vim_mode         = false,
		compact_mode     = false,
		timestamps       = false,
		loaded           = false,
	}
}

// reset_runtime_flags for tests; restores product defaults without a load.
reset_runtime_flags :: proc() {
	g_runtime_flags = default_runtime_flags()
}

// apply_runtime_flags copies cfg product toggles into process globals.
apply_runtime_flags :: proc(cfg: Runtime_Config) {
	g_runtime_flags = Runtime_Flags {
		auto_compact_pct = cfg.auto_compact_pct,
		auto_compact     = cfg.auto_compact,
		memory           = cfg.memory,
		memory_inject    = cfg.memory_inject,
		auto_dream       = cfg.auto_dream,
		subagents        = cfg.subagents,
		vim_mode         = cfg.vim_mode,
		compact_mode     = cfg.compact_mode,
		timestamps       = cfg.timestamps,
		loaded           = true,
	}
	// Theme name (config or default dark)
	if cfg.theme != "" {
		_ = set_ui_theme_name(cfg.theme)
	}
	set_vim_mode(cfg.vim_mode)
	set_compact_mode(cfg.compact_mode)
	set_timestamps(cfg.timestamps)
}

// --- vim_mode process flag (C2.2) ---
g_vim_mode: bool

set_vim_mode :: proc(on: bool) {
	g_vim_mode = on
}

vim_mode_enabled :: proc() -> bool {
	return g_vim_mode
}

toggle_vim_mode :: proc() -> bool {
	g_vim_mode = !g_vim_mode
	return g_vim_mode
}

// --- compact_mode process flag (B8 / Grok [ui].compact_mode) ---
g_compact_mode: bool

set_compact_mode :: proc(on: bool) {
	g_compact_mode = on
}

compact_mode_enabled :: proc() -> bool {
	return g_compact_mode
}

toggle_compact_mode :: proc() -> bool {
	g_compact_mode = !g_compact_mode
	return g_compact_mode
}

// --- timestamps process flag (B37 / Grok [ui].timestamps) ---
g_timestamps: bool

set_timestamps :: proc(on: bool) {
	g_timestamps = on
}

timestamps_enabled :: proc() -> bool {
	return g_timestamps
}

toggle_timestamps :: proc() -> bool {
	g_timestamps = !g_timestamps
	return g_timestamps
}

// flag_* helpers: config defaults when not loaded; gates layer env on top.
flag_auto_compact_pct :: proc() -> int {
	if g_runtime_flags.loaded {
		return g_runtime_flags.auto_compact_pct
	}
	return DEFAULT_AUTO_COMPACT_PCT
}

flag_auto_compact :: proc() -> bool {
	if g_runtime_flags.loaded {
		return g_runtime_flags.auto_compact
	}
	return true
}

flag_memory :: proc() -> bool {
	if g_runtime_flags.loaded {
		return g_runtime_flags.memory
	}
	return true
}

flag_memory_inject :: proc() -> bool {
	if g_runtime_flags.loaded {
		return g_runtime_flags.memory_inject
	}
	return true
}

flag_auto_dream :: proc() -> bool {
	if g_runtime_flags.loaded {
		return g_runtime_flags.auto_dream
	}
	return true
}

flag_subagents :: proc() -> bool {
	if g_runtime_flags.loaded {
		return g_runtime_flags.subagents
	}
	return true
}

destroy_config_layer :: proc(L: ^Config_Layer) {
	delete(L.model)
	delete(L.reasoning_effort)
	delete(L.source)
	delete(L.theme)
	for s in L.allow {
		delete(s)
	}
	delete(L.allow)
	for s in L.deny {
		delete(s)
	}
	delete(L.deny)
}

// load_runtime_config merges defaults → ~/.grok/config.toml → aether.toml → CLI.
// Env kill-switches are not applied here; gate helpers check env first.
// Ends by applying product flags to process globals.
load_runtime_config :: proc(
	model_override: string,
	cwd_override: string,
	max_turns_override: int,
	permission_mode_override: string, // empty = no override
	allocator := context.allocator,
) -> Runtime_Config {
	cfg := Runtime_Config {
		model            = strings.clone(DEFAULT_MODEL, allocator),
		max_turns        = DEFAULT_MAX_TURNS,
		cwd              = abs_cwd(cwd_override if cwd_override != "" else ".", allocator),
		permission_mode  = .Always_Approve,
		auto_compact_pct = DEFAULT_AUTO_COMPACT_PCT,
		auto_compact     = true,
		memory           = true,
		memory_inject    = true,
		auto_dream       = true,
		subagents        = true,
		vim_mode         = false,
		compact_mode     = false,
		timestamps       = false,
	}
	cfg.permission_allow = make([dynamic]string, 0, 8, allocator)
	cfg.permission_deny = make([dynamic]string, 0, 8, allocator)

	// Layer: user home config
	home_cfg, _ := filepath.join(
		{grok_home(context.temp_allocator), "config.toml"},
		context.temp_allocator,
	)
	if os.exists(home_cfg) {
		apply_toml_file(&cfg, home_cfg, allocator)
	}

	// Layer: project aether.toml
	toml_path := find_aether_toml(context.temp_allocator)
	if toml_path != "" {
		delete(cfg.config_path)
		cfg.config_path = strings.clone(toml_path, allocator)
		apply_toml_file(&cfg, toml_path, allocator)
	}

	// CLI overrides (win over TOML)
	if model_override != "" {
		delete(cfg.model)
		cfg.model = strings.clone(model_override, allocator)
	}
	if max_turns_override > 0 {
		cfg.max_turns = max_turns_override
	}
	if permission_mode_override != "" {
		if m, ok := permission_mode_from_string(permission_mode_override); ok {
			cfg.permission_mode = m
		}
	}

	apply_runtime_flags(cfg)
	return cfg
}

destroy_runtime_config :: proc(cfg: ^Runtime_Config) {
	delete(cfg.model)
	delete(cfg.cwd)
	delete(cfg.config_path)
	delete(cfg.theme)
	delete(cfg.reasoning_effort)
	for s in cfg.permission_allow {
		delete(s)
	}
	delete(cfg.permission_allow)
	for s in cfg.permission_deny {
		delete(s)
	}
	delete(cfg.permission_deny)
}

apply_toml_file :: proc(cfg: ^Runtime_Config, path: string, allocator := context.allocator) {
	L := parse_toml_layer(path, context.temp_allocator)
	// model
	if L.model != "" {
		delete(cfg.model)
		cfg.model = strings.clone(L.model, allocator)
	}
	if L.has_reasoning_effort {
		delete(cfg.reasoning_effort)
		cfg.reasoning_effort = strings.clone(L.reasoning_effort, allocator)
	}
	if L.has_perm_mode {
		cfg.permission_mode = L.permission_mode
	}
	if len(L.allow) > 0 {
		clear_string_list(&cfg.permission_allow)
		for s in L.allow {
			append(&cfg.permission_allow, strings.clone(s, allocator))
		}
	}
	if len(L.deny) > 0 {
		clear_string_list(&cfg.permission_deny)
		for s in L.deny {
			append(&cfg.permission_deny, strings.clone(s, allocator))
		}
	}
	if L.has_max_turns && L.max_turns > 0 {
		cfg.max_turns = L.max_turns
	}
	if L.has_auto_compact_pct {
		cfg.auto_compact_pct = clamp_pct(L.auto_compact_pct)
	}
	if L.has_auto_compact {
		cfg.auto_compact = L.auto_compact
	}
	if L.has_memory {
		cfg.memory = L.memory
	}
	if L.has_memory_inject {
		cfg.memory_inject = L.memory_inject
	}
	if L.has_auto_dream {
		cfg.auto_dream = L.auto_dream
	}
	if L.has_subagents {
		cfg.subagents = L.subagents
	}
	if L.has_theme && L.theme != "" {
		delete(cfg.theme)
		// store canonical if known, else raw (set_ui_theme may reject)
		if c, ok := normalize_theme_name(L.theme); ok {
			cfg.theme = strings.clone(c, allocator)
		} else {
			cfg.theme = strings.clone(L.theme, allocator)
		}
	}
	if L.has_vim_mode {
		cfg.vim_mode = L.vim_mode
	}
	if L.has_compact_mode {
		cfg.compact_mode = L.compact_mode
	}
	if L.has_timestamps {
		cfg.timestamps = L.timestamps
	}
}

clamp_pct :: proc(n: int) -> int {
	if n < 0 {
		return 0
	}
	if n > 100 {
		return 100
	}
	return n
}

clear_string_list :: proc(list: ^[dynamic]string) {
	for s in list {
		delete(s)
	}
	clear(list)
}

// parse_toml_layer extracts selected keys from a TOML file (hand-rolled subset).
parse_toml_layer :: proc(path: string, allocator := context.allocator) -> Config_Layer {
	L: Config_Layer
	L.source = strings.clone(path, allocator)
	L.allow = make([dynamic]string, 0, 8, allocator)
	L.deny = make([dynamic]string, 0, 8, allocator)
	// product defaults when has_* stays false
	L.auto_compact = true
	L.memory = true
	L.memory_inject = true
	L.auto_dream = true
	L.subagents = true

	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return L
	}
	section := ""
	for line in strings.split_lines(string(data), context.temp_allocator) {
		trim := strings.trim_space(line)
		if trim == "" || strings.has_prefix(trim, "#") {
			continue
		}
		if strings.has_prefix(trim, "[") && strings.has_suffix(trim, "]") {
			section = trim
			continue
		}
		key, val, ok := split_toml_kv(trim)
		if !ok {
			continue
		}
		switch section {
		case "[models]":
			if key == "default" {
				L.model = strings.clone(unquote(val), allocator)
			} else if key == "default_reasoning_effort" || key == "reasoning_effort" {
				// Grok [models].default_reasoning_effort; empty/off clear
				raw_e := strings.to_lower(strings.trim_space(unquote(val)), context.temp_allocator)
				L.has_reasoning_effort = true
				if raw_e == "" || raw_e == "off" || raw_e == "none" || raw_e == "default" {
					L.reasoning_effort = strings.clone("", allocator)
				} else {
					L.reasoning_effort = strings.clone(raw_e, allocator)
				}
			}
		case "[ui]":
			if key == "permission_mode" {
				if m, mok := permission_mode_from_string(unquote(val)); mok {
					L.permission_mode = m
					L.has_perm_mode = true
				}
			} else if key == "yolo" {
				if parse_toml_bool(val) {
					L.permission_mode = .Always_Approve
					L.has_perm_mode = true
				}
			} else if key == "auto_compact" {
				L.auto_compact = parse_toml_bool(val)
				L.has_auto_compact = true
			} else if key == "auto_compact_pct" {
				if n, nok := parse_toml_int(val); nok {
					L.auto_compact_pct = n
					L.has_auto_compact_pct = true
				}
			} else if key == "theme" {
				L.theme = strings.clone(unquote(val), allocator)
				L.has_theme = true
			} else if key == "vim_mode" {
				L.vim_mode = parse_toml_bool(val)
				L.has_vim_mode = true
			} else if key == "compact_mode" {
				L.compact_mode = parse_toml_bool(val)
				L.has_compact_mode = true
			} else if key == "timestamps" {
				L.timestamps = parse_toml_bool(val)
				L.has_timestamps = true
			}
		case "[compact]":
			if key == "enabled" {
				L.auto_compact = parse_toml_bool(val)
				L.has_auto_compact = true
			} else if key == "threshold_pct" || key == "auto_compact_pct" {
				if n, nok := parse_toml_int(val); nok {
					L.auto_compact_pct = n
					L.has_auto_compact_pct = true
				}
			}
		case "[agent]":
			if key == "max_turns" {
				if n, nok := parse_toml_int(val); nok && n > 0 {
					L.max_turns = n
					L.has_max_turns = true
				}
			}
		case "[permission]":
			if key == "allow" {
				parse_string_array_into(val, &L.allow, allocator)
			} else if key == "deny" {
				parse_string_array_into(val, &L.deny, allocator)
			}
		case "[memory]":
			if key == "enabled" {
				L.memory = parse_toml_bool(val)
				L.has_memory = true
			} else if key == "auto_dream" {
				L.auto_dream = parse_toml_bool(val)
				L.has_auto_dream = true
			}
		case "[memory.initial_injection]":
			if key == "enabled" {
				L.memory_inject = parse_toml_bool(val)
				L.has_memory_inject = true
			}
		case "[subagents]":
			if key == "enabled" {
				L.subagents = parse_toml_bool(val)
				L.has_subagents = true
			}
		}
	}
	return L
}

// parse_toml_bool: true/false/1/0/yes/no/on/off (case-insensitive). Default false if empty.
parse_toml_bool :: proc(raw: string) -> bool {
	v := strings.to_lower(strings.trim_space(unquote(raw)), context.temp_allocator)
	switch v {
	case "true", "1", "yes", "on":
		return true
	case "false", "0", "no", "off", "":
		return false
	}
	return false
}

parse_toml_int :: proc(raw: string) -> (int, bool) {
	v := strings.trim_space(unquote(raw))
	if v == "" {
		return 0, false
	}
	return strconv.parse_int(v)
}

split_toml_kv :: proc(line: string) -> (key: string, val: string, ok: bool) {
	eq := strings.index_byte(line, '=')
	if eq < 0 {
		return "", "", false
	}
	key = strings.trim_space(line[:eq])
	val = strings.trim_space(line[eq + 1:])
	return key, val, key != ""
}

unquote :: proc(s: string) -> string {
	v := strings.trim_space(s)
	if len(v) >= 2 {
		q := v[0]
		if (q == '"' || q == '\'') && v[len(v) - 1] == q {
			return v[1:len(v) - 1]
		}
	}
	return v
}

// parse_string_array_into handles: ["a", "b"] or single "a"
parse_string_array_into :: proc(val: string, out: ^[dynamic]string, allocator := context.allocator) {
	v := strings.trim_space(val)
	if strings.has_prefix(v, "[") && strings.has_suffix(v, "]") {
		inner := strings.trim_space(v[1:len(v) - 1])
		if inner == "" {
			return
		}
		// split on commas not inside quotes — simple scan
		start := 0
		in_q := false
		qch: u8 = 0
		for i in 0 ..< len(inner) {
			ch := inner[i]
			if in_q {
				if ch == qch {
					in_q = false
				}
				continue
			}
			if ch == '"' || ch == '\'' {
				in_q = true
				qch = ch
				continue
			}
			if ch == ',' {
				part := strings.trim_space(inner[start:i])
				if part != "" {
					append(out, strings.clone(unquote(part), allocator))
				}
				start = i + 1
			}
		}
		part := strings.trim_space(inner[start:])
		if part != "" {
			append(out, strings.clone(unquote(part), allocator))
		}
		return
	}
	// single value
	if v != "" {
		append(out, strings.clone(unquote(v), allocator))
	}
}

find_aether_toml :: proc(allocator := context.allocator) -> string {
	if v := os.get_env("AETHER_CONFIG", context.temp_allocator); v != "" {
		if os.exists(v) {
			return strings.clone(v, allocator)
		}
	}
	candidates := []string{"aether.toml", "aether/aether.toml"}
	for c in candidates {
		if os.exists(c) {
			abs, err := filepath.abs(c, allocator)
			if err == nil {
				return abs
			}
			return strings.clone(c, allocator)
		}
	}
	return ""
}

// session_base_url returns the inference base for session (OIDC) auth.
session_base_url :: proc(allocator := context.allocator) -> string {
	if v := os.get_env("AETHER_BASE_URL", context.temp_allocator); v != "" {
		return strings.clone(v, allocator)
	}
	if v := os.get_env("GROK_CLI_CHAT_PROXY_BASE_URL", context.temp_allocator); v != "" {
		return strings.clone(v, allocator)
	}
	return strings.clone(CLI_CHAT_PROXY_BASE_URL, allocator)
}

// api_key_base_url returns the inference base for API-key auth.
api_key_base_url :: proc(allocator := context.allocator) -> string {
	if v := os.get_env("AETHER_BASE_URL", context.temp_allocator); v != "" {
		return strings.clone(v, allocator)
	}
	if v := os.get_env("GROK_XAI_API_BASE_URL", context.temp_allocator); v != "" {
		return strings.clone(v, allocator)
	}
	return strings.clone(XAI_API_BASE_URL, allocator)
}

// silence unused fmt if any
_ :: fmt
