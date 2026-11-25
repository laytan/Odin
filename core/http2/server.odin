#+vet explicit-allocators
package http

import "base:intrinsics"
import "base:runtime"
import "base:sanitizer"

import "core:container/xar"
import "core:io"
import "core:log"
import "core:nbio"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

// PERF: we can pre-compute common header key hashes

Server :: struct {
	allocator:       runtime.Allocator,
	opts:            Server_Options,
	socket:          nbio.TCP_Socket,
	threads:         []Server_Thread,
	serve:           sync.One_Shot_Event,
	running_threads: sync.Wait_Group,
	shutting_down:   bool,
	shutdown_mutex:  sync.Mutex,
	_shutdown_op:    ^nbio.Operation,
	_has_event_loop: bool,
}

Endpoint :: nbio.Endpoint

Server_Options :: struct {
	address:              nbio.Address,
	// nil defaults to DEFAULT_PORT; use OS_ASSIGNED_PORT (0) for an ephemeral OS-assigned port.
	port:                 Maybe(int),
	backlog:              int,
	thread_count:         int,
	// Slice backing array must outlive `listen_and_serve`.
	handlers:             []Handler,
	thread_initializer:   proc(),
	thread_deinitializer: proc(),

	request_quota:  Quota,
	body_quota:     Quota,
	response_quota: Quota,
	// Maximum number of request headers (and chunked trailers) accepted. Zero defaults to DEFAULT_MAX_HEADERS; negative disables the limit.
	max_headers: int,
}

DEFAULT_BACKLOG     :: 1000
DEFAULT_ADDRESS     :: nbio.IP4_Loopback
DEFAULT_PORT        :: 8080
OS_ASSIGNED_PORT    :: 0
DEFAULT_MAX_HEADERS :: 128

General_Error :: enum i32 {
	None,
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

// Applies default request, body, and response quotas for zero-valued Server_Options fields.
@(private="file")
_server_options_apply_defaults :: proc(opts: ^Server_Options) {
	if opts.request_quota == {} {
		opts.request_quota = DEFAULT_HEADERS_QUOTA
	}
	if opts.body_quota == {} {
		opts.body_quota = DEFAULT_BODY_QUOTA
	}
	if opts.response_quota == {} {
		opts.response_quota = DEFAULT_SEND_QUOTA
	}
	if opts.max_headers == 0 {
		opts.max_headers = DEFAULT_MAX_HEADERS
	}
}

make_server :: proc(opts: Server_Options, allocator := context.allocator) -> Server {
	s := Server{
		allocator = allocator,
		opts      = opts,
	}
	_server_options_apply_defaults(&s.opts)
	return s
}

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
			s.opts.address != nil ? s.opts.address : DEFAULT_ADDRESS,
			s.opts.port.? or_else DEFAULT_PORT,
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
	thread:      ^thread.Thread,
	event_loop:  ^nbio.Event_Loop,
	curr_accept: ^nbio.Operation, // PERF: check if having multiple increases performance.
	curr_date:   ^nbio.Operation,
	id:          int,
	connections: xar.Freelist_Array(Connection, 8),
	date:             [DATE_LENGTH]byte,
	free_arenas:      [BUCKETS]_Arena_Bucket,
	arena_trim_ticks: u8,
}

/*
Tracks whether a `Connection` is destroyed or detached while a user callback is on the call stack.

Callbacks (`Scan_Cb`, `Body_Cb`, `Send_Callback`) may synchronously release `c` back to the thread's
connection freelist (via `connection_detach` or an OOM path calling `_connection_destroy`). Because `c`
itself is freed/reusable once released, callers that touch `c` after invoking a callback link a
stack-allocated `_Destroy_Flag` onto `c._destroy_flag` before the call. If `_connection_release` runs
at any nesting depth, it walks `c._destroy_flag` and marks every active stack frame's `destroyed = true`
so outer frames can abort immediately on unwind without dereferencing `c`.
*/
@(private)
_Destroy_Flag :: struct {
	destroyed: bool,
	prev:      ^_Destroy_Flag,
}

@(private)
_destroy_flag_push :: #force_inline proc(c: ^Connection, flag: ^_Destroy_Flag) {
	flag^ = {prev = c._destroy_flag}
	c._destroy_flag = flag
}

@(private)
_destroy_flag_pop :: #force_inline proc(c: ^Connection, flag: ^_Destroy_Flag) -> (destroyed: bool) {
	if flag.destroyed {
		return true
	}
	c._destroy_flag = flag.prev
	return false
}

Connection :: struct {
	socket:            nbio.TCP_Socket,
	remote:            nbio.Endpoint,
	scanner:           Scanner,
	curr_recv:         ^nbio.Operation,
	_destroy_flag:     ^_Destroy_Flag,
	transaction_arena: Arena,
	temp_arena:        Arena,
	using ctx:         Ctx,
}

transaction_allocator_destroy :: proc(c: ^Connection) {
	arena_destroy(&c.transaction_arena)
}

temp_allocator_destroy :: proc(c: ^Connection) {
	arena_destroy(&c.temp_arena)
}

transaction_allocator_from_connection :: proc(c: ^Connection) -> runtime.Allocator {
	return _arena_allocator(&c.transaction_arena, false)
}

transaction_allocator_from_ctx :: proc(ctx: ^Ctx) -> runtime.Allocator {
	return transaction_allocator_from_connection(_connection_of_context(ctx))
}

transaction_allocator :: proc {
	transaction_allocator_from_connection,
	transaction_allocator_from_ctx,
}

temp_allocator_from_connection :: proc(c: ^Connection) -> runtime.Allocator {
	return arena_allocator(&c.temp_arena)
}

temp_allocator_from_ctx :: proc(ctx: ^Ctx) -> runtime.Allocator {
	return temp_allocator_from_connection(_connection_of_context(ctx))
}

temp_allocator :: proc {
	temp_allocator_from_connection,
	temp_allocator_from_ctx,
}

Ctx :: struct {
	req:   Request,
	res:   Response,
	_vars: [dynamic]_Context_Var,
}

_Context_Var :: struct {
	id:  typeid,
	val: rawptr,
}

context_add :: proc(ctx: ^Ctx, var: $T) -> (val: ^T, err: runtime.Allocator_Error) #optional_allocator_error {
	val = new_clone(var, transaction_allocator(ctx)) or_return
	_, err = append(&ctx._vars, _Context_Var{
		id  = T,
		val = val,
	})
	if err != nil {
		return nil, err
	}
	return val, nil
}

context_get :: proc(ctx: ^Ctx, $T: typeid) -> ^T {
	#reverse for var in ctx._vars {
		if var.id == T {
			return (^T)(var.val)
		}
	}

	return nil
}

Request :: struct {
	progress:          Progression,
	line:              Requestline,
	has_consumed_body: bool,
	headers:           Headers,
}

@(private)
_Deferred :: struct {
	trampoline: proc(ctx: ^Ctx, cb: rawptr, data: rawptr),
	cb:         rawptr,
	data:       rawptr,
}

Response :: struct {
	progress: Progression,
	status:   Status,
	headers:  Headers,
	sent:     int,

	_buf:       [dynamic]byte,
	_deferred:  [dynamic]_Deferred,
	_last_send: time.Time,
	_sends:     int,
	_state:     enum {
		None,
		Handling,
		Sending,  // send or send_file is called at least once (and heading is sent).
		Sent,     // respond was called.
		Error,
	},
}

// Overrides the quota applied to receiving the remaining request headers/body.
// The given pointer must live as long as the transaction.
request_set_quota :: proc(req: ^Request, quota: ^Quota) {
	progression_set_quota(&req.progress, quota)
}

// Overrides the quota applied to sending the response.
// The given pointer must live as long as the transaction.
response_set_quota :: proc(res: ^Response, quota: ^Quota) {
	progression_set_quota(&res.progress, quota)
}

response_defer :: proc {
	response_defer_proc,
	response_defer_with_data,
}

response_defer_proc :: proc(ctx: ^Ctx, deferred: proc(ctx: ^Ctx)) -> runtime.Allocator_Error {
	assert(deferred != nil, "nil response_defer proc")
	trampoline :: proc(ctx: ^Ctx, cb: rawptr, _: rawptr) {
		(proc(ctx: ^Ctx))(cb)(ctx)
	}
	_, err := append(&ctx.res._deferred, _Deferred{
		trampoline = trampoline,
		cb         = rawptr(deferred),
	})
	return err
}

response_defer_with_data :: proc(ctx: ^Ctx, data: $T, deferred: proc(ctx: ^Ctx, data: T)) -> runtime.Allocator_Error {
	assert(deferred != nil, "nil response_defer proc")
	when size_of(T) <= size_of(rawptr) {
		packed: rawptr
		when size_of(T) > 0 {
			data := data
			intrinsics.mem_copy(&packed, &data, size_of(T))
		}
		trampoline :: proc(ctx: ^Ctx, cb: rawptr, data: rawptr) {
			val: T
			when size_of(T) > 0 {
				data := data
				intrinsics.mem_copy(&val, &data, size_of(T))
			}
			(proc(ctx: ^Ctx, data: T))(cb)(ctx, val)
		}
		_, err := append(&ctx.res._deferred, _Deferred{
			trampoline = trampoline,
			cb         = rawptr(deferred),
			data       = packed,
		})
		return err
	} else {
		copy_ptr := new_clone(data, transaction_allocator(ctx)) or_return
		trampoline :: proc(ctx: ^Ctx, cb: rawptr, data: rawptr) {
			(proc(ctx: ^Ctx, data: T))(cb)(ctx, (^T)(data)^)
		}
		_, err := append(&ctx.res._deferred, _Deferred{
			trampoline = trampoline,
			cb         = rawptr(deferred),
			data       = copy_ptr,
		})
		return err
	}
}

@(thread_local)
td: ^Server_Thread

@(private)
_thread_id :: #force_inline proc() -> int {
	return td != nil ? td.id : 0
}

_setup_threads :: proc(s: ^Server) -> runtime.Allocator_Error {
	thread_count := max(1, s.opts.thread_count > 0 ? s.opts.thread_count : os.get_processor_core_count())
	s.threads = make([]Server_Thread, thread_count, s.allocator) or_return

	for &server_thread in s.threads {
		xar.init(&server_thread.connections, s.allocator)
	}

	for &server_thread, i in s.threads[1:] {
		server_thread.thread = thread.create_and_start_with_poly_data3(s, &server_thread, i+2, _server_thread, context)
		if server_thread.thread == nil {
			return .Out_Of_Memory
		}
	}

	main_thread := &s.threads[0]
	main_thread.id = 1
	main_thread.s = s
	td = main_thread

	return nil
}

_server_thread :: proc(s: ^Server, thread: ^Server_Thread, id: int) {
	defer if context.temp_allocator.procedure == runtime.default_temp_allocator_proc {
		runtime.default_temp_allocator_destroy(auto_cast context.temp_allocator.data)
	}

	thread.s = s
	thread.id = id
	td = thread
	defer td = nil

	if err := nbio.acquire_thread_event_loop(); err != nil {
		// Should not happen AFAIK, the main thread has already successfully
		// done this, so .Unsupported is handled, could fail to allocate so lets
		// just log it and exit the thread.
		log.errorf("http[t=%v]: msg=\"server thread could not initialize nbio\", err=%v", id, err)
		return
	}
	defer nbio.release_thread_event_loop()

	_server_thread_serve(thread)
}

_server_thread_serve :: proc(thread: ^Server_Thread) {
	if thread.s.opts.thread_initializer != nil {
		thread.s.opts.thread_initializer()
	}

	sync.one_shot_event_wait(&thread.s.serve)

	sync.wait_group_add(&thread.s.running_threads, 1)
	defer sync.wait_group_done(&thread.s.running_threads)

	sync.mutex_lock(&thread.s.shutdown_mutex)
	thread.event_loop = nbio.current_thread_event_loop()
	sync.mutex_unlock(&thread.s.shutdown_mutex)

	if sync.atomic_load(&thread.s.shutting_down) {
		_server_thread_shutdown(thread)
		return
	}

	log.debugf("http[t=%v]: msg=\"serving\"", thread.id)

	thread.curr_accept = nbio.accept_poly(thread.s.socket, thread, _on_accept)

	date_update(nil)

	for {
		if sync.atomic_load(&thread.s.shutting_down) {
			_server_thread_shutdown(thread)
			break
		}

		err := nbio.tick()
		free_all(context.temp_allocator)
		if err != nil {
			log.errorf("http[t=%v]: msg=\"event loop tick error\" err=%v", thread.id, err)
			_server_thread_shutdown(thread)
			break
		}
	}
}

_is_scanning_request_line :: proc(c: ^Connection) -> bool {
	return c.res._state == .None && c.req.line.version == {}
}

_connection_is_idle :: proc(c: ^Connection) -> bool {
	return _is_scanning_request_line(c) && c.scanner.read_head == c.scanner.write_head && c.res._sends == 0
}

_server_thread_shutdown :: proc(thread: ^Server_Thread) {
	nbio.remove(thread.curr_accept)
	thread.curr_accept = nil

	nbio.remove(thread.curr_date)
	thread.curr_date = nil

	iter := xar.freelist_iterator(&thread.connections)
	for c, _ in xar.freelist_iterate_by_ptr(&iter) {
		if _connection_is_idle(c) {
			_connection_destroy(c)
		}
	}

	for {
		iter = xar.freelist_iterator(&thread.connections)
		if _, _, has_active := xar.freelist_iterate_by_ptr(&iter); !has_active {
			break
		}

		err := nbio.tick()
		free_all(context.temp_allocator)
		if err != nil {
			log.errorf("http[t=%v]: msg=\"event loop tick error\" err=%v", thread.id, err)
			break
		}
	}

	if err := nbio.tick(timeout = 0); err != nil {
		log.errorf("http[t=%v]: msg=\"event loop tick error\" err=%v", thread.id, err)
	}
	free_all(context.temp_allocator)

	if thread.s.opts.thread_deinitializer != nil {
		thread.s.opts.thread_deinitializer()
	}

	sync.mutex_lock(&thread.s.shutdown_mutex)
	thread.event_loop = nil
	sync.mutex_unlock(&thread.s.shutdown_mutex)
}

/*
Initiates a graceful shutdown of `s`: stops accepting new connections, closes idle keep-alive
connections immediately, drains in-flight requests, and runs each server thread's
`thread_deinitializer` before `listen_and_serve` returns.

Safe to call from any normal thread, including a request handler or worker thread.
Not safe to call directly from a POSIX signal handler because it acquires `s.shutdown_mutex`;
use `server_shutdown_async` from signal handlers instead.
*/
server_shutdown :: proc(s: ^Server) {
	sync.mutex_lock(&s.shutdown_mutex)
	defer sync.mutex_unlock(&s.shutdown_mutex)

	sync.atomic_store(&s.shutting_down, true)
	for &thread in s.threads {
		if thread.event_loop != nil {
			nbio.wake_up(thread.event_loop)
		}
	}
}

/*
Contextless, async-signal-safe version of `server_shutdown`.

Enqueues a graceful shutdown onto the server's main event loop via `nbio.exec_urgent` without
locking mutexes or allocating, making it signal safe.

Returns `true` if shutdown was triggered by this call, or `false` if the server is not currently
serving, shutdown was already requested (e.g. a second Ctrl-C), or the event loop queue is full.

Example:
	import "core:terminal"

	server := http.make_server()

	terminal.set_termination_handler(proc "contextless" (server: rawptr) -> bool {
		return http.server_shutdown_async((^http.Server)(server))
	}, &server)
*/
server_shutdown_async :: proc "contextless" (s: ^Server) -> bool {
	if sync.atomic_load(&s.shutting_down) {
		return false
	}
	if op := sync.atomic_exchange(&s._shutdown_op, nil); op != nil {
		return nbio.exec_urgent(op)
	}
	return false
}

ACCEPT_RETRY_DELAY :: 50 * time.Millisecond

_on_accept :: proc(op: ^nbio.Operation, thread: ^Server_Thread) {
	thread.curr_accept = nil

	if sync.atomic_load(&thread.s.shutting_down) {
		if op.accept.err == nil && op.accept.client != {} {
			nbio.close(op.accept.client)
		}
		return
	}

	if op.accept.err != nil {
		switch op.accept.err {
		case .None:
			unreachable()
		case .Aborted, .Interrupted, .Would_Block:
			log.debugf("http[t=%v]: msg=\"transient accept error, retrying\", err=%v", thread.id, op.accept.err)
			thread.curr_accept = nbio.accept_poly(thread.s.socket, thread, _on_accept)
		case .Timeout:
			log.warnf("http[t=%v]: msg=\"accept timed out, retrying\", err=%v", thread.id, op.accept.err)
			thread.curr_accept = nbio.accept_poly(thread.s.socket, thread, _on_accept)
		case .Insufficient_Resources, .Network_Unreachable, .Unknown:
			log.warnf("http[t=%v]: msg=\"accept error, backing off\", err=%v, retry_in=%v", thread.id, op.accept.err, ACCEPT_RETRY_DELAY)
			thread.curr_accept = nbio.timeout_poly(ACCEPT_RETRY_DELAY, thread, proc(_: ^nbio.Operation, thread: ^Server_Thread) {
				thread.curr_accept = nil
				if sync.atomic_load(&thread.s.shutting_down) {
					return
				}
				thread.curr_accept = nbio.accept_poly(thread.s.socket, thread, _on_accept)
			})
		case .Invalid_Argument, .Unsupported_Socket, .Not_Listening:
			log.errorf("http[t=%v]: msg=\"fatal accept error, stopping accept loop\", err=%v", thread.id, op.accept.err)
		}
		return
	}

	thread.curr_accept = nbio.accept_poly(thread.s.socket, thread, _on_accept)

	log.debugf("http[t=%v][c=%v]: msg=\"accepted connection\", from=%v", thread.id, op.accept.client, op.accept.client_endpoint)

	c, err := xar.push(&thread.connections, Connection{
		socket = op.accept.client,
		remote = op.accept.client_endpoint,
	})
	if err != nil {
		log.errorf("http[t=%v][c=%v]: msg=\"failed to push connection\", err=%v", thread.id, op.accept.client, err)
		nbio.close(op.accept.client)
		return
	}

	_serve_connection(c)
}

// How long to wait before actually closing a connection.
// This is to make sure the client can fully receive the response.
CONN_CLOSE_DELAY :: time.Millisecond * 500

// Sends a FIN, receives for at most CONN_CLOSE_DELAY (making sure the client gets our close / waiting for it to close too).
// Ultimately destroying the connection.
connection_close :: proc(c: ^Connection) {
	c.res._state    = .Error
	c.scanner.scan = {}
	nbio.remove(c.curr_recv)
	c.curr_recv = nil
	if c.res._sends > 0 {
		return
	}
	if c.socket == {} {
		_connection_destroy(c)
		return
	}

	log.debugf("http[t=%v][c=%v]: msg=\"shutdown\"", td.id, c.socket)
	nbio.shutdown(c.socket, .Send)

	@(static) junk: [1024]byte
	c.req.progress.timeout = CONN_CLOSE_DELAY
	c.scanner.last_recv_start = now()
	c.curr_recv = nbio.recv_poly(c.socket, {junk[:]}, c, on_recv, all=true, timeout=c.req.progress.timeout)

	on_recv :: proc(op: ^nbio.Operation, c: ^Connection) {
		context.temp_allocator = temp_allocator(c)
		c.curr_recv = nil
		c.req.progress.timeout -= since(c.scanner.last_recv_start)
		log.debugf("http[t=%v][c=%v]: err=%v, received=%v, closing_for=%v", td.id, c.socket, op.recv.err, op.recv.received, CONN_CLOSE_DELAY-c.req.progress.timeout)
		if op.recv.err == nil && op.recv.received > 0 {
			if c.req.progress.timeout > 0 {
				c.scanner.last_recv_start = now()
				c.curr_recv = nbio.recv_poly(c.socket, {junk[:]}, c, on_recv, all=true, timeout=c.req.progress.timeout)
				return
			}
		}

		_connection_destroy(c)
	}
}

@(private="file")
_connection_run_deferred :: proc(c: ^Connection) {
	if len(c.res._deferred) == 0 {
		return
	}

	prev_temp := context.temp_allocator
	context.temp_allocator = temp_allocator(c)
	defer context.temp_allocator = prev_temp

	destroy_flag: _Destroy_Flag
	_destroy_flag_push(c, &destroy_flag)

	for len(c.res._deferred) > 0 {
		deferred := pop(&c.res._deferred)
		log.debugf("http[t=%v][c=%v]: msg=\"running defer\", defer=%v", td.id, c.socket, deferred.cb)
		deferred.trampoline(&c.ctx, deferred.cb, deferred.data)
		assert(!destroy_flag.destroyed, "cannot destroy or detach connection inside response_defer")
	}

	_destroy_flag_pop(c, &destroy_flag)
}

@(private="file")
_connection_release :: proc(c: ^Connection) {
	nbio.remove(c.curr_recv)
	c.curr_recv = nil
	c.scanner.scan = {}
	for flag := c._destroy_flag; flag != nil; flag = flag.prev {
		flag.destroyed = true
	}
	c._destroy_flag = nil

	_connection_run_deferred(c)

	temp_allocator_destroy(c)
	transaction_allocator_destroy(c)
	// if mem_use > 0 {
	// 	log.debugf("http[t=%v][c=%v]: msg=\"request cleaned up\", mem_use=%M", td.id, c.socket, mem_use)
	// }

	// `xar.linear_search` checks chunk pointer ranges (O(log N)), not individual connections.
	idx, ok := xar.linear_search(&td.connections, c)
	assert(ok)
	xar.release(&td.connections, idx)
}

@(private)
_connection_abort :: proc(c: ^Connection, skip_graceful := true) {
	c.scanner.scan = {}
	c.res._state   = .Error
	_check_send_done(c, skip_graceful = skip_graceful)
}

_connection_destroy :: proc(c: ^Connection) {
	assert(c.res._sends == 0, "cannot destroy connection while sends are in flight")
	log.debugf("http[t=%v][c=%v]: msg=\"destroy\"", td.id, c.socket)
	sock := c.socket
	_connection_release(c)
	if sock != {} {
		nbio.close(sock)
	}
}

remote_endpoint :: proc(ctx: ^Ctx) -> nbio.Endpoint {
	return _connection_of_context(ctx).remote
}

// Removes the connection from the server pool without closing the socket, returning the underlying
// socket and a copy of any unread bytes still buffered in the scanner.
connection_detach :: proc(ctx: ^Ctx, allocator := context.allocator) -> (socket: nbio.TCP_Socket, buffered: []byte, err: runtime.Allocator_Error) {
	c := _connection_of_context(ctx)
	assert(c.res._sends == 0, "cannot detach connection while sends are in flight")
	assert(allocator.data != &c.temp_arena && allocator.data != &c.transaction_arena, "cannot allocate detached buffer from connection's arena")

	unread := c.scanner.buf[c.scanner.read_head:c.scanner.write_head]
	if len(unread) > 0 {
		buffered, err = make([]byte, len(unread), allocator)
		if err != nil {
			return
		}
		copy(buffered, unread)
	}

	log.debugf("http[t=%v][c=%v]: msg=\"detach\", buffered=%v", td.id, c.socket, len(buffered))
	socket = c.socket
	_connection_release(c)
	return
}

invalid_request :: proc(c: ^Connection, status: Status) {
	c.scanner.scan = {}
	if c.res._state != .None && c.res._state != .Handling {
		c.res._state = .Error
		_check_send_done(c)
		return
	}
	log.warnf("http[t=%v][c=%v]: status=%v, msg=\"invalid request\"", td.id, c.socket, status)
	c.res.status = status
	headers_set(&c.res.headers, "connection", "close")
	respond(&c.ctx)
}

_serve_connection :: proc(c: ^Connection) {
	backing := _arena_backing_allocator(td.s)
	c.temp_arena.c              = c
	c.temp_arena.backing        = backing
	c.transaction_arena.c       = c
	c.transaction_arena.backing = backing

	if err := scanner_reset(&c.scanner, c); err != nil {
		log.errorf("http[t=%v][c=%v]: msg=\"scanner_reset allocation error\", err=%v", td.id, c.socket, err)
		_connection_destroy(c)
		return
	}
	temp_allocator_destroy(c)

	c.ctx = {}

	allocator := transaction_allocator(c)

	progression_init(&c.req.progress, &td.s.opts.request_quota)
	if c.scanner.write_head > 0 {
		progression_update(&c.req.progress, c.scanner.write_head, 0)
	}
	progression_init(&c.res.progress, &td.s.opts.response_quota)

	c.req.headers.allocator  = allocator
	c.res.headers.allocator  = allocator
	c._vars.allocator         = allocator
	c.res._buf.allocator      = allocator
	c.res._deferred.allocator = allocator

	scan_line(&c.scanner, on_rline1)
}

on_rline1 :: proc(c: ^Connection, line: []byte) {
	if len(line) == 0 {
		scan_line(&c.scanner, on_rline)
		return
	}

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
		return
	}

	if line.version.major != 1 || line.version.minor > 1 {
		log.warnf("http[t=%v][c=%v]: version=%v.%v, status=%v", td.id, c.socket, line.version.major, line.version.minor, Status.HTTP_Version_Not_Supported)
		invalid_request(c, .HTTP_Version_Not_Supported)
		return
	}

	log.debugf("http[t=%v][c=%v]: method=%v, target=%q, version=%v.%v", td.id, c.socket, line.method, line.target, line.version.major, line.version.minor)
	c.req.line = line

	scan_line(&c.scanner, on_header)
}

on_header :: proc(c: ^Connection, line: []byte) {
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

	if !_request_add_header(c, key, value) {
		return
	}

	scan_line(&c.scanner, on_header)
}

// Enforces max_headers and appends a parsed header/trailer to c.req.headers.
_request_add_header :: proc(c: ^Connection, key, val: string) -> bool {
	if td.s.opts.max_headers > 0 && headers_len(c.req.headers) >= td.s.opts.max_headers {
		invalid_request(c, .Request_Header_Fields_Too_Large)
		return false
	}

	if alloc_err := headers_add(&c.req.headers, key, val); alloc_err != nil {
		log.errorf("http[t=%v][c=%v]: msg=\"headers_add allocation error\", err=%v", td.id, c.socket, alloc_err)
		invalid_request(c, .Internal_Server_Error)
		return false
	}

	return true
}

on_headers :: proc(c: ^Connection) {
	log.debugf("http[t=%v][c=%v]: msg=\"got headers\"", td.id, c.socket)

	if !validate_headers(c) {
		invalid_request(c, .Bad_Request)
		return
	}

	c.res._state = .Handling
	progression_reset(&c.req.progress, &td.s.opts.body_quota)
	_headers_set_readonly(&c.req.headers)

	// An options request with the "*" is a no-op/ping request to
	// check for server capabilities and should not be sent to handlers.
	if c.req.line.method == .Options && c.req.line.target == "*" {
		c.res.status = .OK
		respond(&c.ctx)
	} else {
		context.temp_allocator = temp_allocator(c)
		c.ctx._vars.allocator   = transaction_allocator(c)
		c.res.status = .OK
		assert(len(td.s.opts.handlers) > 0, "HTTP server does not have a request handler set")
		handle(td.s.opts.handlers, &c.ctx)
	}
}

validate_headers :: proc(c: ^Connection) -> bool {
	// RFC 9112 6.1 / 6.3: Inspect all Transfer-Encoding headers; accept only a single "chunked" coding on HTTP/1.1.
	te_n := 0
	{
		iter := headers_get_all_iterator(&c.req.headers, "transfer-encoding")
		for enc_header in headers_get_all_iter(&iter) {
			te_n += 1
			if te_n > 1 {
				log.warnf("http[t=%v][c=%v]: msg=\"expected at most one Transfer-Encoding header\"", td.id, c.socket)
				return false
			}

			if !_headers_eq(enc_header, "chunked") {
				log.warnf("http[t=%v][c=%v]: msg=\"unsupported Transfer-Encoding header\", value=%q", td.id, c.socket, enc_header)
				return false
			}
		}
	}

	if te_n > 0 && c.req.line.version != {1, 1} {
		log.warnf("http[t=%v][c=%v]: msg=\"Transfer-Encoding requires HTTP/1.1\"", td.id, c.socket)
		return false
	}

	// RFC 9112 6.3: Reject requests containing both Transfer-Encoding and Content-Length,
	// multiple Content-Length headers, or an invalid Content-Length value.
	clen := 0
	{
		content_length_n := 0
		iter := headers_get_all_iterator(&c.req.headers, "content-length")
		for cl_val in headers_get_all_iter(&iter) {
			if te_n > 0 {
				log.warnf("http[t=%v][c=%v]: msg=\"Transfer-Encoding and Content-Length both present\"", td.id, c.socket)
				return false
			}

			content_length_n += 1
			if content_length_n > 1 {
				log.warnf("http[t=%v][c=%v]: msg=\"expected at most one Content-Length header\"", td.id, c.socket)
				return false
			}

			parsed_cl, ok := parse_int(cl_val)
			if !ok {
				log.warnf("http[t=%v][c=%v]: msg=\"invalid Content-Length header\", value=%q", td.id, c.socket, cl_val)
				return false
			}
			clen = parsed_cl
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

	c.req.has_consumed_body = te_n == 0 && clen == 0
	return true
}

_serve :: proc(s: ^Server) {
	shutdown_op := nbio.prep_next_tick(proc(op: ^nbio.Operation) {
		server_shutdown((^Server)(op.user_data[0]))
	})
	shutdown_op.user_data[0] = s
	sync.atomic_store(&s._shutdown_op, shutdown_op)

	sync.one_shot_event_signal(&s.serve)
	_server_thread_serve(td)
	if op := sync.atomic_exchange(&s._shutdown_op, nil); op != nil {
		nbio.reattach(op)
	}
	sync.wait(&s.running_threads)
}

/*
Assumes that the running operations have already been cleaned up.
*/
_destroy :: proc(s: ^Server) {
	if s.threads != nil {
		sync.atomic_store(&s.shutting_down, true)
		sync.one_shot_event_signal(&s.serve)
		for &t in s.threads[1:] {
			if t.thread != nil {
				thread.destroy(t.thread)
				t.thread = nil
			}
		}
		for &t in s.threads {
			xar.freelist_destroy(&t.connections)
			_server_thread_free_arenas_destroy(&t)
		}
		if len(s.threads) > 0 && td == &s.threads[0] {
			td = nil
		}
		delete(s.threads, s.allocator)
		s.threads = nil
	}

	if s.socket != {} {
		if err := nbio.acquire_thread_event_loop(); err == nil {
			defer nbio.release_thread_event_loop()
			closed: bool
			nbio.close_poly(s.socket, &closed, proc(op: ^nbio.Operation, closed: ^bool) { closed^ = true })
			nbio.run_until(&closed)
		}
		s.socket = {}
	}

	if s._has_event_loop {
		nbio.release_thread_event_loop()
		s._has_event_loop = false
	}
}

_setup :: proc(s: ^Server) -> (err: Server_Error) {
	if s.allocator.procedure == nil {
		s.allocator = context.allocator
	}
	_server_options_apply_defaults(&s.opts)

	_acquire_event_loop(s) or_return
	s._has_event_loop = true
	defer if err != nil {
		_destroy(s)
	}

	if listen_err := _listen(s); listen_err != nil {
		switch lerr in listen_err {
		case nbio.Listen_Error:        return lerr
		case nbio.Create_Socket_Error: return lerr
		case nbio.Bind_Error:          return lerr
		}
	}

	headers_init_hash_secret()

	if thread_err := _setup_threads(s); thread_err != nil {
		return .Allocation_Failed
	}

	return nil
}

listen_and_serve :: proc(s: ^Server) -> Server_Error {
	_setup(s) or_return
	_serve(s)
	_destroy(s)
	return nil
}

// Validates HTTP field-value / chunk-line bytes, rejecting CTLs (< 0x20 except HTAB) and DEL (0x7F).
_valid_field_bytes :: proc(data: []byte) -> bool {
	for b in data {
		if (b < 0x20 && b != '\t') || b == 0x7f {
			return false
		}
	}
	return true
}

// Parses a header line into a validated token key and trimmed field value.
header_parse :: proc(line: string) -> (key, value: string, ok: bool) #no_bounds_check {
	colon := strings.index_byte(line, ':')
	(colon > 0) or_return

	key = line[:colon]
	headers_valid_key(key) or_return

	value = strings.trim(line[colon + 1:], " \t")
	_valid_field_bytes(transmute([]byte)value) or_return
	ok = true
	return
}

// PERF: we could read the next request after "consume body" is done already, while response is still being sent

write_response_heading :: proc(ctx: ^Ctx) -> (err: runtime.Allocator_Error) {
	append_str :: #force_inline proc(buf: ^[dynamic]byte, s: string) -> runtime.Allocator_Error {
		_, aerr := append(buf, s)
		return aerr
	}

	res := &ctx.res
	assert(len(res._buf) == 0)
	defer if err != nil {
		clear(&res._buf)
	}

	c := _connection_of_context(ctx)

	log.debugf("http[t=%v][c=%v]: msg=\"writing response heading\"", td.id, c.socket)

	// PERF: to avoid resizes and reallocs of the buffer.
	// We could keep a list of buffers instead.

	MIN             :: len("HTTP/1.1 200 \r\ndate: \r\ncontent-length: 1000\r\n") + DATE_LENGTH
	AVG_HEADER_SIZE :: 20
	reserve_size    := MIN + (AVG_HEADER_SIZE * headers_len(res.headers))
	_ = reserve(&res._buf, reserve_size)

	append_str(&res._buf, "HTTP/1.1 ") or_return

	status := status_string(res.status)
	if status == "" {
		buf: [20]byte
		status = strconv.write_int(buf[:], i64(res.status), 10)
	}
	append_str(&res._buf, status) or_return
	append_str(&res._buf, "\r\n") or_return

	// Per RFC 9910 6.6.1 a Date header must be added in 2xx, 3xx, 4xx responses.
	if !headers_has(res.headers, "date") {
		append_str(&res._buf, "Date: ") or_return
		if _, aerr := append(&res._buf, ..td.date[:]); aerr != nil {
			return aerr
		}
		append_str(&res._buf, "\r\n") or_return
	}

	if response_needs_content_length(c) {
		if !headers_has(res.headers, "content-length") && !headers_has(res.headers, "transfer-encoding") {
			append_str(&res._buf, "Content-Length: 0\r\n") or_return
		}
	}

	if response_must_close(c) && !headers_has(res.headers, "connection") {
		append_str(&res._buf, "Connection: close\r\n") or_return
	}

	for i := 0; header, value in headers_iter(&res.headers, &i) {
		headers_valid_key(header) or_continue
		append_str(&res._buf, header) or_return
		append_str(&res._buf, ": ") or_return

		for value := value; part in header_value_iterator(&value) {
			append_str(&res._buf, part) or_return
		}

		append_str(&res._buf, "\r\n") or_return
	}

	append_str(&res._buf, "\r\n") or_return

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

	_headers_set_readonly(&res.headers)
	return nil
}

Send_Error :: nbio.Send_File_Error

Send_Callback :: proc(ctx: ^Ctx, err: Send_Error)

@(private="file")
_send_error_skip_graceful_close :: proc(err: Send_Error) -> bool {
	tcp_err, is_tcp := err.(nbio.TCP_Send_Error)
	if !is_tcp {
		return false
	}

	#partial switch tcp_err {
	case .Connection_Closed, .Not_Connected, .Network_Unreachable, .Host_Unreachable, .Timeout, .Invalid_Argument:
		return true
	}
	return false
}

on_send :: proc(op: ^nbio.Operation, c: ^Connection, on_sent: Send_Callback) {
	context.temp_allocator = temp_allocator(c)

	sent: int
	err: nbio.Send_File_Error
	#partial switch op.type {
	case .Send:
		sent = op.send.sent
		if op.send.err != nil {
			err = op.send.err.(nbio.TCP_Send_Error)
		}

		// Make sure the buffers given to the send are still not poisoned.
		// Hard to catch without it because there is no direct use after the `send` call.
		for buf in op.send.bufs {
			assert(sanitizer.address_region_is_poisoned(buf) == nil)
		}

	case .Send_File:
		sent = op.sendfile.sent
		err  = op.sendfile.err
	case:
		unimplemented("on_send type")
	}

	if sent > 0 {
		progression_update(&c.res.progress, sent, since(c.res._last_send))
	}

	if err != nil {
		log.warnf("http[t=%v][c=%v]: msg=\"send error\", err=%v", td.id, c.socket, err)
		c.res._state = .Error
	}

	c.res._sends -= 1
	c.res.sent  += sent

	should_check  := c.res._state == .Sent || c.res._state == .Error
	skip_graceful := _send_error_skip_graceful_close(err)

	if !should_check {
		if on_sent != nil { on_sent(&c.ctx, err) }
		return
	}

	if on_sent != nil {
		destroy_flag: _Destroy_Flag
		_destroy_flag_push(c, &destroy_flag)

		on_sent(&c.ctx, err)
		if _destroy_flag_pop(c, &destroy_flag) {
			return
		}
	}

	_check_send_done(c, skip_graceful)
}

_check_send_done :: proc(c: ^Connection, skip_graceful := false) {
	assert(c.res._sends >= 0)
	if (c.res._state != .Sent && c.res._state != .Error) || c.res._sends > 0 {
		return
	}

	if c.res._state == .Error && skip_graceful {
		_connection_destroy(c)
		return
	}

	if c.res._state == .Error || c.res.status == .Switching_Protocols || response_must_close(c) || response_has_close(&c.res) {
		connection_close(c)
		return
	}

	log.debugf("http[t=%v][c=%v]: sent=%v, msg=\"response sent, serving next request\"", td.id, c.socket, c.res.progress.transferred)

	_connection_run_deferred(c)

	_serve_connection(c)
}

response_has_close :: proc(res: ^Response) -> bool {
	return headers_has_token(&res.headers, "connection", "close")
}

// Determines if the connection needs to be closed after sending the response.
response_must_close :: proc(c: ^Connection) -> bool {
	if sync.atomic_load(&td.s.shutting_down) {
		return true
	}

	// If the request we are responding to indicates it is closing the connection, close our side too.
	if headers_has_token(&c.req.headers, "connection", "close") {
		return true
	}

	// HTTP 1.0 does not have persistent connections.
	line := c.req.line
	if line.version == {1, 0} {
		return true
	}

	// If the request had a body that was not fully consumed, close the connection
	// so leftover body bytes on the wire are not misparsed as the next request.
	if !c.req.has_consumed_body {
		return true
	}

	return false
}

@(private)
date_update :: proc(_: ^nbio.Operation) {
	td.curr_date = nbio.timeout(time.Second, date_update)
	date_write(td.date[:], nbio.now())
	td.arena_trim_ticks += 1
	if td.arena_trim_ticks >= ARENA_TRIM_INTERVAL {
		td.arena_trim_ticks = 0
		_server_thread_free_arenas_trim(td)
	}
}

now :: nbio.now

since :: proc(t: time.Time) -> time.Duration {
	return time.diff(t, now())
}
