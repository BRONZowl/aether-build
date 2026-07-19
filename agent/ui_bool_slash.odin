package agent

import "core:fmt"
import "core:strings"
import "aether:core"

// slash_ui_bool handles shared on|off|toggle|status for UI prefs
// (/vim-mode, /timestamps, /compact-mode).
slash_ui_bool :: proc(
	arg: string,
	label: string,
	config_key: string,
	get: proc() -> bool,
	set: proc(on: bool),
	toggle: proc() -> bool,
	status_hint: string,
	out: Slash_Writer,
) {
	a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
	switch a {
	case "", "toggle", "t":
		on := toggle()
		_ = core.persist_ui_bool(config_key, on)
		emit_line(out, fmt.tprintf("aether: %s %s", label, "on" if on else "off"))
	case "on", "true", "1", "yes":
		set(true)
		_ = core.persist_ui_bool(config_key, true)
		emit_line(out, fmt.tprintf("aether: %s on", label))
	case "off", "false", "0", "no":
		set(false)
		_ = core.persist_ui_bool(config_key, false)
		emit_line(out, fmt.tprintf("aether: %s off", label))
	case "status", "show", "?":
		state := "on" if get() else "off"
		if status_hint != "" {
			emit_line(out, fmt.tprintf("aether: %s %s (%s)", label, state, status_hint))
		} else {
			emit_line(out, fmt.tprintf("aether: %s %s", label, state))
		}
	case:
		emit_line(out, fmt.tprintf("aether: usage: /%s [on|off|status|toggle]", label))
	}
}
