package http

import "core:io"
import "core:mem"
import "core:nbio"
import "core:strings"
import "core:time"
import "core:slice"

// TODO: what about an extra layer? Just handling the request, taking in a connection, the request, returning the response.
// Then the next layer is the actual client which handles caching dns, keep alives, redirects, etc.
// That inner layer can then be native only, and the higher level client can be JS too.
//
// Levels?
// Issuer: low level, no idle connections, dns, keep alive, following redirects, etc. Just issues the request, nothing more.
// Client: uses issuer, dns, with keep alive, connection management, dns caching, following redirects, etc. Default global client.
// Issuer_Connection :: struct {
// 	ep:         Endpoint,
// 	ssl:        SSL_Connection,
// 	socket:     nbio.TCP_Socket,
// 	scanner:    Scanner,
// 	using body: Has_Body,
// }
// NOTE: does not do DNS, connection.ep needs to be set.
// issue :: proc(ssl: SSL_Client, connection: ^Issuer_Connection, request: Outgoing_Request) {
// }

// TODO: default to https, default global client.


// TODO: Websocket sketch:
// TODO: Could also use the issuer instead, that won't need any "detaching" because the caller owns the connection already.
// ws_upgrade :: proc(req: Outgoing_Request, res: ^Incoming_Response, err: Request_Error) {
// 	if err != nil {
// 		return err
// 	} else if res.status != .Switching_Protocols {
// 		return .Invalid_Status
// 	}
//
// 	// Preps the client it will be upgraded, doesn't put connection back into pool etc.
// 	return .Upgrade
// }
//
// res, err := request_and_wait(request("laytan.dev/socket", {
// 	headers = headers_create(
// 		{"Upgrade",    "websocket"},
// 		{"Connection", "Upgrade"  },
//		allocator=context.temp_allocator,
// 	),
// 	cb = ws_upgrade,
// }))
//
// // Retrieve the upgraded connection, transferring ownership.
// assert(err == .Upgrade)
// connection := response_do_upgrade(res)
//
// // Use connection for websocket.


// TODO: accept a different allocator, on which the response is allocated.

// TODO: client thread-safe?

/*
A client that will handle requests.

Zero-initialized but can be configured with `client_init`.

The client will handle DNS caching, connections that can be kept alive, and of course orchestrate requests.

This is not supposed to be used directly, targets can have a differing implementation.
*/
Client :: _Client

/*
TODO: helper procs to set up the struct?

Descriptor for a request to be executed.

Everything but `url` is zero-initialized when doing `_and_wait` requests, for async requests `cb` is required too.
By default doing a GET request, with no headers or body, following redirects, accumulating the response body into a buffer.
*/
Outgoing_Request :: struct {
	// The body of the request, see `Outgoing_Body` for more information.
	body:    Outgoing_Body,
	headers: Headers,
	allocator: mem.Allocator,
	url:     string, // TODO: allow URL?
	using callback: Incoming_Callback,
	method:           Method,
	// Redirects are followed by default.
	ignore_redirects: bool,
	web_cors:         Web_CORS_Mode,
	web_credentials:  Web_Credentials,
}

Incoming_Callback :: struct {
	// Data passed through to the `cb` when it is called.
	user_data: rawptr,
	// Callback for the (maybe partial) response, see `On_Incoming_Response` for more information.
	cb:        On_Incoming_Response,
}

// TODO: implement/support.
// TODO: DNS options.
// Options :: struct {
// 	// Disables keeping idle connections around.
// 	// A connection is made for each request.
// 	disable_keepalive: bool,
//
// 	// Maximum amount of connections (including idle).
// 	// Queues new requests when reached.
// 	// Default: 0 (unlimited)
// 	max_connections:          int,
// 	// Maximum amount of connections per host (including idle).
// 	// Queues new requests when reached.
// 	// Default: 128
// 	max_connections_per_host: int,
//
// 	// Maximum amount of idle connections, clamped to `max_connections`.
// 	// Evicts "random" connections when reached.
// 	// Default: 0 (unlimited)
// 	max_idle_connections:          int,
// 	// Maximum amount of idle connections per host, clamped to `max_connections_per_host`. 
// 	// Evicts connections when reached.
// 	// Default: 0 (unlimited, clamped to `max_connections_per_host`)
// 	max_idle_connections_per_host: int,
//
// 	// The size of the buffer used for response bodies.
// 	// When a body is larger, the response callback (with .Partial) is called when the buffer is full.
// 	// This buffer is also used for requests when the body is an `io.Writer`.
// 	// Default: 16 KiB
// 	buffer_size: int,
//
// 	// The maximum size of the response's headers.
// 	// Default: 10 MiB
// 	max_headers_size: int,
// 	// The maximum size of the response's body.
// 	// Default: 1 TiB
// 	max_body_size: int,
//
//      // Check that gets called on redirect responses, should decide if it should be followed.
//      // `from` is the request that was responded to with a redirect, `to` is the redirected request
//      // about to be made, `n` is the amount of redirects that have been done already.
//      // Default: If not to the same target and n <= 10.
//      follow_redirect: proc(from, to: Outgoing_Request, n: int) -> bool,
//
// 	quota: Quota,
// }
// DEFAULT_OPTIONS :: Options{
// 	max_connections_per_host = 128,
//
// 	buffer_size      = 16 * mem.Kilobyte,
// 	max_headers_size = 10 * mem.Megabyte,
// 	max_body_size    = 1  * mem.Terabyte,
//
//      follow_redirect  = default_follow_redirect,
//
// 	quota            = DEFAULT_QUOTA,
// }
// default_follow_redirect :: proc(from, to: Outgoing_Request, n: int) -> bool {
// 	return from.url != to.url && n <= 10
// }
//
// Quota :: struct {
// 	// The max amount of time a connection is allowed to stay idle without activity before it is closed.
// 	// Default: 30 seconds.
// 	idle:          time.Duration,
//
//      // The max amount of time a complete request&response may take.
//      // Default: 1 hour.
//      complete:      time.Duration,
// 	// The max amount of time a DNS name server can take to respond.
// 	// Default: 1 second.
// 	dns_resolve:   time.Duration,
// 	// The max amount of time for a TCP connection to be established.
// 	// Default: 10 seconds.
// 	tcp_connect:   time.Duration,
// 	// The max amount of time for a TLS handshake to complete.
// 	// Default: 10 seconds.
// 	tls_handshake: time.Duration,
// 	// The max amount of time sending our request can take.
// 	// Default: 0 (unlimited)
// 	send_request:  time.Duration,
// 	// The max amount of time to wait on the server's headers to be sent.
// 	// Default: 30 seconds.
// 	headers:       time.Duration,
// 	// The max amount of time to wait on the server's body to be sent.
// 	// Default: 0 (unlimited).
// 	body:          time.Duration,
// }
// DEFAULT_QUOTA :: Quota{
// 	idle          = 30 * time.Second,
//
//      complete      = 1  * time.Hour,
// 	dns_resolve   = 1  * time.Second,
// 	tcp_connect   = 10 * time.Second,
// 	tls_handshake = 10 * time.Second,
// 	headers       = 30 * time.Second,
// }

/*
TODO: pointer is awkward.
TODO: ability to return something that cancels the request, and something that "detaches" it (for upgrade requests).

Optional callback to handle the incoming response.

The default (if left empty in an `Outgoing_Request` is to accumulate into `Incoming_Response.body`.
For the caller to use after the entire request completes.

The callback may be called multiple times with the `err` set to `.Partial`. This means we got a part
of the response body, and have put it into `Incoming_Response.body` for you to deal with.

This can be used to ingest the response body in a streaming fashion.
As an example, you could stream the body into a file with the following psuedo set-up.

Example:
	if err == .Partial {
		os.write(file, res.body[:])
		clear(&res.body) // Clearing the used data from the body, new body data is then written here again.
	}
*/
On_Incoming_Response :: #type proc(req: Outgoing_Request, res: ^Incoming_Response, err: Request_Error)

/*
Body attached to the request.

Allows for a direct slice of bytes or string, and for an `io.Reader`.

`size` is used internally but can also be set to skip trying to retrieve the size of the `io.Reader` with `io.size`.
If `size` is negative, or `io.size` returns `.Empty` (aka there is no size), chunked/streamed encoding is used.
*/
Outgoing_Body :: struct {
	size: Maybe(i64),
	content: union #no_nil {
		[]byte,
		string,
		io.Reader,
		// TODO: implement, we have `nbio.sendfile` but for TLS we need to add it to the TLS interface.
		//
		// OpenSSL has `SSL_sendfile` (which requires kernel TLS).
		//
		// Windows has kernel TLS which you can enable and then encryption/decryption is done in the kernel.
		// Theoretically we can enable KTLS and then switch to `nbio.sendfile`?
		// Can then even just use `nbio.send` etc. Instead of the polling we do in the current windows TLS impl.
		//
		nbio.Handle,
	},
}

// TODO: use all the errors, add more errors for all the quotas.
Request_Error :: enum {
	None,
	// Not a real error, means we got data but the full response is not received yet.
	Partial,

	Allocation_Failure,

	// Given URL is invalid or empty.
	URL_Invalid,
	// Given port is not a number or not a valid port number.
	Port_Invalid,

	// Error with the outgoing body's stream during read.
	Outgoing_Body_Error,

	// DNS server reached the configured timeout.
	DNS_Timeout,
	// DNS Config was invalid, no nameservers, could not read config, etc.
	DNS_Config,
	// DNS servers returned an invalid response.
	DNS_Response_Invalid,
	// DNS could not be resolved by the server.
	DNS_Not_Resolved,

	// Problems with the connection to the network.
	Network,
	// Could not connect to the host.
	Connection_Failure,
	TCP_Connect_Timeout,
	TLS_Handshake_Timeout,
	// Server shut down the connection when not expected.
	TLS_Shutdown,
	// TLS failed.
	TLS_Error,
	Send_Request_Timeout,
	// CORS error, on the web.
	CORS,
	// Response reached a configured timeout.
	Response_Timeout,
	Receive_Response_Error,

	Bad_Response,
	Unsupported_HTTP_Version,
	// Server responded with an invalid header.
	Invalid_Header,

	// Server responded with an invalid cookie.
	// Invalid_Cookie,
	// Response exceeded size limit.
	Exceeds_Max_Size,
	// Server aborted the connection while the request was being made.
	Aborted,

	// An error that does not fit one of the above.
	Unknown,
}

/*
A response from the server.
*/
Incoming_Response :: struct {
	status:  Status,
	body:    [dynamic]byte,
	headers: Headers,
}

/*
Sets cross-origin behavior for the request when targeting the web.

[[ More; https://developer.mozilla.org/en-US/docs/Web/API/RequestInit#mode ]]
*/
Web_CORS_Mode :: enum u8 {
	CORS,
	No_CORS,
	Same_Origin,
}

/*
Policy for including and taking credentials (cookies, etc.) from responses and adding them to requests.

Currently only in use when targeting the web.

[[ More; https://developer.mozilla.org/en-US/docs/Web/API/RequestInit#credentials ]]
*/
Web_Credentials :: enum u8 {
	// Include credentials only when requesting to the same origin.
	Same_Origin,
	// Always include credentials.
	Include,
	// Never include credentials.
	Omit,
}

// TODO: return error enum.
// TODO: options: ssl impl, timeouts, limits (connections, concurrent connections etc.).
client_init :: proc(c: ^Client, allocator := context.allocator) -> bool {
	assert(c != nil, "client is nil")
	if c.initialized {
		return false
	}
	c.initialized = true

	if err := nbio.acquire_thread_event_loop(); err != nil {
		return false
	}
	return _client_init(c, allocator)
}

/*
Destroys the client.

The client is not immediately destroyed, it may use the event loop.
*/
client_destroy :: proc(c: ^Client) {
	_client_destroy(nil, c)
}

/*
Destroy the client and wait for it to be done.

Useful if you are using a tracking allocator/asan.
*/
client_destroy_and_wait :: proc(c: ^Client) {
	destroyed: bool

	_client_destroy(nil, c, &destroyed, proc (destroyed: rawptr) {
		(^bool)(destroyed)^ = true
	})

	nbio.run_until(&destroyed)
}

incoming_response_destroy :: proc(res: Incoming_Response) {
	_incoming_response_destroy(res)
}

request :: proc(c: ^Client, url: string, req: Outgoing_Request = {}, allocator := context.allocator) {
	// TODO: can we do ZII?
	assert(c != nil, "client is nil")
	assert(c.initialized, "client is not initialized")

	req := req
	req.url = url
	if req.allocator.procedure == nil {
		req.allocator = allocator
	}

	_request(c, req)
}

request_and_wait :: proc(c: ^Client, url: string, req: Outgoing_Request = {}, allocator := context.allocator) -> (Incoming_Response, Request_Error) {
	not_js()

	req := req

	State :: struct {
		res:  Incoming_Response,
		err:  Request_Error,
		done: bool,

		orig_cb:        On_Incoming_Response,
		orig_user_data: rawptr,
	}
	s: State
	s.orig_cb        = req.cb
	s.orig_user_data = req.user_data

	req.user_data = &s
	req.cb = proc(req: Outgoing_Request, res: ^Incoming_Response, err: Request_Error) {
		s := (^State)(req.user_data)

		if s.orig_cb != nil {
			// NOTE: Not ideal copy.
			req := req
			req.user_data = s.orig_user_data
			req.cb        = s.orig_cb
			s.orig_cb(req, res, err)
		}

		if err != .Partial {
			if res != nil {
				s.res = res^
			}
			s.err = err
			s.done = true
		}
	}
	request(c, url, req, allocator)

	for {
		if s.done {
			return s.res, s.err
		}

		if err := nbio.tick(); err != nil {
			return {}, .Unknown
		}
	}
}

incoming_body_to_stream :: proc(writer: ^io.Writer) -> Incoming_Callback {
	return {
		user_data = writer,
		cb = proc (req: Outgoing_Request, res: ^Incoming_Response, err: Request_Error) {
			if err != nil && err != .Partial {
				return
			}

			writer := (^io.Writer)(req.user_data)
			_, write_err := io.write_full(writer^, res.body[:])
			assert(write_err == nil) // TODO: some way to cancel the rest of the request and error out from here.
			clear(&res.body)
		},
	}
}

// TODO: fix up and uncomment
Incoming_Result :: struct {
	res: Incoming_Response,
	err: Request_Error,
}

incoming_results_destroy :: proc(results: []Incoming_Result, results_allocator := context.allocator) {
	for &res in results {
		if res.err == nil {
			incoming_response_destroy(res.res)
		}
	}
	delete(results, results_allocator)
}

/*
Sends out all requests given asynchronously in chunks of 64.

Not allowed to be used on the web.
*/
request_and_wait_multiple :: proc(c: ^Client, reqs: ..Outgoing_Request, results_allocator := context.allocator) -> []Incoming_Result {
	not_js()

	res, err := make([]Incoming_Result, len(reqs), results_allocator)
	if err != nil { return nil }
	request_and_wait_multiple_into_buffer(c, reqs, res)
	return res
}

/*
Sends out all requests given asynchronously in chunks of 64, filling the given buffers with results.

Not allowed to be used on the web.
*/
request_and_wait_multiple_into_buffer :: proc(c: ^Client, reqs: []Outgoing_Request, res: []Incoming_Result) #no_bounds_check {
	not_js()

	assert(len(res) >= len(reqs))

	Done :: bit_set[0..<64; u64]

	i: int
	for chunk in slice.iter_chunks(reqs, 64, &i) {
		done: Done
		context.user_ptr = &done

		State :: struct {
			callback: Incoming_Callback,
			res:      ^Incoming_Result,
		}
		states: [64]State

		for &req, j in chunk {
			context.user_index = j

			states[j].res = &res[((i-1)*64)+j]
			states[j].callback = req.callback

			req.user_data = &states[j]
			req.cb = proc(req: Outgoing_Request, res: ^Incoming_Response, err: Request_Error) {

				state := (^State)(req.user_data)

				if state.callback.cb != nil {
					req := req
					req.callback = state.callback
					state.callback.cb(req, res, err)
				}

				if err != .Partial {
					mr := state.res
					if res != nil {
						mr.res = res^
					}
					mr.err = err

					done  := (^Done)(context.user_ptr)
					done^ += { context.user_index }
				}
			}

			if req.allocator.procedure == nil {
				req.allocator = context.allocator
			}

			_request(c, req)
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

@(private="file", disabled=ODIN_OS != .JS)
not_js :: proc(loc := #caller_location) {
	panic("Synchronized HTTP requests cannot be done in JS, you have to use the http.request() procedure and use callbacks", loc=loc)
}

Incoming_SSE :: struct {
	type: string,
	data: string,
}

Incoming_SSE_Iterator :: struct {
	buf:      [dynamic]byte,
	last_id:  string,
	retry:    time.Duration,
	consumed: int,
}

/*
Initializes the SSE (Server Sent Events) iterator with an allocator that is used to temporarily allocate data spanning multiple lines.
*/
incoming_SSE_iterator_init :: proc(it: ^Incoming_SSE_Iterator, allocator := context.allocator) {
	it.buf.allocator = allocator
}

/*
Removes the consumed portion of the body and deletes the internal buffer.
*/
incoming_SSE_iterator_destroy :: proc(it: Incoming_SSE_Iterator, body: ^[dynamic]byte) {
	delete(it.buf)
	remove_range(body, 0, it.consumed)
}

/*
Iterates over server sent events (SSE) currently available in the response body.

May allocate on the buffer if the event spans multiple lines, the strings are slices into the body buffer otherwise.
Returned `data` is only valid to be used until the next iteration/when the iterator is destroyed.

Does not implement the reconnecting part, that is up to you if needed, it does return the parsed information for it.
So if you need long running state preserving connections you can, as specified in [[ the spec ; https://html.spec.whatwg.org/multipage/server-sent-events.html ]]:
- Keep track of the `it.last_id` (if not empty) that is last returned, and when reconnecting, put it on the `Last-Event-ID` header.
- Keep track of the `it.retry` (if non-zero) that is last returned, and when reconnecting, first wait for that duration.
*/
incoming_SSE_iterator :: proc(it: ^Incoming_SSE_Iterator, body: []byte) -> (type, data: string, ok: bool) {
	type = "message"

	resize(&it.buf, 0)

	// NOTE: needed because an empty string check does not suffice, because an empty string is a valid message.
	got_data: bool

	consumed := 0
	body := string(body[it.consumed:])
	lines: for line, consumed_iter in _SSE_line_iterator(&body) {
		consumed += consumed_iter

		if line == "" {
			if !got_data && len(it.buf) == 0 {
				type     = "message"
				data     = ""
				got_data = false
				continue
			} else {
				if len(it.buf) > 0 {
					data = string(it.buf[:])
				}
				it.consumed += consumed
				ok = true
				return
			}
		}

		if strings.has_prefix(line, ":") {
			continue
		}

		field, _, value := strings.partition(line, ":")
		value = strings.trim_prefix(value, " ")

		switch field {
		case "event":
			type = value
		case "data":
			if len(it.buf) > 0 {
				append(&it.buf, "\n")
				append(&it.buf, value)
			} else if got_data {
				append(&it.buf, data)
				append(&it.buf, "\n")
				append(&it.buf, value)
			} else {
				got_data = true
				data = value
			}
		case "id":
			if !strings.contains(value, "\x00") {
				it.last_id = value
			}
		case "retry":
			it.retry = 0
			for ch in value {
				switch ch {
				case '0'..='9':
					it.retry *= 10
					it.retry += time.Duration(ch-'0')
				case:
					// Invalid character
					it.retry = 0
					continue lines
				}
			}
			it.retry *= time.Millisecond
		case:
			// Field is ignored
		}
	}

	return

	// NOTE: not a strings.split variant because it is specified that a lone \r is also a valid line break.
	// + we need to know how much we consumed, which `strings.split_multi_iterate(&it, {"\r\n", "\r", "\n"})` wouldn't give.
	_SSE_line_iterator :: proc(it: ^string) -> (res: string, consumed: int, ok: bool) {
		if len(it) == 0 {
			return
		}

		i, w := strings.index_multi(it^, {"\r", "\n"})
		if i >= 0 {
			hit := it[i:i+1]

			consumed = i+1

			res = it[:i]
			if hit == "\n" && strings.has_suffix(res, "\r") {
				consumed += 1
				res = res[:len(res)-1]
			}

			it^ = it[i+w:]
			if hit == "\r" && strings.has_suffix(it^, "\n") {
				consumed += 1
				it^ = it[1:]
			}
			ok = true
		}
		return
	}
}

