package agent

// web_search — product Full via Responses API hosted search.
// Auth: session (grok login) or XAI_API_KEY via resolve_credentials.
// N/A: alternate search backends.

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

WEB_SEARCH_TIMEOUT_S :: 60
WEB_SEARCH_MAX_CITES :: 12
WEB_SEARCH_MAX_OUT :: 40_000

// web_search_enabled: opt-out AETHER_NO_WEB_SEARCH=1
web_search_enabled :: proc() -> bool {
	if v := os.get_env("AETHER_NO_WEB_SEARCH", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") {
		return false
	}
	return true
}

// web_search_via_responses calls POST {base}/responses with a hosted web_search tool.
// Mirrors xai-grok-tools WebSearchClient::search (non-streaming).
web_search_via_responses :: proc(
	creds: Credentials,
	model: string,
	query: string,
	allowed_domains: []string,
	allocator := context.allocator,
) -> string {
	if !web_search_enabled() {
		return strings.clone("error: web_search disabled (AETHER_NO_WEB_SEARCH=1)", allocator)
	}
	if strings.trim_space(query) == "" {
		return strings.clone("error: query is required", allocator)
	}

	// Build request body
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"model":"`)
	strings.write_string(&b, json_escape(model, context.temp_allocator))
	strings.write_string(&b, `","input":"`)
	strings.write_string(&b, json_escape(query, context.temp_allocator))
	strings.write_string(&b, `","store":false,"temperature":0.1,"top_p":0.95,"max_output_tokens":8192,"tools":[`)
	if len(allowed_domains) > 0 {
		strings.write_string(&b, `{"type":"web_search","filters":{"allowed_domains":[`)
		for d, i in allowed_domains {
			if i > 0 {
				strings.write_byte(&b, ',')
			}
			strings.write_string(&b, `"`)
			strings.write_string(&b, json_escape(d, context.temp_allocator))
			strings.write_string(&b, `"`)
		}
		strings.write_string(&b, `]}}`)
	} else {
		strings.write_string(&b, `{"type":"web_search"}`)
	}
	strings.write_string(&b, `]}`)
	body := strings.to_string(b)

	url := fmt.tprintf("%s/responses", strings.trim_right(creds.base_url, "/"))
	headers := build_auth_headers(creds, context.temp_allocator)

	opts := Http_Opts {
		connect_timeout_s = 15,
		timeout_s         = WEB_SEARCH_TIMEOUT_S,
	}
	resp, herr := http_post_json(url, headers, body, context.allocator, opts)
	if herr != .None {
		return fmt.aprintf("error: web_search HTTP failed: %s", http_error_string(herr), allocator = allocator)
	}
	defer delete(resp.body)

	if resp.status == 401 {
		return strings.clone(
			"error: web_search unauthorized (401) — run `grok login` or set XAI_API_KEY",
			allocator,
		)
	}
	if resp.status < 200 || resp.status >= 300 {
		return fmt.aprintf(
			"error: web_search HTTP %d: %s",
			resp.status,
			truncate(resp.body, 400),
			allocator = allocator,
		)
	}

	text, cites := parse_responses_search_output(resp.body, context.temp_allocator)
	if text == "" {
		text = "No search results found."
	}
	out := strings.builder_make(allocator)
	strings.write_string(&out, text)
	if len(cites) > 0 {
		strings.write_string(&out, "\n\nCitations:\n")
		for c, i in cites {
			if i >= WEB_SEARCH_MAX_CITES {
				strings.write_string(&out, "…\n")
				break
			}
			strings.write_string(&out, fmt.tprintf("- %s\n", c))
		}
	}
	result := strings.to_string(out)
	if len(result) > WEB_SEARCH_MAX_OUT {
		return fmt.aprintf("%s\n...[truncated]", result[:WEB_SEARCH_MAX_OUT], allocator = allocator)
	}
	return result
}

// parse_responses_search_output extracts assistant text and url citations from a Responses JSON body.
parse_responses_search_output :: proc(
	body: string,
	allocator := context.allocator,
) -> (text: string, citations: []string) {
	val, err := json.parse(
		transmute([]byte)body,
		json.DEFAULT_SPECIFICATION,
		false,
		context.temp_allocator,
	)
	if err != nil {
		return fmt.aprintf("(parse error: %v)", err, allocator = allocator), nil
	}
	obj, ok := val.(json.Object)
	if !ok {
		return strings.clone("(invalid response object)", allocator), nil
	}

	// Prefer output_text if present (some APIs flatten it)
	if ot, has := json_str(obj, "output_text"); has && ot != "" {
		text = strings.clone(ot, allocator)
	}

	cites_dyn := make([dynamic]string, 0, 8, allocator)
	seen: map[string]bool
	seen.allocator = context.temp_allocator

	// Walk output array for message content + annotations
	if out_v, has_out := obj["output"]; has_out {
		if arr, is_arr := out_v.(json.Array); is_arr {
			tb := strings.builder_make(context.temp_allocator)
			for item in arr {
				item_obj, is_obj := item.(json.Object)
				if !is_obj {
					continue
				}
				// message type with content parts
				if content_v, has_c := item_obj["content"]; has_c {
					if parts, is_parts := content_v.(json.Array); is_parts {
						for part in parts {
							pobj, is_p := part.(json.Object)
							if !is_p {
								continue
							}
							if t, has_t := json_str(pobj, "text"); has_t && t != "" {
								if strings.builder_len(tb) > 0 {
									strings.write_byte(&tb, '\n')
								}
								strings.write_string(&tb, t)
							}
							// annotations: [{type, url, ...}]
							if ann_v, has_a := pobj["annotations"]; has_a {
								if anns, is_a := ann_v.(json.Array); is_a {
									for ann in anns {
										aobj, is_ao := ann.(json.Object)
										if !is_ao {
											continue
										}
										if u, has_u := json_str(aobj, "url"); has_u && u != "" {
											if !seen[u] {
												seen[u] = true
												append(&cites_dyn, strings.clone(u, allocator))
											}
										}
									}
								}
							}
						}
					}
				}
				// also collect any top-level url fields on web_search_call items
				if u, has_u := json_str(item_obj, "url"); has_u && u != "" {
					if !seen[u] {
						seen[u] = true
						append(&cites_dyn, strings.clone(u, allocator))
					}
				}
			}
			if text == "" {
				text = strings.clone(strings.to_string(tb), allocator)
			}
		}
	}

	if text == "" {
		// last resort: dump truncated body
		text = strings.clone(truncate(body, 500), allocator)
	}
	return text, cites_dyn[:]
}
