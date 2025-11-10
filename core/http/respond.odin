#+build !js
package http

import "core:encoding/json"
import "core:io"

// Sets the response to one that sends the given HTML.
respond_html :: proc(r: ^Response, html: string, status: Status = .OK, loc := #caller_location) {
	r.status = status
	headers_set_content_type(&r.headers, mime_to_content_type(Mime_Type.Html))
	body_set(r, html, loc)
	respond(r, loc)
}

// Sets the response to one that sends the given plain text.
respond_plain :: proc(r: ^Response, text: string, status: Status = .OK, loc := #caller_location) {
	r.status = status
	headers_set_content_type(&r.headers, mime_to_content_type(Mime_Type.Plain))
	body_set(r, text, loc)
	respond(r, loc)
}

/*
Sends the content of the file at the given path as the response.

This procedure uses non blocking IO and only allocates the size of the file in the body's buffer,
no other allocations or temporary buffers, this is to make it as fast as possible.

The content type is taken from the path, optionally overwritten using the parameter.

If the file doesn't exist, a 404 response is sent.
If any other error occurs, a 500 is sent and the error is logged.
// TODO: use nbio.sendfile
*/
// respond_file :: proc(r: ^Response, path: string, content_type: Maybe(Mime_Type) = nil, loc := #caller_location) {
// 	// PERF: we are still putting the content into the body buffer, we could stream it.
// 	// PERF: could even use `splice`/`sendfile` on Linux https://tinselcity.github.io/Sendfile-W-Iouring/
//
// 	assert_has_td(loc)
// 	assert(!r.sent, "response has already been sent", loc)
//
// 	handle, errno := nbio.open(path)
// 	if errno != nil {
// 		if errno == .Not_Exist {
// 			log.debugf("respond_file, open %q, no such file or directory", path)
// 		} else {
// 			log.warnf("respond_file, open %q error: %v", path, errno)
// 		}
//
// 		respond(r, Status.Not_Found)
// 		return
// 	}
//
// 	size, err := nbio.file_size(handle)
// 	if err != nil || int(size) < 0 {
// 		log.errorf("Could not seek the file size of file at %q, error number: %v", path, err)
// 		respond(r, Status.Internal_Server_Error)
// 		nbio.close(handle)
// 		return
// 	}
//
// 	mime := mime_from_extension(path)
// 	content_type := mime_to_content_type(mime)
// 	headers_set_content_type(&r.headers, content_type)
//
// 	_response_write_heading(r, int(size))
//
// 	bytes.buffer_grow(&r._buf, int(size))
// 	buf := dynamic_unwritten(r._buf.buf)[:size]
//
// 	on_read :: proc(user: rawptr, read: int, err: nbio.FS_Error) {
// 		r      := cast(^Response)user
// 		handle := nbio.Handle(uintptr(context.user_ptr))
//
// 		dynamic_add_len(&r._buf.buf, read)
//
// 		if err != nil {
// 			log.errorf("Reading file from respond_file failed, error number: %v", err)
// 			respond(r, Status.Internal_Server_Error)
// 			nbio.close(handle)
// 			return
// 		}
//
// 		respond(r, Status.OK)
// 		nbio.close(handle)
// 	}
//
// 	// Using the context.user_ptr to point to the file handle.
// 	context.user_ptr = rawptr(uintptr(handle))
//
// 	nbio.read_at_all(handle, 0, buf, r, on_read)
// }

/*
Responds with the given content, determining content type from the given path.

This is very useful when you want to `#load(path)` at compile time and respond with that.
*/
respond_file_content :: proc(r: ^Response, path: string, content: []byte, status: Status = .OK, loc := #caller_location) {
	mime := mime_from_extension(path)
	content_type := mime_to_content_type(mime)

	r.status = status
	headers_set_content_type(&r.headers, content_type)
	body_set(r, content, loc)
	respond(r, loc)
}

/*
Sets the response to one that, based on the request path, returns a file.
base:    The base of the request path that should be removed when retrieving the file.
target:  The path to the directory to serve.
request: The request path.

Path traversal is detected and cleaned up.
The Content-Type is set based on the file extension, see the MimeType enum for known file extensions.
*/
// TODO: use nbio.sendfile
// respond_dir :: proc(r: ^Response, base, target, request: string, loc := #caller_location) {
// 	if !strings.has_prefix(request, base) {
// 		respond(r, Status.Not_Found)
// 		return
// 	}
//
// 	full_request, err := os2.join_path({target, request}, context.temp_allocator)
// 	if err != nil {
// 		respond(r, Status.Not_Found)
// 		return
// 	}
//
// 	full_path, rerr := os2.get_relative_path(base, full_request, context.temp_allocator)
// 	if rerr != nil || !strings.has_prefix(full_path, target) {
// 		respond(r, Status.Not_Found)
// 		return
// 	}
//
// 	// TODO: there are more types of index files.
// 	if os2.is_dir(full_path) {
// 		full_path, _ = os2.join_path({full_path, "index.html"}, context.temp_allocator)
// 	}
//
// 	respond_file(r, full_path, loc = loc)
// }

// Sets the response to one that returns the JSON representation of the given value.
respond_json :: proc(r: ^Response, v: any, status: Status = .OK, opt: json.Marshal_Options = {}, loc := #caller_location) -> (err: json.Marshal_Error) {
	opt := opt

	r.status = status
	headers_set_content_type(&r.headers, mime_to_content_type(Mime_Type.Json))

	// Going to write a MINIMUM of 128 bytes at a time.
	rw:  Response_Writer
	buf: [128]byte
	response_writer_init(&rw, r, buf[:])

	// Ends the body and sends the response.
	defer io.close(rw.w)

	if err = json.marshal_to_writer(rw.w, v, &opt); err != nil {
		headers_set_close(&r.headers)
		response_status(r, .Internal_Server_Error)
	}

	return
}

/*
Prefer the procedure group `respond`.
*/
respond_with_none :: proc(r: ^Response, loc := #caller_location) {
	assert_has_td(loc)

	loop := res_loop(r)
	conn := loop_conn(loop)
	req  := loop.req

	// Respond as head request if we set it to get.
	if rline, ok := req.line.(Requestline); ok && req.is_head && conn.server.opts.redirect_head_to_get {
		rline.method = .Head
	}

	response_send(r, conn, loc)
}

/*
Prefer the procedure group `respond`.
*/
respond_with_status :: proc(r: ^Response, status: Status, loc := #caller_location) {
	response_status(r, status)
	respond(r, loc)
}

// Sends the response back to the client, handlers should call this.
respond :: proc {
	respond_with_none,
	respond_with_status,
}
