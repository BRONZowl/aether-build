// Package agent — shared media path helpers for image/video Imagine tools (P5).

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package agent

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "aether:core"

Media_Kind :: enum {
	Image,
	Video,
}

// media_output_dir: env override or {sessions}/images|videos.
// env_key: AETHER_IMAGE_DIR / AETHER_VIDEO_DIR; subdir: "images" / "videos".
media_output_dir :: proc(
	env_key: string,
	subdir: string,
	allocator := context.allocator,
) -> string {
	if env_key != "" {
		if v := os.get_env(env_key, context.temp_allocator); v != "" {
			return strings.clone(v, allocator)
		}
	}
	base := core.aether_sessions_dir("", context.temp_allocator)
	joined, _ := filepath.join({base, subdir}, allocator)
	return joined
}

// next_media_path: ensure dir, bump counter under mu, return abs + relative display path.
next_media_path :: proc(
	dir: string,
	subdir: string,
	ext: string, // "jpg" / "mp4"
	mu: ^sync.Mutex,
	ctr: ^int,
	allocator := context.allocator,
) -> (
	abs_path: string,
	rel: string,
	err: string,
) {
	if !core.ensure_dir(dir) {
		return "", "", fmt.tprintf("cannot create media dir %s", dir)
	}
	sync.mutex_lock(mu)
	ctr^ += 1
	n := ctr^
	sync.mutex_unlock(mu)
	name := fmt.tprintf("%d.%s", n, ext)
	path, jerr := filepath.join({dir, name}, allocator)
	if jerr != nil {
		return "", "", "path join failed"
	}
	return path, fmt.tprintf("%s/%d.%s", subdir, n, ext), ""
}
