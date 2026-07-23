// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

// plan_mode — Grok-shaped lifecycle (full parity slice).
// Reference: crates/codegen/xai-grok-shell/src/session/plan_mode.rs
//            enter_plan_mode / exit_plan_mode tools + exit approval outcomes.

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:terminal"
import "aether:tools"
import "aether:core"

// Plan_Mode_State mirrors Grok PlanModeState.
Plan_Mode_State :: enum {
	Inactive,
	Pending, // user toggled on; model not yet briefed
	Active, // constraints on; model knows
	Exit_Pending, // user toggled off mid-turn
}

Plan_Mode_Tracker :: struct {
	state:                   Plan_Mode_State,
	was_previously_active:   bool,
	reminder_count:          u32,
	pending_exit_reminder:   bool,
	awaiting_plan_approval:  bool,
	// One-shot re-brief after session load (Active restored).
	resume_activation:       bool,
}

// Process-global tracker (synced from Session on load/save).
g_plan: Plan_Mode_Tracker

// Compatibility aliases used by older tests / call sites during migration.
// g_plan_mode_active is true only when Active (edit gate).
// Prefer plan_mode_is_active() / plan_mode_state().

Plan_Enter_Handler :: #type proc() -> bool

Plan_Exit_Outcome :: enum {
	Approved,
	Cancelled,
	Abandoned,
}

Plan_Exit_Result :: struct {
	outcome:  Plan_Exit_Outcome,
	feedback: string, // optional; Cancelled only (not owned by caller after return)
}

// Plan_Exit_Handler: full y/n/a outcome (TUI/REPL).
Plan_Exit_Handler :: #type proc(plan_path, plan_preview: string) -> Plan_Exit_Result

plan_mode_enabled :: proc() -> bool {
	if core.feature_killed("AETHER_NO_PLAN_MODE") {
		return false
	}
	return true
}

plan_mode_state :: proc() -> Plan_Mode_State {
	return g_plan.state
}

// plan_mode_is_active: edit gate — only Active (not Pending).
plan_mode_is_active :: proc() -> bool {
	return g_plan.state == .Active
}

plan_mode_is_pending :: proc() -> bool {
	return g_plan.state == .Pending
}

plan_mode_is_exit_pending :: proc() -> bool {
	return g_plan.state == .Exit_Pending
}

// plan_mode_chip: short header token (empty if inactive).
plan_mode_chip :: proc() -> string {
	switch g_plan.state {
	case .Active:
		return " plan"
	case .Pending:
		return " plan…"
	case .Exit_Pending:
		return " plan↓"
	case .Inactive:
		return ""
	}
	return ""
}

// set_plan_mode_active: load-path compatibility (bool only).
set_plan_mode_active :: proc(on: bool) {
	if on {
		g_plan.state = .Active
		g_plan.was_previously_active = true
	} else {
		g_plan.state = .Inactive
	}
}

// snapshot fields for session persist
plan_mode_snapshot_for_save :: proc() -> Plan_Mode_Tracker {
	return g_plan
}

// sync_plan_mode_from_session restores tracker from session snapshot.
// Collapses Pending → Inactive; Exit_Pending → Inactive + pending_exit_reminder.
sync_plan_mode_from_session :: proc(
	plan_mode: bool,
	state_s: string = "",
	was_active := false,
	reminder_count: u32 = 0,
	pending_exit := false,
	awaiting_approval := false,
) {
	st: Plan_Mode_State = .Inactive
	if state_s != "" {
		st = plan_state_from_string(state_s)
	} else if plan_mode {
		// legacy bool-only sessions
		st = .Active
	}
	exit_rem := pending_exit
	// Collapse transients on load
	switch st {
	case .Pending:
		st = .Inactive
	case .Exit_Pending:
		st = .Inactive
		exit_rem = true
	case .Active, .Inactive:
	}
	g_plan = Plan_Mode_Tracker {
		state                  = st,
		was_previously_active  = was_active || st == .Active,
		reminder_count         = reminder_count,
		pending_exit_reminder  = exit_rem,
		awaiting_plan_approval = awaiting_approval && st == .Active,
		resume_activation      = st == .Active,
	}
}

// clear_plan_mode_for_new_session resets plan state on /new.
clear_plan_mode_for_new_session :: proc() {
	g_plan = {}
}

plan_state_to_string :: proc(st: Plan_Mode_State) -> string {
	switch st {
	case .Inactive:
		return "inactive"
	case .Pending:
		return "pending"
	case .Active:
		return "active"
	case .Exit_Pending:
		return "exit_pending"
	}
	return "inactive"
}

plan_state_from_string :: proc(s: string) -> Plan_Mode_State {
	switch strings.to_lower(strings.trim_space(s), context.temp_allocator) {
	case "pending":
		return .Pending
	case "active":
		return .Active
	case "exit_pending", "exitpending":
		return .Exit_Pending
	}
	return .Inactive
}

// plan_file_path_for_cwd returns absolute path to <cwd>/.grok/plan.md.
plan_file_path_for_cwd :: proc(cwd: string, allocator := context.allocator) -> string {
	ws := cwd
	if ws == "" {
		ws = "."
	}
	if abs, err := filepath.abs(ws, context.temp_allocator); err == nil {
		ws = abs
	}
	joined, jerr := filepath.join({ws, ".grok", "plan.md"}, allocator)
	if jerr != nil {
		return fmt.aprintf("%s/.grok/plan.md", ws, allocator = allocator)
	}
	if cleaned, cerr := filepath.clean(joined, allocator); cerr == nil {
		if joined != cleaned {
			delete(joined)
		}
		return cleaned
	}
	return joined
}

VIEW_PLAN_MAX_CHARS :: 8000

// handle_view_plan_slash: /view-plan | /show-plan — dump plan.md (B32 / Grok-shaped).
handle_view_plan_slash :: proc(cwd: string, allocator := context.allocator) -> string {
	path := plan_file_path_for_cwd(cwd, context.temp_allocator)
	if !os.exists(path) || os.is_directory(path) {
		return fmt.aprintf(
			"aether: no plan file at %s\n(use /plan to enter plan mode; agent writes the plan)",
			path,
			allocator = allocator,
		)
	}
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return fmt.aprintf("aether: cannot read plan %s: %v", path, rerr, allocator = allocator)
	}
	text := string(data)
	if strings.trim_space(text) == "" {
		return fmt.aprintf("aether: plan file empty: %s", path, allocator = allocator)
	}
	if len(text) > VIEW_PLAN_MAX_CHARS {
		return fmt.aprintf(
			"aether: plan (%s) — first %d chars:\n\n%s…",
			path,
			VIEW_PLAN_MAX_CHARS,
			text[:VIEW_PLAN_MAX_CHARS],
			allocator = allocator,
		)
	}
	return fmt.aprintf("aether: plan (%s)\n\n%s", path, text, allocator = allocator)
}

is_plan_file_write :: proc(target_path: string, plan_path: string) -> bool {
	if target_path == "" || plan_path == "" {
		return false
	}
	a := normalize_path_cmp(target_path, context.temp_allocator)
	b := normalize_path_cmp(plan_path, context.temp_allocator)
	return a == b
}

normalize_path_cmp :: proc(p: string, allocator := context.allocator) -> string {
	t := p
	if abs, err := filepath.abs(p, context.temp_allocator); err == nil {
		t = abs
	}
	if cleaned, cerr := filepath.clean(t, allocator); cerr == nil {
		return cleaned
	}
	return strings.clone(t, allocator)
}

seed_plan_file :: proc(plan_path: string) -> string {
	if plan_path == "" {
		return "missing"
	}
	if data, err := os.read_entire_file(plan_path, context.temp_allocator); err == nil {
		if len(data) == 0 {
			return "empty"
		}
		return "nonempty"
	}
	dir := filepath.dir(plan_path)
	if dir != "" && dir != "." {
		_ = os.make_directory_all(dir)
	}
	if err := os.write_entire_file(plan_path, []byte{}); err != nil {
		return "not_created"
	}
	return "empty"
}

// append_plan_user_intent writes /plan <desc> seed into plan file.
append_plan_user_intent :: proc(plan_path, desc: string) -> bool {
	d := strings.trim_space(desc)
	if d == "" || plan_path == "" {
		return false
	}
	_ = seed_plan_file(plan_path)
	existing: string
	if data, err := os.read_entire_file(plan_path, context.temp_allocator); err == nil {
		existing = string(data)
	}
	block := fmt.tprintf("\n## User intent\n\n%s\n", d)
	if strings.trim_space(existing) == "" {
		block = fmt.tprintf("# Plan\n\n## User intent\n\n%s\n", d)
	}
	body := fmt.tprintf("%s%s", existing, block)
	return os.write_entire_file(plan_path, transmute([]byte)body) == nil
}

// --- Tracker transitions ---

// user_toggle_on: /plan or Shift+Tab → Pending (or re-enter Active from Exit_Pending).
user_toggle_on :: proc(cwd: string) -> bool {
	plan_path := plan_file_path_for_cwd(cwd, context.temp_allocator)
	_ = seed_plan_file(plan_path)
	switch g_plan.state {
	case .Inactive:
		g_plan.state = .Pending
		g_plan.pending_exit_reminder = false
		return true
	case .Exit_Pending:
		// model still has plan context
		g_plan.state = .Active
		g_plan.pending_exit_reminder = false
		return true
	case .Pending, .Active:
		return false
	}
	return false
}

// user_toggle_off: turn_in_flight → Exit_Pending when Active.
user_toggle_off :: proc(turn_in_flight: bool) {
	g_plan.awaiting_plan_approval = false
	switch g_plan.state {
	case .Pending:
		g_plan.state = .Inactive
	case .Active:
		if turn_in_flight {
			g_plan.state = .Exit_Pending
		} else {
			g_plan.state = .Inactive
			g_plan.pending_exit_reminder = true
		}
	case .Exit_Pending, .Inactive:
	}
}

// complete_deferred_exit: turn ended while Exit_Pending.
complete_deferred_exit :: proc() {
	if g_plan.state != .Exit_Pending {
		return
	}
	g_plan.state = .Inactive
	g_plan.pending_exit_reminder = true
}

// activate_from_pending: first agent turn while Pending.
activate_from_pending :: proc() -> bool {
	if g_plan.state != .Pending {
		return false
	}
	g_plan.state = .Active
	g_plan.was_previously_active = true
	g_plan.reminder_count = 0
	return true
}

// activate_from_tool: model enter_plan_mode approved.
activate_from_tool :: proc() -> bool {
	// Allow from Inactive or Pending (tool supersedes pending)
	if g_plan.state == .Active {
		return false
	}
	g_plan.state = .Active
	g_plan.was_previously_active = true
	g_plan.reminder_count = 0
	g_plan.pending_exit_reminder = false
	g_plan.awaiting_plan_approval = false
	return true
}

// deactivate_approved: exit_plan_mode approved or abandon.
deactivate_approved :: proc() -> bool {
	if g_plan.state != .Active && g_plan.state != .Exit_Pending {
		return false
	}
	g_plan.state = .Inactive
	g_plan.reminder_count = 0
	g_plan.awaiting_plan_approval = false
	// no pending_exit_reminder — tool result is the signal
	g_plan.pending_exit_reminder = false
	return true
}

// --- Model tools ---

enter_plan_mode_impl :: proc(
	cwd: string,
	on_plan_enter: Plan_Enter_Handler = nil,
	allocator := context.allocator,
) -> string {
	if !plan_mode_enabled() {
		return strings.clone("error: plan mode is disabled (AETHER_NO_PLAN_MODE)", allocator)
	}
	plan_path := plan_file_path_for_cwd(cwd, context.temp_allocator)
	if g_plan.state == .Active {
		return fmt.aprintf(
			"Already in plan mode.\n\nPlan file: %s\n\nExplore the codebase and write your plan only to that file. When ready, call exit_plan_mode.",
			plan_path,
			allocator = allocator,
		)
	}

	// User approval before enter (Grok requires UI confirmation)
	approved := false
	if on_plan_enter != nil {
		approved = on_plan_enter()
	} else {
		approved = default_plan_enter_ask()
	}
	if !approved {
		return strings.clone("User declined to enter plan mode.", allocator)
	}

	seed := seed_plan_file(plan_path)
	_ = activate_from_tool()

	seed_msg: string
	switch seed {
	case "empty":
		seed_msg = "The plan file exists and is empty."
	case "nonempty":
		seed_msg = "The plan file exists but is not empty (prior content preserved)."
	case "not_created":
		seed_msg = "Could not create the plan file — create it at that path first if needed."
	case:
		seed_msg = "The plan file location may be unavailable."
	}

	return fmt.aprintf(
		`You have entered plan mode. Focus on exploring the codebase and creating an implementation plan.

Plan file: %s
%s

Rules while in plan mode:
1. Prefer read/search/shell tools to understand the workspace.
2. Do NOT edit project source — the only writable path is the plan file above.
3. Write your plan to the plan file (use search_replace with empty old_string to create/overwrite the plan body).
4. When the plan is ready, call exit_plan_mode (no arguments) to present it and leave plan mode.

Do not call enter_plan_mode again unless you left plan mode.`,
		plan_path,
		seed_msg,
		allocator = allocator,
	)
}

exit_plan_mode_impl :: proc(
	cwd: string,
	on_plan_exit: Plan_Exit_Handler = nil,
	allocator := context.allocator,
) -> string {
	// Active or Exit_Pending (user mid-turn off) can still present plan
	if g_plan.state != .Active && g_plan.state != .Exit_Pending {
		return strings.clone(
			"error: not in plan mode (call enter_plan_mode first, or /plan)",
			allocator,
		)
	}
	plan_path := plan_file_path_for_cwd(cwd, context.temp_allocator)

	content: string
	if data, err := os.read_entire_file(plan_path, context.temp_allocator); err == nil {
		content = strings.trim_space(string(data))
	}
	preview := content
	if len(preview) > 4000 {
		preview = fmt.tprintf("%s…", preview[:3997])
	}

	g_plan.awaiting_plan_approval = true
	res: Plan_Exit_Result
	if on_plan_exit != nil {
		res = on_plan_exit(plan_path, preview)
	} else {
		res = default_plan_exit_ask(plan_path, preview)
	}
	g_plan.awaiting_plan_approval = false

	switch res.outcome {
	case .Cancelled:
		fb := strings.trim_space(res.feedback)
		if fb == "" {
			return strings.clone(
				"The user wants to revise the plan. Ask the user what changes they would like to make.",
				allocator,
			)
		}
		return fmt.aprintf(
			"The user wants to revise the plan. The user said:\n%s",
			fb,
			allocator = allocator,
		)
	case .Abandoned:
		_ = deactivate_approved()
		return strings.clone(
			"The user chose to abandon the plan entirely (via the Abandon option in the plan approval dialog). Plan mode has been disabled. Do not call exit_plan_mode again unless the user explicitly asks to re-enter plan mode.",
			allocator,
		)
	case .Approved:
		_ = deactivate_approved()
		// Grok: approve w/ comments attaches review notes to the approval result.
		fb := strings.trim_space(res.feedback)
		if content == "" {
			if fb != "" {
				return fmt.aprintf(
					"Plan mode exit approved. No plan content was found at %s — you can proceed with coding.\n\nUser comments:\n%s",
					plan_path,
					fb,
					allocator = allocator,
				)
			}
			return fmt.aprintf(
				"Plan mode exit approved. No plan content was found at %s — you can proceed with coding.",
				plan_path,
				allocator = allocator,
			)
		}
		if fb != "" {
			return fmt.aprintf(
				"Your plan has been approved. You can now start coding.\n\nPlan file: %s\n\n## Plan:\n%s\n\n## User comments:\n%s",
				plan_path,
				content,
				fb,
				allocator = allocator,
			)
		}
		return fmt.aprintf(
			"Your plan has been approved. You can now start coding.\n\nPlan file: %s\n\n## Plan:\n%s",
			plan_path,
			content,
			allocator = allocator,
		)
	}
	return strings.clone("error: unknown plan exit outcome", allocator)
}

default_plan_enter_ask :: proc() -> bool {
	force_ask := false
	if v := os.get_env("AETHER_PLAN_ENTER_ASK", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") {
		force_ask = true
	}
	if !terminal.is_terminal(os.stdin) {
		if force_ask {
			return false
		}
		return true // headless auto-approve
	}
	fmt.eprintf("aether: enter plan mode? [y/N] ")
	line, ok := read_stdin_line(context.temp_allocator)
	if !ok {
		return false
	}
	t := strings.to_lower(strings.trim_space(line), context.temp_allocator)
	return t == "y" || t == "yes"
}

// default_plan_exit_ask: REPL/TTY — Grok letters a/s/q (legacy y/n still accepted).
// Headless auto-approves unless AETHER_PLAN_EXIT_ASK=1.
default_plan_exit_ask :: proc(plan_path, plan_preview: string) -> Plan_Exit_Result {
	force_ask := false
	if v := os.get_env("AETHER_PLAN_EXIT_ASK", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") {
		force_ask = true
	}
	if !terminal.is_terminal(os.stdin) {
		if force_ask {
			return Plan_Exit_Result{outcome = .Cancelled}
		}
		return Plan_Exit_Result{outcome = .Approved}
	}
	fmt.eprintf("aether: exit plan mode?\n  plan: %s\n", plan_path)
	if plan_preview != "" {
		pv := plan_preview
		if len(pv) > 400 {
			pv = pv[:400]
		}
		fmt.eprintf("  preview: %s\n", pv)
	}
	fmt.eprintf("  [a] approve  [s] request changes  [q] quit plan\n  (legacy: y/n)\n  choice: ")
	line, ok := read_stdin_line(context.temp_allocator)
	if !ok {
		return Plan_Exit_Result{outcome = .Cancelled}
	}
	t := strings.trim_space(line)
	low := strings.to_lower(t, context.temp_allocator)
	// Grok primary letters
	if low == "a" || low == "approve" || low == "y" || low == "yes" {
		return Plan_Exit_Result{outcome = .Approved}
	}
	if low == "q" || low == "quit" || low == "abandon" {
		return Plan_Exit_Result{outcome = .Abandoned}
	}
	// s / n / freeform → revise (Cancelled)
	fb := ""
	if strings.has_prefix(low, "s ") ||
	   strings.has_prefix(low, "n ") ||
	   strings.has_prefix(low, "no ") {
		if i := strings.index_byte(t, ' '); i >= 0 && i + 1 < len(t) {
			fb = strings.trim_space(t[i + 1:])
		}
	} else if low != "s" &&
	          low != "n" &&
	          low != "no" &&
	          low != "revise" &&
	          low != "" {
		// treat whole line as feedback cancel
		fb = t
	}
	return Plan_Exit_Result{outcome = .Cancelled, feedback = fb}
}

// user_enter_plan_mode for /plan and Shift+Tab — Pending (not Active until inject).
user_enter_plan_mode :: proc(
	cwd: string,
	desc: string = "",
	allocator := context.allocator,
) -> string {
	if !plan_mode_enabled() {
		return strings.clone("plan mode disabled (AETHER_NO_PLAN_MODE)", allocator)
	}
	plan_path := plan_file_path_for_cwd(cwd, context.temp_allocator)
	if g_plan.state == .Active || g_plan.state == .Pending {
		if desc != "" {
			_ = append_plan_user_intent(plan_path, desc)
			return fmt.aprintf(
				"plan mode already on — appended intent to %s",
				plan_path,
				allocator = allocator,
			)
		}
		return fmt.aprintf(
			"plan mode already on — plan file: %s",
			plan_path,
			allocator = allocator,
		)
	}
	changed := user_toggle_on(cwd)
	if desc != "" {
		_ = append_plan_user_intent(plan_path, desc)
	}
	if !changed && g_plan.state != .Pending && g_plan.state != .Active {
		return strings.clone("plan mode unchanged", allocator)
	}
	return fmt.aprintf(
		"plan mode ON (pending) — next turn activates; write plan only to %s (Shift+Tab cycles; /plan off to leave)",
		plan_path,
		allocator = allocator,
	)
}

// user_exit_plan_mode for /plan off and Shift+Tab.
// turn_in_flight: true when a model turn is running (Exit_Pending).
user_exit_plan_mode :: proc(
	cwd: string,
	turn_in_flight := false,
	allocator := context.allocator,
) -> string {
	if g_plan.state == .Inactive {
		return strings.clone("plan mode already off", allocator)
	}
	plan_path := plan_file_path_for_cwd(cwd, context.temp_allocator)
	was := g_plan.state
	user_toggle_off(turn_in_flight)
	if g_plan.state == .Exit_Pending {
		return fmt.aprintf(
			"plan mode exit deferred (turn in flight) — will leave after turn (plan: %s)",
			plan_path,
			allocator = allocator,
		)
	}
	_ = was
	return fmt.aprintf(
		"plan mode OFF — full edits allowed again (plan file: %s)",
		plan_path,
		allocator = allocator,
	)
}

plan_mode_edit_rejected :: proc(plan_path: string, allocator := context.allocator) -> string {
	return fmt.aprintf(
		"Rejected: file edits are not allowed in plan mode - the only editable file is the plan file (%s).",
		plan_path,
		allocator = allocator,
	)
}

// plan_mode_blocks_write_tool: AccessKind::Edit tools other than plan file.
// Grok only gates Edit; bash/web/MCP flow normally.
plan_mode_blocks_write_tool :: proc(tool_name: string) -> bool {
	if !plan_mode_is_active() {
		return false
	}
	switch tool_name {
	case "search_replace",
	     "write",
	     "delete_file",
	     "image_gen",
	     "image_edit",
	     "image_to_video",
	     "reference_to_video":
		return true
	}
	return false
}

resolve_edit_target_abs :: proc(
	workspace: string,
	file_path: string,
	allocator := context.allocator,
) -> (
	abs: string,
	ok: bool,
) {
	a, inside := tools.resolve_in_workspace(workspace, file_path, allocator)
	return a, inside
}

// Reminder texts
plan_activation_reminder_text :: proc(
	cwd: string,
	full: bool,
	reentry: bool,
	allocator := context.allocator,
) -> string {
	path := plan_file_path_for_cwd(cwd, context.temp_allocator)
	if reentry {
		return fmt.aprintf(
			`<system-reminder>
## Returning to Plan Mode
Plan mode is active again. Plan file: %s
Only edit that file. When ready, call exit_plan_mode.
</system-reminder>`,
			path,
			allocator = allocator,
		)
	}
	if !full {
		return strings.clone(
			`<system-reminder>
Plan mode is still active. Do not make any edits or writes to the system except for the plan file.
</system-reminder>`,
			allocator,
		)
	}
	return fmt.aprintf(
		`<system-reminder>
Plan mode is active. Do not edit project files — the only writable path is the plan file:
%s

Write or update the plan with search_replace. When ready, call exit_plan_mode (the user will be asked to approve).
</system-reminder>`,
		path,
		allocator = allocator,
	)
}

plan_exit_reminder_text :: proc(allocator := context.allocator) -> string {
	return strings.clone(
		`<system-reminder>
You have exited plan mode. You can now make edits, run tools, and take actions normally.
</system-reminder>`,
		allocator,
	)
}

// maybe_inject_plan_reminders: Pending→Active inject; exit reminder; resume Active re-brief.
maybe_inject_plan_reminders :: proc(
	msgs: ^[dynamic]Chat_Message,
	cwd: string,
	allocator := context.allocator,
) -> bool {
	injected := false

	// Deferred exit after turn
	if g_plan.state == .Exit_Pending {
		// complete at turn start of next turn if still Exit_Pending with no in-flight
		// (caller should call complete_deferred_exit at turn end; here as safety)
	}

	// Pending → activate + inject
	if g_plan.state == .Pending {
		reentry := g_plan.was_previously_active
		_ = activate_from_pending()
		full := g_plan.reminder_count % 2 == 0
		text := plan_activation_reminder_text(cwd, full, reentry, allocator)
		append(msgs, Chat_Message{role = .User, content = text})
		g_plan.reminder_count += 1
		g_plan.resume_activation = false
		injected = true
	} else if g_plan.state == .Active && g_plan.resume_activation {
		// Session resume re-brief (edit gate stays Active)
		full := true
		text := plan_activation_reminder_text(cwd, full, true, allocator)
		append(msgs, Chat_Message{role = .User, content = text})
		g_plan.reminder_count += 1
		g_plan.resume_activation = false
		injected = true
	}

	if g_plan.state == .Inactive && g_plan.pending_exit_reminder {
		append(
			msgs,
			Chat_Message {
				role    = .User,
				content = plan_exit_reminder_text(allocator),
			},
		)
		g_plan.pending_exit_reminder = false
		injected = true
	}
	return injected
}

// finish_plan_mode_turn: call at end of agent turn (success/cancel/error).
finish_plan_mode_turn :: proc() {
	complete_deferred_exit()
}

// --- Test helpers / snapshot isolation ---

plan_mode_save_tracker :: proc() -> Plan_Mode_Tracker {
	return g_plan
}

plan_mode_restore_tracker :: proc(t: Plan_Mode_Tracker) {
	g_plan = t
}
