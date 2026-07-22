// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"

Permission_Mode :: enum {
	Always_Approve,
	// Auto (Grok acceptEdits-shaped): auto-allow file Edit tools; ask for Bash/MCP/media.
	Auto,
	Read_Only,
	Ask,
}

Permission_Decision :: enum {
	Allow,
	Deny,
	Ask,
}

// Ask_Decision is the user response to an ask-mode tool prompt
// (Grok AllowOnce / AllowAlways / Reject / RejectAlways).
Ask_Decision :: enum {
	Deny,   // once
	Once,
	Always, // session allow grant
	Never,  // session deny grant + deny this call
}

permission_mode_from_string :: proc(s: string) -> (Permission_Mode, bool) {
	switch strings.to_lower(s, context.temp_allocator) {
	case "always-approve", "always_approve", "yolo", "bypass":
		return .Always_Approve, true
	case "auto", "accept-edits", "accept_edits", "acceptedits":
		return .Auto, true
	case "read-only", "read_only", "readonly":
		return .Read_Only, true
	case "ask", "prompt", "default":
		return .Ask, true
	}
	return .Always_Approve, false
}

permission_mode_string :: proc(m: Permission_Mode) -> string {
	switch m {
	case .Always_Approve:
		return "always-approve"
	case .Auto:
		return "auto"
	case .Read_Only:
		return "read-only"
	case .Ask:
		return "ask"
	}
	return "always-approve"
}

// next_permission_mode cycles ask → auto → always-approve → read-only (TUI Shift+Tab).
next_permission_mode :: proc(m: Permission_Mode) -> Permission_Mode {
	switch m {
	case .Ask:
		return .Auto
	case .Auto:
		return .Always_Approve
	case .Always_Approve:
		return .Read_Only
	case .Read_Only:
		return .Ask
	}
	return .Ask
}

// Tool_Perm_Class: permission bucket for match_rule / mode policy (P2.3).
// String form ("Read"/"Edit"/"Bash"/"Other") is what allow/deny rules use.
Tool_Perm_Class :: enum {
	Read,
	Edit,
	Bash,
	Other,
}

// TOOL_PERM_TABLE: SoT for named tool → class (keep in sync with tools.TOOL_REGISTRY.perm).
// Unlisted tools (skill, spawn, kill_task, hashline_*, use_tool, …) → Other.
TOOL_PERM_TABLE := [?]struct {
	name:  string,
	class: Tool_Perm_Class,
} {
	{"read_file", .Read},
	{"list_dir", .Read},
	{"glob", .Read},
	{"grep", .Read},
	{"web_search", .Read},
	{"web_fetch", .Read},
	{"todo_write", .Read},
	{"ask_user_question", .Read},
	{"lsp", .Read},
	{"update_goal", .Read},
	{"memory_search", .Read},
	{"memory_get", .Read},
	{"list_mcp_resources", .Read},
	{"read_mcp_resource", .Read},
	{"list_mcp_prompts", .Read},
	{"get_mcp_prompt", .Read},
	{"search_tool", .Read},
	{"scheduler_list", .Read},
	{"get_task_output", .Read},
	{"wait_tasks", .Read},
	{"wait_commands_or_subagents", .Read},
	{"search_replace", .Edit},
	{"write", .Edit},
	{"delete_file", .Edit},
	// write-like side effect (file/API); reuse Edit for ask mode
	{"scheduler_create", .Edit},
	{"scheduler_delete", .Edit},
	{"image_gen", .Edit},
	{"image_edit", .Edit},
	{"image_to_video", .Edit},
	{"reference_to_video", .Edit},
	{"run_terminal_cmd", .Bash},
	{"monitor", .Bash},
}

// FILE_EDIT_TOOLS: Auto mode auto-approves these (Grok acceptEdits). Subset of Edit.
FILE_EDIT_TOOLS := [?]string{"search_replace", "write", "delete_file"}

// WRITE_OR_SHELL_EXTRA: treated as write/shell beyond Edit/Bash classes (MCP dispatch).
WRITE_OR_SHELL_EXTRA := [?]string{"use_tool"}

tool_perm_class :: proc(tool_name: string) -> Tool_Perm_Class {
	for e in TOOL_PERM_TABLE {
		if e.name == tool_name {
			return e.class
		}
	}
	return .Other
}

tool_perm_class_string :: proc(c: Tool_Perm_Class) -> string {
	switch c {
	case .Read:
		return "Read"
	case .Edit:
		return "Edit"
	case .Bash:
		return "Bash"
	case .Other:
		return "Other"
	}
	return "Other"
}

// is_file_edit_tool: Auto mode auto-approves these (Grok acceptEdits).
is_file_edit_tool :: proc(tool_name: string) -> bool {
	for n in FILE_EDIT_TOOLS {
		if n == tool_name {
			return true
		}
	}
	return false
}

// tool_class maps model tool names to permission class strings (rules / UI).
tool_class :: proc(tool_name: string) -> string {
	return tool_perm_class_string(tool_perm_class(tool_name))
}

is_write_or_shell :: proc(tool_name: string) -> bool {
	switch tool_perm_class(tool_name) {
	case .Edit, .Bash:
		return true
	case .Read, .Other:
	}
	// use_tool = MCP dispatch (unknown side effects) — treat like shell for modes
	for n in WRITE_OR_SHELL_EXTRA {
		if n == tool_name {
			return true
		}
	}
	return false
}

// match_rule checks a single allow/deny rule against tool + optional command.
// Rules: "Read", "Edit", "Bash", "Bash(git *)", "Bash(rm -rf *)"
match_rule :: proc(rule: string, tool_name: string, command: string) -> bool {
	r := strings.trim_space(rule)
	if r == "" {
		return false
	}
	class := tool_class(tool_name)

	// Bare class match
	if strings.equal_fold(r, class) || strings.equal_fold(r, "Any") || r == "*" {
		return true
	}

	// Bash(pattern)
	if strings.has_prefix(r, "Bash(") && strings.has_suffix(r, ")") {
		if class != "Bash" {
			return false
		}
		pat := r[5:len(r) - 1]
		return match_simple_glob(pat, command)
	}
	if strings.has_prefix(r, "Edit(") {
		return class == "Edit"
	}
	if strings.has_prefix(r, "Read(") {
		return class == "Read"
	}
	return false
}

// match_simple_glob: Grok-shaped shell globs for Bash(…) rules (B13).
// Supports multiple `*` (each matches any run of characters, including spaces).
// Also supports `?` (single char) and simple `[abc]` classes in non-star segments.
// Examples: "git *" , "git * main" , "rm -rf *" , "cargo *".
match_simple_glob :: proc(pattern: string, text: string) -> bool {
	p := strings.trim_space(pattern)
	if p == "*" || p == "" {
		return true
	}
	// Fast path: no meta
	if strings.index_byte(p, '*') < 0 &&
	   strings.index_byte(p, '?') < 0 &&
	   strings.index_byte(p, '[') < 0 {
		return text == p || strings.has_prefix(text, p)
	}
	return glob_match_multi(p, text)
}

// glob_match_multi: sequential match of pattern against text with * / ? / [].
@(private)
glob_match_multi :: proc(pattern: string, text: string) -> bool {
	// Split pattern on * into literal segments (empty segs for leading/trailing/double *)
	parts := make([dynamic]string, 0, 8, context.temp_allocator)
	start := 0
	for i := 0; i <= len(pattern); i += 1 {
		if i == len(pattern) || pattern[i] == '*' {
			append(&parts, pattern[start:i])
			start = i + 1
		}
	}
	// parts: [pre, mid1, mid2, …, suf] with * between each
	if len(parts) == 0 {
		return text == ""
	}
	// No '*': single literal segment must consume whole text
	if len(parts) == 1 {
		n := glob_literal_len(parts[0], text, 0)
		return n == len(text)
	}
	// Leading segment must match prefix (unless empty = leading *)
	pos := 0
	if parts[0] != "" {
		n := glob_literal_len(parts[0], text, 0)
		if n < 0 {
			return false
		}
		pos = n
	}
	// Middle segments: find each after pos
	for pi := 1; pi < len(parts) - 1; pi += 1 {
		seg := parts[pi]
		if seg == "" {
			continue
		}
		found := -1
		for j := pos; j <= len(text); j += 1 {
			n := glob_literal_len(seg, text, j)
			if n >= 0 {
				found = n
				break
			}
		}
		if found < 0 {
			return false
		}
		pos = found
	}
	// Trailing segment
	last := parts[len(parts) - 1]
	if last == "" {
		return true
	}
	// Match last as suffix ending at EOF
	for j := pos; j <= len(text); j += 1 {
		n := glob_literal_len(last, text, j)
		if n == len(text) {
			return true
		}
	}
	return false
}

// glob_literal_len: match pattern segment (no *) at text[from:]; returns end index or -1.
// Supports ? and [abc]/[!abc].
@(private)
glob_literal_len :: proc(seg: string, text: string, from: int) -> int {
	si := 0
	ti := from
	for si < len(seg) {
		if ti >= len(text) {
			return -1
		}
		ch := seg[si]
		if ch == '?' {
			si += 1
			ti += 1
			continue
		}
		if ch == '[' {
			// character class
			si += 1
			neg := false
			if si < len(seg) && (seg[si] == '!' || seg[si] == '^') {
				neg = true
				si += 1
			}
			matched := false
			closed := false
			for si < len(seg) {
				if seg[si] == ']' {
					si += 1
					closed = true
					break
				}
				// range a-z
				if si + 2 < len(seg) && seg[si + 1] == '-' && seg[si + 2] != ']' {
					lo := seg[si]
					hi := seg[si + 2]
					c := text[ti]
					if c >= lo && c <= hi {
						matched = true
					}
					si += 3
					continue
				}
				if seg[si] == text[ti] {
					matched = true
				}
				si += 1
			}
			if !closed {
				return -1
			}
			if neg {
				matched = !matched
			}
			if !matched {
				return -1
			}
			ti += 1
			continue
		}
		if ch != text[ti] {
			return -1
		}
		si += 1
		ti += 1
	}
	return ti
}

// check_tool decides whether a tool may run.
// Deny rules win. Soft bash hard-deny beats always-approve. Readonly bash auto-allows.
// Read_Only denies write/shell except recognized read-only shell.
check_tool :: proc(
	mode: Permission_Mode,
	tool_name: string,
	command: string, // for bash; may be empty
	allow: []string,
	deny: []string,
) -> Permission_Decision {
	// Config deny always wins
	for rule in deny {
		if match_rule(rule, tool_name, command) {
			return .Deny
		}
	}

	// Soft bash: catastrophic patterns denied even under always-approve
	if (tool_name == "run_terminal_cmd" || tool_name == "monitor") && command != "" {
		if why := bash_hard_deny_reason(command); why != "" {
			return .Deny
		}
	}

	// Read-only shell auto-allow (Grok built-in) — including under Read_Only mode
	if (tool_name == "run_terminal_cmd" || tool_name == "monitor") &&
	   command != "" &&
	   bash_is_readonly(command) {
		return .Allow
	}

	if mode == .Read_Only && is_write_or_shell(tool_name) {
		return .Deny
	}

	// Read tools always allowed unless denied.
	if !is_write_or_shell(tool_name) {
		return .Allow
	}

	if len(allow) > 0 {
		for rule in allow {
			if match_rule(rule, tool_name, command) {
				return .Allow
			}
		}
		// allow list present but no match → fall through to mode (ask still prompts)
	}

	switch mode {
	case .Always_Approve:
		return .Allow
	case .Auto:
		// acceptEdits: file edits allowed; bash/MCP/media still ask
		if is_file_edit_tool(tool_name) {
			return .Allow
		}
		return .Ask
	case .Read_Only:
		return .Deny
	case .Ask:
		return .Ask
	}
	return .Allow
}

// --- Session-scoped always-allow grants (Grok in-memory session allows) ---

g_session_allow_mu: sync.Mutex
g_session_allow:    [dynamic]string

session_allow_enabled :: proc() -> bool {
	return !feature_killed("AETHER_NO_SESSION_ALLOW")
}

session_allow_ensure_heap :: proc() {
	raw := (^runtime.Raw_Dynamic_Array)(&g_session_allow)
	if raw.allocator.procedure == runtime.heap_allocator().procedure {
		return
	}
	old := g_session_allow
	g_session_allow = make([dynamic]string, 0, max(8, len(old)), runtime.heap_allocator())
	for s in old {
		append(&g_session_allow, s)
	}
	if raw_data(old) != nil {
		delete(old)
	}
}

// session_allow_add appends a grant rule (cloned). No-ops if disabled or empty.
session_allow_add :: proc(rule: string) {
	if !session_allow_enabled() {
		return
	}
	r := strings.trim_space(rule)
	if r == "" {
		return
	}
	sync.mutex_lock(&g_session_allow_mu)
	defer sync.mutex_unlock(&g_session_allow_mu)
	session_allow_ensure_heap()
	for existing in g_session_allow {
		if existing == r {
			return
		}
	}
	append(&g_session_allow, strings.clone(r, context.allocator))
}

// session_allow_clear frees all session grants (e.g. /new).
session_allow_clear :: proc() {
	sync.mutex_lock(&g_session_allow_mu)
	defer sync.mutex_unlock(&g_session_allow_mu)
	for s in g_session_allow {
		delete(s)
	}
	clear(&g_session_allow)
}

// session_allow_count for tests / status.
session_allow_count :: proc() -> int {
	sync.mutex_lock(&g_session_allow_mu)
	defer sync.mutex_unlock(&g_session_allow_mu)
	return len(g_session_allow)
}

// merge_allow_lists: config allow + session grants into temp slice (caller uses immediately).
merge_allow_lists :: proc(config_allow: []string, allocator := context.temp_allocator) -> []string {
	sync.mutex_lock(&g_session_allow_mu)
	defer sync.mutex_unlock(&g_session_allow_mu)
	n := len(config_allow) + len(g_session_allow)
	if n == 0 {
		return nil
	}
	out := make([dynamic]string, 0, n, allocator)
	for s in config_allow {
		append(&out, s)
	}
	for s in g_session_allow {
		append(&out, s)
	}
	return out[:]
}

// --- Session-scoped never-allow (Grok RejectAlways / in-memory deny) ---

g_session_deny_mu: sync.Mutex
g_session_deny:    [dynamic]string

session_deny_ensure_heap :: proc() {
	raw := (^runtime.Raw_Dynamic_Array)(&g_session_deny)
	if raw.allocator.procedure == runtime.heap_allocator().procedure {
		return
	}
	old := g_session_deny
	g_session_deny = make([dynamic]string, 0, max(8, len(old)), runtime.heap_allocator())
	for s in old {
		append(&g_session_deny, s)
	}
	if raw_data(old) != nil {
		delete(old)
	}
}

// session_deny_add appends a deny rule (cloned). Gated by session_allow_enabled.
session_deny_add :: proc(rule: string) {
	if !session_allow_enabled() {
		return
	}
	r := strings.trim_space(rule)
	if r == "" {
		return
	}
	sync.mutex_lock(&g_session_deny_mu)
	defer sync.mutex_unlock(&g_session_deny_mu)
	session_deny_ensure_heap()
	for existing in g_session_deny {
		if existing == r {
			return
		}
	}
	append(&g_session_deny, strings.clone(r, context.allocator))
}

session_deny_clear :: proc() {
	sync.mutex_lock(&g_session_deny_mu)
	defer sync.mutex_unlock(&g_session_deny_mu)
	for s in g_session_deny {
		delete(s)
	}
	clear(&g_session_deny)
}

session_deny_count :: proc() -> int {
	sync.mutex_lock(&g_session_deny_mu)
	defer sync.mutex_unlock(&g_session_deny_mu)
	return len(g_session_deny)
}

// merge_deny_lists: config deny + session never-allow grants.
merge_deny_lists :: proc(config_deny: []string, allocator := context.temp_allocator) -> []string {
	sync.mutex_lock(&g_session_deny_mu)
	defer sync.mutex_unlock(&g_session_deny_mu)
	n := len(config_deny) + len(g_session_deny)
	if n == 0 {
		return nil
	}
	out := make([dynamic]string, 0, n, allocator)
	for s in config_deny {
		append(&out, s)
	}
	for s in g_session_deny {
		append(&out, s)
	}
	return out[:]
}

// rule_for_session_grant: alias name for allow/deny grant generation.
rule_for_session_grant :: proc(
	tool_name: string,
	command: string,
	allocator := context.allocator,
) -> string {
	return rule_for_always_allow(tool_name, command, allocator)
}

// SAFE single-token binaries (subset of Grok safe-command list).
SAFE_BASH_BINS :: []string{
	"ls", "cat", "pwd", "date", "whoami", "hostname", "uptime", "ps",
	"rg", "grep", "head", "tail", "wc", "find", "which", "type", "file",
	"tree", "du", "df", "echo", "true", "false", "basename", "dirname",
	"realpath", "env", "printenv", "stat", "readlink",
}

// SAFE two-word prefixes.
SAFE_BASH_TWO :: []string{
	"git status", "git branch", "git log", "git diff", "git show",
	"git ls-files", "git rev-parse", "git remote",
	"cargo check", "cargo test", "cargo build", "cargo clippy",
	"npm test", "npm run", "npm ls",
	"kubectl get", "kubectl describe", "kubectl logs",
	"odin check", "odin test", "odin build",
}

is_safe_bash_bin :: proc(word: string) -> bool {
	w := strings.to_lower(word, context.temp_allocator)
	for b in SAFE_BASH_BINS {
		if w == b {
			return true
		}
	}
	return false
}

is_safe_bash_two :: proc(a, b: string) -> bool {
	joined := fmt.tprintf("%s %s", strings.to_lower(a, context.temp_allocator), strings.to_lower(b, context.temp_allocator))
	for t in SAFE_BASH_TWO {
		if joined == t {
			return true
		}
	}
	return false
}

// default_always_allow_scope: word count to keep (Grok manager.rs simplified).
default_always_allow_scope :: proc(words: []string) -> int {
	if len(words) == 0 {
		return 0
	}
	if is_safe_bash_bin(words[0]) {
		// full invocation is "safe enough" for single-bin tools even with args
		return 1
	}
	if len(words) >= 2 && is_safe_bash_two(words[0], words[1]) {
		return 2
	}
	// default: first two words, plus leading flags after that
	n := min(2, len(words))
	for n < len(words) && strings.has_prefix(words[n], "-") {
		n += 1
	}
	return n
}

// rule_for_always_allow builds a session grant rule. Empty if not supported.
// Prefer Bash/Edit only (MCP use_tool skipped in this slice).
rule_for_always_allow :: proc(
	tool_name: string,
	command: string,
	allocator := context.allocator,
) -> string {
	switch tool_name {
	case "search_replace":
		return strings.clone("Edit", allocator)
	case "run_terminal_cmd", "monitor":
		cmd := strings.trim_space(command)
		if cmd == "" {
			return strings.clone("Bash", allocator)
		}
		words, _ := strings.fields(cmd, context.temp_allocator)
		if len(words) == 0 {
			return strings.clone("Bash", allocator)
		}
		n := default_always_allow_scope(words)
		if n <= 0 {
			n = 1
		}
		if n > len(words) {
			n = len(words)
		}
		prefix := strings.join(words[:n], " ", context.temp_allocator)
		return fmt.aprintf("Bash(%s *)", prefix, allocator = allocator)
	case:
		// use_tool / Other: no session always-allow in this slice
		return ""
	}
}
