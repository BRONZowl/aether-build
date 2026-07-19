package mcp

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_qualify_and_parse :: proc(t: ^testing.T) {
	q := qualify_tool_name("chrome-devtools", "list_pages", context.temp_allocator)
	testing.expect(t, q == "chrome-devtools__list_pages", q)
	s, tool, ok := parse_qualified(q)
	testing.expect(t, ok)
	testing.expect(t, s == "chrome-devtools", s)
	testing.expect(t, tool == "list_pages", tool)
	_, _, ok2 := parse_qualified("nounderscore")
	testing.expect(t, !ok2)
}

@(test)
test_sanitize_name :: proc(t: ^testing.T) {
	s := sanitize_name("my server!", context.temp_allocator)
	testing.expect(t, s == "my_server_", s)
}

@(test)
test_parse_mcp_config_block :: proc(t: ^testing.T) {
	path := "/tmp/aether-mcp-cfg-test.toml"
	body :=
		"[models]\ndefault = \"x\"\n\n" +
		"[mcp_servers.demo]\n" +
		"command = \"npx\"\n" +
		"args = [\"-y\", \"foo\"]\n" +
		"enabled = true\n" +
		"startup_timeout_sec = 45\n\n" +
		"[mcp_servers.remote]\n" +
		"url = \"https://example.com/mcp\"\n" +
		"headers = { \"Authorization\" = \"Bearer tok\" }\n" +
		"enabled = true\n"
	_ = os.write_entire_file(path, transmute([]byte)body)
	defer os.remove(path)

	out := make([dynamic]Mcp_Server_Config, 0, 4, context.allocator)
	append_configs_from_file(&out, path, context.allocator)
	defer destroy_server_configs(out[:])

	testing.expectf(t, len(out) == 2, "got %d", len(out))
	if len(out) >= 1 {
		testing.expect(t, out[0].name == "demo", out[0].name)
		testing.expect(t, out[0].command == "npx", out[0].command)
		testing.expect(t, len(out[0].args) == 2)
		testing.expect(t, out[0].startup_timeout_sec == 45)
	}
	if len(out) >= 2 {
		testing.expect(t, out[1].name == "remote")
		testing.expect(t, out[1].url != "")
		testing.expectf(t, len(out[1].headers) >= 1, "headers")
		if len(out[1].headers) >= 1 {
			testing.expect(t, out[1].headers[0][0] == "Authorization")
			testing.expect(t, out[1].headers[0][1] == "Bearer tok")
		}
	}
}

@(test)
test_parse_sse_rpc_result :: proc(t: ^testing.T) {
	// event with matching id=2
	body := "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"x\":1}}\n\n" +
		"data: {\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"tools\":[]}}\n\n"
	res, err := parse_sse_rpc_result(body, 2, context.temp_allocator)
	testing.expectf(t, err == "", "err=%s", err)
	testing.expect(t, strings.contains(res, "tools"), res)
}

@(test)
test_extract_rpc_result_match :: proc(t: ^testing.T) {
	msg := `{"jsonrpc":"2.0","id":7,"result":{"ok":true}}`
	res, err, skip := extract_rpc_result(msg, 7, context.temp_allocator)
	testing.expect(t, !skip)
	testing.expect(t, err == "")
	testing.expect(t, strings.contains(res, "ok"), res)
	_, _, skip2 := extract_rpc_result(msg, 8, context.temp_allocator)
	testing.expect(t, skip2)
}

@(test)
test_parse_resources_and_prompts_list :: proc(t: ^testing.T) {
	srv := Mcp_Server {
		name      = strings.clone("demo", context.allocator),
		resources = make([dynamic]Mcp_Resource, 0, 4, context.allocator),
		prompts   = make([dynamic]Mcp_Prompt, 0, 4, context.allocator),
	}
	defer {
		destroy_server_catalog(&srv)
		delete(srv.name)
	}
	res_json := `{"resources":[{"uri":"file:///a","name":"A","description":"alpha","mimeType":"text/plain"},{"uri":"memo://b","name":"B"}]}`
	err := parse_resources_list(&srv, res_json, context.allocator)
	testing.expect(t, err == "")
	testing.expect(t, len(srv.resources) == 2)
	testing.expect(t, srv.resources[0].uri == "file:///a")
	testing.expect(t, srv.resources[0].mime_type == "text/plain")

	pr_json := `{"prompts":[{"name":"greet","description":"hi","arguments":[{"name":"who"}]}]}`
	err2 := parse_prompts_list(&srv, pr_json, context.allocator)
	testing.expect(t, err2 == "")
	testing.expect(t, len(srv.prompts) == 1)
	testing.expect(t, srv.prompts[0].name == "greet")
	testing.expect(t, strings.contains(srv.prompts[0].arguments_json, "who"))
}

@(test)
test_format_resource_read_result_text :: proc(t: ^testing.T) {
	raw := `{"contents":[{"uri":"u","mimeType":"text/plain","text":"hello world"}]}`
	out := format_resource_read_result(raw, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "hello world"))
	testing.expect(t, strings.contains(out, "uri: u"))
}

@(test)
test_list_mcp_resources_filter :: proc(t: ^testing.T) {
	reg := Mcp_Registry {
		resources = make([dynamic]Mcp_Resource, 0, 2, context.allocator),
	}
	defer {
		for &r in reg.resources {
			destroy_resource(&r)
		}
		delete(reg.resources)
	}
	append(
		&reg.resources,
		Mcp_Resource {
			server      = strings.clone("s1", context.allocator),
			uri         = strings.clone("file:///docs/a.md", context.allocator),
			name        = strings.clone("a", context.allocator),
			description = strings.clone("alpha doc", context.allocator),
			mime_type   = strings.clone("text/markdown", context.allocator),
		},
	)
	append(
		&reg.resources,
		Mcp_Resource {
			server      = strings.clone("s1", context.allocator),
			uri         = strings.clone("file:///other", context.allocator),
			name        = strings.clone("o", context.allocator),
			description = strings.clone("zzz", context.allocator),
			mime_type   = strings.clone("", context.allocator),
		},
	)
	out := list_mcp_resources(&reg, `{"query":"alpha"}`, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "file:///docs/a.md"))
	testing.expect(t, !strings.contains(out, "file:///other"))
}

@(test)
test_mcp_schema_includes_resource_tools :: proc(t: ^testing.T) {
	schema := meta_tools_json_schema()
	testing.expect(t, strings.contains(schema, "list_mcp_resources"))
	testing.expect(t, strings.contains(schema, "read_mcp_resource"))
	testing.expect(t, strings.contains(schema, "list_mcp_prompts"))
	testing.expect(t, strings.contains(schema, "get_mcp_prompt"))
}
