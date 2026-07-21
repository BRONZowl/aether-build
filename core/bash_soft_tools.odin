// Soft bash readonly helpers — Lang runtimes, DBs, HTTP, git, nix, aws (bundler..end).
// Same package core — symbols used by bash_program_is_readonly.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:strings"

// B66: Bundler inspect (list/show/check/outdated/env; not install/exec/update).
BUNDLE_VALUE_FLAGS := [?]string{"--gemfile", "--path", "--binstubs"}
BUNDLE_ALLOW := [?]string {
	"list", "show", "info", "check", "outdated", "env", "platform", "doctor",
	"help", "version", "viz", "licenses", "why",
}
BUNDLE_DENY := [?]string {
	"install", "update", "exec", "add", "remove", "clean", "package", "pack",
	"binstubs", "init", "inject", "open", "console", "lock", "cache", "pristine",
	"plugin", "fund", "issue",
}
BUNDLE_CONFIG_ALLOW := [?]string{"list", "get"}
BUNDLE_NESTED := [?]Cli_Nested{{sub = "config", allow = BUNDLE_CONFIG_ALLOW[:]}}
BUNDLE_READONLY_SPEC := Cli_Readonly_Spec {
	value_flags   = BUNDLE_VALUE_FLAGS[:],
	allow_subs    = BUNDLE_ALLOW[:],
	deny_subs     = BUNDLE_DENY[:],
	nested        = BUNDLE_NESTED[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_bundle_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, BUNDLE_READONLY_SPEC)
}

// B66: rake task listing only (-T/-D/-P/…); bare rake runs default task → ask.
RAKE_VALUE_FLAGS := [?]string{"-f", "--rakefile", "-I", "--libdir", "-R", "--rakelibdir"}
RAKE_INSPECT_FLAGS := [?]string {
	"-T", "--tasks", "-D", "--describe", "-P", "--prereqs", "-W", "--where",
	"--version", "-V", "--help", "-h", "-A", "--all",
}

bash_rake_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false
	}
	if bash_token_in(a, RAKE_INSPECT_FLAGS[:]) {
		return true
	}
	rest := a
	saw_inspect := false
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		if bash_token_in(tok, RAKE_VALUE_FLAGS[:]) {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "-f") && len(tok) > 2 {
			rest = rem
			continue
		}
		if bash_token_in(tok, RAKE_INSPECT_FLAGS[:]) || strings.has_prefix(tok, "-T") {
			saw_inspect = true
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		// positional task name → would run task
		return false
	}
	return saw_inspect
}

// B64: Composer inspect (show/search/outdated/validate; not install/require).
COMPOSER_ALLOW := [?]string {
	"show", "list", "search", "depends", "prohibits", "validate",
	"check-platform-reqs", "outdated", "why", "why-not", "licenses",
	"status", "about", "diagnose", "help", "suggests", "browse",
}
COMPOSER_DENY := [?]string {
	"install", "update", "require", "remove", "create-project",
	"dump-autoload", "dumpautoload", "clear-cache", "clearcache",
	"self-update", "selfupdate", "exec", "run-script", "run",
	"global", "config", "init", "archive", "fund", "bump", "reinstall",
}
COMPOSER_VALUE_FLAGS := [?]string{"--working-dir", "-d"}
COMPOSER_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = COMPOSER_ALLOW[:],
	deny_subs     = COMPOSER_DENY[:],
	value_flags   = COMPOSER_VALUE_FLAGS[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_composer_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "about" {
		return true
	}
	return bash_cli_is_readonly(args, COMPOSER_READONLY_SPEC)
}

// Homebrew subcommand tables.
BREW_MUTATE := [?]string {
	"install", "uninstall", "reinstall", "upgrade", "update", "cleanup", "untap",
	"link", "unlink", "pin", "unpin", "create", "edit", "extract", "bundle",
	"postinstall", "vendor-install", "shellenv", "autoupdate",
}
BREW_ALLOW := [?]string {
	"list", "ls", "info", "search", "outdated", "deps", "uses", "cat", "home", "desc",
	"leaves", "doctor", "missing", "livecheck", "options", "formulae", "casks", "help",
	"config", "env", "commands", "which", "--version", "version", "readall", "style",
	"audit", "log",
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
		if bash_token_in(sub, BREW_MUTATE[:]) {
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
		if bash_token_in(sub, BREW_ALLOW[:]) {
			return true
		}
		return false
	}
}

// B36: kubectl get/describe/logs/… + config view (not apply/delete/create).
KUBECTL_ALLOW_SUBS := [?]string {
	"get", "logs", "describe", "top", "api-resources", "api-versions",
	"explain", "cluster-info", "auth", "diff", "wait", "version", "help",
}
KUBECTL_CONFIG_ALLOW := [?]string {
	"view", "get-contexts", "current-context", "get-clusters", "get-users",
}
KUBECTL_NESTED := [?]Cli_Nested{{sub = "config", allow = KUBECTL_CONFIG_ALLOW[:]}}
KUBECTL_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = KUBECTL_ALLOW_SUBS[:],
	nested        = KUBECTL_NESTED[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_kubectl_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, KUBECTL_READONLY_SPEC)
}

// B36: terraform / tofu inspect (not apply/destroy/import).
TF_VALUE_FLAGS := [?]string{"-chdir"}
TF_ALLOW := [?]string {
	"validate", "providers", "output", "show", "graph", "metadata", "version", "help",
}
TF_STATE := [?]string{"list", "show", "pull"}
TF_WS := [?]string{"list", "show"}
TF_NESTED := [?]Cli_Nested {
	{sub = "state", allow = TF_STATE[:]},
	{sub = "workspace", allow = TF_WS[:]},
}
TF_READONLY_SPEC := Cli_Readonly_Spec {
	value_flags   = TF_VALUE_FLAGS[:],
	allow_subs    = TF_ALLOW[:],
	nested        = TF_NESTED[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_terraform_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if bash_is_help_or_version(a) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(a, TF_VALUE_FLAGS[:])
	if ok && sub == "fmt" {
		// only check/diff modes; bare fmt rewrites files
		if strings.contains(rest, "-check") || strings.contains(rest, "-diff") {
			if strings.contains(rest, "-write=true") {
				return false
			}
			return true
		}
		return false
	}
	if ok && sub == "plan" {
		// plan inspect unless -out / generate-config-out write artifacts
		if strings.contains(rest, "-out") || strings.contains(rest, "-generate-config-out") {
			return false
		}
		return true
	}
	return bash_cli_is_readonly(args, TF_READONLY_SPEC)
}

// B36: helm list/status/get/template/lint (not install/upgrade/uninstall).
HELM_ALLOW_SUBS := [?]string {
	"list", "ls", "status", "history", "get", "show", "search", "lint", "template", "env",
}
HELM_LIST_ALLOW := [?]string{"list", "ls"}
HELM_EMPTY_ALLOW := [?]string{} // nested: empty/help only
HELM_NESTED := [?]Cli_Nested {
	{sub = "dependency", allow = HELM_LIST_ALLOW[:]},
	{sub = "deps", allow = HELM_LIST_ALLOW[:]},
	{sub = "repo", allow = HELM_LIST_ALLOW[:]},
	{sub = "plugin", allow = HELM_LIST_ALLOW[:]},
	{sub = "registry", allow = HELM_EMPTY_ALLOW[:]},
}
HELM_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = HELM_ALLOW_SUBS[:],
	nested        = HELM_NESTED[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_helm_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, HELM_READONLY_SPEC)
}

// B35: docker inspect + compose inspect (not run/up/build/exec).
DOCKER_ALLOW_SUBS := [?]string {
	"ps", "images", "logs", "inspect", "top", "stats", "port", "diff", "info",
}
DOCKER_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = DOCKER_ALLOW_SUBS[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_docker_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if bash_is_help_or_version(a) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(a)
	if !ok {
		return true
	}
	// plugin-style: docker compose …
	if sub == "compose" {
		return bash_docker_compose_is_readonly(rest)
	}
	return bash_cli_is_readonly(args, DOCKER_READONLY_SPEC)
}

// docker compose / docker-compose: list/config/ps/logs/images/top/version only.
DOCKER_COMPOSE_ALLOW := [?]string {
	"ps", "ls", "list", "config", "images", "logs", "top", "port", "events", "wait",
}
DOCKER_COMPOSE_VALUE_FLAGS := [?]string {
	"-f", "--file", "-p", "--project-name", "--profile", "--project-directory",
	"--env-file", "--ansi", "--progress",
}
DOCKER_COMPOSE_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = DOCKER_COMPOSE_ALLOW[:],
	value_flags   = DOCKER_COMPOSE_VALUE_FLAGS[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_docker_compose_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, DOCKER_COMPOSE_READONLY_SPEC)
}

// B16: cargo read-only / non-mutating inspection (no build/test/run).
CARGO_VALUE_FLAGS := [?]string {
	"-C", "--manifest-path", "--config", "--color", "-Z", "--target-dir",
}
CARGO_ALLOW_SUBS := [?]string {
	"check", "metadata", "tree", "search", "help", "version",
	"locate-project", "verify-project", "pkgid", "info", "fetch",
}
CARGO_READONLY_SPEC := Cli_Readonly_Spec {
	value_flags   = CARGO_VALUE_FLAGS[:],
	allow_subs    = CARGO_ALLOW_SUBS[:],
	empty_args_ok = true, // bare cargo / peeled flags only → allow (bash_sub_readonly peel_fail true)
	peel_fail_ok  = true,
}

bash_cargo_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, CARGO_READONLY_SPEC)
}

// npm/pnpm/yarn: inspection only (not install/run/build — those write or execute project code).
NPM_VALUE_FLAGS := [?]string{"--prefix", "--cwd", "-C", "--dir"}
NPM_ALLOW_SUBS := [?]string {
	"list", "ls", "ll", "la", "outdated", "why", "view", "info", "show",
	"audit", "version", "help", "explain", "query", "root", "bin", "prefix",
	"doctor", "fund", "search", "repo", "docs", "home", "bugs",
}
NPM_CONFIG_ALLOW := [?]string{"get", "list", "ls"}
NPM_CONFIG_NESTED := [?]Cli_Nested{{sub = "config", allow = NPM_CONFIG_ALLOW[:]}}
NPM_READONLY_SPEC := Cli_Readonly_Spec {
	value_flags   = NPM_VALUE_FLAGS[:],
	allow_subs    = NPM_ALLOW_SUBS[:],
	nested        = NPM_CONFIG_NESTED[:],
	empty_args_ok = false,
	peel_fail_ok  = false,
}

bash_npm_family_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, NPM_READONLY_SPEC)
}

// B38: bun inspect (not install/run/test/build).
BUN_ALLOW_SUBS := [?]string{"pm", "outdated", "why", "info"}
BUN_DENY_SUBS := [?]string{"x"}
BUN_PM_ALLOW := [?]string{"ls", "list", "whoami", "hash", "cache", "version", "pkg", "view", "why"}
BUN_PM_NESTED := [?]Cli_Nested {
	{sub = "pm", allow = BUN_PM_ALLOW[:]},
}
BUN_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = BUN_ALLOW_SUBS[:],
	deny_subs     = BUN_DENY_SUBS[:],
	nested        = BUN_PM_NESTED[:],
	empty_args_ok = false,
	peel_fail_ok  = false,
}

bash_bun_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, BUN_READONLY_SPEC)
}

// B38: deno inspect (not run/test/install/compile/cache).
DENO_ALLOW := [?]string{"info", "doc", "lint", "check", "types", "version", "help"}
DENO_DENY := [?]string{"bench", "coverage", "jupyter"}
DENO_TASK_ALLOW := [?]string{"list"}
DENO_NESTED := [?]Cli_Nested{{sub = "task", allow = DENO_TASK_ALLOW[:]}}
DENO_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = DENO_ALLOW[:],
	deny_subs     = DENO_DENY[:],
	nested        = DENO_NESTED[:],
	empty_args_ok = false,
	peel_fail_ok  = false,
}

bash_deno_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false
	}
	if bash_is_help_or_version(a) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(a)
	if ok && sub == "fmt" {
		// only --check; bare fmt rewrites
		return strings.contains(rest, "--check")
	}
	return bash_cli_is_readonly(args, DENO_READONLY_SPEC)
}

// B38: poetry inspect (not install/add/run/update).
POETRY_ALLOW := [?]string{"show", "check", "list", "search", "debug", "version", "help", "about"}
POETRY_ENV := [?]string{"info", "list"}
POETRY_NESTED := [?]Cli_Nested{{sub = "env", allow = POETRY_ENV[:]}}
POETRY_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = POETRY_ALLOW[:],
	nested        = POETRY_NESTED[:],
	empty_args_ok = false,
	peel_fail_ok  = false,
}

bash_poetry_config_is_readonly :: proc(rest: string) -> bool {
	// config --list / get only; config set mutates
	if rest == "" ||
	   strings.contains(rest, "--list") ||
	   strings.has_prefix(strings.trim_space(rest), "--list") {
		return true
	}
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
		// export writes to stdout by default — allow unless -o/--output
		if strings.contains(rest, " -o ") || strings.contains(rest, "--output") {
			return false
		}
		return true
	}
	if sub == "config" {
		return bash_poetry_config_is_readonly(rest)
	}
	if sub == "lock" {
		// lock --check is inspect; bare lock may rewrite
		return strings.contains(rest, "--check")
	}
	return bash_cli_is_readonly(args, POETRY_READONLY_SPEC)
}

// uv inspection (not sync/add/run/build/venv).
UV_ALLOW_SUBS := [?]string{"tree", "version", "help"}
UV_PIP_ALLOW := [?]string{"list", "show", "freeze", "check", "tree", "help"}
UV_PYTHON_ALLOW := [?]string{"list", "find", "dir", "help"}
UV_CACHE_ALLOW := [?]string{"dir", "size", "help"}
UV_SELF_ALLOW := [?]string{"version", "help"}
UV_NESTED := [?]Cli_Nested {
	{sub = "pip", allow = UV_PIP_ALLOW[:]},
	{sub = "python", allow = UV_PYTHON_ALLOW[:]},
	{sub = "cache", allow = UV_CACHE_ALLOW[:]},
	{sub = "self", allow = UV_SELF_ALLOW[:]},
}
UV_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = UV_ALLOW_SUBS[:],
	nested        = UV_NESTED[:],
	empty_args_ok = false,
	peel_fail_ok  = false,
}

bash_uv_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, UV_READONLY_SPEC)
}

// rustup inspection / list (not update/default that mutates toolchain install — update mutates).
// Keep only show/which/doc/help and list-style under toolchain/target/component.
RUSTUP_ALLOW_SUBS := [?]string{"show", "which", "doc", "help", "completions"}
RUSTUP_LIST_ALLOW := [?]string{"list"}
RUSTUP_NESTED := [?]Cli_Nested {
	{sub = "toolchain", allow = RUSTUP_LIST_ALLOW[:]},
	{sub = "target", allow = RUSTUP_LIST_ALLOW[:]},
	{sub = "component", allow = RUSTUP_LIST_ALLOW[:]},
	{sub = "override", allow = RUSTUP_LIST_ALLOW[:]},
}
RUSTUP_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = RUSTUP_ALLOW_SUBS[:],
	nested        = RUSTUP_NESTED[:],
	empty_args_ok = false,
	peel_fail_ok  = false,
}

bash_rustup_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, RUSTUP_READONLY_SPEC)
}

// pip inspection only.
PIP_ALLOW_SUBS := [?]string{"list", "show", "freeze", "check", "index", "help", "debug", "hash", "inspect"}
PIP_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = PIP_ALLOW_SUBS[:],
	empty_args_ok = false,
	peel_fail_ok  = false,
}

bash_pip_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, PIP_READONLY_SPEC)
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
GO_ALLOW_SUBS := [?]string{"version", "env", "help", "doc", "list"}
GO_MOD_ALLOW := [?]string{"graph", "why", "verify"}
GO_NESTED := [?]Cli_Nested{{sub = "mod", allow = GO_MOD_ALLOW[:]}}
GO_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = GO_ALLOW_SUBS[:],
	nested        = GO_NESTED[:],
	empty_args_ok = false,
	peel_fail_ok  = false,
}

bash_go_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, GO_READONLY_SPEC)
}

// B25: make help / dry-run / version only (not build targets).
// With -n/--dry-run/help/version, target names are OK (no side effects for dry-run).
MAKE_INSPECT_FLAGS := [?]string {
	"help", "--help", "-h", "-n", "--dry-run", "--just-print", "--recon", "--version",
}
MAKE_VALUE_FLAGS := [?]string{"-f", "--file", "--makefile"}
MAKE_HARMLESS_FLAGS := [?]string{"-q", "--quiet", "-s", "--silent"}

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
		if bash_token_in(tok, MAKE_INSPECT_FLAGS[:]) {
			saw_inspect = true
			continue
		}
		// allow -f Makefile with value
		if bash_token_in(tok, MAKE_VALUE_FLAGS[:]) {
			_, rest2 := first_shell_token(rest)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "-f") && len(tok) > 2 {
			continue
		}
		// harmless listing-ish
		if bash_token_in(tok, MAKE_HARMLESS_FLAGS[:]) {
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
ODIN_ALLOW_SUBS := [?]string{"version", "help", "doc"}
ODIN_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = ODIN_ALLOW_SUBS[:],
	empty_args_ok = false,
	peel_fail_ok  = false,
}

bash_odin_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, ODIN_READONLY_SPEC)
}

// B40: zig version/env/ast-check/fmt --check (not build/run/test).
ZIG_ALLOW := [?]string{"version", "help", "env", "targets", "libc", "std-docs", "ast-check"}
ZIG_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = ZIG_ALLOW[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_zig_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if bash_is_help_or_version(a) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(a)
	if ok && sub == "fmt" {
		// only --check; bare fmt rewrites
		return strings.contains(rest, "--check")
	}
	return bash_cli_is_readonly(args, ZIG_READONLY_SPEC)
}

// B42: swift package inspect (not build/run/test/package resolve).
SWIFT_PKG_ALLOW := [?]string {
	"describe", "show-dependencies", "show-executables", "dump-package",
	"dump-symbol-graph", "tools-version", "completion-tool",
}

bash_swift_package_is_readonly :: proc(rest: string) -> bool {
	sub2, rest2 := first_shell_token(rest)
	n := strings.to_lower(sub2, context.temp_allocator)
	if n == "" || n == "--help" || n == "help" || n == "-h" {
		return true
	}
	if n == "plugin" {
		sub3, _ := first_shell_token(rest2)
		p := strings.to_lower(sub3, context.temp_allocator)
		return p == "" || p == "--list" || p == "list" || p == "--help" || p == "help" || p == "-h"
	}
	return bash_token_in(n, SWIFT_PKG_ALLOW[:])
}

bash_swift_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false
	}
	if a == "-version" || bash_is_help_or_version(a) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(a)
	if !ok {
		return false
	}
	if sub == "package" {
		return bash_swift_package_is_readonly(rest)
	}
	return false
}

// B42: dotnet info/list (not build/run/test/new/restore).
DOTNET_TOOL := [?]string{"list"}
DOTNET_WL := [?]string{"list", "search"}
DOTNET_SDK := [?]string{"check"}
DOTNET_NESTED := [?]Cli_Nested {
	{sub = "tool", allow = DOTNET_TOOL[:]},
	{sub = "workload", allow = DOTNET_WL[:]},
	{sub = "sdk", allow = DOTNET_SDK[:]},
}
// allow empty list → unknown top-level fails closed except nested/nuget
DOTNET_READONLY_SPEC := Cli_Readonly_Spec {
	nested        = DOTNET_NESTED[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_dotnet_nuget_is_readonly :: proc(rest: string) -> bool {
	sub2, rest2 := first_shell_token(rest)
	n := strings.to_lower(sub2, context.temp_allocator)
	if n == "list" || n == "locals" {
		if n == "locals" && strings.contains(rest2, "--clear") {
			return false
		}
		return true
	}
	return n == "" || n == "--help" || n == "help" || n == "-h"
}

bash_dotnet_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "--info" ||
	   a == "--list-sdks" ||
	   a == "--list-runtimes" ||
	   bash_is_help_or_version(a) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(a)
	if ok && sub == "nuget" {
		return bash_dotnet_nuget_is_readonly(rest)
	}
	return bash_cli_is_readonly(args, DOTNET_READONLY_SPEC)
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
REDIS_HELP := [?]string{"--version", "-v", "--help"}
REDIS_VALUE_FLAGS := [?]string{"-h", "-p", "-n", "-a", "--user", "--pass", "-u"}
REDIS_BOOL_FLAGS := [?]string{"--tls", "--insecure"}
REDIS_ALLOW_CMDS := [?]string {
	"ping", "info", "dbsize", "get", "mget", "exists", "type", "ttl", "pttl",
	"strlen", "keys", "scan", "hlen", "hget", "hgetall", "hkeys", "hvals",
	"llen", "lrange", "scard", "smembers", "zcard", "zrange", "zscore",
	"client", "config", "memory", "slowlog", "time", "echo", "object", "randomkey",
}
REDIS_CLIENT_ALLOW := [?]string{"list", "info", "id", "getname", "help"}
REDIS_CONFIG_ALLOW := [?]string{"get", "help"}
REDIS_MEMORY_ALLOW := [?]string{"usage", "stats", "doctor", "help"}
REDIS_SLOWLOG_ALLOW := [?]string{"get", "len", "help"}

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
		if bash_token_in(tok, REDIS_HELP[:]) {
			return true
		}
		// host/port/db/auth flags with separate value
		if bash_token_in(tok, REDIS_VALUE_FLAGS[:]) {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if bash_token_in(tok, REDIS_BOOL_FLAGS[:]) {
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
		if !bash_token_in(cmd, REDIS_ALLOW_CMDS[:]) {
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
		return sub_l == "" || bash_token_in(sub_l, REDIS_CLIENT_ALLOW[:])
	case "config":
		return sub_l == "" || bash_token_in(sub_l, REDIS_CONFIG_ALLOW[:])
	case "memory":
		return sub_l == "" || bash_token_in(sub_l, REDIS_MEMORY_ALLOW[:])
	case "slowlog":
		return sub_l == "" || bash_token_in(sub_l, REDIS_SLOWLOG_ALLOW[:])
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
FFMPEG_HELP_FLAGS := [?]string{"-version", "-L", "-h", "-?"}
FFMPEG_ENCODE_DENY := [?]string {
	"-c:v", "-c:a", "-codec", "-vcodec", "-acodec", "-map",
	"-filter", "-vf", "-af", "-y",
}
FFMPEG_PROBE_VALUE_FLAGS := [?]string{"-v", "-loglevel", "-f", "-ss", "-t", "-to"}
FFMPEG_PROBE_FLAGS := [?]string{"-hide_banner", "-nostdin"}

bash_ffmpeg_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		// bare ffmpeg → help/banner
		return true
	}
	if bash_token_in(a, FFMPEG_HELP_FLAGS[:]) ||
	   strings.has_prefix(a, "-version ") ||
	   strings.has_prefix(a, "-h ") {
		return true
	}
	// encode / write signals (substring scan for multi-token forms)
	al := strings.to_lower(a, context.temp_allocator)
	for d in FFMPEG_ENCODE_DENY {
		if strings.contains(al, d) {
			return false
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
		if bash_token_in(tok, FFMPEG_PROBE_FLAGS[:]) || strings.has_prefix(tok, "-loglevel=") {
			continue
		}
		if bash_token_in(tok, FFMPEG_PROBE_VALUE_FLAGS[:]) {
			_, rest2 := first_shell_token(rest)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "-") {
			// unknown flag — fail closed for safety
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

NIX_TOP_ALLOW := [?]string {
	"help", "--help", "-h", "--version", "search", "path-info", "why-depends", "log",
	"show-config", "show-derivation", "hash", "nar", "doctor",
}
NIX_TOP_DENY := [?]string {
	"repl", "build", "run", "develop", "shell", "eval", "print-dev-env", "copy",
	"copy-sigs", "sign-paths", "verify", "collect-garbage", "upgrade-nix",
}
NIX_FLAKE := [?]string{"show", "metadata", "check", "info", "archive", "prefetch"}
NIX_STORE := [?]string{"ls", "path-from-hash-part", "ping", "diff-closures"}
NIX_REGISTRY := [?]string{"list"}
NIX_PROFILE := [?]string{"list", "diff-closures", "history"}
NIX_CONFIG := [?]string{"show"}
NIX_NESTED := [?]Cli_Nested {
	{sub = "flake", allow = NIX_FLAKE[:]},
	{sub = "store", allow = NIX_STORE[:]},
	{sub = "registry", allow = NIX_REGISTRY[:]},
	{sub = "profile", allow = NIX_PROFILE[:]},
	{sub = "config", allow = NIX_CONFIG[:]},
}

bash_nix_subcommand_is_readonly :: proc(sub, rest: string) -> bool {
	if bash_token_in(sub, NIX_TOP_ALLOW[:]) {
		return true
	}
	if bash_token_in(sub, NIX_TOP_DENY[:]) {
		return false
	}
	for n in NIX_NESTED {
		if n.sub == sub {
			return bash_cli_nested_match(rest, n)
		}
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

PYTEST_INSPECT_FLAGS := [?]string {
	"--collect-only", "--co", "--version", "--help", "-h", "-V",
	"--fixtures", "--markers", "-q", "--quiet", "-v", "--verbose",
}

// B25: pytest collect/version/help only (not running tests).
bash_pytest_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	// empty pytest runs tests
	if a == "" {
		return false
	}
	// must see an inspect flag; paths alone still run tests
	has_inspect := false
	for f in PYTEST_INSPECT_FLAGS {
		if f == "-q" || f == "--quiet" || f == "-v" || f == "--verbose" {
			continue
		}
		if strings.contains(a, f) {
			has_inspect = true
			break
		}
	}
	if !has_inspect {
		return false
	}
	// unknown flags (besides quiet/verbose and inspect) fail closed
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		rest = rem
		if !strings.has_prefix(tok, "-") {
			continue // path / node id ok when inspect present
		}
		if bash_token_in(tok, PYTEST_INSPECT_FLAGS[:]) {
			continue
		}
		return false
	}
	return true
}

CMAKE_E_SAFE := [?]string {
	"capabilities", "echo", "env", "environment", "cat", "compare_files",
	"sha1sum", "sha224sum", "sha256sum", "sha384sum", "sha512sum", "md5sum", "true", "false",
}
CMAKE_HELP_FLAGS := [?]string {
	"--help", "-h", "--version", "-version", "--help-command", "--help-commands",
	"--help-module", "--help-modules", "--help-policy", "--help-variable",
	"--help-variables", "--help-property", "--help-properties", "--system-information",
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
		if tok == "-E" {
			// cmake -E is the command-mode toolbox; allow list of inspect E-subcmds only
			sub2, rem2 := first_shell_token(rest)
			rest = rem2
			if bash_token_in(sub2, CMAKE_E_SAFE[:]) {
				saw_inspect = true
				continue
			}
			return false
		}
		if bash_token_in(tok, CMAKE_HELP_FLAGS[:]) ||
		   tok == "--find-package" ||
		   tok == "--find-package-mode" {
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

NINJA_TOOLS := [?]string {
	"list", "targets", "commands", "query", "graph", "browse", "deps", "missingdeps", "compdb", "inputs",
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
			if bash_token_in(sub2, NINJA_TOOLS[:]) {
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
MESON_ALLOW := [?]string{"introspect"}
MESON_DENY := [?]string {
	"rewriter", "compile", "install", "test", "dist", "init", "setup", "subprojects",
}
MESON_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = MESON_ALLOW[:],
	deny_subs     = MESON_DENY[:],
	empty_args_ok = false,
	peel_fail_ok  = false,
}

bash_meson_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false
	}
	if bash_is_help_or_version(a) {
		return true
	}
	sub, rest, ok := bash_peel_to_sub(a)
	if ok && sub == "configure" {
		// meson configure without -D is inspect; with -D can mutate options
		if strings.contains(rest, "-D") || strings.contains(rest, "--clearcache") {
			return false
		}
		return true
	}
	return bash_cli_is_readonly(args, MESON_READONLY_SPEC)
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

// Nested gh resource groups (list/view-style inspect only).
GH_TOP_ALLOW := [?]string{"status", "search", "browse", "completion", "licenses"}
GH_PR := [?]string{"list", "view", "status", "checks", "diff"}
GH_ISSUE := [?]string{"list", "view", "status"}
GH_REPO := [?]string{"view", "list"}
GH_RUN := [?]string{"list", "view"}
GH_WORKFLOW := [?]string{"list", "view"}
GH_RELEASE := [?]string{"list", "view"} // download writes files
GH_GIST := [?]string{"list", "view"}
GH_AUTH := [?]string{"status"}
GH_CONFIG := [?]string{"list", "get"}
GH_LABEL := [?]string{"list"}
GH_RULESET := [?]string{"list", "view", "check"}
GH_ORG := [?]string{"list"}
GH_CACHE := [?]string{"list"}
GH_PROJECT := [?]string{"list", "view", "field-list", "item-list"}
GH_DISCUSSION := [?]string{"list", "view"}
GH_KEY := [?]string{"list"}
GH_SECRET := [?]string{"list", "get"}
GH_NESTED := [?]Cli_Nested {
	{sub = "pr", allow = GH_PR[:]},
	{sub = "issue", allow = GH_ISSUE[:]},
	{sub = "repo", allow = GH_REPO[:]},
	{sub = "run", allow = GH_RUN[:]},
	{sub = "workflow", allow = GH_WORKFLOW[:]},
	{sub = "release", allow = GH_RELEASE[:]},
	{sub = "gist", allow = GH_GIST[:]},
	{sub = "auth", allow = GH_AUTH[:]},
	{sub = "config", allow = GH_CONFIG[:]},
	{sub = "label", allow = GH_LABEL[:]},
	{sub = "ruleset", allow = GH_RULESET[:]},
	{sub = "org", allow = GH_ORG[:]},
	{sub = "cache", allow = GH_CACHE[:]},
	{sub = "project", allow = GH_PROJECT[:]},
	{sub = "discussion", allow = GH_DISCUSSION[:]},
	{sub = "ssh-key", allow = GH_KEY[:]},
	{sub = "gpg-key", allow = GH_KEY[:]},
	{sub = "variable", allow = GH_SECRET[:]},
	{sub = "secret", allow = GH_SECRET[:]},
}

bash_gh_subcommand_is_readonly :: proc(sub, rest: string) -> bool {
	if sub == "api" {
		return bash_gh_api_is_readonly(rest)
	}
	if bash_token_in(sub, GH_TOP_ALLOW[:]) {
		return true
	}
	for n in GH_NESTED {
		if n.sub == sub {
			return bash_cli_nested_match(rest, n)
		}
	}
	return false
}

// gh api: allow GET/HEAD only; fields force POST in gh → fail closed; graphql is POST.
GH_API_BODY_FLAGS := [?]string{"-f", "-F", "--raw-field", "--field", "--input"}
GH_API_BODY_EQ_PREFIXES := [?]string{"--raw-field=", "--field=", "--input="}
GH_API_BOOL_FLAGS := [?]string{"--include", "-i", "--paginate", "--slurp", "--silent", "--verbose"}
GH_API_VALUE_FLAGS := [?]string {
	"--cache", "--jq", "-q", "--template", "-t", "--header", "-H",
	"--hostname", "--preview", "-p",
}
GH_API_VALUE_EQ_PREFIXES := [?]string {
	"--cache=", "--jq=", "--template=", "--header=", "--hostname=", "--preview=",
}
GH_API_RO_METHODS := [?]string{"get", "head"}

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
		if bash_token_in(tok, GH_API_BODY_FLAGS[:]) {
			saw_body = true
			_, rest2 := first_shell_token(rest)
			rest = rest2
			continue
		}
		body_eq := false
		for p in GH_API_BODY_EQ_PREFIXES {
			if strings.has_prefix(tok, p) {
				body_eq = true
				break
			}
		}
		if body_eq || strings.has_prefix(tok, "-f") || strings.has_prefix(tok, "-F") {
			saw_body = true
			continue
		}
		// include response headers (not body input)
		if bash_token_in(tok, GH_API_BOOL_FLAGS[:]) {
			continue
		}
		if bash_token_in(tok, GH_API_VALUE_FLAGS[:]) {
			_, rest2 := first_shell_token(rest)
			rest = rest2
			continue
		}
		value_eq := false
		for p in GH_API_VALUE_EQ_PREFIXES {
			if strings.has_prefix(tok, p) {
				value_eq = true
				break
			}
		}
		if value_eq {
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
	if !bash_token_in(ml, GH_API_RO_METHODS[:]) {
		return false
	}
	if saw_body {
		return false
	}
	return true
}

// B31: just --list / --show / help (not recipe run).
// https://just.systems — bare `just` and `just RECIPE` execute; inspect flags only.
JUST_VALUE_FLAGS := [?]string {
	"-f", "--justfile", "-d", "--working-directory", "--set", "--shell",
	"--shell-arg", "--dump-format", "--color", "--list-heading", "--list-prefix",
	"--timestamp-format", "--module-path",
}
JUST_VALUE_EQ_PREFIXES := [?]string {
	"--justfile=", "--working-directory=", "--set=", "--color=",
	"--dump-format=", "--shell=",
}
JUST_INSPECT_FLAGS := [?]string {
	"--help", "-h", "--version", "--man",
	"--list", "-l", "--summary", "--dump", "--evaluate", "--variables",
	"--list-submodules", "--unsorted",
}
JUST_SHOW_FLAGS := [?]string{"--show", "-s"}
JUST_MUTATE_FLAGS := [?]string {
	"--edit", "--fmt", "--init", "--command", "-c", "--chooser",
	"--check", "--yes", "--dry-run", "--verbose", "-v", "--quiet", "-q",
	"--clear-shell-args", "--one", "--unstable", "--highlight",
	"--no-highlight", "--no-aliases",
}

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
		if bash_token_in(tok, JUST_VALUE_FLAGS[:]) {
			_, rest2 := first_shell_token(rest)
			rest = rest2
			continue
		}
		eq_value := false
		for p in JUST_VALUE_EQ_PREFIXES {
			if strings.has_prefix(tok, p) {
				eq_value = true
				break
			}
		}
		if eq_value || (strings.has_prefix(tok, "-f") && len(tok) > 2) {
			continue
		}
		if bash_token_in(tok, JUST_INSPECT_FLAGS[:]) {
			saw_inspect = true
			continue
		}
		if bash_token_in(tok, JUST_SHOW_FLAGS[:]) {
			name, rem2 := first_shell_token(rest)
			rest = rem2
			if name == "" || strings.has_prefix(name, "-") {
				return false
			}
			saw_inspect = true
			continue
		}
		if tok == "--completions" {
			shell, rem2 := first_shell_token(rest)
			rest = rem2
			if shell == "" {
				return false
			}
			saw_inspect = true
			continue
		}
		if bash_token_in(tok, JUST_MUTATE_FLAGS[:]) {
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

GIT_ALLOW := [?]string {
	"status", "branch", "log", "diff", "show", "ls-files", "ls-tree",
	"rev-parse", "describe", "blame", "shortlog", "reflog", "name-rev",
	"cat-file", "grep", "whatchanged", "range-diff", "cherry", "version",
	"help", "var", "check-ignore", "check-attr", "check-mailmap",
	"count-objects", "fsck", "verify-pack", "rev-list", "show-branch",
	"show-ref", "symbolic-ref", "for-each-ref", "ls-remote",
}
GIT_WORKTREE := [?]string{"list", "prune"}

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
	if bash_token_in(sub, GIT_ALLOW[:]) {
		return true
	}
	switch sub {
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
		return bash_nested_allow(rest, GIT_WORKTREE[:])
	case "archive":
		// allow stdout-only; block -o / --output file write
		return !strings.contains(rest, " -o") &&
			!strings.contains(rest, "--output") &&
			!strings.has_prefix(strings.trim_space(rest), "-o")
	}
	return false
}
