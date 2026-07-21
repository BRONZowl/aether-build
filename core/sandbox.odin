// Package core — OS sandbox policy (M6).
// Modes: off | soft (workspace path gates + bash cwd) | bwrap (bubblewrap if present).
// Landlock ABI is probed for doctor; full in-process Landlock apply is deferred
// (bubblewrap provides equivalent child isolation when installed).

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

Sandbox_Mode :: enum {
	Off,
	Soft,  // path gates + bash working_dir (always available)
	Bwrap, // soft + wrap bash in bubblewrap when available
}

// sandbox_mode_from_env:
//   AETHER_OS_SANDBOX=0|off|false → Off
//   soft|1|true|workspace → Soft
//   bwrap|landlock|os → Bwrap (falls back to Soft if bwrap missing)
sandbox_mode_from_env :: proc() -> Sandbox_Mode {
	if v := os.get_env("AETHER_NO_OS_SANDBOX", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") {
		return .Off
	}
	v := strings.to_lower(
		strings.trim_space(os.get_env("AETHER_OS_SANDBOX", context.temp_allocator)),
		context.temp_allocator,
	)
	switch v {
	case "", "0", "off", "false", "no":
		return .Off
	case "soft", "1", "true", "yes", "workspace", "on":
		return .Soft
	case "bwrap", "bubblewrap", "landlock", "os", "strict":
		return .Bwrap
	}
	return .Off
}

sandbox_mode_string :: proc(m: Sandbox_Mode) -> string {
	switch m {
	case .Off:
		return "off"
	case .Soft:
		return "soft"
	case .Bwrap:
		return "bwrap"
	}
	return "off"
}

// bwrap_available: bubblewrap on PATH.
bwrap_available :: proc() -> bool {
	// quick path check
	path_env := os.get_env("PATH", context.temp_allocator)
	start := 0
	for i := 0; i <= len(path_env); i += 1 {
		if i == len(path_env) || path_env[i] == ':' {
			dir := path_env[start:i]
			start = i + 1
			if dir == "" {
				continue
			}
			cand, _ := filepath.join({dir, "bwrap"}, context.temp_allocator)
			if os.exists(cand) && !os.is_directory(cand) {
				return true
			}
		}
	}
	return false
}

// landlock_abi_available: probe kernel support (Linux only via /proc or syscall stub).
// Best-effort: check for landlock in /sys or try open of known path.
landlock_abi_available :: proc() -> bool {
	// Presence of documentation node or LSM
	if os.exists("/sys/kernel/security/landlock") {
		return true
	}
	// Some kernels expose via /proc/sys
	if os.exists("/proc/sys/kernel/unprivileged_userns_clone") {
		// not definitive — still report soft
	}
	// Try reading lsm list
	data, err := os.read_entire_file("/sys/kernel/security/lsm", context.temp_allocator)
	if err == nil {
		if strings.contains(string(data), "landlock") {
			return true
		}
	}
	return false
}

// effective_sandbox_mode: Bwrap degrades to Soft if bwrap missing.
effective_sandbox_mode :: proc() -> Sandbox_Mode {
	m := sandbox_mode_from_env()
	if m == .Bwrap && !bwrap_available() {
		return .Soft
	}
	return m
}

// sandbox_status_line for /doctor /features
sandbox_status_line :: proc(allocator := context.allocator) -> string {
	req := sandbox_mode_from_env()
	eff := effective_sandbox_mode()
	bwrap := bwrap_available()
	ll := landlock_abi_available()
	return fmt.aprintf(
		"os-sandbox: request=%s effective=%s  bwrap=%v  landlock_lsm=%v\n" +
		"  soft=workspace path gates + bash cwd; bwrap=child bubblewrap when installed\n" +
		"  env: AETHER_OS_SANDBOX=off|soft|bwrap  AETHER_NO_OS_SANDBOX=1",
		sandbox_mode_string(req),
		sandbox_mode_string(eff),
		bwrap,
		ll,
		allocator = allocator,
	)
}

// build_sandboxed_shell_argv: argv for running command under policy.
// Caller uses working_dir=workspace still.
build_sandboxed_shell_argv :: proc(
	workspace, command: string,
	allocator := context.allocator,
) -> []string {
	mode := effective_sandbox_mode()
	if mode != .Bwrap || !bwrap_available() {
		// soft / off: plain sh -c (workspace working_dir applied by process_start)
		out := make([]string, 3, allocator)
		out[0] = strings.clone("sh", allocator)
		out[1] = strings.clone("-c", allocator)
		out[2] = strings.clone(command, allocator)
		return out
	}
	// bubblewrap: bind workspace RW; system paths RO; no network isolation by default
	// (coding agent often needs network for package tools — leave net shared)
	ws := workspace
	if ws == "" {
		ws = "."
	}
	args := make([dynamic]string, 0, 32, allocator)
	append(&args, strings.clone("bwrap", allocator))
	append(&args, strings.clone("--die-with-parent", allocator))
	append(&args, strings.clone("--dev", allocator))
	append(&args, strings.clone("/dev", allocator))
	append(&args, strings.clone("--proc", allocator))
	append(&args, strings.clone("/proc", allocator))
	// RO system
	sys_paths := [6]string{"/usr", "/bin", "/sbin", "/lib", "/lib64", "/etc"}
	for p in sys_paths {
		if os.exists(p) {
			append(&args, strings.clone("--ro-bind", allocator))
			append(&args, strings.clone(p, allocator))
			append(&args, strings.clone(p, allocator))
		}
	}
	// tmp
	append(&args, strings.clone("--tmpfs", allocator))
	append(&args, strings.clone("/tmp", allocator))
	// workspace RW
	append(&args, strings.clone("--bind", allocator))
	append(&args, strings.clone(ws, allocator))
	append(&args, strings.clone(ws, allocator))
	append(&args, strings.clone("--chdir", allocator))
	append(&args, strings.clone(ws, allocator))
	// also bind ~/.grok read-only for config? optional — soft only for now
	append(&args, strings.clone("sh", allocator))
	append(&args, strings.clone("-c", allocator))
	append(&args, strings.clone(command, allocator))
	return args[:]
}
