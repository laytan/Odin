#+build windows, linux, darwin
package tests_websocket

import "base:runtime"

import c "core:c/libc"
import "core:bytes"
import "core:encoding/endian"
import "core:fmt"
import "core:net"
import "core:nbio"
import "core:strconv"
import "core:strings"
import "core:testing"
import "core:thread"
import "core:time"
import "core:unicode/utf8"

import http "core:http2"
import websocket "core:websocket"
import "vendor:curl"

@(init, private="file")
_curl_init :: proc "contextless" () {
	curl.global_init(curl.GLOBAL_ALL)
}

WS_Test_State :: struct {
	opened:           bool,
	msg_count:        int,
	last_msg_type:    websocket.Message_Type,
	last_msg:         [64]byte,
	last_msg_len:     int,
	sent_cb_count:    int,
	sent_cb_err:      http.Send_Error,
	closed:           bool,
	has_closure:      bool,
	close_type:       websocket.Closure_Type,
	close_status:     websocket.Status,
	close_reason:     [64]byte,
	close_reason_len: int,
}

WS_Client_Context :: struct {
	server:                  ^http.Server,
	endpoint_err:            net.Socket_Info_Error,
	handle_ok:               bool,
	setopt_url_err:          curl.code,
	setopt_connect_only_err: curl.code,
	perform_err:             curl.code,
	getinfo_err:             curl.code,
	status:                  c.long,

	echo_send_err:           curl.code,
	echo_recv_err:           curl.code,
	echo_flags:              curl.ws_flags,
	echo_payload:            [32]byte,
	echo_len:                int,

	pong_send_err:           curl.code,
	pong_recv_err:           curl.code,
	pong_flags:              curl.ws_flags,
	pong_payload:            [32]byte,
	pong_len:                int,

	close_send_err:          curl.code,
	close_recv_err:          curl.code,
	close_flags:             curl.ws_flags,
	close_payload:           [32]byte,
	close_len:               int,

	eof_err:                 curl.code,
}

curl_ws_send_frame :: proc(handle: ^curl.CURL, data: []byte, flags: curl.ws_flags) -> curl.code {
	deadline := time.tick_now()
	offset := 0
	for {
		sent: c.size_t
		ptr: rawptr
		if offset < len(data) {
			ptr = raw_data(data[offset:])
		}
		err := curl.ws_send(handle, ptr, c.size_t(len(data[offset:])), &sent, 0, flags)
		if err == .E_AGAIN {
			if time.tick_since(deadline) >= 2 * time.Second {
				return .E_AGAIN
			}
			time.sleep(time.Millisecond)
			continue
		}
		if err != .E_OK {
			return err
		}
		offset += int(sent)
		if offset >= len(data) {
			return .E_OK
		}
	}
}

curl_ws_recv_frame :: proc(handle: ^curl.CURL, dst: []byte) -> (n: int, flags: curl.ws_flags, err: curl.code) {
	deadline := time.tick_now()
	for {
		got: c.size_t
		meta: ^curl.ws_frame
		ptr: rawptr
		if n < len(dst) {
			ptr = raw_data(dst[n:])
		}
		err = curl.ws_recv(handle, ptr, c.size_t(len(dst[n:])), &got, &meta)
		if err == .E_AGAIN {
			if time.tick_since(deadline) >= 2 * time.Second {
				return n, flags, .E_AGAIN
			}
			time.sleep(time.Millisecond)
			continue
		}
		if err != .E_OK {
			return n, flags, err
		}
		n += int(got)
		if meta != nil {
			flags |= meta.flags
		}
		if meta == nil || meta.bytesleft == 0 || n == len(dst) {
			return n, flags, .E_OK
		}
	}
}

@(test)
test_websocket_upgrade_with_curl :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	ws_state: WS_Test_State
	ws_server := websocket.Server{
		user_data = &ws_state,
		on_open = proc(s: ^websocket.Server, c: ^http.Connection) {
			st := (^WS_Test_State)(s.user_data)
			st.opened = true
			http.context_add(&c.ctx, st)
		},
		on_message = proc(s: ^websocket.Server, c: ^http.Connection, message: websocket.Message) {
			st := (^WS_Test_State)(s.user_data)
			st.msg_count += 1
			st.last_msg_type = message.type
			st.last_msg_len = copy(st.last_msg[:], message.data)
			websocket.send(c, message.type, message.data, proc(c: ^http.Connection, user_data: rawptr, err: http.Send_Error) {
				if arena := (^http.Arena)(user_data); arena != nil {
					http.arena_destroy(arena)
				}
				if st_ptr := http.context_get(&c.ctx, ^WS_Test_State); st_ptr != nil {
					st := st_ptr^
					st.sent_cb_count += 1
					if err != nil && st.sent_cb_err == nil {
						st.sent_cb_err = err
					}
				}
			}, message.arena)
		},
		on_close = proc(s: ^websocket.Server, c: ^http.Connection, closure: Maybe(websocket.Closure)) {
			st := (^WS_Test_State)(s.user_data)
			st.closed = true
			if cl, has_cl := closure.?; has_cl {
				st.has_closure = true
				st.close_type = cl.type
				st.close_status = cl.status
				st.close_reason_len = copy(st.close_reason[:], cl.reason)
			}
		},
	}

	r: http.Router
	defer http.router_destroy(r)
	http.route_get(&r, "/ws", websocket.handler(&ws_server))

	server := http.make_server(http.Server_Options{
		address      = nbio.IP4_Loopback,
		port         = 18081,
		thread_count = 1,
		handler      = http.router(&r),
	})

	setup_err := http._setup(&server)
	if !testing.expect_value(t, setup_err, nil) {
		http._destroy(&server)
		return
	}

	client_ctx := WS_Client_Context{server = &server}
	client_thread := thread.create_and_start_with_data(&client_ctx, proc(data: rawptr) {
		ctx := (^WS_Client_Context)(data)
		defer http.server_shutdown(ctx.server)

		endpoint, endpoint_err := nbio.bound_endpoint(ctx.server.socket)
		ctx.endpoint_err = endpoint_err
		if endpoint_err != nil {
			return
		}

		handle := curl.easy_init()
		ctx.handle_ok = handle != nil
		if handle == nil {
			return
		}
		defer curl.easy_cleanup(handle)

		url := fmt.ctprintf("ws://127.0.0.1:%d/ws", endpoint.port)
		ctx.setopt_url_err          = curl.easy_setopt(handle, .URL, url)
		ctx.setopt_connect_only_err = curl.easy_setopt(handle, .CONNECT_ONLY, c.long(2))

		ctx.perform_err = curl.easy_perform(handle)
		if ctx.perform_err != .E_OK {
			return
		}
		ctx.getinfo_err = curl.easy_getinfo(handle, .RESPONSE_CODE, &ctx.status)

		// Text echo round-trip.
		ctx.echo_send_err = curl_ws_send_frame(handle, transmute([]byte)string("hello ws"), curl.WS_TEXT)
		if ctx.echo_send_err != .E_OK {
			return
		}
		ctx.echo_len, ctx.echo_flags, ctx.echo_recv_err = curl_ws_recv_frame(handle, ctx.echo_payload[:])
		if ctx.echo_recv_err != .E_OK {
			return
		}

		// Ping -> Pong round-trip.
		ctx.pong_send_err = curl_ws_send_frame(handle, transmute([]byte)string("ping"), curl.WS_PING)
		if ctx.pong_send_err != .E_OK {
			return
		}
		ctx.pong_len, ctx.pong_flags, ctx.pong_recv_err = curl_ws_recv_frame(handle, ctx.pong_payload[:])
		if ctx.pong_recv_err != .E_OK {
			return
		}

		// Close handshake: 1000 Normal + "bye".
		close_req: [5]byte
		endian.unchecked_put_u16be(close_req[:2], u16(websocket.Status.Normal))
		copy(close_req[2:], "bye")
		ctx.close_send_err = curl_ws_send_frame(handle, close_req[:], curl.WS_CLOSE)
		if ctx.close_send_err != .E_OK {
			return
		}
		ctx.close_len, ctx.close_flags, ctx.close_recv_err = curl_ws_recv_frame(handle, ctx.close_payload[:])
		if ctx.close_recv_err != .E_OK {
			return
		}

		eof_buf: [16]byte
		_, _, ctx.eof_err = curl_ws_recv_frame(handle, eof_buf[:])
	})

	http._serve(&server)
	thread.join(client_thread)
	thread.destroy(client_thread)
	http._destroy(&server)

	if !testing.expect_value(t, client_ctx.endpoint_err, nil) {
		return
	}
	if !testing.expect(t, client_ctx.handle_ok, "curl.easy_init failed") {
		return
	}
	testing.expect_value(t, client_ctx.setopt_url_err, curl.code.E_OK)
	testing.expect_value(t, client_ctx.setopt_connect_only_err, curl.code.E_OK)
	if client_ctx.perform_err == .E_UNSUPPORTED_PROTOCOL {
		testing.expectf(t, false, "curl WebSocket connect failed: %s (linked libcurl lacks ws protocol support; on macOS pass -extra-linker-flags:\"-L/opt/homebrew/opt/curl/lib\")", curl.easy_strerror(client_ctx.perform_err))
		return
	}
	if !testing.expectf(t, client_ctx.perform_err == .E_OK, "curl WebSocket handshake failed: %s", curl.easy_strerror(client_ctx.perform_err)) {
		return
	}
	testing.expect_value(t, client_ctx.getinfo_err, curl.code.E_OK)
	testing.expect_value(t, client_ctx.status, c.long(101))

	testing.expect_value(t, client_ctx.echo_send_err, curl.code.E_OK)
	testing.expect_value(t, client_ctx.echo_recv_err, curl.code.E_OK)
	testing.expect_value(t, client_ctx.echo_flags, curl.WS_TEXT)
	testing.expect_value(t, string(client_ctx.echo_payload[:client_ctx.echo_len]), "hello ws")

	testing.expect_value(t, client_ctx.pong_send_err, curl.code.E_OK)
	testing.expect_value(t, client_ctx.pong_recv_err, curl.code.E_OK)
	testing.expect_value(t, client_ctx.pong_flags, curl.WS_PONG)
	testing.expect_value(t, string(client_ctx.pong_payload[:client_ctx.pong_len]), "ping")

	testing.expect_value(t, client_ctx.close_send_err, curl.code.E_OK)
	testing.expect_value(t, client_ctx.close_recv_err, curl.code.E_OK)
	testing.expect_value(t, client_ctx.close_flags, curl.WS_CLOSE)
	if testing.expect_value(t, client_ctx.close_len, 5) {
		testing.expect_value(t, websocket.Status(endian.unchecked_get_u16be(client_ctx.close_payload[:2])), websocket.Status.Normal)
		testing.expect_value(t, string(client_ctx.close_payload[2:5]), "bye")
	}
	testing.expect_value(t, client_ctx.eof_err, curl.code.E_GOT_NOTHING)

	testing.expect(t, ws_state.opened, "expected server on_open callback")
	testing.expect_value(t, ws_state.msg_count, 1)
	testing.expect_value(t, ws_state.sent_cb_count, 1)
	testing.expect_value(t, ws_state.sent_cb_err, nil)
	testing.expect_value(t, ws_state.last_msg_type, websocket.Message_Type.Text)
	testing.expect_value(t, string(ws_state.last_msg[:ws_state.last_msg_len]), "hello ws")
	testing.expect(t, ws_state.closed, "expected server on_close callback")
	testing.expect(t, ws_state.has_closure, "expected client WebSocket closure details")
	testing.expect_value(t, ws_state.close_type, websocket.Closure_Type.Client)
	testing.expect_value(t, ws_state.close_status, websocket.Status.Normal)
	testing.expect_value(t, string(ws_state.close_reason[:ws_state.close_reason_len]), "bye")
}

@(test)
test_websocket_rejects_non_get_upgrade_methods :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	opened := false
	ws_server := websocket.Server{
		user_data = &opened,
		on_open = proc(s: ^websocket.Server, c: ^http.Connection) {
			(^bool)(s.user_data)^ = true
		},
	}

	r: http.Router
	defer http.router_destroy(r)
	http.route_get(&r, "/ws", websocket.handler(&ws_server))
	http.route_all(&r, "/ws-all", websocket.handler(&ws_server))

	server := http.make_server(http.Server_Options{
		address      = nbio.IP4_Loopback,
		port         = 18089,
		thread_count = 1,
		handler      = http.router(&r),
	})

	setup_err := http._setup(&server)
	if !testing.expect_value(t, setup_err, nil) {
		http._destroy(&server)
		return
	}

	Method_Case :: struct {
		setopt_ok:   bool,
		perform_err: curl.code,
		getinfo_err: curl.code,
		status:      c.long,
		allow_buf:   [64]byte,
		allow_len:   int,
	}

	Context :: struct {
		server:       ^http.Server,
		endpoint_err: net.Socket_Info_Error,
		head_res:     Method_Case,
		post_res:     Method_Case,
	}

	capture_allow :: proc "c" (contents: [^]byte, size: c.size_t, nmemb: c.size_t, userp: rawptr) -> c.size_t {
		context = runtime.default_context()

		real_size := int(size) * int(nmemb)
		line := strings.trim_space(string(contents[:real_size]))
		if colon := strings.index_byte(line, ':'); colon > 0 {
			if strings.equal_fold(line[:colon], "allow") {
				mc := (^Method_Case)(userp)
				val := strings.trim_space(line[colon+1:])
				mc.allow_len = copy(mc.allow_buf[:], val)
			}
		}
		return c.size_t(real_size)
	}

	discard_body :: proc "c" (contents: [^]byte, size: c.size_t, nmemb: c.size_t, userp: rawptr) -> c.size_t {
		return size * nmemb
	}

	ctx := Context{server = &server}
	client_thread := thread.create_and_start_with_data(&ctx, proc(data: rawptr) {
		ctx := (^Context)(data)
		defer http.server_shutdown(ctx.server)

		endpoint, endpoint_err := nbio.bound_endpoint(ctx.server.socket)
		ctx.endpoint_err = endpoint_err
		if endpoint_err != nil {
			return
		}

		do_req :: proc(port: int, path: string, is_head: bool, mc: ^Method_Case) {
			handle := curl.easy_init()
			if handle == nil { return }
			defer curl.easy_cleanup(handle)

			hdrs := curl.slist_append(nil, "Upgrade: websocket")
			hdrs = curl.slist_append(hdrs, "Connection: Upgrade")
			hdrs = curl.slist_append(hdrs, "Sec-WebSocket-Version: 13")
			hdrs = curl.slist_append(hdrs, "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==")
			defer curl.slist_free_all(hdrs)

			url := fmt.ctprintf("http://127.0.0.1:%d%s", port, path)
			method_ok := curl.easy_setopt(handle, .NOBODY, c.long(1)) == .E_OK if is_head else (
				curl.easy_setopt(handle, .POST, c.long(1)) == .E_OK &&
				curl.easy_setopt(handle, .POSTFIELDS, cstring("")) == .E_OK &&
				curl.easy_setopt(handle, .POSTFIELDSIZE, c.long(0)) == .E_OK
			)
			mc.setopt_ok = method_ok &&
				curl.easy_setopt(handle, .URL, url) == .E_OK &&
				curl.easy_setopt(handle, .HTTPHEADER, hdrs) == .E_OK &&
				curl.easy_setopt(handle, .HEADERFUNCTION, capture_allow) == .E_OK &&
				curl.easy_setopt(handle, .HEADERDATA, mc) == .E_OK &&
				curl.easy_setopt(handle, .WRITEFUNCTION, discard_body) == .E_OK
			if !mc.setopt_ok { return }

			mc.perform_err = curl.easy_perform(handle)
			mc.getinfo_err = curl.easy_getinfo(handle, .RESPONSE_CODE, &mc.status)
		}

		do_req(endpoint.port, "/ws", true, &ctx.head_res)
		do_req(endpoint.port, "/ws-all", false, &ctx.post_res)
	})

	http._serve(&server)
	thread.join(client_thread)
	thread.destroy(client_thread)
	http._destroy(&server)

	if !testing.expect_value(t, ctx.endpoint_err, nil) { return }
	testing.expect(t, !opened, "expected non-GET upgrade requests not to open WebSocket")

	for pair in ([2]struct{ name: string, mc: ^Method_Case }{{"HEAD /ws", &ctx.head_res}, {"POST /ws-all", &ctx.post_res}}) {
		testing.expectf(t, pair.mc.setopt_ok, "%s: setopt failed", pair.name)
		testing.expectf(t, pair.mc.perform_err == .E_OK, "%s: curl failed: %s", pair.name, curl.easy_strerror(pair.mc.perform_err))
		testing.expect_value(t, pair.mc.getinfo_err, curl.code.E_OK)
		testing.expect_value(t, pair.mc.status, c.long(405))
		testing.expect_value(t, string(pair.mc.allow_buf[:pair.mc.allow_len]), "GET")
	}
}

@(test)
test_websocket_ping_pong_and_header_recycling_with_curl :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	ROUNDS :: 40

	Server_State :: struct {
		msg_count:     int,
		sent_cb_count: int,
		sent_cb_err:   http.Send_Error,
		header_nodes:  int,
		pong_nodes:    int,
		closed:        bool,
	}

	st: Server_State
	ws_server := websocket.Server{
		user_data = &st,
		on_open = proc(s: ^websocket.Server, c: ^http.Connection) {
			http.context_add(&c.ctx, (^Server_State)(s.user_data))
		},
		on_message = proc(s: ^websocket.Server, c: ^http.Connection, message: websocket.Message) {
			st := (^Server_State)(s.user_data)
			st.msg_count += 1
			websocket.send(c, message.type, message.data, proc(c: ^http.Connection, user_data: rawptr, err: http.Send_Error) {
				if arena := (^http.Arena)(user_data); arena != nil {
					http.arena_destroy(arena)
				}
				if st_ptr := http.context_get(&c.ctx, ^Server_State); st_ptr != nil {
					st := st_ptr^
					st.sent_cb_count += 1
					if err != nil && st.sent_cb_err == nil {
						st.sent_cb_err = err
					}
				}
			}, message.arena)
		},
		on_close = proc(s: ^websocket.Server, c: ^http.Connection, closure: Maybe(websocket.Closure)) {
			st := (^Server_State)(s.user_data)
			st.closed = true

			if ws := http.context_get(&c.ctx, websocket._Connection); ws != nil {
				for n := ws.headers.free; n != nil; n = n.next { st.header_nodes += 1 }
				for n := ws.headers.in_flight; n != nil; n = n.next { st.header_nodes += 1 }
				for n := ws.pongs.free; n != nil; n = n.next { st.pong_nodes += 1 }
				for n := ws.pongs.in_flight; n != nil; n = n.next { st.pong_nodes += 1 }
			}
		},
	}

	r: http.Router
	defer http.router_destroy(r)
	http.route_get(&r, "/ws", websocket.handler(&ws_server))

	server := http.make_server(http.Server_Options{
		address      = nbio.IP4_Loopback,
		port         = 18090,
		thread_count = 1,
		handler      = http.router(&r),
	})

	setup_err := http._setup(&server)
	if !testing.expect_value(t, setup_err, nil) {
		http._destroy(&server)
		return
	}

	Client_Ctx :: struct {
		server:       ^http.Server,
		endpoint_err: net.Socket_Info_Error,
		handle_ok:    bool,
		perform_err:  curl.code,
		rounds_ok:    int,
		step_err:     curl.code,
		mismatch:     bool,
		close_err:    curl.code,
	}

	c_ctx := Client_Ctx{server = &server}
	client_thread := thread.create_and_start_with_data(&c_ctx, proc(data: rawptr) {
		ctx := (^Client_Ctx)(data)
		defer http.server_shutdown(ctx.server)

		endpoint, endpoint_err := nbio.bound_endpoint(ctx.server.socket)
		ctx.endpoint_err = endpoint_err
		if endpoint_err != nil { return }

		handle := curl.easy_init()
		ctx.handle_ok = handle != nil
		if handle == nil { return }
		defer curl.easy_cleanup(handle)

		url := fmt.ctprintf("ws://127.0.0.1:%d/ws", endpoint.port)
		if curl.easy_setopt(handle, .URL, url) != .E_OK || curl.easy_setopt(handle, .CONNECT_ONLY, c.long(2)) != .E_OK {
			return
		}
		ctx.perform_err = curl.easy_perform(handle)
		if ctx.perform_err != .E_OK { return }

		recv_buf: [64]byte
		for _ in 0 ..< ROUNDS {
			if err := curl_ws_send_frame(handle, transmute([]byte)string("ping"), curl.WS_PING); err != .E_OK {
				ctx.step_err = err
				return
			}
			n, flags, rerr := curl_ws_recv_frame(handle, recv_buf[:])
			if rerr != .E_OK {
				ctx.step_err = rerr
				return
			}
			if flags != curl.WS_PONG || string(recv_buf[:n]) != "ping" {
				ctx.mismatch = true
				return
			}

			// Unsolicited Pong followed immediately by Text also exercises pipelined arena recycling.
			if err := curl_ws_send_frame(handle, transmute([]byte)string("pong"), curl.WS_PONG); err != .E_OK {
				ctx.step_err = err
				return
			}
			if err := curl_ws_send_frame(handle, transmute([]byte)string("hello"), curl.WS_TEXT); err != .E_OK {
				ctx.step_err = err
				return
			}
			tn, tflags, trerr := curl_ws_recv_frame(handle, recv_buf[:])
			if trerr != .E_OK {
				ctx.step_err = trerr
				return
			}
			if tflags != curl.WS_TEXT || string(recv_buf[:tn]) != "hello" {
				ctx.mismatch = true
				return
			}
			ctx.rounds_ok += 1
		}

		close_req: [2]byte
		endian.unchecked_put_u16be(close_req[:2], u16(websocket.Status.Normal))
		ctx.close_err = curl_ws_send_frame(handle, close_req[:], curl.WS_CLOSE)
		if ctx.close_err == .E_OK {
			_, _, _ = curl_ws_recv_frame(handle, recv_buf[:])
		}
	})

	http._serve(&server)
	thread.join(client_thread)
	thread.destroy(client_thread)
	http._destroy(&server)

	if !testing.expect_value(t, c_ctx.endpoint_err, nil) { return }
	testing.expect(t, c_ctx.handle_ok, "curl.easy_init failed")
	testing.expect_value(t, c_ctx.perform_err, curl.code.E_OK)
	testing.expect_value(t, c_ctx.step_err, curl.code.E_OK)
	testing.expect(t, !c_ctx.mismatch, "unexpected ping/pong or text echo payload/flags")
	testing.expect_value(t, c_ctx.rounds_ok, ROUNDS)
	testing.expect_value(t, c_ctx.close_err, curl.code.E_OK)

	testing.expect(t, st.closed, "expected on_close callback")
	testing.expect_value(t, st.msg_count, ROUNDS)
	testing.expect_value(t, st.sent_cb_count, ROUNDS)
	testing.expect_value(t, st.sent_cb_err, nil)
	testing.expectf(t, st.header_nodes > 0 && st.header_nodes <= 4, "expected bounded recycled header nodes (<= 4) across %d sends, got %d", ROUNDS*2+1, st.header_nodes)
	testing.expectf(t, st.pong_nodes > 0 && st.pong_nodes <= 4, "expected bounded recycled pong nodes (<= 4) across %d pings, got %d", ROUNDS, st.pong_nodes)
}

@(private="file")
_tcp_send_all :: proc(sock: net.TCP_Socket, data: []byte) -> bool {
	offset := 0
	for offset < len(data) {
		n, err := net.send_tcp(sock, data[offset:])
		if err != nil || n <= 0 {
			return false
		}
		offset += n
	}
	return true
}

@(private="file")
_tcp_recv_exact :: proc(sock: net.TCP_Socket, buf: []byte) -> bool {
	offset := 0
	for offset < len(buf) {
		n, err := net.recv_tcp(sock, buf[offset:])
		if err != nil || n <= 0 {
			return false
		}
		offset += n
	}
	return true
}

@(private="file")
_ws_raw_handshake :: proc(endpoint: net.Endpoint, raw_req: string) -> (sock: net.TCP_Socket, status: int, ok: bool) {
	dial_err: net.Network_Error
	sock, dial_err = net.dial_tcp(endpoint)
	if dial_err != nil {
		return
	}
	_ = net.set_option(sock, .Receive_Timeout, 2 * time.Second)

	if !_tcp_send_all(sock, transmute([]byte)raw_req) {
		net.close(sock)
		return {}, 0, false
	}

	// Read headers 1 byte at a time so any post-\r\n\r\n server WebSocket frames remain unread in the kernel buffer.
	hdr_buf: [2048]byte
	total := 0
	sep := transmute([]byte)string("\r\n\r\n")
	for total < len(hdr_buf) {
		n, rerr := net.recv_tcp(sock, hdr_buf[total:total+1])
		if rerr != nil || n <= 0 {
			net.close(sock)
			return {}, 0, false
		}
		total += n
		if total >= len(sep) && bytes.equal(hdr_buf[total-len(sep):total], sep) {
			break
		}
	}
	if total < len(sep) || !bytes.equal(hdr_buf[total-len(sep):total], sep) {
		net.close(sock)
		return {}, 0, false
	}

	head_str := string(hdr_buf[:total])
	line_end := strings.index(head_str, "\r\n")
	if line_end < 0 {
		net.close(sock)
		return {}, 0, false
	}
	rline := head_str[:line_end]
	sp1 := strings.index_byte(rline, ' ')
	if sp1 < 0 {
		net.close(sock)
		return {}, 0, false
	}
	rest := rline[sp1+1:]
	sp2 := strings.index_byte(rest, ' ')
	status_str := rest[:sp2] if sp2 >= 0 else rest
	parsed, parse_ok := strconv.parse_int(status_str)
	if !parse_ok {
		net.close(sock)
		return {}, 0, false
	}

	return sock, parsed, true
}

@(private="file")
_ws_append_frame :: proc(dst: ^[dynamic]byte, fin: bool, opcode: u8, masked: bool, payload: []byte) {
	b0 := (u8(fin) << 7) | (opcode & 0x0F)
	mask_bit := u8(masked) << 7
	if len(payload) <= 125 {
		append(dst, b0, mask_bit | u8(len(payload)))
	} else {
		append(dst, b0, mask_bit | 126, u8(len(payload) >> 8), u8(len(payload)))
	}

	if masked {
		mask := [4]byte{0x12, 0x34, 0x56, 0x78}
		append(dst, mask[0], mask[1], mask[2], mask[3])
		for b, i in payload {
			append(dst, b ~ mask[i & 3])
		}
	} else {
		for b in payload {
			append(dst, b)
		}
	}
}

@(private="file")
_ws_recv_raw_frame :: proc(sock: net.TCP_Socket, payload_dst: []byte) -> (fin: bool, opcode: u8, payload: []byte, ok: bool) {
	hdr: [2]byte
	if !_tcp_recv_exact(sock, hdr[:]) {
		return
	}
	fin = (hdr[0] & 0x80) != 0
	opcode = hdr[0] & 0x0F
	if (hdr[1] & 0x80) != 0 {
		return
	}

	plen := u64(hdr[1] & 0x7F)
	if plen == 126 {
		ext: [2]byte
		if !_tcp_recv_exact(sock, ext[:]) {
			return
		}
		plen = u64(endian.unchecked_get_u16be(ext[:]))
	} else if plen == 127 {
		ext: [8]byte
		if !_tcp_recv_exact(sock, ext[:]) {
			return
		}
		plen = endian.unchecked_get_u64be(ext[:])
	}

	if plen > u64(len(payload_dst)) {
		return
	}
	if plen > 0 {
		if !_tcp_recv_exact(sock, payload_dst[:plen]) {
			return
		}
	}
	return fin, opcode, payload_dst[:plen], true
}

@(test)
test_websocket_upgrade_header_validation :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	open_count := 0
	ws_server := websocket.Server{
		user_data = &open_count,
		on_open = proc(s: ^websocket.Server, c: ^http.Connection) {
			(^int)(s.user_data)^ += 1
		},
	}

	r: http.Router
	defer http.router_destroy(r)
	http.route_get(&r, "/ws", websocket.handler(&ws_server))

	server := http.make_server(http.Server_Options{
		address      = nbio.IP4_Loopback,
		port         = 18091,
		thread_count = 1,
		handler      = http.router(&r),
	})

	setup_err := http._setup(&server)
	if !testing.expect_value(t, setup_err, nil) {
		http._destroy(&server)
		return
	}

	Case :: struct {
		name:     string,
		raw_req:  string,
		expected: int,
		ok:       bool,
		status:   int,
	}

	Ctx :: struct {
		server:       ^http.Server,
		endpoint_err: net.Socket_Info_Error,
		cases:        [4]Case,
	}

	c_ctx := Ctx{
		server = &server,
		cases = {
			{
				name = "multi-token Connection header",
				raw_req = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
				expected = 101,
			},
			{
				name = "repeated Connection headers",
				raw_req = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: keep-alive\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
				expected = 101,
			},
			{
				name = "invalid base64 Sec-WebSocket-Key",
				raw_req = "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: !!!!!!!!!!!!!!!!!!!!!!==\r\n\r\n",
				expected = 400,
			},
			{
				name = "HTTP/1.0 upgrade request",
				raw_req = "GET /ws HTTP/1.0\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n",
				expected = 400,
			},
		},
	}

	client_thread := thread.create_and_start_with_data(&c_ctx, proc(data: rawptr) {
		ctx := (^Ctx)(data)
		defer http.server_shutdown(ctx.server)

		endpoint, endpoint_err := nbio.bound_endpoint(ctx.server.socket)
		ctx.endpoint_err = endpoint_err
		if endpoint_err != nil { return }

		for &tc in ctx.cases {
			sock, st, ok := _ws_raw_handshake(endpoint, tc.raw_req)
			tc.ok = ok
			tc.status = st
			if ok {
				if st == 101 {
					// Send clean Close so shutdown does not stall waiting on client FIN.
					frame: [dynamic]byte
					defer delete(frame)
					close_payload: [2]byte
					endian.unchecked_put_u16be(close_payload[:], u16(websocket.Status.Normal))
					_ws_append_frame(&frame, true, 8, true, close_payload[:])
					_ = _tcp_send_all(sock, frame[:])
					dump: [32]byte
					_, _, _, _ = _ws_recv_raw_frame(sock, dump[:])
				}
				net.close(sock)
			}
		}
	})

	http._serve(&server)
	thread.join(client_thread)
	thread.destroy(client_thread)
	http._destroy(&server)

	if !testing.expect_value(t, c_ctx.endpoint_err, nil) { return }
	for tc in c_ctx.cases {
		testing.expectf(t, tc.ok, "%s: handshake failed", tc.name)
		testing.expectf(t, tc.status == tc.expected, "%s: expected HTTP %d, got %d", tc.name, tc.expected, tc.status)
	}
	testing.expect_value(t, open_count, 2)
}

@(test)
test_websocket_protocol_hardening_and_max_message_size :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	ws_server := websocket.Server{
		max_message_size = 10,
		on_message = proc(s: ^websocket.Server, c: ^http.Connection, message: websocket.Message) {
			http.arena_destroy(message.arena)
		},
	}

	// Build a >123-byte UTF-8 reason where byte 123 lands inside a 2-byte rune ("é").
	long_reason_buf: [127]byte
	for i in 0 ..< 122 {
		long_reason_buf[i] = 'a'
	}
	long_reason_buf[122] = 0xC3
	long_reason_buf[123] = 0xA9
	long_reason_buf[124] = 'z'
	long_reason_buf[125] = 'z'
	long_reason_buf[126] = 'z'

	ws_close_server := websocket.Server{
		user_data = &long_reason_buf,
		on_open = proc(s: ^websocket.Server, c: ^http.Connection) {
			buf := (^[127]byte)(s.user_data)
			websocket.send_close(c, .Normal, string(buf[:]))
		},
	}

	r: http.Router
	defer http.router_destroy(r)
	http.route_get(&r, "/ws", websocket.handler(&ws_server))
	http.route_get(&r, "/ws-long-close", websocket.handler(&ws_close_server))

	server := http.make_server(http.Server_Options{
		address      = nbio.IP4_Loopback,
		port         = 18092,
		thread_count = 1,
		handler      = http.router(&r),
	})

	setup_err := http._setup(&server)
	if !testing.expect_value(t, setup_err, nil) {
		http._destroy(&server)
		return
	}

	Ctx :: struct {
		server:             ^http.Server,
		endpoint_err:       net.Socket_Info_Error,
		unmasked_status:    websocket.Status,
		unmasked_ok:        bool,
		short_close_status: websocket.Status,
		short_close_ok:     bool,
		pong_ok:            bool,
		pong_payload:       [16]byte,
		pong_len:           int,
		overflow_status:    websocket.Status,
		overflow_ok:        bool,
		long_close_ok:      bool,
		long_close_status:  websocket.Status,
		long_close_reason:  [128]byte,
		long_close_rlen:    int,
	}

	c_ctx := Ctx{server = &server}
	client_thread := thread.create_and_start_with_data(&c_ctx, proc(data: rawptr) {
		ctx := (^Ctx)(data)
		defer http.server_shutdown(ctx.server)

		endpoint, endpoint_err := nbio.bound_endpoint(ctx.server.socket)
		ctx.endpoint_err = endpoint_err
		if endpoint_err != nil { return }

		ws_req :: "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"

		// 1. Unmasked client Text frame -> 1002 Protocol Error.
		if sock, st, ok := _ws_raw_handshake(endpoint, ws_req); ok {
			defer net.close(sock)
			if st == 101 {
				buf: [dynamic]byte
				defer delete(buf)
				_ws_append_frame(&buf, true, 1, false, transmute([]byte)string("hi"))
				_ = _tcp_send_all(sock, buf[:])
				resp: [128]byte
				_, op, payload, rok := _ws_recv_raw_frame(sock, resp[:])
				if rok && op == 8 && len(payload) >= 2 {
					ctx.unmasked_ok = true
					ctx.unmasked_status = websocket.Status(endian.unchecked_get_u16be(payload[:2]))
				}
			}
		}

		// 2. Masked 1-byte Close frame -> 1002 Protocol Error.
		if sock, st, ok := _ws_raw_handshake(endpoint, ws_req); ok {
			defer net.close(sock)
			if st == 101 {
				buf: [dynamic]byte
				defer delete(buf)
				_ws_append_frame(&buf, true, 8, true, []byte{0x03})
				_ = _tcp_send_all(sock, buf[:])
				resp: [128]byte
				_, op, payload, rok := _ws_recv_raw_frame(sock, resp[:])
				if rok && op == 8 && len(payload) >= 2 {
					ctx.short_close_ok = true
					ctx.short_close_status = websocket.Status(endian.unchecked_get_u16be(payload[:2]))
				}
			}
		}

		// 3. Fragmented message exceeding max_message_size (10) with an interleaved 10-byte Ping.
		if sock, st, ok := _ws_raw_handshake(endpoint, ws_req); ok {
			defer net.close(sock)
			if st == 101 {
				buf: [dynamic]byte
				defer delete(buf)
				// Fragment 1 (6 bytes) + Ping (10 bytes, valid control frame).
				_ws_append_frame(&buf, false, 1, true, transmute([]byte)string("abcdef"))
				_ws_append_frame(&buf, true, 9, true, transmute([]byte)string("0123456789"))
				_ = _tcp_send_all(sock, buf[:])

				resp: [128]byte
				_, pop, ppayload, pok := _ws_recv_raw_frame(sock, resp[:])
				if pok && pop == 10 {
					ctx.pong_ok = true
					ctx.pong_len = copy(ctx.pong_payload[:], ppayload)
				}

				clear(&buf)
				// Fragment 2 (4 bytes -> total 10, still within max_message_size) + Fragment 3 (1 byte -> 11 > 10).
				_ws_append_frame(&buf, false, 0, true, transmute([]byte)string("ghij"))
				_ws_append_frame(&buf, true, 0, true, transmute([]byte)string("k"))
				_ = _tcp_send_all(sock, buf[:])

				_, cop, cpayload, cok := _ws_recv_raw_frame(sock, resp[:])
				if cok && cop == 8 && len(cpayload) >= 2 {
					ctx.overflow_ok = true
					ctx.overflow_status = websocket.Status(endian.unchecked_get_u16be(cpayload[:2]))
				}
			}
		}

		// 4. send_close truncating >123-byte reason safely on UTF-8 boundary.
		long_req :: "GET /ws-long-close HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
		if sock, st, ok := _ws_raw_handshake(endpoint, long_req); ok {
			defer net.close(sock)
			if st == 101 {
				resp: [256]byte
				_, op, payload, rok := _ws_recv_raw_frame(sock, resp[:])
				if rok && op == 8 && len(payload) >= 2 {
					ctx.long_close_ok = true
					ctx.long_close_status = websocket.Status(endian.unchecked_get_u16be(payload[:2]))
					ctx.long_close_rlen = copy(ctx.long_close_reason[:], payload[2:])
				}
			}
		}
	})

	http._serve(&server)
	thread.join(client_thread)
	thread.destroy(client_thread)
	http._destroy(&server)

	if !testing.expect_value(t, c_ctx.endpoint_err, nil) { return }
	testing.expect(t, c_ctx.unmasked_ok, "expected Close frame on unmasked client frame")
	testing.expect_value(t, c_ctx.unmasked_status, websocket.Status.Protocol_Error)
	testing.expect(t, c_ctx.short_close_ok, "expected Close frame on 1-byte client Close")
	testing.expect_value(t, c_ctx.short_close_status, websocket.Status.Protocol_Error)
	testing.expect(t, c_ctx.pong_ok, "expected interleaved Ping to receive Pong during fragmentation")
	testing.expect_value(t, string(c_ctx.pong_payload[:c_ctx.pong_len]), "0123456789")
	testing.expect(t, c_ctx.overflow_ok, "expected Too_Big Close on fragmented overflow")
	testing.expect_value(t, c_ctx.overflow_status, websocket.Status.Too_Big)

	testing.expect(t, c_ctx.long_close_ok, "expected server long Close frame")
	testing.expect_value(t, c_ctx.long_close_status, websocket.Status.Normal)
	testing.expect_value(t, c_ctx.long_close_rlen, 122)
	reason := string(c_ctx.long_close_reason[:c_ctx.long_close_rlen])
	testing.expect(t, utf8.valid_string(reason), "expected truncated close reason to remain valid UTF-8")
	testing.expect_value(t, reason, string(long_reason_buf[:122]))
}

@(test)
test_websocket_pipelined_frames_with_immediate_arena_destroy :: proc(t: ^testing.T) {
	testing.set_fail_timeout(t, 5 * time.Second)

	State :: struct {
		msgs:         [4][32]byte,
		msg_lens:     [4]int,
		msg_count:    int,
		closed:       bool,
		close_status: websocket.Status,
	}

	st: State
	ws_server := websocket.Server{
		user_data = &st,
		on_message = proc(s: ^websocket.Server, c: ^http.Connection, message: websocket.Message) {
			st := (^State)(s.user_data)
			if st.msg_count < len(st.msgs) {
				st.msg_lens[st.msg_count] = copy(st.msgs[st.msg_count][:], message.data)
			}
			st.msg_count += 1
			// Destroy message.arena synchronously even when further pipelined frames follow on the socket.
			http.arena_destroy(message.arena)
		},
		on_close = proc(s: ^websocket.Server, c: ^http.Connection, closure: Maybe(websocket.Closure)) {
			st := (^State)(s.user_data)
			st.closed = true
			if cl, ok := closure.?; ok {
				st.close_status = cl.status
			}
		},
	}

	r: http.Router
	defer http.router_destroy(r)
	http.route_get(&r, "/ws", websocket.handler(&ws_server))

	server := http.make_server(http.Server_Options{
		address      = nbio.IP4_Loopback,
		port         = 18093,
		thread_count = 1,
		handler      = http.router(&r),
	})

	setup_err := http._setup(&server)
	if !testing.expect_value(t, setup_err, nil) {
		http._destroy(&server)
		return
	}

	Ctx :: struct {
		server:       ^http.Server,
		endpoint_err: net.Socket_Info_Error,
		handshake_ok: bool,
		close_ok:     bool,
		close_status: websocket.Status,
	}

	c_ctx := Ctx{server = &server}
	client_thread := thread.create_and_start_with_data(&c_ctx, proc(data: rawptr) {
		ctx := (^Ctx)(data)
		defer http.server_shutdown(ctx.server)

		endpoint, endpoint_err := nbio.bound_endpoint(ctx.server.socket)
		ctx.endpoint_err = endpoint_err
		if endpoint_err != nil { return }

		req :: "GET /ws HTTP/1.1\r\nHost: 127.0.0.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n\r\n"
		sock, status, ok := _ws_raw_handshake(endpoint, req)
		if !ok || status != 101 {
			if ok { net.close(sock) }
			return
		}
		defer net.close(sock)
		ctx.handshake_ok = true

		// Pipeline single-frame Text + 2-fragment Text + single-frame Text + Close in one TCP write.
		pipe: [dynamic]byte
		defer delete(pipe)
		_ws_append_frame(&pipe, true,  1, true, transmute([]byte)string("first"))
		_ws_append_frame(&pipe, false, 1, true, transmute([]byte)string("hel"))
		_ws_append_frame(&pipe, true,  0, true, transmute([]byte)string("lo"))
		_ws_append_frame(&pipe, true,  1, true, transmute([]byte)string("third"))
		close_req: [2]byte
		endian.unchecked_put_u16be(close_req[:], u16(websocket.Status.Normal))
		_ws_append_frame(&pipe, true, 8, true, close_req[:])

		if !_tcp_send_all(sock, pipe[:]) {
			return
		}

		resp: [64]byte
		_, op, payload, rok := _ws_recv_raw_frame(sock, resp[:])
		if rok && op == 8 && len(payload) >= 2 {
			ctx.close_ok = true
			ctx.close_status = websocket.Status(endian.unchecked_get_u16be(payload[:2]))
		}
	})

	http._serve(&server)
	thread.join(client_thread)
	thread.destroy(client_thread)
	http._destroy(&server)

	if !testing.expect_value(t, c_ctx.endpoint_err, nil) { return }
	testing.expect(t, c_ctx.handshake_ok, "expected 101 Switching Protocols")
	testing.expect(t, c_ctx.close_ok, "expected Close echo after pipelined frames")
	testing.expect_value(t, c_ctx.close_status, websocket.Status.Normal)

	testing.expect(t, st.closed, "expected on_close")
	testing.expect_value(t, st.close_status, websocket.Status.Normal)
	if testing.expect_value(t, st.msg_count, 3) {
		testing.expect_value(t, string(st.msgs[0][:st.msg_lens[0]]), "first")
		testing.expect_value(t, string(st.msgs[1][:st.msg_lens[1]]), "hello")
		testing.expect_value(t, string(st.msgs[2][:st.msg_lens[2]]), "third")
	}
}
