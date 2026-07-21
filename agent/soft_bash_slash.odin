// Package agent — /soft-bash status (B47).
// Explains soft bash hard-deny + readonly auto-allow for users.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:strings"
import "aether:core"

// handle_soft_bash_slash: status/help/on/off/check for soft bash safety (B47/B48/B80).
handle_soft_bash_slash :: proc(arg: string, allocator := context.allocator) -> string {
	raw := strings.trim_space(arg)
	a := strings.to_lower(raw, context.temp_allocator)
	if a == "help" || a == "?" {
		return strings.clone(
			"Usage: /soft-bash [status|on|off|check <cmd>|help]\n" +
			"Show or toggle soft-bash safety (hard-deny + readonly auto-allow).\n" +
			"  on|off       process-local toggle (not persisted)\n" +
			"  check <cmd>  dry-run: hard-deny / auto-allow / ask for a shell string\n" +
			"Env AETHER_NO_BASH_SOFT=1 still wins (cannot re-enable while set).",
			allocator,
		)
	}
	// B80: /soft-bash check <command…>
	if a == "check" || a == "test" || a == "classify" {
		return strings.clone(
			"Usage: /soft-bash check <command>\n" +
			"Example: /soft-bash check git status\n" +
			"         /soft-bash check rm -rf /",
			allocator,
		)
	}
	if strings.has_prefix(a, "check ") ||
	   strings.has_prefix(a, "test ") ||
	   strings.has_prefix(a, "classify ") {
		// peel first token from original (preserve command casing)
		cmd := raw
		// find first space
		sp := strings.index_byte(raw, ' ')
		if sp >= 0 {
			cmd = strings.trim_space(raw[sp + 1:])
		} else {
			cmd = ""
		}
		return soft_bash_check_command(cmd, allocator)
	}
	if a == "on" || a == "enable" || a == "true" || a == "1" || a == "yes" {
		ok := core.bash_soft_set_process_enabled(true)
		if ok {
			return strings.clone(
				"aether: soft-bash = on (process; hard-deny + readonly auto-allow)\n" +
				"AETHER_NO_BASH_SOFT still wins if set.",
				allocator,
			)
		}
		return strings.clone(
			"aether: soft-bash still DISABLED (AETHER_NO_BASH_SOFT is set; unset it to re-enable)",
			allocator,
		)
	}
	if a == "off" || a == "disable" || a == "false" || a == "0" || a == "no" {
		_ = core.bash_soft_set_process_enabled(false)
		return strings.clone(
			"aether: soft-bash = off (process; /soft-bash on to re-enable if env allows)",
			allocator,
		)
	}

	b := strings.builder_make(allocator)
	strings.write_string(&b, "## aether soft-bash\n")
	on := core.bash_soft_enabled()
	note := ""
	if core.bash_soft_process_override_active() {
		note = " (process override)"
	}
	strings.write_string(
		&b,
		fmt.tprintf("enabled:   %s%s\n", "yes" if on else "no", note),
	)
	if !on {
		strings.write_string(
			&b,
			"\nSoft bash is off: no hard-deny heuristics and no readonly auto-allow.\n" +
			"Permission mode alone governs shell (yolo may allow catastrophic cmds).\n" +
			"Try: /soft-bash on   (blocked if AETHER_NO_BASH_SOFT=1)\n",
		)
		return strings.to_string(b)
	}

	strings.write_string(
		&b,
		"\nWhen enabled (default):\n" +
		"  1. Hard-deny catastrophic patterns even under always-approve/yolo\n" +
		"     (e.g. rm -rf /, curl|sh, mkfs, dd of=/dev/…).\n" +
		"  2. Auto-allow known read-only / inspect shell in Ask and Read-Only modes\n" +
		"     (all segments of &&/||/;/| chains must be readonly).\n" +
		"  3. Other shell still asks (or is denied in read-only mode).\n",
	)

	strings.write_string(&b, "\n### Auto-allow families (inspect only)\n")
	strings.write_string(&b, "  viewers     ls eza fd dust duf procs tokei cat rg jq …\n")
	strings.write_string(&b, "  git         status log diff show grep … (not push/commit)\n")
	strings.write_string(&b, "  packages    npm list, cargo metadata, uv tree, pip list …\n")
	strings.write_string(&b, "  pipx/gem/composer  list/show/search (not install/require/run)\n")
	strings.write_string(&b, "  bundle/rake list/show/check, rake -T (not install/exec/task)\n")
	strings.write_string(&b, "  runtimes    bun pm ls, deno info, poetry show, go version …\n")
	strings.write_string(&b, "  build       make -n/help, cmake --version, just --list …\n")
	strings.write_string(&b, "  mvn/gradle  dependency:tree, tasks, projects (not package/build)\n")
	strings.write_string(&b, "  sbt         tasks/about/dependencyTree/show (not compile/run/test)\n")
	strings.write_string(&b, "  bazel       query/cquery/info/version (not build/run/test)\n")
	strings.write_string(&b, "  containers  docker/podman/nerdctl/buildah/ctr inspect, crane/skopeo/dive, syft/grype/trivy, cosign/oras/regctl …\n")
	strings.write_string(&b, "  k8s/cloud   kubectl get, helm/helmfile list/template, stern logs, kubeconform, kustomize/skaffold/kind/minikube/k3d/tilt, kubectx/kubens, argocd/flux/istioctl …\n")
	strings.write_string(&b, "  terraform   plan/validate/show, tflint, terraform-docs, terragrunt plan, checkov/tfsec/infracost (not apply)\n")
	strings.write_string(&b, "  ansible     --list-hosts, playbook --list-tasks/--syntax-check, galaxy list …\n")
	strings.write_string(&b, "  vagrant     status/global-status/box list/validate (not up/destroy)\n")
	strings.write_string(&b, "  packer      validate/inspect/fmt -check (not build/init)\n")
	strings.write_string(&b, "  consul/nomad  members/catalog/kv get, job status/plan (not put/run)\n")
	strings.write_string(&b, "  vault       status/secrets list/auth list (not read/kv get/write)\n")
	strings.write_string(&b, "  data        sqlite3 .tables, redis-cli ping, psql -c SELECT …\n")
	strings.write_string(&b, "  http/media  curl -I/GET, http/xh GET, wget --spider, ffprobe, ffmpeg -i …\n")
	strings.write_string(&b, "  lang tools  zig version, swift package describe, dotnet --info …\n")
	strings.write_string(&b, "  nix         flake show/metadata/search, doctor (not build/run/shell)\n")
	strings.write_string(&b, "  brew        list/info/search/outdated (not install/upgrade/update)\n")
	strings.write_string(&b, "  apt/dnf/pac apt list/search, dnf info, pacman -Q/-Ss (not install)\n")
	strings.write_string(&b, "  flatpak/snap/apk  list/info/search (not install/run/add)\n")
	strings.write_string(&b, "  aws         sts identity, s3 ls, describe/list/get (not cp/rm/create)\n")
	strings.write_string(&b, "  gcloud/az   gcloud list/describe/info, az list/show (not create/delete)\n")
	strings.write_string(&b, "  gh          pr/issue list|view, api GET …\n")

	strings.write_string(
		&b,
		"\nStill asks (examples): npm install, cargo build, docker run, curl -X POST,\n" +
		"  terraform apply, psql DELETE, git push, bare interactive db shells.\n",
	)
	strings.write_string(
		&b,
		"\ntips: /soft-bash on|off · /soft-bash check <cmd> · /doctor · /config · /tools\n",
	)
	return strings.to_string(b)
}

// soft_bash_check_command: B80 dry-run classifier for a shell string.
soft_bash_check_command :: proc(command: string, allocator := context.allocator) -> string {
	cmd := strings.trim_space(command)
	if cmd == "" {
		return strings.clone(
			"Usage: /soft-bash check <command>\n" +
			"Example: /soft-bash check ls -la",
			allocator,
		)
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, "## soft-bash check\n")
	strings.write_string(&b, fmt.tprintf("command:  %s\n", cmd))
	if !core.bash_soft_enabled() {
		strings.write_string(
			&b,
			"soft-bash: off\n" +
			"result:    (no soft classification; permission mode alone governs)\n" +
			"tip:       /soft-bash on to enable hard-deny + inspect auto-allow\n",
		)
		return strings.to_string(b)
	}
	// hard-deny wins even under yolo
	// note: bash_hard_deny_reason no-ops when soft off (already handled)
	reason := core.bash_hard_deny_reason(cmd)
	if reason != "" {
		strings.write_string(&b, "soft-bash: on\n")
		strings.write_string(&b, fmt.tprintf("result:    HARD-DENY\n"))
		strings.write_string(&b, fmt.tprintf("reason:    %s\n", reason))
		strings.write_string(
			&b,
			"note:      denied even under always-approve / yolo while soft-bash is on\n",
		)
		return strings.to_string(b)
	}
	if core.bash_is_readonly(cmd) {
		strings.write_string(&b, "soft-bash: on\n")
		strings.write_string(&b, "result:    AUTO-ALLOW (inspect / read-only)\n")
		strings.write_string(
			&b,
			"note:      Ask and Read-Only modes skip the prompt for this shell string\n",
		)
		return strings.to_string(b)
	}
	strings.write_string(&b, "soft-bash: on\n")
	strings.write_string(&b, "result:    ASK (not hard-deny, not inspect auto-allow)\n")
	strings.write_string(
		&b,
		"note:      still gated by permission mode (ask / auto / yolo / read-only)\n",
	)
	return strings.to_string(b)
}
