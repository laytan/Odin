#+build !js
package http

import "base:runtime"

import "core:bufio"
import "core:bytes"
import "core:fmt"
import "core:log"
import "core:mem"
import "core:container/queue"
import "core:mem/virtual"
import "core:nbio"
import "core:net"
import "core:os" // NOTE: os.processor_core_count has no alternative yet
import "core:os/os2"
import "core:slice"
import "core:sync"
import "core:thread"
import "core:time"
import win "core:sys/windows"
import "core:c/libc"

_ :: libc
_ :: os2
_ :: win

Server_Opts :: struct {
	// Whether the server should accept every request that sends a "Expect: 100-continue" header automatically.
	// Defaults to true.
	auto_expect_continue:    bool,
	// When this is true, any HEAD request is automatically redirected to the handler as a GET request.
	// Then, when the response is sent, the body is removed from the response.
	// Defaults to true.
	redirect_head_to_get:    bool,
	// Limit the maximum number of bytes to read for the request line (first line of request containing the URI).
	// The HTTP spec does not specify any limits but in practice it is safer.
	// RFC 7230 3.1.1 says:
	// Various ad hoc limitations on request-line length are found in
	// practice.  It is RECOMMENDED that all HTTP senders and recipients
	// support, at a minimum, request-line lengths of 8000 octets.
	// defaults to 8000.
	limit_request_line:      int,
	// Limit the length of the headers.
	// The HTTP spec does not specify any limits but in practice it is safer.
	// defaults to 8000.
	limit_headers:           int,
	// The thread count to use, defaults to your core count - 1.
	thread_count:            int,

	// // The initial size of the temp_allocator for each connection, defaults to 256KiB and doubles
	// // each time it needs to grow.
	// // NOTE: this value is assigned globally, running multiple servers with a different value will
	// // not work.
	// initial_temp_block_cap:  uint,
	// // The amount of free blocks each thread is allowed to hold on to before deallocating excess.
	// // Defaults to 64.
	// max_free_blocks_queued:  uint,
}

// TODO screaming case
Default_Server_Opts := Server_Opts {
	auto_expect_continue    = true,
	redirect_head_to_get    = true,
	limit_request_line      = 8000,
	limit_headers           = 8000,
	// initial_temp_block_cap  = 256 * mem.Kilobyte,
	// max_free_blocks_queued  = 64,
}

@(init, private)
server_opts_init :: proc() {
	Default_Server_Opts.thread_count = os.processor_core_count()
}

Server_State :: enum {
	Uninitialized,
	Listening,
	Serving,
	Running,
	Closing,
	Cleaning,
	Closed,
}

Server :: struct {
	opts:           Server_Opts,
	tcp_sock:       net.TCP_Socket,
	conn_allocator: mem.Allocator,
	handler:        Handler,
	main_thread:    int,

	threads:        []^thread.Thread,
	// Once the server starts closing/shutdown this is set to true, all threads will check it
	// and start their thread local shutdown procedure.
	//
	// NOTE: This is only ever set from false to true, and checked repeatedly,
	// so it doesn't have to be atomic, this is purely to keep the thread sanitizer happy.
	closing:        bool, // atomic.
	// Threads will decrement the wait group when they have fully closed/shutdown.
	// The main thread waits on this to clean up global data and return.
	threads_closed: sync.Wait_Group,

	// Updated every second with an updated date, this speeds up the server considerably
	// because it would otherwise need to call time.now() and format the date on each response.
	date:           Server_Date,
}

Server_Thread :: struct {
	conns:       map[net.TCP_Socket]^Connection,
	state:       Server_State,

	// Need to keep track of this, if the server socket is closed (during shutdown) we need to manually cancel
	// operations on it.
	curr_accept: ^nbio.Operation,

	// free_temp_blocks:       map[int]queue.Queue(^Block),
	// free_temp_blocks_count: int,
}

@(private, disabled = ODIN_DISABLE_ASSERT)
assert_has_td :: #force_inline proc(loc := #caller_location) {
	assert(td.state != .Uninitialized, "The thread you are calling from is not a server/handler thread", loc)
}

@(private, thread_local)
td: Server_Thread

// TODO screaming case
Default_Endpoint := net.Endpoint {
	address = net.IP4_Any,
	port    = 8080,
}

listen :: proc(
	s: ^Server,
	endpoint: net.Endpoint = Default_Endpoint,
	opts: Server_Opts = Default_Server_Opts,
) -> (err: net.Network_Error) {
	s.opts = opts
	s.conn_allocator = context.allocator
	s.main_thread = sync.current_thread_id()
	// initial_block_cap = int(s.opts.initial_temp_block_cap)
	// max_free_blocks_queued = int(s.opts.max_free_blocks_queued)

	if nbio_err := nbio.acquire_thread_event_loop(); nbio_err != nil {
		if nbio_err == .Unsupported {
			return net.Create_Socket_Error.Network_Unreachable
		}

		// TODO:
		fmt.panicf("unexpected error initializing nbio: %v", nbio_err)
	}

	s.tcp_sock = nbio.listen_tcp(endpoint) or_return
	td.state = .Listening
	return
}

serve :: proc(s: ^Server, h: Handler) -> (err: net.Network_Error) {
	assert(td.state == .Listening, "http server is not listening, listen before serve")
	s.handler = h

	thread_count := max(0, s.opts.thread_count - 1)
	sync.wait_group_add(&s.threads_closed, thread_count)
	s.threads = make([]^thread.Thread, thread_count, s.conn_allocator)
	for i in 0 ..< thread_count {
		s.threads[i] = thread.create_and_start_with_poly_data2(s, false, _server_thread_init, context)
	}

	// Start keeping track of and caching the date for the required date header.
	server_date_start(s)

	sync.wait_group_add(&s.threads_closed, 1)
	_server_thread_init(s, true)

	sync.wait(&s.threads_closed)

	log.debug("server threads are done, shutting down")

	net.close(s.tcp_sock)
	for t in s.threads { thread.destroy(t) }
	delete(s.threads)

	return nil
}

listen_and_serve :: proc(
	s: ^Server,
	h: Handler,
	endpoint: net.Endpoint = Default_Endpoint,
	opts: Server_Opts = Default_Server_Opts,
) -> (err: net.Network_Error) {
	listen(s, endpoint, opts) or_return
	return serve(s, h)
}

_server_thread_init :: proc(s: ^Server, main_thread := false) {
	td.conns = make(map[net.TCP_Socket]^Connection)
	// td.free_temp_blocks = make(map[int]queue.Queue(^Block))

	if !main_thread {
		nbio_err := nbio.acquire_thread_event_loop()
		// TODO: handle, although this happens when the main thread was able to init, but this extra thread isn't.
		fmt.assertf(nbio_err == nil, "unexpected error initializing nbio thread: %v", nbio_err)
	}

	log.debug("accepting connections")

	td.curr_accept = nbio.accept(s.tcp_sock, s, on_accept)

	log.debug("starting event loop")
	td.state = .Serving
	for {
		if sync.atomic_load(&s.closing) { _server_thread_shutdown(s); assert(td.state == .Closed) }
		if td.state == .Closed          { break }
		if td.state == .Cleaning        { continue }

		errno := nbio.tick()
		if errno != nil {
			log.errorf("non-blocking io tick error: %v", errno)
			break
		}
	}

	nbio.release_thread_event_loop()

	log.debug("event loop end")

	sync.wait_group_done(&s.threads_closed)
}


// The time between checks and closes of connections in a graceful shutdown.
@(private)
SHUTDOWN_INTERVAL :: time.Millisecond * 100

// Starts a graceful shutdown.
//
// Some error logs will be generated but all active connections are finished
// before closing them and all connections and threads are freed.
//
// 1. Stops 'server_start' from accepting new connections.
// 2. Close and free non-active connections.
// 3. Repeat 2 every SHUTDOWN_INTERVAL until no more connections are open.
// 4. Close the main socket.
// 5. Signal 'server_start' it can return.
server_shutdown :: proc(s: ^Server) {
	sync.atomic_store(&s.closing, true)
}

_server_thread_shutdown :: proc(s: ^Server, loc := #caller_location) {
	assert_has_td(loc)

	td.state = .Closing
	defer delete(td.conns)
	// defer { blocks: int
	// 	for _, &bucket in td.free_temp_blocks {
	// 		for block in queue.pop_front_safe(&bucket) {
	// 			blocks += 1
	// 			free(block)
	// 		}
	// 		queue.destroy(&bucket)
	// 	}
	// 	delete(td.free_temp_blocks)
	// 	log.infof("had %i temp blocks to spare", blocks)
	// }

	nbio.remove(td.curr_accept)
	td.curr_accept = nil

	for i := 0; ; i += 1 {
		for sock, conn in td.conns {
			#partial switch conn.state {
			case .Active:
				log.infof("shutdown: connection %i still active", sock)
			case .New, .Idle, .Pending:
				log.infof("shutdown: closing connection %i", sock)
				close_eventually(conn)
			case .Closed:
				log.warn("closed connection in connections map, maybe a race or logic error")
			case .Closing:
			}
		}

		if len(td.conns) == 0 {
			break
		}

		err := nbio.tick()
		fmt.assertf(err == nil, "IO tick error during shutdown: %v", err)
	}

	td.state = .Cleaning

	if sync.current_thread_id() == s.main_thread {
		nbio.close(s.tcp_sock)
	}

	log.debug("running out remaining events")
	nbio.run()
	td.state = .Closed

	log.info("shutdown: done")
}

@(private)
on_interrupt_server: ^Server
@(private)
on_interrupt_context: runtime.Context

// Registers a signal handler to shutdown the server gracefully on interrupt signal.
// Can only be called once in the lifetime of the program because of a hacky interaction with libc.
server_shutdown_on_interrupt :: proc(s: ^Server) {
	on_interrupt_server = s
	on_interrupt_context = context

	when ODIN_OS == .Windows {
		ok := win.SetConsoleCtrlHandler(proc "std" (u32) -> win.BOOL {
			context = on_interrupt_context

			// Force close on second signal.
			if td.state == .Closing {
				return false
			}

			server_shutdown(on_interrupt_server)

			return true
		}, true)
		assert(ok == true)
	} else {
		libc.signal(
			libc.SIGINT,
			proc "c" (_: i32) {
				context = on_interrupt_context

				// Force close on second signal.
				if td.state == .Closing {
					os2.exit(1)
				}

				server_shutdown(on_interrupt_server)
			},
		)
	}
}

// Taken from Go's implementation,
// The maximum amount of bytes we will read (if handler did not)
// in order to get the connection ready for the next request.
// TODO: UPPER CASE
@(private)
Max_Post_Handler_Discard_Bytes :: 256 << 10

// How long to wait before actually closing a connection.
// This is to make sure the client can fully receive the response.
// TODO: UPPER CASE
Conn_Close_Delay :: time.Millisecond * 500

Connection_State :: enum {
	Pending, // Pending a client to attach.
	New, // Got client, waiting to service first request.
	Active, // Servicing request.
	Idle, // Waiting for next request.
	Will_Close, // Closing after the current response is sent.
	Closing, // Going to close, cleaning up.
	Closed, // Fully closed.
}

@(private)
connection_set_state :: proc(c: ^Connection, s: Connection_State) -> bool {
	if s < .Closing && c.state >= .Closing {
		return false
	}

	if s == .Closing && c.state == .Closed {
		return false
	}

	c.state = s
	return true
}

// TODO/PERF: pool the connections, saves having to allocate scanner buf and temp_allocator every time.
Connection :: struct {
	server:         ^Server,
	socket:         nbio.TCP_Socket,
	state:          Connection_State,
	scanner:        Scanner,
	temp_allocator: virtual.Arena,
	responses:      queue.Queue(Queued_Response),

	// Need to keep track of this, if (during shutdown) the socket is closed we need to manually cancel
	// operations on it.
	curr_recv:      ^nbio.Operation,

	loop:           Loop,
	ctx:            Context,

	// ud:             rawptr,
}

@(private)
Queued_Response :: struct {
	buf:        []byte,
	on_sent:    proc(c: ^Connection, user: rawptr),
	on_sent_ud: rawptr,
}

// Loop/request cycle state.
@(private)
Loop :: struct {
	req: Request,
	res: Response,
}

res_loop :: #force_inline proc(r: ^Response) -> ^Loop {
	return container_of(r, Loop, "res")
}

loop_conn :: #force_inline proc(l: ^Loop) -> ^Connection {
	return container_of(l, Connection, "loop")
}

Context :: struct {
	req:  ^Request,
	res:  ^Response,
}

@(private)
_connection_close :: proc(c: ^Connection, loc := #caller_location) {
	assert_has_td(loc)

	if c.state >= .Closing {
		log.infof("[%i] connection already closing/closed", c.socket)
		return
	}

	log.debugf("[%i] closing connection", c.socket)

	c.state = .Closing

	assert(queue.len(c.responses) == 0)

	// RFC 7230 6.6.

	// Close read side of the connection, then wait a little bit, allowing the client
	// to process the closing and receive any remaining data.
	net.shutdown(c.socket, net.Shutdown_Manner.Receive)

	nbio.timeout_poly(Conn_Close_Delay, c, proc(_: ^nbio.Operation, c: ^Connection) {
		nbio.remove(c.curr_recv)

		nbio.close_poly(c.socket, c, proc(_: ^nbio.Operation, c: ^Connection) {
			log.infof("[%i] closed connection", c.socket)

			c.state = .Closed

			scanner_destroy(&c.scanner)
			queue.destroy(&c.responses)

			// allocator_destroy(&c.temp_allocator)
			virtual.arena_destroy(&c.temp_allocator)

			delete_key(&td.conns, c.socket)
			free(c, c.server.conn_allocator)
		})
	})
}

connection_temp_allocator :: proc(c: ^Connection) -> mem.Allocator {
	return virtual.arena_allocator(&c.temp_allocator)
}

@(private)
on_accept :: proc(op: ^nbio.Operation) {
	server := cast(^Server)op.user_data[0]

	if op.accept.err != nil {
		#partial switch op.accept.err {
		case .Insufficient_Resources:
			log.warn("Connection limit reached, trying again in a bit")
			nbio.timeout(time.Second, server, proc(op: ^nbio.Operation) {
				server := cast(^Server)op.user_data[0]
				td.curr_accept = nbio.accept(server.tcp_sock, server, on_accept)
			})
			return
		}

		fmt.panicf("accept error: %v", op.accept.err)
	}

	// TODO: see if queueing multiple accepts per thread improves things?

	// Accept next connection.
	td.curr_accept = nbio.accept(server.tcp_sock, server, on_accept)

	c := new(Connection, server.conn_allocator)
	c.state = .New
	c.server = server
	c.socket = op.accept.socket

	td.conns[c.socket] = c

	log.infof("[%i] new connection", c.socket)
	conn_handle_reqs(c)
}

@(private)
conn_handle_reqs :: proc(c: ^Connection) {
	scanner_recv :: proc(c: rawptr, buf: []byte, s: ^Scanner, callback: On_Scanner_Read) {
		c := (^Connection)(c)
		assert_has_td()

		context.user_ptr = rawptr(callback)

		c.curr_recv = nbio.recv(c.socket, buf, c, on_recv, timeout=s.timeout)

		on_recv :: proc(op: ^nbio.Operation) {
			c := cast(^Connection)op.user_data[0]
			c.curr_recv = nil
			callback := (On_Scanner_Read)(context.user_ptr)
			callback(&c.scanner, op.recv.received, op.recv.err.(net.TCP_Recv_Error))
		}
	}

	scanner_init(&c.scanner, c, scanner_recv, c.server.conn_allocator)
	c.scanner.timeout = time.Minute // TODO: configurable

	c.responses.data.allocator = c.server.conn_allocator

	// allocator_init(&c.temp_allocator, c.server.conn_allocator)
	// context.temp_allocator = allocator(&c.temp_allocator)
	err := virtual.arena_init_growing(&c.temp_allocator)
	assert(err == nil)
	context.temp_allocator = virtual.arena_allocator(&c.temp_allocator)

	conn_handle_req(c, context.temp_allocator)
}

@(private)
conn_handle_req :: proc(c: ^Connection, allocator := context.temp_allocator) {
	headers_init(&c.loop.req.headers, allocator)
	response_init(&c.loop.res, c.server.conn_allocator, allocator)

	log.info("scanning request")

	c.scanner.max_token_size = c.server.opts.limit_request_line
	scanner_scan(&c.scanner, &c.loop, on_rline1)

	on_rline1 :: proc(l: ^Loop, token: string, err: bufio.Scanner_Error) {
		conn := loop_conn(l)
		if !connection_set_state(conn, .Active) { return }

		// TODO: handle all scanner callbacks the same way as here:

		if err != nil {
			if err == .EOF {
				log.infof("[%i] client disconnected (EOF)", conn.socket)
			} else if err == .No_Progress {
				log.infof("[%i] connection timed out", conn.socket)
			} else {
				log.warnf("[%i] request scanner error: %v", conn.socket, err)
			}

			// TODO: should this try sending an error response?
			close_eventually(conn)
			return
		}

		// In the interest of robustness, a server that is expecting to receive
		// and parse a request-line SHOULD ignore at least one empty line (CRLF)
		// received prior to the request-line.
		if len(token) == 0 {
			log.debug("first request line empty, skipping in interest of robustness")
			scanner_scan(&conn.scanner, l, on_rline2)
			return
		}

		on_rline2(l, token, nil)
	}

	on_rline2 :: proc(l: ^Loop, token: string, err: bufio.Scanner_Error) {
		conn := loop_conn(l)
		if err != nil {
			log.warnf("request scanning error: %v", err)
			close_eventually(conn)
			return
		}

		rline, err := requestline_parse(token, context.temp_allocator)
		switch err {
		case .Method_Not_Implemented:
			log.infof("request-line %q invalid method", token)
			headers_set_close(&l.res.headers)
			l.res.status = .Not_Implemented
			respond(&l.res)
			return
		case .Invalid_Version_Format, .Not_Enough_Fields:
			log.warnf("request-line %q invalid: %s", token, err)
			close_eventually(conn)
			return
		case .None:
			l.req.line = rline
		}

		// Might need to support more versions later.
		if rline.version.major != 1 || rline.version.minor > 1 {
			log.infof("request http version not supported %v", rline.version)
			headers_set_close(&l.res.headers)
			l.res.status = .HTTP_Version_Not_Supported
			respond(&l.res)
			return
		}

		l.req.url = url_parse(rline.target.(string))

		conn.scanner.max_token_size = conn.server.opts.limit_headers
		scanner_scan(&conn.scanner, l, on_header_line)
	}

	on_header_line :: proc(l: ^Loop, token: string, err: bufio.Scanner_Error) {
		conn := loop_conn(l)
		if err != nil {
			log.warnf("request scanning error: %v", err)
			close_eventually(conn)
			return
		}

		// The first empty line denotes the end of the headers section.
		if len(token) == 0 {
			on_headers_end(l)
			return
		}

		if _, ok := header_parse(&l.req.headers, token, context.temp_allocator); !ok {
			log.warnf("header-line %s is invalid", token)
			headers_set_close(&l.res.headers)
			l.res.status = .Bad_Request
			respond(&l.res)
			return
		}

		conn.scanner.max_token_size -= len(token)
		if conn.scanner.max_token_size <= 0 {
			log.warn("request headers too large")
			headers_set_close(&l.res.headers)
			l.res.status = .Request_Header_Fields_Too_Large
			respond(&l.res)
			return
		}

		scanner_scan(&conn.scanner, l, on_header_line)
	}

	on_headers_end :: proc(l: ^Loop) {
		conn := loop_conn(l)
		if !headers_sanitize_for_server(&l.req.headers) {
			log.warn("request headers are invalid")
			headers_set_close(&l.res.headers)
			l.res.status = .Bad_Request
			respond(&l.res)
			return
		}

		l.req.headers.readonly = true

		conn.scanner.max_token_size = bufio.DEFAULT_MAX_SCAN_TOKEN_SIZE

		// Automatically respond with a continue status when the client has the Expect: 100-continue header.
		if expect, ok := headers_get(l.req.headers, "expect");
			ok && expect == "100-continue" && conn.server.opts.auto_expect_continue {

			l.res.status = .Continue

			// TODO: this does not work anymore since we expect another response after 1xx responses.
			respond(&l.res)
			return
		}

		l.req._scanner = &conn.scanner

		rline := &l.req.line.(Requestline)
		// An options request with the "*" is a no-op/ping request to
		// check for server capabilities and should not be sent to handlers.
		if rline.method == .Options && rline.target.(string) == "*" {
			l.res.status = .OK
			respond(&l.res)
		} else {
			// Give the handler this request as a GET, since the HTTP spec
			// says a HEAD is identical to a GET but just without writing the body,
			// handlers shouldn't have to worry about it.
			is_head := rline.method == .Head
			if is_head && conn.server.opts.redirect_head_to_get {
				l.req.is_head = true
				rline.method = .Get
			}

			when !ODIN_DISABLE_ASSERT {
				context.temp_allocator = no_free_all_allocator(conn)
			}

			conn.ctx = {&l.req, &l.res}
			conn.server.handler.handle(&conn.server.handler, &conn.ctx)
		}
	}
}

// A buffer that will contain the date header for the current second.
@(private)
Server_Date :: struct {
	buf_backing: [DATE_LENGTH]byte,
	buf:         bytes.Buffer,
	now:         time.Time,
}

@(private)
server_date_start :: proc(s: ^Server) {
	s.date.buf.buf = slice.into_dynamic(s.date.buf_backing[:])
	server_date_update(nil, s)
}

// Updates the time and schedules itself for after a second.
@(private)
server_date_update :: proc(_: ^nbio.Operation, s: ^Server) {
	if sync.atomic_load(&s.closing) {
		return
	}

	nbio.timeout_poly(time.Second, s, server_date_update)

	bytes.buffer_reset(&s.date.buf)
	s.date.now = nbio.now()
	date_write(bytes.buffer_to_stream(&s.date.buf), s.date.now)
}

@(private)
server_date :: proc(s: ^Server) -> string {
	return string(s.date.buf_backing[:])
}

@(private)
no_free_all_allocator :: proc(c: ^Connection) -> runtime.Allocator {
	return {
		data      = c,
		procedure = proc(allocator_data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int, old_memory: rawptr, old_size: int, location := #caller_location) -> ([]byte, runtime.Allocator_Error) {
			if mode == .Free_All {
				panic("'free_all' called on connection's temporary allocator", location)
			}

			return virtual.arena_allocator_proc(&((^Connection)(allocator_data).temp_allocator), mode, size, alignment, old_memory, old_size, location)
		},
	}
}
