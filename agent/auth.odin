package agent

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "aether:core"

Auth_Kind :: enum {
	Session, // OIDC / login session → cli-chat-proxy headers
	Api_Key, // env or xai::api_key → api.x.ai (usually)
}

Credentials :: struct {
	kind:            Auth_Kind,
	bearer:          string, // allocated
	base_url:        string, // allocated
	user_id:         string,
	email:           string,
	scope:           string,
	refresh_token:   string,
	expires_at:      string,
	oidc_issuer:     string,
	oidc_client_id:  string,
	principal_type:  string,
	principal_id:    string,
	auth_path:       string,
}

destroy_credentials :: proc(c: ^Credentials) {
	delete(c.bearer)
	delete(c.base_url)
	delete(c.user_id)
	delete(c.email)
	delete(c.scope)
	delete(c.refresh_token)
	delete(c.expires_at)
	delete(c.oidc_issuer)
	delete(c.oidc_client_id)
	delete(c.principal_type)
	delete(c.principal_id)
	delete(c.auth_path)
}

// resolve_credentials implements the plan's resolution order and may refresh OIDC.
resolve_credentials :: proc(allocator := context.allocator) -> (Credentials, string /* error */) {
	// 1) Env API key override (CI / escape hatch)
	if key := os.get_env("XAI_API_KEY", context.temp_allocator); key != "" {
		return env_api_key_creds(key, allocator), ""
	}
	if key := os.get_env("GROK_CODE_XAI_API_KEY", context.temp_allocator); key != "" {
		return env_api_key_creds(key, allocator), ""
	}

	// 2) GROK_AUTH inline JSON
	if inline := os.get_env("GROK_AUTH", context.temp_allocator); inline != "" {
		entries, ok := parse_auth_json_entries(inline, context.temp_allocator)
		if ok && len(entries) > 0 {
			idx := pick_preferred_entry(entries)
			if idx >= 0 {
				creds := credentials_from_entry(entries[idx], "", allocator)
				return ensure_fresh(creds)
			}
		}
	}

	// 3) auth.json on disk
	path := core.auth_json_path(context.temp_allocator)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {}, fmt.tprintf("Not signed in. %s", auth_sign_in_hint())
	}
	entries, ok := parse_auth_json_entries(string(data), context.temp_allocator)
	if !ok || len(entries) == 0 {
		return {}, fmt.tprintf(
			"Not signed in (auth.json empty or unreadable). %s",
			auth_sign_in_hint(),
		)
	}
	idx := pick_preferred_entry(entries)
	if idx < 0 {
		return {}, fmt.tprintf("Not signed in. %s", auth_sign_in_hint())
	}
	creds := credentials_from_entry(entries[idx], path, allocator)
	return ensure_fresh(creds)
}

env_api_key_creds :: proc(key: string, allocator := context.allocator) -> Credentials {
	return Credentials {
		kind     = .Api_Key,
		bearer   = strings.clone(key, allocator),
		base_url = core.api_key_base_url(allocator),
	}
}

credentials_from_entry :: proc(
	e: Auth_Entry,
	auth_path: string,
	allocator := context.allocator,
) -> Credentials {
	kind := Auth_Kind.Session
	base: string
	if e.auth_mode == .Api_Key || e.scope == API_KEY_SCOPE {
		kind = .Api_Key
		base = core.api_key_base_url(allocator)
	} else {
		base = core.session_base_url(allocator)
	}
	return Credentials {
		kind             = kind,
		bearer           = strings.clone(e.key, allocator),
		base_url         = base,
		user_id          = strings.clone(e.user_id, allocator),
		email            = strings.clone(e.email, allocator),
		scope            = strings.clone(e.scope, allocator),
		refresh_token    = strings.clone(e.refresh_token, allocator),
		expires_at       = strings.clone(e.expires_at, allocator),
		oidc_issuer      = strings.clone(e.oidc_issuer, allocator),
		oidc_client_id   = strings.clone(e.oidc_client_id, allocator),
		principal_type   = strings.clone(e.principal_type, allocator),
		principal_id     = strings.clone(e.principal_id, allocator),
		auth_path        = strings.clone(auth_path, allocator) if auth_path != "" else "",
	}
}

ensure_fresh :: proc(creds: Credentials) -> (Credentials, string) {
	c := creds
	if c.kind != .Session {
		return c, ""
	}
	view := Auth_Entry {
		key            = c.bearer,
		refresh_token  = c.refresh_token,
		expires_at     = c.expires_at,
		oidc_issuer    = c.oidc_issuer,
		oidc_client_id = c.oidc_client_id,
	}
	if !entry_needs_refresh(view) {
		return c, ""
	}
	if err := refresh_oidc(&c); err != "" {
		destroy_credentials(&c)
		return {}, err
	}
	return c, ""
}

// build_auth_headers returns allocated header strings for an inference request.
build_auth_headers :: proc(c: Credentials, allocator := context.allocator) -> []string {
	hs := make([dynamic]string, 0, 10, allocator)
	append(&hs, fmt.aprintf("Authorization: Bearer %s", c.bearer, allocator = allocator))
	// Version gate at cli-chat-proxy (and for consistency on all backends).
	append(
		&hs,
		fmt.aprintf("x-grok-client-version: %s", core.PROXY_CLIENT_VERSION, allocator = allocator),
	)
	append(&hs, strings.clone("x-grok-client-identifier: aether-grok", allocator))
	if c.kind == .Session {
		append(&hs, strings.clone("X-XAI-Token-Auth: xai-grok-cli", allocator))
		if strings.contains(c.base_url, "cli-chat-proxy") || strings.contains(c.base_url, "grok.com") {
			append(&hs, strings.clone("x-authenticateresponse: authenticate-response", allocator))
			append(&hs, strings.clone("x-grok-client-mode: headless", allocator))
		}
	}
	if c.user_id != "" {
		append(&hs, fmt.aprintf("x-grok-user-id: %s", c.user_id, allocator = allocator))
	}
	return hs[:]
}

destroy_headers :: proc(headers: []string) {
	for h in headers {
		delete(h)
	}
	delete(headers)
}

refresh_oidc :: proc(c: ^Credentials) -> string /* error */ {
	if c.refresh_token == "" || c.oidc_issuer == "" || c.oidc_client_id == "" {
		return fmt.tprintf("session expired; %s", auth_sign_in_hint())
	}
	issuer := strings.trim_right(c.oidc_issuer, "/")
	disc_url := fmt.tprintf("%s/.well-known/openid-configuration", issuer)
	disc_resp, herr := http_get(disc_url)
	if herr != .None {
		return fmt.tprintf("OIDC discovery failed: %s", http_error_string(herr))
	}
	defer delete(disc_resp.body)
	if disc_resp.status != 200 {
		return fmt.tprintf("OIDC discovery HTTP %d", disc_resp.status)
	}

	token_endpoint, ok := json_field_string(disc_resp.body, "token_endpoint")
	if !ok || token_endpoint == "" {
		return "OIDC discovery missing token_endpoint"
	}

	pairs := make([dynamic][2]string, 0, 6, context.temp_allocator)
	append(&pairs, [2]string{"grant_type", "refresh_token"})
	append(&pairs, [2]string{"refresh_token", c.refresh_token})
	append(&pairs, [2]string{"client_id", c.oidc_client_id})
	if c.principal_type != "" {
		append(&pairs, [2]string{"principal_type", c.principal_type})
	}
	if c.principal_id != "" {
		append(&pairs, [2]string{"principal_id", c.principal_id})
	}
	form := form_encode(pairs[:], context.temp_allocator)

	tok_resp, terr := http_post_form(token_endpoint, nil, form)
	if terr != .None {
		return fmt.tprintf("OIDC refresh failed: %s", http_error_string(terr))
	}
	defer delete(tok_resp.body)
	if tok_resp.status != 200 {
		return fmt.tprintf(
			"OIDC refresh HTTP %d — %s body: %s",
			tok_resp.status,
			auth_sign_in_hint(),
			truncate(tok_resp.body, 200),
		)
	}

	access, aok := json_field_string(tok_resp.body, "access_token")
	if !aok || access == "" {
		return "OIDC refresh response missing access_token"
	}
	delete(c.bearer)
	c.bearer = strings.clone(access)

	if rt, rok := json_field_string(tok_resp.body, "refresh_token"); rok && rt != "" {
		delete(c.refresh_token)
		c.refresh_token = strings.clone(rt)
	}

	expires_at := ""
	if exp_in, eok := json_field_int(tok_resp.body, "expires_in"); eok && exp_in > 0 {
		exp_time := time.time_add(time.now(), time.Duration(exp_in) * time.Second)
		expires_at = format_rfc3339_utc(exp_time, context.temp_allocator)
		delete(c.expires_at)
		c.expires_at = strings.clone(expires_at)
	}

	if c.auth_path != "" && c.scope != "" {
		_ = update_auth_json_entry(c.auth_path, c.scope, c.bearer, c.refresh_token, expires_at)
	}
	return ""
}

json_field_string :: proc(body: string, key: string) -> (string, bool) {
	val, err := json.parse(
		transmute([]byte)body,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if err != nil {
		return "", false
	}
	obj, ok := val.(json.Object)
	if !ok {
		return "", false
	}
	return json_str(obj, key)
}

json_field_int :: proc(body: string, key: string) -> (i64, bool) {
	val, err := json.parse(
		transmute([]byte)body,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if err != nil {
		return 0, false
	}
	obj, ok := val.(json.Object)
	if !ok {
		return 0, false
	}
	v, found := obj[key]
	if !found {
		return 0, false
	}
	#partial switch n in v {
	case json.Integer:
		return i64(n), true
	case json.Float:
		return i64(n), true
	}
	return 0, false
}

format_rfc3339_utc :: proc(t: time.Time, allocator := context.allocator) -> string {
	dt, ok := time.time_to_datetime(t)
	if !ok {
		return strings.clone("", allocator)
	}
	return fmt.aprintf(
		"%04d-%02d-%02dT%02d:%02d:%02dZ",
		dt.year,
		int(dt.month),
		dt.day,
		dt.hour,
		dt.minute,
		dt.second,
		allocator = allocator,
	)
}

truncate :: proc(s: string, n: int) -> string {
	if len(s) <= n {
		return s
	}
	return s[:n]
}
