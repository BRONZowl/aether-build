// Package tools — process-group isolation for FG/BG shell trees.
// Without a private process group, process_kill only SIGKILLs the shell and
// leaves hyperfine/grok/chromium (etc.) running; aether then appears frozen
// until the whole tree exits or the FG timeout fires.
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
#+build linux, darwin, freebsd, openbsd, netbsd
package tools

import "core:os"
import "core:strings"
import "core:sys/posix"

// with_process_group_leader prepends `setsid` when available so the child is a
// session/process-group leader. Cancel/timeout can then killpg the whole tree.
with_process_group_leader :: proc(argv: []string, allocator := context.allocator) -> []string {
	if len(argv) == 0 {
		return argv
	}
	// Already wrapped
	if argv[0] == "setsid" || strings.has_suffix(argv[0], "/setsid") {
		return argv
	}
	// Prefer absolute path so PATH quirks in sandbox still work
	setsid_path := "/usr/bin/setsid"
	if !os.exists(setsid_path) {
		setsid_path = "setsid"
		// still try; process_start searches PATH
	}
	out := make([]string, len(argv) + 1, allocator)
	out[0] = strings.clone(setsid_path, allocator)
	for a, i in argv {
		out[i + 1] = a // argv entries already owned by caller allocator
	}
	return out
}

// process_kill_tree SIGKILLs the process group (if leader) and the direct pid.
process_kill_tree :: proc(child: os.Process) {
	if child.pid > 0 {
		// Process group (setsid leader has pgid == pid)
		_ = posix.killpg(posix.pid_t(child.pid), .SIGKILL)
		// Fallback: negative-pid form of kill(2)
		_ = posix.kill(posix.pid_t(-child.pid), .SIGKILL)
	}
	_ = os.process_kill(child)
}

// posix_setpgid_self: best-effort make pid its own group leader (race-prone vs setsid).
posix_setpgid_self :: proc(pid: int) {
	if pid <= 0 {
		return
	}
	_ = posix.setpgid(posix.pid_t(pid), posix.pid_t(pid))
}
