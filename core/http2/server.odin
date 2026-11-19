#+vet explicit-allocators
#+build !js
package http

import "base:intrinsics"
import "base:runtime"
import "base:sanitizer"

import "core:container/xar"
import "core:io"
import "core:log"
import "core:mem/virtual"
import "core:nbio"
import "core:os"
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

	temp_allocator_backing: virtual.Arena,
}

Endpoint :: nbio.Endpoint

Server_Options :: struct {
	address:      nbio.Address,
	port:         int,
	backlog:      int,
	thread_count: int,
	handler:      Handler,
	no_redirect_head_to_get: bool,
	thread_initializer: proc(),

	request_quota:  Quota,
	body_quota:     Quota,
	response_quota: Quota,
	// Maximum number of request headers (and chunked trailers) accepted. Zero defaults to DEFAULT_MAX_HEADERS; negative disables the limit.
	max_headers:    int,
}

DEFAULT_BACKLOG     :: 1000
DEFAULT_ADDRESS     :: nbio.IP4_Loopback
DEFAULT_PORT        :: 8080
DEFAULT_MAX_HEADERS :: 128

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
	thread:      ^thread.Thread,
	event_loop:  ^nbio.Event_Loop,
	curr_accept: ^nbio.Operation, // PERF: check if having multiple increases performance.
	curr_date:   ^nbio.Operation,
	id:          int,
	connections: xar.Freelist_Array(Connection, 8),
	date:        [DATE_LENGTH]byte,
	free_arenas: [BUCKETS]^_Arena_Block,
}

Connection :: struct {
	socket:            nbio.TCP_Socket,
	remote:            nbio.Endpoint,
	scanner:           Scanner,
	curr_recv:         ^nbio.Operation,
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
	return transaction_allocator_from_connection(connection_of_context(ctx))
}

transaction_allocator :: proc {
	transaction_allocator_from_connection,
	transaction_allocator_from_ctx,
}

temp_allocator :: proc(c: ^Connection) -> runtime.Allocator {
	return arena_allocator(&c.temp_arena)
}

Ctx :: struct {
	req:  Request,
	res:  Response,
	// TODO: prive
	vars: [dynamic]Context_Var,
}

Context_Var :: struct {
	id:  typeid,
	val: rawptr,
}

context_add :: proc(ctx: ^Ctx, var: $T) -> ^T {
	val := new_clone(var, transaction_allocator(ctx))
	append(&ctx.vars, Context_Var{
		id  = T,
		val = val,
	})
	return val
}

context_get :: proc(ctx: ^Ctx, $T: typeid) -> ^T {
	#reverse for var in ctx.vars {
		if var.id == T {
			return (^T)(var.val)
		}
	}

	return nil
}

Request :: struct {
	quota:              ^Quota,
	progress:           Progression,
	line:               Requestline,
	is_redirected_head: bool,
	has_consumed_body:  bool,
	headers:            Headers,
}

Response :: struct {
	quota:    ^Quota,
	progress: Progression,
	status:   Status,
	headers:  Headers,

	// TODO: prive
	buf: [dynamic]byte,
	// TODO: prive
	deferred: [dynamic]proc(ctx: ^Ctx),

	// TODO: prive
	last_send: time.Time,
	sends: int,
	sent:  int,
	// TODO: prive
	state: enum {
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
	req.quota = quota
	progression_set_quota(&req.progress, quota^)
}

// Overrides the quota applied to sending the response.
// The given pointer must live as long as the transaction.
response_set_quota :: proc(res: ^Response, quota: ^Quota) {
	res.quota = quota
	progression_set_quota(&res.progress, quota^)
}

response_defer :: proc(ctx: ^Ctx, deffered: proc(^Ctx)) {
	append(&ctx.res.deferred, deffered)
}

// TODO: quota option on server. Transaction could hold only the 2 mutating durations to save space.

// TODO: max length

// TODO: send quota too

@(thread_local)
td: ^Server_Thread

_setup_threads :: proc(s: ^Server) -> runtime.Allocator_Error {
	thread_count := max(1, s.opts.thread_count > 0 ? s.opts.thread_count : os.get_processor_core_count())
	s.threads = make([]Server_Thread, thread_count, s.allocator) or_return

	for &server_thread in s.threads {
		xar.init(&server_thread.connections, s.allocator)
	}

	for &server_thread, i in s.threads[1:] {
		server_thread.thread = thread.create_and_start_with_poly_data3(s, &server_thread, i+2, _server_thread, context)
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
	if thread.s.opts.thread_initializer != nil {
		thread.s.opts.thread_initializer()
	}

	sync.one_shot_event_wait(&thread.s.serve)

	sync.wait_group_add(&thread.s.running_threads, 1)
	defer sync.wait_group_done(&thread.s.running_threads)

	sync.mutex_lock(&thread.s.shutdown_mutex)
	thread.event_loop = nbio.current_thread_event_loop()
	sync.mutex_unlock(&thread.s.shutdown_mutex)

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
			_server_thread_shutdown(thread)
			break
		}
	}
}

_server_thread_shutdown :: proc(thread: ^Server_Thread) {
	nbio.remove(thread.curr_accept)
	thread.curr_accept = nil

	nbio.remove(thread.curr_date)
	thread.curr_date = nil

	iter := xar.freelist_iterator(&thread.connections)
	for c, _ in xar.freelist_iterate_by_ptr(&iter) {
		nbio.remove(c.curr_recv)
		c.curr_recv = nil
		connection_destroy(c)
	}

	sync.mutex_lock(&thread.s.shutdown_mutex)
	thread.event_loop = nil
	nbio.release_thread_event_loop()
	sync.mutex_unlock(&thread.s.shutdown_mutex)
}

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

_on_accept :: proc(op: ^nbio.Operation, thread: ^Server_Thread) {
	thread.curr_accept = nil
	if op.accept.err != nil {
		log.errorf("http[t=%v]: accept_err=", thread.id, op.accept.err)
		// TODO: handle, try again later.
		return
	}

	thread.curr_accept = nbio.accept_poly(thread.s.socket, thread, _on_accept)

	log.debugf("http[t=%v][c=%v]: msg=\"accepted connection\", from=%v", thread.id, op.accept.client, op.accept.client_endpoint)

	c, err := xar.push(&thread.connections, Connection{
		socket = op.accept.client,
		remote = op.accept.client_endpoint,
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

	_serve_connection(c)
}

// How long to wait before actually closing a connection.
// This is to make sure the client can fully receive the response.
CONN_CLOSE_DELAY :: time.Millisecond * 500

// Sends a FIN, receives for at most CONN_CLOSE_DELAY (making sure the client gets our close / waiting for it to close too).
// Ultimately destroying the connection.
connection_close :: proc(c: ^Connection) {
	c.res.state    = .Error
	c.scanner.scan = {}
	nbio.remove(c.curr_recv)
	c.curr_recv = nil
	if c.res.sends > 0 {
		return
	}

	log.debugf("http[t=%v][c=%v]: msg=\"shutdown\"", td.id, c.socket)
	nbio.shutdown(c.socket, .Send)

	@(static) junk: [1024]byte
	c.req.progress.timeout = CONN_CLOSE_DELAY
	c.scanner.last_recv_start = now()
	c.curr_recv = nbio.recv_poly(c.socket, {junk[:]}, c, on_recv, all=true, timeout=c.req.progress.timeout)

	on_recv :: proc(op: ^nbio.Operation, c: ^Connection) {
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

		connection_destroy(c)
	}
}

@(private="file")
_connection_release :: proc(c: ^Connection) {
	nbio.remove(c.curr_recv)
	c.curr_recv = nil
	c.scanner.scan = {}
	if c.scanner._pump_destroyed != nil {
		c.scanner._pump_destroyed^ = true
	}

	#reverse for deferred in c.res.deferred {
		log.debugf("http[t=%v][c=%v]: msg=\"running defer\", defer=%v", td.id, c.socket, deferred)
		deferred(&c.ctx)
	}
	clear(&c.res.deferred)

	temp_allocator_destroy(c)
	transaction_allocator_destroy(c)
	// if mem_use > 0 {
	// 	log.debugf("http[t=%v][c=%v]: msg=\"request cleaned up\", mem_use=%M", td.id, c.socket, mem_use)
	// }

	idx, ok := xar.linear_search(&td.connections, c)
	assert(ok)
	xar.release(&td.connections, idx)
}

connection_destroy :: proc(c: ^Connection) {
	log.debugf("http[t=%v][c=%v]: msg=\"destroy\"", td.id, c.socket)
	nbio.remove(c.curr_recv)
	c.curr_recv = nil
	if c.socket != {} {
		nbio.close(c.socket)
	}
	_connection_release(c)
}

// Removes the connection from the server pool without closing the socket, returning the underlying
// socket and a copy of any unread bytes still buffered in the scanner.
connection_detach :: proc(c: ^Connection, allocator := context.allocator) -> (socket: nbio.TCP_Socket, buffered: []byte, err: runtime.Allocator_Error) {
	assert(c.res.sends == 0, "cannot detach connection while sends are in flight")
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
	if c.res.state != .None && c.res.state != .Handling {
		c.res.state = .Error
		_check_send_done(c)
		return
	}
	log.warnf("http[t=%v][c=%v]: status=%v, msg=\"invalid request\"", td.id, c.socket, status)
	c.res.status = status
	headers_set(&c.res.headers, "connection", "close")
	respond(&c.res)
}

_serve_connection :: proc(c: ^Connection) {
	c.temp_arena.c        = c
	c.transaction_arena.c = c

	scanner_reset(&c.scanner, c)
	temp_allocator_destroy(c)

	c.ctx = {}

	allocator := transaction_allocator(c)

	c.req.quota = &td.s.opts.request_quota
	progression_init(&c.req.progress, c.req.quota^)
	if c.scanner.write_head > 0 {
		progression_update(&c.req.progress, c.req.quota^, c.scanner.write_head, 0)
	}
	c.res.quota = &td.s.opts.response_quota
	progression_init(&c.res.progress, c.res.quota^)

	c.req.headers.allocator  = allocator
	c.res.headers.allocator  = allocator
	c.vars.allocator         = allocator
	c.res.buf.allocator      = allocator
	c.res.deferred.allocator = allocator

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

	c.res.state = .Handling
	c.req.quota = &td.s.opts.body_quota
	progression_reset(&c.req.progress, c.req.quota^)
	_headers_set_readonly(&c.req.headers)

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
		assert(td.s.opts.handler.handle != nil, "HTTP server does not have a request handler set")
		td.s.opts.handler.handle(&td.s.opts.handler, &c.ctx)
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
		for &t in s.threads[1:] {
			thread.destroy(t.thread)
		}
		for &t in s.threads {
			xar.freelist_destroy(&t.connections)
			_server_thread_free_arenas_destroy(&t)
		}
		delete(s.threads, s.allocator)
	}
	virtual.arena_destroy(&s.temp_allocator_backing)
}

_DEFAULT_BLOCK_SIZE :: runtime.Gigabyte

_setup :: proc(s: ^Server) -> Server_Error {
	if s.allocator.procedure == nil {
		s.allocator = context.allocator
	}
	_server_options_apply_defaults(&s.opts)

	_acquire_event_loop(s) or_return

	if listen_err := _listen(s); listen_err != nil {
		switch err in listen_err {
		case nbio.Listen_Error:        return err
		case nbio.Create_Socket_Error: return err
		case nbio.Bind_Error:          return err
		}
	}

	if err := virtual.arena_init_growing(&s.temp_allocator_backing, _DEFAULT_BLOCK_SIZE); err != nil {
		return .Allocation_Failed
	}

	headers_init_hash_secret()

	if err := _setup_threads(s); err != nil {
		virtual.arena_destroy(&s.temp_allocator_backing)
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

// TODO: chunked writer - can this work with the tracking of sends, wait for all sends
// PERF: we could read the next request after "consume body" is done already, while response is still being sent

// TODO
send_heading :: send_response_heading

write_response_heading :: proc(res: ^Response) {
	// if len(res.buf) > 0 {
	// 	return
	// }
	assert(len(res.buf) == 0)

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

	if response_must_close(c) && !headers_has(res.headers, "connection") {
		append(&res.buf, "Connection: close\r\n")
	}

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

Send_Error :: nbio.Send_File_Error

Send_Callback :: proc(c: ^Connection, err: Send_Error)

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
		progression_update(&c.res.progress, c.res.quota != nil ? c.res.quota^ : {}, sent, since(c.res.last_send))
	}

	if err != nil {
		log.warnf("http[t=%v][c=%v]: msg=\"send error\", err=%v", td.id, c.socket, err)

		// TODO: some of these errors don't need a graceful shutdown
	}

	if err != nil {
		c.res.state = .Error
	}

	c.res.sends -= 1
	c.res.sent  += sent

	should_check := c.res.state == .Sent || c.res.state == .Error

	if on_sent != nil { on_sent(c, err) }

	if should_check {
		_check_send_done(c)
	}
}

_check_send_done :: proc(c: ^Connection) {
	assert(c.res.sends >= 0)
	if (c.res.state != .Sent && c.res.state != .Error) || c.res.sends > 0 {
		return
	}

	if c.res.state == .Error || c.res.status == .Switching_Protocols || response_must_close(c) || response_has_close(&c.res) {
		connection_close(c)
		return
	}

	log.debugf("http[t=%v][c=%v]: sent=%v, msg=\"response sent, serving next request\"", td.id, c.socket, c.res.progress.transferred)

	#reverse for deferred in c.res.deferred {
		log.debugf("http[t=%v][c=%v]: msg=\"running defer\", defer=%v", td.id, c.socket, deferred)
		deferred(&c.ctx)
	}
	clear(&c.res.deferred)

	_serve_connection(c)
}

response_has_close :: proc(res: ^Response) -> bool {
	if connection, ok := headers_get(res.headers, "connection"); ok && _headers_eq(connection, "close") {
		return true
	}

	return false
}

// Determines if the connection needs to be closed after sending the response.
response_must_close :: proc(c: ^Connection) -> bool {
	// If the request we are responding to indicates it is closing the connection, close our side too.
	if connection, ok := headers_get(c.req.headers, "connection"); ok && _headers_eq(connection, "close") {
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
}

now :: nbio.now

since :: proc(t: time.Time) -> time.Duration {
	return time.diff(t, now())
}
