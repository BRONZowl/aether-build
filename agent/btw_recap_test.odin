package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_collect_side_context_and_recap_local :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-recap-test-%d", os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)

	sess := new_session("m", dir, dir, false, .Always_Approve)
	defer destroy_session(&sess)
	append(&sess.msgs, Chat_Message{role = .User, content = strings.clone("implement the queue")})
	append(&sess.msgs, Chat_Message{role = .Assistant, content = strings.clone("added mid-turn queue")})

	ctx := collect_side_context(sess.msgs[:], 10, 4000, context.temp_allocator)
	testing.expect(t, strings.contains(ctx, "queue"))
	testing.expect(t, strings.contains(ctx, "user") || strings.contains(ctx, "["))

	// Offline recap
	_ = os.unset_env("XAI_API_KEY")
	_ = os.unset_env("GROK_AUTH")
	_ = os.set_env("GROK_AUTH_PATH", "/tmp/aether-no-auth-recap")
	out := handle_recap_slash(&sess, "m", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "recap"))
	testing.expect(t, strings.contains(out, "queue") || strings.contains(out, "Recent"))
}

@(test)
test_btw_offline_does_not_grow_history :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-btw-test-%d", os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)

	sess := new_session("m", dir, dir, false, .Always_Approve)
	defer destroy_session(&sess)
	n0 := len(sess.msgs)

	_ = os.unset_env("XAI_API_KEY")
	_ = os.unset_env("GROK_AUTH")
	_ = os.set_env("GROK_AUTH_PATH", "/tmp/aether-no-auth-btw2")

	out := handle_btw_slash(&sess, "m", "what is the auth path", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "btw:"))
	testing.expect(t, strings.contains(out, "auth path"))
	testing.expect(t, len(sess.msgs) == n0)
}
