package agent

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_is_plan_file_write_exact :: proc(t: ^testing.T) {
	testing.expect(t, is_plan_file_write("/tmp/ws/.grok/plan.md", "/tmp/ws/.grok/plan.md"))
	testing.expect(t, !is_plan_file_write("/tmp/ws/src/main.odin", "/tmp/ws/.grok/plan.md"))
	testing.expect(t, !is_plan_file_write("", "/tmp/ws/.grok/plan.md"))
}

@(test)
test_plan_file_path_for_cwd :: proc(t: ^testing.T) {
	p := plan_file_path_for_cwd("/tmp/aether-plan-test-ws")
	defer delete(p)
	testing.expect(t, strings.contains(p, ".grok"))
	testing.expect(t, strings.has_suffix(p, "plan.md"))
}

@(test)
test_view_plan_slash :: proc(t: ^testing.T) {
	tmp := "/tmp/aether-view-plan-test"
	_ = os.remove_all(tmp)
	testing.expect(t, os.make_directory_all(tmp) == nil)
	defer os.remove_all(tmp)

	missing := handle_view_plan_slash(tmp, context.allocator)
	defer delete(missing)
	testing.expect(t, strings.contains(missing, "no plan file"), missing)

	plan := plan_file_path_for_cwd(tmp, context.temp_allocator)
	parent := filepath.dir(plan)
	testing.expect(t, os.make_directory_all(parent) == nil)
	_ = os.write_entire_file(plan, transmute([]byte)string("# My Plan\n\n- step one\n"))

	out := handle_view_plan_slash(tmp, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "My Plan"), out)
	testing.expect(t, strings.contains(out, "step one"), out)
}

test_plan_exit_yes :: proc(path, preview: string) -> Plan_Exit_Result {
	return Plan_Exit_Result{outcome = .Approved}
}
test_plan_exit_no :: proc(path, preview: string) -> Plan_Exit_Result {
	return Plan_Exit_Result{outcome = .Cancelled}
}
test_plan_exit_abandon :: proc(path, preview: string) -> Plan_Exit_Result {
	return Plan_Exit_Result{outcome = .Abandoned}
}
test_plan_exit_revise_fb :: proc(path, preview: string) -> Plan_Exit_Result {
	return Plan_Exit_Result{outcome = .Cancelled, feedback = "add error handling"}
}
test_plan_enter_yes :: proc() -> bool { return true }
test_plan_enter_no :: proc() -> bool { return false }

@(test)
test_seed_and_enter_exit_plan_mode :: proc(t: ^testing.T) {
	prev := plan_mode_save_tracker()
	defer plan_mode_restore_tracker(prev)
	clear_plan_mode_for_new_session()

	tmp := "/tmp/aether-plan-mode-test"
	_ = os.remove_all(tmp)
	_ = os.make_directory_all(tmp)
	defer {_ = os.remove_all(tmp)}

	plan := plan_file_path_for_cwd(tmp, context.temp_allocator)
	_ = os.remove(plan)

	status := seed_plan_file(plan)
	testing.expect(t, status == "empty")
	testing.expect(t, os.exists(plan))

	_ = os.write_entire_file(plan, transmute([]byte)string("# prior\n"))
	status = seed_plan_file(plan)
	testing.expect(t, status == "nonempty")
	data, _ := os.read_entire_file(plan, context.temp_allocator)
	testing.expect(t, string(data) == "# prior\n")

	msg := enter_plan_mode_impl(tmp, test_plan_enter_yes, context.temp_allocator)
	testing.expect(t, plan_mode_is_active())
	testing.expect(
		t,
		strings.contains(msg, "entered plan mode") || strings.contains(msg, "Already"),
	)
	// re-enter while active
	msg2 := enter_plan_mode_impl(tmp, test_plan_enter_yes, context.temp_allocator)
	testing.expect(t, strings.contains(msg2, "Already") || strings.contains(msg2, "already"))

	_ = os.write_entire_file(plan, transmute([]byte)string("## Step 1\nDo X\n"))
	out := exit_plan_mode_impl(tmp, test_plan_exit_yes, context.temp_allocator)
	testing.expect(
		t,
		strings.contains(out, "approved") ||
		strings.contains(out, "start coding") ||
		strings.contains(out, "Do X"),
	)
	testing.expect(t, !plan_mode_is_active())

	// exit when inactive
	err := exit_plan_mode_impl(tmp, test_plan_exit_yes, context.temp_allocator)
	testing.expect(t, strings.has_prefix(err, "error:"))
}

@(test)
test_enter_plan_declined :: proc(t: ^testing.T) {
	prev := plan_mode_save_tracker()
	defer plan_mode_restore_tracker(prev)
	clear_plan_mode_for_new_session()
	out := enter_plan_mode_impl("/tmp", test_plan_enter_no, context.temp_allocator)
	testing.expect(t, strings.contains(out, "declined to enter"))
	testing.expect(t, !plan_mode_is_active())
}

@(test)
test_exit_plan_deny_and_abandon :: proc(t: ^testing.T) {
	prev := plan_mode_save_tracker()
	defer plan_mode_restore_tracker(prev)
	clear_plan_mode_for_new_session()
	g_plan.state = .Active

	out := exit_plan_mode_impl("/tmp", test_plan_exit_no, context.temp_allocator)
	testing.expect(t, strings.contains(out, "revise") || strings.contains(out, "changes"))
	testing.expect(t, plan_mode_is_active())

	out2 := exit_plan_mode_impl("/tmp", test_plan_exit_revise_fb, context.temp_allocator)
	testing.expect(t, strings.contains(out2, "error handling"))
	testing.expect(t, plan_mode_is_active())

	out3 := exit_plan_mode_impl("/tmp", test_plan_exit_abandon, context.temp_allocator)
	testing.expect(t, strings.contains(out3, "abandon"))
	testing.expect(t, !plan_mode_is_active())
}

@(test)
test_plan_reminder_text_helpers :: proc(t: ^testing.T) {
	act := plan_activation_reminder_text("/tmp/aether-plan-rem-ws", true, false, context.temp_allocator)
	testing.expect(t, strings.contains(act, "system-reminder"))
	testing.expect(t, strings.contains(act, "plan.md"))
	sparse := plan_activation_reminder_text("/tmp/x", false, false, context.temp_allocator)
	testing.expect(t, strings.contains(sparse, "still active"))
	re := plan_activation_reminder_text("/tmp/x", true, true, context.temp_allocator)
	testing.expect(t, strings.contains(re, "Returning") || strings.contains(re, "again"))
	ex := plan_exit_reminder_text(context.temp_allocator)
	testing.expect(t, strings.contains(ex, "exited plan mode"))

	prev := plan_mode_save_tracker()
	defer plan_mode_restore_tracker(prev)
	clear_plan_mode_for_new_session()
	g_plan.state = .Pending
	g_plan.was_previously_active = false

	msgs: [dynamic]Chat_Message
	msgs.allocator = context.temp_allocator
	_ = maybe_inject_plan_reminders(&msgs, "/tmp/aether-plan-rem-ws", context.temp_allocator)
	testing.expect(t, plan_mode_is_active())
	testing.expect(t, len(msgs) > 0)
	testing.expect(t, strings.contains(msgs[0].content, "system-reminder"))
}

@(test)
test_user_plan_toggle_pending :: proc(t: ^testing.T) {
	prev := plan_mode_save_tracker()
	defer plan_mode_restore_tracker(prev)
	clear_plan_mode_for_new_session()

	tmp := "/tmp/aether-plan-mode-user"
	_ = os.remove_all(tmp)
	_ = os.make_directory_all(tmp)
	defer {_ = os.remove_all(tmp)}

	a := user_enter_plan_mode(tmp, "", context.temp_allocator)
	testing.expect(t, plan_mode_is_pending())
	testing.expect(t, !plan_mode_is_active()) // Pending does not edit-gate
	testing.expect(t, strings.contains(a, "ON") || strings.contains(a, "plan"))

	// inject activates
	msgs: [dynamic]Chat_Message
	msgs.allocator = context.temp_allocator
	_ = maybe_inject_plan_reminders(&msgs, tmp, context.temp_allocator)
	testing.expect(t, plan_mode_is_active())

	b := user_exit_plan_mode(tmp, false, context.temp_allocator)
	testing.expect(t, !plan_mode_is_active())
	testing.expect(t, strings.contains(b, "OFF") || strings.contains(b, "off"))
}

@(test)
test_exit_pending_mid_turn :: proc(t: ^testing.T) {
	prev := plan_mode_save_tracker()
	defer plan_mode_restore_tracker(prev)
	clear_plan_mode_for_new_session()
	g_plan.state = .Active

	_ = user_exit_plan_mode("/tmp", true, context.temp_allocator)
	testing.expect(t, plan_mode_is_exit_pending())
	finish_plan_mode_turn()
	testing.expect(t, !plan_mode_is_exit_pending())
	testing.expect(t, g_plan.pending_exit_reminder)
}

@(test)
test_plan_snapshot_collapse :: proc(t: ^testing.T) {
	prev := plan_mode_save_tracker()
	defer plan_mode_restore_tracker(prev)

	sync_plan_mode_from_session(true, "pending", true, 1, false, false)
	testing.expect(t, plan_mode_state() == .Inactive)

	sync_plan_mode_from_session(true, "exit_pending", true, 0, false, false)
	testing.expect(t, plan_mode_state() == .Inactive)
	testing.expect(t, g_plan.pending_exit_reminder)

	sync_plan_mode_from_session(true, "active", true, 2, false, true)
	testing.expect(t, plan_mode_is_active())
	testing.expect(t, g_plan.resume_activation)
	testing.expect(t, g_plan.awaiting_plan_approval)
}

@(test)
test_plan_mode_edit_rejected_msg :: proc(t: ^testing.T) {
	m := plan_mode_edit_rejected("/ws/.grok/plan.md", context.temp_allocator)
	testing.expect(t, strings.contains(m, "Rejected"))
	testing.expect(t, strings.contains(m, "plan.md"))
}

@(test)
test_plan_user_intent_append :: proc(t: ^testing.T) {
	prev := plan_mode_save_tracker()
	defer plan_mode_restore_tracker(prev)
	clear_plan_mode_for_new_session()

	tmp := "/tmp/aether-plan-intent"
	_ = os.remove_all(tmp)
	_ = os.make_directory_all(tmp)
	defer {_ = os.remove_all(tmp)}

	_ = user_enter_plan_mode(tmp, "ship the feature", context.temp_allocator)
	plan := plan_file_path_for_cwd(tmp, context.temp_allocator)
	data, err := os.read_entire_file(plan, context.temp_allocator)
	testing.expect(t, err == nil)
	testing.expect(t, strings.contains(string(data), "ship the feature"))
	testing.expect(t, strings.contains(string(data), "User intent"))
}
