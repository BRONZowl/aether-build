#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
import "aether:agent"
import "aether:core"

// Prompt history, input helpers, copy selected block.

history_up :: proc(s: ^App_State) -> bool {
	if len(s.prompt_history) == 0 {
		return false
	}
	if s.history_idx < 0 {
		s.history_idx = len(s.prompt_history) - 1
	} else if s.history_idx > 0 {
		s.history_idx -= 1
	} else {
		return true // already at oldest
	}
	input_set_text(s, s.prompt_history[s.history_idx])
	return true
}



history_down :: proc(s: ^App_State) -> bool {
	if s.history_idx < 0 {
		return false
	}
	if s.history_idx + 1 >= len(s.prompt_history) {
		// past newest → clear and leave history mode
		s.history_idx = -1
		input_clear(s)
		return true
	}
	s.history_idx += 1
	input_set_text(s, s.prompt_history[s.history_idx])
	return true
}

input_set_text :: proc(s: ^App_State, text: string) {
	clear(&s.input)
	for i in 0 ..< len(text) {
		append(&s.input, text[i])
	}
	s.cursor = len(s.input)
}

// seed_prompt_history: global durable history (B23) then this session's user turns.
// Oldest-first so Up from empty walks newest last entries first.
seed_prompt_history :: proc(s: ^App_State, msgs: []agent.Chat_Message) {
	for h in s.prompt_history {
		delete(h)
	}
	clear(&s.prompt_history)
	s.history_idx = -1
	// 1) global file (oldest → newest)
	global := core.load_prompt_history(context.allocator)
	defer core.destroy_prompt_history_list(global)
	for g in global {
		append(&s.prompt_history, strings.clone(g))
	}
	// 2) session user prompts (append; skip consecutive dups of last)
	for m in msgs {
		if m.role == .User && m.content != "" {
			if len(s.prompt_history) > 0 &&
			   s.prompt_history[len(s.prompt_history) - 1] == m.content {
				continue
			}
			append(&s.prompt_history, strings.clone(m.content))
		}
	}
	// cap
	for len(s.prompt_history) > core.PROMPT_HISTORY_MAX {
		delete(s.prompt_history[0])
		ordered_remove(&s.prompt_history, 0)
	}
}

input_apply_backslash_continuation :: proc(s: ^App_State) -> bool {
	text := input_text(s)
	end := len(text)
	for end > 0 && (text[end - 1] == ' ' || text[end - 1] == '\t') {
		end -= 1
	}
	if end == 0 || text[end - 1] != '\\' {
		return false
	}
	s.cursor = len(s.input)
	for len(s.input) > end - 1 {
		input_backspace(s)
	}
	input_insert_byte(s, '\n')
	return true
}

// copy_selected_block: y = full text; Y = tool metadata when possible.
copy_selected_block :: proc(st: ^App_State, meta: bool) -> string {
	i := st.selected_block
	if i < 0 || i >= len(st.blocks) {
		return "nothing selected"
	}
	b := st.blocks[i]
	text: string
	if meta && b.kind == .Tool {
		// tool name + first line of body (args preview)
		first := b.text
		if nl := strings.index_byte(first, '\n'); nl >= 0 {
			first = first[:nl]
		}
		name := b.tool_name if b.tool_name != "" else "tool"
		text = fmt.tprintf("%s\n%s", name, first)
	} else {
		text = b.text
	}
	if text == "" {
		return "empty block"
	}
	return copy_to_clipboard(text)
}

