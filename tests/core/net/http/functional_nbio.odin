#+build windows, linux, darwin
package test_core_net_http

import "base:runtime"
import "base:sanitizer"

import "core:container/xar"
import "core:log"
import "core:mem"
import "core:nbio"
import "core:net"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"

import http "core:http2"

nbio_make_tcp_pair :: proc(t: ^testing.T, listen_sock: nbio.TCP_Socket, endpoint: nbio.Endpoint) -> (accepted, peer: nbio.TCP_Socket, ok: bool) {
	Accept_State :: struct {
		done:   bool,
		err:    nbio.Accept_Error,
		client: nbio.TCP_Socket,
	}
	Dial_State :: struct {
		done: bool,
		err:  nbio.Network_Error,
		sock: nbio.TCP_Socket,
	}
	a_st: Accept_State
	d_st: Dial_State

	nbio.accept_poly(listen_sock, &a_st, proc(op: ^nbio.Operation, st: ^Accept_State) {
		st.err    = op.accept.err
		st.client = op.accept.client
		st.done   = true
	})
	nbio.dial_poly(endpoint, &d_st, proc(op: ^nbio.Operation, st: ^Dial_State) {
		st.err  = op.dial.err
		st.sock = op.dial.socket
		st.done = true
	})
	for !a_st.done || !d_st.done {
		nbio.tick()
	}
	if !testing.expect_value(t, a_st.err, nil) || !testing.expect_value(t, d_st.err, nil) {
		return
	}
	return a_st.client, d_st.sock, true
}

nbio_close_socket :: proc(sock: nbio.TCP_Socket) {
	closed: bool
	nbio.close_poly(sock, &closed, proc(_: ^nbio.Operation, closed: ^bool) { closed^ = true })
	nbio.run_until(&closed)
}

nbio_tick_until :: proc(timeout: time.Duration, state: ^$T, done: proc(^T) -> bool) -> (completed: bool) {
	timed_out := false
	guard := nbio.timeout_poly(timeout, &timed_out, proc(_: ^nbio.Operation, timed_out: ^bool) {
		timed_out^ = true
	})
	for !timed_out && !done(state) {
		nbio.tick()
	}
	if !timed_out {
		nbio.remove(guard)
	}
	return !timed_out
}

run_test_server_existing :: proc(
	t:             ^testing.T,
	server:        ^http.Server,
	client_data:   ^$T,
	client_proc:   proc(port: int, server: ^http.Server, data: ^T),
	auto_shutdown := true,
	loc           := #caller_location,
) -> (serve_finished_at: time.Time, ok: bool) {
	if setup_err := http._setup(server); !testing.expect_value(t, setup_err, nil, loc) {
		http._destroy(server)
		return
	}

	endpoint, ep_err := nbio.bound_endpoint(server.socket)
	if !testing.expect_value(t, ep_err, nil, loc) {
		http._destroy(server)
		return
	}

	Runner_Ctx :: struct {
		port:          int,
		server:        ^http.Server,
		client_data:   ^T,
		client_proc:   proc(port: int, server: ^http.Server, data: ^T),
		auto_shutdown: bool,
	}
	rctx := Runner_Ctx{
		port          = endpoint.port,
		server        = server,
		client_data   = client_data,
		client_proc   = client_proc,
		auto_shutdown = auto_shutdown,
	}

	client_thread := thread.create_and_start_with_data(&rctx, proc(raw: rawptr) {
		rc := (^Runner_Ctx)(raw)
		defer if rc.auto_shutdown {
			http.server_shutdown(rc.server)
		}
		rc.client_proc(rc.port, rc.server, rc.client_data)
	})

	http._serve(server)
	serve_finished_at = time.now()
	thread.join(client_thread)
	thread.destroy(client_thread)
	http._destroy(server)
	return serve_finished_at, true
}

run_test_server :: proc(
	t:             ^testing.T,
	opts:          http.Server_Options,
	client_data:   ^$T,
	client_proc:   proc(port: int, server: ^http.Server, data: ^T),
	allocator     := context.allocator,
	auto_shutdown := true,
	loc           := #caller_location,
) -> (serve_finished_at: time.Time, ok: bool) {
	opts := opts
	if opts.address == {} {
		opts.address = nbio.IP4_Loopback
	}
	if opts.port == nil {
		opts.port = http.OS_ASSIGNED_PORT
	}
	if opts.thread_count == 0 {
		opts.thread_count = 1
	}

	server := http.make_server(opts, allocator)
	return run_test_server_existing(t, &server, client_data, client_proc, auto_shutdown, loc)
}

@(test)
test_accept_error_recovery_and_oom_cleanup :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	if acq_err := nbio.acquire_thread_event_loop(); !testing.expect_value(t, acq_err, nil) {
		return
	}
	defer nbio.release_thread_event_loop()

	listen_sock, listen_err := nbio.listen_tcp(nbio.Endpoint{nbio.IP4_Loopback, 0})
	if !testing.expect_value(t, listen_err, nil) {
		return
	}
	defer nbio_close_socket(listen_sock)

	s := http.make_server({})
	thread := http.Server_Thread{s = &s, id = 1}
	s.socket = listen_sock

	// 1. Transient error (.Aborted) immediately re-arms .Accept.
	{
		op: nbio.Operation
		op.accept.err = .Aborted
		http._on_accept(&op, &thread)
		testing.expect(t, thread.curr_accept != nil && thread.curr_accept.type == .Accept, "expected .Aborted to immediately re-arm accept")
		if thread.curr_accept != nil {
			nbio.remove(thread.curr_accept)
			thread.curr_accept = nil
		}
		nbio.tick(timeout = 0)
	}

	// 2. Resource error (.Insufficient_Resources) schedules backoff timeout in curr_accept and then re-arms .Accept.
	{
		op: nbio.Operation
		op.accept.err = .Insufficient_Resources
		http._on_accept(&op, &thread)
		testing.expect(t, thread.curr_accept != nil && thread.curr_accept.type == .Timeout, "expected .Insufficient_Resources to schedule backoff timer")

		done := nbio_tick_until(2 * time.Second, &thread, proc(th: ^http.Server_Thread) -> bool {
			return th.curr_accept != nil && th.curr_accept.type == .Accept
		})
		testing.expect(t, done, "timed out waiting for accept backoff timer to re-arm accept")
		testing.expect(t, thread.curr_accept != nil && thread.curr_accept.type == .Accept, "expected backoff timer callback to re-arm accept")
		if thread.curr_accept != nil {
			nbio.remove(thread.curr_accept)
			thread.curr_accept = nil
		}
		nbio.tick(timeout = 0)
	}

	// 3. Permanent error (.Not_Listening) stops the accept loop cleanly.
	{
		op: nbio.Operation
		op.accept.err = .Not_Listening
		prev_logger := context.logger
		context.logger = log.nil_logger()
		http._on_accept(&op, &thread)
		context.logger = prev_logger
		testing.expect(t, thread.curr_accept == nil, "expected fatal accept error not to re-arm accept")
	}

	// 4. xar.push OOM closes accepted client socket (peer sees EOF) while keeping accept loop armed.
	{
		endpoint, endpoint_err := nbio.bound_endpoint(listen_sock)
		if !testing.expect_value(t, endpoint_err, nil) {
			return
		}

		Accept_State :: struct {
			done:   bool,
			err:    nbio.Accept_Error,
			client: nbio.TCP_Socket,
			ep:     nbio.Endpoint,
		}
		Dial_State :: struct {
			done: bool,
			err:  nbio.Network_Error,
			sock: nbio.TCP_Socket,
		}
		accept_st: Accept_State
		dial_st: Dial_State

		nbio.accept_poly(listen_sock, &accept_st, proc(op: ^nbio.Operation, st: ^Accept_State) {
			st.err    = op.accept.err
			st.client = op.accept.client
			st.ep     = op.accept.client_endpoint
			st.done   = true
		})
		nbio.dial_poly(endpoint, &dial_st, proc(op: ^nbio.Operation, st: ^Dial_State) {
			st.err  = op.dial.err
			st.sock = op.dial.socket
			st.done = true
		})
		for !accept_st.done || !dial_st.done {
			nbio.tick()
		}
		if !testing.expect_value(t, accept_st.err, nil) || !testing.expect_value(t, dial_st.err, nil) {
			return
		}
		defer nbio_close_socket(dial_st.sock)

		fa := Test_Fail_Allocator{fail = true}
		oom_thread := http.Server_Thread{s = &s, id = 2}
		xar.init(&oom_thread.connections, test_fail_allocator(&fa))
		defer xar.freelist_destroy(&oom_thread.connections)

		fake_op: nbio.Operation
		fake_op.accept.client          = accept_st.client
		fake_op.accept.client_endpoint = accept_st.ep

		prev_logger := context.logger
		context.logger = log.nil_logger()
		http._on_accept(&fake_op, &oom_thread)
		context.logger = prev_logger

		testing.expect(t, oom_thread.curr_accept != nil && oom_thread.curr_accept.type == .Accept, "expected OOM on xar.push to keep accept armed")
		if oom_thread.curr_accept != nil {
			nbio.remove(oom_thread.curr_accept)
			oom_thread.curr_accept = nil
		}

		// Peer socket should immediately observe EOF/closed because _on_accept closed accept_st.client.
		Recv_State :: struct {
			done:     bool,
			received: int,
			err:      nbio.Recv_Error,
		}
		recv_st: Recv_State
		buf: [16]byte
		nbio.recv_poly(dial_st.sock, {buf[:]}, &recv_st, proc(op: ^nbio.Operation, st: ^Recv_State) {
			st.received = op.recv.received
			st.err      = op.recv.err
			st.done     = true
		}, timeout = time.Second)
		for !recv_st.done {
			nbio.tick()
		}
		testing.expect(t, recv_st.received == 0 && recv_st.err != nbio.Recv_Error(nbio.TCP_Recv_Error.Timeout), "expected peer socket to observe closed accepted connection")
	}
}

@(test)
test_dead_socket_send_error_skips_graceful_close :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	if acq_err := nbio.acquire_thread_event_loop(); !testing.expect_value(t, acq_err, nil) {
		return
	}
	defer nbio.release_thread_event_loop()

	listen_sock, listen_err := nbio.listen_tcp(nbio.Endpoint{nbio.IP4_Loopback, 0})
	if !testing.expect_value(t, listen_err, nil) {
		return
	}
	defer nbio_close_socket(listen_sock)

	endpoint, endpoint_err := nbio.bound_endpoint(listen_sock)
	if !testing.expect_value(t, endpoint_err, nil) {
		return
	}

	env: Test_Env
	test_env_init(&env, with_connections = true)
	defer {
		nbio.tick(timeout = 0)
		test_env_destroy(&env)
	}

	// 1. Dead-socket TCP_Send_Error (.Connection_Closed) skips 500ms drain and destroys immediately.
	{
		accepted, peer, ok := nbio_make_tcp_pair(t, listen_sock, endpoint)
		if !ok { return }
		defer nbio_close_socket(peer)

		c := test_conn_push(t, &env, socket = accepted)
		c.res._state = .Sending
		c.res._sends = 1

		Defer_Flag :: distinct ^bool
		defer_ran := false
		http.context_add(&c.ctx, Defer_Flag(&defer_ran))
		http.response_defer(&c.ctx, proc(ctx: ^http.Ctx) {
			flag := http.context_get(ctx, Defer_Flag)^
			(^bool)(flag)^ = true
		})

		op := nbio.Operation{
			type = .Send,
			send = {err = nbio.TCP_Send_Error.Connection_Closed},
		}
		http.on_send(&op, c, nil)

		testing.expect_value(t, active_connection_count(&env.thread), 0)
		testing.expect(t, defer_ran, "expected response_defer to run during immediate connection_destroy")
	}

	// 2. Multiple in-flight sends wait for sends == 0 before destroying immediately.
	{
		accepted, peer, ok := nbio_make_tcp_pair(t, listen_sock, endpoint)
		if !ok { return }
		defer nbio_close_socket(peer)

		c := test_conn_push(t, &env, socket = accepted)
		c.res._state = .Sending
		c.res._sends = 2

		op := nbio.Operation{
			type = .Send,
			send = {err = nbio.TCP_Send_Error.Connection_Closed},
		}
		http.on_send(&op, c, nil)
		testing.expect_value(t, active_connection_count(&env.thread), 1)
		testing.expect_value(t, c.res._sends, 1)
		testing.expect(t, c.res._state == .Error, "expected state to transition to .Error")

		http.on_send(&op, c, nil)
		testing.expect_value(t, active_connection_count(&env.thread), 0)
	}

	// 3. FS_Error on Send_File (socket still usable) preserves graceful connection_close drain.
	{
		accepted, peer, ok := nbio_make_tcp_pair(t, listen_sock, endpoint)
		if !ok { return }
		peer_closed := false
		defer if !peer_closed {
			nbio_close_socket(peer)
		}

		c := test_conn_push(t, &env, socket = accepted)
		c.res._state = .Sending
		c.res._sends = 1

		op := nbio.Operation{
			type     = .Send_File,
			sendfile = {err = nbio.FS_Error.EOF},
		}
		http.on_send(&op, c, nil)

		testing.expect_value(t, active_connection_count(&env.thread), 1)
		testing.expect(t, c.curr_recv != nil, "expected connection_close to arm drain recv on non-dead-socket error")

		nbio_close_socket(peer)
		peer_closed = true

		completed := nbio_tick_until(2 * time.Second, &env.thread, proc(th: ^http.Server_Thread) -> bool {
			return active_connection_count(th) == 0
		})
		testing.expect(t, completed, "timed out waiting for graceful connection_close drain to finish")
		testing.expect_value(t, active_connection_count(&env.thread), 0)
	}
}

@(test)
test_peer_disconnect_during_inflight_send :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	if acq_err := nbio.acquire_thread_event_loop(); !testing.expect_value(t, acq_err, nil) {
		return
	}
	defer nbio.release_thread_event_loop()

	listen_sock, listen_err := nbio.listen_tcp(nbio.Endpoint{nbio.IP4_Loopback, 0})
	if !testing.expect_value(t, listen_err, nil) {
		return
	}
	defer nbio_close_socket(listen_sock)

	endpoint, endpoint_err := nbio.bound_endpoint(listen_sock)
	if !testing.expect_value(t, endpoint_err, nil) {
		return
	}

	env: Test_Env
	test_env_init(&env, with_connections = true)
	defer {
		nbio.tick(timeout = 0)
		test_env_destroy(&env)
	}

	accepted, peer, ok := nbio_make_tcp_pair(t, listen_sock, endpoint)
	if !ok { return }
	peer_closed := false
	defer if !peer_closed {
		nbio_close_socket(peer)
	}

	c := test_conn_push(t, &env, socket = accepted)
	c.req.line              = {method = .Get, target = "/", version = {1, 1}}
	c.req.has_consumed_body = true
	http.budget_init(&c.req.budget, &http.NO_LIMITS)
	http.budget_init(&c.res.budget, &http.NO_LIMITS)
	c.res.status = .OK
	c.res._state = .Handling

	Flags :: struct {
		sent_ran:  bool,
		defer_ran: bool,
	}
	flags: Flags
	http.context_add(&c.ctx, &flags)
	http.response_defer(&c.ctx, proc(ctx: ^http.Ctx) {
		f := http.context_get(ctx, ^Flags)^
		f.defer_ran = true
	})

	payload, payload_err := make([]byte, 8 * mem.Megabyte, http.transaction_allocator(c))
	if !testing.expect_value(t, payload_err, nil) {
		return
	}

	http.send(&c.ctx, {payload}, proc(ctx: ^http.Ctx, err: http.Send_Error) {
		f := http.context_get(ctx, ^Flags)^
		f.sent_ran = true
	})
	http.scan_bytes(&c.scanner, 64, proc(c: ^http.Connection, data: []byte) {})

	testing.expect_value(t, c.res._sends, 1)
	testing.expect(t, c.curr_recv != nil, "expected active Recv op to be tracked")

	// Flush submissions once so both the large Send and the Recv are in flight, then send TCP FIN from peer.
	nbio.tick(timeout = 10 * time.Millisecond)
	nbio.shutdown(peer, .Send)

	Fin_Wait :: struct {
		thread: ^http.Server_Thread,
		c:      ^http.Connection,
	}
	fin_wait := Fin_Wait{thread = &env.thread, c = c}
	fin_ok := nbio_tick_until(2 * time.Second, &fin_wait, proc(fw: ^Fin_Wait) -> bool {
		return active_connection_count(fw.thread) == 0 || fw.c.curr_recv == nil
	})
	testing.expect(t, fin_ok, "timed out waiting for scanner_on_recv to receive peer FIN")
	testing.expect_value(t, active_connection_count(&env.thread), 1)
	testing.expect(t, c.res._state == .Error, "expected state to transition to .Error on disconnect during send")
	testing.expect(t, !flags.defer_ran, "expected connection_destroy/response_defer to wait for in-flight send")

	// Now close peer so the blocked send finishes/errors and completes teardown.
	nbio_close_socket(peer)
	peer_closed = true

	done := nbio_tick_until(2 * time.Second, &env.thread, proc(th: ^http.Server_Thread) -> bool {
		return active_connection_count(th) == 0
	})
	testing.expect(t, done, "timed out waiting for connection teardown after send completion")
	testing.expect_value(t, active_connection_count(&env.thread), 0)
	testing.expect(t, flags.sent_ran, "expected on_sent callback to run cleanly before teardown")
	testing.expect(t, flags.defer_ran, "expected response_defer to run once on final teardown")
}

@(test)
test_free_all_during_inflight_temp_recv :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	if acq_err := nbio.acquire_thread_event_loop(); !testing.expect_value(t, acq_err, nil) {
		return
	}
	defer nbio.release_thread_event_loop()

	listen_sock, listen_err := nbio.listen_tcp(nbio.Endpoint{nbio.IP4_Loopback, 0})
	if !testing.expect_value(t, listen_err, nil) {
		return
	}
	defer nbio_close_socket(listen_sock)

	endpoint, endpoint_err := nbio.bound_endpoint(listen_sock)
	if !testing.expect_value(t, endpoint_err, nil) {
		return
	}

	env: Test_Env
	test_env_init(&env, with_connections = true)
	defer {
		nbio.tick(timeout = 0)
		test_env_destroy(&env)
	}

	accepted, peer, ok := nbio_make_tcp_pair(t, listen_sock, endpoint)
	if !ok { return }
	defer nbio_close_socket(peer)

	c := test_conn_push(t, &env, socket = accepted)
	c_destroyed := false
	defer if !c_destroyed {
		http._connection_destroy(c)
	}
	http.budget_init(&c.req.budget, &http.NO_LIMITS)
	http.budget_init(&c.res.budget, &http.NO_LIMITS)
	c.res._state = .Sending

	Frame_State :: struct {
		got:     [8]byte,
		got_len: int,
		called:  bool,
	}
	frame_state: Frame_State
	http.context_add(&c.ctx, &frame_state)

	http.scan_temp_bytes(&c.scanner, 8, proc(c: ^http.Connection, data: []byte) {
		st := http.context_get(&c.ctx, ^Frame_State)^
		st.called  = true
		st.got_len = copy(st.got[:], data)
	})

	testing.expect(t, c.curr_recv != nil, "expected active recv op in flight")
	testing.expect(t, c.scanner.allocator == &c.temp_arena, "expected scanner buffer allocated in temp_arena")

	orig_buf_ptr := raw_data(c.scanner.buf)
	orig_block   := c.temp_arena.tail

	nbio.tick(timeout = 10 * time.Millisecond)

	scratch1, err1 := make([]byte, 128, http.temp_allocator(c))
	testing.expect_value(t, err1, nil)
	scratch1[0] = 1
	scratch2, err2 := make([]byte, 5000, http.temp_allocator(c))
	testing.expect_value(t, err2, nil)
	scratch2[0] = 2
	testing.expect(t, c.temp_arena.tail != orig_block, "expected overflow block pushed into temp_arena")

	free_all(http.temp_allocator(c))

	testing.expect(t, raw_data(c.scanner.buf) == orig_buf_ptr, "expected scanner buffer pointer preserved across free_all")
	testing.expect(t, c.temp_arena.tail == orig_block, "expected pinned block retained as tail")
	testing.expect(t, orig_block.prev == nil, "expected overflow block unlinked")
	testing.expect(t, env.thread.free_arenas[1].head != nil, "expected 8 KiB overflow block returned to thread freelist")
	testing.expect(t, sanitizer.address_region_is_poisoned(c.scanner.buf) == nil, "expected scanner buffer unpoisoned")

	expected_offset := int(uintptr(raw_data(c.scanner.buf)) - uintptr(raw_data(orig_block.data))) + len(c.scanner.buf)
	testing.expect_value(t, orig_block.offset, expected_offset)
	testing.expect(t, orig_block.last == raw_data(c.scanner.buf), "expected orig_block.last set to scanner buffer")

	// Trailing space in the pinned block can still be reused while recv is in flight.
	reused, reuse_err := make([]byte, 64, http.temp_allocator(c))
	testing.expect_value(t, reuse_err, nil)
	reused[0] = 3
	testing.expect(t, c.temp_arena.tail == orig_block, "expected trailing space in pinned block to be reused after rewind")

	Send_State :: struct {
		done: bool,
		err:  nbio.TCP_Send_Error,
	}
	s_st: Send_State
	payload := transmute([]byte)string("abcdefgh")
	nbio.send_poly(peer, {payload}, &s_st, proc(op: ^nbio.Operation, st: ^Send_State) {
		st.err  = op.send.err.(nbio.TCP_Send_Error) or_else nil
		st.done = true
	})

	Wait_State :: struct {
		frame: ^Frame_State,
		send:  ^Send_State,
	}
	wait_st := Wait_State{frame = &frame_state, send = &s_st}
	done := nbio_tick_until(2 * time.Second, &wait_st, proc(ws: ^Wait_State) -> bool {
		return ws.frame.called && ws.send.done
	})

	testing.expect(t, done, "timed out waiting for peer send / scanner recv")
	testing.expect_value(t, s_st.err, nil)
	testing.expect(t, frame_state.called, "expected scan_temp_bytes callback to receive peer data")
	testing.expect_value(t, string(frame_state.got[:frame_state.got_len]), "abcdefgh")

	// Once recv completes (curr_recv == nil) and buffer is consumed, free_all releases it cleanly.
	testing.expect(t, c.curr_recv == nil, "expected curr_recv cleared after recv completion")
	free_all(http.temp_allocator(c))
	testing.expect(t, c.scanner.buf == nil, "expected empty scanner buf cleared once curr_recv == nil")
	testing.expect(t, c.temp_arena.tail == nil, "expected temp_arena freed once curr_recv == nil")

	http._connection_destroy(c)
	c_destroyed = true
	testing.expect_value(t, active_connection_count(&env.thread), 0)
}

@(test)
test_setup_failure_cleanup_and_worker_join :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	if acq_err := nbio.acquire_thread_event_loop(); !testing.expect_value(t, acq_err, nil) {
		return
	}
	defer nbio.release_thread_event_loop()

	// 1. _setup bind failure on a fresh thread closes any socket state and releases thread event loop.
	{
		holder, listen_err := nbio.listen_tcp(nbio.Endpoint{nbio.IP4_Loopback, 0})
		if !testing.expect_value(t, listen_err, nil) {
			return
		}
		defer nbio_close_socket(holder)

		ep, ep_err := nbio.bound_endpoint(holder)
		if !testing.expect_value(t, ep_err, nil) {
			return
		}

		Bind_Result :: struct {
			allocator:              runtime.Allocator,
			port:                   int,
			setup_err:              http.Server_Error,
			socket_cleared:         bool,
			threads_nil:            bool,
			loop_nil:               bool,
			loop_nil_after_destroy: bool,
		}
		res := Bind_Result{allocator = context.allocator, port = ep.port}

		worker := thread.create_and_start_with_data(&res, proc(data: rawptr) {
			res := (^Bind_Result)(data)
			context.allocator = res.allocator
			s := http.make_server(http.Server_Options{
				address      = nbio.IP4_Loopback,
				port         = res.port,
				thread_count = 1,
			})
			res.setup_err      = http._setup(&s)
			res.socket_cleared = s.socket == {}
			res.threads_nil    = s.threads == nil
			res.loop_nil       = nbio.current_thread_event_loop() == nil
			http._destroy(&s)
			res.loop_nil_after_destroy = nbio.current_thread_event_loop() == nil
		})
		testing.expect(t, worker != nil, "expected helper thread created")
		thread.destroy(worker)

		testing.expect(t, res.setup_err != nil, "expected _setup to fail when port is already in use")
		testing.expect(t, res.socket_cleared, "expected s.socket cleared on _setup bind failure")
		testing.expect(t, res.threads_nil, "expected s.threads nil on _setup bind failure")
		testing.expect(t, res.loop_nil, "expected thread event loop released on _setup bind failure")
		testing.expect(t, res.loop_nil_after_destroy, "expected _destroy after failed _setup to leave event loop released")
	}

	// 2. _setup OOM during _setup_threads closes s.socket and releases loop.
	{
		OOM_Result :: struct {
			allocator:      runtime.Allocator,
			setup_err:      http.Server_Error,
			socket_cleared: bool,
			threads_nil:    bool,
			loop_nil:       bool,
		}
		res := OOM_Result{allocator = context.allocator}

		worker := thread.create_and_start_with_data(&res, proc(data: rawptr) {
			res := (^OOM_Result)(data)
			context.allocator = res.allocator
			fa := Test_Fail_Allocator{fail = true}
			s := http.make_server(http.Server_Options{
				address      = nbio.IP4_Loopback,
				port         = http.OS_ASSIGNED_PORT,
				thread_count = 1,
			}, test_fail_allocator(&fa))

			res.setup_err      = http._setup(&s)
			res.socket_cleared = s.socket == {}
			res.threads_nil    = s.threads == nil
			res.loop_nil       = nbio.current_thread_event_loop() == nil
		})
		testing.expect(t, worker != nil, "expected helper thread created")
		thread.destroy(worker)

		testing.expect_value(t, res.setup_err, http.Server_Error(http.General_Error.Allocation_Failed))
		testing.expect(t, res.socket_cleared, "expected s.socket closed and cleared on _setup_threads OOM")
		testing.expect(t, res.threads_nil, "expected s.threads nil on _setup_threads OOM")
		testing.expect(t, res.loop_nil, "expected thread event loop released on _setup_threads OOM")
	}

	// 3. Multi-threaded _setup followed by _destroy without _serve joins worker threads cleanly without deadlocking.
	{
		NoServe_Result :: struct {
			allocator:      runtime.Allocator,
			setup_err:      http.Server_Error,
			socket_cleared: bool,
			threads_nil:    bool,
			loop_nil:       bool,
		}
		res := NoServe_Result{allocator = context.allocator}

		worker := thread.create_and_start_with_data(&res, proc(data: rawptr) {
			res := (^NoServe_Result)(data)
			context.allocator = res.allocator
			s := http.make_server(http.Server_Options{
				address      = nbio.IP4_Loopback,
				port         = http.OS_ASSIGNED_PORT,
				thread_count = 2,
			})
			res.setup_err = http._setup(&s)
			http._destroy(&s)
			res.socket_cleared = s.socket == {}
			res.threads_nil    = s.threads == nil
			res.loop_nil       = nbio.current_thread_event_loop() == nil
		})
		testing.expect(t, worker != nil, "expected helper thread created")
		thread.destroy(worker)

		testing.expect_value(t, res.setup_err, nil)
		testing.expect(t, res.socket_cleared, "expected s.socket closed and cleared by _destroy")
		testing.expect(t, res.threads_nil, "expected s.threads cleaned up and nil after _destroy")
		testing.expect(t, res.loop_nil, "expected event loop released cleanly")
	}
}

@(test)
test_pipelining_and_smuggling_over_tcp :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	r: http.Router
	defer http.router_destroy(r)
	http.route_get(&r, "/a", proc(ctx: ^http.Ctx) { http.respond_plain(ctx, "a") })
	http.route_get(&r, "/b", proc(ctx: ^http.Ctx) { http.respond_plain(ctx, "b") })

	Client_Ctx :: struct {
		pipe_buf:  [1024]byte,
		pipe_len:  int,
		pipe_ok:   bool,
		clte_buf:  [512]byte,
		clte_len:  int,
		clte_ok:   bool,
		tete_buf:  [512]byte,
		tete_len:  int,
		tete_ok:   bool,
	}
	res: Client_Ctx

	_, ok := run_test_server(t, {handlers = {http.router(&r)}}, &res, proc(port: int, _: ^http.Server, res: ^Client_Ctx) {
		endpoint := net.Endpoint{net.IP4_Loopback, port}

		send_and_read_all :: proc(endpoint: net.Endpoint, req: string, out: []byte) -> (n: int, ok: bool) {
			sock, derr := net.dial_tcp(endpoint)
			if derr != nil { return }
			defer net.close(sock)
			_ = net.set_option(sock, .Receive_Timeout, 2 * time.Second)

			sent := 0
			bytes := transmute([]byte)req
			for sent < len(bytes) {
				sn, serr := net.send_tcp(sock, bytes[sent:])
				if serr != nil || sn <= 0 { return }
				sent += sn
			}
			for n < len(out) {
				rn, rerr := net.recv_tcp(sock, out[n:])
				if rn > 0 { n += rn }
				if rn == 0 || rerr != nil { break }
			}
			return n, true
		}

		// 1. Two pipelined HTTP/1.1 requests in one write.
		res.pipe_len, res.pipe_ok = send_and_read_all(
			endpoint,
			"GET /a HTTP/1.1\r\nHost: localhost\r\n\r\n" +
			"GET /b HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n",
			res.pipe_buf[:],
		)

		// 2. CL.TE smuggling attempt -> 400 Bad Request + Connection: close.
		res.clte_len, res.clte_ok = send_and_read_all(
			endpoint,
			"POST /a HTTP/1.1\r\nHost: localhost\r\nContent-Length: 4\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n",
			res.clte_buf[:],
		)

		// 3. TE.TE duplicate Transfer-Encoding -> 400 Bad Request + Connection: close.
		res.tete_len, res.tete_ok = send_and_read_all(
			endpoint,
			"POST /a HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nTransfer-Encoding: gzip\r\n\r\n0\r\n\r\n",
			res.tete_buf[:],
		)
	})
	if !ok { return }

	testing.expect(t, res.pipe_ok, "expected pipelined TCP round-trip to succeed")
	pipe_resp := string(res.pipe_buf[:res.pipe_len])
	testing.expect_value(t, strings.count(pipe_resp, "HTTP/1.1 200 OK\r\n"), 2)
	testing.expect(t, strings.contains(pipe_resp, "\r\n\r\na"), "expected first pipelined body 'a'")
	testing.expect(t, strings.has_suffix(pipe_resp, "\r\n\r\nb"), "expected second pipelined body 'b'")

	testing.expect(t, res.clte_ok, "expected CL.TE smuggling connection to close cleanly")
	clte_resp := string(res.clte_buf[:res.clte_len])
	testing.expect(t, strings.has_prefix(clte_resp, "HTTP/1.1 400 Bad Request\r\n"), "expected 400 for CL.TE")
	testing.expect(t, strings.contains(strings.to_lower(clte_resp, context.temp_allocator), "connection: close\r\n"), "expected Connection: close for CL.TE")

	testing.expect(t, res.tete_ok, "expected TE.TE smuggling connection to close cleanly")
	tete_resp := string(res.tete_buf[:res.tete_len])
	testing.expect(t, strings.has_prefix(tete_resp, "HTTP/1.1 400 Bad Request\r\n"), "expected 400 for TE.TE")
	testing.expect(t, strings.contains(strings.to_lower(tete_resp, context.temp_allocator), "connection: close\r\n"), "expected Connection: close for TE.TE")
}
