// Package hooks — HTTP handler runner (A4.7 / Grok type:"http").
// POSTs event envelope JSON; SSRF: https-only + blocked private ranges (loopback OK).
package hooks

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:net"
import "core:os"
import "core:strings"
import curl "vendor:curl"

// expand_hook_env_vars expands ${VAR} and $VAR from process env.
// Unset refs are left verbatim (validation will fail later if still invalid).
expand_hook_env_vars :: proc(s: string, allocator := context.allocator) -> string {
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
				if val := os.get_env(name, context.temp_allocator); val != "" {
					strings.write_string(&b, val)
				} else {
					// preserve unset
					strings.write_string(&b, s[i:i + 3 + end])
				}
				i = i + 3 + end
				continue
			}
		}
		// $NAME (alnum + _)
		j := i + 1
		for j < len(s) {
			ch := s[j]
			if (ch >= 'A' && ch <= 'Z') ||
			   (ch >= 'a' && ch <= 'z') ||
			   (ch >= '0' && ch <= '9') ||
			   ch == '_' {
				j += 1
			} else {
				break
			}
		}
		if j > i + 1 {
			name := s[i + 1:j]
			if val := os.get_env(name, context.temp_allocator); val != "" {
				strings.write_string(&b, val)
			} else {
				strings.write_string(&b, s[i:j])
			}
			i = j
			continue
		}
		strings.write_byte(&b, '$')
		i += 1
	}
	return strings.to_string(b)
}

// --- SSRF (aligned with agent/web_fetch + Grok http hooks) ---

hook_is_blocked_ip4 :: proc(a, b, c, d: u8) -> bool {
	if a == 127 {
		return false // loopback allowed for local dev
	}
	if a == 10 {
		return true
	}
	if a == 172 && b >= 16 && b <= 31 {
		return true
	}
	if a == 192 && b == 168 {
		return true
	}
	if a == 169 && b == 254 {
		return true
	}
	if a == 100 && b >= 64 && b <= 127 {
		return true
	}
	if a == 0 && b == 0 && c == 0 && d == 0 {
		return true
	}
	return false
}

hook_is_blocked_address :: proc(addr: net.Address) -> bool {
	switch v in addr {
	case net.IP4_Address:
		return hook_is_blocked_ip4(v[0], v[1], v[2], v[3])
	case net.IP6_Address:
		loopback := net.IP6_Address{0, 0, 0, 0, 0, 0, 0, 1}
		if v == loopback {
			return false
		}
		zero: net.IP6_Address
		if v == zero {
			return true
		}
		s0 := u16(v[0])
		if s0 & 0xffc0 == 0xfe80 {
			return true
		}
		if s0 & 0xfe00 == 0xfc00 {
			return true
		}
		if v[0] == 0 && v[1] == 0 && v[2] == 0 && v[3] == 0 && v[4] == 0 && u16(v[5]) == 0xffff {
			hi := u16(v[6])
			lo := u16(v[7])
			return hook_is_blocked_ip4(u8(hi >> 8), u8(hi & 0xff), u8(lo >> 8), u8(lo & 0xff))
		}
		return false
	}
	return false
}

// parse_hook_url: scheme + host from URL string (minimal).
parse_hook_url :: proc(url: string) -> (scheme, host: string, ok: bool) {
	u := strings.trim_space(url)
	if u == "" {
		return "", "", false
	}
	sep := strings.index(u, "://")
	if sep < 0 {
		return "", "", false
	}
	scheme = strings.to_lower(u[:sep], context.temp_allocator)
	rest := u[sep + 3:]
	// strip path/query
	if i := strings.index_any(rest, "/?#"); i >= 0 {
		rest = rest[:i]
	}
	if rest == "" {
		return scheme, "", false
	}
	// userinfo@host
	if at := strings.last_index_byte(rest, '@'); at >= 0 {
		rest = rest[at + 1:]
	}
	// [ipv6]:port or host:port
	if strings.has_prefix(rest, "[") {
		if rb := strings.index_byte(rest, ']'); rb > 0 {
			host = rest[1:rb]
			return scheme, host, host != ""
		}
		return scheme, "", false
	}
	// host:port — single colon
	if c := strings.index_byte(rest, ':'); c >= 0 {
		if strings.last_index_byte(rest, ':') == c {
			rest = rest[:c]
		}
	}
	host = rest
	return scheme, host, host != ""
}

// validate_hook_url: HTTPS only (or http://loopback when AETHER_HOOKS_HTTP_ALLOW_HTTP=1 for tests).
// Blocks private/link-local resolved addresses (loopback allowed).
validate_hook_url :: proc(url: string) -> string /* err or "" */ {
	scheme, host, ok := parse_hook_url(url)
	if !ok {
		return "invalid URL"
	}
	allow_http := false
	if v := os.get_env("AETHER_HOOKS_HTTP_ALLOW_HTTP", context.temp_allocator); v == "1" ||
	   v == "true" ||
	   v == "yes" {
		allow_http = true
	}
	if scheme == "https" {
		// ok
	} else if scheme == "http" && allow_http {
		// test / local only
	} else if scheme == "http" {
		// allow bare loopback over http for local dev (Grok is https-only; we keep
		// private ranges blocked below so LAN is still protected)
		h_low := strings.to_lower(host, context.temp_allocator)
		if h_low != "localhost" && h_low != "127.0.0.1" && h_low != "::1" {
			return "only https:// URLs are allowed for HTTP hooks (http limited to loopback)"
		}
	} else {
		return fmt.tprintf("only https:// URLs are allowed for HTTP hooks, got %s://", scheme)
	}

	// literal IP
	if ip, ok4 := net.parse_ip4_address(host); ok4 {
		if hook_is_blocked_address(ip) {
			return fmt.tprintf("URL resolves to blocked private/internal IP: %s", host)
		}
		return ""
	}
	if ip6, ok6 := net.parse_ip6_address(host); ok6 {
		if hook_is_blocked_address(ip6) {
			return fmt.tprintf("URL resolves to blocked private/internal IP: %s", host)
		}
		return ""
	}

	// DNS
	port := "443" if scheme == "https" else "80"
	ep4, ep6, nerr := net.resolve(fmt.tprintf("%s:%s", host, port))
	if nerr != nil {
		ep4, ep6, nerr = net.resolve(host)
	}
	if nerr != nil {
		return fmt.tprintf("DNS resolution failed for %s", host)
	}
	has := false
	if _, ok4 := ep4.address.(net.IP4_Address); ok4 {
		has = true
		if hook_is_blocked_address(ep4.address) {
			return fmt.tprintf("URL host %s resolves to blocked private/internal IP", host)
		}
	}
	if _, ok6 := ep6.address.(net.IP6_Address); ok6 {
		has = true
		if hook_is_blocked_address(ep6.address) {
			return fmt.tprintf("URL host %s resolves to blocked private/internal IP", host)
		}
	}
	if !has {
		return fmt.tprintf("DNS resolved no addresses for %s", host)
	}
	return ""
}

@(private)
Hook_Body_Ctx :: struct {
	b: strings.Builder,
}

@(private)
hook_body_write_cb :: proc "c" (
	buffer: [^]byte,
	size: c.size_t,
	nitems: c.size_t,
	userdata: rawptr,
) -> c.size_t {
	context = runtime.default_context()
	total := int(size * nitems)
	if total <= 0 {
		return 0
	}
	ctx := cast(^Hook_Body_Ctx)userdata
	// cap response
	if strings.builder_len(ctx.b) >= MAX_HOOK_STDOUT {
		return c.size_t(total)
	}
	take := total
	room := MAX_HOOK_STDOUT - strings.builder_len(ctx.b)
	if take > room {
		take = room
	}
	if take > 0 {
		strings.write_string(&ctx.b, string(buffer[:take]))
	}
	return c.size_t(total)
}

// http_post_json_hooks POSTs body to url; returns status + body (temp/owned via allocator).
http_post_json_hooks :: proc(
	url, body: string,
	timeout_s: int,
	allocator := context.allocator,
) -> (
	status: int,
	resp_body: string,
	ok: bool,
) {
	curl.global_init(curl.GLOBAL_DEFAULT)
	easy := curl.easy_init()
	if easy == nil {
		return 0, "", false
	}
	defer curl.easy_cleanup(easy)

	url_c := strings.clone_to_cstring(url, context.temp_allocator)
	body_c := strings.clone_to_cstring(body, context.temp_allocator)

	mem: Hook_Body_Ctx
	strings.builder_init(&mem.b, allocator)

	curl.easy_setopt(easy, .URL, url_c)
	curl.easy_setopt(easy, .POST, c.long(1))
	curl.easy_setopt(easy, .POSTFIELDS, body_c)
	curl.easy_setopt(easy, .POSTFIELDSIZE, c.long(len(body)))
	curl.easy_setopt(easy, .WRITEFUNCTION, hook_body_write_cb)
	curl.easy_setopt(easy, .WRITEDATA, &mem)
	curl.easy_setopt(easy, .FOLLOWLOCATION, c.long(0)) // no redirect (SSRF)
	secs := timeout_s if timeout_s > 0 else 5
	if secs > 120 {
		secs = 120
	}
	curl.easy_setopt(easy, .CONNECTTIMEOUT, c.long(min(15, secs)))
	curl.easy_setopt(easy, .TIMEOUT, c.long(secs))
	curl.easy_setopt(easy, .USERAGENT, cstring("aether-hooks/0.1"))
	// restrict schemes (libcurl PROTOCOLS_STR)
	curl.easy_setopt(easy, .PROTOCOLS_STR, cstring("https,http"))

	slist: ^curl.slist
	defer if slist != nil {
		curl.slist_free_all(slist)
	}
	slist = curl.slist_append(slist, "Content-Type: application/json")
	slist = curl.slist_append(slist, "Accept: application/json")
	curl.easy_setopt(easy, .HTTPHEADER, slist)

	res := curl.easy_perform(easy)
	if res != .E_OK {
		delete(mem.b.buf)
		return 0, "", false
	}
	code: c.long
	curl.easy_getinfo(easy, .RESPONSE_CODE, &code)
	return int(code), strings.to_string(mem.b), true
}

// run_hook_http POSTs envelope; blocking hooks honor decision JSON / non-2xx fail-open.
run_hook_http :: proc(
	spec: Hook_Spec,
	envelope_json: string,
	blocking: bool,
) -> (
	decision: Hook_Decision,
	reason: string,
	exit_code: int,
) {
	decision = .Allow
	// re-expand in case env changed
	url := expand_hook_env_vars(spec.url, context.temp_allocator)
	if url == "" {
		return .Allow, "", 0 // fail-open
	}
	if err := validate_hook_url(url); err != "" {
		// SSRF / bad URL — fail-open (Grok marks Failed; we never deny on config errors)
		return .Allow, "", 0
	}
	timeout_s := spec.timeout_s
	if timeout_s <= 0 {
		timeout_s = 5
	}
	status, body, ok := http_post_json_hooks(url, envelope_json, timeout_s, context.temp_allocator)
	if !ok {
		return .Allow, "", 0
	}
	exit_code = status
	if !blocking {
		return .Allow, "", status
	}
	// non-2xx: fail-open
	if status < 200 || status >= 300 {
		return .Allow, "", status
	}
	dec, why := parse_decision_from_stdout(body)
	if dec == .Deny {
		return .Deny, why if why != "" else "http hook denied", status
	}
	return .Allow, "", status
}
