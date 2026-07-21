// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "aether:mcp"
import "aether:core"

// maybe_start_mcp loads config and starts MCP when not disabled.
// Returns registry (may be empty/partial); caller must stop via maybe_stop_mcp.
maybe_start_mcp :: proc(no_mcp: bool, quiet: bool) -> ^mcp.Mcp_Registry {
	if no_mcp {
		return nil
	}
	if core.feature_killed("AETHER_NO_MCP") {
		return nil
	}
	cfgs := mcp.load_mcp_configs()
	if len(cfgs) == 0 {
		mcp.destroy_server_configs(cfgs)
		return nil
	}
	reg := mcp.start_registry(cfgs, quiet)
	mcp.destroy_server_configs(cfgs)
	if reg == nil || len(reg.servers) == 0 {
		if reg != nil {
			mcp.stop_registry(reg)
		}
		return nil
	}
	mcp.set_registry(reg)
	return reg
}

// maybe_stop_mcp stops a registry. If reg is nil, stops the global registry.
// Safe after /mcp reconnect (always stop g_registry).
maybe_stop_mcp :: proc(reg: ^mcp.Mcp_Registry = nil) {
	r := reg
	if r == nil {
		r = mcp.get_registry()
	}
	if r == nil {
		return
	}
	// Only clear global if it matches what we stop
	if mcp.get_registry() == r {
		mcp.set_registry(nil)
	}
	mcp.stop_registry(r)
}

// maybe_restart_mcp stops global registry and starts fresh (A3.1 reconnect).
maybe_restart_mcp :: proc(no_mcp: bool, quiet: bool) -> ^mcp.Mcp_Registry {
	maybe_stop_mcp(nil)
	return maybe_start_mcp(no_mcp, quiet)
}

mcp_enabled_for_turn :: proc(reg: ^mcp.Mcp_Registry = nil) -> bool {
	r := reg
	if r == nil {
		r = mcp.get_registry()
	}
	return r != nil && len(r.tools) > 0
}

mcp_status_line :: proc(allocator := context.allocator) -> string {
	reg := mcp.get_registry()
	if reg == nil {
		return strings.clone("mcp: disabled or no servers", allocator)
	}
	return mcp.status_text(reg, allocator)
}

// handle_mcp_slash implements /mcp [status|reconnect|auth|set-token|doctor|list-config|help].
// R2b: doctor/list are in-process (no host `grok` required).
handle_mcp_slash :: proc(
	arg: string,
	no_mcp: bool,
	quiet: bool,
	allocator := context.allocator,
) -> string {
	a := strings.trim_space(arg)
	al := strings.to_lower(a, context.temp_allocator)
	// first token
	cmd := al
	rest := ""
	if sp := strings.index_byte(a, ' '); sp >= 0 {
		cmd = strings.to_lower(a[:sp], context.temp_allocator)
		rest = strings.trim_space(a[sp + 1:])
	}

	switch cmd {
	case "", "status", "list", "show":
		return mcp_status_line(allocator)
	case "help", "?":
		return strings.clone(
			"Usage: /mcp [status|reconnect|auth|set-token|enroll|doctor|list-config|help]\n" +
			"  status              connected servers/tools (default)\n" +
			"  reconnect           reload config + re-auth (in-process)\n" +
			"  auth [name]         auth source (+ enroll tips for HTTP servers)\n" +
			"  set-token <name> <token>  write access_token → ~/.grok/mcp_credentials.json + reconnect\n" +
			"  enroll <name> <token>     alias of set-token (M3 first-class enroll)\n" +
			"  doctor [server]     in-process health report (config + live; no host grok)\n" +
			"  list-config         configured servers from aether.toml / ~/.grok\n" +
			"  host-doctor [s]     optional legacy: shell out to `grok mcp doctor` if present\n" +
			"Browser OAuth DCR: use host `grok` once if the server needs full OAuth dance;\n" +
			"  then tokens live in mcp_credentials.json and Aether reconnects without host.\n" +
			"Auth: XAI_API_KEY / aether login for the model; MCP tokens via enroll/set-token.",
			allocator,
		)
	case "auth":
		return mcp_auth_status_and_enroll(rest, allocator)
	case "reconnect", "reload", "restart":
		reg := maybe_restart_mcp(no_mcp, quiet)
		st := mcp_status_line(context.temp_allocator)
		if reg == nil {
			return fmt.aprintf("aether: mcp reconnected — no servers\n%s", st, allocator = allocator)
		}
		return fmt.aprintf("aether: mcp reconnected\n%s", st, allocator = allocator)
	case "set-token", "token", "enroll":
		return mcp_set_token_cmd(rest, no_mcp, quiet, allocator)
	case "doctor":
		return mcp_doctor_report(rest, no_mcp, quiet, allocator)
	case "list-config", "config-list", "configured":
		return mcp_list_config(allocator)
	case "host-list", "list-cli", "cli-list":
		// R2: default to in-process list; keep host as optional alias via host-doctor
		return mcp_list_config(allocator)
	case "host-doctor":
		code := run_host_mcp_doctor(rest, quiet)
		if code == 0 {
			return strings.clone(
				"aether: host mcp doctor finished (exit 0). Prefer: /mcp doctor (in-process).",
				allocator,
			)
		}
		return fmt.aprintf(
			"aether: host mcp doctor exit %d (optional; use /mcp doctor without host grok)",
			code,
			allocator = allocator,
		)
	case:
		return fmt.aprintf(
			"aether: unknown /mcp arg %q (try /mcp help)",
			arg,
			allocator = allocator,
		)
	}
}

// mcp_list_config: configured servers from disk (no secrets).
mcp_list_config :: proc(allocator := context.allocator) -> string {
	cfgs := mcp.load_mcp_configs()
	defer mcp.destroy_server_configs(cfgs)
	if len(cfgs) == 0 {
		return strings.clone(
			"mcp config: no servers (add [mcp_servers.*] in aether.toml or ~/.grok/config.toml)",
			allocator,
		)
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, "mcp configured servers:\n")
	for c in cfgs {
		en := "on" if c.enabled else "off"
		if c.url != "" {
			fmt.sbprintf(&b, "  %s  %s  http  url=%s\n", c.name, en, c.url)
		} else if c.command != "" {
			fmt.sbprintf(&b, "  %s  %s  stdio command=%s\n", c.name, en, c.command)
		} else {
			fmt.sbprintf(&b, "  %s  %s  (missing command/url)\n", c.name, en)
		}
	}
	return strings.to_string(b)
}

// mcp_doctor_report: in-process health (R2b). filter empty = all.
// Compares config vs live registry; never prints tokens.
mcp_doctor_report :: proc(
	filter: string,
	no_mcp: bool,
	quiet: bool,
	allocator := context.allocator,
) -> string {
	_ = quiet
	want := strings.to_lower(strings.trim_space(filter), context.temp_allocator)
	cfgs := mcp.load_mcp_configs()
	defer mcp.destroy_server_configs(cfgs)
	reg := mcp.get_registry()

	b := strings.builder_make(allocator)
	strings.write_string(&b, "mcp doctor (in-process; no host grok required)\n")
	if no_mcp || core.feature_killed("AETHER_NO_MCP") {
		strings.write_string(&b, "  note: MCP disabled (AETHER_NO_MCP / --no-mcp)\n")
	}
	if len(cfgs) == 0 {
		strings.write_string(
			&b,
			"  no [mcp_servers] configured\n" +
			"  tip: add stdio command= or http url= under [mcp_servers.name]\n",
		)
		return strings.to_string(b)
	}

	n_ok := 0
	n_bad := 0
	n_skip := 0
	for c in cfgs {
		if want != "" && strings.to_lower(c.name, context.temp_allocator) != want {
			continue
		}
		if !c.enabled {
			fmt.sbprintf(&b, "  %s  SKIP  disabled in config\n", c.name)
			n_skip += 1
			continue
		}
		transport := "stdio"
		detail := c.command
		if c.url != "" {
			transport = "http"
			detail = c.url
		}
		if detail == "" {
			fmt.sbprintf(&b, "  %s  FAIL  missing command= and url=\n", c.name)
			n_bad += 1
			continue
		}
		// live match
		alive := false
		n_tools := 0
		n_res := 0
		n_pr := 0
		auth := "n/a"
		found_live := false
		if reg != nil {
			for s in reg.servers {
				if s.name == c.name {
					found_live = true
					alive = s.alive
					n_tools = len(s.tools)
					n_res = len(s.resources)
					n_pr = len(s.prompts)
					if s.kind == .Http {
						auth = mcp.auth_source_string(s.auth_source)
					} else {
						auth = "stdio"
					}
					break
				}
			}
		}
		if found_live && alive {
			fmt.sbprintf(
				&b,
				"  %s  OK    %s  auth=%s  tools=%d resources=%d prompts=%d\n      %s\n",
				c.name,
				transport,
				auth,
				n_tools,
				n_res,
				n_pr,
				detail,
			)
			n_ok += 1
		} else if found_live && !alive {
			fmt.sbprintf(
				&b,
				"  %s  DEAD  %s  (process/session not alive)\n      %s\n      tip: /mcp reconnect\n",
				c.name,
				transport,
				detail,
			)
			n_bad += 1
		} else {
			fmt.sbprintf(
				&b,
				"  %s  DOWN  %s  (not in live registry)\n      %s\n      tip: /mcp reconnect\n",
				c.name,
				transport,
				detail,
			)
			n_bad += 1
		}
	}
	if want != "" && n_ok + n_bad + n_skip == 0 {
		fmt.sbprintf(&b, "  no server matching %q in config\n", filter)
	}
	fmt.sbprintf(&b, "summary: ok=%d bad=%d skipped=%d\n", n_ok, n_bad, n_skip)
	strings.write_string(
		&b,
		"credentials: never printed; use /mcp auth · set-token · ~/.grok/mcp_credentials.json\n",
	)
	return strings.to_string(b)
}

mcp_auth_status :: proc(allocator := context.allocator) -> string {
	reg := mcp.get_registry()
	if reg == nil || len(reg.servers) == 0 {
		return strings.clone("mcp auth: no servers connected", allocator)
	}
	b := strings.builder_make(allocator)
	strings.write_string(&b, "mcp auth sources (no secrets):\n")
	for s in reg.servers {
		if s.kind == .Http {
			strings.write_string(
				&b,
				fmt.tprintf("  %s  auth=%s  alive=%v\n", s.name, mcp.auth_source_string(s.auth_source), s.alive),
			)
		} else {
			strings.write_string(&b, fmt.tprintf("  %s  transport=stdio  alive=%v\n", s.name, s.alive))
		}
	}
	return strings.to_string(b)
}

// mcp_auth_status_and_enroll: M3 — auth sources + per-server enroll tips.
mcp_auth_status_and_enroll :: proc(filter: string, allocator := context.allocator) -> string {
	want := strings.to_lower(strings.trim_space(filter), context.temp_allocator)
	base := mcp_auth_status(context.temp_allocator)
	b := strings.builder_make(allocator)
	strings.write_string(&b, base)
	if !strings.has_suffix(base, "\n") {
		strings.write_byte(&b, '\n')
	}
	cfgs := mcp.load_mcp_configs()
	defer mcp.destroy_server_configs(cfgs)
	if len(cfgs) == 0 {
		return strings.to_string(b)
	}
	strings.write_string(&b, "enroll tips (M3):\n")
	for c in cfgs {
		if want != "" && strings.to_lower(c.name, context.temp_allocator) != want {
			continue
		}
		if c.url == "" {
			continue
		}
		has := mcp.mcp_credential_has_token(c.name, c.url)
		cred := "credentials:yes" if has else "credentials:no"
		fmt.sbprintf(
			&b,
			"  %s  url=%s  %s\n" +
			"      → /mcp enroll %s <access_token>   (writes mcp_credentials.json + reconnect)\n" +
			"      → bearer_token_env_var / headers in config for env-based auth\n" +
			"      → full browser OAuth DCR: host `grok` once, then Aether reuses the file\n",
			c.name,
			c.url,
			cred,
			c.name,
		)
	}
	return strings.to_string(b)
}

// mcp_set_token_cmd: rest = "<server_name> <access_token>"; auto-reconnect (M3).
mcp_set_token_cmd :: proc(
	rest: string,
	no_mcp := false,
	quiet := true,
	allocator := context.allocator,
) -> string {
	r := strings.trim_space(rest)
	if r == "" {
		return strings.clone(
			"aether: usage: /mcp set-token|enroll <server_name> <access_token>\n" +
			"Writes Grok-compatible ~/.grok/mcp_credentials.json for that server's URL from config,\n" +
			"then reconnects MCP so the token is used immediately.\n" +
			"Token may appear in shell history — prefer offline file write when possible.",
			allocator,
		)
	}
	name := r
	tok := ""
	if sp := strings.index_byte(r, ' '); sp >= 0 {
		name = strings.trim_space(r[:sp])
		tok = strings.trim_space(r[sp + 1:])
	}
	if name == "" || tok == "" {
		return strings.clone(
			"aether: usage: /mcp set-token|enroll <server_name> <access_token>",
			allocator,
		)
	}
	cfgs := mcp.load_mcp_configs()
	defer mcp.destroy_server_configs(cfgs)
	url, ok := mcp.find_mcp_server_url_in_configs(cfgs, name)
	if !ok {
		return fmt.aprintf(
			"aether: no HTTP mcp_servers.%s with url in config (check aether.toml / ~/.grok)",
			name,
			allocator = allocator,
		)
	}
	if err := mcp.upsert_mcp_credential(name, url, tok); err != "" {
		return fmt.aprintf("aether: credentials write failed: %s", err, allocator = allocator)
	}
	// Auto-reconnect so enroll is one step
	_ = maybe_restart_mcp(no_mcp, quiet)
	st := mcp_status_line(context.temp_allocator)
	return fmt.aprintf(
		"aether: enrolled access_token for %s (url %s) + reconnected\n%s\nNever commit credentials files.",
		name,
		url,
		st,
		allocator = allocator,
	)
}
