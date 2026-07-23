// Package agent — /status and /version slash (B21 product dashboard).

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:strings"
import "aether:core"
import "aether:hooks"
import "aether:mcp"
import "aether:skills"
import "aether:tools"

// handle_version_slash: short version banner (CLI-aligned).
handle_version_slash :: proc(allocator := context.allocator) -> string {
	return fmt.aprintf(
		"%s\nproxy-client: %s",
		core.version_string(),
		core.PROXY_CLIENT_VERSION,
		allocator = allocator,
	)
}

// handle_status_slash: one-screen product status (auth, model, session, tools).
// Does not print secrets (no API keys / tokens).
handle_status_slash :: proc(
	sess: ^Session,
	model: string,
	perm: core.Permission_Mode,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, fmt.tprintf("## aether status\n"))
	strings.write_string(&b, fmt.tprintf("version:   %s\n", core.version_string()))
	strings.write_string(&b, fmt.tprintf("proxy-cli: %s\n", core.PROXY_CLIENT_VERSION))

	// Auth (best-effort, no secrets)
	creds, aerr := resolve_credentials()
	if aerr != "" {
		strings.write_string(&b, fmt.tprintf("auth:      not signed in (%s)\n", aerr))
	} else {
		who := creds.email if creds.email != "" else (creds.user_id if creds.user_id != "" else "api-key")
		kind := "session" if creds.kind == .Session else "api-key"
		strings.write_string(&b, fmt.tprintf("auth:      %s as %s\n", kind, who))
		if host := host_of(creds.base_url); host != "" {
			strings.write_string(&b, fmt.tprintf("api host:  %s\n", host))
		}
		destroy_credentials(&creds)
	}

	m := model
	if sess != nil && sess.model != "" {
		m = sess.model
	}
	if m == "" {
		m = core.DEFAULT_MODEL
	}
	strings.write_string(&b, fmt.tprintf("model:     %s\n", m))
	eff := reasoning_effort_current()
	strings.write_string(
		&b,
		fmt.tprintf("effort:    %s\n", eff if eff != "" else "(default/off)"),
	)
	strings.write_string(&b, fmt.tprintf("perm:      %s\n", core.permission_mode_string(perm)))

	if sess != nil {
		strings.write_string(&b, fmt.tprintf("session:   %s\n", sess.id if sess.id != "" else "(none)"))
		title := sess.title if sess.title != "" else "(untitled)"
		strings.write_string(&b, fmt.tprintf("title:     %s\n", title))
		strings.write_string(&b, fmt.tprintf("cwd:       %s\n", sess.cwd if sess.cwd != "" else "."))
		strings.write_string(&b, fmt.tprintf("messages:  %d\n", len(sess.msgs)))
		strings.write_string(&b, fmt.tprintf("autosave:  %v\n", sess.auto_save))
		// context rough
		chars := estimate_message_chars(sess.msgs[:])
		toks := estimate_tokens(chars)
		window := context_window_for_model(sess.model)
		pct := context_usage_pct(toks, window)
		strings.write_string(
			&b,
			fmt.tprintf("context:   ~%d/%d tokens (%d%%)\n", toks, window, pct),
		)
		strings.write_string(
			&b,
			fmt.tprintf("plan:      %s\n", plan_state_to_string(plan_mode_state())),
		)
	} else {
		strings.write_string(&b, "session:   (none)\n")
	}

	// Feature flags / soft systems
	mem := "on" if tools.memory_enabled() else "off"
	strings.write_string(&b, fmt.tprintf("memory:    %s\n", mem))
	bash_soft := "on" if core.bash_soft_enabled() else "off"
	strings.write_string(&b, fmt.tprintf("bash-soft: %s\n", bash_soft))
	notify := "on" if desktop_notify_enabled() else "off"
	turn_n := "on" if turn_notify_enabled() else "off"
	strings.write_string(&b, fmt.tprintf("notify:    desktop=%s turns=%s\n", notify, turn_n))

	// Hooks / MCP / skills counts
	if hooks.hooks_enabled() {
		r := hooks.get_registry()
		n := 0 if r == nil else len(r.specs)
		strings.write_string(&b, fmt.tprintf("hooks:     %d loaded\n", n))
	} else {
		strings.write_string(&b, "hooks:     disabled\n")
	}
	mreg := mcp.get_registry()
	if mreg != nil && len(mreg.tools) > 0 {
		strings.write_string(&b, fmt.tprintf("mcp tools: %d\n", len(mreg.tools)))
	} else {
		strings.write_string(&b, "mcp tools: 0 (or not connected)\n")
	}
	sreg := skills.get_registry()
	if sreg != nil && len(sreg.skills) > 0 {
		strings.write_string(&b, fmt.tprintf("skills:    %d\n", len(sreg.skills)))
	} else {
		strings.write_string(&b, "skills:    0\n")
	}

	strings.write_string(
		&b,
		"tips:      /about · /keys · /tools · /permissions · /env · /paths · /features · /soft-bash · /doctor · /config · /help\n",
	)
	return strings.to_string(b)
}
