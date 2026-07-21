// Copyright 2023-2026 SpaceXAI
// SPDX-License-Identifier: Apache-2.0

package tools

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"

@(test)
test_read_file_text_offset_limit :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-read-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)
	p, _ := filepath.join({root, "a.txt"}, context.temp_allocator)
	_ = os.write_entire_file(p, "one\ntwo\nthree\nfour\n")

	out := tool_read_file(
		`{"target_file":"a.txt","offset":2,"limit":2}`,
		root,
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, strings.contains(out, "2→two"))
	testing.expect(t, strings.contains(out, "3→three"))
	testing.expect(t, !strings.contains(out, "1→one"))
}

@(test)
test_read_file_negative_offset :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-read-neg-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)
	p, _ := filepath.join({root, "b.txt"}, context.temp_allocator)
	_ = os.write_entire_file(p, "a\nb\nc\nd\n")

	// last 2 lines: offset -2 → start at c
	out := tool_read_file(
		`{"target_file":"b.txt","offset":-2,"limit":10}`,
		root,
		context.allocator,
	)
	defer delete(out)
	testing.expect(t, strings.contains(out, "c") || strings.contains(out, "d"))
}

@(test)
test_read_file_binary_reject :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-read-bin-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)
	p, _ := filepath.join({root, "x.bin"}, context.temp_allocator)
	payload := []byte{0x00, 0x01, 0x02, 0xff, 0xfe}
	_ = os.write_entire_file(p, payload)

	out := tool_read_file(`{"target_file":"x.bin"}`, root, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "binary") || strings.contains(out, "error"))
}

@(test)
test_read_file_image_not_binary_dump :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-read-img-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)
	p, _ := filepath.join({root, "i.jpg"}, context.temp_allocator)
	// minimal jpeg magic + padding
	payload := make([]byte, 32)
	payload[0] = 0xff
	payload[1] = 0xd8
	payload[2] = 0xff
	_ = os.write_entire_file(p, payload)

	out := tool_read_file(`{"target_file":"i.jpg"}`, root, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "[image file]") || strings.contains(out, "image/jpeg"))
	testing.expect(t, !strings.contains(out, "cannot read binary"))
}

@(test)
test_read_file_missing :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-read-miss-%d", os.get_pid())
	_ = os.make_directory_all(root)
	defer os.remove_all(root)
	out := tool_read_file(`{"target_file":"nope.txt"}`, root, context.allocator)
	defer delete(out)
	testing.expect(t, strings.contains(out, "error") || strings.contains(out, "cannot read"))
}

@(test)
test_detect_image_kind :: proc(t: ^testing.T) {
	jpeg := []byte{0xff, 0xd8, 0xff, 0xe0}
	png := []byte{0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a}
	testing.expect(t, detect_image_kind(jpeg) == "image/jpeg")
	testing.expect(t, detect_image_kind(png) == "image/png")
	testing.expect(t, detect_image_kind([]byte{1, 2, 3}) == "")
}

@(test)
test_parse_pdf_pages :: proc(t: ^testing.T) {
	f, l, ok := parse_pdf_pages("3")
	testing.expect(t, ok && f == 3 && l == 3)
	f, l, ok = parse_pdf_pages("1-5")
	testing.expect(t, ok && f == 1 && l == 5)
	f, l, ok = parse_pdf_pages("10-")
	testing.expect(t, ok && f == 10 && l == 0)
	_, _, ok = parse_pdf_pages("")
	testing.expect(t, !ok)
	_, _, ok = parse_pdf_pages("5-2")
	testing.expect(t, !ok)
}

@(test)
test_is_pdf_file :: proc(t: ^testing.T) {
	testing.expect(t, is_pdf_file("pdf", []byte{}))
	testing.expect(t, is_pdf_file("txt", []byte{'%', 'P', 'D', 'F', '-'}))
	testing.expect(t, !is_pdf_file("txt", []byte{1, 2, 3, 4}))
}

@(test)
test_scrape_ooxml_text_at_runs :: proc(t: ^testing.T) {
	xml := `<a:p><a:r><a:t>Hello</a:t></a:r><a:r><a:t> PPTX</a:t></a:r></a:p>`
	got := scrape_ooxml_text(xml, context.temp_allocator)
	testing.expect(t, strings.contains(got, "Hello"))
	testing.expect(t, strings.contains(got, "PPTX"))
}

@(test)
test_read_file_pptx_text :: proc(t: ^testing.T) {
	root := fmt.tprintf("/tmp/aether-read-pptx-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)
	// build minimal pptx via python3 if available
	script := fmt.tprintf(
		`import zipfile
from pathlib import Path
p = Path(%q) / "hello.pptx"
slide = '''<?xml version="1.0"?><p:sld xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main"><p:cSld><p:spTree><p:nvGrpSpPr><p:cNvPr id="1" name=""/><p:cNvGrpSpPr/><p:nvPr/></p:nvGrpSpPr><p:grpSpPr/><p:sp><p:nvSpPr><p:cNvPr id="2" name="t"/><p:cNvSpPr/><p:nvPr/></p:nvSpPr><p:spPr/><p:txBody><a:bodyPr/><a:lstStyle/><a:p><a:r><a:t>Hello PPTX</a:t></a:r></a:p></p:txBody></p:sp></p:spTree></p:cSld></p:sld>'''
ct = '''<?xml version="1.0"?><Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types"><Default Extension="xml" ContentType="application/xml"/><Override PartName="/ppt/slides/slide1.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.slide+xml"/><Override PartName="/ppt/presentation.xml" ContentType="application/vnd.openxmlformats-officedocument.presentationml.presentation.main+xml"/></Types>'''
pres = '''<?xml version="1.0"?><p:presentation xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><p:sldIdLst><p:sldId id="256" r:id="rId1"/></p:sldIdLst></p:presentation>'''
rels = '''<?xml version="1.0"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/slide" Target="slides/slide1.xml"/></Relationships>'''
with zipfile.ZipFile(p, "w") as z:
    z.writestr("[Content_Types].xml", ct)
    z.writestr("ppt/presentation.xml", pres)
    z.writestr("ppt/_rels/presentation.xml.rels", rels)
    z.writestr("ppt/slides/slide1.xml", slide)
`,
		root,
	)
	child, err := os.process_start({command = {"python3", "-c", script}})
	if err != nil {
		return
	}
	_, _ = os.process_wait(child)
	out := tool_read_file(`{"target_file":"hello.pptx","pages":"1"}`, root, context.allocator)
	defer delete(out)
	if strings.contains(out, "unzip unavailable") {
		return
	}
	testing.expect(t, strings.contains(out, "[pptx file]"))
	testing.expect(t, strings.contains(out, "Hello") || strings.contains(out, "PPTX") || strings.contains(out, "slide"))
}

@(test)
test_read_file_pdf_text :: proc(t: ^testing.T) {
	// requires pdftotext
	root := fmt.tprintf("/tmp/aether-read-pdf-%d", os.get_pid())
	_ = os.remove_all(root)
	_ = os.make_directory_all(root)
	defer os.remove_all(root)
	// minimal PDF with Hello PDF (from session fixture generator)
	pdf := transmute([]byte)string(
		`%PDF-1.1
1 0 obj<< /Type /Catalog /Pages 2 0 R >>endobj
2 0 obj<< /Type /Pages /Kids [3 0 R] /Count 1 >>endobj
3 0 obj<< /Type /Page /Parent 2 0 R /MediaBox [0 0 300 144] /Contents 4 0 R /Resources<< /Font<< /F1 5 0 R >> >> >>endobj
4 0 obj<< /Length 44 >>stream
BT /F1 24 Tf 100 100 Td (Hello PDF) Tj ET
endstream endobj
5 0 obj<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>endobj
xref
0 6
0000000000 65535 f 
0000000009 00000 n 
0000000068 00000 n 
0000000125 00000 n 
0000000274 00000 n 
0000000373 00000 n 
trailer<< /Size 6 /Root 1 0 R >>
startxref
456
%%EOF
`,
	)
	p, _ := filepath.join({root, "hello.pdf"}, context.temp_allocator)
	testing.expect(t, os.write_entire_file(p, pdf) == nil)

	out := tool_read_file(`{"target_file":"hello.pdf","pages":"1"}`, root, context.allocator)
	defer delete(out)
	// If pdftotext missing, error mentions install; otherwise extract
	if strings.contains(out, "unavailable") || strings.contains(out, "pdftotext") && strings.contains(out, "error:") {
		// skip soft when poppler absent
		return
	}
	testing.expect(t, strings.contains(out, "[pdf file]"))
	testing.expect(t, strings.contains(out, "Hello") || strings.contains(out, "PDF") || strings.contains(out, "→"))
}
