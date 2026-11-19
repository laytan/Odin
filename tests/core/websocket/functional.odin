#+build windows, linux, darwin
package tests_websocket

import c "core:c/libc"
import "core:encoding/endian"
import "core:fmt"
import "core:net"
import "core:nbio"
import "core:testing"
import "core:thread"
import "core:time"

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
	msg_arenas:       [4]^http.Arena,
	msg_arena_count:  int,
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
		},
		on_message = proc(s: ^websocket.Server, c: ^http.Connection, message: websocket.Message) {
			st := (^WS_Test_State)(s.user_data)
			st.msg_count += 1
			st.last_msg_type = message.type
			st.last_msg_len = copy(st.last_msg[:], message.data)
			if st.msg_arena_count < len(st.msg_arenas) {
				st.msg_arenas[st.msg_arena_count] = message.arena
				st.msg_arena_count += 1
			}
			websocket.send(c, message.type, message.data)
		},
		on_close = proc(s: ^websocket.Server, c: ^http.Connection, closure: Maybe(websocket.Closure)) {
			st := (^WS_Test_State)(s.user_data)
			st.closed = true
			if cl, has_cl := closure.?; has_cl {
				st.has_closure = true
				st.close_type = cl.type
				st.close_status = cl.status
				st.close_reason_len = copy(st.close_reason[:], cl.reason)
				if cl.arena != nil {
					http.arena_destroy(cl.arena)
				}
			}
			for i in 0 ..< st.msg_arena_count {
				if st.msg_arenas[i] != nil {
					http.arena_destroy(st.msg_arenas[i])
					st.msg_arenas[i] = nil
				}
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
	testing.expect_value(t, ws_state.last_msg_type, websocket.Message_Type.Text)
	testing.expect_value(t, string(ws_state.last_msg[:ws_state.last_msg_len]), "hello ws")
	testing.expect(t, ws_state.closed, "expected server on_close callback")
	testing.expect(t, ws_state.has_closure, "expected client WebSocket closure details")
	testing.expect_value(t, ws_state.close_type, websocket.Closure_Type.Client)
	testing.expect_value(t, ws_state.close_status, websocket.Status.Normal)
	testing.expect_value(t, string(ws_state.close_reason[:ws_state.close_reason_len]), "bye")
}
