// Aether-Grok — high-performance Odin port of Grok Build components.
// Entry point: thin main that dispatches to the cli package.
//
// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0
// See LICENSE and NOTICE in the repository root.
package main

import "core:os"
import "aether:cli"

main :: proc() {
	code := cli.run()
	os.exit(code)
}
