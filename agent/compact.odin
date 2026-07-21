// Package agent — /compact history summarization + auto-compact (B1.1–2).
// Grok refs: helpers/session_compact.rs (manual + threshold path, abbreviated).

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "aether:core"
import "aether:hooks"
import "aether:tools"

COMPACT_MAX_TRANSCRIPT_CHARS :: 80_000
COMPACT_MAX_SUMMARY_CHARS :: 12_000
COMPACT_MAX_MSGS :: 80
AUTO_COMPACT_DEFAULT_PCT :: 80
AUTO_COMPACT_MIN_NON_SYSTEM :: 6

// COMPACT_SUMMARIZATION_PROMPT short Grok-shaped summary request (no tools).
COMPACT_SUMMARIZATION_PROMPT :: "Please summarize the conversation so far. This summary will be " +
	"provided to another AI assistant to continue working on the task. The other assistant will " +
	"only see the user's original goals and your summary — not tool calls or raw tool outputs. " +
	"Compress context while preserving: user requests, work done, file paths and code details, " +
	"errors and fixes, and what remains. Prefer tight prose. " +
	"Output a single markdown summary with ## headers. DO NOT call any tools."

// build_compact_user_prompt optional focus notes.
build_compact_user_prompt :: proc(user_context: string, allocator := context.allocator) -> string {
	base := COMPACT_SUMMARIZATION_PROMPT
	ctx := strings.trim_space(user_context)
	if ctx == "" {
		return strings.clone(base, allocator)
	}
	return fmt.aprintf(
		"%s\n\n<user_provided_context>\n%s\n</user_provided_context>\n\n" +
		"Incorporate the user-provided context above into your summary.",
		base,
		ctx,
		allocator = allocator,
	)
}

// extract_summary_block prefers <summary>...</summary> content.
extract_summary_block :: proc(text: string, allocator := context.allocator) -> string {
	t := strings.trim_space(text)
	if t == "" {
		return strings.clone("", allocator)
	}
	// case-insensitive search for tags
	lower := strings.to_lower(t, context.temp_allocator)
	start_tag := "<summary>"
	end_tag := "</summary>"
	si := strings.index(lower, start_tag)
	if si < 0 {
		return strings.clone(t, allocator)
	}
	content_start := si + len(start_tag)
	ei := strings.index(lower[content_start:], end_tag)
	if ei < 0 {
		return strings.clone(strings.trim_space(t[content_start:]), allocator)
	}
	return strings.clone(strings.trim_space(t[content_start:content_start + ei]), allocator)
}

// collect_compact_transcript builds plain text from recent non-system messages.
collect_compact_transcript :: proc(
	msgs: []Chat_Message,
	max_msgs := COMPACT_MAX_MSGS,
	max_chars := COMPACT_MAX_TRANSCRIPT_CHARS,
	allocator := context.allocator,
) -> string {
	idxs := make([dynamic]int, 0, len(msgs), context.temp_allocator)
	for m, i in msgs {
		if m.role == .System {
			continue
		}
		append(&idxs, i)
	}
	if len(idxs) == 0 {
		return strings.clone("", allocator)
	}
	from := 0
	if len(idxs) > max_msgs {
		from = len(idxs) - max_msgs
	}
	b := strings.builder_make(allocator)
	for j in from ..< len(idxs) {
		m := msgs[idxs[j]]
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
			tb := strings.builder_make(context.temp_allocator)
			strings.write_string(&tb, "(tools: ")
			for tc, k in m.tool_calls {
				if k > 0 {
					strings.write_string(&tb, ", ")
				}
				strings.write_string(&tb, tc.name)
			}
			strings.write_byte(&tb, ')')
			content = strings.to_string(tb)
		}
		if len(content) > 6000 {
			content = content[:6000]
		}
		block := fmt.tprintf("### %s\n%s\n\n", role, content)
		if strings.builder_len(b) + len(block) > max_chars {
			break
		}
		strings.write_string(&b, block)
	}
	return strings.to_string(b)
}

// compact_heuristic_summary offline Mode B.
compact_heuristic_summary :: proc(
	msgs: []Chat_Message,
	allocator := context.allocator,
) -> string {
	// Collect last few user + assistant texts
	b := strings.builder_make(allocator)
	strings.write_string(&b, "## Compacted summary (heuristic)\n\n")
	strings.write_string(&b, "### Recent conversation\n\n")
	n_user := 0
	n_asst := 0
	// walk from end
	for i := len(msgs) - 1; i >= 0; i -= 1 {
		m := msgs[i]
		if m.role == .User {
			if n_user >= 6 {
				continue
			}
			c := strings.trim_space(m.content)
			if c == "" {
				continue
			}
			if len(c) > 1500 {
				c = c[:1500]
			}
			// prepend by building reverse... collect later
			n_user += 1
		} else if m.role == .Assistant {
			if n_asst >= 6 {
				continue
			}
			c := strings.trim_space(m.content)
			if c == "" {
				continue
			}
			n_asst += 1
		}
	}
	// Forward pass last messages
	start := 0
	if len(msgs) > 20 {
		start = len(msgs) - 20
	}
	for i in start ..< len(msgs) {
		m := msgs[i]
		if m.role != .User && m.role != .Assistant {
			continue
		}
		c := strings.trim_space(m.content)
		if c == "" {
			continue
		}
		if len(c) > 1200 {
			c = c[:1200]
		}
		label := "User" if m.role == .User else "Assistant"
		strings.write_string(&b, fmt.tprintf("**%s:** %s\n\n", label, c))
	}
	out := strings.to_string(b)
	// Header-only → empty
	if !strings.contains(out, "**User:**") && !strings.contains(out, "**Assistant:**") {
		delete(out)
		return strings.clone("", allocator)
	}
	return out
}

// count_non_system counts messages that are not system.
count_non_system :: proc(msgs: []Chat_Message) -> int {
	n := 0
	for m in msgs {
		if m.role != .System {
			n += 1
		}
	}
	return n
}

// apply_compact_history replaces sess.msgs with system + compact preamble + summary.
// Keeps a clone of the first system message when present; else rebuilds prompt.
apply_compact_history :: proc(
	sess: ^Session,
	summary: string,
	perm: core.Permission_Mode,
) {
	sum := strings.trim_space(summary)
	if sum == "" {
		return
	}
	if len(sum) > COMPACT_MAX_SUMMARY_CHARS {
		sum = sum[:COMPACT_MAX_SUMMARY_CHARS]
	}

	// Preserve system content
	sys_content: string
	if len(sess.msgs) > 0 && sess.msgs[0].role == .System {
		raw := sess.msgs[0].content
		// Strip prior memory inject block so re-inject can run cleanly
		if idx := strings.index(raw, MEMORY_INJECT_MARKER); idx >= 0 {
			sys_content = strings.clone(strings.trim_right_space(raw[:idx]))
		} else {
			sys_content = strings.clone(raw)
		}
	} else {
		catalog := skills_catalog_text(context.temp_allocator)
		sys_content = build_system_prompt(sess.cwd, perm, context.allocator, catalog)
	}

	// Destroy all messages
	for len(sess.msgs) > 0 {
		last, _ := pop_safe(&sess.msgs)
		destroy_message(&last)
	}

	append(
		&sess.msgs,
		Chat_Message{role = .System, content = sys_content},
	)
	append(
		&sess.msgs,
		Chat_Message {
			role    = .User,
			content = strings.clone(
				"This session was compacted. Continue from the summary below. " +
				"Do not assume tool outputs from before the compact are still available; re-read files if needed.",
			),
		},
	)
	append(
		&sess.msgs,
		Chat_Message {
			role    = .Assistant,
			content = strings.clone(sum),
		},
	)

	// Allow first-turn memory re-inject after compact
	sess.memory_injected = false
}

// run_session_compact performs Mode A/B compact on sess.
// force_heuristic skips model. user_context is focus notes (not "heuristic").
run_session_compact :: proc(
	sess: ^Session,
	model: string,
	user_context: string,
	force_heuristic: bool,
	perm: core.Permission_Mode,
	allocator := context.allocator,
) -> string {
	if sess == nil {
		return strings.clone("aether: no session", allocator)
	}
	n_before := len(sess.msgs)
	if count_non_system(sess.msgs[:]) == 0 {
		return strings.clone("aether: nothing to compact (only system / empty history)", allocator)
	}

	chars_before := estimate_message_chars(sess.msgs[:])
	toks_before := estimate_tokens(chars_before)

	// Best-effort memory flush when memory on and enough user turns
	_, u, _, _ := count_roles(sess.msgs[:])
	if tools.memory_enabled() && u >= 2 {
		_ = run_memory_flush(sess, model, force_heuristic, context.temp_allocator)
	}

	summary := ""
	mode := "heuristic"

	if !force_heuristic {
		creds, cerr := resolve_credentials(context.temp_allocator)
		if cerr == "" {
			transcript := collect_compact_transcript(sess.msgs[:], COMPACT_MAX_MSGS, COMPACT_MAX_TRANSCRIPT_CHARS, context.temp_allocator)
			if strings.trim_space(transcript) != "" {
				prompt := build_compact_user_prompt(user_context, context.temp_allocator)
				req := make([dynamic]Chat_Message, 0, 3, context.temp_allocator)
				append(
					&req,
					Chat_Message {
						role    = .System,
						content = strings.clone(
							"You are a conversation compressor. Output only the summary markdown. No tools.",
							context.temp_allocator,
						),
					},
				)
				append(
					&req,
					Chat_Message {
						role    = .User,
						content = strings.clone(
							fmt.tprintf("%s\n\n--- Conversation ---\n\n%s", prompt, transcript),
							context.temp_allocator,
						),
					},
				)
				m := model
				if m == "" {
					m = sess.model
				}
				turn, err := chat_completion(creds, m, req[:], "")
				if err == "" {
					extracted := extract_summary_block(turn.content, context.temp_allocator)
					destroy_assistant_turn(&turn)
					if strings.trim_space(extracted) != "" {
						summary = extracted
						mode = "model"
					}
				}
			}
		}
	}

	if summary == "" {
		summary = compact_heuristic_summary(sess.msgs[:], context.temp_allocator)
		mode = "heuristic"
	}
	if strings.trim_space(summary) == "" {
		hooks.run_post_compact_hooks(sess.cwd, mode, n_before, n_before, false)
		return strings.clone("aether: compact produced empty summary", allocator)
	}

	hooks.run_pre_compact_hooks(sess.cwd, mode, n_before)
	apply_compact_history(sess, summary, perm)
	n_after := len(sess.msgs)
	hooks.run_post_compact_hooks(sess.cwd, mode, n_before, n_after, true)

	chars_after := estimate_message_chars(sess.msgs[:])
	toks_after := estimate_tokens(chars_after)

	if sess.auto_save {
		_ = session_save(sess)
	}

	return fmt.aprintf(
		"aether: compacted (%s) %d → %d messages\nbefore: ~%d tokens (%d chars)\nafter:  ~%d tokens (%d chars)\nsummary preview:\n%s",
		mode,
		n_before,
		n_after,
		toks_before,
		chars_before,
		toks_after,
		chars_after,
		truncate_preview(summary, 400, context.temp_allocator),
		allocator = allocator,
	)
}

truncate_preview :: proc(s: string, max: int, allocator := context.allocator) -> string {
	t := strings.trim_space(s)
	if len(t) <= max {
		return strings.clone(t, allocator)
	}
	return fmt.aprintf("%s…", t[:max], allocator = allocator)
}

// auto_compact_enabled: not AETHER_NO_AUTO_COMPACT, config auto_compact, and threshold > 0.
auto_compact_enabled :: proc() -> bool {
	if v := os.get_env("AETHER_NO_AUTO_COMPACT", context.temp_allocator); v == "1" ||
	   v == "true" ||
	   v == "yes" ||
	   v == "on" {
		return false
	}
	if !core.flag_auto_compact() {
		return false
	}
	return auto_compact_threshold_pct() > 0
}

// auto_compact_threshold_pct: env AETHER_AUTO_COMPACT_PCT wins, else config, else 80.
// Set to 0 to disable via threshold without NO_AUTO_COMPACT.
auto_compact_threshold_pct :: proc() -> int {
	if v := os.get_env("AETHER_AUTO_COMPACT_PCT", context.temp_allocator); v != "" {
		if n, ok := strconv.parse_int(v); ok {
			if n < 0 {
				return 0
			}
			if n > 100 {
				return 100
			}
			return n
		}
	}
	return core.flag_auto_compact_pct()
}

// should_auto_compact reports whether msgs exceed the usage threshold.
should_auto_compact :: proc(msgs: []Chat_Message) -> bool {
	if !auto_compact_enabled() {
		return false
	}
	if count_non_system(msgs) < AUTO_COMPACT_MIN_NON_SYSTEM {
		return false
	}
	window := default_context_window()
	if window <= 0 {
		return false
	}
	toks := estimate_tokens(estimate_message_chars(msgs))
	pct := context_usage_pct(toks, window)
	return pct >= auto_compact_threshold_pct()
}

// maybe_auto_compact runs heuristic compact once when over threshold.
// Returns user-visible notice or "".
// Prefer sess when available (flush + memory latch); else compact msgs only via temporary Session shell.
maybe_auto_compact :: proc(
	sess: ^Session,
	msgs: ^[dynamic]Chat_Message,
	model: string,
	perm: core.Permission_Mode,
	allocator := context.allocator,
) -> string {
	if sess != nil {
		if !should_auto_compact(sess.msgs[:]) {
			return ""
		}
		// Always heuristic for auto (fast/offline-safe)
		out := run_session_compact(sess, model, "", true, perm, context.temp_allocator)
		if strings.contains(out, "compacted") {
			return fmt.aprintf("aether: auto-compact — %s", out, allocator = allocator)
		}
		return ""
	}
	if msgs == nil || !should_auto_compact(msgs[:]) {
		return ""
	}
	// Build a transient session wrapper so apply path works
	tmp := Session {
		msgs  = msgs^,
		model = model,
		cwd   = "",
	}
	out := run_session_compact(&tmp, model, "", true, perm, context.temp_allocator)
	// Write back dynamic array (msgs is the same storage if we used msgs^ carefully)
	// run_session_compact mutates tmp.msgs which may reallocate — copy pointer back
	msgs^ = tmp.msgs
	if strings.contains(out, "compacted") {
		return fmt.aprintf("aether: auto-compact — %s", out, allocator = allocator)
	}
	return ""
}

// handle_compact_slash implements /compact [heuristic|status|help|focus text].
handle_compact_slash :: proc(
	sess: ^Session,
	model: string,
	arg: string,
	perm: core.Permission_Mode,
	allocator := context.allocator,
) -> string {
	a := strings.trim_space(arg)
	al := strings.to_lower(a, context.temp_allocator)
	if al == "help" || al == "?" {
		return strings.clone(
			"Usage: /compact [heuristic|status|focus notes…]\n" +
			"Compress conversation history into a short summary so the next turns use less context.\n" +
			"  (empty)     model when credentials available, else offline heuristic\n" +
			"  heuristic   force offline summary\n" +
			"  status      auto-compact threshold / enable flags\n" +
			"  <text>      focus notes for the model (what to preserve)\n" +
			"Auto: when usage ≥ AETHER_AUTO_COMPACT_PCT (default 80); off: AETHER_NO_AUTO_COMPACT=1 or PCT=0\n" +
			"Best-effort /flush runs first when memory is enabled.",
			allocator,
		)
	}
	if al == "status" {
		en := auto_compact_enabled()
		return fmt.aprintf(
			"auto-compact: %s\nthreshold:    %d%% of window\nwindow:       %d tokens (est.)\nmin msgs:     %d non-system\nopt-out:      AETHER_NO_AUTO_COMPACT=1  AETHER_AUTO_COMPACT_PCT=0\nauto mode:    heuristic only (manual /compact may use model)",
			"enabled" if en else "disabled",
			auto_compact_threshold_pct(),
			default_context_window(),
			AUTO_COMPACT_MIN_NON_SYSTEM,
			allocator = allocator,
		)
	}
	force_h := al == "heuristic" || al == "offline" || al == "local"
	focus := a
	if force_h {
		focus = ""
	}
	return run_session_compact(sess, model, focus, force_h, perm, allocator)
}
