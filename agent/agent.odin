// Package agent — headless agent runtime for Aether-Grok.
// Rust reference: xai-grok-agent, xai-grok-shell, xai-chat-state, pager headless.
package agent

import "core:fmt"
import "core:strings"
import "aether:core"

Headless_Options :: struct {
	prompt:            string,
	model:             string,
	max_turns:         int,
	cwd:               string,
	quiet:             bool,
	verbose:           bool,
	session_ref:       string,
	continue_last:     bool,
	no_autosave:       bool,
	sessions_dir:      string,
	permission_mode:   string, // CLI override; empty = from config
	no_mcp:            bool, // skip MCP startup
}

// run_whoami prints identity from auth resolution (no secrets).
run_whoami :: proc(verbose: bool) -> int {
	creds, aerr := resolve_credentials()
	if aerr != "" {
		fmt.eprintf("aether: %s\n", aerr)
		return 1
	}
	defer destroy_credentials(&creds)

	kind := "session" if creds.kind == .Session else "api-key"
	email := creds.email if creds.email != "" else "(none)"
	uid := creds.user_id if creds.user_id != "" else "(none)"
	fmt.printf("auth_kind: %s\n", kind)
	fmt.printf("email:     %s\n", email)
	fmt.printf("user_id:   %s\n", uid)
	fmt.printf("base_url:  %s\n", creds.base_url)
	if verbose {
		fmt.printf("scope:     %s\n", creds.scope if creds.scope != "" else "(env/inline)")
		fmt.printf("token:     …%s\n", token_suffix(creds.bearer))
	}
	return 0
}

// run_headless resolves auth, loads config, and runs the tool loop.
run_headless :: proc(opts: Headless_Options) -> int {
	if opts.prompt == "" {
		fmt.eprintln("aether: empty prompt")
		return 1
	}

	cfg := core.load_runtime_config(opts.model, opts.cwd, opts.max_turns, opts.permission_mode)
	defer core.destroy_runtime_config(&cfg)
	apply_config_reasoning_effort(cfg.reasoning_effort)

	creds, aerr := resolve_credentials()
	if aerr != "" {
		fmt.eprintf("aether: %s\n", aerr)
		return 1
	}
	defer destroy_credentials(&creds)

	// Headless: keep stderr clean (Grok -p prints answer only). Auth line is verbose-only.
	if !opts.quiet && opts.verbose {
		who := creds.email if creds.email != "" else (creds.user_id if creds.user_id != "" else "api-key")
		mode := "session" if creds.kind == .Session else "api-key"
		fmt.eprintf(
			"aether: auth=%s as %s model=%s cwd=%s perm=%s\n",
			mode,
			who,
			cfg.model,
			cfg.cwd,
			core.permission_mode_string(cfg.permission_mode),
		)
	}

	_ = maybe_start_mcp(opts.no_mcp, opts.quiet)
	defer maybe_stop_mcp(nil)
	maybe_start_hooks(cfg.cwd, opts.quiet)
	defer maybe_stop_hooks("exit")
	sreg := maybe_start_skills(cfg.cwd, opts.quiet)
	defer maybe_stop_skills(sreg)

	// B29: durable prompt history for headless -p (shared with TUI/REPL)
	if strings.trim_space(opts.prompt) != "" {
		_ = core.append_prompt_history(opts.prompt)
	}

	turn := Turn_Options {
		workspace        = cfg.cwd,
		max_turns        = cfg.max_turns,
		quiet            = opts.quiet,
		verbose          = opts.verbose,
		permission_mode  = cfg.permission_mode,
		permission_allow = cfg.permission_allow[:],
		permission_deny  = cfg.permission_deny[:],
		mcp_enabled       = mcp_enabled_for_turn(nil),
		skills_enabled    = skills_enabled_for_turn(),
		subagents_enabled = subagents_enabled(),
	}
	return run_tool_loop(creds, cfg.model, opts.prompt, turn)
}

// host_of strips scheme/path for logging.
host_of :: proc(url: string) -> string {
	u := url
	if i := strings.index(u, "://"); i >= 0 {
		u = u[i + 3:]
	}
	if i := strings.index_any(u, "/?"); i >= 0 {
		u = u[:i]
	}
	return u
}
