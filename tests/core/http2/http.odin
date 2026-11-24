package tests_http2

import http "core:http2"
import "core:mem"
import "core:strings"
import "core:testing"

@(test)
test_query_parsing :: proc(t: ^testing.T) {
	testing.expect_value(t, http.query_of_url("/a?b=1"), "b=1")
	testing.expect_value(t, http.query_of_url("?a=1"), "a=1")
	testing.expect_value(t, http.query_of_url("/a?"), "")
	testing.expect_value(t, http.query_of_url("/a"), "")
	testing.expect_value(t, http.query_of_url(""), "")

	{
		q := "flag&a=1&b=2=3&&c=&=val&tail"
		expected := [?]http.Query_Entry{
			{"flag", ""},
			{"a", "1"},
			{"b", "2=3"},
			{"c", ""},
			{"", "val"},
			{"tail", ""},
		}
		i := 0
		for entry in http.query_iter(&q) {
			testing.expect(t, i < len(expected), "more query entries than expected")
			if i < len(expected) {
				testing.expect_value(t, entry, expected[i])
			}
			i += 1
		}
		testing.expect_value(t, i, len(expected))
	}

	{
		q := ""
		_, ok := http.query_iter(&q)
		testing.expect(t, !ok, "expected empty query string to yield nothing")
	}

	{
		q := "&&&"
		_, ok := http.query_iter(&q)
		testing.expect(t, !ok, "expected empty segments to yield nothing")
	}

	val, ok := http.query_get("/p?flag&x=42", "x")
	testing.expect(t, ok)
	testing.expect_value(t, val, "42")

	flag_val, flag_ok := http.query_get("/p?flag&x=42", "flag")
	testing.expect(t, flag_ok)
	testing.expect_value(t, flag_val, "")

	_, missing_ok := http.query_get("?a=1", "b")
	testing.expect(t, !missing_ok)
}

@(test)
test_body_url_encoded :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)

	// Empty and separator-only bodies yield empty maps.
	{
		m, ok := http.body_url_encoded("", context.temp_allocator)
		testing.expect(t, ok)
		testing.expect_value(t, len(m), 0)

		m2, ok2 := http.body_url_encoded("&&&", context.temp_allocator)
		testing.expect(t, ok2)
		testing.expect_value(t, len(m2), 0)
	}

	// WHATWG URL 5.1 decoding cases and edge cases.
	{
		body := "msg=hello+world%20%2B+%3D+%26&utf8=%C3%A9%F0%9F%98%80&bom=%EF%BB%BFhi&flag&empty=&=val&eq=1=2&dup=first&dup=second"
		m, ok := http.body_url_encoded(body, context.temp_allocator)
		testing.expect(t, ok)
		testing.expect_value(t, m["msg"], "hello world + = &")
		testing.expect_value(t, m["utf8"], "é😀")
		testing.expect_value(t, m["bom"], "\ufeffhi")
		testing.expect(t, "flag" in m)
		testing.expect_value(t, m["flag"], "")
		testing.expect(t, "empty" in m)
		testing.expect_value(t, m["empty"], "")
		testing.expect(t, "" in m)
		testing.expect_value(t, m[""], "val")
		testing.expect_value(t, m["eq"], "1=2")
		testing.expect_value(t, m["dup"], "second")

		// Duplicate keys are preserved via query_iter + url_encoded_decode.
		q := body
		dups: [dynamic]string
		dups.allocator = context.temp_allocator
		for entry in http.query_iter(&q) {
			k, kok := http.url_encoded_decode(entry.key, context.temp_allocator)
			v, vok := http.url_encoded_decode(entry.value, context.temp_allocator)
			testing.expect(t, kok && vok)
			if k == "dup" {
				append(&dups, v)
			}
		}
		testing.expect_value(t, len(dups), 2)
		if len(dups) == 2 {
			testing.expect_value(t, dups[0], "first")
			testing.expect_value(t, dups[1], "second")
		}
	}

	// Invalid percent escapes and invalid UTF-8 fail without leaking.
	invalid_inputs := [?]string{
		"a=%2",
		"a=%",
		"a=%ZZ",
		"a=%%",
		"a=%0x1",
		"a=%FF%FE",
		"a=\xff",
		"ok=%20&bad=%ZZ",
		"bad=%ZZ&ok=%20",
		"k%ZZ=ok",
		"ok=1&ok+2=hello+world&bad=%2",
	}
	for input in invalid_inputs {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.allocator)
		defer mem.tracking_allocator_destroy(&track)

		_, ok := http.body_url_encoded(input, mem.tracking_allocator(&track))
		testing.expectf(t, !ok, "expected failure for invalid form input %q", input)
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
	}
}

@(test)
test_range_header_and_apply :: proc(t: ^testing.T) {
	http.headers_init_hash_secret()

	make_req :: proc(range_val: string) -> http.Request {
		req: http.Request
		req.headers.allocator = context.allocator
		http.headers_set(&req.headers, "Range", range_val)
		return req
	}

	// Valid ranges.
	{
		req := make_req("bytes=0-9")
		defer http.headers_destroy(req.headers)
		r, ok := http.get_range_header(&req)
		testing.expect(t, ok)
		testing.expect_value(t, r.start, Maybe(int)(0))
		testing.expect_value(t, r.end, Maybe(int)(9))
	}
	{
		req := make_req("BYTES=0-9")
		defer http.headers_destroy(req.headers)
		r, ok := http.get_range_header(&req)
		testing.expect(t, ok)
		testing.expect_value(t, r.start, Maybe(int)(0))
		testing.expect_value(t, r.end, Maybe(int)(9))
	}
	{
		req := make_req("bytes=5-")
		defer http.headers_destroy(req.headers)
		r, ok := http.get_range_header(&req)
		testing.expect(t, ok)
		testing.expect_value(t, r.start, Maybe(int)(5))
		testing.expect_value(t, r.end, Maybe(int)(nil))
	}
	{
		req := make_req("bytes=-10")
		defer http.headers_destroy(req.headers)
		r, ok := http.get_range_header(&req)
		testing.expect(t, ok)
		testing.expect_value(t, r.start, Maybe(int)(nil))
		testing.expect_value(t, r.end, Maybe(int)(-10))
	}
	{
		req := make_req("bytes=-0")
		defer http.headers_destroy(req.headers)
		r, ok := http.get_range_header(&req)
		testing.expect(t, ok)
		_, _, apply_ok := http.apply_range_to_size(r, 100)
		testing.expect(t, !apply_ok, "bytes=-0 must be unsatisfiable")
	}

	// Ignored / invalid Range headers.
	for bad in ([?]string{
		"bytes=0-1, 2-3",
		"items=0-5",
		"bytes=-",
		"bytes=abc-def",
		"bytes=0-1-2",
		"bytes",
	}) {
		req := make_req(bad)
		defer http.headers_destroy(req.headers)
		_, ok := http.get_range_header(&req)
		testing.expectf(t, !ok, "expected %q to be ignored/rejected", bad)
	}

	// apply_range_to_size cases.
	{
		off, n, ok := http.apply_range_to_size({start = 10, end = 19}, 100)
		testing.expect(t, ok)
		testing.expect_value(t, off, 10)
		testing.expect_value(t, n, 10)
	}
	{
		off, n, ok := http.apply_range_to_size({start = 90, end = 200}, 100)
		testing.expect(t, ok)
		testing.expect_value(t, off, 90)
		testing.expect_value(t, n, 10)
	}
	{
		off, n, ok := http.apply_range_to_size({start = 90}, 100)
		testing.expect(t, ok)
		testing.expect_value(t, off, 90)
		testing.expect_value(t, n, 10)
	}
	{
		off, n, ok := http.apply_range_to_size({end = -10}, 100)
		testing.expect(t, ok)
		testing.expect_value(t, off, 90)
		testing.expect_value(t, n, 10)
	}
	{
		off, n, ok := http.apply_range_to_size({end = -200}, 100)
		testing.expect(t, ok)
		testing.expect_value(t, off, 0)
		testing.expect_value(t, n, 100)
	}
	for unsat in ([?]http.Range{
		{start = 100, end = 110},
		{start = 20, end = 10},
		{end = 0},
	}) {
		_, _, ok := http.apply_range_to_size(unsat, 100)
		testing.expectf(t, !ok, "expected %v to be unsatisfiable", unsat)
	}
	{
		_, _, ok := http.apply_range_to_size({start = 0, end = 0}, 0)
		testing.expect(t, !ok, "empty representation cannot satisfy a byte range")
	}
}
