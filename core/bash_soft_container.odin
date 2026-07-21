// Soft bash readonly helpers — Containers, registries, SBOM/scanners (crane..trivy).
// Same package core — symbols used by bash_program_is_readonly.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:strings"

// B85: crane inspect (manifest/digest/ls/config/version; not push/delete/copy).
bash_crane_is_readonly :: proc(args: string) -> bool {
	return bash_sub_readonly(
		args,
		allow = {
			"manifest", "digest", "config", "ls", "list", "catalog", "validate",
			"blob", "raw", "version", "help",
		},
		deny = {
			"push", "delete", "rm", "copy", "cp", "append", "mutate", "rebase",
			"export", "pull", "auth", "login", "logout", "serve", "registry",
			"edit", "flatten", "tag", "completion",
		},
	)
}

// B85: skopeo inspect (inspect/list-tags/login no; not copy/delete).
bash_skopeo_is_readonly :: proc(args: string) -> bool {
	return bash_sub_readonly(
		args,
		allow = {"inspect", "list-tags", "layers", "help", "version"},
		deny = {
			"copy", "delete", "sync", "login", "logout",
			"standalone-sign", "standalone-verify", "generate-sigstore-key",
		},
	)
}

// B85: dive image layer explorer (always inspect of an image; no push).
bash_dive_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if bash_is_help_or_version(a) {
		return true
	}
	// dive build is docker build wrapper — mutates
	sub, rem, ok := bash_peel_to_sub(a)
	if ok && sub == "build" {
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
	// --out-file report
	if bash_infracost_writes_file(a) {
		return false
	}
	return bash_sub_readonly(
		args,
		allow = {"breakdown", "diff", "output", "estimate", "validate", "version", "help"},
		deny = {
			"completion", "configure", "auth", "upload", "comment", "register", "login", "logout",
		},
	)
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
	if bash_is_help_or_version(a) {
		return true
	}
	// plugin install / config or report file writes
	if strings.contains(a, "--init") ||
	   strings.contains(a, "--fix-config") ||
	   strings.contains(a, "--fix") {
		return false
	}
	// bare tflint / path args — lint to stdout
	return true
}

// B90: terraform-docs inspect (render to stdout; not --output-file / inject).
bash_terraform_docs_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	// file writes
	if bash_terraform_docs_writes_file(a) {
		return false
	}
	// --output-mode inject/replace rewrites README
	if strings.contains(a, "--output-mode=inject") ||
	   strings.contains(a, "--output-mode=replace") ||
	   strings.contains(a, "--output-mode inject") ||
	   strings.contains(a, "--output-mode replace") {
		return false
	}
	if bash_is_help_or_version(a) {
		return true
	}
	sub, _, ok := bash_peel_to_sub(a)
	if !ok {
		return true // path-only module dir
	}
	if sub == "completion" {
		return false
	}
	// format subcommands or bare path as first token (module dir)
	if bash_token_in(
		sub,
		[]string{
			"markdown", "json", "yaml", "yml", "toml", "tfvars", "tfvars-hcl", "tfvars-json",
			"asciidoc", "asciidoc-document", "asciidoc-table", "pretty", "xml", "html",
			"version", "help",
		},
	) {
		return true
	}
	// path argument (module dir) as first non-flag token
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
	if bash_is_help_or_version(strings.trim_space(args)) {
		return true
	}
	sub, _, ok := bash_peel_to_sub(args)
	if !ok {
		return true // flags only / bare — log query
	}
	// completion scripts may write; bare query string / pod pattern — logs
	return sub != "completion"
}

// B89: kubeconform manifest validate (always inspect; not schema install mutators).
bash_kubeconform_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if bash_is_help_or_version(a) {
		return true
	}
	// -o output format (json/junit/text) is stdout; -cache dir writes cache — ask
	if strings.contains(a, "-cache") || strings.contains(a, "--cache") {
		return false
	}
	return true
}

// B88: buildah inspect (images/containers/inspect/version; not bud/from/commit/push).
bash_buildah_is_readonly :: proc(args: string) -> bool {
	return bash_sub_readonly(
		args,
		allow = {
			"images", "image", "containers", "ps", "ls", "list", "inspect", "info", "version", "help",
		},
		deny = {
			"from", "bud", "build", "build-using-dockerfile", "commit", "push", "pull",
			"login", "logout", "rm", "rmi", "run", "config", "copy", "add", "tag", "untag",
			"rename", "manifest", "mkcw", "prune", "source", "unshare", "completion",
			"mount", "umount", "unmount",
		},
	)
}

// B88: nerdctl inspect (docker-compatible ps/images/logs; not run/build/push).
bash_nerdctl_is_readonly :: proc(args: string) -> bool {
	value_flags := []string {
		"-n", "--namespace", "-a", "--address", "-H", "--host",
		"--cgroup-manager", "--snapshotter", "--data-root",
		"--cni-path", "--cni-netconfpath", "--bip", "--storage-driver",
	}
	if bash_is_help_or_version(strings.trim_space(args)) {
		return true
	}
	sub, rem, ok := bash_peel_to_sub(args, value_flags)
	if !ok {
		return true
	}
	if sub == "compose" {
		return bash_docker_compose_is_readonly(rem)
	}
	if bash_token_in(sub, []string{"version", "help", "info", "events"}) {
		return true
	}
	if sub == "image" || sub == "images" {
		return bash_nerdctl_image_is_readonly(rem, sub == "images")
	}
	if sub == "system" {
		return bash_nested_allow(rem, []string{"df", "info", "events"})
	}
	if sub == "container" {
		return bash_nested_allow(
			rem,
			[]string{"ls", "list", "ps", "inspect", "logs", "top", "stats", "port", "diff"},
		)
	}
	return bash_token_in(
		sub,
		[]string{"ps", "logs", "inspect", "top", "stats", "port", "diff"},
	)
}

bash_nerdctl_image_is_readonly :: proc(args: string, bare_images: bool) -> bool {
	if bare_images {
		// nerdctl images [filters] — list
		return true
	}
	return bash_sub_readonly(
		args,
		allow = {"ls", "list", "inspect", "history"},
	)
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
	if bash_is_help_or_version(a) {
		return true
	}
	// file write destinations
	if bash_syft_grype_writes_file(a) {
		return false
	}
	sub, _, ok := bash_peel_to_sub(a)
	if !ok {
		return true
	}
	if bash_token_in(sub, []string{"login", "attest", "completion"}) {
		return false
	}
	// known inspect verbs or bare image/dir/source ref (legacy: `syft alpine:3`)
	return true
}

// B86: grype vuln scan (scan/version/db status; not db delete/update login).
bash_grype_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if bash_is_help_or_version(a) {
		return true
	}
	if bash_syft_grype_writes_file(a) {
		return false
	}
	sub, rem, ok := bash_peel_to_sub(a)
	if !ok {
		return true
	}
	if bash_token_in(sub, []string{"login", "completion"}) {
		return false
	}
	if sub == "explain" || sub == "version" || sub == "help" {
		return true
	}
	if sub == "db" {
		// grype db status|list|check inspect; update/delete mutates local DB
		return bash_nested_allow(rem, []string{"status", "list", "check", "providers"})
	}
	// bare target scan: grype alpine:3
	return true
}

// B86: trivy scan (image/fs/config/repo/sbom/k8s/version; not server/plugin/login/clean).
bash_trivy_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	// --output / -o file (not stdout)
	if bash_trivy_writes_file(a) {
		return false
	}
	if bash_is_help_or_version(a) {
		return true
	}
	sub, _, ok := bash_peel_to_sub(a)
	if !ok {
		return true
	}
	// mutators / long-running / auth
	if bash_token_in(
		sub,
		[]string{"server", "plugin", "login", "registry", "clean", "completion", "module", "vex"},
	) {
		return false
	}
	// known scanners or legacy: trivy <image>
	_ = sub
	return true
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

