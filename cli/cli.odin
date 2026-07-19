// Package cli — argument parsing and subcommand dispatch.
// Rust reference: crates/codegen/xai-grok-pager-bin, shell entrypoints / headless -p.
package cli

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sys/posix"
import "aether:agent"
import "aether:core"
import "aether:tui"

// stdin_stdout_tty: true when both ends look like a terminal (safe for TUI).
stdin_stdout_tty :: proc() -> bool {
	return bool(posix.isatty(posix.STDIN_FILENO)) && bool(posix.isatty(posix.STDOUT_FILENO))
}

// default_interactive: bare invoke prefers TUI on a TTY, else line REPL.
default_interactive :: proc() -> Command {
	if stdin_stdout_tty() {
		return .Tui
	}
	return .Repl
}

Command :: enum {
	None,
	Help,
	Version,
	Whoami,
	Login,
	Headless,
	Repl,
	Tui,
	Unknown,
}

Parse_Result :: struct {
	command:        Command,
	unknown:        string,
	prompt:         string,
	model:          string,
	max_turns:      int,
	cwd:            string,
	quiet:          bool,
	verbose:        bool,
	session_ref:      string,
	continue_last:    bool,
	no_autosave:      bool,
	sessions_dir:     string,
	permission_mode:  string,
	no_mcp:           bool,
	login_args:       [dynamic]string, // passthrough after `login`
}

destroy_parse_result :: proc(r: ^Parse_Result) {
	delete(r.prompt)
	delete(r.model)
	delete(r.cwd)
	delete(r.unknown)
	delete(r.session_ref)
	delete(r.sessions_dir)
	delete(r.permission_mode)
	for a in r.login_args {
		delete(a)
	}
	delete(r.login_args)
}

parse :: proc() -> Parse_Result {
	args := os.args[1:]
	result := Parse_Result {
		max_turns = 0,
	}
	if len(args) == 0 {
		result.command = default_interactive()
		return result
	}

	i := 0
	for i < len(args) {
		a := args[i]
		switch a {
		case "--help", "-h", "help":
			result.command = .Help
			return result
		case "--version", "-V", "-v", "version":
			result.command = .Version
			return result
		case "whoami":
			result.command = .Whoami
		case "login":
			// Host bridge: `aether login [args…]` → `grok login [args…]`
			result.command = .Login
			result.login_args = make([dynamic]string, 0, 4, context.allocator)
			i += 1
			for i < len(args) {
				append(&result.login_args, strings.clone(args[i]))
				i += 1
			}
			return result
		case "chat", "repl":
			result.command = .Repl
		case "tui":
			result.command = .Tui
		case "-p", "--print", "--single":
			if i + 1 >= len(args) {
				fmt.eprintln("aether: -p requires a prompt argument")
				result.command = .Help
				return result
			}
			i += 1
			result.prompt = strings.clone(args[i])
			result.command = .Headless
		case "-m", "--model":
			if i + 1 >= len(args) {
				fmt.eprintln("aether: -m requires a model id")
				result.command = .Help
				return result
			}
			i += 1
			result.model = strings.clone(args[i])
		case "--max-turns":
			if i + 1 >= len(args) {
				fmt.eprintln("aether: --max-turns requires a number")
				result.command = .Help
				return result
			}
			i += 1
			n, ok := strconv.parse_int(args[i])
			if !ok || n < 0 {
				fmt.eprintln("aether: invalid --max-turns value")
				result.command = .Help
				return result
			}
			result.max_turns = n
		case "--cwd":
			if i + 1 >= len(args) {
				fmt.eprintln("aether: --cwd requires a path")
				result.command = .Help
				return result
			}
			i += 1
			result.cwd = strings.clone(args[i])
		case "--session":
			if i + 1 >= len(args) {
				fmt.eprintln("aether: --session requires an id, title, or path")
				result.command = .Help
				return result
			}
			i += 1
			result.session_ref = strings.clone(args[i])
			if result.command == .None {
				result.command = default_interactive()
			}
		case "--continue", "-c":
			result.continue_last = true
			if result.command == .None {
				result.command = default_interactive()
			}
		case "--no-autosave":
			result.no_autosave = true
		case "--no-mcp":
			result.no_mcp = true
		case "--sessions-dir":
			if i + 1 >= len(args) {
				fmt.eprintln("aether: --sessions-dir requires a path")
				result.command = .Help
				return result
			}
			i += 1
			result.sessions_dir = strings.clone(args[i])
		case "--quiet", "-q":
			result.quiet = true
		case "--verbose":
			result.verbose = true
		case "--permission-mode":
			if i + 1 >= len(args) {
				fmt.eprintln("aether: --permission-mode requires always-approve|auto|read-only|ask")
				result.command = .Help
				return result
			}
			i += 1
			result.permission_mode = strings.clone(args[i])
		case "--yolo", "--always-approve":
			result.permission_mode = strings.clone("always-approve")
		case "--read-only":
			result.permission_mode = strings.clone("read-only")
		case:
			if strings.has_prefix(a, "-") {
				result.command = .Unknown
				result.unknown = strings.clone(a)
				return result
			}
			// bare prompt after optional flags → headless (even if default would be TUI)
			if result.command == .None || result.command == .Repl || result.command == .Tui {
				if result.prompt == "" {
					result.prompt = strings.clone(a)
					result.command = .Headless
				} else {
					result.command = .Unknown
					result.unknown = strings.clone(a)
					return result
				}
			} else if result.command == .Whoami {
				result.command = .Unknown
				result.unknown = strings.clone(a)
				return result
			} else {
				result.command = .Unknown
				result.unknown = strings.clone(a)
				return result
			}
		}
		i += 1
	}

	if result.command == .None {
		if result.prompt != "" {
			result.command = .Headless
		} else {
			result.command = default_interactive()
		}
	}
	return result
}

print_help :: proc() {
	fmt.println(core.PROJECT_NAME, "—", core.DESCRIPTION)
	fmt.println()
	fmt.println("Usage (prefer command name aether-grok on PATH):")
	fmt.println("  aether-grok                    Fullscreen TUI (TTY; else line REPL)")
	fmt.println("  aether-grok tui [flags]        Fullscreen chat UI")
	fmt.println("  aether-grok chat|repl [flags]  Multi-turn line REPL")
	fmt.println("  aether-grok [flags] -p TEXT    One-shot headless turn")
	fmt.println("  aether-grok login | whoami | help | version")
	fmt.println()
	fmt.println("Also installed: aether-grok-odin, grok-odin (same binary).")
	fmt.println("Note: plain `aether` may be Arch's desktop theme tool (/usr/bin/aether) — not this product.")
	fmt.println()
	fmt.println("Agent flags (auth: XAI_API_KEY or ~/.grok/auth.json):")
	fmt.println("  -p, --print, --single TEXT   One-shot session, print answer, exit")
	fmt.println("  -m, --model ID               Model override (default from aether.toml)")
	fmt.println("  --max-turns N                Cap tool loop turns per prompt (default 20)")
	fmt.println("  --cwd DIR                    Workspace root for tools (default: process cwd)")
	fmt.println("  -q, --quiet                  Suppress progress on stderr")
	fmt.println("  --verbose                    Extra diagnostics (never prints tokens)")
	fmt.println("  --permission-mode MODE       always-approve | auto | read-only | ask")
	fmt.println("  --yolo / --always-approve    Auto-approve write/shell tools")
	fmt.println("  --read-only                  Deny write/shell tools")
	fmt.println()
	fmt.println("Sessions (~/.grok/aether/sessions):")
	fmt.println("  --session ID|title|path      Resume a saved session")
	fmt.println("  -c, --continue               Resume most recent session")
	fmt.println("  --no-autosave                Disable save-after-turn")
	fmt.println("  --no-mcp                     Disable MCP server startup")
	fmt.println("  --sessions-dir DIR           Override session store")
	fmt.println()
	fmt.println("In TUI/REPL: /help /login /whoami /session /sessions /save /load /new /clear /exit")
	fmt.println()
	fmt.println("Other:")
	fmt.println("  login [--host]               Device-code sign-in (in-process); --host → grok login")
	fmt.println("  whoami                       Show signed-in identity (no secrets)")
	fmt.println("  help, --help, -h             Show this help")
	fmt.println("  version, --version           Print version")
	fmt.println()
	fmt.println("Exit codes: 0 ok, 1 usage/auth, 2 max turns, 3 model/HTTP error, 4 cancelled")
	fmt.println("Auth (R0-A): set XAI_API_KEY (recommended). Or `aether-grok login` device flow (M7).")
	fmt.println("      Existing ~/.grok/auth.json works. Host grok optional: aether-grok login --host")
}

print_version :: proc() {
	fmt.println(core.version_string())
}

run :: proc() -> int {
	result := parse()
	defer destroy_parse_result(&result)

	opts := agent.Headless_Options {
		prompt           = result.prompt,
		model            = result.model,
		max_turns        = result.max_turns,
		cwd              = result.cwd,
		quiet            = result.quiet,
		verbose          = result.verbose,
		session_ref      = result.session_ref,
		continue_last    = result.continue_last,
		no_autosave      = result.no_autosave,
		sessions_dir     = result.sessions_dir,
		permission_mode  = result.permission_mode,
		no_mcp           = result.no_mcp,
	}

	switch result.command {
	case .Help:
		print_help()
		return 0
	case .None:
		// Should be filled by parse(); default interactive if not
		if default_interactive() == .Tui {
			return tui.run(opts)
		}
		return agent.run_repl(opts)
	case .Version:
		print_version()
		return 0
	case .Whoami:
		return agent.run_whoami(result.verbose)
	case .Login:
		return agent.run_host_login(result.login_args[:], result.quiet)
	case .Headless:
		return agent.run_headless(opts)
	case .Repl:
		return agent.run_repl(opts)
	case .Tui:
		return tui.run(opts)
	case .Unknown:
		fmt.eprintf("unknown command: %s\n\n", result.unknown)
		print_help()
		return 1
	}
	return 0
}
