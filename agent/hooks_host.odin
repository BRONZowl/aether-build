// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:strings"
import "aether:core"
import "aether:hooks"

// g_hooks_cwd for SessionEnd at process teardown.
g_hooks_cwd: string

// maybe_start_hooks loads hooks for cwd into the process registry.
maybe_start_hooks :: proc(cwd: string, quiet: bool) {
	// keep last cwd for session end
	if g_hooks_cwd != "" {
		delete(g_hooks_cwd)
	}
	g_hooks_cwd = strings.clone(cwd if cwd != "" else ".")
	if !hooks.hooks_enabled() {
		hooks.clear_global_registry()
		return
	}
	hooks.reload_global_hooks(cwd)
	if !quiet {
		r := hooks.get_registry()
		if r != nil && len(r.specs) > 0 {
			fmt.eprintf("aether: hooks loaded: %d\n", len(r.specs))
		}
	}
	hooks.run_session_start_hooks(cwd)
}

// maybe_stop_hooks fires SessionEnd once then clears registry.
maybe_stop_hooks :: proc(reason: string = "exit") {
	cwd := g_hooks_cwd if g_hooks_cwd != "" else "."
	hooks.run_session_end_hooks(cwd, reason)
	if g_hooks_cwd != "" {
		delete(g_hooks_cwd)
		g_hooks_cwd = ""
	}
}

// allow_user_prompt runs UserPromptSubmit hooks. Returns false if blocked.
// When blocked and quiet is false, prints reason to stderr; TUI passes notice callback via status optional.
allow_user_prompt :: proc(cwd, prompt: string, quiet := false) -> bool {
	dec, reason := hooks.run_user_prompt_submit_hooks(cwd, prompt)
	if dec == .Deny {
		if !quiet {
			fmt.eprintf("aether: prompt blocked by hook: %s\n", reason)
		}
		return false
	}
	return true
}

// allow_user_prompt_notice like allow_user_prompt but returns deny reason for UI.
allow_user_prompt_notice :: proc(cwd, prompt: string) -> (ok: bool, reason: string) {
	dec, why := hooks.run_user_prompt_submit_hooks(cwd, prompt)
	if dec == .Deny {
		return false, why
	}
	return true, ""
}

// handle_hooks_slash: status | list | reload | paths | add | remove | trust | untrust | help
handle_hooks_slash :: proc(
	arg: string,
	cwd: string,
	allocator := context.allocator,
) -> string {
	a := strings.trim_space(arg)
	a_l := strings.to_lower(a, context.temp_allocator)
	if a_l == "help" || a_l == "?" {
		return strings.clone(
			"Usage: /hooks [status|list|reload|paths|add <path>|remove <path>|trust|untrust|help]\n" +
			"Local command hooks from $GROK_HOME/hooks, <cwd>/.grok/hooks, and hooks-paths (B18).\n" +
			"  add/remove  absolute path under ~/.grok (file or dir of *.json)\n" +
			"  paths       list ~/.grok/hooks-paths entries\n" +
			"  trust       grant folder trust for this workspace (project hooks may load)\n" +
			"  untrust     revoke folder trust (project hooks gated; global hooks keep loading)\n" +
			"  list|status loaded hooks for this session + folder-trust line\n" +
			"Events: SessionStart/End, Pre/PostToolUse(+Fail), Stop, UserPromptSubmit, PermissionDenied,\n" +
			"         SubagentStart/Stop, PreCompact/PostCompact, Notification.\n" +
			"Opt-out: AETHER_NO_HOOKS=1  AETHER_NO_FOLDER_TRUST=1 (always load project hooks)\n" +
			"Store: ~/.grok/trusted_folders.toml (Grok-compatible).",
			allocator,
		)
	}
	// M1: /hooks trust | untrust (Grok hooks-trust / hooks-untrust)
	if a_l == "trust" || a_l == "hooks-trust" {
		if err := core.grant_folder_trust(cwd); err != "" {
			return fmt.aprintf("aether: hooks trust failed: %s", err, allocator = allocator)
		}
		maybe_start_hooks(cwd, true)
		return fmt.aprintf(
			"aether: folder trusted — project hooks may load\n%s\n%s",
			core.folder_trust_status_line(cwd, context.temp_allocator),
			hooks.status_text(hooks.get_registry(), context.temp_allocator),
			allocator = allocator,
		)
	}
	if a_l == "untrust" || a_l == "hooks-untrust" || a_l == "revoke" {
		if err := core.revoke_folder_trust(cwd); err != "" {
			return fmt.aprintf("aether: hooks untrust failed: %s", err, allocator = allocator)
		}
		maybe_start_hooks(cwd, true)
		return fmt.aprintf(
			"aether: folder untrusted — project hooks gated\n%s\n%s",
			core.folder_trust_status_line(cwd, context.temp_allocator),
			hooks.status_text(hooks.get_registry(), context.temp_allocator),
			allocator = allocator,
		)
	}
	if a_l == "reload" {
		maybe_start_hooks(cwd, true)
		return fmt.aprintf(
			"aether: hooks reloaded\n%s\n%s",
			core.folder_trust_status_line(cwd, context.temp_allocator),
			hooks.status_text(hooks.get_registry(), context.temp_allocator),
			allocator = allocator,
		)
	}
	if a_l == "paths" || a_l == "path" {
		return hooks.format_hooks_paths_status(allocator)
	}
	// add <path> | remove <path>
	if strings.has_prefix(a_l, "add ") || a_l == "add" {
		rest := ""
		if strings.has_prefix(a_l, "add ") {
			rest = strings.trim_space(a[len("add "):])
		}
		if rest == "" {
			return strings.clone(
				"aether: usage: /hooks add <absolute path under ~/.grok>",
				allocator,
			)
		}
		if err := hooks.add_hooks_path(rest); err != "" {
			return fmt.aprintf("aether: hooks add failed: %s", err, allocator = allocator)
		}
		maybe_start_hooks(cwd, true)
		return fmt.aprintf(
			"aether: hooks path added (reloaded)\n%s",
			hooks.format_hooks_paths_status(context.temp_allocator),
			allocator = allocator,
		)
	}
	if strings.has_prefix(a_l, "remove ") ||
	   strings.has_prefix(a_l, "rm ") ||
	   a_l == "remove" ||
	   a_l == "rm" {
		rest := ""
		if strings.has_prefix(a_l, "remove ") {
			rest = strings.trim_space(a[len("remove "):])
		} else if strings.has_prefix(a_l, "rm ") {
			rest = strings.trim_space(a[len("rm "):])
		}
		if rest == "" {
			return strings.clone(
				"aether: usage: /hooks remove <path from hooks-paths>",
				allocator,
			)
		}
		if err := hooks.remove_hooks_path(rest); err != "" {
			return fmt.aprintf("aether: hooks remove failed: %s", err, allocator = allocator)
		}
		maybe_start_hooks(cwd, true)
		return fmt.aprintf(
			"aether: hooks path removed (reloaded)\n%s",
			hooks.format_hooks_paths_status(context.temp_allocator),
			allocator = allocator,
		)
	}
	// list / status / bare
	if a_l == "" || a_l == "status" || a_l == "list" || a_l == "show" || a_l == "info" {
		return fmt.aprintf(
			"%s\n%s",
			core.folder_trust_status_line(cwd, context.temp_allocator),
			hooks.status_text(hooks.get_registry(), context.temp_allocator),
			allocator = allocator,
		)
	}
	return fmt.aprintf(
		"aether: unknown /hooks arg %q (try /hooks help)",
		arg,
		allocator = allocator,
	)
}
