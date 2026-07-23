// Package core — shared types, version, paths, and config for Aether-Grok.
// Rust reference: xai-grok-shared, xai-grok-version, xai-grok-env, xai-grok-config.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:fmt"

VERSION :: "0.1.1"
// Semver advertised to cli-chat-proxy (must be >= their minimum, currently 0.1.202).
// Bump when aligning with a known-good Rust Grok CLI release.
PROXY_CLIENT_VERSION :: "0.2.101"
PROJECT_NAME :: "aether-grok"
DESCRIPTION :: "High-performance Odin port of Grok Build components"

// version_string returns the human-readable version banner.
version_string :: proc() -> string {
	return fmt.tprintf("%s %s", PROJECT_NAME, VERSION)
}

// user_agent for HTTP requests.
user_agent :: proc() -> string {
	return fmt.tprintf("%s/%s (linux)", PROJECT_NAME, VERSION)
}
