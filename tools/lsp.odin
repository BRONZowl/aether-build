package tools

// lsp tool — Grok Build LspTool product Full slice (shaping + caps).
// Reference: crates/codegen/xai-grok-tools/.../lsp + implementations/lsp
// Model ops: goToDefinition, findReferences, hover, goToImplementation,
// documentSymbol, workspaceSymbol, diagnostics (B10: publishDiagnostics cache).

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:time"

Lsp_Op :: enum {
	Go_To_Definition,
	Find_References,
	Hover,
	Go_To_Implementation,
	Document_Symbol,
	Workspace_Symbol,
	Diagnostics,
	Unknown,
}

lsp_op_from_string :: proc(s: string) -> Lsp_Op {
	switch strings.trim_space(s) {
	case "goToDefinition", "definition", "goto_definition":
		return .Go_To_Definition
	case "findReferences", "references", "find_references":
		return .Find_References
	case "hover":
		return .Hover
	case "goToImplementation", "implementation", "goto_implementation":
		return .Go_To_Implementation
	case "documentSymbol", "document_symbol", "documentSymbols":
		return .Document_Symbol
	case "workspaceSymbol", "workspace_symbol", "workspaceSymbols":
		return .Workspace_Symbol
	case "diagnostics", "diagnostic", "documentDiagnostics", "publishDiagnostics":
		return .Diagnostics
	}
	return .Unknown
}

lsp_op_label :: proc(op: Lsp_Op) -> string {
	switch op {
	case .Go_To_Definition:
		return "Definition"
	case .Find_References:
		return "References"
	case .Hover:
		return "Hover"
	case .Go_To_Implementation:
		return "Implementation"
	case .Document_Symbol:
		return "Document symbols"
	case .Workspace_Symbol:
		return "Workspace symbols"
	case .Diagnostics:
		return "Diagnostics"
	case .Unknown:
		return "LSP"
	}
	return "LSP"
}

LSP_DIAG_LINE_CAP :: 100
LSP_DIAG_WAIT :: 1500 * time.Millisecond
LSP_DIAG_FILE_CAP :: 20
LSP_DIAG_WAIT_MAX :: 10 * time.Second

// Opened_Doc: one file opened for diagnostics batch (B11).
Opened_Doc :: struct {
	sess: ^Lsp_Session,
	abs:  string,
	uri:  string,
}

// Diag_Filter: severity filtering for diagnostics output (B12).
// LSP severity: 1=Error, 2=Warning, 3=Info, 4=Hint. Keep items with severity <= min
// (more severe numbers are lower priority in LSP).
Diag_Filter :: struct {
	min_severity: int, // 1..4; default 4 = include all
	errors_only:  bool, // force min_severity = 1
}

diag_filter_default :: proc() -> Diag_Filter {
	return Diag_Filter {
		min_severity = 4,
		errors_only  = false,
	}
}

// parse_diag_filter from tool JSON: errors_only, min_severity (1-4 or error/warn/info/hint).
parse_diag_filter :: proc(obj: json.Object) -> Diag_Filter {
	f := diag_filter_default()
	if jbool(obj, "errors_only", false) || jbool(obj, "errorsOnly", false) {
		f.errors_only = true
		f.min_severity = 1
		return f
	}
	// string severity
	if ms := jstr(obj, "min_severity"); ms != "" {
		f.min_severity = severity_from_string(ms)
	} else if sev_s := jstr(obj, "severity"); sev_s != "" {
		f.min_severity = severity_from_string(sev_s)
	} else {
		n := jint(obj, "min_severity", 0)
		if n == 0 {
			n = jint(obj, "severity", 0)
		}
		if n >= 1 && n <= 4 {
			f.min_severity = n
		}
	}
	if f.min_severity < 1 {
		f.min_severity = 1
	}
	if f.min_severity > 4 {
		f.min_severity = 4
	}
	return f
}

severity_from_string :: proc(s: string) -> int {
	switch strings.to_lower(strings.trim_space(s), context.temp_allocator) {
	case "error", "errors", "1", "e":
		return 1
	case "warn", "warning", "warnings", "2", "w":
		return 2
	case "info", "information", "3", "i":
		return 3
	case "hint", "hints", "4", "h":
		return 4
	}
	return 4
}

// Keep diagnostic if its severity is at least as severe as min (lower number = worse).
// Missing severity treated as Error (1).
diag_severity_kept :: proc(sev: int, f: Diag_Filter) -> bool {
	s := sev
	if s < 1 || s > 4 {
		s = 1
	}
	return s <= f.min_severity
}

LSP_LOCATION_CAP :: 50
LSP_SYMBOL_LINE_CAP :: 200

// display_path_ws: workspace-relative when path is under workspace.
display_path_ws :: proc(path, workspace: string) -> string {
	if workspace == "" || path == "" {
		return path
	}
	ws := workspace
	if !strings.has_suffix(ws, "/") {
		// avoid /tmp/foo matching /tmp/foobar
		if path == ws {
			return "."
		}
		if strings.has_prefix(path, ws) && len(path) > len(ws) {
			ch := path[len(ws)]
			if ch == '/' || ch == '\\' {
				return path[len(ws) + 1:]
			}
		}
		return path
	}
	if strings.has_prefix(path, ws) {
		return path[len(ws):]
	}
	return path
}

// format_lsp_locations: Grok format_locations_labeled (1-based line/col display).
format_lsp_locations :: proc(
	label: string,
	result_json: string,
	allocator := context.allocator,
	workspace := "",
) -> string {
	// Parse on the same allocator as the result builder (large arrays need heap, not a tiny temp).
	locs := collect_locations(result_json, allocator)
	if len(locs) == 0 {
		return strings.clone("No results found.", allocator)
	}
	total := len(locs)
	show := min(total, LSP_LOCATION_CAP)
	b := strings.builder_make(allocator)
	fmt.sbprintf(
		&b,
		"%s (%d location%s):\n",
		label,
		total,
		"" if total == 1 else "s",
	)
	for i in 0 ..< show {
		L := locs[i]
		p := display_path_ws(L.path, workspace)
		fmt.sbprintf(&b, "  %s:%d:%d\n", p, L.line, L.col)
	}
	if total > show {
		fmt.sbprintf(&b, "... and %d more\n", total - show)
	}
	return strings.to_string(b)
}

Lsp_Loc :: struct {
	path: string,
	line: int, // 1-based
	col:  int, // 1-based
}

collect_locations :: proc(result_json: string, allocator := context.allocator) -> [dynamic]Lsp_Loc {
	out := make([dynamic]Lsp_Loc, 0, 8, allocator)
	if result_json == "" || result_json == "null" {
		return out
	}
	val, err := json.parse(transmute([]byte)result_json, json.DEFAULT_SPECIFICATION, false, allocator)
	if err != nil {
		return out
	}
	// single Location | Location[] | {location: Location}[] (LocationLink)
	#partial switch t in val {
	case json.Array:
		for item in t {
			if loc, ok := location_from_value(item); ok {
				append(&out, loc)
			}
		}
	case json.Object:
		if loc, ok := location_from_value(val); ok {
			append(&out, loc)
		}
	}
	return out
}

location_from_value :: proc(v: json.Value) -> (Lsp_Loc, bool) {
	obj, ok := v.(json.Object)
	if !ok {
		return {}, false
	}
	// LocationLink uses targetUri / targetRange
	uri := ""
	if u, has := obj["uri"]; has {
		if s, is_s := u.(json.String); is_s {
			uri = string(s)
		}
	}
	if uri == "" {
		if u, has := obj["targetUri"]; has {
			if s, is_s := u.(json.String); is_s {
				uri = string(s)
			}
		}
	}
	range_v: json.Value
	has_range := false
	if r0, has0 := obj["range"]; has0 {
		range_v = r0
		has_range = true
	} else if r1, has1 := obj["targetSelectionRange"]; has1 {
		range_v = r1
		has_range = true
	} else if r2, has2 := obj["targetRange"]; has2 {
		range_v = r2
		has_range = true
	}
	// nested location: { location: { uri, range } }
	if uri == "" {
		if loc_v, has := obj["location"]; has {
			return location_from_value(loc_v)
		}
	}
	if uri == "" || !has_range {
		return {}, false
	}
	line, col := 1, 1
	if ro, is_o := range_v.(json.Object); is_o {
		if st, has := ro["start"]; has {
			if so, is_s := st.(json.Object); is_s {
				line = jint(so, "line", 0) + 1
				col = jint(so, "character", 0) + 1
			}
		}
	}
	return Lsp_Loc{path = file_uri_to_path(uri), line = line, col = col}, true
}

format_lsp_hover :: proc(result_json: string, allocator := context.allocator) -> string {
	if result_json == "" || result_json == "null" {
		return strings.clone("No results found.", allocator)
	}
	val, err := json.parse(transmute([]byte)result_json, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if err != nil {
		return strings.clone(result_json, allocator)
	}
	obj, ok := val.(json.Object)
	if !ok {
		return strings.clone(result_json, allocator)
	}
	cv, has := obj["contents"]
	if !has {
		return strings.clone("No results found.", allocator)
	}
	return hover_contents_to_text(cv, allocator)
}

hover_contents_to_text :: proc(v: json.Value, allocator := context.allocator) -> string {
	#partial switch t in v {
	case json.String:
		s := strings.trim_space(string(t))
		if s == "" {
			return strings.clone("No results found.", allocator)
		}
		return strings.clone(s, allocator)
	case json.Object:
		// MarkupContent { kind, value } or MarkedString { language, value }
		lang := ""
		if lv, has := t["language"]; has {
			if s, is_s := lv.(json.String); is_s {
				lang = string(s)
			}
		}
		val_s := ""
		if val, has := t["value"]; has {
			if s, is_s := val.(json.String); is_s {
				val_s = string(s)
			}
		}
		if val_s == "" {
			return strings.clone("No results found.", allocator)
		}
		if lang != "" {
			// Grok markup_string_to_text LanguageString → fenced block
			return fmt.aprintf("```%s\n%s\n```", lang, val_s, allocator = allocator)
		}
		return strings.clone(val_s, allocator)
	case json.Array:
		b := strings.builder_make(allocator)
		for item, i in t {
			if i > 0 {
				strings.write_string(&b, "\n\n")
			}
			part := hover_contents_to_text(item, context.temp_allocator)
			strings.write_string(&b, part)
		}
		out := strings.to_string(b)
		if strings.trim_space(out) == "" {
			delete(out)
			return strings.clone("No results found.", allocator)
		}
		return out
	}
	return strings.clone("No results found.", allocator)
}

// format_lsp_symbols best-effort for DocumentSymbol[] / SymbolInformation[]
format_lsp_symbols :: proc(
	result_json: string,
	allocator := context.allocator,
	workspace := "",
) -> string {
	if result_json == "" || result_json == "null" {
		return strings.clone("No symbols found.", allocator)
	}
	val, err := json.parse(transmute([]byte)result_json, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if err != nil {
		return strings.clone(result_json, allocator)
	}
	arr, is_arr := val.(json.Array)
	if !is_arr || len(arr) == 0 {
		return strings.clone("No symbols found.", allocator)
	}
	b := strings.builder_make(allocator)
	n := 0
	for item in arr {
		if n >= LSP_SYMBOL_LINE_CAP {
			break
		}
		_ = append_symbol_lines(&b, item, "", workspace, &n)
	}
	if n == 0 {
		delete(strings.to_string(b))
		return strings.clone("No symbols found.", allocator)
	}
	// If we hit the cap, there may still be unvisited siblings/children.
	if n >= LSP_SYMBOL_LINE_CAP {
		fmt.sbprintf(&b, "... and more symbols (capped at %d lines)\n", LSP_SYMBOL_LINE_CAP)
	}
	return strings.to_string(b)
}

append_symbol_lines :: proc(
	b: ^strings.Builder,
	v: json.Value,
	indent: string,
	workspace: string,
	count_so_far: ^int,
) -> int {
	if count_so_far^ >= LSP_SYMBOL_LINE_CAP {
		return 0
	}
	obj, ok := v.(json.Object)
	if !ok {
		return 0
	}
	name := ""
	if nv, has := obj["name"]; has {
		if s, is_s := nv.(json.String); is_s {
			name = string(s)
		}
	}
	kind := 0
	if kv, has := obj["kind"]; has {
		#partial switch k in kv {
		case json.Integer:
			kind = int(k)
		case json.Float:
			kind = int(k)
		}
	}
	path := ""
	line := 1
	// SymbolInformation: location
	if loc_v, has := obj["location"]; has {
		if loc, lok := location_from_value(loc_v); lok {
			path = loc.path
			line = loc.line
		}
	}
	// DocumentSymbol: range
	if path == "" {
		if rv, has := obj["range"]; has {
			if ro, is_o := rv.(json.Object); is_o {
				if st, has_s := ro["start"]; has_s {
					if so, is_s := st.(json.Object); is_s {
						line = jint(so, "line", 0) + 1
					}
				}
			}
		}
	}
	count := 0
	if name != "" {
		disp := display_path_ws(path, workspace)
		if path != "" {
			fmt.sbprintf(b, "%s%s %s (%s:%d)\n", indent, symbol_kind_name(kind), name, disp, line)
		} else {
			fmt.sbprintf(b, "%s%s %s (line %d)\n", indent, symbol_kind_name(kind), name, line)
		}
		count = 1
		count_so_far^ += 1
	}
	if ch, has := obj["children"]; has {
		if arr, is_a := ch.(json.Array); is_a {
			child_indent := fmt.tprintf("%s  ", indent)
			for c in arr {
				if count_so_far^ >= LSP_SYMBOL_LINE_CAP {
					break
				}
				count += append_symbol_lines(b, c, child_indent, workspace, count_so_far)
			}
		}
	}
	return count
}

symbol_kind_name :: proc(k: int) -> string {
	// LSP SymbolKind
	switch k {
	case 1:
		return "File"
	case 2:
		return "Module"
	case 3:
		return "Namespace"
	case 4:
		return "Package"
	case 5:
		return "Class"
	case 6:
		return "Method"
	case 7:
		return "Property"
	case 8:
		return "Field"
	case 9:
		return "Constructor"
	case 10:
		return "Enum"
	case 11:
		return "Interface"
	case 12:
		return "Function"
	case 13:
		return "Variable"
	case 14:
		return "Constant"
	case 15:
		return "String"
	case 16:
		return "Number"
	case 17:
		return "Boolean"
	case 18:
		return "Array"
	case 19:
		return "Object"
	case 20:
		return "Key"
	case 21:
		return "Null"
	case 22:
		return "EnumMember"
	case 23:
		return "Struct"
	case 24:
		return "Event"
	case 25:
		return "Operator"
	case 26:
		return "TypeParameter"
	}
	return "Symbol"
}

// tool_lsp is the model-facing entrypoint.
tool_lsp :: proc(arguments_json: string, workspace: string, allocator := context.allocator) -> string {
	if !lsp_enabled() {
		return strings.clone("error: lsp disabled (AETHER_NO_LSP=1)", allocator)
	}
	obj, ok := json_obj(arguments_json)
	if !ok {
		return strings.clone("error: invalid JSON arguments", allocator)
	}
	op_s := jstr(obj, "operation")
	if op_s == "" {
		return strings.clone("error: operation is required", allocator)
	}
	op := lsp_op_from_string(op_s)
	if op == .Unknown {
		return fmt.aprintf("error: unknown operation %q", op_s, allocator = allocator)
	}

	file_path := jstr(obj, "file_path")
	if file_path == "" {
		file_path = jstr(obj, "path")
	}
	line := jint(obj, "line", -1)
	character := jint(obj, "character", -1)
	if character < 0 {
		character = jint(obj, "column", -1)
	}
	query := jstr(obj, "query")
	// B11: optional wait for diagnostics settle (ms); default LSP_DIAG_WAIT
	wait_ms := jint(obj, "timeout_ms", -1)
	if wait_ms < 0 {
		wait_ms = jint(obj, "wait_ms", -1)
	}
	// B12: severity filter for diagnostics
	diag_filt := parse_diag_filter(obj)

	servers := load_lsp_servers(workspace, context.temp_allocator)
	// note: temp_allocator owns server strings for this call — do not free_lsp_servers on temp
	if len(servers) == 0 {
		return strings.clone(
			"error: no LSP servers configured. Add ~/.grok/lsp.json or <cwd>/.grok/lsp.json",
			allocator,
		)
	}

	if op == .Workspace_Symbol {
		if query == "" {
			return strings.clone("error: query is required for workspaceSymbol", allocator)
		}
		return lsp_workspace_symbol(servers[:], workspace, query, allocator)
	}

	// B11: multi-file diagnostics via paths / file_paths array
	if op == .Diagnostics {
		paths := collect_diag_paths(obj, file_path, context.temp_allocator)
		if len(paths) == 0 {
			return strings.clone(
				"error: file_path or paths[] is required for diagnostics",
				allocator,
			)
		}
		return lsp_diagnostics_for_paths(servers[:], workspace, paths, wait_ms, diag_filt, allocator)
	}

	if file_path == "" {
		return strings.clone("error: file_path is required for this operation", allocator)
	}
	abs, _ := resolve_lsp_path(workspace, file_path, context.temp_allocator)
	server_name, lang_id, rok := resolve_lsp_server(servers[:], abs)
	if !rok {
		return fmt.aprintf(
			"error: no LSP server for file %s (configure extensions in lsp.json or use a known server name)",
			abs,
			allocator = allocator,
		)
	}
	cfg, cok := find_lsp_server_cfg(servers[:], server_name)
	if !cok {
		return fmt.aprintf("error: server %q missing from config", server_name, allocator = allocator)
	}
	sess, serr := lsp_ensure_session(cfg, workspace)
	if serr != "" {
		return fmt.aprintf("error: LSP %s: %s", server_name, serr, allocator = allocator)
	}
	if oerr := lsp_did_open_if_needed(sess, abs, lang_id); oerr != "" {
		return fmt.aprintf("error: didOpen: %s", oerr, allocator = allocator)
	}

	uri := path_to_file_uri(abs, context.temp_allocator)
	needs_pos :=
		op == .Go_To_Definition ||
		op == .Find_References ||
		op == .Hover ||
		op == .Go_To_Implementation
	if needs_pos && (line < 0 || character < 0) {
		return strings.clone("error: line and character (0-based) are required", allocator)
	}

	method: string
	params: string
	switch op {
	case .Go_To_Definition:
		method = "textDocument/definition"
		params = fmt.tprintf(
			`{"textDocument":{"uri":%s},"position":{"line":%d,"character":%d}}`,
			lsp_json_quote(uri, context.temp_allocator),
			line,
			character,
		)
	case .Find_References:
		method = "textDocument/references"
		params = fmt.tprintf(
			`{"textDocument":{"uri":%s},"position":{"line":%d,"character":%d},"context":{"includeDeclaration":true}}`,
			lsp_json_quote(uri, context.temp_allocator),
			line,
			character,
		)
	case .Hover:
		method = "textDocument/hover"
		params = fmt.tprintf(
			`{"textDocument":{"uri":%s},"position":{"line":%d,"character":%d}}`,
			lsp_json_quote(uri, context.temp_allocator),
			line,
			character,
		)
	case .Go_To_Implementation:
		method = "textDocument/implementation"
		params = fmt.tprintf(
			`{"textDocument":{"uri":%s},"position":{"line":%d,"character":%d}}`,
			lsp_json_quote(uri, context.temp_allocator),
			line,
			character,
		)
	case .Document_Symbol:
		method = "textDocument/documentSymbol"
		params = fmt.tprintf(
			`{"textDocument":{"uri":%s}}`,
			lsp_json_quote(uri, context.temp_allocator),
		)
	case .Diagnostics, .Workspace_Symbol, .Unknown:
		return strings.clone("error: internal op routing", allocator)
	}

	res, rerr := lsp_request(sess, method, params, LSP_REQUEST_TIMEOUT, context.temp_allocator)
	if rerr != "" {
		return fmt.aprintf("error: %s: %s", method, rerr, allocator = allocator)
	}
	out: string
	switch op {
	case .Hover:
		out = format_lsp_hover(res, context.temp_allocator)
	case .Document_Symbol:
		out = format_lsp_symbols(res, context.temp_allocator, workspace)
	case .Go_To_Definition, .Find_References, .Go_To_Implementation:
		out = format_lsp_locations(lsp_op_label(op), res, context.temp_allocator, workspace)
	case .Diagnostics, .Workspace_Symbol, .Unknown:
		out = res
	}
	return cap_output(out, DEFAULT_OUTPUT_CAP, allocator)
}

// collect_diag_paths: file_path + paths[] / file_paths[] (deduped, cap LSP_DIAG_FILE_CAP).
// Returns slice of path strings (not owned beyond allocator).
collect_diag_paths :: proc(
	obj: json.Object,
	file_path: string,
	allocator := context.allocator,
) -> []string {
	tmp := make([dynamic]string, 0, 8, context.temp_allocator)
	if file_path != "" {
		append(&tmp, file_path)
	}
	for key in ([]string{"paths", "file_paths", "files"}) {
		if av, has := obj[key]; has {
			if arr, is_a := av.(json.Array); is_a {
				for item in arr {
					if s, is_s := item.(json.String); is_s {
						p := strings.trim_space(string(s))
						if p != "" {
							append(&tmp, p)
						}
					}
				}
			}
		}
	}
	// dedupe
	out := make([dynamic]string, 0, len(tmp), allocator)
	seen := make(map[string]bool, 8, context.temp_allocator)
	for p in tmp {
		if seen[p] {
			continue
		}
		seen[p] = true
		append(&out, strings.clone(p, allocator))
		if len(out) >= LSP_DIAG_FILE_CAP {
			break
		}
	}
	return out[:]
}

diag_wait_duration :: proc(wait_ms: int) -> time.Duration {
	if wait_ms < 0 {
		return LSP_DIAG_WAIT
	}
	if wait_ms == 0 {
		return 0
	}
	d := time.Duration(wait_ms) * time.Millisecond
	if d > LSP_DIAG_WAIT_MAX {
		return LSP_DIAG_WAIT_MAX
	}
	return d
}

// lsp_diagnostics_for_paths: multi-file diagnostics (B11) + severity filter (B12).
lsp_diagnostics_for_paths :: proc(
	servers: []Lsp_Server_Cfg,
	workspace: string,
	paths: []string,
	wait_ms: int,
	filt: Diag_Filter = {},
	allocator := context.allocator,
) -> string {
	f := filt
	if f.min_severity == 0 && !f.errors_only {
		f = diag_filter_default()
	}
	if f.errors_only {
		f.min_severity = 1
	}
	if len(paths) == 0 {
		return strings.clone("error: no paths for diagnostics", allocator)
	}
	wait := diag_wait_duration(wait_ms)
	// Open all files first (group by server session)
	opened := make([dynamic]Opened_Doc, 0, len(paths), context.temp_allocator)
	errs := make([dynamic]string, 0, 4, context.temp_allocator)

	for p in paths {
		abs, _ := resolve_lsp_path(workspace, p, context.temp_allocator)
		server_name, lang_id, rok := resolve_lsp_server(servers, abs)
		if !rok {
			append(
				&errs,
				fmt.tprintf("no LSP server for %s", display_path_ws(abs, workspace)),
			)
			continue
		}
		cfg, cok := find_lsp_server_cfg(servers, server_name)
		if !cok {
			append(&errs, fmt.tprintf("server %q missing", server_name))
			continue
		}
		sess, serr := lsp_ensure_session(cfg, workspace)
		if serr != "" {
			append(&errs, fmt.tprintf("%s: %s", server_name, serr))
			continue
		}
		if oerr := lsp_did_open_if_needed(sess, abs, lang_id); oerr != "" {
			append(&errs, fmt.tprintf("didOpen %s: %s", display_path_ws(abs, workspace), oerr))
			continue
		}
		uri := path_to_file_uri(abs, context.temp_allocator)
		append(&opened, Opened_Doc{sess = sess, abs = abs, uri = uri})
	}

	// Shared drain window across sessions (each session drained)
	if wait > 0 {
		// Drain each unique session once
		seen_sess := make(map[rawptr]bool, 4, context.temp_allocator)
		for o in opened {
			key := rawptr(o.sess)
			if seen_sess[key] {
				continue
			}
			seen_sess[key] = true
			lsp_drain_notifications(o.sess, wait)
		}
	}

	// Optional pull per file + format
	b := strings.builder_make(context.temp_allocator)
	if len(paths) > 1 {
		fmt.sbprintf(&b, "Diagnostics for %d file(s):\n\n", len(opened))
	}
	any_diag := false
	for o in opened {
		// pull model
		pull_params := fmt.tprintf(
			`{"textDocument":{"uri":%s}}`,
			lsp_json_quote(o.uri, context.temp_allocator),
		)
		if pull, perr := lsp_request(
			o.sess,
			"textDocument/diagnostic",
			pull_params,
			2 * time.Second,
			context.temp_allocator,
		); perr == "" && pull != "" && pull != "null" {
			if items := extract_pull_diagnostic_items(pull, context.temp_allocator); items != "" {
				lsp_diag_store_json(o.uri, items)
			}
		} else if wait > 0 {
			lsp_drain_notifications(o.sess, 200 * time.Millisecond)
		}
		raw := lsp_diag_get_json(o.uri, context.temp_allocator)
		part := format_lsp_diagnostics(o.abs, raw, context.temp_allocator, workspace, f)
		if !strings.contains(part, "none reported") {
			any_diag = true
		}
		strings.write_string(&b, part)
		if !strings.has_suffix(part, "\n") {
			strings.write_byte(&b, '\n')
		}
		strings.write_byte(&b, '\n')
	}
	for e in errs {
		fmt.sbprintf(&b, "note: %s\n", e)
	}
	if len(opened) == 0 && len(errs) > 0 {
		return cap_output(strings.to_string(b), DEFAULT_OUTPUT_CAP, allocator)
	}
	_ = any_diag
	return cap_output(strings.to_string(b), DEFAULT_OUTPUT_CAP, allocator)
}

// lsp_diagnostics_for_file: single-file helper (still used by tests/format path).
lsp_diagnostics_for_file :: proc(
	sess: ^Lsp_Session,
	abs: string,
	uri: string,
	workspace: string,
	allocator := context.allocator,
	wait := LSP_DIAG_WAIT,
	filt: Diag_Filter = {},
) -> string {
	f := filt
	if f.min_severity == 0 && !f.errors_only {
		f = diag_filter_default()
	}
	if f.errors_only {
		f.min_severity = 1
	}
	if wait > 0 {
		lsp_drain_notifications(sess, wait)
	}
	pull_params := fmt.tprintf(
		`{"textDocument":{"uri":%s}}`,
		lsp_json_quote(uri, context.temp_allocator),
	)
	if pull, perr := lsp_request(
		sess,
		"textDocument/diagnostic",
		pull_params,
		2 * time.Second,
		context.temp_allocator,
	); perr == "" && pull != "" && pull != "null" {
		if items := extract_pull_diagnostic_items(pull, context.temp_allocator); items != "" {
			lsp_diag_store_json(uri, items)
		}
	} else if wait > 0 {
		lsp_drain_notifications(sess, 300 * time.Millisecond)
	}
	raw := lsp_diag_get_json(uri, context.temp_allocator)
	out := format_lsp_diagnostics(abs, raw, context.temp_allocator, workspace, f)
	return cap_output(out, DEFAULT_OUTPUT_CAP, allocator)
}

// extract_pull_diagnostic_items: pull report → diagnostics array JSON string.
extract_pull_diagnostic_items :: proc(report_json: string, allocator := context.allocator) -> string {
	val, err := json.parse(transmute([]byte)report_json, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if err != nil {
		return ""
	}
	obj, ok := val.(json.Object)
	if !ok {
		// maybe already an array
		if _, is_a := val.(json.Array); is_a {
			return strings.clone(report_json, allocator)
		}
		return ""
	}
	if items, has := obj["items"]; has {
		return lsp_json_encode(items, allocator)
	}
	// relatedDocuments map — skip; full report only
	return ""
}

// format_lsp_diagnostics formats a publishDiagnostics diagnostics array.
// filt: B12 severity filter (default = all).
format_lsp_diagnostics :: proc(
	path: string,
	diagnostics_json: string,
	allocator := context.allocator,
	workspace := "",
	filt: Diag_Filter = {},
) -> string {
	f := filt
	if f.min_severity == 0 && !f.errors_only {
		f = diag_filter_default()
	}
	if f.errors_only {
		f.min_severity = 1
	}
	disp := display_path_ws(path, workspace)
	if diagnostics_json == "" || diagnostics_json == "null" || diagnostics_json == "[]" {
		return fmt.aprintf("Diagnostics for %s: none reported (yet).", disp, allocator = allocator)
	}
	val, err := json.parse(
		transmute([]byte)diagnostics_json,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if err != nil {
		return fmt.aprintf("Diagnostics for %s: (parse error)", disp, allocator = allocator)
	}
	arr, is_a := val.(json.Array)
	if !is_a {
		return fmt.aprintf("Diagnostics for %s: (unexpected payload)", disp, allocator = allocator)
	}
	if len(arr) == 0 {
		return fmt.aprintf("Diagnostics for %s: none reported.", disp, allocator = allocator)
	}
	// Count kept after filter
	kept := 0
	for i in 0 ..< len(arr) {
		item, is_o := arr[i].(json.Object)
		if !is_o {
			continue
		}
		sev := jint(item, "severity", 1)
		if diag_severity_kept(sev, f) {
			kept += 1
		}
	}
	if kept == 0 {
		filt_note := ""
		if f.errors_only || f.min_severity < 4 {
			filt_note = " (after severity filter)"
		}
		return fmt.aprintf(
			"Diagnostics for %s: none reported%s.",
			disp,
			filt_note,
			allocator = allocator,
		)
	}
	b := strings.builder_make(allocator)
	fmt.sbprintf(&b, "Diagnostics for %s (%d):\n", disp, kept)
	shown := 0
	for i in 0 ..< len(arr) {
		if shown >= LSP_DIAG_LINE_CAP {
			break
		}
		item, is_o := arr[i].(json.Object)
		if !is_o {
			continue
		}
		sev := jint(item, "severity", 1)
		if !diag_severity_kept(sev, f) {
			continue
		}
		sev_s := "error"
		switch sev {
		case 1:
			sev_s = "error"
		case 2:
			sev_s = "warn"
		case 3:
			sev_s = "info"
		case 4:
			sev_s = "hint"
		}
		line, col := 1, 1
		if rv, has := item["range"]; has {
			if ro, is_r := rv.(json.Object); is_r {
				if st, has_s := ro["start"]; has_s {
					if so, is_s := st.(json.Object); is_s {
						line = jint(so, "line", 0) + 1
						col = jint(so, "character", 0) + 1
					}
				}
			}
		}
		msg := ""
		if mv, has := item["message"]; has {
			if s, is_s := mv.(json.String); is_s {
				msg = string(s)
			}
		}
		if msg == "" {
			msg = "(no message)"
		}
		if strings.contains(msg, "\n") {
			msg, _ = strings.replace_all(msg, "\n", " ", context.temp_allocator)
		}
		src := ""
		if sv, has := item["source"]; has {
			if s, is_s := sv.(json.String); is_s {
				src = string(s)
			}
		}
		code := ""
		if cv, has := item["code"]; has {
			#partial switch c in cv {
			case json.String:
				code = string(c)
			case json.Integer:
				code = fmt.tprintf("%d", int(c))
			case json.Float:
				code = fmt.tprintf("%d", int(c))
			}
		}
		extra := ""
		if src != "" && code != "" {
			extra = fmt.tprintf(" (%s %s)", src, code)
		} else if src != "" {
			extra = fmt.tprintf(" (%s)", src)
		} else if code != "" {
			extra = fmt.tprintf(" (%s)", code)
		}
		fmt.sbprintf(&b, "  %s:%d:%d [%s]%s %s\n", disp, line, col, sev_s, extra, msg)
		shown += 1
	}
	if kept > shown {
		fmt.sbprintf(&b, "  … +%d more\n", kept - shown)
	}
	return strings.to_string(b)
}

resolve_lsp_path :: proc(
	workspace: string,
	path: string,
	allocator := context.allocator,
) -> (
	abs: string,
	ok: bool,
) {
	p := strings.trim_space(path)
	if p == "" {
		return "", false
	}
	if os.is_absolute_path(p) {
		return strings.clone(p, allocator), true
	}
	j, jerr := filepath.join({workspace, p}, allocator)
	if jerr != nil {
		return strings.clone(p, allocator), true
	}
	return j, true
}

lsp_workspace_symbol :: proc(
	servers: []Lsp_Server_Cfg,
	workspace: string,
	query: string,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(context.temp_allocator)
	any_ok := false
	params := fmt.tprintf(`{"query":%s}`, lsp_json_quote(query, context.temp_allocator))
	for cfg in servers {
		sess, err := lsp_ensure_session(cfg, workspace)
		if err != "" {
			continue
		}
		res, rerr := lsp_request(sess, "workspace/symbol", params, LSP_REQUEST_TIMEOUT, context.temp_allocator)
		if rerr != "" {
			continue
		}
		part := format_lsp_symbols(res, context.temp_allocator, workspace)
		if strings.contains(part, "No symbols") {
			continue
		}
		if any_ok {
			strings.write_byte(&b, '\n')
		}
		fmt.sbprintf(&b, "# %s\n%s", cfg.name, part)
		any_ok = true
	}
	if !any_ok {
		return strings.clone("No symbols found.", allocator)
	}
	return cap_output(strings.to_string(b), DEFAULT_OUTPUT_CAP, allocator)
}
