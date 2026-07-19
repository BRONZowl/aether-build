// Package core — soft bash safety (A4 residual / Grok-shaped heuristics).
// 1) Hard-deny catastrophic patterns even under always-approve.
// 2) Auto-allow recognized read-only shell commands (skip Ask prompt).
// Opt out: AETHER_NO_BASH_SOFT=1  (env always wins over process toggle)
// Process: /soft-bash on|off (B48)
package core

import "core:os"
import "core:strings"

// Process override for soft bash (B48). Env kill-switch still wins when set.
Bash_Soft_Override :: enum {
	Unset,
	On,
	Off,
}

g_bash_soft_override: Bash_Soft_Override

bash_soft_enabled :: proc() -> bool {
	// Env kill-switch always wins (same as memory + AETHER_NO_*)
	v := os.get_env("AETHER_NO_BASH_SOFT", context.temp_allocator)
	if v == "1" || v == "true" || v == "yes" || v == "on" {
		return false
	}
	switch g_bash_soft_override {
	case .On:
		return true
	case .Off:
		return false
	case .Unset:
		return true // default on
	}
	return true
}

// bash_soft_set_process_enabled: /soft-bash on|off for this process.
// Returns false if env kill-switch blocks re-enable.
bash_soft_set_process_enabled :: proc(on: bool) -> bool {
	if on {
		v := os.get_env("AETHER_NO_BASH_SOFT", context.temp_allocator)
		if v == "1" || v == "true" || v == "yes" || v == "on" {
			return false
		}
		g_bash_soft_override = .On
		return true
	}
	g_bash_soft_override = .Off
	return true
}

bash_soft_clear_process_override :: proc() {
	g_bash_soft_override = .Unset
}

bash_soft_process_override_active :: proc() -> bool {
	return g_bash_soft_override != .Unset
}

// bash_hard_deny_reason: empty = ok; non-empty = deny (catastrophic).
bash_hard_deny_reason :: proc(command: string) -> string {
	if !bash_soft_enabled() || command == "" {
		return ""
	}
	blob := strings.to_lower(command, context.temp_allocator)
	// collapse spaces for some patterns
	compact, _ := strings.replace_all(blob, " ", "", context.temp_allocator)

	// catastrophic delete of filesystem root (not /tmp/… — check path after slash)
	if bash_looks_like_rm_root(blob) {
		return "hard-deny: recursive delete of filesystem root"
	}
	// fork bomb
	if strings.contains(blob, ":(){") || strings.contains(blob, ":(){:|:&};:") {
		return "hard-deny: fork bomb"
	}
	// disk wipe / raw write
	if strings.contains(blob, "mkfs") ||
	   strings.contains(blob, "dd if=") ||
	   strings.contains(blob, "dd of=/dev/") {
		return "hard-deny: disk wipe / raw device write"
	}
	// pipe to shell
	if (strings.contains(blob, "curl") ||
	    strings.contains(blob, "wget") ||
	    strings.contains(blob, "fetch")) &&
	   (strings.contains(blob, "| sh") ||
	    strings.contains(blob, "|sh") ||
	    strings.contains(blob, "| bash") ||
	    strings.contains(blob, "|bash") ||
	    strings.contains(blob, "| zsh") ||
	    strings.contains(blob, "|zsh")) {
		return "hard-deny: download piped to shell"
	}
	if strings.contains(compact, "curl|sh") ||
	   strings.contains(compact, "curl|bash") ||
	   strings.contains(compact, "wget|sh") ||
	   strings.contains(compact, "wget|bash") {
		return "hard-deny: download piped to shell"
	}
	// system control
	if strings.contains(blob, "shutdown") ||
	   strings.contains(blob, "reboot") ||
	   strings.contains(blob, "poweroff") ||
	   strings.contains(blob, "init 0") ||
	   strings.contains(blob, "kill -9 1") ||
	   strings.contains(blob, "kill -9 1 ") {
		return "hard-deny: system halt / kill init"
	}
	if strings.contains(blob, "sudo rm ") ||
	   strings.contains(blob, "sudo dd ") ||
	   strings.contains(blob, "sudo mkfs") {
		return "hard-deny: privileged destructive sudo"
	}
	if strings.contains(blob, "chmod -r 777 /") ||
	   strings.contains(blob, "chown -r /") ||
	   strings.contains(blob, "chown -r / ") {
		return "hard-deny: recursive chown/chmod on root"
	}
	return ""
}

// bash_looks_like_rm_root: "rm -rf /" or "rm -rf /*" but not "rm -rf /tmp/…".
bash_looks_like_rm_root :: proc(blob: string) -> bool {
	// normalize common flag orders
	patterns := []string{"rm -rf /", "rm -fr /", "rm -r -f /", "rm -f -r /"}
	for pat in patterns {
		start := 0
		for start < len(blob) {
			i := strings.index(blob[start:], pat)
			if i < 0 {
				break
			}
			pos := start + i + len(pat)
			// end of string, *, whitespace, or chain op → root wipe
			if pos >= len(blob) {
				return true
			}
			ch := blob[pos]
			if ch == '*' || ch == ' ' || ch == '\t' || ch == ';' || ch == '&' || ch == '|' || ch == '\n' {
				return true
			}
			// /tmp, /home, /var → not hard-deny root wipe
			start = pos
		}
	}
	return false
}

// bash_is_readonly: every segment is a known read-only viewer (Grok-shaped list).
// Conservative: pipes/redirection/complex quoting → false.
bash_is_readonly :: proc(command: string) -> bool {
	if !bash_soft_enabled() || command == "" {
		return false
	}
	// any redirect → not pure readonly auto-allow
	if strings.contains(command, ">") ||
	   strings.contains(command, ">>") ||
	   strings.contains(command, " <") ||
	   strings.contains(command, "<<") {
		return false
	}
	// split on chain operators (not quote-aware — false negatives only)
	// also split pipes: every stage must be readonly
	rest := command
	for len(rest) > 0 {
		seg: string
		// find next && || ; |
		cut := -1
		kind := 0 // 1=&& 2=|| 3=; 4=|
		i := 0
		for i < len(rest) {
			if i + 1 < len(rest) && rest[i] == '&' && rest[i + 1] == '&' {
				cut = i
				kind = 1
				break
			}
			if i + 1 < len(rest) && rest[i] == '|' && rest[i + 1] == '|' {
				cut = i
				kind = 2
				break
			}
			if rest[i] == ';' {
				cut = i
				kind = 3
				break
			}
			if rest[i] == '|' {
				cut = i
				kind = 4
				break
			}
			i += 1
		}
		if cut < 0 {
			seg = rest
			rest = ""
		} else {
			seg = rest[:cut]
			if kind == 1 || kind == 2 {
				rest = rest[cut + 2:]
			} else {
				rest = rest[cut + 1:]
			}
		}
		if !bash_segment_is_readonly(seg) {
			return false
		}
	}
	return true
}

bash_segment_is_readonly :: proc(seg: string) -> bool {
	s := strings.trim_space(seg)
	if s == "" {
		return true
	}
	// strip simple env assignments PREFIX=val cmd
	for {
		// first token
		tok, rem := first_shell_token(s)
		if tok == "" {
			return true
		}
		if strings.contains(tok, "=") && !strings.has_prefix(tok, "-") {
			s = rem
			continue
		}
		prog := shell_base_name(tok)
		prog_l := strings.to_lower(prog, context.temp_allocator)
		// sudo / env wrappers: peel one layer
		if prog_l == "sudo" || prog_l == "command" || prog_l == "time" || prog_l == "nice" {
			s = rem
			continue
		}
		if prog_l == "env" {
			// skip env VAR=... until real program
			s = rem
			continue
		}
		return bash_program_is_readonly(prog_l, rem)
	}
}

// first_shell_token: whitespace-split first token (no quote handling).
first_shell_token :: proc(s: string) -> (tok, rest: string) {
	t := strings.trim_left_space(s)
	if t == "" {
		return "", ""
	}
	end := 0
	for end < len(t) {
		if t[end] == ' ' || t[end] == '\t' {
			break
		}
		end += 1
	}
	tok = t[:end]
	rest = strings.trim_left_space(t[end:])
	return
}

shell_base_name :: proc(tok: string) -> string {
	// /usr/bin/ls → ls
	if i := strings.last_index_byte(tok, '/'); i >= 0 && i + 1 < len(tok) {
		return tok[i + 1:]
	}
	return tok
}

bash_program_is_readonly :: proc(prog, args: string) -> bool {
	// filesystem viewers
	switch prog {
	case "ls", "cat", "pwd", "date", "whoami", "hostname", "uptime", "ps",
	     "head", "tail", "wc", "sort", "uniq", "tr", "cut", "file", "stat",
	     "realpath", "readlink", "dirname", "basename", "echo", "printf",
	     "true", "false", "type", "which", "command", "env", "printenv",
	     "id", "uname", "df", "du", "free", "top", "htop",
	     "tree", "bat", "less", "more", "jq", "yq", "hexdump", "od",
	     "nl", "tac", "column", "paste", "diff", "cmp", "md5sum", "sha256sum",
	     // B49: modern listing tools (read-only)
	     "eza", "exa", "fd", "fdfind",
	     // B52: modern system / LOC viewers (read-only)
	     "dust", "duf", "procs", "btm", "bottom", "tokei", "cloc", "scc",
	     "hyperfine", // benchmarks only; no file writes by default
	     "delta": // git diff pager-style; read-only when used as viewer
		return true
	case "grep", "egrep", "fgrep", "rg":
		// block rg --pre (spawns preprocessor)
		if prog == "rg" &&
		   (strings.contains(args, "--pre ") ||
		    strings.contains(args, "--pre=") ||
		    strings.has_prefix(args, "--pre")) {
			return false
		}
		return true
	case "find":
		// find -exec / -delete are write-like
		if strings.contains(args, "-exec") ||
		   strings.contains(args, "-delete") ||
		   strings.contains(args, "-fprint") {
			return false
		}
		return true
	case "git":
		return bash_git_is_readonly(args)
	case "cargo":
		return bash_cargo_is_readonly(args)
	case "npm", "pnpm", "yarn", "yarnpkg":
		return bash_npm_family_is_readonly(args)
	case "bun":
		return bash_bun_is_readonly(args)
	case "deno":
		return bash_deno_is_readonly(args)
	case "poetry":
		return bash_poetry_is_readonly(args)
	case "uv":
		return bash_uv_is_readonly(args)
	case "rustup":
		return bash_rustup_is_readonly(args)
	case "pip", "pip3":
		return bash_pip_is_readonly(args)
	case "python", "python3":
		return bash_python_is_readonly(args)
	case "go":
		return bash_go_is_readonly(args)
	case "make", "gmake":
		return bash_make_is_readonly(args)
	case "odin":
		return bash_odin_is_readonly(args)
	case "zig":
		return bash_zig_is_readonly(args)
	case "swift":
		return bash_swift_is_readonly(args)
	case "dotnet":
		return bash_dotnet_is_readonly(args)
	case "sqlite3", "sqlite":
		return bash_sqlite3_is_readonly(args)
	case "redis-cli":
		return bash_redis_cli_is_readonly(args)
	case "psql":
		return bash_psql_is_readonly(args)
	case "mysql", "mariadb":
		return bash_mysql_is_readonly(args)
	case "curl":
		return bash_curl_is_readonly(args)
	case "wget":
		return bash_wget_is_readonly(args)
	case "xh", "http", "https":
		// HTTPie / xh — B51 inspect GET/HEAD
		return bash_httpie_is_readonly(args)
	case "ffprobe":
		return bash_ffprobe_is_readonly(args)
	case "ffmpeg":
		return bash_ffmpeg_is_readonly(args)
	case "nix":
		return bash_nix_is_readonly(args)
	case "nix-shell", "nix-env", "nix-channel", "nixos-rebuild":
		// only version/help for legacy tools; mutators fail closed
		return bash_nix_legacy_is_readonly(prog, args)
	case "nixos-version":
		return true
	case "aws":
		return bash_aws_is_readonly(args)
	case "gcloud":
		return bash_gcloud_is_readonly(args)
	case "az":
		return bash_az_is_readonly(args)
	case "pytest":
		return bash_pytest_is_readonly(args)
	case "cmake":
		return bash_cmake_is_readonly(args)
	case "ninja":
		return bash_ninja_is_readonly(args)
	case "meson":
		return bash_meson_is_readonly(args)
	case "just":
		return bash_just_is_readonly(args)
	case "gh":
		return bash_gh_is_readonly(args)
	case "terraform", "tofu":
		// OpenTofu (`tofu`) shares terraform CLI shape
		return bash_terraform_is_readonly(args)
	case "pulumi":
		return bash_pulumi_is_readonly(args)
	case "ansible":
		return bash_ansible_is_readonly(args)
	case "ansible-playbook":
		return bash_ansible_playbook_is_readonly(args)
	case "ansible-inventory":
		return bash_ansible_inventory_is_readonly(args)
	case "ansible-doc":
		return bash_ansible_doc_is_readonly(args)
	case "ansible-galaxy":
		return bash_ansible_galaxy_is_readonly(args)
	case "ansible-config":
		return bash_ansible_config_is_readonly(args)
	case "vagrant":
		return bash_vagrant_is_readonly(args)
	case "packer":
		return bash_packer_is_readonly(args)
	case "consul":
		return bash_consul_is_readonly(args)
	case "nomad":
		return bash_nomad_is_readonly(args)
	case "vault":
		return bash_vault_is_readonly(args)
	case "argocd":
		return bash_argocd_is_readonly(args)
	case "flux":
		return bash_flux_is_readonly(args)
	case "istioctl":
		return bash_istioctl_is_readonly(args)
	case "kustomize":
		return bash_kustomize_is_readonly(args)
	case "kubectx", "kubectl-ctx":
		return bash_kubectx_is_readonly(args)
	case "kubens", "kubectl-ns":
		return bash_kubens_is_readonly(args)
	case "skaffold":
		return bash_skaffold_is_readonly(args)
	case "kind":
		return bash_kind_is_readonly(args)
	case "minikube":
		return bash_minikube_is_readonly(args)
	case "k3d":
		return bash_k3d_is_readonly(args)
	case "tilt":
		return bash_tilt_is_readonly(args)
	case "crane":
		return bash_crane_is_readonly(args)
	case "skopeo":
		return bash_skopeo_is_readonly(args)
	case "dive":
		return bash_dive_is_readonly(args)
	case "syft":
		return bash_syft_is_readonly(args)
	case "grype":
		return bash_grype_is_readonly(args)
	case "trivy":
		return bash_trivy_is_readonly(args)
	case "cosign":
		return bash_cosign_is_readonly(args)
	case "oras":
		return bash_oras_is_readonly(args)
	case "regctl":
		return bash_regctl_is_readonly(args)
	case "buildah":
		return bash_buildah_is_readonly(args)
	case "nerdctl":
		return bash_nerdctl_is_readonly(args)
	case "ctr":
		return bash_ctr_is_readonly(args)
	case "helmfile":
		return bash_helmfile_is_readonly(args)
	case "stern":
		return bash_stern_is_readonly(args)
	case "kubeconform":
		return bash_kubeconform_is_readonly(args)
	case "tflint":
		return bash_tflint_is_readonly(args)
	case "terraform-docs":
		return bash_terraform_docs_is_readonly(args)
	case "terragrunt":
		return bash_terragrunt_is_readonly(args)
	case "checkov":
		return bash_checkov_is_readonly(args)
	case "tfsec":
		return bash_tfsec_is_readonly(args)
	case "infracost":
		return bash_infracost_is_readonly(args)
	case "helm":
		return bash_helm_is_readonly(args)
	case "kubectl":
		return bash_kubectl_is_readonly(args)
	case "docker":
		return bash_docker_is_readonly(args)
	case "podman":
		// B58: Podman CLI mirrors docker inspect surface
		return bash_docker_is_readonly(args)
	case "docker-compose":
		// legacy binary — same inspect set as `docker compose`
		return bash_docker_compose_is_readonly(args)
	case "brew":
		return bash_brew_is_readonly(args)
	case "pipx":
		return bash_pipx_is_readonly(args)
	case "gem":
		return bash_gem_is_readonly(args)
	case "bundle", "bundler":
		return bash_bundle_is_readonly(args)
	case "rake":
		return bash_rake_is_readonly(args)
	case "composer":
		return bash_composer_is_readonly(args)
	case "mvn", "mvnw":
		return bash_mvn_is_readonly(args)
	case "gradle", "gradlew":
		return bash_gradle_is_readonly(args)
	case "sbt":
		return bash_sbt_is_readonly(args)
	case "bazel", "bazelisk":
		return bash_bazel_is_readonly(args)
	case "apt", "apt-get":
		return bash_apt_is_readonly(args)
	case "apt-cache":
		// apt-cache is almost entirely inspect
		return bash_apt_cache_is_readonly(args)
	case "dnf", "yum":
		return bash_dnf_is_readonly(args)
	case "pacman":
		return bash_pacman_is_readonly(args)
	case "flatpak":
		return bash_flatpak_is_readonly(args)
	case "snap":
		return bash_snap_is_readonly(args)
	case "apk":
		return bash_apk_is_readonly(args)
	case "systemctl":
		sub, _ := first_shell_token(args)
		return sub == "status" || sub == "is-active" || sub == "is-enabled" || sub == "show" || sub == "list-units"
	}
	return false
}

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

// B85: crane inspect (manifest/digest/ls/config/version; not push/delete/copy).
bash_crane_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
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
		// mutators
		if sub == "push" ||
		   sub == "delete" ||
		   sub == "rm" ||
		   sub == "copy" ||
		   sub == "cp" ||
		   sub == "append" ||
		   sub == "mutate" ||
		   sub == "rebase" ||
		   sub == "export" || // may write tarball
		   sub == "pull" || // writes local
		   sub == "auth" ||
		   sub == "login" ||
		   sub == "logout" ||
		   sub == "serve" ||
		   sub == "registry" ||
		   sub == "edit" ||
		   sub == "flatten" ||
		   sub == "tag" {
			// tag mutates remote
			return false
		}
		// inspect
		if sub == "manifest" ||
		   sub == "digest" ||
		   sub == "config" ||
		   sub == "ls" ||
		   sub == "list" ||
		   sub == "catalog" ||
		   sub == "validate" ||
		   sub == "blob" || // read blob to stdout — inspect
		   sub == "raw" ||
		   sub == "version" ||
		   sub == "help" ||
		   sub == "completion" {
			if sub == "completion" {
				return false
			}
			return true
		}
		return false
	}
}

// B85: skopeo inspect (inspect/list-tags/login no; not copy/delete).
bash_skopeo_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "--version" ||
	   a == "version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") {
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
		if sub == "copy" ||
		   sub == "delete" ||
		   sub == "sync" ||
		   sub == "login" ||
		   sub == "logout" ||
		   sub == "standalone-sign" ||
		   sub == "standalone-verify" ||
		   sub == "generate-sigstore-key" {
			return false
		}
		if sub == "inspect" ||
		   sub == "list-tags" ||
		   sub == "layers" ||
		   sub == "help" ||
		   sub == "--version" ||
		   sub == "version" {
			return true
		}
		return false
	}
}

// B85: dive image layer explorer (always inspect of an image; no push).
bash_dive_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		// bare dive needs image — help-ish / TUI
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" {
		return true
	}
	// dive build is docker build wrapper — mutates
	if strings.has_prefix(a, "build ") || a == "build" {
		return false
	}
	// any other args are image refs / flags for explore
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "build" {
			return false
		}
		if strings.has_prefix(tok, "-") {
			// --ci is still inspect; --export may write
			if tok == "--export" || strings.has_prefix(tok, "--export=") || tok == "-j" || tok == "--json" {
				// json to stdout ok; -j file?
				if tok == "--export" {
					next, _ := first_shell_token(rem)
					if next != "" && next != "-" && !strings.has_prefix(next, "-") {
						return false
					}
				}
				if strings.has_prefix(tok, "--export=") {
					val := tok[strings.index_byte(tok, '=') + 1:]
					if val != "" && val != "-" {
						return false
					}
				}
			}
			rest = rem
			continue
		}
		// image name — inspect
		rest = rem
	}
	return true
}

// B91: checkov policy scan (scan to stdout; not create-config / output-file-path).
bash_checkov_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "-v" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		// config / report writes; external module download
		if tok == "--create-config" ||
		   tok == "--output-file-path" ||
		   tok == "--download-external-modules" ||
		   strings.has_prefix(tok, "--output-file-path=") ||
		   strings.has_prefix(tok, "--create-config") {
			return false
		}
		if tok == "-d" ||
		   tok == "--directory" ||
		   tok == "-f" ||
		   tok == "--file" ||
		   tok == "-o" ||
		   tok == "--output" ||
		   tok == "--framework" ||
		   tok == "--check" ||
		   tok == "--skip-check" ||
		   tok == "--repo-id" ||
		   tok == "--repo-root-for-plan-enrichment" ||
		   tok == "--var-file" ||
		   tok == "--external-checks-dir" ||
		   tok == "--config-file" ||
		   tok == "--bc-api-key" ||
		   tok == "--policy-metadata-filter" {
			if strings.contains(tok, "=") {
				rest = rem
				continue
			}
			// -o is format (cli/json/junitxml) — value not a path usually
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--directory=") ||
		   strings.has_prefix(tok, "--file=") ||
		   strings.has_prefix(tok, "--output=") ||
		   strings.has_prefix(tok, "--framework=") ||
		   strings.has_prefix(tok, "--config-file=") {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		// path / extra arg
		rest = rem
	}
	return true
}

// B91: tfsec scan (scan to stdout; not --out file).
bash_tfsec_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   a == "-v" ||
	   strings.has_prefix(a, "version ") ||
	   strings.has_prefix(a, "help ") {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		// report file
		if tok == "--out" ||
		   tok == "-O" ||
		   tok == "--output" ||
		   strings.has_prefix(tok, "--out=") ||
		   strings.has_prefix(tok, "--output=") {
			// --out without = needs path; --format is stdout format (tfsec uses --format not --out for format)
			if strings.has_prefix(tok, "--out=") || strings.has_prefix(tok, "--output=") {
				val := tok[strings.index_byte(tok, '=') + 1:]
				if val != "" && val != "-" {
					return false
				}
				rest = rem
				continue
			}
			if tok == "--out" || tok == "-O" || tok == "--output" {
				next, _ := first_shell_token(rem)
				if next != "" && next != "-" && !strings.has_prefix(next, "-") {
					return false
				}
			}
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		if !strings.has_prefix(tok, "-") {
			if sub == "version" || sub == "help" {
				return true
			}
			// directory path
			rest = rem
			continue
		}
		// flags with values
		if tok == "--format" ||
		   tok == "-f" ||
		   tok == "--exclude" ||
		   tok == "-e" ||
		   tok == "--filter-results" ||
		   tok == "--tfvars-file" ||
		   tok == "--config-file" ||
		   tok == "--custom-check-dir" ||
		   tok == "--minimum-severity" {
			if strings.contains(tok, "=") {
				rest = rem
				continue
			}
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--format=") ||
		   strings.has_prefix(tok, "--exclude=") ||
		   strings.has_prefix(tok, "--config-file=") ||
		   strings.has_prefix(tok, "--tfvars-file=") {
			rest = rem
			continue
		}
		rest = rem
	}
	return true
}

// B91: infracost estimate (breakdown/diff/output; not configure/auth/upload/comment).
bash_infracost_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   a == "-v" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	// --out-file report
	if bash_infracost_writes_file(a) {
		return false
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
		// inspect
		if sub == "breakdown" ||
		   sub == "diff" ||
		   sub == "output" ||
		   sub == "estimate" ||
		   sub == "validate" ||
		   sub == "completion" ||
		   sub == "version" ||
		   sub == "help" {
			if sub == "completion" {
				return false
			}
			return true
		}
		// mutators / auth / PR side effects
		if sub == "configure" ||
		   sub == "auth" ||
		   sub == "upload" ||
		   sub == "comment" ||
		   sub == "register" ||
		   sub == "login" ||
		   sub == "logout" {
			return false
		}
		return false
	}
}

bash_infracost_writes_file :: proc(args: string) -> bool {
	rest := args
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return false
		}
		if tok == "--out-file" ||
		   tok == "--out" ||
		   tok == "-o" {
			// -o may be format for some subcmds; fail-closed if next looks like path
			next, _ := first_shell_token(rem)
			if next != "" && next != "-" && !strings.has_prefix(next, "-") {
				// formats: json table html github-comment …
				if next == "json" ||
				   next == "table" ||
				   next == "html" ||
				   next == "diff" ||
				   next == "github-comment" ||
				   next == "gitlab-comment" ||
				   next == "azure-repos-comment" ||
				   next == "bitbucket-comment" ||
				   next == "slack-message" {
					rest = rem
					continue
				}
				return true
			}
		}
		if strings.has_prefix(tok, "--out-file=") || strings.has_prefix(tok, "--out=") {
			val := tok[strings.index_byte(tok, '=') + 1:]
			if val != "" && val != "-" {
				return true
			}
		}
		rest = rem
	}
}

// B90: tflint inspect (default lint / --version; not --init / --fix-config).
bash_tflint_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		// bare tflint lints cwd
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   a == "-v" {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		// plugin install / config write
		if tok == "--init" ||
		   tok == "--fix-config" ||
		   tok == "--fix" ||
		   strings.has_prefix(tok, "--fix=") ||
		   strings.has_prefix(tok, "--fix-config") {
			return false
		}
		// --fix=path writes report file
		if tok == "--format" || tok == "-f" {
			// format is stdout format — peel value
			if strings.has_prefix(tok, "--format=") {
				rest = rem
				continue
			}
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "-") {
			// peel flags that take values
			if tok == "--config" ||
			   tok == "-c" ||
			   tok == "--var" ||
			   tok == "--var-file" ||
			   tok == "--module" ||
			   tok == "--chdir" ||
			   tok == "--filter" ||
			   tok == "--minimum-failure-severity" ||
			   tok == "--call-module-type" ||
			   tok == "--format" ||
			   tok == "-f" {
				if strings.contains(tok, "=") {
					rest = rem
					continue
				}
				// value may follow
				if tok == "--module" {
					// boolean in newer tflint sometimes
					rest = rem
					continue
				}
				_, rest2 := first_shell_token(rem)
				rest = rest2
				continue
			}
			if strings.has_prefix(tok, "--config=") ||
			   strings.has_prefix(tok, "--var=") ||
			   strings.has_prefix(tok, "--var-file=") ||
			   strings.has_prefix(tok, "--chdir=") ||
			   strings.has_prefix(tok, "--filter=") ||
			   strings.has_prefix(tok, "--format=") {
				rest = rem
				continue
			}
			rest = rem
			continue
		}
		// path to module — lint
		rest = rem
	}
	return true
}

// B90: terraform-docs inspect (render to stdout; not --output-file / inject).
bash_terraform_docs_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   a == "-v" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	// file writes
	if bash_terraform_docs_writes_file(a) {
		return false
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if strings.has_prefix(tok, "-") {
			// --output-mode inject rewrites README
			if tok == "--output-mode" || strings.has_prefix(tok, "--output-mode=") {
				mode := ""
				if strings.has_prefix(tok, "--output-mode=") {
					mode = tok[strings.index_byte(tok, '=') + 1:]
				} else {
					mode, _ = first_shell_token(rem)
				}
				if mode == "inject" || mode == "replace" {
					return false
				}
			}
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		// subcommands: markdown, json, yaml, toml, tfvars, asciidoc, pretty, completion
		if sub == "completion" {
			return false
		}
		if sub == "markdown" ||
		   sub == "json" ||
		   sub == "yaml" ||
		   sub == "yml" ||
		   sub == "toml" ||
		   sub == "tfvars" ||
		   sub == "tfvars-hcl" ||
		   sub == "tfvars-json" ||
		   sub == "asciidoc" ||
		   sub == "asciidoc-document" ||
		   sub == "asciidoc-table" ||
		   sub == "pretty" ||
		   sub == "xml" ||
		   sub == "html" ||
		   sub == "version" ||
		   sub == "help" {
			return true
		}
		// path argument (module dir)
		rest = rem
	}
	return true
}

bash_terraform_docs_writes_file :: proc(args: string) -> bool {
	rest := args
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return false
		}
		if tok == "--output-file" || tok == "-o" {
			next, _ := first_shell_token(rem)
			if next != "" && next != "-" && !strings.has_prefix(next, "-") {
				return true
			}
		}
		if strings.has_prefix(tok, "--output-file=") {
			val := tok[strings.index_byte(tok, '=') + 1:]
			if val != "" && val != "-" {
				return true
			}
		}
		rest = rem
	}
}

// B90: terragrunt inspect (plan/validate/show/output/graph; not apply/destroy/import).
bash_terragrunt_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   a == "-v" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	rest := a
	// peel terragrunt global flags
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "--terragrunt-config" ||
		   tok == "--terragrunt-working-dir" ||
		   tok == "--terragrunt-log-level" ||
		   tok == "--terragrunt-iam-role" ||
		   tok == "--terragrunt-source" ||
		   tok == "--terragrunt-source-update" ||
		   tok == "--terragrunt-download-dir" ||
		   tok == "--working-dir" ||
		   tok == "--config" ||
		   tok == "--log-level" ||
		   tok == "-C" {
			if strings.contains(tok, "=") {
				rest = rem
				continue
			}
			// boolean flags
			if tok == "--terragrunt-source-update" {
				// may download — fail-closed
				return false
			}
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--terragrunt-") ||
		   strings.has_prefix(tok, "--working-dir=") ||
		   strings.has_prefix(tok, "--config=") ||
		   strings.has_prefix(tok, "--log-level=") {
			if strings.has_prefix(tok, "--terragrunt-source-update") {
				return false
			}
			// --terragrunt-non-interactive etc.
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		// terragrunt-native inspect
		if sub == "terragrunt-info" ||
		   sub == "render-json" ||
		   sub == "graph-dependencies" ||
		   sub == "output-module-groups" ||
		   sub == "validate-inputs" ||
		   sub == "hclfmt" || // rewrites HCL — ask
		   sub == "hclvalidate" ||
		   sub == "hcl" ||
		   sub == "info" ||
		   sub == "version" ||
		   sub == "help" {
			if sub == "hclfmt" {
				return false
			}
			if sub == "hcl" {
				// hcl validate / format
				hrest := rem
				for {
					ht, hrem := first_shell_token(hrest)
					if ht == "" {
						return true
					}
					if strings.has_prefix(ht, "-") {
						hrest = hrem
						continue
					}
					hsub := strings.to_lower(ht, context.temp_allocator)
					if hsub == "validate" || hsub == "validate-inputs" {
						return true
					}
					if hsub == "fmt" || hsub == "format" {
						return false
					}
					return false
				}
			}
			return true
		}
		if sub == "run-all" || sub == "run" {
			// run-all plan ok; run-all apply not
			rrest := rem
			for {
				rt, rrem := first_shell_token(rrest)
				if rt == "" {
					return true
				}
				if strings.has_prefix(rt, "-") {
					rrest = rrem
					continue
				}
				return bash_terragrunt_tf_sub_readonly(strings.to_lower(rt, context.temp_allocator), rrem)
			}
		}
		// terraform passthrough subcommands
		return bash_terragrunt_tf_sub_readonly(sub, rem)
	}
}

bash_terragrunt_tf_sub_readonly :: proc(sub: string, rest: string) -> bool {
	// align with soft-bash terraform inspect surface
	if sub == "plan" ||
	   sub == "validate" ||
	   sub == "show" ||
	   sub == "output" ||
	   sub == "graph" ||
	   sub == "providers" ||
	   sub == "version" ||
	   sub == "test" {
		return true
	}
	if sub == "fmt" || sub == "console" || sub == "get" {
		// fmt rewrites; get downloads modules
		return false
	}
	if sub == "state" {
		// state list/show/pull only
		srest := rest
		for {
			st, srem := first_shell_token(srest)
			if st == "" {
				return true
			}
			if strings.has_prefix(st, "-") {
				srest = srem
				continue
			}
			ssub := strings.to_lower(st, context.temp_allocator)
			if ssub == "list" || ssub == "show" || ssub == "pull" {
				return true
			}
			// mv/rm/push/replace/…
			return false
		}
	}
	// mutators (+ legacy plan-all inspect)
	if sub == "apply" ||
	   sub == "destroy" ||
	   sub == "import" ||
	   sub == "taint" ||
	   sub == "untaint" ||
	   sub == "init" ||
	   sub == "refresh" ||
	   sub == "force-unlock" ||
	   sub == "workspace" ||
	   sub == "login" ||
	   sub == "logout" ||
	   sub == "apply-all" ||
	   sub == "destroy-all" ||
	   sub == "output-all" ||
	   sub == "plan-all" {
		if sub == "plan-all" || sub == "output-all" {
			return true
		}
		return false
	}
	return false
}

// B89: helmfile inspect (list/status/template/build/lint; not apply/sync/destroy).
bash_helmfile_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	// --output-file / -o path writes rendered charts
	if bash_helmfile_writes_file(a) {
		return false
	}
	rest := a
	// peel common globals that take values (-f file, -e env, -l selector, …)
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "-f" ||
		   tok == "--file" ||
		   tok == "-e" ||
		   tok == "--environment" ||
		   tok == "-l" ||
		   tok == "--selector" ||
		   tok == "-n" ||
		   tok == "--namespace" ||
		   tok == "--state-values-set" ||
		   tok == "--state-values-file" ||
		   tok == "--chart" ||
		   tok == "--log-level" ||
		   tok == "--kube-context" ||
		   tok == "--kubeconfig" {
			if strings.contains(tok, "=") {
				rest = rem
				continue
			}
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--file=") ||
		   strings.has_prefix(tok, "--environment=") ||
		   strings.has_prefix(tok, "--selector=") ||
		   strings.has_prefix(tok, "--namespace=") ||
		   strings.has_prefix(tok, "--state-values-set=") ||
		   strings.has_prefix(tok, "--state-values-file=") ||
		   strings.has_prefix(tok, "--log-level=") ||
		   strings.has_prefix(tok, "--kube-context=") ||
		   strings.has_prefix(tok, "--kubeconfig=") {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		// inspect / render
		if sub == "list" ||
		   sub == "ls" ||
		   sub == "status" ||
		   sub == "template" ||
		   sub == "build" ||
		   sub == "lint" ||
		   sub == "write-values" || // writes values files — ask
		   sub == "deps" || // may download charts
		   sub == "fetch" ||
		   sub == "repos" ||
		   sub == "diff" || // plan-like; no cluster mutate
		   sub == "version" ||
		   sub == "help" ||
		   sub == "print-env" ||
		   sub == "show-dag" ||
		   sub == "cache" {
			if sub == "write-values" || sub == "deps" || sub == "fetch" {
				return false
			}
			if sub == "repos" {
				// repos add/remove mutates; list is rare — fail-closed
				return false
			}
			if sub == "cache" {
				// cache clean mutates
				return false
			}
			return true
		}
		// mutators
		if sub == "apply" ||
		   sub == "sync" ||
		   sub == "destroy" ||
		   sub == "delete" ||
		   sub == "remove" ||
		   sub == "init" ||
		   sub == "charts" ||
		   sub == "test" ||
		   sub == "completion" {
			return false
		}
		return false
	}
}

bash_helmfile_writes_file :: proc(args: string) -> bool {
	rest := args
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return false
		}
		// helmfile template --output-dir / -o
		if tok == "--output-dir" ||
		   tok == "--output-file" ||
		   tok == "-o" ||
		   tok == "--skip-deps" {
			if tok == "--skip-deps" {
				rest = rem
				continue
			}
			next, _ := first_shell_token(rem)
			if next != "" && next != "-" && !strings.has_prefix(next, "-") {
				return true
			}
		}
		if strings.has_prefix(tok, "--output-dir=") ||
		   strings.has_prefix(tok, "--output-file=") {
			eq := strings.index_byte(tok, '=')
			val := tok[eq + 1:]
			if val != "" && val != "-" {
				return true
			}
		}
		rest = rem
	}
}

// B89: stern multi-pod logs (always inspect; no cluster mutate).
bash_stern_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	// completion scripts
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if strings.has_prefix(tok, "-") {
			// all flags are query/filter for log stream
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		if sub == "completion" || sub == "help" || sub == "version" {
			if sub == "completion" {
				return false
			}
			return true
		}
		// bare query string / pod pattern — logs
		return true
	}
}

// B89: kubeconform manifest validate (always inspect; not schema install mutators).
bash_kubeconform_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "-v" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" {
		return true
	}
	// -o output format (json/junit/text) is stdout; -cache dir writes cache — ask
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "-cache" || tok == "--cache" {
			// next is cache dir — local write
			return false
		}
		if strings.has_prefix(tok, "-cache=") || strings.has_prefix(tok, "--cache=") {
			return false
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		// file path / dir — validate
		rest = rem
	}
	return true
}

// B88: buildah inspect (images/containers/inspect/version; not bud/from/commit/push).
bash_buildah_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
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
		// inspect
		if sub == "images" ||
		   sub == "image" || // image list alias paths
		   sub == "containers" ||
		   sub == "ps" ||
		   sub == "ls" ||
		   sub == "list" ||
		   sub == "inspect" ||
		   sub == "info" ||
		   sub == "version" ||
		   sub == "help" ||
		   sub == "mount" || // list mounts when bare-ish; still can mount — fail-closed if extra writey
		   sub == "umount" ||
		   sub == "unmount" {
			// mount/umount mutate mount table
			if sub == "mount" || sub == "umount" || sub == "unmount" {
				return false
			}
			if sub == "image" {
				// buildah image (noop) / rare; image list-ish only if second is list
				return true
			}
			return true
		}
		// mutators
		if sub == "from" ||
		   sub == "bud" ||
		   sub == "build" ||
		   sub == "build-using-dockerfile" ||
		   sub == "commit" ||
		   sub == "push" ||
		   sub == "pull" ||
		   sub == "login" ||
		   sub == "logout" ||
		   sub == "rm" ||
		   sub == "rmi" ||
		   sub == "run" ||
		   sub == "config" ||
		   sub == "copy" ||
		   sub == "add" ||
		   sub == "tag" ||
		   sub == "untag" ||
		   sub == "rename" ||
		   sub == "manifest" || // can mutate; fail-closed (inspect via inspect cmd)
		   sub == "mkcw" ||
		   sub == "prune" ||
		   sub == "source" ||
		   sub == "unshare" ||
		   sub == "completion" {
			return false
		}
		return false
	}
}

// B88: nerdctl inspect (docker-compatible ps/images/logs; not run/build/push).
bash_nerdctl_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	// compose plugin same as docker compose
	rest := a
	// peel global flags that take values
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "-n" ||
		   tok == "--namespace" ||
		   tok == "-a" ||
		   tok == "--address" ||
		   tok == "-H" ||
		   tok == "--host" ||
		   tok == "--cgroup-manager" ||
		   tok == "--insecure-registry" ||
		   tok == "--snapshotter" ||
		   tok == "--data-root" ||
		   tok == "--cni-path" ||
		   tok == "--cni-netconfpath" ||
		   tok == "--bip" ||
		   tok == "--iptables" ||
		   tok == "--storage-driver" {
			// flags with optional values
			if tok == "-n" ||
			   tok == "--namespace" ||
			   tok == "-a" ||
			   tok == "--address" ||
			   tok == "-H" ||
			   tok == "--host" ||
			   tok == "--cgroup-manager" ||
			   tok == "--snapshotter" ||
			   tok == "--data-root" ||
			   tok == "--cni-path" ||
			   tok == "--cni-netconfpath" ||
			   tok == "--bip" ||
			   tok == "--storage-driver" {
				// may be --namespace=x form
				if strings.has_prefix(tok, "--") && strings.contains(tok, "=") {
					rest = rem
					continue
				}
				_, rest2 := first_shell_token(rem)
				rest = rest2
				continue
			}
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "--namespace=") ||
		   strings.has_prefix(tok, "--address=") ||
		   strings.has_prefix(tok, "--host=") ||
		   strings.has_prefix(tok, "--cgroup-manager=") ||
		   strings.has_prefix(tok, "--snapshotter=") ||
		   strings.has_prefix(tok, "--data-root=") {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			// other boolean globals
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		if sub == "compose" {
			return bash_docker_compose_is_readonly(rem)
		}
		if sub == "version" ||
		   sub == "help" ||
		   sub == "info" ||
		   sub == "events" {
			return true
		}
		// classic inspect (mirror docker)
		if bash_sub_in(
			   sub,
			   []string{"ps", "images", "image", "logs", "inspect", "top", "stats", "port", "diff", "system"},
		   ) {
			// image ls vs image rm — nerdctl image is parent
			if sub == "image" || sub == "images" {
				return bash_nerdctl_image_is_readonly(rem, sub == "images")
			}
			if sub == "system" {
				// system df/info — inspect; system prune mutates
				srest := rem
				for {
					st, srem := first_shell_token(srest)
					if st == "" {
						return true
					}
					if strings.has_prefix(st, "-") {
						srest = srem
						continue
					}
					ssub := strings.to_lower(st, context.temp_allocator)
					if ssub == "df" || ssub == "info" || ssub == "events" {
						return true
					}
					return false
				}
			}
			return true
		}
		// container inspect aliases
		if sub == "container" {
			crest := rem
			for {
				ct, crem := first_shell_token(crest)
				if ct == "" {
					return true
				}
				if strings.has_prefix(ct, "-") {
					crest = crem
					continue
				}
				csub := strings.to_lower(ct, context.temp_allocator)
				return bash_sub_in(
					csub,
					[]string{"ls", "list", "ps", "inspect", "logs", "top", "stats", "port", "diff"},
				)
			}
		}
		return false
	}
}

bash_nerdctl_image_is_readonly :: proc(args: string, bare_images: bool) -> bool {
	if bare_images {
		// nerdctl images [filters] — list
		return true
	}
	rest := args
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
		if sub == "ls" ||
		   sub == "list" ||
		   sub == "inspect" ||
		   sub == "history" {
			return true
		}
		// rm/pull/push/tag/build/import/export/prune
		return false
	}
}

// B88: ctr (containerd) inspect (images/containers/tasks/content list; not pull/run/rm).
bash_ctr_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	rest := a
	// peel global -a/--address -n/--namespace
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "-a" ||
		   tok == "--address" ||
		   tok == "-n" ||
		   tok == "--namespace" ||
		   tok == "--timeout" ||
		   tok == "-t" {
			if strings.contains(tok, "=") {
				rest = rem
				continue
			}
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--address=") ||
		   strings.has_prefix(tok, "--namespace=") ||
		   strings.has_prefix(tok, "--timeout=") {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		if sub == "version" || sub == "help" || sub == "plugins" || sub == "info" {
			// plugins list is default; info is host
			if sub == "plugins" {
				return bash_ctr_listish(rem, true)
			}
			return true
		}
		if sub == "images" || sub == "i" || sub == "image" {
			return bash_ctr_images_is_readonly(rem)
		}
		if sub == "containers" || sub == "c" || sub == "container" {
			return bash_ctr_containers_is_readonly(rem)
		}
		if sub == "tasks" || sub == "t" || sub == "task" {
			return bash_ctr_tasks_is_readonly(rem)
		}
		if sub == "content" {
			return bash_ctr_content_is_readonly(rem)
		}
		if sub == "namespaces" || sub == "ns" {
			return bash_ctr_namespaces_is_readonly(rem)
		}
		if sub == "snapshots" {
			return bash_ctr_listish_or_mutate(rem, []string{"list", "ls", "tree", "usage", "info"})
		}
		if sub == "leases" {
			return bash_ctr_listish_or_mutate(rem, []string{"list", "ls"})
		}
		if sub == "events" {
			return true
		}
		// run, install, deprecations, etc.
		return false
	}
}

bash_ctr_listish :: proc(args: string, default_list: bool) -> bool {
	rest := args
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return default_list
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		if sub == "list" || sub == "ls" {
			return true
		}
		return false
	}
}

bash_ctr_listish_or_mutate :: proc(args: string, allowed: []string) -> bool {
	rest := args
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			// bare parent often lists
			return true
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		return bash_sub_in(strings.to_lower(tok, context.temp_allocator), allowed)
	}
}

bash_ctr_images_is_readonly :: proc(args: string) -> bool {
	rest := args
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			// ctr images → list
			return true
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		if sub == "list" ||
		   sub == "ls" ||
		   sub == "check" ||
		   sub == "usage" ||
		   sub == "label" { // label get may mutate with set — fail if set-like
			// `ctr images label` can set labels — require only list path: treat as ask
			if sub == "label" {
				return false
			}
			return true
		}
		// pull push rm tag import export mount unmount convert encrypt decrypt
		return false
	}
}

bash_ctr_containers_is_readonly :: proc(args: string) -> bool {
	rest := args
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
		if sub == "list" || sub == "ls" || sub == "info" {
			return true
		}
		// create delete checkpoint restore label
		return false
	}
}

bash_ctr_tasks_is_readonly :: proc(args: string) -> bool {
	rest := args
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
		if sub == "list" || sub == "ls" || sub == "ps" || sub == "metrics" {
			return true
		}
		// start kill delete exec pause resume checkpoint
		return false
	}
}

bash_ctr_content_is_readonly :: proc(args: string) -> bool {
	rest := args
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
		if sub == "ls" ||
		   sub == "list" ||
		   sub == "fetch" || // network fetch into store — mutates
		   sub == "get" ||
		   sub == "active" {
			if sub == "fetch" {
				return false
			}
			return true
		}
		// push delete label edit
		return false
	}
}

bash_ctr_namespaces_is_readonly :: proc(args: string) -> bool {
	rest := args
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
		if sub == "list" || sub == "ls" {
			return true
		}
		// create remove label
		return false
	}
}

// B87: cosign inspect (verify/tree/triangulate/version; not sign/upload/login).
bash_cosign_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	// --output-file / download to path
	if bash_cosign_writes_file(a) {
		return false
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
		// mutators / key material / auth
		if sub == "sign" ||
		   sub == "sign-blob" ||
		   sub == "attest" ||
		   sub == "attest-blob" ||
		   sub == "attach" ||
		   sub == "upload" ||
		   sub == "copy" ||
		   sub == "clean" ||
		   sub == "login" ||
		   sub == "logout" ||
		   sub == "generate-key-pair" ||
		   sub == "import-key-pair" ||
		   sub == "initialize" ||
		   sub == "load" ||
		   sub == "save" ||
		   sub == "completion" ||
		   sub == "piv-tool" ||
		   sub == "pkcs11-tool" {
			return false
		}
		// inspect (public-key/env stdout; outfile caught above)
		if sub == "verify" ||
		   sub == "verify-blob" ||
		   sub == "verify-attestation" ||
		   sub == "verify-blob-attestation" ||
		   sub == "tree" ||
		   sub == "triangulate" ||
		   sub == "download" ||
		   sub == "dockerfile" ||
		   sub == "manifest" ||
		   sub == "public-key" ||
		   sub == "env" ||
		   sub == "version" ||
		   sub == "help" ||
		   sub == "man" {
			return true
		}
		return false
	}
}

bash_cosign_writes_file :: proc(args: string) -> bool {
	rest := args
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return false
		}
		if tok == "--output-file" || tok == "--outfile" || tok == "-output-file" {
			next, _ := first_shell_token(rem)
			if next != "" && next != "-" && !strings.has_prefix(next, "-") {
				return true
			}
		}
		if strings.has_prefix(tok, "--output-file=") ||
		   strings.has_prefix(tok, "--outfile=") {
			eq := strings.index_byte(tok, '=')
			val := tok[eq + 1:]
			if val != "" && val != "-" {
				return true
			}
		}
		// cosign download attestation --output-file
		if tok == "-o" || tok == "--output" {
			next, _ := first_shell_token(rem)
			if next != "" && next != "-" && !strings.has_prefix(next, "-") {
				// may be format not path for some subcmds — fail-closed if looks like path
				if strings.contains(next, ".") || strings.contains(next, "/") {
					return true
				}
			}
		}
		rest = rem
	}
}

// B87: oras inspect (manifest fetch/discover/repo tags; not push/pull/login).
bash_oras_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	// pull/cp write local files; also -o output
	if bash_oras_writes_file(a) {
		return false
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
		if sub == "push" ||
		   sub == "pull" ||
		   sub == "attach" ||
		   sub == "copy" ||
		   sub == "cp" ||
		   sub == "login" ||
		   sub == "logout" ||
		   sub == "tag" || // retag remote
		   sub == "backup" ||
		   sub == "restore" ||
		   sub == "completion" {
			return false
		}
		if sub == "manifest" {
			// manifest fetch|fetch-config|delete|push
			mrest := rem
			for {
				mt, mrem := first_shell_token(mrest)
				if mt == "" {
					return true
				}
				if strings.has_prefix(mt, "-") {
					mrest = mrem
					continue
				}
				msub := strings.to_lower(mt, context.temp_allocator)
				if msub == "fetch" ||
				   msub == "fetch-config" ||
				   msub == "get" ||
				   msub == "help" {
					return true
				}
				if msub == "push" ||
				   msub == "delete" ||
				   msub == "update" {
					return false
				}
				return false
			}
		}
		if sub == "blob" {
			brest := rem
			for {
				bt, brem := first_shell_token(brest)
				if bt == "" {
					return true
				}
				if strings.has_prefix(bt, "-") {
					brest = brem
					continue
				}
				bsub := strings.to_lower(bt, context.temp_allocator)
				if bsub == "fetch" ||
				   bsub == "push" || // mutates
				   bsub == "delete" ||
				   bsub == "help" {
					if bsub == "fetch" || bsub == "help" {
						return true
					}
					return false
				}
				return false
			}
		}
		if sub == "repo" || sub == "repository" {
			rrest := rem
			for {
				rt, rrem := first_shell_token(rrest)
				if rt == "" {
					return true
				}
				if strings.has_prefix(rt, "-") {
					rrest = rrem
					continue
				}
				rsub := strings.to_lower(rt, context.temp_allocator)
				if rsub == "tags" ||
				   rsub == "ls" ||
				   rsub == "list" ||
				   rsub == "help" {
					return true
				}
				return false
			}
		}
		if sub == "discover" ||
		   sub == "resolve" ||
		   sub == "version" ||
		   sub == "help" ||
		   sub == "trace" {
			return true
		}
		return false
	}
}

bash_oras_writes_file :: proc(args: string) -> bool {
	rest := args
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return false
		}
		if tok == "-o" || tok == "--output" {
			next, _ := first_shell_token(rem)
			if next != "" && next != "-" && !strings.has_prefix(next, "-") {
				return true
			}
		}
		if strings.has_prefix(tok, "--output=") {
			val := tok[strings.index_byte(tok, '=') + 1:]
			if val != "" && val != "-" {
				return true
			}
		}
		rest = rem
	}
}

// B87: regctl inspect (image digest/manifest/config/tag ls; not copy/delete/login).
bash_regctl_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
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
		if sub == "registry" {
			// registry config/login/set — fail-closed except login already mutates
			rrest := rem
			for {
				rt, rrem := first_shell_token(rrest)
				if rt == "" {
					return true
				}
				if strings.has_prefix(rt, "-") {
					rrest = rrem
					continue
				}
				rsub := strings.to_lower(rt, context.temp_allocator)
				if rsub == "config" ||
				   rsub == "whoami" ||
				   rsub == "help" {
					// config get is inspect; config set mutates — scan further
					if rsub == "config" {
						crest := rrem
						for {
							ct, crem := first_shell_token(crest)
							if ct == "" {
								return true // regctl registry config (dump)
							}
							if strings.has_prefix(ct, "-") {
								crest = crem
								continue
							}
							csub := strings.to_lower(ct, context.temp_allocator)
							if csub == "set" || csub == "delete" || csub == "rm" {
								return false
							}
							// get / dump
							return true
						}
					}
					return true
				}
				if rsub == "login" ||
				   rsub == "logout" ||
				   rsub == "set" {
					return false
				}
				return false
			}
		}
		if sub == "image" {
			irest := rem
			for {
				it, irem := first_shell_token(irest)
				if it == "" {
					return true
				}
				if strings.has_prefix(it, "-") {
					irest = irem
					continue
				}
				isub := strings.to_lower(it, context.temp_allocator)
				// inspect
				if isub == "digest" ||
				   isub == "manifest" ||
				   isub == "config" ||
				   isub == "inspect" ||
				   isub == "ratelimit" ||
				   isub == "rate-limit" ||
				   isub == "export" || // may write tar — check -o
				   isub == "import" ||
				   isub == "copy" ||
				   isub == "delete" ||
				   isub == "del" ||
				   isub == "rm" ||
				   isub == "mod" ||
				   isub == "create" ||
				   isub == "append-file" ||
				   isub == "get-file" || // get-file to stdout ok; -o file ask
				   isub == "help" {
					if isub == "export" ||
					   isub == "import" ||
					   isub == "copy" ||
					   isub == "delete" ||
					   isub == "del" ||
					   isub == "rm" ||
					   isub == "mod" ||
					   isub == "create" ||
					   isub == "append-file" {
						return false
					}
					if isub == "get-file" {
						if bash_regctl_output_file(irem) {
							return false
						}
						return true
					}
					if isub == "manifest" || isub == "config" {
						// manifest get vs put/delete
						mrest := irem
						for {
							mt, mrem := first_shell_token(mrest)
							if mt == "" {
								return true
							}
							if strings.has_prefix(mt, "-") {
								mrest = mrem
								continue
							}
							// first non-flag is image ref — get
							// if subcommand put/delete
							msub := strings.to_lower(mt, context.temp_allocator)
							if msub == "put" ||
							   msub == "delete" ||
							   msub == "del" ||
							   msub == "rm" ||
							   msub == "head" {
								if msub == "head" {
									return true
								}
								return false
							}
							// image ref — get
							if bash_regctl_output_file(mrest) {
								return false
							}
							return true
						}
					}
					return true
				}
				return false
			}
		}
		if sub == "tag" {
			trest := rem
			for {
				tt, trem := first_shell_token(trest)
				if tt == "" {
					return true
				}
				if strings.has_prefix(tt, "-") {
					trest = trem
					continue
				}
				tsub := strings.to_lower(tt, context.temp_allocator)
				if tsub == "ls" ||
				   tsub == "list" ||
				   tsub == "help" {
					return true
				}
				if tsub == "delete" ||
				   tsub == "del" ||
				   tsub == "rm" ||
				   tsub == "copy" {
					return false
				}
				return false
			}
		}
		if sub == "artifact" {
			arest := rem
			for {
				at, arem := first_shell_token(arest)
				if at == "" {
					return true
				}
				if strings.has_prefix(at, "-") {
					arest = arem
					continue
				}
				asub := strings.to_lower(at, context.temp_allocator)
				if asub == "tree" ||
				   asub == "list" ||
				   asub == "ls" ||
				   asub == "get" ||
				   asub == "help" {
					return true
				}
				if asub == "put" ||
				   asub == "delete" ||
				   asub == "del" {
					return false
				}
				return false
			}
		}
		if sub == "blob" {
			brest := rem
			for {
				bt, brem := first_shell_token(brest)
				if bt == "" {
					return true
				}
				if strings.has_prefix(bt, "-") {
					brest = brem
					continue
				}
				bsub := strings.to_lower(bt, context.temp_allocator)
				if bsub == "get" ||
				   bsub == "head" ||
				   bsub == "help" {
					if bash_regctl_output_file(brem) {
						return false
					}
					return true
				}
				if bsub == "put" ||
				   bsub == "delete" ||
				   bsub == "del" ||
				   bsub == "copy" {
					return false
				}
				return false
			}
		}
		if sub == "repo" || sub == "repository" {
			rrest := rem
			for {
				rt, rrem := first_shell_token(rrest)
				if rt == "" {
					return true
				}
				if strings.has_prefix(rt, "-") {
					rrest = rrem
					continue
				}
				rsub := strings.to_lower(rt, context.temp_allocator)
				if rsub == "ls" ||
				   rsub == "list" ||
				   rsub == "help" {
					return true
				}
				return false
			}
		}
		if sub == "ref" {
			// ref parse/format inspect
			return true
		}
		if sub == "version" || sub == "help" || sub == "completion" {
			if sub == "completion" {
				return false
			}
			return true
		}
		return false
	}
}

bash_regctl_output_file :: proc(args: string) -> bool {
	rest := args
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return false
		}
		if tok == "-o" || tok == "--output" || tok == "--out" {
			next, _ := first_shell_token(rem)
			if next != "" && next != "-" && !strings.has_prefix(next, "-") {
				return true
			}
		}
		if strings.has_prefix(tok, "--output=") || strings.has_prefix(tok, "--out=") {
			eq := strings.index_byte(tok, '=')
			val := tok[eq + 1:]
			if val != "" && val != "-" {
				return true
			}
		}
		rest = rem
	}
}

// B86: syft SBOM inspect (scan/packages/version; not login/attest).
bash_syft_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	// file write destinations
	if bash_syft_grype_writes_file(a) {
		return false
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
		// mutators / auth
		if sub == "login" ||
		   sub == "attest" ||
		   sub == "completion" {
			return false
		}
		// inspect / convert-to-stdout
		if sub == "packages" ||
		   sub == "scan" ||
		   sub == "convert" ||
		   sub == "cataloger" ||
		   sub == "version" ||
		   sub == "help" {
			return true
		}
		// bare image/dir/source ref (legacy: `syft alpine:3`)
		return true
	}
}

// B86: grype vuln scan (scan/version/db status; not db delete/update login).
bash_grype_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	if bash_syft_grype_writes_file(a) {
		return false
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
		if sub == "login" || sub == "completion" {
			return false
		}
		if sub == "explain" {
			// local vulnerability docs
			return true
		}
		if sub == "db" {
			// grype db status|list|check inspect; update/delete mutates local DB
			db_rest := rem
			for {
				dt, drem := first_shell_token(db_rest)
				if dt == "" {
					return true
				}
				if strings.has_prefix(dt, "-") {
					db_rest = drem
					continue
				}
				dsub := strings.to_lower(dt, context.temp_allocator)
				if dsub == "status" ||
				   dsub == "list" ||
				   dsub == "check" ||
				   dsub == "providers" ||
				   dsub == "help" {
					return true
				}
				if dsub == "update" ||
				   dsub == "delete" ||
				   dsub == "import" ||
				   dsub == "export" {
					return false
				}
				return false
			}
		}
		if sub == "version" || sub == "help" {
			return true
		}
		// bare target scan: grype alpine:3
		return true
	}
}

// B86: trivy scan (image/fs/config/repo/sbom/k8s/version; not server/plugin/login/clean).
bash_trivy_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	// --output / -o file (not stdout)
	if bash_trivy_writes_file(a) {
		return false
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
		// mutators / long-running / auth (registry → login; vex → mutators)
		if sub == "server" ||
		   sub == "plugin" ||
		   sub == "login" ||
		   sub == "registry" ||
		   sub == "clean" ||
		   sub == "completion" ||
		   sub == "module" ||
		   sub == "vex" {
			return false
		}
		// inspect scanners
		if sub == "image" ||
		   sub == "fs" ||
		   sub == "filesystem" ||
		   sub == "repo" ||
		   sub == "repository" ||
		   sub == "config" ||
		   sub == "rootfs" ||
		   sub == "sbom" ||
		   sub == "kubernetes" ||
		   sub == "k8s" ||
		   sub == "vm" ||
		   sub == "aws" ||
		   sub == "azure" ||
		   sub == "google" ||
		   sub == "convert" ||
		   sub == "version" ||
		   sub == "help" {
			return true
		}
		// legacy: trivy <image>
		return true
	}
}

// syft/grype: -o/--file report path (not stdout/-)
bash_syft_grype_writes_file :: proc(args: string) -> bool {
	rest := args
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return false
		}
		if tok == "--file" || tok == "-f" {
			next, _ := first_shell_token(rem)
			if next != "" && next != "-" && !strings.has_prefix(next, "-") {
				return true
			}
		}
		if strings.has_prefix(tok, "--file=") {
			val := tok[strings.index_byte(tok, '=') + 1:]
			if val != "" && val != "-" {
				return true
			}
		}
		// grype -o json is format; grype uses --file for path. syft -o is format template.
		// syft: --file writes; -o alone is format (allow)
		rest = rem
	}
}

// trivy: -o/--output file path
bash_trivy_writes_file :: proc(args: string) -> bool {
	rest := args
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return false
		}
		if tok == "--output" || tok == "-o" {
			next, _ := first_shell_token(rem)
			if next != "" && next != "-" && !strings.has_prefix(next, "-") {
				return true
			}
		}
		if strings.has_prefix(tok, "--output=") {
			val := tok[strings.index_byte(tok, '=') + 1:]
			if val != "" && val != "-" {
				return true
			}
		}
		rest = rem
	}
}

// B84: k3d inspect (cluster list/get/version; not create/delete/start).
bash_k3d_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
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
		// resource groups
		if sub == "cluster" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" ||
				n == "list" ||
				n == "ls" ||
				n == "get" ||
				n == "help" ||
				n == "--help"
		}
		if sub == "node" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "list" || n == "ls" || n == "get" || n == "help" || n == "--help"
		}
		if sub == "image" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			// import mutates; list none — fail closed for import
			return n == "help" || n == "--help"
		}
		if sub == "registry" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "list" || n == "ls" || n == "get" || n == "help" || n == "--help"
		}
		if sub == "kubeconfig" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			// get prints; merge/write asks
			return n == "get" || n == "help" || n == "--help" || n == ""
		}
		// top-level mutators / shortcuts
		if sub == "create" ||
		   sub == "delete" ||
		   sub == "start" ||
		   sub == "stop" ||
		   sub == "import-images" ||
		   sub == "completion" {
			return false
		}
		if sub == "version" || sub == "help" || sub == "config" {
			if sub == "config" {
				// config init may write
				next, _ := first_shell_token(rem)
				n := strings.to_lower(next, context.temp_allocator)
				return n == "" || n == "help" || n == "--help"
			}
			return true
		}
		return false
	}
}

// B84: tilt inspect (version/describe/get/args; not up/down/ci/trigger).
bash_tilt_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   a == "args" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "-f" || tok == "--file" || tok == "--context" || tok == "--namespace" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--file=") ||
		   strings.has_prefix(tok, "--context=") ||
		   strings.has_prefix(tok, "-f") && len(tok) > 2 {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		// mutators / long-running
		if sub == "up" ||
		   sub == "down" ||
		   sub == "ci" ||
		   sub == "demo" ||
		   sub == "trigger" ||
		   sub == "docker" ||
		   sub == "alpha" ||
		   sub == "snapshot" ||
		   sub == "create-snapshot" ||
		   sub == "completion" ||
		   sub == "verify-install" {
			return false
		}
		// inspect
		if sub == "version" ||
		   sub == "help" ||
		   sub == "describe" ||
		   sub == "get" ||
		   sub == "args" ||
		   sub == "api-resources" ||
		   sub == "dump" ||
		   sub == "logs" ||
		   sub == "explain" {
			return true
		}
		return false
	}
}

// B83: kind inspect (get/list/version/export; not create/delete/load).
bash_kind_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
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
		// mutators
		if sub == "create" ||
		   sub == "delete" ||
		   sub == "load" ||
		   sub == "export" || // export kubeconfig may write - refine
		   sub == "build" ||
		   sub == "completion" {
			if sub == "export" {
				// kind export kubeconfig - often writes; fail closed
				return false
			}
			if sub == "completion" {
				return false
			}
			return false
		}
		// get / version
		if sub == "get" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			// get clusters / get nodes / get kubeconfig (prints)
			return n == "" ||
				n == "clusters" ||
				n == "nodes" ||
				n == "kubeconfig" ||
				n == "help" ||
				n == "--help"
		}
		if sub == "version" || sub == "help" {
			return true
		}
		return false
	}
}

// B83: minikube inspect (status/profile list/version/ip; not start/stop/delete).
bash_minikube_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "-p" || tok == "--profile" || tok == "--node" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--profile=") ||
		   strings.has_prefix(tok, "-p") && len(tok) > 2 {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		// mutators
		if sub == "start" ||
		   sub == "stop" ||
		   sub == "delete" ||
		   sub == "pause" ||
		   sub == "unpause" ||
		   sub == "ssh" ||
		   sub == "cp" ||
		   sub == "mount" ||
		   sub == "tunnel" ||
		   sub == "dashboard" ||
		   sub == "service" || // may open browser / tunnel
		   sub == "addons" || // enable/disable; list is inspect
		   sub == "config" ||
		   sub == "image" ||
		   sub == "cache" ||
		   sub == "update-context" ||
		   sub == "kubectl" ||
		   sub == "node" ||
		   sub == "completion" {
			if sub == "addons" {
				next, _ := first_shell_token(rem)
				n := strings.to_lower(next, context.temp_allocator)
				return n == "list" || n == "help" || n == "--help" || n == ""
			}
			if sub == "config" {
				next, _ := first_shell_token(rem)
				n := strings.to_lower(next, context.temp_allocator)
				return n == "view" || n == "get" || n == "defaults" || n == "help" || n == "--help" || n == ""
			}
			if sub == "image" {
				next, _ := first_shell_token(rem)
				n := strings.to_lower(next, context.temp_allocator)
				return n == "ls" || n == "list" || n == "help" || n == "--help"
			}
			if sub == "profile" {
				// handled below
			}
			if sub == "node" {
				next, _ := first_shell_token(rem)
				n := strings.to_lower(next, context.temp_allocator)
				return n == "list" || n == "help" || n == "--help" || n == ""
			}
			if sub == "service" {
				next, _ := first_shell_token(rem)
				n := strings.to_lower(next, context.temp_allocator)
				// list only
				return n == "list" || n == "help" || n == "--help"
			}
			if sub != "profile" {
				return false
			}
		}
		if sub == "profile" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			// list only (not set/delete)
			return n == "" || n == "list" || n == "help" || n == "--help"
		}
		// inspect
		if sub == "status" ||
		   sub == "version" ||
		   sub == "help" ||
		   sub == "ip" ||
		   sub == "logs" ||
		   sub == "docker-env" ||
		   sub == "podman-env" ||
		   sub == "ssh-key" ||
		   sub == "ssh-host" ||
		   sub == "update-check" ||
		   sub == "license" ||
		   sub == "options" {
			// docker-env / podman-env print shell — inspect
			return true
		}
		return false
	}
}

// B82: skaffold inspect (diagnose/render/version/schema; not run/dev/delete).
bash_skaffold_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		// common globals that take values
		if tok == "-f" ||
		   tok == "--filename" ||
		   tok == "-p" ||
		   tok == "--profile" ||
		   tok == "--kube-context" ||
		   tok == "--namespace" ||
		   tok == "-n" ||
		   tok == "--kubeconfig" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--filename=") ||
		   strings.has_prefix(tok, "--profile=") ||
		   strings.has_prefix(tok, "--kube-context=") ||
		   strings.has_prefix(tok, "--namespace=") ||
		   strings.has_prefix(tok, "--kubeconfig=") ||
		   (strings.has_prefix(tok, "-f") && len(tok) > 2) ||
		   (strings.has_prefix(tok, "-p") && len(tok) > 2) {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		// mutators / runners
		if sub == "run" ||
		   sub == "dev" ||
		   sub == "debug" ||
		   sub == "delete" ||
		   sub == "deploy" ||
		   sub == "build" ||
		   sub == "test" ||
		   sub == "apply" ||
		   sub == "verify" ||
		   sub == "exec" ||
		   sub == "filter-api-server-logs" ||
		   sub == "init" ||
		   sub == "fix" ||
		   sub == "survey" ||
		   sub == "credits" {
			// credits is inspect-ish
			if sub == "credits" {
				return true
			}
			return false
		}
		// inspect
		if sub == "diagnose" ||
		   sub == "render" ||
		   sub == "schema" ||
		   sub == "version" ||
		   sub == "help" ||
		   sub == "config" ||
		   sub == "completion" ||
		   sub == "options" ||
		   sub == "inspect" {
			// completion writes shell files
			if sub == "completion" {
				return false
			}
			// config set mutates
			if sub == "config" {
				next, _ := first_shell_token(rem)
				n := strings.to_lower(next, context.temp_allocator)
				return n == "" ||
					n == "list" ||
					n == "get" ||
					n == "help" ||
					n == "--help"
			}
			return true
		}
		return false
	}
}

// B81: kustomize inspect (build/cfg/version; not edit/create to disk).
bash_kustomize_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	// -o/--output to a path writes files — fail closed (anywhere in args)
	if bash_kustomize_writes_output(a) {
		return false
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if strings.has_prefix(tok, "-") {
			// peel flags (value-taking already handled for -o)
			if tok == "-f" ||
			   tok == "--filename" ||
			   tok == "--load-restrictor" ||
			   tok == "--enable-helm" {
				// some take values
				if tok == "-f" || tok == "--filename" || tok == "--load-restrictor" {
					_, rest2 := first_shell_token(rem)
					rest = rest2
					continue
				}
				rest = rem
				continue
			}
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		if sub == "edit" ||
		   sub == "create" ||
		   sub == "localize" ||
		   sub == "fix" ||
		   sub == "completion" {
			return false
		}
		if sub == "build" ||
		   sub == "cfg" ||
		   sub == "version" ||
		   sub == "help" ||
		   sub == "openapi" {
			// remaining tokens are paths/flags — already checked -o
			return true
		}
		return false
	}
}

// bash_kustomize_writes_output: true if -o/--output targets a non-stdout path.
bash_kustomize_writes_output :: proc(args: string) -> bool {
	rest := args
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return false
		}
		if tok == "-o" || tok == "--output" {
			next, _ := first_shell_token(rem)
			if next != "" && next != "-" && !strings.has_prefix(next, "-") {
				return true
			}
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-o=") || strings.has_prefix(tok, "--output=") {
			eq := strings.index_byte(tok, '=')
			if eq >= 0 && eq + 1 < len(tok) {
				val := tok[eq + 1:]
				if val != "" && val != "-" {
					return true
				}
			}
			rest = rem
			continue
		}
		rest = rem
	}
}

// B81: kubectx — list/current only (switching context is mild mutate → ask).
bash_kubectx_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		// bare lists contexts
		return true
	}
	if a == "--help" || a == "-h" || a == "help" || a == "--current" || a == "-c" {
		return true
	}
	// any positional name switches context
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "--help" || tok == "-h" || tok == "--current" || tok == "-c" {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		// context name / - (previous) switches
		return false
	}
}

// B81: kubens — list/current only (switching ns asks).
bash_kubens_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "--help" || a == "-h" || a == "help" || a == "--current" || a == "-c" {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "--help" || tok == "-h" || tok == "--current" || tok == "-c" {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		return false
	}
}

// B79: istioctl inspect (version/proxy-status/analyze/proxy-config; not install/apply).
bash_istioctl_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "--kubeconfig" ||
		   tok == "--context" ||
		   tok == "--namespace" ||
		   tok == "-n" ||
		   tok == "--istioNamespace" ||
		   tok == "-i" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--kubeconfig=") ||
		   strings.has_prefix(tok, "--context=") ||
		   strings.has_prefix(tok, "--namespace=") ||
		   strings.has_prefix(tok, "--istioNamespace=") ||
		   (strings.has_prefix(tok, "-n") && len(tok) > 2) {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		// mutators / writers
		if sub == "install" ||
		   sub == "uninstall" ||
		   sub == "upgrade" ||
		   sub == "apply" ||
		   sub == "delete" ||
		   sub == "create" ||
		   sub == "replace" ||
		   sub == "experimental" ||
		   sub == "x" ||
		   sub == "dashboard" ||
		   sub == "kube-inject" ||
		   sub == "admin" ||
		   sub == "bug-report" ||
		   sub == "tag" ||
		   sub == "waypoint" {
			return false
		}
		// inspect
		if sub == "version" ||
		   sub == "help" ||
		   sub == "proxy-status" ||
		   sub == "ps" ||
		   sub == "analyze" ||
		   sub == "validate" ||
		   sub == "proxy-config" ||
		   sub == "pc" ||
		   sub == "ztunnel-config" ||
		   sub == "wait" {
			return true
		}
		if sub == "remote" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "list" || n == "help" || n == "--help"
		}
		return false
	}
}

// B78: Flux CLI inspect (get/export/tree/logs; not create/delete/reconcile/bootstrap).
bash_flux_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   a == "check" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") ||
	   strings.has_prefix(a, "check ") {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		// kubeconfig globals
		if tok == "--kubeconfig" ||
		   tok == "--context" ||
		   tok == "--namespace" ||
		   tok == "-n" ||
		   tok == "--kube-api-burst" ||
		   tok == "--kube-api-qps" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--kubeconfig=") ||
		   strings.has_prefix(tok, "--context=") ||
		   strings.has_prefix(tok, "--namespace=") ||
		   (strings.has_prefix(tok, "-n") && len(tok) > 2) {
			rest = rem
			continue
		}
		if tok == "--verbose" || tok == "-v" {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		// mutators
		if sub == "bootstrap" ||
		   sub == "install" ||
		   sub == "uninstall" ||
		   sub == "create" ||
		   sub == "delete" ||
		   sub == "suspend" ||
		   sub == "resume" ||
		   sub == "reconcile" ||
		   sub == "migrate" ||
		   sub == "push" ||
		   sub == "pull" ||
		   sub == "build" ||
		   sub == "trace" ||
		   sub == "events" ||
		   sub == "stats" ||
		   sub == "completion" ||
		   sub == "envsubst" {
			// build is kustomize-ish local; still may write — fail closed
			// events/stats/trace are inspect
			if sub == "events" || sub == "stats" || sub == "trace" {
				return true
			}
			return false
		}
		// get / export / tree / logs / diff — inspect families
		if sub == "get" ||
		   sub == "export" ||
		   sub == "tree" ||
		   sub == "logs" ||
		   sub == "diff" ||
		   sub == "version" ||
		   sub == "help" ||
		   sub == "check" {
			return true
		}
		return false
	}
}

// B77: Argo CD CLI inspect (app list/get/diff; not sync/delete/login).
bash_argocd_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "--server" ||
		   tok == "--auth-token" ||
		   tok == "--grpc-web-root-path" ||
		   tok == "--header" ||
		   tok == "-H" ||
		   tok == "--loglevel" ||
		   tok == "--logformat" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--server=") ||
		   strings.has_prefix(tok, "--auth-token=") ||
		   strings.has_prefix(tok, "--loglevel=") {
			rest = rem
			continue
		}
		if tok == "--grpc-web" ||
		   tok == "--plaintext" ||
		   tok == "--insecure" ||
		   tok == "--core" {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)

		if sub == "login" ||
		   sub == "logout" ||
		   sub == "account" ||
		   sub == "gpg" ||
		   sub == "cert" ||
		   sub == "admin" {
			return false
		}
		if sub == "cluster" || sub == "repo" || sub == "proj" || sub == "project" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "list" || n == "get" || n == "help" || n == "--help"
		}
		if sub == "app" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			// inspect
			if n == "" ||
			   n == "list" ||
			   n == "get" ||
			   n == "diff" ||
			   n == "history" ||
			   n == "manifests" ||
			   n == "resources" ||
			   n == "logs" ||
			   n == "help" ||
			   n == "--help" {
				return true
			}
			// sync/create/delete/set/patch/wait/edit/rollback
			return false
		}
		if sub == "applicationset" || sub == "appset" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "list" || n == "get" || n == "help" || n == "--help"
		}
		if sub == "context" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "list" || n == "help" || n == "--help"
		}
		if sub == "version" || sub == "help" {
			return true
		}
		return false
	}
}

// B76: Vault inspect — status/version/list metadata only.
// Never auto-allow read/kv get (secret exfil) or write/delete/login.
bash_vault_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   a == "status" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") ||
	   strings.has_prefix(a, "status ") {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "-address" ||
		   tok == "-namespace" ||
		   tok == "-ca-cert" ||
		   tok == "-client-cert" ||
		   tok == "-client-key" ||
		   tok == "-token" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "-address=") ||
		   strings.has_prefix(tok, "-namespace=") ||
		   strings.has_prefix(tok, "-token=") {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)

		if sub == "status" ||
		   sub == "version" ||
		   sub == "help" ||
		   sub == "print" ||
		   sub == "path-help" {
			return true
		}
		// mount / auth method listing only
		if sub == "secrets" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "list" || n == "help" || n == "--help"
		}
		if sub == "auth" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "list" || n == "help" || n == "--help"
		}
		if sub == "policy" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "list" || n == "help" || n == "--help"
		}
		if sub == "operator" {
			next, nrem := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			if n == "raft" {
				n2, _ := first_shell_token(nrem)
				n2l := strings.to_lower(n2, context.temp_allocator)
				return n2l == "" || n2l == "list-peers" || n2l == "help" || n2l == "--help"
			}
			return n == "members" || n == "key-status" || n == "help" || n == "--help"
		}
		// everything else (read/write/kv/login/token/…) asks
		return false
	}
}

// B75: Consul inspect (members/catalog/kv get/info; not put/delete/join).
bash_consul_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "-http-addr" ||
		   tok == "-datacenter" ||
		   tok == "-token" ||
		   tok == "-ca-file" ||
		   tok == "-client-cert" ||
		   tok == "-client-key" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "-http-addr=") ||
		   strings.has_prefix(tok, "-datacenter=") ||
		   strings.has_prefix(tok, "-token=") {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		// hard mutators / sensitive
		if sub == "join" ||
		   sub == "leave" ||
		   sub == "force-leave" ||
		   sub == "reload" ||
		   sub == "monitor" ||
		   sub == "exec" ||
		   sub == "lock" ||
		   sub == "watch" ||
		   sub == "connect" ||
		   sub == "acl" ||
		   sub == "operator" ||
		   sub == "services" ||
		   sub == "event" ||
		   sub == "rtt" {
			return false
		}
		if sub == "snapshot" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "inspect" || n == "help" || n == "--help"
		}
		if sub == "config" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "list" || n == "read" || n == "help" || n == "--help"
		}
		if sub == "catalog" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" ||
				n == "datacenters" ||
				n == "nodes" ||
				n == "services" ||
				n == "node" ||
				n == "service" ||
				n == "help" ||
				n == "--help"
		}
		if sub == "kv" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			// get/export only (not put/delete/import)
			return n == "get" || n == "export" || n == "help" || n == "--help"
		}
		if sub == "intention" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "list" || n == "get" || n == "match" || n == "check" || n == "help" || n == "--help"
		}
		if sub == "health" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" ||
				n == "node" ||
				n == "checks" ||
				n == "service" ||
				n == "state" ||
				n == "help" ||
				n == "--help"
		}
		if sub == "members" ||
		   sub == "info" ||
		   sub == "validate" ||
		   sub == "version" ||
		   sub == "help" {
			return true
		}
		return false
	}
}

// B75: Nomad inspect (status/node status/job status; not run/stop/alloc exec).
bash_nomad_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "-address" ||
		   tok == "-region" ||
		   tok == "-namespace" ||
		   tok == "-token" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "-address=") ||
		   strings.has_prefix(tok, "-region=") ||
		   strings.has_prefix(tok, "-namespace=") ||
		   strings.has_prefix(tok, "-token=") {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)

		if sub == "run" ||
		   sub == "stop" ||
		   sub == "system" ||
		   sub == "operator" ||
		   sub == "acl" ||
		   sub == "volume" ||
		   sub == "var" ||
		   sub == "quota" ||
		   sub == "sentinel" ||
		   sub == "namespace" ||
		   sub == "scaling" ||
		   sub == "service" ||
		   sub == "ui" ||
		   sub == "monitor" {
			return false
		}
		if sub == "job" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" ||
				n == "status" ||
				n == "history" ||
				n == "inspect" ||
				n == "allocations" ||
				n == "evals" ||
				n == "deployments" ||
				n == "plan" ||
				n == "validate" ||
				n == "help" ||
				n == "--help"
		}
		if sub == "alloc" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			// status/logs/fs only (not exec/restart/signal)
			return n == "" ||
				n == "status" ||
				n == "logs" ||
				n == "fs" ||
				n == "checks" ||
				n == "help" ||
				n == "--help"
		}
		if sub == "deployment" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "status" || n == "list" || n == "help" || n == "--help"
		}
		if sub == "node" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			if n == "drain" || n == "eligibility" || n == "purge" {
				return false
			}
			// status or bare id
			return n == "" || n == "status" || n == "help" || n == "--help" || !strings.has_prefix(n, "-")
		}
		if sub == "server" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "members" || n == "help" || n == "--help"
		}
		if sub == "agent" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "info" || n == "self" || n == "health" || n == "help" || n == "--help"
		}
		if sub == "fmt" {
			r2 := rem
			has_check := false
			for {
				t2, r3 := first_shell_token(r2)
				if t2 == "" {
					break
				}
				if t2 == "-check" || t2 == "--check" {
					has_check = true
				}
				r2 = r3
			}
			return has_check
		}
		if sub == "status" || sub == "version" || sub == "help" {
			return true
		}
		return false
	}
}

// B74: Packer inspect (validate/inspect/version/fmt -check; not build/init).
bash_packer_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		// value-taking globals
		if tok == "-var" ||
		   tok == "-var-file" ||
		   tok == "-except" ||
		   tok == "-only" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "-var=") ||
		   strings.has_prefix(tok, "-var-file=") ||
		   strings.has_prefix(tok, "-except=") ||
		   strings.has_prefix(tok, "-only=") {
			rest = rem
			continue
		}
		if tok == "-color" ||
		   tok == "-machine-readable" ||
		   tok == "-check" ||
		   tok == "-diff" ||
		   tok == "-write=false" {
			rest = rem
			continue
		}
		if tok == "-write" || tok == "-write=true" {
			return false
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		// mutators
		if sub == "build" ||
		   sub == "init" ||
		   sub == "console" ||
		   sub == "fix" ||
		   sub == "hcl2_upgrade" ||
		   sub == "plugins" ||
		   sub == "plugin" {
			return false
		}
		// fmt: only with -check (no write)
		if sub == "fmt" {
			r2 := rem
			has_check := false
			for {
				t2, r3 := first_shell_token(r2)
				if t2 == "" {
					break
				}
				if t2 == "-check" || strings.has_prefix(t2, "-check=") {
					has_check = true
				}
				if t2 == "-write=true" || t2 == "-write" {
					return false
				}
				r2 = r3
			}
			return has_check
		}
		// inspect
		if sub == "validate" ||
		   sub == "inspect" ||
		   sub == "version" ||
		   sub == "help" {
			return true
		}
		return false
	}
}

// B73: vagrant inspect (status/global-status/box list/validate; not up/destroy).
bash_vagrant_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "--machine-readable" ||
		   tok == "--color" ||
		   tok == "--no-color" ||
		   tok == "--debug" ||
		   tok == "-v" ||
		   tok == "--verbose" {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		// box: list/outdated/info only
		if sub == "box" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" ||
				n == "list" ||
				n == "outdated" ||
				n == "info" ||
				n == "help" ||
				n == "--help"
		}
		// plugin: list only
		if sub == "plugin" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "list" || n == "license" || n == "help" || n == "--help"
		}
		// snapshot: list only
		if sub == "snapshot" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "list" || n == "help" || n == "--help"
		}
		// mutators
		if sub == "up" ||
		   sub == "destroy" ||
		   sub == "halt" ||
		   sub == "suspend" ||
		   sub == "resume" ||
		   sub == "reload" ||
		   sub == "provision" ||
		   sub == "ssh" ||
		   sub == "rdp" ||
		   sub == "winrm" ||
		   sub == "push" ||
		   sub == "package" ||
		   sub == "init" ||
		   sub == "cloud" ||
		   sub == "rsync" ||
		   sub == "rsync-auto" ||
		   sub == "share" ||
		   sub == "login" ||
		   sub == "upload" ||
		   sub == "download" ||
		   sub == "powershell" {
			return false
		}
		// inspect
		if sub == "status" ||
		   sub == "global-status" ||
		   sub == "validate" ||
		   sub == "version" ||
		   sub == "help" ||
		   sub == "list-commands" ||
		   sub == "ssh-config" ||
		   sub == "port" {
			return true
		}
		return false
	}
}

// B72: ansible ad-hoc — list-hosts/version only (not -m module runs).
bash_ansible_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "--version" || a == "--help" || a == "-h" {
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
		if tok == "-i" ||
		   tok == "--inventory" ||
		   tok == "--inventory-file" ||
		   tok == "-l" ||
		   tok == "--limit" ||
		   tok == "-e" ||
		   tok == "--extra-vars" ||
		   tok == "-u" ||
		   tok == "--user" ||
		   tok == "-c" ||
		   tok == "--connection" ||
		   tok == "-t" ||
		   tok == "--tree" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "-i") && len(tok) > 2 {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "--inventory=") ||
		   strings.has_prefix(tok, "--limit=") ||
		   strings.has_prefix(tok, "--extra-vars=") ||
		   strings.has_prefix(tok, "--user=") {
			rest = rem
			continue
		}
		// module execution — not inspect
		if tok == "-m" ||
		   tok == "--module-name" ||
		   tok == "-a" ||
		   tok == "--args" ||
		   tok == "-b" ||
		   tok == "--become" ||
		   tok == "-k" ||
		   tok == "--ask-pass" {
			return false
		}
		if strings.has_prefix(tok, "--module-name=") || strings.has_prefix(tok, "--args=") {
			return false
		}
		if tok == "--list-hosts" || tok == "--version" || tok == "--help" || tok == "-h" {
			saw_inspect = true
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		// host pattern positional — ok with list-hosts
		rest = rem
	}
	return saw_inspect
}

// B72: ansible-playbook list/syntax only (not applying a playbook).
bash_ansible_playbook_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false
	}
	if a == "--version" || a == "--help" || a == "-h" {
		return true
	}
	rest := a
	saw_inspect := false
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		if tok == "-i" ||
		   tok == "--inventory" ||
		   tok == "-l" ||
		   tok == "--limit" ||
		   tok == "-e" ||
		   tok == "--extra-vars" ||
		   tok == "-t" ||
		   tok == "--tags" ||
		   tok == "--skip-tags" ||
		   tok == "--start-at-task" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--inventory=") ||
		   strings.has_prefix(tok, "--limit=") ||
		   strings.has_prefix(tok, "--tags=") ||
		   strings.has_prefix(tok, "--extra-vars=") {
			rest = rem
			continue
		}
		// apply-ish
		if tok == "--check" || // dry-run still touches remote somewhat; fail closed
		   tok == "-C" ||
		   tok == "--diff" ||
		   tok == "-D" ||
		   tok == "-b" ||
		   tok == "--become" ||
		   tok == "-k" ||
		   tok == "--ask-pass" ||
		   tok == "--ask-become-pass" ||
		   tok == "-K" {
			// --check is borderline; fail closed for apply family
			if tok == "--check" || tok == "-C" || tok == "--diff" || tok == "-D" {
				return false
			}
			return false
		}
		if tok == "--list-hosts" ||
		   tok == "--list-tasks" ||
		   tok == "--list-tags" ||
		   tok == "--syntax-check" ||
		   tok == "--version" ||
		   tok == "--help" ||
		   tok == "-h" {
			saw_inspect = true
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		// playbook path positional — ok if inspect flag present
		rest = rem
	}
	return saw_inspect
}

// B72: ansible-inventory is almost entirely inspect.
bash_ansible_inventory_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	rest := a
	saw_inspect := false
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		if tok == "-i" || tok == "--inventory" || tok == "--host" || tok == "--toml" || tok == "--yaml" || tok == "--json" {
			if tok == "--host" || tok == "-i" || tok == "--inventory" {
				_, rest2 := first_shell_token(rem)
				rest = rest2
				if tok == "--host" {
					saw_inspect = true
				}
				continue
			}
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "--inventory=") || strings.has_prefix(tok, "--host=") {
			if strings.has_prefix(tok, "--host=") {
				saw_inspect = true
			}
			rest = rem
			continue
		}
		if tok == "--list" ||
		   tok == "--graph" ||
		   tok == "--export" ||
		   tok == "--version" ||
		   tok == "--help" ||
		   tok == "-h" ||
		   tok == "--playbook-dir" {
			if tok == "--playbook-dir" {
				_, rest2 := first_shell_token(rem)
				rest = rest2
				continue
			}
			saw_inspect = true
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		rest = rem
	}
	// default ansible-inventory --list is common; bare may print help
	return saw_inspect || a == "" || strings.contains(a, "--list") || strings.contains(a, "--graph")
}

// B72: ansible-doc is documentation (always inspect).
bash_ansible_doc_is_readonly :: proc(args: string) -> bool {
	_ = args
	return true
}

// B72: ansible-config view/list/dump only (not init).
bash_ansible_config_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" || a == "--help" || a == "-h" || a == "help" {
		return true
	}
	sub, _ := first_shell_token(a)
	sub_l := strings.to_lower(sub, context.temp_allocator)
	return sub_l == "list" ||
		sub_l == "dump" ||
		sub_l == "view" ||
		sub_l == "help" ||
		sub_l == "--help" ||
		sub_l == "-h" ||
		sub_l == "--version"
}

// B72: ansible-galaxy list/search/info only (not install/remove).
bash_ansible_galaxy_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" || a == "--help" || a == "-h" || a == "--version" {
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
		// collection / role groups
		if sub == "collection" || sub == "role" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			if n == "install" ||
			   n == "remove" ||
			   n == "download" ||
			   n == "init" ||
			   n == "build" ||
			   n == "publish" ||
			   n == "verify" {
				return false
			}
			return n == "" ||
				n == "list" ||
				n == "search" ||
				n == "info" ||
				n == "help" ||
				n == "--help"
		}
		if sub == "install" ||
		   sub == "remove" ||
		   sub == "delete" ||
		   sub == "init" ||
		   sub == "build" ||
		   sub == "publish" ||
		   sub == "import" ||
		   sub == "setup" {
			return false
		}
		if sub == "list" ||
		   sub == "search" ||
		   sub == "info" ||
		   sub == "help" ||
		   sub == "--version" {
			return true
		}
		return false
	}
}

// B71: Pulumi inspect (stack ls/output, config get, about; not up/destroy/preview).
bash_pulumi_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if a == "version" ||
	   a == "--version" ||
	   a == "help" ||
	   a == "--help" ||
	   a == "-h" ||
	   a == "about" ||
	   a == "whoami" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") ||
	   strings.has_prefix(a, "about ") ||
	   strings.has_prefix(a, "whoami ") {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		// globals that take values
		if tok == "-C" ||
		   tok == "--cwd" ||
		   tok == "-s" ||
		   tok == "--stack" ||
		   tok == "--color" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if tok == "-v" || tok == "--verbose" {
			n, nrem := first_shell_token(rem)
			if n != "" && len(n) > 0 && n[0] >= '0' && n[0] <= '9' {
				rest = nrem
				continue
			}
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "--cwd=") ||
		   strings.has_prefix(tok, "--stack=") ||
		   strings.has_prefix(tok, "--color=") ||
		   (strings.has_prefix(tok, "-C") && len(tok) > 2) ||
		   (strings.has_prefix(tok, "-s") && len(tok) > 2) {
			rest = rem
			continue
		}
		if tok == "--non-interactive" ||
		   tok == "-y" ||
		   tok == "--yes" ||
		   tok == "--logtostderr" ||
		   tok == "--logflow" {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)

		// hard mutators
		if sub == "up" ||
		   sub == "destroy" ||
		   sub == "refresh" ||
		   sub == "cancel" ||
		   sub == "import" ||
		   sub == "new" ||
		   sub == "init" ||
		   sub == "login" ||
		   sub == "logout" ||
		   sub == "preview" ||
		   sub == "watch" ||
		   sub == "install" ||
		   sub == "convert" ||
		   sub == "package" ||
		   sub == "org" ||
		   sub == "env" ||
		   sub == "gen-completion" {
			return false
		}

		// state: list/get only
		if sub == "state" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "list" || n == "get" || n == "help" || n == "--help"
		}
		// plugin: ls only
		if sub == "plugin" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "ls" || n == "list" || n == "help" || n == "--help"
		}
		// stack: list/output/history/export/graph only
		if sub == "stack" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" ||
				n == "ls" ||
				n == "list" ||
				n == "output" ||
				n == "outputs" ||
				n == "history" ||
				n == "export" ||
				n == "graph" ||
				n == "help" ||
				n == "--help"
		}
		// config: get/list / bare list / key get
		if sub == "config" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			if n == "set" || n == "rm" || n == "cp" || n == "refresh" || n == "env" {
				return false
			}
			return true
		}
		// policy ls
		if sub == "policy" {
			next, _ := first_shell_token(rem)
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" || n == "ls" || n == "list" || n == "help" || n == "--help"
		}
		// inspect top-level
		if sub == "logs" ||
		   sub == "history" ||
		   sub == "about" ||
		   sub == "whoami" ||
		   sub == "version" ||
		   sub == "help" ||
		   sub == "schema" {
			return true
		}
		return false
	}
}

// B70: Bazel / bazelisk inspect (query/cquery/info/version; not build/run/test).
bash_bazel_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		// bare bazel — help-ish
		return true
	}
	if a == "help" ||
	   a == "version" ||
	   a == "--version" ||
	   a == "--help" ||
	   a == "-h" ||
	   strings.has_prefix(a, "help ") ||
	   strings.has_prefix(a, "version ") {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		// startup options that take values
		if tok == "--output_base" ||
		   tok == "--output_user_root" ||
		   tok == "--server_javabase" ||
		   tok == "--host_jvm_args" ||
		   tok == "--bazelrc" ||
		   tok == "--block_for_lock" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--output_base=") ||
		   strings.has_prefix(tok, "--output_user_root=") ||
		   strings.has_prefix(tok, "--server_javabase=") ||
		   strings.has_prefix(tok, "--host_jvm_args=") ||
		   strings.has_prefix(tok, "--bazelrc=") {
			rest = rem
			continue
		}
		if tok == "--batch" ||
		   tok == "--nobatch" ||
		   tok == "--nosystem_rc" ||
		   tok == "--nohome_rc" ||
		   tok == "--noworkspace_rc" ||
		   tok == "--ignore_all_rc_files" {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			// other startup flags — peel; real command follows
			rest = rem
			continue
		}
		// first non-flag is command
		cmd := strings.to_lower(tok, context.temp_allocator)
		// mutators
		if cmd == "build" ||
		   cmd == "run" ||
		   cmd == "test" ||
		   cmd == "coverage" ||
		   cmd == "mobile-install" ||
		   cmd == "fetch" || // downloads deps — borderline; fail closed (network+cache write)
		   cmd == "sync" ||
		   cmd == "shutdown" ||
		   cmd == "clean" ||
		   cmd == "mod" || // mod tidy etc mutate
		   cmd == "vendor" ||
		   cmd == "canonicalize-flags" {
			return false
		}
		// inspect
		if cmd == "query" ||
		   cmd == "cquery" ||
		   cmd == "aquery" ||
		   cmd == "info" ||
		   cmd == "version" ||
		   cmd == "help" ||
		   cmd == "dump" ||
		   cmd == "analyze-profile" ||
		   cmd == "print_action" ||
		   cmd == "config" ||
		   cmd == "license" ||
		   cmd == "workspace" { // prints workspace path
			return true
		}
		return false
	}
}

// B69: sbt inspect (tasks/about/dependencyTree/…; not compile/run/test).
// Note: bare `sbt` drops into interactive shell → ask.
bash_sbt_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false
	}
	if a == "--version" ||
	   a == "-version" ||
	   a == "--help" ||
	   a == "-h" ||
	   a == "help" ||
	   a == "about" ||
	   a == "version" {
		return true
	}
	rest := a
	saw_inspect := false
	// after show/inspect/print/tasks, remaining tokens are setting/task names (inspect)
	after_inspect_cmd := false
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		// common sbt globals / JVM opts
		if tok == "-D" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "-D") ||
		   strings.has_prefix(tok, "-J") ||
		   tok == "-batch" ||
		   tok == "--batch" ||
		   tok == "-no-colors" ||
		   tok == "--no-colors" ||
		   tok == "-supershell=false" ||
		   tok == "-error" ||
		   tok == "-warn" ||
		   tok == "-info" ||
		   tok == "-debug" {
			rest = rem
			continue
		}
		if tok == "--version" || tok == "-version" || tok == "--help" || tok == "-h" {
			saw_inspect = true
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		// strip surrounding quotes if any (simple)
		t := tok
		if len(t) >= 2 && ((t[0] == '"' && t[len(t) - 1] == '"') || (t[0] == '\'' && t[len(t) - 1] == '\'')) {
			t = t[1:len(t) - 1]
		}
		tl := strings.to_lower(t, context.temp_allocator)
		// mutators / runners
		if tl == "compile" ||
		   tl == "test" ||
		   tl == "testonly" ||
		   tl == "run" ||
		   tl == "runmain" ||
		   tl == "package" ||
		   tl == "publish" ||
		   tl == "publishlocal" ||
		   tl == "publishm2" ||
		   tl == "clean" ||
		   tl == "reload" ||
		   tl == "update" ||
		   tl == "console" ||
		   tl == "consolequick" ||
		   tl == "consoleproject" ||
		   tl == "exit" ||
		   tl == "quit" ||
		   tl == "assembly" ||
		   tl == "stage" ||
		   strings.has_prefix(tl, "run ") ||
		   strings.has_prefix(tl, "test:") ||
		   strings.has_prefix(tl, "compile") ||
		   strings.contains(tl, "publish") {
			return false
		}
		// inspect-ish commands
		if tl == "tasks" ||
		   tl == "about" ||
		   tl == "settings" ||
		   tl == "inspect" ||
		   tl == "show" ||
		   tl == "print" ||
		   tl == "dependencytree" ||
		   tl == "dependencylist" ||
		   tl == "dependencygraph" ||
		   tl == "evicted" ||
		   tl == "plugins" ||
		   tl == "projects" ||
		   tl == "project" ||
		   strings.has_prefix(tl, "show ") ||
		   strings.has_prefix(tl, "inspect ") ||
		   strings.has_prefix(tl, "print ") ||
		   strings.has_prefix(tl, "tasks ") ||
		   strings.has_prefix(tl, "dependencytree") ||
		   strings.has_prefix(tl, "dependencylist") ||
		   strings.has_prefix(tl, "settings ") {
			saw_inspect = true
			if tl == "show" ||
			   tl == "inspect" ||
			   tl == "print" ||
			   tl == "tasks" ||
			   tl == "settings" ||
			   strings.has_prefix(tl, "show ") ||
			   strings.has_prefix(tl, "inspect ") ||
			   strings.has_prefix(tl, "print ") {
				after_inspect_cmd = true
			}
			rest = rem
			continue
		}
		// setting names after show/inspect/print
		if after_inspect_cmd {
			rest = rem
			continue
		}
		// unknown command → fail closed
		return false
	}
	return saw_inspect
}

// B67: Maven inspect (help/dependency:tree/…; not package/install/test).
bash_mvn_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		// bare mvn may run default lifecycle
		return false
	}
	if a == "--version" ||
	   a == "-v" ||
	   a == "-version" ||
	   a == "--help" ||
	   a == "-h" ||
	   a == "help" {
		return true
	}
	rest := a
	saw_inspect := false
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		// common value-taking flags
		if tok == "-f" ||
		   tok == "--file" ||
		   tok == "-s" ||
		   tok == "--settings" ||
		   tok == "-P" ||
		   tok == "--activate-profiles" ||
		   tok == "-pl" ||
		   tok == "--projects" ||
		   tok == "-am" ||
		   tok == "-D" {
			if tok == "-am" {
				rest = rem
				continue
			}
			// -Dfoo=bar may be one token or -D + value
			if tok == "-D" {
				_, rest2 := first_shell_token(rem)
				rest = rest2
				continue
			}
			if strings.has_prefix(tok, "-D") && len(tok) > 2 {
				rest = rem
				continue
			}
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "-D") ||
		   strings.has_prefix(tok, "--file=") ||
		   strings.has_prefix(tok, "--settings=") ||
		   strings.has_prefix(tok, "--activate-profiles=") ||
		   strings.has_prefix(tok, "--projects=") {
			rest = rem
			continue
		}
		if tok == "-q" ||
		   tok == "--quiet" ||
		   tok == "-B" ||
		   tok == "--batch-mode" ||
		   tok == "-o" ||
		   tok == "--offline" ||
		   tok == "-U" ||
		   tok == "-N" ||
		   tok == "--non-recursive" ||
		   tok == "--version" ||
		   tok == "-v" ||
		   tok == "-version" ||
		   tok == "--help" ||
		   tok == "-h" {
			if tok == "--version" || tok == "-v" || tok == "-version" || tok == "--help" || tok == "-h" {
				saw_inspect = true
			}
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		t := strings.to_lower(tok, context.temp_allocator)
		// lifecycle / mutator goals
		if t == "clean" ||
		   t == "validate" ||
		   t == "compile" ||
		   t == "test" ||
		   t == "package" ||
		   t == "verify" ||
		   t == "install" ||
		   t == "deploy" ||
		   t == "site" ||
		   t == "integration-test" ||
		   strings.has_prefix(t, "spring-boot:") ||
		   strings.has_prefix(t, "exec:") ||
		   strings.has_prefix(t, "jetty:") ||
		   strings.has_prefix(t, "tomcat:") ||
		   strings.has_prefix(t, "cargo:") ||
		   strings.has_prefix(t, "release:") {
			return false
		}
		// inspect plugins / goals
		if t == "help" ||
		   strings.has_prefix(t, "help:") ||
		   strings.has_prefix(t, "dependency:tree") ||
		   strings.has_prefix(t, "dependency:list") ||
		   strings.has_prefix(t, "dependency:analyze") ||
		   strings.has_prefix(t, "dependency:resolve") ||
		   strings.has_prefix(t, "dependency:purge-local-repository") || // mutates local repo!
		   t == "dependency:tree" ||
		   t == "dependency:list" ||
		   t == "dependency:analyze" ||
		   t == "dependency:resolve" ||
		   t == "dependency:resolve-sources" ||
		   t == "dependency:resolve-plugins" ||
		   t == "dependency:display-ancestors" ||
		   t == "dependency:get" ||
		   t == "versions:display-dependency-updates" ||
		   t == "versions:display-plugin-updates" ||
		   t == "versions:display-property-updates" ||
		   t == "versions:display-parent-updates" ||
		   t == "enforcer:display-info" ||
		   t == "project-info-reports:dependencies" {
			// purge is mutate — already partially matched; block purge explicitly
			if strings.contains(t, "purge") {
				return false
			}
			saw_inspect = true
			rest = rem
			continue
		}
		// unknown goal → fail closed
		return false
	}
	return saw_inspect
}

// B67: Gradle inspect (tasks/dependencies/projects; not build/test/run).
bash_gradle_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return false
	}
	if a == "--version" || a == "-v" || a == "--help" || a == "-h" || a == "help" {
		return true
	}
	rest := a
	saw_inspect := false
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			break
		}
		// value-taking globals
		if tok == "-p" ||
		   tok == "--project-dir" ||
		   tok == "-b" ||
		   tok == "--build-file" ||
		   tok == "-c" ||
		   tok == "--settings-file" ||
		   tok == "-g" ||
		   tok == "--gradle-user-home" ||
		   tok == "-D" ||
		   tok == "-P" ||
		   tok == "--console" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "-D") ||
		   strings.has_prefix(tok, "-P") ||
		   strings.has_prefix(tok, "--project-dir=") ||
		   strings.has_prefix(tok, "--build-file=") ||
		   strings.has_prefix(tok, "--settings-file=") ||
		   strings.has_prefix(tok, "--gradle-user-home=") ||
		   strings.has_prefix(tok, "--console=") {
			rest = rem
			continue
		}
		if tok == "-q" ||
		   tok == "--quiet" ||
		   tok == "-i" ||
		   tok == "--info" ||
		   tok == "--offline" ||
		   tok == "--version" ||
		   tok == "-v" ||
		   tok == "--help" ||
		   tok == "-h" ||
		   tok == "--dry-run" ||
		   tok == "-m" {
			if tok == "--version" ||
			   tok == "-v" ||
			   tok == "--help" ||
			   tok == "-h" ||
			   tok == "--dry-run" ||
			   tok == "-m" {
				saw_inspect = true
			}
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		t := strings.to_lower(tok, context.temp_allocator)
		// mutator tasks
		if t == "build" ||
		   t == "test" ||
		   t == "check" ||
		   t == "assemble" ||
		   t == "clean" ||
		   t == "run" ||
		   t == "bootrun" ||
		   t == "publish" ||
		   t == "publishtomavenlocal" ||
		   t == "install" ||
		   t == "jar" ||
		   t == "war" ||
		   t == "classes" ||
		   t == "compilejava" ||
		   t == "compilekotlin" ||
		   t == "compiletestjava" ||
		   t == "javadoc" ||
		   t == "disttar" ||
		   t == "distzip" ||
		   t == "wrapper" ||
		   t == "init" ||
		   strings.has_prefix(t, "publish") ||
		   strings.has_prefix(t, "deploy") ||
		   strings.has_prefix(t, "upload") ||
		   strings.has_prefix(t, "run") ||
		   strings.has_prefix(t, "boot") {
			return false
		}
		// inspect tasks (task names lowercased)
		if t == "tasks" ||
		   t == "help" ||
		   t == "dependencies" ||
		   t == "dependencyinsight" ||
		   t == "projects" ||
		   t == "properties" ||
		   t == "components" ||
		   t == "model" ||
		   t == "outgoingvariants" ||
		   t == "resolvableconfigurations" ||
		   t == "buildenvironment" ||
		   t == "javatoolchains" {
			saw_inspect = true
			rest = rem
			continue
		}
		return false
	}
	return saw_inspect
}

// B66: Bundler inspect (list/show/check/outdated/env; not install/exec/update).
bash_bundle_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		// bare bundle — help-ish / version depending on install; treat as inspect
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
		// peel globals that take values
		if tok == "--gemfile" || tok == "--path" || tok == "--binstubs" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--gemfile=") ||
		   strings.has_prefix(tok, "--path=") ||
		   strings.has_prefix(tok, "--binstubs=") {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		if sub == "install" ||
		   sub == "update" ||
		   sub == "exec" ||
		   sub == "add" ||
		   sub == "remove" ||
		   sub == "clean" ||
		   sub == "package" ||
		   sub == "pack" ||
		   sub == "binstubs" ||
		   sub == "init" ||
		   sub == "inject" ||
		   sub == "open" ||
		   sub == "console" ||
		   sub == "lock" ||
		   sub == "cache" ||
		   sub == "pristine" ||
		   sub == "plugin" ||
		   sub == "fund" ||
		   sub == "issue" {
			return false
		}
		// config: get/list only
		if sub == "config" {
			next, nrem := first_shell_token(rem)
			_ = nrem
			n := strings.to_lower(next, context.temp_allocator)
			return n == "" ||
				n == "list" ||
				n == "get" ||
				n == "help" ||
				n == "--help" ||
				n == "-h"
		}
		if sub == "list" ||
		   sub == "show" ||
		   sub == "info" ||
		   sub == "check" ||
		   sub == "outdated" ||
		   sub == "env" ||
		   sub == "platform" ||
		   sub == "doctor" ||
		   sub == "help" ||
		   sub == "version" ||
		   sub == "viz" ||
		   sub == "licenses" ||
		   sub == "why" {
			return true
		}
		return false
	}
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
	if a == "" {
		return true
	}
	if a == "--version" || a == "-V" || a == "--help" || a == "-h" || a == "help" || a == "about" {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		// peel globals that take values
		if tok == "--working-dir" || tok == "-d" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--working-dir=") {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		if sub == "install" ||
		   sub == "update" ||
		   sub == "require" ||
		   sub == "remove" ||
		   sub == "create-project" ||
		   sub == "dump-autoload" ||
		   sub == "dumpautoload" ||
		   sub == "clear-cache" ||
		   sub == "clearcache" ||
		   sub == "self-update" ||
		   sub == "selfupdate" ||
		   sub == "exec" ||
		   sub == "run-script" ||
		   sub == "run" ||
		   sub == "global" || // global install etc — fail closed
		   sub == "config" || // can write
		   sub == "init" ||
		   sub == "archive" ||
		   sub == "fund" ||
		   sub == "bump" ||
		   sub == "reinstall" {
			return false
		}
		if sub == "show" ||
		   sub == "list" ||
		   sub == "search" ||
		   sub == "depends" ||
		   sub == "prohibits" ||
		   sub == "validate" ||
		   sub == "check-platform-reqs" ||
		   sub == "outdated" ||
		   sub == "why" ||
		   sub == "why-not" ||
		   sub == "licenses" ||
		   sub == "status" ||
		   sub == "about" ||
		   sub == "diagnose" ||
		   sub == "help" ||
		   sub == "suggests" ||
		   sub == "browse" {
			return true
		}
		return false
	}
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
	sub, rest := first_shell_token(args)
	if sub == "" || sub == "--help" || sub == "-h" || sub == "help" || sub == "version" {
		return true
	}
	if bash_sub_in(
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
		   },
	   ) {
		return true
	}
	if sub == "config" {
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_sub_in(
			sub2,
			[]string{
				"view",
				"get-contexts",
				"current-context",
				"get-clusters",
				"get-users",
			},
		)
	}
	return false
}

// B36: terraform / tofu inspect (not apply/destroy/import).
bash_terraform_is_readonly :: proc(args: string) -> bool {
	rest := args
	sub := ""
	// peel global -chdir[=dir]
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		if tok == "-chdir" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "-chdir=") {
			rest = rem
			continue
		}
		sub = tok
		rest = rem
		break
	}
	if sub == "--help" || sub == "-h" || sub == "help" || sub == "version" || sub == "-version" {
		return true
	}
	switch sub {
	case "validate", "providers", "output", "show", "graph", "metadata":
		return true
	case "fmt":
		// only check/diff modes; bare fmt rewrites files
		if strings.contains(rest, "-check") || strings.contains(rest, "-diff") {
			if strings.contains(rest, "-write=true") {
				return false
			}
			return true
		}
		return false
	case "plan":
		// plan inspect unless -out / generate-config-out write artifacts
		if strings.contains(rest, "-out") || strings.contains(rest, "-generate-config-out") {
			return false
		}
		return true
	case "state":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_sub_in(sub2, []string{"list", "show", "pull"})
	case "workspace":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_sub_in(sub2, []string{"list", "show"})
	}
	return false
}

// B36: helm list/status/get/template/lint (not install/upgrade/uninstall).
bash_helm_is_readonly :: proc(args: string) -> bool {
	sub, rest := first_shell_token(args)
	if sub == "" || sub == "--help" || sub == "-h" || sub == "help" || sub == "version" ||
	   sub == "env" {
		return true
	}
	switch sub {
	case "list", "ls", "status", "history", "get", "show", "search", "lint", "template",
	     "dependency", "deps":
		if sub == "dependency" || sub == "deps" {
			sub2, _ := first_shell_token(rest)
			// list/build? build writes charts — only list
			if sub2 == "" || sub2 == "list" || sub2 == "ls" || sub2 == "--help" || sub2 == "help" {
				return true
			}
			return false
		}
		if sub == "get" || sub == "show" {
			// get all|hooks|manifest|notes|values — all read
			return true
		}
		if sub == "search" {
			return true
		}
		return true
	case "repo":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		// list only — add/remove/update mutate
		return sub2 == "list" || sub2 == "ls"
	case "plugin":
		sub2, _ := first_shell_token(rest)
		return sub2 == "list" || sub2 == "ls" || sub2 == "" || sub2 == "--help" || sub2 == "help"
	case "registry":
		// login mutates credentials — fail closed except help
		sub2, _ := first_shell_token(rest)
		return sub2 == "" || sub2 == "--help" || sub2 == "help"
	}
	return false
}

// B35: docker inspect + compose inspect (not run/up/build/exec).
bash_docker_is_readonly :: proc(args: string) -> bool {
	sub, rest := first_shell_token(args)
	if sub == "" {
		// bare docker — help-ish
		return true
	}
	if sub == "--help" || sub == "-h" || sub == "--version" || sub == "version" || sub == "help" ||
	   sub == "info" {
		return true
	}
	// plugin-style: docker compose …
	if sub == "compose" {
		return bash_docker_compose_is_readonly(rest)
	}
	// classic inspect
	return bash_sub_in(sub, []string{"ps", "images", "logs", "inspect", "top", "stats", "port", "diff"})
}

// docker compose / docker-compose: list/config/ps/logs/images/top/version only.
bash_docker_compose_is_readonly :: proc(args: string) -> bool {
	rest := args
	// peel common global flags that take a value
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			// bare compose — prints help
			return true
		}
		if tok == "-f" ||
		   tok == "--file" ||
		   tok == "-p" ||
		   tok == "--project-name" ||
		   tok == "--profile" ||
		   tok == "--project-directory" ||
		   tok == "--env-file" ||
		   tok == "--ansi" ||
		   tok == "--progress" {
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if strings.has_prefix(tok, "--file=") ||
		   strings.has_prefix(tok, "--project-name=") ||
		   strings.has_prefix(tok, "--profile=") ||
		   strings.has_prefix(tok, "--project-directory=") ||
		   strings.has_prefix(tok, "--env-file=") ||
		   strings.has_prefix(tok, "--ansi=") ||
		   strings.has_prefix(tok, "--progress=") ||
		   (strings.has_prefix(tok, "-f") && len(tok) > 2) ||
		   (strings.has_prefix(tok, "-p") && len(tok) > 2) {
			rest = rem
			continue
		}
		if tok == "--help" || tok == "-h" || tok == "--version" || tok == "version" || tok == "help" {
			return true
		}
		// first real subcommand
		return bash_sub_in(
			tok,
			[]string{
				"ps",
				"ls",
				"list",
				"config",
				"images",
				"logs",
				"top",
				"port",
				"events",
				"wait", // wait for healthy — read-ish; still no mutate
			},
		)
	}
}

// token_in: exact match of sub against allowed readonly subcommands.
bash_sub_in :: proc(sub: string, allowed: []string) -> bool {
	if sub == "" {
		return false
	}
	for a in allowed {
		if sub == a {
			return true
		}
	}
	return false
}

// B16: cargo read-only / non-mutating inspection (no build/test/run).
bash_cargo_is_readonly :: proc(args: string) -> bool {
	sub, rest := first_shell_token(args)
	// peel global flags that take a value: -C, --manifest-path, --config, -Z, --color
	for {
		if sub == "" {
			return true
		}
		if sub == "-C" ||
		   sub == "--manifest-path" ||
		   sub == "--config" ||
		   sub == "--color" ||
		   sub == "-Z" ||
		   sub == "--target-dir" {
			_, rest2 := first_shell_token(rest)
			sub, rest = first_shell_token(rest2)
			continue
		}
		if strings.has_prefix(sub, "-") &&
		   (strings.has_prefix(sub, "--quiet") ||
			   sub == "-q" ||
			   sub == "-v" ||
			   sub == "-vv" ||
			   sub == "--verbose" ||
			   sub == "--offline" ||
			   sub == "--locked" ||
			   sub == "--frozen" ||
			   sub == "--version" ||
			   sub == "-V" ||
			   sub == "--help" ||
			   sub == "-h") {
			// bare --version/-V without subcommand
			if sub == "--version" || sub == "-V" || sub == "--help" || sub == "-h" {
				return true
			}
			sub, rest = first_shell_token(rest)
			continue
		}
		break
	}
	return bash_sub_in(
		sub,
		[]string{
			"check",
			"metadata",
			"tree",
			"search",
			"help",
			"version",
			"locate-project",
			"verify-project",
			"pkgid",
			"info",
			"fetch",
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
	return bash_sub_in(
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
	sub, rest := first_shell_token(args)
	if sub == "" {
		// bare `bun` may start REPL — fail closed
		return false
	}
	if sub == "--version" ||
	   sub == "-v" ||
	   sub == "--help" ||
	   sub == "-h" ||
	   sub == "help" ||
	   sub == "version" {
		return true
	}
	// package manager inspect
	if sub == "pm" {
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_sub_in(
			sub2,
			[]string{"ls", "list", "whoami", "hash", "cache", "version", "pkg", "view", "why"},
		)
	}
	// top-level inspect-ish
	if bash_sub_in(sub, []string{"pm", "outdated", "why", "info", "x"}) {
		// bun x runs packages — fail closed
		if sub == "x" {
			return false
		}
		return true
	}
	return false
}

// B38: deno inspect (not run/test/install/compile/cache).
bash_deno_is_readonly :: proc(args: string) -> bool {
	sub, rest := first_shell_token(args)
	if sub == "" {
		return false
	}
	if sub == "--version" ||
	   sub == "-V" ||
	   sub == "--help" ||
	   sub == "-h" ||
	   sub == "help" ||
	   sub == "version" {
		return true
	}
	switch sub {
	case "info", "doc", "lint", "check", "types", "coverage", "bench":
		// bench executes code — fail closed
		if sub == "bench" || sub == "coverage" {
			return false
		}
		return true
	case "fmt":
		// only --check
		if strings.contains(rest, "--check") {
			return true
		}
		return false
	case "task":
		// task list is inspect; bare task / task NAME runs
		sub2, _ := first_shell_token(rest)
		return sub2 == "" || sub2 == "--help" || sub2 == "help" || sub2 == "list"
	case "jupyter":
		return false
	}
	return false
}

// B38: poetry inspect (not install/add/run/update).
bash_poetry_is_readonly :: proc(args: string) -> bool {
	sub, rest := first_shell_token(args)
	if sub == "" {
		return false
	}
	if sub == "--version" ||
	   sub == "-V" ||
	   sub == "--help" ||
	   sub == "-h" ||
	   sub == "help" ||
	   sub == "version" ||
	   sub == "about" {
		return true
	}
	switch sub {
	case "show", "check", "list", "search", "export":
		// export writes to stdout by default — allow (no file write unless -o)
		if sub == "export" && (strings.contains(rest, " -o ") || strings.contains(rest, "--output")) {
			return false
		}
		return true
	case "config":
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
	case "env":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_sub_in(sub2, []string{"info", "list"})
	case "debug":
		return true
	case "lock":
		// lock --check is inspect; bare lock may rewrite
		return strings.contains(rest, "--check")
	}
	return false
}

// uv inspection (not sync/add/run/build/venv).
bash_uv_is_readonly :: proc(args: string) -> bool {
	sub, rest := first_shell_token(args)
	if sub == "" {
		return false
	}
	if sub == "--version" || sub == "-V" || sub == "--help" || sub == "-h" {
		return true
	}
	if sub == "pip" {
		sub2, _ := first_shell_token(rest)
		return bash_sub_in(sub2, []string{"list", "show", "freeze", "check", "tree", "help"})
	}
	if sub == "python" {
		sub2, _ := first_shell_token(rest)
		return sub2 == "" || bash_sub_in(sub2, []string{"list", "find", "dir", "help"})
	}
	if sub == "cache" {
		sub2, _ := first_shell_token(rest)
		return sub2 == "" || bash_sub_in(sub2, []string{"dir", "size", "help"})
	}
	if sub == "self" {
		sub2, _ := first_shell_token(rest)
		return sub2 == "" || bash_sub_in(sub2, []string{"version", "help"})
	}
	return bash_sub_in(sub, []string{"tree", "version", "help"})
}

// rustup inspection / list (not update/default that mutates toolchain install — update mutates).
// Keep only show/which/doc/help and list-style under toolchain/target/component.
bash_rustup_is_readonly :: proc(args: string) -> bool {
	sub, rest := first_shell_token(args)
	if sub == "" {
		return false
	}
	if sub == "--version" || sub == "-V" || sub == "--help" || sub == "-h" {
		return true
	}
	if sub == "toolchain" || sub == "target" || sub == "component" || sub == "override" {
		sub2, _ := first_shell_token(rest)
		return sub2 == "list" || sub2 == "" || sub2 == "help"
	}
	return bash_sub_in(sub, []string{"show", "which", "doc", "help", "completions"})
}

// pip inspection only.
bash_pip_is_readonly :: proc(args: string) -> bool {
	sub, _ := first_shell_token(args)
	if sub == "" {
		return false
	}
	if sub == "--version" || sub == "-V" || sub == "--help" || sub == "-h" {
		return true
	}
	return bash_sub_in(
		sub,
		[]string{"list", "show", "freeze", "check", "index", "help", "debug", "hash", "inspect"},
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
	sub, rest := first_shell_token(args)
	if sub == "" {
		return false
	}
	if sub == "version" || sub == "env" || sub == "help" || sub == "doc" || sub == "list" {
		return true
	}
	if sub == "mod" {
		sub2, _ := first_shell_token(rest)
		return bash_sub_in(sub2, []string{"graph", "why", "verify"})
	}
	return false
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
	sub, _ := first_shell_token(args)
	if sub == "" {
		return false
	}
	return sub == "version" ||
		sub == "--version" ||
		sub == "help" ||
		sub == "--help" ||
		sub == "-h" ||
		sub == "doc"
}

// B40: zig version/env/ast-check/fmt --check (not build/run/test).
bash_zig_is_readonly :: proc(args: string) -> bool {
	sub, rest := first_shell_token(args)
	if sub == "" {
		// bare zig prints help-ish — allow
		return true
	}
	if sub == "version" ||
	   sub == "--version" ||
	   sub == "help" ||
	   sub == "--help" ||
	   sub == "-h" ||
	   sub == "env" ||
	   sub == "targets" ||
	   sub == "libc" ||
	   sub == "std-docs" ||
	   sub == "ast-check" {
		return true
	}
	if sub == "fmt" {
		// only --check; bare fmt rewrites
		return strings.contains(rest, "--check")
	}
	return false
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
		if bash_sub_in(
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
		if !bash_sub_in(
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
		return sub_l == "" || bash_sub_in(sub_l, []string{"list", "info", "id", "getname", "help"})
	case "config":
		return sub_l == "get" || sub_l == "" || sub_l == "help"
	case "memory":
		return sub_l == "" || bash_sub_in(sub_l, []string{"usage", "stats", "doctor", "help"})
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
		return bash_sub_in(
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
		return bash_sub_in(
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
				if bash_sub_in(
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
			if bash_sub_in(
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
	sub, rest := first_shell_token(args)
	if sub == "" {
		return false
	}
	switch sub {
	case "--help", "-h", "--version", "version", "help":
		return true
	case "introspect":
		return true // all introspect subcommands read build dir
	case "configure":
		// meson configure without -D is inspect; with -D can mutate options
		if strings.contains(rest, "-D") || strings.contains(rest, "--clearcache") {
			return false
		}
		return true
	case "rewriter", "compile", "install", "test", "dist", "init", "setup", "subprojects":
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
		return bash_sub_in(sub2, []string{"list", "view", "status", "checks", "diff"})
	case "issue":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		// develop can create branches — not readonly
		return bash_sub_in(sub2, []string{"list", "view", "status"})
	case "repo":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_sub_in(sub2, []string{"view", "list"})
	case "run":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_sub_in(sub2, []string{"list", "view"})
	case "workflow":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_sub_in(sub2, []string{"list", "view"})
	case "release":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		// download writes files
		return bash_sub_in(sub2, []string{"list", "view"})
	case "gist":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_sub_in(sub2, []string{"list", "view"})
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
		return bash_sub_in(sub2, []string{"list", "get"})
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
		return bash_sub_in(sub2, []string{"list", "view", "check"})
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
		return bash_sub_in(sub2, []string{"list", "view", "field-list", "item-list"})
	case "discussion":
		sub2, _ := first_shell_token(rest)
		if sub2 == "" || sub2 == "--help" || sub2 == "help" {
			return true
		}
		return bash_sub_in(sub2, []string{"list", "view"})
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
