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

	is_pumping: bool,

	last_recv_start: time.Time,
}

MULTIPLIER :: 512

scanner_reset :: proc(s: ^Scanner, c: ^Connection) {
	to_copy := s.buf[s.read_head:s.write_head]
	if len(to_copy) == 0 {
		transaction_allocator_destroy(c)
		s^  = {}
		s.c = c
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
		c          = c,
		buf        = new_buf,
		read_head  = 0,
		write_head = n,
		allocator  = &c.transaction_arena,
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
		allocator = &s.c.transaction_arena,
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

	s.is_pumping = true
	defer s.is_pumping = false

	for s.scan.callback != nil {
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
		} else {
			capacity := len(s.buf)-s.write_head
			if capacity < MULTIPLIER || s.scan.allocator != s.allocator { // PERF: could check if prev is transaction_allocator and new is temp_allocator and skip this
				prev_buf := s.buf
				buf_left := s.buf[s.read_head:s.write_head]
				new_size := max(MULTIPLIER, len(prev_buf) * 2)

				s.allocator = s.scan.allocator

				err: mem.Allocator_Error
				s.buf, err = _arena_block_resize_in_place(s.allocator.tail, s.buf, new_size, 1, false)
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
				invalid_request(s.c, .Payload_Too_Large)
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
			nbio.recv_poly(
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

		curr_quota := s.c.res.state == .None ? td.s.opts.request_quota : td.s.opts.body_quota
		dur := since(s.last_recv_start)
		progression_update(&s.c.req.progress, curr_quota, op.recv.received, dur)

		log.debugf("http[t=%v][c=%v]: received=%v/%v, duration=%b", td.id, s.c.socket, op.recv.received, len(op.recv.bufs[0]), dur)
		s.write_head += op.recv.received

		scanner_pump(s)
	}
}

// TODO: allow use of temp arena (advanced use can use it for streaming, each part can be freed right away)
// TODO: handle the body cb (when given .Partial) closing the connection, don't keep going then

Body_Cb :: proc(req: ^Request, body: []byte, is_partial: bool)

Body_Request :: struct {
	cb: Body_Cb,
	curr_size: int,
}

body :: proc(req: ^Request, cb: Body_Cb, loc := #caller_location) {
	assert(context_get(context_of_request(req), Body_Request) == nil, "body already consumed", loc)
	context_add(context_of_request(req), Body_Request{
		cb,
		0,
	})

	enc_header, ok := get_header(req, "Transfer-Encoding")
	if ok && strings.has_suffix(enc_header, "chunked") {
		_body_chunked(req)
	} else {
		_body_length(req)
	}
}

_body_cb :: proc(req: ^Request, body: []byte, is_partial: bool) {
	body_req := context_get(context_of_request(req), Body_Request)
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
	scan_line(&c.scanner, on_size)

	on_size :: proc(c: ^Connection, data: []byte) {
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

		if size == 0 {
			scan_line(&c.scanner, on_trailer)
			return
		}

		body_req := context_get(&c.ctx, Body_Request)
		assert(body_req != nil)
		body_req.curr_size = size
		scan_at_most(&c.scanner, size, on_body)
	}

	on_body :: proc(c: ^Connection, data: []byte) {
		body_req := context_get(&c.ctx, Body_Request)
		assert(body_req != nil)
		body_req.curr_size -= len(data)

		_body_cb(&c.req, data, is_partial=true)

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
			_, val_ptr, just_inserted, err := headers_entry(&c.req.headers, "Transfer-Encoding")
			assert(!just_inserted)
			assert(err == nil)
			// TODO: is the space required?
			if strings.has_suffix(val_ptr^, ", chunked") {
				val_ptr^ = strings.trim_suffix(val_ptr^, ", chunked")
			} else if val_ptr^ == "chunked" {
				headers_delete(&c.req.headers, "Transfer-Encoding")
			}

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
			headers_add(&c.req.headers, key, val)
			_headers_set_readonly(&c.req.headers)
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
		_body_cb(req, nil, is_partial=false)
		return
	}

	body_req := context_get(&c.ctx, Body_Request)
	assert(body_req != nil)
	body_req.curr_size = clen
	scan_at_most(&c.scanner, clen, on_body)

	on_body :: proc(c: ^Connection, data: []byte) {
		body_req := context_get(&c.ctx, Body_Request)
		assert(body_req != nil)
		body_req.curr_size -= len(data)
		if body_req.curr_size > 0 {
			_body_cb(&c.req, data, is_partial=true)
			scan_at_most(&c.scanner, body_req.curr_size, on_body)
			return
		}

		_body_cb(&c.req, data, is_partial=false)
	}
}

// TODO: set this up once at init/start, globally
@(thread_local)
allowed_trailers: Headers

init_allowed_trailers :: proc() {
	if allowed_trailers.len > 0 {
		return
	}

	allowed_trailers = _headers_make(runtime.heap_allocator())
	// Message framing:
	headers_set(&allowed_trailers, "transfer-encoding", "")
	headers_set(&allowed_trailers, "content-length", "")
	// Routing:
	headers_set(&allowed_trailers, "host", "")
	// Request modifiers:
	headers_set(&allowed_trailers, "if-match", "")
	headers_set(&allowed_trailers, "if-none-match", "")
	headers_set(&allowed_trailers, "if-modified-since", "")
	headers_set(&allowed_trailers, "if-unmodified-since", "")
	headers_set(&allowed_trailers, "if-range", "")
	// Authentication:
	headers_set(&allowed_trailers, "www-authenticate", "")
	headers_set(&allowed_trailers, "authorization", "")
	headers_set(&allowed_trailers, "proxy-authenticate", "")
	headers_set(&allowed_trailers, "proxy-authorization", "")
	headers_set(&allowed_trailers, "cookie", "")
	headers_set(&allowed_trailers, "set-cookie", "")
	// Control data:
	headers_set(&allowed_trailers, "age", "")
	headers_set(&allowed_trailers, "cache-control", "")
	headers_set(&allowed_trailers, "expires", "")
	headers_set(&allowed_trailers, "date", "")
	headers_set(&allowed_trailers, "location", "")
	headers_set(&allowed_trailers, "retry-after", "")
	headers_set(&allowed_trailers, "vary", "")
	headers_set(&allowed_trailers, "warning", "")
	// How to process:
	headers_set(&allowed_trailers, "content-encoding", "")
	headers_set(&allowed_trailers, "content-type", "")
	headers_set(&allowed_trailers, "trailer", "")
	headers_set(&allowed_trailers, "content-range", "")
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
	init_allowed_trailers()
	return headers_has(allowed_trailers, key)
}
