#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sys/posix"
import "core:time"
import "core:unicode/utf8"
import "aether:agent"
import "aether:core"

// open_session + rebuild_blocks from chat history.

open_session :: proc(
	opts: agent.Headless_Options,
	model: string,
	cwd: string,
	auto_save: bool,
	perm: core.Permission_Mode,
) -> (agent.Session, string) {
	if opts.session_ref != "" {
		path, err := agent.resolve_session_ref(opts.session_ref, opts.sessions_dir, context.temp_allocator)
		if err != "" {
			return {}, err
		}
		return agent.session_load_file(path, auto_save)
	}
	if opts.continue_last {
		path := agent.most_recent_session_path(opts.sessions_dir, context.temp_allocator)
		if path == "" {
			return {}, "no previous sessions to continue"
		}
		return agent.session_load_file(path, auto_save)
	}
	catalog := agent.skills_catalog_text(context.temp_allocator)
	return agent.new_session(model, cwd, opts.sessions_dir, auto_save, perm, context.allocator, catalog), ""
}

rebuild_blocks :: proc(s: ^App_State, msgs: []agent.Chat_Message) {
	// Preserve expand state by tool name order (best-effort)
	prev_expand := make(map[string]bool, context.temp_allocator)
	// B37: preserve wall-clock stamps across rebuild (match kind+text key)
	prev_stamp := make(map[string]i64, context.temp_allocator)
	for b in s.blocks {
		if b.kind == .Tool && b.tool_name != "" {
			prev_expand[b.tool_name] = b.expanded
		}
		if b.time_unix != 0 {
			k := block_stamp_key(b.kind, b.text, b.tool_name, context.temp_allocator)
			prev_stamp[k] = b.time_unix
		}
	}
	state_clear_blocks(s)

	Pending_Tool :: struct {
		name: string,
		args: string,
	}
	pending := make(map[string]Pending_Tool, context.temp_allocator)
	defer delete(pending)

	// restore stamp on last-added block when key matches
	restore_stamp :: proc(s: ^App_State, prev: map[string]i64) {
		if len(s.blocks) == 0 {
			return
		}
		i := len(s.blocks) - 1
		b := &s.blocks[i]
		k := block_stamp_key(b.kind, b.text, b.tool_name, context.temp_allocator)
		if t, ok := prev[k]; ok {
			b.time_unix = t
		}
	}

	for m in msgs {
		switch m.role {
		case .System:
			continue
		case .User:
			if m.content != "" {
				state_add_block(s, .User, m.content)
				restore_stamp(s, prev_stamp)
			}
		case .Assistant:
			if m.content != "" {
				state_add_block(s, .Assistant, m.content)
				restore_stamp(s, prev_stamp)
			}
			for tc in m.tool_calls {
				pending[tc.id] = Pending_Tool {
					name = tc.name,
					args = tc.arguments,
				}
			}
		case .Tool:
			name := "tool"
			args := ""
			if p, ok := pending[m.tool_call_id]; ok {
				name = p.name if p.name != "" else "tool"
				args = p.args
				delete_key(&pending, m.tool_call_id)
			}
			body: string
			if args != "" && m.content != "" {
				body = fmt.tprintf("args: %s\n---\n%s", args, m.content)
			} else if m.content != "" {
				body = m.content
			} else if args != "" {
				body = fmt.tprintf("args: %s", args)
			} else {
				body = "(empty)"
			}
			// Preserve user expand choice; stay collapsed by default (cleaner Grok-like cards).
			exp: bool
			if name in prev_expand {
				exp = prev_expand[name]
			} else {
				exp = false
			}
			state_add_block(s, .Tool, body, name, exp)
			restore_stamp(s, prev_stamp)
		}
	}
	for id, p in pending {
		_ = id
		body := p.args if p.args != "" else "(pending)"
		nm := p.name if p.name != "" else "tool"
		exp := prev_expand[nm] if nm in prev_expand else false
		state_add_block(s, .Tool, body, nm, exp)
		restore_stamp(s, prev_stamp)
	}
}
