package agent

import "core:strings"
import "core:testing"
import "aether:core"

@(test)
test_handle_permissions_slash_status :: proc(t: ^testing.T) {
	out := handle_permissions_slash("", core.Permission_Mode.Ask, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "permissions"), out)
	testing.expect(t, strings.contains(out, "current:"), out)
	testing.expect(t, strings.contains(out, "ask"), out)
	testing.expect(t, strings.contains(out, "auto"), out)
	testing.expect(t, strings.contains(out, "always-approve"), out)
	testing.expect(t, strings.contains(out, "read-only"), out)
	testing.expect(t, strings.contains(out, "Shift+Tab") || strings.contains(out, "Shift+tab"), out)
	testing.expect(t, strings.contains(out, "soft-bash"), out)
}

@(test)
test_handle_permissions_slash_marks_current :: proc(t: ^testing.T) {
	out := handle_permissions_slash("status", core.Permission_Mode.Auto, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "current:   auto"), out)
	// current mode row is marked with *
	testing.expect(t, strings.contains(out, "* auto"), out)
}

@(test)
test_handle_permissions_slash_help :: proc(t: ^testing.T) {
	out := handle_permissions_slash("help", core.Permission_Mode.Ask, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "Usage: /permissions"), out)
	testing.expect(t, strings.contains(out, "Shift+Tab") || strings.contains(out, "permission_mode"), out)
}

@(test)
test_handle_permissions_slash_yolo_current :: proc(t: ^testing.T) {
	out := handle_permissions_slash("", core.Permission_Mode.Always_Approve, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "current:   always-approve"), out)
	testing.expect(t, strings.contains(out, "* always-approve"), out)
}
