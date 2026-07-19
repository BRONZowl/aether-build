package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_path_is_executable_and_look_path_bin :: proc(t: ^testing.T) {
	testing.expect(t, !path_is_executable(""))
	testing.expect(t, !path_is_executable("/no/such/file/xyz"))
	// /bin/sh usually exists on Linux
	if os.exists("/bin/sh") {
		testing.expect(t, path_is_executable("/bin/sh"))
	}
}

@(test)
test_find_grok_cli_env_override :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-grok-bin-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)

	fake, _ := filepath.join({dir, "fake-grok"}, context.temp_allocator)
	// shebang script
	body := "#!/bin/sh\nexit 0\n"
	testing.expect(t, os.write_entire_file(fake, transmute([]byte)body) == nil)
	_ = os.chmod(fake, os.perm(0o755))

	prev_a := os.get_env("AETHER_GROK_BIN", context.temp_allocator)
	prev_g := os.get_env("GROK_BIN", context.temp_allocator)
	os.unset_env("GROK_BIN")
	os.set_env("AETHER_GROK_BIN", fake)
	defer {
		if prev_a != "" {
			os.set_env("AETHER_GROK_BIN", prev_a)
		} else {
			os.unset_env("AETHER_GROK_BIN")
		}
		if prev_g != "" {
			os.set_env("GROK_BIN", prev_g)
		} else {
			os.unset_env("GROK_BIN")
		}
	}

	p, err := find_grok_cli(context.allocator)
	defer delete(p)
	testing.expect(t, err == "", err)
	testing.expect(t, p == fake, p)
}

@(test)
test_find_grok_cli_bad_env :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_GROK_BIN", context.temp_allocator)
	os.set_env("AETHER_GROK_BIN", "/definitely/not/a/real/grok-bin-xyz")
	defer {
		if prev != "" {
			os.set_env("AETHER_GROK_BIN", prev)
		} else {
			os.unset_env("AETHER_GROK_BIN")
		}
	}
	p, err := find_grok_cli(context.allocator)
	testing.expect(t, p == "")
	testing.expect(t, err != "")
	testing.expect(t, strings.contains(err, "not an executable"))
}

@(test)
test_host_login_missing_message :: proc(t: ^testing.T) {
	m := host_login_missing_message()
	testing.expect(t, strings.contains(m, "AETHER_GROK_BIN"))
	testing.expect(t, strings.contains(m, "XAI_API_KEY"))
}

@(test)
test_run_host_login_with_fake_binary :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-login-run-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)

	// script that accepts "login" and exits 0
	fake, _ := filepath.join({dir, "grok"}, context.temp_allocator)
	body := "#!/bin/sh\n# $1 should be login\nif [ \"$1\" = \"login\" ]; then exit 0; fi\nexit 2\n"
	testing.expect(t, os.write_entire_file(fake, transmute([]byte)body) == nil)
	_ = os.chmod(fake, os.perm(0o755))

	prev := os.get_env("AETHER_GROK_BIN", context.temp_allocator)
	os.set_env("AETHER_GROK_BIN", fake)
	defer {
		if prev != "" {
			os.set_env("AETHER_GROK_BIN", prev)
		} else {
			os.unset_env("AETHER_GROK_BIN")
		}
	}

	// Force host bridge (default is in-process device login).
	code := run_host_login([]string{"--host"}, true /* quiet */)
	testing.expect(t, code == 0, fmt.tprintf("exit %d", code))
}

@(test)
test_run_host_mcp_doctor_and_list :: proc(t: ^testing.T) {
	dir := fmt.aprintf("/tmp/aether-mcp-host-%d", os.get_pid())
	defer delete(dir)
	_ = os.remove_all(dir)
	defer os.remove_all(dir)
	testing.expect(t, os.make_directory_all(dir) == nil)

	// Accept mcp doctor / mcp list — path must outlive set_env (no temp_allocator)
	fake := fmt.aprintf("%s/grok", dir)
	body :=
		"#!/bin/sh\n" +
		"if [ \"$1\" = \"mcp\" ] && [ \"$2\" = \"doctor\" ]; then exit 0; fi\n" +
		"if [ \"$1\" = \"mcp\" ] && [ \"$2\" = \"list\" ]; then exit 0; fi\n" +
		"exit 3\n"
	testing.expect(t, os.write_entire_file(fake, transmute([]byte)body) == nil)
	_ = os.chmod(fake, os.perm(0o755))
	testing.expect(t, path_is_executable(fake))

	prev := os.get_env("AETHER_GROK_BIN", context.temp_allocator)
	// clone for set_env in case env holds a pointer
	fake_env := strings.clone(fake)
	os.set_env("AETHER_GROK_BIN", fake_env)
	defer {
		delete(fake_env)
		delete(fake)
		if prev != "" {
			os.set_env("AETHER_GROK_BIN", prev)
		} else {
			os.unset_env("AETHER_GROK_BIN")
		}
	}

	testing.expect(t, run_host_mcp_doctor("", true) == 0)
	testing.expect(t, run_host_mcp_list(true) == 0)
	// wrong subcommand still fails through fake
	testing.expect(t, run_host_grok([]string{"mcp", "nope"}, true) == 3)
}
