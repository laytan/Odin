#+vet explicit-allocators
package http

import "base:intrinsics"
import "base:runtime"

import "core:nbio"
import "core:os"
import "core:log"
import "core:time"
import "core:strings"

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

	switch res.state {
	case .Error:
		return
	case .None, .Handling:
		send_response_heading(res)
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
			res.state = .Error
			_check_send_done(c)
			return
		}

		if nbytes != SEND_ENTIRE_FILE && max >= 0 {
			nbytes = min(nbytes, c.res.progress.max)
		}

		if timeout < 0 {
			timeout = nbio.NO_TIMEOUT
		}

		res.sends += 1
		res.last_send = now()
		nbio.sendfile_poly2(c.socket, file, c, on_sent, on_send, offset=offset, nbytes=nbytes, timeout=timeout)
	}
}

send :: proc(res: ^Response, bufs: [][]byte, on_sent: Send_Callback = nil) {
	c := connection_of_response(res)
	switch res.state {
	case .Error:
		return
	case .None, .Handling:
		write_response_heading(res)
		res.state = .Sending
		if !wants_body(&c.req) || len(bufs) == 0 {
			_do_send(res, {res.buf[:]}, on_sent)
			return
		}
		new_bufs := ([^][]byte)(intrinsics.alloca(size_of([]byte) * (len(bufs) + 1), align_of([]byte)))[:len(bufs)+1]
		new_bufs[0] = res.buf[:]
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
		res.state = .Error
		_check_send_done(c)
		return
	}

	if max > 0 {
		bufs = constraint_bufs(bufs, max)
	}

	if timeout < 0 {
		timeout = nbio.NO_TIMEOUT
	}

	res.sends += 1
	res.last_send = now()
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

respond :: proc(res: ^Response) {
	c := connection_of_response(res)

	switch res.state {
	case .Error:
		return
	case .None, .Handling:
		send_response_heading(res)
		if res.state == .Error {
			return
		}
	case .Sending:
	case .Sent:
		panic("response has been sent already")
	case:
		unreachable()
	}

	res.state = .Sent
	_check_send_done(c)
}

respond_bytes :: proc(res: ^Response, bytes: []byte) {
	c := connection_of_response(res)

	switch res.state {
	case .Error:
		return
	case .None, .Handling:
		set_content_length_header(res, len(bytes))
		if len(bytes) > 0 {
			send(res, {bytes})
		} else {
			send_response_heading(res)
		}
		if res.state == .Error {
			return
		}
	case .Sent, .Sending:
		panic("response has been sent already")
	case:
		unreachable()
	}

	res.state = .Sent
	_check_send_done(c)
}

send_response_heading :: proc(res: ^Response, on_sent: Send_Callback = nil) {
	write_response_heading(res)

	res.state = .Sending
	_do_send(res, {res.buf[:]}, on_sent)
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
		if op.stat.err != nil {
			c := connection_of_response(res)
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
			c := connection_of_response(res)
			log.warnf("http[t=%v][c=%v]: msg=\"not a regular file, too big, or no size\", type=%v, size=%v", td.id, c.socket, op.stat.type, op.stat.size)
			res.status = .Not_Found
			respond(res)
			return
		}

		if m, ok := mime.?; ok && !headers_has(res.headers, "content-type") {
			set_header(res, "Content-Type", mime_to_content_type(m))
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
		if op.open.err != nil {
			c := connection_of_response(res)
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
	if !headers_has(res.headers, "content-type") {
		if mime, ok := mime_from_extension(file); ok {
			set_header(res, "Content-Type", mime_to_content_type(mime))
		}
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
