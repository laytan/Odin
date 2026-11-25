package test_core_net_http

import "base:runtime"
import "base:sanitizer"

import "core:container/xar"
import "core:log"
import "core:mem"
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
	c._vars.allocator         = tx_alloc
	c.req.headers.allocator  = tx_alloc
	c.res.headers.allocator  = tx_alloc
	c.res._buf.allocator      = tx_alloc
	c.res._deferred.allocator = tx_alloc

	http.progression_init(&c.req.progress, &env.s.opts.request_quota)
	http.progression_init(&c.res.progress, &env.s.opts.response_quota)

	if len(payload) > 0 {
		buf, buf_err := make([]byte, max(http.MULTIPLIER, len(payload)), tx_alloc)
		testing.expect_value(t, buf_err, nil)
		c.scanner.buf        = buf
		c.scanner.write_head = copy(buf, payload)
	}

	return c
}

destroy_test_connection :: proc(c: ^http.Connection) {
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
		defer http._connection_destroy(c)

		chk := http.context_add(&c.ctx, Upgrade_Check{})
		c.req.line.version      = {1, 1}
		c.req.has_consumed_body = true
		c.res.status            = .Switching_Protocols
		testing.expect_value(t, http.headers_set(&c.res.headers, "Upgrade", "websocket"), nil)
		testing.expect_value(t, http.headers_set(&c.res.headers, "Connection", "upgrade"), nil)

		http.write_response_heading(&c.ctx)
		heading := string(c.res._buf[:])
		testing.expect(t, strings.has_prefix(heading, "HTTP/1.1 101 Switching Protocols\r\n"), "expected 101 status line")
		testing.expect(t, !strings.contains(heading, "Content-Length:"), "expected no Content-Length on 101 heading")
		testing.expect(t, !strings.contains(heading, "Connection: close"), "expected no Connection: close on 101 heading")

		c.res._state = .Sending
		c.res._sends = 1

		op := nbio.Operation{
			type = .Send,
			send = {sent = len(c.res._buf)},
		}
		http.on_send(&op, c, proc(ctx: ^http.Ctx, err: http.Send_Error) {
			chk := http.context_get(ctx, Upgrade_Check)
			c   := http._connection_of_context(ctx)
			chk.on_sent_called     = true
			chk.last_err           = err
			chk.temp_alloc_matched = context.temp_allocator.data == http.temp_allocator(c).data

			http.request_set_quota(&c.req, &chk.empty_quota)
			http.response_set_quota(&c.res, &chk.empty_quota)
		})

		testing.expect(t, chk.on_sent_called, "expected on_sent callback after 101 flush")
		testing.expect_value(t, chk.last_err, nil)
		testing.expect(t, chk.temp_alloc_matched, "expected temp_allocator bound inside on_sent")
		testing.expect_value(t, c.res._state, type_of(c.res._state).Sending)
		testing.expect_value(t, c.res._sends, 0)
		testing.expect_value(t, active_connection_count(&env.thread), 1)
		testing.expect_value(t, c.req.progress.max, -1)
		testing.expect_value(t, c.req.progress.timeout, time.Duration(-1))
		testing.expect_value(t, c.res.progress.max, -1)
		testing.expect_value(t, c.res.progress.timeout, time.Duration(-1))
	}

	// 2. 0-byte send error via on_send transitions to .Error without tripping progression_update assert.
	{
		c := push_test_connection(t, &env)
		defer destroy_test_connection(c)

		chk := http.context_add(&c.ctx, Upgrade_Check{})
		c.res._state = .Sending
		c.res._sends = 2

		op := nbio.Operation{
			type = .Send,
			send = {sent = 0, err = nbio.TCP_Send_Error.Connection_Closed},
		}
		http.on_send(&op, c, proc(ctx: ^http.Ctx, err: http.Send_Error) {
			chk := http.context_get(ctx, Upgrade_Check)
			chk.on_sent_called = true
			chk.last_err       = err
		})

		testing.expect(t, chk.on_sent_called, "expected on_sent callback on error")
		testing.expect_value(t, chk.last_err, http.Send_Error(nbio.TCP_Send_Error.Connection_Closed))
		testing.expect_value(t, c.res._sends, 1)
		testing.expect_value(t, c.res._state, type_of(c.res._state).Error)
	}

	// 3. respond() on a 101 response transitions to .Sent while keeping status == .Switching_Protocols.
	{
		c := push_test_connection(t, &env)
		defer destroy_test_connection(c)

		c.res.status = .Switching_Protocols
		c.res._state  = .Sending
		c.res._sends  = 1
		http.respond(&c.ctx)
		testing.expect_value(t, c.res._state, type_of(c.res._state).Sent)
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
		defer destroy_test_connection(c)

		st := http.context_add(&c.ctx, Close_State{})
		c.res._state = .Sending
		c.res._sends = 2
		c.scanner.scan = {
			split     = http.split_n(16),
			allocator = &c.temp_arena,
			callback  = proc(c: ^http.Connection, data: []byte) {},
		}
		testing.expect(t, c.scanner.scan.callback != nil, "expected pending scan before close")

		http.connection_close(c)
		testing.expect_value(t, c.res._state, type_of(c.res._state).Error)
		testing.expect(t, c.scanner.scan.callback == nil, "expected scanner scan cleared on connection_close")
		testing.expect_value(t, active_connection_count(&env.thread), 1)

		// Idempotent second call and safe no-ops after .Error.
		http.connection_close(c)
		payload := transmute([]byte)string("ignored")
		http.send(&c.ctx, {payload})
		http.respond(&c.ctx)
		testing.expect_value(t, c.res._sends, 2)
		testing.expect_value(t, c.res._state, type_of(c.res._state).Error)

		// First of two pending sends finishes: connection remains alive until sends hits 0.
		op1 := nbio.Operation{type = .Send, send = {sent = 8}}
		http.on_send(&op1, c, proc(ctx: ^http.Ctx, err: http.Send_Error) {
			st := http.context_get(ctx, Close_State)
			st.calls += 1
		})
		testing.expect_value(t, st.calls, 1)
		testing.expect_value(t, c.res._sends, 1)
		testing.expect_value(t, c.res._state, type_of(c.res._state).Error)
		testing.expect_value(t, active_connection_count(&env.thread), 1)
	}

	// 2. invalid_request in .Sending state marks .Error without writing an HTTP response heading.
	{
		c := push_test_connection(t, &env)
		defer destroy_test_connection(c)

		c.res._state = .Sending
		c.res._sends = 1
		http.invalid_request(c, .Request_Timeout)
		testing.expect_value(t, c.res._state, type_of(c.res._state).Error)
		testing.expect_value(t, len(c.res._buf), 0)
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
		prev_alloc := env.s.allocator
		counter := Arena_Counting_Allocator{backing = prev_alloc}
		env.s.allocator = arena_counting_allocator(&counter)
		defer {
			http._server_thread_free_arenas_destroy(&env.thread)
			env.s.allocator = prev_alloc
		}

		c := push_test_connection(t, &env, payload = "AAAA" + "BBBB" + "CCCC")
		defer http._connection_destroy(c)

		c.res._state = .Sending
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

		allocs_after_warmup := counter.alloc_count

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
			testing.expect_value(t, counter.alloc_count, allocs_after_warmup)
		}
		testing.expect_value(t, st.frames, 25)
	}

	// 2. Allocator switch on ok == false (transaction_arena -> unused temp_arena with tail == nil),
	//    and subsequent capacity < MULTIPLIER on temp_arena after free_all emptied s.buf.
	{
		c := push_test_connection(t, &env, payload = "hi")
		defer destroy_test_connection(c)

		c.res._state           = .Sending
		c.res._sends           = 1
		c.req.progress.max     = -1
		c.req.progress.timeout = -1

		c.scanner.scan = {
			split     = http.split_n(16),
			allocator = &c.temp_arena,
			callback  = proc(c: ^http.Connection, data: []byte) {},
		}
		testing.expect(t, http._scanner_pump_buffered(&c.scanner))
		testing.expect(t, http._scanner_prepare_recv_buf(&c.scanner))
		testing.expect_value(t, c.res._state, type_of(c.res._state).Sending)
		testing.expect_value(t, c.scanner.allocator, &c.temp_arena)
		testing.expect(t, len(c.scanner.buf) >= http.MULTIPLIER, "expected scanner buffer allocated in temp_arena")
		testing.expect_value(t, string(c.scanner.buf[c.scanner.read_head:c.scanner.write_head]), "hi")

		http.scan_temp_bytes(&c.scanner, 2, proc(c: ^http.Connection, data: []byte) {
			free_all(context.temp_allocator)
		})
		testing.expect(t, c.scanner.buf == nil, "expected empty scanner buf after free_all")
		testing.expect(t, c.temp_arena.tail == nil, "expected empty temp_arena after free_all")

		c.scanner.scan = {
			split     = http.split_n(16),
			allocator = &c.temp_arena,
			callback  = proc(c: ^http.Connection, data: []byte) {},
		}
		testing.expect(t, http._scanner_pump_buffered(&c.scanner))
		testing.expect(t, http._scanner_prepare_recv_buf(&c.scanner))
		testing.expect_value(t, c.res._state, type_of(c.res._state).Sending)
		testing.expect(t, len(c.scanner.buf) >= http.MULTIPLIER, "expected fresh scanner buffer allocated")
	}

	// 3. Destroying connection from inside Scan_Cb during scanner_pump is ASAN-safe (_destroy_flag).
	{
		c := push_test_connection(t, &env, payload = "bye!")
		c.res._state = .Sending

		http.scan_temp_bytes(&c.scanner, 4, proc(c: ^http.Connection, data: []byte) {
			http._connection_destroy(c)
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

		sock, buffered, err := http.connection_detach(&c.ctx, context.allocator)
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

		sock, buffered, err := http.connection_detach(&c.ctx, context.allocator)
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

		c.res._state = .Sending
		c.res._sends = 1

		op := nbio.Operation{type = .Send, send = {sent = 16}}
		http.on_send(&op, c, proc(ctx: ^http.Ctx, send_err: http.Send_Error) {
			st := http.context_get(ctx, ^Detach_State)^
			testing.expect_value(st.t, send_err, nil)
			err: runtime.Allocator_Error
			st.detached_fd, st.buffered, err = http.connection_detach(ctx, context.allocator)
			testing.expect_value(st.t, err, nil)
		})
		defer delete(st.buffered)

		testing.expect_value(t, st.detached_fd, nbio.TCP_Socket(44))
		testing.expect_value(t, string(st.buffered), "raw-tail")
		testing.expect_value(t, active_connection_count(&env.thread), 0)
	}
	{
		c := push_test_connection(t, &env, socket = nbio.TCP_Socket(45), payload = "HDR!TAIL")
		c.res._state = .Sending
		st := Detach_State{t = t}
		http.context_add(&c.ctx, &st)

		http.scan_temp_bytes(&c.scanner, 4, proc(c: ^http.Connection, data: []byte) {
			st := http.context_get(&c.ctx, ^Detach_State)^
			testing.expect_value(st.t, string(data), "HDR!")
			err: runtime.Allocator_Error
			st.detached_fd, st.buffered, err = http.connection_detach(&c.ctx, context.allocator)
			testing.expect_value(st.t, err, nil)
		})
		defer delete(st.buffered)

		testing.expect_value(t, st.detached_fd, nbio.TCP_Socket(45))
		testing.expect_value(t, string(st.buffered), "TAIL")
		testing.expect_value(t, active_connection_count(&env.thread), 0)
	}
}

@(test)
test_response_defer_binds_connection_temp_allocator :: proc(t: ^testing.T) {
	Defer_Check :: struct {
		ran:     bool,
		matched: bool,
	}

	env: Upgrade_Test_Env
	setup_upgrade_env(t, &env)
	defer destroy_upgrade_env(&env)

	outer_buf: [1024]byte
	outer_arena: mem.Arena
	mem.arena_init(&outer_arena, outer_buf[:])
	prev_temp := context.temp_allocator
	context.temp_allocator = mem.arena_allocator(&outer_arena)
	defer context.temp_allocator = prev_temp

	run_check_defer :: proc(ctx: ^http.Ctx) {
		chk := http.context_get(ctx, ^Defer_Check)^
		c := http._connection_of_context(ctx)
		chk.ran     = true
		chk.matched = context.temp_allocator.data == http.temp_allocator(c).data

		scratch, err := make([]byte, 64, context.temp_allocator)
		assert(err == nil && len(scratch) == 64)
		assert(c.temp_arena.tail != nil)
	}

	// 1. _connection_destroy binds context.temp_allocator = temp_allocator(c) for defers and reclaims blocks.
	{
		c := push_test_connection(t, &env)
		chk: Defer_Check
		http.context_add(&c.ctx, &chk)
		http.response_defer(&c.ctx, run_check_defer)

		http._connection_destroy(c)

		testing.expect(t, chk.ran, "expected response_defer to run on _connection_destroy")
		testing.expect(t, chk.matched, "expected temp_allocator(c) bound inside _connection_destroy defer")
		testing.expect_value(t, outer_arena.offset, 0)
		testing.expect_value(t, active_connection_count(&env.thread), 0)
		testing.expect(t, env.thread.free_arenas[0].head != nil, "expected arena blocks returned to thread freelist")
	}

	// 2. connection_detach binds context.temp_allocator = temp_allocator(c) for defers.
	{
		c := push_test_connection(t, &env, socket = nbio.TCP_Socket(77), payload = "tail")
		chk: Defer_Check
		http.context_add(&c.ctx, &chk)
		http.response_defer(&c.ctx, run_check_defer)

		sock, buffered, derr := http.connection_detach(&c.ctx, context.allocator)
		defer delete(buffered)

		testing.expect_value(t, derr, nil)
		testing.expect_value(t, sock, nbio.TCP_Socket(77))
		testing.expect_value(t, string(buffered), "tail")
		testing.expect(t, chk.ran, "expected response_defer to run on connection_detach")
		testing.expect(t, chk.matched, "expected temp_allocator(c) bound inside connection_detach defer")
		testing.expect_value(t, outer_arena.offset, 0)
		testing.expect_value(t, active_connection_count(&env.thread), 0)
	}
}

@(test)
test_scanner_free_all_pins_buf_while_recv_in_flight :: proc(t: ^testing.T) {
	env: Upgrade_Test_Env
	setup_upgrade_env(t, &env)
	defer destroy_upgrade_env(&env)

	c := push_test_connection(t, &env)
	defer http._connection_destroy(c)

	dummy_recv: nbio.Operation
	defer c.curr_recv = nil

	buf, buf_err := make([]byte, http.MULTIPLIER, http.temp_allocator(c))
	testing.expect_value(t, buf_err, nil)
	buf[0] = 'x'
	buf[1] = 'y'
	c.scanner.allocator  = &c.temp_arena
	c.scanner.buf        = buf
	c.scanner.read_head  = 0
	c.scanner.write_head = 2

	orig_buf_ptr := raw_data(c.scanner.buf)
	orig_block   := c.temp_arena.tail
	testing.expect(t, orig_block != nil, "expected scanner buffer block in temp_arena")

	c.curr_recv = &dummy_recv

	scratch1, err1 := make([]byte, 128, http.temp_allocator(c))
	testing.expect_value(t, err1, nil)
	scratch1[0] = 1

	scratch2, err2 := make([]byte, 5000, http.temp_allocator(c))
	testing.expect_value(t, err2, nil)
	scratch2[0] = 2
	testing.expect(t, c.temp_arena.tail != orig_block, "expected 5000-byte allocation to push an 8 KiB overflow block")

	free_all(http.temp_allocator(c))

	testing.expect(t, raw_data(c.scanner.buf) == orig_buf_ptr, "expected scanner buffer pointer preserved while recv is in flight")
	testing.expect_value(t, c.scanner.read_head, 0)
	testing.expect_value(t, c.scanner.write_head, 2)
	testing.expect_value(t, string(c.scanner.buf[:2]), "xy")
	testing.expect(t, c.temp_arena.tail == orig_block, "expected pinned block to become temp_arena.tail")
	testing.expect(t, orig_block.prev == nil, "expected overflow block unlinked from pinned block")
	testing.expect(t, env.thread.free_arenas[1].head != nil, "expected 8 KiB overflow block returned to thread freelist")
	testing.expect(t, sanitizer.address_region_is_poisoned(c.scanner.buf) == nil, "expected pinned scanner buffer to remain unpoisoned")

	expected_offset := int(uintptr(raw_data(c.scanner.buf)) - uintptr(raw_data(orig_block.data))) + len(c.scanner.buf)
	testing.expect_value(t, orig_block.offset, expected_offset)
	testing.expect(t, orig_block.last == raw_data(c.scanner.buf), "expected orig_block.last set to scanner buffer")

	reused, reuse_err := make([]byte, 64, http.temp_allocator(c))
	testing.expect_value(t, reuse_err, nil)
	reused[0] = 3
	testing.expect(t, c.temp_arena.tail == orig_block, "expected trailing space in pinned block to be reused after rewind")

	c.curr_recv = nil
	c.scanner.read_head = 2
	free_all(http.temp_allocator(c))
	testing.expect(t, c.scanner.buf == nil, "expected empty scanner buf cleared once curr_recv == nil")
	testing.expect(t, c.temp_arena.tail == nil, "expected temp_arena freed once curr_recv == nil")
}

@(test)
test_oom_paths_teardown_cleanly :: proc(t: ^testing.T) {
	Fail_Toggle_Allocator :: struct {
		backing: mem.Allocator,
		fail:    bool,
	}

	fail_toggle_allocator :: proc(ft: ^Fail_Toggle_Allocator) -> mem.Allocator {
		return {
			data = ft,
			procedure = proc(
				allocator_data: rawptr,
				mode: mem.Allocator_Mode,
				size, alignment: int,
				old_memory: rawptr,
				old_size: int,
				location := #caller_location,
			) -> ([]byte, mem.Allocator_Error) {
				ft := (^Fail_Toggle_Allocator)(allocator_data)
				if ft.fail {
					#partial switch mode {
					case .Alloc, .Alloc_Non_Zeroed, .Resize, .Resize_Non_Zeroed:
						return nil, .Out_Of_Memory
					}
				}
				return ft.backing.procedure(ft.backing.data, mode, size, alignment, old_memory, old_size, location)
			},
		}
	}

	make_oom_conn :: proc(t: ^testing.T, s: ^http.Server, thread: ^http.Server_Thread) -> ^http.Connection {
		c, err := xar.push(&thread.connections, http.Connection{
			transaction_arena = http.get_arena(nil),
			temp_arena        = http.get_arena(nil),
		})
		testing.expect_value(t, err, nil)

		c.transaction_arena.c = c
		c.temp_arena.c        = c
		c.scanner.c           = c
		c.scanner.allocator   = &c.transaction_arena

		tx_alloc := http.transaction_allocator(c)
		c._vars.allocator         = tx_alloc
		c.req.headers.allocator  = tx_alloc
		c.res.headers.allocator  = tx_alloc
		c.res._buf.allocator      = tx_alloc
		c.res._deferred.allocator = tx_alloc

		http.progression_init(&c.req.progress, &s.opts.request_quota)
		http.progression_init(&c.res.progress, &s.opts.response_quota)
		return c
	}

	// 1. context_add, response_defer, mid-heading write_response_heading OOM, and send_heading teardown.
	{
		ft := Fail_Toggle_Allocator{backing = context.allocator}
		s := http.make_server({}, fail_toggle_allocator(&ft))

		thread := http.Server_Thread{s = &s, id = 1}
		http.date_write(thread.date[:], time.now())
		xar.init(&thread.connections, context.allocator)
		defer xar.freelist_destroy(&thread.connections)

		prev_td := http.td
		http.td = &thread
		defer http.td = prev_td
		defer http._server_thread_free_arenas_destroy(&thread)

		c := make_oom_conn(t, &s, &thread)
		http._server_thread_free_arenas_destroy(&thread)
		ft.fail = true

		ptr, add_err := http.context_add(&c.ctx, int(42))
		testing.expect_value(t, add_err, runtime.Allocator_Error.Out_Of_Memory)
		testing.expect(t, ptr == nil, "expected nil pointer from context_add on OOM")
		testing.expect_value(t, len(c._vars), 0)

		def_err := http.response_defer(&c.ctx, proc(ctx: ^http.Ctx) {})
		testing.expect_value(t, def_err, runtime.Allocator_Error.Out_Of_Memory)
		testing.expect_value(t, len(c.res._deferred), 0)

		def_small_err := http.response_defer(&c.ctx, u32(7), proc(_: ^http.Ctx, _: u32) {})
		testing.expect_value(t, def_small_err, runtime.Allocator_Error.Out_Of_Memory)
		testing.expect_value(t, len(c.res._deferred), 0)

		Large_Defer :: struct {
			a, b, c: int,
		}
		def_large_err := http.response_defer(&c.ctx, Large_Defer{1, 2, 3}, proc(_: ^http.Ctx, _: Large_Defer) {})
		testing.expect_value(t, def_large_err, runtime.Allocator_Error.Out_Of_Memory)
		testing.expect_value(t, len(c.res._deferred), 0)

		small_buf: [24]byte
		small_arena: mem.Arena
		mem.arena_init(&small_arena, small_buf[:])
		c.res._buf.allocator = mem.arena_allocator(&small_arena)
		c.res.status = .OK
		c.res._state = .Handling

		hdr_err := http.write_response_heading(&c.ctx)
		testing.expect_value(t, hdr_err, runtime.Allocator_Error.Out_Of_Memory)
		testing.expect_value(t, len(c.res._buf), 0)

		c.res._buf = {}
		c.res._buf.allocator = http.transaction_allocator(c)
		prev_logger := context.logger
		context.logger = log.nil_logger()
		http.send_heading(&c.ctx)
		context.logger = prev_logger
		testing.expect_value(t, active_connection_count(&thread), 0)
	}

	// 2. scanner_reset OOM, _scanner_free_all OOM fallback pinning, and scanner_pump OOM teardown.
	{
		ft := Fail_Toggle_Allocator{backing = context.allocator}
		s := http.make_server({}, fail_toggle_allocator(&ft))

		thread := http.Server_Thread{s = &s, id = 1}
		http.date_write(thread.date[:], time.now())
		xar.init(&thread.connections, context.allocator)
		defer xar.freelist_destroy(&thread.connections)

		prev_td := http.td
		http.td = &thread
		defer http.td = prev_td
		defer http._server_thread_free_arenas_destroy(&thread)

		c := make_oom_conn(t, &s, &thread)
		c.scanner.allocator = &c.temp_arena

		buf, buf_err := make([]byte, http.MULTIPLIER, http.temp_allocator(c))
		testing.expect_value(t, buf_err, nil)
		c.scanner.buf        = buf
		c.scanner.read_head  = 0
		c.scanner.write_head = copy(buf, "hello")
		orig_block := c.temp_arena.tail

		// Push an 8 KiB overflow block into temp_arena so free_all OOM fallback reclaims it.
		overflow, ov_err := make([]byte, 5000, http.temp_allocator(c))
		testing.expect_value(t, ov_err, nil)
		overflow[0] = 1
		testing.expect(t, c.temp_arena.tail != orig_block, "expected overflow block in temp_arena")

		http._server_thread_free_arenas_destroy(&thread)
		ft.fail = true

		reset_err := http.scanner_reset(&c.scanner, c)
		testing.expect_value(t, reset_err, runtime.Allocator_Error.Out_Of_Memory)
		testing.expect_value(t, string(c.scanner.buf[c.scanner.read_head:c.scanner.write_head]), "hello")

		free_all(http.temp_allocator(c))
		testing.expect(t, c.temp_arena.tail == orig_block, "expected _scanner_free_all OOM fallback to pin existing buf block")
		testing.expect(t, thread.free_arenas[1].head != nil, "expected 8 KiB overflow block returned to thread freelist")
		testing.expect(t, sanitizer.address_region_is_poisoned(c.scanner.buf) == nil, "expected pinned scanner buffer unpoisoned")
		testing.expect_value(t, string(c.scanner.buf[c.scanner.read_head:c.scanner.write_head]), "hello")

		http._server_thread_free_arenas_destroy(&thread)
		c.res._state = .Handling
		prev_logger := context.logger
		context.logger = log.nil_logger()
		http.scan_bytes(&c.scanner, 16, proc(c: ^http.Connection, data: []byte) {})
		context.logger = prev_logger
		testing.expect_value(t, active_connection_count(&thread), 0)
	}
}

@(test)
test_on_send_destroy_and_detach_in_callback_on_error :: proc(t: ^testing.T) {
	Cb_State :: struct {
		called:      bool,
		scan_called: bool,
		got_err:     http.Send_Error,
		detached_fd: nbio.TCP_Socket,
		buffered:    []byte,
		got_bytes:   [4]byte,
	}

	env: Upgrade_Test_Env
	setup_upgrade_env(t, &env)
	defer destroy_upgrade_env(&env)

	// 1. on_sent calls _connection_destroy(c) when err != nil; no double-destroy or UAF.
	{
		c := push_test_connection(t, &env)
		st: Cb_State
		http.context_add(&c.ctx, &st)
		c.res._state = .Sending
		c.res._sends = 1

		op := nbio.Operation{
			type = .Send,
			send = {sent = 0, err = nbio.TCP_Send_Error.Connection_Closed},
		}
		http.on_send(&op, c, proc(ctx: ^http.Ctx, err: http.Send_Error) {
			st := http.context_get(ctx, ^Cb_State)^
			st.called  = true
			st.got_err = err
			http._connection_destroy(http._connection_of_context(ctx))
		})

		testing.expect(t, st.called, "expected on_sent callback to run on send error")
		testing.expect_value(t, st.got_err, http.Send_Error(nbio.TCP_Send_Error.Connection_Closed))
		testing.expect_value(t, active_connection_count(&env.thread), 0)
	}

	// 2. on_sent calls connection_detach(c) when err != nil; clones unread bytes and skips _check_send_done.
	{
		c := push_test_connection(t, &env, socket = nbio.TCP_Socket(88), payload = "leftover")
		st: Cb_State
		http.context_add(&c.ctx, &st)
		c.res._state = .Sending
		c.res._sends = 1

		op := nbio.Operation{
			type = .Send,
			send = {sent = 0, err = nbio.TCP_Send_Error.Connection_Closed},
		}
		http.on_send(&op, c, proc(ctx: ^http.Ctx, err: http.Send_Error) {
			st := http.context_get(ctx, ^Cb_State)^
			st.called  = true
			st.got_err = err
			derr: runtime.Allocator_Error
			st.detached_fd, st.buffered, derr = http.connection_detach(ctx, context.allocator)
			assert(derr == nil)
		})
		defer delete(st.buffered)

		testing.expect(t, st.called, "expected on_sent callback to run on send error")
		testing.expect_value(t, st.got_err, http.Send_Error(nbio.TCP_Send_Error.Connection_Closed))
		testing.expect_value(t, st.detached_fd, nbio.TCP_Socket(88))
		testing.expect_value(t, string(st.buffered), "leftover")
		testing.expect_value(t, active_connection_count(&env.thread), 0)
	}

	// 3. Nested on_send (err != nil) -> on_sent -> scan_temp_bytes -> Scan_Cb -> _connection_destroy(c).
	{
		c := push_test_connection(t, &env, payload = "ABCD")
		st: Cb_State
		http.context_add(&c.ctx, &st)
		c.res._state = .Sending
		c.res._sends = 1

		op := nbio.Operation{
			type = .Send,
			send = {sent = 0, err = nbio.TCP_Send_Error.Connection_Closed},
		}
		http.on_send(&op, c, proc(ctx: ^http.Ctx, err: http.Send_Error) {
			st := http.context_get(ctx, ^Cb_State)^
			c  := http._connection_of_context(ctx)
			st.called  = true
			st.got_err = err
			http.scan_temp_bytes(&c.scanner, 4, proc(c: ^http.Connection, data: []byte) {
				st := http.context_get(&c.ctx, ^Cb_State)^
				st.scan_called = true
				copy(st.got_bytes[:], data)
				http._connection_destroy(c)
			})
		})

		testing.expect(t, st.called, "expected outer on_sent callback to run")
		testing.expect(t, st.scan_called, "expected nested scan_temp_bytes callback to run")
		testing.expect_value(t, st.got_err, http.Send_Error(nbio.TCP_Send_Error.Connection_Closed))
		testing.expect_value(t, string(st.got_bytes[:]), "ABCD")
		testing.expect_value(t, active_connection_count(&env.thread), 0)
	}
}

@(test)
test_body_partial_detach_in_callback :: proc(t: ^testing.T) {
	Body_Detach_State :: struct {
		called:      bool,
		is_partial:  bool,
		got_chunk:   [16]byte,
		got_len:     int,
		detached_fd: nbio.TCP_Socket,
		buffered:    []byte,
		detach_err:  runtime.Allocator_Error,
	}

	Body_Case :: struct {
		name:    string,
		hdr_key: string,
		hdr_val: string,
		payload: string,
		socket:  nbio.TCP_Socket,
	}

	env: Upgrade_Test_Env
	setup_upgrade_env(t, &env)
	defer destroy_upgrade_env(&env)

	cases := []Body_Case{
		{"content-length", "Content-Length", "10", "hello", nbio.TCP_Socket(91)},
		{"chunked", "Transfer-Encoding", "chunked", "a\r\nhello", nbio.TCP_Socket(92)},
	}

	for tc in cases {
		c := push_test_connection(t, &env, socket = tc.socket, payload = tc.payload)
		c.req.line              = {method = .Post, target = "/upload", version = {1, 1}}
		c.res._state            = .Handling
		c.req.has_consumed_body = false
		http.progression_init(&c.req.progress, &env.s.opts.body_quota)
		testing.expect_value(t, http.headers_set(&c.req.headers, tc.hdr_key, tc.hdr_val), nil)
		http._headers_set_readonly(&c.req.headers)

		st: Body_Detach_State
		http.context_add(&c.ctx, &st)

		http.body(&c.ctx, proc(ctx: ^http.Ctx, data: []byte, is_partial: bool) {
			st := http.context_get(ctx, ^Body_Detach_State)^
			st.called     = true
			st.is_partial = is_partial
			st.got_len    = copy(st.got_chunk[:], data)
			st.detached_fd, st.buffered, st.detach_err = http.connection_detach(ctx, context.allocator)
		})
		defer delete(st.buffered)

		testing.expectf(t, st.called, "%s: expected partial Body_Cb to run", tc.name)
		testing.expectf(t, st.is_partial, "%s: expected is_partial == true", tc.name)
		testing.expect_value(t, string(st.got_chunk[:st.got_len]), "hello")
		testing.expect_value(t, st.detach_err, nil)
		testing.expect_value(t, st.detached_fd, tc.socket)
		testing.expect(t, st.buffered == nil, "expected no unread bytes left after partial chunk")
		testing.expect_value(t, active_connection_count(&env.thread), 0)
	}
}

@(test)
test_keepalive_deferred_lifo_and_next_request :: proc(t: ^testing.T) {
	Defer_Keepalive_State :: struct {
		order:        [dynamic]int,
		temp_matched: bool,
	}

	env: Upgrade_Test_Env
	setup_upgrade_env(t, &env)
	defer destroy_upgrade_env(&env)

	c := push_test_connection(t, &env, payload = "next")
	defer http._connection_destroy(c)

	c.req.line              = {method = .Get, target = "/", version = {1, 1}}
	c.req.has_consumed_body = true
	c.res._state            = .Sent
	c.res._sends            = 0
	// Keep scanner pumping so _serve_connection's scan_line doesn't arm an nbio.recv on the mock socket.
	c.scanner.is_pumping    = true

	st := Defer_Keepalive_State{
		order = make([dynamic]int, context.allocator),
	}
	defer delete(st.order)
	http.context_add(&c.ctx, &st)

	http.response_defer(&c.ctx, proc(ctx: ^http.Ctx) {
		st := http.context_get(ctx, ^Defer_Keepalive_State)^
		append(&st.order, 1)
	})
	http.response_defer(&c.ctx, proc(ctx: ^http.Ctx) {
		st := http.context_get(ctx, ^Defer_Keepalive_State)^
		c  := http._connection_of_context(ctx)
		st.temp_matched = context.temp_allocator.data == http.temp_allocator(c).data
		append(&st.order, 2)
		http.response_defer(ctx, proc(ctx: ^http.Ctx) {
			st := http.context_get(ctx, ^Defer_Keepalive_State)^
			append(&st.order, 3)
		})
	})

	http._check_send_done(c)

	testing.expect(t, st.temp_matched, "expected temp_allocator(c) bound during keep-alive response_defer")
	testing.expect_value(t, len(st.order), 3)
	if len(st.order) == 3 {
		testing.expect_value(t, st.order[0], 2)
		testing.expect_value(t, st.order[1], 3)
		testing.expect_value(t, st.order[2], 1)
	}
	testing.expect_value(t, len(c.res._deferred), 0)
	testing.expect_value(t, string(c.scanner.buf[c.scanner.read_head:c.scanner.write_head]), "next")
	testing.expect_value(t, active_connection_count(&env.thread), 1)
}

@(test)
test_response_defer_with_user_data :: proc(t: ^testing.T) {
	Event :: struct {
		kind: string,
		u16v: u16,
		nsec: i64,
		tag:  string,
		n:    int,
	}

	Large_Payload :: struct {
		out: ^[dynamic]Event,
		tag: string,
		n:   int,
	}

	Small_Payload :: struct {
		out: ^[dynamic]Event,
		v:   u16,
	}

	env: Upgrade_Test_Env
	setup_upgrade_env(t, &env)
	defer destroy_upgrade_env(&env)

	c := push_test_connection(t, &env)
	defer http._connection_destroy(c)
	c.req.line              = {method = .Get, target = "/", version = {1, 1}}
	c.req.has_consumed_body = true
	c.res._state            = .Sent
	c.res._sends            = 0
	c.scanner.is_pumping    = true

	events := make([dynamic]Event, context.allocator)
	defer delete(events)

	// Pre-reserve _deferred so inline response_defer calls measure strictly 0 extra tx arena growth.
	reserve(&c.res._deferred, 8)
	tx_tail_before   := c.transaction_arena.tail
	tx_offset_before := tx_tail_before.offset

	testing.expect_value(t, http.response_defer(&c.ctx, &events, proc(_: ^http.Ctx, ev: ^[dynamic]Event) {
		append(ev, Event{kind = "ptr"})
	}), nil)

	// Sub-pointer-width integer packed inline into _Deferred.data.
	sub_val := Small_Payload{out = &events, v = 0xBEEF}
	testing.expect(t, size_of(u16) < size_of(rawptr))
	testing.expect_value(t, http.response_defer(&c.ctx, u16(0xBEEF), proc(ctx: ^http.Ctx, v: u16) {
		sp := http.context_get(ctx, Small_Payload)
		append(sp.out, Event{kind = "u16", u16v = v})
	}), nil)
	testing.expect_value(t, c.transaction_arena.tail, tx_tail_before)
	testing.expect_value(t, c.transaction_arena.tail.offset, tx_offset_before)

	http.context_add(&c.ctx, sub_val)

	// Exact pointer-width value (time.Time on 64-bit) with no heap/arena clone.
	stamp := time.Time{_nsec = 123456789}
	tx_after_ctx_add := c.transaction_arena.tail.offset
	testing.expect_value(t, http.response_defer(&c.ctx, stamp, proc(ctx: ^http.Ctx, ts: time.Time) {
		sp := http.context_get(ctx, Small_Payload)
		append(sp.out, Event{kind = "time", nsec = ts._nsec})
	}), nil)
	when size_of(time.Time) <= size_of(rawptr) {
		testing.expect_value(t, c.transaction_arena.tail.offset, tx_after_ctx_add)
	}

	// Struct larger than rawptr is cloned onto transaction_allocator before returning.
	local_large := Large_Payload{out = &events, tag = "cloned", n = 99}
	testing.expect(t, size_of(Large_Payload) > size_of(rawptr))
	testing.expect_value(t, http.response_defer(&c.ctx, local_large, proc(_: ^http.Ctx, lp: Large_Payload) {
		append(lp.out, Event{kind = "large", tag = lp.tag, n = lp.n})
	}), nil)
	// Clobber caller stack copy to prove defer observes cloned payload.
	local_large = {}

	// 2-arg form interoperates in the same LIFO stack.
	testing.expect_value(t, http.response_defer(&c.ctx, proc(ctx: ^http.Ctx) {
		sp := http.context_get(ctx, Small_Payload)
		append(sp.out, Event{kind = "plain"})
	}), nil)

	http._check_send_done(c)

	testing.expect_value(t, len(c.res._deferred), 0)
	testing.expect_value(t, len(events), 5)
	if len(events) == 5 {
		testing.expect_value(t, events[0], Event{kind = "plain"})
		testing.expect_value(t, events[1], Event{kind = "large", tag = "cloned", n = 99})
		testing.expect_value(t, events[2], Event{kind = "time", nsec = 123456789})
		testing.expect_value(t, events[3], Event{kind = "u16", u16v = 0xBEEF})
		testing.expect_value(t, events[4], Event{kind = "ptr"})
	}
}
