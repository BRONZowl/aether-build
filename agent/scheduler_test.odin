package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"

@(test)
test_parse_interval_and_human :: proc(t: ^testing.T) {
	s, err := parse_interval("5m")
	testing.expect(t, err == "" && s == 300)
	s2, e2 := parse_interval("30s")
	testing.expect(t, e2 == "" && s2 == 60) // clamp min
	s3, e3 := parse_interval("2h")
	testing.expect(t, e3 == "" && s3 == 7200)
	_, e4 := parse_interval("nope")
	testing.expect(t, e4 != "")
	testing.expect(t, interval_to_human(300) == "every 5 minutes")
	testing.expect(t, interval_to_human(3600) == "every 1 hour")
}

@(test)
test_scheduler_create_list_delete :: proc(t: ^testing.T) {
	scheduler_clear()
	defer scheduler_clear()

	out := handle_scheduler_create(
		`{"interval":"5m","prompt":"check deploy","recurring":true}`,
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, strings.contains(out, "Scheduled task created"))
	testing.expect(t, strings.contains(out, "id:"))

	// extract id
	id := ""
	if i := strings.index(out, "id: "); i >= 0 {
		rest := out[i + 4:]
		end := strings.index_byte(rest, '\n')
		if end < 0 {
			end = len(rest)
		}
		id = strings.trim_space(rest[:end])
	}
	testing.expect(t, id != "")

	list := handle_scheduler_list("{}", context.allocator)
	defer delete(list)
	testing.expect(t, strings.contains(list, id))
	testing.expect(t, strings.contains(list, "check deploy"))

	del := handle_scheduler_delete(
		fmt_tprintf_sched_id(id),
		context.allocator,
	)
	defer delete(del)
	testing.expect(t, strings.contains(del, "success: true"))

	list2 := handle_scheduler_list("{}", context.allocator)
	defer delete(list2)
	testing.expect(t, strings.contains(list2, "No scheduled") || !strings.contains(list2, id))
}

fmt_tprintf_sched_id :: proc(id: string) -> string {
	return strings.concatenate([]string{`{"id":"`, id, `"}`}, context.temp_allocator)
}

@(test)
test_format_relative_unix :: proc(t: ^testing.T) {
	now: i64 = 1_000_000
	testing.expect(t, format_relative_unix(now, now) == "now")
	testing.expect(t, format_relative_unix(now + 30, now) == "now")
	testing.expect(t, format_relative_unix(now + 120, now) == "in 2m")
	testing.expect(t, format_relative_unix(now + 7200, now) == "in 2h")
	testing.expect(t, format_relative_unix(now - 120, now) == "overdue by 2m")
}

@(test)
test_task_is_missed_and_list_flag :: proc(t: ^testing.T) {
	scheduler_clear()
	defer scheduler_clear()
	// Create one-shot then force it into the past
	out := handle_scheduler_create(
		`{"interval":"5m","prompt":"missed job","recurring":false}`,
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, strings.contains(out, "created"))

	sync.mutex_lock(&g_sched_mu)
	if len(g_sched_tasks) > 0 {
		// created far in the past so next_fire < now and never fired
		g_sched_tasks[0].created_unix = unix_now() - 3600
		g_sched_tasks[0].last_fired = 0
		g_sched_tasks[0].recurring = false
	}
	sync.mutex_unlock(&g_sched_mu)

	now := unix_now()
	sync.mutex_lock(&g_sched_mu)
	missed := len(g_sched_tasks) > 0 && task_is_missed(g_sched_tasks[0], now)
	sync.mutex_unlock(&g_sched_mu)
	testing.expect(t, missed)

	list := handle_scheduler_list("{}", context.allocator)
	defer delete(list)
	testing.expect(t, strings.contains(list, "missed=true"))
	testing.expect(t, strings.contains(list, "next_fire="))
}

@(test)
test_scheduler_fire_immediately_one_shot :: proc(t: ^testing.T) {
	scheduler_clear()
	defer scheduler_clear()

	out := handle_scheduler_create(
		`{"interval":"5m","prompt":"do the thing","recurring":false,"fire_immediately":true}`,
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, strings.contains(out, "created"))
	testing.expect(t, scheduler_has_due())

	msgs := make([dynamic]Chat_Message, 0, 2)
	defer {
		for &m in msgs {
			destroy_message(&m)
		}
		delete(msgs)
	}
	ok := maybe_inject_scheduler_fires(&msgs, context.allocator)
	testing.expect(t, ok)
	testing.expect(t, len(msgs) == 1)
	testing.expect(t, strings.contains(msgs[0].content, "Scheduled task fired"))
	testing.expect(t, strings.contains(msgs[0].content, "do the thing"))
	// one-shot removed
	testing.expect(t, !scheduler_has_due())
	list := handle_scheduler_list("{}", context.allocator)
	defer delete(list)
	testing.expect(t, strings.contains(list, "No scheduled"))
}

@(test)
test_scheduler_disabled_env :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_SCHEDULER", context.temp_allocator)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_NO_SCHEDULER")
		} else {
			_ = os.set_env("AETHER_NO_SCHEDULER", prev)
		}
	}
	_ = os.set_env("AETHER_NO_SCHEDULER", "1")
	testing.expect(t, !scheduler_enabled())
	out := handle_scheduler_create(
		`{"interval":"5m","prompt":"x"}`,
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, strings.contains(out, "disabled"))
}

@(test)
test_task_next_fire_math :: proc(t: ^testing.T) {
	task := Scheduled_Task {
		interval_secs = 300,
		created_unix  = 1000,
		last_fired    = 0,
	}
	testing.expect(t, task_next_fire(task) == 1300)
	task.last_fired = 2000
	testing.expect(t, task_next_fire(task) == 2300)
	testing.expect(t, task_is_due(task, 2300))
	testing.expect(t, !task_is_due(task, 2299))
}

@(test)
test_parse_loop_create_args :: proc(t: ^testing.T) {
	iv, pr, err := parse_loop_create_args("30m check deploy status")
	testing.expect(t, err == "")
	testing.expect(t, iv == "30m")
	testing.expect(t, pr == "check deploy status")

	iv2, pr2, err2 := parse_loop_create_args("check deploy every hour")
	testing.expect(t, err2 == "")
	testing.expect(t, iv2 == "1h")
	testing.expect(t, pr2 == "check deploy")

	iv3, pr3, err3 := parse_loop_create_args("run tests every 2 days")
	testing.expect(t, err3 == "")
	testing.expect(t, iv3 == "2d")
	testing.expect(t, pr3 == "run tests")

	_, _, err4 := parse_loop_create_args("just do something")
	testing.expect(t, err4 != "")
}

@(test)
test_scheduler_durable_persist_and_reload :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/aether-sched-durable-%d.json", os.get_pid())
	prev := os.get_env("AETHER_SCHEDULER_PATH", context.temp_allocator)
	_ = os.set_env("AETHER_SCHEDULER_PATH", path)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_SCHEDULER_PATH")
		} else {
			_ = os.set_env("AETHER_SCHEDULER_PATH", prev)
		}
		_ = os.remove(path)
	}
	scheduler_clear()
	defer scheduler_clear()

	out := handle_scheduler_create(
		`{"interval":"5m","prompt":"durable check","recurring":true,"durable":true}`,
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, strings.contains(out, "durable: true"))
	testing.expect(t, os.exists(path))

	// non-durable must not be only entry after reload
	out2 := handle_scheduler_create(
		`{"interval":"5m","prompt":"ephemeral","recurring":true,"durable":false}`,
		context.allocator,
	)
	defer delete(out2)

	// simulate process restart
	scheduler_reset_for_reload()
	list := handle_scheduler_list("{}", context.allocator)
	defer delete(list)
	testing.expect(t, strings.contains(list, "durable check"))
	testing.expect(t, strings.contains(list, "durable=true"))
	testing.expect(t, !strings.contains(list, "ephemeral"))
}

@(test)
test_scheduler_clear_session_keeps_durable :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/aether-sched-sess-%d.json", os.get_pid())
	prev := os.get_env("AETHER_SCHEDULER_PATH", context.temp_allocator)
	_ = os.set_env("AETHER_SCHEDULER_PATH", path)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_SCHEDULER_PATH")
		} else {
			_ = os.set_env("AETHER_SCHEDULER_PATH", prev)
		}
		_ = os.remove(path)
	}
	scheduler_clear()
	defer scheduler_clear()

	_ = handle_scheduler_create(
		`{"interval":"5m","prompt":"keep me","recurring":true,"durable":true}`,
		context.allocator,
	)
	_ = handle_scheduler_create(
		`{"interval":"5m","prompt":"drop me","recurring":true,"durable":false}`,
		context.allocator,
	)
	scheduler_clear_session()
	list := handle_scheduler_list("{}", context.allocator)
	defer delete(list)
	testing.expect(t, strings.contains(list, "keep me"))
	testing.expect(t, !strings.contains(list, "drop me"))
}

@(test)
test_scheduler_missed_oneshot_due_after_reload :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/aether-sched-miss-%d.json", os.get_pid())
	prev := os.get_env("AETHER_SCHEDULER_PATH", context.temp_allocator)
	_ = os.set_env("AETHER_SCHEDULER_PATH", path)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_SCHEDULER_PATH")
		} else {
			_ = os.set_env("AETHER_SCHEDULER_PATH", prev)
		}
		_ = os.remove(path)
	}
	scheduler_clear()
	defer scheduler_clear()

	// create one-shot due immediately (fire_immediately) durable
	out := handle_scheduler_create(
		`{"interval":"5m","prompt":"missed job","recurring":false,"fire_immediately":true,"durable":true}`,
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, scheduler_has_due())

	// restart without firing
	scheduler_reset_for_reload()
	testing.expect(t, scheduler_has_due())
	msgs := make([dynamic]Chat_Message, 0, 2)
	defer {
		for &m in msgs {
			destroy_message(&m)
		}
		delete(msgs)
	}
	ok := maybe_inject_scheduler_fires(&msgs, context.allocator)
	testing.expect(t, ok)
	testing.expect(t, strings.contains(msgs[0].content, "missed job"))
}

@(test)
test_handle_loop_slash_create_list_stop :: proc(t: ^testing.T) {
	scheduler_clear()
	defer scheduler_clear()

	out := handle_loop_slash("5m hello loop", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "Scheduled task created"))
	testing.expect(t, strings.contains(out, "Cancel with"))

	list := handle_loop_slash("list", context.allocator)
	defer delete(list)
	testing.expect(t, strings.contains(list, "hello loop"))

	// extract id
	id := ""
	if i := strings.index(out, "id: "); i >= 0 {
		rest := out[i + 4:]
		end := strings.index_byte(rest, '\n')
		if end < 0 {
			end = len(rest)
		}
		id = strings.trim_space(rest[:end])
	}
	testing.expect(t, id != "")
	stop := handle_loop_slash(fmt.tprintf("stop %s", id), context.allocator)
	defer delete(stop)
	testing.expect(t, strings.contains(stop, "success: true"))
}
