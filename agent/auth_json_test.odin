package agent

import "core:testing"

@(test)
test_pick_prefers_oidc_over_api_key :: proc(t: ^testing.T) {
	entries := []Auth_Entry {
		{scope = "xai::api_key", key = "api-key-token", auth_mode = .Api_Key},
		{
			scope = "https://auth.x.ai::client",
			key = "session-token",
			auth_mode = .Oidc,
			refresh_token = "rt",
		},
	}
	idx := pick_preferred_entry(entries)
	testing.expect(t, idx == 1, "expected OIDC entry preferred over api_key")
}

@(test)
test_parse_auth_json_session :: proc(t: ^testing.T) {
	raw := `{
  "https://auth.x.ai::abc": {
    "key": "tok-abc",
    "auth_mode": "oidc",
    "user_id": "u1",
    "email": "a@b.c",
    "refresh_token": "rt1",
    "expires_at": "2099-01-01T00:00:00Z",
    "oidc_issuer": "https://auth.x.ai",
    "oidc_client_id": "abc"
  }
}`
	entries, ok := parse_auth_json_entries(raw, context.allocator)
	testing.expect(t, ok, "parse should succeed")
	defer destroy_auth_entries(entries)
	testing.expect(t, len(entries) == 1, "one entry")
	testing.expect(t, entries[0].auth_mode == .Oidc, "oidc mode")
	testing.expect(t, entries[0].email == "a@b.c", "email")
	testing.expect(t, entries[0].key == "tok-abc", "key")
}

@(test)
test_entry_needs_refresh_expired :: proc(t: ^testing.T) {
	e := Auth_Entry {
		key            = "k",
		refresh_token  = "rt",
		oidc_issuer    = "https://auth.x.ai",
		oidc_client_id = "c",
		expires_at     = "2020-01-01T00:00:00Z",
	}
	testing.expect(t, entry_needs_refresh(e), "expired should need refresh")
}

@(test)
test_entry_needs_refresh_far_future :: proc(t: ^testing.T) {
	e := Auth_Entry {
		key            = "k",
		refresh_token  = "rt",
		oidc_issuer    = "https://auth.x.ai",
		oidc_client_id = "c",
		expires_at     = "2099-01-01T00:00:00Z",
	}
	testing.expect(t, !entry_needs_refresh(e), "far future should not need refresh")
}
