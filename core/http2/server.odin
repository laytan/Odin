#+vet explicit-allocators
#+build !js
package http

import "base:intrinsics"
import "base:runtime"

import "core:mem"
import "core:strings"
import "core:time"
import "core:bytes"
import "core:nbio"
import "core:log"
import "core:os"
import "core:thread"
import "core:sync"
import "core:container/xar"
import "core:mem/virtual"
import "core:io"

// PERF: we can pre-compute common header key hashes

Server :: struct {
	allocator:       runtime.Allocator,
	opts:            Server_Options,
	socket:          nbio.TCP_Socket,
	threads:         []Server_Thread,
	serve:           sync.One_Shot_Event,
	running_threads: sync.Wait_Group,
	shutting_down:   bool,

	temp_allocator_backing: virtual.Arena,
}

Endpoint :: nbio.Endpoint

Server_Options :: struct {
	address:      nbio.Address,
	port:         int,
	backlog:      int,
	thread_count: int,
	handler:      Handler,
	no_auto_expect_continue: bool,
	no_redirect_head_to_get: bool,
}

DEFAULT_BACKLOG  :: 1000
DEFAULT_ADDRESS  :: nbio.IP4_Any
DEFAULT_PORT     :: 8080

General_Error :: enum i32 {
	Allocation_Failed,
	Unsupported,
}

Listen_Error :: union #shared_nil {
	nbio.Create_Socket_Error,
	nbio.Bind_Error,
	nbio.Listen_Error,
}

Server_Error :: intrinsics.type_merge(
	Listen_Error,
	union #shared_nil {
		General_Error,
	},
)

_acquire_event_loop :: proc(s: ^Server) -> General_Error {
	if err := nbio.acquire_thread_event_loop(); err != nil {
		#partial switch err {
		case .Unsupported:
			when ODIN_OS == .Linux {
				log.errorf("http: unsupported platform for nbio. Is io_uring disabled in your Linux Kernel?")
			}
			return .Unsupported
		case .Allocation_Failed:
			return .Allocation_Failed
		}
	}

	return nil
}

_listen :: proc(s: ^Server) -> Listen_Error {
	socket, net_err := nbio.listen_tcp(
		nbio.Endpoint{
			s.opts.address != nil ? s.opts.address  : DEFAULT_ADDRESS,
			s.opts.port > 0       ? s.opts.port     : DEFAULT_PORT,
		},
		s.opts.backlog > 0        ? s.opts.backlog  : DEFAULT_BACKLOG,
	)
	#partial switch err in net_err {
	case nbio.Create_Socket_Error: return err
	case nbio.Bind_Error:          return err
	case nbio.Listen_Error:        return err
	case nil:
	case:
		panic("unexpected nbio.listen_tcp error")
	}

	s.socket = socket
	return nil
}

Server_Thread :: struct {
	s:           ^Server,
	thread:      thread.Thread,
	event_loop:  ^nbio.Event_Loop,
	curr_accept: ^nbio.Operation,
	id:          int,
	connections: xar.Freelist_Array(Connection, 8),
	free_arenas: ^Arena,
	date: [DATE_LENGTH]byte,
}

Arena :: struct {
	using base: mem.Arena,
	prev: ^Arena,
}

Connection :: struct {
	socket: nbio.TCP_Socket,
	recv:   ^nbio.Operation,

	using temp: struct {
		arenas:          ^Arena,
		temp_arenas:     ^Arena,
		pos:             int,
		buf:             [dynamic]byte,
		last_recv_start: time.Time,
		last_recv_dur:   time.Duration,
		last_recv_n:     int,
		headers_quota:   Quota,
		body_quota:      Quota,

		using ctx: Context,
	},
}

// One virtual allocator on the server.
// Each server thread holds a list of free arenas
// Each connection holds a list of used arenas

ARENA_SIZE :: 4096

server_thread_get_free_arena :: proc(min_size: int = 0) -> ^Arena {
	size := max(ARENA_SIZE, uint(max(0, min_size+size_of(Arena)+align_of(Arena))))

	{
		free_arena := td.free_arenas
		if free_arena != nil {
			if  uint(len(free_arena.data)) >= size {
				td.free_arenas = free_arena.prev
				free_arena.offset = size_of(Arena)
				free_arena.peak_used, free_arena.temp_count = 0, 0
				free_arena.prev = nil
				return free_arena
			}
		}
	}

	data, err := virtual.arena_alloc(&td.s.temp_allocator_backing, size, mem.DEFAULT_ALIGNMENT)
	assert(err == nil) // TODO: Handle

	arena := (^Arena)(raw_data(data))
	arena.data   = data
	arena.offset = size_of(Arena)

	return arena
}

transaction_allocator_destroy :: proc(c: ^Connection) -> (mem_used: int) {
	arena := c.arenas
	for arena != nil {
		prev_arena := arena.prev
		mem_used += arena.peak_used
		arena.prev = td.free_arenas
		td.free_arenas = arena
		arena = prev_arena
	}
	c.arenas = nil
	return
}

temp_allocator_destroy :: proc(c: ^Connection) -> (mem_used: int) {
	arena := c.temp_arenas
	for arena != nil {
		prev_arena := arena.prev
		mem_used += arena.peak_used
		arena.prev = td.free_arenas
		td.free_arenas = arena
		arena = prev_arena
	}
	c.temp_arenas = nil
	return
}

transaction_allocator :: proc(c: ^Connection) -> runtime.Allocator {
	return connection_allocator(c, "arenas", false)
}

temp_allocator :: proc(c: ^Connection) -> runtime.Allocator {
	return connection_allocator(c, "temp_arenas", true)
}

@(private="file")
connection_allocator :: proc(c: ^Connection, $ARENAS_FIELD: string, $FREE_ALL: bool) -> runtime.Allocator {
	return {
		data = c,
		procedure = proc(allocator_data: rawptr, mode: runtime.Allocator_Mode,
                             size, alignment: int,
                             old_memory: rawptr, old_size: int,
                             location: runtime.Source_Code_Location) -> (bs: []byte, err: runtime.Allocator_Error) {
			c := (^Connection)(allocator_data)

			get_arena :: #force_inline proc(c: ^Connection) -> ^Arena {
				return (^^Arena)(uintptr(c) + offset_of_by_string(Connection, ARENAS_FIELD))^
			}

			set_arena :: #force_inline proc(c: ^Connection, arena: ^Arena) {
				(^^Arena)(uintptr(c) + offset_of_by_string(Connection, ARENAS_FIELD))^ = arena
			}

			new_arena :: proc(c: ^Connection, min_size := 0) -> ^Arena {
				arena := server_thread_get_free_arena(min_size)
				arena.prev = get_arena(c)
				set_arena(c, arena)
				return arena
			}

			arena := get_arena(c)
			if arena == nil {
				arena = new_arena(c)
			}

			switch mode {
			case .Alloc:
				bs, err = mem.arena_alloc_bytes(arena, size, alignment, location)
				if err == .Out_Of_Memory {
					arena = new_arena(c, size)
					bs, err = mem.arena_alloc_bytes(arena, size, alignment, location)
				}
				return

			case .Alloc_Non_Zeroed:
				bs, err = mem.arena_alloc_bytes_non_zeroed(arena, size, alignment, location)
				if err == .Out_Of_Memory {
					arena = new_arena(c, size)
					bs, err = mem.arena_alloc_bytes_non_zeroed(arena, size, alignment, location)
				}
				return

			case .Resize, .Resize_Non_Zeroed:
				should_zero := mode == .Resize
				bs, err = mem._default_resize_bytes_align(mem.byte_slice(old_memory, old_size), size, alignment, should_zero, mem.arena_allocator(arena), location)
				if err == .Out_Of_Memory {
					arena = new_arena(c, size)
					if should_zero {
						bs, err = mem.arena_alloc_bytes(arena, size, alignment, location)
					} else {
						bs, err = mem.arena_alloc_bytes_non_zeroed(arena, size, alignment, location)
					}
					intrinsics.mem_copy_non_overlapping(raw_data(bs), old_memory, old_size)
				}
				return

			case .Query_Features:
				set := (^mem.Allocator_Mode_Set)(old_memory)
				if set != nil {
					set^ = {.Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed, .Query_Features}
					when FREE_ALL {
						set^ += {.Free_All}
					}
				}
				return nil, nil

			case .Free_All:
				when FREE_ALL {
					#assert(ARENAS_FIELD == "temp_arenas")
					temp_allocator_destroy(c)

					return nil, nil
				} else {
					return nil, .Mode_Not_Implemented
				}

			case .Free, .Query_Info:
				return nil, .Mode_Not_Implemented

			case:
				return nil, nil
			}
		},
	}
}

Context :: struct {
	req:  Request,
	res:  Response,
	vars: [dynamic]Context_Var,
}

Context_Var :: struct {
	id:  typeid,
	val: rawptr,
}

context_add :: proc(ctx: ^Context, var: $T) -> ^T {
	val := new_clone(var, transaction_allocator(connection_of_context(ctx)))
	append(&ctx.vars, Context_Var{
		id  = T,
		val = val,
	})
	return val
}

context_get :: proc(ctx: ^Context, $T: typeid) -> ^T {
	#reverse for var in ctx.vars {
		if var.id == T {
			return (^T)(var.val)
		}
	}

	return nil
}

Request :: struct {
	line:    Requestline,
	is_redirected_head: bool,
	headers: Headers,
}

Response :: struct {
	status:  Status,
	headers: Headers,

	buf: [dynamic]byte,
	deferred: [dynamic]proc(res: ^Response),
}

// TODO: always run, also on send/recv failure etc.
// TODO: run in reverse.
response_defer :: proc(res: ^Response, deffered: proc(^Response)) {
	append(&res.deferred, deffered)
}

// TODO: quote option on server. Transaction could hold only the 2 mutating durations to save space.

// TODO: max length

Quota :: struct {
	// The minimum time after which a client may be disconnected.
	min:      time.Duration,
	// The absolute maximum time the client may take.
	max:      time.Duration,
	// The minimum flow rate (bytes per second) a client must hold.
	min_rate: int,
	// Every `min_rate` bytes received adds this amount of time to the allowed timeout (up to `max`).
	rate_add: time.Duration,
}

// Default quota for headers, this is intentionally permissive.
//
// Allow at least 20 seconds to receive the headers. If the client sends data, increase the timeout
// by 1 second for every 500 bytes received. But do not allow more than 40 seconds in total.
DEFAULT_HEADERS_QUOTA :: Quota{
	min      = 20 * time.Second,
	max      = 40 * time.Second,
	min_rate = 500,
	rate_add = time.Second,
}

// Default quota for bodies, this is intentionally permissive.
//
// Allow at least 20 seconds to receive the body. If the client sends data, increase the timeout
// by 1 second for every 500 bytes received. With no total limit (client may send 500b/s indefinitely).
DEFAULT_BODY_QUOTA :: Quota{
	min      = 20 * time.Second,
	max      = 0,
	min_rate = 500,
	rate_add = time.Second,
}

/*
Returns the timeout for the next recv call.
If that `recv` errors on a timeout, abort the connection.
If this returns 0, abort the connection.
If this returns -1, no quota/timeout is configured.
*/
get_timeout :: proc(last_recv_dur: time.Duration, q: ^Quota, received: int) -> time.Duration {
	last_recv_dur := last_recv_dur
	last_recv_dur  = max(0, last_recv_dur)

	if q.min_rate > 0 && last_recv_dur > 0 {
		rate := f64(received) / time.duration_seconds(last_recv_dur)
		if rate < f64(q.min_rate) {
			return 0
		}
	}

	if q.max > 0 {
		q.max -= last_recv_dur
		if q.max <= 0 {
			return 0
		}
	}

	if q.min > 0 {
		q.min -= last_recv_dur
		if q.min_rate > 0 && q.rate_add > 0 {
			q.min += time.Duration((f64(received) / f64(q.min_rate)) * f64(q.rate_add))
		}
		if q.max > 0 && q.min > q.max {
			q.min = q.max
		}

		return q.min
	}

	return q.max > 0 ? q.max : -1
}

@(thread_local)
td: ^Server_Thread

_setup_threads :: proc(s: ^Server) -> runtime.Allocator_Error {
	thread_count := max(1, s.opts.thread_count > 0 ? s.opts.thread_count : os.get_processor_core_count())
	s.threads = make([]Server_Thread, thread_count, s.allocator) or_return

	for &server_thread in s.threads {
		xar.init(&server_thread.connections, s.allocator)
	}

	for &server_thread, i in s.threads[1:] {
		thread.create_and_start_with_poly_data3(s, &server_thread, i+2, _server_thread, context)
	}

	main_thread := &s.threads[0]
	main_thread.id = 1
	main_thread.s = s
	td = main_thread

	return nil
}

_server_thread :: proc(s: ^Server, thread: ^Server_Thread, id: int) {
	thread.s = s
	thread.id = id
	td = thread

	if err := nbio.acquire_thread_event_loop(); err != nil {
		// Should not happen AFAIK, the main thread has already successfully
		// done this, so .Unsupported is handled, could fail to allocate so lets
		// just log it and exit the thread.
		log.errorf("http[t=%v]: msg=\"server thread could not initialize nbio\", err=%v", id, err)
		return
	}

	_server_thread_serve(thread)
}

_server_thread_serve :: proc(thread: ^Server_Thread) {
	thread.event_loop = nbio.current_thread_event_loop()

	sync.one_shot_event_wait(&thread.s.serve)

	sync.wait_group_add(&thread.s.running_threads, 1)
	defer sync.wait_group_done(&thread.s.running_threads)

	log.debugf("http[t=%v]: msg=\"serving\"", thread.id)

	thread.curr_accept = nbio.accept_poly(thread.s.socket, thread, _on_accept)

	date_update(nil)

	for {
		if sync.atomic_load(&thread.s.shutting_down) {
			_server_thread_shutdown(thread)
			break
		}

		err := nbio.tick()
		if err != nil {
			log.errorf("http[t=%v]: msg=\"event loop tick error\" err=%v", thread.id, err)
			break
		}
	}
}

_server_thread_shutdown :: proc(thread: ^Server_Thread) {
	log.warn("TODO: shutdown")
	nbio.release_thread_event_loop()
}

_on_accept :: proc(op: ^nbio.Operation, thread: ^Server_Thread) {
	if op.accept.err != nil {
		log.errorf("http[t=%v]: accept_err=", thread.id, op.accept.err)
		// TODO: handle, try again later.
		return
	}

	thread.curr_accept = nbio.accept_poly(thread.s.socket, thread, _on_accept)

	log.debugf("http[t=%v][c=%v]: msg=\"accepted connection\", from=%v", thread.id, op.accept.client, op.accept.client_endpoint)

	c, err := xar.push(&thread.connections, Connection{
		socket = op.accept.client,
	})
	if err != nil {
		log.error(err)
		// TODO: handle, try again later.
		return
	}

	// TODO: initialize with server's configs

	// Scanner.
	// Scanner per transaction.
	// Re-use scanners?
	// Scan entire header?

	for deferred in c.res.deferred {
		log.debugf("http[t=%v][c=%v]: msg=\"running defer\", defer=%v", td.id, c.socket, deferred)
		deferred(&c.res)
	}

	_serve_connection(c)
}

// How long to wait before actually closing a connection.
// This is to make sure the client can fully receive the response.
CONN_CLOSE_DELAY :: time.Millisecond * 500

// Sends a FIN, receives for at most CONN_CLOSE_DELAY (making sure the client gets our close / waiting for it to close too).
// Ultimately destroying the connection.
connection_close :: proc(c: ^Connection) {
	log.debugf("http[t=%v][c=%v]: msg=\"shutdown\"", td.id, c.socket)
	nbio.shutdown(c.socket, .Send)

	@(static) junk: [1024]byte

	c.headers_quota.max = CONN_CLOSE_DELAY
	c.last_recv_start   = nbio.now()
	nbio.recv_poly(c.socket, {junk[:]}, c, on_recv, all=true, timeout=c.headers_quota.max)

	on_recv :: proc(op: ^nbio.Operation, c: ^Connection) {
		now := nbio.now()
		c.headers_quota.max -= time.diff(c.last_recv_start, now)
		log.debugf("http[t=%v][c=%v]: err=%v, received=%v, closing_for=%v", td.id, c.socket, op.recv.err, op.recv.received, CONN_CLOSE_DELAY-c.headers_quota.max)
		if op.recv.err == nil && op.recv.received > 0 {
			if c.headers_quota.max > 0 {
				c.last_recv_start = now
				nbio.recv_poly(c.socket, {junk[:]}, c, on_recv, all=true, timeout=c.headers_quota.max)
				return
			}
		}

		connection_destroy(c)
	}
}

connection_destroy :: proc(c: ^Connection) {
	log.debugf("http[t=%v][c=%v]: msg=\"destroy\"", td.id, c.socket)
	nbio.close(c.socket)

	mem_use := transaction_allocator_destroy(c) + temp_allocator_destroy(c)
	if mem_use > 0 {
		log.debugf("http[t=%v][c=%v]: msg=\"request cleaned up\", mem_use=%M", td.id, c.socket, mem_use)
	}

	idx, ok := xar.linear_search(&td.connections, c)
	assert(ok)
	xar.release(&td.connections, idx)
}

invalid_request :: proc(c: ^Connection, status: Status) {
	log.warnf("http[t=%v][c=%v]: status=%v, msg=\"invalid request\"", td.id, c.socket, status)
	c.res.status = status
	headers_set(&c.res.headers, "connection", "close")
	respond(&c.res)
}

_serve_connection :: proc(c: ^Connection) {
	mem_use := transaction_allocator_destroy(c) + temp_allocator_destroy(c)
	if mem_use > 0 {
		log.debugf("http[t=%v][c=%v]: msg=\"request cleaned up\", mem_use=%M", td.id, c.socket, mem_use)
	}

	mem.zero_item(&c.temp)

	c.headers_quota = DEFAULT_HEADERS_QUOTA
	c.body_quota    = DEFAULT_BODY_QUOTA

	allocator := transaction_allocator(c)

	c.buf.allocator          = allocator
	c.req.headers.allocator  = allocator
	c.res.headers.allocator  = allocator
	c.vars.allocator         = allocator
	c.res.buf.allocator      = allocator
	c.res.deferred.allocator = allocator

	scan_rline1(c)

	scan_rline1 :: proc(c: ^Connection) {
		line, ok := scan_header_line_or_recv(c, scan_rline1)
		if !ok { return }

		if len(line) == 0 {
			scan_rline2(c)
			return
		}

		on_rline(c, line)
	}

	scan_rline2 :: proc(c: ^Connection) {
		line, ok := scan_header_line_or_recv(c, scan_rline2)
		if !ok { return }

		on_rline(c, line)
	}

	on_rline :: proc(c: ^Connection, line: []byte) {
		log.debugf("http[t=%v][c=%v]: rline=%q", td.id, c.socket, line)

		line, err := requestline_parse(string(line))
		if err != nil {
			log.warnf("http[t=%v][c=%v]: err=%v", td.id, c.socket, err)
			#partial switch err {
			case .Method_Not_Implemented: invalid_request(c, .Method_Not_Allowed)
			case:                         invalid_request(c, .Bad_Request)
			}
		}

		if line.version.major != 1 || line.version.minor > 1 {
			log.warnf("http[t=%v][c=%v]: version=%v.%v, status=%v", td.id, c.socket, line.version.major, line.version.minor, Status.HTTP_Version_Not_Supported)
			invalid_request(c, .HTTP_Version_Not_Supported)
			return
		}

		log.debugf("http[t=%v][c=%v]: method=%v, target=%q, version=%v.%v", td.id, c.socket, line.method, line.target, line.version.major, line.version.minor)
		c.req.line = line

		scan_headers(c)
	}

	scan_headers :: proc(c: ^Connection) {
		for line in scan_header_line_or_recv(c, scan_headers) {
			if len(line) == 0 {
				on_headers(c)
				return
			}

			key, value, ok := header_parse(string(line))
			if !ok {
				invalid_request(c, .Bad_Request)
				return
			}

			log.debugf("http[t=%v][c=%v]: key=%q, value=%q", td.id, c.socket, key, value)

			if alloc_err := headers_add(&c.req.headers, key, value); alloc_err != nil {
				log.errorf("http[t=%v][c=%v]: msg=\"headers_add allocation error\", err=%v", td.id, c.socket, alloc_err)
				invalid_request(c, .Internal_Server_Error)
				return
			}
		}
	}

	on_headers :: proc(c: ^Connection) {
		log.debugf("http[t=%v][c=%v]: msg=\"got headers\"", td.id, c.socket)

		if !validate_headers(c) {
			invalid_request(c, .Bad_Request)
			return
		}

		_headers_set_readonly(&c.req.headers)

		// // Automatically respond with a continue status when the client has the Expect: 100-continue header.
		if expect, ok := headers_get(c.req.headers, "expect");
			ok && expect == "100-continue" && !td.s.opts.no_auto_expect_continue {
			c.res.status = .Continue
			respond(&c.res)
			return
		}

		// An options request with the "*" is a no-op/ping request to
		// check for server capabilities and should not be sent to handlers.
		if c.req.line.method == .Options && c.req.line.target == "*" {
			c.res.status = .OK
			respond(&c.res)
		} else {
			// Give the handler this request as a GET, since the HTTP spec
			// says a HEAD is identical to a GET but just without writing the body,
			// handlers shouldn't have to worry about it.
			if c.req.line.method == .Head && !td.s.opts.no_redirect_head_to_get {
				c.req.is_redirected_head = true
				c.req.line.method = .Get
			}

			context.temp_allocator = temp_allocator(c) 
			c.ctx.vars.allocator   = transaction_allocator(c)
			c.res.status = .OK
			td.s.opts.handler.handle(&td.s.opts.handler, &c.ctx.req, &c.ctx.res)
		}
	}

	validate_headers :: proc(c: ^Connection) -> bool {
		// RFC 7230 3.3.3: If a Transfer-Encoding header field
		// is present in a request and the chunked transfer coding is not
		// the final encoding, the message body length cannot be determined
		// reliably; the server MUST respond with the 400 (Bad Request)
		// status code and then close the connection.
		if enc_header, ok := headers_get(c.req.headers, "transfer-encoding"); ok {
			if !strings.has_suffix(enc_header, "chunked") {
				log.warnf("http[t=%v][c=%v]: msg=\"Transfer-Encoding does not end with chunked\"", td.id, c.socket)
				return false
			}

			// RFC 7230 3.3.3: If a message is received with both a Transfer-Encoding and a
			// Content-Length header field, the Transfer-Encoding overrides the
			// Content-Length.  Such a message might indicate an attempt to
			// perform request smuggling (Section 9.5) or response splitting
			// (Section 9.4) and ought to be handled as an error.
			headers_delete(c.req.headers, "content-length")
		} else {
			// RFC 7230 3.3.3: If a message is received without Transfer-Encoding and with
			// either multiple Content-Length header fields having differing
			// field-values or a single Content-Length header field having an
			// invalid value, then the message framing is invalid and the
			// recipient MUST treat it as an unrecoverable error.
			content_length_n := 0
			iter := headers_get_all_iterator(&c.req.headers, "content-length")
			for _ in headers_get_all_iter(&iter) {
				content_length_n += 1
				if content_length_n > 1 {
					log.warnf("http[t=%v][c=%v]: msg=\"expected at most one Content-Length header\"", td.id, c.socket)
					return false
				}
			}
		}

		// RFC 7230 5.4: Server MUST respond with 400 to any request
		// with multiple "Host" header fields.
		{
			host_n := 0
			iter := headers_get_all_iterator(&c.req.headers, "host")
			for _ in headers_get_all_iter(&iter) {
				host_n += 1
				if host_n > 1 {
					break
				}
			}

			// RFC 7230 5.4: A server MUST respond with a 400 (Bad Request) status code to any
			// HTTP/1.1 request message that lacks a Host header field.
			if host_n != 1 {
				log.warnf("http[t=%v][c=%v]: msg=\"expected exactly one Host header\"", td.id, c.socket)
				return false
			}
		}

		return true
	}
}

_serve :: proc(s: ^Server) {
	sync.one_shot_event_signal(&s.serve)
	_server_thread_serve(td)
	sync.wait(&s.running_threads)
}

/*
Assumes that the running operations have already been cleaned up.
*/
_destroy :: proc(s: ^Server) {
	nbio.acquire_thread_event_loop()
	defer nbio.release_thread_event_loop()

	if s.socket != {} {
		closed: bool
		nbio.close_poly(s.socket, &closed, proc(op: ^nbio.Operation, closed: ^bool) { closed^ = true })
		nbio.run_until(&closed)
	}

	if s.threads != nil {
		for &t in s.threads {
			thread.destroy(&t.thread)
		}
		delete(s.threads, s.allocator)
	}
}

listen_and_serve :: proc(s: ^Server) -> Server_Error {
	if s.allocator.procedure == nil {
		s.allocator = context.allocator
	}
	_acquire_event_loop(s) or_return
	if listen_err := _listen(s); listen_err != nil {
		switch err in listen_err {
		case nbio.Listen_Error:        return err
		case nbio.Create_Socket_Error: return err
		case nbio.Bind_Error:          return err
		}
	}
	if err := _setup_threads(s); err != nil { return .Allocation_Failed }
	// TODO: better
	if err := virtual.arena_init_growing(&s.temp_allocator_backing); err != nil { return .Allocation_Failed }
	_serve(s)
	_destroy(s)
	return nil
}

Scan_Cb :: #type proc(c: ^Connection)

NO_TIMEOUT :: nbio.NO_TIMEOUT

// TODO: way to free parts of what we scanned, some checkpoint system?
// TODO: the heading of the request (request line, headers, etc.) should never be freed.
// TODO: but a user may want to read part of the body and "free" it when done. (websockets for example can scan a message, handle it, free it).
// NOTE: could maybe be done with a way to switch the buffer we scan in, allowing switching it to `temp_allocator`.

scan_recv :: proc(c: ^Connection, timeout: time.Duration, cb: Scan_Cb) {
	timeout := timeout
	if timeout < 0 {
		timeout = nbio.NO_TIMEOUT
	} else if timeout == 0 {
		log.warnf("http[t=%v][c=%v]: recv error=%v", td.id, c.socket, nbio.TCP_Recv_Error.Timeout)
		invalid_request(c, .Request_Timeout)
		return
	}

	MIN :: 512

	to_recv := dynamic_unwritten(c.buf)
	if len(to_recv) < MIN {
		new_cap := max(MIN*2, 2*cap(c.buf))
		log.debugf("http[t=%v][c=%v]: prev_unwritten=%v, new_unwritten=%v", td.id, c.socket, len(to_recv), new_cap)
		new_buf, err := make([dynamic]byte, new_cap, transaction_allocator(c))
		assert(err == nil)
		left := c.buf[c.pos:]
		copy(new_buf[:], left)
		resize(&new_buf, len(left))
		c.pos = 0
		c.buf = new_buf
		to_recv = dynamic_unwritten(c.buf)
	}

	log.debugf("http[t=%v][c=%v]: recv=%v, timeout=%b", td.id, c.socket, len(to_recv), timeout)

	c.last_recv_start = nbio.now()
	c.recv = nbio.recv_poly2(c.socket, {to_recv}, c, cb, scan_on_recv, timeout=timeout)

	dynamic_unwritten :: proc(d: [dynamic]$E) -> []E  {
		return (cast([^]E)raw_data(d))[len(d):cap(d)]
	}

	dynamic_add_len :: proc(d: ^[dynamic]$E, to_add: int) {
		(transmute(^runtime.Raw_Dynamic_Array)d).len += to_add
		assert(len(d) <= cap(d))
	}

	scan_on_recv :: proc(op: ^nbio.Operation, c: ^Connection, cb: Scan_Cb) {
		c.recv = nil
		if op.recv.err != nil {
			log.warnf("http[t=%v][c=%v]: recv error=%v", td.id, c.socket, op.recv.err)
			switch op.recv.err.(nbio.TCP_Recv_Error) {
			case .Timeout:
				invalid_request(c, .Request_Timeout)
			case .Not_Connected, .Connection_Closed:
				connection_destroy(c)
			case .Network_Unreachable, .Insufficient_Resources, .Invalid_Argument, .Would_Block, .Interrupted, .Unknown, .None:
				fallthrough
			case:
				invalid_request(c, .Internal_Server_Error)
			}
			return
		}

		if op.recv.received == 0 {
			log.debugf("http[t=%v][c=%v]: msg=\"client disconnected\"", td.id, c.socket)
			connection_destroy(c)
			return
		}

		c.last_recv_dur = time.diff(c.last_recv_start, nbio.now())
		c.last_recv_n   = op.recv.received

		log.debugf("http[t=%v][c=%v]: received=%v/%v, duration=%b", td.id, c.socket, c.last_recv_n, len(op.recv.bufs[0]), c.last_recv_dur)

		dynamic_add_len(&c.buf, op.recv.received)

		cb(c)
	}
}

scan_line :: proc(c: ^Connection) -> (bs: []byte, ok: bool) {
	subject := c.buf[c.pos:]
	start := 0
	for {
		index := bytes.index_byte(subject[start:], '\r')
		if index < 0 {
			return
		}

		if len(subject) > index+1 && subject[index+1] == '\n' {
			c.pos += index+2
			bs = subject[:index]
			ok = true
			return
		}

		start = index+1
	}
}

scan_line_or_recv :: proc(c: ^Connection, timeout: time.Duration, cb: Scan_Cb) -> (bs: []byte, ok: bool) {
	bs, ok = scan_line(c)
	if !ok {
		scan_recv(c, timeout, cb)
	}
	return
}

scan_header_line_or_recv :: proc(c: ^Connection, cb: Scan_Cb) -> ([]byte, bool) {
	return scan_line_or_recv(c, get_timeout(c.last_recv_dur, &c.headers_quota, c.last_recv_n), cb)
}

scan_body_line_or_recv :: proc(c: ^Connection, cb: Scan_Cb) -> ([]byte, bool) {
	return scan_line_or_recv(c, get_timeout(c.last_recv_dur, &c.body_quota, c.last_recv_n), cb)
}

scan_n :: proc(c: ^Connection, n: int) -> (bs: []byte, ok: bool) {
	// TODO: make buffer big enough right away but with a max so a client can't get us to allocate huge things without actually sending it over too.
	subject := c.buf[c.pos:]
	if len(subject) < n {
		return
	}

	c.pos += n
	ok = true
	bs = subject[:n]
	return 
}

scan_n_or_recv :: proc(c: ^Connection, n: int, cb: Scan_Cb) -> (bs: []byte, ok: bool) {
	bs, ok = scan_n(c, n)
	if !ok {
		scan_recv(c, get_timeout(c.last_recv_dur, &c.body_quota, c.last_recv_n), cb)
	}
	return
}

//
// scan_header_n_or_recv :: proc(c: ^Connection, cb: Scan_Cb) -> ([]byte, bool) {
// }
//
// scan_body_n_or_recv :: proc(c: ^Connection, cb: Scan_Cb) -> ([]byte, bool) {
// }

// Parses the header and adds it to the headers if valid. The given string is copied.
header_parse :: proc(line: string) -> (key, value: string, ok: bool) #no_bounds_check {
	// Preceding spaces should not be allowed.
	(len(line) > 0 && line[0] != ' ') or_return

	colon := strings.index_byte(line, ':')
	(colon > 0) or_return

	// There must not be a space before the colon.
	(line[colon - 1] != ' ') or_return

	key   = line[:colon]
	value = strings.trim_space(line[colon + 1:])
	ok    = true
	return
}

// TODO: response_write_heading - writes the heading into the buffer
// TODO: response_send_heading - sends the heading buffer
// TODO: if user wants to respond with in-mem bytes, execute send with 2 buffers (heading, user's buffer)
// TODO: sendfile - sends heading and then sendfile
// TODO: chunked writer - can this work with the tracking of sends, wait for all sends
// TODO: track sends - if user sends heading and sends file, wait for both
// PERF: we could read the next request after "consume body" is done already, while response is still being sent
// TODO: do not send any body when it's a redirected head to get - no-op send calls

// TODO
send_heading :: send_response_heading

write_response_heading :: proc(res: ^Response) {
	if len(res.buf) > 0 {
		return
	}

	c := connection_of_response(res)

	log.debugf("http[t=%v][c=%v]: msg=\"writing response heading\"", td.id, c.socket)

	// PERF: to avoid resizes and reallocs of the buffer.
	// We could keep a list of buffers instead.

	// if c.req.is_redirected_head {
	// }

	w := buf_writer(&res.buf)

	MIN             :: len("HTTP/1.1 200 \r\ndate: \r\ncontent-length: 1000\r\n") + DATE_LENGTH
	AVG_HEADER_SIZE :: 20
	reserve_size    := MIN + (AVG_HEADER_SIZE * headers_len(res.headers))
	reserve(&res.buf, reserve_size)

	append(&res.buf, "HTTP/1.1 ")

	status := status_string(res.status)
	if len(status) > 0 {
		append(&res.buf, status)
	} else {
		_, err := io.write_int(w, int(res.status))
		assert(err == nil) // TODO
		append(&res.buf, " \r\n")
	}

	// Per RFC 9910 6.6.1 a Date header must be added in 2xx, 3xx, 4xx responses.
	if !headers_has(res.headers, "date") {
		append(&res.buf, "Date: ")
		append(&res.buf, ..td.date[:])
		append(&res.buf, "\r\n")
	}

	if response_needs_content_length(c) {
		if !headers_has(res.headers, "content-length") && !headers_has(res.headers, "transfer-encoding") {
			append(&res.buf, "Content-Length: 0\r\n")
		}
	}

	if response_must_close(c) && !headers_has(c.req.headers, "connection") {
		append(&res.buf, "Connection: close\r\n")
	}

	// TODO: think about if we need to do this here (skipping invalid headers).
	// TODO: where does it make sense to validate/sanitize?
	for i := 0; header, value in headers_iter(&res.headers, &i) {
		headers_valid_key(header) or_continue
		append(&res.buf, header)
		append(&res.buf, ": ")

		for value := value; part in header_value_iterator(&value) {
			append(&res.buf, part)
		}

		append(&res.buf, "\r\n")
	}

	// TODO: cookies

	append(&res.buf, "\r\n")

	// A server MUST NOT send a Content-Length header field in any response
	// with a status code of 1xx (Informational) or 204 (No Content).  A
	// server MUST NOT send a Content-Length header field in any 2xx
	// (Successful) response to a CONNECT request.
	response_needs_content_length :: proc(c: ^Connection) -> bool {
		if status_is_informational(c.res.status) || c.res.status == .No_Content {
			return false
		}

		if status_is_success(c.res.status) && c.req.line.method == .Connect {
			return false
		}

		return true
	}
}

Response_State :: enum {
	None,            // Send called: write heading, send both heading and given buffer. state is sent_heading
	Written_Heading, // Send called: send both heading and given buffer. state is sent_heading
	Sent_Heading,    // Send called: just send given content (add n)
	Responding,      // Send called: panic? Send callback: close transaction
}

// send: adds 1 to a counter
// if response heading isn't sent yet (state or some flag), send it first/together
// callback: removes 1 from the counter
// `respond`: set a flag/state that we are done
// check in callback if counter is 0 and we are done: cleanup connection

send_response_heading :: proc(res: ^Response) {
	write_response_heading(res)

	c := connection_of_response(res)

	// TODO: track send

	// TODO: quota
	nbio.send_poly(c.socket, {res.buf[:]}, c, proc(op: ^nbio.Operation, c: ^Connection) {
		log.debugf("http[t=%v][c=%v]: sent=%v, err=%v", td.id, c.socket, op.send.sent, op.send.err)
	})
}

send :: proc(res: ^Response, bufs: [][]byte) {
	// TODO: track send
	// TODO: quota

	c := connection_of_response(res)

	nbio.send_poly(c.socket, bufs, c, proc(op: ^nbio.Operation, c: ^Connection) {
		log.debugf("http[t=%v][c=%v]: sent=%v, err=%v", td.id, c.socket, op.send.sent, op.send.err)
	})
}

// TODO: send response heading if needed
// TODO: track sends, wait for all pending sends to complete and initiate a close
respond :: proc(res: ^Response) {
	write_response_heading(res)

	c := connection_of_response(res)

	// TODO: quota
	nbio.send_poly(c.socket, {res.buf[:]}, c, on_send)

	// TODO: consume body
}

on_send :: proc(op: ^nbio.Operation, c: ^Connection) {
	sent: int
	err: nbio.Send_File_Error
	#partial switch op.type {
	case .Send:
		sent = op.send.sent
		if op.send.err != nil {
			err = op.send.err.(nbio.TCP_Send_Error)
		}
	case .Send_File:
		sent = op.sendfile.sent
		err  = op.sendfile.err
	case:
		unimplemented("on_send type")
	}

	if err != nil {
		log.warnf("http[t=%v][c=%v]: msg=\"send error\", err=%v", td.id, c.socket, err)

		// TODO: some of these errors don't need a graceful shutdown
	}

	// TODO: if consume body still going, wait for that

	if err != nil || response_must_close(c) || response_has_close(&c.res) {
		connection_close(c)
		return
	}

	// TODO: informational/take over connection

	log.debugf("http[t=%v][c=%v]: sent=%v, msg=\"response sent, serving next request\"", td.id, sent, c.socket)

	_serve_connection(c)

	response_has_close :: proc(res: ^Response) -> bool {
		if connection, _ := headers_get(res.headers, "connection"); connection == "close" {
			return true
		}

		return false
	}
}

// Determines if the connection needs to be closed after sending the response.
response_must_close :: proc(c: ^Connection) -> bool {
	// If the request we are responding to indicates it is closing the connection, close our side too.
	if connection, _:= headers_get(c.req.headers, "connection"); connection == "close" {
		return true
	}

	// HTTP 1.0 does not have persistent connections.
	line := c.req.line
	if line.version == {1, 0} {
		return true
	}

	return false
}

@(private)
date_update :: proc(_: ^nbio.Operation) {
	nbio.timeout(time.Second, date_update)
	date_write(td.date[:], nbio.now())
}
