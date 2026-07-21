// Soft bash readonly helpers — OS package managers + language package tools (flatpak..gem).
// Same package core — symbols used by bash_program_is_readonly.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:strings"

// B60: flatpak inspect (list/info/search/remotes; not install/update/run).
FLATPAK_VALUE_FLAGS := [?]string{"--columns", "--arch", "--installation"}
FLATPAK_ALLOW := [?]string {
	"list", "info", "search", "remote-list", "remotes", "remote-ls", "remote-info",
	"history", "ps", "permission-show", "permission-list", "document-list",
	"document-info", "help", "--version",
}
FLATPAK_DENY := [?]string {
	"install", "uninstall", "update", "upgrade", "run", "override", "make-current",
	"enter", "permission-set", "permission-reset", "permission-remove", "repair",
	"create-usb", "build", "build-export", "build-bundle", "build-import-bundle",
	"build-sign", "build-update-repo", "build-commit-from", "repo",
	"document-export", "document-unexport", "kill", "spawn",
	"remote-add", "remote-delete", "remote-modify", "mask", "unmask",
}
FLATPAK_CONFIG_ALLOW := [?]string{"--list", "get", "list"}
FLATPAK_NESTED := [?]Cli_Nested{{sub = "config", allow = FLATPAK_CONFIG_ALLOW[:]}}
FLATPAK_READONLY_SPEC := Cli_Readonly_Spec {
	value_flags   = FLATPAK_VALUE_FLAGS[:],
	allow_subs    = FLATPAK_ALLOW[:],
	deny_subs     = FLATPAK_DENY[:],
	nested        = FLATPAK_NESTED[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_flatpak_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, FLATPAK_READONLY_SPEC)
}

// B60: snap inspect (list/info/find; not install/remove/refresh).
SNAP_ALLOW := [?]string {
	"list", "info", "find", "search", "version", "help", "known", "connections",
	"interface", "interfaces", "model", "changes", "tasks", "warnings", "get",
	"services", "logs", "whoami", "ok",
}
SNAP_DENY := [?]string {
	"install", "remove", "refresh", "try", "download", "pack", "start", "stop",
	"restart", "enable", "disable", "set", "unset", "connect", "disconnect",
	"alias", "unalias", "prefer", "switch", "create-cohort", "ack", "sign",
	"login", "logout", "buy", "abort", "watch", "wait", "run", "routine",
	"prepare-image", "remodel", "reboot", "recovery", "debug",
}
SNAP_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = SNAP_ALLOW[:],
	deny_subs     = SNAP_DENY[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_snap_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, SNAP_READONLY_SPEC)
}

// B60: Alpine apk inspect (info/search/list/version; not add/del/upgrade).
APK_ALLOW := [?]string {
	"info", "search", "list", "version", "policy", "stats", "audit", "verify", "help",
}
APK_DENY := [?]string {
	"add", "del", "delete", "fix", "upgrade", "update", "fetch", "manifest",
	"dot", "cache", "index",
}
APK_VALUE_FLAGS := [?]string{"--repository", "-X", "--root", "--keys-dir"}
APK_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = APK_ALLOW[:],
	deny_subs     = APK_DENY[:],
	value_flags   = APK_VALUE_FLAGS[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_apk_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, APK_READONLY_SPEC)
}

// B59: apt / apt-get inspect (list/search/show/policy; not install/update/upgrade).
APT_ALLOW := [?]string {
	"list", "search", "show", "showsrc", "policy", "depends", "rdepends",
	"changelog", "check", "help", "moo",
}
APT_DENY := [?]string {
	"install", "remove", "purge", "update", "upgrade", "full-upgrade",
	"dist-upgrade", "autoremove", "autopurge", "clean", "autoclean",
	"source", "build-dep", "download", "reinstall", "mark", "hold", "unhold",
}
APT_VALUE_FLAGS := [?]string{"-o", "--option"}
APT_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = APT_ALLOW[:],
	deny_subs     = APT_DENY[:],
	value_flags   = APT_VALUE_FLAGS[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_apt_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, APT_READONLY_SPEC)
}

// B59: apt-cache is read-only package metadata (no install path).
APT_CACHE_ALLOW := [?]string {
	"search", "show", "showpkg", "showsrc", "policy", "depends", "rdepends",
	"pkgnames", "dotty", "xvcg", "unmet", "dump", "dumpavail", "stats",
	"madison", "help",
}
APT_CACHE_DENY := [?]string{"gencaches"}
APT_CACHE_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = APT_CACHE_ALLOW[:],
	deny_subs     = APT_CACHE_DENY[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_apt_cache_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, APT_CACHE_READONLY_SPEC)
}

// B59: dnf / yum inspect (list/info/search/repolist; not install/remove/upgrade).
DNF_VALUE_FLAGS := [?]string{"--enablerepo", "--disablerepo", "--repoid", "--setopt"}
DNF_ALLOW := [?]string {
	"list", "info", "search", "repolist", "repoinfo", "check-update", "check-upgrade",
	"provides", "whatprovides", "repoquery", "history", "help", "check", "deplist",
	"changelog", "leaves",
}
DNF_DENY := [?]string {
	"install", "remove", "erase", "upgrade", "update", "downgrade", "reinstall",
	"distro-sync", "makecache", "clean", "autoremove", "groupinstall", "groupremove", "mark",
}
DNF_MODULE_ALLOW := [?]string{"list", "info", "provides"}
DNF_GROUP_ALLOW := [?]string{"list", "info", "summary"}
DNF_NESTED := [?]Cli_Nested {
	{sub = "module", allow = DNF_MODULE_ALLOW[:]},
	{sub = "group", allow = DNF_GROUP_ALLOW[:]},
}
DNF_READONLY_SPEC := Cli_Readonly_Spec {
	value_flags   = DNF_VALUE_FLAGS[:],
	allow_subs    = DNF_ALLOW[:],
	deny_subs     = DNF_DENY[:],
	nested        = DNF_NESTED[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_dnf_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, DNF_READONLY_SPEC)
}

// B59: pacman query/search only (-Q/-S query forms; not -S install / -R / -Syu).
PACMAN_HELP := [?]string{"--version", "-V", "--help", "-h", "help"}
PACMAN_QUERY_LONG := [?]string{"--query", "--files", "--deptest"}
PACMAN_MUTATE_LONG := [?]string{"--remove", "--upgrade", "--database"}
// Short-flag ops: uppercase primary ops; lowercase modifiers for -S search forms.
PACMAN_OP_QUERY :: 'Q'
PACMAN_OP_SYNC :: 'S'
PACMAN_OP_REMOVE :: 'R'
PACMAN_OP_UPGRADE :: 'U'
PACMAN_OP_FILES :: 'F'
PACMAN_SYNC_SEARCH_MODS := [?]rune{'s', 'i', 'l', 'g'} // -Ss -Si -Sl -Sg
PACMAN_SYNC_MUTATE_MODS := [?]rune{'y', 'u'} // -Sy / -Su / -Syu

bash_pacman_rune_in :: proc(c: rune, set: []rune) -> bool {
	for r in set {
		if r == c {
			return true
		}
	}
	return false
}

bash_pacman_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if bash_token_in(a, PACMAN_HELP[:]) {
		return true
	}
	rest := a
	saw_query := false
	saw_sync_query := false // -Ss -Si -Sl -Sg (search/info) without install
	saw_mutator := false
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		// long options
		if bash_token_in(tok, PACMAN_QUERY_LONG[:]) {
			saw_query = true
			rest = rem
			continue
		}
		if tok == "--sync" {
			// bare --sync with packages installs; with -s/-i search/info OK
			// track and refine with short flags
			saw_sync_query = true // provisional; cleared if install-like
			rest = rem
			continue
		}
		if bash_token_in(tok, PACMAN_MUTATE_LONG[:]) {
			saw_mutator = true
			rest = rem
			continue
		}
		if tok == "--help" || tok == "--version" {
			rest = rem
			continue
		}
		// short flag clusters: -Q, -Qi, -Ql, -Qo, -Qs, -Qu, -Qe, -Ss, -Si, -Sl, -Sg, -F, -Fl
		// mutators: -S (install if no s/i/l/g only search flags and has targets), -R, -U, -Syu, -Syy
		if strings.has_prefix(tok, "-") && !strings.has_prefix(tok, "--") {
			flags := tok[1:]
			// expand cluster
			has_Q := false
			has_S := false
			has_R := false
			has_U := false
			has_F := false
			has_search_mod := false
			has_mutate_mod := false
			for c in flags {
				switch c {
				case PACMAN_OP_QUERY:
					has_Q = true
				case PACMAN_OP_SYNC:
					has_S = true
				case PACMAN_OP_REMOVE:
					has_R = true
				case PACMAN_OP_UPGRADE:
					has_U = true
				case PACMAN_OP_FILES:
					has_F = true
				case:
					if bash_pacman_rune_in(c, PACMAN_SYNC_SEARCH_MODS[:]) {
						has_search_mod = true
					} else if bash_pacman_rune_in(c, PACMAN_SYNC_MUTATE_MODS[:]) {
						has_mutate_mod = true
					}
					// query mods / help / unknown — ignore for classify
				}
			}
			if has_R || has_U {
				saw_mutator = true
			}
			if has_Q {
				saw_query = true
			}
			if has_F {
				// file database query is inspect
				saw_query = true
			}
			if has_S {
				// -Ss -Si -Sl -Sg are search/info; -Syu / -S pkg are mutators
				if has_mutate_mod {
					saw_mutator = true
				} else if has_search_mod {
					saw_sync_query = true
				} else {
					// plain -S or -S pkg → install
					saw_mutator = true
				}
			}
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "--") {
			// other long flags: peel
			rest = rem
			continue
		}
		// positional package names — only OK if already in query mode
		rest = rem
	}
	if saw_mutator {
		return false
	}
	return saw_query || saw_sync_query
}

// B64: pipx inspect (list/version/environment; not install/run/upgrade).
PIPX_ALLOW := [?]string{"list", "version", "environment", "help"}
PIPX_DENY := [?]string {
	"install", "uninstall", "upgrade", "upgrade-all", "reinstall", "reinstall-all",
	"inject", "uninject", "run", "runpip", "ensurepath", "completions",
}
PIPX_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = PIPX_ALLOW[:],
	deny_subs     = PIPX_DENY[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_pipx_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, PIPX_READONLY_SPEC)
}

// B64: RubyGems inspect (list/search/env/outdated; not install/update).
GEM_ALLOW := [?]string {
	"list", "search", "query", "specification", "spec", "environment", "env",
	"which", "outdated", "contents", "dependency", "info", "help", "check", "sources",
}
GEM_DENY := [?]string {
	"install", "uninstall", "update", "cleanup", "build", "push", "yank",
	"signout", "signin", "owner", "cert", "pristine", "lock", "unpack",
	"generate_index", "server", "mirror", "fetch", "open", "rdoc", "stale",
}
GEM_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = GEM_ALLOW[:],
	deny_subs     = GEM_DENY[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

// gem sources --add/--remove mutates; bare sources lists.
bash_gem_sources_is_readonly :: proc(rest: string) -> bool {
	r2 := rest
	for {
		t2, r3 := first_shell_token(r2)
		if t2 == "" {
			return true
		}
		if t2 == "--add" ||
		   t2 == "--remove" ||
		   t2 == "--clear-all" ||
		   t2 == "-a" ||
		   t2 == "-r" {
			return false
		}
		r2 = r3
	}
	return true
}

bash_gem_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if bash_is_help_or_version(a) {
		return true
	}
	sub, rem, ok := bash_peel_to_sub(a)
	if ok && sub == "sources" {
		return bash_gem_sources_is_readonly(rem)
	}
	return bash_cli_is_readonly(args, GEM_READONLY_SPEC)
}

