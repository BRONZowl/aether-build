// Shared JSON string-value escape for embedding in hand-built JSON.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:fmt"
import "core:strings"

// json_string_escape escapes a string for inclusion inside a JSON string value.
// Control bytes (< 0x20) become \u00xx; quotes/backslashes and \n\r\t are escaped.
json_string_escape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make_len_cap(0, len(s) + 8, allocator)
	for i in 0 ..< len(s) {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(&b, "\\\"")
		case '\\':
			strings.write_string(&b, "\\\\")
		case '\n':
			strings.write_string(&b, "\\n")
		case '\r':
			strings.write_string(&b, "\\r")
		case '\t':
			strings.write_string(&b, "\\t")
		case:
			if ch < 0x20 {
				strings.write_string(&b, fmt.tprintf("\\u%04x", ch))
			} else {
				strings.write_byte(&b, ch)
			}
		}
	}
	return strings.to_string(b)
}
