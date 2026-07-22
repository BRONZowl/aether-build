// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
// Package tui — SGR palettes for Line_Style / chrome bars (C2.1).
// Mode accents (plan gold, system blue, prompt borders) mirror Grok Build
// xai-grok-pager-render theme slots: accent_plan, accent_system, prompt_border*.
package tui

import "core:os"
import "core:strings"
import "aether:core"

// Theme holds SGR "on" sequences (reset is always \x1b[0m at call sites).
Theme :: struct {
	name:                 string,
	user:                 string, // accent_user — chevron / ask
	assistant:            string,
	tool:                 string,
	dim:                  string,
	code:                 string,
	bold:                 string,
	status:               string,
	bar_reverse:          string,
	bar_dim:              string,
	// Grok-aligned mode / chrome accents
	accent_plan:          string, // golden plan mode
	accent_system:        string, // auto mode flag (blue)
	prompt_border:        string, // unfocused box chrome
	prompt_border_active: string, // focused box chrome (non-plan)
}

// truecolor preferred when COLORTERM advertises it.
wants_truecolor :: proc() -> bool {
	v := os.get_env("COLORTERM", context.temp_allocator)
	return strings.contains(strings.to_lower(v, context.temp_allocator), "truecolor") ||
		strings.contains(strings.to_lower(v, context.temp_allocator), "24bit")
}

// theme_for_name maps core canonical name → palette (Grok RGB where known).
theme_for_name :: proc(name: string) -> Theme {
	n, _ := core.normalize_theme_name(name)
	tc := wants_truecolor()
	switch n {
	case "light":
		// GrokDay-ish: deep golden plan, blue user
		return Theme {
			name                 = "light",
			user                 = "\x1b[34m",
			assistant            = "",
			tool                 = "\x1b[33m",
			dim                  = "\x1b[2m",
			code                 = "\x1b[2m\x1b[34m",
			bold                 = "\x1b[1m",
			status               = "\x1b[2m",
			bar_reverse          = "\x1b[7m",
			bar_dim              = "\x1b[2m",
			accent_plan          = "\x1b[38;2;168;120;10m", // #A8780A
			accent_system        = "\x1b[34m",
			prompt_border        = "\x1b[2m",
			prompt_border_active = "\x1b[90m",
		}
	case "tokyonight":
		if tc {
			return Theme {
				name                 = "tokyonight",
				user                 = "\x1b[38;2;122;162;247m", // BLUE
				assistant            = "\x1b[38;2;192;202;245m",
				tool                 = "\x1b[38;2;224;175;104m",
				dim                  = "\x1b[38;2;86;95;137m",
				code                 = "\x1b[38;2;158;206;106m",
				bold                 = "\x1b[1m",
				status               = "\x1b[38;2;86;95;137m",
				bar_reverse          = "\x1b[48;2;36;40;59m\x1b[38;2;192;202;245m",
				bar_dim              = "\x1b[38;2;86;95;137m",
				accent_plan          = "\x1b[38;2;230;180;50m", // #E6B432 golden
				accent_system        = "\x1b[38;2;122;162;247m", // same BLUE as Grok TN
				prompt_border        = "\x1b[38;2;60;75;120m", // #323E64
				prompt_border_active = "\x1b[38;2;75;92;140m", // #4B5C8C
			}
		}
		return Theme {
			name                 = "tokyonight",
			user                 = "\x1b[94m",
			assistant            = "\x1b[37m",
			tool                 = "\x1b[93m",
			dim                  = "\x1b[2m",
			code                 = "\x1b[92m",
			bold                 = "\x1b[1m",
			status               = "\x1b[2m",
			bar_reverse          = "\x1b[7m",
			bar_dim              = "\x1b[2m",
			accent_plan          = "\x1b[33m",
			accent_system        = "\x1b[94m",
			prompt_border        = "\x1b[2m",
			prompt_border_active = "\x1b[90m",
		}
	case "rosepine":
		if tc {
			return Theme {
				name                 = "rosepine",
				user                 = "\x1b[38;2;196;167;231m",
				assistant            = "\x1b[38;2;224;222;244m",
				tool                 = "\x1b[38;2;246;193;119m", // GOLD
				dim                  = "\x1b[38;2;110;106;134m",
				code                 = "\x1b[38;2;156;207;216m",
				bold                 = "\x1b[1m",
				status               = "\x1b[38;2;110;106;134m",
				bar_reverse          = "\x1b[48;2;42;39;63m\x1b[38;2;224;222;244m",
				bar_dim              = "\x1b[38;2;110;106;134m",
				accent_plan          = "\x1b[38;2;246;193;119m", // GOLD
				accent_system        = "\x1b[38;2;156;207;216m",
				prompt_border        = "\x1b[38;2;110;106;134m",
				prompt_border_active = "\x1b[38;2;144;140;170m",
			}
		}
		return Theme {
			name                 = "rosepine",
			user                 = "\x1b[95m",
			assistant            = "",
			tool                 = "\x1b[33m",
			dim                  = "\x1b[2m",
			code                 = "\x1b[96m",
			bold                 = "\x1b[1m",
			status               = "\x1b[2m",
			bar_reverse          = "\x1b[7m",
			bar_dim              = "\x1b[2m",
			accent_plan          = "\x1b[33m",
			accent_system        = "\x1b[96m",
			prompt_border        = "\x1b[2m",
			prompt_border_active = "\x1b[90m",
		}
	case "oscura":
		if tc {
			return Theme {
				name                 = "oscura",
				user                 = "\x1b[38;2;167;139;250m",
				assistant            = "\x1b[38;2;228;228;231m",
				tool                 = "\x1b[38;2;251;191;36m",
				dim                  = "\x1b[38;2;113;113;122m",
				code                 = "\x1b[38;2;134;239;172m",
				bold                 = "\x1b[1m",
				status               = "\x1b[38;2;113;113;122m",
				bar_reverse          = "\x1b[48;2;24;24;27m\x1b[38;2;228;228;231m",
				bar_dim              = "\x1b[38;2;113;113;122m",
				accent_plan          = "\x1b[38;2;235;217;110m", // #EBD96E GOLD
				accent_system        = "\x1b[38;2;167;139;250m",
				prompt_border        = "\x1b[38;2;63;63;70m",
				prompt_border_active = "\x1b[38;2;113;113;122m",
			}
		}
		return Theme {
			name                 = "oscura",
			user                 = "\x1b[35m",
			assistant            = "",
			tool                 = "\x1b[33m",
			dim                  = "\x1b[2m",
			code                 = "\x1b[32m",
			bold                 = "\x1b[1m",
			status               = "\x1b[2m",
			bar_reverse          = "\x1b[7m",
			bar_dim              = "\x1b[2m",
			accent_plan          = "\x1b[33m",
			accent_system        = "\x1b[35m",
			prompt_border        = "\x1b[2m",
			prompt_border_active = "\x1b[90m",
		}
	}
	// dark / default — GrokNight-aligned
	if tc {
		return Theme {
			name                 = "dark",
			user                 = "\x1b[38;2;225;225;225m", // FG_DARK-ish
			assistant            = "",
			tool                 = "\x1b[38;2;255;219;141m",
			dim                  = "\x1b[38;2;120;120;128m",
			code                 = "\x1b[38;2;134;239;172m",
			bold                 = "\x1b[1m",
			status               = "\x1b[38;2;120;120;128m",
			bar_reverse          = "\x1b[7m",
			bar_dim              = "\x1b[38;2;120;120;128m",
			accent_plan          = "\x1b[38;2;255;219;141m", // #FFDB8D golden
			accent_system        = "\x1b[38;2;100;149;237m", // BLUE-ish
			prompt_border        = "\x1b[38;2;50;50;55m", // #323237
			prompt_border_active = "\x1b[38;2;80;80;88m", // #505058
		}
	}
	return Theme {
		name                 = "dark",
		user                 = "\x1b[37m",
		assistant            = "",
		tool                 = "\x1b[33m",
		dim                  = "\x1b[2m",
		code                 = "\x1b[2m\x1b[32m",
		bold                 = "\x1b[1m",
		status               = "\x1b[2m",
		bar_reverse          = "\x1b[7m",
		bar_dim              = "\x1b[2m",
		accent_plan          = "\x1b[33m",
		accent_system        = "\x1b[94m",
		prompt_border        = "\x1b[2m",
		prompt_border_active = "\x1b[90m",
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
