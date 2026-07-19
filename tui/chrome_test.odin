#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:strings"
import "core:testing"
import "core:unicode/utf8"

@(test)
test_layout_left_right_keeps_right :: proc(t: ^testing.T) {
	// narrow width: right chips preserved, left truncated
	out := layout_left_right("⎇ main ~/very/long/path/here", "ask · ctx:10%", 28)
	testing.expect(t, strings.contains(out, "ask"), out)
	testing.expect(t, strings.contains(out, "ctx:10%"), out)
	testing.expect(t, utf8.rune_count(out) <= 28, out)
}

@(test)
test_truncate_runes :: proc(t: ^testing.T) {
	testing.expect(t, truncate_runes("hello", 10) == "hello")
	got := truncate_runes("hello world", 6)
	testing.expect(t, strings.has_suffix(got, "…"), got)
	testing.expect(t, utf8.rune_count(got) == 6, got)
}

@(test)
test_format_composer_info :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	st.model = strings.clone("grok-test")
	st.perm = strings.clone("ask")
	info := format_composer_info(&st)
	testing.expect(t, strings.contains(info, "grok-test"), info)
	testing.expect(t, strings.contains(info, "ask"), info)
	st.multiline_mode = true
	info2 := format_composer_info(&st)
	testing.expect(t, strings.contains(info2, "multi"), info2)
}

@(test)
test_composer_borders_width :: proc(t: ^testing.T) {
	top := format_composer_top_border(40)
	testing.expect(t, utf8.rune_count(top) == 40, top)
	testing.expect(t, strings.has_prefix(top, "╭"), top)
	testing.expect(t, strings.has_suffix(top, "╮"), top)
	bot := format_composer_bottom_border(40, "m · ask")
	testing.expect(t, utf8.rune_count(bot) == 40, bot)
	testing.expect(t, strings.has_prefix(bot, "╰"), bot)
	testing.expect(t, strings.has_suffix(bot, "╯"), bot)
	testing.expect(t, strings.contains(bot, "m · ask"), bot)
}
