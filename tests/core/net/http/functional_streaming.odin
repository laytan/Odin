#+build windows, linux, darwin
package test_core_net_http

import "base:sanitizer"

import c "core:c/libc"
import "core:fmt"
import "core:io"
import "core:mem"
import "core:net"
import "core:strings"
import "core:testing"
import "core:time"

import http "core:http2"
import "vendor:curl"

FNV1A_OFFSET :: u64(14695981039346656037)
FNV1A_PRIME  :: u64(1099511628211)

fnv1a_step :: proc(h: u64, data: []byte) -> u64 {
	res := h
	for b in data {
		res = (res ~ u64(b)) * FNV1A_PRIME
	}
	return res
}

write_test_pattern :: proc(buf: []byte, start_pos: int) {
	for i in 0..<len(buf) {
		buf[i] = u8(((start_pos + i) * 31 + 7) & 0xFF)
	}
}

expected_pattern_hash :: proc(total: int) -> u64 {
	h := FNV1A_OFFSET
	buf: [16 * 1024]byte
	pos := 0
	for pos < total {
		n := min(len(buf), total - pos)
		write_test_pattern(buf[:n], pos)
		h = fnv1a_step(h, buf[:n])
		pos += n
	}
	return h
}

Stream_Hash_Result :: struct {
	setopt_ok:   bool,
	perform_err: curl.code,
	getinfo_err: curl.code,
	status:      c.long,
	count:       int,
	hash:        u64,
	small_buf:   [64]byte,
	small_len:   int,
}

curl_write_hash :: proc "c" (contents: [^]byte, size: c.size_t, nmemb: c.size_t, userp: rawptr) -> c.size_t {
	r := (^Stream_Hash_Result)(userp)
	n := int(size) * int(nmemb)
	for i in 0..<n {
		r.hash = (r.hash ~ u64(contents[i])) * FNV1A_PRIME
	}
	if r.count < len(r.small_buf) {
		copied := copy(r.small_buf[r.small_len:], contents[:min(n, len(r.small_buf) - r.small_len)])
		r.small_len += copied
	}
	r.count += n
	return c.size_t(n)
}

expect_stream_hash :: proc(t: ^testing.T, name: string, got: ^Stream_Hash_Result, exp_len: int, exp_hash: u64, loc := #caller_location) {
	testing.expectf(t, got.setopt_ok, "%s: setopt failed", name, loc = loc)
	testing.expectf(t, got.perform_err == .E_OK, "%s: curl failed: %s", name, curl.easy_strerror(got.perform_err), loc = loc)
	testing.expect_value(t, got.getinfo_err, curl.code.E_OK, loc = loc)
	testing.expect_value(t, got.status, c.long(200), loc = loc)
	testing.expect_value(t, got.count, exp_len, loc = loc)
	testing.expect_value(t, got.hash, exp_hash, loc = loc)
}

@(test)
test_streaming_body_bounded_memory :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)

	UPLOAD_SIZE :: 2 * mem.Megabyte
	PARSED_SIZE :: 128 * mem.Kilobyte
	CHUNK_SIZE  :: 16 * mem.Kilobyte

	Stream_State :: struct {
		count:    int,
		hash:     u64,
		track:    ^mem.Tracking_Allocator,
		peak_out: ^i64,
		sentinel: []byte,
	}

	Server_Check :: struct {
		track:              ^mem.Tracking_Allocator,
		peak_after_cl:      i64,
		peak_after_chunked: i64,
		cl_temp_ok:         bool,
		chunked_temp_ok:    bool,
	}

	server_track: mem.Tracking_Allocator
	test_tracking_init(&server_track)
	defer mem.tracking_allocator_destroy(&server_track)

	srv_check := Server_Check{track = &server_track}

	r: http.Router
	defer http.router_destroy(r)

	http.route_post(&r, "/stream-cl", http.handler(&srv_check, proc(user_data: rawptr, ctx: ^http.Ctx) {
		chk := (^Server_Check)(user_data)
		sentinel, serr := make([]byte, 128, context.temp_allocator)
		if serr != nil {
			ctx.res.status = .Internal_Server_Error
			http.respond(ctx)
			return
		}
		for &b in sentinel { b = 0x5A }

		http.context_add(ctx, Stream_State{
			hash     = FNV1A_OFFSET,
			track    = chk.track,
			peak_out = &chk.peak_after_cl,
			sentinel = sentinel,
		})
		http.context_add(ctx, chk)

		http.body(ctx, proc(ctx: ^http.Ctx, body: []byte, is_partial: bool) {
			st := http.context_get(ctx, Stream_State)
			st.hash = fnv1a_step(st.hash, body)
			st.count += len(body)

			if !is_partial {
				chk := http.context_get(ctx, ^Server_Check)^
				st.peak_out^ = st.track.peak_memory_allocated
				temp_ok := len(st.sentinel) == 128 && sanitizer.address_region_is_poisoned(st.sentinel) == nil
				for b in st.sentinel {
					if b != 0x5A { temp_ok = false }
				}
				chk.cl_temp_ok = temp_ok
				tag, _ := http.get_header(ctx, "X-Request-Tag")
				http.set_header(ctx, "connection", "close")
				http.respond_plain(ctx, fmt.aprintf("%d:%d:%s", st.count, st.hash, tag, allocator = http.transaction_allocator(ctx)))
			}
		})
	}))

	http.route_post(&r, "/stream-chunked", http.handler(&srv_check, proc(user_data: rawptr, ctx: ^http.Ctx) {
		chk := (^Server_Check)(user_data)
		sentinel, serr := make([]byte, 128, context.temp_allocator)
		if serr != nil {
			ctx.res.status = .Internal_Server_Error
			http.respond(ctx)
			return
		}
		for &b in sentinel { b = 0xA5 }

		http.context_add(ctx, Stream_State{
			hash     = FNV1A_OFFSET,
			track    = chk.track,
			peak_out = &chk.peak_after_chunked,
			sentinel = sentinel,
		})
		http.context_add(ctx, chk)

		http.body(ctx, proc(ctx: ^http.Ctx, body: []byte, is_partial: bool) {
			st := http.context_get(ctx, Stream_State)
			st.hash = fnv1a_step(st.hash, body)
			st.count += len(body)

			if !is_partial {
				chk := http.context_get(ctx, ^Server_Check)^
				st.peak_out^ = st.track.peak_memory_allocated
				temp_ok := len(st.sentinel) == 128 && sanitizer.address_region_is_poisoned(st.sentinel) == nil
				for b in st.sentinel {
					if b != 0xA5 { temp_ok = false }
				}
				chk.chunked_temp_ok = temp_ok
				tag, _ := http.get_header(ctx, "X-Request-Tag")
				tr, _  := http.get_header(ctx, "X-Trailer-Check")
				http.set_header(ctx, "connection", "close")
				http.respond_plain(ctx, fmt.aprintf("%d:%d:%s:%s", st.count, st.hash, tag, tr, allocator = http.transaction_allocator(ctx)))
			}
		})
	}))

	http.route_post(&r, "/parsed", http.body_parser, proc(ctx: ^http.Ctx) {
		bps: http.Body_Parser_Stream
		http.body_parser_stream_init(&bps, ctx)
		stream := http.body_parser_stream(&bps)

		h := FNV1A_OFFSET
		total := 0
		buf: [4096]byte
		for {
			n, rerr := io.read(stream, buf[:])
			if n > 0 {
				h = fnv1a_step(h, buf[:n])
				total += n
			}
			if rerr == .EOF { break }
			if rerr != nil {
				ctx.res.status = .Internal_Server_Error
				http.respond(ctx)
				return
			}
		}
		http.set_header(ctx, "connection", "close")
		http.respond_plain(ctx, fmt.aprintf("%d:%d", total, h, allocator = http.transaction_allocator(ctx)))
	})

	Client_Result :: struct {
		cl_ok:        bool,
		chunked_ok:   bool,
		parsed_ok:    bool,
		cl_body:      [256]byte,
		cl_len:       int,
		chunked_body: [256]byte,
		chunked_len:  int,
		parsed_body:  [256]byte,
		parsed_len:   int,
	}
	res: Client_Result

	_, ok := run_test_server(
		t,
		{body_limits = {max_size = 4 * mem.Megabyte, min = 5 * time.Second}, handlers = {http.router(&r)}},
		&res,
		proc(port: int, _: ^http.Server, res: ^Client_Result) {
			endpoint := net.Endpoint{net.IP4_Loopback, port}

			send_all :: proc(sock: net.TCP_Socket, bytes: []byte) -> bool {
				sent := 0
				for sent < len(bytes) {
					n, serr := net.send_tcp(sock, bytes[sent:])
					if serr != nil || n <= 0 { return false }
					sent += n
				}
				return true
			}

			recv_body :: proc(sock: net.TCP_Socket, out_body: []byte) -> (n: int, ok: bool) {
				resp_buf: [2048]byte
				total := 0
				for total < len(resp_buf) {
					rn, rerr := net.recv_tcp(sock, resp_buf[total:])
					if rn > 0 { total += rn }
					if rn == 0 || rerr != nil { break }
				}
				sep := strings.index(string(resp_buf[:total]), "\r\n\r\n")
				if sep < 0 || !strings.has_prefix(string(resp_buf[:total]), "HTTP/1.1 200 ") {
					return 0, false
				}
				body := resp_buf[sep+4:total]
				return copy(out_body, body), len(body) <= len(out_body)
			}

			WRITE_SIZE :: 64 * mem.Kilobyte
			payload: [WRITE_SIZE]byte
			hdr_buf: [512]byte

			// 1. 2 MiB Content-Length upload (64 KiB TCP writes to exercise adaptive .Reuse ramp-up).
			if sock, derr := net.dial_tcp(endpoint); derr == nil {
				defer net.close(sock)
				hdr := fmt.bprintf(hdr_buf[:], "POST /stream-cl HTTP/1.1\r\nHost: localhost\r\nX-Request-Tag: keep-me\r\nContent-Length: %d\r\n\r\n", UPLOAD_SIZE)
				ok := send_all(sock, transmute([]byte)hdr)
				for pos := 0; ok && pos < UPLOAD_SIZE; {
					n := min(len(payload), UPLOAD_SIZE - pos)
					write_test_pattern(payload[:n], pos)
					ok = send_all(sock, payload[:n])
					pos += n
				}
				if ok { res.cl_len, res.cl_ok = recv_body(sock, res.cl_body[:]) }
			}

			// 2. 2 MiB Transfer-Encoding: chunked upload with trailer.
			if sock, derr := net.dial_tcp(endpoint); derr == nil {
				defer net.close(sock)
				hdr := "POST /stream-chunked HTTP/1.1\r\nHost: localhost\r\nX-Request-Tag: keep-me\r\nTransfer-Encoding: chunked\r\nTrailer: X-Trailer-Check\r\n\r\n"
				ok := send_all(sock, transmute([]byte)hdr)
				for pos := 0; ok && pos < UPLOAD_SIZE; {
					n := min(CHUNK_SIZE, UPLOAD_SIZE - pos)
					chunk_hdr := fmt.bprintf(hdr_buf[:], "%x\r\n", n)
					write_test_pattern(payload[:n], pos)
					ok = send_all(sock, transmute([]byte)chunk_hdr) &&
						send_all(sock, payload[:n]) &&
						send_all(sock, transmute([]byte)string("\r\n"))
					pos += n
				}
				if ok { ok = send_all(sock, transmute([]byte)string("0\r\nX-Trailer-Check: ok-trailer\r\n\r\n")) }
				if ok { res.chunked_len, res.chunked_ok = recv_body(sock, res.chunked_body[:]) }
			}

			// 3. 128 KiB body_parser upload across multiple writes.
			if sock, derr := net.dial_tcp(endpoint); derr == nil {
				defer net.close(sock)
				hdr := fmt.bprintf(hdr_buf[:], "POST /parsed HTTP/1.1\r\nHost: localhost\r\nContent-Length: %d\r\n\r\n", PARSED_SIZE)
				ok := send_all(sock, transmute([]byte)hdr)
				for pos := 0; ok && pos < PARSED_SIZE; {
					n := min(4096, PARSED_SIZE - pos)
					write_test_pattern(payload[:n], pos)
					ok = send_all(sock, payload[:n])
					pos += n
				}
				if ok { res.parsed_len, res.parsed_ok = recv_body(sock, res.parsed_body[:]) }
			}
		},
		allocator = mem.tracking_allocator(&server_track),
	)
	if !ok { return }

	expected_2m  := expected_pattern_hash(UPLOAD_SIZE)
	expected_128 := expected_pattern_hash(PARSED_SIZE)

	testing.expect(t, res.cl_ok, "expected 2 MiB Content-Length streaming upload to succeed")
	testing.expect_value(t, string(res.cl_body[:res.cl_len]), fmt.tprintf("%d:%d:keep-me", UPLOAD_SIZE, expected_2m))
	testing.expect(t, res.chunked_ok, "expected 2 MiB chunked streaming upload to succeed")
	testing.expect_value(t, string(res.chunked_body[:res.chunked_len]), fmt.tprintf("%d:%d:keep-me:ok-trailer", UPLOAD_SIZE, expected_2m))
	testing.expect(t, res.parsed_ok, "expected 128 KiB body_parser upload to succeed")
	testing.expect_value(t, string(res.parsed_body[:res.parsed_len]), fmt.tprintf("%d:%d", PARSED_SIZE, expected_128))

	testing.expect(t, srv_check.cl_temp_ok, "expected temp_allocator data preserved during Content-Length streaming")
	testing.expect(t, srv_check.chunked_temp_ok, "expected temp_allocator data preserved during chunked streaming")
	testing.expect(t, srv_check.peak_after_cl > 0 && srv_check.peak_after_cl < 768 * mem.Kilobyte, "expected O(1) bounded peak memory during 2 MiB Content-Length streaming")
	testing.expect(t, srv_check.peak_after_chunked > 0 && srv_check.peak_after_chunked < 768 * mem.Kilobyte, "expected O(1) bounded peak memory during 2 MiB chunked streaming")
	testing.expect(t, server_track.peak_memory_allocated < 768 * mem.Kilobyte, "expected bounded peak memory after 128 KiB body_parser upload")

	testing.expect_value(t, server_track.current_memory_allocated, 0)
	testing.expect_value(t, len(server_track.bad_free_array), 0)
}

@(test)
test_streaming_response_bounded_memory :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)

	STREAM_SIZE      :: 2 * mem.Megabyte
	CHUNK_SIZE       :: 4 * mem.Kilobyte
	BURST_CHUNKS     :: 4
	BURST_CHUNK_SIZE :: 1024

	server_track: mem.Tracking_Allocator
	test_tracking_init(&server_track)
	defer mem.tracking_allocator_destroy(&server_track)

	Server_Peak_Check :: struct {
		track:                ^mem.Tracking_Allocator,
		peak_seq:             i64,
		peak_burst:           i64,
		seq_zero_tx_growth:   bool,
		burst_zero_tx_growth: bool,
		burst_saw_multi:      bool,
	}
	srv_check := Server_Peak_Check{track = &server_track}

	r: http.Router
	defer http.router_destroy(r)

	// 1. Sequential send_chunk streaming (depth=1, reusing one 4 KiB buffer and inline_hdr).
	Seq_State :: struct {
		buf:         [CHUNK_SIZE]byte,
		pos:         int,
		chunks:      int,
		tx_tail_1:   rawptr,
		tx_offset_1: int,
		chk:         ^Server_Peak_Check,
	}
	http.route_get(&r, "/seq", http.handler(&srv_check, proc(user_data: rawptr, ctx: ^http.Ctx) {
		chk := (^Server_Peak_Check)(user_data)
		if _, err := http.context_add(ctx, Seq_State{chk = chk}); err != nil {
			ctx.res.status = .Internal_Server_Error
			http.respond(ctx)
			return
		}

		send_next :: proc(ctx: ^http.Ctx, err: http.Send_Error) {
			if err != nil || ctx.res._state == .Error { return }
			c  := http._connection_of_context(ctx)
			st := http.context_get(ctx, Seq_State)
			if st.pos >= STREAM_SIZE {
				st.chk.peak_seq = st.chk.track.peak_memory_allocated
				st.chk.seq_zero_tx_growth =
					st.tx_tail_1 != nil &&
					rawptr(c.transaction_arena.tail) == st.tx_tail_1 &&
					c.transaction_arena.tail.offset == st.tx_offset_1
				http.respond(ctx)
				return
			}
			n := min(len(st.buf), STREAM_SIZE - st.pos)
			write_test_pattern(st.buf[:n], st.pos)
			st.pos    += n
			st.chunks += 1
			http.send_chunk(ctx, {st.buf[:n]}, send_next)
			if st.chunks == 1 && c.transaction_arena.tail != nil {
				st.tx_tail_1   = c.transaction_arena.tail
				st.tx_offset_1 = c.transaction_arena.tail.offset
			}
		}

		send_next(ctx, nil)
	}))

	// 2. Bursty send_chunk streaming (4 x 1 KiB chunks per burst, draining to _sends == 0 between bursts).
	Burst_State :: struct {
		bufs:        [BURST_CHUNKS][BURST_CHUNK_SIZE]byte,
		pos:         int,
		bursts:      int,
		tx_tail_1:   rawptr,
		tx_offset_1: int,
		chk:         ^Server_Peak_Check,
	}
	http.route_get(&r, "/burst", http.handler(&srv_check, proc(user_data: rawptr, ctx: ^http.Ctx) {
		chk := (^Server_Peak_Check)(user_data)
		if _, err := http.context_add(ctx, Burst_State{chk = chk}); err != nil {
			ctx.res.status = .Internal_Server_Error
			http.respond(ctx)
			return
		}

		send_burst :: proc(ctx: ^http.Ctx) {
			if ctx.res._state == .Error { return }
			c  := http._connection_of_context(ctx)
			st := http.context_get(ctx, Burst_State)
			if st.pos >= STREAM_SIZE {
				st.chk.peak_burst = st.chk.track.peak_memory_allocated
				st.chk.burst_zero_tx_growth =
					st.tx_tail_1 != nil &&
					rawptr(c.transaction_arena.tail) == st.tx_tail_1 &&
					c.transaction_arena.tail.offset == st.tx_offset_1
				http.respond(ctx)
				return
			}

			st.bursts += 1
			for i in 0..<BURST_CHUNKS {
				if st.pos >= STREAM_SIZE { break }
				n := min(len(st.bufs[i]), STREAM_SIZE - st.pos)
				write_test_pattern(st.bufs[i][:n], st.pos)
				st.pos += n
				if ctx.res._sends > 0 {
					st.chk.burst_saw_multi = true
				}
				http.send_chunk(ctx, {st.bufs[i][:n]}, on_burst_part)
			}
			if st.bursts == 1 && c.transaction_arena.tail != nil {
				st.tx_tail_1   = c.transaction_arena.tail
				st.tx_offset_1 = c.transaction_arena.tail.offset
			}
		}

		on_burst_part :: proc(ctx: ^http.Ctx, err: http.Send_Error) {
			if err != nil || ctx.res._state == .Error || ctx.res._sends > 0 { return }
			send_burst(ctx)
		}

		send_burst(ctx)
	}))

	http.route_get(&r, "/after", proc(ctx: ^http.Ctx) {
		http.respond_plain(ctx, "still-alive")
	})

	Client_Result :: struct {
		handle_ok: bool,
		seq:       Stream_Hash_Result,
		burst:     Stream_Hash_Result,
		after:     Stream_Hash_Result,
	}
	res: Client_Result

	_, ok := run_test_server(
		t,
		{response_limits = http.NO_LIMITS, handlers = {http.router(&r)}},
		&res,
		proc(port: int, _: ^http.Server, res: ^Client_Result) {
			handle := curl.easy_init()
			res.handle_ok = handle != nil
			if handle == nil { return }
			defer curl.easy_cleanup(handle)

			do_req :: proc(handle: ^curl.CURL, port: int, path: string, out: ^Stream_Hash_Result) {
				out.hash = FNV1A_OFFSET
				url := fmt.ctprintf("http://127.0.0.1:%d%s", port, path)
				out.setopt_ok =
					curl.easy_setopt(handle, .HTTPGET, c.long(1)) == .E_OK &&
					curl.easy_setopt(handle, .URL, url) == .E_OK &&
					curl.easy_setopt(handle, .WRITEFUNCTION, curl_write_hash) == .E_OK &&
					curl.easy_setopt(handle, .WRITEDATA, out) == .E_OK
				if !out.setopt_ok { return }
				out.perform_err = curl.easy_perform(handle)
				out.getinfo_err = curl.easy_getinfo(handle, .RESPONSE_CODE, &out.status)
			}

			do_req(handle, port, "/seq",   &res.seq)
			do_req(handle, port, "/burst", &res.burst)
			do_req(handle, port, "/after", &res.after)
		},
		allocator = mem.tracking_allocator(&server_track),
	)
	if !ok || !testing.expect(t, res.handle_ok, "curl.easy_init failed") { return }

	expected_hash := expected_pattern_hash(STREAM_SIZE)
	expect_stream_hash(t, "seq",   &res.seq,   STREAM_SIZE, expected_hash)
	expect_stream_hash(t, "burst", &res.burst, STREAM_SIZE, expected_hash)

	testing.expect_value(t, res.after.perform_err, curl.code.E_OK)
	testing.expect_value(t, res.after.status, c.long(200))
	testing.expect_value(t, string(res.after.small_buf[:res.after.small_len]), "still-alive")

	testing.expect(t, srv_check.seq_zero_tx_growth, "expected zero transaction_arena growth after first sequential chunk")
	testing.expect(t, srv_check.burst_saw_multi, "expected bursty send_chunk to have overlapping sends in flight")
	testing.expect(t, srv_check.burst_zero_tx_growth, "expected zero transaction_arena growth after first drained burst")
	testing.expect(t, srv_check.peak_seq > 0 && srv_check.peak_seq < 256 * mem.Kilobyte, "expected O(1) bounded peak memory during 2 MiB sequential send_chunk")
	testing.expect(t, srv_check.peak_burst > 0 && srv_check.peak_burst < 256 * mem.Kilobyte, "expected O(max_burst) bounded peak memory during 2 MiB bursty send_chunk")
	testing.expect(t, server_track.peak_memory_allocated < 256 * mem.Kilobyte, "expected O(1) bounded overall server peak memory across all 2 MiB streams")

	testing.expect_value(t, server_track.current_memory_allocated, 0)
	testing.expect_value(t, len(server_track.bad_free_array), 0)
}

@(test)
test_streaming_body_backpressure_zero_copy :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 10 * time.Second)

	STREAM_SIZE :: 2 * mem.Megabyte

	server_track: mem.Tracking_Allocator
	test_tracking_init(&server_track)
	defer mem.tracking_allocator_destroy(&server_track)

	Echo_Stats :: struct {
		track:                    ^mem.Tracking_Allocator,
		cl_pauses:                int,
		chunked_pauses:           int,
		cl_steady_chunks:         int,
		chunked_steady:           int,
		cl_unexpected_alloc:      bool,
		chunked_unexpected_alloc: bool,
	}
	stats := Echo_Stats{track = &server_track}

	Echo_Kind :: enum {
		Content_Length,
		Chunked,
	}
	Echo_Req :: struct {
		stats:      ^Echo_Stats,
		kind:       Echo_Kind,
		chunks:     int,
		prev_buf:   int,
		prev_alloc: i64,
	}

	handle_echo :: proc(ctx: ^http.Ctx, stats: ^Echo_Stats, kind: Echo_Kind) {
		if _, err := http.context_add(ctx, Echo_Req{stats = stats, kind = kind}); err != nil {
			ctx.res.status = .Internal_Server_Error
			http.respond(ctx)
			return
		}

		on_echo_sent :: proc(ctx: ^http.Ctx, err: http.Send_Error) {
			if err != nil || ctx.res._state == .Error { return }
			http.body_resume(ctx)
		}

		http.body(ctx, proc(ctx: ^http.Ctx, body: []byte, is_partial: bool) {
			c  := http._connection_of_context(ctx)
			er := http.context_get(ctx, Echo_Req)
			st := er.stats

			if !is_partial {
				if er.chunks >= 2 && st.track.total_memory_allocated != er.prev_alloc {
					switch er.kind {
					case .Content_Length: st.cl_unexpected_alloc = true
					case .Chunked:        st.chunked_unexpected_alloc = true
					}
				}
				http.respond(ctx)
				return
			}

			er.chunks += 1
			cur_buf   := len(c.scanner.buf)
			cur_alloc := st.track.total_memory_allocated
			if er.chunks >= 2 && cur_buf == er.prev_buf {
				if cur_alloc != er.prev_alloc {
					switch er.kind {
					case .Content_Length: st.cl_unexpected_alloc = true
					case .Chunked:        st.chunked_unexpected_alloc = true
					}
				}
				switch er.kind {
				case .Content_Length: st.cl_steady_chunks += 1
				case .Chunked:        st.chunked_steady += 1
				}
			}
			er.prev_buf = cur_buf

			http.body_pause(ctx)
			switch er.kind {
			case .Content_Length: st.cl_pauses += 1
			case .Chunked:        st.chunked_pauses += 1
			}
			// Zero-copy pass of `retain = false` scanner slice directly into async `send_chunk`.
			http.send_chunk(ctx, {body}, on_echo_sent)
			er.prev_alloc = st.track.total_memory_allocated
		}, retain = false)
	}

	r: http.Router
	defer http.router_destroy(r)

	http.route_post(&r, "/echo-cl", http.handler(&stats, proc(user_data: rawptr, ctx: ^http.Ctx) {
		handle_echo(ctx, (^Echo_Stats)(user_data), .Content_Length)
	}))
	http.route_post(&r, "/echo-chunked", http.handler(&stats, proc(user_data: rawptr, ctx: ^http.Ctx) {
		handle_echo(ctx, (^Echo_Stats)(user_data), .Chunked)
	}))
	http.route_get(&r, "/after", proc(ctx: ^http.Ctx) {
		http.respond_plain(ctx, "still-alive")
	})

	Upload_State :: struct {
		sent:  int,
		total: int,
	}

	Client_Result :: struct {
		handle_ok: bool,
		cl:        Stream_Hash_Result,
		chunked:   Stream_Hash_Result,
		after:     Stream_Hash_Result,
	}
	res: Client_Result

	_, ok := run_test_server(
		t,
		{body_limits = http.NO_LIMITS, response_limits = http.NO_LIMITS, handlers = {http.router(&r)}},
		&res,
		proc(port: int, _: ^http.Server, res: ^Client_Result) {
			handle := curl.easy_init()
			res.handle_ok = handle != nil
			if handle == nil { return }
			defer curl.easy_cleanup(handle)

			read_pattern :: proc "c" (ptr: [^]byte, size: c.size_t, nmemb: c.size_t, userdata: rawptr) -> c.size_t {
				st := (^Upload_State)(userdata)
				if st.sent >= st.total { return 0 }
				max_n := min(int(size) * int(nmemb), 16 * 1024)
				n := min(max_n, st.total - st.sent)
				for i in 0..<n {
					ptr[i] = u8(((st.sent + i) * 31 + 7) & 0xFF)
				}
				st.sent += n
				return c.size_t(n)
			}

			// 1. POST /echo-cl with Content-Length: 2 MiB.
			{
				up := Upload_State{total = STREAM_SIZE}
				res.cl.hash = FNV1A_OFFSET
				hdrs := curl.slist_append(nil, "Expect:")
				defer curl.slist_free_all(hdrs)
				url := fmt.ctprintf("http://127.0.0.1:%d/echo-cl", port)
				res.cl.setopt_ok =
					curl.easy_setopt(handle, .URL, url) == .E_OK &&
					curl.easy_setopt(handle, .POST, c.long(1)) == .E_OK &&
					curl.easy_setopt(handle, .POSTFIELDSIZE, c.long(STREAM_SIZE)) == .E_OK &&
					curl.easy_setopt(handle, .HTTPHEADER, hdrs) == .E_OK &&
					curl.easy_setopt(handle, .READFUNCTION, read_pattern) == .E_OK &&
					curl.easy_setopt(handle, .READDATA, &up) == .E_OK &&
					curl.easy_setopt(handle, .WRITEFUNCTION, curl_write_hash) == .E_OK &&
					curl.easy_setopt(handle, .WRITEDATA, &res.cl) == .E_OK
				if res.cl.setopt_ok {
					res.cl.perform_err = curl.easy_perform(handle)
					res.cl.getinfo_err = curl.easy_getinfo(handle, .RESPONSE_CODE, &res.cl.status)
				}
			}

			// 2. POST /echo-chunked with Transfer-Encoding: chunked (2 MiB).
			{
				up := Upload_State{total = STREAM_SIZE}
				res.chunked.hash = FNV1A_OFFSET
				hdrs := curl.slist_append(nil, "Transfer-Encoding: chunked")
				hdrs = curl.slist_append(hdrs, "Expect:")
				defer curl.slist_free_all(hdrs)
				url := fmt.ctprintf("http://127.0.0.1:%d/echo-chunked", port)
				res.chunked.setopt_ok =
					curl.easy_setopt(handle, .URL, url) == .E_OK &&
					curl.easy_setopt(handle, .POST, c.long(1)) == .E_OK &&
					curl.easy_setopt(handle, .POSTFIELDSIZE, c.long(-1)) == .E_OK &&
					curl.easy_setopt(handle, .HTTPHEADER, hdrs) == .E_OK &&
					curl.easy_setopt(handle, .READFUNCTION, read_pattern) == .E_OK &&
					curl.easy_setopt(handle, .READDATA, &up) == .E_OK &&
					curl.easy_setopt(handle, .WRITEFUNCTION, curl_write_hash) == .E_OK &&
					curl.easy_setopt(handle, .WRITEDATA, &res.chunked) == .E_OK
				if res.chunked.setopt_ok {
					res.chunked.perform_err = curl.easy_perform(handle)
					res.chunked.getinfo_err = curl.easy_getinfo(handle, .RESPONSE_CODE, &res.chunked.status)
				}
			}

			// 3. GET /after verifying server stays healthy.
			{
				curl.easy_reset(handle)
				res.after.hash = FNV1A_OFFSET
				url := fmt.ctprintf("http://127.0.0.1:%d/after", port)
				res.after.setopt_ok =
					curl.easy_setopt(handle, .URL, url) == .E_OK &&
					curl.easy_setopt(handle, .HTTPGET, c.long(1)) == .E_OK &&
					curl.easy_setopt(handle, .WRITEFUNCTION, curl_write_hash) == .E_OK &&
					curl.easy_setopt(handle, .WRITEDATA, &res.after) == .E_OK
				if res.after.setopt_ok {
					res.after.perform_err = curl.easy_perform(handle)
					res.after.getinfo_err = curl.easy_getinfo(handle, .RESPONSE_CODE, &res.after.status)
				}
			}
		},
		allocator = mem.tracking_allocator(&server_track),
	)
	if !ok || !testing.expect(t, res.handle_ok, "curl.easy_init failed") { return }

	expected_hash := expected_pattern_hash(STREAM_SIZE)
	expect_stream_hash(t, "echo-cl",      &res.cl,      STREAM_SIZE, expected_hash)
	expect_stream_hash(t, "echo-chunked", &res.chunked, STREAM_SIZE, expected_hash)

	testing.expect(t, res.after.setopt_ok, "after: setopt failed")
	testing.expectf(t, res.after.perform_err == .E_OK, "after: curl failed: %s", curl.easy_strerror(res.after.perform_err))
	testing.expect_value(t, res.after.status, c.long(200))
	testing.expect_value(t, string(res.after.small_buf[:res.after.small_len]), "still-alive")

	testing.expect(t, stats.cl_pauses > 10, "expected Content-Length echo to pause across many chunks")
	testing.expect(t, stats.chunked_pauses > 10, "expected chunked echo to pause across many chunks")
	testing.expect(t, stats.cl_steady_chunks > 10 && !stats.cl_unexpected_alloc, "expected zero per-chunk allocations during paused Content-Length echo")
	testing.expect(t, stats.chunked_steady > 10 && !stats.chunked_unexpected_alloc, "expected zero per-chunk allocations during paused chunked echo")
	testing.expect(t, server_track.peak_memory_allocated < 768 * mem.Kilobyte, "expected O(1) bounded peak server memory across 2 MiB paused zero-copy echoes")

	testing.expect_value(t, server_track.current_memory_allocated, 0)
	testing.expect_value(t, len(server_track.bad_free_array), 0)
}
