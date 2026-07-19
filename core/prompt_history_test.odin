package core

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_prompt_history_append_and_load :: proc(t: ^testing.T) {
	// Explicit path — no env (parallel-safe)
	path := fmt.tprintf("/tmp/aether-phist-%d-b23.jsonl", os.get_pid())
	_ = os.remove(path)
	defer os.remove(path)

	err := append_prompt_history_to(path, "hello world")
	testing.expect(t, err == "", err)
	err2 := append_prompt_history_to(path, "hello world") // dup skip
	testing.expect(t, err2 == "")
	err3 := append_prompt_history_to(path, "second prompt")
	testing.expect(t, err3 == "")

	list := load_prompt_history_from(path, context.allocator)
	defer destroy_prompt_history_list(list)
	testing.expectf(t, len(list) == 2, "got %d", len(list))
	if len(list) >= 1 {
		testing.expect(t, list[0] == "hello world", list[0])
	}
	if len(list) >= 2 {
		testing.expect(t, list[1] == "second prompt", list[1])
	}
}

@(test)
test_prompt_history_path_default_contains_jsonl :: proc(t: ^testing.T) {
	// Don't touch env — just ensure default path shape
	prev := os.get_env("AETHER_PROMPT_HISTORY_PATH", context.temp_allocator)
	_ = os.unset_env("AETHER_PROMPT_HISTORY_PATH")
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_PROMPT_HISTORY_PATH", prev)
		}
	}
	p := prompt_history_path(context.allocator)
	defer delete(p)
	testing.expect(t, strings.contains(p, "prompt-history.jsonl"))
}

@(test)
test_prompt_history_enabled_opt_out :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_PROMPT_HISTORY", context.temp_allocator)
	_ = os.set_env("AETHER_NO_PROMPT_HISTORY", "1")
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_NO_PROMPT_HISTORY", prev)
		} else {
			_ = os.unset_env("AETHER_NO_PROMPT_HISTORY")
		}
	}
	testing.expect(t, !prompt_history_enabled())
}
