// Package core — data-driven soft-bash CLI readonly classifier (P4).
// Prefer Cli_Readonly_Spec + bash_cli_is_readonly over hand-rolled peel loops.
//
// Still custom (do not force into the table without parity tests):
//   pacman short-flag clusters, rake inspect flags, brew, poetry export/config,
//   terraform fmt/plan/state, terragrunt/helmfile custom, python -m, make dry-run,
//   curl/wget/httpie method, redis/psql/mysql, git porcelain, aws/gcloud/az,
//   gh api, nix, ffmpeg, dive export walk, checkov/tfsec flag walks, ctr tree.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:strings"

// Cli_Nested: when top-level sub matches, check next token against allow.
// require_sub: if true, empty next is NOT readonly (e.g. consul kv needs get|export).
Cli_Nested :: struct {
	sub:         string,
	allow:       []string,
	require_sub: bool,
}

// Cli_Readonly_Spec describes a program's inspect-only surface.
Cli_Readonly_Spec :: struct {
	value_flags:   []string, // flags that consume the next token
	allow_subs:    []string, // allowed subcommands (if non-empty, allowlist mode)
	deny_subs:     []string, // hard-deny subs (checked first)
	nested:        []Cli_Nested, // e.g. config → get|list
	// empty_args_ok: bare `prog` with no args is readonly (default false = fail closed)
	empty_args_ok: bool,
	// peel_fail_ok: when peel finds no subcommand after flags → true (cargo-like) or false (npm)
	peel_fail_ok:  bool,
}

// bash_cli_nested_match evaluates a nested subcommand rule.
bash_cli_nested_match :: proc(rest: string, n: Cli_Nested) -> bool {
	if n.require_sub {
		next, _ := first_shell_token(rest)
		tok := strings.to_lower(next, context.temp_allocator)
		if tok == "" {
			return false
		}
		if tok == "help" || tok == "--help" || tok == "-h" {
			return true
		}
		return bash_token_in(tok, n.allow)
	}
	return bash_nested_allow(rest, n.allow)
}

// bash_cli_is_readonly: shared walker for Cli_Readonly_Spec.
bash_cli_is_readonly :: proc(args: string, spec: Cli_Readonly_Spec) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return spec.empty_args_ok
	}
	if bash_is_help_or_version(a) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(a, spec.value_flags)
	if !ok {
		return spec.peel_fail_ok
	}
	for n in spec.nested {
		if sub == n.sub {
			return bash_cli_nested_match(rest, n)
		}
	}
	if len(spec.deny_subs) > 0 && bash_token_in(sub, spec.deny_subs) {
		return false
	}
	if len(spec.allow_subs) > 0 {
		return bash_token_in(sub, spec.allow_subs)
	}
	if len(spec.deny_subs) > 0 {
		return true
	}
	return false
}
