#+build linux, darwin, freebsd, openbsd, netbsd
package tui

import "core:os"
import "core:sys/posix"

// Key bindings match Grok Build (see ~/.grok/docs/user-guide/03-keyboard-shortcuts.md).
// Raw byte path + Kitty CSI-u when the terminal supports keyboard enhancement.

Key_Kind :: enum {
	Char,
	Enter, // bare Enter → send (or newline in multiline mode)
	Mod_Enter, // Shift+Enter / Alt+Enter → newline (or send in multiline)
	Backspace,
	Esc,
	Ctrl_C,
	Ctrl_D, // quit alt (VS Code family)
	Ctrl_Q, // quit
	Ctrl_S, // session picker (Grok)
	Ctrl_N, // new session (double-press, Grok)
	Ctrl_O, // toggle YOLO / always-approve (Grok)
	Ctrl_F, // scrollback search / find (Grok-shaped)
	Ctrl_M, // toggle multiline (when disambiguated from Enter)
	Ctrl_U, // scroll half page up
	Ctrl_K, // scroll line up
	Ctrl_J, // scroll line down
	Ctrl_V, // paste (text + clipboard image / path → Image #N)
	Up,
	Down,
	Left,
	Right,
	PgUp,
	PgDn,
	Home,
	End,
	Tab, // toggle prompt / scrollback focus (Grok)
	Shift_Tab, // cycle: ask → plan → auto → always-approve → read-only
	Mouse_Wheel_Up, // SGR/X10 wheel (C2.2)
	Mouse_Wheel_Down,
	Mouse_Click, // left press (C2.3); x/y 1-based
	Mouse_Middle, // middle press (C2.5 PRIMARY paste)
	Shift_Left, // C2.4 turn nav (prev user)
	Shift_Right, // C2.4 turn nav (next user)
	Paste, // bracketed paste payload (C2.6); text in Key.text
	Unknown,
}

Key :: struct {
	kind:      Key_Kind,
	ch:        rune,
	mouse_btn: int, // SGR button code (0=left, 64=wheel up, …)
	mouse_x:   int, // 1-based column
	mouse_y:   int, // 1-based row
	text:      string, // Paste: views g_paste_buf (valid until next paste/key)
}

MAX_BRACKETED_PASTE :: 200_000

@(private)
g_paste_buf: [dynamic]u8

// one-byte pushback
@(private)
g_has_pending: bool
@(private)
g_pending:     u8

// multi-byte pushback for escape partials (rare)
@(private)
g_push_buf:  [32]u8
@(private)
g_push_len:  int
@(private)
g_push_idx:  int

read_byte :: proc() -> (u8, bool) {
	if g_push_idx < g_push_len {
		b := g_push_buf[g_push_idx]
		g_push_idx += 1
		if g_push_idx >= g_push_len {
			g_push_len = 0
			g_push_idx = 0
		}
		return b, true
	}
	if g_has_pending {
		g_has_pending = false
		return g_pending, true
	}
	buf: [1]u8
	n, err := os.read(os.stdin, buf[:])
	if n <= 0 {
		_ = err
		return 0, false
	}
	return buf[0], true
}

push_bytes :: proc(bs: []u8) {
	// prepend remaining unread push buffer is complex; only used when empty
	if g_push_idx < g_push_len {
		return
	}
	n := min(len(bs), len(g_push_buf))
	copy(g_push_buf[:n], bs[:n])
	g_push_len = n
	g_push_idx = 0
}

// read_key blocks until a key arrives.
// Matches Grok Build: bare Enter / Shift|Alt+Enter / Ctrl chords / CSI-u.
read_key :: proc() -> Key {
	b, ok := read_byte()
	if !ok {
		return Key{kind = .Esc}
	}

	// Classic control characters (no keyboard enhancement needed)
	switch b {
	case 0x03:
		return Key{kind = .Ctrl_C}
	case 0x04:
		return Key{kind = .Ctrl_D}
	case 0x09:
		return Key{kind = .Tab}
	case 0x0b:
		return Key{kind = .Ctrl_K}
	case 0x0a:
		// Ctrl+J / LF — Grok: scroll line down (not newline)
		return Key{kind = .Ctrl_J}
	case 0x0d:
		// CR / Ctrl+M without disambiguation — bare Enter
		// Drain optional LF after CR
		drain_cr_lf()
		return Key{kind = .Enter}
	case 0x11:
		return Key{kind = .Ctrl_Q}
	case 0x13:
		return Key{kind = .Ctrl_S}
	case 0x0e:
		return Key{kind = .Ctrl_N}
	case 0x0f:
		return Key{kind = .Ctrl_O}
	case 0x06:
		return Key{kind = .Ctrl_F}
	case 0x15:
		return Key{kind = .Ctrl_U}
	case 0x16:
		return Key{kind = .Ctrl_V}
	case 0x7f, 0x08:
		return Key{kind = .Backspace}
	case 0x1b:
		return read_escape()
	}

	if b >= 32 && b < 127 {
		return Key{kind = .Char, ch = rune(b)}
	}
	// UTF-8 multi-byte
	need := 0
	if b & 0xe0 == 0xc0 {
		need = 1
	} else if b & 0xf0 == 0xe0 {
		need = 2
	} else if b & 0xf8 == 0xf0 {
		need = 3
	}
	if need > 0 {
		bytes: [4]u8
		bytes[0] = b
		ok_all := true
		for i in 0 ..< need {
			c, cok := read_byte()
			if !cok {
				ok_all = false
				break
			}
			bytes[i + 1] = c
		}
		if ok_all {
			r: rune
			if need == 1 {
				r = rune(bytes[0] & 0x1f) << 6 | rune(bytes[1] & 0x3f)
			} else if need == 2 {
				r = rune(bytes[0] & 0x0f) << 12 | rune(bytes[1] & 0x3f) << 6 | rune(bytes[2] & 0x3f)
			} else {
				r =
					rune(bytes[0] & 0x07) << 18 |
					rune(bytes[1] & 0x3f) << 12 |
					rune(bytes[2] & 0x3f) << 6 |
					rune(bytes[3] & 0x3f)
			}
			return Key{kind = .Char, ch = r}
		}
	}
	return Key{kind = .Unknown}
}

drain_cr_lf :: proc() {
	old: posix.termios
	if posix.tcgetattr(posix.FD(posix.STDIN_FILENO), &old) != .OK {
		return
	}
	raw := old
	raw.c_cc[.VMIN] = 0
	raw.c_cc[.VTIME] = 0
	_ = posix.tcsetattr(posix.FD(posix.STDIN_FILENO), .TCSANOW, &raw)
	nb, nok := read_byte()
	_ = posix.tcsetattr(posix.FD(posix.STDIN_FILENO), .TCSANOW, &old)
	if nok && nb != 0x0a {
		g_pending = nb
		g_has_pending = true
	}
}

// Timed read of next byte (VTIME in deciseconds; 1 = 100ms).
read_byte_timeout :: proc(vtime: u8 = 1) -> (u8, bool) {
	old: posix.termios
	if posix.tcgetattr(posix.FD(posix.STDIN_FILENO), &old) != .OK {
		return read_byte()
	}
	raw := old
	raw.c_cc[.VMIN] = 0
	raw.c_cc[.VTIME] = posix.cc_t(vtime)
	_ = posix.tcsetattr(posix.FD(posix.STDIN_FILENO), .TCSANOW, &raw)
	b, ok := read_byte()
	_ = posix.tcsetattr(posix.FD(posix.STDIN_FILENO), .TCSANOW, &old)
	return b, ok
}

read_escape :: proc() -> Key {
	b1, ok1 := read_byte_timeout(1)
	if !ok1 {
		return Key{kind = .Esc}
	}

	// Alt+Enter often arrives as ESC CR
	if b1 == 0x0d {
		drain_cr_lf()
		return Key{kind = .Mod_Enter}
	}
	// Alt+char: ESC + printable → treat as Esc for now (not used for input cmds)
	if b1 != '[' && b1 != 'O' {
		// lone meta — ignore as Esc
		return Key{kind = .Esc}
	}

	if b1 == 'O' {
		// SS3: application cursor keys
		b2, ok2 := read_byte_timeout(1)
		if !ok2 {
			return Key{kind = .Esc}
		}
		switch b2 {
		case 'A':
			return Key{kind = .Up}
		case 'B':
			return Key{kind = .Down}
		case 'C':
			return Key{kind = .Right}
		case 'D':
			return Key{kind = .Left}
		case 'H':
			return Key{kind = .Home}
		case 'F':
			return Key{kind = .End}
		case 'M':
			// Some terminals: SS3 M = keypad enter — treat as Enter
			return Key{kind = .Enter}
		}
		return Key{kind = .Esc}
	}

	// CSI: ESC [
	return read_csi()
}

// read_csi parses after ESC [ already consumed.
// Supports: arrows, Home/End, PgUp/Dn, modifyOtherKeys Enter, Kitty CSI-u, mouse SGR/X10.
read_csi :: proc() -> Key {
	// Collect until final byte (0x40-0x7E)
	params: [48]u8
	n := 0
	for n < len(params) {
		b, ok := read_byte_timeout(1)
		if !ok {
			return Key{kind = .Esc}
		}
		// intermediate or param digits / ; / < (SGR mouse)
		if (b >= '0' && b <= '9') || b == ';' || b == '<' {
			params[n] = b
			n += 1
			continue
		}
		// final byte
		final := b
		ps := string(params[:n])

		// Mouse SGR: ESC [ < btn ; x ; y M|m  (M=press, m=release)
		if final == 'M' || final == 'm' {
			if n == 0 && final == 'M' {
				// X10 legacy: ESC [ M Cb Cx Cy
				return decode_mouse_x10()
			}
			return decode_mouse_sgr(ps, final == 'M')
		}
		// Kitty / CSI-u: ESC [ code ; mods u
		if final == 'u' {
			return decode_csi_u(ps)
		}
		// xterm modifyOtherKeys: ESC [ 27 ; mods ; code ~
		if final == '~' {
			return decode_csi_tilde(ps)
		}
		// simple CSI: ESC [ A  or ESC [ 1 ; 2 A (shift+arrow for turn nav C2.4)
		if final == 'A' || final == 'B' || final == 'C' || final == 'D' ||
		   final == 'H' || final == 'F' || final == 'Z' {
			// params "1;2D" → shift+left (mods: 1=none, 2=shift, …)
			shift := csi_arrow_shift(ps)
			switch final {
			case 'A':
				return Key{kind = .Up}
			case 'B':
				return Key{kind = .Down}
			case 'C':
				if shift {
					return Key{kind = .Shift_Right}
				}
				return Key{kind = .Right}
			case 'D':
				if shift {
					return Key{kind = .Shift_Left}
				}
				return Key{kind = .Left}
			case 'H':
				return Key{kind = .Home}
			case 'F':
				return Key{kind = .End}
			case 'Z':
				return Key{kind = .Shift_Tab}
			}
		}
		// ESC [ 5 ~ / 6 ~ already handled if we got digits then ~
		// bare "5~" style collected as params "5" final '~'
		_ = ps
		return Key{kind = .Esc}
	}
	return Key{kind = .Esc}
}

// decode_mouse_sgr: params "<btn;col;row" — wheel 64/65; left click btn 0 press only.
// press=true when final is 'M' (press); release 'm' ignored for clicks.
decode_mouse_sgr :: proc(params: string, press: bool) -> Key {
	p := params
	if len(p) > 0 && p[0] == '<' {
		p = p[1:]
	}
	parts := split_semi(p)
	if len(parts) < 1 {
		return Key{kind = .Unknown}
	}
	btn := parts[0]
	mx, my := 0, 0
	if len(parts) >= 2 {
		mx = parts[1]
	}
	if len(parts) >= 3 {
		my = parts[2]
	}
	// SGR wheel: 64 up, 65 down
	if btn == 64 || btn == 68 || btn == 72 || btn == 80 {
		return Key{kind = .Mouse_Wheel_Up, mouse_btn = btn, mouse_x = mx, mouse_y = my}
	}
	if btn == 65 || btn == 69 || btn == 73 || btn == 81 {
		return Key{kind = .Mouse_Wheel_Down, mouse_btn = btn, mouse_x = mx, mouse_y = my}
	}
	// Left button press only (btn 0); ignore motion (32+) and releases
	if press && btn == 0 {
		return Key {
			kind      = .Mouse_Click,
			mouse_btn = btn,
			mouse_x   = mx,
			mouse_y   = my,
		}
	}
	// Middle button press (btn 1) — PRIMARY paste (C2.5)
	if press && btn == 1 {
		return Key {
			kind      = .Mouse_Middle,
			mouse_btn = btn,
			mouse_x   = mx,
			mouse_y   = my,
		}
	}
	return Key{kind = .Unknown}
}

// decode_mouse_x10: after ESC [ M, three bytes Cb Cx Cy (Cb - 32 = button).
decode_mouse_x10 :: proc() -> Key {
	cb, ok1 := read_byte_timeout(1)
	cx, ok2 := read_byte_timeout(1)
	cy, ok3 := read_byte_timeout(1)
	if !ok1 || !ok2 || !ok3 {
		return Key{kind = .Unknown}
	}
	btn := int(cb) - 32
	mx := int(cx) - 32
	my := int(cy) - 32
	if btn == 64 || btn == 4 {
		return Key{kind = .Mouse_Wheel_Up, mouse_btn = btn, mouse_x = mx, mouse_y = my}
	}
	if btn == 65 || btn == 5 {
		return Key{kind = .Mouse_Wheel_Down, mouse_btn = btn, mouse_x = mx, mouse_y = my}
	}
	// left press
	if btn == 0 {
		return Key{kind = .Mouse_Click, mouse_btn = 0, mouse_x = mx, mouse_y = my}
	}
	// middle press
	if btn == 1 {
		return Key{kind = .Mouse_Middle, mouse_btn = 1, mouse_x = mx, mouse_y = my}
	}
	return Key{kind = .Unknown}
}

// csi_arrow_shift: true when CSI params look like "1;2" (shift) on arrows.
// Kitty/xterm: mods field 2 = shift (1-based encoding: actual = mods-1 bit0).
csi_arrow_shift :: proc(params: string) -> bool {
	// bare "A" → no shift; "1;2" or "1;2A" collected as "1;2"
	parts := split_semi(params)
	if len(parts) < 2 {
		return false
	}
	mods := parts[1]
	return (mods > 0) && ((mods - 1) & 1) != 0
}

// decode_csi_u: "13" or "13;2" or "109;5" → key
// mods: 1=none, 2=shift, 3=alt, 4=shift+alt, 5=ctrl, ...
decode_csi_u :: proc(params: string) -> Key {
	code, mods := parse_two_params(params)
	shift := (mods > 0) && ((mods - 1) & 1) != 0
	alt := (mods > 0) && ((mods - 1) & 2) != 0
	ctrl := (mods > 0) && ((mods - 1) & 4) != 0

	// Arrow keys as CSI-u (rare): 57349 left etc. — also handle 1/2/3/4 for some terminals
	// Standard arrows often not CSI-u; still handle shift+arrow if code is left/right
	// xterm/kitty private use: skip unless common

	// Enter = 13, Escape = 27, Backspace = 127, Tab = 9
	if code == 13 {
		if shift || alt {
			return Key{kind = .Mod_Enter}
		}
		if ctrl {
			// Ctrl+Enter → interject in Grok mid-turn; idle: treat as send-now no-op / Enter
			return Key{kind = .Enter}
		}
		return Key{kind = .Enter}
	}
	if code == 27 {
		return Key{kind = .Esc}
	}
	if code == 127 || code == 8 {
		return Key{kind = .Backspace}
	}
	// letter keys with ctrl: 'm' = 109, 'q' = 113, 'c' = 99, 'u' = 117, 'j' = 106, 'k' = 107, 'd' = 100
	if ctrl {
		switch code {
		case 109, 77: // m/M
			return Key{kind = .Ctrl_M}
		case 113, 81: // q
			return Key{kind = .Ctrl_Q}
		case 99, 67: // c
			return Key{kind = .Ctrl_C}
		case 100, 68: // d
			return Key{kind = .Ctrl_D}
		case 117, 85: // u
			return Key{kind = .Ctrl_U}
		case 106, 74: // j
			return Key{kind = .Ctrl_J}
		case 107, 75: // k
			return Key{kind = .Ctrl_K}
		case 115, 83: // s
			return Key{kind = .Ctrl_S}
		case 110, 78: // n
			return Key{kind = .Ctrl_N}
		case 111, 79: // o
			return Key{kind = .Ctrl_O}
		case 102, 70: // f
			return Key{kind = .Ctrl_F}
		case 118, 86: // v
			return Key{kind = .Ctrl_V}
		}
	}
	// printable with no mods
	if code >= 32 && code < 127 && !ctrl && !alt {
		ch := rune(code)
		if shift && ch >= 'a' && ch <= 'z' {
			ch = ch - 32
		}
		return Key{kind = .Char, ch = ch}
	}
	return Key{kind = .Unknown}
}

// is_bracketed_paste_start: CSI ~ param is 200.
is_bracketed_paste_start :: proc(params: string) -> bool {
	parts := split_semi(params)
	return len(parts) == 1 && parts[0] == 200
}

// is_bracketed_paste_end: CSI ~ param is 201.
is_bracketed_paste_end :: proc(params: string) -> bool {
	parts := split_semi(params)
	return len(parts) == 1 && parts[0] == 201
}

// read_bracketed_paste consumes stdin until ESC [ 201 ~ (or cap / timeout).
// Payload stored in g_paste_buf; Key.text views it.
read_bracketed_paste :: proc() -> Key {
	if g_paste_buf.allocator.procedure == nil {
		g_paste_buf = make([dynamic]u8, 0, 4096)
	}
	clear(&g_paste_buf)
	for len(g_paste_buf) < MAX_BRACKETED_PASTE {
		// VTIME deciseconds: 10 = 1s between paste chunks
		b, ok := read_byte_timeout(10)
		if !ok {
			break
		}
		if b != 0x1b {
			append(&g_paste_buf, b)
			continue
		}
		// ESC — maybe end sequence [ 2 0 1 ~
		b2, ok2 := read_byte_timeout(2)
		if !ok2 {
			append(&g_paste_buf, 0x1b)
			break
		}
		if b2 != '[' {
			append(&g_paste_buf, 0x1b)
			append(&g_paste_buf, b2)
			continue
		}
		// collect digits/params until final
		pbuf: [16]u8
		pn := 0
		final: u8
		got_final := false
		for pn < len(pbuf) {
			c, cok := read_byte_timeout(2)
			if !cok {
				break
			}
			if (c >= '0' && c <= '9') || c == ';' {
				pbuf[pn] = c
				pn += 1
				continue
			}
			final = c
			got_final = true
			break
		}
		if got_final && final == '~' && is_bracketed_paste_end(string(pbuf[:pn])) {
			// end of paste
			break
		}
		// not end — treat as literal content (rare)
		append(&g_paste_buf, 0x1b)
		append(&g_paste_buf, '[')
		for i in 0 ..< pn {
			append(&g_paste_buf, pbuf[i])
		}
		if got_final {
			append(&g_paste_buf, final)
		}
	}
	return Key{kind = .Paste, text = string(g_paste_buf[:])}
}

// decode_csi_tilde: "5" PgUp, "6" PgDn, "200"/"201" bracketed paste, "27;2;13" mod enter.
decode_csi_tilde :: proc(params: string) -> Key {
	// Form: n~ or 27;mods;code~
	parts := split_semi(params)
	if len(parts) == 1 {
		switch parts[0] {
		case 5:
			return Key{kind = .PgUp}
		case 6:
			return Key{kind = .PgDn}
		case 1, 7:
			return Key{kind = .Home}
		case 4, 8:
			return Key{kind = .End}
		case 3:
			// Delete key — backspace-like for MVP
			return Key{kind = .Backspace}
		case 200:
			// Bracketed paste start → read until ESC [ 201 ~
			return read_bracketed_paste()
		case 201:
			// stray end without start — ignore
			return Key{kind = .Unknown}
		}
	}
	// 27 ; mods ; keycode ~
	if len(parts) >= 3 && parts[0] == 27 {
		mods := parts[1]
		code := parts[2]
		shift := (mods > 0) && ((mods - 1) & 1) != 0
		alt := (mods > 0) && ((mods - 1) & 2) != 0
		ctrl := (mods > 0) && ((mods - 1) & 4) != 0
		if code == 13 {
			if shift || alt {
				return Key{kind = .Mod_Enter}
			}
			return Key{kind = .Enter}
		}
		if ctrl && (code == 109 || code == 77) {
			return Key{kind = .Ctrl_M}
		}
		if ctrl && (code == 113 || code == 81) {
			return Key{kind = .Ctrl_Q}
		}
	}
	// 1;mods A style shouldn't end in ~
	return Key{kind = .Unknown}
}

parse_two_params :: proc(s: string) -> (code, mods: int) {
	code = 0
	mods = 1 // default "no modifiers" in kitty is often omitted
	semi := -1
	for i in 0 ..< len(s) {
		if s[i] == ';' {
			semi = i
			break
		}
	}
	if semi < 0 {
		code, _ = parse_pos_int(s)
		return code, 1
	}
	code, _ = parse_pos_int(s[:semi])
	mods, _ = parse_pos_int(s[semi + 1:])
	if mods == 0 {
		mods = 1
	}
	return
}

split_semi :: proc(s: string) -> [dynamic]int {
	out := make([dynamic]int, 0, 4, context.temp_allocator)
	start := 0
	for i in 0 ..= len(s) {
		if i == len(s) || s[i] == ';' {
			if i > start {
				n, _ := parse_pos_int(s[start:i])
				append(&out, n)
			} else {
				append(&out, 0)
			}
			start = i + 1
		}
	}
	return out
}
