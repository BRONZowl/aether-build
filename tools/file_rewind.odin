// Package tools — soft file-edit rewind (B2.2).
// Snapshot prior content before write/search_replace/delete; /rewind restores LIFO.
// Process-local stack (not multi-session). Opt out: AETHER_NO_FILE_REWIND=1.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tools

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

MAX_REWIND_STACK :: 40
// Cap stored content per snapshot (avoid huge binaries in RAM).
MAX_REWIND_BYTES :: 2 * 1024 * 1024

File_Rewind_Op :: enum {
	Write, // create or overwrite
	Edit, // search_replace
	Delete,
}

File_Rewind_Entry :: struct {
	abs_path:   string, // owned
	disp_path:  string, // owned display path for messages
	op:         File_Rewind_Op,
	// prior content; empty + existed=false means file did not exist (create)
	prior:      string, // owned
	existed:    bool,
}

g_rewind_mu:    sync.Mutex
g_rewind_stack: [dynamic]File_Rewind_Entry

file_rewind_enabled :: proc() -> bool {
	v := os.get_env("AETHER_NO_FILE_REWIND", context.temp_allocator)
	return !(v == "1" || v == "true" || v == "yes" || v == "on")
}

file_rewind_clear :: proc() {
	sync.mutex_lock(&g_rewind_mu)
	defer sync.mutex_unlock(&g_rewind_mu)
	if g_rewind_stack.allocator.procedure == nil {
		return
	}
	for &e in g_rewind_stack {
		delete(e.abs_path)
		delete(e.disp_path)
		delete(e.prior)
	}
	clear(&g_rewind_stack)
}

file_rewind_count :: proc() -> int {
	sync.mutex_lock(&g_rewind_mu)
	defer sync.mutex_unlock(&g_rewind_mu)
	if g_rewind_stack.allocator.procedure == nil {
		return 0
	}
	return len(g_rewind_stack)
}

// file_rewind_push_before_mutation snapshots current file state (call before write/delete).
// Skip if disabled, path missing for non-delete and we'll treat as create.
file_rewind_push_before_mutation :: proc(
	abs_path, disp_path: string,
	op: File_Rewind_Op,
) {
	if !file_rewind_enabled() {
		return
	}
	existed := os.exists(abs_path) && !os.is_directory(abs_path)
	prior := ""
	if existed {
		data, err := os.read_entire_file(abs_path, context.temp_allocator)
		if err != nil {
			return // fail-open: don't block mutation
		}
		if len(data) > MAX_REWIND_BYTES {
			// too large — skip snapshot rather than OOM
			return
		}
		prior = string(data)
	} else if op == .Delete {
		// nothing to rewind
		return
	}

	sync.mutex_lock(&g_rewind_mu)
	defer sync.mutex_unlock(&g_rewind_mu)
	if g_rewind_stack.allocator.procedure == nil {
		g_rewind_stack = make([dynamic]File_Rewind_Entry, 0, 16, runtime.heap_allocator())
	}
	// trim stack
	for len(g_rewind_stack) >= MAX_REWIND_STACK {
		e := g_rewind_stack[0]
		delete(e.abs_path)
		delete(e.disp_path)
		delete(e.prior)
		ordered_remove(&g_rewind_stack, 0)
	}
	append(
		&g_rewind_stack,
		File_Rewind_Entry {
			abs_path  = strings.clone(abs_path, runtime.heap_allocator()),
			disp_path = strings.clone(disp_path if disp_path != "" else abs_path, runtime.heap_allocator()),
			op        = op,
			prior     = strings.clone(prior, runtime.heap_allocator()),
			existed   = existed,
		},
	)
}

// file_rewind_undo restores the last snapshot. Returns status message (owned).
file_rewind_undo :: proc(allocator := context.allocator) -> string {
	if !file_rewind_enabled() {
		return strings.clone("aether: file rewind disabled (AETHER_NO_FILE_REWIND)", allocator)
	}
	sync.mutex_lock(&g_rewind_mu)
	defer sync.mutex_unlock(&g_rewind_mu)
	if g_rewind_stack.allocator.procedure == nil || len(g_rewind_stack) == 0 {
		return strings.clone("aether: nothing to rewind", allocator)
	}
	e := g_rewind_stack[len(g_rewind_stack) - 1]
	pop(&g_rewind_stack)

	msg: string
	if !e.existed {
		// was create → remove file if present
		if os.exists(e.abs_path) && !os.is_directory(e.abs_path) {
			if err := os.remove(e.abs_path); err != nil {
				msg = fmt.aprintf(
					"aether: rewind failed removing %s: %v",
					e.disp_path,
					err,
					allocator = allocator,
				)
			} else {
				msg = fmt.aprintf(
					"aether: rewound create of %s (deleted)",
					e.disp_path,
					allocator = allocator,
				)
			}
		} else {
			msg = fmt.aprintf(
				"aether: rewound create of %s (already absent)",
				e.disp_path,
				allocator = allocator,
			)
		}
	} else {
		// restore prior content
		if err := os.write_entire_file(e.abs_path, transmute([]byte)e.prior); err != nil {
			msg = fmt.aprintf(
				"aether: rewind failed writing %s: %v",
				e.disp_path,
				err,
				allocator = allocator,
			)
		} else {
			op_s := "edit"
			switch e.op {
			case .Write:
				op_s = "write"
			case .Edit:
				op_s = "edit"
			case .Delete:
				op_s = "delete"
			}
			msg = fmt.aprintf(
				"aether: rewound %s of %s (%d bytes restored)",
				op_s,
				e.disp_path,
				len(e.prior),
				allocator = allocator,
			)
		}
	}
	delete(e.abs_path)
	delete(e.disp_path)
	delete(e.prior)
	return msg
}

// file_rewind_status short summary for /rewind status.
file_rewind_status :: proc(allocator := context.allocator) -> string {
	n := file_rewind_count()
	on := "on" if file_rewind_enabled() else "off"
	return fmt.aprintf(
		"aether: file rewind %s · stack %d/%d (write/edit/delete)",
		on,
		n,
		MAX_REWIND_STACK,
		allocator = allocator,
	)
}
