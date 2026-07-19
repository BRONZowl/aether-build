// Package agent — /doctor health check (B30 / B39).
// Environment + host deps + soft systems; no secrets printed.
package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "aether:core"
import "aether:hooks"
import "aether:mcp"
import "aether:skills"
import "aether:tools"

// doctor_cmd_ok: command -v name succeeds.
doctor_cmd_ok :: proc(name: string) -> bool {
	if name == "" {
		return false
	}
	// quote-safe: only allow simple idents
	for i in 0 ..< len(name) {
		ch := name[i]
		ok_ch :=
			(ch >= 'a' && ch <= 'z') ||
			(ch >= 'A' && ch <= 'Z') ||
			(ch >= '0' && ch <= '9') ||
			ch == '_' ||
			ch == '-' ||
			ch == '+'
		if !ok_ch {
			return false
		}
	}
	child, err := os.process_start(
		{command = {"sh", "-c", fmt.tprintf("command -v %s >/dev/null 2>&1", name)}},
	)
	if err != nil {
		return false
	}
	state, werr := os.process_wait(child)
	if werr != nil {
		return false
	}
	return state.exit_code == 0
}

doctor_line :: proc(
	b: ^strings.Builder,
	level: string, // ok | warn | fail
	label, detail: string,
	ok_n, warn_n, fail_n: ^int,
) {
	switch level {
	case "ok":
		ok_n^ += 1
	case "warn":
		warn_n^ += 1
	case "fail":
		fail_n^ += 1
	}
	strings.write_string(b, fmt.tprintf("[%s] %-12s %s\n", level, label, detail))
}

// handle_doctor_slash: multi-check health report.
handle_doctor_slash :: proc(
	sess: ^Session,
	cwd: string,
	allocator := context.allocator,
) -> string {
	b := strings.builder_make(allocator)
	ok_n, warn_n, fail_n := 0, 0, 0
	strings.write_string(&b, "## aether doctor\n")
	strings.write_string(&b, fmt.tprintf("version: %s\n\n", core.version_string()))

	// --- auth ---
	creds, aerr := resolve_credentials()
	if aerr != "" {
		doctor_line(&b, "fail", "auth", aerr, &ok_n, &warn_n, &fail_n)
	} else {
		kind := "session" if creds.kind == .Session else "api-key"
		who := creds.email if creds.email != "" else (creds.user_id if creds.user_id != "" else "ok")
		doctor_line(
			&b,
			"ok",
			"auth",
			fmt.tprintf("%s as %s", kind, who),
			&ok_n,
			&warn_n,
			&fail_n,
		)
		destroy_credentials(&creds)
	}

	// --- host tools ---
	if doctor_cmd_ok("rg") {
		doctor_line(&b, "ok", "ripgrep", "rg on PATH", &ok_n, &warn_n, &fail_n)
	} else {
		doctor_line(&b, "fail", "ripgrep", "rg not found (grep/glob tools need it)", &ok_n, &warn_n, &fail_n)
	}
	if doctor_cmd_ok("git") {
		doctor_line(&b, "ok", "git", "on PATH", &ok_n, &warn_n, &fail_n)
	} else {
		doctor_line(&b, "warn", "git", "not on PATH (/diff and git readonly soft-bash limited)", &ok_n, &warn_n, &fail_n)
	}
	if doctor_cmd_ok("odin") {
		doctor_line(&b, "ok", "odin", "on PATH", &ok_n, &warn_n, &fail_n)
	} else {
		doctor_line(&b, "warn", "odin", "not on PATH (rebuild uses project .tools)", &ok_n, &warn_n, &fail_n)
	}
	if doctor_cmd_ok("make") {
		doctor_line(&b, "ok", "make", "on PATH", &ok_n, &warn_n, &fail_n)
	} else {
		doctor_line(&b, "warn", "make", "not on PATH", &ok_n, &warn_n, &fail_n)
	}

	// --- optional host tools (B39; soft-bash / clipboard / notify ecosystem) ---
	// Missing → warn only (not fail); product still runs without them.
	doctor_optional_cmd(&b, "curl", "HTTP helper for bash; web_fetch is built-in", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "gh", "GitHub CLI (soft-bash inspect)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "docker", "containers (soft-bash compose inspect)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "podman", "Podman (soft-bash ps/images/logs)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "brew", "Homebrew (soft-bash list/info/search)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "apt", "APT (soft-bash list/search/show)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "dnf", "DNF (soft-bash list/info/repolist)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "pacman", "pacman (soft-bash -Q/-Ss/-Si)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "flatpak", "Flatpak (soft-bash list/search)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "snap", "snap (soft-bash list/info/find)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "apk", "Alpine apk (soft-bash info/search)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "pipx", "pipx (soft-bash list/environment)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "gem", "RubyGems (soft-bash list/search)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "bundle", "Bundler (soft-bash list/show/check)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "rake", "Rake (soft-bash -T/--tasks)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "composer", "Composer (soft-bash show/outdated)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "mvn", "Maven (soft-bash dependency:tree/help)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "gradle", "Gradle (soft-bash tasks/dependencies)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "sbt", "sbt (soft-bash tasks/about/dependencyTree)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "bazel", "Bazel (soft-bash query/info/version)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "pulumi", "Pulumi (soft-bash stack ls/config get)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "ansible", "Ansible (soft-bash list-hosts/docs)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "vagrant", "Vagrant (soft-bash status/box list)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "packer", "Packer (soft-bash validate/inspect)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "consul", "Consul (soft-bash members/catalog/kv get)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "nomad", "Nomad (soft-bash status/job status)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "vault", "Vault (soft-bash status/list; no secret read)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "argocd", "Argo CD (soft-bash app list/get/diff)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "flux", "Flux (soft-bash get/check/logs)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "istioctl", "Istio (soft-bash proxy-status/analyze)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "kustomize", "Kustomize (soft-bash build/version)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "kubectx", "kubectx (soft-bash list/current)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "kubens", "kubens (soft-bash list/current)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "skaffold", "Skaffold (soft-bash diagnose/render)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "kind", "kind (soft-bash get clusters/nodes)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "minikube", "minikube (soft-bash status/profile list)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "k3d", "k3d (soft-bash cluster list)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "tilt", "Tilt (soft-bash describe/get)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "crane", "crane (soft-bash manifest/digest/ls)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "skopeo", "skopeo (soft-bash inspect/list-tags)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "dive", "dive (soft-bash image layer inspect)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "syft", "syft (soft-bash SBOM scan)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "grype", "grype (soft-bash vuln scan)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "trivy", "trivy (soft-bash image/fs/config scan)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "cosign", "cosign (soft-bash verify/tree)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "oras", "oras (soft-bash manifest fetch/discover)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "regctl", "regctl (soft-bash image digest/manifest)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "buildah", "buildah (soft-bash images/inspect)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "nerdctl", "nerdctl (soft-bash ps/images/logs)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "ctr", "ctr (soft-bash images/containers ls)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "helmfile", "helmfile (soft-bash list/template/diff)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "stern", "stern (soft-bash multi-pod logs)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "kubeconform", "kubeconform (soft-bash manifest validate)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "tflint", "tflint (soft-bash lint)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "terraform-docs", "terraform-docs (soft-bash render stdout)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "terragrunt", "terragrunt (soft-bash plan/validate)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "checkov", "checkov (soft-bash policy scan)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "tfsec", "tfsec (soft-bash security scan)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "infracost", "infracost (soft-bash cost breakdown)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "zig", "Zig toolchain (soft-bash inspect)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "sqlite3", "SQLite CLI (soft-bash inspect)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "redis-cli", "Redis CLI (soft-bash inspect)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "psql", "PostgreSQL CLI (soft-bash inspect)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "mysql", "MySQL CLI (soft-bash inspect)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "wget", "wget (soft-bash spider/-O -)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "ffprobe", "ffprobe media inspect", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "nix", "Nix (soft-bash flake show/search)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "aws", "AWS CLI (soft-bash describe/list/sts)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "gcloud", "Google Cloud CLI (soft-bash list/describe)", &ok_n, &warn_n, &fail_n)
	doctor_optional_cmd(&b, "az", "Azure CLI (soft-bash list/show)", &ok_n, &warn_n, &fail_n)
	// clipboard: any common tool is enough
	clip_ok :=
		doctor_cmd_ok("wl-copy") ||
		doctor_cmd_ok("xclip") ||
		doctor_cmd_ok("xsel") ||
		doctor_cmd_ok("pbcopy")
	if clip_ok {
		tool := "pbcopy"
		if doctor_cmd_ok("wl-copy") {
			tool = "wl-copy"
		} else if doctor_cmd_ok("xclip") {
			tool = "xclip"
		} else if doctor_cmd_ok("xsel") {
			tool = "xsel"
		}
		doctor_line(&b, "ok", "clipboard", fmt.tprintf("%s available (/copy)", tool), &ok_n, &warn_n, &fail_n)
	} else {
		doctor_line(
			&b,
			"warn",
			"clipboard",
			"no wl-copy/xclip/xsel/pbcopy (/copy may fall back to file)",
			&ok_n,
			&warn_n,
			&fail_n,
		)
	}
	if doctor_cmd_ok("notify-send") {
		doctor_line(&b, "ok", "notify-send", "on PATH (desktop notify)", &ok_n, &warn_n, &fail_n)
	} else {
		doctor_line(
			&b,
			"warn",
			"notify-send",
			"not on PATH (desktop notify limited; OSC/bel still work)",
			&ok_n,
			&warn_n,
			&fail_n,
		)
	}

	// --- paths ---
	gh := core.grok_home(context.temp_allocator)
	if gh != "" && (os.exists(gh) || core.ensure_dir(gh)) {
		doctor_line(&b, "ok", "grok-home", gh, &ok_n, &warn_n, &fail_n)
	} else {
		doctor_line(&b, "fail", "grok-home", fmt.tprintf("unusable: %s", gh), &ok_n, &warn_n, &fail_n)
	}
	sdir := ""
	if sess != nil && sess.sessions_dir != "" {
		sdir = sess.sessions_dir
	} else {
		sdir = core.aether_sessions_dir("", context.temp_allocator)
	}
	if core.ensure_dir(sdir) {
		doctor_line(&b, "ok", "sessions", sdir, &ok_n, &warn_n, &fail_n)
	} else {
		doctor_line(&b, "fail", "sessions", fmt.tprintf("cannot create %s", sdir), &ok_n, &warn_n, &fail_n)
	}
	mroot := tools.memory_root(context.temp_allocator)
	if tools.memory_enabled() {
		if mroot != "" {
			doctor_line(&b, "ok", "memory", fmt.tprintf("on · %s", mroot), &ok_n, &warn_n, &fail_n)
		} else {
			doctor_line(&b, "warn", "memory", "on but root empty", &ok_n, &warn_n, &fail_n)
		}
	} else {
		doctor_line(&b, "warn", "memory", "disabled", &ok_n, &warn_n, &fail_n)
	}

	// --- soft systems ---
	if core.bash_soft_enabled() {
		doctor_line(&b, "ok", "bash-soft", "enabled", &ok_n, &warn_n, &fail_n)
	} else {
		doctor_line(&b, "warn", "bash-soft", "disabled (AETHER_NO_BASH_SOFT)", &ok_n, &warn_n, &fail_n)
	}
	if desktop_notify_enabled() {
		tn := "on" if turn_notify_enabled() else "off"
		doctor_line(&b, "ok", "notify", fmt.tprintf("desktop on · turns %s", tn), &ok_n, &warn_n, &fail_n)
	} else {
		doctor_line(&b, "warn", "notify", "desktop disabled", &ok_n, &warn_n, &fail_n)
	}
	if hooks.hooks_enabled() {
		r := hooks.get_registry()
		n := 0 if r == nil else len(r.specs)
		doctor_line(&b, "ok", "hooks", fmt.tprintf("%d loaded", n), &ok_n, &warn_n, &fail_n)
	} else {
		doctor_line(&b, "warn", "hooks", "disabled", &ok_n, &warn_n, &fail_n)
	}
	mreg := mcp.get_registry()
	if mreg != nil && len(mreg.tools) > 0 {
		doctor_line(&b, "ok", "mcp", fmt.tprintf("%d tools", len(mreg.tools)), &ok_n, &warn_n, &fail_n)
	} else {
		doctor_line(&b, "warn", "mcp", "no tools connected", &ok_n, &warn_n, &fail_n)
	}
	sreg := skills.get_registry()
	if sreg != nil && len(sreg.skills) > 0 {
		doctor_line(&b, "ok", "skills", fmt.tprintf("%d discovered", len(sreg.skills)), &ok_n, &warn_n, &fail_n)
	} else {
		doctor_line(&b, "warn", "skills", "none discovered", &ok_n, &warn_n, &fail_n)
	}

	// --- cwd / session ---
	ws := cwd
	if sess != nil && sess.cwd != "" {
		ws = sess.cwd
	}
	if ws == "" {
		ws = "."
	}
	abs, _ := filepath.abs(ws, context.temp_allocator)
	if os.exists(abs) && os.is_directory(abs) {
		doctor_line(&b, "ok", "cwd", abs, &ok_n, &warn_n, &fail_n)
	} else {
		doctor_line(&b, "warn", "cwd", fmt.tprintf("missing? %s", ws), &ok_n, &warn_n, &fail_n)
	}
	if sess != nil {
		doctor_line(
			&b,
			"ok",
			"session",
			fmt.tprintf("%s · %d msgs", sess.id, len(sess.msgs)),
			&ok_n,
			&warn_n,
			&fail_n,
		)
	} else {
		doctor_line(&b, "warn", "session", "none", &ok_n, &warn_n, &fail_n)
	}

	// summary
	strings.write_string(&b, "\n")
	overall := "ok"
	if fail_n > 0 {
		overall = "fail"
	} else if warn_n > 0 {
		overall = "warn"
	}
	strings.write_string(
		&b,
		fmt.tprintf(
			"summary:   %s  (ok=%d warn=%d fail=%d)\n",
			overall,
			ok_n,
			warn_n,
			fail_n,
		),
	)
	strings.write_string(
		&b,
		"tips:      /about · /status · /config · /soft-bash · /tools · /mcp doctor · /help\n",
	)
	return strings.to_string(b)
}

// doctor_optional_cmd: ok if on PATH, else warn (never fail).
doctor_optional_cmd :: proc(
	b: ^strings.Builder,
	name, why: string,
	ok_n, warn_n, fail_n: ^int,
) {
	if doctor_cmd_ok(name) {
		doctor_line(b, "ok", name, fmt.tprintf("on PATH (%s)", why), ok_n, warn_n, fail_n)
	} else {
		doctor_line(b, "warn", name, fmt.tprintf("not on PATH (%s)", why), ok_n, warn_n, fail_n)
	}
}
