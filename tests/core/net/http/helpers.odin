package test_core_net_http

import "core:container/xar"
import "core:mem"
import "core:nbio"
import "core:sync"
import "core:testing"
import "core:time"

import http "core:http2"

@(init, private="file")
_init_test_hash_secret :: proc "contextless" () {
	http.headers_init_hash_secret()
}

Test_Env :: struct {
	s:               http.Server,
	handlers:        [1]http.Handler,
	thread:          http.Server_Thread,
	prev_td:         ^http.Server_Thread,
	has_connections: bool,
}

test_env_init :: proc(
	env:              ^Test_Env,
	opts             := http.Server_Options{},
	allocator        := context.allocator,
	with_connections := false,
) {
	env^ = {}
	env.s = http.make_server(opts, allocator)
	env.thread = http.Server_Thread{s = &env.s, id = 1}
	http.date_write(env.thread.date[:], time.now())
	env.has_connections = with_connections
	if with_connections {
		xar.init(&env.thread.connections, context.allocator)
	}
	env.prev_td = http.td
	http.td = &env.thread
}

test_env_destroy :: proc(env: ^Test_Env) {
	if env.has_connections {
		xar.freelist_destroy(&env.thread.connections)
	}
	http._server_thread_free_arenas_destroy(&env.thread)
	http.td = env.prev_td
}

test_conn_init :: proc(
	t:             ^testing.T,
	c:             ^http.Connection,
	env:           ^Test_Env,
	payload       := "",
	mock_send     := false,
	mock_handling := false,
	init_budgets  := true,
) {
	if c.transaction_arena.backing.procedure == nil {
		c.transaction_arena = http.get_arena(nil)
	}
	c.transaction_arena.c = c
	if c.temp_arena.backing.procedure == nil {
		c.temp_arena = http.get_arena(nil)
	}
	c.temp_arena.c = c

	tx_alloc := http.transaction_allocator(c)
	c._vars.allocator         = tx_alloc
	c.req.headers.allocator   = tx_alloc
	c.res.headers.allocator   = tx_alloc
	c.res._buf.allocator      = tx_alloc
	c.res._deferred.allocator = tx_alloc
	c.scanner.c               = c
	c.scanner.allocator       = &c.transaction_arena

	if init_budgets {
		http.budget_init(&c.req.budget, &env.s.opts.request_limits)
		http.budget_init(&c.res.budget, &env.s.opts.response_limits)
	}

	if mock_send || mock_handling {
		c.res.budget.max = 0
		c.res._sends     = 1
	}
	if mock_handling {
		c.res._state = .Handling
		c.res.status = .OK
	}

	if len(payload) > 0 {
		buf, buf_err := make([]byte, max(http.MULTIPLIER, len(payload)), tx_alloc)
		testing.expect_value(t, buf_err, nil)
		c.scanner.buf        = buf
		c.scanner.write_head = copy(buf, payload)
	}
}

test_conn_destroy :: proc(c: ^http.Connection) {
	http.temp_allocator_destroy(c)
	http.transaction_allocator_destroy(c)
}

test_conn_push :: proc(
	t:             ^testing.T,
	env:           ^Test_Env,
	socket:        nbio.TCP_Socket = {},
	payload       := "",
	mock_send     := false,
	mock_handling := false,
) -> ^http.Connection {
	c, err := xar.push(&env.thread.connections, http.Connection{socket = socket})
	testing.expect_value(t, err, nil)
	test_conn_init(t, c, env, payload = payload, mock_send = mock_send, mock_handling = mock_handling)
	return c
}

test_conn_destroy_pooled :: proc(c: ^http.Connection) {
	// Mock unit tests set c.res._sends > 0 without an active nbio send op to prevent
	// _check_send_done from destroying the connection before assertions run.
	c.res._sends = 0
	http._connection_destroy(c)
}

active_connection_count :: proc(thread: ^http.Server_Thread) -> (count: int) {
	iter := xar.freelist_iterator(&thread.connections)
	for _, _ in xar.freelist_iterate_by_ptr(&iter) {
		count += 1
	}
	return
}

test_req_set_headers :: proc(t: ^testing.T, c: ^http.Connection, headers: [][2]string, readonly := true) {
	for pair in headers {
		testing.expect_value(t, http.headers_set(&c.req.headers, pair[0], pair[1]), nil)
	}
	if readonly {
		http._headers_set_readonly(&c.req.headers)
	}
}

Test_Counting_Allocator :: struct {
	backing:     mem.Allocator,
	alloc_count: int,
	free_count:  int,
}

test_counting_allocator :: proc(c: ^Test_Counting_Allocator) -> mem.Allocator {
	return {
		data = c,
		procedure = proc(
			allocator_data: rawptr,
			mode: mem.Allocator_Mode,
			size, alignment: int,
			old_memory: rawptr,
			old_size: int,
			location := #caller_location,
		) -> ([]byte, mem.Allocator_Error) {
			c := (^Test_Counting_Allocator)(allocator_data)
			#partial switch mode {
			case .Alloc, .Alloc_Non_Zeroed:
				sync.atomic_add(&c.alloc_count, 1)
			case .Free:
				if old_memory != nil {
					sync.atomic_add(&c.free_count, 1)
				}
			}
			return c.backing.procedure(c.backing.data, mode, size, alignment, old_memory, old_size, location)
		},
	}
}

Test_Fail_Allocator :: struct {
	backing: mem.Allocator,
	fail:    bool,
}

test_fail_allocator :: proc(fa: ^Test_Fail_Allocator) -> mem.Allocator {
	return {
		data = fa,
		procedure = proc(
			allocator_data: rawptr,
			mode: mem.Allocator_Mode,
			size, alignment: int,
			old_memory: rawptr,
			old_size: int,
			location := #caller_location,
		) -> ([]byte, mem.Allocator_Error) {
			fa := (^Test_Fail_Allocator)(allocator_data)
			if fa.fail {
				#partial switch mode {
				case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
					return nil, .Out_Of_Memory
				}
			}
			return fa.backing.procedure(fa.backing.data, mode, size, alignment, old_memory, old_size, location)
		},
	}
}

test_tracking_init :: proc(track: ^mem.Tracking_Allocator) {
	mem.tracking_allocator_init(track, context.allocator)
	track.bad_free_callback = mem.tracking_allocator_bad_free_callback_add_to_array
}

expect_slice :: proc(t: ^testing.T, got, want: []$T, loc := #caller_location) {
	if !testing.expect_value(t, len(got), len(want), loc = loc) {
		return
	}
	for v, i in want {
		testing.expect_value(t, got[i], v, loc = loc)
	}
}
