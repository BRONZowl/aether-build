// Package agent — /fork argument parsing (Grok-shaped flags).
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
package agent

import "core:strings"

// Fork_Worktree: worktree isolation choice for session fork.
Fork_Worktree :: enum {
	Ask, // TUI modal; REPL defaults to No
	Yes,
	No,
}

// parse_fork_args: leading --worktree / --no-worktree; rest is title/directive.
// Unknown flags begin free text (Grok-conservative).
parse_fork_args :: proc(arg: string) -> (wt: Fork_Worktree, rest: string, err: string) {
	wt = .Ask
	s := strings.trim_space(arg)
	saw_yes := false
	saw_no := false

	for s != "" {
		token: string
		after: string
		if sp := strings.index_byte(s, ' '); sp >= 0 {
			token = s[:sp]
			after = strings.trim_space(s[sp + 1:])
		} else {
			token = s
			after = ""
		}
		if token == "--worktree" {
			if saw_no {
				return .Ask, "", "--worktree and --no-worktree are mutually exclusive"
			}
			if saw_yes {
				return .Ask, "", "--worktree specified twice"
			}
			saw_yes = true
			wt = .Yes
			s = after
			continue
		}
		if token == "--no-worktree" {
			if saw_yes {
				return .Ask, "", "--worktree and --no-worktree are mutually exclusive"
			}
			if saw_no {
				return .Ask, "", "--no-worktree specified twice"
			}
			saw_no = true
			wt = .No
			s = after
			continue
		}
		if token == "--at" {
			return .Ask, "", "--at is not supported in this version"
		}
		// free text (including unknown --foo)
		rest = s
		break
	}
	return wt, rest, ""
}

// fork_title_from_rest: short title for session; empty → session_fork default.
fork_title_from_rest :: proc(rest: string) -> string {
	t := strings.trim_space(rest)
	if t == "" {
		return ""
	}
	// Use first line only; cap length for title field
	if nl := strings.index_byte(t, '\n'); nl >= 0 {
		t = t[:nl]
	}
	t = strings.trim_space(t)
	if len(t) > 80 {
		return t[:77] // caller may fmt with …
	}
	return t
}
