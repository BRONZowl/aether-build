// Soft bash readonly helpers — OS package managers + language package tools (flatpak..gem).
// Same package core — symbols used by bash_program_is_readonly.
package core

import "core:strings"

// B60: flatpak inspect (list/info/search/remotes; not install/update/run).
bash_flatpak_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "--version" || a == "--help" || a == "-h" || a == "help" {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if strings.has_prefix(tok, "-") {
			// peel flags (user/system, columns, …)
			if tok == "--user" ||
			   tok == "--system" ||
			   tok == "--columns" ||
			   tok == "--arch" ||
			   tok == "--installation" {
				if tok == "--columns" || tok == "--arch" || tok == "--installation" {
					_, rest2 := first_shell_token(rem)
					rest = rest2
					continue
				}
				rest = rem
				continue
			}
			if strings.has_prefix(tok, "--columns=") ||
			   strings.has_prefix(tok, "--arch=") ||
			   strings.has_prefix(tok, "--installation=") {
				rest = rem
				continue
			}
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		if sub == "install" ||
		   sub == "uninstall" ||
		   sub == "update" ||
		   sub == "upgrade" ||
		   sub == "run" ||
		   sub == "override" ||
		   sub == "make-current" ||
		   sub == "enter" ||
		   sub == "permission-set" ||
		   sub == "permission-reset" ||
		   sub == "permission-remove" ||
		   sub == "repair" ||
		   sub == "create-usb" ||
		   sub == "build" ||
		   sub == "build-export" ||
		   sub == "build-bundle" ||
		   sub == "build-import-bundle" ||
		   sub == "build-sign" ||
		   sub == "build-update-repo" ||
		   sub == "build-commit-from" ||
		   sub == "repo" ||
		   sub == "document-export" ||
		   sub == "document-unexport" ||
		   sub == "kill" ||
		   sub == "spawn" {
			return false
		}
		// remote-add / remote-delete mutate; remote-list/remote-ls/remote-info inspect
		if sub == "remote-add" ||
		   sub == "remote-delete" ||
		   sub == "remote-modify" ||
		   sub == "mask" ||
		   sub == "unmask" {
			return false
		}
		if sub == "config" {
			// config set mutates; list/get only
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "--list" || n == "get" || n == "--help" || n == "-h" || n == "list"
		}
		if sub == "list" ||
		   sub == "info" ||
		   sub == "search" ||
		   sub == "remote-list" ||
		   sub == "remotes" ||
		   sub == "remote-ls" ||
		   sub == "remote-info" ||
		   sub == "history" ||
		   sub == "ps" ||
		   sub == "permission-show" ||
		   sub == "permission-list" ||
		   sub == "document-list" ||
		   sub == "document-info" ||
		   sub == "help" ||
		   sub == "--version" {
			return true
		}
		return false
	}
}

// B60: snap inspect (list/info/find; not install/remove/refresh).
bash_snap_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" || a == "--version" || a == "--help" || a == "-h" || a == "help" {
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
		   sub == "remove" ||
		   sub == "refresh" ||
		   sub == "try" ||
		   sub == "download" ||
		   sub == "pack" ||
		   sub == "start" ||
		   sub == "stop" ||
		   sub == "restart" ||
		   sub == "enable" ||
		   sub == "disable" ||
		   sub == "set" ||
		   sub == "unset" ||
		   sub == "connect" ||
		   sub == "disconnect" ||
		   sub == "alias" ||
		   sub == "unalias" ||
		   sub == "prefer" ||
		   sub == "switch" ||
		   sub == "create-cohort" ||
		   sub == "ack" ||
		   sub == "sign" ||
		   sub == "login" ||
		   sub == "logout" ||
		   sub == "buy" ||
		   sub == "abort" ||
		   sub == "watch" ||
		   sub == "wait" ||
		   sub == "run" ||
		   sub == "routine" ||
		   sub == "prepare-image" ||
		   sub == "remodel" ||
		   sub == "reboot" ||
		   sub == "recovery" ||
		   sub == "debug" {
			return false
		}
		if sub == "list" ||
		   sub == "info" ||
		   sub == "find" ||
		   sub == "search" ||
		   sub == "version" ||
		   sub == "help" ||
		   sub == "known" ||
		   sub == "connections" ||
		   sub == "interface" ||
		   sub == "interfaces" ||
		   sub == "model" ||
		   sub == "changes" ||
		   sub == "tasks" ||
		   sub == "warnings" ||
		   sub == "get" ||
		   sub == "services" ||
		   sub == "logs" ||
		   sub == "whoami" ||
		   sub == "ok" {
			return true
		}
		return false
	}
}

// B60: Alpine apk inspect (info/search/list/version; not add/del/upgrade).
bash_apk_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "--version" || a == "--help" || a == "-h" || a == "help" || a == "version" {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		// globals that take values
		if tok == "--repository" || tok == "-X" || tok == "--root" || tok == "--keys-dir" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--repository=") ||
		   strings.has_prefix(tok, "--root=") ||
		   strings.has_prefix(tok, "--keys-dir=") {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		if sub == "add" ||
		   sub == "del" ||
		   sub == "delete" ||
		   sub == "fix" ||
		   sub == "upgrade" ||
		   sub == "update" ||
		   sub == "fetch" ||
		   sub == "manifest" ||
		   sub == "dot" ||
		   sub == "cache" ||
		   sub == "index" {
			return false
		}
		if sub == "info" ||
		   sub == "search" ||
		   sub == "list" ||
		   sub == "version" ||
		   sub == "policy" ||
		   sub == "stats" ||
		   sub == "audit" ||
		   sub == "verify" ||
		   sub == "help" {
			return true
		}
		return false
	}
}

// B59: apt / apt-get inspect (list/search/show/policy; not install/update/upgrade).
bash_apt_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "--version" ||
	   a == "-v" ||
	   a == "--help" ||
	   a == "-h" ||
	   a == "help" {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		// common globals
		if tok == "-y" ||
		   tok == "--yes" ||
		   tok == "--assume-yes" ||
		   tok == "-qq" ||
		   tok == "-q" ||
		   tok == "--quiet" ||
		   tok == "-o" ||
		   tok == "--option" {
			if tok == "-o" || tok == "--option" {
				_, rest2 := first_shell_token(rem)
				rest = rest2
				continue
			}
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-o") && len(tok) > 2 {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		// mutators
		if sub == "install" ||
		   sub == "remove" ||
		   sub == "purge" ||
		   sub == "update" ||
		   sub == "upgrade" ||
		   sub == "full-upgrade" ||
		   sub == "dist-upgrade" ||
		   sub == "autoremove" ||
		   sub == "autopurge" ||
		   sub == "clean" ||
		   sub == "autoclean" ||
		   sub == "source" ||
		   sub == "build-dep" ||
		   sub == "download" ||
		   sub == "reinstall" ||
		   sub == "mark" ||
		   sub == "hold" ||
		   sub == "unhold" {
			return false
		}
		// inspect
		if sub == "list" ||
		   sub == "search" ||
		   sub == "show" ||
		   sub == "showsrc" ||
		   sub == "policy" ||
		   sub == "depends" ||
		   sub == "rdepends" ||
		   sub == "changelog" ||
		   sub == "check" ||
		   sub == "help" ||
		   sub == "moo" {
			return true
		}
		return false
	}
}

// B59: apt-cache is read-only package metadata (no install path).
bash_apt_cache_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" || a == "--help" || a == "-h" || a == "help" {
		return true
	}
	// gencaches writes — deny; most other ops are inspect
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
		if sub == "gencaches" {
			return false
		}
		if sub == "search" ||
		   sub == "show" ||
		   sub == "showpkg" ||
		   sub == "showsrc" ||
		   sub == "policy" ||
		   sub == "depends" ||
		   sub == "rdepends" ||
		   sub == "pkgnames" ||
		   sub == "dotty" ||
		   sub == "xvcg" ||
		   sub == "unmet" ||
		   sub == "dump" ||
		   sub == "dumpavail" ||
		   sub == "stats" ||
		   sub == "madison" ||
		   sub == "help" {
			return true
		}
		return false
	}
}

// B59: dnf / yum inspect (list/info/search/repolist; not install/remove/upgrade).
bash_dnf_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "--version" || a == "--help" || a == "-h" || a == "help" {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		// peel common globals
		if tok == "-y" ||
		   tok == "--assumeyes" ||
		   tok == "-q" ||
		   tok == "--quiet" ||
		   tok == "-v" ||
		   tok == "--verbose" ||
		   tok == "--enablerepo" ||
		   tok == "--disablerepo" ||
		   tok == "--repoid" ||
		   tok == "--setopt" {
			if tok == "--enablerepo" ||
			   tok == "--disablerepo" ||
			   tok == "--repoid" ||
			   tok == "--setopt" {
				_, rest2 := first_shell_token(rem)
				rest = rest2
				continue
			}
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "--enablerepo=") ||
		   strings.has_prefix(tok, "--disablerepo=") ||
		   strings.has_prefix(tok, "--repoid=") ||
		   strings.has_prefix(tok, "--setopt=") {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		if sub == "install" ||
		   sub == "remove" ||
		   sub == "erase" ||
		   sub == "upgrade" ||
		   sub == "update" ||
		   sub == "downgrade" ||
		   sub == "reinstall" ||
		   sub == "distro-sync" ||
		   sub == "makecache" ||
		   sub == "clean" ||
		   sub == "autoremove" ||
		   sub == "groupinstall" ||
		   sub == "groupremove" ||
		   sub == "mark" {
			// mark install/remove mutates; fail closed
			return false
		}
		// module enable/install still mutates — only list/info under module
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
		if sub == "list" ||
		   sub == "info" ||
		   sub == "search" ||
		   sub == "repolist" ||
		   sub == "repoinfo" ||
		   sub == "check-update" ||
		   sub == "check-upgrade" ||
		   sub == "provides" ||
		   sub == "whatprovides" ||
		   sub == "repoquery" ||
		   sub == "history" ||
		   sub == "help" ||
		   sub == "check" ||
		   sub == "deplist" ||
		   sub == "changelog" ||
		   sub == "leaves" {
			return true
		}
		return false
	}
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

