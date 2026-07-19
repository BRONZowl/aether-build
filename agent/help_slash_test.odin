package agent

import "core:strings"
import "core:testing"

@(test)
test_handle_help_slash_sections :: proc(t: ^testing.T) {
	out := handle_help_slash("", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "aether commands"), out)
	testing.expect(t, strings.contains(out, "### Discover"), out)
	testing.expect(t, strings.contains(out, "### Session"), out)
	testing.expect(t, strings.contains(out, "### Exit"), out)
	testing.expect(t, strings.contains(out, "/about"), out)
	testing.expect(t, strings.contains(out, "/permissions"), out)
	testing.expect(t, strings.contains(out, "/env"), out)
	testing.expect(t, strings.contains(out, "/paths"), out)
	testing.expect(t, strings.contains(out, "/exit"), out)
}

@(test)
test_handle_help_slash_filter :: proc(t: ^testing.T) {
	out := handle_help_slash("plan", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "/plan"), out)
	testing.expect(t, strings.contains(out, "view-plan") || strings.contains(out, "/view-plan"), out)
	// unrelated commands should drop when filter is specific
	testing.expect(t, !strings.contains(out, "/imagine-video"), out)
}

@(test)
test_handle_help_slash_section_filter :: proc(t: ^testing.T) {
	out := handle_help_slash("memory", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "/remember") || strings.contains(out, "/memory"), out)
	testing.expect(t, strings.contains(out, "### Memory") || strings.contains(out, "/memory"), out)
}

@(test)
test_handle_help_slash_help :: proc(t: ^testing.T) {
	out := handle_help_slash("help", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "Usage: /help"), out)
}

@(test)
test_handle_help_slash_no_match :: proc(t: ^testing.T) {
	out := handle_help_slash("zzzz-no-such-cmd", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "no commands matching"), out)
}
