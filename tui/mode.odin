// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
import "aether:agent"
import "aether:core"
import "aether:tools"

// toggle_yolo flips Always_Approve vs previous mode (Grok Ctrl+O).
toggle_yolo :: proc(
	st: ^App_State,
	perm: ^core.Permission_Mode,
	perm_before: ^core.Permission_Mode,
) {
	if perm^ == .Always_Approve {
		// Leaving yolo: drop plan if still active, restore prior perm
		if agent.plan_mode_is_active() || agent.plan_mode_is_pending() || agent.plan_mode_is_exit_pending() {
			_ = agent.user_exit_plan_mode(".", st.streaming, context.temp_allocator)
		}
		perm^ = perm_before^
		delete(st.perm)
		st.perm = strings.clone(core.permission_mode_string(perm^))
		_ = core.persist_permission_mode(perm^)
		state_set_status(st, fmt.tprintf("yolo off (%s)", st.perm))
	} else {
		// Entering yolo: leave plan mode (Always-Approve is full agent)
		if agent.plan_mode_is_active() || agent.plan_mode_is_pending() || agent.plan_mode_is_exit_pending() {
			_ = agent.user_exit_plan_mode(".", st.streaming, context.temp_allocator)
		}
		if perm^ != .Always_Approve {
			perm_before^ = perm^
		}
		perm^ = .Always_Approve
		delete(st.perm)
		st.perm = strings.clone(core.permission_mode_string(perm^))
		_ = core.persist_permission_mode(perm^)
		state_set_status(st, "yolo on")
	}
}

// cycle_mode: Grok-shaped Shift+Tab ring.
// With plan mode: ask → plan → auto → always-approve → read-only → ask.
// With AETHER_NO_PLAN_MODE: ask → auto → always-approve → read-only → ask.
cycle_mode :: proc(
	st: ^App_State,
	perm: ^core.Permission_Mode,
	perm_before: ^core.Permission_Mode,
	cwd: string,
) {
	sync_sess_plan :: proc() {
		if stream_sess() != nil {
			stream_sess().plan_mode =
				agent.plan_mode_is_active() ||
				agent.plan_mode_is_pending() ||
				agent.plan_mode_is_exit_pending()
		}
	}
	apply_perm :: proc(
		st: ^App_State,
		perm: ^core.Permission_Mode,
		perm_before: ^core.Permission_Mode,
		m: core.Permission_Mode,
	) {
		perm^ = m
		if m != .Always_Approve {
			perm_before^ = m
		}
		delete(st.perm)
		st.perm = strings.clone(core.permission_mode_string(perm^))
		_ = core.persist_permission_mode(perm^)
		state_set_status(st, fmt.tprintf("mode: %s", st.perm))
	}
	if agent.plan_mode_enabled() {
		// plan Active/Pending/Exit_Pending → auto (leave plan into accept-edits)
		if agent.plan_mode_is_active() ||
		   agent.plan_mode_is_pending() ||
		   agent.plan_mode_is_exit_pending() {
			_ = agent.user_exit_plan_mode(cwd, st.streaming, context.temp_allocator)
			sync_sess_plan()
			apply_perm(st, perm, perm_before, .Auto)
			return
		}
		// Not in plan: ask → plan; auto → always; always → ro; ro → ask
		switch perm^ {
		case .Ask:
			_ = agent.user_enter_plan_mode(cwd, "", context.temp_allocator)
			sync_sess_plan()
			// Keep underlying permission as ask; header shows plan chip via agent state
			perm_before^ = .Ask
			delete(st.perm)
			st.perm = strings.clone(core.permission_mode_string(perm^))
			state_set_status(st, "mode: plan")
			return
		case .Auto:
			apply_perm(st, perm, perm_before, .Always_Approve)
			return
		case .Always_Approve:
			apply_perm(st, perm, perm_before, .Read_Only)
			return
		case .Read_Only:
			apply_perm(st, perm, perm_before, .Ask)
			return
		}
	}
	// Plan mode disabled: permission-only cycle (includes auto)
	perm^ = core.next_permission_mode(perm^)
	if perm^ != .Always_Approve {
		perm_before^ = perm^
	}
	delete(st.perm)
	st.perm = strings.clone(core.permission_mode_string(perm^))
	_ = core.persist_permission_mode(perm^)
	state_set_status(st, fmt.tprintf("mode: %s", st.perm))
}
