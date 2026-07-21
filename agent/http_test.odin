package agent

import "core:strings"
import "core:testing"

@(test)
test_http_is_retryable :: proc(t: ^testing.T) {
	testing.expect(t, http_is_retryable(0, .Timed_Out, false), "timeout without payload")
	testing.expect(t, http_is_retryable(0, .Perform_Failed, false), "transport fail")
	testing.expect(t, http_is_retryable(429, .None, false), "429")
	testing.expect(t, http_is_retryable(503, .None, false), "503")
	testing.expect(t, http_is_retryable(502, .None, false), "502")
	testing.expect(t, http_is_retryable(504, .None, false), "504")

	testing.expect(t, !http_is_retryable(0, .Cancelled, false), "never retry cancel")
	testing.expect(t, !http_is_retryable(0, .Timed_Out, true), "no retry after payload")
	testing.expect(t, !http_is_retryable(401, .None, false), "no retry 401")
	testing.expect(t, !http_is_retryable(400, .None, false), "no retry 400")
	testing.expect(t, !http_is_retryable(200, .None, false), "no retry 200")
	testing.expect(t, !http_is_retryable(429, .None, true), "no retry 429 after payload")
}

@(test)
test_http_retry_backoff_ms :: proc(t: ^testing.T) {
	testing.expect(t, http_retry_backoff_ms(0) == 500)
	testing.expect(t, http_retry_backoff_ms(1) == 1500)
	testing.expect(t, http_retry_backoff_ms(2) == 1500)
}

@(test)
test_http_sse_opts_stall :: proc(t: ^testing.T) {
	o := http_sse_opts()
	testing.expect(t, o.timeout_s == 300)
	testing.expect(t, o.connect_timeout_s == 15)
	testing.expect(t, o.low_speed_limit == 1)
	testing.expect(t, o.low_speed_time == 120)
}

@(test)
test_http_error_string_cancelled :: proc(t: ^testing.T) {
	testing.expect(t, http_error_string(.Cancelled) == "cancelled")
	testing.expect(t, http_error_string(.Timed_Out) == "timed out" || strings.contains(http_error_string(.Timed_Out), "timed out"))
	testing.expect(t, http_error_string(.None) == "ok")
}

@(test)
test_sse_feed_partial_lines :: proc(t: ^testing.T) {
	seen: [dynamic]string
	seen.allocator = context.allocator
	defer {
		for s in seen {
			delete(s)
		}
		delete(seen)
	}

	on_data :: proc(user: rawptr, data: string) {
		arr := cast(^[dynamic]string)user
		append(arr, strings.clone(data))
	}

	ctx: Sse_Stream_Ctx
	ctx.line_buf = make([dynamic]byte, context.temp_allocator)
	ctx.full_body = make([dynamic]byte, context.temp_allocator)
	ctx.on_data = on_data
	ctx.user = &seen

	// Split a data line across two chunks
	sse_feed_bytes(&ctx, transmute([]byte)string("data: {\"a\":"))
	testing.expect(t, len(seen) == 0, "incomplete line should not fire")
	sse_feed_bytes(&ctx, transmute([]byte)string("1}\n"))
	testing.expect(t, len(seen) == 1, "complete line fires once")
	testing.expect(t, seen[0] == `{"a":1}`, seen[0])

	sse_feed_bytes(&ctx, transmute([]byte)string("data: [DONE]\n"))
	testing.expect(t, len(seen) == 2, "DONE event")
	testing.expect(t, seen[1] == "[DONE]", seen[1])
	testing.expect(t, ctx.done, "DONE marks stream done")
}

@(test)
test_sse_ignores_comments_and_empty :: proc(t: ^testing.T) {
	seen: [dynamic]string
	seen.allocator = context.allocator
	defer {
		for s in seen {
			delete(s)
		}
		delete(seen)
	}
	on_data :: proc(user: rawptr, data: string) {
		arr := cast(^[dynamic]string)user
		append(arr, strings.clone(data))
	}
	ctx: Sse_Stream_Ctx
	ctx.line_buf = make([dynamic]byte, context.temp_allocator)
	ctx.full_body = make([dynamic]byte, context.temp_allocator)
	ctx.on_data = on_data
	ctx.user = &seen

	sse_feed_bytes(&ctx, transmute([]byte)string(": keep-alive\n"))
	sse_feed_bytes(&ctx, transmute([]byte)string("\n"))
	sse_feed_bytes(&ctx, transmute([]byte)string("data: x\n"))
	testing.expectf(t, len(seen) == 1, "expected 1 data event, got %d", len(seen))
	if len(seen) == 1 {
		testing.expect(t, seen[0] == "x", seen[0])
	}
}
