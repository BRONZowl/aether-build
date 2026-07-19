// Soft bash readonly helpers — OS package managers + language package tools (flatpak..gem).
// Same package core — symbols used by bash_program_is_readonly.
package core

import "core:strings"

// B60: flatpak inspect (list/info/search/remotes; not install/update/run).
bash_flatpak_is_readonly :: proc(args: string) -> bool {
	value_flags := []string{"--columns", "--arch", "--installation"}
	sub, rem, ok := bash_peel_to_sub(args, value_flags)
	if bash_is_help_or_version(strings.trim_space(args)) || !ok {
		return true
	}
	if sub == "config" {
		next, _ := first_shell_token(rem)
		n := strings.to_lower(next, context.temp_allocator)
		return n == "" || n == "--list" || n == "get" || n == "--help" || n == "-h" || n == "list"
	}
	deny := []string {
		"install", "uninstall", "update", "upgrade", "run", "override", "make-current",
		"enter", "permission-set", "permission-reset", "permission-remove", "repair",
		"create-usb", "build", "build-export", "build-bundle", "build-import-bundle",
		"build-sign", "build-update-repo", "build-commit-from", "repo",
		"document-export", "document-unexport", "kill", "spawn",
		"remote-add", "remote-delete", "remote-modify", "mask", "unmask",
	}
	allow := []string {
		"list", "info", "search", "remote-list", "remotes", "remote-ls", "remote-info",
		"history", "ps", "permission-show", "permission-list", "document-list",
		"document-info", "help", "--version",
	}
	if bash_token_in(sub, deny) {
		return false
	}
	return bash_token_in(sub, allow)
}

// B60: snap inspect (list/info/find; not install/remove/refresh).
bash_snap_is_readonly :: proc(args: string) -> bool {
	return bash_sub_readonly(
		args,
		allow = {
			"list", "info", "find", "search", "version", "help", "known", "connections",
			"interface", "interfaces", "model", "changes", "tasks", "warnings", "get",
			"services", "logs", "whoami", "ok",
		},
		deny = {
			"install", "remove", "refresh", "try", "download", "pack", "start", "stop",
			"restart", "enable", "disable", "set", "unset", "connect", "disconnect",
			"alias", "unalias", "prefer", "switch", "create-cohort", "ack", "sign",
			"login", "logout", "buy", "abort", "watch", "wait", "run", "routine",
			"prepare-image", "remodel", "reboot", "recovery", "debug",
		},
	)
}

// B60: Alpine apk inspect (info/search/list/version; not add/del/upgrade).
bash_apk_is_readonly :: proc(args: string) -> bool {
	return bash_sub_readonly(
		args,
		allow = {
			"info", "search", "list", "version", "policy", "stats", "audit", "verify", "help",
		},
		deny = {
			"add", "del", "delete", "fix", "upgrade", "update", "fetch", "manifest",
			"dot", "cache", "index",
		},
		value_flags = {"--repository", "-X", "--root", "--keys-dir"},
	)
}

// B59: apt / apt-get inspect (list/search/show/policy; not install/update/upgrade).
bash_apt_is_readonly :: proc(args: string) -> bool {
	return bash_sub_readonly(
		args,
		allow = {
			"list", "search", "show", "showsrc", "policy", "depends", "rdepends",
			"changelog", "check", "help", "moo",
		},
		deny = {
			"install", "remove", "purge", "update", "upgrade", "full-upgrade",
			"dist-upgrade", "autoremove", "autopurge", "clean", "autoclean",
			"source", "build-dep", "download", "reinstall", "mark", "hold", "unhold",
		},
		value_flags = {"-o", "--option"},
	)
}

// B59: apt-cache is read-only package metadata (no install path).
bash_apt_cache_is_readonly :: proc(args: string) -> bool {
	return bash_sub_readonly(
		args,
		allow = {
			"search", "show", "showpkg", "showsrc", "policy", "depends", "rdepends",
			"pkgnames", "dotty", "xvcg", "unmet", "dump", "dumpavail", "stats",
			"madison", "help",
		},
		deny = {"gencaches"},
	)
}

// B59: dnf / yum inspect (list/info/search/repolist; not install/remove/upgrade).
bash_dnf_is_readonly :: proc(args: string) -> bool {
	value_flags := []string{"--enablerepo", "--disablerepo", "--repoid", "--setopt"}
	if bash_is_help_or_version(strings.trim_space(args)) {
		return true
	}
	sub, rem, ok := bash_peel_to_sub(args, value_flags)
	if !ok {
		return true
	}
	// nested: module/group inspect only
	if sub == "module" {
		next, _ := first_shell_token(rem)
		n := strings.to_lower(next, context.temp_allocator)
		return n == "list" || n == "info" || n == "provides" || n == "" || n == "help"
	}
	if sub == "group" {
		next, _ := first_shell_token(rem)
		n := strings.to_lower(next, context.temp_allocator)
		return n == "list" || n == "info" || n == "summary" || n == "" || n == "help"
	}
	deny := []string {
		"install", "remove", "erase", "upgrade", "update", "downgrade", "reinstall",
		"distro-sync", "makecache", "clean", "autoremove", "groupinstall", "groupremove", "mark",
	}
	allow := []string {
		"list", "info", "search", "repolist", "repoinfo", "check-update", "check-upgrade",
		"provides", "whatprovides", "repoquery", "history", "help", "check", "deplist",
		"changelog", "leaves",
	}
	if bash_token_in(sub, deny) {
		return false
	}
	return bash_token_in(sub, allow)
}

// B59: pacman query/search only (-Q/-S query forms; not -S install / -R / -Syu).
bash_pacman_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "--version" || a == "-V" || a == "--help" || a == "-h" || a == "help" {
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
		if tok == "--query" {
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
		if tok == "--remove" || tok == "--upgrade" || tok == "--database" {
			saw_mutator = true
			rest = rem
			continue
		}
		if tok == "--files" || tok == "--deptest" {
			// file DB query / dependency test — inspect
			saw_query = true
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
			has_s := false // search
			has_i := false // info
			has_l := false // list
			has_g := false // groups
			has_y := false // refresh (mutates dbs when with S)
			has_u := false // sysupgrade
			for c in flags {
				switch c {
				case 'Q':
					has_Q = true
				case 'S':
					has_S = true
				case 'R':
					has_R = true
				case 'U':
					has_U = true
				case 'F':
					has_F = true
				case 's':
					has_s = true
				case 'i':
					has_i = true
				case 'l':
					has_l = true
				case 'g':
					has_g = true
				case 'y':
					has_y = true
				case 'u':
					has_u = true
				case 'h', 'V':
				// help/version
				case 'v', 'q', 'e', 'd', 'k', 'm', 'n', 'o', 'p', 't':
				// common query modifiers
				case:
				// unknown short — ignore for classify
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
				if has_y || has_u {
					saw_mutator = true
				} else if has_s || has_i || has_l || has_g {
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
bash_pipx_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "--version" || a == "-V" || a == "--help" || a == "-h" || a == "help" {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		if sub == "install" ||
		   sub == "uninstall" ||
		   sub == "upgrade" ||
		   sub == "upgrade-all" ||
		   sub == "reinstall" ||
		   sub == "reinstall-all" ||
		   sub == "inject" ||
		   sub == "uninject" ||
		   sub == "run" ||
		   sub == "runpip" ||
		   sub == "ensurepath" ||
		   sub == "completions" {
			// completions may write shell files — fail closed
			return false
		}
		if sub == "list" ||
		   sub == "version" ||
		   sub == "environment" ||
		   sub == "help" {
			return true
		}
		return false
	}
}

// B64: RubyGems inspect (list/search/env/outdated; not install/update).
bash_gem_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "--version" || a == "-v" || a == "--help" || a == "-h" || a == "help" {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		if sub == "install" ||
		   sub == "uninstall" ||
		   sub == "update" ||
		   sub == "cleanup" ||
		   sub == "build" ||
		   sub == "push" ||
		   sub == "yank" ||
		   sub == "signout" ||
		   sub == "signin" ||
		   sub == "owner" ||
		   sub == "cert" ||
		   sub == "pristine" ||
		   sub == "lock" ||
		   sub == "unpack" ||
		   sub == "generate_index" ||
		   sub == "server" ||
		   sub == "mirror" ||
		   sub == "fetch" ||
		   sub == "open" ||
		   sub == "rdoc" ||
		   sub == "stale" {
			return false
		}
		// sources --add/--remove mutates; bare sources lists
		if sub == "sources" {
			r2 := rem
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
		}
		if sub == "list" ||
		   sub == "search" ||
		   sub == "query" ||
		   sub == "specification" ||
		   sub == "spec" ||
		   sub == "environment" ||
		   sub == "env" ||
		   sub == "which" ||
		   sub == "outdated" ||
		   sub == "contents" ||
		   sub == "dependency" ||
		   sub == "info" ||
		   sub == "help" ||
		   sub == "check" {
			return true
		}
		return false
	}
}

