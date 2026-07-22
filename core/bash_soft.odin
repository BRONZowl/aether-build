// Package core — soft bash safety (A4 residual / Grok-shaped heuristics).
// 1) Hard-deny catastrophic patterns even under always-approve.
// 2) Auto-allow recognized read-only shell commands (skip Ask prompt).
// Opt out: AETHER_NO_BASH_SOFT=1  (env always wins over process toggle)
// Process: /soft-bash on|off (B48)

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

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
	ov: Feature_Override = .Unset
	switch g_bash_soft_override {
	case .On:
		ov = .On
	case .Off:
		ov = .Off
	case .Unset:
		ov = .Unset
	}
	return feature_enabled("AETHER_NO_BASH_SOFT", ov, true)
}

// bash_soft_set_process_enabled: /soft-bash on|off for this process.
// Returns false if env kill-switch blocks re-enable.
bash_soft_set_process_enabled :: proc(on: bool) -> bool {
	if on {
		if feature_killed("AETHER_NO_BASH_SOFT") {
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

// --- Shared readonly matchers (Wave C) --------------------------------------
// Peel leading flags, match first subcommand against allow/deny lists.
// Fail-closed: unknown sub → false (same as most existing helpers).

// bash_is_help_or_version: bare/help/version whole-arg forms.
bash_is_help_or_version :: proc(a: string) -> bool {
	if a == "" {
		return true
	}
	switch a {
	case "--version", "-v", "-V", "--help", "-h", "help", "version":
		return true
	}
	return false
}

// bash_token_in: case-sensitive membership (callers lower-case first).
bash_token_in :: proc(tok: string, list: []string) -> bool {
	for x in list {
		if tok == x {
			return true
		}
	}
	return false
}

// bash_peel_to_sub: skip leading -flags; optional value_flags consume next token.
// Returns first non-flag token (lowercased into temp allocator) and remaining args.
bash_peel_to_sub :: proc(
	args: string,
	value_flags: []string = {},
) -> (
	sub: string,
	rest: string,
	ok: bool,
) {
	rest = strings.trim_space(args)
	if rest == "" {
		return "", "", false
	}
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return "", "", false
		}
		// long/short flags
		if strings.has_prefix(tok, "-") {
			// value flags: exact match or --flag=value
			consume_val := false
			for vf in value_flags {
				if tok == vf {
					consume_val = true
					break
				}
				// --flag=value form already includes value (no extra token)
				if strings.has_prefix(vf, "--") &&
				   strings.has_prefix(tok, vf) &&
				   len(tok) > len(vf) &&
				   tok[len(vf)] == '=' {
					consume_val = false
					break
				}
			}
			if consume_val {
				_, rest2 := first_shell_token(rem)
				rest = rest2
				continue
			}
			rest = rem
			continue
		}
		// first subcommand
		sub = strings.to_lower(tok, context.temp_allocator)
		return sub, rem, true
	}
}

// bash_sub_readonly: peel flags → first sub in allow (true) or deny (false).
// Special nested pairs handled by caller after peel (e.g. dnf module list).
// If no subcommand found after peel → true (bare/help only).
// Implemented via Cli_Readonly_Spec (P4).
bash_sub_readonly :: proc(
	args: string,
	allow: []string,
	deny: []string = {},
	value_flags: []string = {},
) -> bool {
	return bash_cli_is_readonly(
		args,
		Cli_Readonly_Spec {
			value_flags   = value_flags,
			allow_subs    = allow,
			deny_subs     = deny,
			empty_args_ok = true, // empty peels as fail → peel_fail_ok
			peel_fail_ok  = true,
		},
	)
}

// bash_nested_allow: after a top-level sub, next token empty/help or in allow.
bash_nested_allow :: proc(rest: string, allow: []string) -> bool {
	next, _ := first_shell_token(rest)
	n := strings.to_lower(next, context.temp_allocator)
	if n == "" || n == "help" || n == "--help" || n == "-h" {
		return true
	}
	return bash_token_in(n, allow)
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

