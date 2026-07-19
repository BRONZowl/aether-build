#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:strings"
import "core:unicode/utf8"

// search_open activates find mode; initial may prefill the query.
search_open :: proc(s: ^App_State, initial := "") {
	s.search.active = true
	clear(&s.search.query)
	if initial != "" {
		for i in 0 ..< len(initial) {
			append(&s.search.query, initial[i])
		}
	}
	search_rebuild(s)
	if len(s.search.hits) > 0 {
		s.search.hit_i = 0
		search_goto_current(s)
	} else {
		s.search.hit_i = -1
	}
	search_set_status(s)
}

search_close :: proc(s: ^App_State) {
	s.search.active = false
	clear(&s.search.query)
	clear(&s.search.hits)
	s.search.hit_i = -1
	if s.focus == .Scrollback {
		state_set_status(s, "scrollback")
	} else {
		state_set_status(s, "ready")
	}
}

search_query_string :: proc(ss: ^Scrollback_Search, allocator := context.allocator) -> string {
	if len(ss.query) == 0 {
		return strings.clone("", allocator)
	}
	return strings.clone(string(ss.query[:]), allocator)
}

// search_rebuild rescans blocks for case-insensitive substring matches.
search_rebuild :: proc(s: ^App_State) {
	clear(&s.search.hits)
	q := search_query_string(&s.search, context.temp_allocator)
	if q == "" {
		s.search.hit_i = -1
		return
	}
	q_low := strings.to_lower(q, context.temp_allocator)
	for bi in 0 ..< len(s.blocks) {
		bl := s.blocks[bi]
		hay := bl.text
		if bl.tool_name != "" {
			hay = fmt.tprintf("%s %s", bl.tool_name, bl.text)
		}
		hay_low := strings.to_lower(hay, context.temp_allocator)
		if strings.contains(hay_low, q_low) {
			append(&s.search.hits, bi)
		}
	}
	if len(s.search.hits) == 0 {
		s.search.hit_i = -1
	} else if s.search.hit_i < 0 || s.search.hit_i >= len(s.search.hits) {
		s.search.hit_i = 0
	}
}

search_goto_current :: proc(s: ^App_State) {
	if s.search.hit_i < 0 || s.search.hit_i >= len(s.search.hits) {
		return
	}
	bi := s.search.hits[s.search.hit_i]
	if bi < 0 || bi >= len(s.blocks) {
		return
	}
	s.focus = .Scrollback
	s.selected_block = bi
}

search_next :: proc(s: ^App_State) {
	if len(s.search.hits) == 0 {
		return
	}
	if s.search.hit_i < 0 {
		s.search.hit_i = 0
	} else {
		s.search.hit_i = (s.search.hit_i + 1) % len(s.search.hits)
	}
	search_goto_current(s)
}

search_prev :: proc(s: ^App_State) {
	if len(s.search.hits) == 0 {
		return
	}
	if s.search.hit_i < 0 {
		s.search.hit_i = len(s.search.hits) - 1
	} else {
		s.search.hit_i -= 1
		if s.search.hit_i < 0 {
			s.search.hit_i = len(s.search.hits) - 1
		}
	}
	search_goto_current(s)
}

search_set_status :: proc(s: ^App_State) {
	q := search_query_string(&s.search, context.temp_allocator)
	if q == "" {
		state_set_status(s, "find:  (type to search · n/N · Esc)")
		return
	}
	if len(s.search.hits) == 0 {
		state_set_status(s, fmt.tprintf("find: %s  no matches", q))
		return
	}
	// 1-based index for display
	state_set_status(
		s,
		fmt.tprintf("find: %s  %d/%d", q, s.search.hit_i + 1, len(s.search.hits)),
	)
}

// handle_search_key: true if key consumed.
handle_search_key :: proc(s: ^App_State, key: Key) -> bool {
	if !s.search.active {
		return false
	}
	#partial switch key.kind {
	case .Esc:
		search_close(s)
		return true
	case .Enter:
		search_next(s)
		search_set_status(s)
		return true
	case .Backspace:
		if len(s.search.query) > 0 {
			// pop last UTF-8 rune
			_, size := utf8.decode_last_rune(s.search.query[:])
			if size <= 0 {
				size = 1
			}
			resize(&s.search.query, len(s.search.query) - size)
		}
		search_rebuild(s)
		if len(s.search.hits) > 0 {
			s.search.hit_i = 0
			search_goto_current(s)
		}
		search_set_status(s)
		return true
	case .Char:
		// n/N navigate when query non-empty and not typing? Grok types all into query.
		// Plan: n/N always navigate when query non-empty; when empty, append.
		// Simpler: always append chars including n/N (like vim /). Use Tab for next? Plan said n/N.
		// Use: if ch is n/N and query already has content, navigate; Ctrl+N not here.
		// Actually plan: "n next, N prev". So special-case n/N.
		if key.ch == 'n' && len(s.search.query) > 0 {
			search_next(s)
			search_set_status(s)
			return true
		}
		if key.ch == 'N' && len(s.search.query) > 0 {
			search_prev(s)
			search_set_status(s)
			return true
		}
		if key.ch >= 32 {
			// append utf8 of rune
			buf, n := utf8.encode_rune(key.ch)
			for i in 0 ..< n {
				append(&s.search.query, buf[i])
			}
			search_rebuild(s)
			if len(s.search.hits) > 0 {
				s.search.hit_i = 0
				search_goto_current(s)
			} else {
				s.search.hit_i = -1
			}
			search_set_status(s)
		}
		return true
	case .Ctrl_C, .Ctrl_Q:
		search_close(s)
		return true
	case .Up, .Down, .PgUp, .PgDn, .Ctrl_J, .Ctrl_K, .Ctrl_U:
		// allow scroll while searching
		return false
	case:
		return true // swallow other keys while searching
	}
	return true
}
