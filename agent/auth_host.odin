// Package agent — host Grok CLI bridge (A5.2 login, A3.2 mcp doctor/list).
// Aether does not implement in-process browser OAuth; it execs `grok` when needed.
package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "aether:core"

// find_grok_cli resolves the host Grok binary.
// Order: AETHER_GROK_BIN / GROK_BIN → PATH → ~/.local/bin/grok
// Returns owned path on success; caller delete().
find_grok_cli :: proc(allocator := context.allocator) -> (path: string, err: string) {
	env_keys := [2]string{"AETHER_GROK_BIN", "GROK_BIN"}
	for key in env_keys {
		if v := strings.trim_space(os.get_env(key, context.temp_allocator)); v != "" {
			if path_is_executable(v) {
				return strings.clone(v, allocator), ""
			}
			return "", fmt.tprintf("%s=%s is not an executable file", key, v)
		}
	}

	if p := look_path_bin("grok", allocator); p != "" {
		return p, ""
	}

	// Common local install
	uhome, uerr := os.user_home_dir(context.temp_allocator)
	if uerr == nil && uhome != "" {
		cand, _ := filepath.join({uhome, ".local", "bin", "grok"}, context.temp_allocator)
		if path_is_executable(cand) {
			return strings.clone(cand, allocator), ""
		}
	}
	return "", "host CLI `grok` not found on PATH"
}

// look_path_bin finds an executable name on PATH (owned).
look_path_bin :: proc(name: string, allocator := context.allocator) -> string {
	if name == "" {
		return ""
	}
	// Absolute / relative with slash
	if strings.contains(name, "/") {
		if path_is_executable(name) {
			return strings.clone(name, allocator)
		}
		return ""
	}
	path_env := os.get_env("PATH", context.temp_allocator)
	start := 0
	for i := 0; i <= len(path_env); i += 1 {
		if i == len(path_env) || path_env[i] == ':' {
			dir := path_env[start:i]
			start = i + 1
			if dir == "" {
				continue
			}
			cand, _ := filepath.join({dir, name}, context.temp_allocator)
			if path_is_executable(cand) {
				return strings.clone(cand, allocator)
			}
		}
	}
	return ""
}

path_is_executable :: proc(path: string) -> bool {
	// Best-effort: exists and not a directory (kernel enforces +x on exec).
	if path == "" || !os.exists(path) || os.is_directory(path) {
		return false
	}
	return true
}

// host_cli_missing_message user-facing when grok is absent (legacy bridges only).
// R0-A: product does not require host CLI — prefer XAI_API_KEY.
host_cli_missing_message :: proc(purpose: string = "legacy host features") -> string {
	return fmt.tprintf(
		"aether: host CLI not found (optional for %s).\n" +
		"Ship mode R0-A: set XAI_API_KEY (recommended). Existing ~/.grok/auth.json still works.\n" +
		"Optional browser login: install Rust grok (https://x.ai/cli) or AETHER_GROK_BIN=…\n" +
		"MCP: use /mcp doctor (in-process) — no host grok required.",
		purpose,
	)
}

// host_login_missing_message keeps A5.2 name; R0-A: login is optional.
host_login_missing_message :: proc() -> string {
	return host_cli_missing_message("browser login (optional)")
}

// run_host_grok execs `grok [args…]` with inherited stdio.
// Returns process exit code (1 if binary missing / start failed).
run_host_grok :: proc(args: []string, quiet := false, label := "grok") -> int {
	bin, ferr := find_grok_cli(context.allocator)
	if ferr != "" {
		fmt.eprintln(host_cli_missing_message(label))
		if ferr != "host CLI `grok` not found on PATH" {
			fmt.eprintf("aether: %s\n", ferr)
		}
		return 1
	}
	defer delete(bin)

	argv := make([dynamic]string, 0, 1 + len(args), context.temp_allocator)
	append(&argv, bin)
	for a in args {
		append(&argv, a)
	}

	if !quiet {
		// short log of command
		b := strings.builder_make(context.temp_allocator)
		strings.write_string(&b, "aether: running ")
		strings.write_string(&b, bin)
		for a in args {
			strings.write_byte(&b, ' ')
			strings.write_string(&b, a)
		}
		strings.write_string(&b, "…")
		fmt.eprintln(strings.to_string(b))
	}

	child, serr := os.process_start(
		{
			command = argv[:],
			stdin   = os.stdin,
			stdout  = os.stdout,
			stderr  = os.stderr,
		},
	)
	if serr != nil {
		fmt.eprintf("aether: failed to start host CLI: %v\n", serr)
		return 1
	}

	// Long operations (login, mcp doctor) — generous timeout
	state, werr := os.process_wait(child, 30 * time.Minute)
	if werr != nil {
		_ = os.process_kill(child)
		_, _ = os.process_wait(child, 5 * time.Second)
		fmt.eprintf("aether: host CLI wait error: %v\n", werr)
		return 1
	}
	return int(state.exit_code)
}

// run_host_login execs `grok login [extra…]`.
run_host_login :: proc(extra_args: []string = {}, quiet := false) -> int {
	argv := make([dynamic]string, 0, 1 + len(extra_args), context.temp_allocator)
	append(&argv, "login")
	for a in extra_args {
		append(&argv, a)
	}
	if !quiet {
		fmt.eprintln(
			"aether: optional browser login via host `grok` (R0-A: prefer XAI_API_KEY)…",
		)
	}
	code := run_host_grok(argv[:], quiet, "browser login")
	if code == 0 && !quiet {
		auth_p := core.auth_json_path(context.temp_allocator)
		fmt.eprintf(
			"aether: login finished — session in %s (try `aether whoami`)\n",
			auth_p,
		)
	}
	return code
}

// run_host_mcp_doctor: `grok mcp doctor [server]`.
run_host_mcp_doctor :: proc(server: string = "", quiet := false) -> int {
	argv := make([dynamic]string, 0, 3, context.temp_allocator)
	append(&argv, "mcp")
	append(&argv, "doctor")
	if strings.trim_space(server) != "" {
		append(&argv, strings.trim_space(server))
	}
	return run_host_grok(argv[:], quiet, "mcp doctor")
}

// run_host_mcp_list: `grok mcp list`.
run_host_mcp_list :: proc(quiet := false) -> int {
	return run_host_grok([]string{"mcp", "list"}, quiet, "mcp list")
}

// auth_sign_in_hint short phrase for resolve_credentials errors (R0-A).
auth_sign_in_hint :: proc() -> string {
	return "Set XAI_API_KEY (recommended). Optional: existing ~/.grok/auth.json or `aether login` if host grok is installed."
}
