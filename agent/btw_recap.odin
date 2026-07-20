// Package agent — /btw side agent + /recap model summary (Wave 4).
// Side turns do not append to the main session transcript.
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
package agent

import "core:fmt"
import "core:strings"
import "aether:core"

BTW_MAX_CONTEXT_CHARS :: 6_000
BTW_MAX_MSGS :: 12
RECAP_MAX_TRANSCRIPT_CHARS :: 24_000
RECAP_MAX_MSGS :: 40

// collect_side_context: recent user/assistant text for side questions (temp-friendly).
collect_side_context :: proc(
	msgs: []Chat_Message,
	max_msgs: int,
	max_chars: int,
	allocator := context.allocator,
) -> string {
	if len(msgs) == 0 {
		return strings.clone("", allocator)
	}
	start := 0
	count := 0
	for i := len(msgs) - 1; i >= 0 && count < max_msgs; i -= 1 {
		m := msgs[i]
		if m.role == .User || m.role == .Assistant {
			if strings.trim_space(m.content) != "" {
				count += 1
				start = i
			}
		}
	}
	b := strings.builder_make(allocator)
	chars := 0
	for i in start ..< len(msgs) {
		m := msgs[i]
		if m.role != .User && m.role != .Assistant {
			continue
		}
		role := "user" if m.role == .User else "assistant"
		t := strings.trim_space(m.content)
		if t == "" {
			continue
		}
		if len(t) > 800 {
			t = fmt.tprintf("%s…", t[:797])
		}
		line := fmt.tprintf("[%s] %s\n", role, t)
		if chars + len(line) > max_chars {
			strings.write_string(&b, "…[context truncated]\n")
			break
		}
		strings.write_string(&b, line)
		chars += len(line)
	}
	return strings.to_string(b)
}

// handle_btw_slash: brief model answer off-transcript (falls back to local note).
handle_btw_slash :: proc(
	sess: ^Session,
	model: string,
	arg: string,
	allocator := context.allocator,
) -> string {
	q := strings.trim_space(arg)
	if q == "" {
		return strings.clone(
			"aether: usage: /btw <question>\n" +
			"  Asks a side question without adding to the main session transcript.\n" +
			"  Uses a short context window of recent turns.",
			allocator,
		)
	}
	m := model
	if m == "" && sess != nil {
		m = sess.model
	}
	if m == "" {
		m = "grok-4.5"
	}

	creds, cerr := resolve_credentials(context.temp_allocator)
	if cerr != "" {
		return strings.clone(
			fmt.tprintf(
				"btw: (local note — not signed in: %s)\n  %s\n  Sign in with /login or XAI_API_KEY for a model answer.",
				cerr,
				q,
			),
			allocator,
		)
	}

	ctx := ""
	if sess != nil {
		ctx = collect_side_context(sess.msgs[:], BTW_MAX_MSGS, BTW_MAX_CONTEXT_CHARS, context.temp_allocator)
	}

	req := make([dynamic]Chat_Message, 0, 3, context.temp_allocator)
	append(
		&req,
		Chat_Message {
			role    = .System,
			content = strings.clone(
				"You answer a brief side question (\"btw\") while the user works on another task.\n" +
				"Rules: be concise (a few short paragraphs max). Do not call tools. " +
				"Do not invent file contents you have not seen. If context is insufficient, say so.",
				context.temp_allocator,
			),
		},
	)
	user_body: string
	if strings.trim_space(ctx) != "" {
		user_body = fmt.tprintf(
			"Recent session context (may be incomplete):\n%s\n\nSide question (btw):\n%s",
			ctx,
			q,
		)
	} else {
		user_body = fmt.tprintf("Side question (btw):\n%s", q)
	}
	append(
		&req,
		Chat_Message {
			role    = .User,
			content = strings.clone(user_body, context.temp_allocator),
		},
	)

	turn, err := chat_completion(creds, m, req[:], "")
	if err != "" {
		return strings.clone(
			fmt.tprintf("btw: (model error: %s)\n  local note: %s", err, q),
			allocator,
		)
	}
	answer := strings.trim_space(turn.content)
	destroy_assistant_turn(&turn)
	if answer == "" {
		return strings.clone(fmt.tprintf("btw: (empty model reply)\n  %s", q), allocator)
	}
	// Cap very long answers for notice sinks
	if len(answer) > 4000 {
		answer = fmt.tprintf("%s\n…[truncated]", answer[:4000])
	}
	return strings.clone(fmt.tprintf("btw:\n%s", answer), allocator)
}

// handle_recap_slash: model “where was I” with local fallback.
handle_recap_slash :: proc(
	sess: ^Session,
	model: string,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "## recap\n")
	if sess == nil || len(sess.msgs) == 0 {
		strings.write_string(&b, "(empty session)\n")
		return strings.to_string(b)
	}
	fmt.sbprintf(
		&b,
		"session %s  title=%q  model=%s  messages=%d\n\n",
		sess.id,
		sess.title if sess.title != "" else "(none)",
		sess.model if sess.model != "" else model,
		len(sess.msgs),
	)

	m := model
	if m == "" {
		m = sess.model
	}
	if m == "" {
		m = "grok-4.5"
	}

	// Prefer model summary (not written into session history)
	creds, cerr := resolve_credentials(context.temp_allocator)
	if cerr == "" {
		transcript := collect_side_context(
			sess.msgs[:],
			RECAP_MAX_MSGS,
			RECAP_MAX_TRANSCRIPT_CHARS,
			context.temp_allocator,
		)
		if strings.trim_space(transcript) != "" {
			req := make([dynamic]Chat_Message, 0, 3, context.temp_allocator)
			append(
				&req,
				Chat_Message {
					role    = .System,
					content = strings.clone(
						"You write a short \"where was I\" recap for a coding agent session.\n" +
						"Cover: goal, progress, key files/decisions, blockers, next steps.\n" +
						"Use tight markdown bullets. No tools. Do not invent facts not in the transcript.",
						context.temp_allocator,
					),
				},
			)
			append(
				&req,
				Chat_Message {
					role    = .User,
					content = strings.clone(
						fmt.tprintf("Summarize this session so far:\n\n%s", transcript),
						context.temp_allocator,
					),
				},
			)
			turn, err := chat_completion(creds, m, req[:], "")
			if err == "" {
				ans := strings.trim_space(turn.content)
				destroy_assistant_turn(&turn)
				if ans != "" {
					if len(ans) > 6000 {
						ans = fmt.tprintf("%s\n…[truncated]", ans[:6000])
					}
					strings.write_string(&b, ans)
					strings.write_string(&b, "\n")
					return strings.to_string(b)
				}
			} else {
				fmt.sbprintf(&b, "(model recap failed: %s — local fallback)\n\n", err)
			}
		}
	} else {
		fmt.sbprintf(&b, "(not signed in — local fallback; %s)\n\n", cerr)
	}

	// Local fallback: recent turns
	roles := make([dynamic]string, 0, 6, context.temp_allocator)
	texts := make([dynamic]string, 0, 6, context.temp_allocator)
	for i := len(sess.msgs) - 1; i >= 0 && len(roles) < 6; i -= 1 {
		m2 := sess.msgs[i]
		role := ""
		switch m2.role {
		case .User:
			role = "user"
		case .Assistant:
			role = "assistant"
		case .System, .Tool:
			continue
		}
		t := strings.trim_space(m2.content)
		if t == "" {
			continue
		}
		if len(t) > 200 {
			t = fmt.tprintf("%s…", t[:197])
		}
		t, _ = strings.replace_all(t, "\n", " ", context.temp_allocator)
		append(&roles, role)
		append(&texts, t)
	}
	if len(roles) == 0 {
		strings.write_string(&b, "(no user/assistant turns yet)\n")
		return strings.to_string(b)
	}
	strings.write_string(&b, "Recent turns (newest first):\n")
	for i in 0 ..< len(roles) {
		fmt.sbprintf(&b, "  [%s] %s\n", roles[i], texts[i])
	}
	return strings.to_string(b)
}
