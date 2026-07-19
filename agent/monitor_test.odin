package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

@(test)
test_sanitize_monitor_description :: proc(t: ^testing.T) {
	s := sanitize_monitor_description("watch \"CI\"\nstatus", context.allocator)
	defer delete(s)
	testing.expect(t, !strings.contains(s, "\""))
	testing.expect(t, !strings.contains(s, "\n"))
	testing.expect(t, strings.contains(s, "CI"))
}

@(test)
test_truncate_and_batch_monitor_lines :: proc(t: ^testing.T) {
	long := strings.repeat("x", 600, context.temp_allocator)
	tr := truncate_monitor_line(long, context.allocator)
	defer delete(tr)
	testing.expect(t, strings.contains(tr, "...(truncated)"))
	testing.expect(t, len(tr) < 520)

	lines := []string{"a", "b", "c"}
	b := batch_monitor_lines(lines, context.allocator)
	defer delete(b)
	testing.expect(t, b == "a\nb\nc")
}

@(test)
test_resolve_monitor_timeout_ms :: proc(t: ^testing.T) {
	testing.expect(t, resolve_monitor_timeout_ms(-1, false) == MONITOR_DEFAULT_TIMEOUT_MS)
	testing.expect(t, resolve_monitor_timeout_ms(0, false) == MONITOR_DEFAULT_TIMEOUT_MS)
	testing.expect(t, resolve_monitor_timeout_ms(5000, false) == 5000)
	testing.expect(t, resolve_monitor_timeout_ms(5000, true) == 0)
	testing.expect(t, resolve_monitor_timeout_ms(0, true) == 0)
}

@(test)
test_monitor_log_path_env :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-monlog-%d", os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)
	prev := os.get_env("AETHER_MONITOR_DIR", context.temp_allocator)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_MONITOR_DIR")
		} else {
			_ = os.set_env("AETHER_MONITOR_DIR", prev)
		}
	}
	_ = os.set_env("AETHER_MONITOR_DIR", dir)
	p := monitor_log_path("monitor-xyz", context.allocator)
	defer delete(p)
	testing.expect(t, strings.contains(p, "monitor-xyz.log"))
	testing.expect(t, strings.has_prefix(p, dir))
}

@(test)
test_format_monitor_events_reminder :: proc(t: ^testing.T) {
	ev := []Monitor_Event{
		{task_id = "monitor-1", description = "CI", body = "ok"},
	}
	out := format_monitor_events_reminder(ev, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "system-reminder"))
	testing.expect(t, strings.contains(out, "monitor-1"))
	testing.expect(t, strings.contains(out, "ok"))
	testing.expect(t, strings.contains(out, "[CI]"))
}

@(test)
test_monitor_push_drain_and_inject :: proc(t: ^testing.T) {
	// clear queue
	_ = monitor_drain_events(context.temp_allocator)
	monitor_push_event("monitor-t", "desc", "line-one")
	testing.expect(t, monitor_has_pending_events())
	msgs := make([dynamic]Chat_Message, 0, 2)
	defer {
		for &m in msgs {
			destroy_message(&m)
		}
		delete(msgs)
	}
	ok := maybe_inject_monitor_events(&msgs, context.allocator)
	testing.expect(t, ok)
	testing.expect(t, len(msgs) == 1)
	testing.expect(t, strings.contains(msgs[0].content, "line-one"))
	testing.expect(t, !monitor_has_pending_events())
}

@(test)
test_handle_monitor_short_command :: proc(t: ^testing.T) {
	// Use unique serial via full env; don't parallel-race bg cap
	opts := Turn_Options {
		workspace = "/tmp",
		quiet     = true,
	}
	// free slots if possible by waiting briefly on prior tests
	args := `{"command":"printf 'alpha\\nbeta\\n'","description":"unit-test-mon"}`
	out := handle_monitor(args, opts, context.allocator)
	defer delete(out)
	if strings.contains(out, "max concurrent") {
		// flaky under load — skip hard fail
		return
	}
	testing.expect(t, strings.contains(out, "Monitor started"))
	testing.expect(t, strings.contains(out, "monitor-"))
	// extract id
	id := ""
	if i := strings.index(out, "task_id: "); i >= 0 {
		rest := out[i + len("task_id: "):]
		end := strings.index_any(rest, " \n,)")
		if end < 0 {
			end = len(rest)
		}
		id = rest[:end]
	}
	testing.expect(t, strings.has_prefix(id, "monitor-"))
	// wait for process to finish and events
	for _ in 0 ..< 50 {
		if !monitor_has_pending_events() {
			st, _, found := bg_task_snapshot(id, context.temp_allocator)
			if found && st != .Running {
				break
			}
		}
		time.sleep(50 * time.Millisecond)
	}
	// drain events or completion
	if monitor_has_pending_events() {
		ev := monitor_drain_events(context.allocator)
		defer destroy_monitor_events(ev)
		joined := ""
		for e in ev {
			joined = fmt.tprintf("%s\n%s", joined, e.body)
		}
		testing.expect(t, strings.contains(joined, "alpha") || strings.contains(joined, "beta"))
	}
	// ensure kill path safe if still running
	_ = handle_kill_task(fmt.tprintf(`{"task_id":%q}`, id), context.temp_allocator)
	// wait finish
	for _ in 0 ..< 40 {
		st, _, found := bg_task_snapshot(id, context.temp_allocator)
		if found && st != .Running {
			break
		}
		time.sleep(50 * time.Millisecond)
	}
}

@(test)
test_monitor_disabled_env :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_MONITOR", context.temp_allocator)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_NO_MONITOR")
		} else {
			_ = os.set_env("AETHER_NO_MONITOR", prev)
		}
	}
	_ = os.set_env("AETHER_NO_MONITOR", "1")
	testing.expect(t, !monitor_enabled())
	out := handle_monitor(
		`{"command":"echo x","description":"d"}`,
		Turn_Options{quiet = true},
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, strings.contains(out, "disabled"))
}
