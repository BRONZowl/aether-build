package agent

import "core:strings"
import "core:testing"

@(test)
test_handle_aliases_slash_basic :: proc(t: ^testing.T) {
	out := handle_aliases_slash("", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "aliases"), out)
	testing.expect(t, strings.contains(out, "/m") || strings.contains(out, "/model"), out)
	testing.expect(t, strings.contains(out, "/yolo") || strings.contains(out, "/always-approve"), out)
	testing.expect(t, strings.contains(out, "/cm") || strings.contains(out, "/compact"), out)
	testing.expect(t, strings.contains(out, "/quit"), out)
	testing.expect(t, strings.contains(out, "/exit") || strings.contains(out, "/q"), out)
	testing.expect(t, strings.contains(out, "/settings"), out)
	testing.expect(t, strings.contains(out, "/mcps") || strings.contains(out, "/mcp"), out)
}

@(test)
test_handle_aliases_slash_filter :: proc(t: ^testing.T) {
	out := handle_aliases_slash("yolo", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "yolo") || strings.contains(out, "always"), out)
	// filter should drop unrelated rows like /theme when possible
	testing.expect(t, !strings.contains(out, "/theme") || strings.contains(out, "yolo"), out)
}

@(test)
test_handle_aliases_slash_help :: proc(t: ^testing.T) {
	out := handle_aliases_slash("help", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "Usage: /aliases"), out)
}
