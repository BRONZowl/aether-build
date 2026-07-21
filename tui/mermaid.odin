// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

#+build linux, darwin, freebsd, openbsd, netbsd
// Package tui — Mermaid Unicode box-drawing layout (M8).
// Supports flowchart/graph (TD/TB/LR/BT) and sequenceDiagram.
// Unsupported types fall back to a framed source box (Grok-shaped).
// PNG/SVG engine residual N/A (no raster pipeline in standalone Aether).
package tui

import "core:fmt"
import "core:os"
import "core:strings"
import "core:unicode/utf8"
import "aether:core"

MERMAID_MAX_NODES :: 64
MERMAID_MAX_EDGES :: 128
MERMAID_MAX_PARTICIPANTS :: 16
MERMAID_MAX_MSGS :: 64
MERMAID_WRAP :: 22
MERMAID_MAX_LABEL_LINES :: 3
MERMAID_GAP_X :: 3
MERMAID_GAP_Y :: 2
MERMAID_MAX_CANVAS_W :: 200
MERMAID_MAX_CANVAS_H :: 120

Mermaid_Dir :: enum {
	Down,
	Up,
	Right,
	Left,
}

Mermaid_Shape :: enum {
	Rect,
	Round,
	Diamond,
}

// mermaid_render_enabled: auto/on unless AETHER_NO_MERMAID or AETHER_RENDER_MERMAID=off.
mermaid_render_enabled :: proc() -> bool {
	if core.feature_killed("AETHER_NO_MERMAID") {
		return false
	}
	v := strings.to_lower(
		strings.trim_space(os.get_env("AETHER_RENDER_MERMAID", context.temp_allocator)),
		context.temp_allocator,
	)
	switch v {
	case "0", "off", "false", "no", "source", "raw":
		return false
	case "", "1", "on", "true", "yes", "auto", "layout", "art":
		return true
	}
	return true
}

// try_render_mermaid: plain-line art for a fence body, or nil if disabled/blank.
// Caller owns returned lines (allocator). ok=false → caller shows raw fence.
try_render_mermaid :: proc(
	src: string,
	max_width: int,
	allocator := context.allocator,
) -> (
	lines: [dynamic]string,
	ok: bool,
) {
	if !mermaid_render_enabled() {
		return {}, false
	}
	body := strings.trim_space(src)
	if body == "" {
		return {}, false
	}
	// Strip BOM-ish leading noise
	if strings.has_prefix(body, "\ufeff") {
		body = body[3:]
	}
	mw := max_width
	if mw <= 0 {
		mw = 80
	}
	if g, gok := parse_flowchart(body, context.temp_allocator); gok {
		art, aok := layout_flowchart(&g, mw, allocator)
		if aok {
			return art, true
		}
		// fall through to framed source
	} else if seq, sok := parse_sequence(body, context.temp_allocator); sok {
		art, aok := layout_sequence(&seq, mw, allocator)
		if aok {
			return art, true
		}
	}
	// Framed fallback always succeeds for non-empty mermaid fences
	return mermaid_fallback_frame(body, mw, allocator), true
}

// --- flowchart parse ---

Mermaid_Node :: struct {
	id:    string,
	label: string,
	shape: Mermaid_Shape,
}

Mermaid_Edge :: struct {
	from:  int,
	to:    int,
	label: string,
}

Mermaid_Graph :: struct {
	nodes: [dynamic]Mermaid_Node,
	edges: [dynamic]Mermaid_Edge,
	dir:   Mermaid_Dir,
}

free_mermaid_graph :: proc(g: ^Mermaid_Graph) {
	for n in g.nodes {
		delete(n.id)
		delete(n.label)
	}
	delete(g.nodes)
	for e in g.edges {
		delete(e.label)
	}
	delete(g.edges)
}

parse_flowchart :: proc(src: string, allocator := context.allocator) -> (Mermaid_Graph, bool) {
	g: Mermaid_Graph
	g.nodes = make([dynamic]Mermaid_Node, 0, 16, allocator)
	g.edges = make([dynamic]Mermaid_Edge, 0, 16, allocator)
	g.dir = .Down

	stmts := split_mermaid_statements(src, context.temp_allocator)
	if len(stmts) == 0 {
		return {}, false
	}
	// header
	htoks := split_ws(stmts[0], context.temp_allocator)
	if len(htoks) == 0 {
		return {}, false
	}
	kind := strings.to_lower(htoks[0], context.temp_allocator)
	if kind != "graph" && kind != "flowchart" {
		return {}, false
	}
	dir_s := "TD"
	if len(htoks) >= 2 {
		dir_s = strings.to_upper(htoks[1], context.temp_allocator)
	}
	switch dir_s {
	case "LR":
		g.dir = .Right
	case "RL":
		g.dir = .Left
	case "BT":
		g.dir = .Up
	case:
		g.dir = .Down // TD/TB/default
	}

	for i in 1 ..< len(stmts) {
		st := stmts[i]
		first := first_word(st)
		fl := strings.to_lower(first, context.temp_allocator)
		switch fl {
		case "subgraph", "end", "classdef", "class", "style", "linkstyle", "click", "direction":
			continue
		}
		parse_flow_statement(st, &g, allocator)
		if len(g.nodes) >= MERMAID_MAX_NODES || len(g.edges) >= MERMAID_MAX_EDGES {
			break
		}
	}
	if len(g.nodes) == 0 {
		free_mermaid_graph(&g)
		return {}, false
	}
	return g, true
}

parse_flow_statement :: proc(st: string, g: ^Mermaid_Graph, allocator := context.allocator) {
	// Chain: A[Label] --> B --> C{X}
	// Walk tokens loosely
	rest := strings.trim_space(st)
	if rest == "" {
		return
	}
	prev := -1
	for rest != "" {
		rest = strings.trim_left_space(rest)
		if rest == "" {
			break
		}
		// edge op first if we already have a node
		if prev >= 0 {
			elabel: string
			op_len := 0
			if strings.has_prefix(rest, "-->") {
				op_len = 3
			} else if strings.has_prefix(rest, "---") {
				op_len = 3
			} else if strings.has_prefix(rest, "-.->") {
				op_len = 4
			} else if strings.has_prefix(rest, "==>") {
				op_len = 3
			} else if strings.has_prefix(rest, "->") {
				op_len = 2
			} else if strings.has_prefix(rest, "--") {
				// -- text --> form
				// find -->
				if p := strings.index(rest, "-->"); p > 0 {
					mid := strings.trim_space(rest[2:p])
					// strip |label|
					if strings.has_prefix(mid, "|") && strings.has_suffix(mid, "|") && len(mid) >= 2 {
						elabel = mid[1:len(mid) - 1]
					} else if mid != "" {
						elabel = mid
					}
					op_len = p + 3
				}
			}
			if op_len == 0 {
				// try |label| between arrows: -->|yes|
				if strings.has_prefix(rest, "-->|") {
					end := strings.index_byte(rest[4:], '|')
					if end >= 0 {
						elabel = rest[4:4 + end]
						op_len = 4 + end + 1
					}
				}
			}
			if op_len == 0 {
				break
			}
			rest = rest[op_len:]
			rest = strings.trim_left_space(rest)
			nid, nlabel, nshape, nadv, nok := parse_node_token(rest)
			if !nok {
				break
			}
			to_i := ensure_node(g, nid, nlabel, nshape, allocator)
			if prev >= 0 && to_i >= 0 && len(g.edges) < MERMAID_MAX_EDGES {
				append(
					&g.edges,
					Mermaid_Edge {
						from = prev,
						to = to_i,
						label = strings.clone(elabel, allocator),
					},
				)
			}
			prev = to_i
			rest = rest[nadv:]
			continue
		}
		// first node
		nid, nlabel, nshape, nadv, nok := parse_node_token(rest)
		if !nok {
			break
		}
		prev = ensure_node(g, nid, nlabel, nshape, allocator)
		rest = rest[nadv:]
	}
}

parse_node_token :: proc(
	s: string,
) -> (
	id: string,
	label: string,
	shape: Mermaid_Shape,
	adv: int,
	ok: bool,
) {
	s2 := strings.trim_left_space(s)
	if s2 == "" {
		return "", "", .Rect, 0, false
	}
	// id = alnum/_
	i := 0
	for i < len(s2) {
		c := s2[i]
		if (c >= 'a' && c <= 'z') ||
		   (c >= 'A' && c <= 'Z') ||
		   (c >= '0' && c <= '9') ||
		   c == '_' {
			i += 1
		} else {
			break
		}
	}
	if i == 0 {
		return "", "", .Rect, 0, false
	}
	id = s2[:i]
	label = id
	shape = .Rect
	adv = i + (len(s) - len(s2)) // account for leading space consumed via s2? better recompute
	// recompute adv from original s
	lead := 0
	for lead < len(s) && (s[lead] == ' ' || s[lead] == '\t') {
		lead += 1
	}
	adv = lead + i
	rest := s[adv:]
	if rest == "" {
		return id, label, shape, adv, true
	}
	// shape delimiters
	closer: string
	open_len := 0
	switch rest[0] {
	case '[':
		if len(rest) > 1 && rest[1] == '[' {
			closer = "]]"
			open_len = 2
			shape = .Rect
		} else if len(rest) > 1 && rest[1] == '(' {
			closer = ")]"
			open_len = 2
			shape = .Round
		} else {
			closer = "]"
			open_len = 1
			shape = .Rect
		}
	case '(':
		if len(rest) > 1 && rest[1] == '(' {
			closer = "))"
			open_len = 2
			shape = .Round
		} else {
			closer = ")"
			open_len = 1
			shape = .Round
		}
	case '{':
		closer = "}"
		open_len = 1
		shape = .Diamond
	case:
		return id, label, shape, adv, true
	}
	body_start := open_len
	end := strings.index(rest[body_start:], closer)
	if end < 0 {
		return id, label, shape, adv, true
	}
	raw := rest[body_start:body_start + end]
	raw = strings.trim_space(raw)
	// strip quotes
	if len(raw) >= 2 && raw[0] == '"' && raw[len(raw) - 1] == '"' {
		raw = raw[1:len(raw) - 1]
	}
	if raw != "" {
		label = raw
	}
	adv += body_start + end + len(closer)
	return id, label, shape, adv, true
}

ensure_node :: proc(
	g: ^Mermaid_Graph,
	id: string,
	label: string,
	shape: Mermaid_Shape,
	allocator := context.allocator,
) -> int {
	for n, i in g.nodes {
		if n.id == id {
			if label != "" && label != id {
				delete(g.nodes[i].label)
				g.nodes[i].label = strings.clone(label, allocator)
				g.nodes[i].shape = shape
			}
			return i
		}
	}
	if len(g.nodes) >= MERMAID_MAX_NODES {
		return -1
	}
	lab := label
	if lab == "" {
		lab = id
	}
	append(
		&g.nodes,
		Mermaid_Node {
			id = strings.clone(id, allocator),
			label = strings.clone(lab, allocator),
			shape = shape,
		},
	)
	return len(g.nodes) - 1
}

// --- sequence parse ---

Mermaid_Seq_Msg :: struct {
	from:  int,
	to:    int,
	text:  string,
	async: bool, // -->> dashed
}

Mermaid_Sequence :: struct {
	labels: [dynamic]string, // participant display names
	ids:    [dynamic]string, // participant ids
	msgs:   [dynamic]Mermaid_Seq_Msg,
}

free_mermaid_sequence :: proc(s: ^Mermaid_Sequence) {
	for l in s.labels {
		delete(l)
	}
	delete(s.labels)
	for id in s.ids {
		delete(id)
	}
	delete(s.ids)
	for m in s.msgs {
		delete(m.text)
	}
	delete(s.msgs)
}

parse_sequence :: proc(src: string, allocator := context.allocator) -> (Mermaid_Sequence, bool) {
	seq: Mermaid_Sequence
	seq.labels = make([dynamic]string, 0, 8, allocator)
	seq.ids = make([dynamic]string, 0, 8, allocator)
	seq.msgs = make([dynamic]Mermaid_Seq_Msg, 0, 16, allocator)

	lines := strings.split_lines(src, context.temp_allocator)
	started := false
	for raw in lines {
		line := strings.trim_space(raw)
		if line == "" || strings.has_prefix(line, "%%") {
			continue
		}
		// strip trailing comments
		if p := strings.index(line, "%%"); p >= 0 {
			line = strings.trim_space(line[:p])
		}
		low := strings.to_lower(line, context.temp_allocator)
		if !started {
			if strings.has_prefix(low, "sequencediagram") {
				started = true
				continue
			}
			return {}, false
		}
		// participant Alice as A / participant Alice
		if strings.has_prefix(low, "participant ") || strings.has_prefix(low, "actor ") {
			rest := line
			if strings.has_prefix(low, "participant ") {
				rest = strings.trim_space(line[len("participant "):])
			} else {
				rest = strings.trim_space(line[len("actor "):])
			}
			id, lab := parse_participant_decl(rest)
			_ = ensure_participant(&seq, id, lab, allocator)
			continue
		}
		// skip notes / activate for MVP
		if strings.has_prefix(low, "note ") ||
		   strings.has_prefix(low, "activate ") ||
		   strings.has_prefix(low, "deactivate ") ||
		   strings.has_prefix(low, "loop ") ||
		   strings.has_prefix(low, "alt ") ||
		   strings.has_prefix(low, "else") ||
		   strings.has_prefix(low, "end") ||
		   strings.has_prefix(low, "opt ") ||
		   strings.has_prefix(low, "par ") ||
		   strings.has_prefix(low, "and ") ||
		   strings.has_prefix(low, "rect ") ||
		   strings.has_prefix(low, "autonumber") {
			continue
		}
		// Message: A->>B: text  / A-->>B: text / A->B: text
		if msg_ok := try_parse_seq_message(line, &seq, allocator); msg_ok {
			continue
		}
	}
	if !started || (len(seq.labels) == 0 && len(seq.msgs) == 0) {
		free_mermaid_sequence(&seq)
		return {}, false
	}
	// ensure at least participants from messages
	if len(seq.labels) == 0 {
		free_mermaid_sequence(&seq)
		return {}, false
	}
	return seq, true
}

parse_participant_decl :: proc(rest: string) -> (id: string, label: string) {
	// "Name as Id" or just Name
	if p := strings.index(rest, " as "); p >= 0 {
		lab := strings.trim_space(rest[:p])
		id = strings.trim_space(rest[p + 4:])
		if lab == "" {
			lab = id
		}
		if id == "" {
			id = lab
		}
		// strip quotes
		lab = strip_quotes(lab)
		id = strip_quotes(id)
		return id, lab
	}
	name := strip_quotes(strings.trim_space(rest))
	return name, name
}

strip_quotes :: proc(s: string) -> string {
	if len(s) >= 2 && s[0] == '"' && s[len(s) - 1] == '"' {
		return s[1:len(s) - 1]
	}
	return s
}

ensure_participant :: proc(
	seq: ^Mermaid_Sequence,
	id: string,
	label: string,
	allocator := context.allocator,
) -> int {
	for existing, i in seq.ids {
		if existing == id {
			return i
		}
	}
	if len(seq.ids) >= MERMAID_MAX_PARTICIPANTS {
		return -1
	}
	append(&seq.ids, strings.clone(id, allocator))
	lab := label
	if lab == "" {
		lab = id
	}
	append(&seq.labels, strings.clone(lab, allocator))
	return len(seq.ids) - 1
}

try_parse_seq_message :: proc(
	line: string,
	seq: ^Mermaid_Sequence,
	allocator := context.allocator,
) -> bool {
	// Find arrow operators
	ops := [?]string{"-->>", "->>", "-->", "->", "-x", "--x"}
	op_at := -1
	op_len := 0
	op_async := false
	for op in ops {
		if p := strings.index(line, op); p >= 0 {
			if op_at < 0 || p < op_at {
				op_at = p
				op_len = len(op)
				op_async = op == "-->>" || op == "-->"
			}
		}
	}
	if op_at <= 0 {
		return false
	}
	from_s := strings.trim_space(line[:op_at])
	rest := line[op_at + op_len:]
	// optional + for activation: +Bob
	rest = strings.trim_left_space(rest)
	if rest != "" && (rest[0] == '+' || rest[0] == '-') {
		rest = rest[1:]
	}
	to_s: string
	text: string
	if colon := strings.index_byte(rest, ':'); colon >= 0 {
		to_s = strings.trim_space(rest[:colon])
		text = strings.trim_space(rest[colon + 1:])
	} else {
		to_s = strings.trim_space(rest)
	}
	if from_s == "" || to_s == "" {
		return false
	}
	// strip trailing +/- 
	// strip trailing activation markers
	for len(to_s) > 0 {
		c := to_s[len(to_s) - 1]
		if c == '+' || c == '-' {
			to_s = to_s[:len(to_s) - 1]
		} else {
			break
		}
	}
	fi := ensure_participant(seq, from_s, from_s, allocator)
	ti := ensure_participant(seq, to_s, to_s, allocator)
	if fi < 0 || ti < 0 {
		return false
	}
	if len(seq.msgs) >= MERMAID_MAX_MSGS {
		return true
	}
	append(
		&seq.msgs,
		Mermaid_Seq_Msg {
			from = fi,
			to = ti,
			text = strings.clone(text, allocator),
			async = op_async,
		},
	)
	return true
}

// --- layout flowchart ---

layout_flowchart :: proc(
	g: ^Mermaid_Graph,
	max_width: int,
	allocator := context.allocator,
) -> (
	[dynamic]string,
	bool,
) {
	n := len(g.nodes)
	if n == 0 {
		return {}, false
	}
	// ranks: longest-path style from roots (no incoming); cycles stay near min
	ranks := make([]int, n, context.temp_allocator)
	indeg := make([]int, n, context.temp_allocator)
	for e in g.edges {
		if e.from != e.to && e.to >= 0 && e.to < n {
			indeg[e.to] += 1
		}
	}
	adj := make([][dynamic]int, n, context.temp_allocator)
	for i in 0 ..< n {
		adj[i] = make([dynamic]int, 0, 4, context.temp_allocator)
	}
	for e in g.edges {
		if e.from != e.to && e.from >= 0 && e.from < n && e.to >= 0 && e.to < n {
			append(&adj[e.from], e.to)
		}
	}
	queue := make([dynamic]int, 0, n, context.temp_allocator)
	for i in 0 ..< n {
		ranks[i] = 0
		if indeg[i] == 0 {
			append(&queue, i)
		}
	}
	if len(queue) == 0 {
		append(&queue, 0)
	}
	// Kahn-like with rank = max(pred)+1
	remaining := make([]int, n, context.temp_allocator)
	copy(remaining, indeg)
	seen_n := 0
	qi := 0
	for qi < len(queue) {
		u := queue[qi]
		qi += 1
		seen_n += 1
		for v in adj[u] {
			if ranks[u] + 1 > ranks[v] {
				ranks[v] = ranks[u] + 1
			}
			remaining[v] -= 1
			if remaining[v] == 0 {
				append(&queue, v)
			}
		}
	}
	// nodes still in cycle / unreached: leave rank 0 or keep best seen
	_ = seen_n

	max_rank := 0
	for r in ranks {
		if r > max_rank {
			max_rank = r
		}
	}
	by_rank := make([][dynamic]int, max_rank + 1, context.temp_allocator)
	for i in 0 ..= max_rank {
		by_rank[i] = make([dynamic]int, 0, 4, context.temp_allocator)
	}
	for i in 0 ..< n {
		r := ranks[i]
		if r < 0 {
			r = 0
		}
		if r > max_rank {
			r = max_rank
		}
		append(&by_rank[r], i)
	}

	// wrap labels
	wrapped := make([][]string, n, context.temp_allocator)
	box_w := make([]int, n, context.temp_allocator)
	box_h := make([]int, n, context.temp_allocator)
	for i in 0 ..< n {
		wrapped[i] = wrap_label_lines(g.nodes[i].label, MERMAID_WRAP, MERMAID_MAX_LABEL_LINES, context.temp_allocator)
		w := 1
		for ln in wrapped[i] {
			w = max(w, display_width(ln))
		}
		box_w[i] = w + 4 // pad + borders
		box_h[i] = len(wrapped[i]) + 2
	}

	vertical := g.dir == .Down || g.dir == .Up
	// positions
	px := make([]int, n, context.temp_allocator)
	py := make([]int, n, context.temp_allocator)
	canvas_w := 0
	canvas_h := 0

	if vertical {
		y := 0
		for r in 0 ..= max_rank {
			row := by_rank[r][:]
			// row width
			row_w := 0
			for j, idx in row {
				if j > 0 {
					row_w += MERMAID_GAP_X
				}
				row_w += box_w[idx]
			}
			x := 0
			for idx in row {
				px[idx] = x
				py[idx] = y
				x += box_w[idx] + MERMAID_GAP_X
			}
			canvas_w = max(canvas_w, row_w)
			max_h := 1
			for idx in row {
				max_h = max(max_h, box_h[idx])
			}
			// normalize box heights for connectors from center
			y += max_h + MERMAID_GAP_Y
			canvas_h = y
		}
		// center each rank row in canvas
		for r in 0 ..= max_rank {
			row := by_rank[r][:]
			row_w := 0
			for j, idx in row {
				if j > 0 {
					row_w += MERMAID_GAP_X
				}
				row_w += box_w[idx]
			}
			off := max(0, (canvas_w - row_w) / 2)
			x := off
			for idx in row {
				px[idx] = x
				x += box_w[idx] + MERMAID_GAP_X
			}
		}
		canvas_h = max(1, canvas_h - MERMAID_GAP_Y)
	} else {
		// LR: ranks as columns
		x := 0
		for r in 0 ..= max_rank {
			col := by_rank[r][:]
			max_w := 1
			for idx in col {
				max_w = max(max_w, box_w[idx])
			}
			y := 0
			for idx in col {
				px[idx] = x
				py[idx] = y
				y += box_h[idx] + MERMAID_GAP_Y
			}
			canvas_h = max(canvas_h, y - MERMAID_GAP_Y)
			x += max_w + MERMAID_GAP_X
			canvas_w = x
		}
		canvas_w = max(1, canvas_w - MERMAID_GAP_X)
		// center columns vertically
		for r in 0 ..= max_rank {
			col := by_rank[r][:]
			col_h := 0
			for j, idx in col {
				if j > 0 {
					col_h += MERMAID_GAP_Y
				}
				col_h += box_h[idx]
			}
			off := max(0, (canvas_h - col_h) / 2)
			y := off
			for idx in col {
				py[idx] = y
				y += box_h[idx] + MERMAID_GAP_Y
			}
		}
	}

	if canvas_w > MERMAID_MAX_CANVAS_W || canvas_h > MERMAID_MAX_CANVAS_H {
		return {}, false
	}
	if max_width > 0 && canvas_w > max_width {
		return {}, false
	}

	// canvas as [][]u8 runes stored as strings lines
	grid := make([][]rune, canvas_h, context.temp_allocator)
	for y in 0 ..< canvas_h {
		grid[y] = make([]rune, canvas_w, context.temp_allocator)
		for x in 0 ..< canvas_w {
			grid[y][x] = ' '
		}
	}

	// draw boxes
	for i in 0 ..< n {
		draw_box_on_grid(grid, canvas_w, canvas_h, px[i], py[i], box_w[i], box_h[i], wrapped[i], g.nodes[i].shape)
	}
	// draw edges (simple)
	for e in g.edges {
		if e.from < 0 || e.to < 0 || e.from >= n || e.to >= n {
			continue
		}
		if e.from == e.to {
			continue // skip self-loops in MVP
		}
		fx := px[e.from] + box_w[e.from] / 2
		fy := py[e.from] + box_h[e.from] / 2
		tx := px[e.to] + box_w[e.to] / 2
		ty := py[e.to] + box_h[e.to] / 2
		if vertical {
			// exit bottom of from, enter top of to (for Down)
			sy := py[e.from] + box_h[e.from] - 1
			ey := py[e.to]
			sx := fx
			ex := tx
			if g.dir == .Up {
				sy = py[e.from]
				ey = py[e.to] + box_h[e.to] - 1
			}
			// vertical then horizontal then vertical
			mid_y := (sy + ey) / 2
			if ranks[e.to] == ranks[e.from] + 1 || ranks[e.from] == ranks[e.to] + 1 {
				// adjacent ranks: straight-ish
				draw_v_line(grid, canvas_w, canvas_h, sx, sy, mid_y)
				draw_h_line(grid, canvas_w, canvas_h, sx, ex, mid_y)
				draw_v_line(grid, canvas_w, canvas_h, ex, mid_y, ey)
			} else {
				draw_v_line(grid, canvas_w, canvas_h, sx, sy, mid_y)
				draw_h_line(grid, canvas_w, canvas_h, sx, ex, mid_y)
				draw_v_line(grid, canvas_w, canvas_h, ex, mid_y, ey)
			}
			// arrow head near target
			put_rune(grid, canvas_w, canvas_h, ex, ey, '▼' if g.dir != .Up else '▲')
		} else {
			sx := px[e.from] + box_w[e.from] - 1
			ex := px[e.to]
			sy := fy
			ey := ty
			if g.dir == .Left {
				sx = px[e.from]
				ex = px[e.to] + box_w[e.to] - 1
			}
			mid_x := (sx + ex) / 2
			draw_h_line(grid, canvas_w, canvas_h, sx, mid_x, sy)
			draw_v_line(grid, canvas_w, canvas_h, mid_x, sy, ey)
			draw_h_line(grid, canvas_w, canvas_h, mid_x, ex, ey)
			put_rune(grid, canvas_w, canvas_h, ex, ey, '▶' if g.dir != .Left else '◀')
		}
		// edge label near midpoint
		if e.label != "" {
			lab := e.label
			if display_width(lab) > 12 {
				lab = truncate_display(lab, 12, context.temp_allocator)
			}
			mx := (fx + tx) / 2
			my := (fy + ty) / 2
			put_str(grid, canvas_w, canvas_h, mx, my, lab)
		}
	}

	// flip for BT/RL: reverse rows or cols so direction matches
	if g.dir == .Up {
		// reverse row order
		for y := 0; y < canvas_h / 2; y += 1 {
			grid[y], grid[canvas_h - 1 - y] = grid[canvas_h - 1 - y], grid[y]
		}
	}
	if g.dir == .Left {
		for y in 0 ..< canvas_h {
			for x := 0; x < canvas_w / 2; x += 1 {
				grid[y][x], grid[y][canvas_w - 1 - x] = grid[y][canvas_w - 1 - x], grid[y][x]
			}
		}
	}

	out := make([dynamic]string, 0, canvas_h + 2, allocator)
	// header chip
	append(&out, strings.clone("◇ mermaid · flowchart", allocator))
	for y in 0 ..< canvas_h {
		// trim trailing spaces
		line := runes_to_trimmed_string(grid[y], allocator)
		append(&out, line)
	}
	return out, true
}

// --- layout sequence ---

layout_sequence :: proc(
	seq: ^Mermaid_Sequence,
	max_width: int,
	allocator := context.allocator,
) -> (
	[dynamic]string,
	bool,
) {
	n := len(seq.labels)
	if n == 0 {
		return {}, false
	}
	// box widths
	bw := make([]int, n, context.temp_allocator)
	labels := make([]string, n, context.temp_allocator)
	for i in 0 ..< n {
		labels[i] = truncate_display(seq.labels[i], MERMAID_WRAP, context.temp_allocator)
		bw[i] = display_width(labels[i]) + 4
	}
	// gaps between centers
	gaps := make([]int, max(0, n - 1), context.temp_allocator)
	for i in 0 ..< n - 1 {
		gaps[i] = max(6, bw[i] / 2 + bw[i + 1] / 2 + 2)
	}
	// expand gaps for message text
	for m in seq.msgs {
		if m.from == m.to {
			continue
		}
		l := min(m.from, m.to)
		r := max(m.from, m.to)
		need := max(4, display_width(m.text) + 2)
		cur := 0
		for i in l ..< r {
			cur += gaps[i]
		}
		if cur < need && r - 1 < len(gaps) {
			gaps[r - 1] += need - cur
		}
	}
	// center xs
	xs := make([]int, n, context.temp_allocator)
	xs[0] = bw[0] / 2
	for i in 1 ..< n {
		xs[i] = xs[i - 1] + gaps[i - 1]
	}
	canvas_w := xs[n - 1] + bw[n - 1] / 2 + 1
	// rows: header boxes + messages + footer boxes
	msg_rows := len(seq.msgs)
	// each msg ~ 2 lines (text + arrow)
	body_h := msg_rows * 2 + 1
	box_h := 3
	canvas_h := box_h + body_h + box_h
	if canvas_w > MERMAID_MAX_CANVAS_W || canvas_h > MERMAID_MAX_CANVAS_H {
		return {}, false
	}
	if max_width > 0 && canvas_w > max_width {
		return {}, false
	}

	grid := make([][]rune, canvas_h, context.temp_allocator)
	for y in 0 ..< canvas_h {
		grid[y] = make([]rune, canvas_w, context.temp_allocator)
		for x in 0 ..< canvas_w {
			grid[y][x] = ' '
		}
	}

	// participant boxes top and bottom
	for i in 0 ..< n {
		bx := max(0, xs[i] - bw[i] / 2)
		draw_box_on_grid(grid, canvas_w, canvas_h, bx, 0, bw[i], box_h, []string{labels[i]}, .Rect)
		draw_box_on_grid(
			grid,
			canvas_w,
			canvas_h,
			bx,
			canvas_h - box_h,
			bw[i],
			box_h,
			[]string{labels[i]},
			.Rect,
		)
		// lifeline
		for y in box_h ..< canvas_h - box_h {
			if grid[y][xs[i]] == ' ' {
				grid[y][xs[i]] = '│'
			}
		}
	}

	// messages
	y := box_h + 1
	for m in seq.msgs {
		if m.from < 0 || m.to < 0 || m.from >= n || m.to >= n {
			y += 2
			continue
		}
		x0 := xs[m.from]
		x1 := xs[m.to]
		if m.text != "" {
			// center text between
			tx := (x0 + x1) / 2
			tw := display_width(m.text)
			put_str(grid, canvas_w, canvas_h, max(0, tx - tw / 2), y, m.text)
		}
		ay := y + 1
		if m.from == m.to {
			// self message
			put_str(grid, canvas_w, canvas_h, x0 + 1, ay, "──╮")
			put_str(grid, canvas_w, canvas_h, x0 + 1, ay + 1, "◀─┘")
			y += 3
			continue
		}
		// horizontal arrow
		left := min(x0, x1)
		right := max(x0, x1)
		ch: rune = '─'
		if m.async {
			ch = '┄'
		}
		for x := left + 1; x < right; x += 1 {
			if grid[ay][x] == ' ' || grid[ay][x] == '│' {
				grid[ay][x] = ch
			}
		}
		if x1 > x0 {
			put_rune(grid, canvas_w, canvas_h, right, ay, '▶')
		} else {
			put_rune(grid, canvas_w, canvas_h, left, ay, '◀')
		}
		y += 2
	}

	out := make([dynamic]string, 0, canvas_h + 2, allocator)
	append(&out, strings.clone("◇ mermaid · sequence", allocator))
	for row in 0 ..< canvas_h {
		append(&out, runes_to_trimmed_string(grid[row], allocator))
	}
	return out, true
}

// --- fallback frame ---

mermaid_fallback_frame :: proc(
	src: string,
	max_width: int,
	allocator := context.allocator,
) -> [dynamic]string {
	header_kind := first_word(src)
	if header_kind == "" {
		header_kind = "diagram"
	}
	title := fmt.tprintf(" mermaid: %s ", strings.to_lower(header_kind, context.temp_allocator))
	inner_limit := max(8, max_width - 4)
	if max_width <= 0 {
		inner_limit = 76
	}

	body_lines := make([dynamic]string, 0, 16, context.temp_allocator)
	for raw in strings.split_lines(src, context.temp_allocator) {
		line := strings.trim_right_space(raw)
		if line == "" && len(body_lines) == 0 {
			continue
		}
		// chunk long lines (rune-safe)
		for len(line) > 0 {
			if display_width(line) <= inner_limit {
				append(&body_lines, line)
				break
			}
			w := 0
			end := 0
			for end < len(line) {
				_, sz := utf8.decode_rune(line[end:])
				if sz <= 0 {
					break
				}
				if w + 1 > inner_limit {
					break
				}
				w += 1
				end += sz
			}
			if end == 0 {
				end = min(1, len(line))
			}
			append(&body_lines, line[:end])
			line = line[end:]
		}
	}
	content_w := display_width(title)
	for ln in body_lines {
		content_w = max(content_w, display_width(ln))
	}
	inner := content_w + 2

	out := make([dynamic]string, 0, len(body_lines) + 3, allocator)
	// top
	{
		b := strings.builder_make(allocator)
		strings.write_string(&b, "╭")
		strings.write_string(&b, title)
		pad := max(0, inner - display_width(title))
		for i := 0; i < pad; i += 1 {
			strings.write_string(&b, "─")
		}
		strings.write_string(&b, "╮")
		append(&out, strings.to_string(b))
	}
	for ln in body_lines {
		pad := max(0, content_w - display_width(ln))
		b := strings.builder_make(allocator)
		strings.write_string(&b, "│ ")
		strings.write_string(&b, ln)
		for i := 0; i < pad; i += 1 {
			strings.write_byte(&b, ' ')
		}
		strings.write_string(&b, " │")
		append(&out, strings.to_string(b))
	}
	{
		b := strings.builder_make(allocator)
		strings.write_string(&b, "╰")
		for i := 0; i < inner; i += 1 {
			strings.write_string(&b, "─")
		}
		strings.write_string(&b, "╯")
		append(&out, strings.to_string(b))
	}
	return out
}

// --- canvas helpers ---

draw_box_on_grid :: proc(
	grid: [][]rune,
	cw, ch: int,
	x, y, w, h: int,
	lines: []string,
	shape: Mermaid_Shape,
) {
	if w < 3 || h < 2 {
		return
	}
	tl: rune = '┌'
	tr: rune = '┐'
	bl: rune = '└'
	br: rune = '┘'
	if shape == .Round || shape == .Diamond {
		// Round and diamond share rounded corners in terminal art
		tl, tr, bl, br = '╭', '╮', '╰', '╯'
	}
	// corners + edges
	put_rune(grid, cw, ch, x, y, tl)
	put_rune(grid, cw, ch, x + w - 1, y, tr)
	put_rune(grid, cw, ch, x, y + h - 1, bl)
	put_rune(grid, cw, ch, x + w - 1, y + h - 1, br)
	for i := 1; i < w - 1; i += 1 {
		put_rune(grid, cw, ch, x + i, y, '─')
		put_rune(grid, cw, ch, x + i, y + h - 1, '─')
	}
	for j := 1; j < h - 1; j += 1 {
		put_rune(grid, cw, ch, x, y + j, '│')
		put_rune(grid, cw, ch, x + w - 1, y + j, '│')
	}
	// clear interior then text
	for j := 1; j < h - 1; j += 1 {
		for i := 1; i < w - 1; i += 1 {
			put_rune(grid, cw, ch, x + i, y + j, ' ')
		}
	}
	for ln, li in lines {
		if 1 + li >= h - 1 {
			break
		}
		put_str(grid, cw, ch, x + 2, y + 1 + li, ln)
	}
}

put_rune :: proc(grid: [][]rune, cw, ch, x, y: int, r: rune) {
	if y < 0 || y >= ch || x < 0 || x >= cw {
		return
	}
	// don't overwrite box borders with space
	if r == ' ' && grid[y][x] != ' ' {
		return
	}
	grid[y][x] = r
}

put_str :: proc(grid: [][]rune, cw, ch, x, y: int, s: string) {
	if y < 0 || y >= ch {
		return
	}
	cx := x
	i := 0
	for i < len(s) {
		r, sz := utf8.decode_rune(s[i:])
		if sz <= 0 {
			break
		}
		put_rune(grid, cw, ch, cx, y, r)
		cx += 1
		i += sz
	}
}

draw_h_line :: proc(grid: [][]rune, cw, ch, x0, x1, y: int) {
	a := min(x0, x1)
	b := max(x0, x1)
	for x := a; x <= b; x += 1 {
		if y < 0 || y >= ch || x < 0 || x >= cw {
			continue
		}
		cur := grid[y][x]
		if cur == '│' || cur == '┼' {
			grid[y][x] = '┼'
		} else if cur == ' ' || cur == '─' || cur == '┄' {
			grid[y][x] = '─'
		}
	}
}

draw_v_line :: proc(grid: [][]rune, cw, ch, x, y0, y1: int) {
	a := min(y0, y1)
	b := max(y0, y1)
	for y := a; y <= b; y += 1 {
		if y < 0 || y >= ch || x < 0 || x >= cw {
			continue
		}
		cur := grid[y][x]
		if cur == '─' || cur == '┼' {
			grid[y][x] = '┼'
		} else if cur == ' ' || cur == '│' {
			grid[y][x] = '│'
		}
	}
}

runes_to_trimmed_string :: proc(row: []rune, allocator := context.allocator) -> string {
	end := len(row)
	for end > 0 && row[end - 1] == ' ' {
		end -= 1
	}
	b := strings.builder_make(allocator)
	for i in 0 ..< end {
		strings.write_rune(&b, row[i])
	}
	return strings.to_string(b)
}

// --- string utils ---

display_width :: proc(s: string) -> int {
	n := 0
	for _ in s {
		n += 1
	}
	return n
}

truncate_display :: proc(s: string, max_w: int, allocator := context.allocator) -> string {
	if display_width(s) <= max_w {
		return s
	}
	if max_w <= 1 {
		return "…"
	}
	b := strings.builder_make(allocator)
	n := 0
	for r in s {
		if n >= max_w - 1 {
			break
		}
		strings.write_rune(&b, r)
		n += 1
	}
	strings.write_string(&b, "…")
	return strings.to_string(b)
}

wrap_label_lines :: proc(
	label: string,
	width: int,
	max_lines: int,
	allocator := context.allocator,
) -> []string {
	if label == "" {
		out := make([]string, 1, allocator)
		out[0] = ""
		return out
	}
	if display_width(label) <= width {
		out := make([]string, 1, allocator)
		out[0] = label
		return out
	}
	// simple word wrap
	words := strings.fields(label, context.temp_allocator)
	lines := make([dynamic]string, 0, max_lines, allocator)
	cur := strings.builder_make(context.temp_allocator)
	for w in words {
		cw := display_width(strings.to_string(cur))
		ww := display_width(w)
		if cw > 0 && cw + 1 + ww > width {
			if len(lines) + 1 >= max_lines {
				// ellipsis last
				s := strings.to_string(cur)
				append(&lines, truncate_display(s, width, allocator))
				return lines[:]
			}
			append(&lines, strings.clone(strings.to_string(cur), allocator))
			strings.builder_reset(&cur)
		}
		if strings.builder_len(cur) > 0 {
			strings.write_byte(&cur, ' ')
		}
		// hard-split long word
		if ww > width {
			rest := w
			for display_width(rest) > width {
				take := truncate_display(rest, width, context.temp_allocator)
				// remove ellipsis for intermediate
				if strings.has_suffix(take, "…") && len(take) > 1 {
					// approximate
					take = take[:len(take) - len("…")]
				}
				if strings.builder_len(cur) > 0 {
					append(&lines, strings.clone(strings.to_string(cur), allocator))
					strings.builder_reset(&cur)
				}
				if len(lines) >= max_lines - 1 {
					append(&lines, truncate_display(rest, width, allocator))
					return lines[:]
				}
				append(&lines, strings.clone(take, allocator))
				// advance rest by rune count of take
				adv := 0
				cnt := 0
				mw := display_width(take)
				for adv < len(rest) && cnt < mw {
					_, sz := utf8.decode_rune(rest[adv:])
					adv += max(1, sz)
					cnt += 1
				}
				rest = rest[adv:]
			}
			strings.write_string(&cur, rest)
		} else {
			strings.write_string(&cur, w)
		}
	}
	if strings.builder_len(cur) > 0 {
		if len(lines) >= max_lines {
			// replace last
			if len(lines) > 0 {
				lines[len(lines) - 1] = truncate_display(
					fmt.tprintf("%s %s", lines[len(lines) - 1], strings.to_string(cur)),
					width,
					allocator,
				)
			}
		} else {
			append(&lines, strings.clone(strings.to_string(cur), allocator))
		}
	}
	if len(lines) == 0 {
		append(&lines, strings.clone(truncate_display(label, width, context.temp_allocator), allocator))
	}
	return lines[:]
}

split_mermaid_statements :: proc(src: string, allocator := context.allocator) -> []string {
	out := make([dynamic]string, 0, 16, allocator)
	for raw in strings.split_lines(src, context.temp_allocator) {
		line := raw
		// strip // style? mermaid uses %%
		if p := strings.index(line, "%%"); p >= 0 {
			line = line[:p]
		}
		// split on ;
		cur := strings.builder_make(context.temp_allocator)
		in_q := false
		for i := 0; i < len(line); i += 1 {
			c := line[i]
			if c == '"' {
				in_q = !in_q
				strings.write_byte(&cur, c)
				continue
			}
			if !in_q && c == ';' {
				t := strings.trim_space(strings.to_string(cur))
				if t != "" {
					append(&out, strings.clone(t, allocator))
				}
				strings.builder_reset(&cur)
				continue
			}
			strings.write_byte(&cur, c)
		}
		t := strings.trim_space(strings.to_string(cur))
		if t != "" {
			append(&out, strings.clone(t, allocator))
		}
	}
	return out[:]
}

split_ws :: proc(s: string, allocator := context.allocator) -> []string {
	return strings.fields(s, allocator)
}

first_word :: proc(s: string) -> string {
	s2 := strings.trim_space(s)
	if s2 == "" {
		return ""
	}
	for i in 0 ..< len(s2) {
		if s2[i] == ' ' || s2[i] == '\t' {
			return s2[:i]
		}
	}
	return s2
}
