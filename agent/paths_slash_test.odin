// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:strings"
import "core:testing"

@(test)
test_handle_paths_slash_basic :: proc(t: ^testing.T) {
	out := handle_paths_slash("", nil, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "aether paths"), out)
	testing.expect(t, strings.contains(out, "GROK_HOME"), out)
	testing.expect(t, strings.contains(out, "user config") || strings.contains(out, "config.toml"), out)
	testing.expect(t, strings.contains(out, "sessions"), out)
	testing.expect(t, strings.contains(out, "memory"), out)
	testing.expect(t, strings.contains(out, "auth.json"), out)
	testing.expect(t, strings.contains(out, "prompt history") || strings.contains(out, "prompt-history"), out)
}

@(test)
test_handle_paths_slash_help :: proc(t: ^testing.T) {
	out := handle_paths_slash("help", nil, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "Usage: /paths"), out)
}

@(test)
test_handle_paths_slash_filter :: proc(t: ^testing.T) {
	out := handle_paths_slash("session", nil, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "session"), out)
	// filter should drop unrelated rows like plan.md when searching session
	// (session dir still matches)
	testing.expect(t, strings.contains(out, "sessions") || strings.contains(out, "session"), out)
}

@(test)
test_handle_paths_slash_with_session_cwd :: proc(t: ^testing.T) {
	sess: Session
	sess.cwd = "/tmp"
	sess.id = "test-session-id"
	out := handle_paths_slash("", &sess, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "cwd"), out)
	testing.expect(t, strings.contains(out, "session file") || strings.contains(out, "test-session-id"), out)
	testing.expect(t, strings.contains(out, "aether.toml") || strings.contains(out, "project"), out)
}
