package agent

import "core:fmt"
import "core:strconv"
import "core:strings"

// count_user_turns: number of User-role messages after any leading System messages.
count_user_turns :: proc(msgs: []Chat_Message) -> int {
	n := 0
	for m in msgs {
		if m.role == .User {
			n += 1
		}
	}
	return n
}

// last_assistant_content returns the most recent non-empty assistant text (not owned).
last_assistant_content :: proc(msgs: []Chat_Message) -> string {
	for i := len(msgs) - 1; i >= 0; i -= 1 {
		if msgs[i].role == .Assistant && strings.trim_space(msgs[i].content) != "" {
			return msgs[i].content
		}
	}
	return ""
}

// conversation_rewind_turns removes the last `n` user turns from sess.msgs.
// A user turn = User message + all following non-User messages until the next User.
// Leading System messages are never removed. n < 1 defaults to 1.
// Returns how many user turns were removed.
conversation_rewind_turns :: proc(sess: ^Session, n: int) -> (removed: int, err: string) {
	want := n
	if want < 1 {
		want = 1
	}
	if sess == nil {
		return 0, "no session"
	}
	available := count_user_turns(sess.msgs[:])
	if available == 0 {
		return 0, "nothing to rewind (no user turns)"
	}
	if want > available {
		want = available
	}

	// Drop from the end, one user-turn at a time.
	for t := 0; t < want; t += 1 {
		// Walk back past trailing non-User (assistant/tool) then the User.
		// Never pop System-only prefix.
		if len(sess.msgs) == 0 {
			break
		}
		// Find start index of last user turn
		end := len(sess.msgs)
		// skip trailing non-user non-system from end
		i := end - 1
		for i >= 0 && sess.msgs[i].role != .User {
			if sess.msgs[i].role == .System {
				// Should not strip system; stop
				break
			}
			i -= 1
		}
		if i < 0 || sess.msgs[i].role != .User {
			break
		}
		// drop suffix [i, end) — always a trailing segment
		to_drop := end - i
		for k := 0; k < to_drop; k += 1 {
			m := pop(&sess.msgs)
			destroy_message(&m)
		}
		removed += 1
	}
	if removed == 0 {
		return 0, "nothing to rewind"
	}
	return removed, ""
}

// parse_rewind_count parses "/rewind" args: empty → 1, positive int, or error.
parse_rewind_count :: proc(arg: string) -> (n: int, ok: bool) {
	a := strings.trim_space(arg)
	if a == "" {
		return 1, true
	}
	// strip trailing turn/turns labels
	al := strings.to_lower(a, context.temp_allocator)
	for suf in ([]string{" turns", " turn", "t"}) {
		if strings.has_suffix(al, suf) && len(al) > len(suf) {
			al = strings.trim_space(al[:len(al) - len(suf)])
			break
		}
	}
	v, okp := strconv.parse_int(al, 10)
	if !okp || v < 1 {
		return 0, false
	}
	return v, true
}

// format_rewind_status describes conversation + file stack briefly.
format_conversation_rewind_status :: proc(sess: ^Session, allocator := context.allocator) -> string {
	turns := 0
	if sess != nil {
		turns = count_user_turns(sess.msgs[:])
	}
	msgs := 0
	if sess != nil {
		msgs = len(sess.msgs)
	}
	return fmt.aprintf(
		"conversation: %d user turn(s), %d message(s) — /rewind [N] drops last N turns; /undo-file for file edits",
		turns,
		msgs,
		allocator = allocator,
	)
}
