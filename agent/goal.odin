package agent

// goal — Grok-shaped goal mode (product Full: session-durable).
// Reference: crates/codegen/xai-grok-tools/.../update_goal + /goal docs

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "aether:tools"

MAX_GOAL_PROGRESS :: 20

Goal_Status :: enum {
	Inactive,
	Active,
	Paused,
	Blocked,
	Completed,
}

Goal_State :: struct {
	status:         Goal_Status,
	objective:      string, // owned (heap)
	progress:       [dynamic]string, // owned lines
	blocked:        string, // owned
	// M2: optional token budget (Grok /goal --budget). 0 = no budget.
	token_budget:   i64,
	// Tokens (chars/4) at goal set / first check; -1 until latched.
	token_baseline: i64,
}

g_goal_mu: sync.Mutex
g_goal:    Goal_State

// goal_enabled: opt-out AETHER_NO_GOAL=1
goal_enabled :: proc() -> bool {
	if v := os.get_env("AETHER_NO_GOAL", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") {
		return false
	}
	return true
}

goal_status_string :: proc(s: Goal_Status) -> string {
	switch s {
	case .Inactive:
		return "inactive"
	case .Active:
		return "active"
	case .Paused:
		return "paused"
	case .Blocked:
		return "blocked"
	case .Completed:
		return "completed"
	}
	return "inactive"
}

goal_is_active_or_paused :: proc() -> bool {
	sync.mutex_lock(&g_goal_mu)
	defer sync.mutex_unlock(&g_goal_mu)
	return g_goal.status == .Active || g_goal.status == .Paused || g_goal.status == .Blocked
}

// goal_chip for TUI: "", " goal", " goal:blocked", " goal:paused"
goal_chip :: proc() -> string {
	if !goal_enabled() {
		return ""
	}
	sync.mutex_lock(&g_goal_mu)
	defer sync.mutex_unlock(&g_goal_mu)
	switch g_goal.status {
	case .Active:
		return " goal"
	case .Blocked:
		return " goal:blocked"
	case .Paused:
		return " goal:paused"
	case .Inactive, .Completed:
		return ""
	}
	return ""
}

goal_ensure_progress_heap :: proc() {
	raw := (^runtime.Raw_Dynamic_Array)(&g_goal.progress)
	if raw.allocator.procedure == runtime.heap_allocator().procedure {
		return
	}
	old := g_goal.progress
	g_goal.progress = make([dynamic]string, 0, max(4, len(old)), runtime.heap_allocator())
	for p in old {
		append(&g_goal.progress, p)
	}
	if raw_data(old) != nil {
		delete(old)
	}
}

goal_append_progress :: proc(msg: string) {
	ha := runtime.heap_allocator()
	goal_ensure_progress_heap()
	if strings.trim_space(msg) == "" {
		return
	}
	append(&g_goal.progress, strings.clone(msg, ha))
	for len(g_goal.progress) > MAX_GOAL_PROGRESS {
		delete(g_goal.progress[0], ha)
		ordered_remove(&g_goal.progress, 0)
	}
}

// goal_activate sets objective and Active status. budget 0 = unlimited.
goal_activate :: proc(objective: string, budget: i64 = 0) {
	ha := runtime.heap_allocator()
	sync.mutex_lock(&g_goal_mu)
	defer sync.mutex_unlock(&g_goal_mu)
	goal_ensure_progress_heap()
	delete(g_goal.objective, ha)
	delete(g_goal.blocked, ha)
	for p in g_goal.progress {
		delete(p, ha)
	}
	clear(&g_goal.progress)
	g_goal.objective = strings.clone(strings.trim_space(objective), ha)
	g_goal.blocked = ""
	g_goal.status = .Active
	g_goal.token_budget = budget if budget > 0 else 0
	g_goal.token_baseline = -1 // latch on first budget check
}

goal_clear :: proc() {
	ha := runtime.heap_allocator()
	sync.mutex_lock(&g_goal_mu)
	defer sync.mutex_unlock(&g_goal_mu)
	goal_ensure_progress_heap()
	delete(g_goal.objective, ha)
	delete(g_goal.blocked, ha)
	for p in g_goal.progress {
		delete(p, ha)
	}
	clear(&g_goal.progress)
	g_goal.objective = ""
	g_goal.blocked = ""
	g_goal.status = .Inactive
	g_goal.token_budget = 0
	g_goal.token_baseline = -1
}

// parse_goal_budget: trailing `--budget <positive int>` only (Grok rules).
// Returns cleaned objective + optional budget.
parse_goal_budget :: proc(trimmed: string) -> (objective: string, budget: i64) {
	// rsplit once on --budget
	idx := strings.last_index(trimmed, "--budget")
	if idx < 0 {
		return trimmed, 0
	}
	head := strings.trim_space(trimmed[:idx])
	tail := strings.trim_space(trimmed[idx + len("--budget"):])
	// flag must be own token: whitespace before --budget (or start) and after
	if idx > 0 && trimmed[idx - 1] != ' ' && trimmed[idx - 1] != '\t' {
		return trimmed, 0
	}
	if head == "" || tail == "" {
		return trimmed, 0
	}
	// tail must be single all-digit token
	if strings.contains(tail, " ") || strings.contains(tail, "\t") {
		return trimmed, 0
	}
	for i in 0 ..< len(tail) {
		if tail[i] < '0' || tail[i] > '9' {
			return trimmed, 0
		}
	}
	n, ok := strconv.parse_i64(tail)
	if !ok || n <= 0 {
		return trimmed, 0
	}
	return head, n
}

goal_status_text :: proc(allocator := context.allocator) -> string {
	sync.mutex_lock(&g_goal_mu)
	defer sync.mutex_unlock(&g_goal_mu)
	if g_goal.status == .Inactive || g_goal.objective == "" {
		return strings.clone("goal: inactive (use /goal <objective>)", allocator)
	}
	b := strings.builder_make(allocator)
	fmt.sbprintf(
		&b,
		"goal: %s\nobjective: %s\n",
		goal_status_string(g_goal.status),
		g_goal.objective,
	)
	if g_goal.token_budget > 0 {
		used: i64 = 0
		if g_goal.token_baseline >= 0 {
			// cannot compute without msgs here; show budget limit only
			fmt.sbprintf(&b, "token_budget: %d (used tracked after agent turns)\n", g_goal.token_budget)
		} else {
			fmt.sbprintf(&b, "token_budget: %d (not yet counted)\n", g_goal.token_budget)
		}
		_ = used
	}
	if g_goal.blocked != "" {
		fmt.sbprintf(&b, "blocked_reason: %s\n", g_goal.blocked)
	}
	if len(g_goal.progress) > 0 {
		strings.write_string(&b, "recent progress:\n")
		// last up to 5
		start := 0
		if len(g_goal.progress) > 5 {
			start = len(g_goal.progress) - 5
		}
		for i in start ..< len(g_goal.progress) {
			fmt.sbprintf(&b, "  - %s\n", g_goal.progress[i])
		}
	}
	return strings.to_string(b)
}

// goal_prompt_blurb: empty when inactive; system-prompt add-on when active.
goal_prompt_blurb :: proc(allocator := context.allocator) -> string {
	if !goal_enabled() {
		return ""
	}
	sync.mutex_lock(&g_goal_mu)
	defer sync.mutex_unlock(&g_goal_mu)
	if g_goal.status != .Active && g_goal.status != .Paused && g_goal.status != .Blocked {
		return ""
	}
	return fmt.aprintf(
		"\n\nGoal mode: %s — objective: %s\nUse update_goal to log progress (message), mark completed=true when fully done, or blocked_reason only after 3+ failed attempts at the same problem.",
		goal_status_string(g_goal.status),
		g_goal.objective,
		allocator = allocator,
	)
}

// goal_json_escape for session embedding (avoid fmt `{` issues).
goal_json_escape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(&b, `\"`)
		case '\\':
			strings.write_string(&b, `\\`)
		case '\n':
			strings.write_string(&b, `\n`)
		case '\r':
			strings.write_string(&b, `\r`)
		case '\t':
			strings.write_string(&b, `\t`)
		case:
			strings.write_byte(&b, ch)
		}
	}
	return strings.to_string(b)
}

// goal_snapshot_json_object: `{"status":...,"objective":...,"blocked":...,"progress":[...]}`
goal_snapshot_json_object :: proc(allocator := context.allocator) -> string {
	sync.mutex_lock(&g_goal_mu)
	defer sync.mutex_unlock(&g_goal_mu)
	goal_ensure_progress_heap()
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"status":"`)
	strings.write_string(&b, goal_status_string(g_goal.status))
	strings.write_string(&b, `","objective":"`)
	strings.write_string(&b, goal_json_escape(g_goal.objective, context.temp_allocator))
	strings.write_string(&b, `","blocked":"`)
	strings.write_string(&b, goal_json_escape(g_goal.blocked, context.temp_allocator))
	strings.write_string(&b, `","progress":[`)
	for p, i in g_goal.progress {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_byte(&b, '"')
		strings.write_string(&b, goal_json_escape(p, context.temp_allocator))
		strings.write_byte(&b, '"')
	}
	strings.write_string(&b, `],"token_budget":`)
	fmt.sbprintf(&b, "%d", g_goal.token_budget)
	strings.write_string(&b, `,"token_baseline":`)
	fmt.sbprintf(&b, "%d", g_goal.token_baseline)
	strings.write_string(&b, `}`)
	return strings.to_string(b)
}

goal_status_from_string :: proc(s: string) -> Goal_Status {
	switch strings.to_lower(strings.trim_space(s), context.temp_allocator) {
	case "active":
		return .Active
	case "paused":
		return .Paused
	case "blocked":
		return .Blocked
	case "completed":
		return .Completed
	case "inactive":
		return .Inactive
	}
	return .Inactive
}

// goal_restore_from_json_object replaces process goal state from session.
goal_restore_from_json_object :: proc(obj: json.Object) {
	ha := runtime.heap_allocator()
	sync.mutex_lock(&g_goal_mu)
	defer sync.mutex_unlock(&g_goal_mu)
	goal_ensure_progress_heap()
	delete(g_goal.objective, ha)
	delete(g_goal.blocked, ha)
	for p in g_goal.progress {
		delete(p, ha)
	}
	clear(&g_goal.progress)

	st := "inactive"
	if v, has := obj["status"]; has {
		if s, is_s := v.(json.String); is_s {
			st = string(s)
		}
	}
	g_goal.status = goal_status_from_string(st)

	obj_s := ""
	if v, has := obj["objective"]; has {
		if s, is_s := v.(json.String); is_s {
			obj_s = string(s)
		}
	}
	g_goal.objective = strings.clone(obj_s, ha)

	blk := ""
	if v, has := obj["blocked"]; has {
		if s, is_s := v.(json.String); is_s {
			blk = string(s)
		}
	}
	g_goal.blocked = strings.clone(blk, ha)

	if pv, has := obj["progress"]; has {
		if arr, is_a := pv.(json.Array); is_a {
			for item in arr {
				if s, is_s := item.(json.String); is_s {
					append(&g_goal.progress, strings.clone(string(s), ha))
				}
			}
		}
	}
	// Cap progress
	for len(g_goal.progress) > MAX_GOAL_PROGRESS {
		delete(g_goal.progress[0], ha)
		ordered_remove(&g_goal.progress, 0)
	}

	g_goal.token_budget = 0
	g_goal.token_baseline = -1
	if v, has := obj["token_budget"]; has {
		if n, is_n := v.(json.Integer); is_n && n > 0 {
			g_goal.token_budget = i64(n)
		} else if f, is_f := v.(json.Float); is_f && f > 0 {
			g_goal.token_budget = i64(f)
		}
	}
	if v, has := obj["token_baseline"]; has {
		if n, is_n := v.(json.Integer); is_n {
			g_goal.token_baseline = i64(n)
		} else if f, is_f := v.(json.Float); is_f {
			g_goal.token_baseline = i64(f)
		}
	}
}

// goal_check_budget: after an agent turn, pause if session token use since
// baseline exceeds token_budget. Returns system-reminder text or "".
goal_check_budget :: proc(msgs: []Chat_Message) -> string {
	if !goal_enabled() {
		return ""
	}
	sync.mutex_lock(&g_goal_mu)
	defer sync.mutex_unlock(&g_goal_mu)
	if g_goal.status != .Active || g_goal.token_budget <= 0 {
		return ""
	}
	cur := i64(estimate_tokens(estimate_message_chars(msgs)))
	if g_goal.token_baseline < 0 {
		g_goal.token_baseline = cur
		return ""
	}
	used := cur - g_goal.token_baseline
	if used < 0 {
		used = 0
	}
	if used < g_goal.token_budget {
		return ""
	}
	g_goal.status = .Paused
	return fmt.tprintf(
		"<system-reminder>Goal token budget exhausted: used≈%d / budget=%d. Goal paused. Use /goal resume (optionally raise budget by /goal <obj> --budget N) to continue.</system-reminder>",
		used,
		g_goal.token_budget,
	)
}

// goal_budget_status_line for /goal status with live usage (needs msgs).
goal_budget_status_extra :: proc(msgs: []Chat_Message, allocator := context.allocator) -> string {
	sync.mutex_lock(&g_goal_mu)
	defer sync.mutex_unlock(&g_goal_mu)
	if g_goal.token_budget <= 0 {
		return ""
	}
	cur := i64(estimate_tokens(estimate_message_chars(msgs)))
	base := g_goal.token_baseline
	used: i64 = 0
	if base >= 0 {
		used = cur - base
		if used < 0 {
			used = 0
		}
	}
	note := " (not yet latched)"
	if base >= 0 {
		note = " (baseline latched)"
	}
	return fmt.aprintf(
		"token_budget: used≈%d / %d%s\n",
		used,
		g_goal.token_budget,
		note,
		allocator = allocator,
	)
}

// goal_restore_from_json_text for tests.
goal_restore_from_json_text :: proc(json_text: string) -> string /* err */ {
	val, err := json.parse(
		transmute([]byte)json_text,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if err != nil {
		return "invalid goal JSON"
	}
	obj, ok := val.(json.Object)
	if !ok {
		return "goal must be object"
	}
	goal_restore_from_json_object(obj)
	return ""
}

// handle_update_goal — model tool entrypoint.
handle_update_goal :: proc(
	arguments_json: string,
	allocator := context.allocator,
) -> string {
	if !goal_enabled() {
		return strings.clone("error: goal mode disabled (AETHER_NO_GOAL=1)", allocator)
	}
	obj, ok := tools.json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	message := strings.trim_space(tools.jstr(obj, "message"))
	completed := tools.jbool(obj, "completed", false)
	blocked := strings.trim_space(tools.jstr(obj, "blocked_reason"))

	if completed && blocked != "" {
		return strings.clone(
			"error: do not set both completed and blocked_reason; use completed for success, blocked_reason for failure",
			allocator,
		)
	}
	if !completed && blocked == "" && message == "" {
		return strings.clone(
			"error: provide message, completed=true, and/or blocked_reason",
			allocator,
		)
	}

	ha := runtime.heap_allocator()
	sync.mutex_lock(&g_goal_mu)
	defer sync.mutex_unlock(&g_goal_mu)

	if g_goal.status == .Inactive || g_goal.objective == "" {
		return strings.clone(
			"error: no active goal (user should run /goal <objective> first)",
			allocator,
		)
	}

	if blocked != "" {
		if g_goal.status != .Active && g_goal.status != .Paused {
			return fmt.aprintf(
				"error: cannot block goal in status %s",
				goal_status_string(g_goal.status),
				allocator = allocator,
			)
		}
		if message != "" {
			goal_append_progress(message)
		}
		goal_append_progress(fmt.tprintf("blocked: %s", blocked))
		delete(g_goal.blocked, ha)
		g_goal.blocked = strings.clone(blocked, ha)
		g_goal.status = .Blocked
		return fmt.aprintf(
			"Goal blocked: %s\nobjective: %s\n(User can /goal resume or /goal clear.)",
			blocked,
			g_goal.objective,
			allocator = allocator,
		)
	}

	if completed {
		if g_goal.status != .Active {
			return fmt.aprintf(
				"error: can only complete an active goal (status=%s); /goal resume if paused/blocked",
				goal_status_string(g_goal.status),
				allocator = allocator,
			)
		}
		summary := message if message != "" else "completed"
		goal_append_progress(fmt.tprintf("completed: %s", summary))
		obj_copy := strings.clone(g_goal.objective, context.temp_allocator)
		// leave status Completed for status queries until clear/new goal
		g_goal.status = .Completed
		return fmt.aprintf(
			"Goal completed: %s\nobjective: %s\nYou may continue with remaining work or wait for a new /goal.",
			summary,
			obj_copy,
			allocator = allocator,
		)
	}

	// message-only progress
	if g_goal.status == .Completed {
		return strings.clone(
			"error: goal already completed; user can /goal <new objective>",
			allocator,
		)
	}
	goal_append_progress(message)
	return fmt.aprintf(
		"Goal progress logged: %s\nstatus: %s\nobjective: %s",
		message,
		goal_status_string(g_goal.status),
		g_goal.objective,
		allocator = allocator,
	)
}

// handle_goal_slash processes /goal arguments (without the /goal prefix).
handle_goal_slash :: proc(arg: string, allocator := context.allocator) -> string {
	if !goal_enabled() {
		return strings.clone("aether: goal mode disabled (AETHER_NO_GOAL=1)", allocator)
	}
	a := strings.trim_space(arg)
	al := strings.to_lower(a, context.temp_allocator)
	if a == "" || al == "status" || al == "?" {
		return goal_status_text(allocator)
	}
	if al == "clear" || al == "off" || al == "end" {
		goal_clear()
		return strings.clone("aether: goal cleared", allocator)
	}
	if al == "pause" {
		sync.mutex_lock(&g_goal_mu)
		defer sync.mutex_unlock(&g_goal_mu)
		if g_goal.status != .Active {
			return fmt.aprintf(
				"aether: cannot pause (status=%s)",
				goal_status_string(g_goal.status),
				allocator = allocator,
			)
		}
		g_goal.status = .Paused
		return strings.clone("aether: goal paused", allocator)
	}
	if al == "resume" {
		sync.mutex_lock(&g_goal_mu)
		defer sync.mutex_unlock(&g_goal_mu)
		if g_goal.status != .Paused && g_goal.status != .Blocked {
			return fmt.aprintf(
				"aether: cannot resume (status=%s)",
				goal_status_string(g_goal.status),
				allocator = allocator,
			)
		}
		delete(g_goal.blocked, runtime.heap_allocator())
		g_goal.blocked = ""
		g_goal.status = .Active
		return strings.clone("aether: goal resumed", allocator)
	}
	// treat as new objective [ --budget N ]
	if len(a) < 2 {
		return strings.clone(
			"aether: usage: /goal <objective> [--budget <tokens>] | status | pause | resume | clear",
			allocator,
		)
	}
	obj, budget := parse_goal_budget(a)
	if len(obj) < 2 {
		return strings.clone(
			"aether: usage: /goal <objective> [--budget <tokens>] | status | pause | resume | clear",
			allocator,
		)
	}
	goal_activate(obj, budget)
	if budget > 0 {
		return fmt.aprintf(
			"aether: goal set — %s (token budget %d)",
			obj,
			budget,
			allocator = allocator,
		)
	}
	return fmt.aprintf("aether: goal set — %s", obj, allocator = allocator)
}
