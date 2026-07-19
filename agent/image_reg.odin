package agent

// image_reg — Grok AttachedImages-shaped [Image #N] registry for media tools.
// Reference: crates/.../resources.rs AttachedImages + image_edit token resolve.
// Process-local; cleared on /new. Auto-registers image_gen / image_edit saves.

import "base:runtime"
import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"

g_image_reg_mu:   sync.Mutex
g_image_reg:      map[int]string // display N → owned path or data URL
g_image_reg_next: int            // next number to assign (1-based)

image_reg_ensure :: proc() {
	if g_image_reg_next < 1 {
		g_image_reg_next = 1
	}
	if g_image_reg.allocator.procedure == nil {
		g_image_reg = make(map[int]string, runtime.heap_allocator())
	}
}

// image_reg_clear empties the registry (/new).
image_reg_clear :: proc() {
	sync.mutex_lock(&g_image_reg_mu)
	defer sync.mutex_unlock(&g_image_reg_mu)
	image_reg_ensure()
	for _, v in g_image_reg {
		delete(v)
	}
	clear(&g_image_reg)
	g_image_reg_next = 1
}

// image_reg_register stores ref and returns display number ≥ 1.
image_reg_register :: proc(ref: string) -> int {
	r := strings.trim_space(ref)
	if r == "" {
		return 0
	}
	sync.mutex_lock(&g_image_reg_mu)
	defer sync.mutex_unlock(&g_image_reg_mu)
	image_reg_ensure()
	n := g_image_reg_next
	g_image_reg_next += 1
	g_image_reg[n] = strings.clone(r, runtime.heap_allocator())
	return n
}

// parse_image_token: [Image #N] | Image #N | image #N | #N → 1-based N.
parse_image_token :: proc(value: string) -> (n: int, ok: bool) {
	trimmed := strings.trim_space(value)
	if trimmed == "" {
		return 0, false
	}
	// Reject paths / data URLs early
	if strings.has_prefix(trimmed, "/") ||
	   strings.has_prefix(trimmed, "data:") ||
	   strings.has_prefix(trimmed, "file:") ||
	   strings.has_prefix(trimmed, "./") ||
	   strings.has_prefix(trimmed, "../") {
		return 0, false
	}
	inner := trimmed
	if strings.has_prefix(inner, "[") && strings.has_suffix(inner, "]") {
		inner = strings.trim_space(inner[1:len(inner) - 1])
	}
	// optional "image" label (ASCII)
	if len(inner) >= 5 {
		head := strings.to_lower(inner[:5], context.temp_allocator)
		if head == "image" {
			inner = strings.trim_space(inner[5:])
		}
	}
	if !strings.has_prefix(inner, "#") {
		return 0, false
	}
	digits := strings.trim_space(inner[1:])
	if digits == "" {
		return 0, false
	}
	// only digits
	for i in 0 ..< len(digits) {
		ch := digits[i]
		if ch < '0' || ch > '9' {
			return 0, false
		}
	}
	parsed, pok := strconv.parse_int(digits)
	if !pok || parsed < 1 {
		return 0, false
	}
	return parsed, true
}

// image_reg_lookup returns owned clone of ref for display number, or "".
image_reg_lookup :: proc(n: int, allocator := context.allocator) -> (string, bool) {
	if n < 1 {
		return "", false
	}
	sync.mutex_lock(&g_image_reg_mu)
	defer sync.mutex_unlock(&g_image_reg_mu)
	image_reg_ensure()
	ref, has := g_image_reg[n]
	if !has || ref == "" {
		return "", false
	}
	return strings.clone(ref, allocator), true
}

// image_reg_resolve_token: if value is an attachment token, return registry ref.
// ok=false means "not a token" (caller should treat as path/data URL).
// err non-empty means it was a token but resolution failed.
image_reg_resolve_token :: proc(
	value: string,
	allocator := context.allocator,
) -> (
	ref: string,
	is_token: bool,
	err: string,
) {
	n, tok := parse_image_token(value)
	if !tok {
		return "", false, ""
	}
	sync.mutex_lock(&g_image_reg_mu)
	defer sync.mutex_unlock(&g_image_reg_mu)
	image_reg_ensure()
	if len(g_image_reg) == 0 {
		return "", true, fmt.tprintf(
			"image reference %q matches no registered image. If it was generated earlier, re-run image_gen or pass an absolute path / data URL.",
			strings.trim_space(value),
		)
	}
	r, has := g_image_reg[n]
	if !has || r == "" {
		// list available
		b := strings.builder_make(context.temp_allocator)
		first := true
		for k in g_image_reg {
			if !first {
				strings.write_string(&b, ", ")
			}
			first = false
			fmt.sbprintf(&b, "[Image #%d]", k)
		}
		return "", true, fmt.tprintf(
			"image reference %q does not match any registered image. Available: %s.",
			strings.trim_space(value),
			strings.to_string(b),
		)
	}
	return strings.clone(r, allocator), true, ""
}

// image_reg_label formats Image #N for tool results.
image_reg_label :: proc(n: int, allocator := context.allocator) -> string {
	if n < 1 {
		return strings.clone("", allocator)
	}
	return fmt.aprintf("[Image #%d]", n, allocator = allocator)
}
