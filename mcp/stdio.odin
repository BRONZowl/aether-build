package mcp

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"
import "aether:core"

// stdio_connect spawns a stdio MCP server and runs initialize + tools/list.
stdio_connect :: proc(
	cfg: Mcp_Server_Config,
	quiet: bool,
	allocator := context.allocator,
) -> (Mcp_Server, string /* err */) {
	_ = quiet
	cmd := make([dynamic]string, 0, 1 + len(cfg.args), context.temp_allocator)
	append(&cmd, cfg.command)
	for a in cfg.args {
		append(&cmd, a)
	}

	// env: inherit + extras as KEY=VALUE (nil env = inherit current)
	env_slice: []string = nil
	if len(cfg.env) > 0 {
		base, eerr := os.environ(context.temp_allocator)
		if eerr != nil {
			base = nil
		}
		env_dyn := make([dynamic]string, 0, len(base) + len(cfg.env), context.temp_allocator)
		for e in base {
			append(&env_dyn, e)
		}
		for kv in cfg.env {
			prefix := fmt.tprintf("%s=", kv[0])
			for i := 0; i < len(env_dyn); i += 1 {
				if strings.has_prefix(env_dyn[i], prefix) {
					ordered_remove(&env_dyn, i)
					i -= 1
				}
			}
			append(&env_dyn, fmt.tprintf("%s=%s", kv[0], kv[1]))
		}
		env_slice = env_dyn[:]
	}

	stdin_r, stdin_w, e1 := os.pipe()
	if e1 != nil {
		return {}, fmt.tprintf("pipe stdin: %v", e1)
	}
	stdout_r, stdout_w, e2 := os.pipe()
	if e2 != nil {
		os.close(stdin_r)
		os.close(stdin_w)
		return {}, fmt.tprintf("pipe stdout: %v", e2)
	}

	child, serr := os.process_start(
		{
			command = cmd[:],
			env     = env_slice,
			stdin   = stdin_r,
			stdout  = stdout_w,
			// stderr inherits / null — leave nil to shut down per Process_Desc docs
		},
	)
	// parent closes ends given to child
	os.close(stdin_r)
	os.close(stdout_w)
	if serr != nil {
		os.close(stdin_w)
		os.close(stdout_r)
		return {}, fmt.tprintf("spawn: %v", serr)
	}

	srv := Mcp_Server {
		name      = strings.clone(cfg.name, allocator),
		kind      = .Stdio,
		child     = child,
		stdin_w   = stdin_w,
		stdout_r  = stdout_r,
		next_id   = 1,
		alive     = true,
		tools     = make([dynamic]Mcp_Tool, 0, 16, allocator),
		resources = make([dynamic]Mcp_Resource, 0, 8, allocator),
		prompts   = make([dynamic]Mcp_Prompt, 0, 8, allocator),
	}

	timeout := cfg.startup_timeout_sec
	if timeout <= 0 {
		timeout = 30
	}
	deadline := time.now()
	// store as Duration from now
	timeout_dur := time.Duration(timeout) * time.Second

	// initialize
	init_params := fmt.tprintf(
		`{{"protocolVersion":"2024-11-05","capabilities":{{}},"clientInfo":{{"name":"aether-grok","version":"{}"}}}}`,
		core.version_string(),
	)
	// version_string may contain quotes — use simple fixed clientInfo
	init_params = `{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"aether-grok","version":"0.1.0"}}`

	resp, rerr := rpc_request(&srv, "initialize", init_params, timeout_dur, context.temp_allocator)
	if rerr != "" {
		stdio_close(&srv)
		return {}, fmt.tprintf("initialize: %s", rerr)
	}
	_ = resp
	// notifications/initialized
	_ = rpc_notify(&srv, "notifications/initialized", "{}")

	list_resp, lerr := rpc_request(&srv, "tools/list", "{}", timeout_dur, context.temp_allocator)
	if lerr != "" {
		stdio_close(&srv)
		return {}, fmt.tprintf("tools/list: %s", lerr)
	}
	if err := parse_tools_list(&srv, list_resp, allocator); err != "" {
		stdio_close(&srv)
		return {}, err
	}
	// Best-effort resources/prompts — never fail connect
	fetch_server_catalog(&srv, timeout_dur, allocator)
	_ = deadline
	return srv, ""
}

stdio_close :: proc(s: ^Mcp_Server) {
	if s == nil {
		return
	}
	if s.alive {
		_ = os.process_kill(s.child)
		_, _ = os.process_wait(s.child, 2 * time.Second)
		s.alive = false
	}
	if s.stdin_w != nil {
		os.close(s.stdin_w)
		s.stdin_w = nil
	}
	if s.stdout_r != nil {
		os.close(s.stdout_r)
		s.stdout_r = nil
	}
	destroy_server_catalog(s)
	delete(s.name)
}

// Content-Length frame write
write_message :: proc(s: ^Mcp_Server, body: string) -> string /* err */ {
	if s == nil || !s.alive {
		return "server not alive"
	}
	header := fmt.tprintf("Content-Length: %d\r\n\r\n", len(body))
	n, err := os.write(s.stdin_w, transmute([]byte)header)
	if err != nil || n < len(header) {
		return fmt.tprintf("write header: %v", err)
	}
	n2, err2 := os.write(s.stdin_w, transmute([]byte)body)
	if err2 != nil || n2 < len(body) {
		return fmt.tprintf("write body: %v", err2)
	}
	return ""
}

// read_message reads one Content-Length framed JSON message (or NDJSON line fallback).
read_message :: proc(
	s: ^Mcp_Server,
	timeout: time.Duration,
	allocator := context.allocator,
) -> (string, string /* err */) {
	if s == nil || !s.alive {
		return "", "server not alive"
	}
	start := time.now()
	header_buf: [dynamic]byte
	header_buf.allocator = context.temp_allocator
	buf: [1]u8
	// read headers until \r\n\r\n
	for {
		if time.since(start) > timeout {
			return "", "timeout reading headers"
		}
		has, _ := os.pipe_has_data(s.stdout_r)
		if !has {
			// check process dead
			st, werr := os.process_wait(s.child, 0)
			if werr == nil && st.exited {
				s.alive = false
				return "", "process exited"
			}
			time.sleep(5 * time.Millisecond)
			continue
		}
		n, rerr := os.read(s.stdout_r, buf[:])
		if n > 0 {
			append(&header_buf, buf[0])
			// check for end of headers
			if len(header_buf) >= 4 {
				h := string(header_buf[:])
				if strings.has_suffix(h, "\r\n\r\n") {
					break
				}
				// NDJSON fallback: got a full line without Content-Length
				if strings.has_suffix(h, "\n") && !strings.has_prefix(h, "Content-Length:") &&
				   !strings.has_prefix(h, "content-length:") {
					line := strings.trim_right(h, "\r\n")
					if strings.has_prefix(strings.trim_space(line), "{") {
						return strings.clone(line, allocator), ""
					}
				}
			}
		}
		if rerr == .EOF || rerr == .Broken_Pipe {
			s.alive = false
			return "", "eof"
		}
	}
	header := string(header_buf[:])
	cl := 0
	for line in strings.split_lines(header, context.temp_allocator) {
		low := strings.to_lower(line, context.temp_allocator)
		if strings.has_prefix(low, "content-length:") {
			num := strings.trim_space(line[len("Content-Length:"):])
			// case insensitive already
			if i := strings.index_byte(low, ':'); i >= 0 {
				num = strings.trim_space(line[i + 1:])
			}
			if n, ok := strconv.parse_int(num); ok {
				cl = n
			}
		}
	}
	if cl <= 0 || cl > 16 * 1024 * 1024 {
		return "", fmt.tprintf("bad content-length %d", cl)
	}
	body := make([]byte, cl, context.temp_allocator)
	got := 0
	for got < cl {
		if time.since(start) > timeout {
			return "", "timeout reading body"
		}
		n, rerr := os.read(s.stdout_r, body[got:])
		if n > 0 {
			got += n
		}
		if rerr == .EOF || rerr == .Broken_Pipe {
			if got < cl {
				return "", "eof mid-body"
			}
			break
		}
		if n == 0 {
			time.sleep(2 * time.Millisecond)
		}
	}
	return strings.clone(string(body[:cl]), allocator), ""
}

// build_rpc_request_body builds a JSON-RPC request string with next id.
build_rpc_request_body :: proc(s: ^Mcp_Server, method: string, params_json: string) -> (body: string, id: int) {
	id = s.next_id
	s.next_id += 1
	if params_json == "" || params_json == "null" {
		body = fmt.tprintf(
			`{"jsonrpc":"2.0","id":%d,"method":%s}`,
			id,
			json_quote(method, context.temp_allocator),
		)
	} else {
		body = fmt.tprintf(
			`{"jsonrpc":"2.0","id":%d,"method":%s,"params":%s}`,
			id,
			json_quote(method, context.temp_allocator),
			params_json,
		)
	}
	return body, id
}

// extract_rpc_result parses a JSON-RPC response message for matching id.
// Returns result JSON or err. skip=true means notification / wrong id — caller continues.
extract_rpc_result :: proc(
	msg: string,
	want_id: int,
	allocator := context.allocator,
) -> (result_json: string, err: string, skip: bool) {
	val, perr := json.parse(transmute([]byte)msg, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil {
		return "", "", true
	}
	obj, ok := val.(json.Object)
	if !ok {
		return "", "", true
	}
	if _, has_id := obj["id"]; !has_id {
		return "", "", true // notification
	}
	id_ok := false
	#partial switch v in obj["id"] {
	case json.Integer:
		id_ok = int(v) == want_id
	case json.Float:
		id_ok = int(v) == want_id
	}
	if !id_ok {
		return "", "", true
	}
	if err_v, has_err := obj["error"]; has_err {
		return "", fmt.tprintf("rpc error: %s", truncate_json(err_v, 300)), false
	}
	if res, has := obj["result"]; has {
		return json_value_to_string(res, allocator), "", false
	}
	return strings.clone("{}", allocator), "", false
}

rpc_request :: proc(
	s: ^Mcp_Server,
	method: string,
	params_json: string,
	timeout: time.Duration,
	allocator := context.allocator,
) -> (result_json: string, err: string) {
	if s == nil || !s.alive {
		return "", "server not alive"
	}
	body, id := build_rpc_request_body(s, method, params_json)

	if s.kind == .Http {
		return http_rpc_request(s, body, id, timeout, allocator)
	}

	// stdio
	if werr := write_message(s, body); werr != "" {
		return "", werr
	}
	deadline_start := time.now()
	for {
		remain := timeout - time.since(deadline_start)
		if remain <= 0 {
			return "", "timeout waiting for response"
		}
		msg, rerr := read_message(s, remain, context.temp_allocator)
		if rerr != "" {
			return "", rerr
		}
		res, e, skip := extract_rpc_result(msg, id, allocator)
		if skip {
			continue
		}
		return res, e
	}
}

rpc_notify :: proc(s: ^Mcp_Server, method: string, params_json: string) -> string {
	body := fmt.tprintf(
		`{"jsonrpc":"2.0","method":%s,"params":%s}`,
		json_quote(method, context.temp_allocator),
		params_json if params_json != "" else "{}",
	)
	if s.kind == .Http {
		// best-effort POST notification; ignore body
		_, err := http_rpc_request(s, body, -1, 30 * time.Second, context.temp_allocator)
		return err
	}
	return write_message(s, body)
}

// server_call_tool runs tools/call on stdio or HTTP server.
server_call_tool :: proc(
	s: ^Mcp_Server,
	tool_name: string,
	arguments_json: string,
	timeout: time.Duration,
	allocator := context.allocator,
) -> string {
	if s == nil || !s.alive {
		return strings.clone("error: mcp server not alive", allocator)
	}
	args := arguments_json if arguments_json != "" else "{}"
	params := fmt.tprintf(
		`{"name":%s,"arguments":%s}`,
		json_quote(tool_name, context.temp_allocator),
		args,
	)
	res, err := rpc_request(s, "tools/call", params, timeout, context.temp_allocator)
	if err != "" {
		return fmt.aprintf("error: mcp tools/call: %s", err, allocator = allocator)
	}
	return format_tool_result(res, allocator)
}

// alias for older name
stdio_call_tool :: server_call_tool

// fetch_server_catalog best-effort resources/list + prompts/list (never fails connect).
fetch_server_catalog :: proc(
	s: ^Mcp_Server,
	timeout: time.Duration,
	allocator := context.allocator,
) {
	if s == nil || !s.alive {
		return
	}
	if res, err := rpc_request(s, "resources/list", "{}", timeout, context.temp_allocator); err == "" {
		_ = parse_resources_list(s, res, allocator)
	}
	if res, err := rpc_request(s, "prompts/list", "{}", timeout, context.temp_allocator); err == "" {
		_ = parse_prompts_list(s, res, allocator)
	}
}

// server_read_resource calls resources/read.
server_read_resource :: proc(
	s: ^Mcp_Server,
	uri: string,
	timeout: time.Duration,
	allocator := context.allocator,
) -> string {
	if s == nil || !s.alive {
		return strings.clone("error: mcp server not alive", allocator)
	}
	params := fmt.tprintf(`{"uri":%s}`, json_quote(uri, context.temp_allocator))
	res, err := rpc_request(s, "resources/read", params, timeout, context.temp_allocator)
	if err != "" {
		return fmt.aprintf("error: mcp resources/read: %s", err, allocator = allocator)
	}
	return format_resource_read_result(res, allocator)
}

// server_get_prompt calls prompts/get.
server_get_prompt :: proc(
	s: ^Mcp_Server,
	name: string,
	arguments_json: string,
	timeout: time.Duration,
	allocator := context.allocator,
) -> string {
	if s == nil || !s.alive {
		return strings.clone("error: mcp server not alive", allocator)
	}
	args := arguments_json if arguments_json != "" else "{}"
	params := fmt.tprintf(
		`{"name":%s,"arguments":%s}`,
		json_quote(name, context.temp_allocator),
		args,
	)
	res, err := rpc_request(s, "prompts/get", params, timeout, context.temp_allocator)
	if err != "" {
		return fmt.aprintf("error: mcp prompts/get: %s", err, allocator = allocator)
	}
	return format_prompt_get_result(res, allocator)
}

parse_resources_list :: proc(
	s: ^Mcp_Server,
	result_json: string,
	allocator := context.allocator,
) -> string {
	val, err := json.parse(
		transmute([]byte)result_json,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if err != nil {
		return fmt.tprintf("parse resources/list: %v", err)
	}
	obj, ok := val.(json.Object)
	if !ok {
		return "resources/list result not object"
	}
	arr_v, has := obj["resources"]
	if !has {
		return ""
	}
	arr, is_arr := arr_v.(json.Array)
	if !is_arr {
		return "resources not array"
	}
	n := 0
	for item in arr {
		if n >= MAX_MCP_CATALOG {
			break
		}
		tobj, is_obj := item.(json.Object)
		if !is_obj {
			continue
		}
		uri := json_obj_str(tobj, "uri")
		if uri == "" {
			continue
		}
		mime := json_obj_str(tobj, "mimeType")
		if mime == "" {
			mime = json_obj_str(tobj, "mime_type")
		}
		r := Mcp_Resource {
			server      = strings.clone(s.name, allocator),
			uri         = strings.clone(uri, allocator),
			name        = strings.clone(json_obj_str(tobj, "name"), allocator),
			description = strings.clone(json_obj_str(tobj, "description"), allocator),
			mime_type   = strings.clone(mime, allocator),
		}
		append(&s.resources, r)
		n += 1
	}
	return ""
}

parse_prompts_list :: proc(
	s: ^Mcp_Server,
	result_json: string,
	allocator := context.allocator,
) -> string {
	val, err := json.parse(
		transmute([]byte)result_json,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if err != nil {
		return fmt.tprintf("parse prompts/list: %v", err)
	}
	obj, ok := val.(json.Object)
	if !ok {
		return "prompts/list result not object"
	}
	arr_v, has := obj["prompts"]
	if !has {
		return ""
	}
	arr, is_arr := arr_v.(json.Array)
	if !is_arr {
		return "prompts not array"
	}
	n := 0
	for item in arr {
		if n >= MAX_MCP_CATALOG {
			break
		}
		tobj, is_obj := item.(json.Object)
		if !is_obj {
			continue
		}
		name := json_obj_str(tobj, "name")
		if name == "" {
			continue
		}
		args_json := "[]"
		if av, has_a := tobj["arguments"]; has_a {
			args_json = json_value_to_string(av, context.temp_allocator)
		}
		p := Mcp_Prompt {
			server         = strings.clone(s.name, allocator),
			name           = strings.clone(name, allocator),
			description    = strings.clone(json_obj_str(tobj, "description"), allocator),
			arguments_json = strings.clone(args_json, allocator),
		}
		append(&s.prompts, p)
		n += 1
	}
	return ""
}

format_resource_read_result :: proc(result_json: string, allocator := context.allocator) -> string {
	val, err := json.parse(
		transmute([]byte)result_json,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if err != nil {
		// raw fallback
		return cap_mcp_output(result_json, allocator)
	}
	obj, ok := val.(json.Object)
	if !ok {
		return cap_mcp_output(result_json, allocator)
	}
	contents_v, has := obj["contents"]
	if !has {
		return cap_mcp_output(result_json, allocator)
	}
	arr, is_arr := contents_v.(json.Array)
	if !is_arr || len(arr) == 0 {
		return strings.clone("(empty resource)", allocator)
	}
	b := strings.builder_make(allocator)
	for item, i in arr {
		if i > 0 {
			strings.write_string(&b, "\n---\n")
		}
		cobj, is_obj := item.(json.Object)
		if !is_obj {
			continue
		}
		uri := json_obj_str(cobj, "uri")
		mime := json_obj_str(cobj, "mimeType")
		if mime == "" {
			mime = json_obj_str(cobj, "mime_type")
		}
		if uri != "" {
			strings.write_string(&b, fmt.tprintf("uri: %s\n", uri))
		}
		if mime != "" {
			strings.write_string(&b, fmt.tprintf("mimeType: %s\n", mime))
		}
		if tv, has_t := cobj["text"]; has_t {
			if ts, is_s := tv.(json.String); is_s {
				strings.write_string(&b, string(ts))
				continue
			}
		}
		if bv, has_b := cobj["blob"]; has_b {
			if bs, is_s := bv.(json.String); is_s {
				strings.write_string(
					&b,
					fmt.tprintf("[blob %d base64 chars mime=%s]", len(string(bs)), mime),
				)
				continue
			}
		}
		strings.write_string(&b, json_value_to_string(item, context.temp_allocator))
	}
	out := strings.to_string(b)
	capped := cap_mcp_output(out, allocator)
	if capped != out {
		delete(out)
	}
	return capped
}

format_prompt_get_result :: proc(result_json: string, allocator := context.allocator) -> string {
	// Prefer pretty-ish text; fall back to capped raw JSON
	val, err := json.parse(
		transmute([]byte)result_json,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if err != nil {
		return cap_mcp_output(result_json, allocator)
	}
	obj, ok := val.(json.Object)
	if !ok {
		return cap_mcp_output(result_json, allocator)
	}
	b := strings.builder_make(allocator)
	if d := json_obj_str(obj, "description"); d != "" {
		strings.write_string(&b, fmt.tprintf("description: %s\n\n", d))
	}
	if mv, has := obj["messages"]; has {
		strings.write_string(&b, "messages:\n")
		strings.write_string(&b, json_value_to_string(mv, context.temp_allocator))
		strings.write_byte(&b, '\n')
	} else {
		strings.write_string(&b, json_value_to_string(val, context.temp_allocator))
	}
	out := strings.to_string(b)
	capped := cap_mcp_output(out, allocator)
	if capped != out {
		delete(out)
	}
	return capped
}

cap_mcp_output :: proc(s: string, allocator := context.allocator) -> string {
	if len(s) <= MAX_MCP_RESOURCE_BYTES {
		return strings.clone(s, allocator)
	}
	return fmt.aprintf(
		"%s\n… [truncated at %d bytes]",
		s[:MAX_MCP_RESOURCE_BYTES],
		MAX_MCP_RESOURCE_BYTES,
		allocator = allocator,
	)
}

parse_tools_list :: proc(s: ^Mcp_Server, result_json: string, allocator := context.allocator) -> string {
	val, err := json.parse(
		transmute([]byte)result_json,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if err != nil {
		return fmt.tprintf("parse tools/list: %v", err)
	}
	obj, ok := val.(json.Object)
	if !ok {
		// maybe bare array
		if arr, is_arr := val.(json.Array); is_arr {
			return ingest_tools_array(s, arr, allocator)
		}
		return "tools/list result not object"
	}
	tools_v, has := obj["tools"]
	if !has {
		return "tools/list missing tools"
	}
	arr, is_arr := tools_v.(json.Array)
	if !is_arr {
		return "tools not array"
	}
	return ingest_tools_array(s, arr, allocator)
}

ingest_tools_array :: proc(s: ^Mcp_Server, arr: json.Array, allocator := context.allocator) -> string {
	for item in arr {
		tobj, is_obj := item.(json.Object)
		if !is_obj {
			continue
		}
		name := json_obj_str(tobj, "name")
		if name == "" {
			continue
		}
		desc := json_obj_str(tobj, "description")
		schema := "{}"
		if schema_v, has_schema := tobj["inputSchema"]; has_schema {
			schema = json_value_to_string(schema_v, context.temp_allocator)
		} else if schema_v2, has_schema2 := tobj["input_schema"]; has_schema2 {
			schema = json_value_to_string(schema_v2, context.temp_allocator)
		}
		t := Mcp_Tool {
			server      = strings.clone(s.name, allocator),
			name        = strings.clone(name, allocator),
			qualified   = qualify_tool_name(s.name, name, allocator),
			description = strings.clone(desc, allocator),
			schema_json = strings.clone(schema, allocator),
		}
		append(&s.tools, t)
	}
	return ""
}

json_obj_str :: proc(obj: json.Object, key: string) -> string {
	v, ok := obj[key]
	if !ok {
		return ""
	}
	s, is := v.(json.String)
	if is {
		return string(s)
	}
	return ""
}

json_quote :: proc(s: string, allocator := context.allocator) -> string {
	// minimal JSON string escape
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '"')
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(&b, "\\\"")
		case '\\':
			strings.write_string(&b, "\\\\")
		case '\n':
			strings.write_string(&b, "\\n")
		case '\r':
			strings.write_string(&b, "\\r")
		case '\t':
			strings.write_string(&b, "\\t")
		case:
			if ch < 0x20 {
				strings.write_string(&b, fmt.tprintf("\\u%04x", ch))
			} else {
				strings.write_byte(&b, ch)
			}
		}
	}
	strings.write_byte(&b, '"')
	return strings.to_string(b)
}

json_value_to_string :: proc(v: json.Value, allocator := context.allocator) -> string {
	// re-marshal via fmt for objects/arrays using recursive builder
	return json_marshal_value(v, allocator)
}

json_marshal_value :: proc(v: json.Value, allocator := context.allocator) -> string {
	#partial switch t in v {
	case json.Null:
		return strings.clone("null", allocator)
	case json.Boolean:
		return strings.clone("true" if bool(t) else "false", allocator)
	case json.Integer:
		return fmt.aprintf("%d", i64(t), allocator = allocator)
	case json.Float:
		return fmt.aprintf("%v", f64(t), allocator = allocator)
	case json.String:
		return json_quote(string(t), allocator)
	case json.Array:
		b := strings.builder_make(allocator)
		strings.write_byte(&b, '[')
		for item, i in t {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			strings.write_string(&b, json_marshal_value(item, context.temp_allocator))
		}
		strings.write_byte(&b, ']')
		return strings.to_string(b)
	case json.Object:
		b := strings.builder_make(allocator)
		strings.write_byte(&b, '{')
		first := true
		for key, val in t {
			if !first {
				strings.write_byte(&b, ',')
			}
			first = false
			strings.write_string(&b, json_quote(key, context.temp_allocator))
			strings.write_byte(&b, ':')
			strings.write_string(&b, json_marshal_value(val, context.temp_allocator))
		}
		strings.write_byte(&b, '}')
		return strings.to_string(b)
	}
	return strings.clone("null", allocator)
}

truncate_json :: proc(v: json.Value, max: int) -> string {
	s := json_marshal_value(v, context.temp_allocator)
	if len(s) > max {
		return fmt.tprintf("%s…", s[:max])
	}
	return s
}

format_tool_result :: proc(result_json: string, allocator := context.allocator) -> string {
	val, err := json.parse(
		transmute([]byte)result_json,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if err != nil {
		return strings.clone(result_json, allocator)
	}
	obj, ok := val.(json.Object)
	if !ok {
		return strings.clone(result_json, allocator)
	}
	// isError
	if ie, has := obj["isError"]; has {
		if b, is_b := ie.(json.Boolean); is_b && bool(b) {
			// still extract text
		}
	}
	if content, has := obj["content"]; has {
		if arr, is_arr := content.(json.Array); is_arr {
			b := strings.builder_make(allocator)
			for item, i in arr {
				if i > 0 {
					strings.write_byte(&b, '\n')
				}
				if o, is_o := item.(json.Object); is_o {
					if t, tok := o["text"]; tok {
						if ts, is_s := t.(json.String); is_s {
							strings.write_string(&b, string(ts))
							continue
						}
					}
				}
				strings.write_string(&b, json_marshal_value(item, context.temp_allocator))
			}
			out := strings.to_string(b)
			if out == "" {
				return strings.clone(result_json, allocator)
			}
			// cap size
			if len(out) > 40_000 {
				return fmt.aprintf("%s\n...[truncated]", out[:40_000], allocator = allocator)
			}
			return out
		}
	}
	return strings.clone(result_json, allocator)
}
