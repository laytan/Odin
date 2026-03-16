#+vet explicit-allocators
package http

import "base:intrinsics"

import "core:nbio"
import "core:os"
import "core:log"
import "core:time"
import "core:strings"

// TODO: respond_file_content

set_content_length_header :: proc(res: ^Response, length: int, loc := #caller_location) {
	if length <= 0 { return }
	b := strings.builder_make(0, transaction_allocator(connection_of_response(res)))
	strings.write_int(&b, length)
	set_header(res, "Content-Length", strings.to_string(b), loc)
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
	return req.line.method != .Head && !req.is_redirected_head
}

set_header :: proc(res: ^Response, key, value: string, loc := #caller_location) {
	headers_set(&res.headers, key, value, loc)
}

get_header :: proc(req: ^Request, key: string) -> (string, bool) {
	return headers_get(req.headers, key)
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

send_file :: proc(res: ^Response, file: nbio.Handle, offset, nbytes: int) {
	c := connection_of_response(res)
	log.debugf("http[t=%v][c=%v]: offset=%v, nbytes=%v", td.id, c.socket, offset, nbytes)

	send_heading(res)
	if nbytes > 0 && wants_body(&c.req) {
		nbio.sendfile_poly(c.socket, file, c, on_send, offset=offset, nbytes=nbytes)
	}
}

respond_handle :: proc(res: ^Response, file: nbio.Handle) {
	nbio.stat_poly(file, res, on_stat)

	on_stat :: proc(op: ^nbio.Operation, res: ^Response) {
		if op.stat.err != nil {
			c := connection_of_response(res)
			log.errorf("http[t=%v][c=%v]: msg=\"failed to stat\", err=%v", td.id, c.socket, op.stat.err)
			res.status = .Not_Found
			respond(res)
			return
		}

		if op.stat.size <= 0 || op.stat.size > i64(max(int)) {
			c := connection_of_response(res)
			log.errorf("http[t=%v][c=%v]: msg=\"file too big or no size\", type=%v, size=%v", td.id, c.socket, op.stat.type, op.stat.size)
			res.status = .Not_Found
			respond(res)
			return
		}

		_respond_handle_with_size(res, op.stat.handle, int(op.stat.size), op.stat.last_modified)
	}
}

respond_file :: proc(res: ^Response, file: ^os.File) -> nbio.Association_Error {
	// TODO: set content type
	handle := nbio.associate_handle(os.fd(file)) or_return
	respond_handle(res, handle)
	return nil
}

respond_file_path :: proc(res: ^Response, file: string, dir := nbio.CWD) {
	nbio.open_poly(file, res, on_open, dir=dir)

	// TODO: set content type

	on_open :: proc(op: ^nbio.Operation, res: ^Response) {
		if op.open.err != nil {
			c := connection_of_response(res)
			log.warnf("http[t=%v][c=%v]: msg=\"failed to open\", path=%q, err=%v", td.id, c.socket, op.open.path, op.open.err)
			res.status = .Not_Found
			respond(res)
			return
		}

		Respond_File_Path_Handle :: distinct nbio.Handle
		context_add(context_of_response(res), Respond_File_Path_Handle(op.open.handle))
		response_defer(res, proc(res: ^Response) {
			handle := context_get(context_of_response(res), Respond_File_Path_Handle)
			nbio.close(nbio.Handle(handle^))
		})

		respond_handle(res, op.open.handle)
	}
}
