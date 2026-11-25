#+vet explicit-allocators
package http

import "base:intrinsics"
import "base:runtime"

import "core:encoding/json"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

set_content_length_header :: proc(ctx: ^Ctx, length: int, loc := #caller_location) {
	if length <= 0 { return }
	b := strings.builder_make(0, transaction_allocator(ctx))
	strings.write_int(&b, length)
	set_header(ctx, "Content-Length", strings.to_string(b), loc)
}

get_content_length_header :: proc(req: ^Request) -> (clen: int, has, ok: bool) {
	clen_str, has_clen := headers_get(req.headers, "Content-Length")
	if !has_clen {
		ok = true
		return
	}
	has = true

	clen, ok = parse_int(clen_str)
	return
}

set_content_range_header :: proc(ctx: ^Ctx, range: Maybe([2]int), size: int, loc := #caller_location) {
	b := strings.builder_make(0, 32, transaction_allocator(ctx))

	strings.write_string(&b, "bytes ")
	if r, has_range := range.?; has_range {
		strings.write_int(&b, r.x)
		strings.write_string(&b, "-")
		strings.write_int(&b, r.y)
	} else {
		strings.write_string(&b, "*")
	}
	strings.write_string(&b, "/")
	strings.write_int(&b, size)

	set_header(ctx, "Content-Range", strings.to_string(b), loc)
}

Range :: struct {
	start: Maybe(int),
	end:   Maybe(int),
}

get_range_header :: proc(req: ^Request) -> (range: Range, ok: bool) {
	str := headers_get(req.headers, "range") or_return

	PREFIX :: "bytes="
	if len(str) < len(PREFIX) || !_headers_eq(str[:len(PREFIX)], PREFIX) {
		return
	}
	str = str[len(PREFIX):]

	// RFC 9110 §14.2: Ignore multi-range requests (no multipart/byteranges support).
	if strings.index_byte(str, ',') >= 0 {
		return
	}

	start, dash, end := strings.partition(str, "-")
	if len(dash) == 0 {
		return
	}

	if len(end) != 0 {
		range.end = parse_int(end) or_return
	}

	if len(start) == 0 {
		if end, has_end := range.end.?; has_end {
			range.end = -end
			ok = true
		}
		return
	}

	range.start = parse_int(start) or_return
	ok = true
	return
}

apply_range_to_size :: proc(range: Range, size: int) -> (offset, nbytes: int, ok: bool) {
	if size <= 0 {
		return
	}

	nbytes = size

	start, has_start := range.start.?
	if has_start {
		assert(start >= 0)
		if start >= nbytes {
			return
		}
		offset  = start
		nbytes -= start
	}

	if end, has_end := range.end.?; has_end {
		if has_start {
			assert(end >= 0)
			if start > end {
				return
			}
			end = min(end, size-1)
			nbytes = end - start + 1
		} else {
			suffix_length := -end
			assert(suffix_length >= 0)
			if suffix_length == 0 {
				return
			}
			if suffix_length < size {
				offset = size - suffix_length
				nbytes = suffix_length
			}
		}
	}

	ok = true
	return
}

wants_body :: proc(ctx: ^Ctx) -> bool {
	return ctx.req.line.method != .Head
}

set_header :: proc(ctx: ^Ctx, key, value: string, loc := #caller_location) -> mem.Allocator_Error {
	return headers_set(&ctx.res.headers, key, value, loc)
}

get_header :: proc(ctx: ^Ctx, key: string) -> (string, bool) {
	return headers_get(ctx.req.headers, key)
}

set_cookie :: proc(ctx: ^Ctx, c: Cookie, loc := #caller_location) -> mem.Allocator_Error {
	b := strings.builder_make(0, 64, transaction_allocator(ctx)) or_return
	strings.write_string(&b, c.name)
	strings.write_byte(&b, '=')
	strings.write_string(&b, c.value)

	if c.domain != "" {
		strings.write_string(&b, "; Domain=")
		strings.write_string(&b, c.domain)
	}

	if c.expires_gmt != {} {
		strings.write_string(&b, "; Expires=")
		date_buf: [DATE_LENGTH]byte
		date_write(date_buf[:], c.expires_gmt)
		strings.write_bytes(&b, date_buf[:])
	}

	if a, ok := c.max_age_secs.(int); ok {
		strings.write_string(&b, "; Max-Age=")
		strings.write_int(&b, a)
	}

	if c.path != "" {
		strings.write_string(&b, "; Path=")
		strings.write_string(&b, c.path)
	}

	switch c.same_site {
	case .None:        strings.write_string(&b, "; SameSite=None")
	case .Lax:         strings.write_string(&b, "; SameSite=Lax")
	case .Strict:      strings.write_string(&b, "; SameSite=Strict")
	case .Unspecified:
	}

	if c.secure {
		strings.write_string(&b, "; Secure")
	}

	if c.partitioned {
		strings.write_string(&b, "; Partitioned")
	}

	if c.http_only {
		strings.write_string(&b, "; HttpOnly")
	}

	return headers_add(&ctx.res.headers, "Set-Cookie", strings.to_string(b), loc)
}

@(private="file")
_is_strong_etag :: proc(etag: string) -> bool {
	return len(etag) >= 2 && etag[0] == '"' && etag[len(etag)-1] == '"'
}

@(private="file")
_if_range_matches :: proc(res: ^Response, condition: string, last_modified: Maybe(time.Time)) -> bool {
	if len(condition) == 0 {
		return false
	}

	if condition[0] == '"' || strings.has_prefix(condition, "W/") || strings.has_prefix(condition, "w/") {
		if !_is_strong_etag(condition) {
			return false
		}

		// User can set etag header in their handler and we will check it.
		etag := headers_get(res.headers, "etag") or_return
		return _is_strong_etag(etag) && condition == etag
	}

	condition_time := date_parse(condition) or_return

	lm_time: time.Time
	if lm_hdr, has_lm := headers_get(res.headers, "last-modified"); has_lm {
		lm_time = date_parse(lm_hdr) or_return
	} else {
		lm_time = last_modified.? or_return
	}

	return time.to_unix_seconds(condition_time) == time.to_unix_seconds(lm_time)
}

@(private="file")
_apply_request_range :: proc(ctx: ^Ctx, size: int, last_modified: Maybe(time.Time) = nil) -> (offset, nbytes: int, responded: bool) {
	nbytes = size

	if ctx.res.status != .OK {
		return
	}

	if accept_ranges, has_ar := headers_get(ctx.res.headers, "accept-ranges"); has_ar {
		// User can set this to none in their handler to disable our ranges functionality.
		if _headers_eq(accept_ranges, "none") {
			return
		}
	} else {
		set_header(ctx, "Accept-Ranges", "bytes")
	}

	c := _connection_of_context(ctx)
	if ctx.req.line.method != .Get && ctx.req.line.method != .Head {
		return
	}

	if condition, has_condition := headers_get(ctx.req.headers, "if-range"); has_condition {
		if !_if_range_matches(&ctx.res, condition, last_modified) {
			return
		}
	}

	range, has_range := get_range_header(&ctx.req)
	if !has_range {
		return
	}

	log.debugf("http[t=%v][c=%v]: range=%v", td.id, c.socket, range)
	range_ok: bool
	if offset, nbytes, range_ok = apply_range_to_size(range, size); !range_ok {
		log.debugf("http[t=%v][c=%v]: range=%v, size=%v, status=%v", td.id, c.socket, range, size, Status.Range_Not_Satisfiable)
		ctx.res.status = .Range_Not_Satisfiable
		set_content_range_header(ctx, nil, size)
		respond(ctx)
		return 0, 0, true
	}

	ctx.res.status = .Partial_Content
	set_content_range_header(ctx, [2]int{offset, offset + max(0, nbytes - 1)}, size)
	return offset, nbytes, false
}

_respond_handle_with_size :: proc(c: ^Connection, file: nbio.Handle, size: int, last_modified: time.Time) {
	assert(size > 0)

	if !headers_has(c.res.headers, "last-modified") {
		last_modified_buf, err := make([]byte, DATE_LENGTH, transaction_allocator(c))
		if err != nil {
			log.errorf("http[t=%v][c=%v]: msg=\"failed to allocate Last-Modified buffer\", err=%v", td.id, c.socket, err)
			c.res._state = .Error
			_check_send_done(c, skip_graceful = true)
			return
		}
		date_write(last_modified_buf, last_modified)
		set_header(&c.ctx, "Last-Modified", string(last_modified_buf))
	}

	offset, nbytes, responded := _apply_request_range(&c.ctx, size, last_modified)
	if responded {
		return
	}

	set_content_length_header(&c.ctx, nbytes)
	send_file(&c.ctx, file, offset, nbytes)
	respond(&c.ctx)
}

// send_ procs are primitives which can be called multiple times
// respond_ procs finalize the response, called once per response

SEND_ENTIRE_FILE :: nbio.SEND_ENTIRE_FILE

send_file :: proc(ctx: ^Ctx, file: nbio.Handle, offset: int = 0, nbytes: int = SEND_ENTIRE_FILE, on_sent: Send_Callback = nil) {
	nbytes := nbytes
	c := _connection_of_context(ctx)
	log.debugf("http[t=%v][c=%v]: offset=%v, nbytes=%v", td.id, c.socket, offset, nbytes)

	switch ctx.res._state {
	case .Error:
		return
	case .None, .Handling:
		send_heading(ctx)
		if ctx.res._state == .Error {
			return
		}
	case .Sending:
	case .Sent:
		panic("response has been sent already")
	case:
		unreachable()
	}

	if nbytes > 0 && wants_body(ctx) {
		max := ctx.res.progress.max
		timeout := ctx.res.progress.timeout
		if max == 0 || timeout == 0 {
			ctx.res._state = .Error
			_check_send_done(c)
			return
		}

		if nbytes != SEND_ENTIRE_FILE && max >= 0 {
			nbytes = min(nbytes, ctx.res.progress.max)
		}

		if timeout < 0 {
			timeout = nbio.NO_TIMEOUT
		}

		ctx.res._sends += 1
		ctx.res._last_send = now()
		nbio.sendfile_poly2(c.socket, file, c, on_sent, on_send, offset=offset, nbytes=nbytes, timeout=timeout)
	}
}

send :: proc(ctx: ^Ctx, bufs: [][]byte, on_sent: Send_Callback = nil) {
	c := _connection_of_context(ctx)
	switch ctx.res._state {
	case .Error:
		return
	case .None, .Handling:
		if err := write_response_heading(ctx); err != nil {
			log.errorf("http[t=%v][c=%v]: msg=\"failed to write response heading\", err=%v", td.id, c.socket, err)
			ctx.res._state = .Error
			_check_send_done(c, skip_graceful = true)
			return
		}
		ctx.res._state = .Sending
		if !wants_body(ctx) || len(bufs) == 0 {
			_do_send(c, {ctx.res._buf[:]}, on_sent)
			return
		}
		new_bufs := ([^][]byte)(intrinsics.alloca(size_of([]byte) * (len(bufs) + 1), align_of([]byte)))[:len(bufs)+1]
		new_bufs[0] = ctx.res._buf[:]
		copy(new_bufs[1:], bufs)
		_do_send(c, new_bufs, on_sent)
	case .Sending:
		if !wants_body(ctx) || len(bufs) == 0 {
			if on_sent != nil {
				on_sent(ctx, nil)
			}
			return
		}
		_do_send(c, bufs, on_sent)
	case .Sent:
		panic("response has been sent already")
	case:
		unreachable()
	}
}

_constraint_bufs :: proc(bufs: [][]byte, max: int) -> [][]byte {
	total: int
	for buf in bufs {
		total += len(buf)
	}

	constrained := bufs
	for n := total; n > max; {
		last := &constrained[len(constrained)-1]
		take := min(len(last), n-max)
		last^ = last[:len(last)-take]
		if len(last) == 0 {
			constrained = constrained[:len(constrained)-1]
		}
		n -= take
	}

	return constrained
}

_do_send :: proc(c: ^Connection, bufs: [][]byte, on_sent: Send_Callback) {
	bufs := bufs

	max := c.res.progress.max
	timeout := c.res.progress.timeout
	if max == 0 || timeout == 0 {
		c.res._state = .Error
		_check_send_done(c)
		return
	}

	if max > 0 {
		bufs = _constraint_bufs(bufs, max)
	}

	if timeout < 0 {
		timeout = nbio.NO_TIMEOUT
	}

	c.res._sends += 1
	c.res._last_send = now()
	nbio.send_poly2(c.socket, bufs, c, on_sent, on_send, timeout=timeout)
}

@(private="file")
_Chunk_Header :: struct {
	buf:  [20]byte,
	next: ^_Chunk_Header,
}

@(private="file")
_Chunked_State :: struct {
	inline_hdr: _Chunk_Header,
	in_flight:  ^_Chunk_Header,
	free:       ^_Chunk_Header,
}

@(private="file")
_response_allows_body :: proc(c: ^Connection) -> bool {
	return !status_is_informational(c.res.status) && c.res.status != .No_Content && c.res.status != .Not_Modified
}

@(private="file")
_begin_chunked :: proc(ctx: ^Ctx) -> ^_Chunked_State {
	if state := context_get(ctx, _Chunked_State); state != nil {
		return state
	}

	assert(ctx.res._state == .None || ctx.res._state == .Handling, "cannot begin chunked response after headers have been sent")
	assert(!headers_has(ctx.res.headers, "content-length"), "cannot use chunked encoding with Content-Length header")

	if !headers_has(ctx.res.headers, "transfer-encoding") {
		if err := set_header(ctx, "Transfer-Encoding", "chunked"); err != nil {
			c := _connection_of_context(ctx)
			log.errorf("http[t=%v][c=%v]: msg=\"failed to set Transfer-Encoding header\", err=%v", td.id, c.socket, err)
			ctx.res._state = .Error
			_check_send_done(c, skip_graceful = true)
			return nil
		}
	}

	state, err := context_add(ctx, _Chunked_State{})
	if err != nil {
		c := _connection_of_context(ctx)
		log.errorf("http[t=%v][c=%v]: msg=\"failed to allocate Chunked_State\", err=%v", td.id, c.socket, err)
		ctx.res._state = .Error
		_check_send_done(c, skip_graceful = true)
		return nil
	}
	state.free = &state.inline_hdr
	return state
}

_write_chunk_header :: proc(dst: []byte, size: int) -> []byte {
	assert(size > 0)
	hex := strconv.write_int(dst[:len(dst)-2], i64(size), 16)
	dst[len(hex)]   = '\r'
	dst[len(hex)+1] = '\n'
	return dst[:len(hex)+2]
}

@(private="file")
_set_default_content_type :: proc(ctx: ^Ctx, mime: Mime_Type, loc := #caller_location) {
	if !headers_has(ctx.res.headers, "content-type") {
		set_header(ctx, "Content-Type", mime_to_content_type(mime), loc)
	}
}

respond :: proc(ctx: ^Ctx) {
	c := _connection_of_context(ctx)
	is_chunked := context_get(ctx, _Chunked_State) != nil

	switch ctx.res._state {
	case .Error:
		return
	case .None, .Handling:
		if is_chunked && wants_body(ctx) && _response_allows_body(c) {
			send(ctx, {transmute([]byte)string("0\r\n\r\n")})
		} else {
			send_heading(ctx)
		}
		if ctx.res._state == .Error {
			return
		}
	case .Sending:
		if is_chunked && wants_body(ctx) && _response_allows_body(c) {
			send(ctx, {transmute([]byte)string("0\r\n\r\n")})
			if ctx.res._state == .Error {
				return
			}
		}
	case .Sent:
		panic("response has been sent already")
	case:
		unreachable()
	}

	ctx.res._state = .Sent
	_check_send_done(c)
}

respond_bytes :: proc(ctx: ^Ctx, bytes: []byte) {
	c := _connection_of_context(ctx)

	switch ctx.res._state {
	case .Error:
		return
	case .None, .Handling:
		set_content_length_header(ctx, len(bytes))
		if len(bytes) > 0 {
			send(ctx, {bytes})
		} else {
			send_heading(ctx)
		}
		if ctx.res._state == .Error {
			return
		}
	case .Sent, .Sending:
		panic("response has been sent already")
	case:
		unreachable()
	}

	ctx.res._state = .Sent
	_check_send_done(c)
}

respond_plain :: proc(ctx: ^Ctx, text: string) {
	_set_default_content_type(ctx, .Plain)
	respond_bytes(ctx, transmute([]byte)text)
}

respond_html :: proc(ctx: ^Ctx, html: string) {
	_set_default_content_type(ctx, .Html)
	respond_bytes(ctx, transmute([]byte)html)
}

/*
Marshals `v` as JSON into the transaction arena and sends the response with `Content-Type: application/json` (if unset).
Buffering the serialized JSON sets an exact `Content-Length` and returns any marshal error before headers are sent.
For custom streaming or incremental formatting without buffering the whole payload, write into a reusable
`strings.Builder` (or buffer) and emit chunks with `send_chunk(..., on_sent)`, or build into `transaction_allocator`
with `strings.to_writer` and finish with `respond_bytes`.
*/
respond_json :: proc(ctx: ^Ctx, v: any, opt: json.Marshal_Options = {}, loc := #caller_location) -> json.Marshal_Error {
	data := json.marshal(v, opt, transaction_allocator(ctx), loc) or_return
	_set_default_content_type(ctx, .Json, loc)
	respond_bytes(ctx, data)
	return nil
}

/*
Streams HTTP/1.1 `Transfer-Encoding: chunked` body data.

`bufs` are sent zero-copy (underlying memory must remain valid until `on_sent` runs or the response
completes; the outer `bufs` slice itself may be temporary). Chunk headers are pooled per response and
recycled lazily whenever `res._sends == 0` (O(1) memory for sequential `on_sent` streaming and
O(max_burst) memory for bursty streams that drain between bursts). Pass `on_sent` for async
backpressure so a producer can wait for the previous chunk to drain before generating or reusing buffers.
Streaming loops should check `wants_body(ctx)` to avoid generating bodies for `HEAD`.
*/
send_chunk :: proc(ctx: ^Ctx, bufs: [][]byte, on_sent: Send_Callback = nil) {
	if ctx.res._state == .Error {
		return
	}

	c := _connection_of_context(ctx)
	state := _begin_chunked(ctx)
	if state == nil {
		return
	}

	total, non_empty := 0, 0
	for buf in bufs {
		if len(buf) > 0 {
			total += len(buf)
			non_empty += 1
		}
	}

	// Never emit a 0-length terminating chunk mid-stream; still flush headers or invoke `on_sent`.
	if total == 0 || !wants_body(ctx) || !_response_allows_body(c) {
		send(ctx, nil, on_sent)
		return
	}

	if ctx.res._sends == 0 {
		for state.in_flight != nil {
			node := state.in_flight
			state.in_flight = node.next
			node.next = state.free
			state.free = node
		}
	}

	node := state.free
	if node != nil {
		state.free = node.next
	} else {
		alloc_err: runtime.Allocator_Error
		node, alloc_err = new(_Chunk_Header, transaction_allocator(ctx))
		if alloc_err != nil {
			ctx.res._state = .Error
			_check_send_done(c, skip_graceful = true)
			return
		}
	}
	node.next = state.in_flight
	state.in_flight = node

	hdr := _write_chunk_header(node.buf[:], total)

	framed_bufs := ([^][]byte)(intrinsics.alloca(size_of([]byte) * (non_empty + 2), align_of([]byte)))[:non_empty + 2]
	framed_bufs[0] = hdr
	idx := 1
	for buf in bufs {
		if len(buf) > 0 {
			framed_bufs[idx] = buf
			idx += 1
		}
	}
	framed_bufs[idx] = transmute([]byte)string("\r\n")

	send(ctx, framed_bufs, on_sent)
}

send_heading :: proc(ctx: ^Ctx, on_sent: Send_Callback = nil) {
	c := _connection_of_context(ctx)
	if err := write_response_heading(ctx); err != nil {
		log.errorf("http[t=%v][c=%v]: msg=\"failed to write response heading\", err=%v", td.id, c.socket, err)
		ctx.res._state = .Error
		_check_send_done(c, skip_graceful = true)
		return
	}

	ctx.res._state = .Sending
	_do_send(c, {ctx.res._buf[:]}, on_sent)
}

@(private="file")
_redirect_to_trailing_slash :: proc(c: ^Connection) {
	allocator := transaction_allocator(c)
	path_part, qmark, query_part := strings.partition(c.req.line.target, "?")
	trimmed_lead := strings.trim_left(path_part, "/")

	b := strings.builder_make(0, len(c.req.line.target) + 2, allocator)
	strings.write_byte(&b, '/')
	strings.write_string(&b, trimmed_lead)
	if len(trimmed_lead) > 0 {
		strings.write_byte(&b, '/')
	}
	if qmark != "" {
		strings.write_byte(&b, '?')
		strings.write_string(&b, query_part)
	}

	c.res.status = .Temporary_Redirect
	set_header(&c.ctx, "Location", strings.to_string(b))
	respond(&c.ctx)
}

@(private="file")
_respond_handle :: proc(c: ^Connection, file: nbio.Handle, redirect_if_dir: bool, mime: Maybe(Mime_Type) = nil) {
	nbio.stat_poly3(file, c, redirect_if_dir, mime, on_stat)

	on_stat :: proc(op: ^nbio.Operation, c: ^Connection, redirect_if_dir: bool, mime: Maybe(Mime_Type)) {
		context.temp_allocator = temp_allocator(c)

		if op.stat.err != nil {
			log.errorf("http[t=%v][c=%v]: msg=\"failed to stat\", err=%v", td.id, c.socket, op.stat.err)
			c.res.status = .Not_Found
			respond(&c.ctx)
			return
		}

		if op.stat.type == .Directory && redirect_if_dir {
			_redirect_to_trailing_slash(c)
			return
		}

		if op.stat.type != .Regular || op.stat.size <= 0 || op.stat.size > i64(max(int)) {
			log.warnf("http[t=%v][c=%v]: msg=\"not a regular file, too big, or no size\", type=%v, size=%v", td.id, c.socket, op.stat.type, op.stat.size)
			c.res.status = .Not_Found
			respond(&c.ctx)
			return
		}

		if m, ok := mime.?; ok {
			_set_default_content_type(&c.ctx, m)
		}

		_respond_handle_with_size(c, op.stat.handle, int(op.stat.size), op.stat.last_modified)
	}
}

respond_handle :: proc(ctx: ^Ctx, file: nbio.Handle) {
	_respond_handle(_connection_of_context(ctx), file, redirect_if_dir = false)
}

respond_file :: proc(ctx: ^Ctx, file: ^os.File) -> nbio.Association_Error {
	handle := nbio.associate_handle(os.fd(file)) or_return
	mime: Maybe(Mime_Type)
	if !headers_has(ctx.res.headers, "content-type") {
		if m, ok := mime_from_extension(os.name(file)); ok {
			mime = m
		}
	}
	_respond_handle(_connection_of_context(ctx), handle, redirect_if_dir = false, mime = mime)
	return nil
}

@(private="file")
_respond_file_path :: proc(c: ^Connection, file: string, dir := nbio.CWD, redirect_if_dir := false) {
	nbio.open_poly2(file, c, redirect_if_dir, on_open, dir=dir)

	on_open :: proc(op: ^nbio.Operation, c: ^Connection, redirect_if_dir: bool) {
		context.temp_allocator = temp_allocator(c)

		if op.open.err != nil {
			log.warnf("http[t=%v][c=%v]: msg=\"failed to open\", path=%q, err=%v", td.id, c.socket, op.open.path, op.open.err)
			c.res.status = .Not_Found
			respond(&c.ctx)
			return
		}

		mime: Maybe(Mime_Type)
		if !headers_has(c.res.headers, "content-type") {
			if m, ok := mime_from_extension(op.open.path); ok {
				mime = m
			}
		}

		if def_err := response_defer(&c.ctx, op.open.handle, proc(_: ^Ctx, handle: nbio.Handle) {
			nbio.close(handle)
		}); def_err != nil {
			log.errorf("http[t=%v][c=%v]: msg=\"failed to register file handle defer\", err=%v", td.id, c.socket, def_err)
			nbio.close(op.open.handle)
			c.res._state = .Error
			_check_send_done(c, skip_graceful = true)
			return
		}

		_respond_handle(c, op.open.handle, redirect_if_dir, mime)
	}
}

respond_file_path :: proc(ctx: ^Ctx, file: string, dir := nbio.CWD) {
	_respond_file_path(_connection_of_context(ctx), file, dir = dir, redirect_if_dir = false)
}

/*
Responds with the given content, automatically setting `Content-Type` from `file`'s extension if not already set.
Supports `Range` and `If-Range` requests (disable with `Accept-Ranges: none`, or pre-set `ETag`/`Last-Modified`).
Useful when serving files embedded at compile time with `#load(path)`.

You can set the Last-Modified header before calling this (for example with the compilation timestamp)
to add last modified ranges support.
*/
respond_file_content :: proc(ctx: ^Ctx, file: string, content: []byte) {
	if mime, ok := mime_from_extension(file); ok {
		_set_default_content_type(ctx, mime)
	}

	offset, nbytes, responded := _apply_request_range(ctx, len(content))
	if responded {
		return
	}

	respond_bytes(ctx, content[offset:offset+nbytes])
}

_resolve_dir_path :: proc(target, path: string, allocator: runtime.Allocator) -> (resolved: string, is_dir_redirect: bool, ok: bool) {
	if path == "" {
		return "", true, true
	}
	if path[0] != '/' {
		return
	}

	rel := path[1:]

	// Reject decoded ASCII control characters (including NUL/CR/LF) and DEL,
	// backslashes (Windows path separators), and colons (drive letters / NTFS alternate data streams).
	for b in transmute([]byte)rel {
		if b < 0x20 || b == 0x7f || b == '\\' || b == ':' {
			return
		}
	}

	rem := rel
	for seg in strings.split_iterator(&rem, "/") {
		if seg == "" || seg == "." || seg == ".." {
			return
		}
	}

	clean_target := strings.trim_prefix(strings.trim_right(target, "/"), "./")
	if clean_target == "." {
		clean_target = ""
	}
	wants_index := len(rel) == 0 || rel[len(rel)-1] == '/'

	b := strings.builder_make(0, len(clean_target) + 1 + len(rel) + len("index.html"), allocator)
	if clean_target != "" {
		strings.write_string(&b, clean_target)
		strings.write_byte(&b, '/')
	}
	strings.write_string(&b, rel)
	if wants_index {
		strings.write_string(&b, "index.html")
	}

	return strings.to_string(b), false, true
}

/*
Serves a static file from `target` (optionally relative to `dir`) for the already percent-decoded request `path`
(such as `route_suffix(ctx)` from a wildcard route). Redirects bare-prefix (`""`) and directory paths without a
trailing slash using `307 Temporary Redirect`.
*/
respond_dir :: proc(ctx: ^Ctx, target, path: string, dir := nbio.CWD) {
	c := _connection_of_context(ctx)
	without_query, _, _ := strings.partition(ctx.req.line.target, "?")
	// Reject percent-encoded slashes on the raw request target: decoding turns %2f into a '/'
	// directory separator, whereas browsers still treat %2f as part of a single path segment
	// (breaking relative URL resolution on directory redirects).
	if strings.contains(without_query, "%2f") || strings.contains(without_query, "%2F") {
		ctx.res.status = .Not_Found
		respond(ctx)
		return
	}

	resolved, is_dir_redirect, ok := _resolve_dir_path(target, path, transaction_allocator(ctx))
	if !ok {
		ctx.res.status = .Not_Found
		respond(ctx)
		return
	}
	if is_dir_redirect {
		_redirect_to_trailing_slash(c)
		return
	}

	has_trailing_slash := len(path) > 0 && path[len(path)-1] == '/'
	_respond_file_path(c, resolved, dir = dir, redirect_if_dir = !has_trailing_slash)
}
