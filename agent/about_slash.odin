// Package agent — /about product blurb (B50).

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:strings"
import "aether:core"

// handle_about_slash: short product identity + discoverability tips.
handle_about_slash :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	// V1: brand art above blurb when enabled
	if core.brand_art_enabled() {
		art := core.brand_render_for_about(context.temp_allocator)
		if art != "" {
			strings.write_string(&b, art)
			strings.write_string(&b, "\n\n")
		}
	}
	strings.write_string(&b, "## aether\n")
	strings.write_string(
		&b,
		fmt.tprintf("%s\n", core.version_string()),
	)
	strings.write_string(
		&b,
		fmt.tprintf("proxy-client: %s\n\n", core.PROXY_CLIENT_VERSION),
	)
	strings.write_string(
		&b,
		"Odin agent + TUI for xAI Grok — headless, REPL, and fullscreen chat.\n" +
		"Dual-product monorepo peer to Rust Grok Build; shared ~/.grok user data.\n\n",
	)
	strings.write_string(&b, "### Discover\n")
	strings.write_string(&b, "  /help       sectioned commands (/help plan filters)\n")
	strings.write_string(&b, "  /aliases    slash command aliases\n")
	strings.write_string(&b, "  /keys       TUI keyboard shortcuts\n")
	strings.write_string(&b, "  /tools      model tools for this process\n")
	strings.write_string(&b, "  /status     auth / model / session snapshot\n")
	strings.write_string(&b, "  /settings   effective settings + env overrides (/config)\n")
	strings.write_string(&b, "  /doctor     health check (deps, paths, soft systems)\n")
	strings.write_string(&b, "  /soft-bash  shell hard-deny + inspect auto-allow\n")
	strings.write_string(&b, "  /permissions  ask/auto/yolo/read-only modes (/perm)\n")
	strings.write_string(&b, "  /env         AETHER_* kill-switches + product env\n")
	strings.write_string(&b, "  /paths      config / sessions / memory locations\n")
	strings.write_string(&b, "  /features   process feature flags on/off\n")
	strings.write_string(&b, "  /mcps       MCP servers (/mcp)\n")
	strings.write_string(&b, "  /context    estimated context window usage\n\n")
	strings.write_string(
		&b,
		"Auth: XAI_API_KEY or ~/.grok/auth.json  ·  Config: ~/.grok/config.toml\n" +
		"Opt out soft-bash: AETHER_NO_BASH_SOFT=1 or /soft-bash off\n",
	)
	return strings.to_string(b)
}
