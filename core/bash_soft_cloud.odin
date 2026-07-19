// Soft bash readonly helpers — K8s, IaC, cloud CLIs, build systems (k3d..gradle).
// Same package core — symbols used by bash_program_is_readonly.
package core

import "core:strings"

// B84: k3d inspect (cluster list/get/version; not create/delete/start).
bash_k3d_is_readonly :: proc(args: string) -> bool {
	if bash_is_help_or_version(strings.trim_space(args)) {
		return true
	}
	sub, rem, ok := bash_peel_to_sub(args)
	if !ok {
		return true
	}
	// resource groups with nested inspect verbs
	if sub == "cluster" || sub == "node" || sub == "registry" {
		next, _ := first_shell_token(rem)
		n := strings.to_lower(next, context.temp_allocator)
		return n == "" ||
			n == "list" ||
			n == "ls" ||
			n == "get" ||
			n == "help" ||
			n == "--help" ||
			n == "-h"
	}
	if sub == "image" {
		next, _ := first_shell_token(rem)
		n := strings.to_lower(next, context.temp_allocator)
		// import mutates; list none — fail closed for import
		return n == "help" || n == "--help" || n == "-h"
	}
	if sub == "kubeconfig" {
		next, _ := first_shell_token(rem)
		n := strings.to_lower(next, context.temp_allocator)
		// get prints; merge/write asks
		return n == "get" || n == "help" || n == "--help" || n == "-h" || n == ""
	}
	if sub == "config" {
		// config init may write
		next, _ := first_shell_token(rem)
		n := strings.to_lower(next, context.temp_allocator)
		return n == "" || n == "help" || n == "--help" || n == "-h"
	}
	if bash_token_in(
		sub,
		[]string{"create", "delete", "start", "stop", "import-images", "completion"},
	) {
		return false
	}
	return bash_token_in(sub, []string{"version", "help"})
}

// B84: tilt inspect (version/describe/get/args; not up/down/ci/trigger).
bash_tilt_is_readonly :: proc(args: string) -> bool {
	a := strings.trim_space(args)
	if a == "args" {
		return true
	}
	return bash_sub_readonly(
		args,
		allow = {
			"version", "help", "describe", "get", "args", "api-resources", "dump", "logs", "explain",
		},
		deny = {
			"up", "down", "ci", "demo", "trigger", "docker", "alpha", "snapshot",
			"create-snapshot", "completion", "verify-install",
		},
		value_flags = {"-f", "--file", "--context", "--namespace"},
	)
}

// B83: kind inspect (get/list/version/export; not create/delete/load).
bash_kind_is_readonly :: proc(args: string) -> bool {
	if bash_is_help_or_version(strings.trim_space(args)) {
		return true
	}
	sub, rem, ok := bash_peel_to_sub(args)
	if !ok {
		return true
	}
	if sub == "get" {
		next, _ := first_shell_token(rem)
		n := strings.to_lower(next, context.temp_allocator)
		return n == "" ||
			n == "clusters" ||
			n == "nodes" ||
			n == "kubeconfig" ||
			n == "help" ||
			n == "--help" ||
			n == "-h"
	}
	if bash_token_in(sub, []string{"create", "delete", "load", "export", "build", "completion"}) {
		return false
	}
	return bash_token_in(sub, []string{"version", "help"})
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
	return bash_sub_readonly(
		args,
		allow = {"list", "dump", "view", "help"},
		deny = {"init"},
	)
}

// B72: ansible-galaxy list/search/info only (not install/remove).
bash_ansible_galaxy_is_readonly :: proc(args: string) -> bool {
	if bash_is_help_or_version(strings.trim_space(args)) {
		return true
	}
	sub, rem, ok := bash_peel_to_sub(args)
	if !ok {
		return true
	}
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
			n == "--help" ||
			n == "-h"
	}
	if bash_token_in(
		sub,
		[]string{"install", "remove", "delete", "init", "build", "publish", "import", "setup"},
	) {
		return false
	}
	return bash_token_in(sub, []string{"list", "search", "info", "help"})
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

