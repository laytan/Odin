package http

import "core:nbio"
import "core:slice"

// TODO: timeouts

// TODO: set max concurrency

// TODO: accept a different allocator, on which the response is allocated.

// TODO: sync can only be done in non-js :(.

Client :: _Client

On_Response :: #type proc(req: Client_Request, res: ^Client_Response, err: Request_Error)

Client_Request :: struct {
	user_data: rawptr,
	cb:        On_Response,

	headers: Headers,

	url:     string,
	cookies: []Cookie,
	body:    []byte,

	method:  Method,

	js_cors:        JS_CORS_Mode,
	js_credentials: JS_Credentials,

	// TODO: implement following redirects on native.
	ignore_redirects: bool,
}

// WARN: DO NOT change the layout of this enum or the following struct without at least make sure you didn't break the JS implementation!

Request_Error :: enum {
	None,
	Partial,
	Bad_URL,
	Network,
	CORS,
	Timeout,
	Aborted,
	Unknown,
	DNS,
}

// TODO: maybe should hold the client so the callback can get the client without passing it through.
// + response_destroy could be made to use that instead of taking the client too.
Client_Response :: struct {
	status:  Status,
	body:    [dynamic]byte `fmt:"s"`,
	headers: Headers,

	// NOTE: unused on JS targets, use the `js_credentials` option to configure cookies there.
	// TODO: Implement a proper cookie jar per client, see rfc.
	// it should take response cookies, add it to the jar and automatically add them to matching requests again.
	// we can then make use of `js_credentials` on native too.
	cookies: [dynamic]Cookie,
}

JS_CORS_Mode :: enum u8 {
	CORS,
	No_CORS,
	Same_Origin,
}

// Policy for including and taking credentials (cookies, etc.) from responses and adding them to requests.
JS_Credentials :: enum u8 {
	Same_Origin, // Include credentials only when requesting to the same origin.
	Include,     // Always include credentials.
	Omit,        // Never include credentials.
}

// TODO: return error enum.
client_init :: proc(c: ^Client, allocator := context.allocator) -> bool {
	if err := nbio.acquire_thread_event_loop(); err != nil {
		return false
	}
	return _client_init(c, allocator)
}

client_destroy :: proc(c: ^Client) {
	_client_destroy(nil, c)
	nbio.release_thread_event_loop()
}

response_destroy :: proc(c: ^Client, res: Client_Response) {
	_response_destroy(c, res)
}

get :: proc(url: string, user_data: rawptr = nil, cb: On_Response = nil) -> Client_Request {
	return { url = url, user_data = user_data, cb = cb }
}

// TODO: post, post_json, yada yada

request :: proc(c: ^Client, req: Client_Request) {
	// TODO: make sure client is initialized
	_client_request(c, req)
}

Multi_Res :: struct {
	res: Client_Response,
	err: Request_Error,
}

responses_destroy :: proc(c: ^Client, s: []Multi_Res) {
	for &res in s {
		if res.err == nil {
			response_destroy(c, res.res)
		}
	}
	delete(s)
}

sync_one_request :: proc(c: ^Client, req: Client_Request) -> (Client_Response, Request_Error) {
	not_js()

	req := req

	State :: struct {
		res:  Client_Response,
		err:  Request_Error,
		done: bool,

		orig_cb:        On_Response,
		orig_user_data: rawptr,
	}
	s: State
	s.orig_cb        = req.cb
	s.orig_user_data = req.user_data

	req.user_data = &s
	req.cb = proc(req: Client_Request, res: ^Client_Response, err: Request_Error) {
		s := (^State)(req.user_data)

		if s.orig_cb != nil {
			// NOTE: Not ideal copy.
			req := req
			req.user_data = s.orig_user_data
			req.cb        = s.orig_cb
			s.orig_cb(req, res, err)
		}

		if err != .Partial {
			s.res = res^
			s.err = err
			s.done = true
		}
	}
	_client_request(c, req)

	for {
		if s.done {
			return s.res, s.err
		}

		if err := nbio.tick(); err != nil {
			return {}, .Unknown
		}
	}
}

/*
Sends out all requests given asynchronously in chunks of 64.
*/
sync_requests :: proc(c: ^Client, reqs: ..Client_Request) -> []Multi_Res {
	not_js()

	res, err := make([]Multi_Res, len(reqs))
	if err != nil { return nil }
	sync_requests_into(c, reqs, res)
	return res
}

/*
Sends out all requests given asynchronously in chunks of 64.
*/
sync_requests_into :: proc(c: ^Client, reqs: []Client_Request, res: []Multi_Res) #no_bounds_check {
	not_js()

	assert(len(res) >= len(reqs))

	Done :: bit_set[0..<64; u64]

	i: int
	for chunk in slice.iter_chunks(reqs, 64, &i) {
		done: Done
		context.user_ptr = &done

		for &req, j in chunk {

			// TODO: support this.
			assert(req.cb == nil, "unimplemented: sync_requests with user cb too")

			context.user_index = j

			req.user_data = &res[((i-1)*64)+j]
			req.cb = proc(req: Client_Request, res: ^Client_Response, err: Request_Error) {

				// TODO: support this.
				if err == .Partial {
					return
				}

				mr := (^Multi_Res)(req.user_data)
				mr.res = res^
				mr.err = err

				done  := (^Done)(context.user_ptr)
				done^ += { context.user_index }
			}
			_client_request(c, req)
		}

		for {
			if card(done) == len(chunk) {
				break
			}

			if err := nbio.tick(); err != nil {
				for &r in res[(i-1)*64:] {
					r.err = .Unknown
				}
				return
			}
		}
	}

	return
}

sync_request :: proc {
	sync_one_request,
	sync_requests,
	sync_requests_into,
}

@(private="file", disabled=ODIN_OS != .JS)
not_js :: proc(loc := #caller_location) {
	panic("Synchronized HTTP requests cannot be done in JS, you have to use the http.request() procedure and use callbacks", loc=loc)
}
