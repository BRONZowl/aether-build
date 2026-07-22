// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:time"
import "aether:core"

Chat_Role :: enum {
	System,
	User,
	Assistant,
	Tool,
}

Tool_Call :: struct {
	id:        string, // allocated
	name:      string,
	arguments: string, // JSON string
}

Chat_Message :: struct {
	role:         Chat_Role,
	content:      string, // allocated
	tool_calls:   []Tool_Call, // for assistant
	tool_call_id: string, // for tool role
}

destroy_tool_call :: proc(tc: ^Tool_Call) {
	delete(tc.id)
	delete(tc.name)
	delete(tc.arguments)
}

destroy_message :: proc(m: ^Chat_Message) {
	delete(m.content)
	delete(m.tool_call_id)
	for &tc in m.tool_calls {
		destroy_tool_call(&tc)
	}
	delete(m.tool_calls)
}

destroy_messages :: proc(msgs: []Chat_Message) {
	for &m in msgs {
		destroy_message(&m)
	}
	delete(msgs)
}

clone_tool_call :: proc(tc: Tool_Call, allocator := context.allocator) -> Tool_Call {
	return Tool_Call {
		id        = strings.clone(tc.id, allocator),
		name      = strings.clone(tc.name, allocator),
		arguments = strings.clone(tc.arguments, allocator),
	}
}

clone_message :: proc(m: Chat_Message, allocator := context.allocator) -> Chat_Message {
	out := Chat_Message {
		role         = m.role,
		content      = strings.clone(m.content, allocator),
		tool_call_id = strings.clone(m.tool_call_id, allocator),
	}
	if len(m.tool_calls) > 0 {
		tcs := make([]Tool_Call, len(m.tool_calls), allocator)
		for tc, i in m.tool_calls {
			tcs[i] = clone_tool_call(tc, allocator)
		}
		out.tool_calls = tcs
	}
	return out
}

// clone_messages deep-copies messages into a new dynamic array (caller owns).
clone_messages :: proc(
	src: []Chat_Message,
	allocator := context.allocator,
) -> [dynamic]Chat_Message {
	out := make([dynamic]Chat_Message, 0, len(src), allocator)
	for m in src {
		append(&out, clone_message(m, allocator))
	}
	return out
}

// json_escape escapes a string for inclusion in a JSON string value.
// Thin alias of core.json_string_escape (shared across agent/hooks/mcp/tools).
json_escape :: proc(s: string, allocator := context.allocator) -> string {
	return core.json_string_escape(s, allocator)
}

role_str :: proc(r: Chat_Role) -> string {
	switch r {
	case .System:
		return "system"
	case .User:
		return "user"
	case .Assistant:
		return "assistant"
	case .Tool:
		return "tool"
	}
	return "user"
}

// build_chat_completions_body builds a chat completions JSON request.
build_chat_completions_body :: proc(
	model: string,
	messages: []Chat_Message,
	tools_json: string, // full JSON array or "" for none
	stream: bool = false,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, `{"model":"`)
	strings.write_string(&b, json_escape(model, context.temp_allocator))
	if stream {
		strings.write_string(&b, `","stream":true,"messages":[`)
	} else {
		strings.write_string(&b, `","stream":false,"messages":[`)
	}
	for m, i in messages {
		if i > 0 {
			strings.write_byte(&b, ',')
		}
		strings.write_string(&b, `{"role":"`)
		strings.write_string(&b, role_str(m.role))
		strings.write_string(&b, `"`)
		if m.role == .Tool {
			strings.write_string(&b, `,"tool_call_id":"`)
			strings.write_string(&b, json_escape(m.tool_call_id, context.temp_allocator))
			strings.write_string(&b, `"`)
		}
		// content — user messages may expand [Image #N] to multimodal parts (M1)
		if m.role == .Assistant && len(m.tool_calls) > 0 && m.content == "" {
			strings.write_string(&b, `,"content":null`)
		} else if m.role == .User {
			write_user_content_json(&b, m.content)
		} else {
			strings.write_string(&b, `,"content":"`)
			strings.write_string(&b, json_escape(m.content, context.temp_allocator))
			strings.write_string(&b, `"`)
		}
		if m.role == .Assistant && len(m.tool_calls) > 0 {
			strings.write_string(&b, `,"tool_calls":[`)
			for tc, j in m.tool_calls {
				if j > 0 {
					strings.write_byte(&b, ',')
				}
				strings.write_string(&b, `{"id":"`)
				strings.write_string(&b, json_escape(tc.id, context.temp_allocator))
				strings.write_string(&b, `","type":"function","function":{"name":"`)
				strings.write_string(&b, json_escape(tc.name, context.temp_allocator))
				strings.write_string(&b, `","arguments":"`)
				strings.write_string(&b, json_escape(tc.arguments, context.temp_allocator))
				strings.write_string(&b, `"}}`)
			}
			strings.write_string(&b, `]`)
		}
		strings.write_byte(&b, '}')
	}
	strings.write_byte(&b, ']')
	if tools_json != "" {
		strings.write_string(&b, `,"tools":`)
		strings.write_string(&b, tools_json)
	}
	// Optional reasoning effort (Grok /effort) when set process-wide.
	if eff := reasoning_effort_current(); eff != "" {
		strings.write_string(&b, `,"reasoning_effort":"`)
		strings.write_string(&b, json_escape(eff, context.temp_allocator))
		strings.write_string(&b, `"`)
	}
	strings.write_byte(&b, '}')
	return strings.to_string(b)
}

Assistant_Turn :: struct {
	content:             string, // allocated
	tool_calls:          []Tool_Call, // allocated
	raw_error:           string, // allocated if parse/API error detail
	streamed_to_stdout:  bool, // true if content was already printed live
}

destroy_assistant_turn :: proc(t: ^Assistant_Turn) {
	delete(t.content)
	for &tc in t.tool_calls {
		destroy_tool_call(&tc)
	}
	delete(t.tool_calls)
	delete(t.raw_error)
}

// format_http_error_body: user-visible detail for non-2xx chat API responses.
// Prefers API error.message; otherwise shows truncated raw body (HTML/plain).
format_http_error_body :: proc(status: int, body: string, allocator := context.allocator) -> string {
	trim := strings.trim_space(body)
	if trim == "" {
		return fmt.aprintf(
			"HTTP %d: empty body (check model id, base URL, and auth)",
			status,
			allocator = allocator,
		)
	}
	// Try structured API error even when status is 4xx
	_, perr := parse_chat_completions_response(body, context.temp_allocator)
	if perr != "" {
		// "API error: …" is useful; bare parse failures need raw body
		if strings.has_prefix(perr, "API error:") {
			return fmt.aprintf("HTTP %d: %s", status, perr, allocator = allocator)
		}
		// Non-JSON (proxy HTML, plain text) — surface body, not only parse noise
		if strings.has_prefix(perr, "invalid JSON") ||
		   strings.contains(perr, "not a JSON") {
			return fmt.aprintf(
				"HTTP %d: %s",
				status,
				truncate(trim, 500),
				allocator = allocator,
			)
		}
		// Other structured parse issues — include both
		return fmt.aprintf(
			"HTTP %d: %s | body: %s",
			status,
			perr,
			truncate(trim, 300),
			allocator = allocator,
		)
	}
	return fmt.aprintf("HTTP %d: %s", status, truncate(trim, 500), allocator = allocator)
}

// parse_chat_completions_response extracts the first choice message.
parse_chat_completions_response :: proc(
	body: string,
	allocator := context.allocator,
) -> (Assistant_Turn, string /* error */) {
	val, err := json.parse(transmute([]byte)body, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if err != nil {
		return {}, fmt.tprintf("invalid JSON response: %v", err)
	}
	obj, ok := val.(json.Object)
	if !ok {
		return {}, "response is not a JSON object"
	}

	// API error shape: {"error":{"message":"..."}}
	if err_v, has_err := obj["error"]; has_err {
		if err_obj, is_obj := err_v.(json.Object); is_obj {
			if msg, mok := json_str(err_obj, "message"); mok {
				return {}, fmt.tprintf("API error: %s", msg)
			}
		}
		return {}, fmt.tprintf("API error: %s", truncate(body, 300))
	}

	choices_v, has_choices := obj["choices"]
	if !has_choices {
		return {}, "response missing choices"
	}
	choices, is_arr := choices_v.(json.Array)
	if !is_arr || len(choices) == 0 {
		return {}, "empty choices"
	}
	choice0, is_obj := choices[0].(json.Object)
	if !is_obj {
		return {}, "choice is not an object"
	}
	msg_v, has_msg := choice0["message"]
	if !has_msg {
		return {}, "choice missing message"
	}
	msg, is_msg := msg_v.(json.Object)
	if !is_msg {
		return {}, "message is not an object"
	}

	turn: Assistant_Turn
	if content, cok := json_str(msg, "content"); cok {
		turn.content = strings.clone(content, allocator)
	} else {
		turn.content = strings.clone("", allocator)
	}

	if tc_v, has_tc := msg["tool_calls"]; has_tc {
		if tc_arr, is_tc := tc_v.(json.Array); is_tc {
			tcs := make([dynamic]Tool_Call, 0, len(tc_arr), allocator)
			for item in tc_arr {
				tc_obj, is_tco := item.(json.Object)
				if !is_tco {
					continue
				}
				tc: Tool_Call
				if id, iok := json_str(tc_obj, "id"); iok {
					tc.id = strings.clone(id, allocator)
				}
				if fn_v, fok := tc_obj["function"]; fok {
					if fn, is_fn := fn_v.(json.Object); is_fn {
						if name, nok := json_str(fn, "name"); nok {
							tc.name = strings.clone(name, allocator)
						}
						if args, aok := json_str(fn, "arguments"); aok {
							tc.arguments = strings.clone(args, allocator)
						}
					}
				}
				append(&tcs, tc)
			}
			turn.tool_calls = tcs[:]
		}
	}
	return turn, ""
}

// Chat_Http_Opts optional cancel/poll for completion requests.
Chat_Http_Opts :: struct {
	cancel:  ^bool,
	on_poll: proc(),
	verbose: bool,
	// Optional: on HTTP 401, refresh OIDC session in place and retry once.
	creds:   ^Credentials,
}

// try_refresh_creds: OIDC refresh into live (and opts.creds when set). Returns true on success.
try_refresh_creds :: proc(slot: ^Credentials, live: ^Credentials) -> bool {
	if live == nil || live.kind != .Session {
		return false
	}
	if err := refresh_oidc(live); err != "" {
		return false
	}
	if slot != nil && slot != live {
		// Mirror refreshed fields into caller's credentials
		delete(slot.bearer)
		slot.bearer = strings.clone(live.bearer)
		if live.refresh_token != "" {
			delete(slot.refresh_token)
			slot.refresh_token = strings.clone(live.refresh_token)
		}
		if live.expires_at != "" {
			delete(slot.expires_at)
			slot.expires_at = strings.clone(live.expires_at)
		}
	}
	return true
}

AUTH_401_HINT :: "Unauthorized (401). Session may be expired — run `aether login` or set XAI_API_KEY."

// chat_completion performs one non-streaming completion request.
// Retries transport / 429 / 502–504 up to 2 times when no body was usable.
chat_completion :: proc(
	creds: Credentials,
	model: string,
	messages: []Chat_Message,
	tools_json: string,
	allocator := context.allocator,
	http_opts: Chat_Http_Opts = {},
) -> (Assistant_Turn, string /* error */) {
	body := build_chat_completions_body(model, messages, tools_json, false, context.temp_allocator)
	live := creds
	if http_opts.creds != nil {
		live = http_opts.creds^
	}
	url := fmt.tprintf("%s/chat/completions", strings.trim_right(live.base_url, "/"))
	headers := build_auth_headers(live, context.temp_allocator)

	opts := Http_Opts {
		connect_timeout_s = 15,
		timeout_s         = 120,
		cancel            = http_opts.cancel,
		on_poll           = http_opts.on_poll,
	}

	last_err := ""
	refreshed_401 := false
	for attempt in 0 ..= 2 {
		if http_opts.cancel != nil && http_opts.cancel^ {
			return {}, "cancelled"
		}
		resp, herr := http_post_json(url, headers, body, context.allocator, opts)
		if herr == .Cancelled {
			return {}, "cancelled"
		}
		if herr != .None {
			last_err = fmt.tprintf("HTTP request failed: %s", http_error_string(herr))
			if attempt < 2 && http_is_retryable(0, herr, false) {
				fmt.eprintf("aether: retrying request (attempt %d)…\n", attempt + 2)
				time.sleep(time.Duration(http_retry_backoff_ms(attempt)) * time.Millisecond)
				continue
			}
			return {}, last_err
		}
		if resp.status == 401 {
			delete(resp.body)
			if !refreshed_401 && try_refresh_creds(http_opts.creds, &live) {
				refreshed_401 = true
				headers = build_auth_headers(live, context.temp_allocator)
				if http_opts.verbose {
					fmt.eprintf("aether: session refreshed after 401 — retrying…\n")
				}
				continue
			}
			return {}, strings.clone(AUTH_401_HINT, allocator)
		}
		if resp.status < 200 || resp.status >= 300 {
			if attempt < 2 && http_is_retryable(resp.status, .None, false) {
				delete(resp.body)
				fmt.eprintf("aether: retrying request (attempt %d)…\n", attempt + 2)
				time.sleep(time.Duration(http_retry_backoff_ms(attempt)) * time.Millisecond)
				continue
			}
			msg := format_http_error_body(resp.status, resp.body, allocator)
			delete(resp.body)
			return {}, msg
		}
		turn, err := parse_chat_completions_response(resp.body, allocator)
		delete(resp.body)
		return turn, err
	}
	return {}, last_err if last_err != "" else "HTTP request failed"
}

// Content_Delta_Handler receives streamed assistant text chunks.
// When set (non-nil), chat_completion_stream calls it instead of writing to stdout.
Content_Delta_Handler :: #type proc(text: string)

// g_content_delta is process-global; set by TUI around agent turns. Clear after.
g_content_delta: Content_Delta_Handler

set_content_delta_handler :: proc(h: Content_Delta_Handler) {
	g_content_delta = h
}

// Stream_Accum accumulates SSE chat.completion.chunk events.
Stream_Accum :: struct {
	content:        strings.Builder,
	tool_ids:       [dynamic]string,
	tool_names:     [dynamic]string,
	tool_args:      [dynamic]strings.Builder,
	live_print:     bool, // print content deltas to stdout as they arrive
	printed_any:    bool,
	saw_tool_calls: bool,
	saw_error:      string,
}

// chat_completion_stream POSTs stream:true and parses SSE progressively.
// Content deltas are printed to stdout as they arrive (unless AETHER_NO_STREAM=1).
// Retries only when no stream payload was received; cancel aborts without retry.
chat_completion_stream :: proc(
	creds: Credentials,
	model: string,
	messages: []Chat_Message,
	tools_json: string,
	quiet: bool,
	verbose: bool,
	allocator := context.allocator,
	http_opts: Chat_Http_Opts = {},
) -> (Assistant_Turn, string /* error */) {
	http_opts := http_opts
	http_opts.verbose = verbose || http_opts.verbose

	if core.env_truthy("AETHER_NO_STREAM") {
		return chat_completion(creds, model, messages, tools_json, allocator, http_opts)
	}

	body := build_chat_completions_body(model, messages, tools_json, true, context.temp_allocator)
	live := creds
	if http_opts.creds != nil {
		live = http_opts.creds^
	}
	url := fmt.tprintf("%s/chat/completions", strings.trim_right(live.base_url, "/"))
	headers := build_auth_headers(live, context.temp_allocator)

	// SSE defaults: 300s total, stall abort <1 B/s for 120s (mid-output freeze)
	opts := http_sse_opts()
	opts.cancel = http_opts.cancel
	opts.on_poll = http_opts.on_poll

	// Headless output policy (clean, Grok-scriptable):
	//   default → buffer; agent loop prints the *final* answer once (no mid-tool noise)
	//   AETHER_STREAM_STDOUT=1 → live-stream tokens like Grok plain progressive mode
	// TUI sets g_content_delta and never writes tokens to stdout.
	live_stdout :=
		g_content_delta == nil &&
		!quiet &&
		core.env_truthy("AETHER_STREAM_STDOUT")

	last_err := ""
	refreshed_401 := false
	for attempt in 0 ..= 2 {
		if http_opts.cancel != nil && http_opts.cancel^ {
			return {}, "cancelled"
		}

		accum: Stream_Accum
		accum.live_print = live_stdout
		accum.content = strings.builder_make(context.temp_allocator)
		accum.tool_ids = make([dynamic]string, context.temp_allocator)
		accum.tool_names = make([dynamic]string, context.temp_allocator)
		accum.tool_args = make([dynamic]strings.Builder, context.temp_allocator)

		on_data :: proc(user: rawptr, data: string) {
			accum := cast(^Stream_Accum)user
			if data == "[DONE]" {
				return
			}
			ingest_sse_data(accum, data)
		}

		status, full_body, herr := http_post_sse(
			url,
			headers,
			body,
			&accum,
			on_data,
			context.temp_allocator,
			opts,
		)

		got_payload :=
			accum.printed_any ||
			accum.saw_tool_calls ||
			strings.builder_len(accum.content) > 0 ||
			len(accum.tool_ids) > 0

		if herr == .Cancelled {
			return {}, "cancelled"
		}
		if herr != .None {
			last_err = fmt.tprintf("HTTP request failed: %s", http_error_string(herr))
			// No partial stream → may retry; else fall back to non-stream once
			if attempt < 2 && http_is_retryable(0, herr, got_payload) {
				fmt.eprintf("aether: retrying request (attempt %d)…\n", attempt + 2)
				time.sleep(time.Duration(http_retry_backoff_ms(attempt)) * time.Millisecond)
				continue
			}
			if !got_payload {
				if verbose {
					fmt.eprintf(
						"aether: stream transport failed (%s), falling back\n",
						http_error_string(herr),
					)
				}
				return chat_completion(creds, model, messages, tools_json, allocator, http_opts)
			}
			return {}, last_err
		}

		if status == 401 {
			if !got_payload && !refreshed_401 && try_refresh_creds(http_opts.creds, &live) {
				refreshed_401 = true
				headers = build_auth_headers(live, context.temp_allocator)
				if verbose {
					fmt.eprintf("aether: session refreshed after 401 — retrying…\n")
				}
				continue
			}
			return {}, strings.clone(AUTH_401_HINT, allocator)
		}
		if status < 200 || status >= 300 {
			if attempt < 2 && http_is_retryable(status, .None, got_payload) {
				fmt.eprintf("aether: retrying request (attempt %d)…\n", attempt + 2)
				time.sleep(time.Duration(http_retry_backoff_ms(attempt)) * time.Millisecond)
				continue
			}
			return {}, format_http_error_body(status, full_body, allocator)
		}

		if accum.saw_error != "" {
			return {}, accum.saw_error
		}

		// Proxy ignored stream and returned a single JSON object
		trim := strings.trim_space(full_body)
		if strings.has_prefix(trim, "{") &&
		   strings.builder_len(accum.content) == 0 &&
		   len(accum.tool_ids) == 0 {
			turn, err := parse_chat_completions_response(full_body, allocator)
			// Non-stream JSON body: print once like a completed plain stream (Grok plain).
			if err == "" && turn.content != "" && live_stdout && len(turn.tool_calls) == 0 {
				fmt.print(turn.content)
				if len(turn.content) == 0 || turn.content[len(turn.content) - 1] != '\n' {
					fmt.println()
				} else {
					// already ends with \n — still ensure shell prompt sits cleanly
				}
				turn.streamed_to_stdout = true
			}
			return turn, err
		}

		turn := assemble_stream_turn(&accum, allocator)
		if turn.streamed_to_stdout {
			// Grok plain on_end: trailing newline after streamed answer
			if !accum.saw_tool_calls && accum.printed_any {
				content := strings.to_string(accum.content)
				if len(content) == 0 || content[len(content) - 1] != '\n' {
					fmt.println()
				}
			}
		}
		return turn, ""
	}
	return {}, last_err if last_err != "" else "HTTP request failed"
}

assemble_stream_turn :: proc(accum: ^Stream_Accum, allocator := context.allocator) -> Assistant_Turn {
	turn: Assistant_Turn
	turn.content = strings.clone(strings.to_string(accum.content), allocator)
	// Final answer only: do not treat tool-prep prose as "already printed final".
	// That would skip printing the real post-tool answer.
	turn.streamed_to_stdout =
		accum.printed_any && !accum.saw_tool_calls && len(accum.tool_ids) == 0
	if len(accum.tool_ids) > 0 {
		tcs := make([dynamic]Tool_Call, 0, len(accum.tool_ids), allocator)
		for i in 0 ..< len(accum.tool_ids) {
			tc: Tool_Call
			if i < len(accum.tool_ids) {
				tc.id = strings.clone(accum.tool_ids[i], allocator)
			}
			if i < len(accum.tool_names) {
				tc.name = strings.clone(accum.tool_names[i], allocator)
			}
			if i < len(accum.tool_args) {
				tc.arguments = strings.clone(strings.to_string(accum.tool_args[i]), allocator)
			}
			append(&tcs, tc)
		}
		turn.tool_calls = tcs[:]
	}
	return turn
}

ingest_sse_data :: proc(accum: ^Stream_Accum, data: string) {
	val, err := json.parse(
		transmute([]byte)data,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if err != nil {
		return
	}
	obj, ok := val.(json.Object)
	if !ok {
		return
	}
	if err_v, has_err := obj["error"]; has_err {
		if err_obj, is_obj := err_v.(json.Object); is_obj {
			if msg, mok := json_str(err_obj, "message"); mok {
				accum.saw_error = fmt.tprintf("API error: %s", msg)
				return
			}
		}
		accum.saw_error = "API stream error"
		return
	}
	choices_v, has_c := obj["choices"]
	if !has_c {
		return
	}
	choices, is_arr := choices_v.(json.Array)
	if !is_arr || len(choices) == 0 {
		return
	}
	ch0, is_obj := choices[0].(json.Object)
	if !is_obj {
		return
	}
	delta_v, has_d := ch0["delta"]
	if !has_d {
		return
	}
	delta, is_delta := delta_v.(json.Object)
	if !is_delta {
		return
	}
	if content, has_content := json_str(delta, "content"); has_content && content != "" {
		strings.write_string(&accum.content, content)
		if !accum.saw_tool_calls {
			if g_content_delta != nil {
				g_content_delta(content)
				accum.printed_any = true
			} else if accum.live_print {
				fmt.print(content)
				accum.printed_any = true
			}
		}
	}
	if tc_v, has_tc := delta["tool_calls"]; has_tc {
		if tc_arr, is_tc := tc_v.(json.Array); is_tc {
			if len(tc_arr) > 0 {
				accum.saw_tool_calls = true
			}
			for item in tc_arr {
				tc_obj, is_tco := item.(json.Object)
				if !is_tco {
					continue
				}
				idx := 0
				if iv, has_i := tc_obj["index"]; has_i {
					#partial switch n in iv {
					case json.Integer:
						idx = int(n)
					case json.Float:
						idx = int(n)
					}
				}
				for len(accum.tool_ids) <= idx {
					append(&accum.tool_ids, "")
					append(&accum.tool_names, "")
					b := strings.builder_make(context.temp_allocator)
					append(&accum.tool_args, b)
				}
				if id, has_id := json_str(tc_obj, "id"); has_id && id != "" {
					accum.tool_ids[idx] = strings.clone(id, context.temp_allocator)
				}
				if fn_v, has_fn := tc_obj["function"]; has_fn {
					if fn, is_fn := fn_v.(json.Object); is_fn {
						if name, has_n := json_str(fn, "name"); has_n && name != "" {
							accum.tool_names[idx] = strings.clone(name, context.temp_allocator)
						}
						if args, has_a := json_str(fn, "arguments"); has_a && args != "" {
							strings.write_string(&accum.tool_args[idx], args)
						}
					}
				}
			}
		}
	}
}


