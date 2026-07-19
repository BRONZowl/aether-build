package agent

import "core:os"
import "core:strings"
import "core:testing"
import "aether:core"

@(test)
test_write_auth_session_entry_round_trip :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("/tmp", "aether-auth-w-", context.allocator)
	testing.expect(t, err == nil)
	defer os.remove_all(dir)

	prev := os.get_env("GROK_HOME", context.temp_allocator)
	_ = os.set_env("GROK_HOME", dir)
	defer {
		if prev != "" {
			_ = os.set_env("GROK_HOME", prev)
		} else {
			_ = os.unset_env("GROK_HOME")
		}
	}

	path := core.auth_json_path(context.temp_allocator)
	scope := "https://auth.x.ai::test-client"
	werr := write_auth_session_entry(
		path,
		scope,
		"access-abc",
		"refresh-xyz",
		"2099-01-01T00:00:00Z",
		"https://auth.x.ai",
		"test-client",
		"user-1",
		"u@example.com",
	)
	testing.expectf(t, werr == "", "write: %s", werr)
	testing.expect(t, os.exists(path))

	data, rerr := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, rerr == nil)
	body := string(data)
	testing.expect(t, strings.contains(body, "access-abc"))
	testing.expect(t, strings.contains(body, "refresh-xyz"))
	testing.expect(t, strings.contains(body, "oidc"))
	testing.expect(t, strings.contains(body, "u@example.com"))

	// resolve should pick it up as session
	entries, ok := parse_auth_json_entries(body, context.allocator)
	testing.expect(t, ok)
	testing.expect(t, len(entries) >= 1)
	if len(entries) > 0 {
		testing.expect(t, entries[0].key == "access-abc")
		destroy_auth_entries(entries)
	}
}

@(test)
test_decode_jwt_sub_email :: proc(t: ^testing.T) {
	// header.payload.sig — payload is {"sub":"uid1","email":"a@b.c"}
	// base64url of payload without padding
	// {"sub":"uid1","email":"a@b.c"} = eyJzdWIiOiJ1aWQxIiwiZW1haWwiOiJhQGIuYyJ9
	jwt := "eyJhbGciOiJub25lIn0.eyJzdWIiOiJ1aWQxIiwiZW1haWwiOiJhQGIuYyJ9.sig"
	sub, email := decode_jwt_sub_email(jwt)
	testing.expect(t, sub == "uid1")
	testing.expect(t, email == "a@b.c")
}

@(test)
test_oauth2_defaults :: proc(t: ^testing.T) {
	iss := oauth2_issuer_from_env(context.temp_allocator)
	testing.expect(t, strings.contains(iss, "auth.x.ai") || iss != "")
	cid := oauth2_client_id_from_env(context.temp_allocator)
	testing.expect(t, len(cid) > 8)
}
