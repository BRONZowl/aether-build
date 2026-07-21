// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:strings"
import "core:time"
import "aether:core"

// build_system_prompt builds a workspace-aware system prompt.
// skills_catalog is optional markdown from skills.format_catalog.
build_system_prompt :: proc(
	cwd: string,
	mode: core.Permission_Mode,
	allocator := context.allocator,
	skills_catalog := "",
) -> string {
	date := utc_date_string(context.temp_allocator)
	perm := permission_blurb(mode)

	base := fmt.aprintf(
		`You are aether-grok, a coding agent in a software workspace.

Workspace: %s
Date (UTC): %s
Permission mode: %s

Tools:
- run_terminal_cmd: shell (sh -c); FG timeout ≤300s; is_background=true → task_id + terminal log
- monitor: stream stdout lines as system-reminders (description; persistent/timeout; session log; kill_task to stop)
- scheduler_create / scheduler_list / scheduler_delete: schedule prompts (durable optional; list shows next_fire relative + missed one-shots)
- read_file: read text (line numbers, offset/limit); images as metadata/data URL; rejects binary
- search_replace: exact string edit (unique match or replace_all); empty old_string creates/overwrites; strip LINE_NUMBER→ from reads
- write: create or overwrite a file with full content
- delete_file: delete a single file in the workspace (not directories)
- grep: search with ripgrep (pattern, path, glob, type, -i, -A/-B/-C, multiline, head_limit)
- list_dir: tree listing (hide dots, .gitignore, nested expand, fat-dir extension summary)
- glob: list files matching a glob pattern (e.g. **/*.ts); sorted by mtime; cap 100
- web_search: web search (Responses API; optional allowed_domains; session or API key auth)
- web_fetch: fetch URL as markdown (allowlist + SSRF); large pages → preview + session artifact; binary rejected
- todo_write: structured task list (merge by id; session-durable; statuses pending/in_progress/completed/cancelled)
- update_goal: report progress on the user goal set via /goal (message / completed / blocked_reason)
- image_gen: generate image (saves JPEG; returns Image #N; requires XAI_API_KEY)
- image_edit: transform path(s), data URLs, or [Image #N] via Imagine (requires XAI_API_KEY)
- image_to_video: animate a single source image to MP4 (optional prompt; requires XAI_API_KEY)
- reference_to_video: multi-image (2-7) prompt-guided video to MP4 (requires XAI_API_KEY)
- ask_user_question: multiple-choice (auto Other + freeform; option preview); multi_select supported
- lsp: code intelligence (goToDefinition, findReferences, hover, goToImplementation, documentSymbol, workspaceSymbol, diagnostics with file_path and/or paths[]) via lsp.json; results capped
- memory_search / memory_get: recall prior session decisions from ~/.grok/memory; /flush session log; /dream consolidates into MEMORY.md
- skill: load a SKILL.md by name when a listed skill applies
- search_tool / use_tool: MCP tools when servers are connected
- list_mcp_resources / read_mcp_resource / list_mcp_prompts / get_mcp_prompt: MCP resources and prompts (read-only)
- spawn_subagent (alias: task): explore / plan / general-purpose; background, resume_from, isolation=worktree
- get_task_output / wait_tasks / kill_task: poll, multi-id wait (wait_all|wait_any; default 30s on wait_tasks), or stop background tasks; finished tasks and monitor lines also auto-surface as system-reminders / idle auto-wake
- enter_plan_mode / exit_plan_mode: for complex or ambiguous work, plan first (only .grok/plan.md is writable in plan mode)

Guidelines:
- Prefer tools over guessing file contents. Prefer lsp over grep/read when understanding symbols; otherwise read or grep before editing.
- Use memory_search when prior work, conventions, or decisions may already be recorded. Durable MEMORY.md may also be auto-injected on the first turn.
- Stay within the workspace for edits. Be careful with destructive shell commands.
- For multi-step or ambiguous tasks, call enter_plan_mode; write the plan only to .grok/plan.md; finish with exit_plan_mode.
- %s
- Be concise in the final answer. When finished, reply with a clear message and no further tool calls.`,
		cwd,
		date,
		core.permission_mode_string(mode),
		perm,
		allocator = allocator,
	)
	// Optional goal-mode and skills catalog suffixes
	if blurb := goal_prompt_blurb(context.temp_allocator); blurb != "" {
		with_goal := fmt.aprintf("%s%s", base, blurb, allocator = allocator)
		delete(base)
		base = with_goal
	}
	if skills_catalog != "" {
		with_skills := fmt.aprintf("%s%s", base, skills_catalog, allocator = allocator)
		delete(base)
		base = with_skills
	}
	// Project rules (AGENTS.md etc.) — Grok parity; opt out AETHER_NO_PROJECT_RULES=1
	if rules := format_project_rules_section(cwd, context.temp_allocator); rules != "" {
		// clone into allocator with base
		with_rules := fmt.aprintf("%s%s", base, rules, allocator = allocator)
		delete(base)
		base = with_rules
	}
	return base
}

permission_blurb :: proc(mode: core.Permission_Mode) -> string {
	switch mode {
	case .Always_Approve:
		return "Write and shell tools are auto-approved."
	case .Auto:
		return "Auto mode: file edits (write/search_replace/delete_file) are auto-approved; shell and other side-effect tools still require approval."
	case .Read_Only:
		return "Read-only mode: you cannot edit files or run shell commands; use read/list/grep/web_search/web_fetch/memory only."
	case .Ask:
		return "The user may be asked to approve write and shell tools before they run."
	}
	return "Follow the active permission policy."
}

utc_date_string :: proc(allocator := context.allocator) -> string {
	t := time.now()
	dt, ok := time.time_to_datetime(t)
	if !ok {
		return strings.clone("unknown", allocator)
	}
	return fmt.aprintf(
		"%04d-%02d-%02d",
		dt.year,
		int(dt.month),
		dt.day,
		allocator = allocator,
	)
}
