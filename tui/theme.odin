#+build linux, darwin, freebsd, openbsd, netbsd
// Package tui — SGR palettes for Line_Style / chrome bars (C2.1).
package tui

import "core:os"
import "core:strings"
import "aether:core"

// Theme holds SGR "on" sequences (reset is always \x1b[0m at call sites).
Theme :: struct {
	name:        string,
	user:        string,
	assistant:   string,
	tool:        string,
	dim:         string,
	code:        string,
	bold:        string,
	status:      string,
	bar_reverse: string,
	bar_dim:     string,
}

// truecolor preferred when COLORTERM advertises it.
wants_truecolor :: proc() -> bool {
	v := os.get_env("COLORTERM", context.temp_allocator)
	return strings.contains(strings.to_lower(v, context.temp_allocator), "truecolor") ||
		strings.contains(strings.to_lower(v, context.temp_allocator), "24bit")
}

// theme_for_name maps core canonical name → palette.
theme_for_name :: proc(name: string) -> Theme {
	n, _ := core.normalize_theme_name(name)
	tc := wants_truecolor()
	switch n {
	case "light":
		return Theme {
			name        = "light",
			user        = "\x1b[34m", // blue
			assistant   = "",
			tool        = "\x1b[35m", // magenta
			dim         = "\x1b[2m",
			code        = "\x1b[2m\x1b[34m",
			bold        = "\x1b[1m",
			status      = "\x1b[2m",
			bar_reverse = "\x1b[7m",
			bar_dim     = "\x1b[2m",
		}
	case "tokyonight":
		if tc {
			return Theme {
				name        = "tokyonight",
				user        = "\x1b[38;2;122;162;247m", // blue
				assistant   = "\x1b[38;2;192;202;245m",
				tool        = "\x1b[38;2;224;175;104m", // yellow
				dim         = "\x1b[38;2;86;95;137m",
				code        = "\x1b[38;2;158;206;106m",
				bold        = "\x1b[1m",
				status      = "\x1b[38;2;86;95;137m",
				bar_reverse = "\x1b[48;2;36;40;59m\x1b[38;2;192;202;245m",
				bar_dim     = "\x1b[38;2;86;95;137m",
			}
		}
		return Theme {
			name        = "tokyonight",
			user        = "\x1b[94m",
			assistant   = "\x1b[37m",
			tool        = "\x1b[93m",
			dim         = "\x1b[2m",
			code        = "\x1b[92m",
			bold        = "\x1b[1m",
			status      = "\x1b[2m",
			bar_reverse = "\x1b[7m",
			bar_dim     = "\x1b[2m",
		}
	case "rosepine":
		if tc {
			return Theme {
				name        = "rosepine",
				user        = "\x1b[38;2;196;167;231m", // iris
				assistant   = "\x1b[38;2;224;222;244m",
				tool        = "\x1b[38;2;246;193;119m",
				dim         = "\x1b[38;2;110;106;134m",
				code        = "\x1b[38;2;156;207;216m",
				bold        = "\x1b[1m",
				status      = "\x1b[38;2;110;106;134m",
				bar_reverse = "\x1b[48;2;42;39;63m\x1b[38;2;224;222;244m",
				bar_dim     = "\x1b[38;2;110;106;134m",
			}
		}
		return Theme {
			name        = "rosepine",
			user        = "\x1b[95m",
			assistant   = "",
			tool        = "\x1b[33m",
			dim         = "\x1b[2m",
			code        = "\x1b[96m",
			bold        = "\x1b[1m",
			status      = "\x1b[2m",
			bar_reverse = "\x1b[7m",
			bar_dim     = "\x1b[2m",
		}
	case "oscura":
		if tc {
			return Theme {
				name        = "oscura",
				user        = "\x1b[38;2;167;139;250m",
				assistant   = "\x1b[38;2;228;228;231m",
				tool        = "\x1b[38;2;251;191;36m",
				dim         = "\x1b[38;2;113;113;122m",
				code        = "\x1b[38;2;134;239;172m",
				bold        = "\x1b[1m",
				status      = "\x1b[38;2;113;113;122m",
				bar_reverse = "\x1b[48;2;24;24;27m\x1b[38;2;228;228;231m",
				bar_dim     = "\x1b[38;2;113;113;122m",
			}
		}
		return Theme {
			name        = "oscura",
			user        = "\x1b[35m",
			assistant   = "",
			tool        = "\x1b[33m",
			dim         = "\x1b[2m",
			code        = "\x1b[32m",
			bold        = "\x1b[1m",
			status      = "\x1b[2m",
			bar_reverse = "\x1b[7m",
			bar_dim     = "\x1b[2m",
		}
	}
	// dark / default (GrokNight-ish)
	return Theme {
		name        = "dark",
		user        = "\x1b[36m", // cyan
		assistant   = "",
		tool        = "\x1b[33m", // yellow
		dim         = "\x1b[2m",
		code        = "\x1b[2m\x1b[32m",
		bold        = "\x1b[1m",
		status      = "\x1b[2m",
		bar_reverse = "\x1b[7m",
		bar_dim     = "\x1b[2m",
	}
}

// active_theme resolves current core name (or monochrome).
active_theme :: proc() -> Theme {
	if core.ui_color_disabled() {
		return Theme {
			name = "nocolor",
		}
	}
	return theme_for_name(core.get_ui_theme_name())
}
