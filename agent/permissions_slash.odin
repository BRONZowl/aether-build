// Package agent — /permissions mode dashboard (B61).
// Explains permission modes and how to change them (discoverability).

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:strings"
import "aether:core"

// handle_permissions_slash: status/help for permission modes.
// Does not change mode (use /auto, /always-approve, Shift+Tab in TUI).
handle_permissions_slash :: proc(
	arg: string,
	perm: core.Permission_Mode,
	allocator := context.allocator,
) -> string {
	a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
	if a == "help" || a == "?" {
		return strings.clone(
			"Usage: /permissions [status|help]\n" +
			"Show permission mode dashboard (ask / auto / always-approve / read-only).\n" +
			"Change mode: /auto, /always-approve (/yolo), Shift+Tab in TUI, or [ui] permission_mode.",
			allocator,
		)
	}

	cur := core.permission_mode_string(perm)
	b := strings.builder_make(allocator)
	strings.write_string(&b, "## aether permissions\n")
	strings.write_string(&b, fmt.tprintf("current:   %s\n\n", cur))

	strings.write_string(&b, "### Modes\n")
	mark_ask := " " if cur != "ask" else "*"
	mark_auto := " " if cur != "auto" else "*"
	mark_yolo := " " if cur != "always-approve" else "*"
	mark_ro := " " if cur != "read-only" else "*"
	strings.write_string(
		&b,
		fmt.tprintf(
			"  %s ask             prompt for tool calls that need approval\n",
			mark_ask,
		),
	)
	strings.write_string(
		&b,
		fmt.tprintf(
			"  %s auto            auto-allow file edits; ask for shell/MCP/media\n",
			mark_auto,
		),
	)
	strings.write_string(
		&b,
		fmt.tprintf(
			"  %s always-approve  auto-allow tools (soft-bash hard-deny still applies)\n",
			mark_yolo,
		),
	)
	strings.write_string(
		&b,
		fmt.tprintf(
			"  %s read-only       deny writes; soft-bash inspect shell still auto-allows\n",
			mark_ro,
		),
	)

	strings.write_string(&b, "\n### How to change\n")
	strings.write_string(&b, "  TUI          Shift+Tab cycles ask → auto → always-approve → read-only\n")
	strings.write_string(&b, "  /auto on     accept file edits; ask for shell\n")
	strings.write_string(&b, "  /yolo on     always-approve (alias /always-approve)\n")
	strings.write_string(&b, "  /yolo off    back to ask\n")
	strings.write_string(&b, "  /always-approve read-only|auto|on|off|status\n")
	strings.write_string(&b, "  config       [ui] permission_mode in ~/.grok/config.toml (persists on cycle)\n")
	strings.write_string(&b, "  CLI          --permission-mode / --yolo / --read-only\n")

	strings.write_string(&b, "\n### Related safety\n")
	soft := "on" if core.bash_soft_enabled() else "off"
	strings.write_string(
		&b,
		fmt.tprintf(
			"  soft-bash:  %s  (hard-deny + inspect auto-allow; /soft-bash)\n",
			soft,
		),
	)
	strings.write_string(&b, "  plan mode:  blocks non-markdown edits while active (/plan)\n")
	strings.write_string(
		&b,
		"\ntips: /status · /soft-bash · /config · /auto · /yolo · /help\n",
	)
	return strings.to_string(b)
}
