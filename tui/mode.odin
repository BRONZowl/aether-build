// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:strings"
import "aether:agent"
import "aether:core"

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

// cycle_mode: Grok Shift+Tab ring — Normal → Plan → Always-Approve → Normal.
// Reference: user-guide/19-plan-mode.md + actions/defaults CycleMode.
// Auto / Read-Only stay available via settings and slash commands, not this ring.
// When AETHER_NO_PLAN_MODE: Normal ↔ Always-Approve only (Ctrl+O-shaped).
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
	}

	ws := cwd if cwd != "" else "."

	if !agent.plan_mode_enabled() {
		// Plan disabled: toggle Always-Approve only
		if perm^ == .Always_Approve {
			apply_perm(st, perm, perm_before, .Ask)
			state_set_status(st, "mode: ask")
		} else {
			if perm^ != .Always_Approve {
				perm_before^ = perm^
			}
			apply_perm(st, perm, perm_before, .Always_Approve)
			state_set_status(st, "mode: always-approve")
		}
		return
	}

	// In plan (any lifecycle state) → leave plan, land Always-Approve (Grok)
	if agent.plan_mode_is_active() ||
	   agent.plan_mode_is_pending() ||
	   agent.plan_mode_is_exit_pending() {
		_ = agent.user_exit_plan_mode(ws, st.streaming, context.temp_allocator)
		sync_sess_plan()
		if perm^ != .Always_Approve {
			perm_before^ = perm^
		}
		apply_perm(st, perm, perm_before, .Always_Approve)
		state_set_status(st, "mode: always-approve")
		return
	}

	// Always-Approve → Normal (Ask); keep Auto/RO only if that was underlying
	if perm^ == .Always_Approve {
		// Return to last non-yolo mode, defaulting to Ask
		rest := perm_before^
		if rest == .Always_Approve {
			rest = .Ask
		}
		apply_perm(st, perm, perm_before, rest)
		state_set_status(st, fmt.tprintf("mode: %s", st.perm))
		return
	}

	// Normal (Ask / Auto / Read_Only) → Plan
	_ = agent.user_enter_plan_mode(ws, "", context.temp_allocator)
	sync_sess_plan()
	// Keep underlying permission; header shows plan chip via agent state
	if perm^ != .Always_Approve {
		perm_before^ = perm^
	}
	delete(st.perm)
	st.perm = strings.clone(core.permission_mode_string(perm^))
	state_set_status(st, "mode: plan")
}
