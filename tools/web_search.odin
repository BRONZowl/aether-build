package tools

import "core:strings"

// web_search is handled by the agent package (Responses API) when dispatched from the loop.
// This stub remains only if dispatch is called without agent context.
tool_web_search :: proc(arguments_json: string, allocator := context.allocator) -> string {
	_ = arguments_json
	return strings.clone(
		"error: web_search must run through the agent (Responses API). This is an internal dispatch error.",
		allocator,
	)
}

// web_fetch is handled by the agent package (libcurl + SSRF/allowlist).
tool_web_fetch_stub :: proc(arguments_json: string, allocator := context.allocator) -> string {
	_ = arguments_json
	return strings.clone(
		"error: web_fetch must run through the agent. This is an internal dispatch error.",
		allocator,
	)
}
