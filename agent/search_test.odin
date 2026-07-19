package agent

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_web_search_disabled_env :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_WEB_SEARCH", context.temp_allocator)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_NO_WEB_SEARCH")
		} else {
			_ = os.set_env("AETHER_NO_WEB_SEARCH", prev)
		}
	}
	_ = os.set_env("AETHER_NO_WEB_SEARCH", "1")
	testing.expect(t, !web_search_enabled())
	out := web_search_from_args({}, "grok", `{"query":"odin"}`, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "disabled"))
}

@(test)
test_web_search_from_args_empty_query :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_WEB_SEARCH", context.temp_allocator)
	_ = os.unset_env("AETHER_NO_WEB_SEARCH")
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_NO_WEB_SEARCH")
		} else {
			_ = os.set_env("AETHER_NO_WEB_SEARCH", prev)
		}
	}
	out := web_search_from_args({}, "grok", `{"query":"  "}`, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "query is required"))
}

@(test)
test_parse_responses_search_output_fixture :: proc(t: ^testing.T) {
	// Minimal Responses-shaped body with text + annotation url
	body := `{"output":[{"type":"message","content":[{"type":"output_text","text":"Hello from search","annotations":[{"type":"url_citation","url":"https://docs.odin-lang.org/"}]}]}]}`
	text, cites := parse_responses_search_output(body, context.allocator)
	defer delete(text)
	defer {
		for c in cites {
			delete(c)
		}
		delete(cites)
	}
	testing.expect(t, strings.contains(text, "Hello from search"))
	testing.expect(t, len(cites) >= 1)
	testing.expect(t, strings.contains(cites[0], "odin-lang"))
}
