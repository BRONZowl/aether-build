package agent

// web_fetch — Grok Build WebFetchTool port (Full product slice).
// Reference: crates/codegen/xai-grok-tools/.../web_fetch/
// Allowlist + SSRF + HTML→md + overflow artifact + process cache + binary reject.
// N/A: proxy, htmd parity, PDF/image download writers.

import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:time"
import "aether:core"

// Safety constants match Grok WebFetchParams / config.rs
WEB_FETCH_MAX_URL_LENGTH :: 2_000
WEB_FETCH_MAX_CONTENT :: 10 * 1024 * 1024
WEB_FETCH_MAX_MARKDOWN :: 100_000
// Chat-friendly preview when full body is saved as a session artifact.
WEB_FETCH_PREVIEW_BYTES :: 24_000
WEB_FETCH_CACHE_TTL_S :: 300
WEB_FETCH_CACHE_MAX :: 32
WEB_FETCH_BINARY_SAMPLE :: 8192
WEB_FETCH_TIMEOUT_S :: 60
WEB_FETCH_USER_AGENT :: "Mozilla/5.0 (compatible; grok-agent/1.0; +https://x.ai)"

Web_Fetch_Cache_Entry :: struct {
	url:  string,
	body: string,
	at:   time.Time,
}

g_web_fetch_cache:    [dynamic]Web_Fetch_Cache_Entry
g_web_fetch_cache_mu: sync.Mutex
g_web_fetch_art_ctr:  int
g_web_fetch_art_mu:   sync.Mutex

// Grok DEFAULT_ALLOWED_DOMAINS (config.rs) — host-only or host/path-prefix.
WEB_FETCH_DEFAULT_DOMAINS :: []string{
	"x.ai",
	"console.x.ai",
	"docs.x.ai",
	"api.x.ai",
	"docs.python.org",
	"en.cppreference.com",
	"docs.oracle.com",
	"learn.microsoft.com",
	"developer.mozilla.org",
	"go.dev",
	"pkg.go.dev",
	"www.php.net",
	"docs.swift.org",
	"kotlinlang.org",
	"ruby-doc.org",
	"doc.rust-lang.org",
	"docs.rs",
	"www.typescriptlang.org",
	"react.dev",
	"angular.io",
	"vuejs.org",
	"nextjs.org",
	"expressjs.com",
	"nodejs.org",
	"bun.sh",
	"jquery.com",
	"getbootstrap.com",
	"tailwindcss.com",
	"d3js.org",
	"threejs.org",
	"redux.js.org",
	"webpack.js.org",
	"jestjs.io",
	"reactrouter.com",
	"docs.djangoproject.com",
	"flask.palletsprojects.com",
	"fastapi.tiangolo.com",
	"pandas.pydata.org",
	"numpy.org",
	"www.tensorflow.org",
	"pytorch.org",
	"scikit-learn.org",
	"matplotlib.org",
	"requests.readthedocs.io",
	"jupyter.org",
	"laravel.com",
	"symfony.com",
	"wordpress.org",
	"docs.spring.io",
	"hibernate.org",
	"tomcat.apache.org",
	"gradle.org",
	"maven.apache.org",
	"asp.net",
	"dotnet.microsoft.com",
	"nuget.org",
	"blazor.net",
	"reactnative.dev",
	"docs.flutter.dev",
	"developer.apple.com",
	"developer.android.com",
	"keras.io",
	"spark.apache.org",
	"huggingface.co",
	"www.kaggle.com",
	"redis.io",
	"www.postgresql.org",
	"dev.mysql.com",
	"www.sqlite.org",
	"graphql.org",
	"prisma.io",
	"docs.aws.amazon.com",
	"cloud.google.com",
	"kubernetes.io",
	"www.docker.com",
	"www.terraform.io",
	"www.ansible.com",
	"vercel.com/docs",
	"docs.netlify.com",
	"devcenter.heroku.com",
	"cypress.io",
	"selenium.dev",
	"docs.unity.com",
	"docs.unrealengine.com",
	"git-scm.com",
	"nginx.org",
	"httpd.apache.org",
}

// web_fetch_enabled: opt-out AETHER_NO_WEB_FETCH=1 (Grok feature-flags the tool).
web_fetch_enabled :: proc() -> bool {
	if v := os.get_env("AETHER_NO_WEB_FETCH", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") {
		return false
	}
	return true
}

// --- domain allowlist (domain.rs port) ---

normalize_domain :: proc(raw: string, allocator := context.temp_allocator) -> string {
	s := strings.trim_space(raw)
	for len(s) > 0 && (s[len(s) - 1] == '/' || s[len(s) - 1] == '.') {
		s = s[:len(s) - 1]
	}
	low := strings.to_lower(s, allocator)
	if strings.has_prefix(low, "www.") {
		return low[4:]
	}
	return low
}

// domain_allowed: Grok DomainMatcher.check — true if permitted.
// Default: WEB_FETCH_DEFAULT_DOMAINS. Override: AETHER_WEB_FETCH_DOMAINS=a,b,c
// Local escape hatch (not Grok default): AETHER_WEB_FETCH_ALLOW_ALL=1
domain_allowed :: proc(host, path: string) -> bool {
	if v := os.get_env("AETHER_WEB_FETCH_ALLOW_ALL", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") {
		return true
	}
	host_n := normalize_domain(host)
	path_n := strings.to_lower(path, context.temp_allocator)
	if path_n == "" {
		path_n = "/"
	}

	list := WEB_FETCH_DEFAULT_DOMAINS
	custom := strings.trim_space(os.get_env("AETHER_WEB_FETCH_DOMAINS", context.temp_allocator))
	if custom != "" {
		list = strings.split(custom, ",", context.temp_allocator)
	}

	any_path := false
	prefixes := make([dynamic]string, 0, 4, context.temp_allocator)
	found := false
	for raw in list {
		norm := normalize_domain(strings.trim_space(raw))
		if norm == "" {
			continue
		}
		eh, ep: string
		if i := strings.index_byte(norm, '/'); i >= 0 {
			eh = norm[:i]
			ep = norm[i:]
		} else {
			eh = norm
			ep = ""
		}
		if eh != host_n {
			continue
		}
		found = true
		if ep == "" || ep == "/" {
			any_path = true
			break
		}
		pfx := ep
		if !strings.has_prefix(pfx, "/") {
			pfx = fmt.tprintf("/%s", pfx)
		}
		for len(pfx) > 1 && pfx[len(pfx) - 1] == '/' {
			pfx = pfx[:len(pfx) - 1]
		}
		append(&prefixes, pfx)
	}
	if !found {
		return false
	}
	if any_path {
		return true
	}
	for pfx in prefixes {
		if path_n == pfx {
			return true
		}
		if strings.has_prefix(path_n, pfx) &&
		   (len(path_n) == len(pfx) || path_n[len(pfx)] == '/') {
			return true
		}
	}
	return false
}

// --- SSRF (ssrf.rs port) ---

is_blocked_ip4 :: proc(a, b, c, d: u8) -> bool {
	if a == 127 {
		return false // loopback allowed
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

is_blocked_address :: proc(addr: net.Address) -> bool {
	switch v in addr {
	case net.IP4_Address:
		return is_blocked_ip4(v[0], v[1], v[2], v[3])
	case net.IP6_Address:
		// loopback ::1
		loopback := net.IP6_Address{0, 0, 0, 0, 0, 0, 0, 1}
		if v == loopback {
			return false
		}
		// unspecified
		zero: net.IP6_Address
		if v == zero {
			return true
		}
		s0 := u16(v[0])
		// fe80::/10 link-local
		if s0 & 0xffc0 == 0xfe80 {
			return true
		}
		// fc00::/7 ULA
		if s0 & 0xfe00 == 0xfc00 {
			return true
		}
		// IPv4-mapped ::ffff:a.b.c.d — segments 6,7 hold the v4 octets in network order
		if v[0] == 0 && v[1] == 0 && v[2] == 0 && v[3] == 0 && v[4] == 0 && u16(v[5]) == 0xffff {
			hi := u16(v[6])
			lo := u16(v[7])
			return is_blocked_ip4(u8(hi >> 8), u8(hi & 0xff), u8(lo >> 8), u8(lo & 0xff))
		}
		return false
	}
	return false
}

check_ssrf_host :: proc(host: string) -> string {
	h := host
	if strings.has_prefix(h, "[") && strings.has_suffix(h, "]") {
		h = h[1:len(h) - 1]
	} else if i := strings.index_byte(h, ':'); i >= 0 {
		// hostname:port — only if single colon (not raw IPv6)
		if strings.last_index_byte(h, ':') == i {
			h = h[:i]
		}
	}

	if ip, ok := net.parse_ip4_address(h); ok {
		if is_blocked_address(ip) {
			return fmt.tprintf("SSRF blocked: private/link-local address %s", host)
		}
		return ""
	}

	ep4, ep6, nerr := net.resolve(fmt.tprintf("%s:443", h))
	if nerr != nil {
		ep4, ep6, nerr = net.resolve(h)
	}
	if nerr != nil {
		return fmt.tprintf("DNS resolution failed for %s", host)
	}
	has := false
	if _, ok4 := ep4.address.(net.IP4_Address); ok4 {
		has = true
		if is_blocked_address(ep4.address) {
			return fmt.tprintf("SSRF blocked: %s resolves to private/link-local address", host)
		}
	}
	if _, ok6 := ep6.address.(net.IP6_Address); ok6 {
		has = true
		if is_blocked_address(ep6.address) {
			return fmt.tprintf("SSRF blocked: %s resolves to private/link-local address", host)
		}
	}
	if !has {
		return fmt.tprintf("DNS empty for %s", host)
	}
	return ""
}

// --- URL helpers ---

Parsed_URL :: struct {
	host: string,
	path: string,
	full: string,
	ok:   bool,
	err:  string,
}

parse_and_normalize_url :: proc(raw: string, allocator := context.allocator) -> Parsed_URL {
	r := strings.trim_space(raw)
	if r == "" {
		return Parsed_URL{err = "url is required"}
	}
	if len(r) > WEB_FETCH_MAX_URL_LENGTH {
		return Parsed_URL{err = fmt.tprintf("url too long (max %d)", WEB_FETCH_MAX_URL_LENGTH)}
	}
	scheme, host_part, path, queries, _ := net.split_url(r, context.temp_allocator)
	if scheme == "" {
		return Parsed_URL{err = "url must include scheme (https://...)"}
	}
	scheme_l := strings.to_lower(scheme, context.temp_allocator)
	if scheme_l != "http" && scheme_l != "https" {
		return Parsed_URL{err = fmt.tprintf("unsupported scheme %s (use http/https)", scheme)}
	}
	if host_part == "" {
		return Parsed_URL{err = "url missing host"}
	}
	host := host_part
	if at := strings.index_byte(host, '@'); at >= 0 {
		host = host[at + 1:]
	}
	host_only := host
	if strings.has_prefix(host, "[") {
		if end := strings.index_byte(host, ']'); end > 0 {
			host_only = host[1:end]
		}
	} else if i := strings.index_byte(host, ':'); i >= 0 {
		host_only = host[:i]
	}
	if path == "" {
		path = "/"
	}
	// rebuild as https (Grok upgrade_to_https)
	b := strings.builder_make(allocator)
	strings.write_string(&b, "https://")
	strings.write_string(&b, host)
	strings.write_string(&b, path)
	if len(queries) > 0 {
		strings.write_byte(&b, '?')
		first := true
		for k, v in queries {
			if !first {
				strings.write_byte(&b, '&')
			}
			first = false
			strings.write_string(&b, k)
			if v != "" {
				strings.write_byte(&b, '=')
				strings.write_string(&b, v)
			}
		}
	}
	return Parsed_URL {
		host = strings.clone(host_only, allocator),
		path = strings.clone(path, allocator),
		full = strings.to_string(b),
		ok   = true,
	}
}

// --- HTML → rough markdown (htmd stand-in) ---

html_to_markdown_simple :: proc(html: string, allocator := context.allocator) -> string {
	s := html
	s = strip_tag_blocks(s, "script", context.temp_allocator)
	s = strip_tag_blocks(s, "style", context.temp_allocator)
	s = strip_tag_blocks(s, "noscript", context.temp_allocator)
	s = strip_tag_blocks(s, "svg", context.temp_allocator)
	s = strip_tag_blocks(s, "iframe", context.temp_allocator)
	s = strip_tag_blocks(s, "object", context.temp_allocator)
	s = strip_tag_blocks(s, "embed", context.temp_allocator)

	b := strings.builder_make(allocator)
	i := 0
	for i < len(s) {
		if s[i] == '<' {
			j := i + 1
			for j < len(s) && s[j] != '>' {
				j += 1
			}
			if j >= len(s) {
				break
			}
			tag := s[i + 1:j]
			tag_l := strings.to_lower(tag, context.temp_allocator)
			if strings.has_prefix(tag_l, "p") ||
			   strings.has_prefix(tag_l, "/p") ||
			   strings.has_prefix(tag_l, "br") ||
			   strings.has_prefix(tag_l, "div") ||
			   strings.has_prefix(tag_l, "/div") ||
			   strings.has_prefix(tag_l, "li") ||
			   strings.has_prefix(tag_l, "/li") ||
			   strings.has_prefix(tag_l, "tr") ||
			   strings.has_prefix(tag_l, "h1") ||
			   strings.has_prefix(tag_l, "h2") ||
			   strings.has_prefix(tag_l, "h3") ||
			   strings.has_prefix(tag_l, "/h") {
				strings.write_byte(&b, '\n')
			}
			if strings.has_prefix(tag_l, "a ") || tag_l == "a" {
				if href := extract_attr(tag, "href"); href != "" {
					strings.write_string(&b, " <")
					strings.write_string(&b, href)
					strings.write_string(&b, "> ")
				}
			}
			i = j + 1
			continue
		}
		if s[i] == '&' {
			if strings.has_prefix(s[i:], "&amp;") {
				strings.write_byte(&b, '&')
				i += 5
				continue
			}
			if strings.has_prefix(s[i:], "&lt;") {
				strings.write_byte(&b, '<')
				i += 4
				continue
			}
			if strings.has_prefix(s[i:], "&gt;") {
				strings.write_byte(&b, '>')
				i += 4
				continue
			}
			if strings.has_prefix(s[i:], "&quot;") {
				strings.write_byte(&b, '"')
				i += 6
				continue
			}
			if strings.has_prefix(s[i:], "&nbsp;") {
				strings.write_byte(&b, ' ')
				i += 6
				continue
			}
		}
		strings.write_byte(&b, s[i])
		i += 1
	}
	raw := strings.to_string(b)
	out := collapse_blank_lines(raw, allocator)
	delete(raw)
	return out
}

strip_tag_blocks :: proc(html, tag: string, allocator := context.allocator) -> string {
	open := fmt.tprintf("<%s", tag)
	close := fmt.tprintf("</%s>", tag)
	b := strings.builder_make(allocator)
	s := html
	for len(s) > 0 {
		low := strings.to_lower(s, context.temp_allocator)
		oi := strings.index(low, open)
		if oi < 0 {
			strings.write_string(&b, s)
			break
		}
		strings.write_string(&b, s[:oi])
		rest := s[oi:]
		gt := strings.index_byte(rest, '>')
		if gt < 0 {
			break
		}
		after_open := rest[gt + 1:]
		low2 := strings.to_lower(after_open, context.temp_allocator)
		ci := strings.index(low2, close)
		if ci < 0 {
			s = after_open
			continue
		}
		s = after_open[ci + len(close):]
	}
	return strings.to_string(b)
}

extract_attr :: proc(tag_inner, name: string) -> string {
	low := strings.to_lower(tag_inner, context.temp_allocator)
	key := fmt.tprintf("%s=", name)
	i := strings.index(low, key)
	if i < 0 {
		return ""
	}
	rest := tag_inner[i + len(key):]
	if len(rest) == 0 {
		return ""
	}
	q := rest[0]
	if q == '"' || q == '\'' {
		rest = rest[1:]
		if j := strings.index_byte(rest, q); j >= 0 {
			return rest[:j]
		}
		return ""
	}
	end := len(rest)
	for j in 0 ..< len(rest) {
		if rest[j] == ' ' || rest[j] == '>' {
			end = j
			break
		}
	}
	return rest[:end]
}

collapse_blank_lines :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	nl := 0
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch == '\n' {
			nl += 1
			if nl <= 2 {
				strings.write_byte(&b, ch)
			}
			continue
		}
		if ch == '\r' {
			continue
		}
		nl = 0
		strings.write_byte(&b, ch)
	}
	return strings.to_string(b)
}

looks_like_html :: proc(body: string) -> bool {
	t := strings.trim_space(body)
	if len(t) >= 15 {
		head := strings.to_lower(t[:15], context.temp_allocator)
		if strings.has_prefix(head, "<!doctype html") {
			return true
		}
	}
	if len(t) >= 5 {
		head := strings.to_lower(t[:5], context.temp_allocator)
		if strings.has_prefix(head, "<html") {
			return true
		}
	}
	return false
}

truncate_bytes :: proc(s: string, max_bytes: int, allocator := context.allocator) -> string {
	if len(s) <= max_bytes {
		return strings.clone(s, allocator)
	}
	n := utf8_safe_prefix_len(s, max_bytes)
	return fmt.aprintf("%s\n\n…[truncated at %d bytes]", s[:n], max_bytes, allocator = allocator)
}

utf8_safe_prefix_len :: proc(s: string, max_bytes: int) -> int {
	n := max_bytes
	if n > len(s) {
		n = len(s)
	}
	for n > 0 && n < len(s) && (s[n] & 0xc0) == 0x80 {
		n -= 1
	}
	if n <= 0 {
		return min(max_bytes, len(s))
	}
	return n
}

// --- binary body detection ---

is_binary_body :: proc(body: string) -> bool {
	if len(body) == 0 {
		return false
	}
	// Common binary magic
	if len(body) >= 4 {
		if body[0] == '%' && body[1] == 'P' && body[2] == 'D' && body[3] == 'F' {
			return true
		}
		if u8(body[0]) == 0x89 && body[1] == 'P' && body[2] == 'N' && body[3] == 'G' {
			return true
		}
		if u8(body[0]) == 0xff && u8(body[1]) == 0xd8 && u8(body[2]) == 0xff {
			return true
		}
		if body[0] == 'G' && body[1] == 'I' && body[2] == 'F' {
			return true
		}
		if body[0] == 'P' && body[1] == 'K' && (body[2] == 0x03 || body[2] == 0x05 || body[2] == 0x07) {
			return true // zip/docx/jar
		}
	}
	n := min(len(body), WEB_FETCH_BINARY_SAMPLE)
	sample := body[:n]
	non_print := 0
	for i in 0 ..< n {
		b := sample[i]
		if b == 0 {
			return true
		}
		if b < 9 || (b >= 14 && b <= 31) {
			non_print += 1
		}
	}
	return f64(non_print) / f64(n) > 0.3
}

// --- payload format / artifact ---

web_fetch_payload_ext :: proc(content: string, ctype: string) -> string {
	cl := strings.to_lower(ctype, context.temp_allocator)
	if strings.contains(cl, "markdown") || ctype == "markdown" {
		return "md"
	}
	if strings.contains(cl, "json") {
		return "json"
	}
	t := strings.trim_space(content)
	if len(t) > 0 && (t[0] == '{' || t[0] == '[') {
		// cheap JSON sniff
		return "json"
	}
	if looks_like_html(content) {
		return "md"
	}
	return "txt"
}

web_fetch_artifact_dir :: proc(allocator := context.allocator) -> string {
	if v := os.get_env("AETHER_WEB_FETCH_DIR", context.temp_allocator); v != "" {
		return strings.clone(v, allocator)
	}
	base := core.aether_sessions_dir("", context.temp_allocator)
	joined, _ := filepath.join({base, "web_fetch"}, allocator)
	return joined
}

web_fetch_save_artifact :: proc(
	content: string,
	ext: string,
	allocator := context.allocator,
) -> (path: string, ok: bool) {
	dir := web_fetch_artifact_dir(context.temp_allocator)
	if !core.ensure_dir(dir) {
		return "", false
	}
	sync.mutex_lock(&g_web_fetch_art_mu)
	g_web_fetch_art_ctr += 1
	n := g_web_fetch_art_ctr
	// Also bump past any existing numbered files
	if fis, ferr := os.read_all_directory_by_path(dir, context.temp_allocator); ferr == nil {
		for e in fis {
			name := e.name
			dot := strings.index_byte(name, '.')
			if dot <= 0 {
				continue
			}
			num_s := name[:dot]
			num := 0
			valid := true
			for ch in num_s {
				if ch < '0' || ch > '9' {
					valid = false
					break
				}
				num = num * 10 + int(ch - '0')
			}
			if valid && num >= n {
				n = num + 1
				g_web_fetch_art_ctr = n
			}
		}
	}
	sync.mutex_unlock(&g_web_fetch_art_mu)

	e := ext
	if e == "" {
		e = "txt"
	}
	name := fmt.tprintf("%d.%s", n, e)
	p, jerr := filepath.join({dir, name}, allocator)
	if jerr != nil {
		return "", false
	}
	if werr := os.write_entire_file(p, transmute([]byte)content); werr != nil {
		delete(p)
		return "", false
	}
	return p, true
}

// apply_overflow: if content fits preview, clone; else save artifact + recovery footer.
web_fetch_apply_overflow :: proc(
	content: string,
	ctype: string,
	allocator := context.allocator,
) -> string {
	preview_cap := min(WEB_FETCH_PREVIEW_BYTES, WEB_FETCH_MAX_MARKDOWN)
	if len(content) <= preview_cap {
		// still hard-cap at MAX_MARKDOWN (same as preview when smaller)
		return strings.clone(content, allocator)
	}

	ext := web_fetch_payload_ext(content, ctype)
	art_path, saved := web_fetch_save_artifact(content, ext, context.temp_allocator)

	// preview must leave room for footer
	file_hint := ""
	if saved {
		file_hint = fmt.tprintf(
			" Full content saved to: %s. Use `read_file` with offsets and limits to read it in chunks.",
			art_path,
		)
	}
	footer := fmt.tprintf(
		"\n\n[web_fetch content truncated: showing first %d of %d bytes.%s]",
		0, // filled after we know preview len
		len(content),
		file_hint,
	)
	// provisional footer with placeholder length — rebuild with real shown bytes
	room := WEB_FETCH_MAX_MARKDOWN - 200 // reserve for footer
	if room < 512 {
		room = 512
	}
	if room > preview_cap {
		room = preview_cap
	}
	shown := utf8_safe_prefix_len(content, room)
	footer = fmt.tprintf(
		"\n\n[web_fetch content truncated: showing first %d of %d bytes.%s]",
		shown,
		len(content),
		file_hint,
	)
	// ensure total under MAX_MARKDOWN
	for len(content[:shown]) + len(footer) > WEB_FETCH_MAX_MARKDOWN && shown > 512 {
		shown = utf8_safe_prefix_len(content, shown - 256)
		footer = fmt.tprintf(
			"\n\n[web_fetch content truncated: showing first %d of %d bytes.%s]",
			shown,
			len(content),
			file_hint,
		)
	}
	return fmt.aprintf("%s%s", content[:shown], footer, allocator = allocator)
}

// --- process-local cache ---

web_fetch_cache_disabled :: proc() -> bool {
	v := os.get_env("AETHER_WEB_FETCH_NO_CACHE", context.temp_allocator)
	return v == "1" || strings.equal_fold(v, "true")
}

web_fetch_cache_get :: proc(url: string, allocator := context.allocator) -> (string, bool) {
	if web_fetch_cache_disabled() {
		return "", false
	}
	sync.mutex_lock(&g_web_fetch_cache_mu)
	defer sync.mutex_unlock(&g_web_fetch_cache_mu)
	now := time.now()
	for e in g_web_fetch_cache {
		if e.url != url {
			continue
		}
		age := time.diff(e.at, now)
		if age > time.Duration(WEB_FETCH_CACHE_TTL_S) * time.Second {
			return "", false
		}
		return strings.clone(e.body, allocator), true
	}
	return "", false
}

web_fetch_cache_put :: proc(url, body: string) {
	if web_fetch_cache_disabled() {
		return
	}
	sync.mutex_lock(&g_web_fetch_cache_mu)
	defer sync.mutex_unlock(&g_web_fetch_cache_mu)
	if g_web_fetch_cache == nil {
		g_web_fetch_cache = make([dynamic]Web_Fetch_Cache_Entry, 0, WEB_FETCH_CACHE_MAX)
	}
	// update existing
	for i in 0 ..< len(g_web_fetch_cache) {
		if g_web_fetch_cache[i].url == url {
			delete(g_web_fetch_cache[i].body)
			g_web_fetch_cache[i].body = strings.clone(body)
			g_web_fetch_cache[i].at = time.now()
			return
		}
	}
	// FIFO evict when full
	if len(g_web_fetch_cache) >= WEB_FETCH_CACHE_MAX {
		delete(g_web_fetch_cache[0].url)
		delete(g_web_fetch_cache[0].body)
		ordered_remove(&g_web_fetch_cache, 0)
	}
	append(
		&g_web_fetch_cache,
		Web_Fetch_Cache_Entry {
			url  = strings.clone(url),
			body = strings.clone(body),
			at   = time.now(),
		},
	)
}

// web_fetch_url is the core path (Grok WebFetchClient.fetch, product Full).
web_fetch_url :: proc(raw_url: string, allocator := context.allocator) -> string {
	if !web_fetch_enabled() {
		return strings.clone("error: web_fetch disabled (AETHER_NO_WEB_FETCH=1)", allocator)
	}
	parsed := parse_and_normalize_url(raw_url, context.temp_allocator)
	if !parsed.ok {
		return fmt.aprintf("Error: %s", parsed.err, allocator = allocator)
	}
	if !domain_allowed(parsed.host, parsed.path) {
		return fmt.aprintf(
			"Error: domain %s is not in the allowed domains list",
			normalize_domain(parsed.host),
			allocator = allocator,
		)
	}
	if ssrf := check_ssrf_host(parsed.host); ssrf != "" {
		return fmt.aprintf("Error: %s", ssrf, allocator = allocator)
	}

	if cached, hit := web_fetch_cache_get(parsed.full, allocator); hit {
		return cached
	}

	headers := []string{
		fmt.tprintf("User-Agent: %s", WEB_FETCH_USER_AGENT),
		"Accept: text/markdown,text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
		"Accept-Language: en-US,en;q=0.9",
	}
	opts := Http_Opts {
		connect_timeout_s = 15,
		timeout_s         = WEB_FETCH_TIMEOUT_S,
	}
	_ = core.user_agent // keep aether UA module linked; fetch sets Grok-compatible header
	resp, herr := http_get(parsed.full, headers, context.temp_allocator, opts)
	if herr != .None {
		return fmt.aprintf(
			"Error fetching URL %s: %s",
			parsed.full,
			http_error_string(herr),
			allocator = allocator,
		)
	}
	if resp.status < 200 || resp.status >= 400 {
		return fmt.aprintf(
			"Error fetching URL %s: HTTP %d",
			parsed.full,
			resp.status,
			allocator = allocator,
		)
	}
	body := resp.body
	raw_len := len(body)
	if raw_len > WEB_FETCH_MAX_CONTENT {
		body = body[:WEB_FETCH_MAX_CONTENT]
	}

	if is_binary_body(body) {
		return fmt.aprintf(
			"error: web_fetch cannot inline binary content (bytes=%d). Use shell download or open the URL in a browser.",
			raw_len,
			allocator = allocator,
		)
	}

	content: string
	ctype: string
	if looks_like_html(body) {
		content = html_to_markdown_simple(body, context.temp_allocator)
		ctype = "markdown"
	} else {
		content = body
		ctype = "text/plain"
	}
	out_body := web_fetch_apply_overflow(content, ctype, context.temp_allocator)
	result := fmt.aprintf(
		"URL: %s\nStatus: %d\nContent-Type: %s\nBytes: %d\n\n%s",
		parsed.full,
		resp.status,
		ctype,
		raw_len,
		out_body,
		allocator = allocator,
	)
	web_fetch_cache_put(parsed.full, result)
	return result
}

// web_fetch_from_args parses tool JSON {"url":"..."} and runs the fetch.
web_fetch_from_args :: proc(arguments_json: string, allocator := context.allocator) -> string {
	val, err := json.parse(
		transmute([]byte)arguments_json,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if err != nil {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	obj, ok := val.(json.Object)
	if !ok {
		return strings.clone("error: arguments must be object", allocator)
	}
	url_s := ""
	if v, has := obj["url"]; has {
		if s, is_s := v.(json.String); is_s {
			url_s = string(s)
		}
	}
	if strings.trim_space(url_s) == "" {
		return strings.clone("error: url is required", allocator)
	}
	return web_fetch_url(url_s, allocator)
}
