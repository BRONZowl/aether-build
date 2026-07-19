package agent

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "aether:core"
import "aether:tools"

SESSION_FORMAT_VERSION :: 1

Session :: struct {
	id:        string,
	title:     string,
	path:      string,
	model:     string,
	cwd:       string,
	created_at: string,
	updated_at: string,
	msgs:      [dynamic]Chat_Message,
	auto_save: bool,
	// sessions_dir used for list/load resolution
	sessions_dir: string,
	// plan_mode: true when Active (edit gate / chip); full snapshot below
	plan_mode: bool,
	// Grok-shaped plan lifecycle snapshot (optional on load)
	plan_mode_state:                 string, // inactive|pending|active|exit_pending
	plan_mode_was_active:            bool,
	plan_mode_reminder_count:        u32,
	plan_mode_pending_exit_reminder: bool,
	plan_mode_awaiting_approval:     bool,
	// memory_injected: first-turn memory context latch (A2.3)
	memory_injected: bool,
}

destroy_session :: proc(s: ^Session) {
	delete(s.id)
	delete(s.title)
	delete(s.path)
	delete(s.model)
	delete(s.cwd)
	delete(s.created_at)
	delete(s.updated_at)
	delete(s.sessions_dir)
	delete(s.plan_mode_state)
	destroy_messages(s.msgs[:])
	s.msgs = {}
}

// new_session creates an empty session with system prompt only.
// skills_catalog is optional markdown appended to the system prompt.
new_session :: proc(
	model: string,
	cwd: string,
	sessions_dir: string,
	auto_save: bool,
	permission_mode: core.Permission_Mode = .Always_Approve,
	allocator := context.allocator,
	skills_catalog := "",
) -> Session {
	dir := core.aether_sessions_dir(sessions_dir, allocator)
	_ = core.ensure_dir(dir)
	id := generate_session_id(allocator)
	path, _ := filepath.join({dir, fmt.tprintf("%s.json", id)}, allocator)
	now := now_rfc3339(allocator)
	s := Session {
		id           = id,
		title        = "",
		path         = path,
		model        = strings.clone(model, allocator),
		cwd          = strings.clone(cwd, allocator),
		created_at   = now,
		updated_at   = strings.clone(now, allocator),
		auto_save    = auto_save,
		sessions_dir = strings.clone(dir, allocator),
	}
	s.msgs = make([dynamic]Chat_Message, 0, 32, allocator)
	append(
		&s.msgs,
		Chat_Message {
			role    = .System,
			content = build_system_prompt(cwd, permission_mode, allocator, skills_catalog),
		},
	)
	return s
}

// g_session_id_seq disambiguates ids generated in the same second (fork/new).
g_session_id_seq: u32

generate_session_id :: proc(allocator := context.allocator) -> string {
	t := time.now()
	dt, ok := time.time_to_datetime(t)
	if !ok {
		g_session_id_seq += 1
		return fmt.aprintf(
			"sess-%d-%d",
			os.get_pid(),
			g_session_id_seq,
			allocator = allocator,
		)
	}
	g_session_id_seq += 1
	// nsec + pid + seq so fork immediately after save never collides
	nsec := u64(t._nsec)
	tag := u32(nsec) ~ u32(os.get_pid()) ~ g_session_id_seq
	return fmt.aprintf(
		"%04d%02d%02d-%02d%02d%02d-%08x",
		dt.year,
		int(dt.month),
		dt.day,
		dt.hour,
		dt.minute,
		dt.second,
		tag,
		allocator = allocator,
	)
}

now_rfc3339 :: proc(allocator := context.allocator) -> string {
	return format_rfc3339_utc(time.now(), allocator)
}

// sanitize_session_key allows only safe filename characters.
sanitize_session_key :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		ok :=
			(ch >= 'A' && ch <= 'Z') ||
			(ch >= 'a' && ch <= 'z') ||
			(ch >= '0' && ch <= '9') ||
			ch == '-' ||
			ch == '_' ||
			ch == '.'
		if ok {
			strings.write_byte(&b, ch)
		} else if ch == ' ' {
			strings.write_byte(&b, '-')
		}
	}
	out := strings.to_string(b)
	if out == "" {
		return strings.clone("session", allocator)
	}
	return out
}

// session_title_from_text builds a one-line display title (allocated).
session_title_from_text :: proc(text: string, max_len := 60, allocator := context.allocator) -> string {
	t := strings.trim_space(text)
	if t == "" {
		return strings.clone("", allocator)
	}
	// first line only
	if nl := strings.index_byte(t, '\n'); nl >= 0 {
		t = strings.trim_space(t[:nl])
	}
	// collapse whitespace runs
	b := strings.builder_make_len_cap(0, min(len(t), max_len + 8), allocator)
	prev_space := false
	n := 0
	for r in t {
		if r == ' ' || r == '\t' || r == '\r' {
			if prev_space {
				continue
			}
			prev_space = true
			strings.write_rune(&b, ' ')
			n += 1
		} else {
			prev_space = false
			strings.write_rune(&b, r)
			n += 1
		}
		if n >= max_len {
			strings.write_string(&b, "…")
			break
		}
	}
	return strings.to_string(b)
}

// session_first_user_text returns content of first non-empty user message (not owned).
session_first_user_text :: proc(s: Session) -> string {
	for m in s.msgs {
		if m.role == .User && strings.trim_space(m.content) != "" {
			return m.content
		}
	}
	return ""
}

// session_ensure_title sets title from first user prompt when still empty.
session_ensure_title :: proc(s: ^Session) {
	if s.title != "" {
		return
	}
	u := session_first_user_text(s^)
	if u == "" {
		return
	}
	delete(s.title)
	s.title = session_title_from_text(u)
}

// first_user_content_from_json_obj light-scans messages array for first user content.
first_user_content_from_json_obj :: proc(obj: json.Object) -> string {
	msgs_v, has := obj["messages"]
	if !has {
		return ""
	}
	arr, ok := msgs_v.(json.Array)
	if !ok {
		return ""
	}
	for item in arr {
		mobj, is_obj := item.(json.Object)
		if !is_obj {
			continue
		}
		role, _ := json_str(mobj, "role")
		if role != "user" {
			continue
		}
		content, _ := json_str(mobj, "content")
		if strings.trim_space(content) != "" {
			return content
		}
	}
	return ""
}

// session_save writes s to s.path atomically.
session_save :: proc(s: ^Session) -> string /* error */ {
	if s.path == "" {
		return "no session path"
	}
	session_ensure_title(s)
	// Persist live plan mode snapshot
	snap := plan_mode_snapshot_for_save()
	s.plan_mode = snap.state == .Active || snap.state == .Pending || snap.state == .Exit_Pending
	delete(s.plan_mode_state)
	s.plan_mode_state = strings.clone(plan_state_to_string(snap.state))
	s.plan_mode_was_active = snap.was_previously_active
	s.plan_mode_reminder_count = snap.reminder_count
	s.plan_mode_pending_exit_reminder = snap.pending_exit_reminder
	s.plan_mode_awaiting_approval = snap.awaiting_plan_approval
	dir := filepath.dir(s.path)
	if !core.ensure_dir(dir) {
		return fmt.tprintf("cannot create sessions dir: %s", dir)
	}
	delete(s.updated_at)
	s.updated_at = now_rfc3339()

	body := session_to_json(s^, context.temp_allocator)
	tmp := fmt.tprintf("%s.tmp.%d", s.path, os.get_pid())
	if err := os.write_entire_file(tmp, transmute([]byte)body); err != nil {
		return fmt.tprintf("write failed: %v", err)
	}
	if err := os.rename(tmp, s.path); err != nil {
		_ = os.remove(tmp)
		return fmt.tprintf("rename failed: %v", err)
	}
	return ""
}

session_to_json :: proc(s: Session, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"version":`)
	strings.write_string(&b, fmt.tprintf("%d", SESSION_FORMAT_VERSION))
	strings.write_string(&b, `,"id":"`)
	strings.write_string(&b, json_escape(s.id, context.temp_allocator))
	strings.write_string(&b, `","title":"`)
	strings.write_string(&b, json_escape(s.title, context.temp_allocator))
	strings.write_string(&b, `","created_at":"`)
	strings.write_string(&b, json_escape(s.created_at, context.temp_allocator))
	strings.write_string(&b, `","updated_at":"`)
	strings.write_string(&b, json_escape(s.updated_at, context.temp_allocator))
	strings.write_string(&b, `","model":"`)
	strings.write_string(&b, json_escape(s.model, context.temp_allocator))
	strings.write_string(&b, `","cwd":"`)
	strings.write_string(&b, json_escape(s.cwd, context.temp_allocator))
	if s.plan_mode {
		strings.write_string(&b, `","plan_mode":true`)
	} else {
		strings.write_string(&b, `","plan_mode":false`)
	}
	st := s.plan_mode_state
	if st == "" {
		st = "active" if s.plan_mode else "inactive"
	}
	strings.write_string(&b, `,"plan_mode_state":"`)
	strings.write_string(&b, json_escape(st, context.temp_allocator))
	strings.write_string(&b, `"`)
	if s.plan_mode_was_active {
		strings.write_string(&b, `,"plan_mode_was_active":true`)
	} else {
		strings.write_string(&b, `,"plan_mode_was_active":false`)
	}
	strings.write_string(
		&b,
		fmt.tprintf(`,"plan_mode_reminder_count":%d`, s.plan_mode_reminder_count),
	)
	if s.plan_mode_pending_exit_reminder {
		strings.write_string(&b, `,"plan_mode_pending_exit_reminder":true`)
	} else {
		strings.write_string(&b, `,"plan_mode_pending_exit_reminder":false`)
	}
	if s.plan_mode_awaiting_approval {
		strings.write_string(&b, `,"plan_mode_awaiting_approval":true`)
	} else {
		strings.write_string(&b, `,"plan_mode_awaiting_approval":false`)
	}
	if s.memory_injected {
		strings.write_string(&b, `,"memory_injected":true`)
	} else {
		strings.write_string(&b, `,"memory_injected":false`)
	}
	// Session-scoped todos (process list snapshot)
	strings.write_string(&b, `,"todos":`)
	strings.write_string(&b, tools.todo_snapshot_json_array(context.temp_allocator))
	// Goal mode snapshot
	strings.write_string(&b, `,"goal":`)
	strings.write_string(&b, goal_snapshot_json_object(context.temp_allocator))
	strings.write_string(&b, `,"messages":[`)
	for m, i in s.msgs {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		write_message_json(&b, m)
	}
	strings.write_string(&b, `]}`)
	return strings.to_string(b)
}

write_message_json :: proc(b: ^strings.Builder, m: Chat_Message) {
	strings.write_string(b, `{"role":"`)
	strings.write_string(b, role_str(m.role))
	strings.write_string(b, `","content":"`)
	strings.write_string(b, json_escape(m.content, context.temp_allocator))
	strings.write_string(b, `"`)
	if m.role == .Tool && m.tool_call_id != "" {
		strings.write_string(b, `,"tool_call_id":"`)
		strings.write_string(b, json_escape(m.tool_call_id, context.temp_allocator))
		strings.write_string(b, `"`)
	}
	if m.role == .Assistant && len(m.tool_calls) > 0 {
		strings.write_string(b, `,"tool_calls":[`)
		for tc, j in m.tool_calls {
			if j > 0 {
				strings.write_byte(b, ',')
			}
			strings.write_string(b, `{"id":"`)
			strings.write_string(b, json_escape(tc.id, context.temp_allocator))
			strings.write_string(b, `","name":"`)
			strings.write_string(b, json_escape(tc.name, context.temp_allocator))
			strings.write_string(b, `","arguments":"`)
			strings.write_string(b, json_escape(tc.arguments, context.temp_allocator))
			strings.write_string(b, `"}`)
		}
		strings.write_string(b, `]`)
	}
	strings.write_byte(b, '}')
}

// session_load_file loads a session JSON file into a new Session (caller destroys).
session_load_file :: proc(
	path: string,
	auto_save: bool,
	allocator := context.allocator,
) -> (Session, string /* error */) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {}, fmt.tprintf("cannot read %s: %v", path, err)
	}
	return session_from_json(string(data), path, auto_save, allocator)
}

// session_import_file loads a session/export JSON and materializes it as a **new**
// session under sessions_dir (new id + path). Does not overwrite the source file.
// B29 / import of B27 /export json dumps.
session_import_file :: proc(
	src_path: string,
	sessions_dir: string,
	auto_save: bool,
	allocator := context.allocator,
) -> (
	Session,
	string, /* error */
) {
	src := strings.trim_space(src_path)
	if src == "" {
		return {}, "import path is empty"
	}
	// expand ~/
	if strings.has_prefix(src, "~/") {
		home := os.get_env("HOME", context.temp_allocator)
		if home != "" {
			src = fmt.tprintf("%s/%s", home, src[2:])
		}
	}
	if !os.exists(src) {
		return {}, fmt.tprintf("file not found: %s", src)
	}
	if os.is_directory(src) {
		return {}, "import path is a directory"
	}
	loaded, lerr := session_load_file(src, auto_save, allocator)
	if lerr != "" {
		return {}, lerr
	}
	dir := sessions_dir
	if dir == "" {
		dir = core.aether_sessions_dir("", context.temp_allocator)
	}
	_ = core.ensure_dir(dir)

	// New identity so save won't clobber source export
	old_id := loaded.id
	delete(loaded.id)
	loaded.id = generate_session_id(allocator)
	delete(loaded.path)
	loaded.path = fmt.aprintf("%s/%s.json", dir, loaded.id, allocator = allocator)
	delete(loaded.sessions_dir)
	loaded.sessions_dir = strings.clone(dir, allocator)
	// Title: keep or mark imported
	if loaded.title == "" {
		loaded.title = fmt.aprintf("imported from %s", filepath.base(src), allocator = allocator)
	} else if !strings.has_prefix(loaded.title, "imported:") {
		// keep original title; note source in updated_at only
		_ = old_id
	}
	delete(loaded.updated_at)
	loaded.updated_at = now_rfc3339()
	loaded.auto_save = auto_save
	if auto_save {
		if e := session_save(&loaded); e != "" {
			// still return session; surface save error to caller via empty path? keep soft
			_ = e
		}
	}
	return loaded, ""
}

session_from_json :: proc(
	raw: string,
	path: string,
	auto_save: bool,
	allocator := context.allocator,
) -> (Session, string /* error */) {
	val, perr := json.parse(transmute([]byte)raw, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil {
		return {}, fmt.tprintf("invalid JSON: %v", perr)
	}
	obj, ok := val.(json.Object)
	if !ok {
		return {}, "session root must be object"
	}

	s: Session
	s.auto_save = auto_save
	s.path = strings.clone(path, allocator)
	s.msgs = make([dynamic]Chat_Message, 0, 32, allocator)

	if id, has := json_str(obj, "id"); has {
		s.id = strings.clone(id, allocator)
	} else {
		s.id = strings.clone(filepath.stem(path), allocator)
	}
	if title, has := json_str(obj, "title"); has {
		s.title = strings.clone(title, allocator)
	}
	if v, has := json_str(obj, "created_at"); has {
		s.created_at = strings.clone(v, allocator)
	}
	if v, has := json_str(obj, "updated_at"); has {
		s.updated_at = strings.clone(v, allocator)
	}
	if v, has := json_str(obj, "model"); has {
		s.model = strings.clone(v, allocator)
	}
	if v, has := json_str(obj, "cwd"); has {
		s.cwd = strings.clone(v, allocator)
	}
	// Optional plan_mode snapshot (default false for older sessions)
	if pv, has := obj["plan_mode"]; has {
		if b, is_bool := pv.(json.Boolean); is_bool {
			s.plan_mode = bool(b)
		}
	}
	if v, has := json_str(obj, "plan_mode_state"); has {
		s.plan_mode_state = strings.clone(v, allocator)
	}
	if pv, has := obj["plan_mode_was_active"]; has {
		if b, is_bool := pv.(json.Boolean); is_bool {
			s.plan_mode_was_active = bool(b)
		}
	}
	if pv, has := obj["plan_mode_reminder_count"]; has {
		#partial switch n in pv {
		case json.Integer:
			s.plan_mode_reminder_count = u32(n)
		case json.Float:
			s.plan_mode_reminder_count = u32(n)
		}
	}
	if pv, has := obj["plan_mode_pending_exit_reminder"]; has {
		if b, is_bool := pv.(json.Boolean); is_bool {
			s.plan_mode_pending_exit_reminder = bool(b)
		}
	}
	if pv, has := obj["plan_mode_awaiting_approval"]; has {
		if b, is_bool := pv.(json.Boolean); is_bool {
			s.plan_mode_awaiting_approval = bool(b)
		}
	}
	if pv, has := obj["memory_injected"]; has {
		if b, is_bool := pv.(json.Boolean); is_bool {
			s.memory_injected = bool(b)
		}
	}
	s.sessions_dir = strings.clone(filepath.dir(path), allocator)

	msgs_v, has_msgs := obj["messages"]
	if !has_msgs {
		return s, "session missing messages"
	}
	arr, is_arr := msgs_v.(json.Array)
	if !is_arr {
		return s, "messages must be array"
	}
	for item in arr {
		mobj, is_obj := item.(json.Object)
		if !is_obj {
			continue
		}
		m, merr := message_from_json_obj(mobj, allocator)
		if merr != "" {
			destroy_session(&s)
			return {}, merr
		}
		append(&s.msgs, m)
	}
	if len(s.msgs) == 0 {
		append(
			&s.msgs,
			Chat_Message {
				role    = .System,
				content = build_system_prompt(s.cwd, .Always_Approve, allocator),
			},
		)
	}
	// Restore process-global plan lifecycle tracker
	sync_plan_mode_from_session(
		s.plan_mode,
		s.plan_mode_state,
		s.plan_mode_was_active,
		s.plan_mode_reminder_count,
		s.plan_mode_pending_exit_reminder,
		s.plan_mode_awaiting_approval,
	)
	// Refresh bool after collapse
	s.plan_mode = plan_mode_is_active() || plan_mode_is_pending() || plan_mode_is_exit_pending()
	// Restore session-scoped todo list into process registry
	if tv, has_todos := obj["todos"]; has_todos {
		if todos_arr, is_todos := tv.(json.Array); is_todos {
			tools.todo_restore_from_json_array(todos_arr)
		} else {
			tools.todo_clear()
		}
	} else {
		// Older sessions without todos key → empty list on load
		tools.todo_clear()
	}
	// Restore goal
	if gv, has_goal := obj["goal"]; has_goal {
		if gobj, is_g := gv.(json.Object); is_g {
			goal_restore_from_json_object(gobj)
		} else {
			goal_clear()
		}
	} else {
		goal_clear()
	}
	return s, ""
}

message_from_json_obj :: proc(obj: json.Object, allocator := context.allocator) -> (Chat_Message, string) {
	role_s, _ := json_str(obj, "role")
	role: Chat_Role
	switch role_s {
	case "system":
		role = .System
	case "user":
		role = .User
	case "assistant":
		role = .Assistant
	case "tool":
		role = .Tool
	case:
		return {}, fmt.tprintf("unknown role: %s", role_s)
	}
	content, _ := json_str(obj, "content")
	m := Chat_Message {
		role    = role,
		content = strings.clone(content, allocator),
	}
	if role == .Tool {
		if tid, has := json_str(obj, "tool_call_id"); has {
			m.tool_call_id = strings.clone(tid, allocator)
		}
	}
	if role == .Assistant {
		if tc_v, has := obj["tool_calls"]; has {
			if arr, is_arr := tc_v.(json.Array); is_arr {
				tcs := make([dynamic]Tool_Call, 0, len(arr), allocator)
				for item in arr {
					tobj, is_obj := item.(json.Object)
					if !is_obj {
						continue
					}
					tc: Tool_Call
					if id, h := json_str(tobj, "id"); h {
						tc.id = strings.clone(id, allocator)
					}
					if name, h := json_str(tobj, "name"); h {
						tc.name = strings.clone(name, allocator)
					}
					if args, h := json_str(tobj, "arguments"); h {
						tc.arguments = strings.clone(args, allocator)
					}
					append(&tcs, tc)
				}
				m.tool_calls = tcs[:]
			}
		}
	}
	return m, ""
}

// resolve_session_ref finds a session file by id, title, or path.
// Matching: path/file → case-insensitive id/title equality → unique substring on id/title.
resolve_session_ref :: proc(
	ref: string,
	sessions_dir: string,
	allocator := context.allocator,
) -> (path: string, err: string) {
	if ref == "" {
		return "", "empty session ref"
	}
	// absolute or relative path to a file
	if strings.has_suffix(ref, ".json") || os.is_absolute_path(ref) || strings.contains(ref, "/") {
		if os.exists(ref) {
			return strings.clone(ref, allocator), ""
		}
		// try as path under sessions dir
	}
	dir := core.aether_sessions_dir(sessions_dir, context.temp_allocator)
	// id.json
	cand, _ := filepath.join({dir, fmt.tprintf("%s.json", sanitize_session_key(ref, context.temp_allocator))}, context.temp_allocator)
	if os.exists(cand) {
		return strings.clone(cand, allocator), ""
	}
	// bare ref as filename
	cand2, _ := filepath.join({dir, ref}, context.temp_allocator)
	if os.exists(cand2) {
		return strings.clone(cand2, allocator), ""
	}

	entries, lerr := list_sessions(dir, context.temp_allocator)
	if lerr != "" {
		return "", fmt.tprintf("session not found: %s", ref)
	}
	ref_l := strings.to_lower(ref, context.temp_allocator)

	// 1) case-insensitive exact id or title
	for e in entries {
		if strings.equal_fold(e.id, ref) || strings.equal_fold(e.title, ref) {
			return strings.clone(e.path, allocator), ""
		}
	}
	// 2) unique case-insensitive substring on id or title
	hits: [dynamic]Session_List_Entry
	hits.allocator = context.temp_allocator
	for e in entries {
		id_l := strings.to_lower(e.id, context.temp_allocator)
		title_l := strings.to_lower(e.title, context.temp_allocator)
		if strings.contains(id_l, ref_l) || (e.title != "" && strings.contains(title_l, ref_l)) {
			append(&hits, e)
		}
	}
	if len(hits) == 1 {
		return strings.clone(hits[0].path, allocator), ""
	}
	if len(hits) > 1 {
		return "", fmt.tprintf("ambiguous session: %d matches for %q (use full id)", len(hits), ref)
	}
	return "", fmt.tprintf("session not found: %s", ref)
}

Session_List_Entry :: struct {
	id:         string,
	title:      string,
	path:       string,
	updated_at: string,
	model:      string,
	msg_count:  int, // B14: messages array length when known
}

destroy_session_list :: proc(entries: []Session_List_Entry) {
	for e in entries {
		delete(e.id)
		delete(e.title)
		delete(e.path)
		delete(e.updated_at)
		delete(e.model)
	}
	delete(entries)
}

// format_session_when shortens RFC3339 for list chrome (B14).
format_session_when :: proc(rfc3339: string, allocator := context.allocator) -> string {
	s := strings.trim_space(rfc3339)
	if s == "" {
		return strings.clone("-", allocator)
	}
	// Prefer YYYY-MM-DD HH:MM when ISO-like
	if len(s) >= 16 && s[4] == '-' && s[10] == 'T' {
		// 2026-07-19T12:34:56Z → 07-19 12:34
		return fmt.aprintf("%s %s", s[5:10], s[11:16], allocator = allocator)
	}
	if len(s) > 19 {
		return strings.clone(s[:19], allocator)
	}
	return strings.clone(s, allocator)
}

// format_session_list_line: one dashboard row (B14).
format_session_list_line :: proc(
	e: Session_List_Entry,
	is_current: bool,
	index: int, // 1-based display index; 0 = omit
	allocator := context.allocator,
) -> string {
	title := e.title if e.title != "" else "-"
	if len(title) > 48 {
		title = fmt.tprintf("%s…", title[:47])
	}
	when_s := format_session_when(e.updated_at, context.temp_allocator)
	model := e.model if e.model != "" else "-"
	if len(model) > 16 {
		model = model[:16]
	}
	mark := " *" if is_current else ""
	id := e.id
	if len(id) > 22 {
		id = id[:22]
	}
	if index > 0 {
		return fmt.aprintf(
			"%2d  %-22s  %-11s  %3d  %-16s  %s%s",
			index,
			id,
			when_s,
			e.msg_count,
			model,
			title,
			mark,
			allocator = allocator,
		)
	}
	return fmt.aprintf(
		"%-22s  %-11s  %3d  %-16s  %s%s",
		id,
		when_s,
		e.msg_count,
		model,
		title,
		mark,
		allocator = allocator,
	)
}

// list_sessions returns sessions sorted by updated_at descending (best-effort).
list_sessions :: proc(sessions_dir: string, allocator := context.allocator) -> ([]Session_List_Entry, string) {
	dir := core.aether_sessions_dir(sessions_dir, context.temp_allocator)
	if !os.exists(dir) {
		return {}, ""
	}
	fis, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return {}, fmt.tprintf("list dir: %v", err)
	}
	out := make([dynamic]Session_List_Entry, 0, len(fis), allocator)
	for fi in fis {
		name := fi.name
		if !strings.has_suffix(name, ".json") {
			continue
		}
		path, _ := filepath.join({dir, name}, context.temp_allocator)
		// light parse for metadata
		data, rerr := os.read_entire_file(path, context.temp_allocator)
		if rerr != nil {
			continue
		}
		val, perr := json.parse(data, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
		if perr != nil {
			continue
		}
		obj, ok := val.(json.Object)
		if !ok {
			continue
		}
		e: Session_List_Entry
		e.path = strings.clone(path, allocator)
		if id, h := json_str(obj, "id"); h {
			e.id = strings.clone(id, allocator)
		} else {
			e.id = strings.clone(filepath.stem(name), allocator)
		}
		if title, h := json_str(obj, "title"); h && strings.trim_space(title) != "" {
			e.title = strings.clone(title, allocator)
		} else {
			// display fallback: first user message (not written until next save)
			if u := first_user_content_from_json_obj(obj); u != "" {
				e.title = session_title_from_text(u, 60, allocator)
			}
		}
		if u, h := json_str(obj, "updated_at"); h {
			e.updated_at = strings.clone(u, allocator)
		}
		if m, h := json_str(obj, "model"); h {
			e.model = strings.clone(m, allocator)
		}
		// message count for dashboard list
		if mv, has := obj["messages"]; has {
			if arr, is_a := mv.(json.Array); is_a {
				e.msg_count = len(arr)
			}
		}
		append(&out, e)
	}
	// sort by updated_at desc (string RFC3339 sorts lexicographically)
	slice.sort_by(out[:], proc(a, b: Session_List_Entry) -> bool {
		return a.updated_at > b.updated_at
	})
	return out[:], ""
}

// most_recent_session_path returns path of newest session or "".
most_recent_session_path :: proc(sessions_dir: string, allocator := context.allocator) -> string {
	entries, err := list_sessions(sessions_dir, context.temp_allocator)
	if err != "" || len(entries) == 0 {
		return ""
	}
	return strings.clone(entries[0].path, allocator)
}

// session_set_title updates the title and optionally autosaves.
session_set_title :: proc(s: ^Session, title: string) -> string /* error */ {
	if s == nil {
		return "no session"
	}
	t := strings.trim_space(title)
	if t == "" {
		return "title is required"
	}
	delete(s.title)
	s.title = strings.clone(t)
	if s.auto_save {
		return session_save(s)
	}
	return ""
}

// session_fork clones history into a new session id/path. Caller owns result.
// Optional title; default is "<src title> (fork)" or "fork".
session_fork :: proc(
	src: Session,
	title: string,
	allocator := context.allocator,
) -> (
	Session,
	string, /* error */
) {
	dir := src.sessions_dir
	if dir == "" {
		dir = core.aether_sessions_dir("", context.temp_allocator)
	}
	_ = core.ensure_dir(dir)
	id := generate_session_id(allocator)
	path, _ := filepath.join({dir, fmt.tprintf("%s.json", id)}, allocator)
	now := now_rfc3339(allocator)

	title_s := strings.trim_space(title)
	if title_s == "" {
		if strings.trim_space(src.title) != "" {
			title_s = fmt.tprintf("%s (fork)", src.title)
		} else {
			title_s = "fork"
		}
	}

	s := Session {
		id                               = id,
		title                            = strings.clone(title_s, allocator),
		path                             = path,
		model                            = strings.clone(src.model, allocator),
		cwd                              = strings.clone(src.cwd, allocator),
		created_at                       = now,
		updated_at                       = strings.clone(now, allocator),
		auto_save                        = src.auto_save,
		sessions_dir                     = strings.clone(dir, allocator),
		plan_mode                        = src.plan_mode,
		plan_mode_state                  = strings.clone(src.plan_mode_state, allocator),
		plan_mode_was_active             = src.plan_mode_was_active,
		plan_mode_reminder_count         = src.plan_mode_reminder_count,
		plan_mode_pending_exit_reminder  = src.plan_mode_pending_exit_reminder,
		plan_mode_awaiting_approval      = src.plan_mode_awaiting_approval,
		memory_injected                  = src.memory_injected,
	}
	s.msgs = clone_messages(src.msgs[:], allocator)

	if err := session_save(&s); err != "" {
		destroy_session(&s)
		return {}, err
	}
	return s, ""
}

// session_delete_by_ref removes a session JSON file. Refuses current_path when set.
session_delete_by_ref :: proc(
	ref: string,
	sessions_dir: string,
	current_path: string = "",
) -> string /* error */ {
	path, err := resolve_session_ref(ref, sessions_dir, context.temp_allocator)
	if err != "" {
		return err
	}
	if current_path != "" {
		// normalize compare
		if path == current_path {
			return "cannot delete the current session (switch with /load or /new first)"
		}
		// also match by abs if available
		if a, e1 := filepath.abs(path, context.temp_allocator); e1 == nil {
			if b, e2 := filepath.abs(current_path, context.temp_allocator); e2 == nil && a == b {
				return "cannot delete the current session (switch with /load or /new first)"
			}
		}
	}
	if !os.exists(path) {
		return fmt.tprintf("session file missing: %s", path)
	}
	if rerr := os.remove(path); rerr != nil {
		return fmt.tprintf("delete failed: %v", rerr)
	}
	return ""
}

// Export_Format for /export (B27).
Export_Format :: enum {
	Markdown,
	Json,
}

// parse_export_arg: "json out.json" | "md" | "path.md" | "path.json" | ""
// Returns format + path (path may be empty for default).
parse_export_arg :: proc(arg: string) -> (fmt: Export_Format, path: string) {
	a := strings.trim_space(arg)
	fmt = .Markdown
	path = ""
	if a == "" {
		return
	}
	// first token format keyword?
	tok, rest := "", ""
	if sp := strings.index_byte(a, ' '); sp >= 0 {
		tok = strings.to_lower(a[:sp], context.temp_allocator)
		rest = strings.trim_space(a[sp + 1:])
	} else {
		tok = strings.to_lower(a, context.temp_allocator)
		rest = ""
	}
	switch tok {
	case "json", "jsonl":
		fmt = .Json
		path = rest
		return
	case "md", "markdown":
		fmt = .Markdown
		path = rest
		return
	}
	// no keyword — treat whole arg as path; infer format from suffix
	path = a
	pl := strings.to_lower(path, context.temp_allocator)
	if strings.has_suffix(pl, ".json") || strings.has_suffix(pl, ".jsonl") {
		fmt = .Json
	} else {
		fmt = .Markdown
	}
	return
}

// session_export_resolve_path: empty → default under sessions dir with ext.
session_export_resolve_path :: proc(
	s: Session,
	out_path: string,
	ext: string, // ".md" or ".json"
	allocator := context.allocator,
) -> string {
	path := strings.trim_space(out_path)
	if path != "" {
		return strings.clone(path, allocator)
	}
	dir := s.sessions_dir
	if dir == "" && s.path != "" {
		dir = filepath.dir(s.path)
	}
	if dir == "" {
		dir = core.aether_sessions_dir("", context.temp_allocator)
	}
	_ = core.ensure_dir(dir)
	return fmt.aprintf(
		"%s/%s-export%s",
		dir,
		s.id if s.id != "" else "session",
		ext,
		allocator = allocator,
	)
}

// session_export_markdown writes a human-readable transcript. Empty out_path →
// <sessions_dir>/<id>-export.md. Returns owned path string.
session_export_markdown :: proc(
	s: Session,
	out_path: string,
	allocator := context.allocator,
) -> (
	path: string,
	err: string,
) {
	path = session_export_resolve_path(s, out_path, ".md", allocator)

	b := strings.builder_make(allocator)
	title := s.title if s.title != "" else "(untitled)"
	strings.write_string(&b, fmt.tprintf("# %s\n\n", title))
	strings.write_string(&b, fmt.tprintf("- id: `%s`\n", s.id))
	strings.write_string(&b, fmt.tprintf("- model: `%s`\n", s.model))
	strings.write_string(&b, fmt.tprintf("- cwd: `%s`\n", s.cwd))
	strings.write_string(&b, fmt.tprintf("- messages: %d\n\n", len(s.msgs)))
	strings.write_string(&b, "---\n\n")

	for m in s.msgs {
		role := role_str(m.role)
		// Skip empty assistant tool-only noise when content empty and tool_calls present?
		// Export all with content; tool results included as tool role.
		if strings.trim_space(m.content) == "" && len(m.tool_calls) == 0 {
			continue
		}
		strings.write_string(&b, fmt.tprintf("## %s\n\n", role))
		if strings.trim_space(m.content) != "" {
			strings.write_string(&b, m.content)
			strings.write_string(&b, "\n\n")
		}
		if len(m.tool_calls) > 0 {
			for tc in m.tool_calls {
				strings.write_string(
					&b,
					fmt.tprintf("*(tool call `%s` %s)*\n\n", tc.name, tc.id),
				)
			}
		}
	}

	body := strings.to_string(b)
	// ensure parent dir for custom paths
	parent := filepath.dir(path)
	if parent != "" && parent != "." {
		_ = core.ensure_dir(parent)
	}
	if werr := os.write_entire_file(path, transmute([]byte)body); werr != nil {
		delete(path)
		delete(body)
		return "", fmt.tprintf("export write failed: %v", werr)
	}
	delete(body)
	return path, ""
}

// session_export_json writes full session JSON (same schema as on-disk session file).
// Empty out_path → <sessions_dir>/<id>-export.json. Returns owned path string.
session_export_json :: proc(
	s: Session,
	out_path: string,
	allocator := context.allocator,
) -> (
	path: string,
	err: string,
) {
	path = session_export_resolve_path(s, out_path, ".json", allocator)
	body := session_to_json(s, context.temp_allocator)
	parent := filepath.dir(path)
	if parent != "" && parent != "." {
		_ = core.ensure_dir(parent)
	}
	if werr := os.write_entire_file(path, transmute([]byte)body); werr != nil {
		delete(path)
		return "", fmt.tprintf("export write failed: %v", werr)
	}
	return path, ""
}

// session_export dispatches markdown or JSON (B27).
session_export :: proc(
	s: Session,
	arg: string,
	allocator := context.allocator,
) -> (
	path: string,
	err: string,
) {
	fmt_kind, out_path := parse_export_arg(arg)
	switch fmt_kind {
	case .Json:
		return session_export_json(s, out_path, allocator)
	case .Markdown:
		return session_export_markdown(s, out_path, allocator)
	}
	return session_export_markdown(s, out_path, allocator)
}
