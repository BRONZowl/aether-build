// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

// scheduler — Grok-shaped scheduled prompts (product Full).
// Reference: crates/codegen/xai-grok-tools/.../scheduler/
// durable=true → ~/.grok/aether/scheduler.json (override AETHER_SCHEDULER_PATH)
// Multi-client notify bus N/A.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import "aether:core"
import "aether:tools"

MAX_SCHEDULED_TASKS :: 50
MIN_INTERVAL_SECS :: i64(60)
RECURRING_TTL_SECS :: i64(7 * 24 * 3600)
MAX_FIRE_BATCH :: 3

Scheduled_Task :: struct {
	id:            string,
	interval_secs: i64,
	prompt:        string,
	recurring:     bool,
	durable:       bool,
	created_unix:  i64,
	last_fired:    i64, // 0 = never
	expires_unix:  i64, // 0 = no expiry (one-shot)
}

g_sched_mu:     sync.Mutex
g_sched_tasks:  [dynamic]Scheduled_Task
g_sched_ctr:    int
g_sched_loaded: bool

// scheduler_enabled: opt-out AETHER_NO_SCHEDULER=1
scheduler_enabled :: proc() -> bool {
	if v := os.get_env("AETHER_NO_SCHEDULER", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") {
		return false
	}
	return true
}

scheduler_ensure_heap :: proc() {
	raw := (^runtime.Raw_Dynamic_Array)(&g_sched_tasks)
	if raw.allocator.procedure == runtime.heap_allocator().procedure {
		return
	}
	old := g_sched_tasks
	g_sched_tasks = make([dynamic]Scheduled_Task, 0, max(8, len(old)), runtime.heap_allocator())
	for t in old {
		append(&g_sched_tasks, t)
	}
	if raw_data(old) != nil {
		delete(old)
	}
}

// parse_interval: "5m", "2h", "1d", "60s" → seconds (min 60).
parse_interval :: proc(s: string) -> (secs: i64, err: string) {
	t := strings.trim_space(s)
	if t == "" {
		return 0, "interval cannot be empty"
	}
	if len(t) < 2 {
		return 0, fmt.tprintf("invalid interval format: %q (expected e.g. 5m, 2h, 1d)", s)
	}
	suffix := t[len(t) - 1:]
	digits := t[:len(t) - 1]
	value, ok := strconv.parse_i64(digits)
	if !ok || value <= 0 {
		return 0, fmt.tprintf("invalid interval format: %q (expected e.g. 5m, 2h, 1d)", s)
	}
	unit: i64
	switch suffix {
	case "s":
		unit = 1
	case "m":
		unit = 60
	case "h":
		unit = 3600
	case "d":
		unit = 86400
	case:
		return 0, fmt.tprintf("invalid interval suffix: %q (expected s, m, h, or d)", suffix)
	}
	if value > 1_000_000 {
		return 0, fmt.tprintf("interval too large: %q", s)
	}
	secs = value * unit
	if secs < MIN_INTERVAL_SECS {
		secs = MIN_INTERVAL_SECS
	}
	return secs, ""
}

interval_to_human :: proc(secs: i64) -> string {
	if secs <= 0 {
		return "every unknown interval"
	}
	if secs % 86400 == 0 {
		n := secs / 86400
		if n == 1 {
			return "every 1 day"
		}
		return fmt.tprintf("every %d days", n)
	}
	if secs % 3600 == 0 {
		n := secs / 3600
		if n == 1 {
			return "every 1 hour"
		}
		return fmt.tprintf("every %d hours", n)
	}
	if secs % 60 == 0 {
		n := secs / 60
		if n == 1 {
			return "every 1 minute"
		}
		return fmt.tprintf("every %d minutes", n)
	}
	if secs == 1 {
		return "every 1 second"
	}
	return fmt.tprintf("every %d seconds", secs)
}

unix_now :: proc() -> i64 {
	return time.to_unix_seconds(time.now())
}

task_next_fire :: proc(t: Scheduled_Task) -> i64 {
	anchor := t.created_unix
	if t.last_fired > 0 {
		anchor = t.last_fired
	}
	return anchor + t.interval_secs
}

task_is_expired :: proc(t: Scheduled_Task, now: i64) -> bool {
	return t.expires_unix > 0 && now >= t.expires_unix
}

task_is_due :: proc(t: Scheduled_Task, now: i64) -> bool {
	if task_is_expired(t, now) {
		return false
	}
	return task_next_fire(t) <= now
}

// task_is_missed: Grok one-shot past due, never fired.
task_is_missed :: proc(t: Scheduled_Task, now: i64) -> bool {
	return !t.recurring && t.last_fired == 0 && task_next_fire(t) < now
}

// format_relative_unix: human next-fire relative to now.
format_relative_unix :: proc(target, now: i64) -> string {
	d := target - now
	if d >= -30 && d <= 30 {
		return "now"
	}
	if d > 0 {
		if d < 60 {
			return fmt.tprintf("in %ds", d)
		}
		if d < 3600 {
			return fmt.tprintf("in %dm", d / 60)
		}
		if d < 86400 {
			return fmt.tprintf("in %dh", d / 3600)
		}
		return fmt.tprintf("in %dd", d / 86400)
	}
	// overdue
	ad := -d
	if ad < 60 {
		return fmt.tprintf("overdue by %ds", ad)
	}
	if ad < 3600 {
		return fmt.tprintf("overdue by %dm", ad / 60)
	}
	if ad < 86400 {
		return fmt.tprintf("overdue by %dh", ad / 3600)
	}
	return fmt.tprintf("overdue by %dd", ad / 86400)
}

free_scheduled_task :: proc(t: ^Scheduled_Task) {
	ha := runtime.heap_allocator()
	delete(t.id, ha)
	delete(t.prompt, ha)
	t^ = {}
}

// scheduler_store_path: AETHER_SCHEDULER_PATH or ~/.grok/aether/scheduler.json
scheduler_store_path :: proc(allocator := context.allocator) -> string {
	if v := os.get_env("AETHER_SCHEDULER_PATH", context.temp_allocator); v != "" {
		return strings.clone(v, allocator)
	}
	home := core.grok_home(context.temp_allocator)
	joined, _ := filepath.join({home, "aether", "scheduler.json"}, allocator)
	return joined
}

// scheduler_json_escape: shared core helper (no printf braces in callers).
scheduler_json_escape :: proc(s: string, allocator := context.allocator) -> string {
	return core.json_string_escape(s, allocator)
}

// scheduler_persist_unlocked writes durable tasks only. Caller holds g_sched_mu.
// Note: do not put JSON '{' in fmt format strings with % — Odin treats '{' specially.
scheduler_persist_unlocked :: proc() {
	path := scheduler_store_path(context.temp_allocator)
	dir := filepath.dir(path)
	if dir != "" && dir != "." {
		_ = core.ensure_dir(dir)
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"version":1,"tasks":[`)
	first := true
	for t in g_sched_tasks {
		if !t.durable {
			continue
		}
		if !first {
			strings.write_byte(&b, ',')
		}
		first = false
		strings.write_string(&b, `{"id":"`)
		strings.write_string(&b, scheduler_json_escape(t.id, context.temp_allocator))
		strings.write_string(&b, `","interval_secs":`)
		fmt.sbprintf(&b, "%d", t.interval_secs)
		strings.write_string(&b, `,"prompt":"`)
		strings.write_string(&b, scheduler_json_escape(t.prompt, context.temp_allocator))
		strings.write_string(&b, `","recurring":`)
		if t.recurring {
			strings.write_string(&b, "true")
		} else {
			strings.write_string(&b, "false")
		}
		strings.write_string(&b, `,"durable":true,"created_unix":`)
		fmt.sbprintf(&b, "%d", t.created_unix)
		strings.write_string(&b, `,"last_fired":`)
		fmt.sbprintf(&b, "%d", t.last_fired)
		strings.write_string(&b, `,"expires_unix":`)
		fmt.sbprintf(&b, "%d", t.expires_unix)
		strings.write_byte(&b, '}')
	}
	strings.write_string(&b, `]}`)
	body := strings.to_string(b)
	tmp := fmt.tprintf("%s.tmp.%d", path, os.get_pid())
	if err := os.write_entire_file(tmp, transmute([]byte)body); err != nil {
		return
	}
	if err := os.rename(tmp, path); err != nil {
		_ = os.remove(tmp)
	}
}

scheduler_persist :: proc() {
	sync.mutex_lock(&g_sched_mu)
	defer sync.mutex_unlock(&g_sched_mu)
	scheduler_ensure_heap()
	scheduler_persist_unlocked()
}

// scheduler_load_unlocked: load durable file into empty registry. Caller holds lock.
scheduler_load_unlocked :: proc() {
	if g_sched_loaded {
		return
	}
	g_sched_loaded = true
	path := scheduler_store_path(context.temp_allocator)
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil || len(data) == 0 {
		return
	}
	val, perr := json.parse(data, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil {
		return
	}
	obj, ok := val.(json.Object)
	if !ok {
		return
	}
	tv, has := obj["tasks"]
	if !has {
		return
	}
	arr, is_a := tv.(json.Array)
	if !is_a {
		return
	}
	ha := runtime.heap_allocator()
	now := unix_now()
	for item in arr {
		to, is_o := item.(json.Object)
		if !is_o {
			continue
		}
		id := tools.jstr(to, "id")
		prompt := tools.jstr(to, "prompt")
		if id == "" || prompt == "" {
			continue
		}
		// only durable should be on disk
		if _, has_d := to["durable"]; has_d && !tools.jbool(to, "durable", true) {
			continue
		}
		interval := i64(tools.jint(to, "interval_secs", 0))
		if interval < MIN_INTERVAL_SECS {
			continue
		}
		recurring := tools.jbool(to, "recurring", true)
		created := i64(tools.jint(to, "created_unix", 0))
		last := i64(tools.jint(to, "last_fired", 0))
		expires := i64(tools.jint(to, "expires_unix", 0))
		task := Scheduled_Task {
			id            = strings.clone(id, ha),
			interval_secs = interval,
			prompt        = strings.clone(prompt, ha),
			recurring     = recurring,
			durable       = true,
			created_unix  = created,
			last_fired    = last,
			expires_unix  = expires,
		}
		if task_is_expired(task, now) {
			free_scheduled_task(&task)
			continue
		}
		if len(g_sched_tasks) >= MAX_SCHEDULED_TASKS {
			free_scheduled_task(&task)
			break
		}
		append(&g_sched_tasks, task)
	}
}

scheduler_ensure_loaded :: proc() {
	sync.mutex_lock(&g_sched_mu)
	defer sync.mutex_unlock(&g_sched_mu)
	scheduler_ensure_heap()
	scheduler_load_unlocked()
}

// scheduler_clear: wipe all tasks (tests). When AETHER_SCHEDULER_PATH set, rewrite empty store.
scheduler_clear :: proc() {
	sync.mutex_lock(&g_sched_mu)
	defer sync.mutex_unlock(&g_sched_mu)
	scheduler_ensure_heap()
	for &t in g_sched_tasks {
		free_scheduled_task(&t)
	}
	clear(&g_sched_tasks)
	g_sched_loaded = true // don't re-load home file mid-test unless reset
	if os.get_env("AETHER_SCHEDULER_PATH", context.temp_allocator) != "" {
		scheduler_persist_unlocked()
	}
}

// scheduler_clear_session: /new — drop non-durable only; keep durable + persist.
scheduler_clear_session :: proc() {
	sync.mutex_lock(&g_sched_mu)
	defer sync.mutex_unlock(&g_sched_mu)
	scheduler_ensure_heap()
	scheduler_load_unlocked()
	for i := len(g_sched_tasks) - 1; i >= 0; i -= 1 {
		if !g_sched_tasks[i].durable {
			free_scheduled_task(&g_sched_tasks[i])
			ordered_remove(&g_sched_tasks, i)
		}
	}
	scheduler_persist_unlocked()
}

// scheduler_reset_for_reload: tests — empty memory and re-read store next ensure.
scheduler_reset_for_reload :: proc() {
	sync.mutex_lock(&g_sched_mu)
	defer sync.mutex_unlock(&g_sched_mu)
	scheduler_ensure_heap()
	for &t in g_sched_tasks {
		free_scheduled_task(&t)
	}
	clear(&g_sched_tasks)
	g_sched_loaded = false
}

// --- tool handlers ---

handle_scheduler_create :: proc(
	arguments_json: string,
	allocator := context.allocator,
) -> string {
	if !scheduler_enabled() {
		return strings.clone("error: scheduler disabled (AETHER_NO_SCHEDULER=1)", allocator)
	}
	obj, ok := tools.json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	interval_s := tools.jstr(obj, "interval")
	prompt := strings.trim_space(tools.jstr(obj, "prompt"))
	if prompt == "" {
		return strings.clone("error: prompt is required", allocator)
	}
	secs, ierr := parse_interval(interval_s)
	if ierr != "" {
		return fmt.aprintf("error: %s", ierr, allocator = allocator)
	}
	recurring := true
	if _, has := obj["recurring"]; has {
		recurring = tools.jbool(obj, "recurring", true)
	}
	durable := tools.jbool(obj, "durable", false)
	fire_immediately := tools.jbool(obj, "fire_immediately", false)
	return scheduler_create_direct(secs, prompt, recurring, fire_immediately, durable, allocator)
}

handle_scheduler_list :: proc(
	arguments_json: string,
	allocator := context.allocator,
) -> string {
	_ = arguments_json
	if !scheduler_enabled() {
		return strings.clone("error: scheduler disabled (AETHER_NO_SCHEDULER=1)", allocator)
	}
	now := unix_now()
	sync.mutex_lock(&g_sched_mu)
	scheduler_ensure_heap()
	scheduler_load_unlocked()
	// drop expired recurring first
	dirty := false
	for i := len(g_sched_tasks) - 1; i >= 0; i -= 1 {
		if task_is_expired(g_sched_tasks[i], now) {
			if g_sched_tasks[i].durable {
				dirty = true
			}
			free_scheduled_task(&g_sched_tasks[i])
			ordered_remove(&g_sched_tasks, i)
		}
	}
	if dirty {
		scheduler_persist_unlocked()
	}
	if len(g_sched_tasks) == 0 {
		sync.mutex_unlock(&g_sched_mu)
		return strings.clone("No scheduled tasks.", allocator)
	}
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "Scheduled tasks (%d):\n", len(g_sched_tasks))
	for t in g_sched_tasks {
		prompt := t.prompt
		if len(prompt) > 80 {
			prompt = fmt.tprintf("%s…", prompt[:77])
		}
		dur := ""
		if t.durable {
			dur = "  durable=true"
		}
		nf := task_next_fire(t)
		rel := format_relative_unix(nf, now)
		missed := ""
		if task_is_missed(t, now) {
			missed = "  missed=true"
		}
		fmt.sbprintf(
			&b,
			"- id=%s  %s  recurring=%v%s%s  next_fire=%s (unix=%d)\n  prompt: %s\n",
			t.id,
			interval_to_human(t.interval_secs),
			t.recurring,
			dur,
			missed,
			rel,
			nf,
			prompt,
		)
	}
	sync.mutex_unlock(&g_sched_mu)
	return strings.to_string(b)
}

scheduler_delete_by_id :: proc(id_in: string, allocator := context.allocator) -> string {
	id := strings.trim_space(id_in)
	if id == "" {
		return strings.clone("error: id is required", allocator)
	}
	sync.mutex_lock(&g_sched_mu)
	scheduler_ensure_heap()
	scheduler_load_unlocked()
	found := false
	was_durable := false
	for i := 0; i < len(g_sched_tasks); i += 1 {
		if g_sched_tasks[i].id == id {
			was_durable = g_sched_tasks[i].durable
			free_scheduled_task(&g_sched_tasks[i])
			ordered_remove(&g_sched_tasks, i)
			found = true
			break
		}
	}
	if found && was_durable {
		scheduler_persist_unlocked()
	}
	sync.mutex_unlock(&g_sched_mu)
	if found {
		return fmt.aprintf("success: true\nremoved scheduled task %s", id, allocator = allocator)
	}
	return fmt.aprintf(
		"success: false\nno scheduled task with id %s",
		id,
		allocator = allocator,
	)
}

handle_scheduler_delete :: proc(
	arguments_json: string,
	allocator := context.allocator,
) -> string {
	if !scheduler_enabled() {
		return strings.clone("error: scheduler disabled (AETHER_NO_SCHEDULER=1)", allocator)
	}
	obj, ok := tools.json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	id := strings.trim_space(tools.jstr(obj, "id"))
	return scheduler_delete_by_id(id, allocator)
}

// --- fire injection ---

scheduler_has_due :: proc() -> bool {
	if !scheduler_enabled() {
		return false
	}
	now := unix_now()
	sync.mutex_lock(&g_sched_mu)
	defer sync.mutex_unlock(&g_sched_mu)
	scheduler_ensure_heap()
	scheduler_load_unlocked()
	for t in g_sched_tasks {
		if task_is_due(t, now) {
			return true
		}
		// expired still "needs" cleanup inject path
		if task_is_expired(t, now) {
			return true
		}
	}
	return false
}

Sched_Fire :: struct {
	id:     string,
	human:  string,
	prompt: string,
	missed: bool, // one-shot catch-up after being past due
}

// maybe_inject_scheduler_fires drains due tasks into user messages (prompt body).
maybe_inject_scheduler_fires :: proc(
	msgs: ^[dynamic]Chat_Message,
	allocator := context.allocator,
) -> bool {
	if !scheduler_enabled() {
		return false
	}
	if g_subagent_depth != 0 {
		return false
	}
	now := unix_now()
	fires := make([dynamic]Sched_Fire, 0, MAX_FIRE_BATCH, context.temp_allocator)

	sync.mutex_lock(&g_sched_mu)
	scheduler_ensure_heap()
	scheduler_load_unlocked()
	persist_needed := false
	// Drop expired tasks that are not also due (due+expired still fire once below)
	for i := len(g_sched_tasks) - 1; i >= 0; i -= 1 {
		if task_is_expired(g_sched_tasks[i], now) && !task_is_due(g_sched_tasks[i], now) {
			if g_sched_tasks[i].durable {
				persist_needed = true
			}
			free_scheduled_task(&g_sched_tasks[i])
			ordered_remove(&g_sched_tasks, i)
		}
	}
	// Fire due (batch) — missed one-shots after reload are due and fire once
	for i := 0; i < len(g_sched_tasks) && len(fires) < MAX_FIRE_BATCH; {
		t := &g_sched_tasks[i]
		if !task_is_due(t^, now) {
			i += 1
			continue
		}
		was_missed := task_is_missed(t^, now)
		append(
			&fires,
			Sched_Fire {
				id     = strings.clone(t.id, context.temp_allocator),
				human  = interval_to_human(t.interval_secs),
				prompt = strings.clone(t.prompt, context.temp_allocator),
				missed = was_missed,
			},
		)
		t.last_fired = now
		if t.durable {
			persist_needed = true
		}
		if !t.recurring || task_is_expired(t^, now) {
			free_scheduled_task(t)
			ordered_remove(&g_sched_tasks, i)
			continue
		}
		i += 1
	}
	if persist_needed {
		scheduler_persist_unlocked()
	}
	sync.mutex_unlock(&g_sched_mu)

	if len(fires) == 0 {
		return false
	}
	for f in fires {
		kind := "Scheduled task fired"
		if f.missed {
			kind = "Scheduled task fired (missed catch-up)"
		}
		text := fmt.aprintf(
			"<system-reminder>\n%s (id=%s, schedule=%s).\n</system-reminder>\n\n%s",
			kind,
			f.id,
			f.human,
			f.prompt,
			allocator = allocator,
		)
		append(msgs, Chat_Message{role = .User, content = text})
	}
	return true
}

// --- /loop slash (Grok-shaped host UX over scheduler_*) ---

LOOP_USAGE :: "Usage: /loop [interval] <prompt>\n" +
	"Example: /loop 30m check deploy status\n" +
	"Example: /loop check deploy status every hour\n" +
	"Commands: /loop list | /loop stop <id>\n\n" +
	"Interval: Ns/Nm/Nh/Nd (min 60s). Recurring tasks expire after 7 days."

// looks_like_compact_interval: "30m", "2h", "90s", "1d"
looks_like_compact_interval :: proc(tok: string) -> bool {
	_, err := parse_interval(tok)
	return err == ""
}

// parse_trailing_every: "check deploy every hour" → ("1h", "check deploy", ok)
parse_trailing_every :: proc(
	s: string,
) -> (
	interval: string,
	prompt: string,
	ok: bool,
) {
	low := strings.to_lower(s, context.temp_allocator)
	idx := strings.last_index(low, " every ")
	if idx < 0 {
		// also allow ending with " every N unit" at start of remaining after first word? skip
		if strings.has_prefix(low, "every ") {
			// whole string is interval phrase — no prompt
			return "", "", false
		}
		return "", "", false
	}
	prompt = strings.trim_space(s[:idx])
	rest := strings.trim_space(s[idx + len(" every "):])
	if prompt == "" || rest == "" {
		return "", "", false
	}
	// rest: "hour" | "2 hours" | "30 minutes" | "day"
	fields, _ := strings.fields(rest, context.temp_allocator)
	if len(fields) == 0 {
		return "", "", false
	}
	n: i64 = 1
	unit_word := fields[0]
	if len(fields) >= 2 {
		// "2 hours" or "30 minutes"
		if parsed, pok := strconv.parse_i64(fields[0]); pok && parsed > 0 {
			n = parsed
			unit_word = fields[1]
		}
	}
	unit_word = strings.trim_right(unit_word, "s") // minutes → minute
	compact: string
	switch unit_word {
	case "second", "sec":
		compact = fmt.tprintf("%ds", n)
	case "minute", "min":
		compact = fmt.tprintf("%dm", n)
	case "hour", "hr":
		compact = fmt.tprintf("%dh", n)
	case "day":
		compact = fmt.tprintf("%dd", n)
	case:
		return "", "", false
	}
	if _, err := parse_interval(compact); err != "" {
		return "", "", false
	}
	return compact, prompt, true
}

// parse_loop_create_args extracts interval + prompt from /loop create form.
// Returns err non-empty when interval missing/unparseable (no silent default).
parse_loop_create_args :: proc(
	arg: string,
) -> (
	interval: string,
	prompt: string,
	err: string,
) {
	a := strings.trim_space(arg)
	if a == "" {
		return "", "", "empty"
	}
	// Leading compact interval
	parts, _ := strings.fields(a, context.temp_allocator)
	if len(parts) >= 2 && looks_like_compact_interval(parts[0]) {
		// rest of string after first token
		sp := strings.index_byte(a, ' ')
		if sp < 0 {
			return "", "", "prompt required"
		}
		prompt = strings.trim_space(a[sp + 1:])
		if prompt == "" {
			return "", "", "prompt required"
		}
		return parts[0], prompt, ""
	}
	// Trailing "every …"
	if iv, pr, ok := parse_trailing_every(a); ok {
		return iv, pr, ""
	}
	return "", "", "no interval found (e.g. 30m or 'every hour')"
}

loop_usage_message :: proc() -> string {
	return LOOP_USAGE
}

// handle_loop_slash: list | stop <id> | create
handle_loop_slash :: proc(arg: string, allocator := context.allocator) -> string {
	if !scheduler_enabled() {
		return strings.clone("aether: scheduler disabled (AETHER_NO_SCHEDULER=1)", allocator)
	}
	a := strings.trim_space(arg)
	if a == "" {
		return strings.clone(LOOP_USAGE, allocator)
	}
	al := strings.to_lower(a, context.temp_allocator)
	// list / status
	if al == "list" || al == "status" || al == "ls" {
		return handle_scheduler_list("{}", allocator)
	}
	// stop / cancel / delete <id>
	if strings.has_prefix(al, "stop ") ||
	   strings.has_prefix(al, "cancel ") ||
	   strings.has_prefix(al, "delete ") ||
	   strings.has_prefix(al, "rm ") {
		sp := strings.index_byte(a, ' ')
		id := strings.trim_space(a[sp + 1:])
		if id == "" {
			return strings.clone("aether: usage: /loop stop <id>", allocator)
		}
		return scheduler_delete_by_id(id, allocator)
	}
	// create
	interval, prompt, perr := parse_loop_create_args(a)
	if perr != "" {
		return fmt.aprintf(
			"aether: /loop: %s\n\n%s",
			perr,
			LOOP_USAGE,
			allocator = allocator,
		)
	}
	secs, ierr := parse_interval(interval)
	if ierr != "" {
		return fmt.aprintf("aether: /loop: %s\n\n%s", ierr, LOOP_USAGE, allocator = allocator)
	}
	out := scheduler_create_direct(secs, prompt, true, true, false, allocator)
	if strings.contains(out, "Scheduled task created") {
		return fmt.aprintf(
			"%s\nCancel with: /loop stop <id>  (or scheduler_delete)",
			out,
			allocator = allocator,
		)
	}
	return out
}

// scheduler_create_direct creates without JSON (used by /loop and tool).
scheduler_create_direct :: proc(
	secs: i64,
	prompt: string,
	recurring: bool,
	fire_immediately: bool,
	durable: bool,
	allocator := context.allocator,
) -> string {
	if !scheduler_enabled() {
		return strings.clone("error: scheduler disabled (AETHER_NO_SCHEDULER=1)", allocator)
	}
	if strings.trim_space(prompt) == "" {
		return strings.clone("error: prompt is required", allocator)
	}
	now := unix_now()
	created := now
	if fire_immediately {
		created = now - secs
	}
	ha := runtime.heap_allocator()
	sync.mutex_lock(&g_sched_mu)
	scheduler_ensure_heap()
	scheduler_load_unlocked()
	if len(g_sched_tasks) >= MAX_SCHEDULED_TASKS {
		sync.mutex_unlock(&g_sched_mu)
		return fmt.aprintf(
			"error: maximum of %d scheduled tasks reached",
			MAX_SCHEDULED_TASKS,
			allocator = allocator,
		)
	}
	g_sched_ctr += 1
	n := g_sched_ctr
	id := fmt.aprintf("%x%04x", now & 0xffffffff, n & 0xffff, allocator = ha)
	expires: i64 = 0
	if recurring {
		expires = now + RECURRING_TTL_SECS
	}
	task := Scheduled_Task {
		id            = id,
		interval_secs = secs,
		prompt        = strings.clone(prompt, ha),
		recurring     = recurring,
		durable       = durable,
		created_unix  = created,
		last_fired    = 0,
		expires_unix  = expires,
	}
	append(&g_sched_tasks, task)
	if durable {
		scheduler_persist_unlocked()
	}
	next := task_next_fire(task)
	human := interval_to_human(secs)
	id_copy := strings.clone(id, context.temp_allocator)
	sync.mutex_unlock(&g_sched_mu)
	note := "(process-local; set durable=true to persist across restarts)"
	if durable {
		note = fmt.tprintf("(durable; saved to %s)", scheduler_store_path(context.temp_allocator))
	}
	return fmt.aprintf(
		"Scheduled task created.\nid: %s\nschedule: %s\nrecurring: %v\ndurable: %v\nnext_fire_unix: %d\n\n%s",
		id_copy,
		human,
		recurring,
		durable,
		next,
		note,
		allocator = allocator,
	)
}
