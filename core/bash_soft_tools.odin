// Soft bash readonly helpers — Lang runtimes, DBs, HTTP, git, nix, aws (bundler..end).
// Same package core — symbols used by bash_program_is_readonly.
package core

import "core:strings"

// B66: Bundler inspect (list/show/check/outdated/env; not install/exec/update).
bash_bundle_is_readonly :: proc(args: string) -> bool {
	if bash_is_help_or_version(strings.trim_space(args)) {
		return true
	}
	sub, rem, ok := bash_peel_to_sub(args, []string{"--gemfile", "--path", "--binstubs"})
	if !ok {
		return true
	}
	// config: get/list only
	if sub == "config" {
		next, _ := first_shell_token(rem)
		n := strings.to_lower(next, context.temp_allocator)
		return n == "" || n == "list" || n == "get" || n == "help" || n == "--help" || n == "-h"
	}
	deny := []string {
		"install", "update", "exec", "add", "remove", "clean", "package", "pack",
		"binstubs", "init", "inject", "open", "console", "lock", "cache", "pristine",
		"plugin", "fund", "issue",
	}
	allow := []string {
		"list", "show", "info", "check", "outdated", "env", "platform", "doctor",
		"help", "version", "viz", "licenses", "why",
	}
	if bash_token_in(sub, deny) {
		return false
	}
	return bash_token_in(sub, allow)
}

// B66: rake task listing only (-T/-D/-P/…); bare rake runs default task → ask.
bash_rake_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		// bare `rake` runs default task
		return false
	}
	if a == "--version" ||
	   a == "-V" ||
	   a == "--help" ||
	   a == "-h" ||
	   a == "-T" ||
	   a == "--tasks" ||
	   a == "-D" ||
	   a == "--describe" ||
	   a == "-P" ||
	   a == "--prereqs" ||
	   a == "-W" ||
	   a == "--where" {
		return true
	}
	rest := a
	saw_inspect := false
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		// value-taking flags
		if tok == "-f" ||
		   tok == "--rakefile" ||
		   tok == "-I" ||
		   tok == "--libdir" ||
		   tok == "-R" ||
		   tok == "--rakelibdir" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "-f") && len(tok) > 2 {
			rest = rem
			continue
		}
		if tok == "-T" ||
		   tok == "--tasks" ||
		   tok == "-D" ||
		   tok == "--describe" ||
		   tok == "-P" ||
		   tok == "--prereqs" ||
		   tok == "-W" ||
		   tok == "--where" ||
		   tok == "--version" ||
		   tok == "-V" ||
		   tok == "--help" ||
		   tok == "-h" ||
		   tok == "-A" || // show all tasks with -T
		   tok == "--all" {
			saw_inspect = true
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-T") {
			// -Tpattern
			saw_inspect = true
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			// other flags (trace, verbose, …) ok for list mode
			rest = rem
			continue
		}
		// positional task name → would run task
		return false
	}
	return saw_inspect
}

// B64: Composer inspect (show/search/outdated/validate; not install/require).
bash_composer_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "about" {
		return true
	}
	return bash_sub_readonly(
		args,
		allow = {
			"show", "list", "search", "depends", "prohibits", "validate",
			"check-platform-reqs", "outdated", "why", "why-not", "licenses",
			"status", "about", "diagnose", "help", "suggests", "browse",
		},
		deny = {
			"install", "update", "require", "remove", "create-project",
			"dump-autoload", "dumpautoload", "clear-cache", "clearcache",
			"self-update", "selfupdate", "exec", "run-script", "run",
			"global", "config", "init", "archive", "fund", "bump", "reinstall",
		},
		value_flags = {"--working-dir", "-d"},
	)
}

// B58: Homebrew inspect (list/info/search/outdated; not install/upgrade/update).
bash_brew_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		// bare brew — help-ish
		return true
	}
	// common global / info flags with no package install
	if a == "--version" ||
	   a == "-v" ||
	   a == "--help" ||
	   a == "-h" ||
	   a == "--prefix" ||
	   a == "--cellar" ||
	   a == "--repository" ||
	   a == "--repo" ||
	   a == "--cache" ||
	   a == "--env" ||
	   a == "--config" ||
	   strings.has_prefix(a, "--prefix ") ||
	   strings.has_prefix(a, "--prefix=") ||
	   strings.has_prefix(a, "--cellar ") ||
	   strings.has_prefix(a, "--cellar=") ||
	   strings.has_prefix(a, "--cache ") ||
	   strings.has_prefix(a, "--cache=") ||
	   strings.has_prefix(a, "--env ") ||
	   strings.has_prefix(a, "--repository ") ||
	   strings.has_prefix(a, "--repo ") {
		return true
	}
	rest := a
	// peel leading flags that take optional values
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "--verbose" ||
		   tok == "-v" ||
		   tok == "--debug" ||
		   tok == "-d" ||
		   tok == "--quiet" ||
		   tok == "-q" ||
		   tok == "--formula" ||
		   tok == "--cask" ||
		   tok == "--help" ||
		   tok == "-h" {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			// unknown flag — peel only this token
			rest = rem
			continue
		}
		// first non-flag is subcommand
		sub := strings.to_lower(tok, context.temp_allocator)
		// mutators
		if sub == "install" ||
		   sub == "uninstall" ||
		   sub == "reinstall" ||
		   sub == "upgrade" ||
		   sub == "update" ||
		   sub == "cleanup" ||
		   sub == "untap" ||
		   sub == "link" ||
		   sub == "unlink" ||
		   sub == "pin" ||
		   sub == "unpin" ||
		   sub == "create" ||
		   sub == "edit" ||
		   sub == "extract" ||
		   sub == "bundle" ||
		   sub == "postinstall" ||
		   sub == "vendor-install" ||
		   sub == "shellenv" || // writes env setup; still mostly inspect — allow? fail closed mild
		   sub == "autoupdate" {
			return false
		}
		// tap: bare / --list only (adding a tap mutates)
		if sub == "tap" {
			next, _ := first_shell_token(rem)
			if next == "" || next == "--list" || next == "--help" || next == "-h" {
				return true
			}
			// `brew tap user/repo` adds
			if strings.has_prefix(next, "-") {
				// flags only after tap — treat as list-ish if no repo arg later
				// fail closed unless only flags
				r2 := rem
				for {
					t2, r3 := first_shell_token(r2)
					if t2 == "" {
						return true
					}
					if strings.has_prefix(t2, "-") {
						r2 = r3
						continue
					}
					return false
				}
			}
			return false
		}
		// services: list / info only
		if sub == "services" {
			next, nrem := first_shell_token(rem)
			_ = nrem
			if next == "" || next == "list" || next == "--help" || next == "-h" || next == "info" {
				return true
			}
			return false
		}
		// inspect verbs
		if sub == "list" ||
		   sub == "ls" ||
		   sub == "info" ||
		   sub == "search" ||
		   sub == "outdated" ||
		   sub == "deps" ||
		   sub == "uses" ||
		   sub == "cat" ||
		   sub == "home" ||
		   sub == "desc" ||
		   sub == "leaves" ||
		   sub == "doctor" ||
		   sub == "missing" ||
		   sub == "livecheck" ||
		   sub == "options" ||
		   sub == "formulae" ||
		   sub == "casks" ||
		   sub == "help" ||
		   sub == "config" ||
		   sub == "env" ||
		   sub == "commands" ||
		   sub == "which" ||
		   sub == "--version" ||
		   sub == "version" ||
		   sub == "readall" ||
		   sub == "style" || // lint, no install
		   sub == "audit" ||
		   sub == "log" {
			return true
		}
		return false
	}
}

// B36: kubectl get/describe/logs/… + config view (not apply/delete/create).
bash_kubectl_is_readonly :: proc(args: string) -> bool {
	if bash_is_help_or_version(strings.trim_space(args)) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(args)
	if !ok {
		return true
	}
	if sub == "config" {
		sub2, _ := first_shell_token(rest)
		n := strings.to_lower(sub2, context.temp_allocator)
		if n == "" || n == "--help" || n == "help" || n == "-h" {
			return true
		}
		return bash_token_in(
			n,
			[]string{
				"view",
				"get-contexts",
				"current-context",
				"get-clusters",
				"get-users",
			},
		)
	}
	return bash_token_in(
		sub,
		[]string{
			"get",
			"logs",
			"describe",
			"top",
			"api-resources",
			"api-versions",
			"explain",
			"cluster-info",
			"auth", // auth can-i is inspect
			"diff",
			"wait",
			"version",
			"help",
		},
	)
}

// B36: terraform / tofu inspect (not apply/destroy/import).
bash_terraform_is_readonly :: proc(args: string) -> bool {
	if bash_is_help_or_version(strings.trim_space(args)) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(args, []string{"-chdir"})
	if !ok {
		return true
	}
	if sub == "fmt" {
		// only check/diff modes; bare fmt rewrites files
		if strings.contains(rest, "-check") || strings.contains(rest, "-diff") {
			if strings.contains(rest, "-write=true") {
				return false
			}
			return true
		}
		return false
	}
	if sub == "plan" {
		// plan inspect unless -out / generate-config-out write artifacts
		if strings.contains(rest, "-out") || strings.contains(rest, "-generate-config-out") {
			return false
		}
		return true
	}
	if sub == "state" {
		sub2, _ := first_shell_token(rest)
		n := strings.to_lower(sub2, context.temp_allocator)
		if n == "" || n == "--help" || n == "help" || n == "-h" {
			return true
		}
		return bash_token_in(n, []string{"list", "show", "pull"})
	}
	if sub == "workspace" {
		sub2, _ := first_shell_token(rest)
		n := strings.to_lower(sub2, context.temp_allocator)
		if n == "" || n == "--help" || n == "help" || n == "-h" {
			return true
		}
		return bash_token_in(n, []string{"list", "show"})
	}
	return bash_token_in(
		sub,
		[]string{"validate", "providers", "output", "show", "graph", "metadata", "version", "help"},
	)
}

// B36: helm list/status/get/template/lint (not install/upgrade/uninstall).
bash_helm_is_readonly :: proc(args: string) -> bool {
	if bash_is_help_or_version(strings.trim_space(args)) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(args)
	if !ok || sub == "env" {
		return true
	}
	// nested: dependency/repo/plugin/registry inspect only
	if sub == "dependency" || sub == "deps" {
		sub2, _ := first_shell_token(rest)
		n := strings.to_lower(sub2, context.temp_allocator)
		return n == "" || n == "list" || n == "ls" || n == "--help" || n == "help" || n == "-h"
	}
	if sub == "repo" {
		sub2, _ := first_shell_token(rest)
		n := strings.to_lower(sub2, context.temp_allocator)
		return n == "" || n == "list" || n == "ls" || n == "--help" || n == "help" || n == "-h"
	}
	if sub == "plugin" {
		sub2, _ := first_shell_token(rest)
		n := strings.to_lower(sub2, context.temp_allocator)
		return n == "" || n == "list" || n == "ls" || n == "--help" || n == "help" || n == "-h"
	}
	if sub == "registry" {
		// login mutates credentials — fail closed except help
		sub2, _ := first_shell_token(rest)
		n := strings.to_lower(sub2, context.temp_allocator)
		return n == "" || n == "--help" || n == "help" || n == "-h"
	}
	return bash_token_in(
		sub,
		[]string{
			"list", "ls", "status", "history", "get", "show", "search", "lint", "template",
		},
	)
}

// B35: docker inspect + compose inspect (not run/up/build/exec).
bash_docker_is_readonly :: proc(args: string) -> bool {
	if bash_is_help_or_version(strings.trim_space(args)) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(args)
	if !ok {
		return true
	}
	if sub == "info" {
		return true
	}
	// plugin-style: docker compose …
	if sub == "compose" {
		return bash_docker_compose_is_readonly(rest)
	}
	return bash_token_in(
		sub,
		[]string{"ps", "images", "logs", "inspect", "top", "stats", "port", "diff"},
	)
}

// docker compose / docker-compose: list/config/ps/logs/images/top/version only.
bash_docker_compose_is_readonly :: proc(args: string) -> bool {
	return bash_sub_readonly(
		args,
		allow = {
			"ps", "ls", "list", "config", "images", "logs", "top", "port", "events", "wait",
		},
		value_flags = {
			"-f", "--file", "-p", "--project-name", "--profile", "--project-directory",
			"--env-file", "--ansi", "--progress",
		},
	)
}

// B16: cargo read-only / non-mutating inspection (no build/test/run).
bash_cargo_is_readonly :: proc(args: string) -> bool {
	return bash_sub_readonly(
		args,
		allow = {
			"check", "metadata", "tree", "search", "help", "version",
			"locate-project", "verify-project", "pkgid", "info", "fetch",
		},
		value_flags = {
			"-C", "--manifest-path", "--config", "--color", "-Z", "--target-dir",
		},
	)
}

// npm/pnpm/yarn: inspection only (not install/run/build — those write or execute project code).
bash_npm_family_is_readonly :: proc(args: string) -> bool {
	sub, rest := first_shell_token(args)
	// yarn often uses yarn list / yarn why without sub as first after global
	if sub == "" {
		return false
	}
	// peel -C / --prefix / --cwd value flags lightly
	for {
		if sub == "--prefix" || sub == "--cwd" || sub == "-C" || sub == "--dir" {
			_, rest2 := first_shell_token(rest)
			sub, rest = first_shell_token(rest2)
			continue
		}
		if strings.has_prefix(sub, "-") &&
		   (sub == "-s" ||
			   sub == "--silent" ||
			   sub == "-q" ||
			   sub == "--quiet" ||
			   sub == "-l" ||
			   sub == "--long" ||
			   sub == "--json" ||
			   sub == "--version" ||
			   sub == "-v" ||
			   sub == "--help" ||
			   sub == "-h") {
			if sub == "--version" || sub == "-v" || sub == "--help" || sub == "-h" {
				return true
			}
			sub, rest = first_shell_token(rest)
			continue
		}
		break
	}
	// config get/list only
	if sub == "config" {
		sub2, _ := first_shell_token(rest)
		return sub2 == "get" || sub2 == "list" || sub2 == "ls" || sub2 == ""
	}
	return bash_token_in(
		sub,
		[]string{
			"list",
			"ls",
			"ll",
			"la",
			"outdated",
			"why",
			"view",
			"info",
			"show",
			"audit",
			"version",
			"help",
			"explain",
			"query",
			"root",
			"bin",
			"prefix",
			"doctor",
			"fund",
			"search",
			"repo",
			"docs",
			"home",
			"bugs",
		},
	)
}

// B38: bun inspect (not install/run/test/build).
bash_bun_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		// bare `bun` may start REPL — fail closed
		return false
	}
	if bash_is_help_or_version(a) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(a)
	if !ok {
		return false
	}
	// package manager inspect
	if sub == "pm" {
		sub2, _ := first_shell_token(rest)
		n := strings.to_lower(sub2, context.temp_allocator)
		if n == "" || n == "--help" || n == "help" || n == "-h" {
			return true
		}
		return bash_token_in(
			n,
			[]string{"ls", "list", "whoami", "hash", "cache", "version", "pkg", "view", "why"},
		)
	}
	// top-level inspect-ish; bun x runs packages — fail closed
	if sub == "x" {
		return false
	}
	return bash_token_in(sub, []string{"pm", "outdated", "why", "info"})
}

// B38: deno inspect (not run/test/install/compile/cache).
bash_deno_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false
	}
	if bash_is_help_or_version(a) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(a)
	if !ok {
		return false
	}
	if sub == "fmt" {
		return strings.contains(rest, "--check")
	}
	if sub == "task" {
		// task list is inspect; bare task / task NAME runs
		return bash_nested_allow(rest, []string{"list"})
	}
	if bash_token_in(sub, []string{"bench", "coverage", "jupyter"}) {
		return false
	}
	return bash_token_in(sub, []string{"info", "doc", "lint", "check", "types", "version", "help"})
}

// B38: poetry inspect (not install/add/run/update).
bash_poetry_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false
	}
	if a == "about" || bash_is_help_or_version(a) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(a)
	if !ok {
		return false
	}
	if sub == "export" {
		// export writes to stdout by default — allow (no file write unless -o)
		if strings.contains(rest, " -o ") || strings.contains(rest, "--output") {
			return false
		}
		return true
	}
	if sub == "config" {
		// config --list / get only; config set mutates
		if rest == "" ||
		   strings.contains(rest, "--list") ||
		   strings.has_prefix(strings.trim_space(rest), "--list") {
			return true
		}
		// bare key get: `poetry config virtualenvs.path` is read if not --unset
		if strings.contains(rest, "--unset") || strings.contains(rest, " -- ") {
			return false
		}
		// two-token set: poetry config key value → mutates
		tok1, rem1 := first_shell_token(rest)
		tok2, _ := first_shell_token(rem1)
		if tok1 != "" && tok2 != "" && !strings.has_prefix(tok1, "-") && !strings.has_prefix(tok2, "-") {
			return false
		}
		// single key get
		return tok1 != ""
	}
	if sub == "env" {
		return bash_nested_allow(rest, []string{"info", "list"})
	}
	if sub == "lock" {
		// lock --check is inspect; bare lock may rewrite
		return strings.contains(rest, "--check")
	}
	return bash_token_in(
		sub,
		[]string{"show", "check", "list", "search", "debug", "version", "help", "about"},
	)
}

// uv inspection (not sync/add/run/build/venv).
bash_uv_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false
	}
	if bash_is_help_or_version(a) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(a)
	if !ok {
		return false
	}
	if sub == "pip" {
		sub2, _ := first_shell_token(rest)
		n := strings.to_lower(sub2, context.temp_allocator)
		return bash_token_in(n, []string{"list", "show", "freeze", "check", "tree", "help"})
	}
	if sub == "python" {
		sub2, _ := first_shell_token(rest)
		n := strings.to_lower(sub2, context.temp_allocator)
		return n == "" || bash_token_in(n, []string{"list", "find", "dir", "help"})
	}
	if sub == "cache" {
		sub2, _ := first_shell_token(rest)
		n := strings.to_lower(sub2, context.temp_allocator)
		return n == "" || bash_token_in(n, []string{"dir", "size", "help"})
	}
	if sub == "self" {
		sub2, _ := first_shell_token(rest)
		n := strings.to_lower(sub2, context.temp_allocator)
		return n == "" || bash_token_in(n, []string{"version", "help"})
	}
	return bash_token_in(sub, []string{"tree", "version", "help"})
}

// rustup inspection / list (not update/default that mutates toolchain install — update mutates).
// Keep only show/which/doc/help and list-style under toolchain/target/component.
bash_rustup_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false // bare rustup may prompt / not pure inspect
	}
	if bash_is_help_or_version(a) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(a)
	if !ok {
		return false
	}
	if sub == "toolchain" || sub == "target" || sub == "component" || sub == "override" {
		sub2, _ := first_shell_token(rest)
		n := strings.to_lower(sub2, context.temp_allocator)
		return n == "list" || n == "" || n == "help" || n == "--help" || n == "-h"
	}
	return bash_token_in(sub, []string{"show", "which", "doc", "help", "completions"})
}

// pip inspection only.
bash_pip_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false
	}
	return bash_sub_readonly(
		a,
		allow = {"list", "show", "freeze", "check", "index", "help", "debug", "hash", "inspect"},
	)
}

// python --version / -V / --help / -m site|pip|pytest inspect (not -c / scripts).
bash_python_is_readonly :: proc(args: string) -> bool {
	if args == "" {
		// bare python opens REPL — not for non-interactive agent; fail closed
		return false
	}
	sub, rest := first_shell_token(args)
	if sub == "--version" || sub == "-V" || sub == "--help" || sub == "-h" {
		return true
	}
	// python -m site / -m pip list / -m pytest --collect-only
	if sub == "-m" {
		mod, rest2 := first_shell_token(rest)
		if mod == "site" {
			return true
		}
		if mod == "pip" || mod == "pip3" {
			return bash_pip_is_readonly(rest2)
		}
		if mod == "pytest" {
			return bash_pytest_is_readonly(rest2)
		}
		return false
	}
	return false
}

// go: version / env / list / help / doc / mod graph|why|verify.
bash_go_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false
	}
	if bash_is_help_or_version(a) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(a)
	if !ok {
		return false
	}
	if sub == "mod" {
		sub2, _ := first_shell_token(rest)
		n := strings.to_lower(sub2, context.temp_allocator)
		return bash_token_in(n, []string{"graph", "why", "verify"})
	}
	return bash_token_in(sub, []string{"version", "env", "help", "doc", "list"})
}

// B25: make help / dry-run / version only (not build targets).
// With -n/--dry-run/help/version, target names are OK (no side effects for dry-run).
bash_make_is_readonly :: proc(args: string) -> bool {
	if args == "" {
		// bare `make` runs default target — not readonly
		return false
	}
	rest := args
	saw_inspect := false
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		rest = rem
		switch tok {
		case "help", "--help", "-h", "-n", "--dry-run", "--just-print", "--recon", "--version":
			saw_inspect = true
			continue
		}
		// allow -f Makefile with value
		if tok == "-f" || tok == "--file" || tok == "--makefile" {
			_, rest2 := first_shell_token(rest)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "-f") && len(tok) > 2 {
			continue
		}
		// harmless listing-ish
		if tok == "-q" || tok == "--quiet" || tok == "-s" || tok == "--silent" {
			continue
		}
		// other flags (-j, -C, …) fail closed
		if strings.has_prefix(tok, "-") {
			return false
		}
		// bare target names only OK when inspect mode (dry-run/help/version)
		if !saw_inspect {
			return false
		}
		continue
	}
	return saw_inspect
}

// B25: odin version/help only (not build/run/test).
bash_odin_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false
	}
	return bash_sub_readonly(
		a,
		allow = {"version", "help", "doc"},
	)
}

// B40: zig version/env/ast-check/fmt --check (not build/run/test).
bash_zig_is_readonly :: proc(args: string) -> bool {
	if bash_is_help_or_version(strings.trim_space(args)) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(args)
	if !ok {
		return true // bare zig prints help-ish
	}
	if sub == "fmt" {
		// only --check; bare fmt rewrites
		return strings.contains(rest, "--check")
	}
	return bash_token_in(
		sub,
		[]string{"version", "help", "env", "targets", "libc", "std-docs", "ast-check"},
	)
}

// B42: swift package inspect (not build/run/test/package resolve).
bash_swift_is_readonly :: proc(args: string) -> bool {
	sub, rest := first_shell_token(args)
	if sub == "" {
		return false
	}
	if sub == "--version" ||
	   sub == "-version" ||
	   sub == "--help" ||
	   sub == "-h" ||
	   sub == "help" ||
	   sub == "version" {
		return true
	}
	if sub == "package" {
		sub2, rest2 := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		// inspect-ish package subcommands
		if bash_token_in(
			   sub2,
			   []string{
				   "describe",
				   "show-dependencies",
				   "show-executables",
				   "dump-package",
				   "dump-symbol-graph",
				   "tools-version",
				   "completion-tool",
			   },
		   ) {
			return true
		}
		// plugin list only
		if sub2 == "plugin" {
			sub3, _ := first_shell_token(rest2)
			return sub3 == "" || sub3 == "--list" || sub3 == "list" || sub3 == "--help" || sub3 == "help"
		}
		return false
	}
	// swiftc --version style sometimes invoked as swift -frontend …
	if sub == "-frontend" {
		return false
	}
	return false
}

// B42: dotnet info/list (not build/run/test/new/restore).
bash_dotnet_is_readonly :: proc(args: string) -> bool {
	sub, rest := first_shell_token(args)
	if sub == "" {
		// bare `dotnet` prints help
		return true
	}
	if sub == "--info" ||
	   sub == "--list-sdks" ||
	   sub == "--list-runtimes" ||
	   sub == "--version" ||
	   sub == "-h" ||
	   sub == "--help" ||
	   sub == "help" {
		return true
	}
	// nuget list source is inspect; add/remove mutates
	if sub == "nuget" {
		sub2, rest2 := first_shell_token(rest)
		if sub2 == "list" || sub2 == "locals" {
			// locals --list is inspect; --clear mutates
			if sub2 == "locals" && strings.contains(rest2, "--clear") {
				return false
			}
			return true
		}
		return sub2 == "" || sub2 == "--help" || sub2 == "help"
	}
	if sub == "tool" {
		sub2, _ := first_shell_token(rest)
		return sub2 == "list" || sub2 == "" || sub2 == "--help" || sub2 == "help"
	}
	if sub == "workload" {
		sub2, _ := first_shell_token(rest)
		return sub2 == "list" || sub2 == "search" || sub2 == "" || sub2 == "--help" || sub2 == "help"
	}
	// sdk check
	if sub == "sdk" {
		sub2, _ := first_shell_token(rest)
		return sub2 == "check" || sub2 == "" || sub2 == "--help" || sub2 == "help"
	}
	return false
}

// B43: sqlite3 inspect metacommands / SELECT (not INSERT/UPDATE/interactive bare).
bash_sqlite3_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		// bare sqlite3 → interactive REPL
		return false
	}
	// version / help flags anywhere
	if strings.contains(a, "-version") ||
	   strings.contains(a, "--version") ||
	   a == "-help" ||
	   a == "--help" ||
	   strings.has_prefix(a, "-help ") ||
	   strings.has_prefix(a, "--help ") {
		return true
	}
	al := strings.to_lower(a, context.temp_allocator)
	// mutating SQL keywords → fail closed
	mutators := []string {
		"insert ",
		"update ",
		"delete ",
		"drop ",
		"create ",
		"alter ",
		"replace ",
		"attach ",
		"detach ",
		"vacuum",
		"reindex",
		".import",
		".read ",
		".load ",
		".backup",
		".restore",
		".clone",
		".excel",
		".once",
		".output",
		".shell",
		".system",
	}
	for m in mutators {
		if strings.contains(al, m) {
			return false
		}
	}
	// known inspect metacommands
	if strings.contains(al, ".schema") ||
	   strings.contains(al, ".tables") ||
	   strings.contains(al, ".indexes") ||
	   strings.contains(al, ".databases") ||
	   strings.contains(al, ".tables") ||
	   strings.contains(al, ".dbinfo") ||
	   strings.contains(al, ".dump") ||
	   strings.contains(al, ".fullschema") ||
	   strings.contains(al, "pragma ") ||
	   strings.contains(al, "select ") ||
	   strings.contains(al, "explain ") ||
	   strings.has_prefix(al, "select") ||
	   strings.has_prefix(al, "pragma") ||
	   strings.has_prefix(al, "explain") {
		return true
	}
	// -readonly flag with a db path only is still interactive — fail closed
	// -cmd with inspect is covered by contains above when user passes ".tables"
	return false
}

// B43: redis-cli inspect (not SET/DEL/FLUSH).
bash_redis_cli_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		// interactive
		return false
	}
	rest := a
	// peel connection flags: -h HOST -p PORT -n DB -a PASS --user …
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return false
		}
		if tok == "--version" || tok == "-v" || tok == "--help" {
			return true
		}
		// host/port/db/auth flags with separate value
		if tok == "-h" ||
		   tok == "-p" ||
		   tok == "-n" ||
		   tok == "-a" ||
		   tok == "--user" ||
		   tok == "--pass" ||
		   tok == "-u" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if tok == "--tls" || tok == "--insecure" {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "--user=") ||
		   strings.has_prefix(tok, "--pass=") ||
		   strings.has_prefix(tok, "-u") {
			rest = rem
			continue
		}
		// first redis command (not a flag)
		if strings.has_prefix(tok, "-") {
			// unknown flag — fail closed
			return false
		}
		cmd := strings.to_lower(tok, context.temp_allocator)
		if !bash_token_in(
			   cmd,
			   []string{
				   "ping",
				   "info",
				   "dbsize",
				   "get",
				   "mget",
				   "exists",
				   "type",
				   "ttl",
				   "pttl",
				   "strlen",
				   "keys",
				   "scan",
				   "hlen",
				   "hget",
				   "hgetall",
				   "hkeys",
				   "hvals",
				   "llen",
				   "lrange",
				   "scard",
				   "smembers",
				   "zcard",
				   "zrange",
				   "zscore",
				   "client",
				   "config",
				   "memory",
				   "slowlog",
				   "time",
				   "echo",
				   "object",
				   "randomkey",
			   },
		   ) {
			return false
		}
		return bash_redis_subcmd_readonly(cmd, rem)
	}
}

bash_redis_subcmd_readonly :: proc(cmd, rest: string) -> bool {
	// client list/info only; config get only; memory usage/stats/doctor
	sub, _ := first_shell_token(rest)
	sub_l := strings.to_lower(sub, context.temp_allocator)
	switch cmd {
	case "client":
		return sub_l == "" || bash_token_in(sub_l, []string{"list", "info", "id", "getname", "help"})
	case "config":
		return sub_l == "get" || sub_l == "" || sub_l == "help"
	case "memory":
		return sub_l == "" || bash_token_in(sub_l, []string{"usage", "stats", "doctor", "help"})
	case "slowlog":
		return sub_l == "get" || sub_l == "len" || sub_l == "" || sub_l == "help"
	}
	return true
}

// B44: psql inspect (SELECT/\\d meta; not interactive bare, not DML/DDL).
bash_psql_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false // interactive
	}
	al := strings.to_lower(a, context.temp_allocator)
	// version / help
	if strings.contains(a, "--version") ||
	   strings.contains(a, "-V") ||
	   a == "--help" ||
	   a == "-?" ||
	   strings.has_prefix(a, "--help ") ||
	   strings.has_prefix(a, "-? ") {
		return true
	}
	// mutating SQL
	mutators := []string {
		"insert ",
		"update ",
		"delete ",
		"drop ",
		"create ",
		"alter ",
		"truncate ",
		"grant ",
		"revoke ",
		"copy ",
		"\\copy",
		"\\i ",
		"\\ir ",
		"\\o ",
		"\\out",
		"\\gexec",
		"\\watch",
		"vacuum",
		"reindex",
		"cluster ",
		"call ",
		"do ",
	}
	for m in mutators {
		if strings.contains(al, m) {
			return false
		}
	}
	// must have an inspect payload (-c / -f with select, or meta)
	// -c 'SELECT…' / -c "\dt"
	if strings.contains(a, " -c ") ||
	   strings.has_prefix(a, "-c ") ||
	   strings.contains(a, " --command=") ||
	   strings.contains(a, "--command=") ||
	   strings.contains(a, " -c") {
		// -c present: allow if inspect-ish body
		if strings.contains(al, "select ") ||
		   strings.contains(al, "select*") ||
		   strings.has_prefix(strings.trim_space(al), "select") ||
		   strings.contains(al, "show ") ||
		   strings.contains(al, "explain ") ||
		   strings.contains(al, "with ") || // CTE often select
		   strings.contains(al, "\\d") ||
		   strings.contains(al, "\\l") ||
		   strings.contains(al, "\\dt") ||
		   strings.contains(al, "\\di") ||
		   strings.contains(al, "\\dn") ||
		   strings.contains(al, "\\df") ||
		   strings.contains(al, "\\du") ||
		   strings.contains(al, "\\conninfo") ||
		   strings.contains(al, "\\encoding") ||
		   strings.contains(al, "\\echo") {
			return true
		}
		// -c with unknown body — fail closed
		return false
	}
	// -l list databases is inspect
	if a == "-l" || strings.has_prefix(a, "-l ") || strings.contains(a, " -l ") || a == "--list" {
		return true
	}
	return false
}

// B44: mysql/mariadb inspect (SELECT/SHOW/DESCRIBE; not DML/DDL or bare interactive).
bash_mysql_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false
	}
	al := strings.to_lower(a, context.temp_allocator)
	if strings.contains(a, "--version") ||
	   strings.contains(a, "-V") ||
	   a == "--help" ||
	   a == "-?" ||
	   strings.has_prefix(a, "--help ") {
		return true
	}
	mutators := []string {
		"insert ",
		"update ",
		"delete ",
		"drop ",
		"create ",
		"alter ",
		"truncate ",
		"replace ",
		"grant ",
		"revoke ",
		"load data",
		"load xml",
		"call ",
		"do ",
		"lock ",
		"unlock ",
		"flush ",
		"optimize ",
		"repair ",
		"handler ",
	}
	for m in mutators {
		if strings.contains(al, m) {
			return false
		}
	}
	// -e / --execute required for non-interactive inspect
	if strings.contains(a, " -e ") ||
	   strings.has_prefix(a, "-e ") ||
	   strings.contains(a, " --execute=") ||
	   strings.contains(a, "--execute=") ||
	   strings.contains(a, " -e") {
		if strings.contains(al, "select ") ||
		   strings.has_prefix(strings.trim_space(al), "select") ||
		   strings.contains(al, "show ") ||
		   strings.contains(al, "describe ") ||
		   strings.contains(al, "desc ") ||
		   strings.contains(al, "explain ") ||
		   strings.contains(al, "with ") {
			return true
		}
		return false
	}
	return false
}

// B46: curl GET/HEAD inspect only (no body upload, no -o write, no POST).
// args is everything after the program name (no leading "curl ").
bash_curl_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false
	}
	if a == "--version" ||
	   a == "-V" ||
	   strings.has_prefix(a, "--version ") ||
	   strings.has_prefix(a, "-V ") ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "--help ") {
		// note: do not treat bare "-h " as always help (rare host flag); only exact -h
		return true
	}
	// Token walk for deny flags (handles leading -o without prior space)
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		rest = rem
		tl := strings.to_lower(tok, context.temp_allocator)
		// write / upload / non-GET methods
		if tok == "-o" ||
		   tok == "-O" ||
		   tok == "-J" ||
		   tok == "-d" ||
		   tok == "-F" ||
		   tok == "-T" ||
		   tok == "-c" ||
		   tok == "-K" ||
		   strings.has_prefix(tok, "-o") && len(tok) > 2 || // -oout
		   strings.has_prefix(tok, "-O") && len(tok) > 2 ||
		   strings.has_prefix(tok, "-d") && len(tok) > 2 ||
		   strings.has_prefix(tl, "--data") ||
		   strings.has_prefix(tl, "--form") ||
		   strings.has_prefix(tl, "--upload") ||
		   strings.has_prefix(tl, "--output") ||
		   strings.has_prefix(tl, "--remote-name") ||
		   strings.has_prefix(tl, "--remote-header-name") ||
		   strings.has_prefix(tl, "--cookie-jar") ||
		   strings.has_prefix(tl, "--config") {
			return false
		}
		if tok == "-X" || tl == "--request" {
			m, rem2 := first_shell_token(rest)
			rest = rem2
			ml := strings.to_lower(m, context.temp_allocator)
			if ml != "" && ml != "get" && ml != "head" {
				return false
			}
			continue
		}
		if strings.has_prefix(tl, "-x") && len(tl) > 2 {
			// -XPOST glued
			method := tl[2:]
			if method != "get" && method != "head" {
				return false
			}
			continue
		}
		if strings.has_prefix(tl, "--request=") {
			method := tl[len("--request="):]
			if method != "get" && method != "head" {
				return false
			}
			continue
		}
	}
	has_url :=
		strings.contains(a, "http://") ||
		strings.contains(a, "https://") ||
		strings.contains(a, "ftp://")
	if !has_url {
		return false
	}
	return true
}

// B51: HTTPie / xh GET/HEAD only (no POST body, no download -o).
// args after program name; method may be first token (GET/HEAD/POST…).
bash_httpie_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		// bare http/xh often shows help
		return true
	}
	if a == "--version" ||
	   a == "-V" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "--help ") ||
	   strings.has_prefix(a, "--version ") {
		return true
	}
	al := strings.to_lower(a, context.temp_allocator)
	// download / session write
	if strings.contains(a, " -o ") ||
	   strings.has_prefix(a, "-o ") ||
	   strings.contains(a, " --download") ||
	   strings.contains(a, " -d ") || // xh -d download
	   strings.has_prefix(a, "-d ") ||
	   strings.contains(a, " --output") ||
	   strings.contains(al, "--session") {
		return false
	}
	// method token
	method := ""
	rest := a
	tok, rem := first_shell_token(rest)
	if tok != "" {
		tl := strings.to_upper(tok, context.temp_allocator)
		if tl == "GET" ||
		   tl == "HEAD" ||
		   tl == "OPTIONS" ||
		   tl == "POST" ||
		   tl == "PUT" ||
		   tl == "PATCH" ||
		   tl == "DELETE" {
			method = tl
			rest = rem
		}
	}
	// body/form markers
	if strings.contains(a, "=") && method != "" && method != "GET" && method != "HEAD" && method != "OPTIONS" {
		// field=value often means body for POST
		return false
	}
	if method == "POST" || method == "PUT" || method == "PATCH" || method == "DELETE" {
		return false
	}
	// must have a URL
	has_url :=
		strings.contains(a, "http://") ||
		strings.contains(a, "https://") ||
		// httpie allows bare host:port/path as first non-method arg
		false
	if !has_url {
		// accept :port/path or example.com/… as first remaining token
		t2, _ := first_shell_token(rest)
		if t2 == "" || strings.has_prefix(t2, "-") {
			return false
		}
		// treat non-flag token as URL-ish target
		has_url = true
	}
	return has_url
}

// B46: wget spider/version or stdout (-O -); not file download / recursive write.
// args is everything after the program name.
bash_wget_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false
	}
	if a == "--version" ||
	   a == "-V" ||
	   strings.has_prefix(a, "--version ") ||
	   strings.has_prefix(a, "-V ") ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "--help ") {
		return true
	}
	al := strings.to_lower(a, context.temp_allocator)
	// spider is HEAD-like inspect
	if strings.contains(a, "--spider") {
		return true
	}
	// -O - or --output-document=- → stdout only
	if strings.has_prefix(a, "-O -") ||
	   strings.has_prefix(a, "-O-") ||
	   strings.contains(a, " -O -") ||
	   strings.contains(a, " -O-") ||
	   strings.contains(a, "--output-document=-") ||
	   strings.contains(a, "--output-document -") {
		if strings.contains(a, "--recursive") ||
		   strings.contains(a, " -r ") ||
		   strings.has_prefix(a, "-r ") ||
		   strings.contains(a, "--mirror") ||
		   strings.contains(al, "--post-data") ||
		   strings.contains(al, "--post-file") ||
		   strings.contains(al, "--method=post") {
			return false
		}
		return strings.contains(a, "http://") || strings.contains(a, "https://") || strings.contains(a, "ftp://")
	}
	return false
}

// B46: ffprobe always inspect (media metadata); bare ok.
bash_ffprobe_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	// ffprobe never mutates media; allow even bare (prints help) and any probe flags
	_ = a
	return true
}

// B49: ffmpeg probe via -i only (no encode/output file).
// Typical inspect: ffmpeg -i file.mp4  (exits non-zero; still metadata on stderr)
bash_ffmpeg_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		// bare ffmpeg → help/banner
		return true
	}
	if a == "-version" ||
	   a == "-L" ||
	   a == "-h" ||
	   a == "-?" ||
	   strings.has_prefix(a, "-version ") ||
	   strings.has_prefix(a, "-h ") {
		return true
	}
	// encode / write signals
	al := strings.to_lower(a, context.temp_allocator)
	deny := []string {
		"-c:v",
		"-c:a",
		"-codec",
		"-vcodec",
		"-acodec",
		"-map",
		"-filter",
		"-vf",
		"-af",
		"-ss", // can be used with -i only for seek-probe; still often encode — fail closed if -to/-t with output
		"-y", // overwrite output
		"-f ",
		" nullsrc",
		" lavfi",
	}
	// allow -f null - as pure probe sink? still unusual — fail closed on -f unless null
	for d in deny {
		if d == "-ss" {
			continue // -ss alone with -i is ok for probe
		}
		if strings.contains(al, d) {
			// -f null is inspect sink
			if d == "-f " && (strings.contains(al, "-f null") || strings.contains(al, "-fnull")) {
				continue
			}
			if d == "-y" || d == "-map" || d == "-c:v" || d == "-c:a" || d == "-codec" ||
			   d == "-vcodec" || d == "-acodec" || d == "-filter" || d == "-vf" || d == "-af" {
				return false
			}
		}
	}
	// must have -i <input>
	rest := a
	saw_i := false
	bare_paths := 0
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		rest = rem
		if tok == "-i" {
			// consume input path
			inp, rem2 := first_shell_token(rest)
			rest = rem2
			if inp == "" {
				return false
			}
			saw_i = true
			continue
		}
		if strings.has_prefix(tok, "-i") && len(tok) > 2 {
			// -ifile glued
			saw_i = true
			continue
		}
		// harmless probe flags
		if tok == "-hide_banner" ||
		   tok == "-nostdin" ||
		   tok == "-v" ||
		   tok == "-loglevel" ||
		   strings.has_prefix(tok, "-loglevel=") ||
		   tok == "-f" {
			if tok == "-v" || tok == "-loglevel" || tok == "-f" {
				_, rest2 := first_shell_token(rest)
				rest = rest2
			}
			continue
		}
		if strings.has_prefix(tok, "-") {
			// unknown flag — fail closed for safety
			// allow a few more probe-only
			if tok == "-ss" || tok == "-t" || tok == "-to" {
				_, rest2 := first_shell_token(rest)
				rest = rest2
				continue
			}
			return false
		}
		// bare path without being -i value → output destination
		bare_paths += 1
	}
	if bare_paths > 0 {
		return false
	}
	return saw_i
}

// B54: nix inspect (flake show/metadata/search; not build/run/shell/eval).
bash_nix_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		// bare nix → help
		return true
	}
	if a == "--version" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "--version ") ||
	   strings.has_prefix(a, "--help ") ||
	   strings.has_prefix(a, "-h ") {
		return true
	}
	// peel experimental flags
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "--extra-experimental-features" ||
		   tok == "--experimental-features" ||
		   tok == "-L" ||
		   tok == "--print-build-logs" {
			if tok == "--extra-experimental-features" || tok == "--experimental-features" {
				_, rest2 := first_shell_token(rem)
				rest = rest2
				continue
			}
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "--extra-experimental-features=") ||
		   strings.has_prefix(tok, "--experimental-features=") {
			rest = rem
			continue
		}
		// first real subcommand
		return bash_nix_subcommand_is_readonly(tok, rem)
	}
}

bash_nix_subcommand_is_readonly :: proc(sub, rest: string) -> bool {
	switch sub {
	case "help", "--help", "-h", "--version":
		return true
	case "flake":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		// show/metadata/check/info are inspect; update/lock/init mutate
		return bash_token_in(
			sub2,
			[]string{"show", "metadata", "check", "info", "archive", "prefetch"},
		)
		// note: prefetch downloads to store — still relatively inspect; allow
	case "search":
		return true
	case "path-info", "why-depends", "log", "show-config", "show-derivation", "hash", "nar":
		return true
	case "store":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		// delete/gc/optimise mutate; ls/ping/diff-closures inspect
		return bash_token_in(
			sub2,
			[]string{"ls", "path-from-hash-part", "ping", "diff-closures"},
		)
	case "registry":
		sub2, _ := first_shell_token(rest)
		return sub2 == "list" || sub2 == "" || sub2 == "--help" || sub2 == "help"
	case "profile":
		sub2, _ := first_shell_token(rest)
		return sub2 == "list" || sub2 == "diff-closures" || sub2 == "history" || sub2 == "" || sub2 == "--help"
	case "config":
		sub2, _ := first_shell_token(rest)
		return sub2 == "show" || sub2 == "" || sub2 == "--help" || sub2 == "help"
	case "doctor":
		return true
	case "repl", "build", "run", "develop", "shell", "eval", "print-dev-env", "copy",
	     "copy-sigs", "sign-paths", "verify", "collect-garbage", "upgrade-nix":
		return false
	}
	return false
}

// Legacy nix-* CLIs: version/help/query only (install/upgrade mutate).
bash_nix_legacy_is_readonly :: proc(prog, args: string) -> bool {
	a := strings.trim_space(args)
	// bare nix-shell / nixos-rebuild starts work — fail closed
	if a == "" {
		return prog != "nix-shell" && prog != "nixos-rebuild"
	}
	if a == "--version" ||
	   a == "--help" ||
	   a == "-h" ||
	   a == "-V" ||
	   strings.has_prefix(a, "--version") ||
	   strings.has_prefix(a, "--help") {
		return true
	}
	// nix-env -q / --query is inspect
	if prog == "nix-env" {
		if strings.contains(a, " -q") ||
		   strings.has_prefix(a, "-q") ||
		   strings.contains(a, "--query") {
			return true
		}
	}
	if prog == "nix-channel" &&
	   (strings.contains(a, "--list") || a == "-l" || strings.has_prefix(a, "-l ")) {
		return true
	}
	return false
}

// B57: gcloud inspect (list/describe/get/info; not create/delete/deploy).
bash_gcloud_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		// bare gcloud — help-ish
		return true
	}
	if a == "help" ||
	   a == "version" ||
	   a == "info" ||
	   a == "--version" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") ||
	   strings.has_prefix(a, "info ") ||
	   strings.has_prefix(a, "--version") ||
	   strings.has_prefix(a, "--help") {
		return true
	}
	rest := a
	saw_inspect := false
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		// global / common flags that take a value
		if tok == "--project" ||
		   tok == "--configuration" ||
		   tok == "--account" ||
		   tok == "--format" ||
		   tok == "--filter" ||
		   tok == "--limit" ||
		   tok == "--page-size" ||
		   tok == "--sort-by" ||
		   tok == "--verbosity" ||
		   tok == "--region" ||
		   tok == "--zone" ||
		   tok == "--billing-project" ||
		   tok == "--impersonate-service-account" ||
		   tok == "--log-http" {
			// --log-http is flag-only; others may take values
			if tok == "--log-http" {
				rest = rem
				continue
			}
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--project=") ||
		   strings.has_prefix(tok, "--configuration=") ||
		   strings.has_prefix(tok, "--account=") ||
		   strings.has_prefix(tok, "--format=") ||
		   strings.has_prefix(tok, "--filter=") ||
		   strings.has_prefix(tok, "--limit=") ||
		   strings.has_prefix(tok, "--page-size=") ||
		   strings.has_prefix(tok, "--sort-by=") ||
		   strings.has_prefix(tok, "--verbosity=") ||
		   strings.has_prefix(tok, "--region=") ||
		   strings.has_prefix(tok, "--zone=") ||
		   strings.has_prefix(tok, "--billing-project=") ||
		   strings.has_prefix(tok, "--impersonate-service-account=") {
			rest = rem
			continue
		}
		if tok == "--quiet" ||
		   tok == "-q" ||
		   tok == "--flatten" ||
		   tok == "--help" ||
		   tok == "-h" ||
		   tok == "--version" {
			rest = rem
			continue
		}
		// positional / group / command
		if strings.has_prefix(tok, "-") {
			// unknown flag — peel as flag-only (fail closed later if needed)
			rest = rem
			continue
		}
		t := strings.to_lower(tok, context.temp_allocator)
		// mutators fail closed
		if t == "create" ||
		   t == "delete" ||
		   t == "update" ||
		   t == "deploy" ||
		   t == "apply" ||
		   t == "set" ||
		   t == "add" ||
		   t == "remove" ||
		   t == "install" ||
		   t == "uninstall" ||
		   t == "start" ||
		   t == "stop" ||
		   t == "reset" ||
		   t == "resize" ||
		   t == "migrate" ||
		   t == "import" ||
		   t == "export" ||
		   t == "run" ||
		   t == "ssh" ||
		   t == "scp" ||
		   t == "mv" ||
		   t == "cp" ||
		   t == "rm" ||
		   t == "write" ||
		   t == "patch" ||
		   t == "replace" ||
		   t == "enable" ||
		   t == "disable" ||
		   t == "undelete" ||
		   t == "restore" ||
		   t == "submit" ||
		   t == "build" ||
		   t == "push" ||
		   t == "pull" ||
		   t == "copy-files" ||
		   t == "add-iam-policy-binding" ||
		   t == "remove-iam-policy-binding" ||
		   t == "set-iam-policy" ||
		   t == "login" ||
		   t == "logout" ||
		   t == "activate" ||
		   t == "revoke" ||
		   t == "init" ||
		   t == "compose" ||
		   t == "execute" ||
		   t == "cancel" ||
		   t == "kill" ||
		   strings.has_prefix(t, "set-") ||
		   strings.has_prefix(t, "add-") ||
		   strings.has_prefix(t, "remove-") ||
		   strings.has_prefix(t, "delete-") ||
		   strings.has_prefix(t, "create-") ||
		   strings.has_prefix(t, "update-") {
			return false
		}
		// known inspect verbs
		if t == "list" ||
		   t == "describe" ||
		   t == "get" ||
		   t == "get-value" ||
		   t == "get-iam-policy" ||
		   t == "info" ||
		   t == "version" ||
		   t == "help" ||
		   t == "ls" ||
		   t == "show" ||
		   t == "search" ||
		   t == "explain" ||
		   t == "print-access-token" ||
		   t == "print-identity-token" ||
		   t == "print-refresh-token" ||
		   t == "cat" ||
		   t == "read" ||
		   t == "count" ||
		   t == "find" ||
		   t == "topic" ||
		   t == "cheatsheet" ||
		   strings.has_prefix(t, "list-") ||
		   strings.has_prefix(t, "describe-") ||
		   strings.has_prefix(t, "get-") {
			saw_inspect = true
		}
		// group tokens (compute, config, auth, …) ignored — continue
		rest = rem
	}
	return saw_inspect
}

// B57: Azure CLI inspect (list/show/get; not create/delete/set).
bash_az_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "help" ||
	   a == "version" ||
	   a == "--version" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") ||
	   strings.has_prefix(a, "--version") ||
	   strings.has_prefix(a, "--help") {
		return true
	}
	// `az find QUERY` is search
	if strings.has_prefix(a, "find ") || a == "find" {
		return true
	}
	rest := a
	saw_inspect := false
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		// common az globals that take values
		if tok == "--subscription" ||
		   tok == "--resource-group" ||
		   tok == "-g" ||
		   tok == "--output" ||
		   tok == "-o" ||
		   tok == "--query" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if tok == "--only-show-errors" ||
		   tok == "--help" ||
		   tok == "-h" ||
		   tok == "--version" ||
		   tok == "--verbose" ||
		   tok == "--debug" {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "--subscription=") ||
		   strings.has_prefix(tok, "--resource-group=") ||
		   strings.has_prefix(tok, "--output=") ||
		   strings.has_prefix(tok, "--query=") ||
		   (strings.has_prefix(tok, "-g") && len(tok) > 2) ||
		   (strings.has_prefix(tok, "-o") && len(tok) > 2) {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		t := strings.to_lower(tok, context.temp_allocator)
		// mutators fail closed
		if t == "create" ||
		   t == "delete" ||
		   t == "update" ||
		   t == "set" ||
		   t == "remove" ||
		   t == "add" ||
		   t == "start" ||
		   t == "stop" ||
		   t == "restart" ||
		   t == "deallocate" ||
		   t == "deploy" ||
		   t == "apply" ||
		   t == "run" ||
		   t == "invoke" ||
		   t == "execute" ||
		   t == "upload" ||
		   t == "download" ||
		   t == "copy" ||
		   t == "move" ||
		   t == "rename" ||
		   t == "import" ||
		   t == "export" ||
		   t == "login" ||
		   t == "logout" ||
		   t == "purge" ||
		   t == "restore" ||
		   t == "enable" ||
		   t == "disable" ||
		   t == "attach" ||
		   t == "detach" ||
		   t == "assign" ||
		   t == "unassign" ||
		   t == "lock" ||
		   t == "unlock" ||
		   t == "wait" ||
		   t == "ssh" ||
		   t == "scp" ||
		   t == "run-command" ||
		   t == "install" ||
		   t == "uninstall" ||
		   t == "upgrade" ||
		   t == "register" ||
		   t == "unregister" ||
		   t == "clear" ||
		   t == "open" ||
		   t == "configure" ||
		   strings.has_prefix(t, "create-") ||
		   strings.has_prefix(t, "delete-") ||
		   strings.has_prefix(t, "update-") ||
		   strings.has_prefix(t, "set-") ||
		   strings.has_prefix(t, "add-") ||
		   strings.has_prefix(t, "remove-") {
			return false
		}
		// known inspect verbs (groups like vm/account pass through)
		if t == "list" ||
		   t == "show" ||
		   t == "get" ||
		   t == "get-access-token" ||
		   t == "version" ||
		   t == "help" ||
		   t == "find" ||
		   t == "check-name" ||
		   t == "self-test" ||
		   t == "feedback" ||
		   strings.has_prefix(t, "list-") ||
		   strings.has_prefix(t, "show-") ||
		   strings.has_prefix(t, "get-") {
			saw_inspect = true
		}
		rest = rem
	}
	return saw_inspect
}

// B56: aws CLI inspect (describe/list/get/sts identity; not create/delete/put).
bash_aws_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false
	}
	if a == "help" ||
	   a == "--version" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "--version") {
		return true
	}
	// peel global flags that take values
	rest := a
	svc := ""
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return false
		}
		if tok == "--profile" ||
		   tok == "--region" ||
		   tok == "--output" ||
		   tok == "--endpoint-url" ||
		   tok == "--no-paginate" ||
		   tok == "--color" ||
		   tok == "--cli-read-timeout" ||
		   tok == "--cli-connect-timeout" {
			if tok == "--no-paginate" {
				rest = rem
				continue
			}
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--profile=") ||
		   strings.has_prefix(tok, "--region=") ||
		   strings.has_prefix(tok, "--output=") ||
		   strings.has_prefix(tok, "--endpoint-url=") {
			rest = rem
			continue
		}
		if tok == "--debug" || tok == "--no-cli-pager" {
			rest = rem
			continue
		}
		// first non-global token is service
		svc = strings.to_lower(tok, context.temp_allocator)
		rest = rem
		break
	}
	if svc == "" || svc == "help" {
		return true
	}
	// operation
	op, op_rest := first_shell_token(rest)
	if op == "" || op == "help" {
		return true
	}
	op_l := strings.to_lower(op, context.temp_allocator)
	_ = op_rest

	// sts identity
	if svc == "sts" {
		return op_l == "get-caller-identity" ||
			op_l == "get-session-token" ||
			op_l == "get-access-key-info" ||
			op_l == "decode-authorization-message" ||
			op_l == "help"
	}
	// common read verbs across services
	if strings.has_prefix(op_l, "describe-") ||
	   strings.has_prefix(op_l, "list-") ||
	   strings.has_prefix(op_l, "get-") ||
	   strings.has_prefix(op_l, "head-") ||
	   op_l == "help" {
		// get-object downloads content — still "get" but mutates local if -o; treat as inspect of API (stdout)
		// create/delete/put prefixes fail closed via not matching
		return true
	}
	// s3 ls / s3api list-buckets style
	if svc == "s3" {
		return op_l == "ls" || op_l == "presign" || op_l == "help"
	}
	if svc == "s3api" {
		return strings.has_prefix(op_l, "list-") ||
			strings.has_prefix(op_l, "get-") ||
			strings.has_prefix(op_l, "head-") ||
			op_l == "help"
	}
	if svc == "iam" {
		return strings.has_prefix(op_l, "list-") ||
			strings.has_prefix(op_l, "get-") ||
			op_l == "help"
	}
	if svc == "ec2" || svc == "ecs" || svc == "eks" || svc == "lambda" || svc == "logs" ||
	   svc == "cloudformation" || svc == "route53" || svc == "rds" || svc == "dynamodb" {
		return strings.has_prefix(op_l, "describe-") ||
			strings.has_prefix(op_l, "list-") ||
			strings.has_prefix(op_l, "get-") ||
			op_l == "help"
	}
	return false
}

// B25: pytest collect/version/help only (not running tests).
bash_pytest_is_readonly :: proc(args: string) -> bool {
	// empty pytest runs tests
	if strings.trim_space(args) == "" {
		return false
	}
	rest := args
	saw_inspect := false
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		rest = rem
		if tok == "--collect-only" ||
		   tok == "--co" ||
		   tok == "--version" ||
		   tok == "--help" ||
		   tok == "-h" ||
		   tok == "-V" ||
		   tok == "--fixtures" ||
		   tok == "--markers" {
			saw_inspect = true
			continue
		}
		// common path/filter args for collection
		if tok == "-q" || tok == "--quiet" || tok == "-v" || tok == "--verbose" {
			continue
		}
		// bare path tokens for collect scope still inspect-ish if --collect-only present
		if strings.has_prefix(tok, "-") {
			// unknown flag → fail closed
			return false
		}
		// path / node id: only ok when we also saw collect/help/version
		continue
	}
	return saw_inspect
}

// B28: cmake help/version/find-package inspect (not configure/build/install).
bash_cmake_is_readonly :: proc(args: string) -> bool {
	if strings.trim_space(args) == "" {
		return false
	}
	rest := args
	saw_inspect := false
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		rest = rem
		switch tok {
		case "--help", "-h", "--version", "-version", "--help-command", "--help-commands",
		     "--help-module", "--help-modules", "--help-policy", "--help-variable",
		     "--help-variables", "--help-property", "--help-properties",
		     "--system-information", "-E":
			// cmake -E is the command-mode toolbox; allow list of inspect E-subcmds only
			if tok == "-E" {
				sub2, rem2 := first_shell_token(rest)
				rest = rem2
				// safe -E commands: capabilities, echo, env, cat, compare_files, …
				if bash_token_in(
					   sub2,
					   []string{
						   "capabilities",
						   "echo",
						   "env",
						   "environment",
						   "cat",
						   "compare_files",
						   "sha1sum",
						   "sha224sum",
						   "sha256sum",
						   "sha384sum",
						   "sha512sum",
						   "md5sum",
						   "true",
						   "false",
					   },
				   ) {
					saw_inspect = true
					continue
				}
				return false
			}
			saw_inspect = true
			continue
		case "--find-package", "--find-package-mode":
			// may still run package discovery; treat as inspect
			saw_inspect = true
			continue
		}
		// path-ish or unknown flags fail closed unless only after inspect flags
		if strings.has_prefix(tok, "-") {
			// allow -P? script mode can write — fail closed
			return false
		}
		// bare path without inspect → configure/build intent
		if !saw_inspect {
			return false
		}
	}
	return saw_inspect
}

// B28: ninja -t tools / -h / --version (not build).
bash_ninja_is_readonly :: proc(args: string) -> bool {
	if strings.trim_space(args) == "" {
		// bare ninja builds
		return false
	}
	rest := args
	saw_inspect := false
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		rest = rem
		if tok == "-h" || tok == "--help" || tok == "--version" || tok == "-v" {
			// -v is verbose build — fail closed
			if tok == "-v" {
				return false
			}
			saw_inspect = true
			continue
		}
		if tok == "-t" {
			// tool mode: list, targets, commands, query, graph, …
			sub2, rem2 := first_shell_token(rest)
			rest = rem2
			if bash_token_in(
				   sub2,
				   []string{
					   "list",
					   "targets",
					   "commands",
					   "query",
					   "graph",
					   "browse",
					   "deps",
					   "missingdeps",
					   "compdb",
					   "inputs",
				   },
			   ) {
				saw_inspect = true
				// remaining args are usually target names for query tools
				continue
			}
			return false
		}
		if strings.has_prefix(tok, "-") {
			return false
		}
		// bare targets without -t → build
		if !saw_inspect {
			return false
		}
	}
	return saw_inspect
}

// B28: meson introspect/configure --help (not compile/install).
bash_meson_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false
	}
	if bash_is_help_or_version(a) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(a)
	if !ok {
		return false
	}
	if sub == "introspect" {
		return true // all introspect subcommands read build dir
	}
	if sub == "configure" {
		// meson configure without -D is inspect; with -D can mutate options
		if strings.contains(rest, "-D") || strings.contains(rest, "--clearcache") {
			return false
		}
		return true
	}
	if bash_token_in(
		sub,
		[]string{"rewriter", "compile", "install", "test", "dist", "init", "setup", "subprojects"},
	) {
		return false
	}
	return false
}

// B33: GitHub CLI inspect (list/view/status/diff/search; not create/merge/push).
// https://cli.github.com — fail closed on api POST/graphql and mutating subcommands.
bash_gh_is_readonly :: proc(args: string) -> bool {
	rest := args
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			// bare `gh` prints help — inspect
			return true
		}
		// global value-taking flags
		if tok == "-R" ||
		   tok == "--repo" ||
		   tok == "--hostname" ||
		   tok == "--jq" ||
		   tok == "-q" ||
		   tok == "--template" ||
		   tok == "-t" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--repo=") ||
		   strings.has_prefix(tok, "--hostname=") ||
		   strings.has_prefix(tok, "--jq=") ||
		   strings.has_prefix(tok, "--template=") {
			rest = rem
			continue
		}
		// global help/version
		if tok == "--help" || tok == "-h" || tok == "--version" || tok == "help" || tok == "version" {
			return true
		}
		// first real subcommand
		return bash_gh_subcommand_is_readonly(tok, rem)
	}
}

bash_gh_subcommand_is_readonly :: proc(sub, rest: string) -> bool {
	switch sub {
	case "status", "search", "browse", "completion", "licenses":
		return true
	case "pr":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_token_in(sub2, []string{"list", "view", "status", "checks", "diff"})
	case "issue":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		// develop can create branches — not readonly
		return bash_token_in(sub2, []string{"list", "view", "status"})
	case "repo":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_token_in(sub2, []string{"view", "list"})
	case "run":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_token_in(sub2, []string{"list", "view"})
	case "workflow":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_token_in(sub2, []string{"list", "view"})
	case "release":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		// download writes files
		return bash_token_in(sub2, []string{"list", "view"})
	case "gist":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_token_in(sub2, []string{"list", "view"})
	case "auth":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return sub2 == "status"
	case "config":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_token_in(sub2, []string{"list", "get"})
	case "label":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return sub2 == "list"
	case "ruleset":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_token_in(sub2, []string{"list", "view", "check"})
	case "org":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return sub2 == "list"
	case "api":
		return bash_gh_api_is_readonly(rest)
	case "cache":
		sub2, _ := first_shell_token(rest)
		return sub2 == "list" || sub2 == "" || sub2 == "--help" || sub2 == "help"
	case "project":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_token_in(sub2, []string{"list", "view", "field-list", "item-list"})
	case "discussion":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_token_in(sub2, []string{"list", "view"})
	case "ssh-key", "gpg-key":
		sub2, _ := first_shell_token(rest)
		return sub2 == "list" || sub2 == "" || sub2 == "--help" || sub2 == "help"
	case "variable", "secret":
		// list/get only — set/delete mutate
		sub2, _ := first_shell_token(rest)
		return sub2 == "list" || sub2 == "get" || sub2 == "" || sub2 == "--help" || sub2 == "help"
	}
	return false
}

// gh api: allow GET/HEAD only; fields force POST in gh → fail closed; graphql is POST.
bash_gh_api_is_readonly :: proc(args: string) -> bool {
	rest := args
	method := "GET"
	saw_body := false
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		rest = rem
		if tok == "-X" || tok == "--method" {
			m, rem2 := first_shell_token(rest)
			rest = rem2
			if m != "" {
				method = m
			}
			continue
		}
		if strings.has_prefix(tok, "--method=") {
			method = tok[len("--method="):]
			continue
		}
		if strings.has_prefix(tok, "-X") && len(tok) > 2 {
			method = tok[2:]
			continue
		}
		// body / field flags → gh switches default method to POST
		if tok == "-f" ||
		   tok == "-F" ||
		   tok == "--raw-field" ||
		   tok == "--field" ||
		   tok == "--input" {
			saw_body = true
			_, rest2 := first_shell_token(rest)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "-f") ||
		   strings.has_prefix(tok, "-F") ||
		   strings.has_prefix(tok, "--raw-field=") ||
		   strings.has_prefix(tok, "--field=") ||
		   strings.has_prefix(tok, "--input=") {
			saw_body = true
			continue
		}
		// include response headers (not body input)
		if tok == "--include" || tok == "-i" || tok == "--paginate" || tok == "--slurp" ||
		   tok == "--silent" || tok == "--verbose" {
			continue
		}
		if tok == "--cache" ||
		   tok == "--jq" ||
		   tok == "-q" ||
		   tok == "--template" ||
		   tok == "-t" ||
		   tok == "--header" ||
		   tok == "-H" ||
		   tok == "--hostname" ||
		   tok == "--preview" ||
		   tok == "-p" {
			_, rest2 := first_shell_token(rest)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--cache=") ||
		   strings.has_prefix(tok, "--jq=") ||
		   strings.has_prefix(tok, "--template=") ||
		   strings.has_prefix(tok, "--header=") ||
		   strings.has_prefix(tok, "--hostname=") ||
		   strings.has_prefix(tok, "--preview=") {
			continue
		}
		if strings.has_prefix(tok, "--") || strings.has_prefix(tok, "-") {
			return false
		}
		// endpoint path
		if tok == "graphql" {
			return false
		}
	}
	ml := strings.to_lower(method, context.temp_allocator)
	if ml != "get" && ml != "head" {
		return false
	}
	if saw_body {
		return false
	}
	return true
}

// B31: just --list / --show / help (not recipe run).
// https://just.systems — bare `just` and `just RECIPE` execute; inspect flags only.
bash_just_is_readonly :: proc(args: string) -> bool {
	if strings.trim_space(args) == "" {
		// bare just runs default recipe
		return false
	}
	rest := args
	saw_inspect := false
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		rest = rem
		// config flags that take a value (path / shell / set) — peel, do not count as inspect alone
		if tok == "-f" ||
		   tok == "--justfile" ||
		   tok == "-d" ||
		   tok == "--working-directory" ||
		   tok == "--set" ||
		   tok == "--shell" ||
		   tok == "--shell-arg" ||
		   tok == "--dump-format" ||
		   tok == "--color" ||
		   tok == "--list-heading" ||
		   tok == "--list-prefix" ||
		   tok == "--timestamp-format" ||
		   tok == "--module-path" {
			_, rest2 := first_shell_token(rest)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--justfile=") ||
		   strings.has_prefix(tok, "--working-directory=") ||
		   strings.has_prefix(tok, "--set=") ||
		   strings.has_prefix(tok, "--color=") ||
		   strings.has_prefix(tok, "--dump-format=") ||
		   strings.has_prefix(tok, "--shell=") ||
		   (strings.has_prefix(tok, "-f") && len(tok) > 2) {
			continue
		}
		switch tok {
		case "--help", "-h", "--version", "--man",
		     "--list", "-l", "--summary", "--dump", "--evaluate", "--variables",
		     "--list-submodules", "--unsorted":
			saw_inspect = true
			continue
		case "--show", "-s":
			name, rem2 := first_shell_token(rest)
			rest = rem2
			if name == "" || strings.has_prefix(name, "-") {
				return false
			}
			saw_inspect = true
			continue
		case "--completions":
			shell, rem2 := first_shell_token(rest)
			rest = rem2
			if shell == "" {
				return false
			}
			saw_inspect = true
			continue
		case "--edit", "--fmt", "--init", "--command", "-c", "--chooser",
		     "--check", "--yes", "--dry-run", "--verbose", "-v", "--quiet", "-q",
		     "--clear-shell-args", "--one", "--unstable", "--highlight",
		     "--no-highlight", "--no-aliases":
			// run/mutate — fail closed
			return false
		}
		if strings.has_prefix(tok, "-") {
			return false
		}
		// bare recipe name → executes
		return false
	}
	return saw_inspect
}

bash_git_is_readonly :: proc(args: string) -> bool {
	sub, rest := first_shell_token(args)
	// peel common global flags: -C, -c, --no-pager, --git-dir, etc.
	for {
		if sub == "" {
			return true
		}
		if sub == "-C" || sub == "--git-dir" || sub == "--work-tree" || sub == "-c" {
			_, rest2 := first_shell_token(rest)
			sub, rest = first_shell_token(rest2)
			continue
		}
		if strings.has_prefix(sub, "-c") && strings.contains(sub, "=") {
			sub, rest = first_shell_token(rest)
			continue
		}
		if sub == "--no-pager" ||
		   sub == "--paginate" ||
		   sub == "-p" ||
		   sub == "--no-optional-locks" {
			sub, rest = first_shell_token(rest)
			continue
		}
		break
	}
	switch sub {
	case "status", "branch", "log", "diff", "show", "ls-files", "ls-tree",
	     "rev-parse", "describe", "blame", "shortlog", "reflog", "name-rev",
	     "cat-file", "grep", "whatchanged", "range-diff", "cherry", "version",
	     "help", "var", "check-ignore", "check-attr", "check-mailmap",
	     "count-objects", "fsck", "verify-pack", "rev-list", "show-branch",
	     "show-ref", "symbolic-ref", "for-each-ref", "ls-remote":
		return true
	case "config":
		// only get/list forms
		return strings.contains(rest, "--get") ||
			strings.contains(rest, "--list") ||
			strings.contains(rest, " -l") ||
			strings.has_prefix(strings.trim_space(rest), "-l")
	case "stash":
		return rest == "" ||
			strings.has_prefix(rest, "list") ||
			strings.has_prefix(rest, "show")
	case "remote":
		return rest == "" ||
			strings.has_prefix(rest, "-v") ||
			strings.has_prefix(rest, "show") ||
			strings.has_prefix(rest, "get-url")
	case "tag":
		return rest == "" ||
			strings.has_prefix(rest, "-l") ||
			strings.contains(rest, "--list")
	case "worktree":
		sub2, _ := first_shell_token(rest)
		return sub2 == "" || sub2 == "list" || sub2 == "prune"
	case "archive":
		// allow stdout-only; block -o / --output file write
		return !strings.contains(rest, " -o") &&
			!strings.contains(rest, "--output") &&
			!strings.has_prefix(strings.trim_space(rest), "-o")
	}
	return false
}
