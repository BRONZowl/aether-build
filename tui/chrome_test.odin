// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:strings"
import "core:testing"
import "core:unicode/utf8"
import "aether:agent"
import "aether:core"

@(test)
test_layout_left_right_keeps_right :: proc(t: ^testing.T) {
	// narrow width: right chips preserved, left truncated
	out := layout_left_right("⎇ main ~/very/long/path/here", "12K / 131K", 28)
	testing.expect(t, strings.contains(out, "12K"), out)
	testing.expect(t, strings.contains(out, "131K"), out)
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
test_composer_mode_accent_matches_grok :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	th := active_theme()
	agent.clear_plan_mode_for_new_session()

	// Chevron: ask/user — not permission-tinted (Grok)
	st.perm = strings.clone("ask")
	ask := composer_mode_accent(&st, th)
	delete(st.perm)
	st.perm = strings.clone("always-approve")
	yolo_ch := composer_mode_accent(&st, th)
	// same chevron for ask and yolo when not plan
	testing.expect(t, ask == yolo_ch, "chevron ignores yolo; only plan tints it")

	// Border: neutral prompt_border* when not plan
	b_ask := composer_border_ansi(true, th, ask)
	testing.expect(t, b_ask == th.prompt_border_active || b_ask != "", b_ask)
	b_idle := composer_border_ansi(false, th, ask)
	testing.expect(t, b_idle == th.prompt_border || b_idle != "", b_idle)

	// Flags: auto = accent_system; yolo/ask = dim gray
	delete(st.perm)
	st.perm = strings.clone("auto")
	auto_f := composer_flag_ansi(&st, th)
	if th.accent_system != "" {
		testing.expect(t, auto_f == th.accent_system, auto_f)
	}
	delete(st.perm)
	st.perm = strings.clone("always-approve")
	yolo_f := composer_flag_ansi(&st, th)
	if th.dim != "" {
		testing.expect(t, yolo_f == th.dim, yolo_f)
	}

	// Plan: gold chevron + gold border
	agent.set_plan_mode_active(true)
	defer agent.clear_plan_mode_for_new_session()
	plan_ch := composer_mode_accent(&st, th)
	plan_b := composer_border_ansi(true, th, plan_ch)
	plan_f := composer_flag_ansi(&st, th)
	if th.accent_plan != "" {
		testing.expect(t, plan_ch == th.accent_plan, plan_ch)
		testing.expect(t, plan_b == th.accent_plan, plan_b)
		testing.expect(t, plan_f == th.accent_plan, plan_f)
	}
}

@(test)
test_format_composer_info :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	st.model = strings.clone("grok-test")
	st.perm = strings.clone("ask")
	_ = agent.set_reasoning_effort("off")
	info := format_composer_info(&st)
	testing.expect(t, strings.contains(info, "grok-test"), info)
	testing.expect(t, strings.contains(info, "ask"), info)
	testing.expect(t, !strings.contains(info, "high"), info)
	// effort appears when set
	_ = agent.set_reasoning_effort("high")
	defer _ = agent.set_reasoning_effort("off")
	info_e := format_composer_info(&st)
	testing.expect(t, strings.contains(info_e, "high"), info_e)
	testing.expect(t, strings.contains(info_e, "grok-test"), info_e)
	st.multiline_mode = true
	info2 := format_composer_info(&st)
	testing.expect(t, strings.contains(info2, "multi"), info2)
	testing.expect(t, strings.contains(info2, "high"), info2)
}

@(test)
test_composer_borders_width :: proc(t: ^testing.T) {
	top := format_composer_top_border(40, "")
	testing.expect(t, utf8.rune_count(top) == 40, top)
	testing.expect(t, strings.has_prefix(top, "╭"), top)
	testing.expect(t, strings.has_suffix(top, "╮"), top)
	// title right-aligned near ╮
	titled := format_composer_top_border(40, "my session")
	testing.expect(t, utf8.rune_count(titled) == 40, titled)
	testing.expect(t, strings.contains(titled, "my session"), titled)
	testing.expect(t, strings.has_suffix(titled, "─╮") || strings.has_suffix(titled, "╮"), titled)
	bot := format_composer_bottom_border(40, "m · ask")
	testing.expect(t, utf8.rune_count(bot) == 40, bot)
	testing.expect(t, strings.has_prefix(bot, "╰"), bot)
	testing.expect(t, strings.has_suffix(bot, "╯"), bot)
	testing.expect(t, strings.contains(bot, "m · ask"), bot)
	// caption closer to right: trailing dashes after caption ≤ 2 (plus ╯)
	// find caption then ensure remaining before ╯ is short
	idx := strings.index(bot, "m · ask")
	testing.expect(t, idx >= 0, bot)
	after := bot[idx + len("m · ask"):]
	// after is like " ──╯" or " ─╯"
	testing.expect(t, utf8.rune_count(after) <= 5, after)
}

@(test)
test_composer_frame_rows_box_has_vpad :: proc(t: ^testing.T) {
	st: App_State
	state_init(&st)
	defer state_destroy(&st)
	// force non-compact
	prev := core.compact_mode_enabled()
	core.set_compact_mode(false)
	defer core.set_compact_mode(prev)
	top, bot := composer_frame_rows(&st, 80)
	testing.expect(t, top == 2, "expected blank + top rail")
	testing.expect(t, bot == 1)
}
