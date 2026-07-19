package agent

import "core:strings"
import "core:testing"

@(test)
test_handle_keys_slash :: proc(t: ^testing.T) {
	out := handle_keys_slash(context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "aether keys"), out)
	testing.expect(t, strings.contains(out, "Compose") || strings.contains(out, "compose"), out)
	testing.expect(t, strings.contains(out, "Shift+Tab"), out)
	testing.expect(t, strings.contains(out, "Ctrl+O") || strings.contains(out, "YOLO"), out)
	testing.expect(t, strings.contains(out, "Ctrl+F") || strings.contains(out, "find"), out)
	testing.expect(t, strings.contains(out, "Enter"), out)
}
