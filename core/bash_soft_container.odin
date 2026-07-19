// Soft bash readonly helpers — Containers, registries, SBOM/scanners (crane..trivy).
// Same package core — symbols used by bash_program_is_readonly.
package core

import "core:strings"

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
		if bash_token_in(
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
				return bash_token_in(
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

