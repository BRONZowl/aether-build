package agent

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_desktop_notify_enabled_env :: proc(t: ^testing.T) {
	prev_no := os.get_env("AETHER_NO_DESKTOP_NOTIFY", context.temp_allocator)
	prev_n := os.get_env("AETHER_NOTIFY", context.temp_allocator)
	defer {
		if prev_no == "" {
			_ = os.unset_env("AETHER_NO_DESKTOP_NOTIFY")
		} else {
			_ = os.set_env("AETHER_NO_DESKTOP_NOTIFY", prev_no)
		}
		if prev_n == "" {
			_ = os.unset_env("AETHER_NOTIFY")
		} else {
			_ = os.set_env("AETHER_NOTIFY", prev_n)
		}
	}
	_ = os.unset_env("AETHER_NO_DESKTOP_NOTIFY")
	_ = os.unset_env("AETHER_NOTIFY")
	testing.expect(t, desktop_notify_enabled())
	_ = os.set_env("AETHER_NO_DESKTOP_NOTIFY", "1")
	testing.expect(t, !desktop_notify_enabled())
	_ = os.unset_env("AETHER_NO_DESKTOP_NOTIFY")
	_ = os.set_env("AETHER_NOTIFY", "0")
	testing.expect(t, !desktop_notify_enabled())
}

@(test)
test_format_bg_notify :: proc(t: ^testing.T) {
	testing.expect(t, format_bg_notify_title(.Completed) == "aether: bg done")
	testing.expect(t, format_bg_notify_title(.Failed) == "aether: bg failed")
	body := format_bg_notify_body("bash-1-2", "sleep 30", .Completed, context.allocator)
	defer delete(body)
	testing.expect(t, strings.contains(body, "bash-1-2"))
	testing.expect(t, strings.contains(body, "completed"))
	testing.expect(t, strings.contains(body, "sleep 30"))
}

@(test)
test_desktop_notify_capture :: proc(t: ^testing.T) {
	prev_cap := g_notify_test_capture
	prev_count := g_notify_call_count
	g_notify_test_capture = true
	g_notify_call_count = 0
	if g_notify_last_title != "" {
		delete(g_notify_last_title)
		g_notify_last_title = ""
	}
	if g_notify_last_body != "" {
		delete(g_notify_last_body)
		g_notify_last_body = ""
	}
	defer {
		g_notify_test_capture = prev_cap
		g_notify_call_count = prev_count
		if g_notify_last_title != "" {
			delete(g_notify_last_title)
			g_notify_last_title = ""
		}
		if g_notify_last_body != "" {
			delete(g_notify_last_body)
			g_notify_last_body = ""
		}
	}

	_ = os.unset_env("AETHER_NO_DESKTOP_NOTIFY")
	_ = os.unset_env("AETHER_NOTIFY")
	desktop_notify("hello-title", "hello-body")
	testing.expect(t, g_notify_call_count == 1)
	testing.expect(t, g_notify_last_title == "hello-title")
	testing.expect(t, g_notify_last_body == "hello-body")
}

@(test)
test_maybe_notify_bg_task_respects_flag :: proc(t: ^testing.T) {
	prev_cap := g_notify_test_capture
	g_notify_test_capture = true
	g_notify_call_count = 0
	if g_notify_last_title != "" {
		delete(g_notify_last_title)
		g_notify_last_title = ""
	}
	if g_notify_last_body != "" {
		delete(g_notify_last_body)
		g_notify_last_body = ""
	}
	defer {
		g_notify_test_capture = prev_cap
		if g_notify_last_title != "" {
			delete(g_notify_last_title)
			g_notify_last_title = ""
		}
		if g_notify_last_body != "" {
			delete(g_notify_last_body)
			g_notify_last_body = ""
		}
	}
	_ = os.unset_env("AETHER_NO_DESKTOP_NOTIFY")

	task := Bg_Task {
		id          = "sub-1",
		description = "explore foo",
		status      = .Completed,
	}
	// With capture on and notify enabled, maybe_notify always fires for terminal tasks
	maybe_notify_bg_task(&task)
	testing.expect(t, g_notify_call_count == 1)
	testing.expect(t, strings.contains(g_notify_last_title, "bg done"))
	testing.expect(t, strings.contains(g_notify_last_body, "sub-1"))

	// Running tasks are ignored
	g_notify_call_count = 0
	task.status = .Running
	maybe_notify_bg_task(&task)
	testing.expect(t, g_notify_call_count == 0)
}

@(test)
test_format_turn_notify :: proc(t: ^testing.T) {
	testing.expect(t, format_turn_notify_title(0) == "aether: done")
	testing.expect(t, format_turn_notify_title(2) == "aether: max turns")
	testing.expect(t, format_turn_notify_title(4) == "aether: cancelled")
	testing.expect(t, format_turn_notify_title(3) == "aether: error")
	body := format_turn_notify_body("my session", "Hello world\nsecond", 0, context.allocator)
	defer delete(body)
	testing.expect(t, strings.contains(body, "my session"))
	testing.expect(t, strings.contains(body, "Hello world"))
	testing.expect(t, !strings.contains(body, "\n"))
}

@(test)
test_maybe_notify_agent_turn_capture :: proc(t: ^testing.T) {
	prev_cap := g_notify_test_capture
	g_notify_test_capture = true
	g_notify_call_count = 0
	if g_notify_last_title != "" {
		delete(g_notify_last_title)
		g_notify_last_title = ""
	}
	if g_notify_last_body != "" {
		delete(g_notify_last_body)
		g_notify_last_body = ""
	}
	prev_turns := os.get_env("AETHER_NOTIFY_TURNS", context.temp_allocator)
	prev_no := os.get_env("AETHER_NO_DESKTOP_NOTIFY", context.temp_allocator)
	defer {
		g_notify_test_capture = prev_cap
		if g_notify_last_title != "" {
			delete(g_notify_last_title)
			g_notify_last_title = ""
		}
		if g_notify_last_body != "" {
			delete(g_notify_last_body)
			g_notify_last_body = ""
		}
		if prev_turns == "" {
			_ = os.unset_env("AETHER_NOTIFY_TURNS")
		} else {
			_ = os.set_env("AETHER_NOTIFY_TURNS", prev_turns)
		}
		if prev_no == "" {
			_ = os.unset_env("AETHER_NO_DESKTOP_NOTIFY")
		} else {
			_ = os.set_env("AETHER_NO_DESKTOP_NOTIFY", prev_no)
		}
	}
	_ = os.unset_env("AETHER_NO_DESKTOP_NOTIFY")
	_ = os.unset_env("AETHER_NOTIFY_TURNS")
	maybe_notify_agent_turn(0, "sess", "preview text", ".")
	testing.expect(t, g_notify_call_count == 1)
	testing.expect(t, g_notify_last_title == "aether: done")
	testing.expect(t, strings.contains(g_notify_last_body, "sess"))
}

@(test)
test_turn_notify_enabled_env :: proc(t: ^testing.T) {
	prev_no := os.get_env("AETHER_NO_DESKTOP_NOTIFY", context.temp_allocator)
	prev_t := os.get_env("AETHER_NOTIFY_TURNS", context.temp_allocator)
	defer {
		if prev_no == "" {
			_ = os.unset_env("AETHER_NO_DESKTOP_NOTIFY")
		} else {
			_ = os.set_env("AETHER_NO_DESKTOP_NOTIFY", prev_no)
		}
		if prev_t == "" {
			_ = os.unset_env("AETHER_NOTIFY_TURNS")
		} else {
			_ = os.set_env("AETHER_NOTIFY_TURNS", prev_t)
		}
	}
	_ = os.unset_env("AETHER_NO_DESKTOP_NOTIFY")
	_ = os.unset_env("AETHER_NOTIFY")
	_ = os.unset_env("AETHER_NOTIFY_TURNS")
	testing.expect(t, turn_notify_enabled())
	_ = os.set_env("AETHER_NOTIFY_TURNS", "0")
	testing.expect(t, !turn_notify_enabled())
}
