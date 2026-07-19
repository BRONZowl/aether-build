// Package agent — /aliases slash alias reference (B53).
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

	// pairs: canonical, aliases (space-separated)
	rows := [][2]string {
		{"/help", "/?"},
		{"/exit", "/quit /q"},
		{"/about", ""},
		{"/keys", "/bindings /shortcuts"},
		{"/tools", "/tool"},
		{"/soft-bash", "/bash-soft /softbash"},
		{"/permissions", "/permission /perm /perms"},
		{"/env", "/environ /environment"},
		{"/paths", "/path /where"},
		{"/features", "/feature /flags"},
		{"/status", ""},
		{"/config", "/settings /preferences /prefs"},
		{"/doctor", ""},
		{"/version", ""},
		{"/model", "/m"},
		{"/theme", "/t"},
		{"/vim-mode", "/vim"},
		{"/compact-mode", "/cm"},
		{"/timestamps", "/timestamp"},
		{"/multiline", "/ml"},
		{"/always-approve", "/yolo"},
		{"/auto", ""},
		{"/context", "/usage /cost"},
		{"/session", "/session-info"},
		{"/sessions", "/resume"},
		{"/rename", "/title"},
		{"/view-plan", "/show-plan /plan-view"},
		{"/todos", "/todo"},
		{"/undo-file", "/rewind-file"},
		{"/plan view", "alias of /view-plan"},
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
	for row in rows {
		can := row[0]
		als := row[1]
		if a != "" {
			cl := strings.to_lower(can, context.temp_allocator)
			al := strings.to_lower(als, context.temp_allocator)
			if !strings.contains(cl, a) && !strings.contains(al, a) {
				continue
			}
		}
		n += 1
		if als == "" {
			strings.write_string(&b, fmt.tprintf("  %-22s (none)\n", can))
		} else {
			strings.write_string(&b, fmt.tprintf("  %-22s %s\n", can, als))
		}
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
