#+build linux, darwin, freebsd, openbsd, netbsd
package tui

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
