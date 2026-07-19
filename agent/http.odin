package agent

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:strings"
import curl "vendor:curl"
import "aether:core"

Http_Response :: struct {
	status: int,
	body:   string, // allocated
}

Http_Error :: enum {
	None,
	Init_Failed,
	Perform_Failed,
	Alloc_Failed,
	Cancelled,
	Timed_Out,
}

// Http_Opts configures timeouts and cooperative cancel for a single request.
Http_Opts :: struct {
	connect_timeout_s: int, // default 15 when <= 0
	timeout_s:         int, // default 120 when <= 0; use http_sse_opts for long samples
	cancel:            ^bool,
	on_poll:           proc(), // optional; invoked from xferinfo (e.g. TUI key peek)
}

http_default_opts :: proc() -> Http_Opts {
	return Http_Opts {
		connect_timeout_s = 15,
		timeout_s         = 120,
	}
}

// http_sse_opts is for chat completions streaming (long samples).
http_sse_opts :: proc() -> Http_Opts {
	return Http_Opts {
		connect_timeout_s = 15,
		timeout_s         = 300,
	}
}

http_resolve_opts :: proc(opts: Http_Opts) -> Http_Opts {
	o := opts
	if o.connect_timeout_s <= 0 {
		o.connect_timeout_s = 15
	}
	if o.timeout_s <= 0 {
		o.timeout_s = 120
	}
	return o
}

// Last curl detail for Perform_Failed (not owned; points at libcurl static string).
@(private)
g_last_curl_detail: string

@(private)
set_curl_detail :: proc(res: curl.code) {
	if res == .E_OK {
		g_last_curl_detail = ""
		return
	}
	cs := curl.easy_strerror(res)
	if cs == nil {
		g_last_curl_detail = ""
		return
	}
	g_last_curl_detail = string(cs)
}

@(private)
classify_curl_error :: proc(res: curl.code) -> Http_Error {
	set_curl_detail(res)
	#partial switch res {
	case .E_OK:
		return .None
	case .E_ABORTED_BY_CALLBACK:
		return .Cancelled
	case .E_OPERATION_TIMEDOUT:
		return .Timed_Out
	case:
		return .Perform_Failed
	}
}

// http_is_retryable: safe retries only before any payload and never on cancel.
// got_payload true if any response body/stream content was already consumed.
http_is_retryable :: proc(status: int, err: Http_Error, got_payload: bool) -> bool {
	if got_payload {
		return false
	}
	if err == .Cancelled || err == .Init_Failed || err == .Alloc_Failed {
		return false
	}
	if err == .Timed_Out || err == .Perform_Failed {
		return true
	}
	if err == .None {
		return status == 429 || status == 502 || status == 503 || status == 504
	}
	return false
}

// http_retry_backoff_ms returns sleep duration before attempt `attempt` (0-based after first fail).
http_retry_backoff_ms :: proc(attempt: int) -> int {
	// attempt 0 → 500ms, attempt 1 → 1500ms
	if attempt <= 0 {
		return 500
	}
	return 1500
}

@(private)
Xfer_User :: struct {
	cancel:  ^bool,
	on_poll: proc(),
}

@(private)
xferinfo_cb :: proc "c" (
	clientp: rawptr,
	dltotal: curl.off_t,
	dlnow: curl.off_t,
	ultotal: curl.off_t,
	ulnow: curl.off_t,
) -> c.int {
	context = runtime.default_context()
	_ = dltotal
	_ = dlnow
	_ = ultotal
	_ = ulnow
	u := cast(^Xfer_User)clientp
	if u == nil {
		return 0
	}
	if u.on_poll != nil {
		u.on_poll()
	}
	if u.cancel != nil && u.cancel^ {
		return 1
	}
	return 0
}

@(private)
easy_apply_common :: proc(easy: ^curl.CURL, opts: Http_Opts, xfer: ^Xfer_User) {
	o := http_resolve_opts(opts)
	curl.easy_setopt(easy, .USERAGENT, strings.clone_to_cstring(core.user_agent(), context.temp_allocator))
	curl.easy_setopt(easy, .FOLLOWLOCATION, c.long(1))
	curl.easy_setopt(easy, .CONNECTTIMEOUT, c.long(o.connect_timeout_s))
	curl.easy_setopt(easy, .TIMEOUT, c.long(o.timeout_s))

	// Cooperative cancel / key poll during blocking easy_perform
	if o.cancel != nil || o.on_poll != nil {
		xfer.cancel = o.cancel
		xfer.on_poll = o.on_poll
		curl.easy_setopt(easy, .NOPROGRESS, c.long(0))
		curl.easy_setopt(easy, .XFERINFOFUNCTION, xferinfo_cb)
		curl.easy_setopt(easy, .XFERINFODATA, xfer)
	}
}

@(private)
write_cb :: proc "c" (contents: [^]byte, size: c.size_t, nmemb: c.size_t, userp: rawptr) -> c.size_t {
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

// http_get performs HTTPS GET and returns status + body.
http_get :: proc(
	url: string,
	headers: []string = nil,
	allocator := context.allocator,
	opts: Http_Opts = {},
) -> (Http_Response, Http_Error) {
	return http_request("GET", url, headers, "", allocator, opts)
}

// http_post_json POSTs a JSON body.
http_post_json :: proc(
	url: string,
	headers: []string,
	json_body: string,
	allocator := context.allocator,
	opts: Http_Opts = {},
) -> (Http_Response, Http_Error) {
	hs := make([dynamic]string, 0, len(headers) + 1, context.temp_allocator)
	has_ct := false
	for h in headers {
		append(&hs, h)
		if strings.has_prefix(strings.to_lower(h, context.temp_allocator), "content-type:") {
			has_ct = true
		}
	}
	if !has_ct {
		append(&hs, "Content-Type: application/json")
	}
	return http_request("POST", url, hs[:], json_body, allocator, opts)
}

// http_post_form POSTs application/x-www-form-urlencoded body.
http_post_form :: proc(
	url: string,
	headers: []string,
	form_body: string,
	allocator := context.allocator,
	opts: Http_Opts = {},
) -> (Http_Response, Http_Error) {
	hs := make([dynamic]string, 0, len(headers) + 1, context.temp_allocator)
	for h in headers {
		append(&hs, h)
	}
	append(&hs, "Content-Type: application/x-www-form-urlencoded")
	return http_request("POST", url, hs[:], form_body, allocator, opts)
}

http_request :: proc(
	method: string,
	url: string,
	headers: []string,
	body: string,
	allocator := context.allocator,
	opts: Http_Opts = {},
) -> (resp: Http_Response, err: Http_Error) {
	curl.global_init(curl.GLOBAL_DEFAULT)
	// global_init is refcounted; cleanup not called here intentionally for process lifetime.

	easy := curl.easy_init()
	if easy == nil {
		return {}, .Init_Failed
	}
	defer curl.easy_cleanup(easy)

	memory: [dynamic]byte
	memory.allocator = context.temp_allocator

	xfer: Xfer_User
	easy_apply_common(easy, opts, &xfer)

	url_c := strings.clone_to_cstring(url, context.temp_allocator)
	curl.easy_setopt(easy, .URL, url_c)
	curl.easy_setopt(easy, .WRITEFUNCTION, write_cb)
	curl.easy_setopt(easy, .WRITEDATA, &memory)

	if method == "POST" {
		curl.easy_setopt(easy, .POST, c.long(1))
		if body != "" {
			body_c := strings.clone_to_cstring(body, context.temp_allocator)
			curl.easy_setopt(easy, .POSTFIELDS, body_c)
			curl.easy_setopt(easy, .POSTFIELDSIZE, c.long(len(body)))
		}
	} else if method != "GET" {
		curl.easy_setopt(easy, .CUSTOMREQUEST, strings.clone_to_cstring(method, context.temp_allocator))
		if body != "" {
			body_c := strings.clone_to_cstring(body, context.temp_allocator)
			curl.easy_setopt(easy, .POSTFIELDS, body_c)
		}
	}

	slist: ^curl.slist
	defer if slist != nil {
		curl.slist_free_all(slist)
	}
	for h in headers {
		slist = curl.slist_append(slist, strings.clone_to_cstring(h, context.temp_allocator))
	}
	if slist != nil {
		curl.easy_setopt(easy, .HTTPHEADER, slist)
	}

	res := curl.easy_perform(easy)
	if res != .E_OK {
		return {}, classify_curl_error(res)
	}

	status: c.long = 0
	curl.easy_getinfo(easy, .RESPONSE_CODE, &status)

	body_str, aerr := strings.clone_from_bytes(memory[:], allocator)
	if aerr != nil {
		return {}, .Alloc_Failed
	}
	resp = Http_Response {
		status = int(status),
		body   = body_str,
	}
	return resp, .None
}

http_error_string :: proc(err: Http_Error) -> string {
	switch err {
	case .None:
		return "ok"
	case .Init_Failed:
		return "curl init failed"
	case .Perform_Failed:
		if g_last_curl_detail != "" {
			return fmt.tprintf("curl perform failed: %s", g_last_curl_detail)
		}
		return "curl perform failed"
	case .Alloc_Failed:
		return "allocation failed"
	case .Cancelled:
		return "cancelled"
	case .Timed_Out:
		if g_last_curl_detail != "" {
			return fmt.tprintf("timed out: %s", g_last_curl_detail)
		}
		return "timed out"
	}
	return "unknown http error"
}

// Sse_Data_Handler is invoked for each complete SSE `data:` payload (text after "data:").
// Also called with the special payload "[DONE]".
Sse_Data_Handler :: #type proc(user: rawptr, data: string)

Sse_Stream_Ctx :: struct {
	line_buf:  [dynamic]byte,
	on_data:   Sse_Data_Handler,
	user:      rawptr,
	// Capture full body for error / non-stream fallback diagnostics
	full_body: [dynamic]byte,
	done:      bool,
	cancel:    ^bool,
	on_poll:   proc(),
}

// sse_feed_bytes appends raw chunk bytes and dispatches complete lines.
// Exported for unit tests.
sse_feed_bytes :: proc(ctx: ^Sse_Stream_Ctx, chunk: []byte) {
	if ctx.done {
		return
	}
	if len(chunk) > 0 {
		append(&ctx.full_body, ..chunk)
		append(&ctx.line_buf, ..chunk)
	}
	// Process complete lines (split on \n; tolerate \r\n)
	for {
		idx := -1
		for i in 0 ..< len(ctx.line_buf) {
			if ctx.line_buf[i] == '\n' {
				idx = i
				break
			}
		}
		if idx < 0 {
			break
		}
		// Clone the line before shifting the buffer — handlers may retain the string
		// only for the duration of the call, but the slice would be corrupted by copy().
		raw_line := string(ctx.line_buf[:idx])
		if len(raw_line) > 0 && raw_line[len(raw_line) - 1] == '\r' {
			raw_line = raw_line[:len(raw_line) - 1]
		}
		line := strings.clone(raw_line, context.temp_allocator)
		// advance buffer
		copy(ctx.line_buf[:], ctx.line_buf[idx + 1:])
		resize(&ctx.line_buf, len(ctx.line_buf) - idx - 1)

		sse_handle_line(ctx, line)
		if ctx.done {
			return
		}
	}
}

sse_flush :: proc(ctx: ^Sse_Stream_Ctx) {
	if ctx.done {
		return
	}
	if len(ctx.line_buf) == 0 {
		return
	}
	raw_line := string(ctx.line_buf[:])
	if len(raw_line) > 0 && raw_line[len(raw_line) - 1] == '\r' {
		raw_line = raw_line[:len(raw_line) - 1]
	}
	line := strings.clone(raw_line, context.temp_allocator)
	clear(&ctx.line_buf)
	sse_handle_line(ctx, line)
}

sse_handle_line :: proc(ctx: ^Sse_Stream_Ctx, line: string) {
	trim := strings.trim_space(line)
	if trim == "" || strings.has_prefix(trim, ":") {
		return
	}
	if !strings.has_prefix(trim, "data:") {
		return
	}
	data := strings.trim_space(trim[5:])
	if ctx.on_data != nil {
		ctx.on_data(ctx.user, data)
	}
	if data == "[DONE]" {
		ctx.done = true
	}
}

@(private)
sse_write_cb :: proc "c" (contents: [^]byte, size: c.size_t, nmemb: c.size_t, userp: rawptr) -> c.size_t {
	context = runtime.default_context()
	real_size := int(size * nmemb)
	ctx := cast(^Sse_Stream_Ctx)userp
	// Abort early if cancelled (in addition to xferinfo)
	if ctx.cancel != nil && ctx.cancel^ {
		return 0 // abort transfer
	}
	if ctx.on_poll != nil {
		ctx.on_poll()
		if ctx.cancel != nil && ctx.cancel^ {
			return 0
		}
	}
	if real_size > 0 {
		sse_feed_bytes(ctx, contents[:real_size])
	}
	return c.size_t(real_size)
}

// http_post_sse POSTs JSON and streams the response body as SSE lines via on_data.
// Returns HTTP status. full_body (allocated) is the raw response for fallback/error.
http_post_sse :: proc(
	url: string,
	headers: []string,
	json_body: string,
	user: rawptr,
	on_data: Sse_Data_Handler,
	allocator := context.allocator,
	opts: Http_Opts = {},
) -> (status: int, full_body: string, err: Http_Error) {
	curl.global_init(curl.GLOBAL_DEFAULT)

	easy := curl.easy_init()
	if easy == nil {
		return 0, "", .Init_Failed
	}
	defer curl.easy_cleanup(easy)

	// Prefer SSE defaults when caller left timeout unset
	o := opts
	if o.timeout_s <= 0 {
		o.timeout_s = 300
	}
	if o.connect_timeout_s <= 0 {
		o.connect_timeout_s = 15
	}

	ctx: Sse_Stream_Ctx
	ctx.line_buf = make([dynamic]byte, 0, 4096, context.temp_allocator)
	ctx.full_body = make([dynamic]byte, 0, 8192, context.temp_allocator)
	ctx.on_data = on_data
	ctx.user = user
	ctx.cancel = o.cancel
	ctx.on_poll = o.on_poll

	xfer: Xfer_User
	easy_apply_common(easy, o, &xfer)

	url_c := strings.clone_to_cstring(url, context.temp_allocator)
	curl.easy_setopt(easy, .URL, url_c)
	curl.easy_setopt(easy, .WRITEFUNCTION, sse_write_cb)
	curl.easy_setopt(easy, .WRITEDATA, &ctx)
	// Disable curl's internal buffering if supported — write as data arrives
	curl.easy_setopt(easy, .BUFFERSIZE, c.long(1024))

	curl.easy_setopt(easy, .POST, c.long(1))
	if json_body != "" {
		body_c := strings.clone_to_cstring(json_body, context.temp_allocator)
		curl.easy_setopt(easy, .POSTFIELDS, body_c)
		curl.easy_setopt(easy, .POSTFIELDSIZE, c.long(len(json_body)))
	}

	slist: ^curl.slist
	defer if slist != nil {
		curl.slist_free_all(slist)
	}
	has_ct := false
	has_accept := false
	for h in headers {
		slist = curl.slist_append(slist, strings.clone_to_cstring(h, context.temp_allocator))
		lower := strings.to_lower(h, context.temp_allocator)
		if strings.has_prefix(lower, "content-type:") {
			has_ct = true
		}
		if strings.has_prefix(lower, "accept:") {
			has_accept = true
		}
	}
	if !has_ct {
		slist = curl.slist_append(slist, "Content-Type: application/json")
	}
	if !has_accept {
		slist = curl.slist_append(slist, "Accept: text/event-stream")
	}
	if slist != nil {
		curl.easy_setopt(easy, .HTTPHEADER, slist)
	}

	res := curl.easy_perform(easy)
	sse_flush(&ctx)
	if res != .E_OK {
		// write_cb abort (return 0) may surface as WRITE_ERROR rather than ABORTED
		if o.cancel != nil && o.cancel^ {
			set_curl_detail(res)
			return 0, "", .Cancelled
		}
		return 0, "", classify_curl_error(res)
	}

	st: c.long = 0
	curl.easy_getinfo(easy, .RESPONSE_CODE, &st)

	body_str, aerr := strings.clone_from_bytes(ctx.full_body[:], allocator)
	if aerr != nil {
		return int(st), "", .Alloc_Failed
	}
	return int(st), body_str, .None
}

// form_encode builds application/x-www-form-urlencoded from key/value pairs.
form_encode :: proc(pairs: [][2]string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for p, i in pairs {
		if i > 0 {
			strings.write_byte(&b, '&')
		}
		strings.write_string(&b, url_encode(p[0], context.temp_allocator))
		strings.write_byte(&b, '=')
		strings.write_string(&b, url_encode(p[1], context.temp_allocator))
	}
	return strings.to_string(b)
}

// Minimal percent-encoding for form bodies.
url_encode :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make_len_cap(0, len(s) * 3, allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		if (ch >= 'A' && ch <= 'Z') ||
		   (ch >= 'a' && ch <= 'z') ||
		   (ch >= '0' && ch <= '9') ||
		   ch == '-' ||
		   ch == '_' ||
		   ch == '.' ||
		   ch == '~' {
			strings.write_byte(&b, ch)
		} else if ch == ' ' {
			strings.write_byte(&b, '+')
		} else {
			strings.write_string(&b, fmt.tprintf("%%%02X", ch))
		}
	}
	return strings.to_string(b)
}
