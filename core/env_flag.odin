// Shared env truthy / feature kill-switch helpers (P1 maintainability).
// Prefer these over ad-hoc AETHER_NO_* string comparisons.

// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:os"
import "core:strings"

// Feature_Override: process-local override layered under env kill-switch.
// Env kill always wins when truthy (feature disabled).
Feature_Override :: enum {
	Unset,
	On,
	Off,
}

// env_truthy: empty → false; 1/true/yes/on (case-insensitive) → true.
// Matches historical Aether kill-switch / flag parsing.
env_truthy :: proc(key: string) -> bool {
	if key == "" {
		return false
	}
	v := os.get_env(key, context.temp_allocator)
	if v == "" {
		return false
	}
	switch strings.to_lower(v, context.temp_allocator) {
	case "1", "true", "yes", "on":
		return true
	}
	return false
}

// env_is_set: key present and non-empty after trim.
env_is_set :: proc(key: string) -> bool {
	if key == "" {
		return false
	}
	v := strings.trim_space(os.get_env(key, context.temp_allocator))
	return v != ""
}

// feature_killed: AETHER_NO_* style — true means the feature is DISABLED.
feature_killed :: proc(kill_env_key: string) -> bool {
	return env_truthy(kill_env_key)
}

// feature_enabled: kill wins (disabled); else process override; else default_on.
feature_enabled :: proc(
	kill_env_key: string,
	override: Feature_Override = .Unset,
	default_on := true,
) -> bool {
	if feature_killed(kill_env_key) {
		return false
	}
	switch override {
	case .On:
		return true
	case .Off:
		return false
	case .Unset:
		return default_on
	}
	return default_on
}
