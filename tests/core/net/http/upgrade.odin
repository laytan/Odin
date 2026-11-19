package test_core_net_http

import "base:runtime"

import "core:container/xar"
import "core:mem"
import "core:mem/virtual"
import "core:nbio"
import "core:strings"
import "core:testing"
import "core:time"

import http "core:http2"

Upgrade_Test_Env :: struct {
	s:       http.Server,
	thread:  http.Server_Thread,
	prev_td: ^http.Server_Thread,
}

setup_upgrade_env :: proc(t: ^testing.T, env: ^Upgrade_Test_Env) {
	http.headers_init_hash_secret()

	env.s = http.make_server({})
	err := virtual.arena_init_growing(&env.s.temp_allocator_backing, 64 * mem.Megabyte)
	testing.expect_value(t, err, nil)

	env.thread = http.Server_Thread{s = &env.s, id = 1}
	http.date_write(env.thread.date[:], time.now())
	xar.init(&env.thread.connections, context.allocator)

	env.prev_td = http.td
	http.td = &env.thread
}

destroy_upgrade_env :: proc(env: ^Upgrade_Test_Env) {
	xar.freelist_destroy(&env.thread.connections)
	http._server_thread_free_arenas_destroy(&env.thread)
	http.td = env.prev_td
	virtual.arena_destroy(&env.s.temp_allocator_backing)
}

push_test_connection :: proc(
	t: ^testing.T,
	env: ^Upgrade_Test_Env,
	socket: nbio.TCP_Socket = {},
	payload: string = "",
) -> ^http.Connection {
	c, err := xar.push(&env.thread.connections, http.Connection{
		socket            = socket,
		transaction_arena = http.get_arena(nil),
		temp_arena        = http.get_arena(nil),
	})
	testing.expect_value(t, err, nil)

	c.transaction_arena.c = c
	c.temp_arena.c        = c
	c.scanner.c           = c
	c.scanner.allocator   = &c.transaction_arena

	tx_alloc := http.transaction_allocator(c)
	c.vars.allocator         = tx_alloc
	c.req.headers.allocator  = tx_alloc
	c.res.headers.allocator  = tx_alloc
	c.res.buf.allocator      = tx_alloc
	c.res.deferred.allocator = tx_alloc

	c.req.quota = &env.s.opts.request_quota
	http.progression_init(&c.req.progress, c.req.quota^)
	c.res.quota = &env.s.opts.response_quota
	http.progression_init(&c.res.progress, c.res.quota^)

	if len(payload) > 0 {
		buf, buf_err := make([]byte, max(http.MULTIPLIER, len(payload)), tx_alloc)
		testing.expect_value(t, buf_err, nil)
		c.scanner.buf        = buf
		c.scanner.write_head = copy(buf, payload)
	}

	return c
}

active_connection_count :: proc(thread: ^http.Server_Thread) -> (count: int) {
	iter := xar.freelist_iterator(&thread.connections)
	for _, _ in xar.freelist_iterate_by_ptr(&iter) {
		count += 1
	}
	return
}

@(test)
test_send_heading_upgrade_flow :: proc(t: ^testing.T) {
	Upgrade_Check :: struct {
		on_sent_called:     bool,
		temp_alloc_matched: bool,
		last_err:           http.Send_Error,
		empty_quota:        http.Quota,
	}

	env: Upgrade_Test_Env
	setup_upgrade_env(t, &env)
	defer destroy_upgrade_env(&env)

	// 1. 101 Switching Protocols heading omits Content-Length and Connection: close,
	//    on_send in .Sending runs on_sent with temp_allocator and empty Quota{} clears limits.
	{
		c := push_test_connection(t, &env)
		defer http.connection_destroy(c)

		chk := http.context_add(&c.ctx, Upgrade_Check{})
		c.req.line.version      = {1, 1}
		c.req.has_consumed_body = true
		c.res.status            = .Switching_Protocols
		testing.expect_value(t, http.headers_set(&c.res.headers, "Upgrade", "websocket"), nil)
		testing.expect_value(t, http.headers_set(&c.res.headers, "Connection", "upgrade"), nil)

		http.write_response_heading(&c.res)
		heading := string(c.res.buf[:])
		testing.expect(t, strings.has_prefix(heading, "HTTP/1.1 101 Switching Protocols\r\n"), "expected 101 status line")
		testing.expect(t, !strings.contains(heading, "Content-Length:"), "expected no Content-Length on 101 heading")
		testing.expect(t, !strings.contains(heading, "Connection: close"), "expected no Connection: close on 101 heading")

		c.res.state = .Sending
		c.res.sends = 1

		op := nbio.Operation{
			type = .Send,
			send = {sent = len(c.res.buf)},
		}
		http.on_send(&op, c, proc(c: ^http.Connection, err: http.Send_Error) {
			chk := http.context_get(&c.ctx, Upgrade_Check)
			chk.on_sent_called     = true
			chk.last_err           = err
			chk.temp_alloc_matched = context.temp_allocator.data == http.temp_allocator(c).data

			http.request_set_quota(&c.req, &chk.empty_quota)
			http.response_set_quota(&c.res, &chk.empty_quota)
		})

		testing.expect(t, chk.on_sent_called, "expected on_sent callback after 101 flush")
		testing.expect_value(t, chk.last_err, nil)
		testing.expect(t, chk.temp_alloc_matched, "expected temp_allocator bound inside on_sent")
		testing.expect_value(t, c.res.state, type_of(c.res.state).Sending)
		testing.expect_value(t, c.res.sends, 0)
		testing.expect_value(t, active_connection_count(&env.thread), 1)
		testing.expect_value(t, c.req.progress.max, -1)
		testing.expect_value(t, c.req.progress.timeout, time.Duration(-1))
		testing.expect_value(t, c.res.progress.max, -1)
		testing.expect_value(t, c.res.progress.timeout, time.Duration(-1))
	}

	// 2. 0-byte send error via on_send transitions to .Error without tripping progression_update assert.
	{
		c := push_test_connection(t, &env)
		defer http.connection_destroy(c)

		chk := http.context_add(&c.ctx, Upgrade_Check{})
		c.res.state = .Sending
		c.res.sends = 2

		op := nbio.Operation{
			type = .Send,
			send = {sent = 0, err = nbio.TCP_Send_Error.Connection_Closed},
		}
		http.on_send(&op, c, proc(c: ^http.Connection, err: http.Send_Error) {
			chk := http.context_get(&c.ctx, Upgrade_Check)
			chk.on_sent_called = true
			chk.last_err       = err
		})

		testing.expect(t, chk.on_sent_called, "expected on_sent callback on error")
		testing.expect_value(t, chk.last_err, http.Send_Error(nbio.TCP_Send_Error.Connection_Closed))
		testing.expect_value(t, c.res.sends, 1)
		testing.expect_value(t, c.res.state, type_of(c.res.state).Error)
	}

	// 3. respond() on a 101 response transitions to .Sent while keeping status == .Switching_Protocols.
	{
		c := push_test_connection(t, &env)
		defer http.connection_destroy(c)

		c.res.status = .Switching_Protocols
		c.res.state  = .Sending
		c.res.sends  = 1
		http.respond(&c.res)
		testing.expect_value(t, c.res.state, type_of(c.res.state).Sent)
	}
}

@(test)
test_connection_close_waits_for_pending_sends :: proc(t: ^testing.T) {
	Close_State :: struct {
		calls: int,
	}

	env: Upgrade_Test_Env
	setup_upgrade_env(t, &env)
	defer destroy_upgrade_env(&env)

	// 1. connection_close with pending sends sets .Error, clears scan, ignores send/respond,
	//    and keeps connection alive while sends > 0.
	{
		c := push_test_connection(t, &env, payload = "abcdef")
		defer http.connection_destroy(c)

		st := http.context_add(&c.ctx, Close_State{})
		c.res.state = .Sending
		c.res.sends = 2
		c.scanner.scan = {
			split     = http.split_n(16),
			allocator = &c.temp_arena,
			callback  = proc(c: ^http.Connection, data: []byte) {},
		}
		testing.expect(t, c.scanner.scan.callback != nil, "expected pending scan before close")

		http.connection_close(c)
		testing.expect_value(t, c.res.state, type_of(c.res.state).Error)
		testing.expect(t, c.scanner.scan.callback == nil, "expected scanner scan cleared on connection_close")
		testing.expect_value(t, active_connection_count(&env.thread), 1)

		// Idempotent second call and safe no-ops after .Error.
		http.connection_close(c)
		payload := transmute([]byte)string("ignored")
		http.send(&c.res, {payload})
		http.respond(&c.res)
		testing.expect_value(t, c.res.sends, 2)
		testing.expect_value(t, c.res.state, type_of(c.res.state).Error)

		// First of two pending sends finishes: connection remains alive until sends hits 0.
		op1 := nbio.Operation{type = .Send, send = {sent = 8}}
		http.on_send(&op1, c, proc(c: ^http.Connection, err: http.Send_Error) {
			st := http.context_get(&c.ctx, Close_State)
			st.calls += 1
		})
		testing.expect_value(t, st.calls, 1)
		testing.expect_value(t, c.res.sends, 1)
		testing.expect_value(t, c.res.state, type_of(c.res.state).Error)
		testing.expect_value(t, active_connection_count(&env.thread), 1)
	}

	// 2. invalid_request in .Sending state marks .Error without writing an HTTP response heading.
	{
		c := push_test_connection(t, &env)
		defer http.connection_destroy(c)

		c.res.state = .Sending
		c.res.sends = 1
		http.invalid_request(c, .Request_Timeout)
		testing.expect_value(t, c.res.state, type_of(c.res.state).Error)
		testing.expect_value(t, len(c.res.buf), 0)
	}
}

@(test)
test_scanner_temp_allocator_and_destroy_in_callback :: proc(t: ^testing.T) {
	Frame_Loop_State :: struct {
		t:                  ^testing.T,
		frames:             int,
		last_byte:          u8,
		temp_alloc_matched: bool,
	}

	env: Upgrade_Test_Env
	setup_upgrade_env(t, &env)
	defer destroy_upgrade_env(&env)

	// 1. Transition from transaction_arena into temp_arena and scan 25 frames with
	//    free_all(context.temp_allocator); memory usage remains flat after warmup.
	{
		c := push_test_connection(t, &env, payload = "AAAA" + "BBBB" + "CCCC")
		defer http.connection_destroy(c)

		c.res.state = .Sending
		st := http.context_add(&c.ctx, Frame_Loop_State{t = t})

		scan_next_frame :: proc(c: ^http.Connection) {
			http.scan_temp_bytes(&c.scanner, 4, proc(c: ^http.Connection, data: []byte) {
				st := http.context_get(&c.ctx, Frame_Loop_State)
				testing.expect_value(st.t, len(data), 4)
				st.temp_alloc_matched = context.temp_allocator.data == http.temp_allocator(c).data
				st.last_byte = data[0]
				st.frames += 1

				scratch, serr := make([]byte, 256, context.temp_allocator)
				testing.expect_value(st.t, serr, nil)
				scratch[0] = data[0]

				free_all(context.temp_allocator)
			})
		}

		for i in 0 ..< 3 {
			scan_next_frame(c)
			testing.expect(t, st.temp_alloc_matched, "expected temp_allocator bound inside Scan_Cb")
			testing.expect_value(t, st.last_byte, u8('A' + i))
		}
		testing.expect_value(t, st.frames, 3)

		used_after_warmup := env.s.temp_allocator_backing.total_used

		for round in 0 ..< 22 {
			if c.scanner.buf == nil {
				buf, err := make([]byte, http.MULTIPLIER, http.temp_allocator(c))
				testing.expect_value(t, err, nil)
				c.scanner.buf        = buf
				c.scanner.read_head  = 0
				c.scanner.write_head = 0
			}
			frame_tag := u8('D' + (round % 20))
			for j in 0 ..< 4 {
				c.scanner.buf[c.scanner.write_head + j] = frame_tag
			}
			c.scanner.write_head += 4

			scan_next_frame(c)
			testing.expect_value(t, st.last_byte, frame_tag)
			testing.expect_value(t, env.s.temp_allocator_backing.total_used, used_after_warmup)
		}
		testing.expect_value(t, st.frames, 25)
	}

	// 2. Allocator switch on ok == false (transaction_arena -> unused temp_arena with tail == nil),
	//    and subsequent capacity < MULTIPLIER on temp_arena after free_all emptied s.buf.
	{
		c := push_test_connection(t, &env, payload = "hi")
		defer http.connection_destroy(c)

		c.res.state        = .Sending
		c.res.sends        = 1
		c.req.progress.max = 0

		http.scan_temp_bytes(&c.scanner, 16, proc(c: ^http.Connection, data: []byte) {})
		testing.expect_value(t, c.res.state, type_of(c.res.state).Error)
		testing.expect_value(t, c.scanner.allocator, &c.temp_arena)
		testing.expect(t, len(c.scanner.buf) >= http.MULTIPLIER, "expected scanner buffer allocated in temp_arena")
		testing.expect_value(t, string(c.scanner.buf[c.scanner.read_head:c.scanner.write_head]), "hi")

		c.res.state        = .Sending
		c.req.progress.max = -1
		http.scan_temp_bytes(&c.scanner, 2, proc(c: ^http.Connection, data: []byte) {
			free_all(context.temp_allocator)
		})
		testing.expect(t, c.scanner.buf == nil, "expected empty scanner buf after free_all")
		testing.expect(t, c.temp_arena.tail == nil, "expected empty temp_arena after free_all")

		c.req.progress.max = 0
		http.scan_temp_bytes(&c.scanner, 16, proc(c: ^http.Connection, data: []byte) {})
		testing.expect_value(t, c.res.state, type_of(c.res.state).Error)
		testing.expect(t, len(c.scanner.buf) >= http.MULTIPLIER, "expected fresh scanner buffer allocated")
	}

	// 3. Destroying connection from inside Scan_Cb during scanner_pump is ASAN-safe (_pump_destroyed).
	{
		c := push_test_connection(t, &env, payload = "bye!")
		c.res.state = .Sending

		http.scan_temp_bytes(&c.scanner, 4, proc(c: ^http.Connection, data: []byte) {
			http.connection_destroy(c)
		})
		testing.expect_value(t, active_connection_count(&env.thread), 0)
	}
}

@(test)
test_connection_detach :: proc(t: ^testing.T) {
	Detach_State :: struct {
		t:           ^testing.T,
		detached_fd: nbio.TCP_Socket,
		buffered:    []byte,
	}

	env: Upgrade_Test_Env
	setup_upgrade_env(t, &env)
	defer destroy_upgrade_env(&env)

	// 1. Direct connection_detach clones unread bytes, runs defers LIFO, and releases connection.
	{
		c := push_test_connection(t, &env, socket = nbio.TCP_Socket(42), payload = "HTTP\r\nWS\x81\x02hi")
		c.scanner.read_head = len("HTTP\r\n")

		order := make([dynamic]int, context.allocator)
		defer delete(order)
		http.context_add(&c.ctx, &order)

		http.response_defer(&c.ctx, proc(ctx: ^http.Ctx) {
			order := http.context_get(ctx, ^[dynamic]int)^
			append(order, 1)
		})
		http.response_defer(&c.ctx, proc(ctx: ^http.Ctx) {
			order := http.context_get(ctx, ^[dynamic]int)^
			append(order, 2)
		})

		sock, buffered, err := http.connection_detach(c, context.allocator)
		defer delete(buffered)

		testing.expect_value(t, err, nil)
		testing.expect_value(t, sock, nbio.TCP_Socket(42))
		testing.expect_value(t, string(buffered), "WS\x81\x02hi")
		testing.expect_value(t, len(order), 2)
		testing.expect_value(t, order[0], 2)
		testing.expect_value(t, order[1], 1)
		testing.expect_value(t, active_connection_count(&env.thread), 0)
	}

	// 2. Empty unread buffer returns buffered == nil.
	{
		c := push_test_connection(t, &env, socket = nbio.TCP_Socket(43), payload = "abc")
		c.scanner.read_head = 3

		sock, buffered, err := http.connection_detach(c, context.allocator)
		testing.expect_value(t, err, nil)
		testing.expect_value(t, sock, nbio.TCP_Socket(43))
		testing.expect(t, buffered == nil, "expected nil buffered slice when no unread bytes exist")
		testing.expect_value(t, active_connection_count(&env.thread), 0)
	}

	// 3. Detach from inside on_send's on_sent (.Sending, err == nil) and from inside Scan_Cb under ASAN.
	{
		c := push_test_connection(t, &env, socket = nbio.TCP_Socket(44), payload = "raw-tail")
		st := Detach_State{t = t}
		http.context_add(&c.ctx, &st)

		c.res.state = .Sending
		c.res.sends = 1

		op := nbio.Operation{type = .Send, send = {sent = 16}}
		http.on_send(&op, c, proc(c: ^http.Connection, send_err: http.Send_Error) {
			st := http.context_get(&c.ctx, ^Detach_State)^
			testing.expect_value(st.t, send_err, nil)
			err: runtime.Allocator_Error
			st.detached_fd, st.buffered, err = http.connection_detach(c, context.allocator)
			testing.expect_value(st.t, err, nil)
		})
		defer delete(st.buffered)

		testing.expect_value(t, st.detached_fd, nbio.TCP_Socket(44))
		testing.expect_value(t, string(st.buffered), "raw-tail")
		testing.expect_value(t, active_connection_count(&env.thread), 0)
	}
	{
		c := push_test_connection(t, &env, socket = nbio.TCP_Socket(45), payload = "HDR!TAIL")
		c.res.state = .Sending
		st := Detach_State{t = t}
		http.context_add(&c.ctx, &st)

		http.scan_temp_bytes(&c.scanner, 4, proc(c: ^http.Connection, data: []byte) {
			st := http.context_get(&c.ctx, ^Detach_State)^
			testing.expect_value(st.t, string(data), "HDR!")
			err: runtime.Allocator_Error
			st.detached_fd, st.buffered, err = http.connection_detach(c, context.allocator)
			testing.expect_value(st.t, err, nil)
		})
		defer delete(st.buffered)

		testing.expect_value(t, st.detached_fd, nbio.TCP_Socket(45))
		testing.expect_value(t, string(st.buffered), "TAIL")
		testing.expect_value(t, active_connection_count(&env.thread), 0)
	}
}
