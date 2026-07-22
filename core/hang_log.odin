// Package core — optional hang diagnostics (AETHER_DEBUG_HANG=1).
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
package core

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:time"

hang_log_enabled :: proc() -> bool {
	return env_truthy("AETHER_DEBUG_HANG")
}

// hang_log_path: ~/.grok/aether/hang.log
hang_log_path :: proc(allocator := context.allocator) -> string {
	home := grok_home(context.temp_allocator)
	dir, _ := filepath.join({home, "aether"}, context.temp_allocator)
	_ = ensure_dir(dir)
	p, _ := filepath.join({dir, "hang.log"}, allocator)
	return p
}

// hang_log appends one timestamped line when enabled.
hang_log :: proc(msg: string) {
	if !hang_log_enabled() || msg == "" {
		return
	}
	path := hang_log_path(context.temp_allocator)
	ts := time.now()
	// unix-ish
	line := fmt.tprintf("%v %s\n", ts, msg)
	existing := ""
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		existing = string(data)
		// cap file ~512KB
		if len(existing) > 500_000 {
			existing = existing[len(existing) - 400_000:]
		}
	}
	_ = os.write_entire_file(path, transmute([]byte)fmt.tprintf("%s%s", existing, line))
}
