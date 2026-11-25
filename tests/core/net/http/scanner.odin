package test_core_net_http

import "base:sanitizer"

import "core:fmt"
import "core:io"
import "core:log"
import "core:mem"
import "core:strings"
import "core:testing"
import "core:time"

import http "core:http2"

@(private="file")
finish_mock_response :: proc(c: ^http.Connection, pending_sends := 0) {
	http.write_response_heading(&c.ctx)
	c.res._state = .Sending
	c.res._sends = pending_sends
	http.respond(&c.ctx)
}

@(test)
test_scanner_reset_frees_transaction_arena_when_empty :: proc(t: ^testing.T) {
	counter := Test_Counting_Allocator{backing = context.allocator}
	env: Test_Env
	test_env_init(&env, allocator = test_counting_allocator(&counter))
	defer test_env_destroy(&env)

	c: http.Connection
	test_conn_init(t, &c, &env, init_budgets = false)

	allocs_after_first: int
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
			allocs_after_first = counter.alloc_count
		} else {
			testing.expect_value(t, counter.alloc_count, allocs_after_first)
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

	env: Test_Env
	test_env_init(&env)
	defer test_env_destroy(&env)

	c: http.Connection
	test_conn_init(t, &c, &env, payload = "GET /first HTTP/1.1\r\nGET /second HTTP/1.1\r\n", init_budgets = false)

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

@(test)
test_chunked_body_trailers_filtering :: proc(t: ^testing.T) {
	Chunked_Body_Expectation :: struct {
		t:           ^testing.T,
		buf:         [64]byte,
		len:         int,
		done_called: bool,
	}

	env: Test_Env
	test_env_init(&env)
	defer test_env_destroy(&env)

	c: http.Connection
	test_conn_init(t, &c, &env, payload = "5;ext=1\r\nhello\r\n0\r\nX-Checksum: abc123\r\nContent-Length: 999\r\n\r\n", init_budgets = false)
	defer test_conn_destroy(&c)

	http.budget_init(&c.req.budget, nil)
	test_req_set_headers(t, &c, {
		{"Host", "localhost"},
		{"Transfer-Encoding", "chunked"},
		{"Trailer", "X-Checksum"},
	})

	exp := http.context_add(&c.ctx, Chunked_Body_Expectation{t = t})
	http.body(&c.ctx, proc(ctx: ^http.Ctx, body: []byte, is_partial: bool) {
		exp := http.context_get(ctx, Chunked_Body_Expectation)
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

	env: Test_Env
	test_env_init(&env)
	defer test_env_destroy(&env)

	c: http.Connection
	test_conn_init(t, &c, &env, payload = "hello temp\r\n", init_budgets = false)
	defer test_conn_destroy(&c)

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

	env: Test_Env
	test_env_init(&env)
	defer test_env_destroy(&env)

	c: http.Connection
	test_conn_init(t, &c, &env, payload = "5\r\nhello\r\n2\r\n, \r\n6\r\nworld!\r\n0\r\n\r\n", init_budgets = false)
	defer test_conn_destroy(&c)

	http.budget_init(&c.req.budget, nil)
	test_req_set_headers(t, &c, {{"Host", "localhost"}, {"Transfer-Encoding", "chunked"}})

	exp := http.context_add(&c.ctx, Stream_Expectation{t = t})

	next := proc(ctx: ^http.Ctx) {
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
	}

	http.handle({http.body_parser, next}, &c.ctx)
	testing.expect(t, exp.called, "expected body_parser to invoke next handler")

	// Verify empty body stream behavior (off=0 -> .EOF, off>0 -> .Invalid_Offset).
	empty_c: http.Connection
	test_conn_init(t, &empty_c, &env, init_budgets = false)
	defer test_conn_destroy(&empty_c)
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
	env: Test_Env
	test_env_init(&env)
	defer test_env_destroy(&env)

	// 1. Exhausted request limits before request-line completes -> 414 URI Too Long.
	{
		c: http.Connection
		test_conn_init(t, &c, &env, payload = "GET /too-long-uri-without-crlf", mock_send = true, init_budgets = false)
		defer test_conn_destroy(&c)
		c.req.budget.max = 0

		http.scan_line(&c.scanner, http.on_rline1)
		testing.expect_value(t, c.res.status, http.Status.URI_Too_Long)
		testing.expect(t, c.res._state == .Error)
	}

	// 2. Exhausted request limits after request-line during header scanning -> 431 Request Header Fields Too Large.
	{
		c: http.Connection
		test_conn_init(t, &c, &env, payload = "GET / HTTP/1.1\r\nHost: localhost\r\nX-Big: incomplete", mock_send = true, init_budgets = false)
		defer test_conn_destroy(&c)
		c.req.budget.max = 0

		http.scan_line(&c.scanner, http.on_rline1)
		testing.expect_value(t, c.res.status, http.Status.Request_Header_Fields_Too_Large)
		testing.expect(t, c.res._state == .Error)
	}

	// 3. Header count exceeding max_headers (default 128) -> 431 Request Header Fields Too Large.
	{
		c: http.Connection
		test_conn_init(t, &c, &env, mock_send = true, init_budgets = false)
		defer test_conn_destroy(&c)
		c.req.budget.max = env.s.opts.request_limits.max_size

		tx_alloc := http.transaction_allocator(&c)
		b := strings.builder_make(tx_alloc)
		strings.write_string(&b, "GET / HTTP/1.1\r\nHost: localhost\r\n")
		for i in 0 ..< env.s.opts.max_headers {
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
		testing.expect_value(t, http.headers_len(c.req.headers), env.s.opts.max_headers)
	}

	// 4a. Content-Length exceeding body_limits.max_size -> 413 Payload Too Large.
	{
		c: http.Connection
		test_conn_init(t, &c, &env, mock_handling = true, init_budgets = false)
		defer test_conn_destroy(&c)
		c.req.budget.max = 10 * mem.Megabyte
		test_req_set_headers(t, &c, {{"Host", "localhost"}, {"Content-Length", "10485761"}})

		http.body(&c.ctx, proc(ctx: ^http.Ctx, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res.status, http.Status.Payload_Too_Large)
		testing.expect(t, c.res._state == .Error)
	}

	// 4b. Exhausted body limits during body scanning -> 413 Payload Too Large.
	{
		c: http.Connection
		test_conn_init(t, &c, &env, payload = "5\r\nhe", mock_handling = true, init_budgets = false)
		defer test_conn_destroy(&c)
		c.req.budget.max = 0
		test_req_set_headers(t, &c, {{"Host", "localhost"}, {"Transfer-Encoding", "chunked"}})

		http.body(&c.ctx, proc(ctx: ^http.Ctx, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res.status, http.Status.Payload_Too_Large)
		testing.expect(t, c.res._state == .Error)
	}
}

@(test)
test_validate_headers_smuggling_defenses :: proc(t: ^testing.T) {
	env: Test_Env
	test_env_init(&env)
	defer test_env_destroy(&env)

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
		{"valid HTTP/1.1 with Content-Length",                  {1, 1}, {{"Host", "localhost"}, {"Content-Length", "42"}},                                   true},
		{"valid HTTP/1.1 with single case-insensitive chunked", {1, 1}, {{"Host", "localhost"}, {"Transfer-Encoding", "CHUNKED"}},                           true},
		{"reject missing Host",                                 {1, 1}, {{"Content-Length", "0"}},                                                           false},
		{"reject duplicate Host",                               {1, 1}, {{"Host", "a"}, {"Host", "b"}},                                                      false},
		{"reject both Transfer-Encoding and Content-Length",    {1, 1}, {{"Host", "localhost"}, {"Transfer-Encoding", "chunked"}, {"Content-Length", "5"}},  false},
		{"reject Content-Length before Transfer-Encoding",      {1, 1}, {{"Host", "localhost"}, {"Content-Length", "0"}, {"Transfer-Encoding", "chunked"}},  false},
		{"reject duplicate Transfer-Encoding headers",          {1, 1}, {{"Host", "localhost"}, {"Transfer-Encoding", "chunked"}, {"Transfer-Encoding", "chunked"}}, false},
		{"reject stacked gzip, chunked Transfer-Encoding",      {1, 1}, {{"Host", "localhost"}, {"Transfer-Encoding", "gzip"}, {"Transfer-Encoding", "chunked"}}, false},
		{"reject combined gzip, chunked Transfer-Encoding",     {1, 1}, {{"Host", "localhost"}, {"Transfer-Encoding", "gzip, chunked"}},                     false},
		{"reject non-chunked Transfer-Encoding",                {1, 1}, {{"Host", "localhost"}, {"Transfer-Encoding", "gzip"}},                              false},
		{"reject Transfer-Encoding on HTTP/1.0",                {1, 0}, {{"Host", "localhost"}, {"Transfer-Encoding", "chunked"}},                           false},
		{"reject duplicate Content-Length headers",             {1, 1}, {{"Host", "localhost"}, {"Content-Length", "5"}, {"Content-Length", "5"}},           false},
		{"reject empty Content-Length",                         {1, 1}, {{"Host", "localhost"}, {"Content-Length", ""}},                                     false},
		{"reject negative Content-Length",                      {1, 1}, {{"Host", "localhost"}, {"Content-Length", "-5"}},                                   false},
		{"reject non-numeric Content-Length",                   {1, 1}, {{"Host", "localhost"}, {"Content-Length", "5a"}},                                   false},
	}

	for tc in cases {
		c: http.Connection
		test_conn_init(t, &c, &env, init_budgets = false)
		defer test_conn_destroy(&c)

		c.req.line.version = tc.version
		for pair in tc.headers {
			testing.expect_value(t, http.headers_add(&c.req.headers, pair.k, pair.v), nil)
		}

		got := http.validate_headers(&c)
		testing.expectf(t, got == tc.ok, "%s: expected validate_headers=%v, got %v", tc.desc, tc.ok, got)
	}

	// Verify chunk-size line with CTL byte is rejected with 400 Bad Request.
	{
		c: http.Connection
		test_conn_init(t, &c, &env, payload = "5;ext=\x07\r\nhello\r\n0\r\n\r\n", mock_handling = true, init_budgets = false)
		defer test_conn_destroy(&c)

		c.req.line.version = {1, 1}
		test_req_set_headers(t, &c, {{"Host", "localhost"}, {"Transfer-Encoding", "CHUNKED"}})

		http.body(&c.ctx, proc(ctx: ^http.Ctx, body: []byte, is_partial: bool) {})
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
	}

	test_handler := proc(user_data: rawptr, ctx: ^http.Ctx) {
		state := (^Test_State)(user_data)
		c := http._connection_of_context(ctx)
		state.req_count += 1

		if state.req_count == 2 {
			state.second_target = strings.clone(ctx.req.line.target, context.allocator)
			finish_mock_response(c, pending_sends = 1)
			return
		}

		switch state.mode {
		case .Unconsumed:
			state.must_close_1 = http.response_must_close(c)
			finish_mock_response(c, pending_sends = 1)
			state.res1_had_close = strings.contains(string(c.res._buf[:]), "Connection: close\r\n")

		case .Consumed_Keepalive:
			http.context_add(ctx, state)
			http.body(ctx, proc(ctx: ^http.Ctx, data: []byte, is_partial: bool) {
				state := http.context_get(ctx, ^Test_State)^
				c := http._connection_of_context(ctx)

				state.body_cb_calls += 1
				if len(data) > 0 {
					n := copy(state.body_received[state.body_len:], data)
					state.body_len += n
				}
				if !is_partial {
					state.body_finished = true
					state.must_close_1 = http.response_must_close(c)
					finish_mock_response(c, 0)
				}
			})

		case .Partial_Cb_Respond:
			http.context_add(ctx, state)
			http.body(ctx, proc(ctx: ^http.Ctx, data: []byte, is_partial: bool) {
				state := http.context_get(ctx, ^Test_State)^
				c := http._connection_of_context(ctx)

				state.body_cb_calls += 1
				if len(data) > 0 {
					n := copy(state.body_received[state.body_len:], data)
					state.body_len += n
				}
				if is_partial {
					state.must_close_1 = http.response_must_close(c)
					finish_mock_response(c, 1)
				}
			})
		}
	}

	run_payload :: proc(t: ^testing.T, state: ^Test_State, test_handler: http.Data_Handle_Proc, payload: string, env: ^Test_Env, c: ^http.Connection) {
		test_env_init(env)
		env.handlers[0] = http.handler(state, test_handler)
		env.s.opts.handlers = env.handlers[:]
		test_conn_init(t, c, env, payload = payload, init_budgets = false)
		http._serve_connection(c)
	}

	// 1. Unconsumed Content-Length body requires closing, writes Connection: close, and schedules no body scan.
	{
		state := Test_State{t = t, mode = .Unconsumed}
		env: Test_Env
		c: http.Connection
		run_payload(t, &state, test_handler, "POST /unconsumed-cl HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello", &env, &c)
		defer test_env_destroy(&env)
		defer test_conn_destroy(&c)

		testing.expect_value(t, state.req_count, 1)
		testing.expect(t, state.must_close_1, "expected unconsumed Content-Length body to require closing")
		testing.expect(t, state.res1_had_close, "expected Connection: close header for unconsumed Content-Length")
		testing.expect(t, c.scanner.scan.callback == nil, "expected no body scan scheduled")
	}

	// 2. Unconsumed Transfer-Encoding: chunked body requires closing, writes Connection: close, and schedules no body scan.
	{
		state := Test_State{t = t, mode = .Unconsumed}
		env: Test_Env
		c: http.Connection
		run_payload(t, &state, test_handler, "POST /unconsumed-chunked HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n", &env, &c)
		defer test_env_destroy(&env)
		defer test_conn_destroy(&c)

		testing.expect_value(t, state.req_count, 1)
		testing.expect(t, state.must_close_1, "expected unconsumed chunked body to require closing")
		testing.expect(t, state.res1_had_close, "expected Connection: close header for unconsumed chunked body")
		testing.expect(t, c.scanner.scan.callback == nil, "expected no body scan scheduled")
	}

	// 3. Fully consumed Content-Length body stays keep-alive and serves the pipelined next request.
	{
		state := Test_State{t = t, mode = .Consumed_Keepalive}
		defer delete(state.second_target)
		env: Test_Env
		c: http.Connection
		run_payload(t, &state, test_handler,
			"POST /consumed-cl HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello" +
			"GET /after-consumed-cl HTTP/1.1\r\nHost: localhost\r\n\r\n",
			&env, &c,
		)
		defer test_env_destroy(&env)
		defer test_conn_destroy(&c)

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
		c: http.Connection
		run_payload(t, &state, test_handler,
			"POST /consumed-chunked HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" +
			"5\r\nhello\r\n0\r\n\r\n" +
			"GET /after-consumed-chunked HTTP/1.1\r\nHost: localhost\r\n\r\n",
			&env, &c,
		)
		defer test_env_destroy(&env)
		defer test_conn_destroy(&c)

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
		c: http.Connection
		run_payload(t, &state, test_handler,
			"POST /partial-chunked HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" +
			"5\r\nhello\r\n5\r\nworld\r\n0\r\n\r\n" +
			"GET /should-not-run HTTP/1.1\r\nHost: localhost\r\n\r\n",
			&env, &c,
		)
		defer test_env_destroy(&env)
		defer test_conn_destroy(&c)

		testing.expect_value(t, state.body_cb_calls, 1)
		testing.expect_value(t, string(state.body_received[:state.body_len]), "hello")
		testing.expect_value(t, state.req_count, 1)
		testing.expect(t, state.must_close_1, "expected partial chunked respond to require closing")
		testing.expect(t, c.scanner.scan.callback == nil, "expected scan callback to stop after partial chunked respond")
		testing.expect(t, strings.contains(string(c.res._buf[:]), "Connection: close\r\n"), "expected Connection: close header")
	}

	{
		state := Test_State{t = t, mode = .Partial_Cb_Respond}
		env: Test_Env
		c: http.Connection
		run_payload(t, &state, test_handler,
			"POST /partial-cl HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nhello",
			&env, &c,
		)
		defer test_env_destroy(&env)
		defer test_conn_destroy(&c)

		testing.expect_value(t, state.body_cb_calls, 1)
		testing.expect_value(t, string(state.body_received[:state.body_len]), "hello")
		testing.expect_value(t, state.req_count, 1)
		testing.expect(t, state.must_close_1, "expected partial Content-Length respond to require closing")
		testing.expect(t, c.scanner.scan.callback == nil, "expected scan callback to stop after partial Content-Length respond")
		testing.expect(t, strings.contains(string(c.res._buf[:]), "Connection: close\r\n"), "expected Connection: close header")
	}
}

@(test)
test_body_pause_resume :: proc(t: ^testing.T) {
	Pause_Mode :: enum {
		Async_Paused,
		Sync_Pause_Resume,
		Sync_Pause_Resume_Pause,
		Pause_Before_Body_And_On_Final,
	}

	Pause_State :: struct {
		mode:                  Pause_Mode,
		req_count:             int,
		cb_calls:              int,
		body_received:         [128]byte,
		body_len:              int,
		saved_slice:           []byte,
		finished:              bool,
		consumed_on_end:       bool,
		trailer_ok:            bool,
		second_target:         string,
		early_respond_pending: bool,
	}

	handler := proc(user_data: rawptr, ctx: ^http.Ctx) {
		st := (^Pause_State)(user_data)
		c := http._connection_of_context(ctx)
		st.req_count += 1

		if st.req_count == 2 {
			st.second_target = strings.clone(ctx.req.line.target, context.allocator)
			finish_mock_response(c, pending_sends = 1)
			return
		}

		http.context_add(ctx, st)
		if st.mode == .Pause_Before_Body_And_On_Final {
			// No-ops before body() is called.
			http.body_pause(&c.ctx)
			http.body_resume(&c.ctx)
		}

		http.body(&c.ctx, proc(ctx: ^http.Ctx, data: []byte, is_partial: bool) {
			st := http.context_get(ctx, ^Pause_State)^
			c := http._connection_of_context(ctx)
			st.cb_calls += 1

			if len(data) > 0 {
				n := copy(st.body_received[st.body_len:], data)
				st.body_len += n
			}

			if !is_partial {
				if st.mode == .Pause_Before_Body_And_On_Final {
					// No-ops on final callback once body has been consumed.
					http.body_pause(ctx)
					http.body_resume(ctx)
				}
				st.finished = true
				st.consumed_on_end = ctx.req.has_consumed_body
				if tr, ok := http.get_header(ctx, "X-Tr"); ok && tr == "ok" {
					st.trailer_ok = true
				}
				finish_mock_response(c, st.early_respond_pending ? 1 : 0)
				return
			}

			switch st.mode {
			case .Async_Paused, .Pause_Before_Body_And_On_Final:
				st.saved_slice = data
				http.body_pause(ctx)
			case .Sync_Pause_Resume:
				http.body_pause(ctx)
				http.body_resume(ctx)
			case .Sync_Pause_Resume_Pause:
				if st.cb_calls == 1 {
					st.saved_slice = data
					http.body_pause(ctx)
					http.body_resume(ctx)
					http.body_pause(ctx)
				} else {
					http.body_pause(ctx)
					http.body_resume(ctx)
				}
			}
		})
	}

	setup_and_run :: proc(t: ^testing.T, st: ^Pause_State, h: http.Data_Handle_Proc, payload: string, env: ^Test_Env, c: ^http.Connection) {
		test_env_init(env)
		env.handlers[0] = http.handler(st, h)
		env.s.opts.handlers = env.handlers[:]
		test_conn_init(t, c, env, init_budgets = false)
		buf, buf_err := make([]byte, max(http.MULTIPLIER, 1024), http.transaction_allocator(c))
		testing.expect_value(t, buf_err, nil)
		c.scanner.buf        = buf
		c.scanner.write_head = copy(buf, payload)
		http._serve_connection(c)
	}

	append_bytes :: proc(c: ^http.Connection, more: string) {
		c.scanner.write_head += copy(c.scanner.buf[c.scanner.write_head:], more)
	}

	// 1. Content-Length pause/resume across chunks + keep-alive pipelining.
	{
		st := Pause_State{mode = .Async_Paused}
		defer delete(st.second_target)
		env: Test_Env
		c: http.Connection
		setup_and_run(t, &st, handler, "POST /cl HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nhello", &env, &c)
		defer test_env_destroy(&env)
		defer test_conn_destroy(&c)

		testing.expect_value(t, st.req_count, 1)
		testing.expect_value(t, st.cb_calls, 1)
		testing.expect(t, !st.finished, "expected Content-Length body to pause before finishing")
		testing.expect(t, !c.req.has_consumed_body, "expected has_consumed_body false while paused")
		testing.expect(t, c.scanner.scan.callback == nil, "expected no scan scheduled while paused")
		testing.expect(t, !c.scanner.is_pumping, "expected scanner not pumping while paused")
		testing.expect_value(t, string(st.saved_slice), "hello")

		// Redundant pause is idempotent, and appending unread bytes does not overwrite saved_slice while paused.
		http.body_pause(&c.ctx)
		append_bytes(&c, "worldGET /after-cl HTTP/1.1\r\nHost: localhost\r\n\r\n")
		testing.expect_value(t, string(st.saved_slice), "hello")

		http.body_resume(&c.ctx)

		// Paused after final Content-Length data chunk (curr_size == 0) before uniform (nil, false) EOF.
		testing.expect_value(t, st.cb_calls, 2)
		testing.expect(t, !st.finished, "expected pause after final Content-Length chunk before EOF")
		testing.expect(t, !c.req.has_consumed_body, "expected has_consumed_body false while paused before EOF")
		testing.expect(t, c.scanner.scan.callback == nil, "expected scan callback nil while paused before EOF")
		testing.expect_value(t, string(st.saved_slice), "world")

		http.body_resume(&c.ctx)

		testing.expect(t, st.finished, "expected Content-Length body to emit (nil, false) on resume")
		testing.expect(t, st.consumed_on_end, "expected has_consumed_body true on final callback")
		testing.expect_value(t, st.cb_calls, 3)
		testing.expect_value(t, string(st.body_received[:st.body_len]), "helloworld")
		testing.expect_value(t, st.req_count, 2)
		testing.expect_value(t, st.second_target, "/after-cl")
	}

	// 2. Chunked encoding pause/resume mid-chunk AND on exact chunk boundaries + trailers + keep-alive.
	{
		st := Pause_State{mode = .Async_Paused}
		defer delete(st.second_target)
		env: Test_Env
		c: http.Connection
		setup_and_run(t, &st, handler, "POST /ch HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\na\r\nhello", &env, &c)
		defer test_env_destroy(&env)
		defer test_conn_destroy(&c)

		testing.expect_value(t, st.cb_calls, 1)
		testing.expect(t, !st.finished, "expected mid-chunk pause")
		testing.expect(t, c.scanner.scan.callback == nil, "expected scan callback nil mid-chunk pause")
		testing.expect_value(t, string(st.saved_slice), "hello")

		append_bytes(&c, "world\r\n5\r\n!!!!!\r\n0\r\nX-Tr: ok\r\n\r\nGET /after-ch HTTP/1.1\r\nHost: localhost\r\n\r\n")
		testing.expect_value(t, string(st.saved_slice), "hello")

		http.body_resume(&c.ctx)
		testing.expect_value(t, st.cb_calls, 2)
		testing.expect(t, !st.finished, "expected pause at chunk 1 boundary")
		testing.expect(t, c.scanner.scan.callback == nil, "expected scan callback nil at chunk boundary")
		testing.expect_value(t, string(st.saved_slice), "world")

		http.body_resume(&c.ctx)
		testing.expect_value(t, st.cb_calls, 3)
		testing.expect(t, !st.finished, "expected pause at chunk 2 boundary")
		testing.expect(t, c.scanner.scan.callback == nil, "expected scan callback nil at chunk 2 boundary")
		testing.expect_value(t, string(st.saved_slice), "!!!!!")

		http.body_resume(&c.ctx)
		testing.expect(t, st.finished, "expected chunked body to complete after trailers")
		testing.expect(t, st.consumed_on_end, "expected has_consumed_body true on chunked end")
		testing.expect(t, st.trailer_ok, "expected allowed trailer X-Tr to be parsed")
		testing.expect_value(t, st.cb_calls, 4)
		testing.expect_value(t, string(st.body_received[:st.body_len]), "helloworld!!!!!")
		testing.expect_value(t, st.req_count, 2)
		testing.expect_value(t, st.second_target, "/after-ch")
	}

	// 3a. Synchronous body_pause + body_resume inside Body_Cb completes iteratively.
	{
		st := Pause_State{mode = .Sync_Pause_Resume}
		defer delete(st.second_target)
		env: Test_Env
		c: http.Connection
		setup_and_run(t, &st, handler,
			"POST /sync HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" +
			"3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n" +
			"GET /after-sync HTTP/1.1\r\nHost: localhost\r\n\r\n",
			&env, &c,
		)
		defer test_env_destroy(&env)
		defer test_conn_destroy(&c)

		testing.expect(t, st.finished, "expected sync pause+resume to finish iteratively")
		testing.expect_value(t, st.cb_calls, 3)
		testing.expect_value(t, string(st.body_received[:st.body_len]), "abcdef")
		testing.expect_value(t, st.req_count, 2)
		testing.expect_value(t, st.second_target, "/after-sync")
	}

	// 3b. Synchronous pause -> resume -> pause stays paused until external body_resume.
	{
		st := Pause_State{mode = .Sync_Pause_Resume_Pause, early_respond_pending = true}
		env: Test_Env
		c: http.Connection
		setup_and_run(t, &st, handler,
			"POST /prp HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n" +
			"3\r\nabc\r\n3\r\ndef\r\n0\r\n\r\n",
			&env, &c,
		)
		defer test_env_destroy(&env)
		defer test_conn_destroy(&c)

		testing.expect_value(t, st.cb_calls, 1)
		testing.expect(t, !st.finished, "expected second pause inside Body_Cb to keep stream paused")
		testing.expect(t, c.scanner.scan.callback == nil, "expected scan callback nil after pause->resume->pause")
		testing.expect_value(t, string(st.saved_slice), "abc")

		http.body_resume(&c.ctx)

		testing.expect(t, st.finished, "expected external resume to complete buffered body")
		testing.expect_value(t, st.cb_calls, 3)
		testing.expect_value(t, string(st.body_received[:st.body_len]), "abcdef")
	}

	// 4. Edge cases: pre-body/post-final no-ops, redundant resume, early respond + stray resume, pending scan guard.
	{
		st := Pause_State{mode = .Pause_Before_Body_And_On_Final, early_respond_pending = true}
		env: Test_Env
		c: http.Connection
		setup_and_run(t, &st, handler, "POST /edge-final HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello", &env, &c)
		defer test_env_destroy(&env)
		defer test_conn_destroy(&c)

		testing.expect_value(t, st.cb_calls, 1)
		testing.expect(t, !st.finished, "expected Content-Length chunk to pause before (nil, false) EOF")
		testing.expect_value(t, string(st.saved_slice), "hello")

		http.body_resume(&c.ctx)

		testing.expect(t, st.finished, "expected resume after final Content-Length chunk to deliver (nil, false) EOF")
		testing.expect(t, st.consumed_on_end, "expected has_consumed_body true on final callback")
		testing.expect_value(t, st.cb_calls, 2)
		http.body_resume(&c.ctx)
		testing.expect(t, c.scanner.scan.callback == nil, "expected no scan after redundant resume")
	}

	{
		st := Pause_State{mode = .Async_Paused}
		env: Test_Env
		c: http.Connection
		setup_and_run(t, &st, handler, "POST /early-resp HTTP/1.1\r\nHost: localhost\r\nContent-Length: 10\r\n\r\nhello", &env, &c)
		defer test_env_destroy(&env)
		defer test_conn_destroy(&c)

		testing.expect_value(t, st.cb_calls, 1)
		append_bytes(&c, "world")
		finish_mock_response(&c, pending_sends = 1)
		testing.expect(t, c.res._state == .Sent, "expected response state Sent")

		// Stray resume after respond() must not re-arm scanning.
		http.body_resume(&c.ctx)
		testing.expect(t, !st.finished, "expected stray resume after respond not to deliver further body chunks")
		testing.expect(t, c.scanner.scan.callback == nil, "expected scan callback to stay nil after Sent")
	}

	{
		st := Pause_State{mode = .Async_Paused, early_respond_pending = true}
		env: Test_Env
		c: http.Connection
		setup_and_run(t, &st, handler, "POST /pending-scan HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc", &env, &c)
		defer test_env_destroy(&env)
		defer test_conn_destroy(&c)

		testing.expect_value(t, st.cb_calls, 1)
		testing.expect(t, c.scanner.scan.callback == nil, "expected paused at chunk boundary")

		sentinel_cb :: proc(c: ^http.Connection, data: []byte) {}
		c.scanner.scan = {
			split     = http.split_line(),
			allocator = &c.transaction_arena,
			callback  = sentinel_cb,
		}
		// External pause + resume while another scan is already pending must not clobber the pending scan.
		http.body_pause(&c.ctx)
		http.body_resume(&c.ctx)
		testing.expect(t, c.scanner.scan.callback == sentinel_cb, "expected body_resume not to overwrite active scan.callback")

		c.scanner.scan = {}
		http.body_pause(&c.ctx)
		append_bytes(&c, "\r\n0\r\n\r\n")
		http.body_resume(&c.ctx)
		testing.expect(t, st.finished, "expected chunked body to finish after clearing sentinel and resuming")
		testing.expect_value(t, string(st.body_received[:st.body_len]), "abc")
	}
}

@(test)
test_lazy_expect_continue :: proc(t: ^testing.T) {
	setup_expect_conn :: proc(t: ^testing.T, env: ^Test_Env, c: ^http.Connection, payload: string, req_max := 100, handling := true) {
		test_conn_init(t, c, env, payload = payload, mock_send = !handling, mock_handling = handling, init_budgets = false)
		c.res.status         = {}
		c.req.budget.max     = req_max
		c.req.budget.timeout = -1
	}

	// 1. on_headers rejects (401) without calling body() -> never sends 100 Continue.
	{
		Reject_State :: struct {
			handled:    bool,
			sends_seen: int,
			sent_seen:  int,
		}
		state: Reject_State
		handlers := [1]http.Handler{http.handler(&state, proc(user_data: rawptr, ctx: ^http.Ctx) {
			st := (^Reject_State)(user_data)
			st.handled = true
			st.sends_seen = ctx.res._sends
			st.sent_seen = ctx.res.sent
			ctx.res.status = .Unauthorized
			finish_mock_response(http._connection_of_context(ctx), 1)
		})}

		env: Test_Env
		test_env_init(&env, opts = {handlers = handlers[:]})
		defer test_env_destroy(&env)

		c: http.Connection
		setup_expect_conn(t, &env, &c, "POST /reject HTTP/1.1\r\nHost: localhost\r\nExpect: 100-continue\r\nContent-Length: 5\r\n\r\n", handling = false)
		defer test_conn_destroy(&c)

		http._serve_connection(&c)
		testing.expect(t, state.handled, "expected handler to be invoked")
		testing.expect_value(t, state.sends_seen, 0)
		testing.expect_value(t, state.sent_seen, 0)
		testing.expect(t, strings.has_prefix(string(c.res._buf[:]), "HTTP/1.1 401 Unauthorized\r\n"), "expected 401 status line")
	}

	env: Test_Env
	test_env_init(&env)
	defer test_env_destroy(&env)

	// 2. Content-Length exceeding body_limits.max_size -> 413 Payload Too Large and no 100 Continue.
	{
		c: http.Connection
		setup_expect_conn(t, &env, &c, "", 100)
		defer test_conn_destroy(&c)
		c.req.line.version = {1, 1}
		test_req_set_headers(t, &c, {{"Host", "localhost"}, {"Expect", "100-continue"}, {"Content-Length", "101"}})

		http.body(&c.ctx, proc(ctx: ^http.Ctx, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res.status, http.Status.Payload_Too_Large)
		testing.expect_value(t, c.res._state, type_of(c.res._state).Error)
		testing.expect(t, strings.has_prefix(string(c.res._buf[:]), "HTTP/1.1 413 "), "expected 413 heading without prior 100 Continue")
	}

	// 3. Content-Length: 0 -> finishes immediately and does not send 100 Continue.
	{
		Zero_State :: struct {
			calls:      int,
			is_partial: bool,
		}

		c: http.Connection
		setup_expect_conn(t, &env, &c, "", 100)
		defer test_conn_destroy(&c)
		c.req.line.version      = {1, 1}
		c.req.has_consumed_body = true
		test_req_set_headers(t, &c, {{"Host", "localhost"}, {"Expect", "100-continue"}, {"Content-Length", "0"}})

		zs := http.context_add(&c.ctx, Zero_State{})
		http.body(&c.ctx, proc(ctx: ^http.Ctx, body: []byte, is_partial: bool) {
			zs := http.context_get(ctx, Zero_State)
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
		setup_expect_conn(t, &env, &c, "hello", 100)
		defer test_conn_destroy(&c)
		c.req.line.version = {1, 1}
		test_req_set_headers(t, &c, {{"Host", "localhost"}, {"Expect", "100-continue"}, {"Content-Length", "5"}})

		bs := http.context_add(&c.ctx, Buffered_State{})
		http.body(&c.ctx, proc(ctx: ^http.Ctx, body: []byte, is_partial: bool) {
			bs := http.context_get(ctx, Buffered_State)
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
		setup_expect_conn(t, &env, &c, "", 100)
		defer test_conn_destroy(&c)
		c.req.line.version   = {1, 0}
		c.scanner.is_pumping = true
		test_req_set_headers(t, &c, {{"Host", "localhost"}, {"Expect", "100-continue"}, {"Content-Length", "5"}})

		http.body(&c.ctx, proc(ctx: ^http.Ctx, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res._state, type_of(c.res._state).Handling)
		testing.expect_value(t, c.res._sends, 1)
		testing.expect(t, c.scanner.scan.callback != nil, "expected body scan to be scheduled")
	}

	// 6. HTTP/1.1 Content-Length with no buffered bytes -> sends 100 Continue lazily.
	{
		c: http.Connection
		setup_expect_conn(t, &env, &c, "", 100)
		defer test_conn_destroy(&c)
		c.req.line.version = {1, 1}
		test_req_set_headers(t, &c, {{"Host", "localhost"}, {"Expect", "100-continue"}, {"Content-Length", "5"}})

		http.body(&c.ctx, proc(ctx: ^http.Ctx, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res._state, type_of(c.res._state).Error)
		testing.expect_value(t, c.res.status, http.Status{})
		testing.expect_value(t, len(c.res._buf), 0)
	}

	// 7. HTTP/1.1 chunked body(): sends 100 Continue when limits allow, rejects 413 without 100 Continue when max == 0.
	{
		c: http.Connection
		setup_expect_conn(t, &env, &c, "", 100)
		defer test_conn_destroy(&c)
		c.req.line.version = {1, 1}
		test_req_set_headers(t, &c, {{"Host", "localhost"}, {"Expect", "100-Continue"}, {"Transfer-Encoding", "chunked"}})

		http.body(&c.ctx, proc(ctx: ^http.Ctx, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res._state, type_of(c.res._state).Error)
		testing.expect_value(t, c.res.status, http.Status{})
		testing.expect_value(t, len(c.res._buf), 0)
	}
	{
		c: http.Connection
		setup_expect_conn(t, &env, &c, "", 0)
		defer test_conn_destroy(&c)
		c.req.line.version = {1, 1}
		test_req_set_headers(t, &c, {{"Host", "localhost"}, {"Expect", "100-continue"}, {"Transfer-Encoding", "chunked"}})

		http.body(&c.ctx, proc(ctx: ^http.Ctx, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res.status, http.Status.Payload_Too_Large)
		testing.expect_value(t, c.res._state, type_of(c.res._state).Error)
		testing.expect(t, strings.has_prefix(string(c.res._buf[:]), "HTTP/1.1 413 "), "expected 413 heading without prior 100 Continue")
	}

	// 8. Already sending response -> does not send 100 Continue.
	{
		c: http.Connection
		setup_expect_conn(t, &env, &c, "", 100)
		defer test_conn_destroy(&c)
		c.res._state         = .Sending
		c.req.line.version   = {1, 1}
		c.scanner.is_pumping = true
		test_req_set_headers(t, &c, {{"Host", "localhost"}, {"Expect", "100-continue"}, {"Content-Length", "5"}})

		http.body(&c.ctx, proc(ctx: ^http.Ctx, body: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res._state, type_of(c.res._state).Sending)
		testing.expect_value(t, c.res._sends, 1)
		testing.expect(t, c.scanner.scan.callback != nil, "expected body scan to be scheduled")
	}
}

@(test)
test_scanner_buf_size_bucket_alignment :: proc(t: ^testing.T) {
	hdr := size_of(http._Arena_Block)
	testing.expect_value(t, http._scanner_buf_size(1), http.MULTIPLIER)
	testing.expect_value(t, http._scanner_buf_size(512), 512)
	testing.expect_value(t, http._scanner_buf_size(513), 1024)
	testing.expect_value(t, http._scanner_buf_size(2048), 2048)
	testing.expect_value(t, http._scanner_buf_size(4096 - hdr), 4096 - hdr)
	testing.expect_value(t, http._scanner_buf_size(4096 - hdr + 1), 8192 - hdr)
	testing.expect_value(t, http._scanner_buf_size(http.BODY_BUF_SIZE), 16 * mem.Kilobyte - hdr)
	testing.expect_value(t, http._scanner_buf_size(16 * mem.Megabyte - hdr), 16 * mem.Megabyte - hdr)
	testing.expect_value(t, http._scanner_buf_size(16 * mem.Megabyte + 123), 16 * mem.Megabyte + 123)

	testing.expect_value(t, http._scanner_buf_size(512, http._arena_grow_size(0)), 512)
	testing.expect_value(t, http._scanner_buf_size(1024, http._arena_grow_size(512)), 1024)
	testing.expect_value(t, http._scanner_buf_size(1536, http._arena_grow_size(1024)), 2048)
	testing.expect_value(t, http._scanner_buf_size(2560, http._arena_grow_size(2048)), 4096 - hdr)
	testing.expect_value(t, http._scanner_buf_size(4096 - hdr + 512, http._arena_grow_size(4096 - hdr)), 8192 - hdr)

	// Verify 512 -> 1024 -> 2048 -> (4096 - hdr) resizes in-place inside a single 4 KiB block.
	counter := Test_Counting_Allocator{backing = context.allocator}
	env: Test_Env
	test_env_init(&env, allocator = test_counting_allocator(&counter))
	defer test_env_destroy(&env)

	a := http.get_arena(nil)
	defer http.arena_destroy(&a)
	alloc := http.arena_allocator(&a)

	buf, err := make([]byte, http.MULTIPLIER, alloc)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, counter.alloc_count, 1)

	for step in ([?]int{1024, 2048, 4096 - hdr}) {
		next_size := http._scanner_buf_size(len(buf) + 1, http._arena_grow_size(len(buf)))
		testing.expect_value(t, next_size, step)
		resized, rerr := http._arena_block_resize_in_place(a.tail, buf, next_size, 1, false)
		testing.expect_value(t, rerr, nil)
		buf = resized
		testing.expect_value(t, len(a.tail.data), 4096)
		testing.expect_value(t, counter.alloc_count, 1)
	}

	next_size := http._scanner_buf_size(len(buf) + 1, http._arena_grow_size(len(buf)))
	testing.expect_value(t, next_size, 8192 - hdr)
	_, nerr := make([]byte, next_size, alloc)
	testing.expect_value(t, nerr, nil)
	testing.expect_value(t, len(a.tail.data), 8192)
	testing.expect_value(t, counter.alloc_count, 2)
}

@(test)
test_body_reusable_buffer_caps_untrusted_sizes_and_preserves_state :: proc(t: ^testing.T) {
	// 1. Lying 1 GiB Content-Length with NO_LIMITS caps detached reusable buffer at BODY_BUF_SIZE (16 KiB block)
	//    and compacts in place across repeated chunks without touching headers or temp_allocator allocations.
	{
		State :: struct {
			t:             ^testing.T,
			orig_hdr_ptr:  rawptr,
			temp_sentinel: []byte,
		}

		st := State{t = t}
		counter := Test_Counting_Allocator{backing = context.allocator}
		handlers := [1]http.Handler{http.handler(&st, proc(user_data: rawptr, ctx: ^http.Ctx) {
			st := (^State)(user_data)

			temp, terr := make([]byte, 256, context.temp_allocator)
			testing.expect_value(st.t, terr, nil)
			for &b in temp { b = 0x5A }
			st.temp_sentinel = temp

			http.body(ctx, proc(ctx: ^http.Ctx, data: []byte, is_partial: bool) {})
		})}

		env: Test_Env
		test_env_init(&env, opts = {body_limits = http.NO_LIMITS, handlers = handlers[:]}, allocator = test_counting_allocator(&counter))
		defer test_env_destroy(&env)
		env.s.opts.handlers = handlers[:]

		c: http.Connection
		test_conn_init(t, &c, &env, payload = "POST /upload HTTP/1.1\r\nHost: localhost\r\nX-Tag: keep-me\r\nContent-Length: 1073741824\r\n\r\n")
		defer test_conn_destroy(&c)

		st.orig_hdr_ptr = raw_data(c.scanner.buf)
		c.scanner.scan = {
			split     = http.split_line(),
			allocator = &c.transaction_arena,
			callback  = http.on_rline1,
		}
		testing.expect(t, http._scanner_pump_buffered(&c.scanner), "expected body scan to request recv")
		testing.expect(t, http._scanner_prepare_recv_buf(&c.scanner), "expected body detach buffer preparation to succeed")

		testing.expect(t, c.scanner.buf_reusable, "expected reusable buffer after body detach")
		testing.expect_value(t, len(c.scanner.buf), http.BODY_BUF_SIZE)
		testing.expect(t, raw_data(c.scanner.buf) != st.orig_hdr_ptr, "expected body detach from header buffer")
		testing.expect_value(t, len(c.transaction_arena.tail.data), 16 * mem.Kilobyte)
		// Alloc 1 = initial 4 KiB header block, Alloc 2 = 4 KiB temp_arena sentinel, Alloc 3 = single 16 KiB reusable body block.
		testing.expect_value(t, counter.alloc_count, 3)

		reusable_ptr := raw_data(c.scanner.buf)

		// Empty rewind on subsequent streaming cycle reuses the exact same 16 KiB buffer with 0 allocations.
		for round in 0..<10 {
			for &b in c.scanner.buf { b = u8('A' + (round % 26)) }
			c.scanner.read_head  = 4096
			c.scanner.write_head = 4096
			c.scanner.scan = {
				split     = http.split_at_most(1024),
				allocator = &c.transaction_arena,
				callback  = proc(c: ^http.Connection, data: []byte) {},
				buf_cap   = http.STREAM_MAX_BUF_SIZE,
				reuse     = true,
			}
			testing.expect(t, http._scanner_pump_buffered(&c.scanner))
			testing.expect(t, http._scanner_prepare_recv_buf(&c.scanner))
			testing.expect_value(t, c.scanner.read_head, 0)
			testing.expect_value(t, c.scanner.write_head, 0)
			testing.expect(t, raw_data(c.scanner.buf) == reusable_ptr, "expected pointer preserved across non-full rewinds")
		}
		testing.expect_value(t, counter.alloc_count, 3)

		// Partial compaction shifts unread bytes to offset 0 in place.
		tail_msg := "TAIL_PAYLOAD!"
		tail_start := 4096
		copy(c.scanner.buf[tail_start:], tail_msg)
		c.scanner.read_head  = tail_start
		c.scanner.write_head = tail_start + len(tail_msg)
		c.scanner.scan = {
			split     = http.split_line(),
			allocator = &c.transaction_arena,
			callback  = proc(c: ^http.Connection, data: []byte) {},
			buf_cap   = http.STREAM_MAX_BUF_SIZE,
			reuse     = true,
		}
		testing.expect(t, http._scanner_pump_buffered(&c.scanner))
		testing.expect(t, http._scanner_prepare_recv_buf(&c.scanner))
		testing.expect_value(t, c.scanner.read_head, 0)
		testing.expect_value(t, c.scanner.write_head, len(tail_msg))
		testing.expect_value(t, string(c.scanner.buf[:len(tail_msg)]), tail_msg)
		testing.expect(t, raw_data(c.scanner.buf) == reusable_ptr, "expected pointer preserved across compaction")
		testing.expect_value(t, counter.alloc_count, 3)

		// Adaptive ramp-up: when recvs fill the buffer, .Reuse doubles 16K -> 32K -> 64K -> 128K -> 256K and caps there.
		hdr_size := size_of(http._Arena_Block)
		expected_buckets := [?]int{32 * mem.Kilobyte, 64 * mem.Kilobyte, 128 * mem.Kilobyte, 256 * mem.Kilobyte}
		for bucket_size, idx in expected_buckets {
			c.scanner.read_head  = len(c.scanner.buf)
			c.scanner.write_head = len(c.scanner.buf)
			c.scanner.scan = {
				split     = http.split_at_most(1024),
				allocator = &c.transaction_arena,
				callback  = proc(c: ^http.Connection, data: []byte) {},
				buf_cap   = http.STREAM_MAX_BUF_SIZE,
				reuse     = true,
			}
			testing.expect(t, http._scanner_pump_buffered(&c.scanner))
			testing.expect(t, http._scanner_prepare_recv_buf(&c.scanner))
			testing.expect_value(t, c.scanner.read_head, 0)
			testing.expect_value(t, c.scanner.write_head, 0)
			testing.expect_value(t, len(c.scanner.buf), bucket_size - hdr_size)
			testing.expect_value(t, len(c.transaction_arena.tail.data), bucket_size)
			testing.expect_value(t, counter.alloc_count, 4 + idx)
		}

		// Abandoned intermediate .Reuse blocks (16K/32K/64K/128K) were reclaimed back to td.free_arenas.
		arena_blocks := 0
		for b := c.transaction_arena.tail; b != nil; b = b.prev {
			arena_blocks += 1
		}
		testing.expect_value(t, arena_blocks, 2)
		testing.expect_value(t, len(c.transaction_arena.tail.prev.data), 4 * mem.Kilobyte)

		// Once at STREAM_MAX_BUF_SIZE (256 KiB - hdr), further full recvs stay flat with zero allocations.
		max_ptr := raw_data(c.scanner.buf)
		for _ in 0..<4 {
			c.scanner.read_head  = len(c.scanner.buf)
			c.scanner.write_head = len(c.scanner.buf)
			c.scanner.scan = {
				split     = http.split_at_most(1024),
				allocator = &c.transaction_arena,
				callback  = proc(c: ^http.Connection, data: []byte) {},
				buf_cap   = http.STREAM_MAX_BUF_SIZE,
				reuse     = true,
			}
			testing.expect(t, http._scanner_pump_buffered(&c.scanner))
			testing.expect(t, http._scanner_prepare_recv_buf(&c.scanner))
			testing.expect(t, raw_data(c.scanner.buf) == max_ptr, "expected pointer preserved once at STREAM_MAX_BUF_SIZE")
			testing.expect_value(t, len(c.scanner.buf), http.STREAM_MAX_BUF_SIZE)
			testing.expect_value(t, counter.alloc_count, 7)
		}

		// Original request line, headers, and temp_allocator data remain intact and unpoisoned.
		testing.expect_value(t, c.req.line.target, "/upload")
		tag, tag_ok := http.get_header(&c.ctx, "X-Tag")
		testing.expect(t, tag_ok, "expected header preserved")
		testing.expect_value(t, tag, "keep-me")
		testing.expect(t, sanitizer.address_region_is_poisoned(st.temp_sentinel) == nil, "expected temp_allocator data unpoisoned")
		for b in st.temp_sentinel {
			testing.expect_value(t, b, u8(0x5A))
		}

		// Concurrent second connection reuses the reclaimed 16K/32K/64K/128K blocks with 0 new backing allocs.
		c2: http.Connection
		test_conn_init(t, &c2, &env, payload = "POST /upload2 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 1073741824\r\n\r\n")
		defer test_conn_destroy(&c2)

		testing.expect_value(t, counter.alloc_count, 8) // 4 KiB header block for c2.
		c2.scanner.scan = {
			split     = http.split_line(),
			allocator = &c2.transaction_arena,
			callback  = http.on_rline1,
		}
		testing.expect(t, http._scanner_pump_buffered(&c2.scanner))
		testing.expect_value(t, counter.alloc_count, 9) // 4 KiB temp_arena sentinel before detaching body buffer.
		testing.expect(t, http._scanner_prepare_recv_buf(&c2.scanner))
		testing.expect_value(t, len(c2.scanner.buf), http.BODY_BUF_SIZE)
		testing.expect_value(t, counter.alloc_count, 9)

		for bucket_size in ([?]int{32 * mem.Kilobyte, 64 * mem.Kilobyte, 128 * mem.Kilobyte}) {
			c2.scanner.read_head  = len(c2.scanner.buf)
			c2.scanner.write_head = len(c2.scanner.buf)
			c2.scanner.scan = {
				split     = http.split_at_most(1024),
				allocator = &c2.transaction_arena,
				callback  = proc(c: ^http.Connection, data: []byte) {},
				buf_cap   = http.STREAM_MAX_BUF_SIZE,
				reuse     = true,
			}
			testing.expect(t, http._scanner_pump_buffered(&c2.scanner))
			testing.expect(t, http._scanner_prepare_recv_buf(&c2.scanner))
			testing.expect_value(t, len(c2.transaction_arena.tail.data), bucket_size)
			testing.expect_value(t, counter.alloc_count, 9)
		}
	}

	// 2. Lying 1 GiB chunk size with NO_LIMITS starts detached reusable buffer at BODY_BUF_SIZE (16 KiB block).
	{
		counter := Test_Counting_Allocator{backing = context.allocator}
		handlers := [1]http.Handler{proc(ctx: ^http.Ctx) {
			http.body(ctx, proc(ctx: ^http.Ctx, data: []byte, is_partial: bool) {})
		}}
		env: Test_Env
		test_env_init(&env, opts = {body_limits = http.NO_LIMITS, handlers = handlers[:]}, allocator = test_counting_allocator(&counter))
		defer test_env_destroy(&env)
		env.s.opts.handlers = handlers[:]

		c: http.Connection
		test_conn_init(t, &c, &env, payload = "POST /chunked HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\n\r\n40000000\r\n")
		defer test_conn_destroy(&c)

		c.scanner.scan = {
			split     = http.split_line(),
			allocator = &c.transaction_arena,
			callback  = http.on_rline1,
		}
		testing.expect(t, http._scanner_pump_buffered(&c.scanner))
		testing.expect(t, http._scanner_prepare_recv_buf(&c.scanner))

		testing.expect(t, c.scanner.buf_reusable, "expected reusable buffer after chunked body detach")
		testing.expect_value(t, len(c.scanner.buf), http.BODY_BUF_SIZE)
		testing.expect_value(t, len(c.transaction_arena.tail.data), 16 * mem.Kilobyte)
		testing.expect_value(t, counter.alloc_count, 2)
	}

	// 3. Small split Content-Length (200 bytes) caps reusable buffer at MULTIPLIER (512 bytes) inside existing 4 KiB block.
	{
		counter := Test_Counting_Allocator{backing = context.allocator}
		handlers := [1]http.Handler{proc(ctx: ^http.Ctx) {
			http.body(ctx, proc(ctx: ^http.Ctx, data: []byte, is_partial: bool) {})
		}}
		env: Test_Env
		test_env_init(&env, opts = {body_limits = http.NO_LIMITS, handlers = handlers[:]}, allocator = test_counting_allocator(&counter))
		defer test_env_destroy(&env)
		env.s.opts.handlers = handlers[:]

		c: http.Connection
		test_conn_init(t, &c, &env, payload = "POST /small HTTP/1.1\r\nHost: localhost\r\nContent-Length: 200\r\n\r\n")
		defer test_conn_destroy(&c)

		c.scanner.scan = {
			split     = http.split_line(),
			allocator = &c.transaction_arena,
			callback  = http.on_rline1,
		}
		testing.expect(t, http._scanner_pump_buffered(&c.scanner))
		testing.expect(t, http._scanner_prepare_recv_buf(&c.scanner))

		testing.expect(t, c.scanner.buf_reusable, "expected reusable buffer for split small body")
		testing.expect_value(t, len(c.scanner.buf), http.MULTIPLIER)
		testing.expect_value(t, counter.alloc_count, 1)
		testing.expect(t, c.transaction_arena.tail.prev == nil, "expected 512-byte body buffer to fit inside existing 4 KiB block")
	}

	// 4. Chunked trailers freeze buf_mode to .Grow and preserve trailer headers + pipelined next request.
	{
		Trailer_State :: struct {
			done: bool,
		}

		env: Test_Env
		test_env_init(&env)
		defer test_env_destroy(&env)

		c: http.Connection
		test_conn_init(t, &c, &env, init_budgets = false)
		defer test_conn_destroy(&c)

		http.budget_init(&c.req.budget, nil)
		test_req_set_headers(t, &c, {{"Host", "localhost"}, {"Transfer-Encoding", "chunked"}, {"Trailer", "X-Trailer"}})

		payload := "0\r\nX-Trailer: val\r\n\r\nGET /next HTTP/1.1\r\n"
		rbuf, rerr := make([]byte, http.BODY_BUF_SIZE, http.transaction_allocator(&c))
		testing.expect_value(t, rerr, nil)
		c.scanner.buf          = rbuf
		c.scanner.buf_reusable = true
		c.scanner.write_head   = copy(rbuf, payload)

		ts := http.context_add(&c.ctx, Trailer_State{})
		http.body(&c.ctx, proc(ctx: ^http.Ctx, data: []byte, is_partial: bool) {
			if !is_partial {
				ts := http.context_get(ctx, Trailer_State)
				ts.done = true
			}
		})

		testing.expect(t, ts.done, "expected chunked trailer body completion")
		testing.expect(t, !c.scanner.buf_reusable, "expected on_trailer to clear buf_reusable")
		tr_val, tr_ok := http.get_header(&c.ctx, "X-Trailer")
		testing.expect(t, tr_ok, "expected trailer header stored in request")
		testing.expect_value(t, tr_val, "val")
		testing.expect_value(t, string(c.scanner.buf[c.scanner.read_head:c.scanner.write_head]), "GET /next HTTP/1.1\r\n")
	}
}

@(test)
test_body_retain_and_body_parser_zero_copy_capped_blocks :: proc(t: ^testing.T) {
	// 1. body_parser uses retain = true for true zero-copy parts (zero extra clone allocations).
	{
		Parser_State :: struct {
			t:         ^testing.T,
			called:    bool,
			buf_start: uintptr,
			buf_end:   uintptr,
		}

		counter := Test_Counting_Allocator{backing = context.allocator}
		env: Test_Env
		test_env_init(&env, allocator = test_counting_allocator(&counter))
		defer test_env_destroy(&env)

		c: http.Connection
		test_conn_init(t, &c, &env, payload = "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n", init_budgets = false)
		defer test_conn_destroy(&c)

		http.budget_init(&c.req.budget, nil)
		test_req_set_headers(t, &c, {{"Host", "localhost"}, {"Transfer-Encoding", "chunked"}})
		testing.expect_value(t, counter.alloc_count, 1)

		ps := http.context_add(&c.ctx, Parser_State{
			t         = t,
			buf_start = uintptr(raw_data(c.scanner.buf)),
			buf_end   = uintptr(raw_data(c.scanner.buf)) + uintptr(len(c.scanner.buf)),
		})
		next := proc(ctx: ^http.Ctx) {
			ps := http.context_get(ctx, Parser_State)
			ps.called = true

			it := http.body_parser_iterator(ctx)
			for part, _ in http.body_parser_iter(&it) {
				p := uintptr(raw_data(part))
				testing.expect(ps.t, p >= ps.buf_start && p < ps.buf_end, "expected zero-copy part aliasing original scanner buffer")
			}

			bps: http.Body_Parser_Stream
			http.body_parser_stream_init(&bps, ctx)
			stream := http.body_parser_stream(&bps)
			out: [32]byte
			n, rerr := io.read(stream, out[:])
			testing.expect_value(ps.t, rerr, nil)
			testing.expect_value(ps.t, string(out[:n]), "hello world")
		}

		http.handle({http.body_parser, next}, &c.ctx)
		testing.expect(t, ps.called, "expected body_parser to invoke next handler")
		testing.expect_value(t, counter.alloc_count, 1)
	}

	// 2. .Retain mode starts <= 16 KiB, progressively doubles 16K -> 32K -> 64K when blocks fill,
	//    and clamps cleanly to remaining buf_cap without overwriting previously yielded slices.
	{
		counter := Test_Counting_Allocator{backing = context.allocator}
		env: Test_Env
		test_env_init(&env, allocator = test_counting_allocator(&counter))
		defer test_env_destroy(&env)

		c: http.Connection
		test_conn_init(t, &c, &env, init_budgets = false)
		defer test_conn_destroy(&c)

		trigger_retain :: proc(t: ^testing.T, c: ^http.Connection, cap := i32(http.RETAIN_MAX_BUF_SIZE)) {
			c.scanner.scan = {
				split     = http.split_at_most(64 * mem.Kilobyte),
				allocator = &c.transaction_arena,
				callback  = proc(c: ^http.Connection, data: []byte) {},
				buf_cap   = cap,
				reuse     = false,
			}
			testing.expect(t, http._scanner_pump_buffered(&c.scanner))
			testing.expect(t, http._scanner_prepare_recv_buf(&c.scanner))
		}

		hdr_size := size_of(http._Arena_Block)

		// Block 1: untrusted initial allocation starts at BODY_BUF_SIZE (16 KiB - hdr).
		trigger_retain(t, &c)
		buf1 := c.scanner.buf
		testing.expect(t, !c.scanner.buf_reusable, "expected non-reusable buffer on Block 1")
		testing.expect_value(t, len(buf1), http.BODY_BUF_SIZE)
		testing.expect_value(t, len(c.transaction_arena.tail.data), 16 * mem.Kilobyte)
		testing.expect_value(t, counter.alloc_count, 1)
		for &b in buf1 { b = 'A' }
		c.scanner.read_head  = len(buf1)
		c.scanner.write_head = len(buf1)

		// Block 2: progressively doubles to 32 KiB - hdr once Block 1 fills; buf1 untouched.
		trigger_retain(t, &c)
		buf2 := c.scanner.buf
		testing.expect(t, !c.scanner.buf_reusable, "expected non-reusable buffer on Block 2")
		testing.expect(t, raw_data(buf2) != raw_data(buf1), "expected fresh chained buffer on Block 2")
		testing.expect_value(t, len(buf2), 32 * mem.Kilobyte - hdr_size)
		testing.expect_value(t, len(c.transaction_arena.tail.data), 32 * mem.Kilobyte)
		testing.expect_value(t, counter.alloc_count, 2)
		for &b in buf2 { b = 'B' }
		c.scanner.read_head  = len(buf2)
		c.scanner.write_head = len(buf2)

		// Block 3: progressively doubles to 64 KiB - hdr once Block 2 fills; buf1 and buf2 untouched.
		trigger_retain(t, &c)
		buf3 := c.scanner.buf
		testing.expect(t, raw_data(buf3) != raw_data(buf2), "expected third chained buffer on Block 3")
		testing.expect_value(t, len(buf3), 64 * mem.Kilobyte - hdr_size)
		testing.expect_value(t, len(c.transaction_arena.tail.data), 64 * mem.Kilobyte)
		testing.expect_value(t, counter.alloc_count, 3)
		for &b in buf3 { b = 'C' }
		c.scanner.read_head  = len(buf3)
		c.scanner.write_head = len(buf3)

		// Block 4: remaining buf_cap = 16384 clamps down to 16 KiB - hdr; prior blocks intact.
		trigger_retain(t, &c, 16384)
		buf4 := c.scanner.buf
		testing.expect(t, raw_data(buf4) != raw_data(buf3), "expected fourth chained buffer on Block 4")
		testing.expect_value(t, len(buf4), http.BODY_BUF_SIZE)
		testing.expect_value(t, len(c.transaction_arena.tail.data), 16 * mem.Kilobyte)
		testing.expect_value(t, counter.alloc_count, 4)

		for b in buf1 { testing.expect_value(t, b, u8('A')) }
		for b in buf2 { testing.expect_value(t, b, u8('B')) }
		for b in buf3 { testing.expect_value(t, b, u8('C')) }
	}
}

@(test)
test_scanner_pre_alloc_limits_and_timeout_rejection :: proc(t: ^testing.T) {
	setup_conn :: proc(t: ^testing.T, env: ^Test_Env, c: ^http.Connection, max_bytes: int, timeout: int) {
		c.temp_arena = http.Arena{backing = context.allocator}
		test_conn_init(t, c, env, mock_handling = true, init_budgets = false)
		c.req.budget.max     = max_bytes
		c.req.budget.timeout = time.Duration(timeout)
		buf, err := make([]byte, http.MULTIPLIER, http.transaction_allocator(c))
		testing.expect_value(t, err, nil)
		c.scanner.buf = buf
	}

	for reuse in ([?]bool{true, false}) {
		// 1. budget.max == 0 rejects with 413 Payload Too Large and 0 extra allocations.
		{
			counter := Test_Counting_Allocator{backing = context.allocator}
			env: Test_Env
			test_env_init(&env, allocator = test_counting_allocator(&counter))
			defer test_env_destroy(&env)

			c: http.Connection
			setup_conn(t, &env, &c, 0, -1)
			defer test_conn_destroy(&c)

			before_allocs := counter.alloc_count
			orig_tail := c.transaction_arena.tail
			c.scanner.scan = {
				split     = http.split_at_most(4096),
				allocator = &c.transaction_arena,
				callback  = proc(c: ^http.Connection, data: []byte) {},
				buf_cap   = http.STREAM_MAX_BUF_SIZE,
				reuse     = reuse,
			}
			http.scanner_pump(&c.scanner)
			testing.expect_value(t, c.res.status, http.Status.Payload_Too_Large)
			testing.expect_value(t, c.res._state, type_of(c.res._state).Error)
			testing.expect_value(t, c.transaction_arena.tail, orig_tail)
			testing.expect_value(t, counter.alloc_count, before_allocs)
		}

		// 2. budget.timeout == 0 rejects with 408 Request Timeout and 0 extra allocations.
		{
			counter := Test_Counting_Allocator{backing = context.allocator}
			env: Test_Env
			test_env_init(&env, allocator = test_counting_allocator(&counter))
			defer test_env_destroy(&env)

			c: http.Connection
			setup_conn(t, &env, &c, 1024, 0)
			defer test_conn_destroy(&c)

			before_allocs := counter.alloc_count
			orig_tail := c.transaction_arena.tail
			c.scanner.scan = {
				split     = http.split_at_most(4096),
				allocator = &c.transaction_arena,
				callback  = proc(c: ^http.Connection, data: []byte) {},
				buf_cap   = http.STREAM_MAX_BUF_SIZE,
				reuse     = reuse,
			}
			http.scanner_pump(&c.scanner)
			testing.expect_value(t, c.res.status, http.Status.Request_Timeout)
			testing.expect_value(t, c.res._state, type_of(c.res._state).Error)
			testing.expect_value(t, c.transaction_arena.tail, orig_tail)
			testing.expect_value(t, counter.alloc_count, before_allocs)
		}
	}
}

@(test)
test_chunked_framing_bounds :: proc(t: ^testing.T) {
	setup_chunked_conn :: proc(t: ^testing.T, env: ^Test_Env, c: ^http.Connection, payload: string) {
		c.temp_arena = http.Arena{backing = context.allocator}
		test_conn_init(t, c, env, payload = payload, mock_handling = true, init_budgets = false)
		http.budget_init(&c.req.budget, &env.s.opts.body_limits)
		c.req.line.version = {1, 1}
		test_req_set_headers(t, c, {{"Host", "localhost"}, {"Transfer-Encoding", "chunked"}})
	}

	// 1. Non-CRLF bytes after chunk data -> immediate 400 Bad Request on 2 bytes in both retain = false and retain = true.
	for retain in ([?]bool{false, true}) {
		env: Test_Env
		test_env_init(&env, opts = {body_limits = http.NO_LIMITS})
		defer test_env_destroy(&env)

		c: http.Connection
		setup_chunked_conn(t, &env, &c, "5\r\nhelloXX")
		defer test_conn_destroy(&c)

		http.body(&c.ctx, proc(ctx: ^http.Ctx, data: []byte, is_partial: bool) {}, retain = retain)
		testing.expect_value(t, c.res.status, http.Status.Bad_Request)
		testing.expect_value(t, c.res._state, type_of(c.res._state).Error)
	}

	// 2a. Single huge incomplete trailer line (> request_limits.max_size) -> 431 Request Header Fields Too Large.
	{
		env: Test_Env
		test_env_init(&env, opts = {
			request_limits = {max_size = 512, min = -1},
			body_limits    = http.NO_LIMITS,
		})
		defer test_env_destroy(&env)

		b := strings.builder_make()
		defer strings.builder_destroy(&b)
		strings.write_string(&b, "0\r\nX-Big: ")
		for _ in 0..<512 {
			strings.write_byte(&b, 'x')
		}

		c: http.Connection
		setup_chunked_conn(t, &env, &c, strings.to_string(b))
		defer test_conn_destroy(&c)

		http.body(&c.ctx, proc(ctx: ^http.Ctx, data: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res.status, http.Status.Request_Header_Fields_Too_Large)
		testing.expect_value(t, c.res._state, type_of(c.res._state).Error)
	}

	// 2b. Multiple incomplete trailer lines exceeding request_limits.max_size (needing recv) -> 431.
	{
		env: Test_Env
		test_env_init(&env, opts = {
			request_limits = {max_size = 32, min = -1},
			body_limits    = http.NO_LIMITS,
		})
		defer test_env_destroy(&env)

		c: http.Connection
		setup_chunked_conn(t, &env, &c, "0\r\nX-A: 123456789012\r\nX-B: 123456789012\r\n")
		defer test_conn_destroy(&c)

		http.body(&c.ctx, proc(ctx: ^http.Ctx, data: []byte, is_partial: bool) {})
		testing.expect_value(t, c.res.status, http.Status.Request_Header_Fields_Too_Large)
		testing.expect_value(t, c.res._state, type_of(c.res._state).Error)
	}
}

@(test)
test_body_mode_transition_to_grow_at_buffer_tail :: proc(t: ^testing.T) {
	Transition_State :: struct {
		done: bool,
	}

	// 1. .Reuse (256 KiB full, < 512 bytes left) transitioning to on_trailer compacts in place with 0 new allocs.
	{
		counter := Test_Counting_Allocator{backing = context.allocator}
		env: Test_Env
		test_env_init(&env, allocator = test_counting_allocator(&counter))
		defer test_env_destroy(&env)

		c: http.Connection
		test_conn_init(t, &c, &env, init_budgets = false)
		defer test_conn_destroy(&c)

		http.budget_init(&c.req.budget, nil)
		test_req_set_headers(t, &c, {{"Host", "localhost"}, {"Transfer-Encoding", "chunked"}, {"Trailer", "X-Tr"}})

		buf, err := make([]byte, http.STREAM_MAX_BUF_SIZE, http.transaction_allocator(&c))
		testing.expect_value(t, err, nil)
		orig_ptr := raw_data(buf)

		partial_trailer := "0\r\nX-Tr: "
		start := len(buf) - len(partial_trailer) - 8
		copy(buf[start:], partial_trailer)
		c.scanner.buf          = buf
		c.scanner.buf_reusable = true
		c.scanner.read_head    = start
		c.scanner.write_head   = start + len(partial_trailer)

		ts := http.context_add(&c.ctx, Transition_State{})
		allocs_before := counter.alloc_count

		// Drive chunked size parsing from buffered data at the buffer tail, then prepare recv for trailer.
		c.scanner.scan = {
			split     = http.split_line(),
			allocator = &c.transaction_arena,
			callback  = proc(c: ^http.Connection, data: []byte) {
				assert(string(data) == "0")
				http.scan_line(&c.scanner, proc(c: ^http.Connection, tr: []byte) {
					if len(tr) == 0 {
						ts := http.context_get(&c.ctx, Transition_State)
						ts.done = true
						return
					}
					k, v, ok := http.header_parse(string(tr))
					assert(ok)
					http._headers_set_writable(&c.req.headers)
					_ = http.headers_add(&c.req.headers, k, v)
					http._headers_set_readonly(&c.req.headers)
					http.scan_line(&c.scanner, proc(c: ^http.Connection, end: []byte) {
						assert(len(end) == 0)
						ts := http.context_get(&c.ctx, Transition_State)
						ts.done = true
					})
				})
			},
			buf_cap   = http.STREAM_MAX_BUF_SIZE,
			reuse     = true,
		}
		testing.expect(t, http._scanner_pump_buffered(&c.scanner))
		testing.expect(t, http._scanner_prepare_recv_buf(&c.scanner))

		testing.expect(t, !c.scanner.buf_reusable, "expected reusable buffer to freeze on trailer scan")
		testing.expect(t, raw_data(c.scanner.buf) == orig_ptr, "expected in-place compaction without realloc")
		testing.expect_value(t, counter.alloc_count, allocs_before)
		testing.expect_value(t, c.scanner.read_head, 0)
		testing.expect_value(t, string(c.scanner.buf[:c.scanner.write_head]), "X-Tr: ")

		// Append remaining trailer line and verify completion.
		rest := "ok\r\n\r\n"
		c.scanner.write_head += copy(c.scanner.buf[c.scanner.write_head:], rest)
		testing.expect(t, !http._scanner_pump_buffered(&c.scanner))
		testing.expect(t, ts.done, "expected trailer completion")
		val, ok := http.get_header(&c.ctx, "X-Tr")
		testing.expect(t, ok, "expected trailer header")
		testing.expect_value(t, val, "ok")
	}

	// 2. .Retain (64 KiB full, < 512 bytes left) transitioning to .Grow detaches to a small 4 KiB block (not 128 KiB)
	//    and preserves previously retained slices untouched.
	{
		counter := Test_Counting_Allocator{backing = context.allocator}
		env: Test_Env
		test_env_init(&env, allocator = test_counting_allocator(&counter))
		defer test_env_destroy(&env)

		c: http.Connection
		test_conn_init(t, &c, &env, init_budgets = false)
		defer test_conn_destroy(&c)

		http.budget_init(&c.req.budget, nil)
		test_req_set_headers(t, &c, {{"Host", "localhost"}, {"Transfer-Encoding", "chunked"}})
		ts := http.context_add(&c.ctx, Transition_State{})

		buf_size := 64 * mem.Kilobyte - size_of(http._Arena_Block)
		buf, err := make([]byte, buf_size, http.transaction_allocator(&c))
		testing.expect_value(t, err, nil)
		for &b in buf[:len(buf)-16] { b = 'Z' }
		retained := buf[:1024]

		partial_trailer := "0\r\nX-Tr: "
		start := len(buf) - 16
		copy(buf[start:], partial_trailer)
		c.scanner.buf          = buf
		c.scanner.buf_reusable = false
		c.scanner.read_head    = start
		c.scanner.write_head   = start + len(partial_trailer)

		allocs_before := counter.alloc_count

		c.scanner.scan = {
			split     = http.split_line(),
			allocator = &c.transaction_arena,
			callback  = proc(c: ^http.Connection, data: []byte) {
				assert(string(data) == "0")
				http.scan_line(&c.scanner, proc(c: ^http.Connection, tr: []byte) {
					k, v, ok := http.header_parse(string(tr))
					assert(ok)
					http._headers_set_writable(&c.req.headers)
					_ = http.headers_add(&c.req.headers, k, v)
					http._headers_set_readonly(&c.req.headers)
					http.scan_line(&c.scanner, proc(c: ^http.Connection, end: []byte) {
						assert(len(end) == 0)
						ts := http.context_get(&c.ctx, Transition_State)
						ts.done = true
					})
				})
			},
			buf_cap   = http.RETAIN_MAX_BUF_SIZE,
			reuse     = false,
		}
		testing.expect(t, http._scanner_pump_buffered(&c.scanner))
		testing.expect(t, http._scanner_prepare_recv_buf(&c.scanner))

		testing.expect(t, !c.scanner.buf_reusable, "expected non-reusable buffer after trailer scan")
		testing.expect_value(t, len(c.transaction_arena.tail.data), 4 * mem.Kilobyte)
		testing.expect_value(t, len(c.scanner.buf), 1024)
		testing.expect_value(t, counter.alloc_count, allocs_before + 1)
		testing.expect_value(t, c.scanner.read_head, 0)
		testing.expect_value(t, string(c.scanner.buf[:c.scanner.write_head]), "X-Tr: ")
		for b in retained { testing.expect_value(t, b, u8('Z')) }

		rest := "ok\r\n\r\n"
		c.scanner.write_head += copy(c.scanner.buf[c.scanner.write_head:], rest)
		testing.expect(t, !http._scanner_pump_buffered(&c.scanner))
		testing.expect(t, ts.done, "expected trailer completion")
		val, ok := http.get_header(&c.ctx, "X-Tr")
		testing.expect(t, ok, "expected trailer header")
		testing.expect_value(t, val, "ok")
	}
}

@(test)
test_scanner_allocator_switch_oom_preserves_consistency :: proc(t: ^testing.T) {
	for payload in ([?]string{"hello", "hello\r\n"}) {
		fa := Test_Fail_Allocator{backing = context.allocator, fail = true}
		env: Test_Env
		test_env_init(&env)
		defer test_env_destroy(&env)

		c: http.Connection
		c.temp_arena = http.Arena{backing = test_fail_allocator(&fa)}
		test_conn_init(t, &c, &env, payload = payload, mock_handling = true, init_budgets = false)
		defer test_conn_destroy(&c)

		c.req.budget.max     = -1
		c.req.budget.timeout = -1

		prev_logger := context.logger
		context.logger = log.nil_logger()
		http.scan_temp_line(&c.scanner, proc(c: ^http.Connection, data: []byte) {})
		context.logger = prev_logger

		testing.expect_value(t, c.res.status, http.Status.Internal_Server_Error)
		testing.expect_value(t, c.res._state, type_of(c.res._state).Error)
		testing.expect_value(t, c.scanner.allocator, &c.transaction_arena)
		testing.expect(t, c.temp_arena.tail == nil, "expected failed temp_arena to remain empty")
		testing.expect_value(t, string(c.scanner.buf[c.scanner.read_head:c.scanner.write_head]), payload)
	}
}

@(test)
test_scanner_reset_after_reusable_body_and_alignment :: proc(t: ^testing.T) {
	counter := Test_Counting_Allocator{backing = context.allocator}
	env: Test_Env
	test_env_init(&env, allocator = test_counting_allocator(&counter))
	defer test_env_destroy(&env)

	c: http.Connection
	test_conn_init(t, &c, &env, init_budgets = false)
	defer test_conn_destroy(&c)

	// 1. scanner_reset after detached .Reuse body preserves pipelined bytes and resets mode/flag.
	buf, err := make([]byte, http.BODY_BUF_SIZE, http.transaction_allocator(&c))
	testing.expect_value(t, err, nil)
	pipelined := "GET /next HTTP/1.1\r\n"
	c.scanner.buf          = buf
	c.scanner.buf_reusable = true
	c.scanner.read_head    = 100
	c.scanner.write_head   = 100 + copy(buf[100:], pipelined)

	testing.expect_value(t, http.scanner_reset(&c.scanner, &c), nil)
	testing.expect(t, !c.scanner.buf_reusable, "expected scanner_reset to clear buf_reusable")
	testing.expect(t, c.transaction_arena.tail != nil && c.transaction_arena.tail.prev == nil, "expected single block after scanner_reset")
	testing.expect_value(t, len(c.transaction_arena.tail.data), 4 * mem.Kilobyte)
	testing.expect_value(t, string(c.scanner.buf[c.scanner.read_head:c.scanner.write_head]), pipelined)

	// 2. Carried-over 4096 - size_of(_Arena_Block) bytes fit inside a single 4 KiB block without overshooting to 8 KiB.
	exact_block_cap := 4 * mem.Kilobyte - size_of(http._Arena_Block)
	big_buf, berr := make([]byte, http.BODY_BUF_SIZE, http.transaction_allocator(&c))
	testing.expect_value(t, berr, nil)
	for i in 0..<exact_block_cap {
		big_buf[i] = u8('A' + (i % 26))
	}
	c.scanner.buf        = big_buf
	c.scanner.read_head  = 0
	c.scanner.write_head = exact_block_cap

	testing.expect_value(t, http.scanner_reset(&c.scanner, &c), nil)
	testing.expect_value(t, len(c.scanner.buf), exact_block_cap)
	testing.expect_value(t, len(c.transaction_arena.tail.data), 4 * mem.Kilobyte)
	testing.expect_value(t, c.scanner.write_head, exact_block_cap)
}
