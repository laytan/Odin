package test_core_net_http

import "core:fmt"
import "core:io"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:testing"

import http "core:http2"

@(test)
test_scanner_reset_frees_transaction_arena_when_empty :: proc(t: ^testing.T) {
	s: http.Server
	err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte)
	testing.expect_value(t, err, nil)
	defer virtual.arena_destroy(&s.temp_allocator_backing)

	thread := http.Server_Thread{s = &s, id = 1}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	c := http.Connection{
		transaction_arena = http.get_arena(nil),
		temp_arena        = http.get_arena(nil),
	}
	c.transaction_arena.c = &c
	c.temp_arena.c = &c

	used_after_first: uint
	for cycle in 0..<5 {
		tx_alloc := http.transaction_allocator(&c)
		tmp_alloc := http.temp_allocator(&c)

		tx_buf, tx_err := make([]byte, 2000, tx_alloc)
		testing.expect_value(t, tx_err, nil)
		testing.expect_value(t, len(tx_buf), 2000)

		tmp_buf, tmp_err := make([]byte, 2000, tmp_alloc)
		testing.expect_value(t, tmp_err, nil)
		testing.expect_value(t, len(tmp_buf), 2000)

		http.scanner_reset(&c.scanner, &c)
		http.temp_allocator_destroy(&c)

		testing.expect(t, c.transaction_arena.tail == nil, "expected transaction_arena to be empty after reset")
		testing.expect(t, c.temp_arena.tail == nil, "expected temp_arena to be empty after destroy")
		testing.expect(t, c.scanner.buf == nil, "expected empty scanner buf after reset")
		testing.expect_value(t, c.scanner.read_head, 0)
		testing.expect_value(t, c.scanner.write_head, 0)

		if cycle == 0 {
			used_after_first = s.temp_allocator_backing.total_used
		} else {
			testing.expect_value(t, s.temp_allocator_backing.total_used, used_after_first)
		}
	}
}

@(test)
test_scanner_reset_preserves_pipelined_bytes :: proc(t: ^testing.T) {
	Scan_Expectation :: struct {
		t:        ^testing.T,
		expected: string,
		called:   bool,
	}

	s: http.Server
	err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte)
	testing.expect_value(t, err, nil)
	defer virtual.arena_destroy(&s.temp_allocator_backing)

	thread := http.Server_Thread{s = &s, id = 1}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	c := http.Connection{
		transaction_arena = http.get_arena(nil),
		temp_arena        = http.get_arena(nil),
	}
	c.transaction_arena.c = &c
	c.temp_arena.c = &c
	c._vars.allocator = http.transaction_allocator(&c)
	c.scanner.c = &c
	c.scanner.allocator = &c.transaction_arena

	pipelined := "GET /first HTTP/1.1\r\nGET /second HTTP/1.1\r\n"
	buf, buf_err := make([]byte, http.MULTIPLIER, http.transaction_allocator(&c))
	testing.expect_value(t, buf_err, nil)
	c.scanner.buf = buf
	c.scanner.write_head = copy(buf, pipelined)

	exp := http.context_add(&c.ctx, Scan_Expectation{
		t        = t,
		expected = "GET /first HTTP/1.1",
	})
	http.scan_line(&c.scanner, proc(c: ^http.Connection, data: []byte) {
		exp := http.context_get(&c.ctx, Scan_Expectation)
		exp.called = true
		testing.expect_value(exp.t, string(data), exp.expected)
	})
	testing.expect(t, exp.called, "expected first pipelined request line callback to run")

	// Allocate extra blocks on both arenas to verify old blocks are reclaimed on reset.
	junk1, jerr1 := make([]byte, 4000, http.transaction_allocator(&c))
	testing.expect_value(t, jerr1, nil)
	testing.expect_value(t, len(junk1), 4000)

	junk2, jerr2 := make([]byte, 4000, http.temp_allocator(&c))
	testing.expect_value(t, jerr2, nil)
	testing.expect_value(t, len(junk2), 4000)

	testing.expect(t, c.transaction_arena.tail != nil && c.transaction_arena.tail.prev != nil, "expected chained blocks before reset")

	http.scanner_reset(&c.scanner, &c)
	http.temp_allocator_destroy(&c)
	c.ctx = {}
	c._vars.allocator = http.transaction_allocator(&c)

	testing.expect(t, c.transaction_arena.tail != nil, "expected preserved scanner block in transaction_arena")
	testing.expect(t, c.transaction_arena.tail.prev == nil, "expected previous transaction blocks to be freed")
	testing.expect(t, c.temp_arena.tail == nil, "expected temp_arena to be destroyed")
	testing.expect_value(t, string(c.scanner.buf[c.scanner.read_head:c.scanner.write_head]), "GET /second HTTP/1.1\r\n")

	exp2 := http.context_add(&c.ctx, Scan_Expectation{
		t        = t,
		expected = "GET /second HTTP/1.1",
	})
	http.scan_line(&c.scanner, proc(c: ^http.Connection, data: []byte) {
		exp := http.context_get(&c.ctx, Scan_Expectation)
		exp.called = true
		testing.expect_value(exp.t, string(data), exp.expected)
	})
	testing.expect(t, exp2.called, "expected second pipelined request line callback to run")

	http.scanner_reset(&c.scanner, &c)
	testing.expect(t, c.transaction_arena.tail == nil, "expected empty scanner reset to free preserved block")
}

@(test)
test_header_allowed_trailer :: proc(t: ^testing.T) {
	testing.expect(t, http.header_allowed_trailer("X-Checksum"), "expected custom trailer to be allowed")
	testing.expect(t, http.header_allowed_trailer("x-checksum"), "expected lowercase custom trailer to be allowed")
	testing.expect(t, http.header_allowed_trailer("Server-Timing"), "expected Server-Timing trailer to be allowed")

	forbidden := [?]string{
		"Transfer-Encoding",
		"transfer-encoding",
		"Content-Length",
		"HOST",
		"If-Match",
		"If-None-Match",
		"If-Modified-Since",
		"If-Unmodified-Since",
		"If-Range",
		"WWW-Authenticate",
		"Authorization",
		"Proxy-Authenticate",
		"Proxy-Authorization",
		"Cookie",
		"Set-Cookie",
		"Age",
		"Cache-Control",
		"Expires",
		"Date",
		"Location",
		"Retry-After",
		"Vary",
		"Warning",
		"Content-Encoding",
		"Content-Type",
		"Trailer",
		"Content-Range",
	}
	for h in forbidden {
		testing.expectf(t, !http.header_allowed_trailer(h), "expected forbidden trailer %q to be rejected", h)
	}
}

Chunked_Body_Expectation :: struct {
	t:           ^testing.T,
	buf:         [64]byte,
	len:         int,
	done_called: bool,
}

@(test)
test_chunked_body_trailers_filtering :: proc(t: ^testing.T) {
	s: http.Server
	err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte)
	testing.expect_value(t, err, nil)
	defer virtual.arena_destroy(&s.temp_allocator_backing)

	thread := http.Server_Thread{s = &s, id = 1}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	c := http.Connection{
		transaction_arena = http.get_arena(nil),
		temp_arena        = http.get_arena(nil),
	}
	c.transaction_arena.c = &c
	c.temp_arena.c = &c
	defer http.temp_allocator_destroy(&c)
	defer http.transaction_allocator_destroy(&c)

	tx_alloc := http.transaction_allocator(&c)
	c._vars.allocator = tx_alloc
	c.req.headers.allocator = tx_alloc
	c.scanner.c = &c
	c.scanner.allocator = &c.transaction_arena
	http.progression_init(&c.req.progress, {})

	testing.expect_value(t, http.headers_set(&c.req.headers, "Host", "localhost"), nil)
	testing.expect_value(t, http.headers_set(&c.req.headers, "Transfer-Encoding", "chunked"), nil)
	testing.expect_value(t, http.headers_set(&c.req.headers, "Trailer", "X-Checksum"), nil)
	http._headers_set_readonly(&c.req.headers)

	payload := "5;ext=1\r\nhello\r\n0\r\nX-Checksum: abc123\r\nContent-Length: 999\r\n\r\n"
	buf, buf_err := make([]byte, max(http.MULTIPLIER, len(payload)), tx_alloc)
	testing.expect_value(t, buf_err, nil)
	c.scanner.buf = buf
	c.scanner.write_head = copy(buf, payload)

	exp := http.context_add(&c.ctx, Chunked_Body_Expectation{
		t = t,
	})

	http.body(&c.req, proc(req: ^http.Request, body: []byte, is_partial: bool) {
		exp := http.context_get(http.context_of_request(req), Chunked_Body_Expectation)
		if len(body) > 0 {
			n := copy(exp.buf[exp.len:], body)
			testing.expect_value(exp.t, n, len(body))
			exp.len += n
		}
		if !is_partial {
			exp.done_called = true
		}
	})

	testing.expect(t, exp.done_called, "expected chunked body callback to complete with is_partial == false")
	testing.expect_value(t, string(exp.buf[:exp.len]), "hello")

	checksum, ok := http.headers_get(c.req.headers, "X-Checksum")
	testing.expect(t, ok, "expected allowed trailer X-Checksum to be stored in request headers")
	testing.expect_value(t, checksum, "abc123")

	testing.expect(t, !http.headers_has(c.req.headers, "Content-Length"), "expected forbidden trailer Content-Length to be ignored")
	testing.expect(t, !http.headers_has(c.req.headers, "Trailer"), "expected Trailer header to be removed after trailers are processed")
	testing.expect(t, !http.headers_has(c.req.headers, "Transfer-Encoding"), "expected Transfer-Encoding chunked header to be removed")
}

@(test)
test_scan_temp_line_uses_temp_arena :: proc(t: ^testing.T) {
	Temp_Line_Expectation :: struct {
		t:        ^testing.T,
		expected: string,
		called:   bool,
	}

	s: http.Server
	err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte)
	testing.expect_value(t, err, nil)
	defer virtual.arena_destroy(&s.temp_allocator_backing)

	thread := http.Server_Thread{s = &s, id = 1}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	c := http.Connection{
		transaction_arena = http.get_arena(nil),
		temp_arena        = http.get_arena(nil),
	}
	c.transaction_arena.c = &c
	c.temp_arena.c = &c
	defer http.temp_allocator_destroy(&c)
	defer http.transaction_allocator_destroy(&c)

	tx_alloc := http.transaction_allocator(&c)
	c._vars.allocator = tx_alloc
	c.scanner.c = &c
	c.scanner.allocator = &c.transaction_arena

	payload := "hello temp\r\n"
	buf, buf_err := make([]byte, max(http.MULTIPLIER, len(payload)), tx_alloc)
	testing.expect_value(t, buf_err, nil)
	c.scanner.buf = buf
	c.scanner.write_head = copy(buf, payload)

	testing.expect(t, c.temp_arena.tail == nil, "expected temp_arena to start empty")

	exp := http.context_add(&c.ctx, Temp_Line_Expectation{
		t        = t,
		expected = "hello temp",
	})

	http.scan_temp_line(&c.scanner, proc(c: ^http.Connection, data: []byte) {
		exp := http.context_get(&c.ctx, Temp_Line_Expectation)
		exp.called = true
		testing.expect_value(exp.t, string(data), exp.expected)
		testing.expect_value(exp.t, c.scanner.allocator, &c.temp_arena)
		testing.expect(exp.t, c.temp_arena.tail != nil, "expected scan_temp_line to allocate scanner buffer in temp_arena")
	})

	testing.expect(t, exp.called, "expected scan_temp_line callback to run")
	testing.expect_value(t, c.scanner.allocator, &c.temp_arena)
	testing.expect(t, c.temp_arena.tail != nil, "expected temp_arena to hold reallocated scanner buffer")
}

@(test)
test_body_parser_stream_and_iterator :: proc(t: ^testing.T) {
	Stream_Expectation :: struct {
		t:      ^testing.T,
		called: bool,
	}

	s: http.Server
	err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte)
	testing.expect_value(t, err, nil)
	defer virtual.arena_destroy(&s.temp_allocator_backing)

	thread := http.Server_Thread{s = &s, id = 1}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	c := http.Connection{
		transaction_arena = http.get_arena(nil),
		temp_arena        = http.get_arena(nil),
	}
	c.transaction_arena.c = &c
	c.temp_arena.c = &c
	defer http.temp_allocator_destroy(&c)
	defer http.transaction_allocator_destroy(&c)

	tx_alloc := http.transaction_allocator(&c)
	c._vars.allocator = tx_alloc
	c.req.headers.allocator = tx_alloc
	c.scanner.c = &c
	c.scanner.allocator = &c.transaction_arena
	http.progression_init(&c.req.progress, {})

	testing.expect_value(t, http.headers_set(&c.req.headers, "Host", "localhost"), nil)
	testing.expect_value(t, http.headers_set(&c.req.headers, "Transfer-Encoding", "chunked"), nil)
	http._headers_set_readonly(&c.req.headers)

	payload := "5\r\nhello\r\n2\r\n, \r\n6\r\nworld!\r\n0\r\n\r\n"
	buf, buf_err := make([]byte, max(http.MULTIPLIER, len(payload)), tx_alloc)
	testing.expect_value(t, buf_err, nil)
	c.scanner.buf = buf
	c.scanner.write_head = copy(buf, payload)

	exp := http.context_add(&c.ctx, Stream_Expectation{
		t = t,
	})

	next := http.handler(proc(ctx: ^http.Ctx) {
		exp := http.context_get(ctx, Stream_Expectation)
		exp.called = true
		t := exp.t

		// Verify body_parser_iterator across all 3 parts.
		expected_parts := [?]string{"hello", ", ", "world!"}
		it := http.body_parser_iterator(ctx)
		part_count := 0
		for part, idx in http.body_parser_iter(&it) {
			testing.expect(t, idx < len(expected_parts), "unexpected extra body part")
			testing.expect_value(t, string(part), expected_parts[idx])
			part_count += 1
		}
		testing.expect_value(t, part_count, len(expected_parts))

		bps: http.Body_Parser_Stream
		http.body_parser_stream_init(&bps, ctx)
		stream := http.body_parser_stream(&bps)

		// Verify total size.
		sz, sz_err := io.size(stream)
		testing.expect_value(t, sz_err, nil)
		testing.expect_value(t, sz, i64(13))

		// Verify single full read does not duplicate first part, followed by .EOF.
		full: [32]byte
		n, r_err := io.read(stream, full[:])
		testing.expect_value(t, r_err, nil)
		testing.expect_value(t, string(full[:n]), "hello, world!")

		eof_n, eof_err := io.read(stream, full[:])
		testing.expect_value(t, eof_err, io.Error.EOF)
		testing.expect_value(t, eof_n, 0)

		// Seek back to start and read in 4-byte chunks across part boundaries.
		pos, seek_err := io.seek(stream, 0, .Start)
		testing.expect_value(t, seek_err, nil)
		testing.expect_value(t, pos, i64(0))

		chunked: [32]byte
		total := 0
		for {
			cn, cerr := io.read(stream, chunked[total:min(len(chunked), total+4)])
			if cerr == .EOF {
				break
			}
			testing.expect_value(t, cerr, nil)
			testing.expect(t, cn > 0, "expected positive byte count before EOF")
			total += cn
		}
		testing.expect_value(t, string(chunked[:total]), "hello, world!")

		// Verify io.read_at on an exact part boundary (off = 5 starts at ", ").
		at_buf: [8]byte
		at_n, at_err := io.read_at(stream, at_buf[:], 5)
		testing.expect_value(t, at_err, nil)
		testing.expect_value(t, string(at_buf[:at_n]), ", world!")

		// Verify io.read_at at EOF and out-of-range offsets.
		at_eof_n, at_eof_err := io.read_at(stream, at_buf[:], 13)
		testing.expect_value(t, at_eof_err, io.Error.EOF)
		testing.expect_value(t, at_eof_n, 0)

		bad_neg_n, bad_neg_err := io.read_at(stream, at_buf[:], -1)
		testing.expect_value(t, bad_neg_err, io.Error.Invalid_Offset)
		testing.expect_value(t, bad_neg_n, 0)

		bad_oob_n, bad_oob_err := io.read_at(stream, at_buf[:], 14)
		testing.expect_value(t, bad_oob_err, io.Error.Invalid_Offset)
		testing.expect_value(t, bad_oob_n, 0)
	})

	parser := http.body_parser(&next)
	parser.handle(&parser, &c.ctx)
	testing.expect(t, exp.called, "expected body_parser to invoke next handler")

	// Verify empty body stream behavior (off=0 -> .EOF, off>0 -> .Invalid_Offset).
	empty_c := http.Connection{
		transaction_arena = http.get_arena(nil),
		temp_arena        = http.get_arena(nil),
	}
	empty_c.transaction_arena.c = &empty_c
	empty_c.temp_arena.c = &empty_c
	defer http.temp_allocator_destroy(&empty_c)
	defer http.transaction_allocator_destroy(&empty_c)

	empty_c._vars.allocator = http.transaction_allocator(&empty_c)
	http.context_add(&empty_c.ctx, http.Body_Parser_State{})

	empty_bps: http.Body_Parser_Stream
	http.body_parser_stream_init(&empty_bps, &empty_c.ctx)
	empty_stream := http.body_parser_stream(&empty_bps)

	empty_buf: [8]byte
	empty_n, empty_err := io.read(empty_stream, empty_buf[:])
	testing.expect_value(t, empty_err, io.Error.EOF)
	testing.expect_value(t, empty_n, 0)

	empty_oob_n, empty_oob_err := io.read_at(empty_stream, empty_buf[:], 1)
	testing.expect_value(t, empty_oob_err, io.Error.Invalid_Offset)
	testing.expect_value(t, empty_oob_n, 0)
}

@(test)
test_request_size_and_header_count_limits :: proc(t: ^testing.T) {
	s := http.make_server({})
	err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte)
	testing.expect_value(t, err, nil)
	defer virtual.arena_destroy(&s.temp_allocator_backing)

	thread := http.Server_Thread{s = &s, id = 1}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	setup_conn :: proc(t: ^testing.T, c: ^http.Connection, payload: string, req_max: int) {
		c^ = http.Connection{
			transaction_arena = http.get_arena(nil),
			temp_arena        = http.get_arena(nil),
		}
		c.transaction_arena.c = c
		c.temp_arena.c = c

		tx_alloc := http.transaction_allocator(c)
		c._vars.allocator = tx_alloc
		c.req.headers.allocator = tx_alloc
		c.res.headers.allocator = tx_alloc
		c.res._buf.allocator = tx_alloc
		c.scanner.c = c
		c.scanner.allocator = &c.transaction_arena

		// Prevent invalid_request -> respond -> _do_send from calling nbio without an event loop.
		c.res.progress.max = 0
		c.res._sends = 1
		c.req.progress.max = req_max

		if len(payload) > 0 {
			buf, buf_err := make([]byte, max(http.MULTIPLIER, len(payload)), tx_alloc)
			testing.expect_value(t, buf_err, nil)
			c.scanner.buf = buf
			c.scanner.write_head = copy(buf, payload)
		}
	}

	cleanup_conn :: proc(c: ^http.Connection) {
		http.temp_allocator_destroy(c)
		http.transaction_allocator_destroy(c)
	}

	// 1. Exhausted request quota before request-line completes -> 414 URI Too Long.
	{
		c: http.Connection
		setup_conn(t, &c, "GET /too-long-uri-without-crlf", 0)
		defer cleanup_conn(&c)

		http.scan_line(&c.scanner, http.on_rline1)
		testing.expect_value(t, c.res.status, http.Status.URI_Too_Long)
		testing.expect(t, c.res._state == .Error)
	}

	// 2. Exhausted request quota after request-line during header scanning -> 431 Request Header Fields Too Large.
	{
		c: http.Connection
		setup_conn(t, &c, "GET / HTTP/1.1\r\nHost: localhost\r\nX-Big: incomplete", 0)
		defer cleanup_conn(&c)

		http.scan_line(&c.scanner, http.on_rline1)
		testing.expect_value(t, c.res.status, http.Status.Request_Header_Fields_Too_Large)
		testing.expect(t, c.res._state == .Error)
	}

	// 3. Header count exceeding max_headers (default 128) -> 431 Request Header Fields Too Large.
	{
		c: http.Connection
		setup_conn(t, &c, "", s.opts.request_quota.max_size)
		defer cleanup_conn(&c)

		tx_alloc := http.transaction_allocator(&c)
		b := strings.builder_make(tx_alloc)
		strings.write_string(&b, "GET / HTTP/1.1\r\nHost: localhost\r\n")
		for i in 0 ..< s.opts.max_headers {
			fmt.sbprintf(&b, "X-H%d: 1\r\n", i)
		}
		strings.write_string(&b, "\r\n")
		payload := strings.to_string(b)

		buf, buf_err := make([]byte, max(http.MULTIPLIER, len(payload)), tx_alloc)
		testing.expect_value(t, buf_err, nil)
		c.scanner.buf = buf
		c.scanner.write_head = copy(buf, payload)

		http.scan_line(&c.scanner, http.on_rline1)
		testing.expect_value(t, c.res.status, http.Status.Request_Header_Fields_Too_Large)
		testing.expect(t, c.res._state == .Error)
		testing.expect_value(t, http.headers_len(c.req.headers), s.opts.max_headers)
	}

	// 4a. Content-Length exceeding body_quota.max_size -> 413 Payload Too Large.
	{
		c: http.Connection
		setup_conn(t, &c, "", 10 * mem.Megabyte)
		defer cleanup_conn(&c)

		c.res._state = .Handling
		testing.expect_value(t, http.headers_set(&c.req.headers, "Host", "localhost"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Content-Length", "10485761"), nil)
		http._headers_set_readonly(&c.req.headers)

		http.body(&c.req, proc(req: ^http.Request, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res.status, http.Status.Payload_Too_Large)
		testing.expect(t, c.res._state == .Error)
	}

	// 4b. Exhausted body quota during body scanning -> 413 Payload Too Large.
	{
		c: http.Connection
		setup_conn(t, &c, "5\r\nhe", 0)
		defer cleanup_conn(&c)

		c.res._state = .Handling
		testing.expect_value(t, http.headers_set(&c.req.headers, "Host", "localhost"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Transfer-Encoding", "chunked"), nil)
		http._headers_set_readonly(&c.req.headers)

		http.body(&c.req, proc(req: ^http.Request, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res.status, http.Status.Payload_Too_Large)
		testing.expect(t, c.res._state == .Error)
	}
}

@(test)
test_validate_headers_smuggling_defenses :: proc(t: ^testing.T) {
	s := http.make_server({})
	err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte)
	testing.expect_value(t, err, nil)
	defer virtual.arena_destroy(&s.temp_allocator_backing)

	thread := http.Server_Thread{s = &s, id = 1}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	Header_Pair :: struct {
		k, v: string,
	}
	Validate_Case :: struct {
		desc:    string,
		version: http.Version,
		headers: []Header_Pair,
		ok:      bool,
	}

	cases := []Validate_Case{
		{
			desc    = "valid HTTP/1.1 with Content-Length",
			version = {1, 1},
			headers = {{"Host", "localhost"}, {"Content-Length", "42"}},
			ok      = true,
		},
		{
			desc    = "valid HTTP/1.1 with single case-insensitive chunked TE",
			version = {1, 1},
			headers = {{"Host", "localhost"}, {"Transfer-Encoding", "CHUNKED"}},
			ok      = true,
		},
		{
			desc    = "reject missing Host",
			version = {1, 1},
			headers = {{"Content-Length", "0"}},
			ok      = false,
		},
		{
			desc    = "reject duplicate Host",
			version = {1, 1},
			headers = {{"Host", "a"}, {"Host", "b"}},
			ok      = false,
		},
		{
			desc    = "reject both Transfer-Encoding and Content-Length",
			version = {1, 1},
			headers = {{"Host", "localhost"}, {"Transfer-Encoding", "chunked"}, {"Content-Length", "5"}},
			ok      = false,
		},
		{
			desc    = "reject Content-Length before Transfer-Encoding",
			version = {1, 1},
			headers = {{"Host", "localhost"}, {"Content-Length", "0"}, {"Transfer-Encoding", "chunked"}},
			ok      = false,
		},
		{
			desc    = "reject duplicate Transfer-Encoding headers (TE.TE smuggling)",
			version = {1, 1},
			headers = {{"Host", "localhost"}, {"Transfer-Encoding", "chunked"}, {"Transfer-Encoding", "chunked"}},
			ok      = false,
		},
		{
			desc    = "reject stacked gzip, chunked Transfer-Encoding",
			version = {1, 1},
			headers = {{"Host", "localhost"}, {"Transfer-Encoding", "gzip"}, {"Transfer-Encoding", "chunked"}},
			ok      = false,
		},
		{
			desc    = "reject combined single-line gzip, chunked Transfer-Encoding",
			version = {1, 1},
			headers = {{"Host", "localhost"}, {"Transfer-Encoding", "gzip, chunked"}},
			ok      = false,
		},
		{
			desc    = "reject non-chunked Transfer-Encoding",
			version = {1, 1},
			headers = {{"Host", "localhost"}, {"Transfer-Encoding", "gzip"}},
			ok      = false,
		},
		{
			desc    = "reject Transfer-Encoding on HTTP/1.0",
			version = {1, 0},
			headers = {{"Host", "localhost"}, {"Transfer-Encoding", "chunked"}},
			ok      = false,
		},
		{
			desc    = "reject duplicate Content-Length headers (even identical)",
			version = {1, 1},
			headers = {{"Host", "localhost"}, {"Content-Length", "5"}, {"Content-Length", "5"}},
			ok      = false,
		},
		{
			desc    = "reject invalid Content-Length values",
			version = {1, 1},
			headers = {{"Host", "localhost"}, {"Content-Length", ""}},
			ok      = false,
		},
		{
			desc    = "reject negative Content-Length",
			version = {1, 1},
			headers = {{"Host", "localhost"}, {"Content-Length", "-5"}},
			ok      = false,
		},
		{
			desc    = "reject non-numeric Content-Length",
			version = {1, 1},
			headers = {{"Host", "localhost"}, {"Content-Length", "5a"}},
			ok      = false,
		},
	}

	for tc in cases {
		c := http.Connection{
			transaction_arena = http.get_arena(nil),
			temp_arena        = http.get_arena(nil),
		}
		c.transaction_arena.c = &c
		c.temp_arena.c = &c
		defer http.temp_allocator_destroy(&c)
		defer http.transaction_allocator_destroy(&c)

		tx_alloc := http.transaction_allocator(&c)
		c.req.headers.allocator = tx_alloc
		c.req.line.version = tc.version
		for pair in tc.headers {
			testing.expect_value(t, http.headers_add(&c.req.headers, pair.k, pair.v), nil)
		}

		got := http.validate_headers(&c)
		testing.expectf(t, got == tc.ok, "%s: expected validate_headers=%v, got %v", tc.desc, tc.ok, got)
	}

	// Verify chunk-size line with CTL byte is rejected with 400 Bad Request.
	{
		c := http.Connection{
			transaction_arena = http.get_arena(nil),
			temp_arena        = http.get_arena(nil),
		}
		c.transaction_arena.c = &c
		c.temp_arena.c = &c
		defer http.temp_allocator_destroy(&c)
		defer http.transaction_allocator_destroy(&c)

		tx_alloc := http.transaction_allocator(&c)
		c._vars.allocator = tx_alloc
		c.req.headers.allocator = tx_alloc
		c.res.headers.allocator = tx_alloc
		c.res._buf.allocator = tx_alloc
		c.scanner.c = &c
		c.scanner.allocator = &c.transaction_arena
		c.res._state = .Handling
		c.res.progress.max = 0
		c.res._sends = 1

		c.req.line.version = {1, 1}
		testing.expect_value(t, http.headers_set(&c.req.headers, "Host", "localhost"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Transfer-Encoding", "CHUNKED"), nil)
		http._headers_set_readonly(&c.req.headers)

		payload := "5;ext=\x07\r\nhello\r\n0\r\n\r\n"
		buf, buf_err := make([]byte, max(http.MULTIPLIER, len(payload)), tx_alloc)
		testing.expect_value(t, buf_err, nil)
		c.scanner.buf = buf
		c.scanner.write_head = copy(buf, payload)

		http.body(&c.req, proc(req: ^http.Request, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res.status, http.Status.Bad_Request)
		testing.expect(t, c.res._state == .Error)
	}
}

@(test)
test_unconsumed_and_inflight_body_keepalive :: proc(t: ^testing.T) {
	Test_State :: struct {
		t:              ^testing.T,
		mode:           enum {
			Unconsumed,
			Consumed_Keepalive,
			Partial_Cb_Respond,
		},
		req_count:      int,
		must_close_1:   bool,
		res1_had_close: bool,
		second_target:  string,
		body_cb_calls:  int,
		body_received:  [64]byte,
		body_len:       int,
		body_finished:  bool,
		finish:         proc(c: ^http.Connection, pending_sends := 0),
	}

	Test_Env :: struct {
		s:      http.Server,
		thread: http.Server_Thread,
		prev:   ^http.Server_Thread,
		c:      http.Connection,
	}

	finish_test_response :: proc(c: ^http.Connection, pending_sends := 0) {
		http.write_response_heading(&c.res)
		c.res._state = .Sending
		c.res._sends = pending_sends
		http.respond(&c.res)
	}

	test_handler := http.Handler{
		handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
			state := (^Test_State)(h.user_data)
			c := http.connection_of_context(ctx)
			state.req_count += 1

			if state.req_count == 2 {
				state.second_target = strings.clone(ctx.req.line.target, context.allocator)
				finish_test_response(c, pending_sends = 1)
				return
			}

			switch state.mode {
			case .Unconsumed:
				state.must_close_1 = http.response_must_close(c)
				finish_test_response(c, pending_sends = 1)
				state.res1_had_close = strings.contains(string(c.res._buf[:]), "Connection: close\r\n")

			case .Consumed_Keepalive:
				state.finish = finish_test_response
				http.context_add(ctx, state)
				http.body(&c.req, proc(req: ^http.Request, data: []byte, is_partial: bool) {
					ctx := http.context_of_request(req)
					state := http.context_get(ctx, ^Test_State)^
					c := http.connection_of_request(req)

					state.body_cb_calls += 1
					if len(data) > 0 {
						n := copy(state.body_received[state.body_len:], data)
						state.body_len += n
					}
					if !is_partial {
						state.body_finished = true
						state.must_close_1 = http.response_must_close(c)
						state.finish(c, 0)
					}
				})

			case .Partial_Cb_Respond:
				state.finish = finish_test_response
				http.context_add(ctx, state)
				http.body(&c.req, proc(req: ^http.Request, data: []byte, is_partial: bool) {
					ctx := http.context_of_request(req)
					state := http.context_get(ctx, ^Test_State)^
					c := http.connection_of_request(req)

					state.body_cb_calls += 1
					if len(data) > 0 {
						n := copy(state.body_received[state.body_len:], data)
						state.body_len += n
					}
					if is_partial {
						state.must_close_1 = http.response_must_close(c)
						state.finish(c, 1)
					}
				})
			}
		},
	}

	run_payload :: proc(t: ^testing.T, state: ^Test_State, test_handler: ^http.Handler, payload: string, env: ^Test_Env) {
		test_handler.user_data = state
		env.s = http.make_server({handler = test_handler^})
		err := virtual.arena_init_growing(&env.s.temp_allocator_backing, 64 * mem.Megabyte)
		testing.expect_value(t, err, nil)

		env.thread = http.Server_Thread{s = &env.s, id = 1}
		env.prev = http.td
		http.td = &env.thread

		env.c = http.Connection{
			transaction_arena = http.get_arena(nil),
			temp_arena        = http.get_arena(nil),
		}
		env.c.transaction_arena.c = &env.c
		env.c.temp_arena.c = &env.c

		tx_alloc := http.transaction_allocator(&env.c)
		buf, buf_err := make([]byte, max(http.MULTIPLIER, len(payload)), tx_alloc)
		testing.expect_value(t, buf_err, nil)
		env.c.scanner.buf = buf
		env.c.scanner.write_head = copy(buf, payload)
		env.c.scanner.allocator = &env.c.transaction_arena

		http._serve_connection(&env.c)
	}

	cleanup_env :: proc(env: ^Test_Env) {
		http.temp_allocator_destroy(&env.c)
		http.transaction_allocator_destroy(&env.c)
		http._server_thread_free_arenas_destroy(&env.thread)
		http.td = env.prev
		virtual.arena_destroy(&env.s.temp_allocator_backing)
	}

	// 1. Unconsumed Content-Length body requires closing, writes Connection: close, and schedules no body scan.
	{
		state := Test_State{t = t, mode = .Unconsumed}
		env: Test_Env
		run_payload(t, &state, &test_handler,
			"POST /unconsumed-cl HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello",
			&env,
		)
		defer cleanup_env(&env)

		testing.expect_value(t, state.req_count, 1)
		testing.expect(t, state.must_close_1, "expected unconsumed Content-Length body to require closing")
		testing.expect(t, state.res1_had_close, "expected Connection: close header for unconsumed Content-Length")
		testing.expect(t, env.c.scanner.scan.callback == nil, "expected no body scan scheduled")
	}

	// 2. Unconsumed Transfer-Encoding: chunked body requires closing, writes Connection: close, and schedules no body scan.
	{
		state := Test_State{t = t, mode = .Unconsumed}
		env: Test_Env
		run_payload(t, &state, &test_handler,
			"POST /unconsumed-chunked HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n",
			&env,
		)
		defer cleanup_env(&env)

		testing.expect_value(t, state.req_count, 1)
		testing.expect(t, state.must_close_1, "expected unconsumed chunked body to require closing")
		testing.expect(t, state.res1_had_close, "expected Connection: close header for unconsumed chunked body")
		testing.expect(t, env.c.scanner.scan.callback == nil, "expected no body scan scheduled")
	}

	// 3. Fully consumed Content-Length body stays keep-alive and serves the pipelined next request.
	{
		state := Test_State{t = t, mode = .Consumed_Keepalive}
		defer delete(state.second_target)
		env: Test_Env
		run_payload(t, &state, &test_handler,
			"POST /consumed-cl HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello" +
			"GET /after-consumed-cl HTTP/1.1\r\nHost: localhost\r\n\r\n",
			&env,
		)
		defer cleanup_env(&env)

		testing.expect(t, state.body_finished, "expected consumed Content-Length body to finish")
		testing.expect(t, !state.must_close_1, "expected consumed Content-Length body not to force Connection: close")
		testing.expect_value(t, string(state.body_received[:state.body_len]), "hello")
		testing.expect_value(t, state.req_count, 2)
		testing.expect_value(t, state.second_target, "/after-consumed-cl")
	}

	// 4. Fully consumed Transfer-Encoding: chunked body stays keep-alive and serves the pipelined next request.
	{
		state := Test_State{t = t, mode = .Consumed_Keepalive}
		defer delete(state.second_target)
		env: Test_Env
		run_payload(t, &state, &test_handler,
			"POST /consumed-chunked HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" +
			"5\r\nhello\r\n0\r\n\r\n" +
			"GET /after-consumed-chunked HTTP/1.1\r\nHost: localhost\r\n\r\n",
			&env,
		)
		defer cleanup_env(&env)

		testing.expect(t, state.body_finished, "expected consumed chunked body to finish")
		testing.expect(t, !state.must_close_1, "expected consumed chunked body not to force Connection: close")
		testing.expect_value(t, string(state.body_received[:state.body_len]), "hello")
		testing.expect_value(t, state.req_count, 2)
		testing.expect_value(t, state.second_target, "/after-consumed-chunked")
	}

	// 5. Partial Body_Cb calling respond() on chunked and Content-Length bodies writes Connection: close and stops scanning.
	{
		state := Test_State{t = t, mode = .Partial_Cb_Respond}
		env: Test_Env
		run_payload(t, &state, &test_handler,
			"POST /partial-chunked HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" +
			"5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n" +
			"GET /should-not-run HTTP/1.1\r\nHost: localhost\r\n\r\n",
			&env,
		)
		defer cleanup_env(&env)

		testing.expect_value(t, state.body_cb_calls, 1)
		testing.expect_value(t, string(state.body_received[:state.body_len]), "hello")
		testing.expect_value(t, state.req_count, 1)
		testing.expect(t, state.must_close_1, "expected partial chunked respond to require closing")
		testing.expect(t, env.c.scanner.scan.callback == nil, "expected scan callback to stop after partial chunked respond")
		testing.expect(t, strings.contains(string(env.c.res._buf[:]), "Connection: close\r\n"), "expected Connection: close header")
	}

	{
		state := Test_State{t = t, mode = .Partial_Cb_Respond}
		env: Test_Env
		run_payload(t, &state, &test_handler,
			"POST /partial-cl HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nhello",
			&env,
		)
		defer cleanup_env(&env)

		testing.expect_value(t, state.body_cb_calls, 1)
		testing.expect_value(t, string(state.body_received[:state.body_len]), "hello")
		testing.expect_value(t, state.req_count, 1)
		testing.expect(t, state.must_close_1, "expected partial Content-Length respond to require closing")
		testing.expect(t, env.c.scanner.scan.callback == nil, "expected scan callback to stop after partial Content-Length respond")
		testing.expect(t, strings.contains(string(env.c.res._buf[:]), "Connection: close\r\n"), "expected Connection: close header")
	}
}

@(test)
test_lazy_expect_continue :: proc(t: ^testing.T) {
	http.headers_init_hash_secret()

	setup_conn :: proc(t: ^testing.T, thread: ^http.Server_Thread, c: ^http.Connection, payload: string, req_max := 100) {
		c^ = http.Connection{
			transaction_arena = http.get_arena(nil),
			temp_arena        = http.get_arena(nil),
		}
		c.transaction_arena.c = c
		c.temp_arena.c = c

		tx_alloc := http.transaction_allocator(c)
		c._vars.allocator = tx_alloc
		c.req.headers.allocator = tx_alloc
		c.res.headers.allocator = tx_alloc
		c.res._buf.allocator = tx_alloc
		c.scanner.c = c
		c.scanner.allocator = &c.transaction_arena

		c.req.progress.max = req_max
		c.req.progress.timeout = -1
		// Prevent send_continue/respond -> _do_send from calling nbio without an event loop.
		c.res.progress.max = 0
		c.res._sends = 1

		if len(payload) > 0 {
			buf, buf_err := make([]byte, max(http.MULTIPLIER, len(payload)), tx_alloc)
			testing.expect_value(t, buf_err, nil)
			c.scanner.buf = buf
			c.scanner.write_head = copy(buf, payload)
		}
	}

	cleanup_conn :: proc(c: ^http.Connection) {
		http.temp_allocator_destroy(c)
		http.transaction_allocator_destroy(c)
	}

	// 1. on_headers rejects (401) without calling body() -> never sends 100 Continue.
	{
		Reject_State :: struct {
			handled:    bool,
			sends_seen: int,
			sent_seen:  int,
		}
		state: Reject_State
		handler := http.Handler{
			user_data = &state,
			handle = proc(h: ^http.Handler, ctx: ^http.Ctx) {
				st := (^Reject_State)(h.user_data)
				st.handled = true
				st.sends_seen = ctx.res._sends
				st.sent_seen = ctx.res.sent
				ctx.res.status = .Unauthorized
				http.write_response_heading(&ctx.res)
				ctx.res._state = .Sending
				ctx.res._sends = 1
				http.respond(&ctx.res)
			},
		}

		s := http.make_server({handler = handler})
		err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte)
		testing.expect_value(t, err, nil)
		defer virtual.arena_destroy(&s.temp_allocator_backing)

		thread := http.Server_Thread{s = &s, id = 1}
		prev_td := http.td
		http.td = &thread
		defer http.td = prev_td
		defer http._server_thread_free_arenas_destroy(&thread)

		c: http.Connection
		setup_conn(t, &thread, &c,
			"POST /reject HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n",
		)
		defer cleanup_conn(&c)

		http._serve_connection(&c)
		testing.expect(t, state.handled, "expected handler to be invoked")
		testing.expect_value(t, state.sends_seen, 0)
		testing.expect_value(t, state.sent_seen, 0)
		testing.expect(t, strings.has_prefix(string(c.res._buf[:]), "HTTP/1.1 401 Unauthorized\r\n"), "expected 401 status line")
	}

	s := http.make_server({})
	err := virtual.arena_init_growing(&s.temp_allocator_backing, 64 * mem.Megabyte)
	testing.expect_value(t, err, nil)
	defer virtual.arena_destroy(&s.temp_allocator_backing)

	thread := http.Server_Thread{s = &s, id = 1}
	prev_td := http.td
	http.td = &thread
	defer http.td = prev_td
	defer http._server_thread_free_arenas_destroy(&thread)

	// 2. Content-Length exceeding body_quota.max_size -> 413 Payload Too Large and no 100 Continue.
	{
		c: http.Connection
		setup_conn(t, &thread, &c, "", 100)
		defer cleanup_conn(&c)

		c.res._state = .Handling
		c.req.line.version = {1, 1}
		testing.expect_value(t, http.headers_set(&c.req.headers, "Host", "localhost"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Expect", "100-continue"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Content-Length", "101"), nil)
		http._headers_set_readonly(&c.req.headers)

		http.body(&c.req, proc(req: ^http.Request, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res.status, http.Status.Payload_Too_Large)
		testing.expect_value(t, c.res._state, type_of(c.res._state).Error)
		testing.expect(t, strings.has_prefix(string(c.res._buf[:]), "HTTP/1.1 413 "), "expected 413 heading without prior 100 Continue")
	}

	// 3. Content-Length: 0 -> finishes immediately and does not send 100 Continue.
	{
		Zero_State :: struct {
			calls:       int,
			is_partial:  bool,
		}

		c: http.Connection
		setup_conn(t, &thread, &c, "", 100)
		defer cleanup_conn(&c)

		c.res._state = .Handling
		c.req.line.version = {1, 1}
		c.req.has_consumed_body = true
		testing.expect_value(t, http.headers_set(&c.req.headers, "Host", "localhost"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Expect", "100-continue"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Content-Length", "0"), nil)
		http._headers_set_readonly(&c.req.headers)

		zs := http.context_add(&c.ctx, Zero_State{})
		http.body(&c.req, proc(req: ^http.Request, body: []byte, is_partial: bool) {
			zs := http.context_get(http.context_of_request(req), Zero_State)
			zs.calls += 1
			zs.is_partial = is_partial
		})
		testing.expect_value(t, zs.calls, 1)
		testing.expect(t, !zs.is_partial, "expected 0-byte body to finish immediately")
		testing.expect_value(t, c.res._state, type_of(c.res._state).Handling)
		testing.expect_value(t, c.res._sends, 1)
	}

	// 4. Buffered body bytes already in scanner -> reads body without sending 100 Continue.
	{
		Buffered_State :: struct {
			got:      [16]byte,
			got_len:  int,
			finished: bool,
		}

		c: http.Connection
		setup_conn(t, &thread, &c, "hello", 100)
		defer cleanup_conn(&c)

		c.res._state = .Handling
		c.req.line.version = {1, 1}
		testing.expect_value(t, http.headers_set(&c.req.headers, "Host", "localhost"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Expect", "100-continue"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Content-Length", "5"), nil)
		http._headers_set_readonly(&c.req.headers)

		bs := http.context_add(&c.ctx, Buffered_State{})
		http.body(&c.req, proc(req: ^http.Request, body: []byte, is_partial: bool) {
			bs := http.context_get(http.context_of_request(req), Buffered_State)
			if len(body) > 0 {
				bs.got_len += copy(bs.got[bs.got_len:], body)
			}
			if !is_partial {
				bs.finished = true
			}
		})
		testing.expect(t, bs.finished, "expected buffered body to finish")
		testing.expect_value(t, string(bs.got[:bs.got_len]), "hello")
		testing.expect_value(t, c.res._state, type_of(c.res._state).Handling)
		testing.expect_value(t, c.res._sends, 1)
	}

	// 5. HTTP/1.0 with Expect: 100-continue -> does not send 100 Continue and schedules scan.
	{
		c: http.Connection
		setup_conn(t, &thread, &c, "", 100)
		defer cleanup_conn(&c)

		c.res._state = .Handling
		c.req.line.version = {1, 0}
		c.scanner.is_pumping = true
		testing.expect_value(t, http.headers_set(&c.req.headers, "Host", "localhost"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Expect", "100-continue"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Content-Length", "5"), nil)
		http._headers_set_readonly(&c.req.headers)

		http.body(&c.req, proc(req: ^http.Request, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res._state, type_of(c.res._state).Handling)
		testing.expect_value(t, c.res._sends, 1)
		testing.expect(t, c.scanner.scan.callback != nil, "expected body scan to be scheduled")
	}

	// 6. HTTP/1.1 Content-Length with no buffered bytes -> sends 100 Continue lazily.
	{
		c: http.Connection
		setup_conn(t, &thread, &c, "", 100)
		defer cleanup_conn(&c)

		c.res._state = .Handling
		c.req.line.version = {1, 1}
		testing.expect_value(t, http.headers_set(&c.req.headers, "Host", "localhost"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Expect", "100-continue"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Content-Length", "5"), nil)
		http._headers_set_readonly(&c.req.headers)

		http.body(&c.req, proc(req: ^http.Request, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res._state, type_of(c.res._state).Error)
		testing.expect_value(t, c.res.status, http.Status{})
		testing.expect_value(t, len(c.res._buf), 0)
	}

	// 7. HTTP/1.1 chunked body(): sends 100 Continue when quota available, rejects 413 without 100 Continue when max == 0.
	{
		c: http.Connection
		setup_conn(t, &thread, &c, "", 100)
		defer cleanup_conn(&c)

		c.res._state = .Handling
		c.req.line.version = {1, 1}
		testing.expect_value(t, http.headers_set(&c.req.headers, "Host", "localhost"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Expect", "100-Continue"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Transfer-Encoding", "chunked"), nil)
		http._headers_set_readonly(&c.req.headers)

		http.body(&c.req, proc(req: ^http.Request, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res._state, type_of(c.res._state).Error)
		testing.expect_value(t, c.res.status, http.Status{})
		testing.expect_value(t, len(c.res._buf), 0)
	}
	{
		c: http.Connection
		setup_conn(t, &thread, &c, "", 0)
		defer cleanup_conn(&c)

		c.res._state = .Handling
		c.req.line.version = {1, 1}
		testing.expect_value(t, http.headers_set(&c.req.headers, "Host", "localhost"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Expect", "100-continue"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Transfer-Encoding", "chunked"), nil)
		http._headers_set_readonly(&c.req.headers)

		http.body(&c.req, proc(req: ^http.Request, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res.status, http.Status.Payload_Too_Large)
		testing.expect_value(t, c.res._state, type_of(c.res._state).Error)
		testing.expect(t, strings.has_prefix(string(c.res._buf[:]), "HTTP/1.1 413 "), "expected 413 heading without prior 100 Continue")
	}

	// 8. Already sending response -> does not send 100 Continue.
	{
		c: http.Connection
		setup_conn(t, &thread, &c, "", 100)
		defer cleanup_conn(&c)

		c.res._state = .Sending
		c.req.line.version = {1, 1}
		c.scanner.is_pumping = true
		testing.expect_value(t, http.headers_set(&c.req.headers, "Host", "localhost"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Expect", "100-continue"), nil)
		testing.expect_value(t, http.headers_set(&c.req.headers, "Content-Length", "5"), nil)
		http._headers_set_readonly(&c.req.headers)

		http.body(&c.req, proc(req: ^http.Request, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res._state, type_of(c.res._state).Sending)
		testing.expect_value(t, c.res._sends, 1)
		testing.expect(t, c.scanner.scan.callback != nil, "expected body scan to be scheduled")
	}
}
