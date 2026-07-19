package mcp

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import "core:time"
import curl "vendor:curl"

// Header capture for Mcp-Session-Id and Content-Type
@(private)
Http_Hdr_Ctx :: struct {
	session_id:   strings.Builder,
	content_type: strings.Builder,
}

@(private)
header_cb :: proc "c" (buffer: [^]byte, size: c.size_t, nitems: c.size_t, userdata: rawptr) -> c.size_t {
	context = runtime.default_context()
	total := int(size * nitems)
	if total <= 0 {
		return 0
	}
	ctx := cast(^Http_Hdr_Ctx)userdata
	line := string(buffer[:total])
	// strip trailing \r\n
	line = strings.trim_right(line, "\r\n")
	if line == "" {
		return c.size_t(total)
	}
	// case-insensitive prefix match
	low := strings.to_lower(line, context.temp_allocator)
	if strings.has_prefix(low, "mcp-session-id:") {
		val := strings.trim_space(line[len("mcp-session-id:"):])
		// find actual colon position for original casing
		if i := strings.index_byte(line, ':'); i >= 0 {
			val = strings.trim_space(line[i + 1:])
		}
		strings.builder_reset(&ctx.session_id)
		strings.write_string(&ctx.session_id, val)
	} else if strings.has_prefix(low, "content-type:") {
		val := strings.trim_space(line[len("content-type:"):])
		if i := strings.index_byte(line, ':'); i >= 0 {
			val = strings.trim_space(line[i + 1:])
		}
		strings.builder_reset(&ctx.content_type)
		strings.write_string(&ctx.content_type, val)
	}
	return c.size_t(total)
}

@(private)
body_write_cb :: proc "c" (contents: [^]byte, size: c.size_t, nmemb: c.size_t, userp: rawptr) -> c.size_t {
	context = runtime.default_context()
	real_size := int(size * nmemb)
	memory := cast(^[dynamic]byte)userp
	n := len(memory^)
	if resize(memory, n + real_size) != nil {
		return 0
	}
	copy(memory[n:], contents[:real_size])
	return c.size_t(real_size)
}

// http_connect initializes a Streamable HTTP MCP server (POST-based).
http_connect :: proc(
	cfg: Mcp_Server_Config,
	quiet: bool,
	allocator := context.allocator,
) -> (Mcp_Server, string /* err */) {
	_ = quiet
	auth_hdrs, auth_src := resolve_http_auth_headers(cfg, allocator)
	srv := Mcp_Server {
		name        = strings.clone(cfg.name, allocator),
		kind        = .Http,
		url         = strings.clone(cfg.url, allocator),
		headers     = auth_hdrs,
		auth_source = auth_src,
		next_id     = 1,
		alive       = true,
		tools       = make([dynamic]Mcp_Tool, 0, 16, allocator),
		resources   = make([dynamic]Mcp_Resource, 0, 8, allocator),
		prompts     = make([dynamic]Mcp_Prompt, 0, 8, allocator),
	}

	timeout := cfg.startup_timeout_sec
	if timeout <= 0 {
		timeout = 30
	}
	timeout_dur := time.Duration(timeout) * time.Second

	init_params := `{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"aether-grok","version":"0.1.0"}}`
	resp, rerr := rpc_request(&srv, "initialize", init_params, timeout_dur, context.temp_allocator)
	if rerr != "" {
		http_close(&srv)
		return {}, fmt.tprintf("initialize: %s", rerr)
	}
	_ = resp
	_ = rpc_notify(&srv, "notifications/initialized", "{}")

	list_resp, lerr := rpc_request(&srv, "tools/list", "{}", timeout_dur, context.temp_allocator)
	if lerr != "" {
		http_close(&srv)
		return {}, fmt.tprintf("tools/list: %s", lerr)
	}
	if err := parse_tools_list(&srv, list_resp, allocator); err != "" {
		http_close(&srv)
		return {}, err
	}
	fetch_server_catalog(&srv, timeout_dur, allocator)
	return srv, ""
}

http_close :: proc(s: ^Mcp_Server) {
	if s == nil {
		return
	}
	s.alive = false
	// optional: DELETE with session — skip for v1
	delete(s.url)
	s.url = ""
	delete(s.session_id)
	s.session_id = ""
	for h in s.headers {
		delete(h[0])
		delete(h[1])
	}
	delete(s.headers)
	destroy_server_catalog(s)
	delete(s.name)
}

// http_rpc_request POSTs one JSON-RPC message. want_id < 0 means notification (no result parse).
http_rpc_request :: proc(
	s: ^Mcp_Server,
	body: string,
	want_id: int,
	timeout: time.Duration,
	allocator := context.allocator,
) -> (result_json: string, err: string) {
	if s == nil || s.url == "" {
		return "", "no url"
	}
	curl.global_init(curl.GLOBAL_DEFAULT)
	easy := curl.easy_init()
	if easy == nil {
		return "", "curl init failed"
	}
	defer curl.easy_cleanup(easy)

	memory: [dynamic]byte
	memory.allocator = context.temp_allocator
	hdr_ctx: Http_Hdr_Ctx
	hdr_ctx.session_id = strings.builder_make(context.temp_allocator)
	hdr_ctx.content_type = strings.builder_make(context.temp_allocator)

	url_c := strings.clone_to_cstring(s.url, context.temp_allocator)
	curl.easy_setopt(easy, .URL, url_c)
	curl.easy_setopt(easy, .POST, c.long(1))
	body_c := strings.clone_to_cstring(body, context.temp_allocator)
	curl.easy_setopt(easy, .POSTFIELDS, body_c)
	curl.easy_setopt(easy, .POSTFIELDSIZE, c.long(len(body)))
	curl.easy_setopt(easy, .WRITEFUNCTION, body_write_cb)
	curl.easy_setopt(easy, .WRITEDATA, &memory)
	curl.easy_setopt(easy, .HEADERFUNCTION, header_cb)
	curl.easy_setopt(easy, .HEADERDATA, &hdr_ctx)
	curl.easy_setopt(easy, .FOLLOWLOCATION, c.long(1))
	secs := int(timeout / time.Second)
	if secs < 5 {
		secs = 5
	}
	if secs > 600 {
		secs = 600
	}
	curl.easy_setopt(easy, .CONNECTTIMEOUT, c.long(15))
	curl.easy_setopt(easy, .TIMEOUT, c.long(secs))
	curl.easy_setopt(easy, .USERAGENT, cstring("aether-grok-mcp/0.1"))

	slist: ^curl.slist
	defer if slist != nil {
		curl.slist_free_all(slist)
	}
	slist = curl.slist_append(slist, "Content-Type: application/json")
	slist = curl.slist_append(slist, "Accept: application/json, text/event-stream")
	for h in s.headers {
		line := fmt.tprintf("%s: %s", h[0], h[1])
		slist = curl.slist_append(slist, strings.clone_to_cstring(line, context.temp_allocator))
	}
	if s.session_id != "" {
		line := fmt.tprintf("Mcp-Session-Id: %s", s.session_id)
		slist = curl.slist_append(slist, strings.clone_to_cstring(line, context.temp_allocator))
	}
	curl.easy_setopt(easy, .HTTPHEADER, slist)

	res := curl.easy_perform(easy)
	if res != .E_OK {
		cs := curl.easy_strerror(res)
		if cs != nil {
			return "", fmt.tprintf("curl: %s", string(cs))
		}
		return "", "curl perform failed"
	}

	status: c.long = 0
	curl.easy_getinfo(easy, .RESPONSE_CODE, &status)

	// update session id if server sent one
	sid := strings.to_string(hdr_ctx.session_id)
	if sid != "" {
		delete(s.session_id)
		s.session_id = strings.clone(sid, context.allocator)
	}

	resp_body := string(memory[:])
	ct := strings.to_lower(strings.to_string(hdr_ctx.content_type), context.temp_allocator)

	if int(status) < 200 || int(status) >= 300 {
		snip := resp_body
		if len(snip) > 200 {
			snip = snip[:200]
		}
		return "", fmt.tprintf("HTTP %d: %s", int(status), snip)
	}

	if want_id < 0 {
		// notification
		return "", ""
	}

	// JSON body
	if strings.contains(ct, "application/json") || strings.has_prefix(strings.trim_space(resp_body), "{") {
		// single JSON-RPC response or batch
		res_j, e, skip := extract_rpc_result(strings.trim_space(resp_body), want_id, allocator)
		if !skip {
			return res_j, e
		}
		// try as bare result object without wrapper — unlikely
		return "", fmt.tprintf("unexpected JSON response (id mismatch)")
	}

	// SSE: extract data: frames
	if strings.contains(ct, "text/event-stream") || strings.contains(resp_body, "data:") {
		return parse_sse_rpc_result(resp_body, want_id, allocator)
	}

	// fallback: try as JSON anyway
	res_j, e, skip := extract_rpc_result(strings.trim_space(resp_body), want_id, allocator)
	if !skip {
		return res_j, e
	}
	return "", "unrecognized HTTP MCP response (expected JSON or SSE)"
}

// parse_sse_rpc_result walks SSE body for data: lines with matching JSON-RPC id.
parse_sse_rpc_result :: proc(
	body: string,
	want_id: int,
	allocator := context.allocator,
) -> (string, string) {
	// accumulate multi-line data fields per event
	data_parts: [dynamic]string
	data_parts.allocator = context.temp_allocator

	flush_event :: proc(
		parts: ^[dynamic]string,
		want_id: int,
		allocator := context.allocator,
	) -> (string, string, bool /* done */) {
		if len(parts) == 0 {
			return "", "", false
		}
		// join with \n per SSE
		b := strings.builder_make(context.temp_allocator)
		for p, i in parts {
			if i > 0 {
				strings.write_byte(&b, '\n')
			}
			strings.write_string(&b, p)
		}
		clear(parts)
		msg := strings.to_string(b)
		if !strings.has_prefix(strings.trim_space(msg), "{") {
			return "", "", false
		}
		res, err, skip := extract_rpc_result(msg, want_id, allocator)
		if skip {
			return "", "", false
		}
		return res, err, true
	}

	for line in strings.split_lines(body, context.temp_allocator) {
		if line == "" {
			res, err, done := flush_event(&data_parts, want_id, allocator)
			if done {
				return res, err
			}
			continue
		}
		if strings.has_prefix(line, "data:") {
			payload := strings.trim_space(line[5:])
			append(&data_parts, payload)
		}
		// ignore event:, id:, retry:
	}
	// trailing event without blank line
	res, err, done := flush_event(&data_parts, want_id, allocator)
	if done {
		return res, err
	}
	return "", "SSE stream ended without matching JSON-RPC response"
}
