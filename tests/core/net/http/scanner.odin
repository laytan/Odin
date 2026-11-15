package test_core_net_http

import "core:mem"
import "core:mem/virtual"
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
	c.vars.allocator = http.transaction_allocator(&c)
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
	c.vars.allocator = http.transaction_allocator(&c)

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
	c.vars.allocator = tx_alloc
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
	c.vars.allocator = tx_alloc
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
