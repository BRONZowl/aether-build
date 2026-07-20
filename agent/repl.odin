package agent

import "core:bufio"
import "core:fmt"
import "core:os"
import "core:strings"
import "aether:core"

// run_repl interactive multi-turn session with shared history + optional disk persistence.
run_repl :: proc(opts: Headless_Options) -> int {
	cfg := core.load_runtime_config(opts.model, opts.cwd, opts.max_turns, opts.permission_mode)
	apply_config_reasoning_effort(cfg.reasoning_effort)
	_ = maybe_start_mcp(opts.no_mcp, opts.quiet)
	defer maybe_stop_mcp(nil) // always stop global (safe after /mcp reconnect)
	maybe_start_hooks(cfg.cwd if cfg.cwd != "" else opts.cwd, opts.quiet)
	defer maybe_stop_hooks("exit")
	sreg := maybe_start_skills(cfg.cwd, opts.quiet)
	defer maybe_stop_skills(sreg)
	defer core.destroy_runtime_config(&cfg)

	creds, aerr := resolve_credentials()
	if aerr != "" {
		fmt.eprintf("aether: %s\n", aerr)
		return 1
	}
	defer destroy_credentials(&creds)

	auto_save := !opts.no_autosave
	sess, serr := open_repl_session(opts, cfg.model, cfg.cwd, auto_save, cfg.permission_mode)
	if serr != "" {
		fmt.eprintf("aether: %s\n", serr)
		return 1
	}
	defer destroy_session(&sess)

	model := sess.model if sess.model != "" else cfg.model
	cwd := sess.cwd if sess.cwd != "" else cfg.cwd
	perm := cfg.permission_mode

	if !opts.quiet {
		who := creds.email if creds.email != "" else (creds.user_id if creds.user_id != "" else "api-key")
		mode := "session" if creds.kind == .Session else "api-key"
		fmt.eprintf(
			"aether: auth=%s as %s model=%s cwd=%s perm=%s\n",
			mode,
			who,
			model,
			cwd,
			core.permission_mode_string(perm),
		)
		title := sess.title if sess.title != "" else "(untitled)"
		fmt.eprintf(
			"aether: chat session=%s title=%s autosave=%v\n",
			sess.id,
			title,
			sess.auto_save,
		)
		// Grok-parity welcome on REPL start (logo + menu + tip)
		if core.brand_art_enabled() {
			art := core.brand_render_welcome(24, 80, context.temp_allocator)
			if art != "" {
				fmt.eprintf("%s\n", art)
			}
		} else {
			fmt.eprintf("%s\n", core.brand_repl_no_art_banner(context.temp_allocator))
		}
	}

	reader: bufio.Reader
	bufio.reader_init(&reader, os.to_reader(os.stdin))
	defer bufio.reader_destroy(&reader)

	for {
		// Idle auto-wake: surface finished bg tasks without a user prompt
		{
			ask_turn_allow := false
			wake_opts := Turn_Options {
				workspace         = cwd,
				max_turns         = cfg.max_turns,
				quiet             = opts.quiet,
				verbose           = opts.verbose,
				permission_mode   = perm,
				permission_live   = &perm,
				permission_allow  = cfg.permission_allow[:],
				permission_deny   = cfg.permission_deny[:],
				ask_turn_allow    = &ask_turn_allow,
				mcp_enabled       = mcp_enabled_for_turn(nil),
				skills_enabled    = skills_enabled_for_turn(),
				subagents_enabled = subagents_enabled(),
			}
			ran, wcode := try_idle_auto_wake(creds, model, &sess.msgs, wake_opts)
			if ran {
				if wcode != 0 && !opts.quiet {
					fmt.eprintf("aether: auto-wake turn ended code=%d\n", wcode)
				}
				if sess.auto_save {
					if e := session_save(&sess); e != "" && !opts.quiet {
						fmt.eprintf("aether: autosave failed: %s\n", e)
					}
				}
				// Loop again so another wake can fire if more tasks completed
				continue
			}
		}

		fmt.eprint("> ")
		line, rerr := bufio.reader_read_string(&reader, '\n', context.allocator)
		if rerr == .EOF {
			if len(line) == 0 {
				fmt.eprintln()
				if sess.auto_save {
					_ = session_save(&sess)
				}
				return 0
			}
		} else if rerr != nil && rerr != .EOF {
			fmt.eprintf("aether: read error: %v\n", rerr)
			delete(line)
			return 1
		}

		trimmed := strings.trim_space(line)
		text := strings.clone(trimmed)
		delete(line)

		if text == "" {
			delete(text)
			if rerr == .EOF {
				if note := maybe_auto_dream(&sess, model); note != "" && !opts.quiet {
					fmt.eprintln(note)
				}
				if sess.auto_save {
					_ = session_save(&sess)
				}
				return 0
			}
			continue
		}

		if strings.has_prefix(text, "/") {
			action := run_slash(&sess, text, opts, &model, &cwd, &perm, nil)
			delete(text)
			if action == .Exit {
				// /exit already ran maybe_auto_dream inside slash
				if sess.auto_save {
					if e := session_save(&sess); e != "" && !opts.quiet {
						fmt.eprintf("aether: save on exit: %s\n", e)
					}
				}
				return 0
			}
			// Session_Changed / Continue: REPL just keeps looping
			continue
		}

		// UserPromptSubmit hooks may block the turn
		if !allow_user_prompt(cwd, text, opts.quiet) {
			delete(text)
			continue
		}

		// B28: durable global prompt history (shared with TUI Up/Down)
		_ = core.append_prompt_history(text)

		append(
			&sess.msgs,
			Chat_Message {
				role    = .User,
				content = text,
			},
		)

		ask_turn_allow := false
		turn := Turn_Options {
			workspace         = cwd,
			max_turns         = cfg.max_turns,
			quiet             = opts.quiet,
			verbose           = opts.verbose,
			permission_mode   = perm,
			permission_live   = &perm,
			permission_allow  = cfg.permission_allow[:],
			permission_deny   = cfg.permission_deny[:],
			ask_turn_allow    = &ask_turn_allow,
			mcp_enabled       = mcp_enabled_for_turn(nil),
			skills_enabled    = skills_enabled_for_turn(),
			subagents_enabled = subagents_enabled(),
			memory_injected   = &sess.memory_injected,
			session           = &sess,
		}
		final_text, code := run_agent_turn(creds, model, &sess.msgs, turn)
		maybe_notify_agent_turn(code, sess.title, final_text, cwd)
		if code == 0 {
			delete(final_text)
		} else if code == 2 {
			// max-turns detail already emitted by loop when !quiet
			if opts.quiet {
				fmt.eprintln("aether: max tool iterations; history kept — continue or /clear")
			}
		} else if code == 3 {
			fmt.eprintln("aether: model error; history kept — try again or /clear")
		} else if code == 4 {
			if !opts.quiet {
				fmt.eprintln("aether: turn cancelled; history kept")
			}
		}
		// Autosave any turn that may have mutated history (not only success).
		if sess.auto_save {
			if e := session_save(&sess); e != "" && !opts.quiet {
				fmt.eprintf("aether: autosave failed: %s\n", e)
			}
		}

		if rerr == .EOF {
			if sess.auto_save {
				_ = session_save(&sess)
			}
			return 0
		}

		if len(sess.msgs) > 80 && !opts.quiet {
			fmt.eprintf(
				"aether: history is large (%d messages); consider /clear or /new\n",
				len(sess.msgs),
			)
		}
	}
}

open_repl_session :: proc(
	opts: Headless_Options,
	model: string,
	cwd: string,
	auto_save: bool,
	perm: core.Permission_Mode,
) -> (Session, string) {
	if opts.session_ref != "" {
		path, err := resolve_session_ref(opts.session_ref, opts.sessions_dir, context.temp_allocator)
		if err != "" {
			return {}, err
		}
		return session_load_file(path, auto_save)
	}
	if opts.continue_last {
		path := most_recent_session_path(opts.sessions_dir, context.temp_allocator)
		if path == "" {
			return {}, "no previous sessions to continue"
		}
		return session_load_file(path, auto_save)
	}
	catalog := skills_catalog_text(context.temp_allocator)
	return new_session(model, cwd, opts.sessions_dir, auto_save, perm, context.allocator, catalog), ""
}


