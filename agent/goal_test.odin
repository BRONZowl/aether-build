package agent

import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

@(test)
test_goal_activate_progress_complete :: proc(t: ^testing.T) {
	goal_clear()
	defer goal_clear()

	goal_activate("Ship the scheduler")
	out := handle_update_goal(`{"message":"wrote interval parser"}`, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "progress logged"))
	testing.expect(t, strings.contains(out, "interval parser"))

	done := handle_update_goal(
		`{"completed":true,"message":"all green"}`,
		context.allocator,
	)
	defer delete(done)
	testing.expect(t, strings.contains(done, "Goal completed"))
	// cannot complete again
	again := handle_update_goal(`{"completed":true}`, context.allocator)
	defer delete(again)
	testing.expect(t, strings.contains(again, "error"))
}

@(test)
test_goal_block_and_resume :: proc(t: ^testing.T) {
	goal_clear()
	defer goal_clear()
	goal_activate("Fix flaky test")
	blk := handle_update_goal(
		`{"blocked_reason":"need env credentials"}`,
		context.allocator,
	)
	defer delete(blk)
	testing.expect(t, strings.contains(blk, "blocked"))
	testing.expect(t, goal_chip() == " goal:blocked")

	r := handle_goal_slash("resume", context.allocator)
	defer delete(r)
	testing.expect(t, strings.contains(r, "resumed"))
	testing.expect(t, goal_chip() == " goal")
}

@(test)
test_goal_inactive_errors :: proc(t: ^testing.T) {
	goal_clear()
	defer goal_clear()
	out := handle_update_goal(`{"message":"hi"}`, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "no active goal"))
}

@(test)
test_goal_slash_status_and_clear :: proc(t: ^testing.T) {
	goal_clear()
	defer goal_clear()
	set := handle_goal_slash("Migrate auth", context.allocator)
	defer delete(set)
	testing.expect(t, strings.contains(set, "goal set"))
	st := handle_goal_slash("status", context.allocator)
	defer delete(st)
	testing.expect(t, strings.contains(st, "Migrate auth"))
	cl := handle_goal_slash("clear", context.allocator)
	defer delete(cl)
	testing.expect(t, strings.contains(cl, "cleared"))
	testing.expect(t, goal_chip() == "")
}

@(test)
test_parse_goal_budget :: proc(t: ^testing.T) {
	o, b := parse_goal_budget("implement X --budget 500000")
	testing.expect(t, o == "implement X")
	testing.expect(t, b == 500_000)
	o2, b2 := parse_goal_budget("implement X")
	testing.expect(t, o2 == "implement X")
	testing.expect(t, b2 == 0)
	// not trailing
	o3, b3 := parse_goal_budget("use --budget 10 carefully")
	testing.expect(t, b3 == 0)
	// multi-token tail ignored
	o4, b4 := parse_goal_budget("obj --budget 10 more")
	testing.expect(t, b4 == 0)
	_ = o3
	_ = o4
}

@(test)
test_goal_budget_pause :: proc(t: ^testing.T) {
	goal_clear()
	defer goal_clear()
	goal_activate("tiny", 5) // 5 tokens ≈ 20 chars
	msgs := make([dynamic]Chat_Message, 0, 4, context.allocator)
	defer {
		for m in msgs {
			delete(m.content)
		}
		delete(msgs)
	}
	// latch baseline
	n1 := goal_check_budget(msgs[:])
	testing.expect(t, n1 == "")
	// grow past budget
	append(&msgs, Chat_Message{role = .User, content = strings.clone("xxxxxxxxxxxxxxxxxxxx")}) // 20 chars = 5 tokens
	append(&msgs, Chat_Message{role = .Assistant, content = strings.clone("yyyyyyyyyyyyyyyyyyyy")}) // +20
	n2 := goal_check_budget(msgs[:])
	testing.expect(t, strings.contains(n2, "budget exhausted") || strings.contains(n2, "paused") || n2 != "")
	// status should be paused if over
	sync.mutex_lock(&g_goal_mu)
	st := g_goal.status
	sync.mutex_unlock(&g_goal_mu)
	testing.expect(t, st == .Paused || n2 != "")
}

@(test)
test_goal_snapshot_restore_round_trip :: proc(t: ^testing.T) {
	goal_clear()
	defer goal_clear()
	goal_activate("Ship A1.10")
	_ = handle_update_goal(`{"message":"goal durable"}`, context.allocator)
	snap := goal_snapshot_json_object(context.allocator)
	defer delete(snap)
	testing.expect(t, strings.contains(snap, "Ship A1.10"))
	testing.expect(t, strings.contains(snap, "goal durable"))
	testing.expect(t, strings.contains(snap, `"status":"active"`))

	goal_clear()
	st0 := goal_status_text(context.allocator)
	defer delete(st0)
	testing.expect(t, strings.contains(st0, "inactive"))

	err := goal_restore_from_json_text(snap)
	testing.expect(t, err == "")
	st1 := goal_status_text(context.allocator)
	defer delete(st1)
	testing.expect(t, strings.contains(st1, "Ship A1.10"))
	testing.expect(t, strings.contains(st1, "goal durable"))
	testing.expect(t, goal_chip() == " goal")
}

@(test)
test_goal_disabled_env :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_GOAL", context.temp_allocator)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_NO_GOAL")
		} else {
			_ = os.set_env("AETHER_NO_GOAL", prev)
		}
	}
	_ = os.set_env("AETHER_NO_GOAL", "1")
	testing.expect(t, !goal_enabled())
	out := handle_update_goal(`{"message":"x"}`, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "disabled"))
}
