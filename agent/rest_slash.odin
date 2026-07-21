// Package agent — remaining Grok Build slash commands (text/TUI equivalents).
// When Grok opens a modal/pane Aether cannot, keep the same name and closest
// functional behavior (list / export / open URL / honest N/A).
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "aether:core"
import "aether:tools"

BUILD_DOCS_URL :: "https://docs.x.ai/build/overview"

// format_bg_tasks_list: snapshot of process-local background tasks.
format_bg_tasks_list :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	sync.mutex_lock(&g_bg_mu)
	n := len(g_bg_tasks)
	if n == 0 {
		sync.mutex_unlock(&g_bg_mu)
		strings.write_string(&b, "Background tasks: (none)\n")
		return strings.to_string(b)
	}
	fmt.sbprintf(&b, "Background tasks (%d):\n", n)
	for t in g_bg_tasks {
		kind := "subagent"
		switch t.task_kind {
		case .Subagent:
			kind = "subagent"
		case .Shell:
			kind = "shell"
		case .Monitor:
			kind = "monitor"
		}
		desc := t.description
		if len(desc) > 72 {
			desc = fmt.tprintf("%s…", desc[:69])
		}
		fmt.sbprintf(
			&b,
			"  - %s  [%s] %s  %s\n",
			t.id,
			bg_status_string(t.status),
			kind,
			desc,
		)
	}
	sync.mutex_unlock(&g_bg_mu)
	return strings.to_string(b)
}

// handle_tasks_slash: list bg + scheduled + session todos (Grok /tasks).
handle_tasks_slash :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "## tasks\n\n")
	bg := format_bg_tasks_list(context.temp_allocator)
	strings.write_string(&b, bg)
	strings.write_string(&b, "\n")
	sched := handle_scheduler_list("{}", context.temp_allocator)
	strings.write_string(&b, sched)
	if !strings.has_suffix(sched, "\n") {
		strings.write_string(&b, "\n")
	}
	strings.write_string(&b, "\nSession todos:\n")
	sum := tools.summarize_todo_state(context.temp_allocator)
	if sum == "" {
		strings.write_string(&b, "(none)\n")
	} else {
		strings.write_string(&b, sum)
		if !strings.has_suffix(sum, "\n") {
			strings.write_string(&b, "\n")
		}
	}
	return strings.to_string(b)
}

// handle_queue_slash: REPL/text path. TUI owns the live queue + pane.
handle_queue_slash :: proc(arg: string, allocator := context.allocator) -> string {
	a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
	if a == "help" || a == "?" {
		return strings.clone(
			"## queue\n" +
			"TUI: mid-turn type + Enter queues a follow-up; empty Enter force-sends #1.\n" +
			"  /queue          open queue pane (TUI) or show tips\n" +
			"  /queue clear    clear (TUI)\n" +
			"  /queue drop N   drop item N (TUI)\n",
			allocator,
		)
	}
	return strings.clone(
		"## queue\n" +
		"In the TUI, follow-ups typed while the agent is working are queued FIFO.\n" +
		"  Enter (with text)  → enqueue\n" +
		"  Empty Enter        → cancel turn and force-send queue head\n" +
		"  /queue             → list pane · drop/clear\n" +
		"(REPL has no mid-turn queue; send the next message when idle.)\n",
		allocator,
	)
}

// handle_docs_slash: discover + open online Build docs.
handle_docs_slash :: proc(arg: string, allocator := context.allocator) -> string {
	a := strings.trim_space(arg)
	al := strings.to_lower(a, context.temp_allocator)
	if al == "web" || al == "online" || al == "x.ai" || al == "url" {
		if open_browser_url(BUILD_DOCS_URL) {
			return strings.clone(
				fmt.tprintf("aether: opened %s", BUILD_DOCS_URL),
				allocator,
			)
		}
		return strings.clone(
			fmt.tprintf("aether: open in browser: %s", BUILD_DOCS_URL),
			allocator,
		)
	}
	if al == "" || al == "how-to" || al == "howto" || al == "guides" || al == "list" {
		b := strings.builder_make(allocator)
		strings.write_string(&b, "## docs\n")
		strings.write_string(&b, "In-product discover:\n")
		strings.write_string(&b, "  /help [filter]   sectioned slash commands\n")
		strings.write_string(&b, "  /about           product blurb + tips\n")
		strings.write_string(&b, "  /keys            TUI keyboard shortcuts\n")
		strings.write_string(&b, "  /doctor          health check\n")
		strings.write_string(&b, "  /status          auth / model / session\n")
		strings.write_string(&b, "  /release-notes   local CHANGELOG\n")
		strings.write_string(&b, "\nOnline (Grok Build):\n")
		fmt.sbprintf(&b, "  /docs web        → %s\n", BUILD_DOCS_URL)
		strings.write_string(&b, "  Repo: README.md · PORTING.md · docs/COMMAND_PARITY.md\n")
		return strings.to_string(b)
	}
	// Title-ish: search help catalog + about
	help_blob := handle_help_slash(a, context.temp_allocator)
	if strings.contains(strings.to_lower(help_blob, context.temp_allocator), al) &&
	   !strings.contains(help_blob, "(no matches)") {
		return strings.clone(help_blob, allocator)
	}
	return strings.clone(
		fmt.tprintf(
			"aether: no local guide matching %q — try /docs, /docs web, or /help %s",
			a,
			a,
		),
		allocator,
	)
}

// find_changelog_path: walk cwd and parents for CHANGELOG.md.
find_changelog_path :: proc(start: string, allocator := context.allocator) -> string {
	cur := start
	if cur == "" {
		if wd, err := os.get_working_directory(context.temp_allocator); err == nil {
			cur = wd
		} else {
			cur = "."
		}
	}
	for i := 0; i < 8; i += 1 {
		cand, _ := filepath.join({cur, "CHANGELOG.md"}, context.temp_allocator)
		if os.exists(cand) && !os.is_directory(cand) {
			return strings.clone(cand, allocator)
		}
		parent := filepath.dir(cur)
		if parent == cur || parent == "" {
			break
		}
		cur = parent
	}
	return ""
}

// handle_release_notes_slash: show CHANGELOG head (or version blurb).
handle_release_notes_slash :: proc(cwd: string, allocator := context.allocator) -> string {
	path := find_changelog_path(cwd, context.temp_allocator)
	b := strings.builder_make(allocator)
	strings.write_string(&b, "## release notes\n")
	fmt.sbprintf(&b, "version: %s\n\n", core.version_string())
	if path == "" {
		strings.write_string(
			&b,
			"No CHANGELOG.md found near the working directory.\n" +
			"See the aether repo CHANGELOG.md or run from the project root.\n",
		)
		return strings.to_string(b)
	}
	fmt.sbprintf(&b, "source: %s\n\n", path)
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		fmt.sbprintf(&b, "(could not read: %v)\n", err)
		return strings.to_string(b)
	}
	text := string(data)
	// Cap to first ~80 lines / 8k so TUI notices stay usable
	max_bytes := 8000
	max_lines := 80
	n_lines := 0
	end := 0
	for i := 0; i < len(text) && n_lines < max_lines && i < max_bytes; i += 1 {
		if text[i] == '\n' {
			n_lines += 1
		}
		end = i + 1
	}
	strings.write_string(&b, text[:end])
	if end < len(text) {
		strings.write_string(&b, "\n…[truncated; open CHANGELOG.md for full notes]\n")
	}
	return strings.to_string(b)
}

// handle_privacy_slash: persist local coding_data_share preference.
handle_privacy_slash :: proc(arg: string, allocator := context.allocator) -> string {
	a := strings.to_lower(strings.trim_space(arg), context.temp_allocator)
	switch a {
	case "":
		return core.privacy_status_text(allocator)
	case "opt-in", "in", "share":
		pe := core.set_privacy_coding_data_share(true)
		msg := "aether: privacy opt-in saved (coding_data_share=true in config.toml).\n" +
			"Still no remote coding-data API — local preference only.\n"
		if pe != "" {
			msg = fmt.tprintf("%s(persist note: %s)\n", msg, pe)
		}
		return strings.clone(msg, allocator)
	case "opt-out", "out", "private":
		pe := core.set_privacy_coding_data_share(false)
		msg := "aether: privacy opt-out saved (coding_data_share=false).\n"
		if pe != "" {
			msg = fmt.tprintf("%s(persist note: %s)\n", msg, pe)
		}
		return strings.clone(msg, allocator)
	case:
		return strings.clone(
			"aether: usage: /privacy [opt-in|opt-out]\nAliases: in, share | out, private\n",
			allocator,
		)
	}
}

// handle_terminal_setup_slash: environment / color / clipboard diagnostics.
handle_terminal_setup_slash :: proc(allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "## terminal-setup\n")
	term := os.get_env("TERM", context.temp_allocator)
	colorterm := os.get_env("COLORTERM", context.temp_allocator)
	term_prog := os.get_env("TERM_PROGRAM", context.temp_allocator)
	tmux := os.get_env("TMUX", context.temp_allocator)
	ssh := os.get_env("SSH_CONNECTION", context.temp_allocator)
	no_color := os.get_env("NO_COLOR", context.temp_allocator)
	pager := os.get_env("PAGER", context.temp_allocator)
	cols := os.get_env("COLUMNS", context.temp_allocator)
	lines := os.get_env("LINES", context.temp_allocator)

	strings.write_string(&b, "Environment\n")
	fmt.sbprintf(&b, "  TERM         %s\n", term if term != "" else "(unset)")
	fmt.sbprintf(&b, "  COLORTERM    %s\n", colorterm if colorterm != "" else "(unset)")
	fmt.sbprintf(&b, "  TERM_PROGRAM %s\n", term_prog if term_prog != "" else "(unset)")
	fmt.sbprintf(&b, "  tmux         %s\n", "yes" if tmux != "" else "no")
	fmt.sbprintf(&b, "  ssh          %s\n", "yes" if ssh != "" else "no")
	fmt.sbprintf(&b, "  NO_COLOR     %s\n", no_color if no_color != "" else "(unset)")
	fmt.sbprintf(&b, "  COLUMNS/LINES %s / %s\n", cols if cols != "" else "?", lines if lines != "" else "?")
	fmt.sbprintf(&b, "  PAGER        %s\n", pager if pager != "" else "less (default for /transcript)")

	// Color
	strings.write_string(&b, "\nColor\n")
	if no_color != "" {
		strings.write_string(&b, "  NO_COLOR is set — structural SGR may still apply in TUI markdown.\n")
	} else if colorterm == "truecolor" || colorterm == "24bit" {
		strings.write_string(&b, "  truecolor reported (COLORTERM)\n")
	} else {
		strings.write_string(&b, "  limited color env; for full themes set COLORTERM=truecolor when supported\n")
	}

	// Clipboard
	strings.write_string(&b, "\nClipboard\n")
	has_wl := doctor_cmd_ok("wl-copy") || doctor_cmd_ok("wl-paste")
	has_xclip := doctor_cmd_ok("xclip")
	has_xsel := doctor_cmd_ok("xsel")
	has_pb := doctor_cmd_ok("pbcopy")
	if has_wl {
		strings.write_string(&b, "  wayland: wl-copy/wl-paste available\n")
	}
	if has_xclip {
		strings.write_string(&b, "  x11: xclip available\n")
	}
	if has_xsel {
		strings.write_string(&b, "  x11: xsel available\n")
	}
	if has_pb {
		strings.write_string(&b, "  macOS: pbcopy available\n")
	}
	if !has_wl && !has_xclip && !has_xsel && !has_pb {
		strings.write_string(
			&b,
			"  no known clipboard helper (install wl-clipboard, xclip, or use OSC 52)\n",
		)
	}

	strings.write_string(&b, "\nTips\n")
	strings.write_string(&b, "  /toggle-mouse-reporting  toggle SGR mouse capture in TUI\n")
	strings.write_string(&b, "  /theme list              color themes\n")
	strings.write_string(&b, "  /keys                    keyboard shortcuts\n")
	if tmux != "" {
		strings.write_string(
			&b,
			"  tmux: enable clipboard with set -g set-clipboard on (or OSC 52)\n",
		)
	}
	return strings.to_string(b)
}

// handle_logout_slash: remove disk auth when not using env API key.
handle_logout_slash :: proc(allocator := context.allocator) -> string {
	if key := os.get_env("XAI_API_KEY", context.temp_allocator); key != "" {
		return strings.clone(
			"aether: signed in via XAI_API_KEY — unset that env var to log out (auth.json not used).",
			allocator,
		)
	}
	if key := os.get_env("GROK_CODE_XAI_API_KEY", context.temp_allocator); key != "" {
		return strings.clone(
			"aether: signed in via GROK_CODE_XAI_API_KEY — unset that env var to log out.",
			allocator,
		)
	}
	if inline := os.get_env("GROK_AUTH", context.temp_allocator); inline != "" {
		return strings.clone(
			"aether: GROK_AUTH is set in the environment — unset it to log out.",
			allocator,
		)
	}
	path := core.auth_json_path(context.temp_allocator)
	if !os.exists(path) {
		return strings.clone(
			fmt.tprintf("aether: already signed out (no %s)", path),
			allocator,
		)
	}
	// Rename to .bak so user can recover
	bak := fmt.tprintf("%s.bak", path)
	_ = os.remove(bak) // best-effort replace previous bak
	if rerr := os.rename(path, bak); rerr != nil {
		// fallback: delete
		if derr := os.remove(path); derr != nil {
			return strings.clone(
				fmt.tprintf("aether: logout failed (could not remove %s: %v)", path, rerr),
				allocator,
			)
		}
		return strings.clone(
			fmt.tprintf("aether: logged out (removed %s). Use /login to sign in again.", path),
			allocator,
		)
	}
	return strings.clone(
		fmt.tprintf(
			"aether: logged out (moved %s → %s). Use /login to sign in again.",
			path,
			bak,
		),
		allocator,
	)
}

// handle_cd_slash: change session/process workspace cwd.
// msg is always heap-owned (caller deletes). new_cwd is heap-owned when non-empty.
handle_cd_slash :: proc(
	arg: string,
	cur_cwd: string,
	allocator := context.allocator,
) -> (msg: string, new_cwd: string) {
	a := strings.trim_space(arg)
	if a == "" || a == "status" || a == "?" {
		show := cur_cwd
		if show == "" {
			if wd, err := os.get_working_directory(context.temp_allocator); err == nil {
				show = wd
			} else {
				show = "."
			}
		}
		return strings.clone(fmt.tprintf("aether: cwd = %s", show), allocator), ""
	}
	if a == "help" {
		return strings.clone(
			"aether: usage: /cd [path]\n  bare /cd shows workspace; /cd <path> changes it for tools + session.",
			allocator,
		), ""
	}
	// Expand ~
	target := a
	if strings.has_prefix(a, "~") {
		home, herr := os.user_home_dir(context.temp_allocator)
		if herr == nil && home != "" {
			if a == "~" {
				target = home
			} else if strings.has_prefix(a, "~/") {
				joined, _ := filepath.join({home, a[2:]}, context.temp_allocator)
				target = joined
			}
		}
	}
	// Relative to current workspace when not absolute
	if !filepath.is_abs(target) {
		base := cur_cwd if cur_cwd != "" else "."
		joined, _ := filepath.join({base, target}, context.temp_allocator)
		target = joined
	}
	abs, aerr := filepath.abs(target, context.temp_allocator)
	if aerr != nil {
		abs = target
	}
	if !os.exists(abs) {
		return strings.clone(fmt.tprintf("aether: path not found: %s", abs), allocator), ""
	}
	if !os.is_directory(abs) {
		return strings.clone(fmt.tprintf("aether: not a directory: %s", abs), allocator), ""
	}
	owned := strings.clone(abs, allocator)
	if cerr := os.change_directory(owned); cerr != nil {
		// Still update logical cwd for tools even if process chdir fails
		return strings.clone(
			fmt.tprintf("aether: workspace set to %s (process chdir failed: %v)", owned, cerr),
			allocator,
		), owned
	}
	return strings.clone(fmt.tprintf("aether: cwd → %s", owned), allocator), owned
}

// handle_transcript_export: write markdown transcript; return path or error text.
// open_pager=false → just export (caller may open pager).
handle_transcript_export :: proc(
	sess: Session,
	allocator := context.allocator,
) -> (path: string, err: string) {
	p, e := session_export_markdown(sess, "", allocator)
	if e != "" {
		return "", e
	}
	return p, ""
}

// handle_transcript_slash: export + path; note about $PAGER (TUI opens pager).
handle_transcript_slash :: proc(sess: Session, allocator := context.allocator) -> string {
	path, e := handle_transcript_export(sess, context.temp_allocator)
	if e != "" {
		return strings.clone(fmt.tprintf("aether: transcript failed: %s", e), allocator)
	}
	pager := os.get_env("PAGER", context.temp_allocator)
	if pager == "" {
		pager = "less"
	}
	return strings.clone(
		fmt.tprintf(
			"aether: transcript → %s\n  open with: %s %s\n  (TUI /transcript suspends and runs $PAGER)",
			path,
			pager,
			path,
		),
		allocator,
	)
}

// handle_share_slash: local share — export markdown + copy path to clipboard.
handle_share_slash :: proc(sess: ^Session, allocator := context.allocator) -> string {
	if sess == nil {
		return strings.clone("aether: no active session to share", allocator)
	}
	// Path must be freed with the same allocator used to create it.
	path, e := session_export_markdown(sess^, "", allocator)
	if e != "" {
		return strings.clone(
			fmt.tprintf(
				"aether: share export failed: %s\n  Session file: %s\n",
				e,
				sess.path,
			),
			allocator,
		)
	}
	defer delete(path, allocator)
	// Clipboard gets path (and a short hint); public URL N/A
	clip := fmt.tprintf("%s\n", path)
	cst := copy_text_to_clipboard(clip)
	return strings.clone(
		fmt.tprintf(
			"aether: local share ready (no public URL).\n" +
			"  transcript: %s\n" +
			"  clipboard: %s\n" +
			"  session: %s\n",
			path,
			cst,
			sess.path,
		),
		allocator,
	)
}

// handle_voice_slash: dictation not implemented.
handle_voice_slash :: proc(allocator := context.allocator) -> string {
	return strings.clone(
		"aether: /voice dictation is not available in Aether (Grok Build only).\n" +
		"  Type in the prompt, or paste from the system dictation tool.\n",
		allocator,
	)
}

// handle_marketplace_slash: plugins list + install tips.
handle_marketplace_slash :: proc(cwd: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "## marketplace\n")
	strings.write_string(
		&b,
		"No remote marketplace UI. Local plugins (same as /plugins):\n\n",
	)
	pout := handle_plugins_slash("", cwd, context.temp_allocator)
	strings.write_string(&b, pout)
	strings.write_string(
		&b,
		"\nInstall: /plugins add <path-or-url> · list: /plugins · skills: /skills\n",
	)
	return strings.to_string(b)
}

// handle_config_agents_slash: list personas + subagent types.
handle_config_agents_slash :: proc(cwd: string, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "## config-agents\n")
	strings.write_string(
		&b,
		"No agents modal. Subagent personas (spawn_subagent persona=):\n\n",
	)
	plist := format_personas_list(cwd, context.temp_allocator)
	strings.write_string(&b, plist)
	strings.write_string(
		&b,
		"\nBuilt-in subagent types: general-purpose, explore, plan\n" +
		"Personas: ~/.grok/personas/ or <cwd>/.grok/personas/\n" +
		"See also: /personas · /skills · /create-skill\n",
	)
	return strings.to_string(b)
}

// import-claude lives in import_claude.odin (scan/apply merge).

// handle_dashboard_slash: text snapshot (TUI opens interactive dashboard).
handle_dashboard_slash :: proc(sess: ^Session, allocator := context.allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_string(&b, "## dashboard\n")
	strings.write_string(
		&b,
		"TUI: /dashboard opens interactive overview (Enter load · k kill bg).\n\n",
	)
	if sess != nil {
		fmt.sbprintf(
			&b,
			"Current: %s  %q  msgs=%d  cwd=%s\n\n",
			sess.id,
			sess.title if sess.title != "" else "(none)",
			len(sess.msgs),
			sess.cwd,
		)
		dir := sess.sessions_dir
		if dir == "" {
			dir = core.aether_sessions_dir("", context.temp_allocator)
		}
		entries, err := list_sessions(dir, context.temp_allocator)
		if err == "" && len(entries) > 0 {
			fmt.sbprintf(&b, "Saved sessions (newest, max 8):\n")
			n := min(8, len(entries))
			for i in 0 ..< n {
				e := entries[i]
				cur := e.id == sess.id || e.path == sess.path
				mark := " " if !cur else "*"
				fmt.sbprintf(&b, " %s %s  %s\n", mark, e.id, e.title if e.title != "" else "(untitled)")
			}
			strings.write_string(&b, "\n")
		}
	}
	bg := format_bg_tasks_list(context.temp_allocator)
	strings.write_string(&b, bg)
	strings.write_string(
		&b,
		"\n  /resume  session picker  ·  /tasks  bg+scheduler  ·  /fork  branch session\n",
	)
	return strings.to_string(b)
}

// handle_expand_slash: document expand (TUI expands last tool card).
handle_expand_slash :: proc(allocator := context.allocator) -> string {
	return strings.clone(
		"aether: /expand expands the last tool card in the TUI (same as `e` / Ctrl+E).\n" +
		"  Headless/REPL: use /export or /transcript for full tool output.\n",
		allocator,
	)
}

// run_transcript_pager: best-effort open $PAGER on path (blocks). Returns "" ok or error.
run_transcript_pager :: proc(path: string) -> string {
	if path == "" {
		return "empty path"
	}
	p := os.get_env("PAGER", context.temp_allocator)
	if p == "" {
		p = "less"
	}
	argv: []string
	if strings.contains(p, " ") {
		argv = []string{"sh", "-c", fmt.tprintf("%s %q", p, path)}
	} else if p == "less" {
		argv = []string{"less", "-R", path}
	} else {
		argv = []string{p, path}
	}
	state, _, _, err := os.process_exec(
		{command = argv},
		context.temp_allocator,
	)
	if err != nil {
		// try less
		state2, _, _, err2 := os.process_exec(
			{command = {"less", "-R", path}},
			context.temp_allocator,
		)
		if err2 != nil {
			return fmt.tprintf("pager failed: %v (also less: %v); path: %s", err, err2, path)
		}
		_ = state2
		return ""
	}
	_ = state
	return ""
}
