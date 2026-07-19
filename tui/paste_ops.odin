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
import "aether:tools"

// apply_middle_paste: PRIMARY/clipboard text + image path/clipboard image → prompt (C2.5 / M1).
apply_middle_paste :: proc(st: ^App_State) -> bool {
	return apply_paste(st, false)
}

// apply_bracketed_paste: terminal ESC[200~…201~ payload (C2.6).
// Focuses prompt; rewrites image paths to [Image #N]; bulk-inserts (no per-char Esc).
apply_bracketed_paste :: proc(st: ^App_State, raw: string) -> bool {
	if st.focus != .Prompt {
		focus_prompt(st)
	}
	if raw == "" {
		return false
	}
	rewritten, n_att := agent.process_paste_for_images(raw, context.temp_allocator)
	insert := rewritten if rewritten != "" else raw
	if input_insert_text(st, insert) {
		st.history_idx = -1
		if n_att > 0 {
			state_set_status(st, fmt.tprintf("pasted %d image(s)", n_att))
		} else {
			// short status: rune count approx
			n := 0
			for _ in insert {
				n += 1
				if n > 9999 {
					break
				}
			}
			state_set_status(st, fmt.tprintf("pasted %d chars", n))
		}
		return true
	}
	return false
}

// try_paste_clipboard_image attaches binary clipboard image as [Image #N].
try_paste_clipboard_image :: proc(st: ^App_State) -> bool {
	data, ok := paste_clipboard_image_bytes(context.temp_allocator)
	if !ok {
		return false
	}
	label, aok := agent.save_clipboard_image_bytes(data, context.temp_allocator)
	if !aok {
		return false
	}
	if input_insert_text(st, fmt.tprintf("%s ", label)) {
		st.history_idx = -1
		state_set_status(st, "pasted image")
		return true
	}
	return false
}

// apply_paste: multimodal-aware paste (M1).
// prefer_image=true (Ctrl+V): try clipboard image bytes first, then text.
// prefer_image=false (middle): text first (PRIMARY), then clipboard image if empty.
apply_paste :: proc(st: ^App_State, prefer_image: bool) -> bool {
	if st.focus != .Prompt {
		focus_prompt(st)
	}
	if prefer_image {
		if try_paste_clipboard_image(st) {
			return true
		}
	}
	text, ok := paste_from_primary(context.temp_allocator)
	if ok && text != "" {
		rewritten, n_att := agent.process_paste_for_images(text, context.temp_allocator)
		insert := rewritten if rewritten != "" else text
		if input_insert_text(st, insert) {
			st.history_idx = -1
			if n_att > 0 {
				state_set_status(st, fmt.tprintf("pasted %d image(s)", n_att))
			} else {
				state_set_status(st, "pasted")
			}
			return true
		}
	}
	if !prefer_image {
		if try_paste_clipboard_image(st) {
			return true
		}
	}
	state_set_status(st, "paste: empty / no selection")
	return true
}
