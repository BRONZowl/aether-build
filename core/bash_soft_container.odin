// Soft bash readonly helpers — Containers, registries, SBOM/scanners (crane..trivy).
// Same package core — symbols used by bash_program_is_readonly.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:strings"

// B85: crane inspect (manifest/digest/ls/config/version; not push/delete/copy).
CRANE_ALLOW := [?]string {
	"manifest", "digest", "config", "ls", "list", "catalog", "validate",
	"blob", "raw", "version", "help",
}
CRANE_DENY := [?]string {
	"push", "delete", "rm", "copy", "cp", "append", "mutate", "rebase",
	"export", "pull", "auth", "login", "logout", "serve", "registry",
	"edit", "flatten", "tag", "completion",
}
CRANE_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = CRANE_ALLOW[:],
	deny_subs     = CRANE_DENY[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_crane_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, CRANE_READONLY_SPEC)
}

// B85: skopeo inspect (inspect/list-tags/login no; not copy/delete).
SKOPEO_ALLOW := [?]string{"inspect", "list-tags", "layers", "help", "version"}
SKOPEO_DENY := [?]string {
	"copy", "delete", "sync", "login", "logout",
	"standalone-sign", "standalone-verify", "generate-sigstore-key",
}
SKOPEO_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = SKOPEO_ALLOW[:],
	deny_subs     = SKOPEO_DENY[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_skopeo_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, SKOPEO_READONLY_SPEC)
}

// B85: dive image layer explorer (always inspect of an image; no push).
DIVE_MUTATE_SUBS := [?]string{"build"}

bash_dive_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if bash_is_help_or_version(a) {
		return true
	}
	// dive build is docker build wrapper — mutates
	sub, rem, ok := bash_peel_to_sub(a)
	if ok && bash_token_in(sub, DIVE_MUTATE_SUBS[:]) {
		return false
	}
	// --export to a path writes; --export=- / bare flags ok
	rest := a
	for {
		tok, r2 := first_shell_token(rest)
		if tok == "" {
			break
		}
		if tok == "--export" {
			next, _ := first_shell_token(r2)
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
		rest = r2
	}
	_ = rem
	_ = ok
	// image name / flags — explore inspect
	return true
}

// B91: checkov policy scan (scan to stdout; not create-config / output-file-path).
CHECKOV_HELP := [?]string{"version", "--version", "-v", "help", "--help", "-h"}
CHECKOV_MUTATE_FLAGS := [?]string {
	"--create-config", "--output-file-path", "--download-external-modules",
}
CHECKOV_VALUE_FLAGS := [?]string {
	"-d", "--directory", "-f", "--file", "-o", "--output", "--framework",
	"--check", "--skip-check", "--repo-id", "--repo-root-for-plan-enrichment",
	"--var-file", "--external-checks-dir", "--config-file", "--bc-api-key",
	"--policy-metadata-filter",
}
CHECKOV_VALUE_EQ_PREFIXES := [?]string {
	"--directory=", "--file=", "--output=", "--framework=", "--config-file=",
}

bash_checkov_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if bash_token_in(a, CHECKOV_HELP[:]) {
		return true
	}
	rest := a
	for {
		tok, rem := first_shell_token(rest)
		if tok == "" {
			return true
		}
		// config / report writes; external module download
		if bash_token_in(tok, CHECKOV_MUTATE_FLAGS[:]) ||
		   strings.has_prefix(tok, "--output-file-path=") ||
		   strings.has_prefix(tok, "--create-config") {
			return false
		}
		if bash_token_in(tok, CHECKOV_VALUE_FLAGS[:]) {
			if strings.contains(tok, "=") {
				rest = rem
				continue
			}
			// -o is format (cli/json/junitxml) — value not a path usually
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		eq_value := false
		for p in CHECKOV_VALUE_EQ_PREFIXES {
			if strings.has_prefix(tok, p) {
				eq_value = true
				break
			}
		}
		if eq_value {
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
TFSEC_HELP := [?]string{"version", "--version", "help", "--help", "-h", "-v"}
TFSEC_OUT_FLAGS := [?]string{"--out", "-O", "--output"}
TFSEC_VALUE_FLAGS := [?]string {
	"--format", "-f", "--exclude", "-e", "--filter-results",
	"--tfvars-file", "--config-file", "--custom-check-dir", "--minimum-severity",
}
TFSEC_VALUE_EQ_PREFIXES := [?]string {
	"--format=", "--exclude=", "--config-file=", "--tfvars-file=",
}

bash_tfsec_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if bash_token_in(a, TFSEC_HELP[:]) ||
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
		if bash_token_in(tok, TFSEC_OUT_FLAGS[:]) ||
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
			if bash_token_in(tok, TFSEC_OUT_FLAGS[:]) {
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
		if bash_token_in(tok, TFSEC_VALUE_FLAGS[:]) {
			if strings.contains(tok, "=") {
				rest = rem
				continue
			}
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		eq_value := false
		for p in TFSEC_VALUE_EQ_PREFIXES {
			if strings.has_prefix(tok, p) {
				eq_value = true
				break
			}
		}
		if eq_value {
			rest = rem
			continue
		}
		rest = rem
	}
	return true
}

// B91: infracost estimate (breakdown/diff/output; not configure/auth/upload/comment).
INFRACOST_ALLOW := [?]string{"breakdown", "diff", "output", "estimate", "validate", "version", "help"}
INFRACOST_DENY := [?]string {
	"completion", "configure", "auth", "upload", "comment", "register", "login", "logout",
}
INFRACOST_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = INFRACOST_ALLOW[:],
	deny_subs     = INFRACOST_DENY[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_infracost_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	// --out-file report
	if bash_infracost_writes_file(a) {
		return false
	}
	return bash_cli_is_readonly(args, INFRACOST_READONLY_SPEC)
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
// Flag-oriented: no subcommands — keep explicit write guards.
bash_tflint_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if bash_is_help_or_version(a) {
		return true
	}
	if strings.contains(a, "--init") ||
	   strings.contains(a, "--fix-config") ||
	   strings.contains(a, "--fix") {
		return false
	}
	return true
}

// B90: terraform-docs inspect (render to stdout; not --output-file / inject).
// Deny-only: path-as-module-dir is ok; completion writes shell scripts.
TF_DOCS_DENY := [?]string{"completion"}
TF_DOCS_READONLY_SPEC := Cli_Readonly_Spec {
	deny_subs     = TF_DOCS_DENY[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_terraform_docs_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if bash_terraform_docs_writes_file(a) {
		return false
	}
	if strings.contains(a, "--output-mode=inject") ||
	   strings.contains(a, "--output-mode=replace") ||
	   strings.contains(a, "--output-mode inject") ||
	   strings.contains(a, "--output-mode replace") {
		return false
	}
	return bash_cli_is_readonly(args, TF_DOCS_READONLY_SPEC)
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
TG_HELP := [?]string{"version", "--version", "help", "--help", "-h", "-v"}
TG_VALUE_FLAGS := [?]string {
	"--terragrunt-config", "--terragrunt-working-dir", "--terragrunt-log-level",
	"--terragrunt-iam-role", "--terragrunt-source", "--terragrunt-download-dir",
	"--working-dir", "--config", "--log-level", "-C",
}
TG_NATIVE_INSPECT := [?]string {
	"terragrunt-info", "render-json", "graph-dependencies", "output-module-groups",
	"validate-inputs", "hclvalidate", "info", "version", "help",
}
TG_TF_ALLOW := [?]string{"plan", "validate", "show", "output", "graph", "providers", "version", "test"}
TG_TF_DENY := [?]string{"fmt", "console", "get"}
TG_STATE_ALLOW := [?]string{"list", "show", "pull"}
TG_LEGACY_ALLOW := [?]string{"plan-all", "output-all"}
TG_MUTATE := [?]string {
	"apply", "destroy", "import", "taint", "untaint", "init", "refresh",
	"force-unlock", "workspace", "login", "logout", "apply-all", "destroy-all",
}
TG_RUN_WRAPPERS := [?]string{"run-all", "run"}

bash_terragrunt_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if bash_token_in(a, TG_HELP[:]) ||
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
		if bash_token_in(tok, TG_VALUE_FLAGS[:]) {
			if strings.contains(tok, "=") {
				rest = rem
				continue
			}
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		if tok == "--terragrunt-source-update" ||
		   strings.has_prefix(tok, "--terragrunt-source-update") {
			// may download — fail-closed
			return false
		}
		if strings.has_prefix(tok, "--terragrunt-") ||
		   strings.has_prefix(tok, "--working-dir=") ||
		   strings.has_prefix(tok, "--config=") ||
		   strings.has_prefix(tok, "--log-level=") {
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
		if bash_token_in(sub, TG_NATIVE_INSPECT[:]) {
			return true
		}
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
		if bash_token_in(sub, TG_RUN_WRAPPERS[:]) {
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
	if bash_token_in(sub, TG_TF_ALLOW[:]) {
		return true
	}
	if bash_token_in(sub, TG_TF_DENY[:]) {
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
			if bash_token_in(ssub, TG_STATE_ALLOW[:]) {
				return true
			}
			// mv/rm/push/replace/…
			return false
		}
	}
	// mutators (+ legacy plan-all inspect)
	if bash_token_in(sub, TG_LEGACY_ALLOW[:]) {
		return true
	}
	if bash_token_in(sub, TG_MUTATE[:]) {
		return false
	}
	return false
}

// B89: helmfile inspect (list/status/template/build/lint; not apply/sync/destroy).
HELMFILE_HELP := [?]string{"version", "--version", "help", "--help", "-h"}
HELMFILE_VALUE_FLAGS := [?]string {
	"-f", "--file", "-e", "--environment", "-l", "--selector",
	"-n", "--namespace", "--state-values-set", "--state-values-file",
	"--chart", "--log-level", "--kube-context", "--kubeconfig",
}
HELMFILE_VALUE_EQ_PREFIXES := [?]string {
	"--file=", "--environment=", "--selector=", "--namespace=",
	"--state-values-set=", "--state-values-file=", "--log-level=",
	"--kube-context=", "--kubeconfig=",
}
HELMFILE_ALLOW := [?]string {
	"list", "ls", "status", "template", "build", "lint",
	"diff", "version", "help", "print-env", "show-dag",
}
HELMFILE_DENY := [?]string {
	"write-values", "deps", "fetch", "repos", "cache",
	"apply", "sync", "destroy", "delete", "remove", "init", "charts", "test", "completion",
}
HELMFILE_WRITE_FLAGS := [?]string{"--output-dir", "--output-file", "-o"}

bash_helmfile_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "" {
		return true
	}
	if bash_token_in(a, HELMFILE_HELP[:]) ||
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
		if bash_token_in(tok, HELMFILE_VALUE_FLAGS[:]) {
			if strings.contains(tok, "=") {
				rest = rem
				continue
			}
			_, rest2 := first_shell_token(rem)
			rest = rest2
			continue
		}
		eq_value := false
		for p in HELMFILE_VALUE_EQ_PREFIXES {
			if strings.has_prefix(tok, p) {
				eq_value = true
				break
			}
		}
		if eq_value {
			rest = rem
			continue
		}
		if strings.has_prefix(tok, "-") {
			rest = rem
			continue
		}
		sub := strings.to_lower(tok, context.temp_allocator)
		if bash_token_in(sub, HELMFILE_ALLOW[:]) {
			return true
		}
		if bash_token_in(sub, HELMFILE_DENY[:]) {
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
		if bash_token_in(tok, HELMFILE_WRITE_FLAGS[:]) {
			next, _ := first_shell_token(rem)
			if next != "" && next != "-" && !strings.has_prefix(next, "-") {
				return true
			}
		}
		if tok == "--skip-deps" {
			rest = rem
			continue
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
STERN_DENY := [?]string{"completion"}
STERN_READONLY_SPEC := Cli_Readonly_Spec {
	deny_subs     = STERN_DENY[:],
	empty_args_ok = true,
	peel_fail_ok  = true, // flags/bare pod pattern — log query
}

bash_stern_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, STERN_READONLY_SPEC)
}

// B89: kubeconform manifest validate (always inspect; not schema install mutators).
// Flag-oriented: -cache writes local schema cache.
bash_kubeconform_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if bash_is_help_or_version(a) {
		return true
	}
	if strings.contains(a, "-cache") || strings.contains(a, "--cache") {
		return false
	}
	return true
}

// B88: buildah inspect (images/containers/inspect/version; not bud/from/commit/push).
BUILDAH_ALLOW := [?]string {
	"images", "image", "containers", "ps", "ls", "list", "inspect", "info", "version", "help",
}
BUILDAH_DENY := [?]string {
	"from", "bud", "build", "build-using-dockerfile", "commit", "push", "pull",
	"login", "logout", "rm", "rmi", "run", "config", "copy", "add", "tag", "untag",
	"rename", "manifest", "mkcw", "prune", "source", "unshare", "completion",
	"mount", "umount", "unmount",
}
BUILDAH_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = BUILDAH_ALLOW[:],
	deny_subs     = BUILDAH_DENY[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_buildah_is_readonly :: proc(args: string) -> bool {
	return bash_cli_is_readonly(args, BUILDAH_READONLY_SPEC)
}

// B88: nerdctl inspect (docker-compatible ps/images/logs; not run/build/push).
NERDCTL_VALUE_FLAGS := [?]string {
	"-n", "--namespace", "-a", "--address", "-H", "--host",
	"--cgroup-manager", "--snapshotter", "--data-root",
	"--cni-path", "--cni-netconfpath", "--bip", "--storage-driver",
}
NERDCTL_ALLOW := [?]string {
	"version", "help", "info", "events", "ps", "logs", "inspect", "top", "stats", "port", "diff",
}
NERDCTL_SYS := [?]string{"df", "info", "events"}
NERDCTL_CTR := [?]string{"ls", "list", "ps", "inspect", "logs", "top", "stats", "port", "diff"}
NERDCTL_NESTED := [?]Cli_Nested {
	{sub = "system", allow = NERDCTL_SYS[:]},
	{sub = "container", allow = NERDCTL_CTR[:]},
}
NERDCTL_READONLY_SPEC := Cli_Readonly_Spec {
	value_flags   = NERDCTL_VALUE_FLAGS[:],
	allow_subs    = NERDCTL_ALLOW[:],
	nested        = NERDCTL_NESTED[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_nerdctl_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if bash_is_help_or_version(a) {
		return true
	}
	sub, rem, ok := bash_peel_to_sub(a, NERDCTL_VALUE_FLAGS[:])
	if ok && sub == "compose" {
		return bash_docker_compose_is_readonly(rem)
	}
	if ok && (sub == "image" || sub == "images") {
		return bash_nerdctl_image_is_readonly(rem, sub == "images")
	}
	return bash_cli_is_readonly(args, NERDCTL_READONLY_SPEC)
}

NERDCTL_IMAGE_ALLOW := [?]string{"ls", "list", "inspect", "history"}
NERDCTL_IMAGE_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = NERDCTL_IMAGE_ALLOW[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_nerdctl_image_is_readonly :: proc(args: string, bare_images: bool) -> bool {
	if bare_images {
		// nerdctl images [filters] — list
		return true
	}
	return bash_cli_is_readonly(args, NERDCTL_IMAGE_READONLY_SPEC)
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
		return bash_token_in(strings.to_lower(tok, context.temp_allocator), allowed)
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
COSIGN_ALLOW := [?]string {
	"verify", "verify-blob", "verify-attestation", "verify-blob-attestation",
	"tree", "triangulate", "download", "dockerfile", "manifest", "public-key",
	"env", "version", "help", "man",
}
COSIGN_DENY := [?]string {
	"sign", "sign-blob", "attest", "attest-blob", "attach", "upload", "copy", "clean",
	"login", "logout", "generate-key-pair", "import-key-pair", "initialize",
	"load", "save", "completion", "piv-tool", "pkcs11-tool",
}
COSIGN_READONLY_SPEC := Cli_Readonly_Spec {
	allow_subs    = COSIGN_ALLOW[:],
	deny_subs     = COSIGN_DENY[:],
	empty_args_ok = true,
	peel_fail_ok  = true,
}

bash_cosign_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if bash_cosign_writes_file(a) {
		return false
	}
	return bash_cli_is_readonly(args, COSIGN_READONLY_SPEC)
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
SYFT_DENY := [?]string{"login", "attest", "completion"}
SYFT_READONLY_SPEC := Cli_Readonly_Spec {
	deny_subs     = SYFT_DENY[:],
	empty_args_ok = true,
	peel_fail_ok  = true, // bare image/dir source
}

bash_syft_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if bash_syft_grype_writes_file(a) {
		return false
	}
	return bash_cli_is_readonly(args, SYFT_READONLY_SPEC)
}

// B86: grype vuln scan (scan/version/db status; not db delete/update login).
GRYPE_DENY := [?]string{"login", "completion"}
GRYPE_DB := [?]string{"status", "list", "check", "providers"}
GRYPE_NESTED := [?]Cli_Nested{{sub = "db", allow = GRYPE_DB[:]}}
GRYPE_READONLY_SPEC := Cli_Readonly_Spec {
	deny_subs     = GRYPE_DENY[:],
	nested        = GRYPE_NESTED[:],
	empty_args_ok = true,
	peel_fail_ok  = true, // bare target scan
}

bash_grype_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if bash_syft_grype_writes_file(a) {
		return false
	}
	return bash_cli_is_readonly(args, GRYPE_READONLY_SPEC)
}

// B86: trivy scan (image/fs/config/repo/sbom/k8s/version; not server/plugin/login/clean).
TRIVY_DENY := [?]string {
	"server", "plugin", "login", "registry", "clean", "completion", "module", "vex",
}
TRIVY_READONLY_SPEC := Cli_Readonly_Spec {
	deny_subs     = TRIVY_DENY[:],
	empty_args_ok = true,
	peel_fail_ok  = true, // legacy: trivy <image>
}

bash_trivy_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	// --output / -o file (not stdout)
	if bash_trivy_writes_file(a) {
		return false
	}
	return bash_cli_is_readonly(args, TRIVY_READONLY_SPEC)
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

