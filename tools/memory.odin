// Package tools — file-backed memory_search / memory_get + session log writers.
// Layout matches Grok: MEMORY.md, {slug}/MEMORY.md, {slug}/sessions/*.md.
// No SQLite / embeddings / dream (A2.2).
package tools

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:time"
import "aether:core"

MEMORY_MAX_RESULTS_DEFAULT :: 6
MEMORY_MAX_RESULTS_CAP :: 20
MEMORY_MAX_FILES :: 80
MEMORY_MAX_FILE_BYTES :: 2 * 1024 * 1024
MEMORY_MAX_TOTAL_BYTES :: 8 * 1024 * 1024
MEMORY_CHUNK_LINES :: 40
MEMORY_CHUNK_OVERLAP :: 10

// Test hooks (avoid env races under parallel odin test).
@(private)
g_memory_root_override: string
@(private)
g_memory_force_disabled: bool
// Process-local force-enable via /memory on (overrides config [memory] enabled=false;
// AETHER_NO_MEMORY env kill-switch still wins).
@(private)
g_memory_force_enabled: bool

// memory_enabled is false when AETHER_NO_MEMORY=1 (or true/yes/on).
// Config [memory] enabled=false also disables unless /memory on forced.
// Process toggle: memory_set_process_enabled (/memory on|off).
memory_enabled :: proc() -> bool {
	if g_memory_force_disabled {
		return false
	}
	if v := os.get_env("AETHER_NO_MEMORY", context.temp_allocator); v == "1" ||
	   v == "true" ||
	   v == "yes" ||
	   v == "on" {
		return false
	}
	if g_memory_force_enabled {
		return true
	}
	if !core.flag_memory() {
		return false
	}
	return true
}

// memory_set_process_enabled: Grok-shaped /memory on|off for this process.
// on → clear force-off, force-on (overrides config false; not AETHER_NO_MEMORY).
// off → force-off for this process.
// Returns true if memory_enabled() after the change (env may still block "on").
memory_set_process_enabled :: proc(on: bool) -> bool {
	if on {
		g_memory_force_disabled = false
		g_memory_force_enabled = true
	} else {
		g_memory_force_enabled = false
		g_memory_force_disabled = true
	}
	return memory_enabled()
}

// memory_clear_process_override: reset on/off latch (tests / default).
memory_clear_process_override :: proc() {
	g_memory_force_disabled = false
	g_memory_force_enabled = false
}

// memory_root returns AETHER_MEMORY_DIR, else $GROK_HOME/memory, else ~/.grok/memory.
memory_root :: proc(allocator := context.allocator) -> string {
	if g_memory_root_override != "" {
		return strings.clone(g_memory_root_override, allocator)
	}
	if v := os.get_env("AETHER_MEMORY_DIR", context.temp_allocator); v != "" {
		return strings.clone(v, allocator)
	}
	if gh := os.get_env("GROK_HOME", context.temp_allocator); gh != "" {
		joined, _ := filepath.join({gh, "memory"}, allocator)
		return joined
	}
	home, err := os.user_home_dir(context.temp_allocator)
	if err != nil || home == "" {
		return strings.clone(".grok/memory", allocator)
	}
	joined, _ := filepath.join({home, ".grok", "memory"}, allocator)
	return joined
}

// path_under_root reports whether abs is root or a descendant (prefix + separator).
path_under_root :: proc(root, abs: string) -> bool {
	if abs == root {
		return true
	}
	if !strings.has_prefix(abs, root) || len(abs) <= len(root) {
		return false
	}
	ch := abs[len(root)]
	return ch == '/' || ch == '\\'
}

// resolve_under_memory_root joins/cleans path and requires it stay under memory root.
resolve_under_memory_root :: proc(
	root: string,
	path: string,
	allocator := context.allocator,
) -> (
	abs: string,
	ok: bool,
) {
	if path == "" {
		return "", false
	}
	root_abs := root
	if r, err := filepath.abs(root, context.temp_allocator); err == nil {
		root_abs = r
	}
	if cleaned, cerr := filepath.clean(root_abs, context.temp_allocator); cerr == nil {
		root_abs = cleaned
	}

	target: string
	if os.is_absolute_path(path) {
		target = path
	} else {
		j, jerr := filepath.join({root_abs, path}, context.temp_allocator)
		if jerr != nil {
			return "", false
		}
		target = j
	}
	if t, err := filepath.abs(target, context.temp_allocator); err == nil {
		target = t
	}
	if cleaned, cerr := filepath.clean(target, context.temp_allocator); cerr == nil {
		target = cleaned
	}
	if !path_under_root(root_abs, target) {
		return "", false
	}
	return strings.clone(target, allocator), true
}

// format_memory_lines numbers lines starting at first_line_num (1-based).
// Uses split on '\n' so a trailing newline yields a trailing blank numbered line.
format_memory_lines :: proc(content: string, first_line_num: int, allocator := context.allocator) -> string {
	if content == "" {
		return strings.clone("", allocator)
	}
	parts := strings.split(content, "\n", context.temp_allocator)
	b := strings.builder_make(allocator)
	for line, i in parts {
		if i > 0 {
			strings.write_byte(&b, '\n')
		}
		strings.write_string(&b, fmt.tprintf("%d→%s", first_line_num + i, line))
	}
	return strings.to_string(b)
}

tool_memory_get :: proc(arguments_json: string, allocator := context.allocator) -> string {
	if !memory_enabled() {
		return strings.clone("error: memory is disabled (AETHER_NO_MEMORY=1)", allocator)
	}
	obj, ok := json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	path := jstr(obj, "path")
	if path == "" {
		return strings.clone("error: path is required", allocator)
	}
	from := jint(obj, "from", 0) // 0-based
	if from < 0 {
		from = 0
	}
	// lines: 0 or missing means all remaining (use -1 sentinel for missing)
	lines_limit := -1
	if _, has := obj["lines"]; has {
		lines_limit = jint(obj, "lines", 0)
		if lines_limit < 0 {
			lines_limit = 0
		}
	}

	root := memory_root(context.temp_allocator)
	abs, under := resolve_under_memory_root(root, path, context.temp_allocator)
	if !under {
		return strings.clone("error: path is outside the memory root", allocator)
	}
	data, rerr := os.read_entire_file(abs, context.temp_allocator)
	if rerr != nil {
		return fmt.aprintf("error: cannot read %s: %v", path, rerr, allocator = allocator)
	}
	text := string(data)

	// Split like format_memory_lines (preserve trailing empty after final newline).
	all_parts := strings.split(text, "\n", context.temp_allocator)
	// If file is empty, no parts of interest.
	total := len(all_parts)
	if total == 0 {
		return fmt.aprintf(
			"**File:** %s\n**Lines:** 0 (from: %s, limit: %s)\n\n",
			abs,
			from_label(from),
			lines_label(lines_limit),
			allocator = allocator,
		)
	}
	start := from
	if start > total {
		start = total
	}
	end := total
	if lines_limit >= 0 {
		end = start + lines_limit
		if end > total {
			end = total
		}
	}
	// Reconstruct content slice for the requested window.
	// Join selected parts with \n.
	b_slice := strings.builder_make(context.temp_allocator)
	for i in start ..< end {
		if i > start {
			strings.write_byte(&b_slice, '\n')
		}
		strings.write_string(&b_slice, all_parts[i])
	}
	window := strings.to_string(b_slice)
	numbered := format_memory_lines(window, start + 1, context.temp_allocator)
	shown := end - start
	return fmt.aprintf(
		"**File:** %s\n**Lines:** %d (from: %s, limit: %s)\n\n%s",
		abs,
		shown,
		from_label(from),
		lines_label(lines_limit),
		numbered,
		allocator = allocator,
	)
}

from_label :: proc(from: int) -> string {
	if from <= 0 {
		return "start"
	}
	return fmt.tprintf("%d", from)
}

lines_label :: proc(limit: int) -> string {
	if limit < 0 {
		return "all"
	}
	return fmt.tprintf("%d", limit)
}

// --- search ---

Memory_Source :: enum {
	Global,
	Workspace,
	Session,
	Other,
}

memory_source_string :: proc(s: Memory_Source) -> string {
	switch s {
	case .Global:
		return "global"
	case .Workspace:
		return "workspace"
	case .Session:
		return "session"
	case .Other:
		return "other"
	}
	return "other"
}

memory_source_weight :: proc(s: Memory_Source) -> f64 {
	switch s {
	case .Workspace:
		return 1.0
	case .Session:
		return 0.9
	case .Global:
		return 0.85
	case .Other:
		return 0.5
	}
	return 0.5
}

Memory_Hit :: struct {
	path:       string,
	start_line: int, // 1-based
	end_line:   int, // 1-based inclusive
	snippet:    string,
	score:      f64,
	source:     Memory_Source,
}

tool_memory_search :: proc(
	arguments_json: string,
	workspace: string,
	allocator := context.allocator,
) -> string {
	if !memory_enabled() {
		return strings.clone("error: memory is disabled (AETHER_NO_MEMORY=1)", allocator)
	}
	obj, ok := json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	query := strings.trim_space(jstr(obj, "query"))
	if query == "" {
		return strings.clone("error: query is required", allocator)
	}
	max_results := jint(obj, "max_results", MEMORY_MAX_RESULTS_DEFAULT)
	if max_results <= 0 {
		max_results = MEMORY_MAX_RESULTS_DEFAULT
	}
	if max_results > MEMORY_MAX_RESULTS_CAP {
		max_results = MEMORY_MAX_RESULTS_CAP
	}
	min_score := jfloat(obj, "min_score", 0.0)

	tokens := tokenize_query(query, context.temp_allocator)
	if len(tokens) == 0 {
		return strings.clone("No memory results found for query.", allocator)
	}

	root := memory_root(context.temp_allocator)
	if !os.exists(root) || !os.is_directory(root) {
		return fmt.aprintf(
			"No memory results found (memory root missing or empty: %s). Use /flush to write session notes.",
			root,
			allocator = allocator,
		)
	}

	ws_abs := workspace
	if workspace != "" {
		if a, err := filepath.abs(workspace, context.temp_allocator); err == nil {
			ws_abs = a
		}
	}
	ws_base := filepath.base(ws_abs)

	candidates := collect_memory_files(root, ws_abs, ws_base, context.temp_allocator)
	hits := make([dynamic]Memory_Hit, 0, 32, context.temp_allocator)
	total_bytes := 0
	for c in candidates {
		if total_bytes >= MEMORY_MAX_TOTAL_BYTES {
			break
		}
		info, ierr := os.stat(c.path, context.temp_allocator)
		if ierr != nil {
			continue
		}
		if info.size > i64(MEMORY_MAX_FILE_BYTES) {
			continue
		}
		data, rerr := os.read_entire_file(c.path, context.temp_allocator)
		if rerr != nil {
			continue
		}
		total_bytes += len(data)
		text := string(data)
		file_hits := score_file_chunks(c.path, text, c.source, tokens, context.temp_allocator)
		for h in file_hits {
			append(&hits, h)
		}
	}

	// Sort by score descending
	slice.sort_by(hits[:], proc(a, b: Memory_Hit) -> bool {
		return a.score > b.score
	})

	// Filter min_score and take top
	kept := make([dynamic]Memory_Hit, 0, max_results, context.temp_allocator)
	for h in hits {
		if h.score < min_score {
			continue
		}
		append(&kept, h)
		if len(kept) >= max_results {
			break
		}
	}

	if len(kept) == 0 {
		return strings.clone("No memory results found for query.", allocator)
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, fmt.tprintf("Found %d memory result(s):\n", len(kept)))
	for h, i in kept {
		strings.write_string(
			&b,
			fmt.tprintf(
				"\n### Result %d (score: %.2f, source: %s)\n**File:** %s (lines %d-%d)\n```\n%s\n```\n",
				i + 1,
				h.score,
				memory_source_string(h.source),
				h.path,
				h.start_line,
				h.end_line,
				h.snippet,
			),
		)
	}
	return strings.to_string(b)
}

jfloat :: proc(obj: json.Object, key: string, default: f64 = 0) -> f64 {
	v, ok := obj[key]
	if !ok {
		return default
	}
	#partial switch n in v {
	case json.Float:
		return f64(n)
	case json.Integer:
		return f64(n)
	case json.String:
		// best-effort: only integers in string form
		parsed, ok2 := parse_positive_int(string(n))
		if ok2 {
			return f64(parsed)
		}
	}
	return default
}

tokenize_query :: proc(query: string, allocator := context.allocator) -> []string {
	lower := strings.to_lower(query, context.temp_allocator)
	out := make([dynamic]string, 0, 8, allocator)
	start := -1
	for i in 0 ..= len(lower) {
		at_end := i == len(lower)
		ch: u8 = 0
		if !at_end {
			ch = lower[i]
		}
		is_alnum := !at_end && ((ch >= 'a' && ch <= 'z') || (ch >= '0' && ch <= '9'))
		if is_alnum {
			if start < 0 {
				start = i
			}
		} else if start >= 0 {
			tok := lower[start:i]
			if len(tok) >= 2 && !token_seen(out[:], tok) {
				append(&out, strings.clone(tok, allocator))
			}
			start = -1
		}
	}
	return out[:]
}

token_seen :: proc(tokens: []string, t: string) -> bool {
	for x in tokens {
		if x == t {
			return true
		}
	}
	return false
}

Mem_File :: struct {
	path:   string,
	source: Memory_Source,
}

// collect_memory_files walks the memory root for .md files with source labels.
collect_memory_files :: proc(
	root: string,
	ws_abs: string,
	ws_base: string,
	allocator := context.allocator,
) -> []Mem_File {
	out := make([dynamic]Mem_File, 0, 32, allocator)
	// Global MEMORY.md
	global_md, _ := filepath.join({root, "MEMORY.md"}, context.temp_allocator)
	if os.exists(global_md) && !os.is_directory(global_md) {
		abs, _ := filepath.abs(global_md, allocator)
		append(&out, Mem_File{path = abs, source = .Global})
	}

	// Workspace subdirs
	fis, ferr := os.read_all_directory_by_path(root, context.temp_allocator)
	if ferr != nil {
		return out[:]
	}
	for fi in fis {
		if fi.type != .Directory {
			continue
		}
		name := fi.name
		if name == "" || name[0] == '.' {
			continue
		}
		ws_dir, _ := filepath.join({root, name}, context.temp_allocator)
		preferred := is_preferred_workspace(ws_dir, name, ws_abs, ws_base)

		// MEMORY.md in workspace
		mem_md, _ := filepath.join({ws_dir, "MEMORY.md"}, context.temp_allocator)
		if os.exists(mem_md) && !os.is_directory(mem_md) {
			abs, _ := filepath.abs(mem_md, allocator)
			src: Memory_Source = .Other
			if preferred {
				src = .Workspace
			}
			append(&out, Mem_File{path = abs, source = src})
		}

		// sessions/*.md
		sess_dir, _ := filepath.join({ws_dir, "sessions"}, context.temp_allocator)
		if os.exists(sess_dir) && os.is_directory(sess_dir) {
			sfis, sferr := os.read_all_directory_by_path(sess_dir, context.temp_allocator)
			if sferr == nil {
				for sfi in sfis {
					if sfi.type == .Directory {
						continue
					}
					if !strings.has_suffix(sfi.name, ".md") {
						continue
					}
					sp, _ := filepath.join({sess_dir, sfi.name}, context.temp_allocator)
					abs, _ := filepath.abs(sp, allocator)
					src: Memory_Source = .Other
					if preferred {
						src = .Session
					}
					append(&out, Mem_File{path = abs, source = src})
					if len(out) >= MEMORY_MAX_FILES {
						return out[:]
					}
				}
			}
		}
		if len(out) >= MEMORY_MAX_FILES {
			break
		}
	}
	return out[:]
}

is_preferred_workspace :: proc(ws_dir, dir_name, ws_abs, ws_base: string) -> bool {
	if ws_base != "" {
		if dir_name == ws_base {
			return true
		}
		prefix := fmt.tprintf("%s-", ws_base)
		if strings.has_prefix(dir_name, prefix) {
			return true
		}
	}
	if ws_abs == "" {
		return false
	}
	mem_md, _ := filepath.join({ws_dir, "MEMORY.md"}, context.temp_allocator)
	data, err := os.read_entire_file(mem_md, context.temp_allocator)
	if err != nil {
		return false
	}
	// Check first ~2k for workspace path
	text := string(data)
	if len(text) > 2048 {
		text = text[:2048]
	}
	return strings.contains(text, ws_abs)
}

score_file_chunks :: proc(
	path: string,
	text: string,
	source: Memory_Source,
	tokens: []string,
	allocator := context.allocator,
) -> []Memory_Hit {
	if text == "" || len(tokens) == 0 {
		return nil
	}
	lines := strings.split(text, "\n", context.temp_allocator)
	n := len(lines)
	if n == 0 {
		return nil
	}
	path_lower := strings.to_lower(path, context.temp_allocator)
	weight := memory_source_weight(source)
	n_tok := f64(len(tokens))
	hits := make([dynamic]Memory_Hit, 0, 4, allocator)

	step := MEMORY_CHUNK_LINES - MEMORY_CHUNK_OVERLAP
	if step < 1 {
		step = 1
	}
	start := 0
	for start < n {
		end := start + MEMORY_CHUNK_LINES
		if end > n {
			end = n
		}
		// Build chunk text
		b := strings.builder_make(context.temp_allocator)
		for i in start ..< end {
			if i > start {
				strings.write_byte(&b, '\n')
			}
			strings.write_string(&b, lines[i])
		}
		chunk := strings.to_string(b)
		chunk_lower := strings.to_lower(chunk, context.temp_allocator)

		hits_count := 0.0
		for tok in tokens {
			if strings.contains(chunk_lower, tok) {
				hits_count += 1.0
			} else if strings.contains(path_lower, tok) {
				hits_count += 0.5
			}
		}
		if hits_count > 0 {
			raw := hits_count / n_tok
			score := raw * weight
			if score > 1.0 {
				score = 1.0
			}
			// Cap snippet length for output
			snippet := chunk
			if len(snippet) > 1200 {
				snippet = snippet[:1200]
			}
			append(
				&hits,
				Memory_Hit{
					path = strings.clone(path, allocator),
					start_line = start + 1,
					end_line = end,
					snippet = strings.clone(snippet, allocator),
					score = score,
					source = source,
				},
			)
		}
		if end >= n {
			break
		}
		start += step
	}
	return hits[:]
}

// --- writers (A2.1) ---

// memory_workspace_slug sanitizes filepath.base(cwd) for a memory directory name.
// Allows alnum + '-' + '_'; other chars become '-'; empty → "default".
memory_workspace_slug :: proc(cwd: string, allocator := context.allocator) -> string {
	base := filepath.base(cwd)
	if base == "" || base == "." || base == "/" {
		return strings.clone("default", allocator)
	}
	b := strings.builder_make(allocator)
	for i in 0 ..< len(base) {
		ch := base[i]
		ok :=
			(ch >= 'A' && ch <= 'Z') ||
			(ch >= 'a' && ch <= 'z') ||
			(ch >= '0' && ch <= '9') ||
			ch == '-' ||
			ch == '_'
		if ok {
			strings.write_byte(&b, ch)
		} else {
			strings.write_byte(&b, '-')
		}
	}
	out := strings.to_string(b)
	// collapse empty / only-dashes
	only_dash := true
	for i in 0 ..< len(out) {
		if out[i] != '-' {
			only_dash = false
			break
		}
	}
	if out == "" || only_dash {
		delete(out)
		return strings.clone("default", allocator)
	}
	return out
}

// memory_workspace_dir returns {root}/{slug} for cwd (allocated).
memory_workspace_dir :: proc(cwd: string, allocator := context.allocator) -> string {
	root := memory_root(context.temp_allocator)
	slug := memory_workspace_slug(cwd, context.temp_allocator)
	joined, _ := filepath.join({root, slug}, allocator)
	return joined
}

// memory_today_ymd returns local calendar date as YYYY-MM-DD.
memory_today_ymd :: proc(allocator := context.allocator) -> string {
	t := time.now()
	dt, ok := time.time_to_datetime(t)
	if !ok {
		return strings.clone("1970-01-01", allocator)
	}
	return fmt.aprintf("%04d-%02d-%02d", dt.year, int(dt.month), dt.day, allocator = allocator)
}

// memory_flush_timestamp returns "HH:MM:SS UTC" for flush HTML comments.
memory_flush_timestamp :: proc(allocator := context.allocator) -> string {
	t := time.now()
	dt, ok := time.time_to_datetime(t)
	if !ok {
		return strings.clone("00:00:00 UTC", allocator)
	}
	return fmt.aprintf(
		"%02d:%02d:%02d UTC",
		dt.hour,
		dt.minute,
		dt.second,
		allocator = allocator,
	)
}

// memory_session_log_path returns {root}/{slug}/sessions/{day}.md (allocated).
// day should be YYYY-MM-DD; empty uses today.
memory_session_log_path :: proc(
	cwd: string,
	day: string = "",
	allocator := context.allocator,
) -> string {
	d := day
	if d == "" {
		d = memory_today_ymd(context.temp_allocator)
	}
	ws := memory_workspace_dir(cwd, context.temp_allocator)
	joined, _ := filepath.join({ws, "sessions", fmt.tprintf("%s.md", d)}, allocator)
	return joined
}

// memory_append_session_log creates parents and appends body to the daily session log.
// Uses --- + <!-- flush HH:MM:SS UTC --> separator when the file already has content.
// Returns absolute path written, or err message (path empty on error).
memory_append_session_log :: proc(
	cwd: string,
	body: string,
	allocator := context.allocator,
) -> (
	path: string,
	err: string,
) {
	if !memory_enabled() {
		return "", strings.clone("memory is disabled (AETHER_NO_MEMORY=1)", allocator)
	}
	trimmed := strings.trim_space(body)
	if trimmed == "" {
		return "", strings.clone("empty content", allocator)
	}

	root := memory_root(context.temp_allocator)
	slug := memory_workspace_slug(cwd, context.temp_allocator)
	day := memory_today_ymd(context.temp_allocator)
	// Relative path under root for boundary check
	rel, _ := filepath.join({slug, "sessions", fmt.tprintf("%s.md", day)}, context.temp_allocator)
	abs, under := resolve_under_memory_root(root, rel, context.temp_allocator)
	if !under {
		return "", strings.clone("error: session log path outside memory root", allocator)
	}

	parent := filepath.dir(abs)
	if parent != "" && !os.exists(parent) {
		if os.make_directory_all(parent) != nil {
			return "", fmt.aprintf("cannot create directory %s", parent, allocator = allocator)
		}
	}

	stamp := memory_flush_timestamp(context.temp_allocator)
	chunk: string
	existing_len := 0
	if os.exists(abs) && !os.is_directory(abs) {
		if data, rerr := os.read_entire_file(abs, context.temp_allocator); rerr == nil {
			existing_len = len(data)
		}
	}
	if existing_len > 0 {
		chunk = fmt.tprintf("\n\n---\n\n<!-- flush %s -->\n\n%s", stamp, trimmed)
	} else {
		chunk = fmt.tprintf("<!-- flush %s -->\n\n%s", stamp, trimmed)
	}

	// Read-modify-write (session logs stay modest; avoids O_APPEND portability issues).
	combined: string
	if existing_len > 0 {
		prev, rerr := os.read_entire_file(abs, context.temp_allocator)
		if rerr != nil {
			return "", fmt.aprintf("cannot read %s: %v", abs, rerr, allocator = allocator)
		}
		combined = fmt.tprintf("%s%s", string(prev), chunk)
	} else {
		combined = chunk
	}
	if werr := os.write_entire_file(abs, transmute([]byte)combined); werr != nil {
		return "", fmt.aprintf("cannot write %s: %v", abs, werr, allocator = allocator)
	}
	return strings.clone(abs, allocator), ""
}

// memory_count_md_files counts .md files under root (non-recursive beyond 2 levels).
memory_count_md_files :: proc(root: string) -> int {
	if root == "" || !os.exists(root) || !os.is_directory(root) {
		return 0
	}
	n := 0
	// global MEMORY.md
	g, _ := filepath.join({root, "MEMORY.md"}, context.temp_allocator)
	if os.exists(g) && !os.is_directory(g) {
		n += 1
	}
	fis, ferr := os.read_all_directory_by_path(root, context.temp_allocator)
	if ferr != nil {
		return n
	}
	for fi in fis {
		if fi.type != .Directory {
			if strings.has_suffix(fi.name, ".md") && fi.name != "MEMORY.md" {
				n += 1
			}
			continue
		}
		if fi.name == "" || fi.name[0] == '.' {
			continue
		}
		ws, _ := filepath.join({root, fi.name}, context.temp_allocator)
		wmd, _ := filepath.join({ws, "MEMORY.md"}, context.temp_allocator)
		if os.exists(wmd) && !os.is_directory(wmd) {
			n += 1
		}
		sess, _ := filepath.join({ws, "sessions"}, context.temp_allocator)
		if os.exists(sess) && os.is_directory(sess) {
			sfis, sferr := os.read_all_directory_by_path(sess, context.temp_allocator)
			if sferr == nil {
				for sfi in sfis {
					if sfi.type != .Directory && strings.has_suffix(sfi.name, ".md") {
						n += 1
					}
				}
			}
		}
	}
	return n
}

// memory_status_text is the multi-line body for /memory status (allocated).
memory_status_text :: proc(cwd: string, allocator := context.allocator) -> string {
	root := memory_root(context.temp_allocator)
	slug := memory_workspace_slug(cwd, context.temp_allocator)
	enabled := memory_enabled()
	n := 0
	if enabled {
		n = memory_count_md_files(root)
	}
	return fmt.aprintf(
		"memory: %s\nroot:    %s\nslug:    %s\nfiles:   %d markdown under root\nopt-out: AETHER_NO_MEMORY=1\nwriters: /flush, /dream; first-turn inject + auto-dream (A2.3)",
		"enabled" if enabled else "DISABLED",
		root,
		slug,
		n,
		allocator = allocator,
	)
}

// --- dream writers / lock (A2.2) ---

DREAM_LOCK_NAME :: ".dream-lock"
DREAM_STALE_LOCK_SECS :: u64(3600)
DREAM_CLEANUP_RECENCY_SECS :: u64(300)
DREAM_MIN_HOURS :: u64(4)
DREAM_MIN_SESSIONS :: u64(3)

// memory_workspace_md_path returns {ws}/MEMORY.md (allocated).
memory_workspace_md_path :: proc(cwd: string, allocator := context.allocator) -> string {
	ws := memory_workspace_dir(cwd, context.temp_allocator)
	joined, _ := filepath.join({ws, "MEMORY.md"}, allocator)
	return joined
}

// memory_sessions_dir returns {ws}/sessions (allocated).
memory_sessions_dir :: proc(cwd: string, allocator := context.allocator) -> string {
	ws := memory_workspace_dir(cwd, context.temp_allocator)
	joined, _ := filepath.join({ws, "sessions"}, allocator)
	return joined
}

// memory_write_workspace_md overwrites workspace MEMORY.md (creates parents).
memory_write_workspace_md :: proc(
	cwd: string,
	body: string,
	allocator := context.allocator,
) -> (
	path: string,
	err: string,
) {
	if !memory_enabled() {
		return "", strings.clone("memory is disabled (AETHER_NO_MEMORY=1)", allocator)
	}
	trimmed := strings.trim_space(body)
	if trimmed == "" {
		return "", strings.clone("empty content", allocator)
	}
	root := memory_root(context.temp_allocator)
	slug := memory_workspace_slug(cwd, context.temp_allocator)
	rel, _ := filepath.join({slug, "MEMORY.md"}, context.temp_allocator)
	abs, under := resolve_under_memory_root(root, rel, context.temp_allocator)
	if !under {
		return "", strings.clone("error: MEMORY.md path outside memory root", allocator)
	}
	parent := filepath.dir(abs)
	if parent != "" && !os.exists(parent) {
		if os.make_directory_all(parent) != nil {
			return "", fmt.aprintf("cannot create directory %s", parent, allocator = allocator)
		}
	}
	if werr := os.write_entire_file(abs, transmute([]byte)trimmed); werr != nil {
		return "", fmt.aprintf("cannot write %s: %v", abs, werr, allocator = allocator)
	}
	// Ensure trailing newline for markdown hygiene
	if !strings.has_suffix(trimmed, "\n") {
		_ = os.write_entire_file(abs, transmute([]byte)fmt.tprintf("%s\n", trimmed))
	}
	return strings.clone(abs, allocator), ""
}

// memory_read_workspace_md returns content or empty string if missing.
memory_read_workspace_md :: proc(cwd: string, allocator := context.allocator) -> string {
	path := memory_workspace_md_path(cwd, context.temp_allocator)
	if !os.exists(path) || os.is_directory(path) {
		return strings.clone("", allocator)
	}
	data, err := os.read_entire_file(path, allocator)
	if err != nil {
		return strings.clone("", allocator)
	}
	return string(data)
}

// memory_list_session_stems returns sorted stems of sessions/*.md (caller deletes strings + slice).
memory_list_session_stems :: proc(cwd: string, allocator := context.allocator) -> []string {
	sess := memory_sessions_dir(cwd, context.temp_allocator)
	if !os.exists(sess) || !os.is_directory(sess) {
		return nil
	}
	fis, ferr := os.read_all_directory_by_path(sess, context.temp_allocator)
	if ferr != nil {
		return nil
	}
	out := make([dynamic]string, 0, 8, allocator)
	for fi in fis {
		if fi.type == .Directory {
			continue
		}
		if !strings.has_suffix(fi.name, ".md") {
			continue
		}
		stem := fi.name[:len(fi.name) - 3]
		if stem == "" {
			continue
		}
		append(&out, strings.clone(stem, allocator))
	}
	slice.sort_by(out[:], proc(a, b: string) -> bool {
		return a < b
	})
	return out[:]
}

// memory_session_file_path returns sessions/{stem}.md under workspace.
memory_session_file_path :: proc(
	cwd: string,
	stem: string,
	allocator := context.allocator,
) -> (
	path: string,
	ok: bool,
) {
	if stem == "" || strings.contains(stem, "/") || strings.contains(stem, "\\") ||
	   strings.contains(stem, "..") {
		return "", false
	}
	root := memory_root(context.temp_allocator)
	slug := memory_workspace_slug(cwd, context.temp_allocator)
	rel, _ := filepath.join(
		{slug, "sessions", fmt.tprintf("%s.md", stem)},
		context.temp_allocator,
	)
	abs, under := resolve_under_memory_root(root, rel, context.temp_allocator)
	if !under {
		return "", false
	}
	return strings.clone(abs, allocator), true
}

// memory_read_session_file reads sessions/{stem}.md content (allocated).
memory_read_session_file :: proc(
	cwd: string,
	stem: string,
	allocator := context.allocator,
) -> (
	content: string,
	ok: bool,
) {
	path, pok := memory_session_file_path(cwd, stem, context.temp_allocator)
	if !pok {
		return "", false
	}
	data, err := os.read_entire_file(path, allocator)
	if err != nil {
		return "", false
	}
	return string(data), true
}

// memory_file_mtime_unix returns modification time as unix seconds, or 0.
memory_file_mtime_unix :: proc(path: string) -> i64 {
	fi, err := os.stat(path, context.temp_allocator)
	if err != nil {
		return 0
	}
	return time.to_unix_seconds(fi.modification_time)
}

// memory_sessions_since returns stems of session files with mtime > since_unix.
// since_unix 0 means all sessions. Caller deletes strings + slice.
memory_sessions_since :: proc(
	cwd: string,
	since_unix: i64,
	allocator := context.allocator,
) -> []string {
	stems := memory_list_session_stems(cwd, context.temp_allocator)
	if len(stems) == 0 {
		return nil
	}
	out := make([dynamic]string, 0, len(stems), allocator)
	for stem in stems {
		path, ok := memory_session_file_path(cwd, stem, context.temp_allocator)
		if !ok {
			continue
		}
		mt := memory_file_mtime_unix(path)
		if since_unix <= 0 || mt > since_unix {
			append(&out, strings.clone(stem, allocator))
		}
	}
	return out[:]
}

// memory_delete_session_stem removes sessions/{stem}.md if older than min_age_secs.
// Returns true if deleted.
memory_delete_session_stem :: proc(cwd: string, stem: string, min_age_secs: u64 = DREAM_CLEANUP_RECENCY_SECS) -> bool {
	path, ok := memory_session_file_path(cwd, stem, context.temp_allocator)
	if !ok || !os.exists(path) {
		return false
	}
	mt := memory_file_mtime_unix(path)
	now := time.to_unix_seconds(time.now())
	if mt > 0 && u64(now - mt) < min_age_secs {
		return false
	}
	return os.remove(path) == nil
}

// --- dream lock ---

Dream_Lock_Prior :: struct {
	had_file: bool,
	mtime:    time.Time,
}

// dream_lock_path returns {ws}/.dream-lock (allocated).
dream_lock_path :: proc(cwd: string, allocator := context.allocator) -> string {
	ws := memory_workspace_dir(cwd, context.temp_allocator)
	joined, _ := filepath.join({ws, DREAM_LOCK_NAME}, allocator)
	return joined
}

// process_pid_alive: Linux /proc check; elsewhere assume alive if we cannot tell.
process_pid_alive :: proc(pid: u32) -> bool {
	if pid == 0 {
		return false
	}
	// Same process is always "alive"
	if pid == u32(os.get_pid()) {
		return true
	}
	proc_path := fmt.tprintf("/proc/%d", pid)
	return os.exists(proc_path)
}

// dream_last_consolidated_unix returns lock mtime as unix seconds, or 0 if none.
dream_last_consolidated_unix :: proc(cwd: string) -> i64 {
	path := dream_lock_path(cwd, context.temp_allocator)
	if !os.exists(path) {
		return 0
	}
	return memory_file_mtime_unix(path)
}

// dream_try_acquire writes our PID into the lock. Returns acquired + prior for rollback.
// Ok(false) means held by another live non-stale process.
dream_try_acquire :: proc(
	cwd: string,
	stale_secs: u64 = DREAM_STALE_LOCK_SECS,
) -> (
	acquired: bool,
	prior: Dream_Lock_Prior,
	err: string,
) {
	path := dream_lock_path(cwd, context.temp_allocator)
	// Ensure under root
	root := memory_root(context.temp_allocator)
	slug := memory_workspace_slug(cwd, context.temp_allocator)
	rel, _ := filepath.join({slug, DREAM_LOCK_NAME}, context.temp_allocator)
	abs, under := resolve_under_memory_root(root, rel, context.temp_allocator)
	if !under {
		return false, {}, "lock path outside memory root"
	}
	path = abs

	prior = {}
	if os.exists(path) {
		fi, serr := os.stat(path, context.temp_allocator)
		if serr != nil {
			return false, {}, "cannot stat lock"
		}
		prior.had_file = true
		prior.mtime = fi.modification_time
		age := u64(0)
		now := time.to_unix_seconds(time.now())
		mt := time.to_unix_seconds(fi.modification_time)
		if now > mt {
			age = u64(now - mt)
		}
		if data, rerr := os.read_entire_file(path, context.temp_allocator); rerr == nil {
			pid_str := strings.trim_space(string(data))
			if pid, pok := parse_u32(pid_str); pok {
				if age < stale_secs && process_pid_alive(pid) && pid != u32(os.get_pid()) {
					return false, prior, ""
				}
			}
		}
	}

	parent := filepath.dir(path)
	if parent != "" && !os.exists(parent) {
		if os.make_directory_all(parent) != nil {
			return false, {}, "cannot create workspace dir for lock"
		}
	}
	our_pid := u32(os.get_pid())
	body := fmt.tprintf("%d", our_pid)
	if werr := os.write_entire_file(path, transmute([]byte)body); werr != nil {
		return false, {}, "cannot write lock"
	}
	// Verify we won
	if data, rerr := os.read_entire_file(path, context.temp_allocator); rerr == nil {
		got := strings.trim_space(string(data))
		if pid, pok := parse_u32(got); pok && pid == our_pid {
			return true, prior, ""
		}
	}
	return false, prior, ""
}

// dream_rollback restores lock state after a failed dream.
dream_rollback :: proc(cwd: string, prior: Dream_Lock_Prior) {
	path := dream_lock_path(cwd, context.temp_allocator)
	if !prior.had_file {
		_ = os.remove(path)
		return
	}
	// Clear PID so we don't block reclaimers; restore mtime
	_ = os.write_entire_file(path, transmute([]byte)string(""))
	_ = os.change_times(path, prior.mtime, prior.mtime)
}

// dream_record stamps successful consolidation (writes PID, updates mtime to now).
dream_record :: proc(cwd: string) -> bool {
	path := dream_lock_path(cwd, context.temp_allocator)
	parent := filepath.dir(path)
	if parent != "" && !os.exists(parent) {
		if os.make_directory_all(parent) != nil {
			return false
		}
	}
	body := fmt.tprintf("%d", os.get_pid())
	return os.write_entire_file(path, transmute([]byte)body) == nil
}

parse_u32 :: proc(s: string) -> (u32, bool) {
	if s == "" {
		return 0, false
	}
	n: u64 = 0
	for i in 0 ..< len(s) {
		ch := s[i]
		if ch < '0' || ch > '9' {
			return 0, false
		}
		n = n * 10 + u64(ch - '0')
		if n > u64(max(u32)) {
			return 0, false
		}
	}
	return u32(n), true
}
