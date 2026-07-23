// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "aether:agent"
import "aether:core"

@(test)
test_plan_approval_status_label :: proc(t: ^testing.T) {
	testing.expect(t, plan_approval_status_label(true) == "Waiting on plan approval")
	testing.expect(
		t,
		plan_approval_status_label(false) == "No plan written — approve or request changes",
	)
}

@(test)
test_plan_approval_empty_body_placeholder :: proc(t: ^testing.T) {
	tmp := "/tmp/aether-plan-appr-empty"
	_ = os.make_directory_all(tmp)
	path, _ := filepath.join({tmp, "plan.md"}, context.temp_allocator)
	_ = os.write_entire_file(path, transmute([]byte)string(""))

	body, has := plan_approval_load_body(path, context.temp_allocator)
	testing.expect(t, !has)
	testing.expect(t, strings.contains(body, "No plan written yet"), body)

	// missing file
	miss, _ := filepath.join({tmp, "nope.md"}, context.temp_allocator)
	body2, has2 := plan_approval_load_body(miss, context.temp_allocator)
	testing.expect(t, !has2)
	testing.expect(t, strings.contains(body2, "No plan written yet"), body2)
}

@(test)
test_plan_approval_load_nonempty :: proc(t: ^testing.T) {
	tmp := "/tmp/aether-plan-appr-body"
	_ = os.make_directory_all(tmp)
	path, _ := filepath.join({tmp, "plan.md"}, context.temp_allocator)
	src := "# Plan\n\n## Step 1\nDo the thing\n"
	testing.expect(t, os.write_entire_file(path, transmute([]byte)src) == nil)

	body, has := plan_approval_load_body(path, context.temp_allocator)
	testing.expect(t, has)
	testing.expect(t, strings.contains(body, "Do the thing"), body)
}

@(test)
test_plan_approval_format_feedback :: proc(t: ^testing.T) {
	p: Plan_Approval_View
	plan_approval_init(&p)
	defer plan_approval_destroy(&p)

	append(
		&p.comments,
		Plan_Comment{id = 0, line_start = 3, line_end = 4, text = strings.clone("fix auth")},
	)
	fb := plan_approval_format_feedback(&p, "also rate limit", context.temp_allocator)
	testing.expect(t, strings.contains(fb, "@plan.md:3"), fb)
	testing.expect(t, strings.contains(fb, "fix auth"), fb)
	testing.expect(t, strings.contains(fb, "Additional feedback:"), fb)
	testing.expect(t, strings.contains(fb, "also rate limit"), fb)

	// freeform only
	for c in p.comments {
		delete(c.text)
	}
	clear(&p.comments)
	fb2 := plan_approval_format_feedback(&p, "just freeform", context.temp_allocator)
	testing.expect(t, fb2 == "just freeform", fb2)

	// empty
	fb3 := plan_approval_format_feedback(&p, "  ", context.temp_allocator)
	testing.expect(t, fb3 == "", fb3)
}

@(test)
test_plan_approval_action_bar_with_comments :: proc(t: ^testing.T) {
	p: Plan_Approval_View
	plan_approval_init(&p)
	defer plan_approval_destroy(&p)
	lab := plan_approval_action_bar_label(&p)
	testing.expect(t, strings.contains(lab, "a approve"), lab)
	testing.expect(t, !strings.contains(lab, "w/ comments"), lab)

	append(
		&p.comments,
		Plan_Comment{id = 1, line_start = 1, line_end = 2, text = strings.clone("n")},
	)
	lab2 := plan_approval_action_bar_label(&p)
	testing.expect(t, strings.contains(lab2, "approve w/ comments"), lab2)
}

@(test)
test_cycle_mode_grok_ring :: proc(t: ^testing.T) {
	// Normal → Plan → Always-Approve → Normal (Ask)
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	agent.clear_plan_mode_for_new_session()
	defer agent.clear_plan_mode_for_new_session()

	perm := core.Permission_Mode.Ask
	before := core.Permission_Mode.Ask
	st.perm = strings.clone("ask")

	// 1) Ask → Plan
	cycle_mode(&st, &perm, &before, ".")
	testing.expect(t, agent.plan_mode_is_pending() || agent.plan_mode_is_active())
	testing.expect(t, perm == .Ask, "underlying perm stays Ask under plan")

	// 2) Plan → Always-Approve
	cycle_mode(&st, &perm, &before, ".")
	testing.expect(t, !agent.plan_mode_is_pending() && !agent.plan_mode_is_active())
	testing.expect(t, !agent.plan_mode_is_exit_pending())
	testing.expect(t, perm == .Always_Approve)

	// 3) Always-Approve → Ask
	cycle_mode(&st, &perm, &before, ".")
	testing.expect(t, perm == .Ask)
}
