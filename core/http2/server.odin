#+vet explicit-allocators
#+build !js
package http

import "base:intrinsics"
import "base:runtime"

import "core:bytes"
import "core:container/xar"
import "core:io"
import "core:log"
import "core:math"
import "core:math/bits"
import "core:mem"
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

// Allocation_Stats :: struct {
// 	threads: []Thread_Allocation_Stats,
// 	total: int `fmt:"M"`,
// }
//
// Thread_Allocation_Stats :: struct {
// 	buckets: [BUCKETS]Bucket_Allocation_Stats,
// 	total: int `fmt:"M"`,
// }
//
// Bucket_Allocation_Stats :: struct {
// 	min:   int `fmt:"M"`,
// 	max:   int `fmt:"M"`,
// 	total: int `fmt:"M"`,
// 	count: int,
// }
//
// server_allocation_stats :: proc(s: ^Server) -> Allocation_Stats {
// 	threads := make([]Thread_Allocation_Stats, len(s.threads), context.allocator)
// 	total: int
// 	for &thread, i in threads {
// 		for &bucket, j in thread.buckets {
// 			for tail := s.threads[i].free_arenas[j]; tail != nil; tail = tail.prev {
// 				if bucket.min == 0 {
// 					bucket.min = len(tail.data)
// 				} else {
// 					bucket.min = min(bucket.min, len(tail.data))
// 				}
// 				bucket.max = max(bucket.max, len(tail.data))
// 				bucket.count += 1
// 				bucket.total += len(tail.data)
// 			}
// 			thread.total += bucket.total
// 		}
// 		total += thread.total
// 	}
//
// 	return {threads, total}
// }

Server_Thread :: struct {
	s:           ^Server,
	thread:      thread.Thread,
	event_loop:  ^nbio.Event_Loop,
	curr_accept: ^nbio.Operation,
	id:          int,
	connections: xar.Freelist_Array(Connection, 8),
	date:        [DATE_LENGTH]byte,
	free_arenas: [BUCKETS]^Arena,
}

Arena :: struct {
	using base: mem.Arena,
	last: rawptr,
	prev: ^Arena,
}

arena_resize_in_place :: proc(a: ^Arena, old_data: []byte, size, alignment: int, should_zero: bool) -> ([]byte, mem.Allocator_Error) {
	old_memory := raw_data(old_data)
	if old_memory == nil || old_memory != a.last {
		return nil, .Invalid_Pointer
	}

	if size <= 0 {
		return nil, .Invalid_Argument
	}

	if !mem.is_aligned(old_memory, alignment) {
		return nil, .Invalid_Pointer
	}

	diff := size - len(old_data)
	if a.offset + diff > len(a.data) {
		return nil, .Out_Of_Memory
	}

	if should_zero && diff > 0 {
		mem.zero_slice(a.data[a.offset:][:diff])
	}

	a.offset += diff

	raw := transmute(runtime.Raw_Slice)old_data
	raw.len += diff
	return transmute([]byte)raw, nil
}

Connection :: struct {
	socket:  nbio.TCP_Socket,
	scanner: Scanner,

	using temp: struct {
		arenas:          ^Arena,
		temp_arenas:     ^Arena,
		// pos:             int,
		// buf:             [dynamic]byte,
		// last_recv_start: time.Time,
		// last_recv_dur:   time.Duration,
		// last_recv_n:     int,
		headers_quota:   Quota,
		body_quota:      Quota,

		using ctx: Context,
	},
}

ARENA_SIZE :: 4096
SHIFT      :: 12   // First bucket starts at 4 KiB
BUCKETS    :: 17   // Last bucket starts at 256 MiB

LAST_BUCKET_FROM_SIZE :: 1 << (SHIFT + BUCKETS-1)
#assert(LAST_BUCKET_FROM_SIZE == 256 * mem.Megabyte)

bucket_for :: proc(min_size: int) -> int {
	assert(min_size > 0)
	aligned := uint(math.next_power_of_two(min_size))
	return int(clamp(bits.log2(aligned) - SHIFT, 0, BUCKETS-1))
}

bucket_to_put :: proc(size: uint) -> int {
	assert(size > 0)
	return int(clamp(bits.log2(size) - SHIFT, 0, BUCKETS-1))
}

server_thread_get_free_arena :: proc(size: int = 0, align := mem.DEFAULT_ALIGNMENT) -> ^Arena {
	size   := size
	size    = max(ARENA_SIZE, mem.align_forward_int(size_of(Arena), align) + size)
	bucket := bucket_for(size)

	if bucket == BUCKETS-1 {
		arena := td.free_arenas[bucket]
		if arena != nil {
			if len(arena.data) < size {
				{
					context.temp_allocator = runtime.default_temp_allocator(&runtime.global_default_temp_allocator_data)
					log.debugf("http[t=%v]: size=%M, bucket=%v, got=%M", td.id, size, bucket, len(arena.data))
				}

				td.free_arenas[bucket] = nil
				arena.offset = size_of(Arena)
				arena.peak_used, arena.temp_count = 0, 0
				arena.prev = nil
				return arena
			}

			for prev := arena.prev; prev != nil; arena, prev = prev, prev.prev {
				if len(prev.data) < size {
					continue
				}

				{
					context.temp_allocator = runtime.default_temp_allocator(&runtime.global_default_temp_allocator_data)
					log.debugf("http[t=%v]: size=%M, bucket=%v, got=%M", td.id, size, bucket, len(prev.data))
				}

				arena.prev = prev.prev
				prev.offset = size_of(Arena)
				prev.peak_used, prev.temp_count = 0, 0
				prev.prev = nil
				return prev
			}
		}
	} else {
		for check in bucket..<BUCKETS {
			free_arena := td.free_arenas[check]
			if free_arena == nil {
				continue
			}

			{
				context.temp_allocator = runtime.default_temp_allocator(&runtime.global_default_temp_allocator_data)
				log.debugf("http[t=%v]: size=%M, bucket=%v, check=%v, got=%M", td.id, size, bucket, check, len(free_arena.data))
			}

			td.free_arenas[check] = free_arena.prev
			free_arena.offset = size_of(Arena)
			free_arena.peak_used, free_arena.temp_count = 0, 0
			free_arena.prev = nil
			return free_arena
		}
	}

	{
		context.temp_allocator = runtime.default_temp_allocator(&runtime.global_default_temp_allocator_data)
		log.debugf("http[t=%v]: size=%M, bucket=%v", td.id, size, bucket)
	}

	data, err := virtual.arena_alloc(&td.s.temp_allocator_backing, uint(size), uint(align))
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

		bucket := bucket_to_put(len(arena.data))
		arena.prev = td.free_arenas[bucket]
		td.free_arenas[bucket] = arena

		{
			context.temp_allocator = runtime.default_temp_allocator(&runtime.global_default_temp_allocator_data)
			log.debugf("http[t=%v, c=%v]: size=%M, bucket=%v", td.id, c.socket, len(arena.data), bucket)
		}

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

		bucket := bucket_to_put(len(arena.data))
		arena.prev = td.free_arenas[bucket]
		td.free_arenas[bucket] = arena

		{
			context.temp_allocator = runtime.default_temp_allocator(&runtime.global_default_temp_allocator_data)
			log.debugf("http[t=%v, c=%v]: size=%M, bucket=%v", td.id, c.socket, len(arena.data), bucket)
		}

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

			new_arena :: proc(c: ^Connection, size, align: int) -> ^Arena {
				arena := server_thread_get_free_arena(size, align)
				arena.prev = get_arena(c)
				set_arena(c, arena)
				return arena
			}

			arena := get_arena(c)
			if arena == nil {
				arena = new_arena(c, size, alignment == 0 ? mem.DEFAULT_ALIGNMENT : alignment)
			}

			switch mode {
			case .Alloc:
				bs, err = mem.arena_alloc_bytes(arena, size, alignment, location)
				if err == .Out_Of_Memory {
					arena = new_arena(c, size, alignment)
					bs, err = mem.arena_alloc_bytes(arena, size, alignment, location)
				}
				arena.last = raw_data(bs)
				return

			case .Alloc_Non_Zeroed:
				bs, err = mem.arena_alloc_bytes_non_zeroed(arena, size, alignment, location)
				if err == .Out_Of_Memory {
					arena = new_arena(c, size, alignment)
					bs, err = mem.arena_alloc_bytes_non_zeroed(arena, size, alignment, location)
				}
				arena.last = raw_data(bs)
				return

			case .Resize, .Resize_Non_Zeroed:
				should_zero := mode == .Resize
				bs, err = arena_resize_in_place(arena, mem.byte_slice(old_memory, old_size), size, alignment, should_zero)
				if err != nil {
					bs, err = mem._default_resize_bytes_align(mem.byte_slice(old_memory, old_size), size, alignment, should_zero, mem.arena_allocator(arena), location)
					if err == .Out_Of_Memory {
						arena = new_arena(c, size, alignment)
						if should_zero {
							bs, err = mem.arena_alloc_bytes(arena, size, alignment, location)
						} else {
							bs, err = mem.arena_alloc_bytes_non_zeroed(arena, size, alignment, location)
						}
						if err == nil {
							intrinsics.mem_copy_non_overlapping(raw_data(bs), old_memory, old_size)
						}
					}
				}
				arena.last = raw_data(bs)
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
					if !scanner_free_all(&c.scanner, temp_allocator(c)) {
						temp_allocator_destroy(c)
					}
					arena.last = nil
					return nil, nil
				} else {
					return nil, .Mode_Not_Implemented
				}

			case .Query_Info:
				return nil, .Mode_Not_Implemented

			case .Free:
				if old_memory != arena.last {
					return nil, .Mode_Not_Implemented
				}

				arena.last    = nil
				arena.offset -= old_size
				return nil, nil

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

	sends: int,
	state: enum {
		Handling,
		Sending,  // send or send_file is called at least once (and heading is sent).
		Sent,     // respond was called.
		Error,
	},
}

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
	c.scanner.last_recv_start = nbio.now()
	nbio.recv_poly(c.socket, {junk[:]}, c, on_recv, all=true, timeout=c.headers_quota.max)

	on_recv :: proc(op: ^nbio.Operation, c: ^Connection) {
		now := nbio.now()
		c.headers_quota.max -= time.diff(c.scanner.last_recv_start, now)
		log.debugf("http[t=%v][c=%v]: err=%v, received=%v, closing_for=%v", td.id, c.socket, op.recv.err, op.recv.received, CONN_CLOSE_DELAY-c.headers_quota.max)
		if op.recv.err == nil && op.recv.received > 0 {
			if c.headers_quota.max > 0 {
				c.scanner.last_recv_start = now
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

	#reverse for deferred in c.res.deferred {
		log.debugf("http[t=%v][c=%v]: msg=\"running defer\", defer=%v", td.id, c.socket, deferred)
		deferred(&c.res)
	}

	free_all(temp_allocator(c))
	mem_use := transaction_allocator_destroy(c)
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
	free_all(temp_allocator(c))

	mem_use := transaction_allocator_destroy(c)
	if mem_use > 0 {
		log.debugf("http[t=%v][c=%v]: msg=\"request cleaned up\", mem_use=%M", td.id, c.socket, mem_use)
	}

	mem.zero_item(&c.temp)

	c.headers_quota = DEFAULT_HEADERS_QUOTA
	c.body_quota    = DEFAULT_BODY_QUOTA

	allocator := transaction_allocator(c)

	// c.buf.allocator          = allocator
	c.req.headers.allocator  = allocator
	c.res.headers.allocator  = allocator
	c.vars.allocator         = allocator
	c.res.buf.allocator      = allocator
	c.res.deferred.allocator = allocator

	scanner_reset(&c.scanner, c)

	scan_header_line(&c.scanner, on_rline1)

	on_rline1 :: proc(c: ^Connection, line: []byte) {
		if len(line) == 0 {
			scan_header_line(&c.scanner, on_rline)
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
		}

		if line.version.major != 1 || line.version.minor > 1 {
			log.warnf("http[t=%v][c=%v]: version=%v.%v, status=%v", td.id, c.socket, line.version.major, line.version.minor, Status.HTTP_Version_Not_Supported)
			invalid_request(c, .HTTP_Version_Not_Supported)
			return
		}

		log.debugf("http[t=%v][c=%v]: method=%v, target=%q, version=%v.%v", td.id, c.socket, line.method, line.target, line.version.major, line.version.minor)
		c.req.line = line

		scan_header_line(&c.scanner, on_header)
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

		if alloc_err := headers_add(&c.req.headers, key, value); alloc_err != nil {
			log.errorf("http[t=%v][c=%v]: msg=\"headers_add allocation error\", err=%v", td.id, c.socket, alloc_err)
			invalid_request(c, .Internal_Server_Error)
			return
		}

		scan_header_line(&c.scanner, on_header)
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
			assert(td.s.opts.handler.handle != nil, "HTTP server does not have a request handler set")
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

	if err != nil {
		c.res.state = .Error
	}

	c.res.sends -= 1
	if (c.res.state != .Sent && c.res.state != .Error) || c.res.sends > 0 {
		return
	}

	// TODO: if consume body still going, wait for that

	if c.res.state == .Error || response_must_close(c) || response_has_close(&c.res) {
		connection_close(c)
		return
	}

	// TODO: informational/take over connection

	log.debugf("http[t=%v][c=%v]: sent=%v, msg=\"response sent, serving next request\"", td.id, sent, c.socket)

	#reverse for deferred in c.res.deferred {
		log.debugf("http[t=%v][c=%v]: msg=\"running defer\", defer=%v", td.id, c.socket, deferred)
		deferred(&c.res)
	}
	clear(&c.res.deferred)

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

Scan_Splitter :: struct {
	procedure: proc(user_data: rawptr, data: []byte) -> (int, int, int, bool),
	user_data: rawptr,
}

Scan_Cb :: proc(c: ^Connection, data: []byte)

Scan :: struct #all_or_none {
	split:     Scan_Splitter,
	allocator: runtime.Allocator,
	timeout:   time.Duration,
	callback:  Scan_Cb,
}

// TODO: max size.

Scanner :: struct {
	// container_off?
	c:          ^Connection,

	buf:        []byte,
	read_head:  int,
	write_head: int,
	allocator:  runtime.Allocator,

	scan:       Scan,

	is_pumping: bool,

	last_recv_start: time.Time,
	last_recv_dur:   time.Duration,
	last_recv_n:     int,
}

MULTIPLIER :: 512

scanner_reset :: proc(s: ^Scanner, c: ^Connection) {
	s^  = {}
	s.c = c
}

// TODO: hacky
scanner_free_all :: proc(s: ^Scanner, allocator: runtime.Allocator) -> (handled: bool) {
	if allocator != s.allocator {
		return false
	}

	curr_temp_allocator := temp_allocator(s.c)
	if allocator != curr_temp_allocator {
		return false
	}

	to_copy := s.buf[s.read_head:s.write_head]
	to_alloc := max(MULTIPLIER, len(to_copy))
	log.debugf("http[t=%v][c=%v]: msg=\"scanner_free_all\", to_copy=%v, to_alloc=%v", td.id, s.c.socket, len(to_copy), to_alloc)

	if len(to_copy) == 0 {
		s.buf = {}
		s.read_head, s.write_head = 0, 0
		return false
	}

	new_arena := server_thread_get_free_arena(to_alloc)
	err: runtime.Allocator_Error
	s.buf, err = make([]byte, to_alloc, mem.arena_allocator(new_arena))
	assert(err == nil)
	s.read_head  = 0
	s.write_head = copy(s.buf, to_copy)

	temp_allocator_destroy(s.c)
	s.c.temp_arenas = new_arena
	return true
}

_scan_bytes :: proc(s: ^Scanner, n: int, timeout: time.Duration, allocator: runtime.Allocator, cb: Scan_Cb) {
	s.scan = {
		split     = split_n(n),
		allocator = allocator,
		timeout   = timeout,
		callback  = cb,
	}
	scanner_pump(s)
}

scan_bytes :: proc(s: ^Scanner, n: int, cb: Scan_Cb) {
	_scan_bytes(s, n, get_timeout(s.last_recv_dur, &s.c.body_quota, s.last_recv_n), transaction_allocator(s.c), cb)
}

scan_temp_bytes :: proc(s: ^Scanner, n: int, timeout: time.Duration, cb: Scan_Cb) {
	_scan_bytes(s, n, get_timeout(s.last_recv_dur, &s.c.body_quota, s.last_recv_n), temp_allocator(s.c), cb)
}

_scan_line :: proc(s: ^Scanner, timeout: time.Duration, allocator: runtime.Allocator, cb: Scan_Cb) {
	s.scan = {
		split     = split_line(),
		allocator = transaction_allocator(s.c),
		timeout   = timeout,
		callback  = cb,
	}
	scanner_pump(s)
}

scan_header_line :: proc(s: ^Scanner, cb: Scan_Cb) {
	_scan_line(s, get_timeout(s.last_recv_dur, &s.c.headers_quota, s.last_recv_n), transaction_allocator(s.c), cb)
}

scan_temp_header_line :: proc(s: ^Scanner, cb: Scan_Cb) {
	_scan_line(s, get_timeout(s.last_recv_dur, &s.c.headers_quota, s.last_recv_n), temp_allocator(s.c), cb)
}

scan_body_line :: proc(s: ^Scanner, cb: Scan_Cb) {
	_scan_line(s, get_timeout(s.last_recv_dur, &s.c.body_quota, s.last_recv_n), transaction_allocator(s.c), cb)
}

scan_temp_body_line :: proc(s: ^Scanner, cb: Scan_Cb) {
	_scan_line(s, get_timeout(s.last_recv_dur, &s.c.body_quota, s.last_recv_n), temp_allocator(s.c), cb)
}

split_n :: proc(n: int) -> Scan_Splitter {
	return {
		procedure = proc(needed: rawptr, data: []byte) -> (offset, n, advance: int, ok: bool) {
			needed := int(uintptr(needed))
			if len(data) < needed {
				return
			}

			return 0, needed, needed, true
		},
		user_data = rawptr(uintptr(n)),
	}
}

split_line :: proc() -> Scan_Splitter {
	return {
		procedure = proc(_: rawptr, data: []byte) -> (offset, n, advance: int, ok: bool) {
			start := 0
			for {
				index := bytes.index_byte(data[start:], '\r')
				if index < 0 {
					return
				}
				index += start

				if len(data) > index+1 && data[index+1] == '\n' {
					return 0, index, index+2, true
				}

				start = index+1
			}
		},
	}
}

scanner_pump :: proc(s: ^Scanner) {
	if s.is_pumping { return }

	s.is_pumping = true
	defer s.is_pumping = false

	for s.scan.callback != nil {
		offset, n, advance, ok := s.scan.split.procedure(s.scan.split.user_data, s.buf[s.read_head:s.write_head])
		if ok {
			assert(advance >= n && n >= offset)

			data: []byte
			// PERF: could check if prev is transaction_allocator and new is temp_allocator and skip this
			if s.scan.allocator != s.allocator {
				to_copy := s.buf[s.read_head+offset:s.write_head]

				s.allocator = s.scan.allocator
				err: runtime.Allocator_Error
				s.buf, err = make([]byte, max(len(to_copy), MULTIPLIER), s.allocator)
				assert(err == nil) // TODO: 
				log.debugf("http[t=%v][c=%v]: msg=\"scanner realloc (new allocator)\"", td.id, s.c.socket)

				s.read_head  = advance-offset
				s.write_head = copy(s.buf, to_copy)
				assert(s.write_head == len(to_copy))

				data = s.buf[:n]
			} else {
				data = s.buf[s.read_head+offset:][:n]
				s.read_head += advance
			}

			cb := s.scan.callback
			s.scan = {}
			cb(s.c, data)
		} else {
			capacity := len(s.buf)-s.write_head
			if capacity < MULTIPLIER || s.scan.allocator != s.allocator { // PERF: could check if prev is transaction_allocator and new is temp_allocator and skip this
				prev_buf := s.buf
				buf_left := s.buf[s.read_head:s.write_head]
				new_size := max(MULTIPLIER, len(prev_buf) * 2)

				s.allocator = s.scan.allocator

				// TODO: messy, arbitrary allocator may not be the best idea
				arena: ^Arena
				if s.allocator == temp_allocator(s.c) {
					arena = s.c.temp_arenas
				} else if s.allocator == transaction_allocator(s.c) {
					arena = s.c.arenas
				}

				err: runtime.Allocator_Error
				if arena != nil {
					s.buf, err = arena_resize_in_place(arena, s.buf, new_size, 1, false)
					if err == nil {
						log.debugf("http[t=%v][c=%v]: msg=\"scanner resized in place\", prev=%v, new=%v", td.id, s.c.socket, len(prev_buf), len(s.buf))
					}
				}

				if arena == nil || err != nil {
					s.buf, err = make([]byte, new_size, s.allocator)
					assert(err == nil) // TODO: err
					log.debugf("http[t=%v][c=%v]: msg=\"scanner realloc\", prev=%v, new=%v", td.id, s.c.socket, len(prev_buf), len(s.buf))

					s.read_head  = 0
					s.write_head = copy(s.buf[:], buf_left)
					assert(s.write_head == len(buf_left))
				}
			}

			log.debugf("http[t=%v][c=%v]: msg=\"recv\", n=%v, timeout=%v", td.id, s.c.socket, len(s.buf)-s.read_head, s.scan.timeout)
			s.last_recv_start = nbio.now()
			nbio.recv_poly(
				s.c.socket,
				{s.buf[s.write_head:]},
				s,
				scanner_on_recv,
				timeout=s.scan.timeout,
			)
			return
		}
	}

	scanner_on_recv :: proc(op: ^nbio.Operation, s: ^Scanner) {
		if op.recv.err != nil {
			log.warnf("http[t=%v][c=%v]: recv error=%v", td.id, s.c.socket, op.recv.err)
			switch op.recv.err.(nbio.TCP_Recv_Error) {
			case .Timeout:
				invalid_request(s.c, .Request_Timeout)
			case .Not_Connected, .Connection_Closed:
				connection_destroy(s.c)
			case .Network_Unreachable, .Insufficient_Resources, .Invalid_Argument, .Would_Block, .Interrupted, .Unknown, .None:
				fallthrough
			case:
				invalid_request(s.c, .Internal_Server_Error)
			}
			return
		}

		if op.recv.received == 0 {
			log.debugf("http[t=%v][c=%v]: msg=\"client disconnected\"", td.id, s.c.socket)
			connection_destroy(s.c)
			return
		}

		s.last_recv_dur = time.diff(s.last_recv_start, nbio.now())
		s.last_recv_n   = op.recv.received

		log.debugf("http[t=%v][c=%v]: received=%v/%v, duration=%b", td.id, s.c.socket, s.last_recv_n, len(op.recv.bufs[0]), s.last_recv_dur)
		s.write_head += op.recv.received

		scanner_pump(s)
	}
}
