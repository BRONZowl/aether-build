// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"
import "core:time/datetime"
import "aether:core"

API_KEY_SCOPE :: "xai::api_key"
EARLY_REFRESH_SECS :: i64(300) // 5 minutes

Auth_Mode :: enum {
	Unknown,
	Oidc,
	Api_Key,
	Web_Login,
	External,
}

Auth_Entry :: struct {
	scope:           string, // map key in auth.json
	key:             string,
	auth_mode:       Auth_Mode,
	user_id:         string,
	email:           string,
	refresh_token:   string,
	expires_at:      string, // RFC3339 from file
	oidc_issuer:     string,
	oidc_client_id:  string,
	principal_type:  string,
	principal_id:    string,
}

// parse_auth_json_entries parses ~/.grok/auth.json into allocated entries.
// Caller must destroy_auth_entries.
parse_auth_json_entries :: proc(data: string, allocator := context.allocator) -> ([]Auth_Entry, bool) {
	val, err := json.parse(transmute([]byte)data, json.DEFAULT_SPECIFICATION, false, allocator)
	if err != nil {
		return nil, false
	}
	// Don't destroy val until we've cloned all strings out — we'll destroy after cloning.
	defer json.destroy_value(val, allocator)

	obj, is_root := val.(json.Object)
	if !is_root {
		return nil, false
	}

	entries := make([dynamic]Auth_Entry, 0, len(obj), allocator)
	for scope, v in obj {
		entry_obj, is_obj := v.(json.Object)
		if !is_obj {
			continue
		}
		e := Auth_Entry {
			scope = strings.clone(scope, allocator),
		}
		if s, has := json_str(entry_obj, "key"); has {
			e.key = strings.clone(s, allocator)
		}
		if s, has := json_str(entry_obj, "auth_mode"); has {
			e.auth_mode = parse_auth_mode(s)
		}
		if s, has := json_str(entry_obj, "user_id"); has {
			e.user_id = strings.clone(s, allocator)
		}
		if s, has := json_str(entry_obj, "email"); has {
			e.email = strings.clone(s, allocator)
		}
		if s, has := json_str(entry_obj, "refresh_token"); has {
			e.refresh_token = strings.clone(s, allocator)
		}
		if s, has := json_str(entry_obj, "expires_at"); has {
			e.expires_at = strings.clone(s, allocator)
		}
		if s, has := json_str(entry_obj, "oidc_issuer"); has {
			e.oidc_issuer = strings.clone(s, allocator)
		}
		if s, has := json_str(entry_obj, "oidc_client_id"); has {
			e.oidc_client_id = strings.clone(s, allocator)
		}
		if s, has := json_str(entry_obj, "principal_type"); has {
			e.principal_type = strings.clone(s, allocator)
		}
		if s, has := json_str(entry_obj, "principal_id"); has {
			e.principal_id = strings.clone(s, allocator)
		}
		if e.key != "" {
			append(&entries, e)
		} else {
			destroy_auth_entry(&e)
		}
	}
	return entries[:], true
}

destroy_auth_entry :: proc(e: ^Auth_Entry) {
	delete(e.scope)
	delete(e.key)
	delete(e.user_id)
	delete(e.email)
	delete(e.refresh_token)
	delete(e.expires_at)
	delete(e.oidc_issuer)
	delete(e.oidc_client_id)
	delete(e.principal_type)
	delete(e.principal_id)
}

destroy_auth_entries :: proc(entries: []Auth_Entry) {
	for &e in entries {
		destroy_auth_entry(&e)
	}
	delete(entries)
}

parse_auth_mode :: proc(s: string) -> Auth_Mode {
	switch s {
	case "oidc", "Oidc":
		return .Oidc
	case "api_key", "ApiKey":
		return .Api_Key
	case "web_login", "grok", "WebLogin":
		return .Web_Login
	case "external", "External":
		return .External
	}
	return .Unknown
}

json_str :: proc(obj: json.Object, key: string) -> (string, bool) {
	v, ok := obj[key]
	if !ok {
		return "", false
	}
	s, is_str := v.(json.String)
	if !is_str {
		return "", false
	}
	return string(s), true
}

// pick_preferred_entry prefers OIDC/session entries, then xai::api_key.
// Returns index into entries, or -1.
pick_preferred_entry :: proc(entries: []Auth_Entry) -> int {
	// 1) refreshable OIDC
	for e, i in entries {
		if e.auth_mode == .Oidc && e.key != "" {
			return i
		}
	}
	// 2) web_login legacy session
	for e, i in entries {
		if e.auth_mode == .Web_Login && e.key != "" {
			return i
		}
	}
	// 3) any non-api-key with key
	for e, i in entries {
		if e.auth_mode != .Api_Key && e.scope != API_KEY_SCOPE && e.key != "" {
			return i
		}
	}
	// 4) api_key scope
	for e, i in entries {
		if e.scope == API_KEY_SCOPE || e.auth_mode == .Api_Key {
			return i
		}
	}
	if len(entries) > 0 {
		return 0
	}
	return -1
}

// entry_needs_refresh is true when expires_at is within EARLY_REFRESH_SECS or invalid/missing with refresh_token.
entry_needs_refresh :: proc(e: Auth_Entry) -> bool {
	if e.refresh_token == "" || e.oidc_issuer == "" || e.oidc_client_id == "" {
		return false
	}
	if e.expires_at == "" {
		return true
	}
	exp, ok := parse_rfc3339(e.expires_at)
	if !ok {
		return true
	}
	now := time.now()
	// refresh if exp - now <= 5 minutes
	diff := time.diff(now, exp)
	return diff <= time.Duration(EARLY_REFRESH_SECS) * time.Second
}

// parse_rfc3339 parses timestamps like 2026-07-16T02:03:44.047057898Z
parse_rfc3339 :: proc(s: string) -> (time.Time, bool) {
	// Trim fractional seconds and Z/offset for a simple parse.
	t := strings.trim_space(s)
	if len(t) < 19 {
		return {}, false
	}
	// YYYY-MM-DDTHH:MM:SS
	year, ok1 := parse_int_n(t[0:4])
	month, ok2 := parse_int_n(t[5:7])
	day, ok3 := parse_int_n(t[8:10])
	hour, ok4 := parse_int_n(t[11:13])
	minute, ok5 := parse_int_n(t[14:16])
	second, ok6 := parse_int_n(t[17:19])
	if !(ok1 && ok2 && ok3 && ok4 && ok5 && ok6) {
		return {}, false
	}
	dt, err := datetime.components_to_datetime(year, month, day, hour, minute, second, 0)
	if err != nil {
		return {}, false
	}
	tm, ok := time.datetime_to_time(dt)
	return tm, ok
}

parse_int_n :: proc(s: string) -> (int, bool) {
	n := 0
	if len(s) == 0 {
		return 0, false
	}
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch < '0' || ch > '9' {
			return 0, false
		}
		n = n * 10 + int(ch - '0')
	}
	return n, true
}

// write_auth_session_entry creates or replaces a full OIDC session entry in auth.json.
// Used by device-code login (M7). scope typically "{issuer}::{client_id}".
write_auth_session_entry :: proc(
	path: string,
	scope: string,
	access_token: string,
	refresh_token: string,
	expires_at: string,
	oidc_issuer: string,
	oidc_client_id: string,
	user_id: string = "",
	email: string = "",
) -> string /* err */ {
	if path == "" || scope == "" || access_token == "" {
		return "path, scope, and access_token required"
	}
	// ensure parent
	parent := filepath.dir(path)
	_ = core.ensure_dir(parent)

	obj: json.Object
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil && len(data) > 0 {
		val, perr := json.parse(data, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
		if perr == nil {
			if o, ok := val.(json.Object); ok {
				obj = o
			}
		}
	}
	if obj == nil {
		obj = make(json.Object, context.temp_allocator)
	}

	entry := make(json.Object, context.temp_allocator)
	// preserve unknown fields if entry exists
	if old_v, has := obj[scope]; has {
		if old_e, is_e := old_v.(json.Object); is_e {
			for k, v in old_e {
				entry[k] = v
			}
		}
	}
	entry[strings.clone("key", context.temp_allocator)] = json.String(
		strings.clone(access_token, context.temp_allocator),
	)
	entry[strings.clone("auth_mode", context.temp_allocator)] = json.String(
		strings.clone("oidc", context.temp_allocator),
	)
	if refresh_token != "" {
		entry[strings.clone("refresh_token", context.temp_allocator)] = json.String(
			strings.clone(refresh_token, context.temp_allocator),
		)
	}
	if expires_at != "" {
		entry[strings.clone("expires_at", context.temp_allocator)] = json.String(
			strings.clone(expires_at, context.temp_allocator),
		)
	}
	if oidc_issuer != "" {
		entry[strings.clone("oidc_issuer", context.temp_allocator)] = json.String(
			strings.clone(oidc_issuer, context.temp_allocator),
		)
	}
	if oidc_client_id != "" {
		entry[strings.clone("oidc_client_id", context.temp_allocator)] = json.String(
			strings.clone(oidc_client_id, context.temp_allocator),
		)
	}
	if user_id != "" {
		entry[strings.clone("user_id", context.temp_allocator)] = json.String(
			strings.clone(user_id, context.temp_allocator),
		)
	}
	if email != "" {
		entry[strings.clone("email", context.temp_allocator)] = json.String(
			strings.clone(email, context.temp_allocator),
		)
	}

	obj[strings.clone(scope, context.temp_allocator)] = entry

	out, merr := json.marshal(obj, {}, context.temp_allocator)
	if merr != nil {
		return "marshal auth.json failed"
	}
	tmp := fmt.tprintf("%s.tmp.%d", path, os.get_pid())
	if werr := os.write_entire_file(tmp, out); werr != nil {
		return "write auth.json failed"
	}
	_ = os.chmod(tmp, os.perm(0o600))
	if rerr := os.rename(tmp, path); rerr != nil {
		_ = os.remove(tmp)
		return "rename auth.json failed"
	}
	return ""
}

// update_auth_json_entry rewrites one scope's key/refresh/expires in the file.
// Atomic write via temp file + rename.
update_auth_json_entry :: proc(
	path: string,
	scope: string,
	new_key: string,
	new_refresh: string, // empty = leave unchanged
	new_expires_at: string,
) -> bool {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return false
	}
	val, perr := json.parse(data, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil {
		return false
	}
	// We'll mutate; destroy at end of temp alloc is fine for process.

	obj, ok := val.(json.Object)
	if !ok {
		return false
	}
	entry_val, found := obj[scope]
	if !found {
		return false
	}
	entry_obj, is_obj := entry_val.(json.Object)
	if !is_obj {
		return false
	}

	// Mutate map values — Object is map[string]Value; strings need to be owned by the object.
	// For temp_allocator this is OK for marshal lifetime.
	entry_obj["key"] = json.String(strings.clone(new_key, context.temp_allocator))
	if new_refresh != "" {
		entry_obj["refresh_token"] = json.String(strings.clone(new_refresh, context.temp_allocator))
	}
	if new_expires_at != "" {
		entry_obj["expires_at"] = json.String(strings.clone(new_expires_at, context.temp_allocator))
	}
	obj[scope] = entry_obj
	val = obj

	out, merr := json.marshal(val, {}, context.temp_allocator)
	if merr != nil {
		return false
	}

	tmp := fmt.tprintf("%s.tmp.%d", path, os.get_pid())
	if werr := os.write_entire_file(tmp, out); werr != nil {
		return false
	}
	// rename over original
	if rerr := os.rename(tmp, path); rerr != nil {
		_ = os.remove(tmp)
		return false
	}
	return true
}

token_suffix :: proc(token: string) -> string {
	if len(token) <= 8 {
		return "****"
	}
	return token[len(token) - 8:]
}
