package hooks

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import "core:time"
import "aether:core"

@(test)
test_tool_name_matches :: proc(t: ^testing.T) {
	testing.expect(t, tool_name_matches("", "run_terminal_cmd"))
	testing.expect(t, tool_name_matches("run_terminal_cmd", "run_terminal_cmd"))
	testing.expect(t, tool_name_matches("Bash", "run_terminal_cmd"))
	testing.expect(t, tool_name_matches("Bash|Edit", "run_terminal_cmd"))
	testing.expect(t, !tool_name_matches("Write", "run_terminal_cmd"))
	testing.expect(t, tool_name_matches("Write", "write"))
}

@(test)
test_parse_event_name :: proc(t: ^testing.T) {
	e, ok := parse_event_name("PreToolUse")
	testing.expect(t, ok && e == .Pre_Tool_Use)
	e2, ok2 := parse_event_name("session_start")
	testing.expect(t, ok2 && e2 == .Session_Start)
	e3, ok3 := parse_event_name("PostToolUse")
	testing.expect(t, ok3 && e3 == .Post_Tool_Use)
	e4, ok4 := parse_event_name("post_tool_use_failure")
	testing.expect(t, ok4 && e4 == .Post_Tool_Use_Failure)
	e5, ok5 := parse_event_name("SessionEnd")
	testing.expect(t, ok5 && e5 == .Session_End)
	e6, ok6 := parse_event_name("Stop")
	testing.expect(t, ok6 && e6 == .Stop)
	e7, ok7 := parse_event_name("UserPromptSubmit")
	testing.expect(t, ok7 && e7 == .User_Prompt_Submit)
	e8, ok8 := parse_event_name("beforeSubmitPrompt")
	testing.expect(t, ok8 && e8 == .User_Prompt_Submit)
	e9, ok9 := parse_event_name("PermissionDenied")
	testing.expect(t, ok9 && e9 == .Permission_Denied)
	e10, ok10 := parse_event_name("SubagentStart")
	testing.expect(t, ok10 && e10 == .Subagent_Start)
	e11, ok11 := parse_event_name("SubagentEnd")
	testing.expect(t, ok11 && e11 == .Subagent_Stop)
	e12, ok12 := parse_event_name("PreCompact")
	testing.expect(t, ok12 && e12 == .Pre_Compact)
	e13, ok13 := parse_event_name("post_compact")
	testing.expect(t, ok13 && e13 == .Post_Compact)
	e14, ok14 := parse_event_name("Notification")
	testing.expect(t, ok14 && e14 == .Notification)
	e15, ok15 := parse_event_name("notification")
	testing.expect(t, ok15 && e15 == .Notification)
	_, ok16 := parse_event_name("Unknown")
	testing.expect(t, !ok16)
}

@(test)
test_load_hooks_from_file :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-hooks-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)

	body := `{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash|run_terminal_cmd",
        "hooks": [
          { "type": "command", "command": "bin/guard.sh", "timeout": 3 }
        ]
      }
    ],
    "SessionStart": [
      {
        "hooks": [
          { "type": "command", "command": "bin/log.sh", "timeout": 2 }
        ]
      }
    ]
  }
}`
	path, _ := filepath.join({dir, "test.json"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)body) == nil)

	specs := make([dynamic]Hook_Spec, 0, 4, context.allocator)
	defer {
		for &s in specs {
			destroy_spec(&s)
		}
		delete(specs)
	}
	load_hooks_from_file(path, dir, &specs, context.allocator)
	testing.expectf(t, len(specs) == 2, "got %d", len(specs))
	has_pre := false
	has_start := false
	for s in specs {
		if s.event == .Pre_Tool_Use {
			has_pre = true
			testing.expect(t, strings.contains(s.matcher, "Bash"))
			testing.expect(t, s.timeout_s == 3)
		}
		if s.event == .Session_Start {
			has_start = true
		}
	}
	testing.expect(t, has_pre && has_start)
}

@(test)
test_run_hook_deny_exit_2 :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-hook-run-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)

	script := `#!/bin/sh
echo '{"decision":"deny","reason":"blocked for test"}'
exit 2
`
	sp, _ := filepath.join({dir, "deny.sh"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(sp, transmute([]byte)script) == nil)
	_ = os.chmod(sp, os.perm(0o755))

	spec := Hook_Spec {
		event      = .Pre_Tool_Use,
		name       = "deny-test",
		command    = "deny.sh",
		timeout_s  = 5,
		matcher    = "",
		source_dir = strings.clone(dir),
	}
	defer delete(spec.source_dir)

	env := `{"hook_event_name":"PreToolUse","tool_name":"run_terminal_cmd","tool_input":{}}`
	dec, reason, code := run_hook_command(spec, env, true)
	testing.expectf(t, dec == .Deny, "dec=%v reason=%s code=%d", dec, reason, code)
	testing.expect(t, code == 2)
	testing.expect(t, strings.contains(reason, "blocked") || reason != "")
}

@(test)
test_run_hook_allow_and_missing_fail_open :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-hook-allow-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)

	script := `#!/bin/sh
echo '{"decision":"allow"}'
exit 0
`
	sp, _ := filepath.join({dir, "allow.sh"}, context.temp_allocator)
	_ = os.write_entire_file(sp, transmute([]byte)script)
	_ = os.chmod(sp, os.perm(0o755))

	spec := Hook_Spec {
		event      = .Pre_Tool_Use,
		name       = "allow-test",
		command    = "allow.sh",
		timeout_s  = 5,
		source_dir = strings.clone(dir),
	}
	defer delete(spec.source_dir)
	dec, _, code := run_hook_command(spec, `{}`, true)
	testing.expect(t, dec == .Allow)
	testing.expect(t, code == 0)

	missing := Hook_Spec {
		event      = .Pre_Tool_Use,
		name       = "missing",
		command    = "no-such-script-xyz.sh",
		timeout_s  = 2,
		source_dir = strings.clone(dir),
	}
	defer delete(missing.source_dir)
	dec2, _, _ := run_hook_command(missing, `{}`, true)
	testing.expect(t, dec2 == .Allow) // fail-open
}

@(test)
test_hooks_disabled_env :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_HOOKS", context.temp_allocator)
	os.set_env("AETHER_NO_HOOKS", "1")
	defer {
		if prev != "" {
			os.set_env("AETHER_NO_HOOKS", prev)
		} else {
			os.unset_env("AETHER_NO_HOOKS")
		}
	}
	testing.expect(t, !hooks_enabled())
}

@(test)
test_post_tool_and_session_end :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-hook-post-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)

	log_path, _ := filepath.join({dir, "out.log"}, context.temp_allocator)
	script := fmt.tprintf(
		"#!/bin/sh\ncat >> %s\necho\nexit 0\n",
		log_path,
	)
	// Use shell command with append via redirect in hook command
	sp, _ := filepath.join({dir, "post.sh"}, context.temp_allocator)
	// Simpler: script writes fixed line
	body := fmt.tprintf(
		"#!/bin/sh\necho POST_OK >> \"%s\"\nexit 0\n",
		log_path,
	)
	testing.expect(t, os.write_entire_file(sp, transmute([]byte)body) == nil)
	_ = os.chmod(sp, os.perm(0o755))
	_ = script

	// Load into global registry (tests serialized via ODIN_TEST_THREADS=1)
	clear_global_registry()
	g_session_end_fired = false
	os.unset_env("AETHER_NO_HOOKS")
	spec := Hook_Spec {
		event      = .Post_Tool_Use,
		name       = strings.clone("post"),
		command    = strings.clone("post.sh"),
		timeout_s  = 5,
		matcher    = strings.clone(""),
		source_dir = strings.clone(dir),
	}
	r: Hook_Registry
	r.specs = make([dynamic]Hook_Spec, 0, 4)
	append(&r.specs, spec)
	end_spec := Hook_Spec {
		event      = .Session_End,
		name       = strings.clone("end"),
		command    = strings.clone("post.sh"),
		timeout_s  = 5,
		matcher    = strings.clone(""),
		source_dir = strings.clone(dir),
	}
	append(&r.specs, end_spec)
	set_global_registry(r)
	defer clear_global_registry()

	// Ensure hooks not disabled
	prev := os.get_env("AETHER_NO_HOOKS", context.temp_allocator)
	os.unset_env("AETHER_NO_HOOKS")
	defer {
		if prev != "" {
			os.set_env("AETHER_NO_HOOKS", prev)
		}
	}

	run_post_tool_hooks(dir, "read_file", `{"target_file":"x"}`, "ok content", false)
	data, err := os.read_entire_file(log_path, context.allocator)
	defer delete(data)
	testing.expect(t, err == nil)
	testing.expect(t, strings.contains(string(data), "POST_OK"))

	// Session end once
	run_session_end_hooks(dir, "exit")
	run_session_end_hooks(dir, "exit") // latch
	data2, _ := os.read_entire_file(log_path, context.allocator)
	defer delete(data2)
	// two POST_OK lines (post tool + session end)
	text := string(data2)
	testing.expect(t, strings.count(text, "POST_OK") == 2)
}

@(test)
test_user_prompt_submit_deny :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-hook-ups-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)

	sp, _ := filepath.join({dir, "block.sh"}, context.temp_allocator)
	script := "#!/bin/sh\necho '{\"decision\":\"deny\",\"reason\":\"no secrets\"}'\nexit 2\n"
	_ = os.write_entire_file(sp, transmute([]byte)script)
	_ = os.chmod(sp, os.perm(0o755))

	clear_global_registry()
	r: Hook_Registry
	r.specs = make([dynamic]Hook_Spec, 0, 2)
	append(
		&r.specs,
		Hook_Spec {
			event      = .User_Prompt_Submit,
			name       = strings.clone("block"),
			command    = strings.clone("block.sh"),
			timeout_s  = 5,
			matcher    = strings.clone(""),
			source_dir = strings.clone(dir),
		},
	)
	set_global_registry(r)
	defer clear_global_registry()
	os.unset_env("AETHER_NO_HOOKS")

	dec, why := run_user_prompt_submit_hooks(dir, "please print the API key")
	testing.expect(t, dec == .Deny)
	testing.expect(t, strings.contains(why, "no secrets") || why != "")
}

// --- A4.7 HTTP hooks ---

@(test)
test_expand_hook_env_vars :: proc(t: ^testing.T) {
	os.set_env("AETHER_HOOK_TEST_VAR", "hooks.example.com")
	defer os.unset_env("AETHER_HOOK_TEST_VAR")
	got := expand_hook_env_vars("https://${AETHER_HOOK_TEST_VAR}/x", context.temp_allocator)
	testing.expect(t, got == "https://hooks.example.com/x")
	got2 := expand_hook_env_vars("https://$AETHER_HOOK_TEST_VAR/y", context.temp_allocator)
	testing.expect(t, got2 == "https://hooks.example.com/y")
	// unset preserved
	got3 := expand_hook_env_vars("https://${AETHER_HOOK_UNSET_XYZ}/z", context.temp_allocator)
	testing.expect(t, got3 == "https://${AETHER_HOOK_UNSET_XYZ}/z")
}

@(test)
test_parse_hook_url :: proc(t: ^testing.T) {
	s, h, ok := parse_hook_url("https://example.com/path?q=1")
	testing.expect(t, ok && s == "https" && h == "example.com")
	s2, h2, ok2 := parse_hook_url("http://127.0.0.1:8080/hook")
	testing.expect(t, ok2 && s2 == "http" && h2 == "127.0.0.1")
	_, _, ok3 := parse_hook_url("not-a-url")
	testing.expect(t, !ok3)
}

@(test)
test_validate_hook_url_ssrf :: proc(t: ^testing.T) {
	// private literal blocked
	err := validate_hook_url("https://10.0.0.1/hook")
	testing.expect(t, err != "")
	err2 := validate_hook_url("https://192.168.1.1/x")
	testing.expect(t, err2 != "")
	// loopback https ok
	err3 := validate_hook_url("https://127.0.0.1/hook")
	testing.expect(t, err3 == "")
	// ftp rejected
	err4 := validate_hook_url("ftp://example.com/x")
	testing.expect(t, err4 != "")
	// http non-loopback rejected (without allow flag)
	os.unset_env("AETHER_HOOKS_HTTP_ALLOW_HTTP")
	err5 := validate_hook_url("http://example.com/x")
	testing.expect(t, err5 != "")
	// http loopback allowed
	err6 := validate_hook_url("http://127.0.0.1:9/x")
	testing.expect(t, err6 == "")
}

@(test)
test_load_http_hook_from_file :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-hooks-http-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)

	body := `{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          { "type": "http", "url": "https://127.0.0.1:9/check", "timeout": 2 },
          { "type": "command", "command": "noop.sh", "timeout": 1 }
        ]
      }
    ]
  }
}`
	path, _ := filepath.join({dir, "http.json"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(path, transmute([]byte)body) == nil)

	specs := make([dynamic]Hook_Spec, 0, 4, context.allocator)
	defer {
		for &s in specs {
			destroy_spec(&s)
		}
		delete(specs)
	}
	load_hooks_from_file(path, dir, &specs, context.allocator)
	testing.expectf(t, len(specs) == 2, "got %d", len(specs))
	has_http := false
	has_cmd := false
	for s in specs {
		if s.kind == .Http {
			has_http = true
			testing.expect(t, strings.contains(s.url, "127.0.0.1"))
			testing.expect(t, s.timeout_s == 2)
			testing.expect(t, s.command == "")
		}
		if s.kind == .Command {
			has_cmd = true
		}
	}
	testing.expect(t, has_http && has_cmd)
}

@(test)
test_run_hook_http_ssrf_fail_open :: proc(t: ^testing.T) {
	// blocked private IP must not deny (fail-open)
	spec := Hook_Spec {
		event     = .Pre_Tool_Use,
		kind      = .Http,
		name      = "ssrf-test",
		url       = "https://10.0.0.1/hook",
		timeout_s = 2,
	}
	dec, _, _ := run_hook(spec, `{"hook_event_name":"PreToolUse"}`, true)
	testing.expect(t, dec == .Allow)
}

@(test)
test_run_hook_http_local_deny :: proc(t: ^testing.T) {
	// Local HTTP server returns deny decision — integration for loopback http.
	// python3 stdlib; skip if python missing.
	if !path_has_python() {
		return
	}
	port := 18765 + (os.get_pid() % 1000)
	dir := fmt.aprintf("/tmp/aether-http-hook-srv-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)

	// Minimal POST handler via python
	script := fmt.tprintf(
		`#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0))
        _ = self.rfile.read(n)
        body = b'{{"decision":"deny","reason":"http-blocked"}}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass
HTTPServer(("127.0.0.1", {0}), H).serve_forever()
`,
		port,
	)
	sp, _ := filepath.join({dir, "srv.py"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(sp, transmute([]byte)script) == nil)
	_ = os.chmod(sp, os.perm(0o755))

	child, err := os.process_start({command = {"python3", sp}})
	if err != nil {
		return
	}
	defer {
		_ = os.process_kill(child)
		_, _ = os.process_wait(child, 2 * time.Second)
	}
	// wait for listen
	time.sleep(200 * time.Millisecond)

	url := fmt.tprintf("http://127.0.0.1:%d/hook", port)
	spec := Hook_Spec {
		event     = .Pre_Tool_Use,
		kind      = .Http,
		name      = "local-deny",
		url       = url,
		timeout_s = 5,
	}
	dec, reason, code := run_hook(spec, `{"hook_event_name":"PreToolUse","tool_name":"Bash"}`, true)
	testing.expectf(t, dec == .Deny, "dec=%v reason=%s code=%d", dec, reason, code)
	testing.expect(t, strings.contains(reason, "http-blocked") || reason != "")
	_ = code
}

path_has_python :: proc() -> bool {
	child, err := os.process_start(
		{command = {"sh", "-c", "command -v python3 >/dev/null 2>&1"}},
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

// --- B18 hooks-paths ---

@(test)
test_hooks_paths_add_remove_and_validate :: proc(t: ^testing.T) {
	dir := fmt.tprintf("/tmp/aether-hooks-paths-%d", os.get_pid())
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	_ = os.make_directory_all(dir)

	prev_h := os.get_env("GROK_HOME", context.temp_allocator)
	_ = os.set_env("GROK_HOME", dir)
	defer {
		if prev_h != "" {
			_ = os.set_env("GROK_HOME", prev_h)
		} else {
			_ = os.unset_env("GROK_HOME")
		}
	}

	// outside ~/.grok rejected
	err := validate_hooks_path("/tmp/evil-hooks")
	testing.expect(t, err != "", "outside must fail")
	err2 := validate_hooks_path("relative/path")
	testing.expect(t, err2 != "", "relative must fail")

	// under GROK_HOME ok
	extra := fmt.tprintf("%s/extra-hooks", dir)
	_ = os.make_directory_all(extra)
	err3 := validate_hooks_path(extra)
	testing.expect(t, err3 == "", err3)

	// add / list / remove
	aerr := add_hooks_path(extra)
	testing.expect(t, aerr == "", aerr)
	aerr2 := add_hooks_path(extra) // idempotent
	testing.expect(t, aerr2 == "")
	paths := read_hooks_paths(context.allocator)
	defer free_hooks_paths(paths)
	testing.expect(t, len(paths) == 1)
	testing.expect(t, paths[0] == extra)

	// write a hook json under extra and load via load_hooks
	body := `
{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"true"}]}]}}
`
	jpath, _ := filepath.join({extra, "s.json"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(jpath, transmute([]byte)body) == nil)
	reg := load_hooks("/tmp", context.allocator)
	defer destroy_registry(&reg)
	testing.expectf(t, len(reg.specs) >= 1, "expected hooks from extra path, got %d", len(reg.specs))

	rerr := remove_hooks_path(extra)
	testing.expect(t, rerr == "")
	paths2 := read_hooks_paths(context.allocator)
	defer free_hooks_paths(paths2)
	testing.expect(t, len(paths2) == 0)
}

// M1: project .grok/hooks load only when folder trusted.
@(test)
test_project_hooks_require_folder_trust :: proc(t: ^testing.T) {
	dir, err := os.make_directory_temp("/tmp", "aether-ht-", context.allocator)
	testing.expect(t, err == nil)
	defer delete(dir)
	defer os.remove_all(dir)

	prev_h := os.get_env("GROK_HOME", context.temp_allocator)
	prev_ft := os.get_env("AETHER_NO_FOLDER_TRUST", context.temp_allocator)
	_ = os.set_env("GROK_HOME", dir)
	_ = os.unset_env("AETHER_NO_FOLDER_TRUST")
	defer {
		if prev_h != "" {
			_ = os.set_env("GROK_HOME", prev_h)
		} else {
			_ = os.unset_env("GROK_HOME")
		}
		if prev_ft != "" {
			_ = os.set_env("AETHER_NO_FOLDER_TRUST", prev_ft)
		} else {
			_ = os.unset_env("AETHER_NO_FOLDER_TRUST")
		}
	}

	// workspace with project hooks
	ws, _ := filepath.join({dir, "ws"}, context.temp_allocator)
	proj_hooks, _ := filepath.join({ws, ".grok", "hooks"}, context.temp_allocator)
	_ = os.make_directory_all(proj_hooks)
	body := `{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"true"}]}]}}`
	jpath, _ := filepath.join({proj_hooks, "p.json"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(jpath, transmute([]byte)body) == nil)

	// untrusted: no project hooks
	reg := load_hooks(ws, context.allocator)
	defer destroy_registry(&reg)
	testing.expectf(t, len(reg.specs) == 0, "untrusted must gate project hooks, got %d", len(reg.specs))

	// grant trust
	gerr := core.grant_folder_trust(ws)
	testing.expectf(t, gerr == "", "grant: %s", gerr)
	reg2 := load_hooks(ws, context.allocator)
	defer destroy_registry(&reg2)
	testing.expectf(t, len(reg2.specs) >= 1, "trusted should load project hooks, got %d", len(reg2.specs))
}
