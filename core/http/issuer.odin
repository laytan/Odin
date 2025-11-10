#+vet explicit-allocators
package http

import "base:runtime"

import "core:slice"
import "core:log"
import "core:bufio"
import "core:strings"
import "core:strconv"
import "core:net"
import "core:nbio"
import "core:fmt"
import "core:io"

Issuer_Connection :: struct {
	ep:         net.Endpoint,

	allocator:  runtime.Allocator,

	ssl:        SSL_Connection,
	socket:     nbio.TCP_Socket,

	scanner:    Scanner,
	status:     Status,
	using body: Has_Body,

	curr_req: Issuer_Request,

	type: Issuer_State,
	recursion: int,

	body_off: Maybe(i64),
}

Issuer_State :: enum {
	// We have a fresh TCP/TLS connection, we do not expect a shutdown.
	Fresh,
	// We do not have a fresh TCP/TLS connection, we could get a shutdown, when that happens we can resend the current buffer.
	Reconnect_With_Buffer,
	// We do not have a fresh TCP/TLS connection, we could get a shutdown, when that happens, rebuild the request.
	Keep_Alive,
}

Issuer_Request :: struct {
	body:      Outgoing_Body,
	headers:   Headers,
	allocator: runtime.Allocator,
	url:       string,
	user_data: rawptr,
	cb:        On_Issuer_Response,
	method:    Method,
}

Issuer_Response :: struct {
	body:    []byte,
	headers: ^Headers,
	status:  Status,
}

On_Issuer_Response :: #type proc(req: Issuer_Request, res: Issuer_Response, err: Request_Error)

issue :: proc(conn: ^Issuer_Connection) {
	assert(conn != nil)
	assert(conn.ep != {})
	assert(conn.allocator.procedure != nil)
	assert(conn.curr_req.allocator.procedure != nil)

	// TODO: check all inputs.
	
	log.debug("issue")

	if file, is_file := conn.curr_req.body.content.(nbio.Handle); is_file && conn.curr_req.body.size == nil {
		nbio.stat_poly(file, conn, proc(op: ^nbio.Operation, conn: ^Issuer_Connection) {
			assert(op.stat.err == nil) // TODO: errors
			assert(op.stat.type == .Regular)
			conn.curr_req.body.size = op.stat.size
		})
	}

	connect(conn)

	connect :: proc(conn: ^Issuer_Connection) {
		if conn.socket != {} {
			log.debug("already has connection, set type to keep alive, and send the request")
			conn.type = .Keep_Alive
			send_request(conn)
			return
		}

		log.debug("no connection yet, connecting")
		assert(conn.type != .Keep_Alive)
		nbio.dial_poly(conn.ep, conn, on_connect)
	}

	on_connect :: proc(op: ^nbio.Operation, conn: ^Issuer_Connection) {
		if op.dial.err != nil {
			rerr := Request_Error.Unknown
			#partial switch err in op.dial.err {
			case net.Create_Socket_Error:
				#partial switch err {
				case .Network_Unreachable:
					rerr = .Network
				case .Insufficient_Resources:
					rerr = .Allocation_Failure
				}
			case net.Dial_Error:
				#partial switch err {
				case .Network_Unreachable:
					rerr = .Network
				case .Insufficient_Resources:
					rerr = .Allocation_Failure
				case .Refused, .Reset, .Host_Unreachable:
					rerr = .Connection_Failure
				case .Timeout:
					rerr = .TCP_Connect_Timeout
				}
			}

			callback_err(conn, rerr)
			return
		}
		log.debug("tcp connected")

		assert(conn.socket == {})
		conn.socket = op.dial.socket

		switch determine_scheme(conn.curr_req.url, conn.ep.port) {
		case .Https: setup_handshake(conn)
		case .Http:  send_request(conn)
		case:        unreachable()
		}
	}

	setup_handshake :: proc(conn: ^Issuer_Connection) {
		assert(ssl_client != {}, "no SSL")

		assert(conn.ssl == {})

		hostname, _, _ := net.split_port(url_parse(conn.curr_req.url).host) // ignore (bad) port

		conn.ssl = ssl_client.connection_create(ssl_client, conn.socket, hostname, conn.allocator)

		handshake(nil, conn)
	}

	handshake :: proc(op: ^nbio.Operation, conn: ^Issuer_Connection) {
		if op != nil && op.poll.result != .Ready {
			rerr := Request_Error.Unknown
			#partial switch op.poll.result {
			case .Timeout:
				rerr = .TLS_Handshake_Timeout
			}
			callback_err(conn, rerr)
			return
		}

		// TODO: use capabilities to determine send strategy.
		switch err, _ := ssl_client.connect(conn.ssl); err {
		case: fallthrough
		case .Shutdown:
			callback_err(conn, .TLS_Shutdown)
		case .Fatal:
			callback_err(conn, .TLS_Error)
		case .Want_Read, .Want_Write:
			nbio.poll_poly(conn.socket, .Receive if err == .Want_Read else .Send, conn, handshake)
		case .None:
			send_request(conn)
		}
	}

	send_request :: proc(conn: ^Issuer_Connection) {
		body_size := body_size(conn)

		// This is a reconnect which has a buffer already.
		if conn.type == .Reconnect_With_Buffer {
			log.debug("This was a reconnection where we already had a buffer, sending pre-existing buffer")
			assert(len(conn.scanner.buf) > 0)
			log.info(string(conn.scanner.buf[:]))

			if body_size > 0 {
				switch content in conn.curr_req.body.content {
				case []u8:
					send(conn, {conn.scanner.buf[:], content}, sent_memory_body)
					return
				case string:
					send(conn, {conn.scanner.buf[:], transmute([]byte)content}, sent_memory_body)
					return
				case io.Reader, nbio.Handle: // no-op
				case: unreachable()
				}
			}

			send(conn, {conn.scanner.buf[:]}, sent_request)
			return
		}

		log.debug("Not reconnection with buffer, building request")

		scanner_reset(&conn.scanner)
		conn.scanner.buf.allocator = conn.allocator

		buffer_size :: INIT_BUF_SIZE // TODO: configurable

		// Keep alive with a stream is a bit more complicated.
		// We can not just read the request body again, it will advance.
		// What we do, 3 scenarios:
		//	1. If the stream supports seeking, save the current offset,
		//     if we need to reconnect, first seek back
		//
		//  2. If the body size is known and smaller than the buffer size,
		//     read the body into the buffer, send request, and retry with that buffer if needed
		//
		//  3. Else, send a 100 Continue request to the server to see if it is still connected,
		//     reconnect if not, then stream the body on the fresh connection

		clear(&conn.scanner.buf)
		if reserve(&conn.scanner.buf, INIT_BUF_SIZE) != nil {
			callback_err(conn, .Allocation_Failure)
			return
		}

		if !write_request(conn) {
			callback_err(conn, .Allocation_Failure)
			return
		}

		switch content in conn.curr_req.body.content {
		case []byte, string:
			if conn.type == .Keep_Alive {
				log.debug("Body is in memory, if we reconnect we can just write that again")
				conn.type = .Reconnect_With_Buffer
			}
		case nbio.Handle:
			// no-op, we don't want to buffer the file, and we know it supports seeking.
			// TODO: we do want to buffer small files, sendfile is actually slower for them iirc.

		case io.Reader:
			// If the body fits right at the end, do that.
			space := cap(conn.scanner.buf)-len(conn.scanner.buf)
			if body_size >= 0 && body_size <= i64(space) {
				log.debug("Body is a stream, but it's size fits into the buffer, reading it fully now")

				n, read_err := io.read_at_least(content, dynamic_unwritten(conn.scanner.buf), int(body_size))
				if read_err != nil && read_err != .EOF && read_err != .Unexpected_EOF {
					callback_err(conn, .Outgoing_Body_Error)
					return
				}
				dynamic_add_len(&conn.scanner.buf, n)

				if conn.type == .Keep_Alive {
					log.debug("Since we could read the stream fully, if we need to reconnect we can send the pre-existing buffer")
					conn.type = .Reconnect_With_Buffer
				}
			} else if conn.type == .Keep_Alive {
				off, seek_err := io.seek(content, 0, .Current)
				if seek_err == nil {
					log.debug("Body is a stream that supports seeking, if we reconnect we can seek back to the beginning")
					conn.body_off = off
				} else {
					log.debug("Body is a stream that does not supports seeking, we need to make sure we are still connected")
					// TODO: if no seeking, send 100-continue request to check if the server is still connected.
					// We can reconnect if not, then, we send the streaming body on a fresh connection.
					// unimplemented("keep alive non-seekable stream; TODO: send 100-continue")

					assert(!headers_has(conn.curr_req.headers, "Expect"), "TODO: support this")
					// Add header expect continue.
					inject_at(&conn.scanner.buf, len(conn.scanner.buf)-len("\r\n")+1, "Expect: 100-continue")

					log.debug(string(conn.scanner.buf[:]))
					send(conn, {conn.scanner.buf[:]}, sent_100_continue)
					return

					sent_100_continue :: proc(is_shutdown: bool, conn: ^Issuer_Connection) {
						if is_shutdown {
							log.debug("Sent 100 continue, got shutdown")
							reconnect(conn)
							return
						}

						log.debug("Sent 100 continue, got no error, receiving response")

						resize(&conn.scanner.buf, INIT_BUF_SIZE)
						conn._scanner = &conn.scanner
						scanner_reset(&conn.scanner)
						scanner_init(&conn.scanner, conn, scanner_recv, context.allocator)
						scanner_scan(&conn.scanner, conn, received_continue_response)
					}

					received_continue_response :: proc(conn: ^Issuer_Connection, token: string, err: bufio.Scanner_Error) {
						if err == .EOF {
							log.debug("Received 100 continue response, was shutdown, reconnecting")
							reconnect(conn)
							return
						}

						log.debug("Received 100 continue response, verified we are still connected")

						// We have verified that we are still connected.

						// TODO: duplicated code

						si := strings.index_byte(token, ' ')
						if si == -1 && si != len(token)-1 {
							fmt.panicf("response line %q missing space", token)
						}

						version, ok := version_parse(token[:si])
						if !ok || version.major != 1 {
							fmt.panicf("invalid HTTP version in response line %q", token)
						}

						status, status_ok := status_from_string(token[si+1:])
						if !status_ok {
							fmt.panicf("invalid status code in response %q", token)
						}

						assert(status == .Continue, "TODO: what if server doesn't respond with continue?")

						conn.type = .Fresh
						send_reader_body(false, conn)
					}
				}
			}
		}

		log.debug("Sending request that we just built, and memory body if applicable")

		log.info(string(conn.scanner.buf[:]))

		// TODO: check if request should have a body.

		if body_size > 0 {
			switch content in conn.curr_req.body.content {
			case []u8:
				send(conn, {conn.scanner.buf[:], content}, sent_memory_body)
				return
			case string:
				send(conn, {conn.scanner.buf[:], transmute([]byte)content}, sent_memory_body)
				return
			case io.Reader, nbio.Handle: // no-op
			case: unreachable()
			}
		}

		send(conn, {conn.scanner.buf[:]}, sent_request)
	}

	sent_request :: proc(is_shutdown: bool, conn: ^Issuer_Connection) {
		if is_shutdown {
			switch conn.type {
			case .Keep_Alive, .Reconnect_With_Buffer:
				reconnect(conn)
			case .Fresh:
				callback_err(conn, .Aborted)
			}
			return
		}

		if conn.type == .Reconnect_With_Buffer {
			log.debug("Sent request that was a reconnect with buffer")
			return
		}

		body_size := body_size(conn)
		if body_size == 0 {
			receive_response(conn)
			return
		}

		switch content in conn.curr_req.body.content {
		case []byte, string: // no-op, already sent.
		case io.Reader:
			log.debug("Sent request, now sending stream body")
			clear(&conn.scanner.buf)
			send_reader_body(false, conn)
		case nbio.Handle:
			log.debug("Sent request, now sending file")
			send_file_body(conn)
		}
	}

	sent_memory_body :: proc(is_shutdown: bool, conn: ^Issuer_Connection) {
		sent_request(is_shutdown, conn)
		receive_response(conn)
	}

	send_reader_body :: proc(is_shutdown: bool, conn: ^Issuer_Connection) {
		if is_shutdown {
			switch conn.type {
			case .Keep_Alive:
				if _, has_off := conn.body_off.(i64); has_off {
					reconnect(conn)
					return
				}
				// If body does not do seeking, and we get here, server aborted.
			case .Reconnect_With_Buffer:
				reconnect(conn)
				return
			case .Fresh:
			}

			callback_err(conn, .Aborted)
			return
		}

		read :: proc(r: io.Reader, buf: []byte) -> (n: int, err: io.Error) {
			for n < len(buf) && err == nil {
				nn: int
				nn, err = io.read(r, buf[n:])
				if nn == 0 { break }
				n += nn
			}

			if n == len(buf) {
				err = nil
			} else if n > 0 && err == .EOF {
				err = .Unexpected_EOF
			}

			return
		}

		reader  := conn.curr_req.body.content.(io.Reader)

		chunked := body_size(conn) < 0
		buffer  := &conn.scanner.buf

		clear(buffer)
		unwritten := dynamic_unwritten(buffer^)

		n, read_err := read(reader, unwritten)
		dynamic_add_len(buffer, n)

		switch {
		case read_err == .EOF && chunked:
			append(buffer, "0\r\n\r\n")
			send(conn, {buffer[:]}, sent_reader_body)
		case read_err == .EOF:
			sent_reader_body(false, conn)
		case read_err != nil && read_err != .Unexpected_EOF:
			callback_err(conn, .Outgoing_Body_Error)
		case n == 0:
			nbio.next_tick_poly(conn, proc(_: ^nbio.Operation, conn: ^Issuer_Connection) { send_reader_body(false, conn) })
		case chunked:
			append(buffer, "\r\n")
			chunk := len(buffer)

			buf: [32]byte
			size := strconv.write_int(buf[:], i64(chunk - len("\r\n")), 16)
			append(buffer, size)
			append(buffer, "\r\n")

			send(conn, {buffer[chunk:], buffer[:chunk]}, send_reader_body)
		case:
			send(conn, {buffer[:]}, send_reader_body)
		}
	}

	// TODO: If no KTLS is enabled, we need to use the SSL send functions.
	send_file_body :: proc(conn: ^Issuer_Connection) {
		nbio.sendfile_poly(conn.socket, conn.curr_req.body.content.(nbio.Handle), conn, sent_file_body, nbytes=int(conn.curr_req.body.size.?)) // TODO: catch overflow
	}

	sent_file_body :: proc(op: ^nbio.Operation, conn: ^Issuer_Connection) {
		assert(op.sendfile.err == nil)
		// TODO: 
		// if op.sendfile.err != nil {
		// 	rerr := Request_Error.Unknown
		// 	#partial switch op.sendfile.err.(net.TCP_Send_Error) {
		// 	case .Connection_Closed:
		// 		cb(true, conn)
		// 		return
		// 	case .Network_Unreachable:
		// 		rerr = .Network
		// 	case .Insufficient_Resources:
		// 		rerr = .Allocation_Failure
		// 	case .Host_Unreachable, .Not_Connected:
		// 		rerr = .Connection_Failure
		// 	case .Timeout:
		// 		rerr = .Send_Request_Timeout
		// 	}
		//
		// 	// TODO: is send 0 also connection closed?
		//
		// 	callback_err(conn, rerr)
		// 	return
		// }

		receive_response(conn)
	}

	sent_reader_body :: proc(is_shutdown: bool, conn: ^Issuer_Connection) {
		if is_shutdown {
			switch conn.type {
			case .Keep_Alive:
				if _, has_off := conn.body_off.(i64); has_off {
					reconnect(conn)
					return
				}
				// If body does not do seeking, and we get here, server aborted.
			case .Reconnect_With_Buffer:
				reconnect(conn)
				return
			case .Fresh:
			}

			callback_err(conn, .Aborted)
			return
		}

		receive_response(conn)
	}

	receive_response :: proc(conn: ^Issuer_Connection) {
		err := resize(&conn.scanner.buf, INIT_BUF_SIZE)
		assert(err == nil) // should've already reserved this before.
		conn._scanner = &conn.scanner
		conn.body_allocator = conn.curr_req.allocator
		scanner_reset(&conn.scanner)
		scanner_init(&conn.scanner, conn, scanner_recv, conn.allocator)
		scanner_scan(&conn.scanner, conn, received_rline1)
	}

	received_rline1 :: proc(conn: ^Issuer_Connection, token: string, err: bufio.Scanner_Error) {
		if err != nil {
			rerr := Request_Error.Unknown
			switch err {
			case .EOF:
				switch conn.type {
				case .Keep_Alive, .Reconnect_With_Buffer:
					reconnect(conn)
					return
				case .Fresh:
					rerr = .Aborted
				}
			case .No_Progress:
				rerr = .Response_Timeout
			}

			callback_err(conn, rerr)
			return
		}

		if conn.type == .Reconnect_With_Buffer {
			log.debug("reconnect with buffer got first response bytes, so continueing as fresh")
			conn.type = .Fresh
		}

		// NOTE: this is RFC advice for servers, but seems sensible here too.
		//
		// In the interest of robustness, a server that is expecting to receive
		// and parse a request-line SHOULD ignore at least one empty line (CRLF)
		// received prior to the request-line.
		if len(token) == 0 {
			scanner_scan(&conn.scanner, conn, received_rline)
			return
		}

		received_rline(conn, token, nil)
	}

	received_rline :: proc(conn: ^Issuer_Connection, token: string, err: bufio.Scanner_Error) {
		if err != nil {
			rerr := Request_Error.Unknown
			switch err {
			case .EOF:
				rerr = .Aborted
			case .No_Progress:
				rerr = .Response_Timeout
			}
			callback_err(conn, rerr)
			return
		}

		// TODO: duplicated code with 100-continue
		si := strings.index_byte(token, ' ')
		if si == -1 && si != len(token)-1 {
			callback_err(conn, .Bad_Response)
			return
		}

		version, ok := version_parse(token[:si])
		if !ok {
			callback_err(conn, .Bad_Response)
			return
		}
		if version.major != 1 || version.minor > 1 {
			callback_err(conn, .Unsupported_HTTP_Version)
			return
		}

		conn.status, ok = status_from_string(token[si+1:])
		if !ok {
			callback_err(conn, .Bad_Response)
			return
		}

		// TODO: max header size.

		headers_init(&conn.headers, conn.curr_req.allocator)

		scanner_scan(&conn.scanner, conn, on_header_line)
	}

	on_header_line :: proc(conn: ^Issuer_Connection, token: string, err: bufio.Scanner_Error) {
		if err != nil {
			rerr := Request_Error.Unknown
			switch err {
			case .EOF:
				rerr = .Aborted
			case .No_Progress:
				rerr = .Response_Timeout
			}
			callback_err(conn, rerr)
			return
		}

		// First empty line means end of headers.
		if len(token) == 0 {
			on_headers_end(conn)
			return
		}

		_, ok := header_parse(&conn.headers, token, allocator=conn.curr_req.allocator)
		if !ok {
			callback_err(conn, .Invalid_Header)
			return
		}

		scanner_scan(&conn.scanner, conn, on_header_line)
	}

	on_headers_end :: proc(conn: ^Issuer_Connection) {
		if !headers_sanitize(&conn.headers) {
			callback_err(conn, .Invalid_Header)
			return
		}

		// TODO: check if response may have a body (spec)

		// TODO: configurable max length, make sure to handle the error in on_body too!
		body(&conn.body, -1, conn, on_body)
	}

	on_body :: proc(conn: rawptr, body: []byte, err: Body_Error) {
		conn := (^Issuer_Connection)(conn)

		rerr: Request_Error
		switch err {
		case .Partial:
			rerr = .Partial
		case .Timeout:
			rerr = .Response_Timeout
		case .EOF:
			rerr = .Aborted
		case .Invalid_Content_Length, .Invalid_Trailing_Header:
			// TODO: some bad response error indicating invalid length, headers.
			rerr = .Invalid_Header
		case .Corrupted_State, .Already_Consumed:
			panic("corrupted state retrieving body of response, probably a bug in this package")
		case .Exceeds_Max_Size:
			rerr = .Exceeds_Max_Size
		case .Unknown:
			rerr = .Unknown
		case:	
			rerr = .Unknown
		case .None:
		}

		assert(conn.curr_req.cb != nil)
		conn.curr_req.cb(conn.curr_req, {body, &conn.headers, conn.status}, rerr)
	}

	reconnect :: proc(conn: ^Issuer_Connection) {
		assert(conn.type == .Keep_Alive || conn.type == .Reconnect_With_Buffer)

		log.debugf("%v connection shutdown, reconnecting", conn.type)

		if conn.type != .Reconnect_With_Buffer {
			if reader, is_reader := conn.curr_req.body.content.(io.Reader); is_reader {
				if off, is_seeker := conn.body_off.?; is_seeker {
					log.debug("Seeking back to start of body so it can be resent")
					_, seek_err := io.seek(reader, off, .Start)
					if seek_err != nil {
						assert(seek_err != .Empty) // seeking was supported before, that's how we got a `body_off`
						callback_err(conn, .Outgoing_Body_Error)
						return
					}
					conn.body_off = nil
				}
			}
			conn.type = .Fresh
		}

		// TODO: verify this is the right order and timing.
		ssl_client.connection_destroy(ssl_client, conn.ssl)
		nbio.close(conn.socket)
		conn.ssl    = {}
		conn.socket = {}
		connect(conn)
	}
}

write_request :: proc(conn: ^Issuer_Connection) -> (allocations_ok: bool) {
	// Prepare requestline/headers
	r      := &conn.curr_req
	buffer := &conn.scanner.buf
	writer := io.Stream{
		data      = buffer,
		procedure = proc(stream_data: rawptr, mode: io.Stream_Mode, p: []byte, offset: i64, whence: io.Seek_From) -> (n: i64, err: io.Error) {
			assert(mode == .Write)
			buffer := (^[dynamic]byte)(stream_data)
			_, alloc_err := append(buffer, ..p)
			return i64(len(p)), .Unknown if alloc_err != nil else nil
		},
	}

	if err := requestline_write(writer, { method = r.method, target = r.url, version = {1, 1} }); err != nil { return }

	if !headers_has(r.headers, "Content-Length") {
		body_size := body_size(conn)
		if body_size < 0 {
			_, val := headers_delete(&r.headers, "Transfer-Encoding")
			if val == "" {
				if _, err := append(buffer, "Transfer-Encoding: chunked\r\n"); err != nil { return }
			} else {
				append_multiple_strings(buffer, "Transfer-Encoding: ", val, ", chunked\r\n") or_return
			}
		} else if body_size == 0 {
			if _, err := append(buffer, "Content-Length: 0\r\n"); err != nil { return }
		} else {
			if non_zero_reserve(buffer, len("Content-Length: ") + 24 + len("\r\n")) != nil { return }

			_, err := append(buffer, "Content-Length: ")
			assert(err == nil)

			// Write the length into unwritten portion.
			unwritten := dynamic_unwritten(buffer^)
			assert(len(unwritten) > 24)
			l := len(strconv.write_int(unwritten, i64(body_size), 10))
			dynamic_add_len(buffer, l)

			_, err = append(buffer, "\r\n")
			assert(err == nil)
		}
	}

	if !headers_has(r.headers, "Accept") {
		if _, err := append(buffer, "Accept: */*\r\n"); err != nil { return }
	}

	if !headers_has(r.headers, "User-Agent") {
		if _, err := append(buffer, "User-Agent: Odin/" + ODIN_VERSION + "\r\n"); err != nil { return }
	}

	if !headers_has(r.headers, "Host") {
		append_multiple_strings(buffer, "Host: ", url_parse(r.url).host, "\r\n") or_return
	}

	if headers_write(writer, &r.headers) != nil { return }

	if _, err := append(buffer, "\r\n"); err != nil { return }

	allocations_ok = true
	return
}

body_size :: proc(conn: ^Issuer_Connection) -> i64 {
	body := &conn.curr_req.body
	if size, has_size := body.size.?; has_size { return size }
	switch content in body.content {
	case []byte:
		return i64(len(content))
	case string:
		return i64(len(content))
	case io.Reader:
		if content.procedure == nil {
			body.size = 0
			return 0
		}

		body_size, size_err := io.size(content)
		#partial switch size_err {
		case nil:
			body.size = body_size
			return body_size
		case .Empty:
			// no size, use chunked encoding.
			fallthrough
		case:
			// error retrieving size, let's just do chunked encoding.
			body.size = -1
			return -1
		}
	case nbio.Handle:
		panic("should've already retrieved size of the file")
	case:
		unreachable()
	}
}

send :: proc(conn: ^Issuer_Connection, bufs: [][]byte, cb: proc(is_shutdown: bool, conn: ^Issuer_Connection)) {
	cb := cb
	if cb == nil {
		cb = proc(_: bool, _: ^Issuer_Connection) {}
	}

	// TODO: exclusively do raw if KTLS is enabled.

	switch determine_scheme(conn.curr_req.url, conn.ep.port) {
	case .Http:  raw_send(conn, bufs, cb)
	case .Https: ssl_send(nil, conn, bufs, cb)
	case:        unreachable()
	}

	raw_send :: proc(conn: ^Issuer_Connection, bufs: [][]byte, cb: proc(bool, ^Issuer_Connection)) {
		nbio.send_poly2(conn.socket, bufs, conn, cb, proc(op: ^nbio.Operation, conn: ^Issuer_Connection, cb: proc(bool, ^Issuer_Connection)) {
			if op.send.err != nil {
				rerr := Request_Error.Unknown
				#partial switch op.send.err.(net.TCP_Send_Error) {
				case .Connection_Closed:
					cb(true, conn)
					return
				case .Network_Unreachable:
					rerr = .Network
				case .Insufficient_Resources:
					rerr = .Allocation_Failure
				case .Host_Unreachable, .Not_Connected:
					rerr = .Connection_Failure
				case .Timeout:
					rerr = .Send_Request_Timeout
				}

				callback_err(conn, rerr)
				return
			}

			cb(false, conn)
		})
	}

	ssl_send :: proc(op: ^nbio.Operation, conn: ^Issuer_Connection, bufs: [][]byte, cb: proc(bool, ^Issuer_Connection)) {
		if op != nil && op.poll.result != .Ready {
			rerr := Request_Error.Unknown
			#partial switch op.poll.result {
			case .Timeout:
				rerr = .Send_Request_Timeout
			}
			callback_err(conn, rerr)
			return
		}

		switch n, err := ssl_client.send(conn.ssl, bufs); err {
		case: fallthrough
		case .Fatal:
			callback_err(conn, .TLS_Error)
		case .Shutdown:
			cb(true, conn)
		case .Want_Read, .Want_Write:
			nbio.poll_poly3(conn.socket, .Receive if err == .Want_Read else .Send, conn, slice.advance_slices(bufs, n), cb, ssl_send)
		case .None:
			assert(n == slice.reduce(bufs, 0, proc(acc: int, buf: []byte) -> int { return acc + len(buf) }))
			cb(false, conn)
		}
	}
}

scanner_recv :: proc(conn: rawptr, buf: []byte, s: ^Scanner, cb: On_Scanner_Read) {
	conn := (^Issuer_Connection)(conn)

	// NOTE: even with KTLS we still need to recv through the SSL interface from what I've noticed.

	switch determine_scheme(conn.curr_req.url, conn.ep.port) {
	case .Http:  raw_recv(conn, buf, cb)
	case .Https: ssl_recv(nil, conn, buf, cb)
	case:        unreachable()
	}

	raw_recv :: proc(conn: ^Issuer_Connection, buf: []byte, cb: On_Scanner_Read) {
		nbio.recv_poly2(conn.socket, {buf}, conn, cb, raw_received)
	}

	raw_received :: proc(op: ^nbio.Operation, conn: ^Issuer_Connection, cb: On_Scanner_Read) {
		err: net.TCP_Recv_Error
		if op.recv.err != nil { err = op.recv.err.(net.TCP_Recv_Error) }
		cb(&conn.scanner, op.recv.received, err)
	}

	ssl_recv :: proc(op: ^nbio.Operation, conn: ^Issuer_Connection, buf: []byte, cb: On_Scanner_Read) {
		if op != nil && op.type == .Poll && op.poll.result != .Ready {
			rerr := Request_Error.Unknown
			#partial switch op.poll.result {
			case .Timeout:
				rerr = .Response_Timeout
			}
			callback_err(conn, rerr)
			return
		}

		MAX_RECURSION :: 25

		// NOTE: hacky? fix for stack overflows because we keep getting data without going back up the stack.
		if conn.recursion > MAX_RECURSION {
			conn.recursion = 0
			nbio.next_tick_poly3(conn, buf, cb, ssl_recv)
			return
		}

		total: int
		for {
			switch n, res := ssl_client.recv(conn.ssl, buf[total:]); res {
			case .Want_Read, .Want_Write:
				if total > 0 {
					cb(&conn.scanner, total, nil)
				} else {
					conn.recursion = 0
					nbio.poll_poly3(conn.socket, .Receive if res == .Want_Read else .Send, conn, buf, cb, ssl_recv)
				}
			case: fallthrough
			case .Fatal:
				callback_err(conn, .TLS_Error)
			case .Shutdown:
				cb(&conn.scanner, total, .Connection_Closed)
			case .None:
				total += n
				if total < len(buf) {
					continue
				}
				conn.recursion += 1
				cb(&conn.scanner, total, nil)
			}

			break
		}
	}
}

Scheme :: enum {
	Https,
	Http,
}

determine_scheme :: proc(url: string, port: int) -> Scheme {
	scheme_i := strings.index(url, "://")
	if scheme_i >= 0 {
		switch url[:scheme_i] {
		case "http", "ws":   return .Http
		case "https", "wss": return .Https
		}
	}

	switch port {
	case 80:  return .Http
	case 443: return .Https
	}

	// Default to HTTPS if there is an SSL Client set up, HTTP otherwise.
	if ssl_client.connection_create == nil {
		return .Http
	}

	return .Https
}

append_multiple_strings :: proc(array: ^[dynamic]byte, strings: ..string) -> bool {
	n: int
	for str in strings {
		n += len(str)
	}

	if non_zero_reserve(array, n) != nil { return false }

	for str in strings {
		_, err := append(array, str)
		assert(err == nil)
	}
	return true
}

callback_err :: proc(conn: ^Issuer_Connection, err: Request_Error) {
	// TODO: what should we clean up here?
	assert(conn.curr_req.cb != nil)
	conn.curr_req.cb(conn.curr_req, {}, err)
}
