#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:strings"
import "core:testing"

@(test)
test_hit_test_click_zone_layout :: proc(t: ^testing.T) {
	// rows=10, body_h=5, input_h=3 → header=1, body=2..6, status=7, input=8..10
	rows, body_h, input_h := 10, 5, 3
	testing.expect(t, hit_test_click_zone(1, rows, body_h, input_h) == .Header)
	testing.expect(t, hit_test_click_zone(2, rows, body_h, input_h) == .Body)
	testing.expect(t, hit_test_click_zone(6, rows, body_h, input_h) == .Body)
	testing.expect(t, hit_test_click_zone(7, rows, body_h, input_h) == .Status)
	testing.expect(t, hit_test_click_zone(8, rows, body_h, input_h) == .Input)
	testing.expect(t, hit_test_click_zone(10, rows, body_h, input_h) == .Input)
	testing.expect(t, hit_test_click_zone(0, rows, body_h, input_h) == .Outside)
	testing.expect(t, hit_test_click_zone(11, rows, body_h, input_h) == .Outside)
}

@(test)
test_hit_test_with_slash_menu :: proc(t: ^testing.T) {
	// header=1, body=2..4 (body_h=3), menu=5..7 (menu_h=3), status=8, input=9..10
	rows, body_h, input_h, menu_h := 10, 3, 2, 3
	testing.expect(t, hit_test_click_zone(1, rows, body_h, input_h, menu_h) == .Header)
	testing.expect(t, hit_test_click_zone(4, rows, body_h, input_h, menu_h) == .Body)
	testing.expect(t, hit_test_click_zone(5, rows, body_h, input_h, menu_h) == .Slash_Menu)
	testing.expect(t, hit_test_click_zone(7, rows, body_h, input_h, menu_h) == .Slash_Menu)
	testing.expect(t, hit_test_click_zone(8, rows, body_h, input_h, menu_h) == .Status)
	testing.expect(t, hit_test_click_zone(9, rows, body_h, input_h, menu_h) == .Input)
}

@(test)
test_slash_menu_click_accepts_row :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	st.focus = .Prompt
	input_set_text(&st, "/")
	st.cursor = 1
	// body_h=3, menu_h=5 → menu rows 5..9; row 5=header, 6=first match
	body_h, menu_h := 3, 5
	// click first match row (y = 2+body_h+1 = 6)
	testing.expect(t, slash_menu_click(&st, 6, body_h, menu_h))
	got := input_text(&st)
	testing.expect(t, strings.has_prefix(got, "/"))
	testing.expect(t, len(got) > 1)
}

@(test)
test_slash_menu_height_caps_to_terminal :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	st.focus = .Prompt
	input_set_text(&st, "/")
	st.cursor = 1
	// tall enough → menu shows
	h := slash_menu_height(&st, 40, 1)
	testing.expect(t, h >= 2)
	// tiny terminal → no menu or very small
	h2 := slash_menu_height(&st, 4, 1)
	testing.expect(t, h2 == 0 || h2 <= 2)
}

@(test)
test_body_line_index :: proc(t: ^testing.T) {
	// start=10, body_h=5 → y=2 → line 10, y=6 → line 14
	testing.expect(t, body_line_index(2, 5, 10, 20) == 10)
	testing.expect(t, body_line_index(6, 5, 10, 20) == 14)
	testing.expect(t, body_line_index(1, 5, 10, 20) == -1)
	testing.expect(t, body_line_index(7, 5, 10, 20) == -1)
	testing.expect(t, body_line_index(6, 5, 10, 12) == -1) // past total
}

@(test)
test_decode_mouse_sgr_click_and_wheel :: proc(t: ^testing.T) {
	// left press
	k := decode_mouse_sgr("<0;12;4", true)
	testing.expect(t, k.kind == .Mouse_Click)
	testing.expect(t, k.mouse_x == 12 && k.mouse_y == 4)
	// left release ignored
	k2 := decode_mouse_sgr("<0;12;4", false)
	testing.expect(t, k2.kind == .Unknown)
	// wheel
	k3 := decode_mouse_sgr("<64;1;1", true)
	testing.expect(t, k3.kind == .Mouse_Wheel_Up)
	k4 := decode_mouse_sgr("<65;1;1", true)
	testing.expect(t, k4.kind == .Mouse_Wheel_Down)
	// middle press
	k5 := decode_mouse_sgr("<1;8;3", true)
	testing.expect(t, k5.kind == .Mouse_Middle)
	testing.expect(t, k5.mouse_x == 8 && k5.mouse_y == 3)
	// middle release ignored
	k6 := decode_mouse_sgr("<1;8;3", false)
	testing.expect(t, k6.kind == .Unknown)
}

@(test)
test_input_insert_text_normalize :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	testing.expect(t, input_insert_text(&st, "hello\r\nworld\t!"))
	got := input_text(&st)
	testing.expect(t, got == "hello\nworld\t!")
	// strip C0
	input_clear(&st)
	testing.expect(t, input_insert_text(&st, "a\x01b"))
	testing.expect(t, input_text(&st) == "ab")
	// empty
	input_clear(&st)
	testing.expect(t, !input_insert_text(&st, ""))
	testing.expect(t, !input_insert_text(&st, "\x01\x02"))
}
