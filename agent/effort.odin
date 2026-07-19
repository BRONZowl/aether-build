package agent

import "core:strings"

// Process-local reasoning effort for chat completions (Grok /effort parity).
// Empty = omit field from request body.
g_reasoning_effort: string

// set_reasoning_effort accepts low|medium|high|xhigh (case-insensitive).
// Empty or "off"/"default"/"none" clears. Returns false if invalid.
set_reasoning_effort :: proc(level: string) -> bool {
	a := strings.to_lower(strings.trim_space(level), context.temp_allocator)
	switch a {
	case "", "off", "default", "none", "clear":
		if g_reasoning_effort != "" {
			delete(g_reasoning_effort)
			g_reasoning_effort = ""
		}
		return true
	case "low", "medium", "med", "high", "xhigh", "extra-high", "extra_high":
		canon := a
		if a == "med" {
			canon = "medium"
		}
		if a == "extra-high" || a == "extra_high" {
			canon = "xhigh"
		}
		if g_reasoning_effort != "" {
			delete(g_reasoning_effort)
		}
		g_reasoning_effort = strings.clone(canon)
		return true
	case:
		return false
	}
}

reasoning_effort_current :: proc() -> string {
	return g_reasoning_effort
}

// apply_config_reasoning_effort seeds process effort from loaded Runtime_Config (B17).
// Invalid values are ignored (leave prior/empty). Empty cfg → clear.
apply_config_reasoning_effort :: proc(level: string) {
	_ = set_reasoning_effort(level if level != "" else "off")
}
