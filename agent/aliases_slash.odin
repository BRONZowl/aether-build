// Package agent — /aliases slash alias reference (B53).
// Rows derived from core.SLASH_CATALOG (same source as /help + menu).

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:strings"
import "aether:core"

// handle_aliases_slash lists known slash aliases (canonical → others).
handle_aliases_slash :: proc(arg: string, allocator := context.allocator) -> string {
	a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
	if a == "help" || a == "?" {
		return strings.clone(
			"Usage: /aliases [filter]\n" +
			"List slash command aliases. Optional filter matches either side.",
			allocator,
		)
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, "## aether slash aliases\n")
	strings.write_string(
		&b,
		fmt.tprintf("%s\n\n", core.version_string()),
	)
	strings.write_string(&b, "  canonical              aliases\n")
	strings.write_string(&b, "  ---------------------- ------------------------\n")
	n := 0
	for e in core.SLASH_CATALOG {
		can := e.primary
		// space-join aliases
		als := ""
		if len(e.aliases) > 0 {
			als = strings.join(e.aliases, " ", context.temp_allocator)
		}
		if a != "" {
			cl := strings.to_lower(can, context.temp_allocator)
			al := strings.to_lower(als, context.temp_allocator)
			if !strings.contains(cl, a) && !strings.contains(al, a) {
				continue
			}
		}
		// Always list rows that have aliases; also list filtered primaries with none
		// only when filter matches primary (discoverability).
		if als == "" {
			if a == "" {
				continue // unfiltered: only show commands that have aliases
			}
			n += 1
			strings.write_string(&b, fmt.tprintf("  %-22s (none)\n", can))
			continue
		}
		n += 1
		strings.write_string(&b, fmt.tprintf("  %-22s %s\n", can, als))
	}
	if n == 0 {
		strings.write_string(&b, fmt.tprintf("(no aliases matching %q)\n", arg))
	} else {
		strings.write_string(
			&b,
			fmt.tprintf("\n%d row(s). Full command list: /help\n", n),
		)
	}
	return strings.to_string(b)
}
