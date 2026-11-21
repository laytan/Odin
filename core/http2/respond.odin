#+vet explicit-allocators
package http

import "base:intrinsics"
import "base:runtime"

import "core:encoding/json"
import "core:io"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

set_content_length_header :: proc(res: ^Response, length: int, loc := #caller_location) {
	if length <= 0 { return }
	b := strings.builder_make(0, transaction_allocator(connection_of_response(res)))
	strings.write_int(&b, length)
	set_header(res, "Content-Length", strings.to_string(b), loc)
}

get_content_length_header :: proc(req: ^Request) -> (clen: int, has, ok: bool) {
	clen_str, has_clen := get_header(req, "Content-Length")
	if !has_clen {
		ok = true
		return
	}
	has = true

	clen, ok = parse_int(clen_str)
	return
}

set_content_range_header :: proc(res: ^Response, range: Maybe([2]int), size: int, loc := #caller_location) {
	b := strings.builder_make(0, 32, transaction_allocator(connection_of_response(res)))

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

	set_header(res, "Content-Range", strings.to_string(b), loc)
}

Range :: struct {
	start: Maybe(int),
	end:   Maybe(int),
}

get_range_header :: proc(req: ^Request) -> (range: Range, ok: bool) {
	str := get_header(req, "range") or_return

	PREFIX :: "bytes="
	if !strings.has_prefix(str, PREFIX) {
		return
	}
	str = str[len(PREFIX):]

	comma_idx := strings.index_byte(str, ',')
	if comma_idx >= 0 {
		str = str[:comma_idx]

		c := connection_of_request(req)
		log.warnf("http[t=%v][c=%v]: msg=\"unimplemented: multi-range requests, falling back to first range\"", td.id, c.socket)
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
			end = min(end, size-1)
			if start > end {
				return
			}
			nbytes = end - start + 1
		} else {
			suffix_length := -end
			assert(suffix_length >= 0)
			if suffix_length < size {
				offset = size - suffix_length
				nbytes = suffix_length
			}
		}
	}

	ok = true
	return
}

wants_body :: proc(req: ^Request) -> bool {
	return req.line.method != .Head
}

set_header :: proc(res: ^Response, key, value: string, loc := #caller_location) {
	headers_set(&res.headers, key, value, loc)
}

get_header :: proc(req: ^Request, key: string) -> (string, bool) {
	return headers_get(req.headers, key)
}

set_cookie :: proc(res: ^Response, c: Cookie, loc := #caller_location) {
	b := strings.builder_make(0, 64, transaction_allocator(connection_of_response(res)))
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

	headers_add(&res.headers, "Set-Cookie", strings.to_string(b), loc)
}

// TODO: prob want some configuration for the range handling, if it should be done at all, how to handle if-range
// custom etag maybe

_respond_handle_with_size :: proc(res: ^Response, file: nbio.Handle, size: int, last_modified: time.Time) {
	assert(size > 0)

	c := connection_of_response(res)
	allocator := transaction_allocator(c)

	set_header(res, "Accept-Ranges", "bytes")

	{
		last_modified_buf, err := make([]byte, DATE_LENGTH, allocator)
		assert(err == nil) // TODO: err
		date_write(last_modified_buf, last_modified)
		set_header(res, "Last-Modified", string(last_modified_buf))
	}

	nbytes := size
	offset := 0

	condition_met := true
	if condition, has_condition := headers_get(c.req.headers, "if-range"); has_condition {
		condition_met = false
		if condition_time, ok_time := date_parse(condition); ok_time {
			last_modified_secs  := time.to_unix_seconds(last_modified)
			condition_time_secs := time.to_unix_seconds(condition_time)
			log.debugf("http[t=%v][d=%v]: if_range=%v, last_modified=%v", td.id, c.socket, condition_time_secs, last_modified_secs)
			condition_met = condition_time_secs >= last_modified_secs
		} else {
			log.infof("http[t=%v][d=%v]: if_range=%q, ok=false", td.id, c.socket, condition)
		}
	}

	if condition_met {
		if range, has_range := get_range_header(&c.req); has_range {
			log.debugf("http[t=%v][c=%v]: range=%v", td.id, c.socket, range)
			range_ok: bool
			if offset, nbytes, range_ok = apply_range_to_size(range, size); !range_ok {
				log.debugf("http[t=%v][c=%v]: range=%v, size=%v, status=%v", td.id, c.socket, range, size, Status.Range_Not_Satisfiable)
				res.status = .Range_Not_Satisfiable
				set_content_range_header(res, nil, size)
				respond(res)
				return
			}

			res.status = .Partial_Content
			set_content_range_header(res, [2]int{offset, offset+max(0, nbytes-1)}, size)
		}
	}

	set_content_length_header(res, nbytes)
	send_file(res, file, offset, nbytes)
	respond(res)
}

// send_ procs are primitives which can be called multiple times
// respond_ procs finalize the response, called once per response

SEND_ENTIRE_FILE :: nbio.SEND_ENTIRE_FILE

send_file :: proc(res: ^Response, file: nbio.Handle, offset: int = 0, nbytes: int = SEND_ENTIRE_FILE, on_sent: Send_Callback = nil) {
	nbytes := nbytes
	c := connection_of_response(res)
	log.debugf("http[t=%v][c=%v]: offset=%v, nbytes=%v", td.id, c.socket, offset, nbytes)

	switch res._state {
	case .Error:
		return
	case .None, .Handling:
		send_heading(res)
	case .Sending:
	case .Sent:
		panic("response has been sent already")
	case:
		unreachable()
	}

	if nbytes > 0 && wants_body(&c.req) {
		max := c.res.progress.max
		timeout := c.res.progress.timeout
		if max == 0 || timeout == 0 {
			res._state = .Error
			_check_send_done(c)
			return
		}

		if nbytes != SEND_ENTIRE_FILE && max >= 0 {
			nbytes = min(nbytes, c.res.progress.max)
		}

		if timeout < 0 {
			timeout = nbio.NO_TIMEOUT
		}

		res._sends += 1
		res._last_send = now()
		nbio.sendfile_poly2(c.socket, file, c, on_sent, on_send, offset=offset, nbytes=nbytes, timeout=timeout)
	}
}

send :: proc(res: ^Response, bufs: [][]byte, on_sent: Send_Callback = nil) {
	c := connection_of_response(res)
	switch res._state {
	case .Error:
		return
	case .None, .Handling:
		write_response_heading(res)
		res._state = .Sending
		if !wants_body(&c.req) || len(bufs) == 0 {
			_do_send(res, {res._buf[:]}, on_sent)
			return
		}
		new_bufs := ([^][]byte)(intrinsics.alloca(size_of([]byte) * (len(bufs) + 1), align_of([]byte)))[:len(bufs)+1]
		new_bufs[0] = res._buf[:]
		copy(new_bufs[1:], bufs)
		_do_send(res, new_bufs, on_sent)
	case .Sending:
		if !wants_body(&c.req) || len(bufs) == 0 {
			if on_sent != nil {
				on_sent(c, nil)
			}
			return
		}
		_do_send(res, bufs, on_sent)
	case .Sent:
		panic("response has been sent already")
	case:
		unreachable()
	}
}

_do_send :: proc(res: ^Response, bufs: [][]byte, on_sent: Send_Callback) {
	bufs := bufs
	c := connection_of_response(res)

	max := c.res.progress.max
	timeout := c.res.progress.timeout
	if max == 0 || timeout == 0 {
		res._state = .Error
		_check_send_done(c)
		return
	}

	if max > 0 {
		bufs = constraint_bufs(bufs, max)
	}

	if timeout < 0 {
		timeout = nbio.NO_TIMEOUT
	}

	res._sends += 1
	res._last_send = now()
	nbio.send_poly2(c.socket, bufs, c, on_sent, on_send, timeout=timeout)

	constraint_bufs :: proc(bufs: [][]byte, max: int) -> [][]byte {
		total: int
		for buf in bufs {
			total += len(buf)
		}

		constrained := bufs
		for n := total; n > max; {
			last := &constrained[len(constrained)-1]
			take := min(len(last), n-max)
			last^ = last[:take]
			if len(last) == 0 {
				constrained = constrained[:len(constrained)-1]
			}
			n -= take
		}

		return constrained
	}
}

@(private="file")
_Chunked_State :: struct {
	hdr: [20]byte,
}

@(private="file")
_response_allows_body :: proc(c: ^Connection) -> bool {
	return !status_is_informational(c.res.status) && c.res.status != .No_Content && c.res.status != .Not_Modified
}

@(private="file")
_begin_chunked :: proc(res: ^Response) -> ^_Chunked_State {
	ctx := context_of_response(res)
	if state := context_get(ctx, _Chunked_State); state != nil {
		return state
	}

	assert(res._state == .None || res._state == .Handling, "cannot begin chunked response after headers have been sent")
	assert(!headers_has(res.headers, "content-length"), "cannot use chunked encoding with Content-Length header")

	if !headers_has(res.headers, "transfer-encoding") {
		set_header(res, "Transfer-Encoding", "chunked")
	}

	return context_add(ctx, _Chunked_State{})
}

_write_chunk_header :: proc(dst: []byte, size: int) -> []byte {
	assert(size > 0)
	hex := strconv.write_int(dst[:len(dst)-2], i64(size), 16)
	dst[len(hex)]   = '\r'
	dst[len(hex)+1] = '\n'
	return dst[:len(hex)+2]
}

@(private="file")
_set_default_content_type :: proc(res: ^Response, mime: Mime_Type, loc := #caller_location) {
	if !headers_has(res.headers, "content-type") {
		set_header(res, "Content-Type", mime_to_content_type(mime), loc)
	}
}

respond :: proc(res: ^Response) {
	c := connection_of_response(res)
	is_chunked := context_get(context_of_response(res), _Chunked_State) != nil

	switch res._state {
	case .Error:
		return
	case .None, .Handling:
		if is_chunked && wants_body(&c.req) && _response_allows_body(c) {
			send(res, {transmute([]byte)string("0\r\n\r\n")})
		} else {
			send_heading(res)
		}
		if res._state == .Error {
			return
		}
	case .Sending:
		if is_chunked && wants_body(&c.req) && _response_allows_body(c) {
			send(res, {transmute([]byte)string("0\r\n\r\n")})
			if res._state == .Error {
				return
			}
		}
	case .Sent:
		panic("response has been sent already")
	case:
		unreachable()
	}

	res._state = .Sent
	_check_send_done(c)
}

respond_bytes :: proc(res: ^Response, bytes: []byte) {
	c := connection_of_response(res)

	switch res._state {
	case .Error:
		return
	case .None, .Handling:
		set_content_length_header(res, len(bytes))
		if len(bytes) > 0 {
			send(res, {bytes})
		} else {
			send_heading(res)
		}
		if res._state == .Error {
			return
		}
	case .Sent, .Sending:
		panic("response has been sent already")
	case:
		unreachable()
	}

	res._state = .Sent
	_check_send_done(c)
}

respond_plain :: proc(res: ^Response, text: string) {
	_set_default_content_type(res, .Plain)
	respond_bytes(res, transmute([]byte)text)
}

respond_html :: proc(res: ^Response, html: string) {
	_set_default_content_type(res, .Html)
	respond_bytes(res, transmute([]byte)html)
}

/*
Marshals `v` as JSON into the transaction arena and sends the response with `Content-Type: application/json` (if unset).
Buffering the serialized JSON sets an exact `Content-Length` and returns any marshal error before headers are sent.
If you need to stream large JSON payloads without buffering the entire body in memory, use `chunked_writer_init`
with `json.marshal_to_writer` instead.
*/
respond_json :: proc(res: ^Response, v: any, opt: json.Marshal_Options = {}, loc := #caller_location) -> json.Marshal_Error {
	c := connection_of_response(res)
	data := json.marshal(v, opt, transaction_allocator(c), loc) or_return
	_set_default_content_type(res, .Json, loc)
	respond_bytes(res, data)
	return nil
}

send_chunk :: proc(res: ^Response, bufs: [][]byte, on_sent: Send_Callback = nil) {
	if res._state == .Error {
		return
	}

	c := connection_of_response(res)
	state := _begin_chunked(res)

	total, non_empty := 0, 0
	for buf in bufs {
		if len(buf) > 0 {
			total += len(buf)
			non_empty += 1
		}
	}

	// Never emit a 0-length terminating chunk mid-stream; still flush headers or invoke `on_sent`.
	if total == 0 || !wants_body(&c.req) || !_response_allows_body(c) {
		send(res, nil, on_sent)
		return
	}

	hdr: []byte
	if res._sends == 0 {
		hdr = _write_chunk_header(state.hdr[:], total)
	} else {
		tmp: [20]byte
		raw := _write_chunk_header(tmp[:], total)
		alloc_err: runtime.Allocator_Error
		hdr, alloc_err = make([]byte, len(raw), transaction_allocator(c))
		if alloc_err != nil {
			res._state = .Error
			_check_send_done(c)
			return
		}
		copy(hdr, raw)
	}

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

	send(res, framed_bufs, on_sent)
}

DEFAULT_CHUNK_SIZE :: 4 * mem.Kilobyte

Chunked_Writer :: struct {
	res:        ^Response,
	buf:        [dynamic]byte,
	chunk_size: int,
	ended:      bool,
}

/*
Initializes an `io.Writer` that sends HTTP/1.1 `Transfer-Encoding: chunked` body chunks via `send_chunk`.
Writes smaller than `chunk_size` are buffered in the transaction arena until `chunk_size` is reached or `io.flush`/`io.close`
is called; pass `chunk_size <= 0` to flush every `.Write` immediately.
Call `io.close` when finished to flush remaining bytes and finalize the response with `respond`.
*/
chunked_writer_init :: proc(cw: ^Chunked_Writer, res: ^Response, chunk_size := DEFAULT_CHUNK_SIZE) -> io.Writer {
	_begin_chunked(res)
	cw^ = Chunked_Writer{
		res        = res,
		chunk_size = chunk_size,
	}

	return io.Writer{
		data = cw,
		procedure = proc(stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
			flush_buf :: proc(cw: ^Chunked_Writer) {
				if len(cw.buf) == 0 { return }
				send_chunk(cw.res, {cw.buf[:]})
				// Detach instead of clearing so the in-flight async send buffer is never mutated.
				cw.buf = {}
			}

			send_copy :: proc(cw: ^Chunked_Writer, data: []byte, tx_alloc: runtime.Allocator) -> io.Error {
				copy_buf, alloc_err := make([]byte, len(data), tx_alloc)
				if alloc_err != nil {
					return .Buffer_Full
				}
				copy(copy_buf, data)
				send_chunk(cw.res, {copy_buf})
				return nil
			}

			cw := (^Chunked_Writer)(stream_data)

			#partial switch mode {
			case .Write:
				if cw.ended || cw.res._state == .Error {
					return 0, .Closed
				}
				if len(p) == 0 {
					return 0, nil
				}

				tx_alloc := transaction_allocator(connection_of_response(cw.res))
				if cw.chunk_size <= 0 {
					send_copy(cw, p, tx_alloc) or_return
				} else if len(cw.buf) == 0 && len(p) >= cw.chunk_size {
					send_copy(cw, p, tx_alloc) or_return
				} else {
					if len(cw.buf) > 0 && len(cw.buf) + len(p) > cw.chunk_size {
						flush_buf(cw)
						if cw.res._state == .Error {
							return 0, .Closed
						}
					}

					if len(p) >= cw.chunk_size {
						send_copy(cw, p, tx_alloc) or_return
					} else {
						if cap(cw.buf) == 0 {
							buf, alloc_err := make([dynamic]byte, 0, cw.chunk_size, tx_alloc)
							if alloc_err != nil {
								return 0, .Buffer_Full
							}
							cw.buf = buf
						}
						if _, alloc_err := append(&cw.buf, ..p); alloc_err != nil {
							return 0, .Buffer_Full
						}
						if len(cw.buf) >= cw.chunk_size {
							flush_buf(cw)
						}
					}
				}

				if cw.res._state == .Error {
					return 0, .Closed
				}
				return i64(len(p)), nil

			case .Flush:
				if cw.ended || cw.res._state == .Error {
					return 0, .Closed
				}
				if len(cw.buf) > 0 {
					flush_buf(cw)
				} else if cw.res._state == .None || cw.res._state == .Handling {
					send_chunk(cw.res, nil)
				}
				if cw.res._state == .Error {
					return 0, .Closed
				}
				return 0, nil

			case .Destroy:
				if !cw.ended {
					if len(cw.buf) > 0 && cw.res._state != .Error {
						flush_buf(cw)
					}
					cw.ended = true
				}
				return 0, nil

			case .Close:
				if !cw.ended {
					if len(cw.buf) > 0 && cw.res._state != .Error {
						flush_buf(cw)
					}
					cw.ended = true
				}
				if cw.res._state != .Sent && cw.res._state != .Error {
					respond(cw.res)
				}
				if cw.res._state == .Error {
					return 0, .Closed
				}
				return 0, nil

			case .Query:
				return io.query_utility({.Write, .Flush, .Destroy, .Close})
			}

			return 0, .Unsupported
		},
	}
}

send_heading :: proc(res: ^Response, on_sent: Send_Callback = nil) {
	write_response_heading(res)

	res._state = .Sending
	_do_send(res, {res._buf[:]}, on_sent)
}

@(private="file")
_redirect_to_trailing_slash :: proc(res: ^Response) {
	c := connection_of_response(res)
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

	res.status = .Temporary_Redirect
	set_header(res, "Location", strings.to_string(b))
	respond(res)
}

@(private="file")
_respond_handle :: proc(res: ^Response, file: nbio.Handle, redirect_if_dir: bool, mime: Maybe(Mime_Type) = nil) {
	nbio.stat_poly3(file, res, redirect_if_dir, mime, on_stat)

	on_stat :: proc(op: ^nbio.Operation, res: ^Response, redirect_if_dir: bool, mime: Maybe(Mime_Type)) {
		c := connection_of_response(res)
		context.temp_allocator = temp_allocator(c)

		if op.stat.err != nil {
			log.errorf("http[t=%v][c=%v]: msg=\"failed to stat\", err=%v", td.id, c.socket, op.stat.err)
			res.status = .Not_Found
			respond(res)
			return
		}

		if op.stat.type == .Directory && redirect_if_dir {
			_redirect_to_trailing_slash(res)
			return
		}

		if op.stat.type != .Regular || op.stat.size <= 0 || op.stat.size > i64(max(int)) {
			log.warnf("http[t=%v][c=%v]: msg=\"not a regular file, too big, or no size\", type=%v, size=%v", td.id, c.socket, op.stat.type, op.stat.size)
			res.status = .Not_Found
			respond(res)
			return
		}

		if m, ok := mime.?; ok {
			_set_default_content_type(res, m)
		}

		_respond_handle_with_size(res, op.stat.handle, int(op.stat.size), op.stat.last_modified)
	}
}

respond_handle :: proc(res: ^Response, file: nbio.Handle) {
	_respond_handle(res, file, redirect_if_dir = false)
}

respond_file :: proc(res: ^Response, file: ^os.File) -> nbio.Association_Error {
	handle := nbio.associate_handle(os.fd(file)) or_return
	mime: Maybe(Mime_Type)
	if !headers_has(res.headers, "content-type") {
		if m, ok := mime_from_extension(os.name(file)); ok {
			mime = m
		}
	}
	_respond_handle(res, handle, redirect_if_dir = false, mime = mime)
	return nil
}

@(private="file")
_respond_file_path :: proc(res: ^Response, file: string, dir := nbio.CWD, redirect_if_dir := false) {
	nbio.open_poly2(file, res, redirect_if_dir, on_open, dir=dir)

	on_open :: proc(op: ^nbio.Operation, res: ^Response, redirect_if_dir: bool) {
		c := connection_of_response(res)
		context.temp_allocator = temp_allocator(c)

		if op.open.err != nil {
			log.warnf("http[t=%v][c=%v]: msg=\"failed to open\", path=%q, err=%v", td.id, c.socket, op.open.path, op.open.err)
			res.status = .Not_Found
			respond(res)
			return
		}

		mime: Maybe(Mime_Type)
		if !headers_has(res.headers, "content-type") {
			if m, ok := mime_from_extension(op.open.path); ok {
				mime = m
			}
		}

		ctx := context_of_response(res)

		Respond_File_Path_Handle :: distinct nbio.Handle
		context_add(ctx, Respond_File_Path_Handle(op.open.handle))
		response_defer(ctx, proc(ctx: ^Ctx) {
			handle := context_get(ctx, Respond_File_Path_Handle)
			nbio.close(nbio.Handle(handle^))
		})

		_respond_handle(res, op.open.handle, redirect_if_dir, mime)
	}
}

respond_file_path :: proc(res: ^Response, file: string, dir := nbio.CWD) {
	_respond_file_path(res, file, dir = dir, redirect_if_dir = false)
}

/*
Responds with the given content, automatically setting `Content-Type` from `file`'s extension if not already set.
Useful when serving files embedded at compile time with `#load(path)`.
*/
respond_file_content :: proc(res: ^Response, file: string, content: []byte) {
	if mime, ok := mime_from_extension(file); ok {
		_set_default_content_type(res, mime)
	}
	respond_bytes(res, content)
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
respond_dir :: proc(res: ^Response, target, path: string, dir := nbio.CWD) {
	c := connection_of_response(res)
	without_query, _, _ := strings.partition(c.req.line.target, "?")
	// Reject percent-encoded slashes on the raw request target: decoding turns %2f into a '/'
	// directory separator, whereas browsers still treat %2f as part of a single path segment
	// (breaking relative URL resolution on directory redirects).
	if strings.contains(without_query, "%2f") || strings.contains(without_query, "%2F") {
		res.status = .Not_Found
		respond(res)
		return
	}

	resolved, is_dir_redirect, ok := _resolve_dir_path(target, path, transaction_allocator(c))
	if !ok {
		res.status = .Not_Found
		respond(res)
		return
	}
	if is_dir_redirect {
		_redirect_to_trailing_slash(res)
		return
	}

	has_trailing_slash := len(path) > 0 && path[len(path)-1] == '/'
	_respond_file_path(res, resolved, dir = dir, redirect_if_dir = !has_trailing_slash)
}
