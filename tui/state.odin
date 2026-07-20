#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:strings"
import "core:time"
import "core:unicode/utf8"
import "aether:core"

MAX_INPUT_LINES :: 5
TOOL_EXPAND_MAX_LINES :: 80

Block_Kind :: enum {
	User,
	Assistant,
	Tool,
}

// Transcript_Block is logical content; re-wrapped on resize.
Transcript_Block :: struct {
	kind:      Block_Kind,
	text:      string, // owned
	tool_name: string, // owned, tool only
	expanded:  bool, // tool only — Grok-style fold
	// B37: unix seconds when block was first created (0 = unknown / not stamped)
	time_unix: i64,
}

// Scrollback_Search: Ctrl+F / /find over transcript blocks.
Scrollback_Search :: struct {
	active: bool,
	query:  [dynamic]u8, // owned bytes of query
	hits:   [dynamic]int, // block indices
	hit_i:  int, // index into hits; -1 if none
}

Display_Line :: struct {
	text:  string, // owned when from wrap of blocks we re-clone each paint into temp — use temp for paint path
	style: Line_Style,
	// For paint from blocks we use temp allocator lines; permanent lines not stored.
}

Line_Style :: enum {
	Normal,
	User,
	Assistant,
	Tool,
	Dim,
	Code,
	Bold,
	Status,
}

// ESC_CLEAR_NS matches Grok Build: double-Esc within 800ms clears the prompt.
ESC_CLEAR_NS :: i64(800_000_000)
// QUIT_CONFIRM_NS matches Grok Build: double Ctrl+Q/D within 1000ms quits.
QUIT_CONFIRM_NS :: i64(1_000_000_000)

// Focus_Pane: Grok simple-mode prompt vs scrollback.
Focus_Pane :: enum {
	Prompt,
	Scrollback,
}

App_State :: struct {
	blocks:          [dynamic]Transcript_Block,
	scroll:          int,
	// B31: when true, history/stream updates pin scroll to bottom; false after user scrolls up.
	stream_follow:   bool,
	focus:           Focus_Pane,
	// selected transcript block index when focus == Scrollback; -1 = none
	selected_block:  int,
	// input as UTF-8 bytes + cursor byte index
	input:           [dynamic]u8,
	cursor:          int,
	status_owned:    string,
	status:          string,
	model:           string,
	cwd:             string, // owned; workspace path for top-bar location (Grok-shaped)
	session_id:      string,
	session_title:   string, // owned; short display title for header
	perm:            string,
	live_assist:     strings.Builder,
	streaming:       bool,
	// Grok Build: multiline mode (Enter inserts newline; Shift/Alt+Enter sends)
	multiline_mode:  bool,
	quit:            bool,
	last_cols:       int,
	last_redraw_ns:  i64,
	// double-gesture timestamps (0 = none pending)
	esc_first_ns:    i64,
	quit_first_ns:   i64,
	new_first_ns:    i64, // Ctrl+N confirm
	// prompt history (newest at end); history_idx -1 = not browsing
	prompt_history:  [dynamic]string,
	history_idx:     int,
	// ephemeral notice lines from slash commands (owned)
	notices:         [dynamic]string,
	// Ctrl+S session picker (Grok)
	picker:          Session_Picker,
	// Ctrl+M model picker when scrollback focused
	model_picker:    Model_Picker,
	// Wave 1: /rewind interactive picker
	rewind_picker:   Rewind_Picker,
	// Wave 1 settings modal (shell; fields filled in later PR)
	settings_modal:  Settings_Modal,
	// Mid-turn prompt queue (Grok /queue)
	prompt_queue:       [dynamic]string, // owned FIFO
	queue_pane_active:  bool,
	queue_sel:          int,
	queue_force_send:   bool, // empty Enter mid-turn: cancel + drain head
	// Ask-mode tool approval modal (mid-turn)
	ask_active:      bool,
	ask_name:        string, // owned while active
	ask_summary:     string, // owned while active
	// Scrollback find (Ctrl+F / /find)
	search:          Scrollback_Search,
	// B20: Tab slash-complete cycle state
	slash_comp_idx:    int,
	slash_comp_prefix: string, // owned; last prefix used for cycle
	// Live slash suggestion menu (while typing /cmd)
	slash_menu_sel:    int, // highlight index into current matches
}

state_init :: proc(s: ^App_State) {
	s.blocks = make([dynamic]Transcript_Block, 0, 32)
	s.input = make([dynamic]u8, 0, 128)
	s.cursor = 0
	s.scroll = 0
	s.stream_follow = true
	s.live_assist = strings.builder_make()
	s.status = "ready"
	s.multiline_mode = false
	s.last_cols = 0
	s.esc_first_ns = 0
	s.quit_first_ns = 0
	s.new_first_ns = 0
	s.prompt_history = make([dynamic]string, 0, 32)
	s.history_idx = -1
	s.notices = make([dynamic]string, 0, 8)
	s.focus = .Prompt
	s.selected_block = -1
	picker_init(&s.picker)
	model_picker_init(&s.model_picker)
	rewind_picker_init(&s.rewind_picker)
	settings_modal_init(&s.settings_modal)
	prompt_queue_init(s)
	s.ask_active = false
	s.ask_name = ""
	s.ask_summary = ""
	search_init(&s.search)
	s.slash_comp_idx = 0
	s.slash_comp_prefix = ""
	s.slash_menu_sel = 0
}

search_init :: proc(ss: ^Scrollback_Search) {
	ss.active = false
	ss.query = make([dynamic]u8, 0, 32)
	ss.hits = make([dynamic]int, 0, 16)
	ss.hit_i = -1
}

search_destroy :: proc(ss: ^Scrollback_Search) {
	delete(ss.query)
	delete(ss.hits)
	ss.active = false
	ss.hit_i = -1
}

// state_set_session_meta updates id + title chrome from a Session.
state_set_session_meta :: proc(s: ^App_State, id: string, title: string) {
	delete(s.session_id)
	delete(s.session_title)
	s.session_id = strings.clone(id)
	s.session_title = strings.clone(title)
}

state_destroy :: proc(s: ^App_State) {
	for &b in s.blocks {
		delete(b.text)
		delete(b.tool_name)
	}
	delete(s.blocks)
	delete(s.input)
	delete(s.live_assist.buf)
	delete(s.status_owned)
	delete(s.model)
	delete(s.cwd)
	delete(s.session_id)
	delete(s.session_title)
	delete(s.perm)
	for h in s.prompt_history {
		delete(h)
	}
	delete(s.prompt_history)
	for n in s.notices {
		delete(n)
	}
	delete(s.notices)
	picker_destroy(&s.picker)
	model_picker_destroy(&s.model_picker)
	rewind_picker_destroy(&s.rewind_picker)
	settings_modal_destroy(&s.settings_modal)
	prompt_queue_destroy(s)
	delete(s.ask_name)
	delete(s.ask_summary)
	search_destroy(&s.search)
	if s.slash_comp_prefix != "" {
		delete(s.slash_comp_prefix)
		s.slash_comp_prefix = ""
	}
}

state_set_status :: proc(s: ^App_State, text: string) {
	delete(s.status_owned)
	s.status_owned = strings.clone(text)
	s.status = s.status_owned
}

// state_set_cwd updates the top-bar workspace path (no-op if unchanged).
state_set_cwd :: proc(s: ^App_State, cwd: string) {
	path := cwd if cwd != "" else "."
	if s.cwd == path {
		return
	}
	delete(s.cwd)
	s.cwd = strings.clone(path)
}

// stream_scroll_adjust: delta > 0 scrolls toward older content (leaves bottom).
// When offset returns to 0, re-enable stick-to-bottom follow (B31).
stream_scroll_adjust :: proc(s: ^App_State, delta: int) {
	if delta == 0 {
		return
	}
	if delta > 0 {
		s.scroll += delta
		s.stream_follow = false
		return
	}
	s.scroll = max(0, s.scroll + delta)
	if s.scroll == 0 {
		s.stream_follow = true
	}
}

// stream_pin_bottom forces tail + follow (stream start / turn end / session load).
stream_pin_bottom :: proc(s: ^App_State) {
	s.scroll = 0
	s.stream_follow = true
}

// stream_maybe_pin_bottom: history/live updates only snap to tail when following.
stream_maybe_pin_bottom :: proc(s: ^App_State) {
	if s.stream_follow {
		s.scroll = 0
	}
}

state_add_block :: proc(s: ^App_State, kind: Block_Kind, text: string, tool_name := "", expanded := false) {
	append(
		&s.blocks,
		Transcript_Block {
			kind      = kind,
			text      = strings.clone(text),
			tool_name = strings.clone(tool_name) if tool_name != "" else "",
			expanded  = expanded,
			time_unix = time.to_unix_seconds(time.now()),
		},
	)
}

// block_stamp_key: stable identity for preserving time_unix across rebuild_blocks.
block_stamp_key :: proc(kind: Block_Kind, text, tool_name: string, allocator := context.allocator) -> string {
	// cap text so huge tool bodies don't bloat keys
	t := text
	if len(t) > 120 {
		t = t[:120]
	}
	return fmt.aprintf("%v\x00%s\x00%s", kind, tool_name, t, allocator = allocator)
}

// format_block_hhmm: "HH:MM " prefix or "" (temp allocator).
format_block_hhmm :: proc(unix_sec: i64) -> string {
	if unix_sec <= 0 || !core.timestamps_enabled() {
		return ""
	}
	t := time.unix(unix_sec, 0)
	h, m, _ := time.clock(t)
	return fmt.tprintf("%02d:%02d ", h, m)
}

state_clear_blocks :: proc(s: ^App_State) {
	for &b in s.blocks {
		delete(b.text)
		delete(b.tool_name)
	}
	clear(&s.blocks)
}

state_add_notice :: proc(s: ^App_State, line: string) {
	append(&s.notices, strings.clone(line))
	// keep last 40 notice lines
	for len(s.notices) > 40 {
		delete(s.notices[0])
		ordered_remove(&s.notices, 0)
	}
}

state_clear_notices :: proc(s: ^App_State) {
	for n in s.notices {
		delete(n)
	}
	clear(&s.notices)
}

history_push :: proc(s: ^App_State, prompt: string) {
	if prompt == "" {
		return
	}
	// skip consecutive duplicate
	if len(s.prompt_history) > 0 {
		last := s.prompt_history[len(s.prompt_history) - 1]
		if last == prompt {
			s.history_idx = -1
			return
		}
	}
	append(&s.prompt_history, strings.clone(prompt))
	// B23: durable global history (best-effort)
	_ = core.append_prompt_history(prompt)
	// cap in-memory
	for len(s.prompt_history) > core.PROMPT_HISTORY_MAX {
		delete(s.prompt_history[0])
		ordered_remove(&s.prompt_history, 0)
	}
	s.history_idx = -1
}

// toggle last tool block expand (Grok-lite: empty `e` on prompt)
toggle_last_tool_expand :: proc(s: ^App_State) -> bool {
	for i := len(s.blocks) - 1; i >= 0; i -= 1 {
		if s.blocks[i].kind == .Tool {
			s.blocks[i].expanded = !s.blocks[i].expanded
			return true
		}
	}
	return false
}

// set_selected_tool_expand: want = -1 toggle, 0 collapse, 1 expand
set_selected_tool_expand :: proc(s: ^App_State, want: int) -> bool {
	i := s.selected_block
	if i < 0 || i >= len(s.blocks) {
		return false
	}
	if s.blocks[i].kind != .Tool {
		return false
	}
	if want < 0 {
		s.blocks[i].expanded = !s.blocks[i].expanded
	} else {
		s.blocks[i].expanded = want != 0
	}
	return true
}

focus_prompt :: proc(s: ^App_State) {
	s.focus = .Prompt
}

focus_scrollback :: proc(s: ^App_State) {
	s.focus = .Scrollback
	if len(s.blocks) == 0 {
		s.selected_block = -1
		return
	}
	if s.selected_block < 0 || s.selected_block >= len(s.blocks) {
		s.selected_block = len(s.blocks) - 1
	}
}

// Click_Zone for mouse hit-test (C2.3). Rows are 1-based (SGR).
Click_Zone :: enum {
	Header,
	Body,
	Status,
	Slash_Menu, // live slash suggestion popup rows
	Input,
	Outside,
}

// hit_test_click_zone maps screen row y (1-based) to chrome region.
// Layout matches render: 1 header + body_h body + menu_h slash menu + 1 status + input_h input.
// menu_h is the live slash suggestion popup (0 when closed).
hit_test_click_zone :: proc(y, rows, body_h, input_h: int, menu_h: int = 0) -> Click_Zone {
	if y < 1 || y > rows {
		return .Outside
	}
	if y == 1 {
		return .Header
	}
	// body: rows 2 .. 1+body_h
	if body_h > 0 && y >= 2 && y <= 1 + body_h {
		return .Body
	}
	// slash menu sits between body and status
	menu_start := 2 + body_h
	menu_end := menu_start + menu_h - 1
	if menu_h > 0 && y >= menu_start && y <= menu_end {
		return .Slash_Menu
	}
	status_row := 2 + body_h + menu_h
	if y == status_row {
		return .Status
	}
	// input: remaining rows
	if y > status_row {
		return .Input
	}
	return .Outside
}

// body_line_index: 0-based index into flattened lines for body click.
// y is 1-based; start is first visible flattened line index.
body_line_index :: proc(y, body_h, start, total: int) -> int {
	if body_h <= 0 || y < 2 || y > 1 + body_h {
		return -1
	}
	// body_row 0..body_h-1
	body_row := y - 2
	line_i := start + body_row
	if line_i < 0 || line_i >= total {
		return -1
	}
	return line_i
}

// scrollback_move_sel moves selection by delta; returns true if changed.
scrollback_move_sel :: proc(s: ^App_State, delta: int) -> bool {
	if len(s.blocks) == 0 {
		s.selected_block = -1
		return false
	}
	if s.selected_block < 0 {
		s.selected_block = len(s.blocks) - 1
		return true
	}
	n := s.selected_block + delta
	if n < 0 {
		n = 0
	}
	if n >= len(s.blocks) {
		n = len(s.blocks) - 1
	}
	if n == s.selected_block {
		return false
	}
	s.selected_block = n
	return true
}

// scrollback_select_edge: first=true → top (index 0), else last block.
scrollback_select_edge :: proc(s: ^App_State, first: bool) -> bool {
	if len(s.blocks) == 0 {
		s.selected_block = -1
		return false
	}
	n := 0 if first else len(s.blocks) - 1
	if s.selected_block == n {
		return false
	}
	s.selected_block = n
	return true
}

// scrollback_find_kind searches exclusive of `from` in direction dir (+1/-1) for kind.
// Returns -1 if none.
scrollback_find_kind :: proc(s: ^App_State, from, dir: int, kind: Block_Kind) -> int {
	if len(s.blocks) == 0 || dir == 0 {
		return -1
	}
	i := from + dir
	for i >= 0 && i < len(s.blocks) {
		if s.blocks[i].kind == kind {
			return i
		}
		i += dir
	}
	return -1
}

// scrollback_move_sel_kind jumps to prev/next block of kind (C2.4 turn nav).
// dir +1 = next, -1 = prev. Returns true if selection changed.
scrollback_move_sel_kind :: proc(s: ^App_State, dir: int, kind: Block_Kind) -> bool {
	if len(s.blocks) == 0 {
		s.selected_block = -1
		return false
	}
	from := s.selected_block
	if from < 0 {
		// no selection: next → first match from -1; prev → last match from len
		from = -1 if dir > 0 else len(s.blocks)
	}
	n := scrollback_find_kind(s, from, dir, kind)
	if n < 0 {
		return false
	}
	if n == s.selected_block {
		return false
	}
	s.selected_block = n
	return true
}

clamp_selected_block :: proc(s: ^App_State) {
	if len(s.blocks) == 0 {
		s.selected_block = -1
		return
	}
	if s.selected_block >= len(s.blocks) {
		s.selected_block = len(s.blocks) - 1
	}
}

// --- input helpers ---

input_text :: proc(s: ^App_State) -> string {
	return string(s.input[:])
}

input_clear :: proc(s: ^App_State) {
	clear(&s.input)
	s.cursor = 0
}

input_insert_rune :: proc(s: ^App_State, r: rune) {
	buf, n := utf8.encode_rune(r)
	inject_at(&s.input, s.cursor, ..buf[:n])
	s.cursor += n
}

input_insert_byte :: proc(s: ^App_State, b: u8) {
	inject_at(&s.input, s.cursor, b)
	s.cursor += 1
}

// input_insert_text pastes UTF-8 bytes at the cursor (C2.5 middle-click / paste).
// Caps total input growth; normalizes CRLF → LF. Returns runes/bytes inserted flag.
input_insert_text :: proc(s: ^App_State, text: string) -> bool {
	if text == "" {
		return false
	}
	// normalize + cap
	MAX_PASTE :: 100_000
	b := strings.builder_make(context.temp_allocator)
	n := 0
	i := 0
	for i < len(text) && n < MAX_PASTE {
		if text[i] == '\r' {
			if i + 1 < len(text) && text[i + 1] == '\n' {
				i += 1 // skip CR of CRLF
			}
			strings.write_byte(&b, '\n')
			n += 1
			i += 1
			continue
		}
		// skip other C0 controls except tab/newline
		c := text[i]
		if c < 0x20 && c != '\n' && c != '\t' {
			i += 1
			continue
		}
		strings.write_byte(&b, c)
		n += 1
		i += 1
	}
	data := strings.to_string(b)
	if len(data) == 0 {
		return false
	}
	inject_at(&s.input, s.cursor, ..transmute([]u8)data)
	s.cursor += len(data)
	return true
}

input_backspace :: proc(s: ^App_State) {
	if s.cursor <= 0 {
		return
	}
	// find start of previous rune
	i := s.cursor - 1
	for i > 0 && (s.input[i] & 0xc0) == 0x80 {
		i -= 1
	}
	// remove [i, cursor)
	ordered_remove_range(&s.input, i, s.cursor)
	s.cursor = i
}

input_delete_word :: proc(s: ^App_State) {
	if s.cursor <= 0 {
		return
	}
	i := s.cursor
	// skip spaces
	for i > 0 && s.input[i - 1] == ' ' {
		i -= 1
	}
	for i > 0 && s.input[i - 1] != ' ' && s.input[i - 1] != '\n' {
		i -= 1
	}
	ordered_remove_range(&s.input, i, s.cursor)
	s.cursor = i
}

input_move_left :: proc(s: ^App_State) {
	if s.cursor <= 0 {
		return
	}
	i := s.cursor - 1
	for i > 0 && (s.input[i] & 0xc0) == 0x80 {
		i -= 1
	}
	s.cursor = i
}

input_move_right :: proc(s: ^App_State) {
	if s.cursor >= len(s.input) {
		return
	}
	i := s.cursor + 1
	for i < len(s.input) && (s.input[i] & 0xc0) == 0x80 {
		i += 1
	}
	s.cursor = i
}

input_home :: proc(s: ^App_State) {
	// start of current line
	i := s.cursor
	for i > 0 && s.input[i - 1] != '\n' {
		i -= 1
	}
	s.cursor = i
}

input_end :: proc(s: ^App_State) {
	i := s.cursor
	for i < len(s.input) && s.input[i] != '\n' {
		i += 1
	}
	s.cursor = i
}

// INPUT_PREFIX is the Grok-shaped composer chevron (display width 2 with trailing space).
INPUT_PREFIX :: "❯ "

input_line_count :: proc(s: ^App_State, cols: int) -> int {
	text := input_text(s)
	// count wrapped lines for "❯ " + text
	w := max(8, cols - 2)
	lines := 1
	col := 2 // prompt prefix columns
	for r in text {
		if r == '\n' {
			lines += 1
			col = 0
			continue
		}
		col += 1
		if col >= w {
			lines += 1
			col = 0
		}
	}
	if lines > MAX_INPUT_LINES {
		return MAX_INPUT_LINES
	}
	if lines < 1 {
		return 1
	}
	return lines
}

// total_input_rows: full composer block height (text + optional box frame).
total_input_rows :: proc(s: ^App_State, cols: int) -> int {
	return composer_block_height(s, cols)
}

// ordered_remove_range removes [lo, hi)
ordered_remove_range :: proc(arr: ^[dynamic]u8, lo, hi: int) {
	if lo >= hi || lo < 0 || hi > len(arr) {
		return
	}
	// shift left
	n := hi - lo
	copy(arr[lo:], arr[hi:])
	resize(arr, len(arr) - n)
}

inject_at :: proc(arr: ^[dynamic]u8, idx: int, items: ..u8) {
	if idx < 0 || idx > len(arr) {
		return
	}
	old_len := len(arr)
	resize(arr, old_len + len(items))
	// shift right
	copy(arr[idx + len(items):], arr[idx:old_len])
	copy(arr[idx:], items)
}
