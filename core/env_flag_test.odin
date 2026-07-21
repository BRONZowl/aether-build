// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package core

import "core:os"
import "core:testing"

// Unique keys avoid parallel test interference.
ENV_FLAG_TEST_KEY :: "AETHER_TEST_ENV_FLAG_TRUTHY"
ENV_FLAG_KILL_KEY :: "AETHER_TEST_ENV_FLAG_KILL"

restore_env :: proc(key, prev: string) {
	if prev == "" {
		_ = os.unset_env(key)
	} else {
		_ = os.set_env(key, prev)
	}
}

@(test)
test_env_truthy_empty_and_falsey :: proc(t: ^testing.T) {
	prev := os.get_env(ENV_FLAG_TEST_KEY, context.temp_allocator)
	defer restore_env(ENV_FLAG_TEST_KEY, prev)

	_ = os.unset_env(ENV_FLAG_TEST_KEY)
	testing.expect(t, !env_truthy(ENV_FLAG_TEST_KEY))
	testing.expect(t, !env_truthy(""))

	falsey := []string{"0", "false", "no", "off", "garbage", "2"}
	for v in falsey {
		_ = os.set_env(ENV_FLAG_TEST_KEY, v)
		testing.expectf(t, !env_truthy(ENV_FLAG_TEST_KEY), "should be falsey: %s", v)
	}
}

@(test)
test_env_truthy_accepted_values :: proc(t: ^testing.T) {
	prev := os.get_env(ENV_FLAG_TEST_KEY, context.temp_allocator)
	defer restore_env(ENV_FLAG_TEST_KEY, prev)

	truthy := []string{"1", "true", "TRUE", "yes", "YES", "on", "On"}
	for v in truthy {
		_ = os.set_env(ENV_FLAG_TEST_KEY, v)
		testing.expectf(t, env_truthy(ENV_FLAG_TEST_KEY), "should be truthy: %s", v)
	}
}

@(test)
test_env_is_set :: proc(t: ^testing.T) {
	prev := os.get_env(ENV_FLAG_TEST_KEY, context.temp_allocator)
	defer restore_env(ENV_FLAG_TEST_KEY, prev)

	_ = os.unset_env(ENV_FLAG_TEST_KEY)
	testing.expect(t, !env_is_set(ENV_FLAG_TEST_KEY))
	_ = os.set_env(ENV_FLAG_TEST_KEY, "  ")
	testing.expect(t, !env_is_set(ENV_FLAG_TEST_KEY))
	_ = os.set_env(ENV_FLAG_TEST_KEY, "x")
	testing.expect(t, env_is_set(ENV_FLAG_TEST_KEY))
}

@(test)
test_feature_killed :: proc(t: ^testing.T) {
	prev := os.get_env(ENV_FLAG_KILL_KEY, context.temp_allocator)
	defer restore_env(ENV_FLAG_KILL_KEY, prev)

	_ = os.unset_env(ENV_FLAG_KILL_KEY)
	testing.expect(t, !feature_killed(ENV_FLAG_KILL_KEY))
	_ = os.set_env(ENV_FLAG_KILL_KEY, "1")
	testing.expect(t, feature_killed(ENV_FLAG_KILL_KEY))
}

@(test)
test_feature_enabled_kill_wins_and_override :: proc(t: ^testing.T) {
	prev := os.get_env(ENV_FLAG_KILL_KEY, context.temp_allocator)
	defer restore_env(ENV_FLAG_KILL_KEY, prev)

	_ = os.unset_env(ENV_FLAG_KILL_KEY)
	testing.expect(t, feature_enabled(ENV_FLAG_KILL_KEY, .Unset, true))
	testing.expect(t, !feature_enabled(ENV_FLAG_KILL_KEY, .Unset, false))
	testing.expect(t, feature_enabled(ENV_FLAG_KILL_KEY, .On, false))
	testing.expect(t, !feature_enabled(ENV_FLAG_KILL_KEY, .Off, true))

	_ = os.set_env(ENV_FLAG_KILL_KEY, "true")
	// Kill always wins
	testing.expect(t, !feature_enabled(ENV_FLAG_KILL_KEY, .Unset, true))
	testing.expect(t, !feature_enabled(ENV_FLAG_KILL_KEY, .On, true))
	testing.expect(t, !feature_enabled(ENV_FLAG_KILL_KEY, .Off, true))
}
