package hooks

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// load_hooks_from_dir parses *.json under dir into out (append).
load_hooks_from_dir :: proc(dir: string, out: ^[dynamic]Hook_Spec, allocator := context.allocator) {
	if dir == "" || !os.exists(dir) || !os.is_directory(dir) {
		return
	}
	fis, err := os.read_all_directory_by_path(dir, context.temp_allocator)
	if err != nil {
		return
	}
	for fi in fis {
		if fi.type == .Directory {
			continue
		}
		if !strings.has_suffix(fi.name, ".json") {
			continue
		}
		path, _ := filepath.join({dir, fi.name}, context.temp_allocator)
		load_hooks_from_file(path, dir, out, allocator)
	}
}

// load_hooks_from_file parses one Grok-shaped settings or hooks JSON file.
load_hooks_from_file :: proc(
	path: string,
	source_dir: string,
	out: ^[dynamic]Hook_Spec,
	allocator := context.allocator,
) {
	data, rerr := os.read_entire_file(path, context.temp_allocator)
	if rerr != nil {
		return
	}
	val, perr := json.parse(data, json.DEFAULT_SPECIFICATION, false, context.temp_allocator)
	if perr != nil {
		return
	}
	root, is_obj := val.(json.Object)
	if !is_obj {
		return
	}
	// Prefer "hooks" key; else treat root as hooks map
	hooks_v, has_hooks := root["hooks"]
	hooks_obj: json.Object
	if has_hooks {
		ho, ok := hooks_v.(json.Object)
		if !ok {
			return
		}
		hooks_obj = ho
	} else {
		hooks_obj = root
	}

	for event_key, groups_v in hooks_obj {
		ev, ok_ev := parse_event_name(event_key)
		if !ok_ev || ev == .Other {
			continue
		}
		arr, is_arr := groups_v.(json.Array)
		if !is_arr {
			continue
		}
		for group_v in arr {
			gobj, is_g := group_v.(json.Object)
			if !is_g {
				continue
			}
			matcher := ""
			if mv, has_m := gobj["matcher"]; has_m {
				if ms, is_s := mv.(json.String); is_s {
					matcher = string(ms)
				}
			}
			hooks_arr_v, has_h := gobj["hooks"]
			if !has_h {
				continue
			}
			harr, is_ha := hooks_arr_v.(json.Array)
			if !is_ha {
				continue
			}
			for hv, hi in harr {
				hobj, is_ho := hv.(json.Object)
				if !is_ho {
					continue
				}
				// type: "command" (default) | "http" (A4.7)
				typ := "command"
				if tv, has_t := hobj["type"]; has_t {
					if ts, is_s := tv.(json.String); is_s {
						typ = string(ts)
					}
				}
				timeout_s := 5
				if tov, has_to := hobj["timeout"]; has_to {
					#partial switch n in tov {
					case json.Integer:
						timeout_s = int(n)
					case json.Float:
						timeout_s = int(n)
					}
				}
				if timeout_s <= 0 {
					timeout_s = 5
				}
				name := fmt.aprintf(
					"%s:%s#%d",
					filepath.base(path),
					event_key,
					hi,
					allocator = allocator,
				)
				switch typ {
				case "command":
					cmd := ""
					if cv, has_c := hobj["command"]; has_c {
						if cs, is_s := cv.(json.String); is_s {
							cmd = string(cs)
						}
					}
					if cmd == "" {
						continue
					}
					append(
						out,
						Hook_Spec {
							event       = ev,
							kind        = .Command,
							name        = name,
							command     = strings.clone(cmd, allocator),
							url         = "",
							timeout_s   = timeout_s,
							matcher     = strings.clone(matcher, allocator),
							source_dir  = strings.clone(source_dir, allocator),
							source_file = strings.clone(path, allocator),
						},
					)
				case "http":
					url_raw := ""
					if uv, has_u := hobj["url"]; has_u {
						if us, is_s := uv.(json.String); is_s {
							url_raw = string(us)
						}
					}
					if url_raw == "" {
						continue
					}
					// Expand ${VAR}/$VAR at load; unset refs preserved for fail later.
					url_exp := expand_hook_env_vars(url_raw, context.temp_allocator)
					append(
						out,
						Hook_Spec {
							event       = ev,
							kind        = .Http,
							name        = name,
							command     = "",
							url         = strings.clone(url_exp, allocator),
							timeout_s   = timeout_s,
							matcher     = strings.clone(matcher, allocator),
							source_dir  = strings.clone(source_dir, allocator),
							source_file = strings.clone(path, allocator),
						},
					)
				case:
					// unsupported handler type — skip (Grok errors; we fail-open skip)
					continue
				}
			}
		}
	}
}

// load_hooks discovers user + project hook dirs for cwd, then extra paths
// listed in $GROK_HOME/hooks-paths (B18 / Grok-shaped).
load_hooks :: proc(cwd: string, allocator := context.allocator) -> Hook_Registry {
	r: Hook_Registry
	r.specs = make([dynamic]Hook_Spec, 0, 8, allocator)
	user_dir := hooks_root_user(context.temp_allocator)
	load_hooks_from_dir(user_dir, &r.specs, allocator)
	proj := hooks_root_project(cwd, context.temp_allocator)
	load_hooks_from_dir(proj, &r.specs, allocator)
	// extra paths (file or dir under ~/.grok)
	extras := read_hooks_paths(context.temp_allocator)
	for ep in extras {
		load_hooks_from_extra_path(ep, &r.specs, allocator)
	}
	return r
}

// reload_global_hooks loads into process registry.
reload_global_hooks :: proc(cwd: string) {
	if !hooks_enabled() {
		clear_global_registry()
		return
	}
	r := load_hooks(cwd, context.allocator)
	set_global_registry(r)
}
