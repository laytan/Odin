#+private
package http

import "base:runtime"

import "core:nbio"
import "core:slice"

@(extra_linker_flags="--export-table")
foreign import "odin_io"

_Client :: struct {
	allocator: runtime.Allocator,
}

_client_init :: proc(c: ^Client, allocator := context.allocator) -> bool {
	c.allocator = allocator
	// TODO: do a health check?
	return true
}

_client_destroy :: proc(c: ^Client) {
	unimplemented()
}

_response_destroy :: proc(c: ^Client, res: Client_Response) {
	unimplemented()
}

@(private="file", rodata)
CORS_MODE_STRINGS := [JS_CORS_Mode]string{
	.CORS        = "cors",
	.No_CORS     = "no-cors",
	.Same_Origin = "same-origin",
}

@(private="file", rodata)
CREDENTIAL_STRINGS := [JS_Credentials]string{
	.Same_Origin = "same-origin",
	.Include     = "include",
	.Omit        = "omit",
}

@(private="file")
In_Flight :: struct {
	method:           string,
	url:              string,
	headers:          []slice.Map_Entry(string, string),
	body:             []byte,
	ignore_redirects: bool,
	cors:             string,
	credentials:      string,

	res:  Client_Response,
	user: rawptr,
	cb:   On_Response,
	ctx:  runtime.Context,
}

@(export, private="file")
http_client_req_ctx :: proc(req: ^In_Flight) -> ^runtime.Context {
	return &req.ctx
}

@(private="file")
On_Internal_Response :: #type proc "contextless" (c: ^Client, r: ^In_Flight, err: Request_Error)

_client_request :: proc(c: ^Client, req: Client_Request, user: rawptr, cb: On_Response) {
	foreign odin_io {
		http_request :: proc "contextless" (c: ^Client, r: ^In_Flight, cb: On_Internal_Response) ---
	}

	// TODO: cookies

	context.allocator = c.allocator

	r := new(In_Flight)
	r.ctx = context

	r.method  = method_string(req.method)
	r.url = req.url

	// TODO/PERF: iterating the rbtree from within JS to skip this work.
	headers := req.headers
	r.headers = make([]slice.Map_Entry(string, string), headers_count(headers), /* allocator */)
	i: int
	iter := headers_iterator(&headers)
	for k, v in headers_next(&iter) {
		r.headers[i] = {k, v}
		i += 1
	}

	r.body = req.body
	r.ignore_redirects = req.ignore_redirects

	r.cors = CORS_MODE_STRINGS[req.js_cors]
	r.credentials = CREDENTIAL_STRINGS[req.js_credentials]

	r.user = user
	r.cb = cb

	headers_init(&r.res.headers)

	http_request(c, r, on_response)

	on_response :: proc "contextless" (c: ^Client, r: ^In_Flight, err: Request_Error) {
		context = r.ctx

		delete(r.headers, /* allocator */)

		r.res.headers.readonly = true

		r.cb(r.res, r.user, err)
	}
}

@(private="file", export)
http_alloc :: proc "contextless" (r: ^In_Flight, size: i32) -> rawptr {
	context = r.ctx
	return make([^]byte, size)
}

@(private="file", export)
http_res_header_set :: proc "contextless" (r: ^In_Flight, key: string, value: string) {
	context = r.ctx
	headers_set(&r.res.headers, key, value)
}
