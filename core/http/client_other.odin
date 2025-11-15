#+vet explicit-allocators
#+build !js
#+private
package http

import intr "base:intrinsics"

import      "core:fmt"
import      "core:bufio"
import      "core:http/dns"
import      "core:log"
import      "core:mem"
import      "core:nbio"
import      "core:net"
import      "core:slice"
import      "core:strconv"
import      "core:strings"
import cio  "core:io"

_client_init :: proc(c: ^Client, allocator := context.allocator) -> bool {
	c.allocator = allocator
	c.conns.allocator = allocator

	// PERF: this is "blocking"
	ns_err, hosts_err, ok := dns.init_sync(&c.dnsc, allocator)
	if ns_err != nil {
		log.warnf("DNS client init: name servers error: %v", ns_err)
	}
	if hosts_err != nil {
		log.warnf("DNS client init: hosts error: %v", hosts_err)
	}
	if ns_err != nil || hosts_err != nil || !ok {
		return false
	}

	if client_ssl.client_create != nil {
		assert(client_ssl.client_destroy != nil)
		assert(client_ssl.connection_create != nil)
		assert(client_ssl.connection_destroy != nil)
		assert(client_ssl.connect != nil)
		assert(client_ssl.send != nil)
		assert(client_ssl.recv != nil)

		c.ssl = client_ssl.client_create()
	}

	return true
}

_client_destroy :: proc(_: ^nbio.Operation, c: ^Client) {
	for ep, &conns in c.conns {
		#reverse for conn, i in conns {
			switch conn.state {
			case .Pending, .Failed, .Closed:
				log.debug("freeing connection")
				strings.builder_destroy(&conn.buf)
				scanner_destroy(&conn.scanner)
				free(conn, c.allocator)
				ordered_remove(&conns, i)
			case .Connected:
				log.debug("closing connection")
				conn.state = .Closing
				nbio.close_poly2(conn.socket, c, conn, proc(op: ^nbio.Operation, c: ^Client, conn: ^Client_Connection) {
					if conn.ssl != nil {
						client_ssl.connection_destroy(c.ssl, conn.ssl)
					}
					conn.state = .Closed
				})
			case .Connecting, .Requesting, .Sent_Headers, .Sent_Request, .Closing:
			}
		}

		if len(conns) <= 0 {
			delete(conns)
			delete_key(&c.conns, ep)
		}
	}

	if len(c.conns) > 0 {
		nbio.next_tick_poly(c, _client_destroy)
		return
	}

	delete(c.conns)

	dns.destroy(&c.dnsc)

	if c.ssl != nil {
		client_ssl.client_destroy(c.ssl)
	}

	log.debug("client destroyed")
}

_response_destroy :: proc(c: ^Client, res: Client_Response) {
	res := res

	iter := headers_iterator(&res.headers)
	for k, v in headers_next(&iter) {
		delete(k, c.allocator)
		delete(v, c.allocator)
	}
	headers_destroy(&res.headers)

	for cookie in res.cookies {
		delete(cookie.name, c.allocator)
	}
	delete(res.cookies)

	delete(res.body)
}

_Client :: struct {
	allocator: mem.Allocator,
	// TODO: ideally the dns client is able to be set by the user.
	// So you can run multiple clients on the same DNS client?
	dnsc:      dns.Client,
	ssl:       SSL_Client,
	conns:     map[Endpoint][dynamic]^Client_Connection,
}

Scheme :: enum {
	HTTP,
	HTTPS,
}

Endpoint :: struct {
	using net: net.Endpoint,
	scheme:    Scheme,
}

In_Flight :: struct {
	using r: Client_Request,
	c:       ^_Client,
	conn:    ^Client_Connection,
	res:     Client_Response,
	ep:      Endpoint,

	// NOTE: temporary to avoid stack overflow.
	recursion: int,
}

in_flight_destroy :: proc(r: ^In_Flight) {
	free(r, r.c.allocator)
}

@(private="file")
Client_Connection :: struct {
	ep:         Endpoint,
	state:      Client_Connection_State,
	ssl:        SSL_Connection,
	socket:     nbio.TCP_Socket,
	buf:        strings.Builder,
	scanner:    Scanner,
	using body: Has_Body,

	will_close: bool,
}

client_connection_destroy :: proc(c: ^Client, conn: ^Client_Connection) {
	conn.state = .Closing

	if conn.ssl != nil {
		client_ssl.connection_destroy(c.ssl, conn.ssl)
	}

	nbio.close_poly2(conn.socket, c, conn, proc(op: ^nbio.Operation, c: ^Client, conn: ^Client_Connection) {
		if op.close.err != nil {
			log.warnf("failed closing connection: %v", op.close.err)
		}

		conn.state = .Closed

		conns, has_conns := &c.conns[conn.ep]
		assert(has_conns)
		idx, found := slice.linear_search(conns[:], conn)
		assert(found)
		unordered_remove(conns, idx)

		if len(conns) == 0 {
			delete(conns^)
			delete_key(&c.conns, conn.ep)
		}

		strings.builder_destroy(&conn.buf)
		scanner_destroy(&conn.scanner)
		headers_destroy(&conn.headers)
		free(conn, c.allocator)
	})
}

@(private="file")
Client_Connection_State :: enum {
	Pending,
	Connecting,
	Connected,
	Requesting,
	Sent_Headers,
	Sent_Request,
	Closing,
	Closed,
	Failed,
}

_client_request :: proc(c: ^Client, req: Client_Request) {
	r := new(In_Flight, c.allocator)
	r.c = c
	r.r = req
	_client_request_on(r)
}

_client_request_on :: proc(r: ^In_Flight) {
	assert(r.r.cb != nil, "no response callback")

	host := url_parse(r.r.url).host
	host_or_endpoint, err := net.parse_hostname_or_endpoint(host)
	if err != nil {
		log.warnf("Invalid request URL %q: %v", r.r.url, err)
		r.r.cb(r.r, {}, .Bad_URL)
		free(r, r.c.allocator)
		return
	}

	switch t in host_or_endpoint {
    case net.Endpoint:
		r.ep.net = t
		on_dns_resolve(r, { t.address, max(u32) }, nil)
    case net.Host:
		r.ep.port = t.port
		dns.resolve(&r.c.dnsc, t.hostname, r, on_dns_resolve)
    case:
		unreachable()
    }

	on_dns_resolve :: proc(r: rawptr, record: dns.Record, err: net.Network_Error) {
		r := (^In_Flight)(r)
		if err != nil {
			log.warnf("DNS resolve error for %q: %v", r.r.url, err)
			r.cb(r, {}, .DNS)
			free(r, r.c.allocator)
			return
		}

		// Finalize endpoint
		{
			r.ep.address = record.address

			switch scheme_str := url_parse(r.url).scheme; scheme_str {
			case "http", "ws":   r.ep.scheme = .HTTP
			case "https", "wss": r.ep.scheme = .HTTPS
			case:
				switch r.ep.port {
				case 80:  r.ep.scheme = .HTTP
				case 443: r.ep.scheme = .HTTPS
				case:
					log.infof("could not reliably determine HTTP or HTTPS based on given scheme %q and port %v, defaulting to HTTP", scheme_str, r.ep.port)
				}
			}

			if r.ep.port == 0 {
				switch r.ep.scheme {
				case .HTTP:  r.ep.port = 80
				case .HTTPS: r.ep.port = 443
				case:        unreachable()
				}
			}
		}

		log.debugf("DNS of %v resolved to %v", r.url, r.ep)

		get_connection: {
			// TODO: err
			_, conns, _, err := map_entry(&r.c.conns, r.ep)
			conns.allocator = r.c.allocator

			for conn in conns {
				// NOTE: might want other states too.
				if conn.state == .Connected {
					r.conn = conn
					break get_connection
				}
			}

			r.conn = new(Client_Connection, r.c.allocator)
			r.conn.ep = r.ep
			append(conns, r.conn)
		}

		connect(r)
	}

	handle_net_err :: proc(r: ^In_Flight, err: net.Network_Error, ctx := "") {
		fmt.panicf("NOOOOOOOOOO: %v %v", ctx, err)
	}

	connect :: proc(r: ^In_Flight) {
		// TODO: connected state, but actually disconnected when we try write
		#partial switch r.conn.state {
		case:
			log.panicf("connect: invalid state: %v", r.conn.state)
		case .Connected:
			on_connected(r, nil)
			return
		case .Pending:
		}

		r.conn.state = .Connecting

		log.debug("connecting to endpoint")

		nbio.dial_poly(r.ep, r, on_tcp_connect)

		on_tcp_connect :: proc(op: ^nbio.Operation, r: ^In_Flight) {
			if op.dial.err != nil {
				handle_net_err(r, op.dial.err, "TCP connect failed")
				return
			}

			assert(r.conn.state == .Connecting)

			log.debug("TCP connection established")
			r.conn.socket = op.dial.socket

			switch r.ep.scheme {
			case .HTTP:
				r.conn.state = .Connected
				on_connected(r, nil)
			case .HTTPS:
				if r.c.ssl == nil {
					panic("HTTP client can't make HTTPS request without an SSL implementation, set it using `set_client_ssl`")
				}

				host := url_parse(r.url).host
				// TODO: just pass string and clone in client_ssl
				chost := strings.clone_to_cstring(host, r.c.allocator)
				defer delete(chost, r.c.allocator)
				r.conn.ssl = client_ssl.connection_create(r.c.ssl, op.dial.socket, chost)

				ssl_connect(nil, r)

				ssl_connect :: proc(op: ^nbio.Operation, r: ^In_Flight) {
					log.debug("SSL connect")
					switch client_ssl.connect(r.conn.ssl) {
					case .None:
						log.debug("SSL connection established")
						r.conn.state = .Connected
						on_connected(r, nil)
					case .Want_Read:
						log.debug("SSL connect want read")
						nbio.poll_poly(r.conn.socket, {.Read}, r, ssl_connect)
					case .Want_Write:
						log.debug("SSL connect want write")
						nbio.poll_poly(r.conn.socket, {.Write}, r, ssl_connect)
					case .Shutdown:
						log.error("SSL connect error: Shutdown")
						on_connected(r, net.Dial_Error.Refused)
					case: fallthrough
					case .Fatal:
						log.error("SSL connect error: Fatal")
						on_connected(r, net.Dial_Error.Refused)
					}
				}
			}
		}
	}

	on_connected :: proc(r: ^In_Flight, err: net.Network_Error) {
		if err != nil {
			handle_net_err(r, err, "SSL connect failed")
			return
		}

		assert(r.conn.state == .Connected)

		// Prepare requestline/headers
		{
			buf := &r.conn.buf
			strings.builder_reset(buf)
			s := strings.to_stream(buf)

			ws :: strings.write_string

			err := requestline_write(s, { method = r.method, target = r.url, version = {1, 1} })
			assert(err == nil) // Only really can be an allocator error.

			if !headers_has(r.headers, "content-length") {
				buf_len := len(r.body)
				if buf_len == 0 {
					ws(buf, "content-length: 0\r\n")
				} else {
					ws(buf, "content-length: ")

					// Make sure at least 20 bytes are there to write into, should be enough for the content length.
					strings.builder_grow(buf, buf_len + 20)

					// Write the length into unwritten portion.
					unwritten := dynamic_unwritten(buf.buf)
					l := len(strconv.write_int(unwritten, i64(buf_len), 10))
					assert(l <= 20)
					dynamic_add_len(&buf.buf, l)

					ws(buf, "\r\n")
				}
			}

			if !headers_has(r.headers, "accept") {
				ws(buf, "accept: */*\r\n")
			}

			if !headers_has(r.headers, "user-agent") {
				ws(buf, "user-agent: odin-http\r\n")
			}

			if !headers_has(r.headers, "host") {
				ws(buf, "host: ")
				ws(buf, url_parse(r.url).host)
				ws(buf, "\r\n")
			}

			// TODO: escaping headers and cookies as needed.

			headers_write(buf, &r.headers)

			if len(r.cookies) > 0 {
				ws(buf, "cookie: ")

				for cookie, i in r.cookies {
					ws(buf, cookie.name)
					ws(buf, "=")
					ws(buf, cookie.value)

					if i != len(r.cookies) - 1 {
						ws(buf, "; ")
					}
				}

				ws(buf, "\r\n")
			}

			ws(buf, "\r\n")
		}

		r.conn.state = .Requesting
		switch r.ep.scheme {
		case .HTTP:  send_http_request(r)
		case .HTTPS: send_https_request(r)
		}
	}

	send_http_request :: proc(r: ^In_Flight) {
		assert(r.conn.state == .Requesting)

		log.debugf("Sending HTTP request:\n%v%v", string(r.conn.buf.buf[:]), string(r.body))

		nbio.send_poly(r.conn.socket, r.conn.buf.buf[:], r, on_sent_req)
		if len(r.body) > 0 {
			nbio.send_poly(r.conn.socket, r.body, r, on_sent_body)
		}

		on_sent_req :: proc(op: ^nbio.Operation, r: ^In_Flight) {
			assert(r.conn.state == .Requesting)
			r.conn.state = .Sent_Headers if op.send.err == nil else .Failed

			log.debugf("Sent HTTP request:\n%v%v", string(r.conn.buf.buf[:]), string(r.body))

			if len(r.body) == 0 {
				err: net.TCP_Send_Error
				if op.send.err != nil { err = op.send.err.(net.TCP_Send_Error) }
				on_sent_request(r, err)
			}
		}

		on_sent_body :: proc(op: ^nbio.Operation, r: ^In_Flight) {
			#partial switch r.conn.state {
			case .Failed:       on_sent_request(r, .Unknown)
			case .Sent_Headers: on_sent_request(r, op.send.err.(net.TCP_Send_Error))
			case:               unreachable()
			}
		}
	}

	send_https_request :: proc(r: ^In_Flight) {
		log.debugf("Sending HTTPS request:\n%v%v", string(r.conn.buf.buf[:]), string(r.body))

		ssl_write_req(nil, r)

		ssl_write_req :: proc(op: ^nbio.Operation, r: ^In_Flight) {
			// TODO: handle error.

			switch n, res := client_ssl.send(r.conn.ssl, r.conn.buf.buf[:]); res {
			case .None:
				log.debugf("Successfully written request line and headers of %m to connection", n)

				if n < len(r.conn.buf.buf) {
					remove_range(&r.conn.buf.buf, 0, n) // PERF: O(N); not hit often
					ssl_write_req(nil, r)
					return
				}

				r.conn.state = .Sent_Headers
				ssl_write_body(nil, r)
			case .Want_Read:
				log.debug("SSL write want read")
				nbio.poll_poly(r.conn.socket, {.Read}, r, ssl_write_req)
			case .Want_Write:
				log.debug("SSL write want write")
				nbio.poll_poly(r.conn.socket, {.Write}, r, ssl_write_req)
			case .Shutdown:
				log.error("write failed, connection is closed")
				on_sent_request(r, .Connection_Closed)
			case: fallthrough
			case .Fatal:
				log.errorf("write failed due to unknown Fatal reason")
				on_sent_request(r, .Connection_Closed)
			}
		}

		ssl_write_body :: proc(op: ^nbio.Operation, r: ^In_Flight) {
			assert(r.conn.state == .Sent_Headers)

			log.debugf("Writing body of %m to connection", len(r.body))

			if len(r.body) == 0 {
				r.conn.state = .Sent_Request
				on_sent_request(r, nil)
				return
			}

			switch n, res := client_ssl.send(r.conn.ssl, r.body); res {
			case .None:
				log.debugf("Successfully written body of %m to connection", n)

				if n < len(r.body) {
					r.body = r.body[n:]
					ssl_write_body(nil, r)
					return
				}

				r.conn.state = .Sent_Request
				on_sent_request(r, nil)
			case .Want_Read:
				log.debug("SSL write want read")
				nbio.poll_poly(r.conn.socket, {.Read}, r, ssl_write_body)
			case .Want_Write:
				log.debug("SSL write want write")
				nbio.poll_poly(r.conn.socket, {.Write}, r, ssl_write_body)
			case .Shutdown:
				log.error("write failed, connection is closed")
				on_sent_request(r, net.TCP_Send_Error.Connection_Closed)
			case: fallthrough
			case .Fatal:
				log.error("write failed due to unknown Fatal reason")
				on_sent_request(r, .Unknown)
			}
		}
	}

	on_sent_request :: proc(r: ^In_Flight, err: net.TCP_Send_Error) {
		if err != nil {
			handle_net_err(r, err, "send request failed")
			return
		}

		log.debug("request has been sent, receiving response")

		r.conn._scanner = &r.conn.scanner
		scanner_reset(&r.conn.scanner)
		scanner_init(&r.conn.scanner, r, scanner_recv, r.c.allocator)

		r.conn.will_close = false
		// r.conn._body_ok = nil // TODO

		scanner_recv :: proc(r: rawptr, buf: []byte, s: ^Scanner, callback: On_Scanner_Read) {
			r := (^In_Flight)(r)

			// TODO: use the timeout.

			switch r.ep.scheme {
			case .HTTP:
				log.debug("executing non-SSL read")
				nbio.recv_poly2(
					r.conn.socket, buf, s, callback,
					proc(op: ^nbio.Operation, s: ^Scanner, callback: On_Scanner_Read) {
						err: net.TCP_Recv_Error
						if op.recv.err != nil { err = op.recv.err.(net.TCP_Recv_Error) }
						callback(s, op.recv.received, err)
					},
				)
			case .HTTPS:
				ssl_recv(nil, r, buf, callback)

				ssl_recv :: proc(op: ^nbio.Operation, r: ^In_Flight, buf: []byte, callback: On_Scanner_Read) {
					// log.debugf("executing SSL recv for %m", len(buf))
					total: int

					MAX_RECURSION :: 25

					// NOTE: hacky? fix for stack overflows because we keep getting data without going back up the stack.
					if r.recursion > MAX_RECURSION {
						nbio.next_tick_poly3(r, buf, callback, proc(_: ^nbio.Operation, r: ^In_Flight, buf: []byte, callback: On_Scanner_Read) {
							r.recursion = 0
							ssl_recv(nil, r, buf, callback)
						})
						return
					}

					receiving: for {
						switch n, res := client_ssl.recv(r.conn.ssl, buf[total:]); res {
						case .None:
							// log.debugf("Successfully received %m/%m from the connection", n, len(buf))
							total += n
							if total < len(buf) {
								continue receiving
							}
							r.recursion += 1
							callback(&r.conn.scanner, total, nil)
						case .Want_Read:
							// log.debug("SSL read want read")
							if total > 0 {
								callback(&r.conn.scanner, total, nil)
							} else {
								r.recursion = 0
								nbio.poll_poly3(r.conn.socket, {.Read}, r, buf, callback, ssl_recv)
							}
						case .Want_Write:
							// log.debug("SSL read want write")
							if total > 0 {
								callback(&r.conn.scanner, total, nil)
							} else {
								r.recursion = 0
								nbio.poll_poly3(r.conn.socket, {.Write}, r, buf, callback, ssl_recv)
							}
						case .Shutdown:
							log.error("read failed, connection is closed")
							callback(&r.conn.scanner, total, .Connection_Closed)
						case: fallthrough
						case .Fatal:
							log.error("read failed due to unknown Fatal reason")
							callback(&r.conn.scanner, total, .Unknown)
						}

						break receiving
					}
				}
			}
		}

		log.debug("scanning response")
		scanner_scan(&r.conn.scanner, r, on_rline1)

		handle_scanner_err :: proc(r: ^In_Flight, err: bufio.Scanner_Error, ctx := "") {

			#partial switch e in err {
			case cio.Error:
				#partial switch e {
				case .EOF:
					log.warnf("server closed connection, reconnecting")

					// TODO: clean up all things that will be allocated anew.
					// TODO: don't do this infinitely, after x (maybe just 1) retry give this error back to the user.

					nbio.close(r.conn.socket)
					// TODO: maybe set this to .Closed and in `connect` do cleanup.
					r.conn.state = .Pending
					connect(r)
					return
				}
			}

			// TODO: call callback.
			log.panicf("%v: receiving failed: %v", err, ctx)
		}

		//
		handle_bad_response :: proc(r: ^In_Flight, ctx := "") {
			log.panicf("bad response: %s", ctx)

			// free everything, close connection,
		}

		on_rline1 :: proc(r: ^In_Flight, token: string, err: bufio.Scanner_Error) {
			if err != nil {
				handle_scanner_err(r, err, "reading request-line")
				return
			}

			log.debug("got response line")

			// NOTE: this is RFC advice for servers, but seems sensible here too.
			//
			// In the interest of robustness, a server that is expecting to receive
			// and parse a request-line SHOULD ignore at least one empty line (CRLF)
			// received prior to the request-line.
			if len(token) == 0 {
				log.debug("first response line is empty, skipping in interest of robustness")
				scanner_scan(&r.conn.scanner, r, on_rline2)
				return
			}

			on_rline2(r, token, nil)
		}

		on_rline2 :: proc(r: ^In_Flight, token: string, err: bufio.Scanner_Error) {
			if err != nil {
				handle_scanner_err(r, err, "reading request-line attempt 2")
				return
			}

			si := strings.index_byte(token, ' ')
			if si == -1 && si != len(token)-1 {
				handle_bad_response(r, "response line missing a space")
				return
			}

			version, ok := version_parse(token[:si])
			if !ok || version.major != 1 {
				handle_bad_response(r, "invalid HTTP version in response")
				return
			}

			// HTTP 1.0, no persistent connections
			if version.minor == 0 {
				r.conn.will_close = true
			}

			r.res.status, ok = status_from_string(token[si+1:])
			if !ok {
				handle_bad_response(r, "invalid status code in response")
				return
			}

			log.debugf("got valid response line %q, parsing headers...", token)

			// TODO: max header size.

			headers_init(&r.conn.headers, r.c.allocator)

			scanner_scan(&r.conn.scanner, r, on_header_line)
		}

		on_header_line :: proc(r: ^In_Flight, token: string, err: bufio.Scanner_Error) {
			if err != nil {
				handle_scanner_err(r, err, "failed reading header line")
				return
			}

			// NOTE: any errors should destroy all allocations.

			// First empty line means end of headers.
			if len(token) == 0 {
				on_headers_end(r)
				return
			}

			key, ok := header_parse(&r.conn.headers, token, r.c.allocator)
			if !ok {
				handle_bad_response(r, "invalid header line")
				return
			}

			if headers_cmp(key, "set-cookie") == .Equal {
				dkey, dval := headers_delete(&r.conn.headers, "set-cookie")

				// TODO: this allocation can be avoided by splitting header_parse into 2 procs (header_split, giving key and val slice, and another that allocates, checks etc.)
				delete(dkey, r.c.allocator)

				cookie, cok := cookie_parse(dval)
				if !cok {
					handle_bad_response(r, "invalid cookie")
					return
				}

				// TODO: set allocator.
				append(&r.res.cookies, cookie)
			}

			log.debugf("parsed valid header %q", token)
			scanner_scan(&r.conn.scanner, r, on_header_line)
		}

		on_headers_end :: proc(r: ^In_Flight) {
			if !headers_sanitize(&r.conn.headers) {
				handle_bad_response(r, "invalid combination of headers")
				return
			}

			r.res.headers = r.conn.headers
			r.res.headers.readonly = true

			// TODO: set r.res.body allocator.

			// TODO: configurable max length, make sure to handle the error in on_body too!
			body(&r.conn.body, -1, r, on_body)
		}

		on_body :: proc(r: rawptr, body: []byte, err: Body_Error) {
			r := (^In_Flight)(r)

			switch err {
			case .None:
				// TODO: determine based on response status and headers if we can keep the connection
				// alive, if so, put the connection on a free list.

				r.conn.state = .Connected
				r.conn.body  = {}

				// TODO: what other statussus/special handling (like only on specific method, changing method, check spec).
				// TODO: have a max amount of redirects to follow.
				if !r.ignore_redirects && (r.res.status == .Found || r.res.status == .Moved_Permanently || r.res.status == .See_Other || r.res.status == .Temporary_Redirect || r.res.status == .Permanent_Redirect) {
					// Reset everything as if the request was made to the location.

					location, has_location := headers_get(r.res.headers, "Location")
					assert(has_location)

					r.r.url = strings.clone(location, r.c.allocator) // TODO: leak

					r.conn = nil
					r.ep = {}

					response_destroy(r.c, r.res)
					r.res = {}

					_client_request_on(r)
					break
				}

				append(&r.res.body, ..body)
				r.cb(r, &r.res, nil)
				free(r, r.c.allocator)

			case .Partial:
				//  NOTE: appending to the body may be stupid, could have a callback take the []byte, and if there isn't a callback do the appending?
				append(&r.res.body, ..body)
				r.cb(r, &r.res, .Partial)

			case .Timeout:
				r.cb(r, &r.res, .Timeout)
				handle_bad_response(r)

			case .EOF:
				r.cb(r, &r.res, .Aborted)
				handle_bad_response(r)

			// TODO: some bad response error indicating invalid length, headers.
			case .Invalid_Content_Length, .Invalid_Trailing_Header, .Unknown:
				r.cb(r, &r.res, .Unknown)
				handle_bad_response(r)

			case .Corrupted_State:
				panic("corrupted state retrieving body of response, probably a bug in this package")

			case .Already_Consumed, .Exceeds_Max_Size:
				// Body is tried to be consumed multiple times, we set no max size currently.
				unreachable()
			}
		}
	}
}
