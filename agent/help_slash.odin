// Package agent — /help sectioned command list (B65).
// Optional filter matches section titles or command lines.
// Catalog: core.SLASH_CATALOG (menu order = Grok builtins; help groups by section).
package agent

import "core:fmt"
import "core:strings"
import "aether:core"

// Fixed help section order (independent of bare-/ catalog order).
HELP_SECTIONS := [?]string {
	"Discover",
	"Session",
	"Model & auth",
	"Permissions & plan",
	"Extensions",
	"Memory & context",
	"TUI & chrome",
	"Exit",
}

// handle_help_slash builds sectioned help; filter keeps matching sections/rows.
handle_help_slash :: proc(arg: string, allocator := context.allocator) -> string {
	a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
	if a == "help" || a == "?" {
		return strings.clone(
			"Usage: /help [filter]\n" +
			"List slash commands by section. Optional filter matches section titles or command text.\n" +
			"Examples: /help session · /help plan · /help mem",
			allocator,
		)
	}

	cat := core.SLASH_CATALOG[:]
	b := strings.builder_make(allocator)
	strings.write_string(&b, "## aether commands\n")
	if a == "" {
		strings.write_string(&b, fmt.tprintf("%s\n\n", core.version_string()))
	} else {
		strings.write_string(
			&b,
			fmt.tprintf("%s  (filter: %s)\n\n", core.version_string(), arg),
		)
	}

	// Group by fixed section titles so bare-/ Grok menu order can interleave sections.
	n_cmds := 0
	for sec_title in HELP_SECTIONS {
		sec_match :=
			a == "" ||
			strings.contains(strings.to_lower(sec_title, context.temp_allocator), a)

		matched_cmds: [dynamic]string
		for e in cat {
			if e.section != sec_title {
				continue
			}
			line := core.slash_help_line(e, context.temp_allocator)
			include := a == "" || sec_match
			if !include {
				blob := strings.concatenate(
					{e.primary, " ", e.help_left, " ", e.help_right},
					context.temp_allocator,
				)
				for al in e.aliases {
					blob = strings.concatenate({blob, " ", al}, context.temp_allocator)
				}
				include = strings.contains(strings.to_lower(blob, context.temp_allocator), a)
			}
			if include {
				append(&matched_cmds, line)
			}
		}
		if len(matched_cmds) > 0 {
			strings.write_string(&b, fmt.tprintf("### %s\n", sec_title))
			for c in matched_cmds {
				strings.write_string(&b, c)
				strings.write_string(&b, "\n")
				n_cmds += 1
			}
			strings.write_string(&b, "\n")
		}
		delete(matched_cmds)
	}

	// Any catalog rows with unknown section (defensive).
	if a == "" {
		known := false
		// skip — all entries use HELP_SECTIONS today
		_ = known
	}

	if n_cmds == 0 {
		strings.write_string(&b, fmt.tprintf("(no commands matching %q)\n", arg))
	} else {
		strings.write_string(
			&b,
			"Anything else is sent to the agent with tools.\n" +
			"tips: /about · /aliases · /keys · /tools · /permissions · /env · /paths\n",
		)
	}
	return strings.to_string(b)
}
