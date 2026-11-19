package http

import "base:runtime"

import "core:strings"
import "core:bytes"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:time"

Scan_Splitter :: struct {
	procedure: proc(user_data: rawptr, data: []byte) -> (int, int, int, bool),
	user_data: rawptr,
}

Scan_Cb :: proc(c: ^Connection, data: []byte)

Scan :: struct #all_or_none {
	split:     Scan_Splitter,
	allocator: ^Arena,
	callback:  Scan_Cb,
}

Scanner :: struct {
	c:          ^Connection,

	buf:        []byte,
	read_head:  int,
	write_head: int,
	allocator:  ^Arena,

	scan:       Scan,

	is_pumping:      bool,
	_pump_destroyed: ^bool,

	last_recv_start: time.Time,
}

MULTIPLIER :: 512

scanner_reset :: proc(s: ^Scanner, c: ^Connection) {
	is_pumping := s.is_pumping
	pump_destroyed := s._pump_destroyed
	to_copy := s.buf[s.read_head:s.write_head]
	if len(to_copy) == 0 {
		transaction_allocator_destroy(c)
		s^ = {
			c               = c,
			is_pumping      = is_pumping,
			_pump_destroyed = pump_destroyed,
		}
		return
	}

	to_alloc := max(MULTIPLIER, len(to_copy))
	log.debugf("http[t=%v][c=%v]: msg=\"scanner_reset\", to_copy=%v, to_alloc=%v", td.id, c.socket, len(to_copy), to_alloc)

	new_arena := _server_thread_get_free_arena(to_alloc)
	new_buf, err := make([]byte, to_alloc, mem.arena_allocator(new_arena))
	assert(err == nil)
	new_arena.last = raw_data(new_buf)
	n := copy(new_buf, to_copy)

	transaction_allocator_destroy(c)
	c.transaction_arena.tail = new_arena

	s^ = {
		c               = c,
		buf             = new_buf,
		read_head       = 0,
		write_head      = n,
		allocator       = &c.transaction_arena,
		is_pumping      = is_pumping,
		_pump_destroyed = pump_destroyed,
	}
}

_scanner_free_all :: proc(s: ^Scanner, a: ^Arena) -> (handled: bool) {
	if a != s.allocator {
		return false
	}

	to_copy := s.buf[s.read_head:s.write_head]
	to_alloc := max(MULTIPLIER, len(to_copy))
	log.debugf("http[t=%v][c=%v]: msg=\"scanner_free_all\", to_copy=%v, to_alloc=%v", td.id, s.c.socket, len(to_copy), to_alloc)

	if len(to_copy) == 0 {
		s.buf = {}
		s.read_head, s.write_head = 0, 0
		return false
	}

	new_arena := _server_thread_get_free_arena(to_alloc)
	err: runtime.Allocator_Error
	s.buf, err = make([]byte, to_alloc, mem.arena_allocator(new_arena))
	assert(err == nil)
	new_arena.last = raw_data(s.buf)
	s.read_head  = 0
	s.write_head = copy(s.buf, to_copy)

	arena_free_all(a)
	a.tail = new_arena
	return true
}

_scan_bytes :: proc(s: ^Scanner, n: int, allocator: ^Arena, cb: Scan_Cb) {
	s.scan = {
		split     = split_n(n),
		allocator = allocator,
		callback  = cb,
	}
	scanner_pump(s)
}

scan_bytes :: proc(s: ^Scanner, n: int, cb: Scan_Cb) {
	_scan_bytes(s, n, &s.c.transaction_arena, cb)
}

scan_temp_bytes :: proc(s: ^Scanner, n: int, cb: Scan_Cb) {
	_scan_bytes(s, n, &s.c.temp_arena, cb)
}

_scan_at_most :: proc(s: ^Scanner, n: int, allocator: ^Arena, cb: Scan_Cb) {
	s.scan = {
		split     = split_at_most(n),
		allocator = allocator,
		callback  = cb,
	}
	scanner_pump(s)
}

scan_at_most :: proc(s: ^Scanner, n: int, cb: Scan_Cb) {
	_scan_at_most(s, n, &s.c.transaction_arena, cb)
}

scan_temp_at_most :: proc(s: ^Scanner, n: int, cb: Scan_Cb) {
	_scan_at_most(s, n, &s.c.temp_arena, cb)
}

_scan_line :: proc(s: ^Scanner, allocator: ^Arena, cb: Scan_Cb) {
	s.scan = {
		split     = split_line(),
		allocator = allocator,
		callback  = cb,
	}
	scanner_pump(s)
}

scan_line :: proc(s: ^Scanner, cb: Scan_Cb) {
	_scan_line(s, &s.c.transaction_arena, cb)
}

scan_temp_line :: proc(s: ^Scanner, cb: Scan_Cb) {
	_scan_line(s, &s.c.temp_arena, cb)
}

split_n :: proc(n: int) -> Scan_Splitter {
	return {
		procedure = proc(needed: rawptr, data: []byte) -> (offset, n, advance: int, ok: bool) {
			needed := int(uintptr(needed))
			if len(data) < needed {
				return
			}

			return 0, needed, needed, true
		},
		user_data = rawptr(uintptr(n)),
	}
}

split_at_most :: proc(n: int) -> Scan_Splitter {
	return {
		procedure = proc(at_most: rawptr, data: []byte) -> (offset, n, advance: int, ok: bool) {
			at_most := int(uintptr(at_most))
			take    := min(len(data), at_most)
			return 0, take, take, take > 0
		},
		user_data = rawptr(uintptr(n)),
	}
}

split_line :: proc() -> Scan_Splitter {
	return {
		procedure = proc(_: rawptr, data: []byte) -> (offset, n, advance: int, ok: bool) {
			start := 0
			for {
				index := bytes.index_byte(data[start:], '\r')
				if index < 0 {
					return
				}
				index += start

				if len(data) > index+1 && data[index+1] == '\n' {
					return 0, index, index+2, true
				}

				start = index+1
			}
		},
	}
}

scanner_pump :: proc(s: ^Scanner) {
	if s.is_pumping { return }

	context.temp_allocator = temp_allocator(s.c)
	s.is_pumping = true
	destroyed := false
	s._pump_destroyed = &destroyed
	defer if !destroyed {
		s._pump_destroyed = nil
		s.is_pumping = false
	}

	for !destroyed && s.scan.callback != nil {
		offset, n, advance, ok := s.scan.split.procedure(s.scan.split.user_data, s.buf[s.read_head:s.write_head])
		if ok {
			assert(advance >= n && n >= offset)

			data: []byte
			// PERF: could check if prev is transaction_allocator and new is temp_allocator and skip this
			if s.scan.allocator != s.allocator {
				to_copy := s.buf[s.read_head+offset:s.write_head]

				s.allocator = s.scan.allocator
				err: runtime.Allocator_Error
				s.buf, err = make([]byte, max(len(to_copy), MULTIPLIER), arena_allocator(s.allocator))
				assert(err == nil) // TODO: 
				log.debugf("http[t=%v][c=%v]: msg=\"scanner realloc (new allocator)\"", td.id, s.c.socket)

				s.read_head  = advance-offset
				s.write_head = copy(s.buf, to_copy)
				assert(s.write_head == len(to_copy))

				data = s.buf[:n]
			} else {
				data = s.buf[s.read_head+offset:][:n]
				s.read_head += advance
			}

			cb := s.scan.callback
			s.scan = {}
			cb(s.c, data)
			if destroyed { return }
		} else {
			capacity := len(s.buf)-s.write_head
			if s.scan.allocator != s.allocator { // PERF: could check if prev is transaction_allocator and new is temp_allocator and skip this
				buf_left := s.buf[s.read_head:s.write_head]
				new_size := max(MULTIPLIER, len(buf_left) + MULTIPLIER)

				s.allocator = s.scan.allocator
				err: mem.Allocator_Error
				s.buf, err = make([]byte, new_size, arena_allocator(s.allocator))
				assert(err == nil) // TODO: err
				log.debugf("http[t=%v][c=%v]: msg=\"scanner realloc (new allocator)\"", td.id, s.c.socket)

				s.read_head  = 0
				s.write_head = copy(s.buf[:], buf_left)
				assert(s.write_head == len(buf_left))
			} else if capacity < MULTIPLIER {
				prev_buf := s.buf
				buf_left := s.buf[s.read_head:s.write_head]
				new_size := max(MULTIPLIER, len(prev_buf) * 2)

				err: mem.Allocator_Error
				s.buf, err = _arena_block_resize_in_place(s.allocator != nil ? s.allocator.tail : nil, s.buf, new_size, 1, false)
				if err == nil {
					log.debugf("http[t=%v][c=%v]: msg=\"scanner resized in place\", prev=%v, new=%v", td.id, s.c.socket, len(prev_buf), len(s.buf))
				} else {
					s.buf, err = make([]byte, new_size, arena_allocator(s.allocator))
					assert(err == nil) // TODO: err
					log.debugf("http[t=%v][c=%v]: msg=\"scanner realloc\", prev=%v, new=%v", td.id, s.c.socket, len(prev_buf), len(s.buf))

					s.read_head  = 0
					s.write_head = copy(s.buf[:], buf_left)
					assert(s.write_head == len(buf_left))
				}
			}

			dst := s.buf[s.write_head:]

			max := s.c.req.progress.max
			if max == 0 {
				if s.c.res.state == .None {
					status := s.c.req.line.version == {} ? Status.URI_Too_Long : Status.Request_Header_Fields_Too_Large
					invalid_request(s.c, status)
				} else {
					invalid_request(s.c, .Payload_Too_Large)
				}
				return
			} else if max > 0 {
				dst = dst[:min(len(dst), max)]
			}

			timeout := s.c.req.progress.timeout
			if timeout == 0 {
				invalid_request(s.c, .Request_Timeout)
				return
			} else if timeout < 0 {
				timeout = nbio.NO_TIMEOUT
			}

			log.debugf("http[t=%v][c=%v]: msg=\"recv\", n=%v, timeout=%v", td.id, s.c.socket, len(dst), timeout)

			s.last_recv_start = now()
			s.c.curr_recv = nbio.recv_poly(
				s.c.socket,
				{dst},
				s,
				scanner_on_recv,
				timeout=timeout,
			)
			return
		}
	}

	scanner_on_recv :: proc(op: ^nbio.Operation, s: ^Scanner) {
		s.c.curr_recv = nil
		if op.recv.err != nil {
			log.warnf("http[t=%v][c=%v]: recv error=%v", td.id, s.c.socket, op.recv.err)
			switch op.recv.err.(nbio.TCP_Recv_Error) {
			case .Timeout:
				invalid_request(s.c, .Request_Timeout)
			case .Not_Connected, .Connection_Closed:
				connection_destroy(s.c)
			case .Network_Unreachable, .Insufficient_Resources, .Invalid_Argument, .Would_Block, .Interrupted, .Unknown, .None:
				fallthrough
			case:
				invalid_request(s.c, .Internal_Server_Error)
			}
			return
		}

		if op.recv.received == 0 {
			log.debugf("http[t=%v][c=%v]: msg=\"client disconnected\"", td.id, s.c.socket)
			connection_destroy(s.c)
			return
		}

		dur := since(s.last_recv_start)
		progression_update(&s.c.req.progress, s.c.req.quota != nil ? s.c.req.quota^ : {}, op.recv.received, dur)

		log.debugf("http[t=%v][c=%v]: received=%v/%v, duration=%b", td.id, s.c.socket, op.recv.received, len(op.recv.bufs[0]), dur)
		s.write_head += op.recv.received

		scanner_pump(s)
	}
}

Body_Cb :: proc(req: ^Request, body: []byte, is_partial: bool)

Body_Request :: struct {
	cb:        Body_Cb,
	curr_size: int,
}

body :: proc(req: ^Request, cb: Body_Cb, loc := #caller_location) {
	c := connection_of_request(req)
	assert(context_get(&c.ctx, Body_Request) == nil, "body already consumed", loc)
	context_add(&c.ctx, Body_Request{cb = cb})

	if req.has_consumed_body {
		_body_cb(req, nil, is_partial=false)
		return
	}

	enc_header, ok := get_header(req, "Transfer-Encoding")
	if ok && _headers_eq(enc_header, "chunked") {
		_body_chunked(req)
	} else {
		_body_length(req)
	}
}

_body_cb :: proc(req: ^Request, body: []byte, is_partial: bool) {
	if !is_partial {
		req.has_consumed_body = true
	}
	c := connection_of_request(req)
	body_req := context_get(&c.ctx, Body_Request)
	assert(body_req != nil)
	body_req.cb(req, body, is_partial)
}

/*
"Decodes" a chunked transfer encoded request body.

RFC 7230 4.1.3 pseudo-code:

length := 0
read chunk-size, chunk-ext (if any), and CRLF
while (chunk-size > 0) {
   read chunk-data and CRLF
   append chunk-data to decoded-body
   length := length + chunk-size
   read chunk-size, chunk-ext (if any), and CRLF
}
read trailer field
while (trailer field is not empty) {
   if (trailer field is allowed to be sent in a trailer) {
   	append trailer field to existing header fields
   }
   read trailer-field
}
Content-Length := length
Remove "chunked" from Transfer-Encoding
Remove Trailer from existing header fields
*/
_body_chunked :: proc(req: ^Request) {
	c := connection_of_request(req)
	if !_maybe_send_continue(c) {
		return
	}
	scan_line(&c.scanner, on_size)

	on_size :: proc(c: ^Connection, data: []byte) {
		if !_valid_field_bytes(data) {
			invalid_request(c, .Bad_Request)
			return
		}

		size_line := string(data)

		// If there is a semicolon, discard everything after it,
		// that would be chunk extensions which we currently have no interest in.
		if semi := strings.index_byte(size_line, ';'); semi > -1 {
			size_line = size_line[:semi]
		}

		size, ok := parse_int16(size_line)
		if !ok {
			invalid_request(c, .Bad_Request)
			return
		}

		if c.req.progress.max >= 0 && size > c.req.progress.max {
			invalid_request(c, .Payload_Too_Large)
			return
		}

		if size == 0 {
			scan_line(&c.scanner, on_trailer)
			return
		}

		body_req := context_get(&c.ctx, Body_Request)
		body_req.curr_size = size
		scan_at_most(&c.scanner, size, on_body)
	}

	on_body :: proc(c: ^Connection, data: []byte) {
		body_req := context_get(&c.ctx, Body_Request)
		body_req.curr_size -= len(data)

		_body_cb(&c.req, data, is_partial=true)
		if c.res.state == .Sent || c.res.state == .Error || c.scanner.scan.callback != nil {
			return
		}

		if body_req.curr_size > 0 {
			scan_at_most(&c.scanner, body_req.curr_size, on_body)
			return
		}

		scan_line(&c.scanner, on_empty_line)
	}

	on_empty_line :: proc(c: ^Connection, data: []byte) {
		if len(data) != 0 {
			invalid_request(c, .Bad_Request)
			return
		}

		scan_line(&c.scanner, on_size)
	}

	on_trailer :: proc(c: ^Connection, data: []byte) {
		// Headers are done, success, clean up chunked stuff from headers.
		if len(data) == 0 {
			_headers_set_writable(&c.req.headers)

			headers_delete(&c.req.headers, "Trailer")
			headers_delete(&c.req.headers, "Transfer-Encoding")

			_headers_set_readonly(&c.req.headers)

			if !validate_headers(c) {
				invalid_request(c, .Bad_Request)
				return
			}

			_body_cb(&c.req, nil, is_partial=false)
			return
		}

		key, val, ok := header_parse(string(data))
		if !ok {
			invalid_request(c, .Bad_Request)
			return
		}

		// A recipient MUST ignore (or consider as an error) any fields that are forbidden to be sent in a trailer.
		if header_allowed_trailer(key) {
			_headers_set_writable(&c.req.headers)
			added := _request_add_header(c, key, val)
			_headers_set_readonly(&c.req.headers)
			if !added {
				return
			}
		}

		scan_line(&c.scanner, on_trailer)
	}
}

_body_length :: proc(req: ^Request) {
	c := connection_of_request(req)
	clen, has_clen, ok := get_content_length_header(req)
	if !ok {
		invalid_request(c, .Bad_Request)
		return
	}

	if !has_clen || clen == 0 {
		_body_cb(&c.req, nil, is_partial=false)
		return
	}

	if c.req.progress.max >= 0 && clen > c.req.progress.max {
		invalid_request(c, .Payload_Too_Large)
		return
	}

	if !_maybe_send_continue(c) {
		return
	}

	body_req := context_get(&c.ctx, Body_Request)
	body_req.curr_size = clen
	scan_at_most(&c.scanner, clen, on_body)

	on_body :: proc(c: ^Connection, data: []byte) {
		body_req := context_get(&c.ctx, Body_Request)
		body_req.curr_size -= len(data)
		if body_req.curr_size > 0 {
			_body_cb(&c.req, data, is_partial=true)
			if c.res.state == .Sent || c.res.state == .Error || c.scanner.scan.callback != nil {
				return
			}
			scan_at_most(&c.scanner, body_req.curr_size, on_body)
			return
		}

		_body_cb(&c.req, data, is_partial=false)
	}
}

_maybe_send_continue :: proc(c: ^Connection) -> bool {
	if c.res.state != .Handling {
		return true
	}
	if c.req.line.version != {1, 1} {
		return true
	}
	if c.scanner.write_head > c.scanner.read_head {
		return true
	}
	if c.req.progress.max == 0 || c.req.progress.timeout == 0 {
		return true
	}
	if expect, ok := headers_get(c.req.headers, "expect"); ok && _headers_eq(expect, "100-continue") {
		CONTINUE_RESPONSE :: "HTTP/1.1 100 Continue\r\n\r\n"
		_do_send(&c.res, {transmute([]byte)string(CONTINUE_RESPONSE)}, nil)
		return c.res.state != .Error
	}
	return true
}

@(private="file", rodata)
FORBIDDEN_TRAILERS := [?]string{
	// Message framing:
	"transfer-encoding",
	"content-length",
	// Routing:
	"host",
	// Request modifiers:
	"if-match",
	"if-none-match",
	"if-modified-since",
	"if-unmodified-since",
	"if-range",
	// Authentication:
	"www-authenticate",
	"authorization",
	"proxy-authenticate",
	"proxy-authorization",
	"cookie",
	"set-cookie",
	// Control data:
	"age",
	"cache-control",
	"expires",
	"date",
	"location",
	"retry-after",
	"vary",
	"warning",
	// How to process:
	"content-encoding",
	"content-type",
	"trailer",
	"content-range",
}

// Returns if this is a valid trailer header.
//
// RFC 7230 4.1.2:
// A sender MUST NOT generate a trailer that contains a field necessary
// for message framing (e.g., Transfer-Encoding and Content-Length),
// routing (e.g., Host), request modifiers (e.g., controls and
// conditionals in Section 5 of [RFC7231]), authentication (e.g., see
// [RFC7235] and [RFC6265]), response control data (e.g., see Section
// 7.1 of [RFC7231]), or determining how to process the payload (e.g.,
// Content-Encoding, Content-Type, Content-Range, and Trailer).
header_allowed_trailer :: proc(key: string) -> bool {
	for forbidden in FORBIDDEN_TRAILERS {
		if _headers_eq(key, forbidden) {
			return false
		}
	}
	return true
}
