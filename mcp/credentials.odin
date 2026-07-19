package mcp

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "aether:core"

// expand_env_in_string replaces ${NAME} and $NAME with environment values.
// Unset vars become empty. Does not expand $$ → $ (no escape).
expand_env_in_string :: proc(s: string, allocator := context.allocator) -> string {
	if s == "" || !strings.contains(s, "$") {
		return strings.clone(s, allocator)
	}
	b := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		if s[i] != '$' {
			strings.write_byte(&b, s[i])
			i += 1
			continue
		}
		// ${NAME}
		if i + 1 < len(s) && s[i + 1] == '{' {
			end := strings.index_byte(s[i + 2:], '}')
			if end >= 0 {
				name := s[i + 2:i + 2 + end]
				val := os.get_env(name, context.temp_allocator)
				strings.write_string(&b, val)
				i = i + 2 + end + 1
				continue
			}
		}
		// $NAME (alnum + _)
		if i + 1 < len(s) && is_env_name_start(s[i + 1]) {
			j := i + 1
			for j < len(s) && is_env_name_char(s[j]) {
				j += 1
			}
			name := s[i + 1:j]
			val := os.get_env(name, context.temp_allocator)
			strings.write_string(&b, val)
			i = j
			continue
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	return strings.to_string(b)
}

is_env_name_start :: proc(ch: u8) -> bool {
	return (ch >= 'A' && ch <= 'Z') || (ch >= 'a' && ch <= 'z') || ch == '_'
}

is_env_name_char :: proc(ch: u8) -> bool {
	return is_env_name_start(ch) || (ch >= '0' && ch <= '9')
}

// credential_key matches Grok: "{server_name}:{server_url}"
credential_key :: proc(server_name, server_url: string, allocator := context.allocator) -> string {
	return fmt.aprintf("%s:%s", server_name, server_url, allocator = allocator)
}

// mcp_credentials_path: $GROK_HOME/mcp_credentials.json
mcp_credentials_path :: proc(allocator := context.allocator) -> string {
	home := core.grok_home(context.temp_allocator)
	joined, _ := filepath.join({home, "mcp_credentials.json"}, allocator)
	return joined
}

// lookup_mcp_access_token loads store and returns access_token for name+url.
// ok false if missing or empty. Does not print secrets.
lookup_mcp_access_token :: proc(
	server_name, server_url: string,
	allocator := context.allocator,
) -> (token: string, ok: bool) {
	path := mcp_credentials_path(context.temp_allocator)
	return lookup_mcp_access_token_from_file(path, server_name, server_url, allocator)
}

lookup_mcp_access_token_from_file :: proc(
	path: string,
	server_name, server_url: string,
	allocator := context.allocator,
) -> (token: string, ok: bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return "", false
	}
	return lookup_mcp_access_token_from_json(string(data), server_name, server_url, allocator)
}

// lookup_mcp_access_token_from_json parses Grok-compatible mcp_credentials.json.
lookup_mcp_access_token_from_json :: proc(
	raw: string,
	server_name, server_url: string,
	allocator := context.allocator,
) -> (token: string, ok: bool) {
	key := credential_key(server_name, server_url, context.temp_allocator)
	val, perr := json.parse(transmute([]byte)raw, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil {
		return "", false
	}
	obj, is_obj := val.(json.Object)
	if !is_obj {
		return "", false
	}
	entry_v, has := obj[key]
	if !has {
		// try alternate: strip trailing slash on url
		if strings.has_suffix(server_url, "/") && len(server_url) > 1 {
			alt := credential_key(server_name, server_url[:len(server_url) - 1], context.temp_allocator)
			entry_v, has = obj[alt]
		}
		if !has && !strings.has_suffix(server_url, "/") {
			alt := credential_key(server_name, fmt.tprintf("%s/", server_url), context.temp_allocator)
			entry_v, has = obj[alt]
		}
		if !has {
			return "", false
		}
	}
	entry, eobj := entry_v.(json.Object)
	if !eobj {
		return "", false
	}
	tr_v, has_tr := entry["token_response"]
	if !has_tr {
		return "", false
	}
	// null or non-object token_response
	tr, is_tr := tr_v.(json.Object)
	if !is_tr {
		return "", false
	}
	at, has_at := tr["access_token"]
	if !has_at {
		return "", false
	}
	at_s, is_str := at.(json.String)
	if !is_str || at_s == "" {
		return "", false
	}
	// optional soft expiry check — still return token if expired (server may reject)
	_ = time.now()
	return strings.clone(string(at_s), allocator), true
}

// has_authorization_header true if any header name is Authorization (case-insensitive).
has_authorization_header :: proc(headers: [][2]string) -> bool {
	for h in headers {
		if strings.equal_fold(h[0], "Authorization") && h[1] != "" {
			return true
		}
	}
	return false
}

// resolve_http_auth_headers builds owned headers for HTTP MCP connect.
// Order: expanded config headers → bearer_token_env_var → mcp_credentials.json.
// Returns headers + auth source for status.
resolve_http_auth_headers :: proc(
	cfg: Mcp_Server_Config,
	allocator := context.allocator,
) -> (headers: [dynamic][2]string, source: Mcp_Auth_Source) {
	headers = make([dynamic][2]string, 0, len(cfg.headers) + 1, allocator)
	source = .None

	for h in cfg.headers {
		key := strings.clone(h[0], allocator)
		val := expand_env_in_string(h[1], allocator)
		append(&headers, [2]string{key, val})
	}
	if has_authorization_header(headers[:]) {
		source = .Headers
		return headers, source
	}

	// bearer_token_env_var
	if cfg.bearer_token_env_var != "" {
		tok := os.get_env(cfg.bearer_token_env_var, context.temp_allocator)
		if tok != "" {
			append(
				&headers,
				[2]string {
					strings.clone("Authorization", allocator),
					fmt.aprintf("Bearer %s", tok, allocator = allocator),
				},
			)
			source = .Env
			return headers, source
		}
	}

	// mcp_credentials.json
	if cfg.url != "" {
		if tok, ok := lookup_mcp_access_token(cfg.name, cfg.url, context.temp_allocator); ok {
			append(
				&headers,
				[2]string {
					strings.clone("Authorization", allocator),
					fmt.aprintf("Bearer %s", tok, allocator = allocator),
				},
			)
			source = .Credentials
			return headers, source
		}
	}
	return headers, source
}

auth_source_string :: proc(s: Mcp_Auth_Source) -> string {
	switch s {
	case .None:
		return "none"
	case .Headers:
		return "headers"
	case .Env:
		return "env"
	case .Credentials:
		return "credentials"
	}
	return "none"
}

// --- credentials write (A3.1) ---

// json_escape_str for embedding in JSON string values.
json_escape_str :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"', '\\':
			strings.write_byte(&b, '\\')
			strings.write_byte(&b, ch)
		case '\n':
			strings.write_string(&b, "\\n")
		case '\r':
			strings.write_string(&b, "\\r")
		case '\t':
			strings.write_string(&b, "\\t")
		case:
			if ch < 0x20 {
				continue
			}
			strings.write_byte(&b, ch)
		}
	}
	return strings.to_string(b)
}

// load_credentials_object reads path into a root object; missing → empty object.
// Caller owns the parse tree on temp_allocator; returns false on parse error of non-empty file.
load_credentials_root :: proc(
	path: string,
) -> (
	obj: json.Object,
	ok: bool,
) {
	if path == "" || !os.exists(path) {
		return make(json.Object, context.temp_allocator), true
	}
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return make(json.Object, context.temp_allocator), true
	}
	if len(strings.trim_space(string(data))) == 0 {
		return make(json.Object, context.temp_allocator), true
	}
	val, perr := json.parse(
		data,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if perr != nil {
		return nil, false
	}
	o, is_obj := val.(json.Object)
	if !is_obj {
		return nil, false
	}
	return o, true
}

// write_credentials_root marshals obj and atomically writes path (tmp + rename).
write_credentials_root :: proc(path: string, obj: json.Object) -> string /* err */ {
	if path == "" {
		return "empty credentials path"
	}
	parent := filepath.dir(path)
	if parent != "" && !os.exists(parent) {
		if os.make_directory_all(parent) != nil {
			return fmt.tprintf("cannot create dir %s", parent)
		}
	}
	// Reuse package json_marshal_value from stdio.odin
	body := json_marshal_value(obj, context.temp_allocator)
	if body == "" {
		body = "{}"
	}
	// Pretty-ish: ensure trailing newline
	if !strings.has_suffix(body, "\n") {
		body = fmt.tprintf("%s\n", body)
	}
	tmp := fmt.tprintf("%s.tmp.%d", path, os.get_pid())
	if werr := os.write_entire_file(tmp, transmute([]byte)body); werr != nil {
		return fmt.tprintf("write failed: %v", werr)
	}
	// Best-effort restrictive mode (ignore errors)
	_ = os.chmod(tmp, os.perm(0o600))
	if rerr := os.rename(tmp, path); rerr != nil {
		_ = os.remove(tmp)
		return fmt.tprintf("rename failed: %v", rerr)
	}
	return ""
}

// upsert_mcp_credential_at merges token_response for name+url into path.
// refresh_token optional; expires_in 0 omits or writes 0.
upsert_mcp_credential_at :: proc(
	path: string,
	server_name, server_url, access_token: string,
	refresh_token: string = "",
	expires_in: int = 0,
) -> string /* err */ {
	if server_name == "" || server_url == "" {
		return "server name and url required"
	}
	if strings.trim_space(access_token) == "" {
		return "access_token required"
	}
	obj, ok := load_credentials_root(path)
	if !ok {
		return "invalid credentials JSON (not an object)"
	}
	key := credential_key(server_name, server_url, context.temp_allocator)

	// Build token_response object
	tr := make(json.Object, context.temp_allocator)
	tr[strings.clone("access_token", context.temp_allocator)] = json.String(
		strings.clone(access_token, context.temp_allocator),
	)
	tr[strings.clone("token_type", context.temp_allocator)] = json.String(
		strings.clone("bearer", context.temp_allocator),
	)
	if refresh_token != "" {
		tr[strings.clone("refresh_token", context.temp_allocator)] = json.String(
			strings.clone(refresh_token, context.temp_allocator),
		)
	}
	if expires_in > 0 {
		tr[strings.clone("expires_in", context.temp_allocator)] = json.Integer(i64(expires_in))
	}

	entry := make(json.Object, context.temp_allocator)
	// Preserve existing entry fields if present
	if old_v, has := obj[key]; has {
		if old_e, is_e := old_v.(json.Object); is_e {
			for k, v in old_e {
				if k == "token_response" {
					continue
				}
				entry[k] = v
			}
		}
	}
	entry[strings.clone("token_response", context.temp_allocator)] = tr
	// updated_at unix seconds
	now := time.to_unix_seconds(time.now())
	entry[strings.clone("token_received_at", context.temp_allocator)] = json.Integer(i64(now))

	obj[strings.clone(key, context.temp_allocator)] = entry
	return write_credentials_root(path, obj)
}

// upsert_mcp_credential writes to default mcp_credentials_path().
upsert_mcp_credential :: proc(
	server_name, server_url, access_token: string,
	refresh_token: string = "",
	expires_in: int = 0,
) -> string /* err */ {
	return upsert_mcp_credential_at(
		mcp_credentials_path(context.temp_allocator),
		server_name,
		server_url,
		access_token,
		refresh_token,
		expires_in,
	)
}

// delete_mcp_credential_at removes key for name+url.
delete_mcp_credential_at :: proc(path, server_name, server_url: string) -> string /* err */ {
	obj, ok := load_credentials_root(path)
	if !ok {
		return "invalid credentials JSON"
	}
	key := credential_key(server_name, server_url, context.temp_allocator)
	if _, has := obj[key]; !has {
		return "" // already gone
	}
	delete_key(&obj, key)
	return write_credentials_root(path, obj)
}

delete_mcp_credential :: proc(server_name, server_url: string) -> string /* err */ {
	return delete_mcp_credential_at(
		mcp_credentials_path(context.temp_allocator),
		server_name,
		server_url,
	)
}

// mcp_credential_has_token reports whether a non-empty access_token exists (no secret returned).
mcp_credential_has_token :: proc(server_name, server_url: string) -> bool {
	_, ok := lookup_mcp_access_token(server_name, server_url, context.temp_allocator)
	return ok
}

// find_mcp_server_url_in_configs looks up url for name in configs.
find_mcp_server_url_in_configs :: proc(cfgs: []Mcp_Server_Config, name: string) -> (url: string, ok: bool) {
	for c in cfgs {
		if c.name == name && c.url != "" {
			return c.url, true
		}
	}
	return "", false
}
