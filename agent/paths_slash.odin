// Package agent — /paths product path dashboard (B63).
// Shows where aether reads/writes user data; marks exists (Y/·).

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "aether:core"
import "aether:tools"

Paths_Row :: struct {
	label: string,
	path:  string,
}

// handle_paths_slash: catalog of product filesystem locations.
// Optional filter on label or path. Never prints secret file contents.
handle_paths_slash :: proc(
	arg: string,
	sess: ^Session,
	allocator := context.allocator,
) -> string {
	a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
	if a == "help" || a == "?" {
		return strings.clone(
			"Usage: /paths [filter|help]\n" +
			"Show product data paths (config, sessions, memory, auth, history, …).\n" +
			"  Y = path exists on disk · = missing (not necessarily an error).\n" +
			"See also: /config · /env · /doctor · /session.",
			allocator,
		)
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, "## aether paths\n")
	strings.write_string(&b, fmt.tprintf("%s\n\n", core.version_string()))
	strings.write_string(&b, "  ok  label              path\n")
	strings.write_string(&b, "  --  -----------------  --------------------------------\n")

	rows: [dynamic]Paths_Row
	defer delete(rows)

	gh := core.grok_home(context.temp_allocator)
	append(&rows, Paths_Row{"GROK_HOME", gh})
	append(&rows, Paths_Row{"user config", core.user_config_toml_path(context.temp_allocator)})
	append(&rows, Paths_Row{"auth.json", core.auth_json_path(context.temp_allocator)})
	append(&rows, Paths_Row{"sessions", core.aether_sessions_dir("", context.temp_allocator)})
	append(&rows, Paths_Row{"memory", tools.memory_root(context.temp_allocator)})
	append(&rows, Paths_Row{"prompt history", core.prompt_history_path(context.temp_allocator)})

	hp, _ := filepath.join({gh, "hooks-paths"}, context.temp_allocator)
	append(&rows, Paths_Row{"hooks-paths", hp})

	aether_dir, _ := filepath.join({gh, "aether"}, context.temp_allocator)
	append(&rows, Paths_Row{"aether data", aether_dir})

	term_dir, _ := filepath.join({gh, "aether", "terminal"}, context.temp_allocator)
	append(&rows, Paths_Row{"terminal logs", term_dir})

	mem := tools.memory_root(context.temp_allocator)
	mem_md, _ := filepath.join({mem, "MEMORY.md"}, context.temp_allocator)
	append(&rows, Paths_Row{"MEMORY.md", mem_md})

	cwd := "."
	if sess != nil && sess.cwd != "" {
		cwd = sess.cwd
	}
	abs := core.abs_cwd(cwd, context.temp_allocator)
	append(&rows, Paths_Row{"cwd", abs})
	proj, _ := filepath.join({abs, "aether.toml"}, context.temp_allocator)
	append(&rows, Paths_Row{"project aether.toml", proj})
	lsp, _ := filepath.join({abs, "lsp.json"}, context.temp_allocator)
	append(&rows, Paths_Row{"project lsp.json", lsp})
	plan, _ := filepath.join({abs, ".grok", "plan.md"}, context.temp_allocator)
	append(&rows, Paths_Row{".grok/plan.md", plan})
	gproj, _ := filepath.join({abs, ".grok"}, context.temp_allocator)
	append(&rows, Paths_Row{"project .grok/", gproj})

	if sess != nil && sess.id != "" {
		sdir := core.aether_sessions_dir("", context.temp_allocator)
		sp, _ := filepath.join({sdir, fmt.tprintf("%s.json", sess.id)}, context.temp_allocator)
		append(&rows, Paths_Row{"session file", sp})
	}

	n := 0
	n_ok := 0
	for row in rows {
		if a != "" {
			ll := strings.to_lower(row.label, context.temp_allocator)
			pl := strings.to_lower(row.path, context.temp_allocator)
			if !strings.contains(ll, a) && !strings.contains(pl, a) {
				continue
			}
		}
		n += 1
		ex := os.exists(row.path)
		mark := "·"
		if ex {
			mark = "Y"
			n_ok += 1
		}
		strings.write_string(
			&b,
			fmt.tprintf("  %s   %-18s  %s\n", mark, row.label, row.path),
		)
	}
	if n == 0 {
		strings.write_string(&b, fmt.tprintf("(no paths matching %q)\n", arg))
	} else {
		strings.write_string(
			&b,
			fmt.tprintf(
				"\n%d path(s), %d exist.  tips: /config · /env · /doctor · /session · /help\n",
				n,
				n_ok,
			),
		)
	}
	return strings.to_string(b)
}
