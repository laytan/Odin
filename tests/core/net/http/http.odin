package test_core_net_http

import "core:mem"
import "core:strings"
import "core:testing"
import "core:time"

import http "core:http2"

@(test)
test_requestline_and_header_parse_validation :: proc(t: ^testing.T) {
	// Valid request lines.
	{
		rl, err := http.requestline_parse("GET /path?a=1 HTTP/1.1")
		testing.expect_value(t, err, http.Requestline_Error.None)
		testing.expect_value(t, rl.method, http.Method.Get)
		testing.expect_value(t, rl.target, "/path?a=1")
		testing.expect_value(t, rl.version, http.Version{1, 1})
	}
	{
		rl, err := http.requestline_parse("POST / HTTP/1.0")
		testing.expect_value(t, err, http.Requestline_Error.None)
		testing.expect_value(t, rl.method, http.Method.Post)
		testing.expect_value(t, rl.target, "/")
		testing.expect_value(t, rl.version, http.Version{1, 0})
	}
	{
		rl, err := http.requestline_parse("GET /a%23b HTTP/1.1")
		testing.expect_value(t, err, http.Requestline_Error.None)
		testing.expect_value(t, rl.target, "/a%23b")
	}

	// Reject malformed request-targets (empty, whitespace, bare CR/LF, NUL, CTL, DEL, raw '#').
	bad_targets := []string{
		"GET  HTTP/1.1",
		"GET /a\rb HTTP/1.1",
		"GET /a\nb HTTP/1.1",
		"GET /a\x00b HTTP/1.1",
		"GET /a\tb HTTP/1.1",
		"GET /a\x07b HTTP/1.1",
		"GET /a\x7fb HTTP/1.1",
		"GET /a#b HTTP/1.1",
	}
	for raw in bad_targets {
		_, err := http.requestline_parse(raw)
		testing.expectf(t, err == .Invalid_Target, "expected .Invalid_Target for %q, got %v", raw, err)
	}

	// Reject non-digit or malformed HTTP versions.
	bad_versions := []string{
		"GET / HTTP/1.\r",
		"GET / HTTP/a.1",
		"GET / HTTP/1.a",
		"GET / HTTP/1.",
		"GET / HTTP/1.12",
		"GET / HTTX/1.1",
		"GET / HTTP/1.1\n",
	}
	for raw in bad_versions {
		_, err := http.requestline_parse(raw)
		testing.expectf(t, err == .Invalid_Version_Format, "expected .Invalid_Version_Format for %q, got %v", raw, err)
	}

	// Valid headers: OWS (' ' and '\t') trimmed at edges, internal HTAB and obs-text permitted.
	valid_headers := [][3]string{
		{"Host: example.com",  "Host",    "example.com"},
		{"X-Tab: \ta\tb \t",   "X-Tab",   "a\tb"},
		{"X-Empty: \t ",       "X-Empty", ""},
		{"X-Obs: caf\xc3\xa9", "X-Obs",   "caf\xc3\xa9"},
	}
	for tc in valid_headers {
		k, v, ok := http.header_parse(tc[0])
		testing.expectf(t, ok, "expected header_parse(%q) to succeed", tc[0])
		testing.expect_value(t, k, tc[1])
		testing.expect_value(t, v, tc[2])
	}

	// Invalid header names & values (non-token key, spaces around colon, CTLs, NUL, bare CR/LF).
	bad_headers := []string{
		": val",
		" Host: localhost",
		"Host : localhost",
		"Bad Key: val",
		"Bad\rKey: val",
		"Bad\x00Key: val",
		"X-Test: a\rb",
		"X-Test: a\nb",
		"X-Test: \ra",
		"X-Test: a\n",
		"X-Test: a\x00b",
		"X-Test: a\x07b",
		"X-Test: a\vb",
		"X-Test: a\fb",
		"X-Test: a\x7fb",
	}
	for raw in bad_headers {
		_, _, ok := http.header_parse(raw)
		testing.expectf(t, !ok, "expected header_parse(%q) to fail", raw)
	}
}

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

	for empty in ([?]string{"", "&&&"}) {
		q := empty
		_, ok := http.query_iter(&q)
		testing.expectf(t, !ok, "expected %q to yield nothing", empty)
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
	for empty in ([?]string{"", "&&&"}) {
		m, ok := http.body_url_encoded(empty, context.temp_allocator)
		testing.expect(t, ok)
		testing.expect_value(t, len(m), 0)
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
		dups := make([dynamic]string, context.temp_allocator)
		for entry in http.query_iter(&q) {
			k, kok := http.url_encoded_decode(entry.key, context.temp_allocator)
			v, vok := http.url_encoded_decode(entry.value, context.temp_allocator)
			testing.expect(t, kok && vok)
			if k == "dup" {
				append(&dups, v)
			}
		}
		expect_slice(t, dups[:], []string{"first", "second"})
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
		test_tracking_init(&track)
		defer mem.tracking_allocator_destroy(&track)

		_, ok := http.body_url_encoded(input, mem.tracking_allocator(&track))
		testing.expectf(t, !ok, "expected failure for invalid form input %q", input)
		testing.expect_value(t, len(track.allocation_map), 0)
		testing.expect_value(t, len(track.bad_free_array), 0)
	}
}

@(test)
test_range_header_and_apply :: proc(t: ^testing.T) {
	// Valid Range header parsing.
	Valid_Parse_Case :: struct {
		header:     string,
		want_range: http.Range,
	}
	for tc in ([?]Valid_Parse_Case{
		{"bytes=0-9", {start = 0, end = 9}},
		{"BYTES=0-9", {start = 0, end = 9}},
		{"bytes=5-",  {start = 5}},
		{"bytes=-10", {end = -10}},
		{"bytes=-0",  {end = 0}},
	}) {
		req: http.Request
		req.headers.allocator = context.allocator
		defer http.headers_destroy(req.headers)
		http.headers_set(&req.headers, "Range", tc.header)

		r, ok := http.get_range_header(&req)
		testing.expectf(t, ok, "expected %q to parse", tc.header)
		testing.expect_value(t, r, tc.want_range)
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
		req: http.Request
		req.headers.allocator = context.allocator
		defer http.headers_destroy(req.headers)
		http.headers_set(&req.headers, "Range", bad)

		_, ok := http.get_range_header(&req)
		testing.expectf(t, !ok, "expected %q to be ignored/rejected", bad)
	}

	// apply_range_to_size valid cases.
	Apply_Case :: struct {
		r:       http.Range,
		size:    int,
		want_off: int,
		want_n:  int,
	}
	for tc in ([?]Apply_Case{
		{{start = 10, end = 19},  100, 10, 10},
		{{start = 90, end = 200}, 100, 90, 10},
		{{start = 90},            100, 90, 10},
		{{end = -10},             100, 90, 10},
		{{end = -200},            100,  0, 100},
	}) {
		off, n, ok := http.apply_range_to_size(tc.r, tc.size)
		testing.expect(t, ok)
		testing.expect_value(t, off, tc.want_off)
		testing.expect_value(t, n, tc.want_n)
	}

	// Unsatisfiable ranges.
	Unsat_Case :: struct {
		r:    http.Range,
		size: int,
	}
	for tc in ([?]Unsat_Case{
		{{start = 100, end = 110}, 100},
		{{start = 20, end = 10},   100},
		{{end = 0},                100},
		{{start = 0, end = 0},     0},
	}) {
		_, _, ok := http.apply_range_to_size(tc.r, tc.size)
		testing.expectf(t, !ok, "expected %v on size %d to be unsatisfiable", tc.r, tc.size)
	}
}

@(test)
test_mime_from_extension_and_content_type :: proc(t: ^testing.T) {
	Known_Case :: struct {
		input:        string,
		mime:         http.Mime_Type,
		content_type: string,
	}

	known := []Known_Case{
		{"notes.txt",      .Plain, "text/plain"},
		{"dir/index.html", .Html,  "text/html"},
		{"dir/page.htm",   .Html,  "text/html"},
		{"app.js",         .Js,    "application/javascript"},
		{"mod.mjs",        .Js,    "application/javascript"},
		{"style.css",      .Css,   "text/css"},
		{"data.csv",       .Csv,   "text/csv"},
		{"feed.xml",       .Xml,   "text/xml"},
		{"archive.zip",    .Zip,   "application/zip"},
		{"api.json",       .Json,  "application/json"},
		{"favicon.ico",    .Ico,   "application/vnd.microsoft.ico"},
		{"anim.gif",       .Gif,   "image/gif"},
		{"photo.jpeg",     .Jpeg,  "image/jpeg"},
		{"photo.jpg",      .Jpeg,  "image/jpeg"},
		{"img.png",        .Png,   "image/png"},
		{"icon.svg",       .Svg,   "image/svg+xml"},
		{"main.wasm",      .Wasm,  "application/wasm"},
		{"README.md",      .Md,    "text/markdown"},
		{"html",           .Html,  "text/html"},
		{".html",          .Html,  "text/html"},
	}

	for tc in known {
		mime, ok := http.mime_from_extension(tc.input)
		testing.expectf(t, ok, "expected mime_from_extension(%q) to succeed", tc.input)
		testing.expect_value(t, mime, tc.mime)
		testing.expect_value(t, http.mime_to_content_type(mime), tc.content_type)
	}

	testing.expect_value(t, http.mime_to_content_type(.Url_Encoded), "application/x-www-form-urlencoded")

	unknown := []string{"", "LICENSE", "dir/Makefile", "dir/html", ".gitignore", "file.bin", "archive.tar.gz"}
	for input in unknown {
		_, ok := http.mime_from_extension(input)
		testing.expectf(t, !ok, "expected mime_from_extension(%q) to return false", input)
	}
}

@(test)
test_set_cookie_and_heading_serialization :: proc(t: ^testing.T) {
	env: Test_Env
	test_env_init(&env, with_connections = true)
	defer test_env_destroy(&env)

	c := test_conn_push(t, &env)
	defer http._connection_destroy(c)

	c.req.line.version      = {1, 1}
	c.req.has_consumed_body = true
	c.res.status            = .OK

	expires, ok := time.datetime_to_time(2026, 11, 21, 15, 30, 0)
	testing.expect(t, ok, "expected valid datetime")

	http.set_cookie(&c.ctx, {
		name  = "session",
		value = "abc123",
	})
	http.set_cookie(&c.ctx, {
		name         = "prefs",
		value        = "dark\r\nmode",
		domain       = "example.com",
		path         = "/app",
		expires_gmt  = expires,
		max_age_secs = 3600,
		same_site    = .Lax,
		secure       = true,
		partitioned  = true,
		http_only    = true,
	})
	http.set_cookie(&c.ctx, {
		name      = "strict_tok",
		value     = "s",
		same_site = .Strict,
	})
	http.set_cookie(&c.ctx, {
		name      = "cross_tok",
		value     = "n",
		same_site = .None,
		secure    = true,
	})

	values := make([dynamic]string, context.allocator)
	defer delete(values)
	iter := http.headers_get_all_iterator(&c.res.headers, "set-cookie")
	for v in http.headers_get_all_iter(&iter) {
		append(&values, v)
	}

	testing.expect_value(t, len(values), 4)
	testing.expect_value(t, values[0], "session=abc123")
	testing.expect_value(t, values[1], "prefs=dark\r\nmode; Domain=example.com; Expires=Sat, 21 Nov 2026 15:30:00 GMT; Max-Age=3600; Path=/app; SameSite=Lax; Secure; Partitioned; HttpOnly")
	testing.expect_value(t, values[2], "strict_tok=s; SameSite=Strict")
	testing.expect_value(t, values[3], "cross_tok=n; SameSite=None; Secure")

	http.write_response_heading(&c.ctx)
	heading := string(c.res._buf[:])
	testing.expect(t, strings.contains(heading, "Set-Cookie: session=abc123\r\n"), "expected first Set-Cookie header line")
	testing.expect(t, strings.contains(heading, "Set-Cookie: prefs=dark  mode; Domain=example.com; Expires=Sat, 21 Nov 2026 15:30:00 GMT; Max-Age=3600; Path=/app; SameSite=Lax; Secure; Partitioned; HttpOnly\r\n"), "expected escaped second Set-Cookie header line")
	testing.expect(t, strings.contains(heading, "Set-Cookie: strict_tok=s; SameSite=Strict\r\n"), "expected strict Set-Cookie header line")
	testing.expect(t, strings.contains(heading, "Set-Cookie: cross_tok=n; SameSite=None; Secure\r\n"), "expected none Set-Cookie header line")
}

@(test)
test_date_write_and_parse :: proc(t: ^testing.T) {
	tm, dt_ok := time.datetime_to_time(2023, 2, 5, 9, 1, 10)
	testing.expect(t, dt_ok)

	buf: [http.DATE_LENGTH]byte
	http.date_write(buf[:], tm)
	formatted := string(buf[:])
	testing.expect_value(t, formatted, "Sun, 05 Feb 2023 09:01:10 GMT")

	parsed, parse_ok := http.date_parse(formatted)
	testing.expect(t, parse_ok)
	testing.expect_value(t, parsed, tm)

	// Deprecated -Month- delimiter is still accepted.
	dep, dep_ok := http.date_parse("Sun, 05-Feb-2023 09:01:10 GMT")
	testing.expect(t, dep_ok)
	testing.expect_value(t, dep, tm)

	for bad in ([?]string{"", "short", "Sun, 05 Xxx 2023 09:01:10 GMT", "Sun, 05 Feb 2023 09:01:10 UTC", "Sun, 99 Feb 2023 09:01:10 GMT"}) {
		_, ok := http.date_parse(bad)
		testing.expectf(t, !ok, "expected date_parse(%q) to fail", bad)
	}
}

@(test)
test_request_cookies :: proc(t: ^testing.T) {
	env: Test_Env
	test_env_init(&env)
	defer test_env_destroy(&env)

	c: http.Connection
	test_conn_init(t, &c, &env)
	defer test_conn_destroy(&c)

	test_req_set_headers(t, &c, {{"Cookie", "a=1; malformed; dup=first; b=two=2; dup=second"}})

	val_a, ok_a := http.request_cookie_get(&c.ctx, "a")
	testing.expect(t, ok_a)
	testing.expect_value(t, val_a, "1")

	val_b, ok_b := http.request_cookie_get(&c.ctx, "b")
	testing.expect(t, ok_b)
	testing.expect_value(t, val_b, "two=2")

	// Duplicate keys return the rightmost (last) value.
	val_dup, ok_dup := http.request_cookie_get(&c.ctx, "dup")
	testing.expect(t, ok_dup)
	testing.expect_value(t, val_dup, "second")

	_, ok_missing := http.request_cookie_get(&c.ctx, "missing")
	testing.expect(t, !ok_missing)

	all := http.request_cookies(&c.ctx, http.transaction_allocator(&c))
	testing.expect_value(t, len(all), 3)
	testing.expect_value(t, all["a"], "1")
	testing.expect_value(t, all["b"], "two=2")
	testing.expect_value(t, all["dup"], "second")
}
