package agent

import "core:fmt"
import "core:os"
import "core:strings"
import "core:testing"

@(test)
test_parse_image_token_forms :: proc(t: ^testing.T) {
	n, ok := parse_image_token("[Image #1]")
	testing.expect(t, ok && n == 1)
	n, ok = parse_image_token("Image #2")
	testing.expect(t, ok && n == 2)
	n, ok = parse_image_token("image #3")
	testing.expect(t, ok && n == 3)
	n, ok = parse_image_token("#4")
	testing.expect(t, ok && n == 4)
	n, ok = parse_image_token("  [image #10]  ")
	testing.expect(t, ok && n == 10)

	_, ok = parse_image_token("/tmp/x.jpg")
	testing.expect(t, !ok)
	_, ok = parse_image_token("data:image/jpeg;base64,xx")
	testing.expect(t, !ok)
	_, ok = parse_image_token("Image 1")
	testing.expect(t, !ok)
	_, ok = parse_image_token("#0")
	testing.expect(t, !ok)
}

@(test)
test_image_reg_register_resolve :: proc(t: ^testing.T) {
	image_reg_clear()
	defer image_reg_clear()

	n1 := image_reg_register("/tmp/a.jpg")
	n2 := image_reg_register("/tmp/b.jpg")
	testing.expect(t, n1 == 1)
	testing.expect(t, n2 == 2)

	ref, is_tok, err := image_reg_resolve_token("[Image #1]", context.allocator)
	defer delete(ref)
	testing.expect(t, is_tok && err == "" && ref == "/tmp/a.jpg")

	ref2, is_tok2, err2 := image_reg_resolve_token("#2", context.allocator)
	defer delete(ref2)
	testing.expect(t, is_tok2 && err2 == "" && ref2 == "/tmp/b.jpg")

	_, is_tok3, err3 := image_reg_resolve_token("[Image #9]", context.allocator)
	testing.expect(t, is_tok3 && err3 != "")
	testing.expect(t, strings.contains(err3, "Available"))
}

@(test)
test_resolve_image_ref_token_end_to_end :: proc(t: ^testing.T) {
	image_reg_clear()
	defer image_reg_clear()

	// minimal JPEG magic so compress path can work or fail gracefully
	dir := fmt.tprintf("/tmp/aether-imgreg-%d", os.get_pid())
	_ = os.remove_all(dir)
	_ = os.make_directory_all(dir)
	defer os.remove_all(dir)
	path := fmt.tprintf("%s/t.jpg", dir)
	// tiny jpeg-like header + padding
	payload := make([]byte, 64)
	payload[0] = 0xff
	payload[1] = 0xd8
	payload[2] = 0xff
	_ = os.write_entire_file(path, payload)

	n := image_reg_register(path)
	testing.expect(t, n >= 1)
	url, err := resolve_image_ref(fmt.tprintf("[Image #%d]", n), context.allocator)
	defer delete(url)
	// may succeed with compress or fail if magick missing on non-jpeg body — path token must resolve first
	// If compress fails we still verify token resolution via image_reg path by checking err is not "matches no"
	if err != "" {
		testing.expect(t, !strings.contains(err, "matches no registered"))
		testing.expect(t, !strings.contains(err, "does not match any"))
	} else {
		testing.expect(t, strings.has_prefix(url, "data:image/"))
	}
}
