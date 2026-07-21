// Soft bash readonly helpers — K8s, IaC, cloud CLIs, build systems (k3d..gradle).
// Same package core — symbols used by bash_program_is_readonly.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:strings"

// B84: k3d inspect (cluster list/get/version; not create/delete/start).
K3D_ALLOW := [?]string{"version", "help"}
K3D_DENY := [?]string{"create", "delete", "start", "stop", "import-images", "completion"}
K3D_LIST_GET := [?]string{"list", "ls", "get"}
K3D_EMPTY := [?]string{} // help/empty only
K3D_KUBECONFIG := [?]string{"get"}
K3D_NESTED := [?]Cli_Nested {
	{sub = "cluster", allow = K3D_LIST_GET[:]},
	{sub = "node", allow = K3D_LIST_GET[:]},
	{sub = "registry", allow = K3D_LIST_GET[:]},
	{sub = "image", allow = K3D_EMPTY[:]},
	{sub = "kubeconfig", allow = K3D_KUBECONFIG[:]},
	{sub = "config", allow = K3D_EMPTY[:]},
}
K3D_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = K3D_ALLOW[:],
	deny_subs     = K3D_DENY[:],
	nested        = K3D_NESTED[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_k3d_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, K3D_READONLY_SPEC)
}

// B84: tilt inspect (version/describe/get/args; not up/down/ci/trigger).
TILT_ALLOW := [?]string {
	"version", "help", "describe", "get", "args", "api-resources", "dump", "logs", "explain",
}
TILT_DENY := [?]string {
	"up", "down", "ci", "demo", "trigger", "docker", "alpha", "snapshot",
	"create-snapshot", "completion", "verify-install",
}
TILT_VALUE_FLAGS := [?]string{"-f", "--file", "--context", "--namespace"}
TILT_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = TILT_ALLOW[:],
	deny_subs     = TILT_DENY[:],
	value_flags   = TILT_VALUE_FLAGS[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_tilt_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "args" {
		return true
	}
	return bash_cli_is_readonly(args, TILT_READONLY_SPEC)
}

// B83: kind inspect (get/list/version/export; not create/delete/load).
KIND_ALLOW := [?]string{"version", "help"}
KIND_DENY := [?]string{"create", "delete", "load", "export", "build", "completion"}
KIND_GET_ALLOW := [?]string{"clusters", "nodes", "kubeconfig"}
KIND_NESTED := [?]Cli_Nested{{sub = "get", allow = KIND_GET_ALLOW[:]}}
KIND_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = KIND_ALLOW[:],
	deny_subs     = KIND_DENY[:],
	nested        = KIND_NESTED[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_kind_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, KIND_READONLY_SPEC)
}

// B83: minikube inspect (status/profile list/version/ip; not start/stop/delete).
MINIKUBE_VALUE_FLAGS := [?]string{"-p", "--profile", "--node"}
MINIKUBE_ALLOW := [?]string {
	"status", "version", "help", "ip", "logs", "docker-env", "podman-env",
	"ssh-key", "ssh-host", "update-check", "license", "options",
}
MINIKUBE_DENY := [?]string {
	"start", "stop", "delete", "pause", "unpause", "ssh", "cp", "mount",
	"tunnel", "dashboard", "cache", "update-context", "kubectl", "completion",
}
MINIKUBE_LIST := [?]string{"list"}
MINIKUBE_CONFIG_ALLOW := [?]string{"view", "get", "defaults"}
MINIKUBE_IMAGE_ALLOW := [?]string{"ls", "list"}
MINIKUBE_NESTED := [?]Cli_Nested {
	{sub = "addons", allow = MINIKUBE_LIST[:]},
	{sub = "node", allow = MINIKUBE_LIST[:]},
	{sub = "profile", allow = MINIKUBE_LIST[:]},
	{sub = "config", allow = MINIKUBE_CONFIG_ALLOW[:]},
	{sub = "image", allow = MINIKUBE_IMAGE_ALLOW[:]},
	{sub = "service", allow = MINIKUBE_LIST[:]},
}
MINIKUBE_READONLY_SPEC := Cli_Readonly_Spec {
	value_flags   = MINIKUBE_VALUE_FLAGS[:],
	allow_subs    = MINIKUBE_ALLOW[:],
	deny_subs     = MINIKUBE_DENY[:],
	nested        = MINIKUBE_NESTED[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_minikube_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, MINIKUBE_READONLY_SPEC)
}

// B82: skaffold inspect (diagnose/render/version/schema; not run/dev/delete).
SKAFFOLD_VALUE_FLAGS := [?]string {
	"-f", "--filename", "-p", "--profile", "--kube-context", "--namespace", "-n", "--kubeconfig",
}
SKAFFOLD_ALLOW := [?]string {
	"diagnose", "render", "schema", "version", "help", "options", "inspect", "credits",
}
SKAFFOLD_DENY := [?]string {
	"run", "dev", "debug", "delete", "deploy", "build", "test", "apply",
	"verify", "exec", "filter-api-server-logs", "init", "fix", "survey", "completion",
}
SKAFFOLD_CONFIG_ALLOW := [?]string{"list", "get"}
SKAFFOLD_NESTED := [?]Cli_Nested{{sub = "config", allow = SKAFFOLD_CONFIG_ALLOW[:]}}
SKAFFOLD_READONLY_SPEC := Cli_Readonly_Spec {
	value_flags   = SKAFFOLD_VALUE_FLAGS[:],
	allow_subs    = SKAFFOLD_ALLOW[:],
	deny_subs     = SKAFFOLD_DENY[:],
	nested        = SKAFFOLD_NESTED[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_skaffold_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, SKAFFOLD_READONLY_SPEC)
}

// B81: kustomize inspect (build/cfg/version; not edit/create to disk).
KUSTOMIZE_ALLOW := [?]string{"build", "cfg", "version", "help", "openapi"}
KUSTOMIZE_DENY := [?]string{"edit", "create", "localize", "fix", "completion"}
KUSTOMIZE_VALUE_FLAGS := [?]string{"-f", "--filename", "--load-restrictor"}
KUSTOMIZE_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = KUSTOMIZE_ALLOW[:],
	deny_subs     = KUSTOMIZE_DENY[:],
	value_flags   = KUSTOMIZE_VALUE_FLAGS[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_kustomize_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	// -o/--output to a path writes files — fail closed (anywhere in args)
	if bash_kustomize_writes_output(a) {
		return false
	}
	return bash_cli_is_readonly(args, KUSTOMIZE_READONLY_SPEC)
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
	if bash_is_help_or_version(strings.trim_space(args)) {
		return true
	}
	// flags only (--current/-c peel away); any positional switches context
	_, _, ok := bash_peel_to_sub(args)
	return !ok
}

// B81: kubens — list/current only (switching ns asks).
bash_kubens_is_readonly :: proc(args: string) -> bool {
	if bash_is_help_or_version(strings.trim_space(args)) {
		return true
	}
	_, _, ok := bash_peel_to_sub(args)
	return !ok
}

// B79: istioctl inspect (version/proxy-status/analyze/proxy-config; not install/apply).
ISTIOCTL_VALUE_FLAGS := [?]string {
	"--kubeconfig", "--context", "--namespace", "-n", "--istioNamespace", "-i",
}
ISTIOCTL_ALLOW := [?]string {
	"version", "help", "proxy-status", "ps", "analyze", "validate",
	"proxy-config", "pc", "ztunnel-config", "wait",
}
ISTIOCTL_DENY := [?]string {
	"install", "uninstall", "upgrade", "apply", "delete", "create", "replace",
	"experimental", "x", "dashboard", "kube-inject", "admin", "bug-report", "tag", "waypoint",
}
ISTIOCTL_REMOTE := [?]string{"list"}
ISTIOCTL_NESTED := [?]Cli_Nested{{sub = "remote", allow = ISTIOCTL_REMOTE[:]}}
ISTIOCTL_READONLY_SPEC := Cli_Readonly_Spec {
	value_flags   = ISTIOCTL_VALUE_FLAGS[:],
	allow_subs    = ISTIOCTL_ALLOW[:],
	deny_subs     = ISTIOCTL_DENY[:],
	nested        = ISTIOCTL_NESTED[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_istioctl_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, ISTIOCTL_READONLY_SPEC)
}

// B78: Flux CLI inspect (get/export/tree/logs; not create/delete/reconcile/bootstrap).
FLUX_ALLOW := [?]string {
	"get", "export", "tree", "logs", "diff", "version", "help", "check",
	"events", "stats", "trace",
}
FLUX_DENY := [?]string {
	"bootstrap", "install", "uninstall", "create", "delete", "suspend", "resume",
	"reconcile", "migrate", "push", "pull", "build", "completion", "envsubst",
}
FLUX_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = FLUX_ALLOW[:],
	deny_subs     = FLUX_DENY[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_flux_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "check" || strings.has_prefix(a, "check ") {
		return true
	}
	return bash_cli_is_readonly(args, FLUX_READONLY_SPEC)
}

// B77: Argo CD CLI inspect (app list/get/diff; not sync/delete/login).
bash_argocd_is_readonly :: proc(args: string) -> bool {
	value_flags := []string {
		"--server", "--auth-token", "--grpc-web-root-path", "--header", "-H",
		"--loglevel", "--logformat",
	}
	if bash_is_help_or_version(strings.trim_space(args)) {
		return true
	}
	sub, rem, ok := bash_peel_to_sub(args, value_flags)
	if !ok {
		return true
	}
	if bash_token_in(sub, []string{"login", "logout", "account", "gpg", "cert", "admin"}) {
		return false
	}
	if sub == "cluster" || sub == "repo" || sub == "proj" || sub == "project" {
		return bash_nested_allow(rem, []string{"list", "get"})
	}
	if sub == "app" {
		return bash_nested_allow(
			rem,
			[]string{"list", "get", "diff", "history", "manifests", "resources", "logs"},
		)
	}
	if sub == "applicationset" || sub == "appset" {
		return bash_nested_allow(rem, []string{"list", "get"})
	}
	if sub == "context" {
		return bash_nested_allow(rem, []string{"list"})
	}
	return bash_token_in(sub, []string{"version", "help"})
}

// B76: Vault inspect — status/version/list metadata only.
// Never auto-allow read/kv get (secret exfil) or write/delete/login.
bash_vault_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "status" || strings.has_prefix(a, "status ") {
		return true
	}
	value_flags := []string {
		"-address", "-namespace", "-ca-cert", "-client-cert", "-client-key", "-token",
	}
	if bash_is_help_or_version(a) {
		return true
	}
	sub, rem, ok := bash_peel_to_sub(a, value_flags)
	if !ok {
		return true
	}
	if bash_token_in(sub, []string{"status", "version", "help", "print", "path-help"}) {
		return true
	}
	// mount / auth method listing only
	if sub == "secrets" || sub == "auth" || sub == "policy" {
		return bash_nested_allow(rem, []string{"list"})
	}
	if sub == "operator" {
		next, nrem := first_shell_token(rem)
		n := strings.to_lower(next, context.temp_allocator)
		if n == "raft" {
			return bash_nested_allow(nrem, []string{"list-peers"})
		}
		return n == "" ||
			n == "members" ||
			n == "key-status" ||
			n == "help" ||
			n == "--help" ||
			n == "-h"
	}
	// everything else (read/write/kv/login/token/…) asks
	return false
}

// B75: Consul inspect (members/catalog/kv get/info; not put/delete/join).
bash_consul_is_readonly :: proc(args: string) -> bool {
	value_flags := []string {
		"-http-addr", "-datacenter", "-token", "-ca-file", "-client-cert", "-client-key",
	}
	if bash_is_help_or_version(strings.trim_space(args)) {
		return true
	}
	sub, rem, ok := bash_peel_to_sub(args, value_flags)
	if !ok {
		return true
	}
	if bash_token_in(
		sub,
		[]string{
			"join", "leave", "force-leave", "reload", "monitor", "exec", "lock", "watch",
			"connect", "acl", "operator", "services", "event", "rtt",
		},
	) {
		return false
	}
	if sub == "snapshot" {
		return bash_nested_allow(rem, []string{"inspect"})
	}
	if sub == "config" {
		return bash_nested_allow(rem, []string{"list", "read"})
	}
	if sub == "catalog" {
		return bash_nested_allow(rem, []string{"datacenters", "nodes", "services", "node", "service"})
	}
	if sub == "kv" {
		// get/export only (not put/delete/import) — empty next not ok for kv
		next, _ := first_shell_token(rem)
		n := strings.to_lower(next, context.temp_allocator)
		return n == "get" || n == "export" || n == "help" || n == "--help" || n == "-h"
	}
	if sub == "intention" {
		return bash_nested_allow(rem, []string{"list", "get", "match", "check"})
	}
	if sub == "health" {
		return bash_nested_allow(rem, []string{"node", "checks", "service", "state"})
	}
	return bash_token_in(sub, []string{"members", "info", "validate", "version", "help"})
}

// B75: Nomad inspect (status/node status/job status; not run/stop/alloc exec).
bash_nomad_is_readonly :: proc(args: string) -> bool {
	value_flags := []string{"-address", "-region", "-namespace", "-token"}
	if bash_is_help_or_version(strings.trim_space(args)) {
		return true
	}
	sub, rem, ok := bash_peel_to_sub(args, value_flags)
	if !ok {
		return true
	}
	if bash_token_in(
		sub,
		[]string{
			"run", "stop", "system", "operator", "acl", "volume", "var", "quota",
			"sentinel", "namespace", "scaling", "service", "ui", "monitor",
		},
	) {
		return false
	}
	if sub == "job" {
		return bash_nested_allow(
			rem,
			[]string{"status", "history", "inspect", "allocations", "evals", "deployments", "plan", "validate"},
		)
	}
	if sub == "alloc" {
		return bash_nested_allow(rem, []string{"status", "logs", "fs", "checks"})
	}
	if sub == "deployment" {
		return bash_nested_allow(rem, []string{"status", "list"})
	}
	if sub == "node" {
		next, _ := first_shell_token(rem)
		n := strings.to_lower(next, context.temp_allocator)
		if n == "drain" || n == "eligibility" || n == "purge" {
			return false
		}
		// status, bare id, or help
		return n == "" ||
			n == "status" ||
			n == "help" ||
			n == "--help" ||
			n == "-h" ||
			!strings.has_prefix(n, "-")
	}
	if sub == "server" {
		return bash_nested_allow(rem, []string{"members"})
	}
	if sub == "agent" {
		return bash_nested_allow(rem, []string{"info", "self", "health"})
	}
	if sub == "fmt" {
		return strings.contains(rem, "-check") || strings.contains(rem, "--check")
	}
	return bash_token_in(sub, []string{"status", "version", "help"})
}

// B74: Packer inspect (validate/inspect/version/fmt -check; not build/init).
bash_packer_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	// bare -write / -write=true rewrites files (-write=false is ok)
	{
		r := a
		for {
			tok, rem := first_shell_token(r)
			if tok == "" {
				break
			}
			if tok == "-write" || tok == "-write=true" {
				return false
			}
			r = rem
		}
	}
	if bash_is_help_or_version(a) {
		return true
	}
	sub, rem, ok := bash_peel_to_sub(
		a,
		[]string{"-var", "-var-file", "-except", "-only"},
	)
	if !ok {
		return true
	}
	if bash_token_in(
		sub,
		[]string{"build", "init", "console", "fix", "hcl2_upgrade", "plugins", "plugin"},
	) {
		return false
	}
	if sub == "fmt" {
		// only with -check (no write)
		return strings.contains(rem, "-check")
	}
	return bash_token_in(sub, []string{"validate", "inspect", "version", "help"})
}

// B73: vagrant inspect (status/global-status/box list/validate; not up/destroy).
bash_vagrant_is_readonly :: proc(args: string) -> bool {
	if bash_is_help_or_version(strings.trim_space(args)) {
		return true
	}
	sub, rem, ok := bash_peel_to_sub(args)
	if !ok {
		return true
	}
	if sub == "box" {
		return bash_nested_allow(rem, []string{"list", "outdated", "info"})
	}
	if sub == "plugin" {
		return bash_nested_allow(rem, []string{"list", "license"})
	}
	if sub == "snapshot" {
		return bash_nested_allow(rem, []string{"list"})
	}
	if bash_token_in(
		sub,
		[]string{
			"up", "destroy", "halt", "suspend", "resume", "reload", "provision",
			"ssh", "rdp", "winrm", "push", "package", "init", "cloud", "rsync",
			"rsync-auto", "share", "login", "upload", "download", "powershell",
		},
	) {
		return false
	}
	return bash_token_in(
		sub,
		[]string{
			"status", "global-status", "validate", "version", "help",
			"list-commands", "ssh-config", "port",
		},
	)
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
ANSIBLE_CONFIG_ALLOW := [?]string{"list", "dump", "view", "help"}
ANSIBLE_CONFIG_DENY := [?]string{"init"}
ANSIBLE_CONFIG_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = ANSIBLE_CONFIG_ALLOW[:],
	deny_subs     = ANSIBLE_CONFIG_DENY[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_ansible_config_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, ANSIBLE_CONFIG_READONLY_SPEC)
}

// B72: ansible-galaxy list/search/info only (not install/remove).
GALAXY_ALLOW := [?]string{"list", "search", "info", "help"}
GALAXY_DENY := [?]string{"install", "remove", "delete", "init", "build", "publish", "import", "setup"}
GALAXY_GROUP := [?]string{"list", "search", "info"}
GALAXY_NESTED := [?]Cli_Nested {
	{sub = "collection", allow = GALAXY_GROUP[:]},
	{sub = "role", allow = GALAXY_GROUP[:]},
}
GALAXY_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = GALAXY_ALLOW[:],
	deny_subs     = GALAXY_DENY[:],
	nested        = GALAXY_NESTED[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_ansible_galaxy_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, GALAXY_READONLY_SPEC)
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

