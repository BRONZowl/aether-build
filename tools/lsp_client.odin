package tools

// lsp_client — stdio JSON-RPC Content-Length sessions (lazy per server name).
// Pattern mirrors aether/mcp/stdio.odin; Aether-only thin client.

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"

LSP_REQUEST_TIMEOUT :: 30 * time.Second
LSP_STARTUP_TIMEOUT :: 15 * time.Second

Lsp_Session :: struct {
	name:      string, // owned
	child:     os.Process,
	stdin_w:   ^os.File, // parent write → child stdin
	stdout_r:  ^os.File, // parent read ← child stdout
	next_id:   int,
	alive:     bool,
	root_uri:  string, // owned
	open_docs: map[string]bool, // uri → true; keys owned
}

g_lsp_mu:       sync.Mutex
g_lsp_sessions: map[string]^Lsp_Session // name → session; heap

// B10: last publishDiagnostics per document URI (owned keys + JSON array values).
g_lsp_diag_mu:     sync.Mutex
g_lsp_diag_by_uri: map[string]string

lsp_sessions_ensure_heap :: proc() {
	// map itself is value type; ensure we allocate sessions with heap_allocator
}

// lsp_diag_store_json replaces cache for uri with diagnostics array JSON (clones).
lsp_diag_store_json :: proc(uri: string, diagnostics_json: string) {
	if uri == "" {
		return
	}
	sync.mutex_lock(&g_lsp_diag_mu)
	defer sync.mutex_unlock(&g_lsp_diag_mu)
	if old, has := g_lsp_diag_by_uri[uri]; has {
		delete(old)
		// keep key
		g_lsp_diag_by_uri[uri] = strings.clone(diagnostics_json)
	} else {
		g_lsp_diag_by_uri[strings.clone(uri)] = strings.clone(diagnostics_json)
	}
}

// lsp_diag_get_json returns owned clone of cached diagnostics array JSON for uri, or "".
lsp_diag_get_json :: proc(uri: string, allocator := context.allocator) -> string {
	sync.mutex_lock(&g_lsp_diag_mu)
	defer sync.mutex_unlock(&g_lsp_diag_mu)
	if s, has := g_lsp_diag_by_uri[uri]; has {
		return strings.clone(s, allocator)
	}
	return ""
}

// lsp_diag_clear_all for tests / session reset.
lsp_diag_clear_all :: proc() {
	sync.mutex_lock(&g_lsp_diag_mu)
	defer sync.mutex_unlock(&g_lsp_diag_mu)
	for k, v in g_lsp_diag_by_uri {
		delete(k)
		delete(v)
	}
	clear(&g_lsp_diag_by_uri)
}

lsp_session_close :: proc(s: ^Lsp_Session) {
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
	for k in s.open_docs {
		delete(k)
	}
	delete(s.open_docs)
	delete(s.name)
	delete(s.root_uri)
}

// lsp_sessions_clear_all for tests / /new optional — kills all servers.
lsp_sessions_clear_all :: proc() {
	sync.mutex_lock(&g_lsp_mu)
	defer sync.mutex_unlock(&g_lsp_mu)
	for _, s in g_lsp_sessions {
		lsp_session_close(s)
		free(s)
	}
	clear(&g_lsp_sessions)
}

lsp_write_message :: proc(s: ^Lsp_Session, body: string) -> string /* err */ {
	if s == nil || !s.alive {
		return "lsp server not alive"
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

lsp_read_message :: proc(
	s: ^Lsp_Session,
	timeout: time.Duration,
	allocator := context.allocator,
) -> (
	string,
	string, /* err */
) {
	if s == nil || !s.alive {
		return "", "lsp server not alive"
	}
	start := time.now()
	header_buf: [dynamic]byte
	header_buf.allocator = context.temp_allocator
	buf: [1]u8
	for {
		if time.since(start) > timeout {
			return "", "timeout reading headers"
		}
		has, _ := os.pipe_has_data(s.stdout_r)
		if !has {
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
			if len(header_buf) >= 4 {
				h := string(header_buf[:])
				if strings.has_suffix(h, "\r\n\r\n") {
					break
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
			num := ""
			if i := strings.index_byte(line, ':'); i >= 0 {
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

lsp_extract_result :: proc(
	msg: string,
	want_id: int,
	allocator := context.allocator,
) -> (
	result_json: string,
	err: string,
	skip: bool,
) {
	val, perr := json.parse(transmute([]byte)msg, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil {
		return "", "", true
	}
	obj, ok := val.(json.Object)
	if !ok {
		return "", "", true
	}
	if _, has_id := obj["id"]; !has_id {
		// notification or server→client request without matching our id
		lsp_handle_notification(msg)
		return "", "", true
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
		return "", fmt.tprintf("rpc error: %s", lsp_json_encode(err_v, context.temp_allocator)), false
	}
	if res, has := obj["result"]; has {
		return lsp_json_encode(res, allocator), "", false
	}
	return strings.clone("null", allocator), "", false
}

lsp_request :: proc(
	s: ^Lsp_Session,
	method: string,
	params_json: string,
	timeout: time.Duration = LSP_REQUEST_TIMEOUT,
	allocator := context.allocator,
) -> (
	result_json: string,
	err: string,
) {
	if s == nil || !s.alive {
		return "", "lsp server not alive"
	}
	id := s.next_id
	s.next_id += 1
	body: string
	if params_json == "" {
		body = fmt.tprintf(
			`{"jsonrpc":"2.0","id":%d,"method":%s}`,
			id,
			lsp_json_quote(method, context.temp_allocator),
		)
	} else {
		body = fmt.tprintf(
			`{"jsonrpc":"2.0","id":%d,"method":%s,"params":%s}`,
			id,
			lsp_json_quote(method, context.temp_allocator),
			params_json,
		)
	}
	if werr := lsp_write_message(s, body); werr != "" {
		return "", werr
	}
	start := time.now()
	for {
		remain := timeout - time.since(start)
		if remain <= 0 {
			return "", "timeout waiting for response"
		}
		msg, rerr := lsp_read_message(s, remain, context.temp_allocator)
		if rerr != "" {
			return "", rerr
		}
		res, e, skip := lsp_extract_result(msg, id, allocator)
		if skip {
			// also try notification path when extract skipped for other reasons
			lsp_handle_notification(msg)
			continue
		}
		return res, e
	}
}

// lsp_handle_notification processes server notifications (publishDiagnostics).
lsp_handle_notification :: proc(msg: string) {
	val, perr := json.parse(transmute([]byte)msg, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil {
		return
	}
	obj, ok := val.(json.Object)
	if !ok {
		return
	}
	// only notifications (no id) or ones we care about by method
	method := ""
	if mv, has := obj["method"]; has {
		if s, is_s := mv.(json.String); is_s {
			method = string(s)
		}
	}
	if method != "textDocument/publishDiagnostics" {
		return
	}
	params, has_p := obj["params"]
	if !has_p {
		return
	}
	po, is_o := params.(json.Object)
	if !is_o {
		return
	}
	uri := ""
	if uv, has := po["uri"]; has {
		if s, is_s := uv.(json.String); is_s {
			uri = string(s)
		}
	}
	if uri == "" {
		return
	}
	diags_json := "[]"
	if dv, has := po["diagnostics"]; has {
		diags_json = lsp_json_encode(dv, context.temp_allocator)
	}
	lsp_diag_store_json(uri, diags_json)
}

// lsp_drain_notifications reads available messages for up to wait_ns, caching diagnostics.
// Used after didOpen so publishDiagnostics can arrive before we read the cache.
lsp_drain_notifications :: proc(s: ^Lsp_Session, wait: time.Duration) {
	if s == nil || !s.alive {
		return
	}
	deadline := time.now()
	// spend at most `wait` total
	for time.since(deadline) < wait {
		has, _ := os.pipe_has_data(s.stdout_r)
		if !has {
			time.sleep(20 * time.Millisecond)
			continue
		}
		// read one message with short timeout
		msg, err := lsp_read_message(s, 200 * time.Millisecond, context.temp_allocator)
		if err != "" {
			break
		}
		lsp_handle_notification(msg)
		// if it was a response we didn't expect, ignore (best-effort drain)
	}
}

lsp_notify :: proc(s: ^Lsp_Session, method: string, params_json: string) -> string {
	body := fmt.tprintf(
		`{"jsonrpc":"2.0","method":%s,"params":%s}`,
		lsp_json_quote(method, context.temp_allocator),
		params_json if params_json != "" else "{}",
	)
	return lsp_write_message(s, body)
}

// lsp_spawn_and_init starts a language server process.
lsp_spawn_and_init :: proc(
	cfg: Lsp_Server_Cfg,
	workspace: string,
	allocator := context.allocator,
) -> (
	^Lsp_Session,
	string, /* err */
) {
	cmd := make([dynamic]string, 0, 1 + len(cfg.args), context.temp_allocator)
	append(&cmd, cfg.command)
	for a in cfg.args {
		append(&cmd, a)
	}
	stdin_r, stdin_w, e1 := os.pipe()
	if e1 != nil {
		return nil, fmt.tprintf("pipe stdin: %v", e1)
	}
	stdout_r, stdout_w, e2 := os.pipe()
	if e2 != nil {
		os.close(stdin_r)
		os.close(stdin_w)
		return nil, fmt.tprintf("pipe stdout: %v", e2)
	}
	child, serr := os.process_start(
		{
			command     = cmd[:],
			working_dir = workspace if workspace != "" else ".",
			stdin       = stdin_r,
			stdout      = stdout_w,
		},
	)
	os.close(stdin_r)
	os.close(stdout_w)
	if serr != nil {
		os.close(stdin_w)
		os.close(stdout_r)
		return nil, fmt.tprintf("spawn %s: %v", cfg.command, serr)
	}

	root := workspace
	if root == "" || !os.is_absolute_path(root) {
		if cwd, cerr := os.get_working_directory(context.temp_allocator); cerr == nil {
			if root == "" || root == "." {
				root = cwd
			} else {
				// relative workspace under cwd
				j, _ := filepath.join({cwd, root}, context.temp_allocator)
				root = j
			}
		} else if root == "" {
			root = "."
		}
	}
	root_uri := path_to_file_uri(root, allocator)

	s := new(Lsp_Session, runtime.heap_allocator())
	s.name = strings.clone(cfg.name, runtime.heap_allocator())
	s.child = child
	s.stdin_w = stdin_w
	s.stdout_r = stdout_r
	s.next_id = 1
	s.alive = true
	s.root_uri = strings.clone(root_uri, runtime.heap_allocator())
	s.open_docs = make(map[string]bool, runtime.heap_allocator())

	init_params := fmt.tprintf(
		`{"processId":null,"rootUri":%s,"capabilities":{"textDocument":{"hover":{"contentFormat":["plaintext","markdown"]},"definition":{"linkSupport":false},"references":{},"documentSymbol":{"hierarchicalDocumentSymbolSupport":true},"implementation":{}},"workspace":{"symbol":{}}},"clientInfo":{"name":"aether-grok","version":"0.1.0"}%s}`,
		lsp_json_quote(root_uri, context.temp_allocator),
		fmt.tprintf(
			`,"initializationOptions":%s`,
			cfg.init_options_json,
		) if cfg.init_options_json != "" else "",
	)
	res, rerr := lsp_request(s, "initialize", init_params, LSP_STARTUP_TIMEOUT, context.temp_allocator)
	if rerr != "" {
		lsp_session_close(s)
		free(s)
		return nil, fmt.tprintf("initialize: %s", rerr)
	}
	_ = res
	_ = lsp_notify(s, "initialized", "{}")
	if cfg.settings_json != "" {
		// workspace/didChangeConfiguration
		params := fmt.tprintf(`{"settings":%s}`, cfg.settings_json)
		_ = lsp_notify(s, "workspace/didChangeConfiguration", params)
	}
	return s, ""
}

// lsp_ensure_session returns a live session for cfg (creates if needed).
lsp_ensure_session :: proc(
	cfg: Lsp_Server_Cfg,
	workspace: string,
) -> (
	^Lsp_Session,
	string, /* err */
) {
	sync.mutex_lock(&g_lsp_mu)
	defer sync.mutex_unlock(&g_lsp_mu)
	if g_lsp_sessions == nil {
		g_lsp_sessions = make(map[string]^Lsp_Session, runtime.heap_allocator())
	}
	if s, has := g_lsp_sessions[cfg.name]; has {
		if s != nil && s.alive {
			return s, ""
		}
		// dead — drop
		if s != nil {
			lsp_session_close(s)
			free(s)
		}
		delete_key(&g_lsp_sessions, cfg.name)
	}
	s, err := lsp_spawn_and_init(cfg, workspace, runtime.heap_allocator())
	if err != "" {
		return nil, err
	}
	g_lsp_sessions[strings.clone(cfg.name, runtime.heap_allocator())] = s
	return s, ""
}

// lsp_did_open_if_needed sends textDocument/didOpen once per uri.
lsp_did_open_if_needed :: proc(
	s: ^Lsp_Session,
	abs_path: string,
	lang_id: string,
) -> string /* err */ {
	uri := path_to_file_uri(abs_path, context.temp_allocator)
	if s.open_docs[uri] {
		return ""
	}
	data, rferr := os.read_entire_file(abs_path, context.temp_allocator)
	if rferr != nil {
		return fmt.tprintf("cannot read file %s", abs_path)
	}
	text := string(data)
	params := fmt.tprintf(
		`{"textDocument":{"uri":%s,"languageId":%s,"version":1,"text":%s}}`,
		lsp_json_quote(uri, context.temp_allocator),
		lsp_json_quote(lang_id, context.temp_allocator),
		lsp_json_quote(text, context.temp_allocator),
	)
	if err := lsp_notify(s, "textDocument/didOpen", params); err != "" {
		return err
	}
	s.open_docs[strings.clone(uri, runtime.heap_allocator())] = true
	return ""
}
