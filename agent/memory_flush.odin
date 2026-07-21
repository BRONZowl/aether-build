// Package agent — memory flush (/flush) and /memory status (A2.1).
// Grok refs: session/helpers/memory_flush.rs + memory storage write_daily_log.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:strings"
import "aether:tools"

FLUSH_MAX_WRITE_CHARS :: 8000
FLUSH_MAX_TRANSCRIPT_CHARS :: 50_000
FLUSH_MAX_MESSAGES :: 30
FLUSH_PREVIEW_CHARS :: 400

// FLUSH_SYSTEM_PROMPT is the one-shot model instruction (Grok-shaped, abbreviated).
FLUSH_SYSTEM_PROMPT :: "You are a memory assistant. Extract ALL useful information from this conversation " +
	"that would help you be more effective in future sessions with this user. " +
	"Write a concise markdown summary with ## headers covering:\n\n" +
	"- **Decisions & rationale** — what was chosen and why\n" +
	"- **Technical context** — architecture, APIs, patterns, tools, file paths discussed\n" +
	"- **Problems & solutions** — bugs found, how they were fixed, workarounds\n\n" +
	"Omit any section where there is nothing substantive to report. " +
	"Do NOT include user preferences like OS, shell, or editor — these belong in global memory. " +
	"Do NOT include an ephemeral progress section.\n\n" +
	"Respond with NO_REPLY if nothing genuinely useful was learned — a routine task " +
	"that followed standard patterns, brief Q&A, or sessions with no novel decisions " +
	"or discoveries are not worth persisting. Only write content that a future session " +
	"would concretely benefit from."

Flush_Kind :: enum {
	Nothing,
	Accepted,
	Rejected,
}

// is_no_reply matches Grok: strip non-alnum, lower, exact "noreply".
is_no_reply :: proc(text: string) -> bool {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(text) {
		ch := text[i]
		if ch >= 'A' && ch <= 'Z' {
			strings.write_byte(&b, ch + 32)
		} else if (ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9') {
			strings.write_byte(&b, ch)
		}
	}
	return strings.to_string(b) == "noreply"
}

// has_markdown_headers requires "# " or "## " (space after hashes).
has_markdown_headers :: proc(text: string) -> bool {
	return strings.contains(text, "## ") || strings.contains(text, "# ")
}

// process_flush_response applies Grok-shaped quality gates on model output.
process_flush_response :: proc(
	response: string,
	max_chars := FLUSH_MAX_WRITE_CHARS,
	allocator := context.allocator,
) -> (
	kind: Flush_Kind,
	content: string,
	reason: string,
) {
	trimmed := strings.trim_space(response)
	if trimmed == "" {
		return .Nothing, "", strings.clone("empty", allocator)
	}
	if is_no_reply(trimmed) {
		return .Nothing, "", strings.clone("NO_REPLY", allocator)
	}
	body := trimmed
	if len(body) > max_chars {
		body = body[:max_chars]
	}
	if !has_markdown_headers(body) {
		return .Rejected, "", strings.clone(
			"flush response lacks markdown structure (no ## headers)",
			allocator,
		)
	}
	return .Accepted, strings.clone(body, allocator), ""
}

// collect_flush_transcript builds a plain-text transcript of recent turns for the model.
collect_flush_transcript :: proc(
	msgs: []Chat_Message,
	max_msgs := FLUSH_MAX_MESSAGES,
	max_chars := FLUSH_MAX_TRANSCRIPT_CHARS,
	allocator := context.allocator,
) -> string {
	// Collect non-system message indices, then take the last max_msgs.
	nonsys := make([dynamic]int, 0, len(msgs), context.temp_allocator)
	for m, i in msgs {
		if m.role == .System {
			continue
		}
		// Skip empty content unless tool calls present (assistant)
		if strings.trim_space(m.content) == "" && len(m.tool_calls) == 0 {
			continue
		}
		append(&nonsys, i)
	}
	if len(nonsys) == 0 {
		return strings.clone("", allocator)
	}
	from := 0
	if len(nonsys) > max_msgs {
		from = len(nonsys) - max_msgs
	}
	b := strings.builder_make(allocator)
	for j in from ..< len(nonsys) {
		i := nonsys[j]
		m := msgs[i]
		role: string
		switch m.role {
		case .User:
			role = "user"
		case .Assistant:
			role = "assistant"
		case .Tool:
			role = "tool"
		case .System:
			role = "system"
		}
		content := strings.trim_space(m.content)
		if content == "" && len(m.tool_calls) > 0 {
			// Summarize tool calls briefly
			tb := strings.builder_make(context.temp_allocator)
			strings.write_string(&tb, "(tool_calls: ")
			for tc, k in m.tool_calls {
				if k > 0 {
					strings.write_string(&tb, ", ")
				}
				strings.write_string(&tb, tc.name)
			}
			strings.write_byte(&tb, ')')
			content = strings.to_string(tb)
		}
		// Cap individual message
		if len(content) > 4000 {
			content = content[:4000]
		}
		block := fmt.tprintf("### %s\n%s\n\n", role, content)
		if strings.builder_len(b) + len(block) > max_chars {
			break
		}
		strings.write_string(&b, block)
	}
	return strings.to_string(b)
}

// flush_heuristic_markdown builds a structured offline summary (Mode B).
flush_heuristic_markdown :: proc(
	msgs: []Chat_Message,
	allocator := context.allocator,
) -> string {
	transcript := collect_flush_transcript(msgs, FLUSH_MAX_MESSAGES, FLUSH_MAX_TRANSCRIPT_CHARS, context.temp_allocator)
	if strings.trim_space(transcript) == "" {
		return strings.clone("", allocator)
	}
	// Ensure ## headers for structure (same bar as model path quality gate).
	return fmt.aprintf(
		"## Session notes (heuristic flush)\n\n### Technical context\n\n%s",
		transcript,
		allocator = allocator,
	)
}

// run_memory_flush extracts notes from sess.msgs and appends to the daily session log.
// Prefer model (Mode A) when credentials resolve; else heuristic (Mode B).
// force_heuristic skips the API (tests / offline).
run_memory_flush :: proc(
	sess: ^Session,
	model: string,
	force_heuristic := false,
	allocator := context.allocator,
) -> string {
	if !tools.memory_enabled() {
		return strings.clone("aether: memory is disabled (AETHER_NO_MEMORY=1)", allocator)
	}
	if sess == nil {
		return strings.clone("aether: no session", allocator)
	}

	content := ""
	mode := "heuristic"

	// Mode A: model extract when creds available
	if !force_heuristic {
		creds, cerr := resolve_credentials(context.temp_allocator)
		if cerr == "" {
			transcript := collect_flush_transcript(
				sess.msgs[:],
				FLUSH_MAX_MESSAGES,
				FLUSH_MAX_TRANSCRIPT_CHARS,
				context.temp_allocator,
			)
			if strings.trim_space(transcript) != "" {
				req := make([dynamic]Chat_Message, 0, 2, context.temp_allocator)
				append(
					&req,
					Chat_Message {
						role    = .System,
						content = strings.clone(FLUSH_SYSTEM_PROMPT, context.temp_allocator),
					},
				)
				append(
					&req,
					Chat_Message {
						role    = .User,
						content = strings.clone(transcript, context.temp_allocator),
					},
				)
				m := model
				if m == "" {
					m = sess.model
				}
				turn, err := chat_completion(creds, m, req[:], "" /* no tools */)
				if err == "" {
					kind, body, reason := process_flush_response(turn.content, FLUSH_MAX_WRITE_CHARS, context.temp_allocator)
					destroy_assistant_turn(&turn)
					switch kind {
					case .Nothing:
						return fmt.aprintf(
							"aether: nothing to persist (%s)",
							reason if reason != "" else "NO_REPLY",
							allocator = allocator,
						)
					case .Rejected:
						// fall through to heuristic
						_ = reason
					case .Accepted:
						content = body
						mode = "model"
					}
				}
				// on API error, fall through to heuristic
			}
		}
	}

	if content == "" {
		content = flush_heuristic_markdown(sess.msgs[:], context.temp_allocator)
		mode = "heuristic"
	}
	if strings.trim_space(content) == "" {
		return strings.clone(
			"aether: nothing to persist (no user/assistant content in session)",
			allocator,
		)
	}

	path, werr := tools.memory_append_session_log(sess.cwd, content, context.temp_allocator)
	if werr != "" {
		return fmt.aprintf("aether: flush write failed: %s", werr, allocator = allocator)
	}

	preview := strings.trim_space(content)
	if len(preview) > FLUSH_PREVIEW_CHARS {
		preview = fmt.tprintf("%s…", preview[:FLUSH_PREVIEW_CHARS])
	}
	return fmt.aprintf(
		"aether: flushed (%s) → %s\n\n%s",
		mode,
		path,
		preview,
		allocator = allocator,
	)
}

// handle_memory_slash implements /memory [status|path|on|off|help].
// When sess is non-nil, status includes inject latch + auto-dream flag.
handle_memory_slash :: proc(
	arg: string,
	cwd: string,
	allocator := context.allocator,
	sess: ^Session = nil,
) -> string {
	a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
	if a == "on" || a == "enable" || a == "true" || a == "1" || a == "yes" {
		ok := tools.memory_set_process_enabled(true)
		if ok {
			return strings.clone(
				"aether: memory = on (process; overrides config [memory] enabled=false; AETHER_NO_MEMORY still wins)",
				allocator,
			)
		}
		return strings.clone(
			"aether: memory still DISABLED (AETHER_NO_MEMORY is set; unset it to re-enable)",
			allocator,
		)
	}
	if a == "off" || a == "disable" || a == "false" || a == "0" || a == "no" {
		_ = tools.memory_set_process_enabled(false)
		return strings.clone("aether: memory = off (process; /memory on to re-enable)", allocator)
	}
	if a == "" || a == "status" || a == "show" || a == "info" {
		base := tools.memory_status_text(cwd, context.temp_allocator)
		inject := "pending"
		if sess != nil && sess.memory_injected {
			inject = "done"
		} else if sess != nil && conversation_has_memory_context(sess.msgs[:]) {
			inject = "done"
		}
		if !memory_inject_enabled() {
			inject = "disabled"
		}
		auto := "on" if auto_dream_enabled() else "off"
		return fmt.aprintf(
			"%s\ninject:  %s (first-turn; AETHER_NO_MEMORY_INJECT=1)\nauto-dream: %s",
			base,
			inject,
			auto,
			allocator = allocator,
		)
	}
	if a == "path" || a == "root" || a == "dir" {
		root := tools.memory_root(context.temp_allocator)
		return fmt.aprintf("%s", root, allocator = allocator)
	}
	if a == "help" || a == "?" {
		return strings.clone(
			"Usage: /memory [status|path|on|off|help]\n" +
			"  status  enabled?, root, workspace slug, markdown file count\n" +
			"  path    print memory root absolute path\n" +
			"  on|off  process-local toggle (Grok-shaped; not persisted)\n" +
			"  help    this text\n" +
			"Writers: /flush  /dream  /remember  Opt-out: AETHER_NO_MEMORY=1",
			allocator,
		)
	}
	return fmt.aprintf(
		"aether: unknown /memory arg %q (try /memory help)",
		arg,
		allocator = allocator,
	)
}

REMEMBER_MAX_NOTE :: 4000
REMEMBER_PREVIEW :: 120

// handle_remember_slash: /remember <note> appends to today's session log (B32 / Grok-shaped).
// No model rewrite modal — raw note with ## User note header.
handle_remember_slash :: proc(
	cwd: string,
	arg: string,
	allocator := context.allocator,
) -> string {
	note := strings.trim_space(arg)
	if note == "" || note == "help" || note == "?" {
		return strings.clone(
			"Usage: /remember <note>\n" +
			"Append a user note to today's memory session log (no model call).\n" +
			"Opt-out: AETHER_NO_MEMORY=1",
			allocator,
		)
	}
	body_note := note
	if len(body_note) > REMEMBER_MAX_NOTE {
		body_note = body_note[:REMEMBER_MAX_NOTE]
	}
	body := fmt.tprintf("## User note\n\n%s\n", body_note)
	path, err := tools.memory_append_session_log(cwd, body, context.temp_allocator)
	if err != "" {
		return fmt.aprintf("aether: remember failed: %s", err, allocator = allocator)
	}
	preview := body_note
	if len(preview) > REMEMBER_PREVIEW {
		preview = fmt.tprintf("%s…", preview[:REMEMBER_PREVIEW])
	}
	return fmt.aprintf("aether: remembered → %s\n%s", path, preview, allocator = allocator)
}

// handle_flush_slash implements /flush (optional: heuristic to force offline).
handle_flush_slash :: proc(
	sess: ^Session,
	model: string,
	arg: string,
	allocator := context.allocator,
) -> string {
	a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
	if a == "help" || a == "?" {
		return strings.clone(
			"Usage: /flush [heuristic]\n" +
			"Persist useful notes from this session into the daily memory log\n" +
			"({memory_root}/{slug}/sessions/YYYY-MM-DD.md).\n" +
			"Uses the model when credentials are available; otherwise offline heuristic.\n" +
			"Pass 'heuristic' to skip the API. Opt-out: AETHER_NO_MEMORY=1",
			allocator,
		)
	}
	force := a == "heuristic" || a == "offline" || a == "local"
	return run_memory_flush(sess, model, force, allocator)
}
