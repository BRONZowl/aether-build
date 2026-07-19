// Package agent — plugins discovery + /plugins host UX (M4 MVP).
// Roots: ~/.grok/plugins/<name>/ and <cwd>/.grok/plugins/<name>/
// Project plugins require folder trust (M1). Skills under plugin skills/ are
// scanned via skills discovery roots.
package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "aether:core"

Plugin_Entry :: struct {
	name:        string, // owned
	path:        string, // owned abs
	source:      string, // "user" | "project" | "path"
	description: string, // owned; from plugin.json or ""
	version:     string, // owned
	has_skills:  bool,
	has_hooks:   bool,
}

destroy_plugin_entry :: proc(p: ^Plugin_Entry) {
	delete(p.name)
	delete(p.path)
	delete(p.source)
	delete(p.description)
	delete(p.version)
}

destroy_plugin_list :: proc(list: []Plugin_Entry) {
	for &p in list {
		destroy_plugin_entry(&p)
	}
	delete(list)
}

plugins_enabled :: proc() -> bool {
	if v := os.get_env("AETHER_NO_PLUGINS", context.temp_allocator); v == "1" ||
	   strings.equal_fold(v, "true") {
		return false
	}
	return true
}

// discover_plugins lists plugin dirs for cwd (project gated by folder trust).
discover_plugins :: proc(cwd: string, allocator := context.allocator) -> []Plugin_Entry {
	out := make([dynamic]Plugin_Entry, 0, 16, allocator)
	if !plugins_enabled() {
		return out[:]
	}
	// User plugins
	home := core.grok_home(context.temp_allocator)
	user_root, _ := filepath.join({home, "plugins"}, context.temp_allocator)
	scan_plugins_dir(user_root, "user", &out, allocator)

	// Project plugins (gated)
	if core.project_scope_allowed(cwd) {
		base := cwd if cwd != "" else "."
		proj, _ := filepath.join({base, ".grok", "plugins"}, context.temp_allocator)
		scan_plugins_dir(proj, "project", &out, allocator)
	}
	return out[:]
}

scan_plugins_dir :: proc(
	root: string,
	source: string,
	out: ^[dynamic]Plugin_Entry,
	allocator := context.allocator,
) {
	if root == "" || !os.exists(root) || !os.is_directory(root) {
		return
	}
	fis, err := os.read_all_directory_by_path(root, context.temp_allocator)
	if err != nil {
		return
	}
	for fi in fis {
		if strings.has_prefix(fi.name, ".") {
			continue
		}
		pdir, _ := filepath.join({root, fi.name}, context.temp_allocator)
		// Accept directories and symlinks that resolve to directories (plugins add uses symlink).
		if !os.is_directory(pdir) {
			continue
		}
		abs, aerr := filepath.abs(pdir, context.temp_allocator)
		if aerr != nil {
			abs = pdir
		}
		// skip duplicates by path
		dup := false
		for e in out {
			if e.path == abs {
				dup = true
				break
			}
		}
		if dup {
			continue
		}
		e := read_plugin_entry(abs, fi.name, source, allocator)
		append(out, e)
	}
}

read_plugin_entry :: proc(
	abs_path, dir_name, source: string,
	allocator := context.allocator,
) -> Plugin_Entry {
	e := Plugin_Entry {
		name   = strings.clone(dir_name, allocator),
		path   = strings.clone(abs_path, allocator),
		source = strings.clone(source, allocator),
	}
	// optional plugin.json / .plugin.json / manifest.json
	manifest_names := [3]string{"plugin.json", ".plugin.json", "manifest.json"}
	for fname in manifest_names {
		mp, _ := filepath.join({abs_path, fname}, context.temp_allocator)
		if !os.exists(mp) {
			continue
		}
		data, rerr := os.read_entire_file(mp, context.temp_allocator)
		if rerr != nil {
			continue
		}
		// light parse: "name", "description", "version" as JSON strings
		body := string(data)
		if n, ok := json_string_field(body, "name"); ok && n != "" {
			delete(e.name)
			e.name = strings.clone(n, allocator)
		}
		if d, ok := json_string_field(body, "description"); ok {
			e.description = strings.clone(d, allocator)
		}
		if v, ok := json_string_field(body, "version"); ok {
			e.version = strings.clone(v, allocator)
		}
		break
	}
	// capabilities
	sk, _ := filepath.join({abs_path, "skills"}, context.temp_allocator)
	e.has_skills = os.exists(sk) && os.is_directory(sk)
	// also SKILL.md packages as direct children
	if !e.has_skills {
		fis, err := os.read_all_directory_by_path(abs_path, context.temp_allocator)
		if err == nil {
			for fi in fis {
				if fi.type == .Directory {
					sm, _ := filepath.join({abs_path, fi.name, "SKILL.md"}, context.temp_allocator)
					if os.exists(sm) {
						e.has_skills = true
						break
					}
				}
			}
		}
	}
	hk, _ := filepath.join({abs_path, "hooks"}, context.temp_allocator)
	e.has_hooks = os.exists(hk) && os.is_directory(hk)
	return e
}

// json_string_field: minimal "key": "value" extractor (quoted).
json_string_field :: proc(body, key: string) -> (string, bool) {
	needle := fmt.tprintf(`"%s"`, key)
	i := strings.index(body, needle)
	if i < 0 {
		return "", false
	}
	rest := body[i + len(needle) :]
	// find :
	ci := strings.index_byte(rest, ':')
	if ci < 0 {
		return "", false
	}
	rest = strings.trim_space(rest[ci + 1 :])
	if len(rest) == 0 || rest[0] != '"' {
		return "", false
	}
	rest = rest[1:]
	// read until unescaped "
	b := strings.builder_make(context.temp_allocator)
	esc := false
	for j in 0 ..< len(rest) {
		ch := rest[j]
		if esc {
			strings.write_byte(&b, ch)
			esc = false
			continue
		}
		if ch == '\\' {
			esc = true
			continue
		}
		if ch == '"' {
			return strings.to_string(b), true
		}
		strings.write_byte(&b, ch)
	}
	return "", false
}

// plugin_skill_roots: skill package dirs from discovered plugins (for skills discovery).
plugin_skill_roots :: proc(cwd: string, allocator := context.allocator) -> []string {
	plugins := discover_plugins(cwd, context.temp_allocator)
	// Don't free plugin paths before cloning skill roots — use owned list
	out := make([dynamic]string, 0, 8, allocator)
	for p in plugins {
		// skills/ subdirectory
		sk, _ := filepath.join({p.path, "skills"}, context.temp_allocator)
		if os.exists(sk) && os.is_directory(sk) {
			append(&out, strings.clone(sk, allocator))
		}
		// plugin root itself may hold skill packages (child dirs with SKILL.md)
		// scan_skills_dir walks one level — pass plugin path as root
		// Only if it contains at least one SKILL.md package
		if p.has_skills {
			// always add plugin path so scan_skills_dir finds nested packages
			// avoid duplicate if already added skills/
			has := false
			for r in out {
				if r == p.path {
					has = true
					break
				}
			}
			if !has {
				// Prefer skills/ only; if skills/ missing, use plugin root
				if !(os.exists(sk) && os.is_directory(sk)) {
					append(&out, strings.clone(p.path, allocator))
				}
			}
		}
	}
	// free temp plugin list paths
	for &p in plugins {
		destroy_plugin_entry(&p)
	}
	delete(plugins)
	return out[:]
}

// format_plugins_list for /plugins status
format_plugins_list :: proc(cwd: string, allocator := context.allocator) -> string {
	if !plugins_enabled() {
		return strings.clone("plugins: DISABLED (AETHER_NO_PLUGINS=1)", allocator)
	}
	list := discover_plugins(cwd, context.allocator)
	defer destroy_plugin_list(list)
	b := strings.builder_make(allocator)
	trust := "trusted" if core.project_scope_allowed(cwd) else "untrusted"
	fmt.sbprintf(
		&b,
		"plugins: %d  folder-trust=%s  roots: ~/.grok/plugins · <cwd>/.grok/plugins\n",
		len(list),
		trust,
	)
	if len(list) == 0 {
		strings.write_string(
			&b,
			"  (none)  /plugins add <path>  or drop a package under ~/.grok/plugins/\n",
		)
		return strings.to_string(b)
	}
	for p in list {
		caps := ""
		if p.has_skills {
			caps = "skills"
		}
		if p.has_hooks {
			if caps != "" {
				caps = fmt.tprintf("%s+hooks", caps)
			} else {
				caps = "hooks"
			}
		}
		if caps == "" {
			caps = "-"
		}
		ver := p.version if p.version != "" else "-"
		desc := p.description if p.description != "" else ""
		fmt.sbprintf(&b, "  %s  [%s]  %s  v=%s  %s\n", p.name, p.source, caps, ver, p.path)
		if desc != "" {
			fmt.sbprintf(&b, "      %s\n", desc)
		}
	}
	return strings.to_string(b)
}

// plugins_add: symlink or note path into ~/.grok/plugins/<name>
plugins_add :: proc(src_path, cwd: string) -> string /* err */ {
	if !plugins_enabled() {
		return "plugins disabled (AETHER_NO_PLUGINS=1)"
	}
	src := strings.trim_space(src_path)
	if src == "" {
		return "path required"
	}
	abs, aerr := filepath.abs(src, context.temp_allocator)
	if aerr != nil {
		abs = src
	}
	if !os.exists(abs) || !os.is_directory(abs) {
		return fmt.tprintf("not a directory: %s", abs)
	}
	name := filepath.base(abs)
	if name == "" || name == "." || name == "/" {
		return "could not determine plugin name from path"
	}
	home := core.grok_home(context.temp_allocator)
	dest_root, _ := filepath.join({home, "plugins"}, context.temp_allocator)
	_ = core.ensure_dir(dest_root)
	dest, _ := filepath.join({dest_root, name}, context.temp_allocator)
	if os.exists(dest) {
		return fmt.tprintf("already installed: %s (remove first)", dest)
	}
	// Prefer symlink
	if lerr := os.symlink(abs, dest); lerr != nil {
		// fallback: not all FS support symlink — report error
		return fmt.tprintf("symlink failed (%v); copy manually into %s", lerr, dest_root)
	}
	return ""
}

// plugins_remove: remove ~/.grok/plugins/<name> (symlink or empty dir)
plugins_remove :: proc(name: string) -> string /* err */ {
	n := strings.trim_space(name)
	if n == "" || strings.contains(n, "/") || strings.contains(n, "..") {
		return "invalid plugin name"
	}
	home := core.grok_home(context.temp_allocator)
	dest, _ := filepath.join({home, "plugins", n}, context.temp_allocator)
	if !os.exists(dest) {
		return fmt.tprintf("not found in user plugins: %s", n)
	}
	// remove symlink first, else directory tree
	if rerr := os.remove(dest); rerr != nil {
		if rerr2 := os.remove_all(dest); rerr2 != nil {
			return fmt.tprintf("remove failed: %v", rerr2)
		}
	}
	return ""
}

// handle_plugins_slash: list|reload|add|remove|trust|help
handle_plugins_slash :: proc(
	arg: string,
	cwd: string,
	allocator := context.allocator,
) -> string {
	a := strings.trim_space(arg)
	al := strings.to_lower(a, context.temp_allocator)
	cmd := al
	rest := ""
	if sp := strings.index_byte(a, ' '); sp >= 0 {
		cmd = strings.to_lower(a[:sp], context.temp_allocator)
		rest = strings.trim_space(a[sp + 1:])
	}

	switch cmd {
	case "", "status", "list", "show", "ls":
		return format_plugins_list(cwd, allocator)
	case "help", "?":
		return strings.clone(
			"Usage: /plugins [list|reload|add <path>|remove <name>|trust|untrust|help]\n" +
			"  list              discovered plugins (user + project if trusted)\n" +
			"  reload            re-discover plugins + reload skills/hooks\n" +
			"  add <path>        symlink directory into ~/.grok/plugins/<name>\n" +
			"  remove <name>     remove user plugin symlink/dir\n" +
			"  trust / untrust   folder trust for project plugins (same as /hooks trust)\n" +
			"Roots: ~/.grok/plugins, <cwd>/.grok/plugins (project needs trust)\n" +
			"Skills under plugin skills/ load on reload. Opt-out: AETHER_NO_PLUGINS=1\n" +
			"Marketplace remote install: not in MVP (local path only).",
			allocator,
		)
	case "trust":
		if err := core.grant_folder_trust(cwd); err != "" {
			return fmt.aprintf("aether: plugins trust failed: %s", err, allocator = allocator)
		}
		maybe_start_hooks(cwd, true)
		_ = reload_skills_for_cwd(cwd, true)
		return fmt.aprintf(
			"aether: folder trusted (project plugins may load)\n%s",
			format_plugins_list(cwd, context.temp_allocator),
			allocator = allocator,
		)
	case "untrust":
		if err := core.revoke_folder_trust(cwd); err != "" {
			return fmt.aprintf("aether: plugins untrust failed: %s", err, allocator = allocator)
		}
		maybe_start_hooks(cwd, true)
		_ = reload_skills_for_cwd(cwd, true)
		return fmt.aprintf(
			"aether: folder untrusted (project plugins gated)\n%s",
			format_plugins_list(cwd, context.temp_allocator),
			allocator = allocator,
		)
	case "reload", "refresh":
		maybe_start_hooks(cwd, true)
		smsg := reload_skills_for_cwd(cwd, true)
		return fmt.aprintf(
			"aether: plugins reloaded (skills + hooks)\n%s\n%s",
			format_plugins_list(cwd, context.temp_allocator),
			smsg,
			allocator = allocator,
		)
	case "add", "install":
		if rest == "" {
			return strings.clone("aether: usage: /plugins add <directory path>", allocator)
		}
		if err := plugins_add(rest, cwd); err != "" {
			return fmt.aprintf("aether: plugins add failed: %s", err, allocator = allocator)
		}
		_ = reload_skills_for_cwd(cwd, true)
		return fmt.aprintf(
			"aether: plugin added\n%s",
			format_plugins_list(cwd, context.temp_allocator),
			allocator = allocator,
		)
	case "remove", "rm", "uninstall":
		if rest == "" {
			return strings.clone("aether: usage: /plugins remove <name>", allocator)
		}
		if err := plugins_remove(rest); err != "" {
			return fmt.aprintf("aether: plugins remove failed: %s", err, allocator = allocator)
		}
		_ = reload_skills_for_cwd(cwd, true)
		return fmt.aprintf(
			"aether: plugin removed: %s\n%s",
			rest,
			format_plugins_list(cwd, context.temp_allocator),
			allocator = allocator,
		)
	case:
		return fmt.aprintf(
			"aether: unknown /plugins arg %q (try /plugins help)",
			arg,
			allocator = allocator,
		)
	}
}
