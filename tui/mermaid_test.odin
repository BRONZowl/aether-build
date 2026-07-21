// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_parse_flowchart_simple :: proc(t: ^testing.T) {
	g, ok := parse_flowchart("flowchart TD\n  A[Start] --> B[End]", context.allocator)
	testing.expect(t, ok)
	defer free_mermaid_graph(&g)
	testing.expect(t, len(g.nodes) == 2)
	testing.expect(t, len(g.edges) == 1)
	testing.expect(t, g.nodes[0].label == "Start" || g.nodes[1].label == "Start")
	testing.expect(t, g.dir == .Down)
}

@(test)
test_parse_flowchart_lr :: proc(t: ^testing.T) {
	g, ok := parse_flowchart("graph LR\nA-->B-->C", context.allocator)
	testing.expect(t, ok)
	defer free_mermaid_graph(&g)
	testing.expect(t, g.dir == .Right)
	testing.expect(t, len(g.nodes) == 3)
	testing.expect(t, len(g.edges) == 2)
}

@(test)
test_layout_flowchart_has_boxes :: proc(t: ^testing.T) {
	g, ok := parse_flowchart("flowchart TD\n  A[Start] --> B[Finish]", context.allocator)
	testing.expect(t, ok)
	defer free_mermaid_graph(&g)
	lines, lok := layout_flowchart(&g, 80, context.allocator)
	testing.expect(t, lok)
	defer {
		for ln in lines {
			delete(ln)
		}
		delete(lines)
	}
	joined := strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "Start"))
	testing.expect(t, strings.contains(joined, "Finish"))
	testing.expect(
		t,
		strings.contains(joined, "┌") ||
		strings.contains(joined, "╭") ||
		strings.contains(joined, "─"),
	)
}

@(test)
test_parse_sequence :: proc(t: ^testing.T) {
	seq, ok := parse_sequence(
		"sequenceDiagram\n  Alice->>Bob: Hello\n  Bob-->>Alice: Hi",
		context.allocator,
	)
	testing.expect(t, ok)
	defer free_mermaid_sequence(&seq)
	testing.expect(t, len(seq.labels) == 2)
	testing.expect(t, len(seq.msgs) == 2)
}

@(test)
test_layout_sequence_has_participants :: proc(t: ^testing.T) {
	seq, ok := parse_sequence(
		"sequenceDiagram\n  Alice->>Bob: Hello",
		context.allocator,
	)
	testing.expect(t, ok)
	defer free_mermaid_sequence(&seq)
	lines, lok := layout_sequence(&seq, 80, context.allocator)
	testing.expect(t, lok)
	defer {
		for ln in lines {
			delete(ln)
		}
		delete(lines)
	}
	joined := strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "Alice"))
	testing.expect(t, strings.contains(joined, "Bob"))
	testing.expect(t, strings.contains(joined, "Hello"))
}

@(test)
test_mermaid_fallback_frame :: proc(t: ^testing.T) {
	lines := mermaid_fallback_frame("pie title Pets\n  \"Dogs\" : 386", 60, context.allocator)
	defer {
		for ln in lines {
			delete(ln)
		}
		delete(lines)
	}
	testing.expect(t, len(lines) >= 3)
	joined := strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "mermaid:"))
	testing.expect(t, strings.contains(joined, "╭") || strings.contains(joined, "│"))
	testing.expect(t, strings.contains(joined, "pie"))
}

@(test)
test_try_render_mermaid_flowchart :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_MERMAID", context.temp_allocator)
	prev2 := os.get_env("AETHER_RENDER_MERMAID", context.temp_allocator)
	_ = os.unset_env("AETHER_NO_MERMAID")
	_ = os.unset_env("AETHER_RENDER_MERMAID")
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_NO_MERMAID", prev)
		}
		if prev2 != "" {
			_ = os.set_env("AETHER_RENDER_MERMAID", prev2)
		}
	}
	lines, ok := try_render_mermaid("flowchart LR\n  A-->B", 80, context.allocator)
	testing.expect(t, ok)
	defer {
		for ln in lines {
			delete(ln)
		}
		delete(lines)
	}
	testing.expect(t, len(lines) >= 2)
	joined := strings.join(lines[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "mermaid"))
}

@(test)
test_try_render_mermaid_disabled :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_MERMAID", context.temp_allocator)
	_ = os.set_env("AETHER_NO_MERMAID", "1")
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_NO_MERMAID", prev)
		} else {
			_ = os.unset_env("AETHER_NO_MERMAID")
		}
	}
	_, ok := try_render_mermaid("flowchart TD\nA-->B", 80, context.allocator)
	testing.expect(t, !ok)
}

@(test)
test_push_assistant_renders_mermaid_art :: proc(t: ^testing.T) {
	prev := os.get_env("AETHER_NO_MERMAID", context.temp_allocator)
	_ = os.unset_env("AETHER_NO_MERMAID")
	_ = os.unset_env("AETHER_RENDER_MERMAID")
	defer {
		if prev != "" {
			_ = os.set_env("AETHER_NO_MERMAID", prev)
		}
	}
	out := make([dynamic]string, 0, 16, context.temp_allocator)
	styles := make([dynamic]Line_Style, 0, 16, context.temp_allocator)
	idxs := make([dynamic]int, 0, 16, context.temp_allocator)
	text := "See:\n```mermaid\nflowchart TD\n  A[Start] --> B[End]\n```\nDone."
	push_assistant(&out, &styles, &idxs, 0, text, 80, context.temp_allocator)
	joined := strings.join(out[:], "\n", context.temp_allocator)
	testing.expect(t, strings.contains(joined, "Start"))
	testing.expect(t, strings.contains(joined, "End"))
	// layout art or framed — not bare --- mermaid --- only with raw source
	testing.expect(
		t,
		strings.contains(joined, "┌") ||
		strings.contains(joined, "╭") ||
		strings.contains(joined, "◇ mermaid"),
	)
	testing.expect(t, strings.contains(joined, "See:") || strings.contains(joined, "Done"))
}
