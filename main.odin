// Aether-Grok — high-performance Odin port of Grok Build components.
// Entry point: thin main that dispatches to the cli package.
package main

import "core:os"
import "aether:cli"

main :: proc() {
	code := cli.run()
	os.exit(code)
}
