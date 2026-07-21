// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_normalize_domain :: proc(t: ^testing.T) {
	testing.expect(t, normalize_domain("www.Example.COM.") == "example.com")
	testing.expect(t, normalize_domain("  docs.rs  ") == "docs.rs")
}

@(test)
test_domain_allowed_default_list :: proc(t: ^testing.T) {
	prev_all := os.get_env("AETHER_WEB_FETCH_ALLOW_ALL", context.temp_allocator)
	prev_dom := os.get_env("AETHER_WEB_FETCH_DOMAINS", context.temp_allocator)
	defer {
		if prev_all == "" {
			_ = os.unset_env("AETHER_WEB_FETCH_ALLOW_ALL")
		} else {
			_ = os.set_env("AETHER_WEB_FETCH_ALLOW_ALL", prev_all)
		}
		if prev_dom == "" {
			_ = os.unset_env("AETHER_WEB_FETCH_DOMAINS")
		} else {
			_ = os.set_env("AETHER_WEB_FETCH_DOMAINS", prev_dom)
		}
	}
	_ = os.unset_env("AETHER_WEB_FETCH_ALLOW_ALL")
	_ = os.unset_env("AETHER_WEB_FETCH_DOMAINS")

	testing.expect(t, domain_allowed("docs.rs", "/reqwest/latest"))
	testing.expect(t, domain_allowed("developer.mozilla.org", "/en-US/docs"))
	testing.expect(t, !domain_allowed("evil.com", "/steal"))
	// path-scoped entry
	testing.expect(t, domain_allowed("vercel.com", "/docs/foo"))
	testing.expect(t, !domain_allowed("vercel.com", "/pricing"))
}

@(test)
test_domain_allow_all_env :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_WEB_FETCH_ALLOW_ALL", context.temp_allocator)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_WEB_FETCH_ALLOW_ALL")
		} else {
			_ = os.set_env("AETHER_WEB_FETCH_ALLOW_ALL", prev)
		}
	}
	_ = os.set_env("AETHER_WEB_FETCH_ALLOW_ALL", "1")
	testing.expect(t, domain_allowed("evil.com", "/x"))
}

@(test)
test_ssrf_blocks_private_literals :: proc(t: ^testing.T) {
	testing.expect(t, is_blocked_ip4(10, 0, 0, 1))
	testing.expect(t, is_blocked_ip4(192, 168, 1, 1))
	testing.expect(t, is_blocked_ip4(172, 16, 0, 1))
	testing.expect(t, is_blocked_ip4(169, 254, 169, 254))
	testing.expect(t, is_blocked_ip4(100, 64, 0, 1))
	testing.expect(t, !is_blocked_ip4(127, 0, 0, 1))
	testing.expect(t, !is_blocked_ip4(1, 1, 1, 1))
	testing.expect(t, !is_blocked_ip4(172, 15, 0, 1))
	testing.expect(t, !is_blocked_ip4(172, 32, 0, 1))

	err := check_ssrf_host("10.0.0.1")
	testing.expect(t, err != "")
	testing.expect(t, strings.contains(err, "SSRF") || strings.contains(err, "private"))
	err2 := check_ssrf_host("127.0.0.1")
	testing.expect(t, err2 == "")
}

@(test)
test_parse_and_normalize_url :: proc(t: ^testing.T) {
	p := parse_and_normalize_url("http://docs.rs/foo", context.allocator)
	defer {
		if p.host != "" {
			delete(p.host)
		}
		if p.path != "" {
			delete(p.path)
		}
		if p.full != "" {
			delete(p.full)
		}
	}
	testing.expect(t, p.ok)
	testing.expect(t, p.host == "docs.rs")
	testing.expect(t, strings.has_prefix(p.full, "https://"))
	testing.expect(t, strings.contains(p.full, "docs.rs/foo"))

	bad := parse_and_normalize_url("not-a-url", context.temp_allocator)
	testing.expect(t, !bad.ok)

	empty := parse_and_normalize_url("", context.temp_allocator)
	testing.expect(t, !empty.ok)
}

@(test)
test_html_to_markdown_strips_script :: proc(t: ^testing.T) {
	html := `<html><head><script>alert(1)</script><style>x{}</style></head><body><p>Hello &amp; world</p><a href="https://docs.rs">link</a></body></html>`
	out := html_to_markdown_simple(html, context.allocator)
	defer delete(out)
	testing.expect(t, !strings.contains(out, "alert"))
	testing.expect(t, strings.contains(out, "Hello") && strings.contains(out, "world"))
	testing.expect(t, strings.contains(out, "docs.rs"))
}

@(test)
test_web_fetch_from_args_validation :: proc(t: ^testing.T) {
	out := web_fetch_from_args(`{}`, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "url is required"))

	out2 := web_fetch_from_args(`{"url":"https://evil.example/"}`, context.allocator)
	defer delete(out2)
	testing.expect(t, strings.contains(out2, "not in the allowed domains") || strings.contains(out2, "Error"))
}

@(test)
test_web_fetch_disabled_env :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_WEB_FETCH", context.temp_allocator)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_NO_WEB_FETCH")
		} else {
			_ = os.set_env("AETHER_NO_WEB_FETCH", prev)
		}
	}
	_ = os.set_env("AETHER_NO_WEB_FETCH", "1")
	testing.expect(t, !web_fetch_enabled())
	out := web_fetch_url("https://docs.rs/", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "disabled"))
}

@(test)
test_is_binary_body :: proc(t: ^testing.T) {
	testing.expect(t, is_binary_body("%PDF-1.4 binary stuff"))
	png := []byte{0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a, 0, 1, 2}
	testing.expect(t, is_binary_body(string(png)))
	testing.expect(t, is_binary_body("hello\x00world"))
	testing.expect(t, !is_binary_body("plain text article about docs"))
	testing.expect(t, !is_binary_body("<!doctype html><html><body>hi</body></html>"))
}

@(test)
test_web_fetch_overflow_saves_artifact :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-webfetch-art-%d", os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)

	prev := os.get_env("AETHER_WEB_FETCH_DIR", context.temp_allocator)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_WEB_FETCH_DIR")
		} else {
			_ = os.set_env("AETHER_WEB_FETCH_DIR", prev)
		}
	}
	_ = os.set_env("AETHER_WEB_FETCH_DIR", dir)

	// body larger than PREVIEW
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< (WEB_FETCH_PREVIEW_BYTES + 2000) {
		strings.write_byte(&b, 'a' if i % 80 != 0 else '\n')
	}
	big := strings.to_string(b)
	out := web_fetch_apply_overflow(big, "text/plain", context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "web_fetch content truncated"))
	testing.expect(t, strings.contains(out, "Full content saved to:"))
	testing.expect(t, len(out) < len(big))

	// artifact on disk
	fis, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	testing.expect(t, err == nil)
	found := false
	for e in fis {
		if strings.has_suffix(e.name, ".txt") || strings.has_suffix(e.name, ".md") {
			found = true
			p, _ := filepath.join({dir, e.name}, context.temp_allocator)
			data, rerr := os.read_entire_file(p, context.temp_allocator)
			testing.expect(t, rerr == nil)
			testing.expect(t, len(data) == len(big))
		}
	}
	testing.expect(t, found)
}

@(test)
test_web_fetch_cache_put_get :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_WEB_FETCH_NO_CACHE", context.temp_allocator)
	defer {
		if prev == "" {
			_ = os.unset_env("AETHER_WEB_FETCH_NO_CACHE")
		} else {
			_ = os.set_env("AETHER_WEB_FETCH_NO_CACHE", prev)
		}
	}
	_ = os.unset_env("AETHER_WEB_FETCH_NO_CACHE")

	url := "https://docs.rs/cache-test-unique-key"
	body := "cached-body-payload"
	web_fetch_cache_put(url, body)
	got, ok := web_fetch_cache_get(url, context.allocator)
	defer if ok {
		delete(got)
	}
	testing.expect(t, ok)
	testing.expect(t, got == body)

	_ = os.set_env("AETHER_WEB_FETCH_NO_CACHE", "1")
	_, ok2 := web_fetch_cache_get(url, context.allocator)
	testing.expect(t, !ok2)
}

@(test)
test_web_fetch_payload_ext :: proc(t: ^testing.T) {
	testing.expect(t, web_fetch_payload_ext("x", "markdown") == "md")
	testing.expect(t, web_fetch_payload_ext(`{"a":1}`, "text/plain") == "json")
	testing.expect(t, web_fetch_payload_ext("hello", "text/plain") == "txt")
}
