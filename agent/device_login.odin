// Package agent — in-process device-code login (M7 / R0-B).
// RFC 8628 against xAI OAuth2 (https://auth.x.ai), Grok-compatible auth.json write.
// No Rust `grok` binary required. Host bridge remains as --host fallback.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:encoding/base64"
import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"
import "aether:core"

// Defaults match xai-grok-shell auth config (OAuth2 provider).
DEFAULT_OAUTH2_ISSUER :: "https://auth.x.ai"
// Public grok-cli OAuth2 client id (same as Rust grok-build default).
DEFAULT_OAUTH2_CLIENT_ID :: "b1a00492-073a-47ea-816f-4c329264a828"
DEFAULT_OAUTH2_SCOPES :: "openid profile email offline_access grok-cli:access api:access conversations:read conversations:write"
DEVICE_GRANT_TYPE :: "urn:ietf:params:oauth:grant-type:device_code"
DEFAULT_DEVICE_POLL_SECS :: 5
DEVICE_SLOW_DOWN_SECS :: 5
MIN_DEVICE_EXPIRY_SECS :: i64(600)

Device_Code :: struct {
	verification_uri:          string, // owned
	verification_uri_complete: string, // owned; may be empty
	user_code:                 string, // owned
	device_code:               string, // owned
	interval_s:                int,
	expires_in:                i64,
}

destroy_device_code :: proc(d: ^Device_Code) {
	delete(d.verification_uri)
	delete(d.verification_uri_complete)
	delete(d.user_code)
	delete(d.device_code)
}

// oauth2_issuer_from_env: AETHER_OAUTH2_ISSUER / GROK_OAUTH2_ISSUER or default.
oauth2_issuer_from_env :: proc(allocator := context.allocator) -> string {
	if v := strings.trim_space(os.get_env("AETHER_OAUTH2_ISSUER", context.temp_allocator)); v != "" {
		return strings.clone(strings.trim_right(v, "/"), allocator)
	}
	if v := strings.trim_space(os.get_env("GROK_OAUTH2_ISSUER", context.temp_allocator)); v != "" {
		return strings.clone(strings.trim_right(v, "/"), allocator)
	}
	return strings.clone(DEFAULT_OAUTH2_ISSUER, allocator)
}

oauth2_client_id_from_env :: proc(allocator := context.allocator) -> string {
	if v := strings.trim_space(os.get_env("AETHER_OAUTH2_CLIENT_ID", context.temp_allocator)); v != "" {
		return strings.clone(v, allocator)
	}
	if v := strings.trim_space(os.get_env("GROK_OAUTH2_CLIENT_ID", context.temp_allocator)); v != "" {
		return strings.clone(v, allocator)
	}
	return strings.clone(DEFAULT_OAUTH2_CLIENT_ID, allocator)
}

// request_device_code: POST {issuer}/oauth2/device/code
request_device_code :: proc(
	issuer, client_id, scopes: string,
	allocator := context.allocator,
) -> (
	dc: Device_Code,
	err: string,
) {
	url := fmt.tprintf("%s/oauth2/device/code", strings.trim_right(issuer, "/"))
	pairs := make([dynamic][2]string, 0, 4, context.temp_allocator)
	append(&pairs, [2]string{"client_id", client_id})
	append(&pairs, [2]string{"scope", scopes})
	append(&pairs, [2]string{"referrer", "aether"})
	form := form_encode(pairs[:], context.temp_allocator)
	headers := []string{
		"x-grok-client-surface: cli",
		fmt.tprintf("x-grok-client-version: %s", core.VERSION),
	}
	resp, herr := http_post_form(url, headers, form)
	if herr != .None {
		return {}, fmt.tprintf("device code request failed: %s", http_error_string(herr))
	}
	defer delete(resp.body)
	if resp.status == 404 {
		return {}, "device-code login not available for this issuer (HTTP 404)"
	}
	if resp.status != 200 {
		return {}, fmt.tprintf(
			"device code request HTTP %d: %s",
			resp.status,
			truncate(resp.body, 200),
		)
	}
	// parse JSON
	val, perr := json.parse(
		transmute([]byte)resp.body,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if perr != nil {
		return {}, "invalid device code JSON"
	}
	obj, ok := val.(json.Object)
	if !ok {
		return {}, "device code response not object"
	}
	dc.device_code = strings.clone(dl_jstr(obj, "device_code"), allocator)
	dc.user_code = strings.clone(dl_jstr(obj, "user_code"), allocator)
	dc.verification_uri = strings.clone(dl_jstr(obj, "verification_uri"), allocator)
	dc.verification_uri_complete = strings.clone(dl_jstr(obj, "verification_uri_complete"), allocator)
	dc.expires_in = dl_jint(obj, "expires_in", MIN_DEVICE_EXPIRY_SECS)
	if dc.expires_in < MIN_DEVICE_EXPIRY_SECS {
		dc.expires_in = MIN_DEVICE_EXPIRY_SECS
	}
	dc.interval_s = int(dl_jint(obj, "interval", i64(DEFAULT_DEVICE_POLL_SECS)))
	if dc.interval_s < 1 {
		dc.interval_s = DEFAULT_DEVICE_POLL_SECS
	}
	if dc.device_code == "" || dc.user_code == "" || dc.verification_uri == "" {
		destroy_device_code(&dc)
		return {}, "device code response missing required fields"
	}
	return dc, ""
}

dl_jstr :: proc(obj: json.Object, key: string) -> string {
	v, has := obj[key]
	if !has {
		return ""
	}
	s, ok := v.(json.String)
	if !ok {
		return ""
	}
	return string(s)
}

dl_jint :: proc(obj: json.Object, key: string, default: i64) -> i64 {
	v, has := obj[key]
	if !has {
		return default
	}
	if n, ok := v.(json.Integer); ok {
		return i64(n)
	}
	if f, ok := v.(json.Float); ok {
		return i64(f)
	}
	return default
}

// complete_device_code_login polls token endpoint and writes auth.json.
complete_device_code_login :: proc(
	issuer, client_id: string,
	dc: Device_Code,
	quiet: bool,
) -> (
	email: string,
	err: string,
) {
	token_url := fmt.tprintf("%s/oauth2/token", strings.trim_right(issuer, "/"))
	interval := time.Duration(dc.interval_s) * time.Second
	deadline := time.time_add(time.now(), time.Duration(dc.expires_in) * time.Second)

	// Sleep first (Grok: immediate poll only returns pending)
	time.sleep(interval)

	for {
		if time.to_unix_seconds(time.now()) >= time.to_unix_seconds(deadline) {
			return "", "device code expired — run `aether login` again"
		}

		pairs := make([dynamic][2]string, 0, 4, context.temp_allocator)
		append(&pairs, [2]string{"grant_type", DEVICE_GRANT_TYPE})
		append(&pairs, [2]string{"device_code", dc.device_code})
		append(&pairs, [2]string{"client_id", client_id})
		form := form_encode(pairs[:], context.temp_allocator)
		headers := []string{
			"x-grok-client-surface: cli",
			fmt.tprintf("x-grok-client-version: %s", core.VERSION),
		}
		resp, herr := http_post_form(token_url, headers, form)
		if herr != .None {
			return "", fmt.tprintf("token poll failed: %s", http_error_string(herr))
		}
		body := resp.body
		defer delete(body)

		if resp.status == 200 {
			return persist_device_tokens(body, issuer, client_id)
		}

		// error object
		err_code, _ := json_field_string(body, "error")
		detail, _ := json_field_string(body, "error_description")
		if detail == "" {
			detail = err_code
		}
		switch err_code {
		case "authorization_pending":
			time.sleep(interval)
			continue
		case "slow_down":
			interval += time.Duration(DEVICE_SLOW_DOWN_SECS) * time.Second
			time.sleep(interval)
			continue
		case "access_denied":
			return "", "authorization denied — user rejected the request"
		case "expired_token":
			return "", "device code expired — run `aether login` again"
		case:
			return "", fmt.tprintf("token exchange error: %s", detail if detail != "" else body[:min(120, len(body))])
		}
	}
}

persist_device_tokens :: proc(
	body, issuer, client_id: string,
) -> (
	email: string,
	err: string,
) {
	access, aok := json_field_string(body, "access_token")
	if !aok || access == "" {
		return "", "token response missing access_token"
	}
	refresh, _ := json_field_string(body, "refresh_token")
	expires_at := ""
	if exp_in, eok := json_field_int(body, "expires_in"); eok && exp_in > 0 {
		exp_time := time.time_add(time.now(), time.Duration(exp_in) * time.Second)
		expires_at = format_rfc3339_utc(exp_time, context.temp_allocator)
	}
	user_id := ""
	email_out := ""
	if id_token, iok := json_field_string(body, "id_token"); iok && id_token != "" {
		user_id, email_out = decode_jwt_sub_email(id_token)
	}

	scope := fmt.tprintf("%s::%s", strings.trim_right(issuer, "/"), client_id)
	path := core.auth_json_path(context.temp_allocator)
	werr := write_auth_session_entry(
		path,
		scope,
		access,
		refresh,
		expires_at,
		issuer,
		client_id,
		user_id,
		email_out,
	)
	if werr != "" {
		return "", werr
	}
	return email_out, ""
}

// decode_jwt_sub_email: no signature verify (token over HTTPS).
decode_jwt_sub_email :: proc(jwt: string) -> (sub, email: string) {
	// split .
	p1 := strings.index_byte(jwt, '.')
	if p1 < 0 {
		return "", ""
	}
	rest := jwt[p1 + 1 :]
	p2 := strings.index_byte(rest, '.')
	payload_b64 := rest
	if p2 >= 0 {
		payload_b64 = rest[:p2]
	}
	// base64url decode manually simplified: use encoding/base64
	// Odin has core:encoding/base64
	return decode_jwt_payload_fields(payload_b64)
}

decode_jwt_payload_fields :: proc(b64url: string) -> (sub, email: string) {
	// pad to multiple of 4
	s := b64url
	// replace url chars
	buf := make([dynamic]u8, 0, len(s) + 4, context.temp_allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		if c == '-' {
			append(&buf, '+')
		} else if c == '_' {
			append(&buf, '/')
		} else {
			append(&buf, c)
		}
	}
	for len(buf) % 4 != 0 {
		append(&buf, '=')
	}
	// decode via std - import base64
	decoded, ok := decode_base64_std(string(buf[:]), context.temp_allocator)
	if !ok {
		return "", ""
	}
	val, err := json.parse(decoded, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if err != nil {
		return "", ""
	}
	obj, is_o := val.(json.Object)
	if !is_o {
		return "", ""
	}
	sub = dl_jstr(obj, "sub")
	email = dl_jstr(obj, "email")
	return sub, email
}

// open_browser_url best-effort (xdg-open / open / start).
open_browser_url :: proc(url: string) -> bool {
	if url == "" {
		return false
	}
	// Linux first
	state, _, _, err := os.process_exec(
		{command = {"xdg-open", url}},
		context.temp_allocator,
	)
	if err == nil && state.exit_code == 0 {
		return true
	}
	state2, _, _, err2 := os.process_exec(
		{command = {"open", url}},
		context.temp_allocator,
	)
	return err2 == nil && state2.exit_code == 0
}

// run_device_login: full interactive device flow. Returns process exit code.
run_device_login :: proc(quiet := false) -> int {
	issuer := oauth2_issuer_from_env(context.temp_allocator)
	client_id := oauth2_client_id_from_env(context.temp_allocator)
	scopes := DEFAULT_OAUTH2_SCOPES
	if v := strings.trim_space(os.get_env("AETHER_OAUTH2_SCOPES", context.temp_allocator)); v != "" {
		scopes = v
	}

	if !quiet {
		fmt.eprintln("aether: device-code login (in-process; no Rust grok required)…")
	}

	dc, err := request_device_code(issuer, client_id, scopes, context.allocator)
	if err != "" {
		if !quiet {
			fmt.eprintf("aether: %s\n", err)
		}
		return 1
	}
	defer destroy_device_code(&dc)

	display_uri := dc.verification_uri_complete if dc.verification_uri_complete != "" else dc.verification_uri

	if !quiet {
		fmt.eprintln()
		fmt.eprintln("To sign in, open this URL in your browser:")
		fmt.eprintln()
		fmt.eprintf("  %s\n", display_uri)
		fmt.eprintln()
	}
	if !open_browser_url(display_uri) && !quiet {
		fmt.eprintln("  (Could not open browser automatically — open the URL above manually.)")
		fmt.eprintln()
	}
	if !quiet {
		if dc.verification_uri_complete != "" {
			fmt.eprintln("Confirm this code in your browser:")
		} else {
			fmt.eprintln("Then enter this code:")
		}
		fmt.eprintln()
		fmt.eprintf("  %s\n", dc.user_code)
		fmt.eprintln()
		fmt.eprintln("Only continue with a code you requested. Don't share it with anyone.")
		fmt.eprintln()
		fmt.eprintln("Waiting for authorization...")
	}

	email, perr := complete_device_code_login(issuer, client_id, dc, quiet)
	if perr != "" {
		if !quiet {
			fmt.eprintf("aether: login failed: %s\n", perr)
		}
		return 1
	}
	if !quiet {
		auth_p := core.auth_json_path(context.temp_allocator)
		if email != "" {
			fmt.eprintf("aether: signed in as %s — session in %s\n", email, auth_p)
		} else {
			fmt.eprintf("aether: signed in — session in %s (try `aether whoami`)\n", auth_p)
		}
	}
	return 0
}

decode_base64_std :: proc(s: string, allocator := context.allocator) -> ([]byte, bool) {
	out, err := base64.decode(s, allocator = allocator)
	if err != nil {
		return nil, false
	}
	return out, true
}
