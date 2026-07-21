// Package tools — tool registry: schema fragments + local dispatch names (P2).
// Single registration site for tools_json_schema; dispatch stays name-switch for handlers.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tools

import "core:strings"

Tool_Group :: enum {
	Core,
	Mcp,
	Skill,
	Spawn,
	Plan,
	Memory,
	Hashline,
}

// Tool_Spec: one OpenAI function tool object (JSON, no leading comma).
// local=true means tools.dispatch implements it; false = agent/loop (or other) owns execution.
Tool_Spec :: struct {
	name:   string,
	schema: string,
	group:  Tool_Group,
	local:  bool,
}

// TOOL_REGISTRY is the single source of tool names + schema fragments.
TOOL_REGISTRY := [?]Tool_Spec {
	{
		name   = "run_terminal_cmd",
		schema = `{"type":"function","function":{"name":"run_terminal_cmd","description":"Run a shell command in the workspace (sh -c). FG timeout default 120s, max 300s. Set is_background=true for long jobs (task_id + session terminal log). Poll with get_task_output; stop with kill_task.","parameters":{"type":"object","properties":{"command":{"type":"string"},"description":{"type":"string","description":"Short label for background tasks"},"timeout":{"type":"integer","description":"FG max 300000 ms; background: 0 or omit = no limit"},"is_background":{"type":"boolean","description":"If true, run async and return task_id + log path"}},"required":["command"]}}}`,
		group  = .Core,
		local  = true,
	},
	{
		name   = "read_file",
		schema = `{"type":"function","function":{"name":"read_file","description":"Read a file. Text: line numbers (N→), offset/limit (negative offset from end). Images: metadata + optional small data URL. PDF: pdftotext extract. PPTX: slide text via unzip. pages for PDF/PPTX (max 20). Binary otherwise rejected.","parameters":{"type":"object","properties":{"target_file":{"type":"string"},"offset":{"type":"integer","description":"1-based start line; negative = from end"},"limit":{"type":"integer","description":"Max lines (default 1000)"},"pages":{"type":"string","description":"PDF/PPTX: page/slide range e.g. 1-5, 3, 10-"}},"required":["target_file"]}}}`,
		group  = .Core,
		local  = true,
	},
	{
		name   = "search_replace",
		schema = `{"type":"function","function":{"name":"search_replace","description":"Exact string replace in a file. Do not include LINE_NUMBER→ prefixes from read_file. old_string must match exactly one place unless replace_all=true. Empty old_string creates/overwrites the file.","parameters":{"type":"object","properties":{"file_path":{"type":"string"},"old_string":{"type":"string"},"new_string":{"type":"string"},"replace_all":{"type":"boolean","description":"Replace every occurrence (default false)"}},"required":["file_path","old_string","new_string"]}}}`,
		group  = .Core,
		local  = true,
	},
	{
		name   = "write",
		schema = `{"type":"function","function":{"name":"write","description":"Create or overwrite a file with full content. Parent directories are created. Prefer search_replace for partial edits.","parameters":{"type":"object","properties":{"file_path":{"type":"string"},"content":{"type":"string"}},"required":["file_path","content"]}}}`,
		group  = .Core,
		local  = true,
	},
	{
		name   = "delete_file",
		schema = `{"type":"function","function":{"name":"delete_file","description":"Delete a single file within the workspace (not directories).","parameters":{"type":"object","properties":{"target_file":{"type":"string","description":"Path to delete"},"file_path":{"type":"string","description":"Alias for target_file"}},"required":["target_file"]}}}`,
		group  = .Core,
		local  = true,
	},
	{
		name   = "grep",
		schema = `{"type":"function","function":{"name":"grep","description":"Search file contents with ripgrep. Supports -A/-B/-C context, type, glob, multiline, -i, head_limit (total output lines, default 200).","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string"},"type":{"type":"string","description":"rg --type (js, py, rust, …)"},"head_limit":{"type":"integer","description":"Max output lines (default 200)"},"-i":{"type":"boolean"},"-A":{"type":"integer"},"-B":{"type":"integer"},"-C":{"type":"integer"},"multiline":{"type":"boolean"}},"required":["pattern"]}}}`,
		group  = .Core,
		local  = true,
	},
	{
		name   = "list_dir",
		schema = `{"type":"function","function":{"name":"list_dir","description":"List files and directories in a path (relative or absolute under workspace). Hides dotfiles; respects .gitignore; nested tree under a char budget; large dirs summarized by extension counts.","parameters":{"type":"object","properties":{"target_directory":{"type":"string","description":"Directory to list (default .)"}},"required":[]}}}`,
		group  = .Core,
		local  = true,
	},
	{
		name   = "glob",
		schema = `{"type":"function","function":{"name":"glob","description":"List files matching a glob pattern (e.g. **/*.ts). Uses ripgrep --files; respects .gitignore; sorted by mtime (newest first); capped at 100 results.","parameters":{"type":"object","properties":{"pattern":{"type":"string","description":"Glob pattern"},"path":{"type":"string","description":"Directory to search (default workspace root)"}},"required":["pattern"]}}}`,
		group  = .Core,
		local  = true,
	},
	{
		name   = "web_search",
		schema = `{"type":"function","function":{"name":"web_search","description":"Search the web for up-to-date coding/software information via Responses API. Optional allowed_domains filter. Auth: grok login session or XAI_API_KEY.","parameters":{"type":"object","properties":{"query":{"type":"string"},"allowed_domains":{"type":"array","items":{"type":"string"},"description":"Restrict results to these domains"}},"required":["query"]}}}`,
		group  = .Core,
		local  = true,
	},
	{
		name   = "web_fetch",
		schema = `{"type":"function","function":{"name":"web_fetch","description":"Fetch a URL as markdown/text. Fails for auth/private URLs (use MCP). HTTP→HTTPS; domain allowlist + SSRF. Long pages: inline preview + full body saved under session web_fetch/ for read_file. Binary responses rejected.","parameters":{"type":"object","properties":{"url":{"type":"string","description":"The URL to fetch content from"}},"required":["url"]}}}`,
		group  = .Core,
		local  = true,
	},
	{
		name   = "todo_write",
		schema = `{"type":"function","function":{"name":"todo_write","description":"Create and manage a structured task list. The user sees this list live — it is your primary way to show progress. Use for any task with 3+ steps. Skip for trivial single-step work.","parameters":{"type":"object","properties":{"merge":{"type":"boolean","description":"When true (default), merge todos by id; when false, replace the list"},"todos":{"type":"array","items":{"type":"object","properties":{"id":{"type":"string"},"content":{"type":"string"},"status":{"type":"string","description":"pending|in_progress|completed|cancelled"}},"required":["id"]}}},"required":["todos"]}}}`,
		group  = .Core,
		local  = true,
	},
	{
		name   = "ask_user_question",
		schema = `{"type":"function","function":{"name":"ask_user_question","description":"Ask the user one or more multiple-choice questions. Every question automatically gets an Other choice for free text. Put the recommended option first and append (Recommended) to its label.","parameters":{"type":"object","properties":{"questions":{"type":"array","items":{"type":"object","properties":{"question":{"type":"string"},"options":{"type":"array","items":{"type":"object","properties":{"label":{"type":"string"},"description":{"type":"string"},"preview":{"type":"string"}},"required":["label","description"]}},"multi_select":{"type":"boolean"}},"required":["question","options"]}}},"required":["questions"]}}}`,
		group  = .Core,
		local  = false,
	},
	{
		name   = "lsp",
		schema = `{"type":"function","function":{"name":"lsp","description":"Code intelligence via language servers. Prefer over grep/read_file for understanding code. Operations: goToDefinition, findReferences, hover, goToImplementation, documentSymbol, workspaceSymbol (requires query), diagnostics (file_path and/or paths[]; optional errors_only or min_severity 1-4). Position ops need file_path + line + character (0-based). Optional timeout_ms for diagnostics settle (default ~1500, max 10000). Results capped; paths relative to workspace when possible.","parameters":{"type":"object","properties":{"operation":{"type":"string","description":"goToDefinition|findReferences|hover|goToImplementation|documentSymbol|workspaceSymbol|diagnostics"},"file_path":{"type":"string"},"paths":{"type":"array","items":{"type":"string"},"description":"diagnostics: multiple files (cap 20)"},"line":{"type":"integer","description":"0-indexed line"},"character":{"type":"integer","description":"0-indexed column"},"query":{"type":"string","description":"workspaceSymbol query"},"timeout_ms":{"type":"integer","description":"diagnostics: wait for publishDiagnostics"},"errors_only":{"type":"boolean","description":"diagnostics: only severity=error"},"min_severity":{"description":"diagnostics: 1=error..4=hint (or error|warn|info|hint)"}},"required":["operation"]}}}`,
		group  = .Core,
		local  = true,
	},
	{
		name   = "monitor",
		schema = `{"type":"function","function":{"name":"monitor","description":"Start a background monitor that streams events from a long-running script. Each stdout line is an event — notifications arrive as system-reminders. Exit ends the watch. Use selective filters (grep --line-buffered). Set persistent=true for session-length watches; stop with kill_task.","parameters":{"type":"object","properties":{"command":{"type":"string","description":"Shell command or script"},"description":{"type":"string","description":"Short label shown on every event"},"timeout_ms":{"type":"integer","description":"Kill after this many ms (default 10h); ignored if persistent"},"persistent":{"type":"boolean","description":"Run until kill_task or exit (no timeout)"}},"required":["command","description"]}}}`,
		group  = .Core,
		local  = false,
	},
	{
		name   = "scheduler_create",
		schema = `{"type":"function","function":{"name":"scheduler_create","description":"Create a scheduled task that runs a prompt on a recurring interval. Interval e.g. 5m, 2h, 1d, 60s (min 60s). Max 50 tasks; recurring expire after 7 days. durable=true persists across process restarts and /new. Set fire_immediately=true to fire once on create.","parameters":{"type":"object","properties":{"interval":{"type":"string"},"prompt":{"type":"string"},"recurring":{"type":"boolean"},"durable":{"type":"boolean","description":"Persist across restarts and /new (default false)"},"fire_immediately":{"type":"boolean"}},"required":["interval","prompt"]}}}`,
		group  = .Core,
		local  = false,
	},
	{
		name   = "scheduler_list",
		schema = `{"type":"function","function":{"name":"scheduler_list","description":"List all active scheduled tasks with IDs, prompts, intervals, and next fire times.","parameters":{"type":"object","properties":{},"required":[]}}}`,
		group  = .Core,
		local  = false,
	},
	{
		name   = "scheduler_delete",
		schema = `{"type":"function","function":{"name":"scheduler_delete","description":"Cancel a scheduled task by ID. Returns success true/false.","parameters":{"type":"object","properties":{"id":{"type":"string"}},"required":["id"]}}}`,
		group  = .Core,
		local  = false,
	},
	{
		name   = "update_goal",
		schema = `{"type":"function","function":{"name":"update_goal","description":"Report progress on the active user goal (set via /goal). Use message for progress notes; completed=true ONLY when fully achieved; blocked_reason only after 3+ failed attempts at the same problem.","parameters":{"type":"object","properties":{"message":{"type":"string"},"completed":{"type":"boolean"},"blocked_reason":{"type":"string"}},"required":[]}}}`,
		group  = .Core,
		local  = false,
	},
	{
		name   = "image_gen",
		schema = `{"type":"function","function":{"name":"image_gen","description":"Generate an image via xAI Imagine; saves JPEG under session images/; returns path and Image #N for later image_edit/video. Requires XAI_API_KEY.","parameters":{"type":"object","properties":{"prompt":{"type":"string"},"aspect_ratio":{"type":"string","description":"auto|1:1|16:9|9:16|4:3|3:4|3:2|2:3"}},"required":["prompt"]}}}`,
		group  = .Core,
		local  = false,
	},
	{
		name   = "image_edit",
		schema = `{"type":"function","function":{"name":"image_edit","description":"Edit images via Imagine. image[] accepts paths, data URLs, or [Image #N] from prior gen/edit. JPEG/PNG ≤400KB pass-through; else ImageMagick compress. Requires XAI_API_KEY.","parameters":{"type":"object","properties":{"prompt":{"type":"string"},"image":{"type":"array","items":{"type":"string"}},"aspect_ratio":{"type":"string"}},"required":["prompt","image"]}}}`,
		group  = .Core,
		local  = false,
	},
	{
		name   = "image_to_video",
		schema = `{"type":"function","function":{"name":"image_to_video","description":"Generate a video from a single source image via xAI Imagine. Provide image (path, data URL, or https URL) and optional prompt/duration/resolution_name. Saves MP4 under session videos/. Requires XAI_API_KEY.","parameters":{"type":"object","properties":{"image":{"type":"string"},"prompt":{"type":"string"},"duration":{"type":"integer","description":"6 or 10 seconds"},"resolution_name":{"type":"string","description":"480p or 720p"}},"required":["image"]}}}`,
		group  = .Core,
		local  = false,
	},
	{
		name   = "reference_to_video",
		schema = `{"type":"function","function":{"name":"reference_to_video","description":"Generate a video from 2-7 reference images and a prompt via xAI Imagine. Saves MP4 under session videos/. Requires XAI_API_KEY.","parameters":{"type":"object","properties":{"prompt":{"type":"string"},"images":{"type":"array","items":{"type":"string"}},"aspect_ratio":{"type":"string","description":"1:1|16:9|9:16|3:2|2:3"},"duration":{"type":"integer","description":"6 or 10"},"resolution_name":{"type":"string","description":"480p or 720p"}},"required":["prompt","images"]}}}`,
		group  = .Core,
		local  = false,
	},
	{
		name   = "search_tool",
		schema = `{"type":"function","function":{"name":"search_tool","description":"Search for MCP integration tools by keyword.","parameters":{"type":"object","properties":{"query":{"type":"string"},"limit":{"type":"integer"}},"required":["query"]}}}`,
		group  = .Mcp,
		local  = false,
	},
	{
		name   = "use_tool",
		schema = `{"type":"function","function":{"name":"use_tool","description":"Call an MCP tool. tool_name is server__tool from search_tool.","parameters":{"type":"object","properties":{"tool_name":{"type":"string"},"tool_input":{"type":"object","additionalProperties":true}},"required":["tool_name","tool_input"]}}}`,
		group  = .Mcp,
		local  = false,
	},
	{
		name   = "list_mcp_resources",
		schema = `{"type":"function","function":{"name":"list_mcp_resources","description":"List MCP resources (uri/name) from connected servers.","parameters":{"type":"object","properties":{"server":{"type":"string"},"query":{"type":"string"},"limit":{"type":"integer"}},"required":[]}}}`,
		group  = .Mcp,
		local  = false,
	},
	{
		name   = "read_mcp_resource",
		schema = `{"type":"function","function":{"name":"read_mcp_resource","description":"Read an MCP resource by server and uri.","parameters":{"type":"object","properties":{"server":{"type":"string"},"uri":{"type":"string"}},"required":["server","uri"]}}}`,
		group  = .Mcp,
		local  = false,
	},
	{
		name   = "list_mcp_prompts",
		schema = `{"type":"function","function":{"name":"list_mcp_prompts","description":"List MCP prompts from connected servers.","parameters":{"type":"object","properties":{"server":{"type":"string"},"query":{"type":"string"},"limit":{"type":"integer"}},"required":[]}}}`,
		group  = .Mcp,
		local  = false,
	},
	{
		name   = "get_mcp_prompt",
		schema = `{"type":"function","function":{"name":"get_mcp_prompt","description":"Get an MCP prompt by server and name; optional arguments object.","parameters":{"type":"object","properties":{"server":{"type":"string"},"name":{"type":"string"},"arguments":{"type":"object","additionalProperties":true}},"required":["server","name"]}}}`,
		group  = .Mcp,
		local  = false,
	},
	{
		name   = "skill",
		schema = `{"type":"function","function":{"name":"skill","description":"Load a skill (SKILL.md) by name. Use when a listed skill matches the task.","parameters":{"type":"object","properties":{"skill":{"type":"string","description":"Skill name"},"args":{"type":"string","description":"Optional arguments for the skill"}},"required":["skill"]}}}`,
		group  = .Skill,
		local  = false,
	},
	{
		name   = "spawn_subagent",
		schema = `{"type":"function","function":{"name":"spawn_subagent","description":"Run a focused subagent (explore=read/research, plan=implementation plan, general-purpose=full coding). Set background=true to return a subagent_id immediately and poll with get_task_output. Default is synchronous. Pass resume_from with a prior subagent_id to continue that conversation (same subagent_type; appends prompt to the prior transcript). Set isolation=worktree for an isolated git worktree (edits stay off the parent tree; path returned and preserved). Optional persona=name loads ~/.grok/personas/<name>.md (or project .grok/personas/) instructions into the child system prompt. Alias: task.","parameters":{"type":"object","properties":{"prompt":{"type":"string","description":"Task for the subagent (or follow-up when resuming)"},"subagent_type":{"type":"string","description":"explore | plan | general-purpose; must match source when resume_from is set"},"description":{"type":"string","description":"Short label"},"background":{"type":"boolean","description":"If true, run async and return subagent_id"},"resume_from":{"type":"string","description":"Completed subagent_id to continue; same process only"},"isolation":{"type":"string","description":"none (default) | worktree — isolated git worktree for the child"},"persona":{"type":"string","description":"Optional persona name from ~/.grok/personas or project .grok/personas"}},"required":["prompt"]}}}`,
		group  = .Spawn,
		local  = false,
	},
	{
		name   = "task",
		schema = `{"type":"function","function":{"name":"task","description":"Alias for spawn_subagent: run explore/plan/general-purpose subagent (background, resume_from, isolation=worktree, persona supported).","parameters":{"type":"object","properties":{"prompt":{"type":"string"},"subagent_type":{"type":"string"},"description":{"type":"string"},"background":{"type":"boolean"},"resume_from":{"type":"string"},"isolation":{"type":"string"},"persona":{"type":"string"}},"required":["prompt"]}}}`,
		group  = .Spawn,
		local  = false,
	},
	{
		name   = "get_task_output",
		schema = `{"type":"function","function":{"name":"get_task_output","description":"Get output/status from a background task (subagent or shell). Pass task_ids and optional timeout_ms (0=poll once; >0 waits up to that budget). Max 20 ids.","parameters":{"type":"object","properties":{"task_ids":{"type":"array","items":{"type":"string"},"description":"Background task ids (sub-* or bash-*)"},"timeout_ms":{"type":"integer","description":"Wait up to this many ms; 0 polls"}},"required":[]}}}`,
		group  = .Spawn,
		local  = false,
	},
	{
		name   = "wait_tasks",
		schema = `{"type":"function","function":{"name":"wait_tasks","description":"Block until background tasks complete (wait-all by default). Prefer for multi-id waits. task_ids required; timeout_ms defaults to 30000 if omit/0; mode wait_all|wait_any. Alias: wait_commands_or_subagents. Max 20 ids.","parameters":{"type":"object","properties":{"task_ids":{"type":"array","items":{"type":"string"}},"timeout_ms":{"type":"integer"},"mode":{"type":"string","description":"wait_all (default) or wait_any"}},"required":["task_ids"]}}}`,
		group  = .Spawn,
		local  = false,
	},
	{
		name   = "wait_commands_or_subagents",
		schema = `{"type":"function","function":{"name":"wait_commands_or_subagents","description":"Alias for wait_tasks: block until background shell/subagent tasks complete.","parameters":{"type":"object","properties":{"task_ids":{"type":"array","items":{"type":"string"}},"timeout_ms":{"type":"integer"},"mode":{"type":"string"}},"required":["task_ids"]}}}`,
		group  = .Spawn,
		local  = false,
	},
	{
		name   = "kill_task",
		schema = `{"type":"function","function":{"name":"kill_task","description":"Stop a running background task. Shell tasks are process-killed; subagents cancel cooperatively.","parameters":{"type":"object","properties":{"task_id":{"type":"string","description":"Background task id"}},"required":["task_id"]}}}`,
		group  = .Spawn,
		local  = false,
	},
	{
		name   = "enter_plan_mode",
		schema = `{"type":"function","function":{"name":"enter_plan_mode","description":"Enter plan mode when a task is ambiguous or the user wants a plan. Enables a planning phase: explore the codebase and write an implementation plan only to the plan file (.grok/plan.md). No other file edits.","parameters":{"type":"object","properties":{},"required":[]}}}`,
		group  = .Plan,
		local  = false,
	},
	{
		name   = "exit_plan_mode",
		schema = `{"type":"function","function":{"name":"exit_plan_mode","description":"Exit plan mode after writing the plan to the plan file. Presents the plan and restores normal editing.","parameters":{"type":"object","properties":{},"required":[]}}}`,
		group  = .Plan,
		local  = false,
	},
	{
		name   = "memory_search",
		schema = `{"type":"function","function":{"name":"memory_search","description":"Search cross-session memory for relevant knowledge chunks. Returns ranked results from global, workspace, and session memory files under ~/.grok/memory.","parameters":{"type":"object","properties":{"query":{"type":"string","description":"Search query (prefer specific technical terms)"},"max_results":{"type":"integer","description":"Max results (default 6)"},"min_score":{"type":"number","description":"Minimum score threshold"}},"required":["query"]}}}`,
		group  = .Memory,
		local  = true,
	},
	{
		name   = "memory_get",
		schema = `{"type":"function","function":{"name":"memory_get","description":"Read a memory file by path with line numbers. Use after memory_search. path may be absolute under the memory root. from is 0-based; lines limits count.","parameters":{"type":"object","properties":{"path":{"type":"string"},"from":{"type":"integer","description":"0-based start line"},"lines":{"type":"integer","description":"Max lines to return"}},"required":["path"]}}}`,
		group  = .Memory,
		local  = true,
	},
	{
		name   = "hashline_read",
		schema = `{"type":"function","function":{"name":"hashline_read","description":"Read a file with hashline anchors (LINE:HASH→content). Use anchors with hashline_edit. Prefer over read_file when hashline pack is active.","parameters":{"type":"object","properties":{"file_path":{"type":"string"},"target_file":{"type":"string"},"offset":{"type":"integer","description":"1-based start line"},"limit":{"type":"integer"}},"required":["file_path"]}}}`,
		group  = .Hashline,
		local  = true,
	},
	{
		name   = "hashline_edit",
		schema = `{"type":"function","function":{"name":"hashline_edit","description":"Edit using hashline anchors from hashline_read. ops: replace (anchor[,end_anchor],content), insert_after (anchor,content; 0: BOF, EOF end), write (full content).","parameters":{"type":"object","properties":{"file_path":{"type":"string"},"op":{"type":"string","description":"replace|insert_after|write"},"anchor":{"type":"string","description":"LINE:HASH or 0: or EOF"},"end_anchor":{"type":"string"},"content":{"type":"string"}},"required":["file_path"]}}}`,
		group  = .Hashline,
		local  = true,
	},
	{
		name   = "hashline_grep",
		schema = `{"type":"function","function":{"name":"hashline_grep","description":"Search file contents (ripgrep); pair with hashline_read for anchors before editing.","parameters":{"type":"object","properties":{"pattern":{"type":"string"},"path":{"type":"string"},"glob":{"type":"string"},"-i":{"type":"boolean"},"head_limit":{"type":"integer"}},"required":["pattern"]}}}`,
		group  = .Hashline,
		local  = true,
	},
}

// tools_json_schema_from_registry builds the tools array from TOOL_REGISTRY.
tools_json_schema_from_registry :: proc(
	with_mcp := false,
	with_skills := false,
	with_spawn := false,
	with_plan := false,
	with_memory := false,
	deny_names: []string = nil,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_byte(&b, '[')
	first := true
	pack := tool_pack_from_env()
	pack_deny := deny_for_tool_pack(pack)
	for spec in TOOL_REGISTRY {
		include := false
		switch spec.group {
		case .Core:
			include = true
		case .Mcp:
			include = with_mcp
		case .Skill:
			include = with_skills
		case .Spawn:
			include = with_spawn
		case .Plan:
			include = with_plan
		case .Memory:
			include = with_memory
		case .Hashline:
			include = pack == .Hashline
		}
		if !include {
			continue
		}
		if tool_name_denied(spec.name, deny_names) {
			continue
		}
		if tool_name_denied(spec.name, pack_deny) {
			continue
		}
		if !first {
			strings.write_byte(&b, ',')
		}
		first = false
		strings.write_string(&b, spec.schema)
	}
	strings.write_byte(&b, ']')
	return strings.to_string(b)
}

// tool_is_registered reports whether name appears in TOOL_REGISTRY.
tool_is_registered :: proc(name: string) -> bool {
	for spec in TOOL_REGISTRY {
		if spec.name == name {
			return true
		}
	}
	return false
}

// tool_is_local reports whether tools.dispatch implements the tool.
tool_is_local :: proc(name: string) -> bool {
	for spec in TOOL_REGISTRY {
		if spec.name == name {
			return spec.local
		}
	}
	return false
}

