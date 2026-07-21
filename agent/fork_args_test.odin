package agent

import "core:strings"
import "core:testing"

@(test)
test_parse_fork_args_matrix :: proc(t: ^testing.T) {
	wt, rest, err := parse_fork_args("")
	testing.expect(t, err == "")
	testing.expect(t, wt == .Ask)
	testing.expect(t, rest == "")

	wt, rest, err = parse_fork_args("--worktree")
	testing.expect(t, err == "")
	testing.expect(t, wt == .Yes)
	testing.expect(t, rest == "")

	wt, rest, err = parse_fork_args("--no-worktree")
	testing.expect(t, err == "")
	testing.expect(t, wt == .No)

	wt, rest, err = parse_fork_args("--worktree my title")
	testing.expect(t, err == "")
	testing.expect(t, wt == .Yes)
	testing.expect(t, rest == "my title")

	wt, rest, err = parse_fork_args("--no-worktree  fix auth")
	testing.expect(t, err == "")
	testing.expect(t, wt == .No)
	testing.expect(t, rest == "fix auth")

	wt, rest, err = parse_fork_args("just a title")
	testing.expect(t, err == "")
	testing.expect(t, wt == .Ask)
	testing.expect(t, rest == "just a title")

	// unknown flag starts directive
	wt, rest, err = parse_fork_args("--foo bar")
	testing.expect(t, err == "")
	testing.expect(t, wt == .Ask)
	testing.expect(t, rest == "--foo bar")

	_, _, err = parse_fork_args("--worktree --no-worktree")
	testing.expect(t, err != "")

	_, _, err = parse_fork_args("--no-worktree --worktree")
	testing.expect(t, err != "")

	_, _, err = parse_fork_args("--at 3")
	testing.expect(t, err != "")
	testing.expect(t, strings.contains(err, "--at"))

	title := fork_title_from_rest("hello world\nmore")
	testing.expect(t, title == "hello world")
}
