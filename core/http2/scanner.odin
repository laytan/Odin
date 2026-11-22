package http

import "base:runtime"

import "core:bytes"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:strings"
import "core:time"

Scan_Splitter :: struct {
	procedure: proc(user_data: rawptr, data: []byte) -> (int, int, int, bool),
	user_data: rawptr,
}

Scan_Cb :: proc(c: ^Connection, data: []byte)

Scan :: struct {
	split:     Scan_Splitter,
	allocator: ^Arena,
	callback:  Scan_Cb,
	// If > 0 (body scans), the buffer starts at `<= BODY_BUF_SIZE` and grows geometrically up to this size,
	// instead of being sized by the pending token.
	buf_cap:   i32,
	// If true, `data` passed to `callback` is only valid until it returns and the buffer is reused for later recvs.
	reuse:     bool,
}

Scanner :: struct {
	c:          ^Connection,

	buf:        []byte,
	read_head:  int,
	write_head: int,
	allocator:  ^Arena,

	scan:       Scan,

	is_pumping:   bool,
	// Set when `buf` was allocated for a `reuse` scan and nothing handed out of it outlives a callback,
	// so it may be compacted, overwritten, and released when replaced.
	buf_reusable: bool,

	last_recv_start: time.Time,
}

MULTIPLIER          :: 512
BODY_BUF_SIZE       :: 16 * mem.Kilobyte - size_of(_Arena_Block)
STREAM_MAX_BUF_SIZE :: 256 * mem.Kilobyte - size_of(_Arena_Block)
RETAIN_MAX_BUF_SIZE :: 32 * mem.Megabyte

// Returns a buffer size of at least `min_needed`, aiming for `want` but at most `cap` (if > 0),
// rounded to make full use of arena blocks.
_scanner_buf_size :: proc(min_needed: int, want := 0, cap := 0) -> int {
	size := max(min_needed, want)
	if cap > 0 && size > cap {
		return max(_arena_fit_size(cap, round_down = true), _arena_fit_size(min_needed))
	}
	return _arena_fit_size(size)
}

@(private="file")
_body_buf_cap :: proc(c: ^Connection, retain: bool, hint := -1) -> i32 {
	max_cap := retain ? RETAIN_MAX_BUF_SIZE : STREAM_MAX_BUF_SIZE
	cap := max_cap
	if hint >= 0 {
		cap = min(cap, hint)
	}
	if c.req.progress.max >= 0 {
		cap = min(cap, c.req.progress.max)
	}
	return i32(clamp(cap, MULTIPLIER, max_cap))
}

// Moves the unconsumed bytes (from `s.read_head + offset`) into a new buffer of `size` on `allocator`,
// releasing the old buffer if reusable.
@(private="file")
_scanner_replace_buf :: proc(s: ^Scanner, allocator: ^Arena, size: int, offset := 0) -> bool {
	buf_left := s.buf[s.read_head+offset:s.write_head]
	new_buf, err := make([]byte, size, arena_allocator(allocator))
	if err != nil {
		log.errorf("http[t=%v][c=%v]: msg=\"scanner realloc OOM\", err=%v", _thread_id(), s.c.socket, err)
		invalid_request(s.c, .Internal_Server_Error)
		return false
	}
	log.debugf("http[t=%v][c=%v]: msg=\"scanner realloc\", prev=%v, new=%v, reuse=%v", _thread_id(), s.c.socket, len(s.buf), size, s.scan.reuse)

	write_head := copy(new_buf, buf_left)
	assert(write_head == len(buf_left))
	if s.buf_reusable {
		_arena_release_exclusive_block(s.allocator, s.buf)
	}

	s.allocator    = allocator
	s.buf          = new_buf
	s.read_head    = 0
	s.write_head   = write_head
	s.buf_reusable = s.scan.reuse
	return true
}

// Rebuilds `a` around any unread bytes remaining in `s.buf`, freeing all previous blocks in `a`.
// Returns `kept = false` with no error when nothing unread remains (leaving the caller to free `a` itself).
@(private="file")
_scanner_reset_arena :: proc(s: ^Scanner, a: ^Arena, c: ^Connection) -> (kept: bool, err: runtime.Allocator_Error) {
	to_copy := s.buf[s.read_head:s.write_head]
	if len(to_copy) == 0 {
		s.buf = {}
		s.read_head, s.write_head = 0, 0
		s.buf_reusable = false
		return false, nil
	}

	to_alloc  := _arena_fit_size(len(to_copy))
	backing   := a.backing.procedure != nil ? a.backing : _arena_default_backing(c)
	new_arena := _arena_block_acquire(backing, to_alloc, align = 1) or_return
	new_buf: []byte
	new_buf, err = make([]byte, to_alloc, mem.arena_allocator(new_arena))
	if err != nil {
		_arena_block_release(backing, new_arena)
		return false, err
	}
	new_arena.last = raw_data(new_buf)
	s.buf          = new_buf
	s.read_head    = 0
	s.write_head   = copy(new_buf, to_copy)
	s.buf_reusable = false

	arena_free_all(a)
	a.backing = backing
	a.tail    = new_arena
	return true, nil
}

scanner_reset :: proc(s: ^Scanner, c: ^Connection) -> (err: runtime.Allocator_Error) {
	is_pumping := s.is_pumping
	log.debugf("http[t=%v][c=%v]: msg=\"scanner_reset\", to_copy=%v", _thread_id(), c.socket, s.write_head - s.read_head)
	kept := _scanner_reset_arena(s, &c.transaction_arena, c) or_return
	if !kept {
		transaction_allocator_destroy(c)
		s^ = {
			c          = c,
			is_pumping = is_pumping,
		}
		return nil
	}

	s^ = {
		c          = c,
		buf        = s.buf,
		read_head  = s.read_head,
		write_head = s.write_head,
		allocator  = &c.transaction_arena,
		is_pumping = is_pumping,
	}
	return nil
}

@(private="file")
_scanner_pin_buf_block :: proc(s: ^Scanner, a: ^Arena) -> bool {
	if len(s.buf) == 0 {
		return false
	}

	buf_ptr := uintptr(raw_data(s.buf))
	buf_block: ^_Arena_Block
	for block := a.tail; block != nil; block = block.prev {
		block_start := uintptr(raw_data(block.data))
		block_end   := block_start + uintptr(len(block.data))
		if buf_ptr >= block_start && buf_ptr < block_end {
			assert(buf_ptr + uintptr(len(s.buf)) <= block_end)
			buf_block = block
			break
		}
	}

	if buf_block == nil {
		return false
	}

	backing := a.backing.procedure != nil ? a.backing : _arena_default_backing(a.c)
	block := a.tail
	a.tail = nil
	for block != nil {
		prev := block.prev
		if block != buf_block {
			_arena_block_release(backing, block)
		}
		block = prev
	}

	buf_block.prev   = nil
	buf_block.offset = int(buf_ptr - uintptr(raw_data(buf_block.data))) + len(s.buf)
	buf_block.last   = raw_data(s.buf)
	a.tail = buf_block
	return true
}

_scanner_free_all :: proc(s: ^Scanner, a: ^Arena) -> (handled: bool) {
	if a != s.allocator {
		return false
	}

	// Never free, poison, or relocate s.buf while an nbio.recv holds a pointer into it.
	// Reclaim all other blocks in `a` and rewind the pinned block's offset to the end of s.buf.
	if s.c.curr_recv != nil {
		log.debugf("http[t=%v][c=%v]: msg=\"scanner_free_all (recv in flight, pinning buf block)\"", _thread_id(), s.c.socket)
		return _scanner_pin_buf_block(s, a)
	}

	log.debugf("http[t=%v][c=%v]: msg=\"scanner_free_all\", to_copy=%v", _thread_id(), s.c.socket, s.write_head - s.read_head)
	kept, err := _scanner_reset_arena(s, a, a.c)
	if err != nil {
		log.warnf("http[t=%v][c=%v]: msg=\"scanner_free_all OOM, pinning existing buf block\", err=%v", _thread_id(), s.c.socket, err)
		return _scanner_pin_buf_block(s, a)
	}
	return kept
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

_scanner_pump_buffered :: proc(s: ^Scanner) -> (needs_recv: bool) {
	if s.is_pumping { return false }

	c := s.c
	context.temp_allocator = temp_allocator(c)
	s.is_pumping = true
	destroy_flag: _Destroy_Flag
	_destroy_flag_push(c, &destroy_flag)
	defer if !_destroy_flag_pop(c, &destroy_flag) {
		s.is_pumping = false
	}

	for !destroy_flag.destroyed && s.scan.callback != nil {
		offset, n, advance, ok := s.scan.split.procedure(s.scan.split.user_data, s.buf[s.read_head:s.write_head])
		if !ok {
			return true
		}

		assert(advance >= n && n >= offset)

		data: []byte
		if s.scan.allocator != s.allocator {
			to_copy_len := s.write_head - (s.read_head + offset)
			if !_scanner_replace_buf(s, s.scan.allocator, _arena_fit_size(to_copy_len), offset) {
				return false
			}
			data        = s.buf[:n]
			s.read_head = advance - offset
		} else {
			// Data handed to a non-reusing callback may be retained, so the buffer must not be overwritten anymore.
			if !s.scan.reuse {
				s.buf_reusable = false
			}
			data = s.buf[s.read_head+offset:][:n]
			s.read_head += advance
		}

		cb := s.scan.callback
		s.scan = {}
		cb(s.c, data)
		if destroy_flag.destroyed { return false }
	}
	return false
}

// Size for a fresh buffer: body scans start at `<= BODY_BUF_SIZE` rather than trusting large declared sizes up front.
@(private="file")
_scanner_initial_buf_size :: proc(s: ^Scanner) -> int {
	cap := int(s.scan.buf_cap)
	return _scanner_buf_size(s.write_head - s.read_head + MULTIPLIER, min(cap, BODY_BUF_SIZE), cap)
}

_scanner_prepare_recv_buf :: proc(s: ^Scanner) -> bool {
	if s.scan.allocator != s.allocator {
		return _scanner_replace_buf(s, s.scan.allocator, _scanner_initial_buf_size(s))
	}

	// A reusing scan must not overwrite a buffer that may still be referenced (e.g. by header values).
	if s.scan.reuse && !s.buf_reusable {
		return _scanner_replace_buf(s, s.allocator, _scanner_initial_buf_size(s))
	}

	// Check before compacting whether the last recv filled the buffer to the end.
	filled := s.write_head == len(s.buf)
	if s.buf_reusable && s.read_head > 0 {
		s.write_head = copy(s.buf, s.buf[s.read_head:s.write_head])
		s.read_head  = 0
	}
	if !s.scan.reuse {
		s.buf_reusable = false
	}

	needs_space := len(s.buf) - s.write_head < MULTIPLIER
	if !needs_space && !(s.buf_reusable && filled) {
		return true
	}

	// Body scans grow geometrically (chaining new blocks when retaining), other scans size for the pending token.
	buf_left := s.write_head - s.read_head
	cap      := int(s.scan.buf_cap)
	want     := _arena_grow_size(cap > 0 ? len(s.buf) : buf_left)
	new_size := _scanner_buf_size(buf_left + MULTIPLIER, max(want, min(cap, BODY_BUF_SIZE)), cap)
	if !needs_space && new_size <= len(s.buf) {
		return true
	}

	resize_to := _arena_fit_size(s.read_head + new_size)
	if resized, err := _arena_block_resize_in_place(s.allocator != nil ? s.allocator.tail : nil, s.buf, resize_to, 1, false); err == nil {
		log.debugf("http[t=%v][c=%v]: msg=\"scanner resized in place\", prev=%v, new=%v", _thread_id(), s.c.socket, len(s.buf), len(resized))
		s.buf = resized
		return true
	}
	return _scanner_replace_buf(s, s.allocator, new_size)
}

scanner_pump :: proc(s: ^Scanner) {
	if !_scanner_pump_buffered(s) {
		return
	}

	max := s.c.req.progress.max
	if max == 0 {
		if _is_scanning_request_line(s.c) {
			invalid_request(s.c, .URI_Too_Long)
		} else if _is_scanning_headers(s.c) {
			invalid_request(s.c, .Request_Header_Fields_Too_Large)
		} else {
			invalid_request(s.c, .Payload_Too_Large)
		}
		return
	}

	timeout := s.c.req.progress.timeout
	if timeout == 0 {
		invalid_request(s.c, .Request_Timeout)
		return
	} else if timeout < 0 {
		timeout = nbio.NO_TIMEOUT
	}

	if !_scanner_prepare_recv_buf(s) {
		return
	}

	dst := s.buf[s.write_head:]
	if max > 0 {
		dst = dst[:min(len(dst), max)]
	}

	log.debugf("http[t=%v][c=%v]: msg=\"recv\", n=%v, timeout=%v", _thread_id(), s.c.socket, len(dst), timeout)

	s.last_recv_start = now()
	s.c.curr_recv = nbio.recv_poly(
		s.c.socket,
		{dst},
		s,
		scanner_on_recv,
		timeout=timeout,
	)
	return

	scanner_on_recv :: proc(op: ^nbio.Operation, s: ^Scanner) {
		context.temp_allocator = temp_allocator(s.c)
		s.c.curr_recv = nil
		if op.recv.err != nil {
			log.warnf("http[t=%v][c=%v]: recv error=%v", td.id, s.c.socket, op.recv.err)
			switch op.recv.err.(nbio.TCP_Recv_Error) {
			case .Timeout:
				invalid_request(s.c, .Request_Timeout)
			case .Not_Connected, .Connection_Closed:
				s.c.scanner.scan = {}
				s.c.res._state   = .Error
				_check_send_done(s.c, skip_graceful = true)
			case .Network_Unreachable, .Insufficient_Resources, .Invalid_Argument, .Would_Block, .Interrupted, .Unknown, .None:
				fallthrough
			case:
				invalid_request(s.c, .Internal_Server_Error)
			}
			return
		}

		if op.recv.received == 0 {
			log.debugf("http[t=%v][c=%v]: msg=\"client disconnected\"", td.id, s.c.socket)
			s.c.scanner.scan = {}
			s.c.res._state   = .Error
			_check_send_done(s.c, skip_graceful = true)
			return
		}

		dur := since(s.last_recv_start)
		progression_update(&s.c.req.progress, s.c.req.quota != nil ? s.c.req.quota^ : {}, op.recv.received, dur)

		log.debugf("http[t=%v][c=%v]: received=%v/%v, duration=%b", td.id, s.c.socket, op.recv.received, len(op.recv.bufs[0]), dur)
		s.write_head += op.recv.received

		scanner_pump(s)
	}
}

/*
Callback invoked with request body chunks from `body`.

Both `Content-Length` and `Transfer-Encoding: chunked` follow the same stream contract:
every data chunk invokes `is_partial = true` with a non-empty `body` slice, and the final EOF
invocation passes `body == nil` and `is_partial = false`.

With `retain = false` (default), `body` is a slice into the connection's reusable streaming buffer
(starting at `<= 16 KiB` and ramping up to `<= 256 KiB` when recvs fill it). Unless paused via
`body_pause`, returning from this callback lets the scanner compact or overwrite that live buffer
in place — a silent data corruption bug that ASAN cannot detect because the allocation is reused
rather than freed.

For async consumers (`send`, `send_chunk`, `nbio.write`, etc.) with `retain = false`, either:
1. Copy/clone `body` before returning, or
2. Call `body_pause(req)` inside this callback before issuing the async operation, keeping `body`
   valid zero-copy until the async completion calls `body_resume(req)` (which then continues
   scanning or delivers the final `(nil, is_partial = false)` callback).

When `body` is called with `retain = true`, chunks live on `transaction_arena` for the duration of
the request.
*/
Body_Cb :: proc(req: ^Request, body: []byte, is_partial: bool)

Body_Request :: struct {
	cb:        Body_Cb,
	curr_size: int,
	retain:    bool,
	paused:    bool,
}

// Scans the next part of the request body into `transaction_arena`, honouring `body(..., retain)`.
// `hint` is the number of body bytes known to remain (-1 if unknown) to avoid oversized buffers.
@(private="file")
_scan_body :: proc(c: ^Connection, split: Scan_Splitter, cb: Scan_Cb, hint := -1) {
	body_req := context_get(&c.ctx, Body_Request)
	c.scanner.scan = {
		split     = split,
		allocator = &c.transaction_arena,
		callback  = cb,
		buf_cap   = _body_buf_cap(c, body_req.retain, hint),
		reuse     = !body_req.retain,
	}
	scanner_pump(&c.scanner)
}

@(private="file")
_request_is_chunked :: proc(req: ^Request) -> bool {
	enc_header, ok := get_header(req, "Transfer-Encoding")
	return ok && _headers_eq(enc_header, "chunked")
}

/*
Streams the request body to `cb`.

Each data chunk passes `is_partial = true` with `len(body) > 0`; once all body bytes (and any
chunked trailers) are consumed, a final EOF invocation passes `nil, is_partial = false`.

With `retain = false` (default), chunks are scanned into a single O(1) reusable buffer on
`transaction_arena` (starting at `<= 16 KiB` and adaptively scaling up to `256 KiB` when recvs fill
it). Returning from `cb` without calling `body_pause` allows subsequent reads to compact or
overwrite that live buffer in place (undetectable by ASAN), so async consumers (`send`,
`send_chunk`, `nbio.write`, etc.) must either copy `body` before returning or call `body_pause(req)`
until their async work completes and calls `body_resume(req)`.

With `retain = true`, chunks are scanned zero-copy into chained buffers on `transaction_arena`
(starting at `<= 16 KiB` and progressively scaling up to `32 MiB` as blocks fill) and remain
valid for the lifetime of the request transaction.
*/
body :: proc(req: ^Request, cb: Body_Cb, retain := false, loc := #caller_location) {
	ctx := context_of_request(req)
	assert(context_get(ctx, Body_Request) == nil, "body already consumed", loc)
	if _, err := context_add(ctx, Body_Request{cb = cb, retain = retain}); err != nil {
		c := connection_of_request(req)
		log.errorf("http[t=%v][c=%v]: msg=\"body context_add OOM\", err=%v", td.id, c.socket, err)
		invalid_request(c, .Internal_Server_Error)
		return
	}

	if req.has_consumed_body {
		_body_cb(req, nil, is_partial=false)
		return
	}

	if _request_is_chunked(req) {
		_body_chunked(req)
	} else {
		_body_length(req)
	}
}

/*
Pauses streaming body reads for `req` until `body_resume` is called.

Call from within a `Body_Cb` (before dispatching any async operation that will call `body_resume`)
to apply backpressure while an async consumer drains the current `body` chunk (e.g. `nbio.write`
to disk or `send_chunk` to the socket). While paused, the scanner stops issuing `nbio.recv` and
does not compact, overwrite, or reallocate its buffer, so `body` remains valid zero-copy (even
with `retain = false`) until `body_resume` is called. When resuming after the final data chunk,
`body_resume` invokes the final `(nil, is_partial = false)` EOF callback.

No-op if `body` has not been called or the body has already been consumed (`is_partial == false`).
*/
body_pause :: proc(req: ^Request) {
	if req.has_consumed_body {
		return
	}
	c := connection_of_request(req)
	body_req := context_get(&c.ctx, Body_Request)
	if body_req == nil {
		return
	}
	body_req.paused = true
}

/*
Resumes streaming body reads previously paused with `body_pause`.

Calling `body_resume` hands the current `body` slice back to the scanner: with `retain = false`,
its bytes may be compacted or overwritten immediately, so any async consumer holding `body` must
have finished reading it first.

Safe to call redundantly, synchronously inside `Body_Cb` (cancelling an earlier `body_pause`
without recursion), after the body has finished, or after the response has ended/errored.
*/
body_resume :: proc(req: ^Request) {
	if req.has_consumed_body {
		return
	}
	c := connection_of_request(req)
	body_req := context_get(&c.ctx, Body_Request)
	if body_req == nil || !body_req.paused {
		return
	}
	body_req.paused = false

	// If called synchronously while the scanner pump is active (e.g. inside `Body_Cb`, or from a
	// synchronous `on_sent` on a `HEAD` request), let the active continuation schedule the next
	// scan iteratively upon return.
	if c.scanner.is_pumping {
		return
	}
	if c.res._state == .Sent || c.res._state == .Error || c.scanner.scan.callback != nil || c.curr_recv != nil {
		return
	}

	if _request_is_chunked(req) {
		_body_chunked_continue(c)
	} else {
		_body_length_continue(c)
	}
}

_body_cb :: proc(req: ^Request, body: []byte, is_partial: bool) -> (destroyed: bool) {
	if !is_partial {
		req.has_consumed_body = true
	}
	c := connection_of_request(req)
	body_req := context_get(&c.ctx, Body_Request)
	assert(body_req != nil)

	if !is_partial {
		body_req.cb(req, body, false)
		return false
	}

	destroy_flag: _Destroy_Flag
	_destroy_flag_push(c, &destroy_flag)
	body_req.cb(req, body, true)
	return _destroy_flag_pop(c, &destroy_flag)
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
	_scan_body(c, split_line(), _body_chunked_on_size)
}

@(private="file")
_body_chunked_continue :: proc(c: ^Connection) {
	body_req := context_get(&c.ctx, Body_Request)
	if body_req.curr_size > 0 {
		_scan_body(c, split_at_most(body_req.curr_size), _body_chunked_on_body)
		return
	}
	_scan_body(c, split_n(2), _body_chunked_on_crlf)
}

@(private="file")
_body_chunked_on_size :: proc(c: ^Connection, data: []byte) {
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
		// Trailers reuse request_quota and scan non-reusably so headers can store zero-copy slices.
		c.req.quota = &td.s.opts.request_quota
		progression_reset(&c.req.progress, c.req.quota^)
		if buffered := c.scanner.write_head - c.scanner.read_head; buffered > 0 {
			progression_update(&c.req.progress, c.req.quota^, buffered, 0)
		}
		scan_line(&c.scanner, _body_chunked_on_trailer)
		return
	}

	body_req := context_get(&c.ctx, Body_Request)
	body_req.curr_size = size
	_scan_body(c, split_at_most(size), _body_chunked_on_body)
}

@(private="file")
_body_chunked_on_body :: proc(c: ^Connection, data: []byte) {
	body_req := context_get(&c.ctx, Body_Request)
	body_req.curr_size -= len(data)

	if _body_cb(&c.req, data, is_partial=true) {
		return
	}
	if c.res._state == .Sent || c.res._state == .Error || c.scanner.scan.callback != nil || body_req.paused {
		return
	}

	_body_chunked_continue(c)
}

@(private="file")
_body_chunked_on_crlf :: proc(c: ^Connection, data: []byte) {
	if len(data) != 2 || data[0] != '\r' || data[1] != '\n' {
		invalid_request(c, .Bad_Request)
		return
	}

	_scan_body(c, split_line(), _body_chunked_on_size)
}

@(private="file")
_body_chunked_on_trailer :: proc(c: ^Connection, data: []byte) {
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

	scan_line(&c.scanner, _body_chunked_on_trailer)
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
	_scan_body(c, split_at_most(clen), _body_length_on_body, hint = clen)
}

@(private="file")
_body_length_continue :: proc(c: ^Connection) {
	body_req := context_get(&c.ctx, Body_Request)
	if body_req.curr_size <= 0 {
		_body_cb(&c.req, nil, is_partial=false)
		return
	}
	_scan_body(c, split_at_most(body_req.curr_size), _body_length_on_body, hint = body_req.curr_size)
}

@(private="file")
_body_length_on_body :: proc(c: ^Connection, data: []byte) {
	body_req := context_get(&c.ctx, Body_Request)
	body_req.curr_size -= len(data)
	if _body_cb(&c.req, data, is_partial=true) {
		return
	}
	if c.res._state == .Sent || c.res._state == .Error || c.scanner.scan.callback != nil || body_req.paused {
		return
	}
	_body_length_continue(c)
}

_maybe_send_continue :: proc(c: ^Connection) -> bool {
	if c.res._state != .Handling {
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
		return c.res._state != .Error
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
