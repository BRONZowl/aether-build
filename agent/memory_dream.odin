// Package agent — memory dream (/dream) consolidate session logs → MEMORY.md (A2.2).
// Grok refs: xai-grok-memory dream.rs + dream_lock.rs.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "aether:core"
import "aether:tools"

MAX_DREAM_INPUT_CHARS :: 32_000
MAX_DREAM_CHARS :: 16_000

// DREAM_SYSTEM_PROMPT is the one-shot model instruction (Grok-shaped, abbreviated).
DREAM_SYSTEM_PROMPT :: "You are performing a dream — a reflective pass over memory files. " +
	"Synthesize recent session logs into durable, well-organized memories " +
	"so future sessions orient quickly.\n\n" +
	"You will receive the contents of recent session logs. " +
	"You may also receive an existing memory document — merge it with new sessions " +
	"rather than discarding prior knowledge. Your job:\n\n" +
	"1. **Merge** related information into coherent topic summaries\n" +
	"2. **Resolve** contradictions — if a recent session disproves an older fact, keep only the current truth\n" +
	"3. **Convert** relative dates (\"yesterday\", \"last week\") to absolute dates\n" +
	"4. **Discard** ephemeral details (greetings, tool noise, current state, next steps, session metadata)\n" +
	"5. **Preserve** decisions, rationale, architecture, preferences, and problem/solution pairs\n\n" +
	"Respond with a single markdown document. Use ## headers to separate topics. " +
	"Each topic should be self-contained and useful to a future session.\n\n" +
	"If the session logs contain nothing worth persisting, respond with NO_REPLY."

// is_scaffold_template: short + Grok scaffold markers (do not feed as existing memory).
is_scaffold_template :: proc(content: string) -> bool {
	trimmed := strings.trim_space(content)
	if len(trimmed) >= 500 {
		return false
	}
	markers := []string {
		"Auto-populated by dream consolidation",
		"Add project-specific knowledge here",
		"Add any cross-project preferences here",
	}
	for m in markers {
		if strings.contains(trimmed, m) {
			return true
		}
	}
	return false
}

// process_dream_response returns accepted markdown or empty + reject reason.
process_dream_response :: proc(
	response: string,
	max_chars := MAX_DREAM_CHARS,
	allocator := context.allocator,
) -> (
	content: string,
	ok: bool,
	reason: string,
) {
	trimmed := strings.trim_space(response)
	if trimmed == "" {
		return "", false, strings.clone("empty", allocator)
	}
	if is_no_reply(trimmed) {
		return "", false, strings.clone("NO_REPLY", allocator)
	}
	if !has_markdown_headers(trimmed) {
		return "", false, strings.clone("no markdown headers", allocator)
	}
	body := trimmed
	if len(body) > max_chars {
		body = body[:max_chars]
	}
	return strings.clone(body, allocator), true, ""
}

// Dream_Message is the prompt payload + stems included under the size cap.
Dream_Message :: struct {
	content:          string, // allocated
	processed_stems:  []string, // allocated stems
}

destroy_dream_message :: proc(m: ^Dream_Message) {
	delete(m.content)
	for s in m.processed_stems {
		delete(s)
	}
	delete(m.processed_stems)
	m^ = {}
}

// build_dream_user_message concatenates existing MEMORY.md + session files.
// Returns ok=false if no session content readable.
build_dream_user_message :: proc(
	cwd: string,
	stems: []string,
	existing_memory: string,
	allocator := context.allocator,
) -> (
	msg: Dream_Message,
	ok: bool,
) {
	b := strings.builder_make(context.temp_allocator)
	processed := make([dynamic]string, 0, len(stems), allocator)

	if em := strings.trim_space(existing_memory); em != "" && !is_scaffold_template(em) {
		strings.write_string(&b, "--- Existing Memory (merge with new sessions) ---\n\n")
		cap_em := MAX_DREAM_INPUT_CHARS / 2
		if len(em) <= cap_em {
			strings.write_string(&b, em)
		} else {
			strings.write_string(&b, em[:cap_em])
		}
	}

	for stem in stems {
		content, rok := tools.memory_read_session_file(cwd, stem, context.temp_allocator)
		if !rok || strings.trim_space(content) == "" {
			continue
		}
		if strings.builder_len(b) > 0 {
			strings.write_string(&b, "\n\n")
		}
		strings.write_string(&b, "--- Session: ")
		strings.write_string(&b, stem)
		strings.write_string(&b, " ---\n\n")
		strings.write_string(&b, content)
		append(&processed, strings.clone(stem, allocator))
		if strings.builder_len(b) >= MAX_DREAM_INPUT_CHARS {
			break
		}
	}

	if len(processed) == 0 {
		delete(processed)
		return {}, false
	}
	msg = Dream_Message {
		content         = strings.clone(strings.to_string(b), allocator),
		processed_stems = processed[:],
	}
	return msg, true
}

// dream_heuristic_markdown offline consolidate (Mode B).
dream_heuristic_markdown :: proc(
	cwd: string,
	stems: []string,
	existing_memory: string,
	allocator := context.allocator,
) -> string {
	msg, ok := build_dream_user_message(cwd, stems, existing_memory, context.temp_allocator)
	if !ok {
		return strings.clone("", allocator)
	}
	// Shallow: keep structure with ## headers so quality gate passes.
	return fmt.aprintf(
		"## Workspace memory (heuristic dream)\n\n### Consolidated notes\n\n%s",
		msg.content,
		allocator = allocator,
	)
}

// check_dream_gates for future auto-dream; slash bypasses.
// Returns reason empty if open; otherwise why skipped.
check_dream_gates :: proc(
	cwd: string,
	min_hours: u64 = tools.DREAM_MIN_HOURS,
	min_sessions: u64 = tools.DREAM_MIN_SESSIONS,
	allocator := context.allocator,
) -> (
	open: bool,
	stems: []string,
	reason: string,
) {
	if !tools.memory_enabled() {
		return false, nil, strings.clone("memory disabled", allocator)
	}
	last := tools.dream_last_consolidated_unix(cwd)
	now := time.to_unix_seconds(time.now())
	if last > 0 {
		hours := u64(0)
		if now > last {
			hours = u64(now - last) / 3600
		}
		if hours < min_hours {
			return false, nil, fmt.aprintf(
				"too soon (%d h since last; need %d)",
				hours,
				min_hours,
				allocator = allocator,
			)
		}
	}
	since := last
	st := tools.memory_sessions_since(cwd, since, allocator)
	if u64(len(st)) < min_sessions {
		return false, st, fmt.aprintf(
			"too few sessions (%d; need %d)",
			len(st),
			min_sessions,
			allocator = allocator,
		)
	}
	return true, st, ""
}

// run_memory_dream consolidates session logs into workspace MEMORY.md.
// force=true: slash path — all session stems, skip time/session gates.
// force_heuristic=true: skip model even if creds exist.
run_memory_dream :: proc(
	sess: ^Session,
	model: string,
	force := true,
	force_heuristic := false,
	allocator := context.allocator,
) -> string {
	if !tools.memory_enabled() {
		return strings.clone("aether: memory is disabled (AETHER_NO_MEMORY=1)", allocator)
	}
	if sess == nil {
		return strings.clone("aether: no session", allocator)
	}
	cwd := sess.cwd
	if cwd == "" {
		return strings.clone("aether: session has no cwd", allocator)
	}

	stems: []string
	if force {
		stems = tools.memory_list_session_stems(cwd, context.temp_allocator)
	} else {
		open, gated, reason := check_dream_gates(cwd, tools.DREAM_MIN_HOURS, tools.DREAM_MIN_SESSIONS, context.temp_allocator)
		if !open {
			return fmt.aprintf("aether: dream skipped — %s", reason, allocator = allocator)
		}
		stems = gated
	}
	if len(stems) == 0 {
		return strings.clone("aether: no session logs to consolidate", allocator)
	}

	existing := tools.memory_read_workspace_md(cwd, context.temp_allocator)

	// Mode A: model
	content := ""
	mode := "heuristic"
	processed: []string

	if !force_heuristic {
		creds, cerr := resolve_credentials(context.temp_allocator)
		if cerr == "" {
			msg, mok := build_dream_user_message(cwd, stems, existing, context.temp_allocator)
			if mok {
				req := make([dynamic]Chat_Message, 0, 2, context.temp_allocator)
				append(
					&req,
					Chat_Message {
						role    = .System,
						content = strings.clone(DREAM_SYSTEM_PROMPT, context.temp_allocator),
					},
				)
				append(
					&req,
					Chat_Message {
						role    = .User,
						content = strings.clone(msg.content, context.temp_allocator),
					},
				)
				m := model
				if m == "" {
					m = sess.model
				}
				turn, err := chat_completion(creds, m, req[:], "")
				if err == "" {
					body, ok, reason := process_dream_response(turn.content, MAX_DREAM_CHARS, context.temp_allocator)
					destroy_assistant_turn(&turn)
					if ok {
						content = body
						mode = "model"
						processed = msg.processed_stems
					} else if reason == "NO_REPLY" || reason == "empty" {
						return fmt.aprintf(
							"aether: nothing to consolidate (%s)",
							reason,
							allocator = allocator,
						)
					}
					// rejected structure → fall through to heuristic
				}
			}
		}
	}

	if content == "" {
		// Mode B
		msg, mok := build_dream_user_message(cwd, stems, existing, context.temp_allocator)
		if !mok {
			return strings.clone("aether: no readable session content", allocator)
		}
		content = dream_heuristic_markdown(cwd, stems, existing, context.temp_allocator)
		processed = msg.processed_stems
		mode = "heuristic"
		if strings.trim_space(content) == "" {
			return strings.clone("aether: nothing to consolidate", allocator)
		}
		// ensure quality gate
		body, ok, _ := process_dream_response(content, MAX_DREAM_CHARS, context.temp_allocator)
		if !ok {
			return strings.clone("aether: heuristic dream failed quality gate", allocator)
		}
		content = body
	}

	// Lock + write
	acquired, prior, lerr := tools.dream_try_acquire(cwd)
	if lerr != "" {
		return fmt.aprintf("aether: dream lock error: %s", lerr, allocator = allocator)
	}
	if !acquired {
		return strings.clone(
			"aether: dream skipped — lock held by another process",
			allocator,
		)
	}

	path, werr := tools.memory_write_workspace_md(cwd, content, context.temp_allocator)
	if werr != "" {
		tools.dream_rollback(cwd, prior)
		return fmt.aprintf("aether: dream write failed: %s", werr, allocator = allocator)
	}
	_ = tools.dream_record(cwd)

	// Cleanup processed sessions (recency guard)
	cleaned := 0
	for stem in processed {
		if tools.memory_delete_session_stem(cwd, stem, tools.DREAM_CLEANUP_RECENCY_SECS) {
			cleaned += 1
		}
	}

	preview := strings.trim_space(content)
	if len(preview) > 400 {
		preview = fmt.tprintf("%s…", preview[:400])
	}
	return fmt.aprintf(
		"aether: dream complete (%s) → %s\nchars: %d  sessions_read: %d  cleaned: %d\n\n%s",
		mode,
		path,
		len(content),
		len(processed),
		cleaned,
		preview,
		allocator = allocator,
	)
}

// handle_dream_slash implements /dream [status|help|heuristic].
handle_dream_slash :: proc(
	sess: ^Session,
	model: string,
	arg: string,
	allocator := context.allocator,
) -> string {
	a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
	if a == "help" || a == "?" {
		return strings.clone(
			"Usage: /dream [status|heuristic|help]\n" +
			"Consolidate session logs into workspace MEMORY.md (model when creds; else offline).\n" +
			"Manual /dream bypasses min_hours/min_sessions gates (Grok slash parity).\n" +
			"  status     last consolidation, session count, lock\n" +
			"  heuristic  force offline merge\n" +
			"Opt-out: AETHER_NO_MEMORY=1  Auto-dream deferred.",
			allocator,
		)
	}
	if a == "status" || a == "show" || a == "info" {
		return dream_status_text(sess.cwd if sess != nil else "", allocator)
	}
	force_h := a == "heuristic" || a == "offline" || a == "local"
	return run_memory_dream(sess, model, true, force_h, allocator)
}

// auto_dream_enabled: memory on and not AETHER_NO_AUTO_DREAM.
// Config [memory] auto_dream=false also disables (env wins).
auto_dream_enabled :: proc() -> bool {
	if !tools.memory_enabled() {
		return false
	}
	if core.feature_killed("AETHER_NO_AUTO_DREAM") {
		return false
	}
	if !core.flag_auto_dream() {
		return false
	}
	return true
}

// maybe_auto_dream runs gated dream (force=false). Returns user-visible notice or "".
// Silent when gates fail / nothing to do (unless AETHER_VERBOSE=1).
maybe_auto_dream :: proc(
	sess: ^Session,
	model: string,
	allocator := context.allocator,
) -> string {
	if !auto_dream_enabled() || sess == nil {
		return ""
	}
	// Prefer model when creds; run_memory_dream falls back to heuristic.
	out := run_memory_dream(sess, model, false /* gates */, false, context.temp_allocator)
	if out == "" {
		return ""
	}
	// Success path
	if strings.contains(out, "dream complete") {
		return strings.clone(out, allocator)
	}
	// Verbose: surface skips
	if v := os.get_env("AETHER_VERBOSE", context.temp_allocator); v == "1" || v == "true" {
		return strings.clone(out, allocator)
	}
	return ""
}

// dream_status_text multi-line status for /dream status.
dream_status_text :: proc(cwd: string, allocator := context.allocator) -> string {
	if !tools.memory_enabled() {
		return strings.clone("dream: memory DISABLED (AETHER_NO_MEMORY=1)", allocator)
	}
	if cwd == "" {
		return strings.clone("dream: no cwd", allocator)
	}
	slug := tools.memory_workspace_slug(cwd, context.temp_allocator)
	ws := tools.memory_workspace_dir(cwd, context.temp_allocator)
	stems := tools.memory_list_session_stems(cwd, context.temp_allocator)
	last := tools.dream_last_consolidated_unix(cwd)
	last_s := "never"
	if last > 0 {
		// human-ish: unix seconds
		last_s = fmt.tprintf("unix %d", last)
	}
	// lock held?
	lock_note := "free"
	path := tools.dream_lock_path(cwd, context.temp_allocator)
	if os.exists(path) {
		if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
			pid_str := strings.trim_space(string(data))
			if pid_str != "" {
				lock_note = fmt.tprintf("file present (pid %s)", pid_str)
			} else {
				lock_note = "file present (empty body)"
			}
		}
	}
	auto := "on" if auto_dream_enabled() else "off"
	return fmt.aprintf(
		"dream: enabled\nworkspace: %s\nslug:      %s\nsessions:  %d log file(s)\nlast:      %s\nlock:      %s\nauto-dream: %s (AETHER_NO_AUTO_DREAM=1 to disable)\ngates:     min_hours=%d min_sessions=%d (auto only; /dream bypasses)\nwriters:   /dream → %s/MEMORY.md",
		ws,
		slug,
		len(stems),
		last_s,
		lock_note,
		auto,
		tools.DREAM_MIN_HOURS,
		tools.DREAM_MIN_SESSIONS,
		ws,
		allocator = allocator,
	)
}
