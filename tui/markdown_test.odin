// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_write_md_inline_visible_styles :: proc(t: ^testing.T) {
	// Color path: force color on for this test (CI often sets NO_COLOR=1)
	prev_nc := os.get_env("NO_COLOR", context.temp_allocator)
	prev_ac := os.get_env("AETHER_NO_COLOR", context.temp_allocator)
	_ = os.unset_env("NO_COLOR")
	_ = os.unset_env("AETHER_NO_COLOR")
	defer {
		if prev_nc != "" {
			_ = os.set_env("NO_COLOR", prev_nc)
		}
		if prev_ac != "" {
			_ = os.set_env("AETHER_NO_COLOR", prev_ac)
		}
	}

	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	n := write_md_inline(&b, "# Title", 80)
	s := strings.to_string(b)
	testing.expect(t, n >= 5)
	testing.expect(t, strings.contains(s, "Title"), s)
	testing.expect(t, strings.contains(s, "\x1b[1m") || strings.contains(s, "#"), s)

	strings.builder_reset(&b)
	n = write_md_inline(&b, "say **bold** and `code`", 80)
	s = strings.to_string(b)
	testing.expect(t, n >= 10)
	testing.expect(t, strings.contains(s, "bold"), s)
	testing.expect(t, !strings.contains(s, "**"), s) // markers consumed when color on
	testing.expect(t, strings.contains(s, "\x1b[1m") || strings.contains(s, "\x1b[7m"), s)
}

@(test)
test_fence_body_start_and_lang :: proc(t: ^testing.T) {
	start, lang := fence_body_start_and_lang("rust\nfn main() {}")
	testing.expect(t, lang == "rust")
	testing.expect(t, start == len("rust\n"))
	// mermaid
	src := "mermaid\ngraph TD\n  A-->B"
	start, lang = fence_body_start_and_lang(src)
	testing.expect(t, lang == "mermaid")
	testing.expect(t, strings.has_prefix(src[start:], "graph"))
	// no tag: first line has spaces
	start, lang = fence_body_start_and_lang("not a tag\ncode")
	testing.expect(t, lang == "")
	testing.expect(t, start == 0)
	// empty
	start, lang = fence_body_start_and_lang("")
	testing.expect(t, lang == "" && start == 0)
}

@(test)
test_is_mermaid_lang :: proc(t: ^testing.T) {
	testing.expect(t, is_mermaid_lang("mermaid"))
	testing.expect(t, is_mermaid_lang("flowchart"))
	testing.expect(t, is_mermaid_lang("sequencediagram"))
	testing.expect(t, !is_mermaid_lang("rust"))
	testing.expect(t, !is_mermaid_lang(""))
}

@(test)
test_fence_header_line :: proc(t: ^testing.T) {
	testing.expect(t, fence_header_line("", context.temp_allocator) == "--- code ---")
	testing.expect(t, fence_header_line("rust", context.temp_allocator) == "--- rust ---")
	h := fence_header_line("mermaid", context.temp_allocator)
	testing.expect(t, strings.contains(h, "mermaid"))
	h2 := fence_header_line("flowchart", context.temp_allocator)
	testing.expect(t, strings.contains(h2, "mermaid"))
	testing.expect(t, strings.contains(h2, "flowchart"))
}

@(test)
test_push_assistant_mermaid_fence :: proc(t: ^testing.T) {
	out := make([dynamic]string, 0, 16, context.temp_allocator)
	styles := make([dynamic]Line_Style, 0, 16, context.temp_allocator)
	idxs := make([dynamic]int, 0, 16, context.temp_allocator)
	text := "See:\n```mermaid\ngraph TD\n  A-->B\n```\nDone."
	push_assistant(&out, &styles, &idxs, 0, text, 80, context.temp_allocator)
	joined := strings.join(out[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "mermaid"))
	// M8: Unicode layout art (boxes/arrows) or framed/raw source fallback
	testing.expect(
		t,
		strings.contains(joined, "graph TD") ||
		strings.contains(joined, "A-->B") ||
		strings.contains(joined, "┌") ||
		strings.contains(joined, "╭") ||
		strings.contains(joined, "◇ mermaid") ||
		strings.contains(joined, "A") && strings.contains(joined, "B"),
	)
	testing.expect(t, strings.contains(joined, "See:") || strings.contains(joined, "Done"))
}

// Open/trailing fence (mid-stream): no crash, body visible, no fake footer-only hang.
@(test)
test_push_assistant_open_fence_live :: proc(t: ^testing.T) {
	out := make([dynamic]string, 0, 16, context.temp_allocator)
	styles := make([dynamic]Line_Style, 0, 16, context.temp_allocator)
	idxs := make([dynamic]int, 0, 16, context.temp_allocator)
	// Unclosed mermaid while streaming (bi == -1 skips layout)
	text := "Intro\n```mermaid\nflowchart TD\n  A-->B"
	push_assistant(&out, &styles, &idxs, -1, text, 80, context.temp_allocator)
	joined := strings.join(out[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "Intro") || strings.contains(joined, "mermaid"))
	testing.expect(t, strings.contains(joined, "A-->B") || strings.contains(joined, "flowchart"))
}

@(test)
test_is_table_delimiter_line :: proc(t: ^testing.T) {
	testing.expect(t, is_table_delimiter_line("| --- | --- |"))
	testing.expect(t, is_table_delimiter_line("|---|:---:|---:|"))
	testing.expect(t, is_table_delimiter_line("- | -"))
	testing.expect(t, !is_table_delimiter_line("---")) // thematic break, no pipe
	testing.expect(t, !is_table_delimiter_line("| a | b |"))
	testing.expect(t, !is_table_delimiter_line(""))
}

@(test)
test_split_table_cells :: proc(t: ^testing.T) {
	c := split_table_cells("| Name | Age |", context.temp_allocator)
	testing.expect(t, len(c) == 2)
	testing.expect(t, c[0] == "Name" && c[1] == "Age")

	c2 := split_table_cells("a | b | c", context.temp_allocator)
	testing.expect(t, len(c2) == 3)
	testing.expect(t, c2[0] == "a" && c2[2] == "c")
}

@(test)
test_try_parse_table_at :: proc(t: ^testing.T) {
	doc := "| Name | Age |\n| --- | --- |\n| Ada | 36 |\n| Bob | 42 |\n\nAfter."
	lines := strings.split_lines(doc, context.temp_allocator)
	end, formatted, ok := try_parse_table_at(lines, 0, 80, context.temp_allocator)
	testing.expect(t, ok)
	testing.expect(t, end == 4) // header, delim, 2 body
	testing.expect(t, len(formatted) == 4) // header + sep + 2 body
	// header line contains Name and Age
	testing.expect(t, strings.contains(formatted[0], "Name"))
	testing.expect(t, strings.contains(formatted[0], "Age"))
	testing.expect(t, strings.contains(formatted[0], "│"))
	// sep uses box drawing
	testing.expect(t, strings.contains(formatted[1], "─"))
	testing.expect(t, strings.contains(formatted[2], "Ada"))
	testing.expect(t, strings.contains(formatted[3], "Bob"))
}

@(test)
test_try_parse_table_rejects_non_table :: proc(t: ^testing.T) {
	lines := []string{"just a | pipe in prose", "not a delimiter"}
	_, _, ok := try_parse_table_at(lines, 0, 80, context.temp_allocator)
	testing.expect(t, !ok)
}

@(test)
test_push_markdown_prose_table :: proc(t: ^testing.T) {
	out := make([dynamic]string, 0, 16, context.temp_allocator)
	styles := make([dynamic]Line_Style, 0, 16, context.temp_allocator)
	idxs := make([dynamic]int, 0, 16, context.temp_allocator)
	text := "Intro\n\n| A | B |\n| - | - |\n| 1 | 2 |\n\nOutro"
	push_markdown_prose(&out, &styles, &idxs, 0, text, 60, context.temp_allocator)
	// expect intro prose + table rows + outro
	testing.expect(t, len(out) >= 4)
	// at least one Code-styled table line
	has_code := false
	for s in styles {
		if s == .Code {
			has_code = true
			break
		}
	}
	testing.expect(t, has_code)
	// joined text has A and 1
	joined := strings.join(out[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "Intro"))
	testing.expect(t, strings.contains(joined, "Outro"))
	testing.expect(t, strings.contains(joined, "│"))
}
