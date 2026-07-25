// Shared JSON string-value escape for embedding in hand-built JSON.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:fmt"
import "core:strings"

// utf8_safe_prefix returns the longest prefix of s with length <= max_bytes that
// does not split a multi-byte UTF-8 sequence. Byte-truncation mid-sequence breaks
// API JSON ("failed to parse as JSON") and corrupts session files.
utf8_safe_prefix :: proc(s: string, max_bytes: int) -> string {
	if max_bytes <= 0 {
		return ""
	}
	end := max_bytes
	if end > len(s) {
		end = len(s)
	}
	// Shrink while s[:end] ends with an incomplete multi-byte character.
	for end > 0 {
		j := end - 1
		for j > 0 && (s[j] & 0xc0) == 0x80 {
			j -= 1
		}
		need := utf8_seq_len(s[j])
		if j + need <= end {
			break
		}
		end = j
	}
	return s[:end]
}

// utf8_seq_len: expected byte length of UTF-8 sequence starting at lead, or 1 for ASCII/invalid.
utf8_seq_len :: proc(lead: u8) -> int {
	if lead < 0x80 {
		return 1
	}
	if lead & 0xe0 == 0xc0 {
		return 2
	}
	if lead & 0xf0 == 0xe0 {
		return 3
	}
	if lead & 0xf8 == 0xf0 {
		return 4
	}
	return 1 // invalid lead — treat as single byte
}

// utf8_decode_valid returns codepoint and byte length if s[i:] starts a valid
// non-overlong, non-surrogate UTF-8 sequence; otherwise ok=false.
utf8_decode_valid :: proc(s: string, i: int) -> (cp: int, n: int, ok: bool) {
	if i >= len(s) {
		return 0, 0, false
	}
	lead := s[i]
	if lead < 0x80 {
		return int(lead), 1, true
	}
	need := utf8_seq_len(lead)
	if need <= 1 || i + need > len(s) {
		return 0, 1, false
	}
	for k in 1 ..< need {
		if (s[i + k] & 0xc0) != 0x80 {
			return 0, 1, false
		}
	}
	// Decode codepoint
	switch need {
	case 2:
		cp = int(lead & 0x1f) << 6 | int(s[i + 1] & 0x3f)
		if cp < 0x80 {
			return 0, 1, false // overlong
		}
	case 3:
		cp = int(lead & 0x0f) << 12 | int(s[i + 1] & 0x3f) << 6 | int(s[i + 2] & 0x3f)
		if cp < 0x800 {
			return 0, 1, false // overlong
		}
		if cp >= 0xd800 && cp <= 0xdfff {
			return 0, 1, false // UTF-16 surrogates illegal in UTF-8
		}
	case 4:
		cp = int(lead & 0x07) << 18 |
			int(s[i + 1] & 0x3f) << 12 |
			int(s[i + 2] & 0x3f) << 6 |
			int(s[i + 3] & 0x3f)
		if cp < 0x10000 || cp > 0x10ffff {
			return 0, 1, false // overlong or out of range
		}
	case:
		return 0, 1, false
	}
	return cp, need, true
}

// json_string_escape escapes a string for inclusion inside a JSON string value.
// Control bytes (< 0x20) become \u00xx except NUL → \ufffd (chat APIs reject U+0000
// in message content even when JSON-escaped). Quotes/backslashes and \n\r\t are
// escaped. Invalid / overlong UTF-8 is replaced with U+FFFD so the request stays
// valid JSON and passes model API validators (e.g. messages[N].content: invalid).
json_string_escape :: proc(s: string, allocator := context.allocator) -> string {
	b := strings.builder_make_len_cap(0, len(s) + 8, allocator)
	i := 0
	for i < len(s) {
		ch := s[i]
		switch ch {
		case '"':
			strings.write_string(&b, "\\\"")
			i += 1
		case '\\':
			strings.write_string(&b, "\\\\")
			i += 1
		case '\n':
			strings.write_string(&b, "\\n")
			i += 1
		case '\r':
			strings.write_string(&b, "\\r")
			i += 1
		case '\t':
			strings.write_string(&b, "\\t")
			i += 1
		case 0:
			// APIs (OpenAI/xAI chat) reject null codepoints in message content.
			strings.write_string(&b, "\\ufffd")
			i += 1
		case:
			if ch < 0x20 || ch == 0x7f {
				strings.write_string(&b, fmt.tprintf("\\u%04x", ch))
				i += 1
			} else if ch < 0x80 {
				strings.write_byte(&b, ch)
				i += 1
			} else {
				_, need, ok := utf8_decode_valid(s, i)
				if !ok {
					strings.write_string(&b, "\\ufffd")
					i += 1
					continue
				}
				strings.write_string(&b, s[i:i + need])
				i += need
			}
		}
	}
	return strings.to_string(b)
}
