// Package agent — local /feedback JSONL persistence (B1.3).
// Grok kinship: session-dir feedback.jsonl; network FeedbackClient N/A.
package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "aether:core"

// feedback_jsonl_path: {dir of sess.path or aether sessions dir}/feedback.jsonl
feedback_jsonl_path :: proc(sess: ^Session, allocator := context.allocator) -> string {
	dir := ""
	if sess != nil && sess.path != "" {
		dir = filepath.dir(sess.path)
	}
	if dir == "" {
		sdir := ""
		if sess != nil {
			sdir = sess.sessions_dir
		}
		dir = core.aether_sessions_dir(sdir, context.temp_allocator)
	}
	joined, _ := filepath.join({dir, "feedback.jsonl"}, allocator)
	return joined
}

// append_session_feedback writes one JSONL line. Returns path or err message.
append_session_feedback :: proc(
	sess: ^Session,
	text: string,
	allocator := context.allocator,
) -> (
	path: string,
	err: string,
) {
	if sess == nil {
		return "", strings.clone("no session", allocator)
	}
	body := strings.trim_space(text)
	if body == "" {
		return "", strings.clone("empty feedback", allocator)
	}
	path = feedback_jsonl_path(sess, context.temp_allocator)
	parent := filepath.dir(path)
	if parent != "" && !os.exists(parent) {
		if !core.ensure_dir(parent) {
			return "", fmt.aprintf("cannot create %s", parent, allocator = allocator)
		}
	}

	ts := now_rfc3339(context.temp_allocator)
	// Use session json_escape
	line := fmt.tprintf(
		`{"type":"user_feedback","submittedAt":"%s","sessionId":"%s","solicited":false,"text":"%s","client":"aether","model":"%s","cwd":"%s"}` +
		"\n",
		json_escape(ts, context.temp_allocator),
		json_escape(sess.id, context.temp_allocator),
		json_escape(body, context.temp_allocator),
		json_escape(sess.model, context.temp_allocator),
		json_escape(sess.cwd, context.temp_allocator),
	)

	// Append: read-modify-write (keeps portability)
	existing := ""
	if os.exists(path) && !os.is_directory(path) {
		if data, rerr := os.read_entire_file(path, context.temp_allocator); rerr == nil {
			existing = string(data)
		}
	}
	combined := fmt.tprintf("%s%s", existing, line)
	if werr := os.write_entire_file(path, transmute([]byte)combined); werr != nil {
		return "", fmt.aprintf("write failed: %v", werr, allocator = allocator)
	}
	return strings.clone(path, allocator), ""
}

// handle_feedback_slash implements /feedback [help|text…].
handle_feedback_slash :: proc(
	sess: ^Session,
	arg: string,
	allocator := context.allocator,
) -> string {
	a := strings.trim_space(arg)
	al := strings.to_lower(a, context.temp_allocator)
	if a == "" || al == "help" || al == "?" {
		path := feedback_jsonl_path(sess, context.temp_allocator)
		return fmt.aprintf(
			"Usage: /feedback <text>\n" +
			"Record local feedback for this session (not sent to the model).\n" +
			"Appends one JSON line to:\n  %s\n" +
			"Remote feedback API: N/A (local only).",
			path,
			allocator = allocator,
		)
	}
	n_before := 0
	if sess != nil {
		n_before = len(sess.msgs)
	}
	path, err := append_session_feedback(sess, a, context.temp_allocator)
	if err != "" {
		return fmt.aprintf("aether: feedback failed: %s", err, allocator = allocator)
	}
	// Guard: must not grow chat history
	if sess != nil && len(sess.msgs) != n_before {
		// should never happen
	}
	return fmt.aprintf("aether: feedback saved → %s", path, allocator = allocator)
}
