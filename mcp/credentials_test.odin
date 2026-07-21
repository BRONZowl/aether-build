// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package mcp

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_expand_env_in_string :: proc(t: ^testing.T) {
	_ = os.set_env("AETHER_MCP_TEST_TOKEN", "secret-tok")
	defer os.unset_env("AETHER_MCP_TEST_TOKEN")

	out := expand_env_in_string("Bearer ${AETHER_MCP_TEST_TOKEN}", context.temp_allocator)
	testing.expect(t, out == "Bearer secret-tok", out)

	out2 := expand_env_in_string("x=$AETHER_MCP_TEST_TOKEN-y", context.temp_allocator)
	testing.expect(t, out2 == "x=secret-tok-y", out2)

	out3 := expand_env_in_string("no vars", context.temp_allocator)
	testing.expect(t, out3 == "no vars")
}

@(test)
test_credential_key :: proc(t: ^testing.T) {
	k := credential_key("linear", "https://mcp.example.com/mcp", context.temp_allocator)
	testing.expect(t, k == "linear:https://mcp.example.com/mcp", k)
}

@(test)
test_lookup_mcp_access_token_from_json :: proc(t: ^testing.T) {
	// Grok legacy fixture shape
	fixture := `{
		"linear:https://mcp.example.com/mcp": {
			"client_id": "legacy-client-id",
			"token_response": {
				"access_token": "at-123",
				"token_type": "bearer",
				"expires_in": 3600,
				"refresh_token": "rt-456",
				"scope": "read write"
			},
			"granted_scopes": ["read", "write"],
			"token_received_at": 1730000000
		},
		"noauth:https://example.com/mcp": {
			"client_id": "c2",
			"token_response": null
		}
	}`
	tok, ok := lookup_mcp_access_token_from_json(
		fixture,
		"linear",
		"https://mcp.example.com/mcp",
		context.temp_allocator,
	)
	testing.expect(t, ok)
	testing.expect(t, tok == "at-123", tok)

	_, ok2 := lookup_mcp_access_token_from_json(
		fixture,
		"noauth",
		"https://example.com/mcp",
		context.temp_allocator,
	)
	testing.expect(t, !ok2)

	_, ok3 := lookup_mcp_access_token_from_json(
		fixture,
		"missing",
		"https://nope",
		context.temp_allocator,
	)
	testing.expect(t, !ok3)
}

@(test)
test_resolve_http_auth_headers_order :: proc(t: ^testing.T) {
	_ = os.set_env("AETHER_MCP_BEARER_TEST", "from-env")
	defer os.unset_env("AETHER_MCP_BEARER_TEST")

	// Explicit Authorization wins
	cfg := Mcp_Server_Config {
		name                 = "s",
		url                  = "https://mcp.example.com/mcp",
		bearer_token_env_var = "AETHER_MCP_BEARER_TEST",
		headers              = make([dynamic][2]string, 0, 2),
	}
	append(&cfg.headers, [2]string{"Authorization", "Bearer explicit"})
	hdrs, src := resolve_http_auth_headers(cfg, context.temp_allocator)
	testing.expect(t, src == .Headers)
	testing.expect(t, has_authorization_header(hdrs[:]))
	found := false
	for h in hdrs {
		if strings.equal_fold(h[0], "Authorization") {
			testing.expect(t, h[1] == "Bearer explicit", h[1])
			found = true
		}
	}
	testing.expect(t, found)

	// Env when no Authorization
	cfg2 := Mcp_Server_Config {
		name                 = "s2",
		url                  = "https://mcp.example.com/mcp",
		bearer_token_env_var = "AETHER_MCP_BEARER_TEST",
		headers              = make([dynamic][2]string, 0, 1),
	}
	hdrs2, src2 := resolve_http_auth_headers(cfg2, context.temp_allocator)
	testing.expect(t, src2 == .Env)
	for h in hdrs2 {
		if strings.equal_fold(h[0], "Authorization") {
			testing.expect(t, h[1] == "Bearer from-env", h[1])
		}
	}

	// Env expansion in headers
	cfg3 := Mcp_Server_Config {
		name    = "s3",
		url     = "https://x",
		headers = make([dynamic][2]string, 0, 1),
	}
	append(&cfg3.headers, [2]string{"X-Key", "${AETHER_MCP_BEARER_TEST}"})
	hdrs3, _ := resolve_http_auth_headers(cfg3, context.temp_allocator)
	for h in hdrs3 {
		if h[0] == "X-Key" {
			testing.expect(t, h[1] == "from-env", h[1])
		}
	}
}

@(test)
test_upsert_mcp_credential_round_trip :: proc(t: ^testing.T) {
	path := fmt.tprintf("/tmp/aether-mcp-creds-%d.json", os.get_pid())
	_ = os.remove(path)
	defer os.remove(path)

	err := upsert_mcp_credential_at(
		path,
		"linear",
		"https://mcp.example.com/mcp",
		"at-write-1",
		"rt-write-1",
		3600,
	)
	testing.expectf(t, err == "", "err: %s", err)
	testing.expect(t, os.exists(path))

	tok, ok := lookup_mcp_access_token_from_file(
		path,
		"linear",
		"https://mcp.example.com/mcp",
		context.temp_allocator,
	)
	testing.expect(t, ok)
	testing.expect(t, tok == "at-write-1", tok)

	// Second server preserved
	err2 := upsert_mcp_credential_at(path, "other", "https://other.example/mcp", "at-2")
	testing.expect(t, err2 == "")
	tok1, ok1 := lookup_mcp_access_token_from_file(
		path,
		"linear",
		"https://mcp.example.com/mcp",
		context.temp_allocator,
	)
	testing.expect(t, ok1 && tok1 == "at-write-1")
	tok2, ok2 := lookup_mcp_access_token_from_file(
		path,
		"other",
		"https://other.example/mcp",
		context.temp_allocator,
	)
	testing.expect(t, ok2 && tok2 == "at-2")

	// Delete linear
	derr := delete_mcp_credential_at(path, "linear", "https://mcp.example.com/mcp")
	testing.expect(t, derr == "")
	_, ok3 := lookup_mcp_access_token_from_file(
		path,
		"linear",
		"https://mcp.example.com/mcp",
		context.temp_allocator,
	)
	testing.expect(t, !ok3)
	_, ok4 := lookup_mcp_access_token_from_file(
		path,
		"other",
		"https://other.example/mcp",
		context.temp_allocator,
	)
	testing.expect(t, ok4)
}

@(test)
test_parse_bearer_token_env_var_config :: proc(t: ^testing.T) {
	path := "/tmp/aether-mcp-bearer-cfg.toml"
	body :=
		"[mcp_servers.remote]\n" +
		"url = \"https://example.com/mcp\"\n" +
		"bearer_token_env_var = \"MY_MCP_TOKEN\"\n" +
		"enabled = true\n"
	_ = os.write_entire_file(path, transmute([]byte)body)
	defer os.remove(path)

	out := make([dynamic]Mcp_Server_Config, 0, 2, context.allocator)
	append_configs_from_file(&out, path, context.allocator)
	defer destroy_server_configs(out[:])
	testing.expect(t, len(out) == 1)
	if len(out) == 1 {
		testing.expect(t, out[0].bearer_token_env_var == "MY_MCP_TOKEN", out[0].bearer_token_env_var)
	}
}
