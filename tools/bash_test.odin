// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tools

import "core:testing"

@(test)
test_clamp_bash_fg_timeout_ms :: proc(t: ^testing.T) {
	testing.expect(t, clamp_bash_fg_timeout_ms(0) == BASH_FG_DEFAULT_TIMEOUT_MS)
	testing.expect(t, clamp_bash_fg_timeout_ms(-1) == BASH_FG_DEFAULT_TIMEOUT_MS)
	testing.expect(t, clamp_bash_fg_timeout_ms(5000) == 5000)
	testing.expect(t, clamp_bash_fg_timeout_ms(999_999) == BASH_FG_MAX_TIMEOUT_MS)
}
